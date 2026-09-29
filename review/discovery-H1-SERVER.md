# Discovery: H1-SERVER

Scope (all read in full unless noted):
`src/flyology-http-server.adb` (4838; HTTP/1.x request, body, response, SSE and
upgrade paths read in full, WebSocket framing 4028-4838 skimmed only for the
upgrade handshake), `src/flyology-http-server.ads` (1133),
`src/flyology-http-server-requests.adb/.ads` (218/58),
`src/flyology-http-server-responses.adb/.ads` (172/91),
`src/flyology-http-server-connections.adb/.ads` (83/111),
`src/flyology-http-server-connection_handlers.adb/.ads` (160/38),
`src/flyology-http-expect_policy.adb/.ads` (13/27),
`src/flyology-http-fixed_response_policy.adb/.ads` (63/94),
`src/flyology-http-headers.adb/.ads` (105/89), `src/flyology-http-methods.ads` (27),
`src/flyology-http-server-exchange_backends.ads` (255),
`src/flyology-http_chunk_encoding.adb/.ads` (47/18).
Cross-checked for exception-to-status mapping: `src/flyology-http-server-routing.adb`
(2020-2280, 2700-2730) and `src/flyology-http-server-applications.adb` (314-342,
715-745, 830-865).
Tests read: `tests/http_server_audit.adb` (877), `tests/http_smoke.adb` (40-140,
140-640, 2030-2180, 3725-3775 plus targeted greps), `tests/http_operations_smoke.adb`
(outline), the three policy smoke tests (28/64/17), `tests/repros/README.md`.
Prior audit: findings 2, 4, 12, 19, 23, 24, 25, 34, 35 and all three appendices.
Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| H1-SERVER-1 | A stray CRLF before a request-line is rejected as malformed, and at EOF becomes a spurious 400 (RFC 9112 §2.2 SHOULD) | P2 | high on behaviour; medium on real-peer impact |
| H1-SERVER-2 | Chunk-extension BWS is rejected although the chunk-ext grammar admits it (RFC 9112 §7.1.1, RFC 9110 §5.6.3) | P2 | high on behaviour; low impact |
| H1-SERVER-3 | Oversized head, unknown transfer coding, CONNECT, and unsupported versions all collapse to 400 instead of 431/501/405/505 | P2 | high |
| H1-SERVER-4 | Absolute-form target with a differing Host is refused instead of Host being ignored (RFC 9112 §3.2.2 MUST); pinned as intended by a test | P2 | high |
| H1-SERVER-5 | Peer-chosen request shapes (body on a WebSocket upgrade; HEAD or HTTP/1.0 on SSE) surface as `Program_Error`, escaping the documented `Protocol_Error` rejection channel | P2 | high |

No P0 or P1 findings. The request-smuggling, header-injection, chunk-framing,
body-limit and response-length surfaces in this area were traced end to end and are
sound; the entries below are diagnostics and grammar-strictness deviations that need
unusual input. None of the prior findings assigned to this area (12, 23, 24, 25, 34, 35)
has regressed; 2, 4 and 19 live in files outside this area and were read for context only.

## Findings

### H1-SERVER-1: A stray CRLF before a request-line is rejected as malformed, and at EOF becomes a spurious 400

- **Location:** `src/flyology-http-server.adb:1141-1162` (request-line split), consumed
  by `:1055-1068` (`Inspect_Request_Head_Input`) for the EOF variant
- **Severity:** P2
- **Confidence:** high that the code behaves as described; medium that a current stock
  client produces the input (RFC 9112 §2.2 names "certain user agents" that send an
  extra CRLF after a POST body; I could not verify which, if any, still do)
- **Evidence:**

```ada
         Head      : constant String := Available (1 .. Header_End - 1);
         Line_End  : constant Natural := Ada.Strings.Fixed.Index (Head, CRLF);
         Request_Line : constant String :=
           (if Line_End = 0 then Head else Head (Head'First .. Line_End - 1));
         ...
         First_Space : constant Natural :=
           Ada.Strings.Fixed.Index (Request_Line, " ");
         ...
      begin
         if First_Space <= Request_Line'First
           or else Second_Space = 0
           ...
         then
            raise Protocol_Error with "malformed HTTP request line";
```

