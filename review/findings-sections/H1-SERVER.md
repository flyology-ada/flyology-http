## H1-SERVER

This area covers the HTTP/1.x server engine: request-line and header-block parsing,
`Host` and request-target validation, `Content-Length` and `Transfer-Encoding`
precedence, chunk decoding and trailers, the `Expect` handshake, body limits and
drains, keep-alive and `Connection` token handling, pipelining, response-length
accounting, response header injection, and the SSE and WebSocket entry points.
Read in full or in the relevant part: `src/flyology-http-server.adb` (4838 lines,
with the WebSocket framing read only for the upgrade handshake),
`src/flyology-http-server.ads`, `src/flyology-http-server-requests.ads/.adb`,
`-responses.ads/.adb`, `-connections.ads/.adb`, `-connection_handlers.ads/.adb`,
`src/flyology-http-expect_policy.ads/.adb`, `-fixed_response_policy.ads/.adb`,
`src/flyology-http-headers.ads/.adb`, `src/flyology-http_chunk_encoding.ads/.adb`,
and `src/flyology-http-server-exchange_backends.ads`; cross-checked for
exception-to-status mapping: `src/flyology-http-server-routing.adb` and
`-applications.adb`; tests: `tests/http_server_audit.adb`, `tests/http_smoke.adb`,
`tests/http_operations_smoke.adb` and the three policy smoke tests.

**The headline for this area is a negative result.** The request-smuggling and
body-desynchronisation surface was attacked directly rather than only read, with
31 crafted cases across two adversarial probes, and it held: both probes PASS with
zero failures. A confirmed smuggling primitive here would have been the review's
only P0 in this area, and there is none. Details are in the coverage evidence below;
no issue is filed for it. What remains is five entries that need unusual or
conformant-but-uncommon input: one P1 raised during verification (H1-SERVER-5) and
four P2, one of which (H1-SERVER-3) stands only partially and one of which
(H1-SERVER-4) is contract drift the maintainer deliberately pinned.

### H1-SERVER-5: peer-chosen request shapes raise `Program_Error` and the connection is dropped with no response

- **Severity:** **P1** (discovery said P2; raised). The rubric puts an unexpected
  exception on valid input via a reachable path, together with a violated `.ads`
  contract, at P1, and both hold. It is not P0, because the pinned dependency recovers
  the worker (below).
- **Location:** `src/flyology-http-server.adb:3059-3063` (`Begin_SSE`), `:3932-3938`
  (`Accept_WebSocket`); the closed handler set at
  `src/flyology-http-server-connection_handlers.adb:125-142`; contract at
  `src/flyology-http-server.ads:857`
- **Repro:** `./tests/repros/run.sh repro_h1_server_5` (exit 1, BUG REPRODUCED,
  11 checks, 10 failures)
- **What is wrong:** This is not merely a wrong exception name. `Begin_SSE` raises
  `Program_Error` for HEAD and for HTTP/1.0, and `Accept_WebSocket` raises it when the
  upgrade request carries a body. `Connection_Handlers.Serve` catches
  `Payload_Too_Large`, `Resource_Exhausted`, `Protocol_Error` and the I/O errors and
  nothing else, so the exception leaves `Serve` and the transport is closed with
  **zero bytes written**: the spike records `wire status: (no response)` for all five
  peer-chosen shapes, against a bodiless handshake baseline that still upgrades with
  101. All three conditions are the peer's choice, not the application's.
