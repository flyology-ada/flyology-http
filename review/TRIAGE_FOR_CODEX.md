# Flyology HTTP issue triage: #57–#133

77 confirmed findings from a correctness review of `flyology_http`, `flyology_quic` and
`flyology_iri` at commit `f078732`: 5 P0, 32 P1, 40 P2. Every issue is self-contained and
carries a runtime reproduction, except five P2 items that say in place why no reproduction
was made.

## Ground rules for every fix

- Read `AGENTS.md` first, in particular its sections "Flyology HTTP agent guide",
  "Decision authority", "Ada interface values", "Ada source style", "Review cycle",
  "Commits", "Performance testing", "Grounded communication" and "TLA+ assurance". They are
  the contract you are fixing against. After creating a worktree run `apm install --frozen`
  and `apm compile --target codex`, as the "Repository workflow" section requires, so
  `AGENTS.md` is current. Run `git status --short --branch` before changing anything.
- One issue per branch and per pull request, unless an entry below says two issues share a
  fix. Problem/Solution commit messages as the "Commits" section defines them, one problem
  per commit, no attribution footers. Reference the issue with `Closes #N`.
- Every fix needs a regression test that fails before and passes after. Every issue carries
  the spike that reproduced the defect. Turn that spike into a test in the suite it belongs
  to rather than inventing a new file:
  - `tests/http_server_audit.adb`, `tests/http_smoke.adb`, `tests/http_operations_smoke.adb`
    for HTTP/1 server cases over the in-memory transport.
  - `tests/http_routing_audit.adb` for routing, middleware, CORS, rate limits and metrics.
  - `tests/http2_server_audit.adb`, `tests/http2_server_integration.adb`,
    `tests/http2_client_integration.adb` and the `flyology-http-http_2_*-smoke.adb` units
    for HTTP/2.
  - `tests/http3_server_integration.adb`, `tests/http3_public_smoke.adb`,
    `tests/http3_client_composable_smoke.adb` and the `flyology-http-http_3_*-smoke.adb` and
    `flyology-http-qpack_*-smoke.adb` units for HTTP/3 and QPACK.
  - `flyology_quic/tests/` for the transport and TLS crate.
  - `tests/http_client_audit.adb`, `tests/http_client_parser_matrix.adb`,
    `tests/http_client_rfc_corpus.adb`, `tests/http_client_pool_model.adb`,
    `tests/http_client_pool_races.adb`, `tests/http_client_redirects.adb`,
    `tests/http_client_deadline_matrix.adb` for the client and the pool. A client parser case
    also belongs in the JSON corpus under `tests/corpus/` when it is expressible there.
  - `tests/websocket_server_audit.adb` and `tests/websocket_client_smoke.adb` for WebSocket.
  - `tests/http1_sse_client_integration.adb` for SSE.
  - `flyology_iri/tests/src/flyology_iri_tests.adb` for the IRI crate.
- Verification by area. Run the suites the change can affect, not all of them.
  - Any `src/` change: `./scripts/test.sh`. This is the gate; it also runs the
    `flyology_iri` and `flyology_quic` suites and the "no tasks in client units" check.
  - A change inside a unit `./scripts/prove.sh` proves: `./scripts/prove.sh` with
    `FLYOLOGY_PROOF_LEVEL=2`, which is what CI runs (`.github/workflows/ci.yml:193`). The
    script's own default is level 1, where two `flyology_quic` checks hit the prover time
    limit; use level 2 or you will chase a phantom. A change there is not done until
    GNATprove reports no unproved checks with `--checks-as-errors=on`.
  - HTTP/2: `./scripts/http2-test.sh all`, and `./scripts/http2-test.sh h2spec` where Docker
    is available. Note that h2spec 2.6.0 marks a test passed on connection close BEFORE
    comparing the GOAWAY code (`spec/verifier.go:53-92`), so a green h2spec run does not
    vouch for an error code; two issues below turn on exactly that.
  - HTTP/3 and QUIC: `./scripts/test-http3-interop.sh all`,
    `./scripts/test-http3-h3spec.sh`, `./scripts/test-http3-stress.sh`, plus
    `flyology_quic/scripts/test.sh` and `flyology_quic/scripts/prove.sh` for the transport
    crate. The QUIC test script refuses the default runtime and needs the one
    `./scripts/test.sh` prepares under `build/rts`, passed as `FLYOLOGY_QUIC_TEST_RTS`.
  - Client: `./scripts/http-client-differential.sh prepare` then `run` (Ada versus PycURL),
    and `./scripts/http-client-conformance.sh`.
  - Anything touching the SSE lifecycle: `./scripts/check-sse-client-formal.sh`. It needs a
    Java runtime and the `flyology-tla` CLI, and it could NOT be run during this review, so
    treat it as unverified ground until someone runs it.
  - WebSocket: `./scripts/websocket-conformance.sh <profile> <lane>` for the profiles under
    `tests/autobahn/`. The run refuses a dirty worktree; commit or stash first, or run from
    a clean worktree at the same commit.
  - IRI: `flyology_iri/scripts/test.sh` with `ADA_URL_ROOT` pointing at the pinned WPT
    corpus (ada-url/ada `32dabc8d`), and `flyology_iri/scripts/wpt-gate-test.sh`.
  - Anything touching the test hooks: `./scripts/check-test-hook-elision.sh`.
  - Public specification or API-documentation changes: `./scripts/docs.sh`, which must
    generate `docs/api/index.html` without errors.
  - Always: `git diff --check` and the maintained formatter project on touched handwritten
    Ada. Never hand-edit generated Ada; the only generated sources here are the SSE
    conformance adapter under `formal/sse_client/ada/generated`.