```ada
      elsif not Input_Closed then
         return Request_Input_Needed;
      elsif Available'Length = 0 then
         Item.State := Terminal;
         return Request_Peer_Closed;
      else
         raise Protocol_Error with "peer closed inside HTTP headers";
```

  When `Pending` begins with `CRLF`, `Line_End = 1`, `Request_Line` is the empty
  string, `First_Space = 0`, and the request is rejected. Nothing skips empty lines
  before the request-line. When the stray `CRLF` is the last thing the peer sends
  before FIN, `Available'Length = 2`, so instead of `Peer_Closed = True` the parser
  raises "peer closed inside HTTP headers".

- **Failure scenario:**
  1. A keep-alive client sends `POST /a HTTP/1.1`, `Content-Length: 1`, body `x`, and
     then the legacy extra `CRLF` after the body, followed by a pipelined
     `GET /b HTTP/1.1`.
  2. `Read_Request` serves `/a`; `Pending` is left as `CRLF GET /b ...`.
  3. The next `Read_Request` raises `Protocol_Error`; `Connection_Handlers.Serve`
     (`src/flyology-http-server-connection_handlers.adb:109-111`) writes a best-effort
     400 with `Connection: close` and closes. `/b` is never served and must be retried.
  4. Variant: if the client instead half-closes after the stray `CRLF`, the server
     writes a 400 after an already-completed response rather than treating it as a
     clean close between requests.
- **Reproduction test sketch:** with the `Memory_Transport` from `tests/http_smoke.adb`:
  `Wire.Input := "POST /a HTTP/1.1" & CRLF & "Host: h" & CRLF & "Content-Length: 1" & CRLF
  & CRLF & "x" & CRLF & "GET /b HTTP/1.1" & CRLF & "Host: h" & CRLF & "Connection: close"
  & CRLF & CRLF;` — first `Read_Request` gives `/a` with `Content = "x"`; expected
  second `Read_Request` gives `Target = "/b"`; actual: `Protocol_Error` "malformed HTTP
  request line". EOF variant: `Wire.Input := "... x" & CRLF;` expected second
  `Read_Request` sets `Peer_Closed`; actual: `Protocol_Error` "peer closed inside HTTP
  headers".
- **Existing coverage:** none. No test in `tests/http_smoke.adb` or
  `tests/http_server_audit.adb` places a `CRLF` before a request-line (grep for
  `CRLF & CRLF & CRLF` and `(CRLF & "GET` found nothing).
- **Standard:** RFC 9112 §2.2: "a server that is expecting to receive and parse a
  request-line SHOULD ignore at least one empty line (CRLF) received prior to the
  request-line." SHOULD-level, hence P2.

### H1-SERVER-2: Chunk-extension BWS is rejected although the chunk-ext grammar admits it

- **Location:** `src/flyology-http-server.adb:874-895` (size slice ends at the first
  `;`) and `:909-923` (extension name must be a token), consumed at `:2015`
- **Severity:** P2
- **Confidence:** high that the code rejects it; low practical impact — I know of no
  stock client that emits chunk extensions at all, let alone with bad whitespace
- **Evidence:**

```ada
      Semicolon : constant Natural := Ada.Strings.Fixed.Index (Line, ";");
      Last      : constant Natural :=
        (if Semicolon = 0 then Line'Last else Semicolon - 1);
      ...
         else
            raise Protocol_Error with "invalid HTTP chunk size";
```

```ada
                  while Position <= Line'Last
                    and then Line (Position) not in '=' | ';'
                  loop
                     Position := Position + 1;
                  end loop;
                  ...
                  Validate_Token
                    (Line (Name_First .. Position - 1),
                     "chunk extension name");
```

  `1 ;a=b` puts a space inside the hex slice; `1; a=b` puts a space inside the
  extension name. Both are grammatical under the chunk-ext ABNF.

