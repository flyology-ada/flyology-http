# Verification: H1-SERVER

Commit: f078732
Findings examined: 5 recorded + 2 adversarial probes raised here.
Confirmed: 3. Refuted: 0. Partial: 1. Other: 1 (confirmed behaviour that is a
deliberately pinned policy choice). Probes: 2, both found the surface sound.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| H1-SERVER-1 | P2 | CONFIRMED | P2 | `repro_h1_server_1` |
| H1-SERVER-2 | P2 | CONFIRMED | P2 | `repro_h1_server_2` |
| H1-SERVER-3 | P2 | PARTIALLY CONFIRMED | P2 | `repro_h1_server_3` |
| H1-SERVER-4 | P2 | CONFIRMED (documented limitation) | P2 | `repro_h1_server_4` |
| H1-SERVER-5 | P2 | CONFIRMED | **P1** (raised) | `repro_h1_server_5` |
| H1-SERVER-6 | — (probe) | REFUTED — no smuggling primitive found | n/a | `repro_h1_server_6` |
| H1-SERVER-7 | — (probe) | REFUTED — no body/keep-alive desync found | n/a | `repro_h1_server_7` |

Standards text was read from the authoritative plain-text RFCs
(`rfc-editor.org/rfc/rfc9110.txt`, `rfc9112.txt`, `rfc6585.txt`), not from
memory. Every quotation below is verbatim from those files.

Relevance of the existing baselines: `review/baselines/SUMMARY.txt` contains no
HTTP/1.1 conformance suite. h2spec (13-) is HTTP/2, Autobahn (20- through 23-)
is WebSocket, h3spec and the interop runs (10- through 12-) are HTTP/3, and the
client differential (18-) exercises the Ada *client* against PycURL. Nothing in
the green set drives crafted HTTP/1.x request heads at the server, which is why
all five entries survive a green baseline.

Harness self-tests re-run after adding the spikes: `repro_smoke` PASS,
`seam_check` PASS.

## H1-SERVER-6 (probe): is the request-smuggling surface really sound?

- **Verdict:** REFUTED — I could not construct a smuggling or desync primitive.
- **Severity:** n/a (a confirmed primitive here would have been P0)
- **Repro:** `tests/repros/src/repro_h1_server_6.adb`, run with
  `./tests/repros/run.sh repro_h1_server_6`
- **Output:**

```
  note probe: HTTP/1.x request-smuggling surface (Content-Length,
  note Transfer-Encoding, field-name and field-value grammar)
  ok   Content-Length with a leading plus is refused
  ok   Content-Length with leading zeros decodes to five
  ok   Content-Length surrounded by OWS decodes to five
  ok   Content-Length surrounded by HTAB decodes to five
  ok   Content-Length with a trailing NUL is refused
  ok   Content-Length with an Ada underscore is refused
  ok   Content-Length as an Ada based literal is refused
  ok   Content-Length list value is refused
  ok   case-differing repeated Content-Length is refused
  ok   Content-Length name with a trailing space is refused
  ok   obs-folded Content-Length is refused
  ok   bare LF between two Content-Length lines is refused
  ok   two Transfer-Encoding lines are refused
  ok   case-differing repeated Transfer-Encoding is refused
  ok   Transfer-Encoding chunked-comma-chunked is refused
  ok   Transfer-Encoding on HTTP/1.0 is refused
  ok   Content-Length together with Transfer-Encoding is refused
  ok   Transfer-Encoding before Content-Length is refused
  ok   Content-Length in a chunked trailer is refused
  ok   well-formed chunked body frames exactly one request
checks: 20  failures: 0
PASS
EXIT=0
```