- Alire redeploys into one shared cache on every command, so two `alr` invocations must
  never run concurrently across lanes. The suites bind fixed loopback ports and start
  Python peers, so suite runs must be serialized too. Any new probe binds an ephemeral port.
- Do not widen scope. An issue that asks for a one-line guard gets a one-line guard.
- Items tagged **DECISION** need a maintainer choice before implementation. Ask; do not
  guess. Under "Decision authority" and "Ada interface values", authorization to fix a
  defect does not authorize a new public constant, default, capacity, timeout, retry count,
  buffer bound, variant or parameter.
- Items tagged **MODEL FIRST** get their model or contract before their code change. See
  the section below.

## Confirm every finding before fixing it

The issues were written by a reviewer, not by the maintainer. Each one was reproduced on
macOS 26.6.2 arm64 with GNAT via Alire. Before you change code:

1. Re-read the cited code at current `main`. Line numbers drift.
2. Rebuild and run the spike the issue quotes. If it no longer reproduces, say so on the
   issue and stop; do not fix what is already fixed, and do not weaken the spike to make it
   reproduce.
3. Where the issue rests on what another implementation does, drive the real peer if a
   maintained script provides one. Several issues say "not verified against a peer" in
   place; those claims are reading, and if driving the peer contradicts the issue, that is
   a finding of its own and goes back to the master task.
4. Peer claims that WERE established: the pinned `h2` 4.3.0 peer sends
   `SETTINGS_ENABLE_PUSH = 0`; stock curl 8.7.1 with nghttp2 1.68.1 gets a GOAWAY on a
   20 KiB HTTP/2 POST; `golang.org/x/net@v0.57.0/http2/server.go:1218-1235` sends
   `RST_STREAM(NO_ERROR)` after a response; quic-go 0.54.1 frames one DATA frame per
   `Write` and does send STOP_SENDING in ordinary use. Those are quoted with file:line in
   the issues that use them.
5. Two issues reason about browser behaviour. No browser was driven in this review. Neither
   rests its severity on the browser claim, and neither should be fixed on that basis alone.

## Work organization: one master task, lanes of at most three

- One master task owns the queue, the layer order and every DECISION. Lanes do not talk to
  each other; they report to the master after every merged pull request.
- At most three lanes at a time, each in its own git worktree. More than three contend on
  the shared Alire cache and on loopback ports, and the wall-clock gain disappears.
- Serialize every `alr` command and every suite run across lanes. A lane that needs the
  Docker peers (h2spec, Autobahn) takes them exclusively.
- A lane that hits a DECISION stops on that issue and moves to the next one in its layer.
  It does not choose a value, a default or a public name.
- A lane that finds an issue wrong reports it to the master rather than closing it.

## Model first: contracts and models where they pay for themselves

This is the "TLA+ assurance" section of `AGENTS.md` applied to this queue.

- **Inside the proved policy boundary**, the fix is the contract. The units
  `./scripts/prove.sh` proves are listed in that script; several findings sit in the
  unproved code that consumes a proved classifier, and for those the right move is often to
  widen the classifier's postcondition so the consuming code cannot get it wrong, rather
  than to add another check in the consumer. Note that two units a reviewer assumed were
  proved are not: `flyology-http-sse_client_policy` has no `SPARK_Mode` and is absent from
  `scripts/prove.sh`. Check the script rather than assuming.