- **Failure scenario:**
  1. A peer sends a chunked body whose size line is `1 ;a=b` or `1; a=b`.
  2. `Read_Body` raises `Protocol_Error`; the request is answered 400 and the
     connection closes, although the body was well-formed.
- **Reproduction test sketch:** `"POST / HTTP/1.1" & CRLF & "Host: h" & CRLF &
  "Transfer-Encoding: chunked" & CRLF & CRLF & "1 ;a=b" & CRLF & "x" & CRLF & "0" & CRLF
  & CRLF` — expected `Content = "x"`; actual `Protocol_Error` "invalid HTTP chunk size".
  With `"1; a=b"` — actual `Protocol_Error` "invalid chunk extension name".
- **Existing coverage:** `tests/http_smoke.adb:480-495` (quoted extension with
  quoted-pair, no BWS) and `:2174-2179` (`1;=x` rejected). Neither exercises BWS.
- **Standard:** RFC 9112 §7.1.1: `chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "="
  BWS chunk-ext-val ] )` and "A recipient MUST ignore unrecognized chunk extensions";
  RFC 9110 §5.6.3: "A recipient MUST parse for such bad whitespace and remove it
  before interpreting the protocol element." The prior audit's "chunk parsing —
  hardened" entry covers the token/quoted-string handling but not BWS.

### H1-SERVER-3: Oversized head, unknown transfer coding, CONNECT, and unsupported versions all collapse to 400

- **Location:** `src/flyology-http-server.adb:1060`, `:1136`, `:1390` (head too
  large); `:1286-1292` (transfer coding); `:805-806` (CONNECT); `:1182-1187`
  (version). All raise the single `Protocol_Error`, which
  `src/flyology-http-server-connection_handlers.adb:109-111` and
  `src/flyology-http-server-routing.adb:2231-2240` can only map to 400.
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
      elsif Available'Length > Max_Header_Bytes then
         raise Protocol_Error with "HTTP request headers are too large";
```

```ada
            if Value.Version_Value /= HTTP_1_1
              or else Transfer_Count > 1
              or else Lower (Trim (Transfer_Value)) /= "chunked"
            then
               raise Protocol_Error with
                 "unsupported request Transfer-Encoding";
```

```ada
      elsif Request_Method = "CONNECT" then
         raise Protocol_Error with "CONNECT is not supported";
```

```ada
            if Wire_Version = "HTTP/1.1" then
               Value.Version_Value := HTTP_1_1;
            elsif Wire_Version = "HTTP/1.0" then
               Value.Version_Value := HTTP_1_0;
            else
               raise Protocol_Error with "unsupported HTTP version";
