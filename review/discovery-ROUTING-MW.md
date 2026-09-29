# Discovery: ROUTING-MW

Scope (all under `src/` unless stated; line counts from `wc -l`):
`flyology-http-server-routing.adb` (3284), `flyology-http-server-routing.ads` (1471),
`flyology-http-route_parameter_policy.adb/.ads` (11/32),
`flyology-http-decoded_path_policy.adb/.ads` (21/26),
`flyology-http-server-native_routes.adb/.ads` (26/55),
`flyology-http-server-applications.adb/.ads` (1143/715),
`flyology-http-server-applications-internals.adb/.ads` (24/18),
`flyology-http-server-middleware.adb/.ads` (92/128),
`flyology-http-server-middleware_authentication` (64/39), `_bulkheads` (200/29),
`_cors` (105/26), `_deadlines` (18/27), `_errors` (70/43), `_logging` (41/28),
`_metrics` (84/25), `_rate_limits` (171/34), `_request_ids` (156/45),
`_security_headers` (28/36), `flyology-http-server-cors.adb/.ads` (170/91),
`flyology-http-server-compression.ads` (37), `flyology-rate_limit_policy.adb/.ads` (27/27),
`flyology-http-server-logging.ads` (35), `flyology-http-server-metrics.adb/.ads` (125/157).
Read for input-domain context only (not reviewed as such): `flyology-http-server.adb`
lines 770-851, 1158-1175, 2690-2796; `flyology-http-server-http_2.adb` lines 2100-2140,
2303-2380; `flyology-http-http_2_hpack.adb` lines 470-640;
`flyology-http-http_3_header_policy.adb` lines 180-330; `flyology-http-server-requests.adb`
lines 40-135, 215; `flyology-http.adb` lines 12-20.
Tests read: `tests/http_routing_audit.adb` (2717; outline plus lines 164-247, 992-1121),
`tests/http_smoke.adb` (lines 2800-2960, 3240-3330 and greps),
`tests/flyology-http-decoded_path_policy-smoke.adb`,
`tests/flyology-http-route_parameter_policy-smoke.adb`,
`tests/flyology-rate_limit_policy_smoke.adb`. Also `proof/proof-status.md`,
`review/prior-audit.md` (findings 2, 11, 17, 26-32 and all appendices),
`website/guide/server/index.html` (routing prose), `CHANGELOG.md` (Unreleased).
Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| ROUTING-MW-1 | A malformed-path 400 for more than 64 segments bypasses the global middleware chain and automatic admission | P1 | high |
| ROUTING-MW-2 | `Applications.Respond` marks the exchange `Failed` before any byte is written, so every Exchange-based 500 recovery path closes or resets instead of answering | P2 | high |
| ROUTING-MW-3 | HTTP/2 `:path` beginning with `http://` or `https://` is routed as an absolute-form target; HTTP/3 and HTTP/1 reject or validate it | P2 | medium |
| ROUTING-MW-4 | Metrics series are keyed by the client-controlled request method with no eviction, so distinct method tokens pin the bounded series table | P2 | high |
| ROUTING-MW-5 | CORS middleware omits `Vary: Origin` on responses whose CORS headers depend on `Origin` but where none were added | P2 | medium |

## Findings

### ROUTING-MW-1: A malformed-path 400 for more than 64 segments bypasses the global middleware chain and automatic admission

- **Location:** `src/flyology-http-server-routing.adb:1895` (`Split_Path` call), raise at
  `:399-401`, handler at `:2086-2090`; contrast with the handled decode failure at
  `:1828-1835` and `:1912-1915`
- **Severity:** P1 (documented contract violated; impact is modest: an unmetered,
  unlogged, header-less 400 on one narrow input class)
- **Confidence:** high
- **Evidence:**