- **The existing SSE model** in `formal/sse_client/` covers the reconnect lifecycle and its
  adapter wraps `SSE_Client_Policy` one to one. The SSE cancellation finding touches the
  wait state that model describes, so extend the model and its trace rather than only
  patching the Ada. Its gate could not be run in this review, so the first lane to touch it
  should run `./scripts/check-sse-client-formal.sh` and report whether it is green before
  changing anything.
- **New bounded TLA+ models**, each with a `_broken` configuration that must fail, for the
  three multi-step state machines this queue keeps tripping over:
  1. **HTTP/2 stream state and flow control together.** Six findings are about the
     interaction, not either half: the window announced before the peer can have read the
     SETTINGS, a stream completed early leaving input uncredited, a cancel mid field
     section pinning the pump, and a reset stream's window accounting. A model whose state
     is (stream state, connection window, stream window, pending field section) and whose
     invariant is that a conforming peer is never failed would have caught them as a class.
  2. **The client pool lease lifecycle.** Admission, release, stale retry, replay
     eligibility and finalization, with the invariant that every lease is released exactly
     once and that a replayed request never sends a partly consumed body. Three findings
     live there, including the silent double POST.
  3. **QUIC recovery and packet-space transitions.** The sent-packet ledger, the congestion
     window, the PTO path and key discard, with the invariants that a full ledger never
     escalates to a connection error and that Initial keys are unusable after the handshake
     completes. Three findings live there.
  Run TLC and TLAPM both, and replay the traces through the shared `flyology-ada/tla`
  harness, as the "TLA+ assurance" section requires.
- **Do not model** the single-site fixes: a wrong error code, a missing `Vary` header, a
  citation correction. A model there costs more than it returns.

## Layer order

The layers below put the surfaces a hostile peer reaches first. Within each layer, P0
before P1 before P2.

One caveat the master should weigh before starting: **all five P0 findings sit in layers 2
and 3**, not in layer 1. A queue optimised for severity rather than for attack surface
would run layers 2 and 3 first. The order below is the proposal; the master decides.

## Layer 1 - HTTP/1 server, routing and middleware