```

- **Failure scenario (each is a complete request from a peer; all yield 400 + close):**

  | Wire input | Actual | Expected |
  |---|---|---|
  | a head whose fields exceed 32 KiB | 400 | 431 Request Header Fields Too Large (RFC 9110 §15.5.15 / RFC 6585 §5) |
  | `Transfer-Encoding: gzip, chunked` (or `chunked` on HTTP/1.0) | 400 | 501 Not Implemented ("SHOULD respond with 501", RFC 9112 §6.1) |
  | `CONNECT example.test:443 HTTP/1.1` with matching Host | 400 | 405 with `Allow` (method known, not supported for any target, RFC 9110 §15.5.6) or 501 (§15.6.2); the request is well-formed, so 400 (§15.5.1 "malformed request syntax") is wrong |
  | `GET / HTTP/1.2` | 400 | processed as HTTP/1.1 ("SHOULD process the message as if it were in the highest minor version ... to which the recipient is conformant", RFC 9112 §2.3) |
  | `GET / HTTP/2.0` on a cleartext HTTP/1 listener | 400 | 505 HTTP Version Not Supported (RFC 9112 §2.3) |

  Impact is diagnostic only: every case closes the connection either way, and no
  ambiguity about message boundaries results. A client or proxy that keys retry or
  fallback behaviour on 431/501/505 cannot distinguish these from a malformed request.
- **Reproduction test sketch:** each row above through `Connection_Handlers.Serve` on a
  `Memory_Transport`; assert the status line in `Wire.Output`.
- **Existing coverage:** `tests/http_smoke.adb:2156-2159` pins that CONNECT is
  rejected via `Is_Rejected` (`:2098-2110`, which only checks that `Protocol_Error` is
  raised, not the status). No test asserts a status for the other rows; the 32 KiB bound
  is asserted only as a rejection. `Flyology.HTTP.Headers.Headers_Too_Large` exists
  (`src/flyology-http-headers.ads:19`) but the server parser never raises it, so
  handlers cannot tell the cases apart even if they wanted to.
- **Standard:** cited per row above.

### H1-SERVER-4: Absolute-form target with a differing Host is refused instead of Host being ignored

- **Location:** `src/flyology-http-server.adb:843-848` in `Validate_Target_And_Authority`
- **Severity:** P2
- **Confidence:** high on behaviour. This is deliberately pinned by
  `tests/http_smoke.adb:2152-2155`, so it is a chosen hardening rather than an
  oversight; I record it because it is a MUST-level deviation the brief asked about, and
  the owner can downgrade it to policy.
- **Evidence:**

```ada
            elsif Host'Length > 0
              and then Lower (Host) /= Lower
                (Request_Target (Authority_First .. Authority_Last))
            then
               raise Protocol_Error with "Host conflicts with request target";
```

  The parser already selects the target's authority as `Authority_Value`
  (`:1211-1247`), so the RFC's "use the host information of the request-target" is
  honoured; what deviates is the additional refusal.

- **Failure scenario:**
  1. A client sends `GET http://example.test/ HTTP/1.1` with `Host: other.test` (for
     example `curl --proxy <this-server> -H 'Host: other.test' http://example.test/`).
  2. The server answers 400 and closes instead of serving the request against
     `example.test` and ignoring the Host field.
  No stock client is known to produce this without operator intervention, and the
  refusal is the safer posture against Host-based confusion at an intermediary, which
  is presumably why it was chosen.
- **Reproduction test sketch:** exactly `tests/http_smoke.adb:2152-2155`, with the
  assertion inverted to expect `Target = "http://example.test/"` and
  `Authority = "example.test"`.
- **Existing coverage:** `tests/http_smoke.adb:2152-2155` asserts the current behaviour
  (rejection).
- **Standard:** RFC 9112 §3.2.2: "When an origin server receives a request with an
  absolute-form of request-target, the origin server MUST ignore the received Host
  header field (if any) and instead use the host information of the request-target."
  RFC 9112 §3.2 lists the 400 cases (missing Host, repeated Host, invalid Host value);
  a mismatching-but-valid Host is not among them.

### H1-SERVER-5: Peer-chosen request shapes surface as `Program_Error`, escaping the documented `Protocol_Error` rejection channel

- **Location:** `src/flyology-http-server.adb:3933-3937` (`Accept_WebSocket`),
  `:3059-3062` (`Begin_SSE`); contract at `src/flyology-http-server.ads:857`; exception
  mapping at `src/flyology-http-server-connection_handlers.adb:99-117` and `:125-142`;
  router handlers at `src/flyology-http-server-routing.adb:2086-2108`, fallback at
  `:2264-2275`
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
      elsif not Item.Body_Done or else Item.Body_Total > 0
        or else Content (Value)'Length > 0
      then
         raise Program_Error with
           "WebSocket upgrade requests must not carry a body";
      end if;
```

```ada
      if Item.Current_Is_Head then
         raise Program_Error with "SSE is not available for HEAD";
      elsif Item.Current_Version /= HTTP_1_1 then
         raise Program_Error with "SSE requires HTTP/1.1";
      end if;