- **Description:** every case the coordinator named was driven through
  `Connection_Handlers.Serve` on an in-memory `Flyology.HTTP.Server.Transport`
  with a pipelined `GET /smuggled` behind the hostile head, so a framing
  divergence would appear as an extra served request. All were refused with a
  single 400 and connection close, or framed exactly as a compliant parser
  frames them. The mechanism is that `Validate_Header_Block`
  (`src/flyology-http-server.adb:610-643`) runs over the whole header block
  before any field is interpreted: it splits only on CRLF, rejects a line whose
  first octet is SP or HTAB, requires a colon strictly after a non-empty
  `Validate_Token` name (so `Content-Length : 5` fails on the space inside the
  name, as RFC 9112 section 5.1 requires), and rejects every octet below 32
  except HTAB plus octet 127 in values — which is what kills the trailing NUL
  and the bare-LF field split. `Header_Field_Count` and `Header` then use the
  same colon rule and the same `Lower` comparison over the same block
  (`Physical_Header_Block` is assigned from `Header_Block` at `:1195` and
  neither is ever reassigned), so counting and lookup cannot disagree on a
  field name's case. `Content-Length` is accepted only when the count is
  exactly one, the joined value contains no comma, is non-empty, and every
  octet is `'0' .. '9'`; the digits-only loop precedes `Body_Size'Value`, which
  is what stops the Ada-specific `1_0` and `16#5#` literals that `'Value` would
  otherwise accept. `Transfer-Encoding` is accepted only on HTTP/1.1, with
  exactly one field line, whose trimmed lowercased value is exactly `chunked`,
  and never beside `Content-Length`. RFC 9112 section 6.1's requirement for the
  CL+TE case — "Regardless, the server MUST close the connection after
  responding to such a request to avoid the potential attacks" — is met,
  because `Connection_Handlers.Serve` answers the `Protocol_Error` with a
  best-effort 400 carrying `Connection: close` and then returns.
  Two additional cases I added beyond the brief, `Content-Length: 5, 5` and a
  `Content-Length` trailer after the last chunk, are also refused.

## H1-SERVER-7 (probe): unread bodies, refused uploads, trailers, Connection tokens

- **Verdict:** REFUTED — no desync found on the non-head-parser surfaces.
- **Severity:** n/a
- **Repro:** `tests/repros/src/repro_h1_server_7.adb`, run with
  `./tests/repros/run.sh repro_h1_server_7`
- **Output:**

```
  note probe: unread bodies, rejected uploads, trailers, Connection
  note tokens and HEAD suppression, each with a pipelined follower
  ok   pipelined follower is 35 octets
  ok   an unread body is not reparsed as the next request
  ok   an unread body forces Connection: close
  ok   a refused 100-continue upload answers once and closes
  ok   no 100 Continue is emitted for a refused upload
  ok   a trailer is not visible as a request header field
  ok   Connection: notclose does not close the connection
  ok   a close member closes even beside keep-alive
  ok   HEAD declares the representation length
  ok   HEAD sends no response content
  ok   the request after a HEAD is framed correctly
checks: 11  failures: 0
PASS
EXIT=0
```

- **Description:** the discovery report's "verified sound" list claims the
  unread-body, Expect, trailer, Connection-token and HEAD paths cannot
  desynchronise. Each was driven with a pipelined `GET /smuggled` whose 35
  octets were also offered as a declared `Content-Length: 35` body, so a
  connection that wrongly stayed alive, or that reinterpreted unread body
  octets, would have produced a second response. None did. `Respond` computes
  `Must_Close := Close or else Item.Request_Close or else not Item.Body_Done`
  (`src/flyology-http-server.adb:2725-2726`), so responding over an unconsumed
  body terminalises the connection; `100 Continue` is emitted only from
  `Accept_Body`, so a handler that refuses an upload never invites the body;
  trailers land in `Item.Trailer_Block` and are reachable only through the
  `Trailer_*` accessors, never through `Header`; and `Header_Has_Token` matched
  `notclose` as a non-member while still matching `close` inside
  `keep-alive, close`.

## H1-SERVER-1: a stray CRLF before a request-line is rejected as malformed

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_h1_server_1.adb`, run with
  `./tests/repros/run.sh repro_h1_server_1`
- **Output:**

```
  note RFC 9112 section 2.2 SHOULD-ignore of one empty line before a
  note request-line; the extra CRLF an HTTP/1.0 agent sends after a POST
  ok   first request target
  ok   first request content
  FAIL pipelined request behind a stray CRLF is served
  note   raised Protocol_Error: malformed HTTP request line
  ok   first request target (EOF)
  FAIL a stray CRLF then FIN is a clean close between requests
  note   raised Protocol_Error: peer closed inside HTTP headers