- **Notes:** Reachability is what raised this. `HEAD /events` and
  `GET /events HTTP/1.0` are ordinary conformant requests that `curl -I` and
  `curl --http1.0` produce, and `showcases/http_server.adb:90-92` routes `/events`
  straight into `Begin_SSE` with no method or version gate, serving it through
  `Handler.Serve` with `Buffer_Body => False` at `:153-160`. So `curl -I` against the
  maintained showcase gets a dropped connection.
  `tests/websocket_conformance_server.adb:105-106` uses the same raw engine for
  `Accept_WebSocket`. The upgrade-with-body case on its own would have stayed P2,
  since RFC 9110 section 9.3.1 advises a client against content in a GET.
  **Verified against the pinned dependency, not a sibling checkout:** discovery had
  only checked a `flyology` 0.2.0 tree. `alire/alire.lock` pins `flyology =0.1.1-dev`
  at `bd95746d5c9c31f5b41b611db9ba82a016ceaaa4`, and in that revision
  `src/flyology-io-structured_servers.adb:452-460` wraps the handler call in
  `when Event : others => Report (...); Failed := True;`, followed by
  `Connections.Close (Connection)` and a completion that returns worker capacity. So
  the escaping `Program_Error` is caught, the connection closed and the worker
  released: **no stall and no capacity loss**, which is what keeps this below P0 and
  confines the damage to the one connection. Through `Routing.Serve` the same requests
  get an answer: the `when others` at `src/flyology-http-server-routing.adb:2264-2276`
  writes 500 and closes, still the wrong channel but not a drop, and the
  `HEAD /events` router case is additionally screened by the route's method gate pinned
  at `tests/http_smoke.adb:3731-3749`. **A maintainer decision is needed on the
  status**, because 400, 405 with `Allow`, and 505 are all defensible for different
  rows; the issue body lists the options and does not choose. `Begin_SSE`'s declaration
  at `src/flyology-http-server.ads:767-776` documents no exception at all, so an
  `@exception` line belongs there whichever way it goes. The two `Program_Error` raises
  in the same subprograms that guard genuine application faults must stay:
  `tests/http_smoke.adb:2034-2063` pins that propagation.

### H1-SERVER-1: a stray CRLF before a request-line is rejected as malformed

- **Severity:** P2 (discovery said P2; unchanged)
- **Location:** `src/flyology-http-server.adb:1140-1148` (request-line split),
  `:1155-1162` (the raise), `:1061-1067` (`Inspect_Request_Head_Input`, the EOF variant)
- **Repro:** `./tests/repros/run.sh repro_h1_server_1` (exit 1, BUG REPRODUCED,
  5 checks, 2 failures)
- **What is wrong:** The request-line is taken as everything up to the first CRLF of the
  buffered head and nothing skips an empty line first, so a leading CRLF makes the
  request-line empty, `First_Space` zero, and the request is rejected with
  "malformed HTTP request line". RFC 9112 section 2.2: "In the interest of robustness,
  a server that is expecting to receive and parse a request-line SHOULD ignore at least
  one empty line (CRLF) received prior to the request-line." The second variant is the
  sharper one for an operator: a peer that sends the stray CRLF and then FIN makes
  `Available'Length` two rather than zero, so instead of a clean close between requests
  the parser raises "peer closed inside HTTP headers" and `Serve` writes a 400 after an
  exchange that already succeeded.