```

  `src/flyology-http-server.ads:857` documents `@exception Protocol_Error Request is
  not a valid version 13 upgrade`. `Connection_Handlers.Serve` maps `Protocol_Error`
  to a best-effort 400 and lets everything else propagate, and
  `tests/http_smoke.adb:2034-2063` (`Check_Application_Failure_Propagates`) pins that
  propagation as the contract for application faults. Whether a GET carries a body, or
  whether the method is HEAD, is chosen by the peer, not the application.

- **Failure scenario:**
  1. Raw engine (`Connection_Handlers.Serve`, e.g. `showcases/http_server.adb:129-131`
     and `tests/websocket_conformance_server.adb:85-90`): a peer sends the `/websocket`
     handshake with `Content-Length: 1` and one body byte. With `Buffer_Body => True`
     (the default) the body is already buffered before `Handle` runs, so
     `Content (Value)'Length > 0`; with `Buffer_Body => False` (what the showcase uses)
     `Body_Done` is false. Either way `Accept_WebSocket` raises `Program_Error`, which
     escapes `Serve` and the handler. The connection is dropped with no response. In the
     `Flyology.IO.Structured_Servers` worker the fault is caught by a `when others`
     around `Handle` (verified only in the sibling checkout
     `flyology-pr261-review-4aadf93/src/flyology-io-structured_servers.adb:451-460`,
     flyology 0.2.0, not the pinned 0.1.1-dev), so no worker capacity is lost; I could
     not verify the pinned revision.
  2. Router (`Routing.Serve`): the same request reaches `X.Accept_WebSocket`
     (`src/flyology-http-server-applications.adb:847`) through a route with
     `Allow_WebSocket`; `Dispatch_Configuration` catches only `Route_Error`,
     `Payload_Too_Large`, `Expectation_Failed` and `Protocol_Error`
     (`routing.adb:2086-2108`), so the `Program_Error` falls to the outer
     `when others` and is answered `500 internal server error` with close
     (`routing.adb:2264-2275`). The peer chose the input, so 400 is the right answer.
  3. `Begin_SSE` on HEAD / HTTP/1.0: through the router the route's method gate answers
     405 first (`tests/http_smoke.adb:3731-3749` pins `HEAD /events` → 405), so only raw
     `Connection_Handlers` users are exposed, and there the same silent drop applies.
- **Reproduction test sketch:** `Wire.Input := "GET /websocket HTTP/1.1" & CRLF & "Host:
  h" & CRLF & "Upgrade: websocket" & CRLF & "Connection: Upgrade" & CRLF &
  "Sec-WebSocket-Version: 13" & CRLF & "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" &
  CRLF & "Content-Length: 1" & CRLF & CRLF & "x";` with a `Connection_Handlers` route
  that calls `Accept_WebSocket`. Expected: `Serve` returns and `Wire.Output` starts with
  `HTTP/1.1 400`; actual: `Program_Error` propagates out of `Serve` and `Wire.Output`
  is empty.
- **Existing coverage:** none for an upgrade carrying a body (grep of the twelve
  `Upgrade: websocket` fixtures in `tests/http_smoke.adb` finds no `Content-Length` or
  `Transfer-Encoding` among them). `tests/http_smoke.adb:3731-3749` covers HEAD on an
  SSE route only through the router.
- **Standard:** RFC 6455 §4.2.1 lists the required handshake parts and does not forbid
  a body; RFC 9110 §9.3.1 says a client SHOULD NOT generate content in a GET, so
  refusing is fine, but the refusal is the peer's fault and belongs on the 400 channel
  the `.ads` documents.

## Areas reviewed with no findings

- **Request-line.** Exactly two SP are required (`:1155-1162`); the method is
  token-checked (`:1164-1166`); the target rejects every byte ≤ 32 and 127
  (`:1172-1176`); the version must be exactly `HTTP/1.1` or `HTTP/1.0`. Tab in the
  request-line, trailing SP, and double SP are all rejected as RFC 9112 §3 requires.
