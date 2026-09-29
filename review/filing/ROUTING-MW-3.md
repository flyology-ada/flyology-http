Title: HTTP/2 :path beginning with http:// is routed as an absolute-form target, unlike HTTP/3 and HTTP/1
Labels: bug
Refs: none

## Summary

Nothing on the HTTP/2 admission path requires `:path` to be an `absolute-path`, so a value such as `http://localhost/admin/users` reaches `Raw_Path`, which was written for the HTTP/1 absolute form. It strips the embedded authority, never compares it with `:authority`, and routes `/admin/users`. RFC 9113 requires such a request to be treated as malformed and answered with a stream error. HTTP/3 rejects the same value and HTTP/1 validates the embedded authority against `Host`, so the three protocols disagree on one input.

## Problem

Commit `f078732`.

HTTP/2 admission checks the method, the scheme, emptiness, `#` and `*`, and nothing else (`src/flyology-http-server-http_2.adb:2341-2349`):

```ada
               if Method_Text = "CONNECT" or else
                 Scheme_Text not in "http" | "https"
                 or else Path_Text = ""
                 or else Ada.Strings.Fixed.Index (Path_Text, "#") /= 0
                 or else (Path_Text = "*"
                   and then Method_Text /= "OPTIONS")
               then
                  raise Request_Message_Error with
                    "unsupported HTTP/2 request target";
```

HTTP/3 requires the leading slash (`src/flyology-http-http_3_header_policy.adb:299-304`):

```ada
         elsif (Scheme = "http" or else Scheme = "https")
           and then Path /= "*"
           and then Path (Path'First) /= '/'
         then
            Result.Status := Invalid_Path;
            return Result;
```

HTTP/1 accepts the absolute form, which RFC 9112 section 3.2.2 makes legal there, and validates it (`src/flyology-http-server.adb:838-848`):

```ada
            if Authority_Last < Authority_First
              or else not Valid_Authority
                (Request_Target (Authority_First .. Authority_Last))
            then
               raise Protocol_Error with "invalid absolute request authority";
            elsif Host'Length > 0
              and then Lower (Host) /= Lower
                (Request_Target (Authority_First .. Authority_Last))
            then
               raise Protocol_Error with "Host conflicts with request target";
            end if;
```

`Raw_Path` cannot tell which protocol produced the value (`src/flyology-http-server-routing.adb:283-286`, `:295-309`):

```ada
   function Absolute_Form_Authority (Target : String) return Natural is
     (if Has_Scheme_Prefix (Target, "http://") then Target'First + 7
      elsif Has_Scheme_Prefix (Target, "https://") then Target'First + 8
      else 0);
```

```ada
      elsif Authority /= 0 then
         Start := 0;
         for Index in Authority .. Target'Last loop
            if Target (Index) = '/' then
               Start := Index;
               exit;
            elsif Target (Index) = '?' then
               return "/";
            end if;
         end loop;
```

A second consequence follows from that early return: `Raw_Path` yields `"/"` when it meets `?` before any `/`, while `Requests.Find_Query` takes the first `?` of the whole target (`src/flyology-http-server-requests.adb:62-63`):

```ada
      Target : constant String := X.Request_Target;
      Mark   : constant Natural := Ada.Strings.Fixed.Index (Target, "?");
```

so `:path: http://localhost?x=1/admin` routes `/` while the query parameter `x` reads `1/admin`. The handler's view of the path and of the query come from different parses of one value.

RFC 9113 forbids the absolute form in `:path` at MUST level, through three linked clauses. Section 8.3.1 defines the value and requires it to be valid:

> "The ':path' pseudo-header field includes the path and query parts of the target URI (the absolute-path production and, optionally, a '?' character followed by the query production; see Section 4.1 of [HTTP])."

> "All HTTP/2 requests MUST include exactly one valid value for the ':method', ':scheme', and ':path' pseudo-header fields, unless they are CONNECT requests (Section 8.5)."

RFC 9110 section 4.1 gives `absolute-path = 1*( "/" segment )`, so `http://localhost/admin/users` is not one. RFC 9113 section 8.3 then says:

> "Endpoints MUST treat a request or response that contains undefined or invalid pseudo-header fields as malformed (Section 8.1.1)."

and RFC 9113 section 8.1.1:

> "Malformed requests or responses that are detected MUST be treated as a stream error (Section 5.4.2) of type PROTOCOL_ERROR."