checks: 5  failures: 2
BUG REPRODUCED
EXIT=1
```

- **Description:** `Read_Request_Head_Impl` takes the head as
  `Available (1 .. Header_End - 1)` and splits the request-line at the first
  CRLF (`src/flyology-http-server.adb:1141-1146`). When `Pending` begins with
  CRLF the request-line is the empty string, `First_Space` is 0, and
  `:1155-1162` raises `Protocol_Error` "malformed HTTP request line"; nothing
  anywhere skips an empty line first. Both cited lines reproduce. RFC 9112
  section 2.2 says verbatim: "In the interest of robustness, a server that is
  expecting to receive and parse a request-line SHOULD ignore at least one
  empty line (CRLF) received prior to the request-line." The same section
  explains where the input comes from: "Older HTTP/1.0 user agent
  implementations might send an extra CRLF after a POST request as a workaround
  for some early server applications" — and an HTTP/1.1 agent "MUST NOT preface
  or follow a request with an extra CRLF", which is why I keep this at P2. The
  second variant is the sharper one for an operator: after a completed
  response, a peer that sends the stray CRLF and then FIN makes
  `Inspect_Request_Head_Input` (`:1055-1068`) see `Available'Length = 2` rather
  than 0, so instead of reporting a clean close between requests it raises
  "peer closed inside HTTP headers" and `Connection_Handlers.Serve` writes a
  400 after an exchange that already succeeded. I did not verify against a
  pinned peer that any current stock client emits the extra CRLF; that claim is
  not verified against a peer.

## H1-SERVER-2: chunk-extension BWS is rejected

- **Verdict:** CONFIRMED, and broader than recorded
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_h1_server_2.adb`, run with
  `./tests/repros/run.sh repro_h1_server_2`
- **Output:**

```
  note RFC 9112 section 7.1.1 chunk-ext admits BWS before the semicolon,
  note after the semicolon, and around the equals sign
  ok   chunk extension without BWS (baseline)
  FAIL BWS before the chunk-ext semicolon
  note   raised Protocol_Error: invalid HTTP chunk size
  FAIL HTAB before the chunk-ext semicolon
  note   raised Protocol_Error: invalid HTTP chunk size
  FAIL BWS after the chunk-ext semicolon
  note   raised Protocol_Error: invalid chunk extension name
  FAIL BWS before the chunk-ext equals sign
  note   raised Protocol_Error: invalid chunk extension name
  FAIL BWS after the chunk-ext equals sign
  note   raised Protocol_Error: invalid chunk extension value
  FAIL BWS around a valueless chunk extension
  note   raised Protocol_Error: invalid HTTP chunk size
checks: 7  failures: 6
BUG REPRODUCED
EXIT=1
```

- **Description:** the discovery entry names two BWS positions; all four that
  the grammar admits are rejected. RFC 9112 section 7.1.1 gives
  `chunk-ext = *( BWS ";" BWS chunk-ext-name [ BWS "=" BWS chunk-ext-val ] )`
  and requires that "A recipient MUST ignore unrecognized chunk extensions";
  RFC 9110 section 5.6.3 adds "A recipient MUST parse for such bad whitespace
  and remove it before interpreting the protocol element." In
  `Parse_Chunk_Size` (`src/flyology-http-server.adb:872-900`) the size slice
  runs to `Semicolon - 1`, so BWS before the `;` lands inside the hex slice and
  fails the HEXDIG loop; the extension scanner at `:909-923` walks to the next
  `=` or `;` and hands the raw slice to `Validate_Token`, so BWS after the `;`
  or before the `=` becomes an invalid name and BWS after the `=` becomes an
  invalid token value. The baseline `1;a=b` is accepted, so only the whitespace
  is at issue. Impact remains low: a rejected chunk is a 400 plus close on a
  body that was well formed, and I know of no stock client that emits chunk
  extensions, let alone with BWS — not verified against a peer.

## H1-SERVER-3: oversized head, unknown transfer coding, CONNECT and versions all answer 400

- **Verdict:** PARTIALLY CONFIRMED — the behaviour is exactly as described for
  all five rows, but three of the five cited standards clauses do not support
  the "expected" column, and one of them does not exist in the cited RFC.
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_h1_server_3.adb`, run with
  `./tests/repros/run.sh repro_h1_server_3`
- **Output:**