- **Header block splitting and smuggling primitives.** `Validate_Header_Block`
  (`:610-643`) splits strictly on CRLF, rejects a line starting with SP/HTAB (obs-fold,
  RFC 9112 §5.2), requires a colon after a non-empty token name (so whitespace before the
  colon is a token failure, RFC 9112 §5.1), and rejects every byte < 32 except HTAB and
  byte 127 in values, which catches bare CR, bare LF and NUL as control bytes. The same
  colon rule is used by `Field_Count`/`Field_Value`/`Header` (`:344-525`), so
  validation and lookup cannot disagree. `Field_Count (Block)` counts lines correctly
  because `Header_Block` never carries a trailing CRLF (`:1189-1193`).
- **Content-Length / Transfer-Encoding precedence (RFC 9112 §6.3).** Exactly one
  `Content-Length` line, no comma, non-empty, digits only, `Body_Size'Value` with
  `Constraint_Error` mapped to 400 (`:1250-1277`; 64-bit overflow pinned by
  `tests/http_server_audit.adb:700-724`); declared length above the limit is 413 before
  any body byte. `Transfer-Encoding` requires HTTP/1.1, exactly one line, value exactly
  `chunked` after trim/lower; `chunked, chunked`, `gzip, chunked`, and TE with CL are all
  refused and the connection closed (`:1280-1297`). No precedence resolution exists to
  desynchronise against.
- **Host (RFC 9112 §3.2).** At most one line; required and non-empty on HTTP/1.1
  (`:1200-1210`); `Valid_Authority` (`:695-768`) refuses userinfo (`@`), comma, empty
  reg-name, bad IPv6/IPvFuture literals, and ports above 65535 with an overflow-safe
  accumulator (`:649-667`). Absolute-form authority is validated and selected as
  `Authority_Value` (`:1211-1247`).