```ada
   --  routing.adb:1828-1835
      function Decode_For_Dispatch return String is
      begin
         return (if Raw = "*" then "*" else Decode_Path (Raw));
      exception
         when Route_Error =>
            Invalid_Path := True;
            return "/";
      end Decode_For_Dispatch;
   ...
   --  routing.adb:1894-1895
   begin
      Split_Path (Path_Value, Path_Segments);
   ...
   --  routing.adb:399-401 (inside Split_Path)
         if Result.Count = Max_Segments then
            raise Route_Error with "too many HTTP path segments";
         end if;
   ...
   --  routing.adb:2086-2090
   exception
      when Route_Error =>
         if not X.Wire_Response_Started then
            X.Problem (400, "invalid-path", "Request path is malformed");
         end if;
```

  The spec promises for the automatic responses, explicitly including the
  malformed-path 400 (`routing.ads:806-811`): "404, 405, CORS preflight, OPTIONS, the
  trailing slash redirect, and the malformed-path 400. Those responses match no route
  ... yet they run the whole global middleware chain and write a response", and
  `Set_Automatic_Admission` is the per-client admission for that surface. Every
  `Decode_Path` failure honours this through `Invalid_Path` and
  `Run_Automatic ("flyology.bad_request")`. The one `Route_Error` that `Split_Path`
  raises on the already-decoded path (`Max_Segments = 64`, `routing.ads:1350`) is
  raised at `:1895`, outside `Decode_For_Dispatch`, and is caught by the outermost
  handler, which writes the 400 directly: no `Configure_Route`, no `Seal_Route`, no
  `Run_Automatic`, so no request-id, logging, metrics, security headers, or
  automatic-admission rate limit or bulkhead run for it. `X.Route_Name` is `""` when
  the response is written.

- **Failure scenario:**
  1. Application registers global middleware (request IDs, security headers, logging,
     metrics) and calls `Set_Automatic_Admission (Rate_Per_Second => 5)` to meter
     unmatched-path floods, as `routing.ads:806-818` describes.
  2. Peer sends `GET /a/a/a/.../a HTTP/1.1` with 65 single-character segments (130
     bytes); any protocol, since `Split_Path` runs on the decoded path after
     `Decode_Path` accepted it (no `//`, no dot segments, valid UTF-8).
  3. `Split_Path` raises at segment 65; the outer handler answers 400 problem+json.
  4. The response carries no `X-Request-ID`, no `X-Content-Type-Options`, is not
     logged or counted, and is not rate limited, however many are sent. A 400 for
     `GET /%2e%2e/` on the same server carries all of them and is metered.
- **Reproduction test sketch:** Same harness as `tests/http_routing_audit.adb:503`
  (`Check_Automatic_Response_Admission`): router with `Set_Automatic_Admission
  (Rate_Per_Second => 1)` and the security-headers middleware; send the 65-segment
  target twice on separate connections. Expected (per spec): first 400 carries
  `X-Content-Type-Options: nosniff`, second is 429. Actual: both are 400 with neither
  header nor `Retry-After`. Compare with `GET /%2e%2e/x` which yields 400 then 429.
- **Existing coverage:** none. `tests/http_routing_audit.adb:503-594` covers 404, 405,
  OPTIONS, redirect and the decode-failure 400 through `Run_Automatic`; no test sends
  more than 64 segments (`rg -n segments tests/` finds only a comment at `:2600`).
- **Standard:** n/a (internal contract in `routing.ads:806-818`, `:869-871`).

### ROUTING-MW-2: `Applications.Respond` marks the exchange `Failed` before any byte is written, so every Exchange-based 500 recovery path closes or resets instead of answering

- **Location:** `src/flyology-http-server-applications.adb:465-468` (consumed at
  `src/flyology-http-server-middleware_errors.adb:52-65` and
  `src/flyology-http-server-http_2.adb:2123-2135`)
- **Severity:** P2 (needs an application-side misuse to trigger; the documented
  recovery contract is then not delivered, and a completed response is relabelled)
- **Confidence:** high
- **Evidence:**

```ada
   --  applications.adb:436-446, 465-468
      Require_Owner (Item);
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP exchange response already started";
      elsif Item.Authentication_Value = Required_Authentication
        and then not Item.Principal_Present
        and then Status < 400
      then
         raise Program_Error with
           "required-authentication route cannot send an unauthenticated"
           & " response";
      end if;
      ...
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Respond;
```

```ada
   --  middleware_errors.adb:52-65
            if not Handled then
               if X.Response = App.Not_Started
                 and then not X.Wire_Response_Started
               then
                  X.Respond
                    (500, ...
               else
                  X.Mark_Failed;
               end if;
```