The surface a plain TCP peer reaches without negotiating anything: the HTTP/1.1
connection engine, request-head and chunk parsing, the router, and the middleware chain
that CORS, rate limits, metrics and the error responder hang from. No P0 sits here; the
three P1 items are an escaping `Program_Error` that drops the connection with no response
(#57), an over-segmented target that bypasses the middleware chain and
automatic admission (#62), and a rejected `Respond` that makes the
errors middleware close instead of writing its 500 (#63). One ordering
constraint: #57 and #60 both change how a parsing or
admission rejection reaches a status in `Connection_Handlers.Serve` and
`Dispatch_Configuration`, so one lane should take both, #57 first, and
both carry a maintainer decision about the same vocabulary.

- **#57** (P1) Raise `Protocol_Error` rather than `Program_Error` for the three peer-chosen refusals, leaving the two application-fault raises alone.
  Depends on: nothing. **DECISION** which status each peer-chosen refusal answers with.
- **#62** (P1) Turn a segmentation failure into the same invalid-path result the decode failure produces, so `Run_Automatic` answers it.
  Depends on: nothing.
- **#63** (P1) Narrow the blanket handler so a rejected `Respond` marks the exchange `Failed` only once the wire response has started.
  Depends on: nothing.
- **#58** (P2) Consume one leading `CRLF` before the head is inspected, in one place both the head inspector and the reader see.
  Depends on: nothing.
- **#59** (P2) Trim SP and HTAB at both ends of the chunk-size and extension name and value slices, leaving quoted strings intact.
  Depends on: nothing.
- **#60** (P2) Distinguish the unknown-transfer-coding rejection from the general malformed-request case so the handler can answer 501.
  Depends on: #57. **DECISION** how the rejection vocabulary carries a status out of the parser.
- **#61** (P2) Record the deliberate refusal of a mismatched absolute-form authority in the server specification and the matching guide page.
  Depends on: nothing. **DECISION** whether the refusal stands or the `Host` field is ignored as RFC 9112 asks.
- **#64** (P2) Require `:path` to be `*` or to begin with `/` in the HTTP/2 admission check, matching the HTTP/3 policy exactly.
  Depends on: nothing.
- **#65** (P2) Bound the method component of the metrics series key, and give the filled table a replacement rule.
  Depends on: nothing. **DECISION** which methods share a fixed key and whether the table evicts.
- **#66** (P2) Emit `Vary: Origin` for every response on a route with a non-wildcard CORS policy, before the three early returns.
  Depends on: nothing.

## Layer 2 - HTTP/2

The HTTP/2 server engine, the client session, HPACK and the settings, frame and policy
units they consume. Two P0 items: a client that fails the connection on a setting RFC 9113
permits, which breaks every origin built on python-hyper h2 (#67), and a server
that enforces its reduced stream window before the peer can have read the SETTINGS that
announced it (#68); the four P1 items are a discarded response body after
`RST_STREAM(NO_ERROR)` (#69), a cancel mid field section that freezes the client
pump (#70), a route body limit that can never answer 413 (#71), and a
missing HPACK dynamic table size update (#72). Two ordering constraints:
#69 must land before #76, or the server change breaks this
repository's own client against itself; and #67 and #73 both turn on
the two `Settings.Apply` call sites that discard the applied result, so one lane should
take both.

- **#67** (P0) Test the value rather than the peer role in the `ENABLE_PUSH` guard, and remove the workaround from both maintained Python peers.
  Depends on: nothing.
- **#68** (P0) Start each stream at the protocol default window, and answer a stream-window overshoot with `RST_STREAM` instead of a connection error.
  Depends on: nothing. **DECISION** what window is advertised and how the per-stream input buffer is bounded. **MODEL FIRST** HTTP/2 stream state and flow control. **PROOF** `Flyology.HTTP.HTTP_2_Policy`, if the window arithmetic changes there.
- **#69** (P1) Leave a stream whose response already completed alone in `Reset_Stream`, so buffered body bytes still reach the caller.
  Depends on: nothing. **DECISION** whether the test is on stream phase, on the error code, or on both.
- **#70** (P1) Admit the pinned header slot regardless of phase in the client's `Pull_Output`, so the field section finishes and the pin clears.
  Depends on: nothing. **MODEL FIRST** HTTP/2 stream state and flow control.
- **#71** (P1) Exclude `Body_Limit_Failure` from the failure test in `Queue_Response_Head`, so an over-limit stream can still answer 413.
  Depends on: nothing. **DECISION** how the over-limit condition is carried without a new failure variant.
- **#72** (P1) Emit the RFC 7541 dynamic table size update from both `Encode_Head` entry points once a lowered table size is acknowledged.
  Depends on: nothing. **DECISION** what maximum the encoder signals and how the value reaches `Encode_Head`.
- **#73** (P2) Pass `Flow_Control_Error` through at both `Settings.Apply` call sites when `Apply` reports it, instead of defaulting to `Protocol_Error`.
  Depends on: nothing.
- **#74** (P2) Test for an idle stream before a zero-increment `WINDOW_UPDATE` is rejected, and stop `Reject_Stream` advancing `Last_Client_Stream`.
  Depends on: nothing. **DECISION** whether the idle test lives at the call site or in the stream controller. **MODEL FIRST** HTTP/2 stream state and flow control.
- **#75** (P2) Charge closed-stream credit without queueing `RST_STREAM` when the server itself reset the stream, including after the slot is reaped.
  Depends on: nothing. **MODEL FIRST** HTTP/2 stream state and flow control.
- **#76** (P2) Reset an early-answered stream with `NO_ERROR`, or keep it draining, so its input count returns to the connection window.
  Depends on: #69. **DECISION** whether the server aborts or drains a request body it will not read. **MODEL FIRST** HTTP/2 stream state and flow control.
- **#77** (P2) Report an idle-stream `RST_STREAM` or `WINDOW_UPDATE` to the frame handler so it reaches `Protocol_Failure`, and suppress the second reset.
  Depends on: nothing. **DECISION** whether the idle test adds a result parameter or moves to the two call sites. **MODEL FIRST** HTTP/2 stream state and flow control.

## Layer 3 - HTTP/3, QPACK and the QUIC transport

The largest layer: the HTTP/3 server and client, QPACK, and the `flyology_quic` transport
and TLS crate underneath them. Three P0 items, one per crate boundary: a request body over
roughly 15 KiB that never completes because no MAX_STREAM_DATA is sent
(#78), a frame larger than the reassembly window that can never be
consumed (#79), and a server with no anti-amplification limit that also
accepts undersized client Initial packets (#92). Twelve P1 items
follow, from the field-section limit that closes the connection on a 33-field request
(#80) to the TLS secrets that outlive the handshake (#103).
Three ordering constraints: #78 and #79 both turn on the
same 16,384-byte figure, once as a transport default and once as a compile-time reassembly
bound, so their decisions should be taken together; #86 shares
`Return_Request_Credit` with #78; and #99 must not
land before #92, because padding the server's Initial is what makes
the missing byte budget reachable. More of this layer sits inside proved units than any
other, so lanes here run `./scripts/prove.sh` with `FLYOLOGY_PROOF_LEVEL=2` routinely.

- **#78** (P0) Return request credit from the `Data_Received` branch as well, and answer an oversized request with STOP_SENDING rather than silence.
  Depends on: nothing. **DECISION** at what rate an in-progress body earns credit, and whether the advertised window changes.
- **#79** (P0) Consume a DATA frame's payload in pieces so the reassembly base advances, and report an oversized declared length as a resource error.
  Depends on: nothing. **DECISION** where the frame-length ceiling and the reassembly bound live. **PROOF** `Flyology.HTTP.HTTP_3_Frame_Policy`, `Flyology.HTTP.HTTP_3_Stream_Receive_Policy` and `Flyology.QUIC.Stream_Reassembly_Policy`.
- **#92** (P0) Credit received and sent bytes per connection, gate output at three times received while the address is unvalidated, and refuse short Initial datagrams.
  Depends on: nothing. **MODEL FIRST** QUIC recovery and packet-space transitions.
- **#80** (P1) Give the QPACK retention bounds a status the server answers with 431, and advertise a field-section limit in the server's settings.
  Depends on: nothing. **DECISION** where the advertised field-section limit lives, and whether a new public status variant is added. **PROOF** `Flyology.HTTP.QPACK_Field_Section_Policy` and `Flyology.HTTP.HTTP_3_Stream_Receive_Policy`.
- **#81** (P1) Drop the client-role guard in `Release_Message` so a cancelled server response releases its send slot.
  Depends on: nothing.
- **#82** (P1) Send GOAWAY and a QUIC application close before `Cleanup`, on both the retirement path and the cancellation path.
  Depends on: nothing. **DECISION** how long the server waits between the GOAWAY and the close.
- **#83** (P1) Answer the raising statuses with a stream-scoped reset inside the event loop, and close the connection on every remaining path.
  Depends on: #82. **DECISION** how the eight request slots relate to the advertised bidirectional stream limit.
- **#84** (P1) Raise `Max_Encode_Length` to what the public field bounds imply, and frame a large field section across several QUIC stream writes.
  Depends on: nothing. **DECISION** the value of `Max_Encode_Length` and whether it stays visible. **PROOF** `Flyology.HTTP.QPACK_Field_Section_Policy`.
- **#85** (P1) Compute each stream's receive limit from what its own reader has consumed, and skip a stream whose ring is full.
  Depends on: nothing. **DECISION** how per-stream headroom crosses the public QUIC interface. **PROOF** `Flyology.QUIC.Receive_Flow_Control_Policy`.
- **#86** (P1) Count retired streams rather than dispatched requests, and return request credit from the `Stream_Reset` branch as well.
  Depends on: #78. **DECISION** the rate at which a peer reset refills the advertised stream limit.
- **#93** (P1) Let `Can_Send` decide first and report a full ledger as blocked rather than as a transport error; reserve one entry for probes.
  Depends on: nothing. **DECISION** the value and visibility of `Max_Sent_Packets`. **MODEL FIRST** QUIC recovery and packet-space transitions. **PROOF** `Flyology.QUIC.Sent_Packet_Policy` and `Flyology.QUIC.Recovery_Policy`.
- **#94** (P1) Record the Initial key discard in the driver, and drop a long-header Initial packet unparsed once the handshake has moved on.
  Depends on: nothing. **MODEL FIRST** QUIC recovery and packet-space transitions.
- **#95** (P1) Ignore post-handshake CRYPTO on the client, keeping `Unexpected_TLS_Message` only for the KeyUpdate case at offset 0.
  Depends on: nothing. **DECISION** whether a 1-RTT CRYPTO reassembly buffer is added, and what bounds it.
- **#96** (P1) Clamp or reject `Transport_Settings` fields that exceed what the reassembly ring and the stream table can honour.
  Depends on: nothing. **DECISION** where the implicit reassembly ceiling lives and what the accepted range is. **PROOF** `Flyology.QUIC.Stream_Reassembly_Policy` and `Flyology.QUIC.Stream_Table_Policy`, if the capacity moves into them.
- **#103** (P1) Clear the handshake, master, exporter and traffic secrets at both success transitions, and wipe the session when the connection is released.
  Depends on: nothing. **DECISION** how the wipe reaches `Session` at finalization.
- **#87** (P2) Extend the stream-local `Message_Error` and `Header_Error` branch to the server role, so a malformed request resets one stream.
  Depends on: #80. **DECISION** whether the server answers with an HTTP status before resetting the stream.
- **#88** (P2) Exempt a zero-length DATA frame from the `Body_Allowed` rejection, and make one layer the authority on content-forbidding statuses.
  Depends on: nothing. **DECISION** which layer wins on 205. **PROOF** `Flyology.HTTP.HTTP_3_Message_Policy`.
- **#89** (P2) Accept Set Dynamic Table Capacity 0 and read Delta Base, refusing only the conditions RFC 9204 actually states.
  Depends on: nothing. **PROOF** `Flyology.HTTP.HTTP_3_Stream_Receive_Policy` and `Flyology.HTTP.QPACK_Field_Section_Policy`.
- **#90** (P2) Abandon a malformed message unconditionally, by consuming its bytes or aborting the transport read rather than through the tombstone table.
  Depends on: #87. **DECISION** the capacity of the tombstone table and where it lives.
- **#91** (P2) Drop the interim and 204 clauses from the `content-length` check, leaving the content-forbidding rule to the message policy.
  Depends on: #88. **PROOF** `Flyology.HTTP.HTTP_3_Header_Policy`.
- **#97** (P2) Record a validated STOP_SENDING, move the send side to Reset Sent, schedule RESET_STREAM, and surface the cancellation upward.
  Depends on: nothing. **DECISION** how the stream identifier and error code reach the layer above. **PROOF** `Flyology.QUIC.Application_Frame_Policy` and `Flyology.QUIC.Receive_Flow_Control_Policy`, if the change reaches them.
- **#98** (P2) Record a received PATH_CHALLENGE and emit PATH_RESPONSE in the next outgoing packet, and accept a PATH_RESPONSE rather than dropping it.
  Depends on: nothing. **DECISION** how many pending challenges an endpoint remembers. **PROOF** `Flyology.QUIC.Application_Frame_Policy`.
- **#99** (P2) Pad the server's ack-eliciting Initial to 1,200 bytes, or coalesce it with the first Handshake packet.
  Depends on: #92.
- **#100** (P2) Consume the whole ACK frame while retaining the newest ranges, and report that outcome as success rather than a transport error.
  Depends on: nothing. **DECISION** the value and visibility of `Max_Ranges`. **PROOF** `Flyology.QUIC.ACK_Range_Policy`.
- **#101** (P2) Compare the peer's connection-ID transport parameters with the identifiers on the wire in `Initialize_Application`, closing with 0x08 on a mismatch.
  Depends on: nothing.
- **#102** (P2) Add the null-backend guard the query functions already use to each packet-driven operation, returning `Invalid_State`.
  Depends on: nothing. **DECISION** a body guard or a precondition on the public operations.
- **#104** (P2) Search the recorded ALPN entries for the configured protocol instead of testing only the first one.
  Depends on: nothing. **DECISION** how many entries `Parse_Result` carries and whose preference order wins. **PROOF** `Flyology.QUIC.TLS_Extension_Policy`.
- **#105** (P2) Map certificate, signature and Finished failures to their TLS alert codes at all three sites, through one shared mapping.
  Depends on: nothing. **DECISION** whether a missing required extension gets its own `Parse_Status` literal. **PROOF** `Flyology.QUIC.TLS_Handshake_Policy` and `Flyology.QUIC.TLS_Extension_Policy`.

## Layer 4 - HTTP client, connection pool and client TLS

The outbound side: the HTTP/1 response parser, the exchange engine, the redirect and
expectation paths, and the connection pool with its leases. No finding in this queue lands
in client TLS itself. No P0; the five P1 items are the response `Content-Length` ceiling
and the `Character'Pos` accumulation behind it (#106,
#108), a negative expectation wait that sends the body immediately
(#107), a same-origin redirect whose query contains `://`
(#113), and the silent second POST after a late 417
(#114). Ordering inside the layer: #106,
#108 and #112 are one widening of the same arithmetic in
the same private record, so one lane takes all three with #106 first;
#119 lands before #118, which otherwise inherits the
same hole; and #116 is settled by whatever #114 and
#115 do with the proved classifiers.

- **#106** (P1) Widen the HTTP/1 response length arithmetic to `Flyology.HTTP.Body_Size` in `Parse_Natural`, `Content_Length` and the private `Response_Data` fields.
  Depends on: nothing.
- **#107** (P1) Select the remaining exchange budget, or clear the deadline, when `Continue_Wait` is negative, in both branches that arm the wait.
  Depends on: nothing.
- **#108** (P1) Accumulate the digit value rather than `Character'Pos` in `Parse_Natural`, binding it once so the guard and the accumulation agree.
  Depends on: #106.
- **#113** (P1) Select the absolute-URI redirect branch with the anchored `Has_URI_Scheme` test instead of the unanchored `://` scan.
  Depends on: nothing.
- **#114** (P1) Track whether any content byte left the exchange, feed it into `Classify_Expectation_Response`, and return a late 417 to the caller.
  Depends on: nothing. **DECISION** how the wrapper observes body-sent, and whether the retry requires a rewindable source. **MODEL FIRST** the client pool lease lifecycle. **PROOF** `Flyology.HTTP.Client_Policy`, if its contract changes.
- **#109** (P2) Evaluate the `close` token first and fall back to the version rule when setting `Reusable`.
  Depends on: nothing.
- **#110** (P2) Allow the terminator's width in the incomplete-head bound, at both copies, so the two checks bound the same quantity.
  Depends on: nothing. **DECISION** where the incomplete-head bound sits relative to `Default_Max_Bytes`.
- **#111** (P2) Consult `Pending_Result` in `Receive_Content_Step`, and abandon the transport once the discarded count passes a bound.
  Depends on: nothing. **DECISION** what that drain bound is and where it is visible.
- **#112** (P2) Widen `Chunk_Size` and `Chunk_Remaining` to `Flyology.HTTP.Body_Size`, so the pending-length comparison is evaluated at 64 bits.
  Depends on: #106, #108.
- **#115** (P2) Give the engine retry and the wrapper retry one shared budget, and bound the pre-handoff branch explicitly.
  Depends on: nothing. **DECISION** what "retried once" counts, and what the documented bound then means. **MODEL FIRST** the client pool lease lifecycle. **PROOF** `Flyology.HTTP.Client_Policy`, if `Classify_Stale_Retry` becomes the single decision point.
- **#116** (P2) Restore the four classifiers' callers or delete them, and add a caller invariant for that specification to `scripts/test.sh`.
  Depends on: #114, #115. **DECISION** restore the callers, or delete the dead functions and correct `proof/proof-status.md`. **PROOF** `Flyology.HTTP.Client_Policy`. **NO REPRO** dead code, documentation.
- **#117** (P2) Classify a stopping pool as `Client_Unavailable` on the HTTP/3 path, covering the `Pool.Install` and `Publish_Connecting` routes too.
  Depends on: nothing. **NO REPRO** race not spikeable.
- **#118** (P2) Retire a non-null `Reply_Data` through `Abandon_Response` and the retention release, each guarded, before `Exchange_Operation.Finalize` frees it.
  Depends on: #119. **DECISION** whether a new barrier point is added so the fix can be tested. **NO REPRO** no barrier point.
- **#119** (P2) Wrap the three calls in `Abandon_Response`'s HTTP/2 branch in their own handlers, and retry the lease return in `Response.Finalize`.
  Depends on: nothing. **DECISION** whether a test-only fault-injection seam is added to the HTTP/2 session. **MODEL FIRST** the client pool lease lifecycle. **NO REPRO** needs injection seam.

## Layer 5 - WebSocket and SSE

The two long-lived streaming surfaces: the WebSocket client and the server upgrade path,
and the SSE serialisers on all three HTTP versions with the reconnecting SSE client. No P0;
the five P1 items are a control-frame bound that ends a healthy keepalive session
(#120), a `Close` drain that raises an exception its contract omits
(#121), a dropped trailing line terminator on HTTP/2 and HTTP/3
(#124), two sink failures that reach the caller as the wrong exception
(#125), and a cancellation token that does not interrupt the reconnect wait
(#126). #126 touches the wait state the existing `formal/sse_client/`
model describes, so its lane runs `./scripts/check-sse-client-formal.sh` and reports whether
that gate is green before changing anything; the model and its trace are extended with the
Ada. #124 touches all three backends at once, so it should not run beside another
SSE change.

- **#120** (P1) Clear `Control_Count` in `Receive` whenever a complete message is returned and whenever the loop is idle with nothing buffered.
  Depends on: nothing.
- **#121** (P1) Give the close drain the bound the last `Receive` used, and name the two reachable exceptions in `Close`'s documentation.
  Depends on: nothing. **DECISION** whether the bound is a `Close` parameter or a value retained on `Client`.
- **#124** (P1) Append the missing trailing-terminator branch to the HTTP/2 and HTTP/3 data loops, or share one serialiser across the three backends.
  Depends on: nothing.
- **#125** (P1) Re-raise the identity preserved in `Failure_Cause` for a `Response_Sink_Failed` result, in the engine or in the SSE layer.
  Depends on: nothing.
- **#126** (P1) Cancel the reconnect wait's `Read_Operation` when the token is requested, so the armed timer child is cancelled.
  Depends on: nothing.
- **#122** (P2) Send the RFC 6455 Close frame before dropping the transport on a detected protocol failure, guarded and written under a deadline.
  Depends on: nothing. **DECISION** what deadline that failure Close is written under.
- **#123** (P2) Skip an empty candidate in `Header_Has_Exact_Token` instead of passing it to `Validate_Token`.
  Depends on: nothing.

## Layer 6 - IRI, lifetime and repository gates

The `flyology_iri` crate and the repository's own integrity gates: the check that no client
unit declares a helper task, and the specification sentences that claim Ada enforces a token
borrow. No P0; the three P1 items are a relative reference that can set the host
(#127), a check that fails open and passes five kinds of violating source
(#131), and two `.ads` sentences that are false as written
(#132). The layer is independent of every other one and can run in parallel
with them, with one exception: #131 changes `scripts/test.sh`, which every
other lane runs as its gate, so it should land between merges rather than beside them.
#133 is the HTTP/3 sibling of a layer 4 finding and follows it.

- **#127** (P1) Build the resolved reference from components, or emit the `/.` guard, so a dot-reduced path beginning with `//` cannot become an authority.
  Depends on: nothing. **DECISION** whether a URI-mode serialization may carry the `/.` guard.
- **#131** (P1) Drop the undeclared `rg` dependency for `grep -REi`, widen the file set to the client closure, and reject `Task_Scopes` instantiations.
  Depends on: nothing. **DECISION** whether a declaration split across lines is covered or declared out of scope.
- **#132** (P1) Correct the two sentences, check the token in `Configure`, or stop returning `'Unchecked_Access`; the body proposes no single direction.
  Depends on: nothing. **DECISION** which of the three, since each promises something different in the specification.
- **#128** (P2) Reject code points above 16#10FFFF# and overlong forms in `To_ASCII`, or substitute U+FFFD as the WHATWG algorithm says.
  Depends on: nothing.
- **#129** (P2) Fail an IPv4-in-IPv6 part that has a leading zero or a fourth digit, as the WHATWG IPv6 parser does.
  Depends on: nothing.
- **#130** (P2) Reject a label beginning with a combining mark, and settle NFC separately; document whichever gap remains.
  Depends on: nothing. **DECISION** whether NFC is implemented, restricted away, or documented as absent.
- **#133** (P2) Give the HTTP/3 branch of `Abandon_Response` the guarded `Release_Pump`, `Cancel_Stream` and `Release_Stream` sequence.
  Depends on: #119. **NO REPRO** no observable difference.

## Explicitly out of scope

Issue #11, "flyology_iri: Slice copies the whole reference on every component access,
making Resolve allocation-heavy", is the repository's only open issue and carries the
`enhancement` label. It reports that the private `Slice` helper materializes the whole
serialized reference for every component access, so each public component getter is
O(reference length) and `Resolve` pays that cost repeatedly; the author states it is not
benchmarked. It is a performance report, not a correctness finding, and nothing in the
queue above fixes it. #127 changes `Resolve` and one of its options removes the
recomposition round trip entirely, so the lane that takes it should read #11 first and
still leave the performance work out of its branch.

There are no open pull requests on the repository.