```
  note observed status for each row of the H1-SERVER-3 table
  note head over Max_Header_Bytes -> 400 (431 would be RFC 6585 section 5)
  note CONNECT with a matching Host -> 400 (405 or 501 would be RFC 9110 section 15.5.6 or 15.6.2)
  note GET / HTTP/1.2 -> 400 (RFC 9112 no longer carries the RFC 7230 minor-version SHOULD)
  note GET / HTTP/2.0 on a cleartext HTTP/1 listener -> 400 (505 is RFC 9110 section 15.6.6, described not required)
  note Transfer-Encoding: chunked on HTTP/1.0 -> 400 (RFC 9112 section 6.1 requires only faulty-framing plus close)
  FAIL unknown transfer coding answers 501 (RFC 9112 section 6.1)
         expected: [501]
         actual:   [400]
checks: 1  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** all five rows behave as the discovery entry says: every one
  answers a single 400 and closes. Row by row, against the text:
  - **Unknown transfer coding.** This is the one genuine normative deviation.
    RFC 9112 section 6.1: "A server that receives a request message with a
    transfer coding it does not understand SHOULD respond with 501 (Not
    Implemented)." `Transfer-Encoding: gzip, chunked` on HTTP/1.1 answers 400.
    The entry folds `chunked` on HTTP/1.0 into this row, and that part does not
    hold: section 6.1 says of that case only "A server or client that receives
    an HTTP/1.0 message containing a Transfer-Encoding header field MUST treat
    the message as if the framing is faulty, even if a Content-Length is
    present, and close the connection after processing the message", which 400
    plus close satisfies.
  - **Oversized head.** The entry cites "RFC 9110 section 15.5.15 / RFC 6585
    section 5". RFC 9110 section 15.5.15 is **414 URI Too Long**, not 431; 431
    lives only in RFC 6585 section 5, which is permissive — "It can be used
    both when the set of request header fields in total is too large, and when
    a single header field is at fault" — with no MUST or SHOULD. 400 is a
    diagnostic loss, not a violation.
  - **CONNECT.** RFC 9110 section 9.3.6 says only "An origin server MAY accept
    a CONNECT request, but most origin servers do not implement CONNECT", and
    imposes a status only for a bad port: "A server MUST reject a CONNECT
    request that targets an empty or invalid port number, typically by
    responding with a 400 (Bad Request) status code." 501 fits section 15.6.2's
    "does not support the functionality required to fulfill the request" and
    405 would require an `Allow` field per section 15.5.6, but neither is
    required here.
  - **`GET / HTTP/1.2`.** The entry quotes "SHOULD process the message as if it
    were in the highest minor version ... to which the recipient is conformant"
    and attributes it to RFC 9112 section 2.3. That sentence is **not in RFC
    9112 or RFC 9110**; it is RFC 7230 section 2.6, which RFC 9112 obsoletes.
    RFC 9112 section 2.3 and RFC 9110 section 2.5 carry no such requirement.
  - **`GET / HTTP/2.0`.** 505 is defined in RFC 9110 **section 15.6.6**, not
    RFC 9112 section 2.3 (RFC 9112 never mentions 505), and it is descriptive:
    "The 505 (HTTP Version Not Supported) status code indicates that the server
    does not support, or refuses to support, the major version of HTTP that was
    used in the request message."

  So the finding stands as recorded behaviour and keeps P2, but the maintainer
  should treat only the 501 row as standards-backed; the rest are conventional
  diagnostics. No row breaks a stock peer: every case closes the connection
  either way and no message-boundary ambiguity results, which is why P2 is
  right under the rubric's "a wrong status code is P2 unless it breaks a stock
  peer". `Flyology.HTTP.Headers.Headers_Too_Large`
  (`src/flyology-http-headers.ads:19`) exists but is never raised by the server
  parser, so an application cannot currently tell these cases apart either.

## H1-SERVER-4: absolute-form target with a differing Host is refused

- **Verdict:** CONFIRMED as behaviour; DOCUMENTED LIMITATION as disposition —
  the deviation is deliberately pinned by the maintained suite.
- **Severity:** P2 (discovery said P2; unchanged). It is contract drift the
  maintainer chose, not an oversight, so it belongs in the guide rather than in
  a fix queue unless the owner wants the MUST honoured.
- **Repro:** `tests/repros/src/repro_h1_server_4.adb`, run with
  `./tests/repros/run.sh repro_h1_server_4`
- **Output:**

```
  note RFC 9112 section 3.2.2 origin-server MUST-ignore of Host under an
  note absolute-form request-target
  ok   absolute form with an agreeing Host (baseline) target
  ok   absolute form with an agreeing Host (baseline) authority
  FAIL absolute form with a differing Host target
  note   raised Protocol_Error: Host conflicts with request target
  FAIL absolute form with a differing Host port target
  note   raised Protocol_Error: Host conflicts with request target