```ada
   --  http_2.adb:2123-2135 (per-stream handler task, no middleware involved)
               exception
                  when others =>
                     if not X.Wire_Response_Started then
                        begin
                           X.Problem
                             (500, "internal-server-error",
                              "Internal server error");
                        exception
                           when others => X.Mark_Failed;
                        end;
```

  `Respond` raises for its own pre-write validation (status outside 200..599 raised by
  `Flyology.HTTP.Server.Respond` at `server.adb:2733`, a payload with 204/205/304 at
  `:2737`, a control byte in `Content_Type`, a second call, or a sub-400 status on a
  `Required_Authentication` route with no principal). The `when others` at `:466`
  sets `Response_Value := Failed` for all of them, although `Wire_Response_Started`
  stays `False`. `middleware_errors.ads:8-9` promises "Unexpected exceptions become a
  generic closing 500 before response start"; its body tests `X.Response =
  Not_Started`, which is now false, and calls `Mark_Failed`. On HTTP/1 the connection
  is closed with no response at all (`Dispatch` returns normally, `Should_Close` is
  true). On HTTP/2 the same happens even without the errors middleware for the
  protocol-neutral raises at `applications.adb:437-446` (second call, or a sub-400
  status on a `Required_Authentication` route with no principal): the handler task's
  `X.Problem (500)` re-enters `Respond`, which raises "already started", and the
  stream is reset. (Whether the h2/h3 backends also reject an out-of-range status
  before writing was not checked; `rg '200 \.\. 599' src/` matches only the HTTP/1
  connection layer.) Only HTTP/1 without the errors middleware still answers 500,
  because `routing.adb:2264-2275` uses the connection-level `Respond`, which checks
  `Response_Begun` rather than the exchange state.

  The second call case additionally overwrites `Completed` with `Failed`
  (`:437-438` then `:467`), so `X.Response` reports `Failed` for a fully written
  response, `Dispatch_Configuration:2067-2073` and the errors middleware then call
  `Mark_Failed`, and a keep-alive connection is closed after a valid response.

- **Failure scenario:**
  1. Application installs `Middleware_Errors` (the documented way to get a safe 500).
  2. A handler calls `X.Respond (99, "text/plain", "x")` or, on a
     `Required_Authentication` route, `X.Text (200, ...)` without a principal.
  3. `Respond` raises before writing; `Response_Value := Failed`.
  4. Errors middleware logs, `Map` leaves `Handled` false, and because `X.Response /=
     Not_Started` it calls `Mark_Failed`.
  5. HTTP/1: the connection closes with zero response bytes (curl: "Empty reply from
     server"). HTTP/2: RST_STREAM. The promised 500 is never written.
- **Reproduction test sketch:** Extend `tests/http_smoke.adb:2738-2960`: add a route
  whose handler calls `X.Respond (99, "", "")`. Expected per `middleware_errors.ads`:
  output contains `500 Internal Server Error` and `Connection: close`. Actual: output
  is empty. Second case: a handler that calls `X.Text (200, "a")` twice; expected
  `X.Response = Completed` after the first call survives; actual `Failed` and the
  connection is marked close.
- **Existing coverage:** `tests/http_smoke.adb:2930-2942` (`/unexpected`) covers a
  handler that raises *before* calling `Respond`, which is the only shape that
  reaches the 500 branch; `:2944-2956` covers a failure after a stream started. No
  test makes `Respond` itself raise.
- **Standard:** n/a (internal contract in `middleware_errors.ads:5-9` and
  `applications.ads:48-57`, where `Failed` is "Response completion is unsafe or
  failed").

### ROUTING-MW-3: HTTP/2 `:path` beginning with `http://` or `https://` is routed as an absolute-form target; HTTP/3 and HTTP/1 reject or validate it

- **Location:** `src/flyology-http-server-routing.adb:283-314` (`Absolute_Form_Authority`,
  `Raw_Path`) reached from `src/flyology-http-server-http_2.adb:2341-2349`; contrast
  `src/flyology-http-http_3_header_policy.adb:299-304` and
  `src/flyology-http-server.adb:811-848`
- **Severity:** P2 (route confusion only through an intermediary that policies on the
  raw `:path` and forwards it unchanged; a directly connected peer gains nothing it
  could not request outright; the cross-protocol contract at `routing.ads:928-930` is
  not upheld for this input)
- **Confidence:** medium (mechanism traced; behaviour of stock h2 intermediaries on a
  non-`/` `:path` not verified here)
- **Evidence:**