- **Notes:** Both cited lines reproduce, and the first request is served correctly in
  both variants, so only the handling of the stray CRLF is at issue. RFC 9112 section
  2.2 also names the origin of the input ("Older HTTP/1.0 user agent implementations
  might send an extra CRLF after a POST request") and forbids an HTTP/1.1 agent from
  doing it, which is why this stays P2. **It was not verified against a pinned peer
  that any current stock client emits the extra CRLF**, and the issue body says so in
  the same sentence as the impact. A maintainer decision is flagged only if more than
  one empty line is to be tolerated; discarding exactly one introduces no new number.
  No maintained test places a CRLF before a request-line, so nothing has to change.

### H1-SERVER-2: chunk-extension BWS is rejected

- **Severity:** P2 (discovery said P2; unchanged). Confirmed and **broader than
  recorded**: discovery named two BWS positions, and all four the grammar admits are
  rejected.
- **Location:** `src/flyology-http-server.adb:875-877` (size slice ends at the
  semicolon), `:894` (the size raise), `:911-922` (extension name scanner)
- **Repro:** `./tests/repros/run.sh repro_h1_server_2` (exit 1, BUG REPRODUCED,
  7 checks, 6 failures)
- **What is wrong:** BWS before the `;` lands inside the hex slice and fails the HEXDIG
  loop; BWS after the `;` or before the `=` becomes an invalid extension name; BWS after
  the `=` becomes an invalid extension value. RFC 9112 section 7.1.1 gives
  `chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )` and
  requires that "A recipient MUST ignore unrecognized chunk extensions"; RFC 9110
  section 5.6.3 adds "A recipient MUST parse for such bad whitespace and remove it
  before interpreting the protocol element." A well-formed chunked body is answered 400
  and the connection closes.
- **Notes:** The baseline `1;a=b` is accepted, so only the whitespace is at issue. Both
  SP and HTAB are refused before the semicolon, and the valueless form `1 ; a ` fails
  too. Impact remains low: **no stock client is known to emit chunk extensions at all**,
  let alone with bad whitespace, and this is **not verified against a peer**. Existing
  coverage is `tests/http_smoke.adb:481-494` (a quoted extension with a quoted-pair, no
  BWS) and `:2174-2179` (`1;=x` rejected); neither exercises whitespace, and neither has
  to change. The fix must not reach inside a quoted-string extension value.

### H1-SERVER-3: oversized head, unknown transfer coding, CONNECT and versions all answer 400

- **Severity:** P2 (discovery said P2; unchanged). Verdict: **PARTIALLY CONFIRMED.**
  The behaviour is exactly as recorded for all five rows, but three of the five cited
  standards clauses do not support the "expected" column, and one of them does not
  exist in the cited RFC.
- **Location:** `src/flyology-http-server.adb:1059-1060` (head too large), `:1291-1292`
  (transfer coding), `:805-806` (CONNECT), `:1182-1187` (version); all reach the single
  `Protocol_Error` mapping at
  `src/flyology-http-server-connection_handlers.adb:109-111` and
  `src/flyology-http-server-routing.adb:2104-2109`
- **Repro:** `./tests/repros/run.sh repro_h1_server_3` (exit 1, BUG REPRODUCED,
  1 check, 1 failure)
- **What is wrong:** Every one of the five inputs answers a single 400 and closes. Only
  one row carries a normative requirement for a different status: RFC 9112 section 6.1,
  "A server that receives a request message with a transfer coding it does not
  understand SHOULD respond with 501 (Not Implemented)." `Transfer-Encoding: gzip,
  chunked` on HTTP/1.1 answers 400. That row is the spike's only assertion; the other
  four are recorded as observed statuses.
- **Notes:** **Three discovery citations were wrong and the issue body must not repeat
  them.** (1) 431 is RFC 6585 section 5, not RFC 9110 section 15.5.15, which is 414 URI
  Too Long; RFC 6585 section 5 is permissive ("It can be used both when the set of
  request header fields in total is too large, and when a single header field is at
  fault") with no MUST or SHOULD. (2) The "SHOULD process the message as if it were in
  the highest minor version" sentence is RFC 7230 section 2.6, which RFC 9112
  obsoletes; it is **not in RFC 9112 or RFC 9110** (RFC 9112 section 2.3 and RFC 9110
  section 2.5 carry no such rule, and RFC 9112 never mentions 505). (3) 505 is RFC 9110
  section 15.6.6 and is descriptive, not required. CONNECT: RFC 9110 section 9.3.6 says
  only "An origin server MAY accept a CONNECT request, but most origin servers do not
  implement CONNECT" and imposes a status only for a bad port. The entry also folded
  `chunked` on HTTP/1.0 into the 501 row, and that part does not hold: RFC 9112
  section 6.1 says of that case only that a recipient "MUST treat the message as if the
  framing is faulty ... and close the connection", which 400 plus close satisfies. All
  standards text was read from the authoritative plain-text RFCs, not from memory. The
  issue body is written around the 501 row and presents the rest as diagnostics quality,
  because a maintainer would correctly reject the other four as written. No row breaks a
  stock peer: every case closes the connection either way and no message-boundary
  ambiguity results, which is why P2 is right under the rubric's "a wrong status code is
  P2 unless it breaks a stock peer". `Flyology.HTTP.Headers.Headers_Too_Large`
  (`src/flyology-http-headers.ads:19`) exists but the server parser never raises it, so
  an application cannot tell these cases apart either. **A maintainer decision is
  needed**, because splitting the rejection vocabulary adds to what
  `src/flyology-http-server.ads` and the routing layer expose. `tests/http_smoke.adb`'s
  `Is_Rejected` helper (`:2098-2113`) only checks that `Protocol_Error` is raised and
  discards the status, so the regression test needs a status-observing helper.

### H1-SERVER-4: absolute-form target with a differing Host is refused

- **Severity:** P2 (discovery said P2; unchanged). Verdict: **CONFIRMED as behaviour,
  DOCUMENTED LIMITATION as disposition.** This is contract drift the maintainer chose,
  so it belongs in the guide rather than in a fix queue unless the owner wants the MUST
  honoured. Labelled `bug, documentation`.
- **Location:** `src/flyology-http-server.adb:843-848`
  (`Validate_Target_And_Authority`); authority selection already correct at `:1211-1247`
- **Repro:** `./tests/repros/run.sh repro_h1_server_4` (exit 1, BUG REPRODUCED,
  4 checks, 2 failures)
- **What is wrong:** A case-insensitive comparison of `Host` against the target
  authority raises `Protocol_Error "Host conflicts with request target"` when they
  differ. RFC 9112 section 3.2.2: "When an origin server receives a request with an
  absolute-form of request-target, the origin server MUST ignore the received Host
  header field (if any) and instead use the host information of the request-target."
  Section 3.2 enumerates the `Host` cases that must answer 400 (missing on HTTP/1.1,
  more than one field line, invalid field value) and a valid but disagreeing `Host` is
  not among them. The "instead use the host information of the request-target" half is
  already honoured; only the extra refusal deviates.
- **Notes:** **Pinned as intended by the maintained suite** at
  `tests/http_smoke.adb:2152-2155`, which asserts the rejection, so changing the
  behaviour means inverting a maintained assertion. The issue body frames the treatment
  as a documentation change unless the maintainer wants the behaviour changed, quotes
  RFC 9112 section 3.2.2, and offers the middle option of comparing only the host
  subcomponent. One case discovery does not mention and the spike adds: the comparison
  is exact, so `GET http://example.test:8080/p?q HTTP/1.1` with `Host: example.test` is
  also refused. Such a client is itself non-conformant under section 3.2 ("a client MUST
  send a field value for Host that is identical to that authority component"), so the
  refusal is defensible, but it widens the rejected set beyond the literal MUST and is
  documented nowhere. The baseline with an agreeing `Host` passes, so the absolute form
  itself is supported.

### Coverage evidence

**The request-smuggling surface was attacked, not just read, and it held.** Two
adversarial probes were written for this area and both PASS with zero failures:
`./tests/repros/run.sh repro_h1_server_6` (20 checks, exit 0) and
`./tests/repros/run.sh repro_h1_server_7` (11 checks, exit 0). Every case was driven
through `Connection_Handlers.Serve` on an in-memory `Flyology.HTTP.Server.Transport`
with a pipelined `GET /smuggled` behind the hostile head, whose 35 octets were also
offered as a declared `Content-Length: 35` body, so any framing divergence would have
shown up as an extra served request. None did.

What was tried in the first probe (all 20 refused correctly or framed as a compliant
parser frames them): `Content-Length` with a leading plus; with leading zeros; wrapped
in OWS; wrapped in HTAB; with a trailing NUL; with an Ada underscore (`1_0`); as an Ada
based literal (`16#5#`); as a list value; repeated with differing case; with a trailing
space inside the field name; obs-folded; split by a bare LF between two `Content-Length`
lines; two `Transfer-Encoding` lines; `Transfer-Encoding` repeated with differing case;
`chunked, chunked`; `Transfer-Encoding` on HTTP/1.0; `Content-Length` together with
`Transfer-Encoding`; `Transfer-Encoding` before `Content-Length`; `Content-Length` in a
chunked trailer; and a well-formed chunked body, which framed exactly one request. Two
of those, `Content-Length: 5, 5` and a `Content-Length` trailer after the last chunk,
were added beyond the brief.

The second probe covered the non-head-parser surfaces that discovery listed as
"verified sound", all 11 correct: an unread body is not reparsed as the next request;
an unread body forces `Connection: close`; a refused 100-continue upload answers once
and closes; no `100 Continue` is emitted for a refused upload; a trailer is not visible
as a request header field; `Connection: notclose` does not close the connection; a
`close` member closes even beside `keep-alive`; HEAD declares the representation length;
HEAD sends no response content; and the request after a HEAD is framed correctly.

The mechanism behind the negative result: `Validate_Header_Block`
(`src/flyology-http-server.adb:610-643`) runs over the whole header block before any
field is interpreted, splits only on CRLF, rejects a line whose first octet is SP or
HTAB, requires a colon strictly after a non-empty `Validate_Token` name, and rejects
every octet below 32 except HTAB plus octet 127 in values, which is what kills the
trailing NUL and the bare-LF field split. `Header_Field_Count` and `Header` use the same
colon rule over the same block, which is assigned once at
`src/flyology-http-server.adb:1195` and never reassigned, so counting and lookup cannot
disagree on a field name's case. `Content-Length` is accepted only when the count is
exactly one, the joined value has no comma, is non-empty, and is digits only, and that
loop precedes `Body_Size'Value`, which is what stops the Ada-specific literals `'Value`
would otherwise accept. `Transfer-Encoding` is accepted only on HTTP/1.1, as exactly one
field line whose trimmed lowercased value is exactly `chunked`, and never beside
`Content-Length`; RFC 9112 section 6.1's "the server MUST close the connection after
responding to such a request" is met, because `Serve` answers the `Protocol_Error` with
a best-effort 400 carrying `Connection: close` and returns. `Respond` computes
`Must_Close := Close or else Item.Request_Close or else not Item.Body_Done`
(`src/flyology-http-server.adb:2725-2726`), so responding over an unconsumed body
terminalises the connection; `100 Continue` is emitted only from `Accept_Body`; trailers
land in `Item.Trailer_Block` and are reachable only through the `Trailer_*` accessors;
and `Header_Has_Token` (`:527-550`) matches whole comma-separated members.

All five recorded entries have a runtime reproduction that was re-run at `f078732` for
this write-up; all five print `BUG REPRODUCED` and exit 1, and the numbers in the issue
bodies are from those fresh runs. The harness self-tests
`./tests/repros/run.sh seam_check` and `./tests/repros/run.sh repro_smoke` both PASS
(exit 0) after the probes were added.

**None of the green baselines covers HTTP/1.1 head parsing, which is why five entries
survive a green suite.** `review/baselines/SUMMARY.txt` contains no HTTP/1.1
conformance suite at all: h2spec (13-) is HTTP/2, Autobahn (14- through 16-, 20-
through 23-) is WebSocket, h3spec and the interop runs (10- through 12-) are HTTP/3,
and the client differential (17-, 18-) exercises the Ada *client* against PycURL.
Nothing in the green set drives crafted HTTP/1.x request heads at this server. Autobahn
reaches the WebSocket conformance server only through a well-formed handshake, so it
cannot see H1-SERVER-5 either.

Standards text for this area was read from the authoritative plain-text RFCs
(`rfc9110.txt`, `rfc9112.txt`, `rfc6585.txt`), not from memory, which is how three
discovery citations were caught. The downstream worker behaviour for H1-SERVER-5 was
verified against the revision this worktree actually builds (`flyology =0.1.1-dev` at
`bd95746d`), not against a sibling 0.2.0 checkout.

Not exercised: no pinned peer was driven against this server for any entry, so the
claims that a current stock client emits an extra CRLF after a POST (H1-SERVER-1) or
chunk extensions with BWS (H1-SERVER-2) are recorded as not verified against a peer.
The composable head read's assumption that the driver never delivers data together with
`Peer_Closed` (`src/flyology-http-server.adb:1412-1426`) depends on the `flyology`
dependency and was not verified.

### Refuted and not counted

**Refuted:** the two adversarial probes above. `repro_h1_server_6` looked for a
smuggling or desync primitive in the `Content-Length` and `Transfer-Encoding`
precedence surface and in the field-name and field-value grammar, and found none;
`repro_h1_server_7` looked for a body or keep-alive desync in the unread-body, Expect,
trailer, `Connection`-token and HEAD paths, and found none. Both are REFUTED, both are
n/a for severity, and neither is filed. A confirmed primitive in either would have been
P0.

Sub-claims narrowed rather than refuted: H1-SERVER-3's "expected" column loses three of
its five rows to corrected citations (above), and its HTTP/1.0-with-`Transfer-Encoding`
row is conformant as it stands. H1-SERVER-4's disposition moved from defect to
documented limitation, because `tests/http_smoke.adb:2152-2155` pins the behaviour.
H1-SERVER-2 widened: four BWS positions rather than the two recorded.

Recorded during discovery and deliberately not counted:

- **Close with an unread body relies on the transport owner's close discipline.** A
  413, 417 or 403 written while request bytes remain unread, followed by the owner's
  `close`, can become a TCP RST that discards the response at the client (RFC 9112
  section 9.6 describes the staged close that avoids it). The engine deliberately does
  not drain and `src/flyology-http-server.ads:536-538` explains why; closing is the
  transport owner's job, so this is outside the area. Worth a guide note for
  applications that reject large uploads.
- **Empty `Host` on HTTP/1.1 is refused.** RFC 9112 section 3.2 permits an empty `Host`
  when the target has no authority, but origin-form requests always have one in
  practice.
- **`Host: example.com:` with an empty port is refused**, because `Valid_Port` requires
  at least one digit. RFC 3986 section 3.2.3's `port = *DIGIT` admits the empty port. No
  known client sends it.
- **413 takes precedence over the TE/CL conflict**, because the length check runs first.
  Both close the connection; diagnostic only.
- **Two `Expect: 100-continue` lines answer 417.** `Expect` is list syntax under RFC
  9110 section 10.1.1, so this is stricter than the grammar; no client sends it.
- **No physical field-count bound** on request headers or trailers, only the 32 KiB byte
  bound, so every `Header` lookup is a linear scan. CPU only, bounded by the byte limit.
- **503 where 413 is knowable at head time.** A declared `Content-Length` larger than
  the ingress budget's `Limit` is discovered only when reservation growth fails mid-body.
  The budget is documented as an independent bound, so this is policy.
- **Redundant `Connection: keep-alive` on HTTP/1.1 responses**, and `Content-Type` on
  204 and 304 responses when the caller supplies one. Harmless.
- **`Initialize_Body_Read` zero-fills the whole caller buffer on every `Read_Body`.**
  Performance only.
- **`Serve` propagates non-protocol exceptions by design**, pinned by
  `Check_Application_Failure_Propagates` (`tests/http_smoke.adb:2034-2063`). H1-SERVER-5
  is recorded only because the inputs that trigger those particular exceptions are
  chosen by the peer.
- **Prior findings assigned to this area have not regressed:** 12 (body-limit
  reservation), 23 (`Current_Is_Head` and `Current_Version` reset), 24 (cookie joiner),
  25 (`Decode_Query` control rejection), 34 (`WebSocket_Limit` retained), 35
  (`WebSocket_Reserved` no longer exists in `src/`).