checks: 4  failures: 2
BUG REPRODUCED
EXIT=1
```

- **Description:** RFC 9112 section 3.2.2 says verbatim: "When an origin server
  receives a request with an absolute-form of request-target, the origin server
  MUST ignore the received Host header field (if any) and instead use the host
  information of the request-target." Section 3.2 enumerates the Host cases
  that must answer 400 — "A server MUST respond with a 400 (Bad Request) status
  code to any HTTP/1.1 request message that lacks a Host header field and to
  any request message that contains more than one Host header field line or a
  Host header field with an invalid field value" — and a valid Host that merely
  disagrees with the target is not among them. `Validate_Target_And_Authority`
  (`src/flyology-http-server.adb:843-848`) adds a case-insensitive comparison
  of the Host against the target authority and raises `Protocol_Error` "Host
  conflicts with request target" when they differ. The parser does already
  select the target's authority as `Authority_Value` (`:1211-1247`), so the
  "instead use the host information of the request-target" half is honoured;
  only the extra refusal deviates. This is pinned as intended by the maintained
  suite at `tests/http_smoke.adb:2152-2155`:

```ada
      pragma Assert
        (Is_Rejected
           ("GET http://example.test/ HTTP/1.1" & CRLF
            & "Host: other.test" & CRLF & CRLF));