```ada
   --  http_2.adb:2341-2349 -- the only :path checks on the h2 admission path
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

```ada
   --  http_3_header_policy.adb:299-304 -- HTTP/3 requires the leading slash
         elsif (Scheme = "http" or else Scheme = "https")
           and then Path /= "*"
           and then Path (Path'First) /= '/'
         then
            Result.Status := Invalid_Path;
            return Result;
```

```ada
   --  routing.adb:283-286, 295-309
   function Absolute_Form_Authority (Target : String) return Natural is
     (if Has_Scheme_Prefix (Target, "http://") then Target'First + 7
      elsif Has_Scheme_Prefix (Target, "https://") then Target'First + 8
      else 0);
   ...
      elsif Authority /= 0 then
         Start := 0;
         for Index in Authority .. Target'Last loop
            if Target (Index) = '/' then
               Start := Index;
               exit;
```

  `Raw_Path` cannot tell which protocol produced `Request_Target`. For HTTP/1 the
  absolute form is legitimate and `server.adb:827-848` validates the embedded
  authority and requires it to agree with `Host`. For HTTP/2 nothing requires
  `:path` to start with `/` (HPACK `Decode_Request` at `http_2_hpack.adb:564-572`
  and `:634-638` only require non-empty; `Valid_Pseudo_Value` rejects octets at or
  below SP and DEL), so `:path: http://anything/admin/users` reaches `Raw_Path`,
  which strips `http://anything` and routes `/admin/users`. The embedded authority is
  never compared with `:authority`; `Request_Authority` returns `:authority`
  (`applications.ads:108-110`). `Requests.Find_Query` (`requests.adb:62-63`) takes
  the first `?` of the whole target, so `:path: http://x?a=1/admin` yields query
  `a=1/admin` while routing `/`. HTTP/3 rejects the same value as `Invalid_Path`
  (tested at `tests/flyology-http-http_3_header_policy-smoke.adb:94`), so the three
  protocols disagree on this input although `routing.ads:928-930` states that
  "Route registration, middleware, body policy, and endpoint handlers are identical
  for both protocols".

- **Failure scenario:**
  1. An h2-speaking edge component applies a deny rule for `:path` prefix `/admin`
     and forwards unmatched requests to this server over h2 without normalising
     `:path`.
  2. Peer sends HEADERS with `:method: GET`, `:scheme: https`, `:authority: app`,
     `:path: https://app/admin/users`.
  3. The edge rule does not match (`:path` does not start with `/admin`); the request
     is forwarded.
  4. This server routes `/admin/users` and the handler runs; `X.Path` is
     `/admin/users` while the wire `:path` was `https://app/admin/users`.
  Whether a given intermediary forwards such a `:path` unchanged is not verified
  here; RFC 9113 requires clients not to generate it and intermediaries not to
  forward malformed requests, which is why this is P2 rather than P1.
- **Reproduction test sketch:** In `tests/http2_server_audit.adb`, encode a request
  header block with `:path` literal `http://localhost/admin/users` against a router
  with `GET /admin/users` and `GET /`. Expected (to match HTTP/3 and RFC 9113
  Section 8.3.1): stream error / 400. Actual: the `/admin/users` handler responds 200
  and `X.Path = "/admin/users"`. Also `:path: http://localhost?x=1/admin` routes `/`
  with `X.Query ("x") = "1/admin"`.
- **Existing coverage:** none for h2. `tests/http_routing_audit.adb:164-240`
  (`Check_Target_Form_Anchoring`) exercises absolute form over HTTP/1 only, where it
  is valid. `rg -n '":path", *"http' tests/` finds nothing.
- **Standard:** RFC 9113 Section 8.3.1 (`:path` "includes the path and query parts of
  the target URI (the "path-absolute" production ...)"); Section 8.1.1 (malformed
  requests are stream errors; intermediaries MUST NOT forward them). RFC 9112
  Section 3.2.2 is the HTTP/1 absolute-form rule that `Raw_Path` was written for.

### ROUTING-MW-4: Metrics series are keyed by the client-controlled request method with no eviction, so distinct method tokens pin the bounded series table

- **Location:** `src/flyology-http-server-metrics.adb:47-83` (consumed from
  `src/flyology-http-server-middleware_metrics.adb:23-30` with `X.Request_Method`)
- **Severity:** P2 (observability only; memory is bounded and the drop is counted, as
  documented; the defect is that a peer can choose which series are dropped, forever)
- **Confidence:** high
- **Evidence:**

```ada
   --  middleware_metrics.adb:23-30
            Metrics.End_Request
              (Output.all,
               X.Request_Method,
               X.Route_Name,
   ...
   --  metrics.adb:54-72
         for Index in 1 .. Value.Series loop
            if Values (Index).Route_Length = Route'Length
              and then Values (Index).Method_Length = Method'Length
              and then Values (Index).Status_Class = Class
              and then Values (Index).Route (1 .. Route'Length) = Route
              and then Values (Index).Method (1 .. Method'Length) = Method
            then
               Found := Index;
               exit;
            end if;
         end loop;
         if Found = 0 then
            if Value.Series = Capacity then
               Value.Dropped_Series :=
                 Saturating_Add (Value.Dropped_Series, 1);
               return;
            end if;
            Value.Series := Value.Series + 1;
```

  `Route` is bounded to the registered table plus the `flyology.*` literals (the
  prior audit's "Metrics cardinality" appendix rests on that), but `Method` is the
  request method as parsed: HTTP/1 accepts any token of any length
  (`server.adb:1164-1168`), HTTP/2 and HTTP/3 any token up to 64 bytes
  (`flyology-http.adb:14`). Methods up to `Max_Method_Length = 16` create a series
  each. Every unknown method to any existing path is answered 405 with
  `Route_Name = "flyology.method_not_allowed"` and reaches `End_Request`. There is no
  eviction (`metrics.adb` never clears a `Used` entry), so once `Capacity` (default
  256) series exist, every legitimate route/method/class combination first seen later
  is dropped for the life of the sink.

- **Failure scenario:**
  1. Server starts with the default `In_Memory (Capacity => 256)` sink and the
     metrics middleware; only a few routes have been hit so far.
  2. Peer sends 256 requests `M0000 /x`, `M0001 /x`, ... (distinct 5-byte tokens) to
     any existing path; each is a 405 and each creates a
     (`flyology.method_not_allowed`, `Mnnnn`, class 4) series.
  3. `Series = Capacity`. Every later first-seen legitimate series, for example
     `("orders.create", "POST", 2)`, increments `Dropped_Series` and is never
     counted; the aggregate counters keep working.
- **Reproduction test sketch:** In-memory sink with `Capacity => 4`, one `GET /x`
  route, metrics middleware. Send `AAAA /x`, `AAAB /x`, `AAAC /x`, `AAAD /x` (405
  each), then `GET /x` (200). Expected (documented intent): a `GET`/2xx series for
  `/x` exists. Actual: `Read.Series = 4`, `Dropped_Series = 1`, no 2xx series.
- **Existing coverage:** `tests/http_smoke.adb:3312-3323` asserts `Series = 1` and
  `Dropped_Series > 0` with a capacity-limited sink, which pins the bounded-drop
  behaviour but only with a fixed method; nothing varies the method.
- **Standard:** n/a. The guide (`website/guide/server/index.html:469`) documents the
  cap and the drop counter; the prior audit's "Metrics cardinality" appendix states
  "a client cannot inflate cardinality", which does not hold for the method key.

### ROUTING-MW-5: CORS middleware omits `Vary: Origin` on responses whose CORS headers depend on `Origin` but where none were added

- **Location:** `src/flyology-http-server-middleware_cors.adb:40-43`, `:53-61`, `:92-95`
  (the only `Vary: Origin` is inside `Add_Origin`, `:24-26`)
- **Severity:** P2 (cache-correctness edge case; a shared cache can serve a CORS-less
  cached copy to an allowed origin, or a reflected copy to another; no credential or
  origin bypass)
- **Confidence:** medium
- **Evidence:**

```ada
   --  middleware_cors.adb:40-43
      if Slot = 0 or else Origin = "" then
         Next.Call (Context, X);
         return;
      end if;
   ...
   --  :53-61
         if Policy = null or else not CORS.Origin_Allowed (Policy.all, Origin)
         then
            if Preflight then
               X.Problem (403, "cors-origin-denied", "CORS origin denied");
            else
               Next.Call (Context, X);
            end if;
            return;
         end if;
   ...
   --  :92-95
         if not CORS.Method_Allowed (Policy.all, X.Request_Method) then
            Next.Call (Context, X);
            return;
         end if;
```

  For a route with a non-wildcard policy, the representation's header set depends on
  `Origin`: present-and-allowed adds `Access-Control-Allow-Origin: <origin>` plus
  `Vary: Origin`; absent or not allowed adds nothing, including no `Vary`. A shared
  cache that stores the no-`Origin` (or denied-origin) response has no `Vary` key and
  will serve it to a later request from an allowed origin, whose browser then fails
  the CORS check. The guide (`website/guide/server/index.html:438`) states preflights
  "emit the required Vary fields", which they do; this is the non-preflight path.

- **Failure scenario:**
  1. `GET /data` (policy origins `https://app.example`, `Allowed_Methods => "GET"`)
     is fetched once by direct navigation (no `Origin`) through a shared cache; the
     200 has no `Vary`.
  2. A page on `https://app.example` calls `fetch("/data")`; the cache matches on
     method and URI, returns the stored copy with no
     `Access-Control-Allow-Origin`; the browser blocks it.
- **Reproduction test sketch:** Same harness as
  `tests/http_routing_audit.adb:1044-1058` (`Answer`): request `/data` with no
  `Origin` header and with `Origin: https://evil.example`. Expected (RFC 9110
  Section 12.5.5): both carry `Vary: Origin`. Actual: `Field_Value (Denied, "Vary")`
  is `""` (the existing test at `:1112-1114` asserts only that `ACAO` is absent).
- **Existing coverage:** `tests/http_routing_audit.adb:1109-1111` and
  `tests/http_smoke.adb:3256-3257` assert `Vary: Origin` on the allowed path only.
- **Standard:** RFC 9110 Section 12.5.5 ("An origin server SHOULD send a Vary header
  field when its algorithm for selecting a representation varies based on aspects of
  the request message other than the method and target URI"); RFC 9111 Section 4.1.

## Areas reviewed with no findings

- **Percent decoding, dot segments, and route matching order** (`routing.adb:288-409`,
  `1824-1895`). Order is: anchored form classification (`Raw_Path`), query strip,
  single-pass percent decode with per-byte rejection of NUL, C0, DEL, and backslash
  (raw or encoded), rejection of an *encoded* `/` (`%2F`, `%2f`), then on the decoded
  string: `//`, the proved `Decoded_Path_Policy.Classify`, and `Valid_UTF8`; then
  `Split_Path`; then matching. The router matches and `X.Path` returns the same
  decoded string (`Configure_Route`), so middleware and handler see what was matched.
  Checked against the proof scope in `proof/proof-status.md:35-39`: the classifier
  proves only slash-delimited `.`/`..` rejection on its input; the unproved
  surrounding code delivers that input after a *single* decode and before any
  further transformation, so `%2e%2e%2f` becomes `../` (rejected), `..%2f` is
  rejected at the encoded slash, `%252e` stays `%2e` literally (no second decode),
  and a raw `..` is rejected. Overlong (`%C0%AF`, `%E0%80%AF`, `%F0%80%80%AF`),
  surrogate (`%ED%A0%80`), and above-U+10FFFF (`%F4%90..`) sequences all fail
  `Valid_UTF8` (`:208-261`). `%00`, `%0D`, `%0A`, `%5C`, `%7F` are rejected before
  the string is assembled. `#` cannot reach routing on any protocol. A raw byte over
  127 is rejected by HTTP/1 (`server.adb:781`) and accepted by h2/h3 only as part of
  a valid UTF-8 sequence, which decodes to the same segments a percent-encoded HTTP/1
  request would, so the two cannot be made to disagree.
- **Parameter capture** (`Match_Path`, `:1688-1748`; `Add_Parameter`,
  `applications.adb:1118-1135`). A parameter cannot span `/` (no `/` survives
  decoding), cannot be empty (`//` rejected), has no length bound to exceed
  (`Unbounded_String`), and the count is bounded at registration by the proved
  `Route_Parameter_Policy.Advance` and again at capture by `Max_Path_Parameters`
  (`Program_Error`, unreachable because registration already bounded it). The
  remainder preserves the trailing slash except when it captures zero segments (see
  observations). `Has_Parameter` distinguishes absent from empty as documented.
- **Method dispatch** (`:1916-1990`). Case-sensitive method match (RFC 9110
  Section 9.1). 405 always carries `Allow` built from the routes matching the path,
  with `HEAD` added for `No_Upgrade` GET routes, de-duplicated by `Add_Allowed`;
  explicit HEAD beats the GET fallback; the GET fallback is never used for SSE or
  WebSocket routes. `OPTIONS *` is answered 204 with a complete `Allow`
  (`:1896-1911`). HEAD body suppression and the GET-sized `Content-Length` are
  applied in the connection layer from the request method (`server.adb:2748-2779`,
  `Current_Is_Head` set per request at `:1169`), so a HEAD served by a GET handler
  cannot emit a body or a wrong length through `Respond`.
- **Registration-time ambiguity** (`Check_Unambiguous`, `Patterns_Overlap`,
  `Validate_Configuration`). I looked for a same-method pair with equal specificity
  that both match one path yet pass `Patterns_Overlap`; the score-collision case
  `/{a}/…/{j}/{*r}` (10 parameters + remainder = 101) versus `/x/{*r}` (101) is
  caught by the remainder rule at `:546-552`, and equal-count pairs are caught by
  `Compatible`. The runtime `Route_Error` at `:1866` is therefore unreachable, as the
  prior audit also concluded; `Mount` and `Commit` both go through the same checks.
- **Mount composition** (`:1602-1686`). Prefix is validated static; `/api/` and
  `/api` join identically except for a `/` source route (documented shape); mounting
  at `/` is a plain copy; the source is sealed (finding 30 fix intact); global
  middleware of the source is copied before its route-local middleware, and the
  destination's own globals still wrap everything, so the effective order across the
  boundary is destination-global, source-global, source-route, backstop, body
  admission, then the `Application`-stage equivalents. Route names keep the
  source-derived name, which is what finding 17's fix accounts for.
- **Automatic responses** (`Run_Automatic`, `:1870-1893`). 404, 405, preflight,
  OPTIONS, redirect, and the `Decode_Path` 400 all run the global chain at both
  stages and are metered by `Automatic_Concurrency`/`Automatic_Rate` (finding 27 fix
  intact). An unread request body on any of them forces `Connection: close` through
  `Must_Close` (`server.adb:2725-2726`), so a POST to a 404 cannot desynchronise the
  next request. Only the `Split_Path` 400 escapes this (ROUTING-MW-1).
- **Fail-closed authentication** (`Require_Authentication`, `:1776-1795`;
  `Respond`, `applications.adb:439-446`; `middleware_authentication.adb`). The
  backstop sits between the two stages; the configured challenge reaches both the
  backstop and the middleware (finding 32 fix intact); `Authenticate` uses
  `in out Boolean` pre-set to `False` (finding 11 fix intact); repeated
  `Authorization` fields are rejected; an empty principal is rejected; a sub-400
  response without a principal on a required route is refused at `Respond`.
- **CORS core** (`cors.adb`). Origin comparison is exact-token, so no suffix or
  case tricks; `*` beside other origins, `*` or `null` with credentials are rejected
  at `Create` (finding 26 fix intact); wildcard responses omit `Vary` correctly;
  preflight emits `Vary` for method and headers; requested headers are compared
  case-insensitively; a comma-joined duplicate `Access-Control-Request-Method` fails
  `Method_Allowed` closed. See ROUTING-MW-5 for the one gap.
- **Rate limiting** (`middleware_rate_limits.adb`, `rate_limit_policy.adb`). The
  proved `Refilled_Tokens` saturates at one second of capacity and treats
  non-positive elapsed time as zero refill, so a backwards test clock or a large
  idle interval cannot mint tokens; `Tokens` is bounded by `Rate`; the monotonic
  clock cannot jump; oversized route or key names are digested rather than denied
  (finding 17 fix intact); `Allowed` is initialised `False` and set only after a
  successful deduction; shard selection and bucket identity use separate lengths so
  `("ab","c")` and `("a","bc")` do not collide.
- **Bulkheads** (`middleware_bulkheads.adb`). The permit is a `Limited_Controlled`
  guard activated only on `Admitted`; `At_Capacity` returns with a non-zero `Slot`
  but `Held = False`, so nothing is released that was not acquired; a handler
  exception, `Operation_Cancelled`, or a middleware short-circuit all unwind through
  `Finalize`; a full counter table takes over an idle counter instead of denying
  (finding 17 fix intact); the global counter is decremented on every held release.
- **Request IDs and security headers**. Inbound IDs are only echoed when
  `Trust_Inbound` and they pass `[A-Za-z0-9._-]{1,128}`; a comma-joined duplicate
  fails validation and a fresh ID is generated; the default ID is a keyed bijection
  of the counter (finding 29 fix intact); `Set_Header`/`Remove_Header` exist and are
  case-insensitive (finding 28 fix intact). No inbound header influences the
  security-header values.
- **Runtime reconfiguration** (`Begin_Update`, `Commit`, `Reclaim`, `Finalize`,
  new since the audit). `Try_Publish` is a protected compare-and-set on the base
  generation; `Begin_Update` reads the published word with acquire semantics, so a
  candidate built between a winner's CAS and its release store is correctly rejected
  as stale; `First_Configuration` always points at the newest generation and
  `Previous` chains older ones, so `Finalize` frees every generation and `Reclaim`
  frees exactly the superseded ones; `Set_Match` recompiles segments and score;
  `Commit` re-validates ambiguity, names, identities, and body limits on the whole
  candidate; `Reclaim`'s unchecked precondition is documented.
- **Middleware pipeline** (`middleware.adb`). Single-use continuation guarded by
  owner task and `Was_Called`; capacity is checked on `Add`; the router sizes the
  route pipeline at `Max_Global + Max_Route + 2`, which cannot overflow.
- **Compression** (`compression.ads`). Interface only; no encoder, no
  `Accept-Encoding` parsing, no framing exists in this crate, so there is nothing to
  double-encode. The spec says so.
- **Regression check on prior findings 2, 11, 17, 26-32.** All fixes are present at
  f078732 as cited above; `git log --since=2026-08-07` on the area files shows only
  the reconfiguration, cacheline, generation-retention, and streaming-length commits,
  none of which touched the fixed code paths.

## Observations not counted

- **Partial mount on a mid-loop failure** (`routing.adb:1635-1685`). Only route
  capacity is checked before copying (as `routing.ads:853-854` states); the per-route
  middleware-capacity check at `:1641-1647` and the ambiguity / duplicate-name checks
  inside `Add` run per route, so a failure part-way leaves the destination holding
  the routes copied so far and the source unsealed. Setup-time only and the caller
  sees `Route_Error`; the spec does not promise atomicity beyond route capacity.
- **`Strict_Slashes` cannot register both `/a` and `/a/`.** `Patterns_Overlap`
  ignores `Trailing`, so the pair is rejected as ambiguous under every slash policy,
  although under `Strict_Slashes` they would never match the same request. A
  limitation, not a contract violation (`routing.ads:109-114` describes matching,
  not registration).
- **Empty remainder loses the trailing slash.** `/files/{*p}` yields `p = ""` for
  both `/files` and `/files/` (`:1731-1739`), while `/files/a/` yields `a/`. The
  handler can still consult `X.Path`.
- **Duplicate `Origin` request fields** are comma-joined by `Request_Header`, and
  `Exact_Word` splits on spaces, so `Origin: https://evil.example` followed by
  `Origin: https://app.example` passes `Origin_Allowed` and the *joined* value is
  reflected as `Access-Control-Allow-Origin`. Browsers never send two `Origin` fields
  and reject a non-origin `ACAO` value, and a non-browser client is not subject to
  CORS, so there is no exploit; a `Request_Header_Count ("Origin") > 1` guard would
  remove the oddity.
- **`*` is not a wildcard in `Allowed_Methods`/`Allowed_Headers`.** A policy created
  with `Allowed_Methods => "*"` denies every preflight because `List_Has` compares
  tokens literally. Documented as "comma-separated token lists", so a policy choice,
  but worth a sentence in `cors.ads`.
- **OPTIONS on a resource with no explicit OPTIONS route is 405**, not an automatic
  204 with `Allow`; only `OPTIONS *` is automatic. RFC 9110 Section 9.3.7 does not
  require the former. A 308 slash redirect is also issued for a preflight whose
  trailing slash mismatches under `Redirect_Slashes`; browsers do not follow
  preflight redirects, so such a route needs the exact form. Both are policy.
- **Headers staged before `Run_Automatic`** (`Allow` at `:1974`, `Location` at
  `:1968`) are inherited by any middleware short-circuit response (for example a 429
  from the automatic rate limit carries `Allow` or `Location`). Harmless.
- **Rate-limiter eviction with spoofable keys.** With an application `Client_Key`
  that trusts a proxy header, a peer controlling more than `Capacity / 16` distinct
  keys can evict its own exhausted bucket and start it full again; the generic
  formal's comment ("Maximum retained attacker-controlled keys") acknowledges the
  bounded-LRU trade-off. Policy value, not a defect.
- **Absurd policy durations overflow the clock addition.** `Route_Policy.Timeout`
  near `Duration'Last` (`:2020-2022`) or `Middleware_Deadlines.Maximum` near
  `Duration'Last` raise `Constraint_Error` in `Clock + To_Time_Span`, surfacing as a
  500. Configuration error; not reachable from a peer.
- **Parser-level error responses carry no middleware headers.** The 400/413/417/500
  written by `Serve` (`routing.adb:2211-2276`) use the connection-level `Respond` and
  never construct an exchange, so security headers and request IDs are absent on
  them by design. Distinct from ROUTING-MW-1, which concerns a response the spec
  places inside the middleware chain.
- **Metrics `Method` truncation.** Methods longer than `Max_Method_Length = 16` are
  counted in `Dropped_Series` rather than stored; HTTP/1 accepts a method token of
  any length. Bounded and counted; noted only because it interacts with
  ROUTING-MW-4.
- **Compression side channel caveat and HEAD/no-body rules** are documented in
  `compression.ads:5-11` for a future encoder; nothing to review now.