- **Request-target forms (RFC 9112 §3.2).** Origin form by leading `/`; absolute form
  only with an anchored `http://`/`https://` prefix (prior finding 2's fix holds here);
  `*` only with OPTIONS; authority form is reachable only via CONNECT, which is refused;
  `#` refused; each `%` must be followed by two hex digits; bytes > 127 and the
  delimiters `<>"{}|\^\`` are refused raw (`:770-851`).
- **Chunk decoding (RFC 9112 §7.1).** Hex digits only, no `+`/`-`/`0x`, leading zeros
  accepted; the size line is capped at 1024 bytes (`:2010`) with `Body_Input_Maximum`
  agreeing at 1026 (`:2039-2055`); per-digit overflow guard against `Body_Limit`
  (`:892-899`) and a cumulative `Body_Total` check (`:2018-2020`); exactly CRLF is
  required after chunk data (`:1953-1966`); the zero chunk switches to trailers.
  Termination of every branch of the extension parser was traced.
- **Trailers (RFC 9110 §6.5).** Each line passes `Validate_Header_Block`; `connection`,
  `content-length`, `host`, `trailer`, `transfer-encoding` and `upgrade` are refused
  (`:1995-1999`); total trailer bytes are bounded by `Max_Header_Bytes` with no
  underflow in `Max_Header_Bytes - Trailer_Bytes - 2` (`:1969-1976`). Trailers are
  exposed only through `Trailer_*` accessors, which raise `Program_Error` before body
  completion (`:2411-2453`, pinned by `tests/http_server_audit.adb:777-790`), and are
  never merged into `Header`, so a trailer cannot override a framing or routing field.
- **Expect (RFC 9110 §10.1.1).** `Expect_Policy.Classify` is SPARK-contracted and
  pinned by its smoke test: HTTP/1.0 ignores the field, one `100-continue` proceeds,
  anything else is 417. `100 Continue` is emitted only from `Accept_Body`, after the
  deadline check (`:1663-1684`), and not at all when framing declares no body
  (`:1316-1321`). A rejected upload (`Respond` with the body unread) forces
  `Connection: close` and `Terminal` (`:2725-2726`, `:2786-2789`; pinned by
  `tests/http_smoke.adb:591-604`), so a body the client sends anyway cannot become the
  next request.
- **Keep-alive and Connection tokens (RFC 9112 §9.3).** HTTP/1.1 persists unless a
  `close` member is present; HTTP/1.0 persists only with `keep-alive` and no `close`
  (`:1340-1345`). `Header_Has_Token` (`:527-550`) splits on commas, trims OWS, compares
  case-insensitively and whole-member, so `notclose` does not match.
- **Pipelining and response ordering.** `Pending` survives across requests; fixed-body
  and chunk-data reads never request more than the framing allows
  (`Body_Input_Maximum`), so the next request's bytes are never consumed as body; the
  engine is strictly request-then-response, so ordering is structural.
- **Response-length accounting (RFC 9112 §6.3).** `Respond` always emits
  `Content-Length` except for 204 and 304, refuses content on 204/205/304, and suppresses
  the body on HEAD while keeping the declared length (`:2715-2790`; pinned by
  `tests/http_smoke.adb:152-194`). 1xx cannot be sent through `Respond` or the streams
  (200..599 guard). Fixed-length streams: overrun is refused before any transport write
  and terminalizes (`:2917-2921`, pinned `:322-347`), underrun terminalizes at
  `End_Response_Stream` (`:3024-3029`, pinned `:348-372`), HEAD declares the length and
  accepts writes without counting (`Fixed_Response_Policy.Write`, pinned `:276-297` and
  the policy smoke test), and no chunked terminator is written for HEAD or fixed
  responses (`:3030-3042`). Unknown-length HTTP/1.0 responses are close-delimited.
- **Body limits and drains.** `Narrow_Body_Limit` only shrinks and refuses once bytes
  have been consumed (`:2477-2491`); `Buffer_Request_Body` reserves only what the next
  read can deliver and grows with arrival (`:2493-2549`; prior finding 12's fix holds
  and is pinned by `tests/http_server_audit.adb:498-631`); a mid-body EOF is
  `Protocol_Error` → 400 + close, never a silent truncation.
- **Header-size bound.** 32 KiB plus the 4-byte terminator; the composable
  `Receive_Head_Step`'s `Room := Max_Header_Bytes + 4 - Current` (`:1384`) cannot go
  negative because every body-phase receive caps `Pending` at ≤ 32 KiB and the
  synchronous head path caps it at 32 KiB + 4 (`:555-597`, `:1129-1132`).
- **Deadlines.** One monotonic origin captured before the first head byte; the head
  timeout is `min(header, request)` (`:1088-1094`); `Narrow_Request_Deadline` only
  shortens (`:2461-2475`); `Accept_Body`, `Read_Body` and the composable operations all
  check the remaining budget before I/O; expiry mid-body leaves `Body_Done` false so any
  response forces close.
- **Response header injection.** `Validate_Extra_Headers` (`:2612-2661`) requires
  CRLF-terminated fields, refuses `CRLF CRLF`, token-checks names, refuses the managed
  fields, and refuses controls/DEL in values; `Content_Type` is scanned for controls
  (`:2753-2763`, `:2829-2833`); the reason phrase comes from a fixed table (`:2568-2604`);
  `Responses.Add_Header`/`Set_Cookie` and `Applications.Add_Header` validate name and
  value (`responses.adb:5-31`, `applications.adb:314-341`). SSE `Event`/`Id` refuse CR
  and LF (`:3088-3096`) and `Data`/`Comment` are line-split into repeated fields, so no
  application value reaches the wire with a raw CR or LF.
- **Ada range safety on hostile input.** Every slice and subtraction on the head and
  body paths was traced: `Header_End - 1` (≥ 0), `Request_Line (First_Space + 1 ..
  Second_Space - 1)` (guarded), `Request_Target'Last - Index < 2`, `Value (Closing + 1)`
  (guarded), `Marker - 1` in `Take_Buffered_Line`, `Body_Remaining - Count`
  (`Count ≤ Body_Remaining`), `Body_Limit - Chunk_Size` (`Chunk_Size ≤ Body_Limit` by
  construction), and the `Natural (Body_Total)` conversions in `Buffer_Request_Body`
  (bounded by the reservation, itself ≤ `Positive'Last`). `Valid_IPv6` wraps
  `GNAT.Sockets.Inet_Addr` in `when others`. No `Constraint_Error` reachable from the
  wire was found.
- **Prior findings assigned to this area.** 23: `Current_Is_Head`/`Current_Version` are
  reset in `Initialize_Request_Head` (`:1021-1023`) and set before any later raise
  (`:1169`, `:1189`). 24: Cookie joiner is `"; "` (`:497-498`). 25: `Decode_Query`
  refuses decoded bytes < 32 and 127 (`requests.adb:44-49`). 34: `WebSocket_Limit`
  retains the application bound and is used by the close drain (`:4338`, `:4816`).
  35: `WebSocket_Reserved` no longer exists in `src/`. 12: see body limits above.

## Observations not counted

- **Close with an unread body relies on the transport owner's close discipline.** A
  413/417/403 written while request bytes remain unread, followed by the owner's
  `close`, can be turned into a TCP RST that discards the response on the client
  (RFC 9112 §9.6 describes the staged close that avoids this). The engine deliberately
  does not drain (`server.ads:536-538` explains why), and closing is the transport
  owner's job, so this is outside the area; it is worth a note in the guide for
  applications that reject large uploads.
- **Empty `Host` on HTTP/1.1 is refused** (`:1205-1208`). RFC 9112 §3.2 permits an
  empty Host when the target has no authority, but origin-form requests always have one
  in practice and every stock client sends a non-empty Host.
- **`Host: example.com:` (empty port) is refused** because `Valid_Port` requires at
  least one digit (`:652-654`); RFC 3986 §3.2.3 `port = *DIGIT` admits the empty port.
  No known client sends it.
- **413 takes precedence over the TE/CL conflict.** A head with `Content-Length` above
  the limit and `Transfer-Encoding: chunked` answers 413 rather than 400 because the
  length check runs first (`:1250-1277` before `:1280-1297`). Both close the connection;
  diagnostic only.
- **Two `Expect: 100-continue` lines answer 417** (`Expect_Policy`, pinned by
  `tests/http_smoke.adb:536-538` and the policy smoke test). `Expect` is list syntax
  under RFC 9110 §10.1.1, so this is stricter than the grammar; no client sends it.
- **No physical field-count bound** on request headers or trailers, only the 32 KiB
  byte bound; every `Header`/`Header_Count` lookup is a linear scan of the block, so a
  head of ~8000 minimal fields costs O(fields) per lookup. CPU only, bounded by the byte
  limit.
- **503 where 413 is knowable at head time.** Under `Read_Request`/`Buffer_Body`, a
  declared `Content-Length` larger than the ingress budget's `Limit` is only discovered
  when reservation growth fails mid-body, yielding `503` with `Retry-After: 1` after
  reading up to the budget. The budget is documented as an independent bound
  (`server.ads:23-25`), so this is policy; a head-time comparison against `Limit` would
  give the client a non-retryable 413 instead.
- **Redundant `Connection: keep-alive` on HTTP/1.1 responses** and `Content-Type` on
  204/304 responses when the caller supplies one; harmless.
- **`Initialize_Body_Read` zero-fills the whole caller buffer on every `Read_Body`**
  (`:2070`); performance only.
- **Unverified driver assumption in the composable head read.** `Receive_Head_Step`
  raises `Program_Error` "closed HTTP head did not terminalize" if `Receive_IO` ever
  reports `Peer_Closed` while a complete head sits in `Pending` (`:1412-1426`). That
  cannot happen if the driver never delivers data together with `Peer_Closed`;
  `Advance_Head` inspects before every receive. The driver lives in the flyology
  dependency and was not verified.
- **`Serve` propagates non-protocol exceptions by design** (`Check_Application_Failure_
  Propagates`). H1-SERVER-5 is recorded only because the inputs that trigger those
  exceptions are chosen by the peer.