```

  Because a maintained test asserts the rejection, this is a chosen hardening
  against Host-based confusion at an intermediary, and the right disposition is
  to record it rather than to change it without the owner's decision. One case
  the discovery entry does not mention is worth flagging to the owner: the
  comparison is exact, so `GET http://example.test:8080/p?q HTTP/1.1` with
  `Host: example.test` is also refused. Such a client is itself non-conformant
  under section 3.2 ("a client MUST send a field value for Host that is
  identical to that authority component"), so the refusal is defensible, but it
  widens the set of inputs the policy rejects beyond the literal MUST at issue.

## H1-SERVER-5: peer-chosen request shapes raise Program_Error and drop the connection

- **Verdict:** CONFIRMED, and materially worse than the discovery entry states.
- **Severity:** **P1** (discovery said P2; raised). The rubric puts a violated
  `.ads` contract and an unexpected exception on valid input via a reachable
  path at P1, and both hold: `src/flyology-http-server.ads:857` documents
  `@exception Protocol_Error Request is not a valid version 13 upgrade`, the
  code raises `Program_Error` instead, and the peer receives **no response at
  all** rather than the wrong status. It is not P0: the exception does not
  stall or amplify, and the pinned dependency recovers the worker (below).
- **Repro:** `tests/repros/src/repro_h1_server_5.adb`, run with
  `./tests/repros/run.sh repro_h1_server_5`
- **Output:**

```
  note peer-chosen shapes reaching Accept_WebSocket and Begin_SSE through
  note the raw Connection_Handlers engine
  ok   baseline: a bodiless handshake upgrades (101)
  FAIL upgrade with Content-Length body, buffered: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "WebSocket upgrade requests must not carry a body"
  FAIL upgrade with Content-Length body, buffered: peer receives a client-error response
  note   wire status: (no response)
  FAIL upgrade with Content-Length body, unbuffered: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "WebSocket upgrade requests must not carry a body"
  FAIL upgrade with Content-Length body, unbuffered: peer receives a client-error response
  note   wire status: (no response)
  FAIL upgrade with a chunked body, unbuffered: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "WebSocket upgrade requests must not carry a body"
  FAIL upgrade with a chunked body, unbuffered: peer receives a client-error response
  note   wire status: (no response)
  FAIL HEAD on an SSE route: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "SSE is not available for HEAD"
  FAIL HEAD on an SSE route: peer receives a client-error response
  note   wire status: (no response)
  FAIL HTTP/1.0 on an SSE route: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "SSE requires HTTP/1.1"
  FAIL HTTP/1.0 on an SSE route: peer receives a client-error response
  note   wire status: (no response)
checks: 11  failures: 10
BUG REPRODUCED
EXIT=1
```

- **Description:** `Accept_WebSocket` (`src/flyology-http-server.adb:3933-3937`)
  raises `Program_Error` when the upgrade request carries a body, and
  `Begin_SSE` (`:3059-3062`) raises `Program_Error` for HEAD and for HTTP/1.0.
  All three conditions are chosen by the peer. `Connection_Handlers.Serve`
  catches `Payload_Too_Large`, `Resource_Exhausted`, `Protocol_Error` and the
  I/O errors around `Handle` (`connection_handlers.adb:126-142`) and nothing
  else, so `Program_Error` leaves `Serve` and the transport is closed without a
  single byte written. That is the answer to the coordinator's question: this
  is not merely a wrong exception name, it is an exception escaping into the
  connection handler that drops the connection with no response. The baseline
  in the same spike shows a bodiless handshake still upgrading with 101, so
  only the peer-chosen shape is at issue.

  **Reachability on valid input.** The upgrade-with-body case needs a client
  that sends content on a GET, which RFC 9110 section 9.3.1 advises against, so
  on its own it would stay P2. The SSE rows do not: `HEAD /events` and
  `GET /events HTTP/1.0` are ordinary, conformant requests that `curl -I` and
  `curl --http1.0` produce. The maintained showcase
  `showcases/http_server.adb:90-92` routes `/events` straight into `Begin_SSE`
  with no method or version gate and serves it through
  `Connection_Handlers.Serve` with `Buffer_Body => False`
  (`showcases/http_server.adb:153-160`), so a plain `curl -I` against the
  showcase is answered with a dropped connection. `tests/websocket_conformance_server.adb:105-110`
  uses the same raw engine for `Accept_WebSocket`. That is what raises this to
  P1.

  **Pinned-dependency verification.** The discovery entry says the downstream
  behaviour was only checked against a sibling `flyology` 0.2.0 checkout. I
  checked the revision this worktree actually builds with.
  `alire/alire.lock` pins `flyology` `=0.1.1-dev` at commit
  `bd95746d5c9c31f5b41b611db9ba82a016ceaaa4`, materialised at
  `~/.local/share/alire/releases/flyology_bd95746d`. In that source,
  `src/flyology-io-structured_servers.adb:452-459` wraps the handler call:

```ada
                           begin
                              Handle (Context, Connection, Peer, Item.Handler_Stop'Access);
                           exception
                              when Connections.Operation_Cancelled =>
                                 Cancelled := True;
                              when Event : others =>
                                 Report (Handler_Callback, Event);
                                 Failed := True;
                           end;
```

  followed by `Connections.Close (Connection)` and
  `Item.State.Handler_Completed (Cancelled, Failed)`. So on the pinned
  dependency the escaping `Program_Error` is caught, reported, the connection
  is closed and worker capacity is returned: no worker is lost and there is no
  stall, which is what keeps this below P0. The observable damage is confined
  to the one connection, which is dropped with no response.

  **Router path.** Through `Routing.Serve` the same requests do not drop the
  connection: `src/flyology-http-server-routing.adb:2264-2276` has a
  `when others` that answers `500 internal server error` with close. 500 is
  still the wrong channel for an input the peer chose, but the peer gets an
  answer. `Dispatch_Configuration` catches only `Route_Error`,
  `Payload_Too_Large`, `Expectation_Failed` and `Protocol_Error`
  (`routing.adb:2086-2108`), so the `Program_Error` does reach that outer
  handler as the entry says. The `HEAD /events` router case is additionally
  screened by the route's method gate (pinned at
  `tests/http_smoke.adb:3731-3749`), so the router exposure is the WebSocket
  body case and HTTP/1.0 SSE.

  **Why the green suites miss it.** Autobahn drives the conformance server
  only through a well-formed handshake, and no HTTP/1.1 conformance suite runs
  against this server at all (see the baseline note at the top).

## Findings sweep

Beyond re-checking the five entries I probed the parts of the discovery
report's "verified sound" list that a spike can settle: the whole
Content-Length / Transfer-Encoding precedence surface, header-name and
header-value grammar including obs-fold and bare-LF splitting, Ada-specific
`'Value` literal acceptance, trailer-to-header leakage, unread-body close
discipline, the refused-100-continue path, `Connection` token matching, and
HEAD body suppression. 31 crafted cases across `repro_h1_server_6` and
`repro_h1_server_7` all behaved correctly, so I found no P0 here and no reason
to doubt that part of the discovery report.

Final state of this area: one P1 (H1-SERVER-5), four P2 (H1-SERVER-1 through
H1-SERVER-4, with H1-SERVER-3 partially standing and H1-SERVER-4 a
deliberately pinned policy). No P0. Two of the five recorded entries carry
citation errors that the maintainer should not act on as written: H1-SERVER-3
attributes 431 to RFC 9110 section 15.5.15 (which is 414) and quotes an RFC
7230 sentence that RFC 9112 does not carry; the rest of its rows are
conventional rather than required.
