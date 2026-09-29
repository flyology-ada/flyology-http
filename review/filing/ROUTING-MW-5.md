Title: CORS middleware omits Vary: Origin on responses whose header set depends on Origin
Labels: bug
Refs: none

## Summary

`Middleware_CORS` emits `Vary: Origin` only from `Add_Origin`, which runs only after the request carried an allowed origin. A request with no `Origin` field, or with an origin the policy does not allow, produces a cacheable response with neither `Access-Control-Allow-Origin` nor `Vary`, although the representation's header set does depend on `Origin`. A shared cache stores that copy under a key that ignores `Origin` and serves it to a later cross-origin fetch, which the user agent then blocks on a resource the server would have allowed.

## Problem

Commit `f078732`.

`Vary: Origin` is emitted in exactly one place (`src/flyology-http-server-middleware_cors.adb:15-30`):

```ada
   procedure Add_Origin
     (X      : in out App.Exchange;
      Policy : CORS.Policy;
      Origin : String)
   is
   begin
      X.Add_Header
        ("Access-Control-Allow-Origin",
         (if CORS.Wildcard (Policy) then "*" else Origin));
      if not CORS.Wildcard (Policy) then
         X.Add_Header ("Vary", "Origin");
      end if;
```

`Call` returns before reaching it on three paths. No CORS slot or no `Origin` field (`:40-43`):

```ada
      if Slot = 0 or else Origin = "" then
         Next.Call (Context, X);
         return;
      end if;
```

a non-preflight request whose origin is not allowed (`:53-61`):

```ada
         if Policy = null or else not CORS.Origin_Allowed (Policy.all, Origin)
         then
            if Preflight then
               X.Problem (403, "cors-origin-denied", "CORS origin denied");
            else
               Next.Call (Context, X);
            end if;
            return;
         end if;
```

and a non-preflight request whose method the policy does not allow (`:92-95`):

```ada
         if not CORS.Method_Allowed (Policy.all, X.Request_Method) then
            Next.Call (Context, X);
            return;
         end if;
```

CORS is specified by the WHATWG Fetch Standard. Its section "CORS protocol and HTTP caches" states the requirement:

> "If CORS protocol requirements are more complicated than setting `Access-Control-Allow-Origin` to * or a static origin, `Vary` is to be used."

and then describes this exact failure:

> "In particular, consider what happens if `Vary` is not used and a server is configured to send `Access-Control-Allow-Origin` for a certain resource only in response to a CORS request. When a user agent receives a response to a non-CORS request for that resource (for example, as the result of a navigation request), the response will lack `Access-Control-Allow-Origin` and the user agent will cache that response. Then, if the user agent subsequently encounters a CORS request for the resource, it will use that cached response from the previous non-CORS request, without `Access-Control-Allow-Origin`."

The same section gives the only alternative shape:

> "However, if `Access-Control-Allow-Origin` is set to * or a static origin for a particular resource, then configure the server to always send `Access-Control-Allow-Origin` in responses for the resource, for non-CORS requests as well as CORS requests, and do not use `Vary`."

The library matches neither. For a non-wildcard policy it emits both fields when the origin is allowed and neither when it is not, and `CORS.Create` accepts a list of origins, which places such a policy in the first quotation's "more complicated than ... a static origin" case. The mechanism the failure depends on is stated by RFC 9110 section 12.5.5:

> "In other words, Vary expands the cache key required to match a new request to the stored cache entry."

The preflight path is already correct, and the guide's claim that preflights "emit the required Vary fields" (`website/guide/server/index.html:438`) holds. This is the non-preflight path.

The existing coverage asserts `Vary: Origin` only where it is emitted: `tests/http_routing_audit.adb:1109-1111` asserts it for the allowed origin, and the neighbouring case at `:1112-1114` asserts only that `Access-Control-Allow-Origin` is absent for an unlisted origin, not that `Vary` is present. `tests/http_smoke.adb:3256-3257` asserts it on the allowed path as well.

## What happens now

Spike: a route `GET /data` with a two-origin, non-wildcard policy and `Allowed_Methods => "GET"`, served over an in-memory transport. It issues the same request three times, with an allowed `Origin`, with a disallowed `Origin`, and with no `Origin` at all, and reads `Access-Control-Allow-Origin` and `Vary` from each response.

```ada
   Listed : aliased constant CORS.Policy := CORS.Create
     (Allowed_Origins => "https://app.example https://ops.example",
      Allowed_Methods => "GET");
   ...
        Answer ("Origin: https://app.example" & CRLF);
        Answer ("Origin: https://evil.example" & CRLF);
        Answer ("");
```

```
  note allowed  ACAO=[https://app.example] Vary=[Origin]
  ok   control: an allowed origin is reflected
  ok   control: the allowed-origin response carries Vary: Origin
  note denied   ACAO=[] Vary=[]
  ok   a disallowed origin is not reflected
  FAIL the disallowed-origin response carries Vary: Origin
  note no-Origin ACAO=[] Vary=[]
  ok   a non-CORS request gets no Access-Control-Allow-Origin
  FAIL the non-CORS response carries Vary: Origin, so a cache cannot reuse it for a later CORS request
checks: 6  failures: 2
BUG REPRODUCED
```

The allowed origin gets both fields. The disallowed origin and the non-CORS request each get a cacheable 200 with neither. No cache is in the loop, so the program establishes the emitted field set, which is the part the server controls, and not the cache's reuse of it.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A response from a route whose CORS policy is not a wildcard should carry `Vary: Origin` whether or not the request had an allowed `Origin`, so a shared cache keys the stored representation on the field that selected it. That is the first of the two configurations the WHATWG Fetch Standard's "CORS protocol and HTTP caches" section permits, and the only one open to a policy that lists more than one origin.

## Suggested treatment

Emit `Vary: Origin` for every response on a route that has a non-wildcard CORS policy, before the three early returns at `src/flyology-http-server-middleware_cors.adb:40-43`, `:53-61` and `:92-95`, rather than only from `Add_Origin` at `:15-30`. The condition is `X.CORS_Policy /= 0` and a resolvable non-wildcard policy, which the middleware already computes. `Add_Origin` then only adds the reflection and the credentials field.

The alternative the same Fetch section allows, always sending `Access-Control-Allow-Origin` and never sending `Vary`, applies only when the policy is a wildcard or exactly one static origin; the wildcard case already behaves that way, and extending it to a single-origin policy would be a second, narrower change rather than a substitute for this one.

The regression test belongs in `tests/http_routing_audit.adb` beside `Check_CORS_List_Member_Validation` at `:1105-1114`, extended so the unlisted-origin case and a request with no `Origin` both assert `Field_Value (..., "Vary") = "Origin"`. The spike is the test.

## Severity

Cache correctness only. `Origin_Allowed` is unchanged, nothing is reflected to a disallowed origin, and no credential or origin check is bypassed, so the failure mode is a cross-origin fetch blocked by the user agent on a resource the policy allows, which presents as an intermittent CORS error rather than a security hole. It needs a shared cache in front of the server and a non-wildcard policy, and the cache interaction itself is not reproduced here, only the emitted field set. Deterministic.