The router also states that dispatch is protocol independent (`src/flyology-http-server-routing.ads:928-930`):

```ada
   --  Select HTTP/1.x or HTTP/2 for one accepted Flyology connection and
   --  serve it through this router. Route registration, middleware, body
   --  policy, and endpoint handlers are identical for both protocols.
```

No maintained test covers this input on HTTP/2. `tests/http_routing_audit.adb:164-240` exercises the absolute form over HTTP/1, where it is valid. `tests/flyology-http-http_3_header_policy-smoke.adb:94-95` pins the HTTP/3 rejection. A green h2spec 2.6.0 run is silent here: its cases under section 8.1.2.3 cover an empty `:path`, an omitted `:method`, `:scheme` or `:path`, and duplicated pseudo-header fields, and none sends a `:path` whose value is syntactically not an `absolute-path`.

## What happens now

Spike: a loopback HTTP/2 server with routes `GET /admin/users` (named `admin.users`) and `GET /` (named `root`), driven by a raw frame peer that encodes the request pseudo-header fields by hand; the handler echoes its route name, `X.Path` and the query parameter `x`. The same program then drives the HTTP/1 lane with the corresponding absolute-form request lines.

```ada
   function Request_Block (Path : String) return Stream_Element_Array is
     (Literal (":method", "GET") & Literal (":scheme", "http") &
      Literal (":authority", "localhost") & Literal (":path", Path));
   ...
   Probe ("http://localhost/admin/users", Response, Refused);
   Probe ("http://localhost?x=1/admin", Response, Refused);
```

```
  note control :path=/admin/users -> route=admin.users path=/admin/users x=
  ok   control: origin-form :path reaches its route
  note :path=http://localhost/admin/users -> route=admin.users path=/admin/users x=
  FAIL absolute-form :path is treated as malformed (RFC 9113 Sections 8.3, 8.3.1, 8.1.1)
  note :path=http://localhost?x=1/admin -> route=root path=/ x=1/admin
  FAIL absolute-form :path with a query is treated as malformed
  note HTTP/1 absolute form agreeing with Host -> 200
  note HTTP/1 absolute form disagreeing with Host -> 400
  ok   HTTP/1 absolute form with a matching Host is served
  ok   HTTP/1 rejects an absolute form whose authority conflicts with Host
checks: 5  failures: 2
BUG REPRODUCED
```

The absolute-form `:path` reaches `admin.users` with `X.Path = /admin/users`; the embedded authority is discarded without being compared with `:authority`. The query variant routes `root` with `X.Path = /` and `x = 1/admin`. HTTP/1 answers 400 when the embedded authority conflicts with `Host` and 200 when it agrees.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

An HTTP/2 request whose `:path` is neither `*` nor an `absolute-path` should be treated as malformed and answered with a stream error of type PROTOCOL_ERROR, as RFC 9113 sections 8.3.1, 8.3 and 8.1.1 require and as `src/flyology-http-http_3_header_policy.adb:299-304` already does for HTTP/3.

## Suggested treatment

Add the leading-slash requirement to the HTTP/2 admission check at `src/flyology-http-server-http_2.adb:2341-2349`, so a `:path` that is not `*` and does not begin with `/` raises `Request_Message_Error` like the other malformed targets there. That matches the HTTP/3 policy exactly and leaves `Raw_Path`'s absolute-form handling in place for HTTP/1, where RFC 9112 section 3.2.2 makes it legal. It needs no new value and no configuration.

The regression test belongs in `tests/http2_server_audit.adb`, which already encodes request header blocks by hand: one case with `:path` set to `http://localhost/admin/users` against a router that has `/admin/users`, asserting the stream error rather than a 200, and one with `http://localhost?x=1/admin` asserting the same. The spike is the test, and it also pins the HTTP/1 behaviour that must not change.

## Severity

A directly connected peer gains nothing from this: it can simply send `:path: /admin/users`. The input matters where an HTTP/2 intermediary applies a path policy to the raw `:path` and forwards the request unchanged, which would let a deny rule on the `/admin` prefix miss a request this server routes to `/admin/users`; whether any deployed intermediary forwards such a value is not verified against a peer here, and RFC 9113 section 8.1.1 tells conforming intermediaries not to forward a malformed request. Independently of that scenario, the three protocols answer one input three different ways, and the handler's path and query come from inconsistent parses of the same value. The input is malformed rather than valid, so no correct peer reaches it. Deterministic; not reproduced against a live peer.
