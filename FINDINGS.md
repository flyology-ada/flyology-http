# Flyology HTTP correctness review: findings

Commit reviewed: `f078732` on `main`, 2026-09-22.
Crates: `flyology_http` (`src/`, about 53,000 lines in 159 files), `flyology_quic`
(`flyology_quic/src/`, about 20,000 lines), `flyology_iri` (`flyology_iri/src/`, about
3,800 lines).

**Confirmed: 77. 5 P0, 32 P1, 40 P2.** Four further findings were folded into a primary as
duplicates, and two adversarial probes refuted a suspected defect class.

## Scope and method

Twelve subsystem reviews, each read-only and independent, then an adversarial verification
pass per area that tried to refute every candidate and reproduced every survivor as a
runnable program. Verification is authoritative where it disagrees with discovery: it
corrected several standard citations that were wrong or drawn from an obsoleted RFC, it
narrowed several claims, and it moved nine severities. A tenth finding was folded as a
duplicate during drafting, when two areas turned out to have reported one site.

The twelve areas: H1-SERVER, H1-CLIENT, ROUTING-MW, CLIENT-POOL, H2, H3-QPACK,
QUIC-TRANSPORT, QUIC-TLS, WEBSOCKET, SSE, IRI, LIFETIME.

Seventy-two of the 77 have a reproduction program under `tests/repros/`. The five that do
not are all P2, and each says in place why no reproduction was made. A program asserts the CORRECT behaviour, so on
current sources it prints `BUG REPRODUCED` and exits 1.

## Severity rubric

- **P0** memory or aliasing unsafety; security-relevant (request smuggling, header or
  response splitting, authentication or TLS-verification bypass, key or secret exposure,
  path traversal through decoded paths, a single hostile packet or frame that stalls or
  amplifies); silent corruption of request or response bytes; hang or deadlock in normal
  operation; or an interop-breaking protocol violation that a stock peer rejects.
- **P1** wrong result or unexpected exception on valid input via a reachable path, or a
  documented contract violated (`.ads` comment, README, guide pages, conformance documents
  under `tests/`).
- **P2** edge-case incorrectness, wrong diagnostics, or contract drift needing unusual input.

Documented policy values are not counted as defects unless they break a protocol rule or a
documented invariant. Those appear under each area's "Refuted and not counted".

## The previous audit, and the regression pass

This repository was audited once before. That report is `FINDGINGS_FABLE5.md`, dated
2026-08-07, 43 confirmed findings, all closed on `main`. It is not present at `main`: it
survives only on the `backup/pre-rewrite` branch, at commit `f0e8fd3`. It was recovered for
this review with `git show f0e8fd3:FINDGINGS_FABLE5.md` and is kept at
`review/prior-audit.md`.

A separate document, `proof/proof-status.md`, uses a different and older finding numbering
that predates the split of this repository from the runtime repository. The two numbering
schemes do not correspond.

**Regression pass result: no prior finding has regressed at `f078732`.** Every area
reviewer re-checked the prior findings in its own files before looking for anything new.
The `flyology_iri` crate carried eleven of the 43 and was checked finding by finding, by
reading code rather than by commit SHA, because the fixes landed as re-authored commits
that are not ancestors of HEAD.

Two items the previous audit flagged and could not settle were settled here **against** the
finding: `Must_Encode` placing `^` in the path percent-encode set, and `Encode_Opaque_Path`
handling a single trailing space, both match the pinned WPT corpus and are already covered
by the gate.

One of the previous audit's explicit coverage gaps was closed: the 257 HPACK Huffman
code and length constants were compared symbol by symbol against RFC 7541 Appendix B using
the pinned `hpack` package. **All 257 match** (`review/evidence/huffman_table_check.out`).

The previous audit also recorded that **nothing was executed except the `flyology_iri`
crate**, so its HTTP/1, HTTP/2, WebSocket and client findings rested on source reading. That
gap is closed here: every confirmed finding in those areas has a runnable reproduction.

`flyology_quic` was never covered by the previous audit at all. Eleven findings here,
including one P0, are in that crate.

## Baselines

Run from the review worktree at `f078732` before any review work, serialized, because
Alire redeploys into one shared cache.

| Suite | Result | Seconds |
| --- | --- | --- |
| `alr build` | PASS | 26 |
| `./scripts/test.sh` (includes the `flyology_iri` and `flyology_quic` suites) | PASS | 228 |
| `flyology_iri` WPT URL conformance, inside the above | 919/919, 0 mismatches | |
| `./scripts/prove.sh` at CI's `FLYOLOGY_PROOF_LEVEL=2` | PASS | 157 |
| `./scripts/prove.sh` at the script's default level 1 | 2 QUIC checks unproved | 139 |
| `./scripts/check-test-hook-elision.sh` | PASS | 159 |
| `./flyology_iri/scripts/wpt-gate-test.sh` | PASS | 2 |
| `./scripts/http2-test.sh prepare` then `all` | PASS | 394 |
| `./scripts/http2-test.sh h2spec` (h2spec 2.6.0, Docker) | PASS, 146/146 | 6 |
| `./scripts/http-client-differential.sh prepare` then `run` (PycURL) | PASS | 83 |
| `./scripts/http-client-conformance.sh` | PASS | 189 |
| `./scripts/test-http3-interop.sh all` (aioquic 1.3.0, quic-go 0.54.1, both roles) | PASS | 89 |
| `./scripts/test-http3-h3spec.sh` | PASS | 85 |
| `./scripts/test-http3-stress.sh` | PASS | 100 |
| Autobahn core, native | 240 OK, 4 NON-STRICT, 3 INFORMATIONAL, 0 failed | 127 |
| Autobahn core, lightweight | 240 OK, 4 NON-STRICT, 3 INFORMATIONAL, 0 failed | 105 |
| Autobahn limits, native | 42 OK, 0 failed | 111 |
| Autobahn compression, native | 180 OK, 36 UNIMPLEMENTED, 0 failed | 483 |
| `./scripts/check-sse-client-formal.sh` | **NOT RUN** | |

Notes on the three rows that are not a plain PASS.

- **`prove.sh` at level 1** leaves two `flyology_quic` checks unproved,
  `stream_reassembly_policy.adb:155` and `stream_table_policy.adb:231`, both reported as
  "provers reached time limit before completing the proof". CI runs the script with
  `FLYOLOGY_PROOF_LEVEL: "2"` (`.github/workflows/ci.yml:193`), where both discharge. This
  is a level difference, not a regression. It is worth noting only because the script's own
  default does not reproduce the gate CI runs.
- **Autobahn** refuses to run in a worktree with untracked files: its provenance guard
  (`scripts/websocket-run-provenance.mjs:167`) requires a clean worktree or the exact
  in-tree QUIC pin. The four profiles above were therefore run from a pristine detached
  worktree at the same commit. The full CI matrix is fourteen profiles including the `wss`
  and `performance` variants; four were run here.
- **`check-sse-client-formal.sh` could not run.** It requires a Java runtime and the
  `flyology-tla` CLI, and neither is installed on this machine (`/usr/bin/java` is the
  macOS stub). The SSE reconnect TLA+ model, its TLAPS proof and its Ada trace replay are
  therefore unexercised evidence in this review. Inspection concluded the model still sits
  on the production path after the composable rework, and the recorded source hash
  differing from the raw file hash is a normalisation rather than staleness, but that is
  reading, not a gate run.

The PycURL differential initially failed because its `prepare` step had not been run; it
passes with the environment prepared. That first failure was a harness mistake in this
review, not a defect.

## What was not exercised

- The SSE formal gate, as above.
- Ten of the fourteen Autobahn profiles, including every `wss` and `performance` variant.
- The Autobahn **client**-under-test role. The previous audit recorded that the WebSocket
  client had never been run in that role, and it still has not been. Three of the four
  WebSocket findings are client-side.
- No browser was driven. Two findings reason about browser behaviour; both say so in place
  and neither rests its severity on it.
- Peer behaviour was checked against pinned sources and pinned binaries only. Where an
  entry could not check a claim against a peer, it says "not verified against a peer".

## How to reproduce

```sh
./scripts/test.sh                      # once, to prepare build/rts
cd tests/repros
./run.sh <program> [seconds]           # one finding
./run-all.sh                           # every program, one line each
```

Exit 1 with `BUG REPRODUCED` is the expected result for a finding spike. Exit 0 is expected
for `repro_smoke`, `seam_check` and the two H1-SERVER probes. Exit 2 is expected for
`repro_lifetime_3b` and `repro_lifetime_3c`, which are negative controls that must fail to
compile. `tests/repros/README.md` has the details, including how to write a spike for a
private package.

The full sweep is recorded at `review/REPRO_SWEEP.txt`.

## Totals by area

| Area | P0 | P1 | P2 | Confirmed | Folded as duplicate | Refuted |
| --- | --- | --- | --- | --- | --- | --- |
| H2 | 2 | 4 | 5 | 11 | | |
| H3-QPACK | 2 | 7 | 5 | 14 | | |
| QUIC-TRANSPORT | 1 | 4 | 6 | 11 | | |
| H1-CLIENT | | 3 | 4 | 7 | | |
| CLIENT-POOL | | 2 | 5 | 7 | 1 | |
| QUIC-TLS | | 1 | 2 | 3 | 2 | |
| ROUTING-MW | | 2 | 3 | 5 | | |
| WEBSOCKET | | 2 | 2 | 4 | | |
| SSE | | 3 | 0 | 3 | | |
| LIFETIME | | 2 | 1 | 3 | 1 | |
| H1-SERVER | | 1 | 4 | 5 | | 2 probes |
| IRI | | 1 | 3 | 4 | | |
| **Total** | **5** | **32** | **40** | **77** | **4** | **2** |

Nine severities moved during verification, all but one upward: H1-SERVER-5, IRI-4,
LIFETIME-2, LIFETIME-3, QUIC-TLS-3, QUIC-TRANSPORT-5, ROUTING-MW-2 and WEBSOCKET-2 rose
from P2 to P1; H3-QPACK-3 fell from P0 to P1 because its trigger could not be checked
against a browser.

## The five P0 findings

- **H2-1** the client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0`,
  which RFC 9113 section 6.5.2 expressly permits. The pinned `h2` 4.3.0 peer sends it by
  default, and both Python peers in this repository delete the setting to work around the
  rejection.
- **H2-2** the server enforces its reduced 16 KiB stream window before the peer can have
  processed the SETTINGS that announced it. Stock `curl 8.7.1` with `nghttp2 1.68.1`
  POSTing 20 KiB gets a GOAWAY.
- **H3-QPACK-1** the server returns no per-stream receive credit while a request body is
  arriving, so an HTTP/3 upload stops permanently at 15,360 body bytes.
- **H3-QPACK-2** HTTP/3 frames are buffered whole against a 16 KiB reassembly bound that no
  configuration can raise, so a DATA frame above 16,381 bytes is never consumed. quic-go
  writes one DATA frame per `Write`.
- **QUIC-TRANSPORT-1** there is no RFC 9000 section 8.1 anti-amplification accounting
  anywhere in the crate, and no enforcement of the section 14.1 minimum on a received
  Initial. Measured: a 216-byte Initial draws 2,084 bytes, 9.64 times, with the
  repository's own test certificate.


## Index

| ID | Issue | Severity | Title | Location | Repro |
| --- | --- | --- | --- | --- | --- |
| H2-1 | #67 | P0 | Client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0` | `src/flyology-http-http_2_settings.adb:45-51` | `flyology-http-http_2_settings-repro_h2_1` |
| H2-2 | #68 | P0 | Server enforces its reduced 16 KiB stream window before the peer can have processed the SETTINGS that announced it | `src/flyology-http-server-http_2.adb:100-101` | `repro_h2_2` |
| H3-QPACK-1 | #78 | P0 | Server returns no per-stream receive credit while a request body is arriving | `src/flyology-http-server-http_3.adb:1637-1671` | `repro_h3_qpack_1` |
| H3-QPACK-2 | #79 | P0 | Whole-frame buffering against a 16 KiB reassembly window | `src/flyology-http-http_3_frame_policy.adb:72-81` | `flyology-http-http_3_stream_receive_policy-repro_h3_qpack_2` |
| QUIC-TRANSPORT-1 | #92 | P0 | No anti-amplification limit before address validation | `flyology-quic-connection_driver.adb:956-995` | `flyology-quic-connection_driver-repro_quic_transport_1` |
| CLIENT-POOL-1 | #113 | P1 | Same-origin relative redirect whose query contains `://` raises `Redirect_Error` | `src/flyology-http-client.adb:6301-6315` | `repro_client_pool_1` |
| CLIENT-POOL-2 | #114 | P1 | Synchronous 417 fallback retries after body transmission with a consumed, un-rewound source | `src/flyology-http-client.adb:6636-6647` | `repro_client_pool_2` |
| H1-CLIENT-1 | #106 | P1 | HTTP/1 response `Content-Length` of 2^31 or more is rejected as malformed | `src/flyology-http-client-http_1_internals.adb:151-168` | `flyology-http-http_3_header_policy-repro_h1_client_1` |
| H1-CLIENT-2 | #107 | P1 | A negative `Set_Expect_Continue` wait sends the body immediately | `src/flyology-http-client.adb:3767-3792` | `repro_h1_client_2` |
| H1-CLIENT-7 | #108 | P1 | a `Content-Length` of 2 147 483 600 .. 2 147 483 647 raises `Constraint_Error` out of the HTTP/1 response parser | see the area section | `repro_h1_client_7` |
| H1-SERVER-5 | #57 | P1 | Peer-chosen request shapes surface as `Program_Error`, escaping the documented `Protocol_Error` rejection channel | `src/flyology-http-server.adb:3933-3937` | `repro_h1_server_5` |
| H2-3 | #69 | P1 | Client discards a complete response when the server follows END_STREAM with `RST_STREAM(NO_ERROR)` | `src/flyology-http-http_2_client_connection.adb:1370-1387` | `repro_h2_3` |
| H2-4 | #70 | P1 | Client `Cancel_Stream` during a fragmented request field section pins the pump, then a non-CONTINUATION frame follows an unterminated HEADERS | `src/flyology-http-http_2_client_connection.adb:1625-1649` | `repro_h2_4` |
| H2-5 | #71 | P1 | A request body exceeding a route limit mid-stream can never receive the 413 over HTTP/2; the stream is reset with INTERNAL_ERROR | `src/flyology-http-server-http_2.adb:644-651` | `repro_h2_5` |
| H2-6 | #72 | P1 | HPACK encoder never emits the dynamic-table size update required after a peer lowers `SETTINGS_HEADER_TABLE_SIZE` | `src/flyology-http-http_2_settings.adb:43-44` | `flyology-http-http_2_requests-repro_h2_6` |
| H3-QPACK-3 | #80 | P1 | Receive-side field-section limits close the connection and are never advertised | `src/flyology-http-qpack_field_section_policy.adb:127-136` | `repro_h3_qpack_3` |
| H3-QPACK-4 | #81 | P1 | Server leaks one send slot per cancelled response | `src/flyology-http-http_3_connection.adb:624-677` | `repro_h3_qpack_4` |
| H3-QPACK-5 | #82 | P1 | Server never sends GOAWAY or CONNECTION_CLOSE at end of life | `src/flyology-http-server-http_3.adb:1897-1927` | `repro_h3_qpack_5` |
| H3-QPACK-6 | #83 | P1 | Exceptions other than Timeout_Error abandon the connection without a close | `src/flyology-http-server-http_3.adb:1901-1918` | `repro_h3_qpack_6` |
| H3-QPACK-7 | #84 | P1 | Send-side field sections are capped at 1,109 encoded bytes | `src/flyology-http-qpack_field_section_policy.ads:21` | `flyology-http-qpack_field_section_policy-repro_h3_qpack_7` |
| H3-QPACK-8 | #85 | P1 | Client raises MAX_STREAM_DATA for every stream from transport-level consumption | `src/flyology-http-client.adb:2517-2552` | `flyology-http-http_3_client_connection-repro_h3_qpack_8` |
| H3-QPACK-9 | #86 | P1 | Peer-reset request streams never refill MAX_STREAMS credit | `src/flyology-http-server-http_3.adb:1637-1663` | `repro_h3_qpack_9` |
| IRI-4 | #127 | P1 | `Resolve` recomposes a `//`-prefixed path without authority into an authority, and rewrites WHATWG opaque paths under a web base | `flyology_iri/src/flyology_iri.adb:1462-1469` | `repro_iri_4` |
| LIFETIME-2 | #131 | P1 | The "no helper task in client units" invariant check fails open and is evadable | `scripts/test.sh:75-84` | `repro_lifetime_2.sh` |
| LIFETIME-3 | #132 | P1 | Two `.ads` contracts claim Ada-enforced lifetime with no `compile_fail` case pinning them; `Request_Tasks` cancellation inheritance is untested | `src/flyology-http-server-request_tasks.ads:25-31` | `repro_lifetime_3, with controls repro_lifetime_3b/3c/3d` |
| QUIC-TLS-3 | #103 | P1 | Handshake, master, exporter and traffic secrets are never wiped after a successful handshake or on finalization | `flyology_quic/src/flyology-quic-tls_session.adb:790-791` | `flyology-quic-tls_session-repro_quic_tls_3` |
| QUIC-TRANSPORT-2 | #93 | P1 | The 64-entry ledger fails large transfers and refuses probes | `flyology-quic-application_space.adb:417-436` | `flyology-quic-connection_driver-repro_quic_transport_2` |
| QUIC-TRANSPORT-3 | #94 | P1 | Initial keys are never discarded; a forged Initial ends an established connection | `flyology-quic-connection_driver.adb:1382-1409` | `flyology-quic-connection_driver-repro_quic_transport_3` |
| QUIC-TRANSPORT-4 | #95 | P1 | A client fails on any post-handshake CRYPTO except one complete ticket at offset 0 | `flyology-quic-application_space.adb:1307-1349` | `flyology-quic-application_space-repro_quic_transport_4` |
| QUIC-TRANSPORT-5 | #96 | P1 | `Transport_Settings` are advertised unclamped against fixed reassembly bounds | `flyology-quic-connections.adb:176-201` | `repro_quic_transport_5` |
| ROUTING-MW-1 | #62 | P1 | A malformed-path 400 for more than 64 segments bypasses the global middleware chain and automatic admission | `src/flyology-http-server-routing.adb:1895` | `repro_routing_mw_1` |
| ROUTING-MW-2 | #63 | P1 | `Applications.Respond` marks the exchange `Failed` before any byte is written, so every Exchange-based 500 recovery path closes or resets instead of answering | `src/flyology-http-server-applications.adb:465-468` | `repro_routing_mw_2` |
| SSE-1 | #124 | P1 | HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator from event data that the HTTP/1.1 serialiser preserves | `src/flyology-http-server-http_2.adb:1966-1996` | `repro_sse_1` |
| SSE-2 | #125 | P1 | `Event_Too_Large` and `Reconnect_Delay_Too_Large` raised while the exchange streams into the sink are re-raised as `Invalid_Event_Stream` | `src/flyology-http-client.adb:3884-3891` | `repro_sse_2` |
| SSE-3 | #126 | P1 | A cancellation token does not interrupt the reconnect wait of the blocking `Read`, contrary to the `.ads` contract | `src/flyology-http-client-sse.adb:648-661` | `repro_sse_3` |
| WEBSOCKET-1 | #120 | P1 | Client `Receive` fails a healthy session after 32 control frames in one call | `src/flyology-http-websocket_client.adb:32` | `repro_websocket_1` |
| WEBSOCKET-2 | #121 | P1 | Client `Close` drains the peer close under the 1 MiB default bound, not the application's | `src/flyology-http-websocket_client.adb:1372-1374` | `repro_websocket_2` |
| CLIENT-POOL-4 | #115 | P2 | Synchronous safe-method exchanges can replay twice (engine retry plus wrapper retry) | `src/flyology-http-client.adb:925-957` | `repro_client_pool_4` |
| CLIENT-POOL-5 | #116 | P2 | Four proved `Client_Policy` classifiers have no production caller; `proof-status.md` still says they are consumed | `src/flyology-http-client_policy.ads:15-40,52-77,86-127,171-188`; | none (see entry) |
| CLIENT-POOL-6 | #117 | P2 | Shutdown racing HTTP/3 establishment reports `Transport_Failed`/`Device_Error` instead of `Client_Unavailable`/`Client_Closed` | `src/flyology-http-client.adb:4963-4969` | none (see entry) |
| CLIENT-POOL-7 | #118 | P2 | `Exchange_Operation.Finalize` frees a response-head `Reply_Data` without returning its lease or lifetime retention | `src/flyology-http-client.adb:1906-1940` | none (see entry) |
| CLIENT-POOL-8 | #119 | P2 | `Response.Finalize` exception path frees the lease record without returning the pool slot | `src/flyology-http-client.adb:7369-7404` | none (see entry) |
| H1-CLIENT-3 | #109 | P2 | An HTTP/1.0 response carrying both `close` and `keep-alive` is pooled | `src/flyology-http-client-http_1_internals.adb:410-418` | `repro_h1_client_3` |
| H1-CLIENT-4 | #110 | P2 | Heads of 16383-16384 bytes are accepted by the oracle but rejected on the live path | `src/flyology-http-client-http_1_internals.adb:363-381` | `repro_h1_client_4` |
| H1-CLIENT-5 | #111 | P2 | A composable buffer exchange drains an over-capacity body with no byte bound | `src/flyology-http-client.adb:3864-3908` | `repro_h1_client_5` |
| H1-CLIENT-6 | #112 | P2 | `Validate_Response` overflows on chunk sizes `7FFFFFFE`/`7FFFFFFF` (test oracle only) | `src/flyology-http-client-http_1_internals.adb:585-587` | `repro_h1_client_6` |
| H1-SERVER-1 | #58 | P2 | A stray CRLF before a request-line is rejected as malformed, and at EOF becomes a spurious 400 | `src/flyology-http-server.adb:1141-1162` | `repro_h1_server_1` |
| H1-SERVER-2 | #59 | P2 | Chunk-extension BWS is rejected although the chunk-ext grammar admits it | `src/flyology-http-server.adb:874-895` | `repro_h1_server_2` |
| H1-SERVER-3 | #60 | P2 | Oversized head, unknown transfer coding, CONNECT, and unsupported versions all collapse to 400 | `src/flyology-http-server.adb:1060` | `repro_h1_server_3` |
| H1-SERVER-4 | #61 | P2 | Absolute-form target with a differing Host is refused instead of Host being ignored | `src/flyology-http-server.adb:843-848` | `repro_h1_server_4` |
| H2-7 | #73 | P2 | `SETTINGS_INITIAL_WINDOW_SIZE` above 2^31-1 is reported as PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR | `src/flyology-http-server-http_2.adb:2422-2427` | `repro_h2_7` |
| H2-8 | #74 | P2 | Server answers `WINDOW_UPDATE(0)` on an idle stream with RST_STREAM on that idle stream and advances `Last_Client_Stream` | `src/flyology-http-server-http_2.adb:1217-1221` | `repro_h2_8` |
| H2-9 | #75 | P2 | Server sends RST_STREAM(STREAM_CLOSED) for every DATA frame on a closed stream, including streams it has already reset | `src/flyology-http-server-http_2.adb:618-631` | `repro_h2_9` |
| H2-10 | #76 | P2 | Server never resets a stream whose response completed while the request half is still open; its buffered input pins the connection window | `src/flyology-http-server-http_2.adb:419-428` | `repro_h2_10` |
| H2-11 | #77 | P2 | Client ignores RST_STREAM and WINDOW_UPDATE on idle streams and answers post-cancel in-flight frames with RST_STREAM(PROTOCOL_ERROR) | `src/flyology-http-http_2_client_connection.adb:1374-1378` | `repro_h2_11` |
| H3-QPACK-10 | #87 | P2 | Server treats malformed requests and empty request streams as connection errors | `src/flyology-http-http_3_connection.adb:426-440` | `repro_h3_qpack_10` |
| H3-QPACK-11 | #88 | P2 | Empty DATA frame on a HEAD, 204, 205 or 304 response is rejected | `src/flyology-http-http_3_message_policy.adb:113-117` | `flyology-http-http_3_message_policy-repro_h3_qpack_11` |
| H3-QPACK-12 | #89 | P2 | Legal QPACK inputs rejected | `src/flyology-http-http_3_stream_receive_policy.adb:169-174` | `flyology-http-http_3_stream_receive_policy-repro_h3_qpack_12` |
| H3-QPACK-13 | #90 | P2 | Stale Stream_Reset re-emission for malformed responses on stream IDs above 4092 | `src/flyology-http-http_3_connection.adb:426-440` | `repro_h3_qpack_13` |
| H3-QPACK-14 | #91 | P2 | 204 or 1xx with Content-Length is treated as malformed | `src/flyology-http-http_3_header_policy.adb:414-418` | `flyology-http-http_3_header_policy-repro_h3_qpack_14` |
| IRI-1 | #128 | P2 | Overlong and out-of-range UTF-8 in a percent-decoded special host decodes to a different host instead of failing | `flyology_iri/src/flyology_iri-web.adb:597` | `repro_iri_1` |
| IRI-2 | #129 | P2 | IPv4-in-IPv6 tail accepts leading zeros the WHATWG IPv6 parser rejects | `flyology_iri/src/flyology_iri-web.adb:477-518` | `repro_iri_2` |
| IRI-3 | #130 | P2 | IDNA applies no NFC normalization and no leading-combining-mark check, and the disclosure does not name either | `flyology_iri/src/flyology_iri-idna.adb:174-211` | `repro_iri_3` |
| LIFETIME-1 | #133 | P2 | Finalizing an unread HTTP/3 `Response` never cancels or releases its stream, unlike HTTP/2 and unlike the composable path | `src/flyology-http-client.adb:2151-2170` | none (see entry) |
| QUIC-TLS-4 | #104 | P2 | Server matches only the first ALPN entry of the ClientHello instead of selecting from the list | `flyology_quic/src/flyology-quic-tls_extension_policy.adb:220-224` | `flyology-quic-tls_session-repro_quic_tls_4` |
| QUIC-TLS-5 | #105 | P2 | TLS failures close with `internal_error` (0x150) and missing ALPN with `missing_extension` (0x16D) instead of the alerts the RFCs require | `flyology_quic/src/flyology-quic-connection_driver.adb:945-951` | `flyology-quic-connection_driver-repro_quic_tls_5` |
| QUIC-TRANSPORT-6 | #97 | P2 | STOP_SENDING is validated and dropped | `flyology-quic-application_space.adb:1392-1402` | `flyology-quic-application_space-repro_quic_transport_6` |
| QUIC-TRANSPORT-7 | #98 | P2 | PATH_CHALLENGE is parsed and ignored | `flyology-quic-application_frame_policy.adb:386-395` | `flyology-quic-application_space-repro_quic_transport_7` |
| QUIC-TRANSPORT-8 | #99 | P2 | The server's ack-eliciting Initial datagram is not expanded to 1,200 bytes | `flyology-quic-initial_space.adb:141-142` | `repro_quic_transport_8` |
| QUIC-TRANSPORT-9 | #100 | P2 | An ACK frame with 64 or more ranges closes the connection | `flyology-quic-ack_range_policy.adb:64-66` | `flyology-quic-application_space-repro_quic_transport_9` |
| QUIC-TRANSPORT-10 | #101 | P2 | Connection-ID transport parameters are never compared with the wire CIDs | the only uses of `Original_Destination_Connection_ID` and | `flyology-quic-connection_driver-repro_quic_transport_10` |
| QUIC-TRANSPORT-11 | #102 | P2 | packet-driven operations dereference an uninitialized connection | see the area section | `repro_quic_transport_11` |
| ROUTING-MW-3 | #64 | P2 | HTTP/2 `:path` beginning with `http://` or `https://` is routed as an absolute-form target; HTTP/3 and HTTP/1 reject or validate it | `src/flyology-http-server-routing.adb:283-314` | `repro_routing_mw_3` |
| ROUTING-MW-4 | #65 | P2 | Metrics series are keyed by the client-controlled request method with no eviction, so distinct method tokens pin the bounded series table | `src/flyology-http-server-metrics.adb:47-83` | `repro_routing_mw_4` |
| ROUTING-MW-5 | #66 | P2 | CORS middleware omits `Vary: Origin` on responses whose CORS headers depend on `Origin` but where none were added | `src/flyology-http-server-middleware_cors.adb:40-43` | `repro_routing_mw_5` |
| WEBSOCKET-3 | #122 | P2 | Client fails the connection with no Close frame on every protocol failure | `src/flyology-http-websocket_client.adb:1310-1321` | `repro_websocket_3` |
| WEBSOCKET-4 | #123 | P2 | Server refuses an upgrade whose `Sec-WebSocket-Protocol` list contains an empty element | `src/flyology-http-server.adb:3961-3973` | `repro_websocket_4` |

---

# Findings by area

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

## ROUTING-MW

Routing, dispatch and the middleware stack: `flyology-http-server-routing.adb/.ads`,
`flyology-http-server-applications.adb/.ads`, the ten `middleware_*` packages,
`flyology-http-server-cors.adb/.ads`, `flyology-http-server-metrics.adb/.ads`,
`flyology-rate_limit_policy`, `flyology-http-decoded_path_policy`,
`flyology-http-route_parameter_policy` and `flyology-http-server-native_routes`, plus the
`:path` and request-target admission sites in `flyology-http-server.adb`,
`flyology-http-server-http_2.adb` and `flyology-http-http_3_header_policy.adb` that feed
them. Tests read: `tests/http_routing_audit.adb`, `tests/http_smoke.adb`, and the three
policy smoke mains. Five findings, all CONFIRMED, all reproduced: two P1 and three P2. The
verification moved ROUTING-MW-2 up from P2 to P1 and corrected the standard citation on
ROUTING-MW-5 and the production name on ROUTING-MW-3. Nothing in this area was refuted, and
the regression check on the previously fixed routing and middleware findings found every fix
still present at `f078732`.

### ROUTING-MW-1: The 400 for a path with more than 64 segments bypasses the middleware chain and automatic admission

- **Severity:** P1 (discovery said P1; unchanged). A named `.ads` contract is violated on an
  input any peer can send on any protocol.
- **Location:** `src/flyology-http-server-routing.adb:1894-1895` (the `Split_Path` call),
  raise at `:399-401`, handler at `:2086-2090`; contract at
  `src/flyology-http-server-routing.ads:806-811`; contrast the handled decode failure at
  `:1828-1835`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_1` (exit 1, BUG REPRODUCED; re-run for
  the drafting pass, 6 checks, 2 failures).
- **What is wrong:** `Decode_For_Dispatch` converts a `Decode_Path` failure into
  `Invalid_Path := True` so the malformed-path 400 is written through
  `Run_Automatic ("flyology.bad_request")` and runs the whole global chain. `Split_Path` is
  called outside that function and raises its own `Route_Error` at `Max_Segments = 64`,
  which unwinds to the outermost handler and writes `X.Problem (400, ...)` directly with no
  `Configure_Route`, no `Seal_Route` and no pipeline. The spike's control arm, `/%2e%2e/x`,
  carries `X-Content-Type-Options: nosniff` and is answered 429 on the second request under
  `Set_Automatic_Admission (Rate_Per_Second => 1)`; a 130-byte, 65-segment target on the same
  router gets neither, and repeats indefinitely.
- **Notes:** No maintainer decision needed; the fix moves the failure onto the existing
  `Run_Automatic` path and `Max_Segments` does not change. No existing test asserts the wrong
  behaviour. `tests/http_routing_audit.adb:503`
  (`Check_Automatic_Response_Admission`) already builds the router, middleware and admission
  policy the regression test needs but covers only the five automatic responses that do go
  through `Run_Automatic`. Outside every unit `scripts/prove.sh` proves.

### ROUTING-MW-2: A rejected Respond marks the exchange Failed, so the errors middleware closes instead of writing its 500

- **Severity:** P1 (discovery said P2; **raised**). The rubric's P1 clause is a documented
  contract violated, with no qualifier that the trigger be ordinary input, and two `.ads`
  contracts are violated: `middleware_errors.ads:8-9` and `applications.ads:49`. The measured
  result is zero response bytes where a closing 500 is promised, in the one component whose
  documented purpose is to contain application faults. The discovery's reason for P2, that it
  needs an application-side defect, is recorded and outweighed, because containing
  application-side defects is the feature. Not P0: the connection closes cleanly, nothing is
  corrupted and nothing hangs.
- **Location:** `src/flyology-http-server-applications.adb:436-446` and `:465-468`; consumed
  at `src/flyology-http-server-middleware_errors.adb:52-65`; `Mark_Failed` at
  `src/flyology-http-server-applications.adb:1001-1010`; the post-handler close at
  `src/flyology-http-server-routing.adb:2065-2074`; the connection-level path that still
  answers at `src/flyology-http-server-routing.adb:2264-2275`; the connection-layer validation
  at `src/flyology-http-server.adb:2733-2739` with the commit point at `:2770`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_2` (exit 1, BUG REPRODUCED; re-run,
  4 checks, 4 failures).
- **What is wrong:** `Respond` validates before writing and then catches every exception in a
  blanket handler that sets `Response_Value := Failed`, so an exchange with nothing on the
  wire reports `Failed` instead of `Not_Started`. `Middleware_Errors.Call` tests exactly that
  state, takes the `X.Mark_Failed` branch, and the HTTP/1 client sees an empty reply: the
  spike measures **0 bytes written**. The verifier measured more than the discovery predicted:
  besides the missing 500, a fully written 200 is relabelled `FAILED` when a second `Respond`
  is rejected, and the next pipelined request on the keep-alive connection is never served
  (1 response observed where 2 are due). The sharpest framing, which is in the issue Summary:
  installing the documented safety net is what removes the safety, because HTTP/1 *without*
  the errors middleware still answers 500 through the connection-level `Respond`, which
  consults `Response_Begun` rather than the exchange state.
- **Notes:** No maintainer decision needed; the fix narrows an over-broad handler and adds no
  value or parameter. No existing test asserts the wrong behaviour:
  `tests/http_smoke.adb:2930-2942` covers a handler that raises *before* calling `Respond`
  (`Unexpected` at `:2804-2811`), which is the only shape that still reaches the 500 branch,
  and `:2944-2956` covers a failure after a stream started. Outside every proved unit.

### ROUTING-MW-3: HTTP/2 :path beginning with http:// is routed as an absolute-form target, unlike HTTP/3 and HTTP/1

- **Severity:** P2 (discovery said P2; unchanged). The area brief asked whether the severity
  must drop because RFC 9113 permits the absolute form in `:path`. It does not permit it, so
  nothing drops. It does not rise either: the input is malformed rather than valid, and
  `routing.ads:928-930` is a statement about dispatch, not about pseudo-header admission, so
  there is no clean `.ads` hook. Confidence rises from the discovery's *medium* to *high* for
  the mechanism and the standard.
- **Location:** `src/flyology-http-server-http_2.adb:2341-2349` (the only `:path` checks on
  the h2 admission path); `src/flyology-http-server-routing.adb:283-286` and `:295-309`
  (`Absolute_Form_Authority`, `Raw_Path`); contrast
  `src/flyology-http-http_3_header_policy.adb:299-304` and
  `src/flyology-http-server.adb:838-848`; the query split at
  `src/flyology-http-server-requests.adb:62-63`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_3` (exit 1, BUG REPRODUCED; re-run,
  5 checks, 2 failures). The only spike in this area that needs a real HTTP/2 connection; it
  binds with `Sockets.Any_Port` and reads the port back with `Sockets.Get_Socket_Name`.
- **What is wrong:** Nothing on the HTTP/2 admission path requires `:path` to be an
  `absolute-path`, so `http://localhost/admin/users` reaches `Raw_Path`, which strips the
  embedded authority, never compares it with `:authority`, and routes `/admin/users`. The
  spike exercises all three lanes: HTTP/2 serves it as `admin.users`; HTTP/1 answers 400 when
  the embedded authority conflicts with `Host` and 200 when it agrees; HTTP/3 rejects it as
  `Invalid_Path`. A second probe is sharper: `:path: http://localhost?x=1/admin` routes `/`
  while the query parameter `x` reads `1/admin`, because `Raw_Path` returns `"/"` on meeting
  `?` before any `/` while `Requests.Find_Query` takes the first `?` of the whole value.
- **Notes:** The discovery report named the wrong production: RFC 9113 section 8.3.1 says
  **`absolute-path`**, not `"path-absolute"`. The issue body quotes all three linked clauses
  that make this a MUST: section 8.3.1 (`absolute-path` plus "exactly one valid value"),
  section 8.3 ("MUST treat ... invalid pseudo-header fields as malformed") and section 8.1.1
  ("MUST be treated as a stream error ... PROTOCOL_ERROR"). The intermediary scenario is
  **not verified against a peer** and the body says so in the same sentence as the claim; the
  severity does not rest on it. The green h2spec 2.6.0 baseline (146 of 146) is silent here:
  its cases under section 8.1.2.3 test only an empty `:path`, an omitted `:method`, `:scheme`
  or `:path`, and duplicated pseudo-header fields, never an invalid *value*. No existing test
  asserts the wrong behaviour; `tests/http_routing_audit.adb:164-240` exercises the absolute
  form over HTTP/1, where it is legal, and
  `tests/flyology-http-http_3_header_policy-smoke.adb:94-95` pins the HTTP/3 rejection.
  Outside every proved unit.

### ROUTING-MW-4: The metrics series key includes the client-chosen request method and nothing evicts a filled table

- **Severity:** P2 (discovery said P2; unchanged). Observability only. Memory stays bounded,
  the loss is counted in `Dropped_Series`, and the aggregate counters keep working. The defect
  is that the peer chooses which series survive, permanently.
- **Location:** `src/flyology-http-server-metrics.adb:54-72`, consumed from
  `src/flyology-http-server-middleware_metrics.adb:23-30` with `X.Request_Method` at `:25`;
  method admission at `src/flyology-http-server.adb:1164-1168` and `src/flyology-http.adb:14`;
  key bounds at `src/flyology-http-server-metrics.ads:119-120`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_4` (exit 1, BUG REPRODUCED; re-run,
  8 checks, 2 failures).
- **What is wrong:** The series key is the triple route, method and status class. `Route` is
  bounded as `metrics.ads:39` states, but `Method` is the token the peer sent, and nothing in
  `metrics.adb` ever clears a `Used` entry or reduces `Value.Series`, so the table is
  fill-once for the life of the sink. Every unknown method to an existing path is a 405 with
  `Route_Name = "flyology.method_not_allowed"`, so only the method varies. The spike drives a
  `Capacity => 4` sink with four distinct five-byte method tokens; `Series` reaches 4 with
  `Dropped_Series = 0`, and the legitimate `GET /x` 200 that follows is dropped, as is every
  legitimate request after it (15 requests counted in the aggregate, none in any series).
- **Notes:** The capacity **is** a documented policy value:
  `src/flyology-http-server-metrics.ads:80-83` declares
  `type In_Memory (Capacity : Positive := 256)` with the comment naming
  route/method/status-class series, and `website/guide/server/index.html:469` documents the
  cap and the drop counter. The finding is therefore **not** about the number 256. It is about
  the peer choosing one of the three key components and about `metrics.adb` never clearing a
  `Used` entry. The issue body frames it that way and carries a **maintainer decision** with
  both sets of options listed and neither chosen: for the method key, a private implementation
  value, a value derived from the router's registered methods, a generic formal, or a
  deliberately public constant; for eviction, a private implementation value, a discriminant
  on `In_Memory` beside `Capacity`, a generic formal, build-time configuration, a deliberately
  public constant, or leaving the table fill-once and documenting it. The rate limiter's
  bucket table already has the least-recently-seen takeover this would mirror
  (`src/flyology-http-server-middleware_rate_limits.adb:94-95`). This makes the earlier
  audit's "Metrics cardinality" appendix claim that a client cannot inflate cardinality
  incorrect for the method key. Existing coverage pins the bound but never varies the method
  (`tests/http_smoke.adb:3322-3323`, `Series = 1` and `Dropped_Series > 0`); it does not
  assert wrong behaviour and need not change. Outside every proved unit.

### ROUTING-MW-5: CORS middleware omits Vary: Origin on responses whose header set depends on Origin

- **Severity:** P2 (discovery said P2; unchanged). Cache-correctness edge case. No credential
  or origin bypass: `Origin_Allowed` is unchanged and nothing is reflected to a disallowed
  origin.
- **Location:** `src/flyology-http-server-middleware_cors.adb:15-30` (`Add_Origin`, the only
  `Vary: Origin`), with the three early returns at `:40-43`, `:53-61` and `:92-95`.
- **Repro:** `./tests/repros/run.sh repro_routing_mw_5` (exit 1, BUG REPRODUCED; re-run,
  6 checks, 2 failures).
- **What is wrong:** For a non-wildcard policy the representation's header set depends on
  `Origin`, but `Vary: Origin` is emitted only from `Add_Origin`, which runs only after the
  origin was present and allowed. The spike's allowed origin gets
  `Access-Control-Allow-Origin` and `Vary`; a disallowed origin and a request with no `Origin`
  each get a cacheable 200 with neither. A shared cache stores the no-`Origin` copy under a
  key that ignores `Origin` and serves it to a later cross-origin fetch, which the user agent
  then blocks on a resource the server would have allowed.
- **Notes:** **The discovery report's citation was wrong and the verifier corrected it.** The
  sentence attributed to RFC 9110 section 12.5.5 ("An origin server SHOULD send a Vary header
  field when its algorithm for selecting a representation varies ...") is not in RFC 9110 at
  all; it paraphrases the obsoleted RFC 7231 section 7.1.4, and RFC 9110 replaced it with a
  weaker intent-conditioned SHOULD plus an explicit "Vary might be elided" escape. On RFC 9110
  alone the finding would be weak. The behaviour claim survives under the WHATWG Fetch
  Standard's "CORS protocol and HTTP caches", which states the requirement and then describes
  this exact failure; the issue body cites Fetch for the requirement and RFC 9110 section
  12.5.5 only for the cache-key mechanism. Filing it against RFC 9110 would invite a correct
  rejection. Cache behaviour itself is **not checkable from a spike**, since no cache is in
  the loop, so the reproduction establishes only the emitted field set, which is the part the
  server controls; the body says so. The preflight path is already correct and the guide's
  claim at `website/guide/server/index.html:438` holds. Existing coverage asserts `Vary` on
  the allowed path only (`tests/http_routing_audit.adb:1109-1111`,
  `tests/http_smoke.adb:3256-3257`) and does not assert wrong behaviour. Outside every proved
  unit.

### Coverage evidence

Read in full or in the ranges the discovery scope lists: `flyology-http-server-routing`
(.adb 3284 lines, .ads 1471), `flyology-http-server-applications`, the ten `middleware_*`
packages, `flyology-http-server-cors`, `flyology-http-server-metrics`,
`flyology-rate_limit_policy`, `flyology-http-server-compression.ads`,
`flyology-http-server-logging.ads`, `flyology-http-decoded_path_policy`,
`flyology-http-route_parameter_policy`, `flyology-http-server-native_routes`, and the
admission sites in `flyology-http-server.adb`, `flyology-http-server-http_2.adb`,
`flyology-http-http_2_hpack.adb`, `flyology-http-http_3_header_policy.adb` and
`flyology-http-server-requests.adb`. Tests read: `tests/http_routing_audit.adb` (2717 lines,
outline plus the automatic-admission and CORS sections), `tests/http_smoke.adb` (the CORS,
metrics and errors-middleware sections), and the `decoded_path_policy`,
`route_parameter_policy` and `rate_limit_policy` smoke mains. Also `proof/proof-status.md`,
`website/guide/server/index.html` and the routing entries in the earlier audit.

Executed: all five spikes, twice, once during verification and once during drafting; every
run exits 1 with BUG REPRODUCED and the same check and failure counts. `repro_routing_mw_3`
drives a real loopback HTTP/2 connection with a raw-frame peer; the other four drive the
router through an in-memory `Flyology.HTTP.Server.Transport` copied from
`tests/http_routing_audit.adb:103-159`.

Suites and peers that bear on the area: the green `./scripts/test.sh` baseline covers
`tests/http_routing_audit.adb` and `tests/http_smoke.adb`, and each finding's entry records
why the relevant assertion is absent rather than wrong. h2spec 2.6.0 (146 of 146) is the only
pinned peer that touches the HTTP/2 admission path, and its section 8.1.2.3 case list does not
cover ROUTING-MW-3, as quoted above. No other pinned peer is relevant: Autobahn is WebSocket,
the HTTP/3 interop runs are request and response exchanges, and the WPT URL corpus belongs to
the IRI area.

Not exercised: whether a deployed HTTP/2 intermediary forwards a non-`absolute-path` `:path`
unchanged (ROUTING-MW-3), which cannot be settled in process and is marked not verified
against a peer; and the behaviour of a real shared cache in front of the server
(ROUTING-MW-5), for which the spike substitutes the emitted field set. No unit in this area
is proved by `scripts/prove.sh` except `flyology-http-decoded_path_policy.adb`,
`flyology-http-route_parameter_policy.adb` and `flyology-rate_limit_policy.adb`, none of which
is touched by any of the five fixes.

### Refuted and not counted

Refuted or checked and found sound, with no finding raised: percent decoding, dot segments and
the matching order (single-pass decode, encoded-slash rejection, the proved
`Decoded_Path_Policy.Classify`, UTF-8 validation, overlong and surrogate sequences);
parameter capture and its bounds; method dispatch, `Allow` construction, the HEAD fallback and
`OPTIONS *`; registration-time ambiguity, where the runtime `Route_Error` at
`routing.adb:1866` is unreachable; mount composition and effective middleware order; the five
automatic responses that do run the global chain; fail-closed authentication; the CORS core
(exact-token origin comparison, the `Create` rejections, preflight `Vary`); rate limiting
(saturating refill, bounded tokens, digest identity, no shard collision); bulkheads (permit
ownership and release on every unwind); request IDs and security headers; runtime
reconfiguration (`Try_Publish`, generation retention, `Reclaim`, `Finalize`); the middleware
pipeline's single-use continuation and capacity checks; and `compression.ads`, which is an
interface with no encoder in this crate. The regression check on the earlier audit's routing
and middleware findings found every fix present at `f078732`.

Recorded but outside the rubric: a mid-loop mount failure leaves the destination holding the
routes copied so far, which the spec does not promise against; `Strict_Slashes` cannot register
both `/a` and `/a/` because `Patterns_Overlap` ignores `Trailing`; an empty remainder loses the
trailing slash; duplicate `Origin` request fields are comma-joined and the joined value can be
reflected, with no exploit because browsers never send two and a non-browser client is not
subject to CORS; `*` is not a wildcard in `Allowed_Methods` or `Allowed_Headers`; `OPTIONS` on
a resource with no explicit `OPTIONS` route is 405; headers staged before `Run_Automatic` are
inherited by a middleware short-circuit response; a rate-limiter key an application derives
from a spoofable proxy header allows self-eviction within the documented bounded-LRU
trade-off; absurd policy durations near `Duration'Last` overflow the clock addition and surface
as a 500, which is a configuration error not reachable from a peer; parser-level 400, 413, 417
and 500 responses carry no middleware headers by design, since they never construct an
exchange; and metrics `Method` truncation above `Max_Method_Length` is counted in
`Dropped_Series`, noted only because it interacts with ROUTING-MW-4.

## H2

This area covers the HTTP/2 engines and every unit they consume: the server engine
(`src/flyology-http-server-http_2.ad?`), the client session
(`src/flyology-http-http_2_client_connection.ad?`), and the frame, HPACK, Huffman,
payload, settings, policy, request and response units under `src/`, together with the
HTTP/2 paths of `src/flyology-http-client.adb`, `src/flyology-http-server-routing.adb`
and `src/flyology-http-server-applications.adb`. The maintained HTTP/2 tests were read
in full: `tests/http2_server_audit.adb`, `tests/http2_peer.py`,
`tests/http2_server_peer.py`, `tests/http_client_differential_peer.py`,
`tests/http2_client_integration.adb`, `tests/http2_server_integration.adb`, the HTTP/2
smoke tests, and `tests/http2-conformance.md`. Eleven findings are confirmed: two P0,
four P1 and five P2. Nothing was refuted, and no severity moved between discovery and
verification. The area's distinguishing feature is the strength of its peer evidence:
every peer-behaviour claim the discovery pass made from memory is now settled against a
pinned artefact, and two of the findings are demonstrated by stock third-party software
failing against this server, or by this repository's own test peers being patched
around its client.

### H2-1: Client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0`

- **Severity:** P0 (discovery said P0; kept)
- **Location:** `src/flyology-http-http_2_settings.adb:45-51`, consumed at
  `src/flyology-http-http_2_client_connection.adb:1829-1835` with the default
  `Peer_Is_Server => True`
- **Repro:** `./tests/repros/run.sh flyology-http-http_2_settings-repro_h2_1`
  (exit 1, BUG REPRODUCED, 4 checks / 3 failures)
- **What is wrong:** The guard rejects SETTINGS identifier 0x2 on the peer role alone,
  `if Peer_Is_Server or else Value > 1`, so the value 0 from a server is a protocol
  error. RFC 9113 section 6.5.2 says the opposite of the source comment: a server that
  includes the setting MUST set it to 0, and only the value 1 is a connection error.
  The client maps the rejection to `Protocol_Failure`, which queues GOAWAY, calls
  `Fail_All` and sets `Closing`, so every request to such an origin fails permanently
  with `Flyology.HTTP.Protocol_Error`.
- **Notes:** Reachability is settled against the pinned peer, not recalled. `h2==4.3.0`
  is pinned in `tests/requirements-http2.txt` and
  `tests/requirements-client-differential.txt`, and driving that exact installed copy
  shows a server-side `H2Connection.initiate_connection()` emitting `setting 0x02 = 0`
  in its first flight (`review/evidence/h2_1_h2_server_settings.log`). The strongest
  evidence is internal: both maintained Python peers delete the setting before
  initiating the connection to avoid this defect, `tests/http2_peer.py:124-126` and
  `tests/http_client_differential_peer.py:99-101`, and both comments misstate RFC 9113
  in the same way the source comment does. `tests/flyology-http-http_2_settings-smoke.adb:27-28`
  asserts the defect as correct and must change with the fix. h2spec tests the server
  role only, so it cannot reach this. No maintainer decision is needed: RFC 9113
  section 6.5.2 fixes both the accepted and the rejected value.

### H2-2: Server enforces its reduced 16 KiB stream window before the peer can have processed the SETTINGS that announced it

- **Severity:** P0 (discovery said P0; kept, and discovery's "curl burst not executed"
  caveat is discharged)
- **Location:** `src/flyology-http-server-http_2.adb:99-101` (initial `Receive_Window`),
  `:633-641` (consume), `:2513-2521` (escalation), `:2417-2418` (the peer's SETTINGS ACK
  is ignored)
- **Repro:** `./tests/repros/run.sh repro_h2_2` (exit 1, BUG REPRODUCED, 1 check /
  1 failure); the same program run as `repro_h2_2 serve` holds a loopback server for a
  stock peer
- **What is wrong:** Every stream starts at `Advertised_Initial_Window_Size` = 16384 and
  `Publish_Data` consumes against it from the first DATA frame. RFC 9113 section 6.9.3
  requires the receiver to be prepared for data that exceeds a reduced window sent before
  the peer processed the SETTINGS, and permits at most `RST_STREAM(FLOW_CONTROL_ERROR)`
  for the affected stream. The refusal instead reaches
  `Protocol_Failure (Frames.Flow_Control_Error)`, a GOAWAY that fails every stream on the
  connection. The server also never observes the peer's SETTINGS ACK, so it has no way to
  know when its reduced window became binding.
- **Notes:** Stock `curl 8.7.1 (nghttp2/1.68.1)` posting 20480 octets to this server gets
  `received GOAWAY, error=3` and exits 56 (`review/evidence/h2_2_curl.log`). The fix is
  not mechanical: `Stream_Buffer_Capacity` is derived from the same constant
  (`src/flyology-http-server-http_2.adb:51-52`), so raising the window alone moves the
  failure to the buffer-overflow return at `:658-661`, which reaches the same
  `Protocol_Failure`. The issue body therefore states this as a maintainer decision under
  "Decision authority" and "Ada interface values", with five options listed and none
  chosen, because `Advertised_Initial_Window_Size` is a visible `.ads` constant and the
  buffer bound is a capacity. The flow-control arithmetic itself is the proved
  `Flyology.HTTP.HTTP_2_Policy` unit; a fix that touches it must keep
  `./scripts/prove.sh` discharging with `--checks-as-errors=on`. h2spec does not cover
  it: 6.9.1/1 sets the peer's window to 1 and checks the sending side, 6.9.2/1 changes
  the window mid-connection, and `tests/http2_server_peer.py:133` sends only
  `local_flow_control_window(stream_id)` octets by construction.

### H2-3: Client discards the buffered response body when the server follows END_STREAM with `RST_STREAM(NO_ERROR)`

- **Severity:** P1 (discovery said P1; kept)
- **Location:** `src/flyology-http-http_2_client_connection.adb:1370-1387`
  (`Reset_Stream`), `:1522-1531` (`Read` tests `Failure` before `Response_Count`);
  consumed at `src/flyology-http-client.adb:7226-7227` and `:4473-4474`
- **Repro:** `./tests/repros/run.sh repro_h2_3` (exit 1, BUG REPRODUCED, 2 checks /
  1 failure)
- **What is wrong:** `Find` excludes only `Free` slots, so a stream already in phase
  `Complete` with its body buffered is flipped to `Failed` with `Other_Stream_Failure`
  regardless of the error code. `Read` tests the failure before it looks at
  `Response_Count`, so the buffered body is never handed out and `Read_Body` raises
  `Protocol_Error with "HTTP/2 response stream failed before body completion"`; the
  composable driver maps the same result to `Response_Invalid`. RFC 9113 section 8.1
  names the sequence as permitted and says "Clients MUST NOT discard responses as a
  result of receiving such a RST_STREAM".
- **Notes:** Verification narrowed the discovery claim. The response *head* survives,
  because it was published before the reset arrived, so `Client.Status` still returns
  413; what is lost is the response body, and the issue body states only that narrower
  claim. Go's behaviour is verified, not recalled:
  `golang.org/x/net@v0.57.0/http2/server.go:1218-1235` does exactly this when a handler
  finishes while the request stream is still `stateOpen`, and the same code is bundled
  into Go's standard `net/http` (`src/net/http/h2_bundle.go` in go1.23.4), which is what
  `tests/interop/http2_go_peer.go` uses and `scripts/http2-interop.sh:77-78` builds. No
  maintained suite covers it: `early-final-body` (`tests/http2_peer.py:170-183`,
  `tests/http2_client_integration.adb:959-968`) sends the same early 413 without a reset,
  the interop Go handler reads the whole body, and h2spec does not test clients. The fix
  needs a maintainer decision about whether it keys on the error code, the stream phase,
  or both. Paired with H2-10, which is the server-side half of the same RFC 9113
  section 8.1 provision.

### H2-4: Cancelling a client stream mid field section abandons the CONTINUATION and freezes the connection pump

- **Severity:** P1 (discovery said P1; kept. Not raised to P0 because reaching it needs
  write backpressure concurrent with a cancellation, which had to be arranged with a
  deliberately slow peer; the consequences once reached are P0-shaped)
- **Location:** `src/flyology-http-http_2_client_connection.adb:1625-1649`
  (`Cancel_Stream`), `:679` and `:719-721` (the pin guards control output), `:761-762`
  and `:813-815` (both emitting branches require `Phase = Open`), `:504-509`
  (`Clear_Stream` is the only clear on this path)
- **Repro:** `./tests/repros/run.sh repro_h2_4 180` (exit 1, BUG REPRODUCED, 1 check /
  1 failure; needs the longer limit)
- **What is wrong:** `Cancel_Stream` queues RST_STREAM and sets `Phase := Complete` but
  leaves `Continuation_Slot` pointing at that slot. `Required_Header_Slot` is initialised
  from the pin, which restricts the output loop to that one slot, and every branch in it
  requires `Phase = Open`; the control-output branch is separately guarded by
  `Continuation_Slot = 0`. The pump can then emit nothing at all: not the CONTINUATION,
  not the queued RST_STREAM, not a sibling's frames, not a SETTINGS or PING ACK. The
  comment at `:1630-1634` asserts the opposite invariant. The server engine handles the
  same case correctly with `(Item.Phase = Open or else Index = Required)`
  (`src/flyology-http-server-http_2.adb:1031-1038`).
- **Notes:** The discovery entry predicted an interleaved frame after the unterminated
  HEADERS; verification did **not** observe that, and the issue body reports only what
  was captured. The spike ran 30 concurrent exchanges with 32 KiB heads against a peer
  draining at about 100 KB/s, let the 3-second deadlines expire mid-section, then waited
  13 further seconds, issued one more request on the same pooled client and drained to
  end of stream. The capture ends on a clean frame boundary at
  `HEADERS stream 49 (no END_HEADERS)`: no CONTINUATION, no RST_STREAM for any of the 25
  cancelled streams, no head for streams 51-59, nothing for the follow-up request, and no
  frame of any kind after the cancel. The peer-level connection error therefore follows
  from RFC 9113 sections 4.3 and 6.10 as a consequence, not as an observation. No
  maintained suite covers it: `tests/http2_server_audit.adb:727-799` covers the server's
  equivalent pin and `tests/flyology-http-http_2_client_connection-smoke.adb` has no
  `Cancel_Stream` case at all. No maintainer decision is needed for the fix.

### H2-5: A route body limit crossed mid-stream can never answer 413 over HTTP/2

- **Severity:** P1 (discovery said P1; kept)
- **Location:** `src/flyology-http-server-http_2.adb:644-651` (`Body_Limit_Failure`),
  `:756-757`, `:1535-1536`, `:836-846` (`Queue_Response_Head` refuses any failure),
  `:1645-1649`, `:2123-2135`; 413 producer at
  `src/flyology-http-server-routing.adb:2091-2096`
- **Repro:** `./tests/repros/run.sh repro_h2_5` (exit 1, BUG REPRODUCED, 2 checks /
  1 failure, with the HTTP/1.1 control passing)
- **What is wrong:** Crossing the limit inside `Publish_Data` sets
  `Failure := Body_Limit_Failure`, which `Queue_Response_Head` treats as a reason to
  refuse every response for that stream. Routing's `X.Problem (413, ...)` therefore
  raises `Flyology.IO.Device_Error` out of the handler, the handler task's `when others`
  fallback 500 fails identically, and `X.Mark_Failed` resets the stream with
  INTERNAL_ERROR. `Discarding := True` on the same line that records the failure shows
  the intent was to keep draining while a 413 is sent.
- **Notes:** The spike serves the same `Routing.Router` and the same route over both
  engines: HTTP/2 answers `RST_STREAM(INTERNAL_ERROR)`, HTTP/1.1 answers
  `HTTP/1.1 413 Content Too Large` (`src/flyology-http-server-routing.adb:2211-2218`), so
  the two engines disagree for one router. The limit is only discoverable mid-stream when
  the request declares no `content-length`, past `Narrow_Body_Limit` at `:2029-2035`.
  Nothing in `tests/http2_server_audit.adb`, `tests/http2_server_integration.adb` or
  `tests/http2_server_peer.py` exercises a route body limit over HTTP/2, and h2spec does
  not run application routes. The fix is a maintainer decision because it changes when a
  server stream may still produce a response; four options are listed in the issue body,
  one of which would add a `Failure_Kind` variant and so falls under "Decision authority"
  and "Ada interface values".

### H2-6: HPACK encoder never emits the dynamic table size update after a peer lowers `SETTINGS_HEADER_TABLE_SIZE`

- **Severity:** P1 (discovery said P1; kept. Discovery's confidence was "medium" because
  the peer-decoder behaviour was recalled; it is now settled against the pinned decoder)
- **Location:** `src/flyology-http-http_2_settings.adb:43-44` stores the value;
  `src/flyology-http-http_2_hpack.adb:774-777` and `:796-797` are the only two
  representations the builder can emit; `src/flyology-http-http_2_requests.adb:37-62` and
  `src/flyology-http-http_2_responses.adb:35-57` build every section from them
- **Repro:** `./tests/repros/run.sh flyology-http-http_2_requests-repro_h2_6` (exit 1,
  BUG REPRODUCED, 4 checks / 2 failures)
- **What is wrong:** `rg -n Header_Table_Size src/` finds four lines, none of them a
  consumer, so the encoder's declared maximum stays at the protocol default 4096 forever.
  RFC 7541 section 4.2 requires the dynamic table size update "at the beginning of the
  first header block following the change to the dynamic table size. In HTTP/2, this
  follows a settings acknowledgment", and section 6.3 gives the `001` prefix. Both
  engines do acknowledge the peer's SETTINGS (`Queue_Settings_Ack` at
  `src/flyology-http-http_2_client_connection.adb:1841` and
  `src/flyology-http-server-http_2.adb:2433`), so the obligation is live. The defect is
  symmetric: the server ignores the client's setting the same way.
- **Notes:** The consequence is settled against the pinned decoder, not recalled. The
  crate's own emitted block `82 86 01 09 6c 6f 63 61 6c 68 6f 73 74 84` fed to
  `hpack 4.2.0` with `max_allowed_table_size = 0` raises
  `InvalidTableSizeError: Encoder did not shrink table size to within the max`, and the
  same bytes are accepted once a `0x20` prefix is added
  (`review/evidence/h2_6_hpack_decoder.log`); h2 reports that as a COMPRESSION_ERROR
  connection error. It needs a peer configured to lower the setting, which Envoy, HAProxy
  and nghttpx all offer, and which is one call to `update_settings` for any h2
  application; the stock default of 4096 on both sides is why it has not been seen. h2spec
  4.2/1 and 6.3/1 test the decoder side only. The fix adds a parameter to two public
  encoding entry points and fixes the signalled value, so it is a maintainer decision;
  five options are listed and none chosen.

### H2-7: `SETTINGS_INITIAL_WINDOW_SIZE` above 2^31-1 is reported as PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `src/flyology-http-server-http_2.adb:2422-2427` and
  `src/flyology-http-http_2_client_connection.adb:1831-1835`; the distinct result is
  produced at `src/flyology-http-http_2_settings.adb:54-58`
- **Repro:** `./tests/repros/run.sh repro_h2_7` (exit 1, BUG REPRODUCED, 2 checks /
  2 failures, both engines)
- **What is wrong:** `Apply` returns `Settings_Flow_Control_Error` correctly, but both
  frame handlers collapse every non-accepted result into `Protocol_Failure` with its
  default `Frames.Protocol_Error_Code`. RFC 9113 section 6.5.2 requires FLOW_CONTROL_ERROR
  for a value above 2^31-1. Four lines further on the server does pass the right code for
  the adjacent `Apply_Peer_Settings` overflow, so the value is available and only this
  path loses it.
- **Notes:** The h2spec baseline does not contradict this, and the reason is verified in
  h2spec's own source rather than inferred: `VerifyConnectionError`
  (`spec/verifier.go:53-92`) sets `passed = true` on a `ConnectionClosedEvent` before it
  compares any GOAWAY code and then breaks the loop, so the "146 tests, 146 passed"
  baseline does not vouch for any GOAWAY error code, including that of its 6.9.2/3 case
  "Sends a SETTINGS_INITIAL_WINDOW_SIZE settings with an exceeded maximum window size
  value". This was re-checked against the copy of the same file in this machine's Go
  module cache (`github.com/summerwind/h2spec@v2.2.1`), where the identical line range and
  the identical `case ConnectionClosedEvent: passed = true` ordering hold. `tests/flyology-http-http_2_settings-smoke.adb:35-36`
  asserts `Apply`'s result only and never reaches an engine. Diagnostic impact only; the
  reason to fix it is that the pinned conformance run is structurally unable to catch this
  class of defect. No maintainer decision needed. Cross-referenced from the issue body to
  H2-1, which shares the client call site.

### H2-8: Server answers `WINDOW_UPDATE(0)` on an idle stream with RST_STREAM on that idle stream and advances `Last_Client_Stream`

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `src/flyology-http-server-http_2.adb:1217-1221` (`Window_Update` returns
  before any idle check), `:2533-2541` (the handler calls `Reject_Stream`), `:1273-1286`
  (`Reject_Stream` with no slot advances `Last_Client_Stream` and reports `Accepted`)
- **Repro:** `./tests/repros/run.sh repro_h2_8` (exit 1, BUG REPRODUCED, 3 checks /
  3 failures: all three predicted symptoms)
- **What is wrong:** A zero increment on a non-zero stream is reported as a stream failure
  before the stream's state is consulted. `Reject_Stream` accepts any odd non-zero
  identifier, finds no slot, sets `Last_Client_Stream := 5`, records the stream as seen
  and reset, queues `RST_STREAM(5, PROTOCOL_ERROR)` and returns `Accepted = True`, so the
  connection-error branch at `:2543-2552` never fires although its own comment states the
  rule. RFC 9113 section 5.1 makes any non-HEADERS, non-PRIORITY frame on an idle stream
  a connection PROTOCOL_ERROR, and section 6.4 forbids sending RST_STREAM for an idle
  stream. The knock-on is the third failure: a later legitimate HEADERS on stream 3 is
  refused as a lower identifier and the connection is failed with GOAWAY.
- **Notes:** The PING ACK in the trace is the positive evidence that the connection
  survived where it should have been failed. h2spec covers neither combination, verified
  in its source rather than assumed: 5.1/3 "idle: Sends a WINDOW_UPDATE frame" sends
  `conn.WriteWindowUpdate(1, 100)` (`http2/5_1_stream_states.go`), a non-zero increment,
  and 6.9/2 calls `conn.WriteHeaders(hp)` before the zero increment
  (`http2/6_9_window_update.go`), so its stream is open. The repository's own idle-stream
  case uses `U32 (100)` at `tests/http2_server_audit.adb:837-838`, so the zero-increment
  branch is untested there too. The same `spec/verifier.go:53-92` limitation noted under
  H2-7 applies to any green connection-error case. Self-inflicted only: a conforming peer
  never sends a zero increment, so this poisons only the offending peer's connection. The
  issue body flags one option (a new out parameter or result variant on `Window_Update`)
  as a maintainer decision and offers a no-signature-change alternative.

### H2-9: Server sends RST_STREAM(STREAM_CLOSED) for every DATA frame on a stream it already reset

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `src/flyology-http-server-http_2.adb:618-631` (`Publish_Data`
  closed-stream branches); the reset paths set `Remote_End := True` at `:911-912`,
  `:1253-1254` and `:1294-1295`
- **Repro:** `./tests/repros/run.sh repro_h2_9` (exit 1, BUG REPRODUCED, 2 checks /
  1 failure)
- **What is wrong:** The `Remote_End` branch does not separate half-closed (remote), where
  RFC 9113 section 5.1 requires a stream error of type STREAM_CLOSED, from closed, where
  the same section says "An endpoint MUST NOT send frames other than PRIORITY on a closed
  stream" and requires frames to be minimally processed and discarded. Because every
  server-side reset path sets `Remote_End` itself, a stream the server closed takes the
  half-closed branch and each in-flight DATA frame draws another RST_STREAM.
- **Notes:** The window accounting on the same path is correct: `Charge_Closed_Stream`
  charges and credits the connection window. This is not an amplification defect, and the
  spike measures it: three 109-octet DATA frames produced three 13-octet RST_STREAM
  frames, a ratio well under one, and no WINDOW_UPDATE appeared because 300 octets is
  below the 8 KiB credit threshold. h2spec's 5.1/8 sends DATA after the *client's*
  RST_STREAM, where STREAM_CLOSED is the correct answer, so it does not cover this;
  `tests/http2_server_audit.adb:602-646` asserts only the connection-window credit and
  tolerates the resets. `Failure = Reset_Failure` is already set on the same lines as
  `Remote_End`, and `Was_Reset` (`:442-452`) already queries the reset history, so the
  fix needs no new state and no maintainer decision. Cross-referenced with H2-11, which is
  the client-side equivalent.

### H2-10: Server never resets a stream whose response completed while the request half is open

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `src/flyology-http-server-http_2.adb:419-428` (`Maybe_Complete` requires
  `Remote_End`), `:2112-2138` (the handler task does no drain or reset);
  `src/flyology-http-server-applications.adb:1019-1026` is one producer of the shape
- **Repro:** `./tests/repros/run.sh repro_h2_10` (exit 1, BUG REPRODUCED, 2 checks /
  1 failure)
- **What is wrong:** A stream answered early keeps `Remote_End` False, so it never
  completes and is never reset. The octets already received were charged to both windows
  and buffered; credit is returned only as bytes leave the buffer, and no handler will
  read them. The slot also stays counted against `Maximum_Concurrent_Streams`
  (`src/flyology-http-server-http_2.ads:19`, 32) until the peer resets it or
  `Max_Connection_Age` (`:38`, 300.0 by default) ends the connection.
- **Notes:** The spike observed four responses, **zero** RST_STREAM frames and **zero**
  octets of connection credit for 64000 octets across four streams, leaving the peer 1535
  octets of a 65535-octet connection window and no event that can replenish it. This is
  not a conformance violation, which is why it stays P2: RFC 9113 section 8.1 makes the
  server's `RST_STREAM(NO_ERROR)` a MAY. It is the same behaviour Go's server implements
  deliberately, and that behaviour is what trips H2-3 on this repository's client side, so
  the two should be fixed together or the server change will break this repository's
  client against itself. No maintained suite covers it: the `early-final` scenarios drive
  the client, and the server audit has no early-response-with-open-request case. The fix
  is a maintainer decision because it sets an externally visible server policy; five
  options are listed, one of which would add a drain limit and so a new value under "Ada
  interface values".

### H2-11: Client ignores RST_STREAM and WINDOW_UPDATE on idle streams

- **Severity:** P2 (discovery said P2; kept). Verdict PARTIALLY CONFIRMED: part (a)
  reproduced, part (b) is a real code path that could not be reached from the synchronous
  API
- **Location:** `src/flyology-http-http_2_client_connection.adb:1374-1378`
  (`Reset_Stream`), `:1342-1346` (`Window_Update`); the asymmetric correct case is
  `Publish_Headers` at `:1107-1111`. Part (b): `:1115-1118`, `:1229-1240`, `:1066-1080`
- **Repro:** `./tests/repros/run.sh repro_h2_11` (exit 1, BUG REPRODUCED, 2 checks /
  1 failure)
- **What is wrong:** Both procedures start with `Find (Stream_ID)` and return silently for
  an unknown stream, so a RST_STREAM or WINDOW_UPDATE naming a never-opened stream is
  dropped where RFC 9113 sections 6.4 and 5.1 require a connection error of type
  PROTOCOL_ERROR. `Publish_Headers` on the same stream is handled correctly, so the three
  frame types disagree about the idle state. The spike's peer sent
  `RST_STREAM(stream 7, CANCEL)` and `WINDOW_UPDATE(stream 9, 100)` in its first flight
  and the exchange still completed with status 200.
- **Notes:** Part (b) of the discovery claim, that post-cancel in-flight frames draw a
  second `RST_STREAM(PROTOCOL_ERROR)` on a stream the client already closed, is a real
  code path (`Reject_Stream` returns early only for `Free | Failed`, not `Complete`) but
  was **not** reproduced: the synchronous `Execute` path releases the slot immediately
  after cancelling (`src/flyology-http-client.adb:741-755`), so `Find` returns 0 by the
  time the late frames arrive and the spike observed zero extra resets. Reaching it needs
  the composable driver's deferred release (`src/flyology-http-client.adb:1066-1070`) with
  the late frame landing inside that window, and no deterministic placement was found. The
  issue body reports part (b) as code-level only in the same sentence as the claim, and
  the Severity section rests on part (a) alone. Existing coverage: `composable-cancel` and
  `reset-race` (`tests/http2_peer.py`, `tests/http2_client_integration.adb:540`, `:613`)
  assert that the session survives, not what the client emits; there is no idle-stream
  case. The fix for part (a) may add an out parameter to two controller operations, which
  the issue body states as a maintainer decision with a no-signature-change alternative.

### Coverage evidence

Read in full under `src/`: `flyology-http-server-http_2.adb` and `.ads`,
`flyology-http-http_2_client_connection.adb` and `.ads`, and the `http_2_frames`,
`http_2_hpack`, `http_2_huffman`, `http_2_payloads`, `http_2_settings`, `http_2_policy`,
`http_2_requests` and `http_2_responses` units; read for call-site tracing: the HTTP/2
paths of `flyology-http-client.adb`, `flyology-http-server-routing.adb` and
`flyology-http-server-applications.adb`. Every file:line quoted in the eleven issue bodies
was re-read at `f078732` before quoting.

Executed: all eleven spikes, each re-run from a clean build for the drafted bodies and
each reproducing with the output quoted verbatim in its issue. `repro_h2_4` needs
`./tests/repros/run.sh repro_h2_4 180`; the rest run inside the default 60-second limit.

Pinned peers and artefacts that bear on this area:

- `h2==4.3.0` (`tests/requirements-http2.txt`), driven directly from
  `build/http2-tester/bin/python`, for the server-side `ENABLE_PUSH = 0` first flight
  (H2-1). Evidence: `review/evidence/h2_1_h2_server_settings.log`.
- Stock `curl 8.7.1 (libcurl/8.7.1, nghttp2/1.68.1)` against this server's own HTTP/2
  engine (H2-2). Evidence: `review/evidence/h2_2_curl.log`.
- `hpack 4.2.0`, the decoder `h2==4.3.0` uses, fed the crate's own encoded bytes with
  `max_allowed_table_size = 0` (H2-6). Evidence:
  `review/evidence/h2_6_hpack_decoder.log`.
- `golang.org/x/net@v0.57.0/http2/server.go:1218-1235` in the local Go module cache, and
  the same code bundled into go1.23.4's `net/http` (`src/net/http/h2_bundle.go`), which is
  what `tests/interop/http2_go_peer.go` links and `scripts/http2-interop.sh:77-78` builds
  (H2-3, H2-10).
- h2spec 2.6.0, pinned at `scripts/http2-test.sh:259` as `summerwind/h2spec:2.6.0`. The
  green baseline (`review/baselines/13-http2-h2spec-docker.log`, 146 tests, 146 passed)
  was read case by case, and h2spec's own source was read to establish what a green run
  does and does not prove: `spec/verifier.go:53-92` accepts a `ConnectionClosedEvent`
  before comparing any GOAWAY code (bearing on H2-7 and on every connection-error case),
  `http2/5_1_stream_states.go` case 3 uses a non-zero increment and
  `http2/6_9_window_update.go` case 2 opens the stream first (bearing on H2-8). The
  verification pass read 2.6.0's source directly; the drafting pass re-checked those three
  files against `github.com/summerwind/h2spec@v2.2.1` in this machine's Go module cache,
  and every cited line range and call holds identically there, so the two versions agree
  on all three points. Nothing in
  the suite sends over-window DATA before processing the server's SETTINGS (H2-2), runs an
  application route body limit (H2-5), or tests the encoder side of HPACK table sizing
  (H2-6), and h2spec tests servers only, so it cannot reach H2-1, H2-3, H2-4 or H2-11.
- The Huffman table check in `review/evidence/huffman_table_check.out` confirms all 257
  symbols against RFC 7541 Appendix B. It was taken as given and not re-derived; there is
  no finding there.

Could not be exercised: part (b) of H2-11, which needs the composable driver's deferred
release to coincide with a late in-flight frame; no deterministic placement was found, and
the issue body says so. The H2-2 curl run and the H2-6 decoder run are out-of-band checks
against the spike's `serve` mode and its emitted block rather than assertions inside a
spike, so they are recorded as evidence logs rather than as exit codes.

### Refuted and not counted

Nothing was refuted. Two entries were narrowed by verification and the issue bodies carry
the narrower claim:

- **H2-3** was narrowed from "discards a complete response" to "discards the buffered
  response body". `Client.Status` still returns the correct status, because the head is
  published before the reset arrives.
- **H2-4**'s predicted interleaving was not observed. What the capture shows is that the
  session emitted nothing at all after the cancel, ending on a clean frame boundary at an
  unterminated HEADERS. The issue body reports the freeze and the dangling section as
  observed facts and the peer's connection error as the RFC consequence.
- **H2-11** part (b) is code-path-confirmed but not reproduced, as described above.

Observations recorded but outside the rubric:

- A self-dependent HEADERS priority is a connection error
  (`src/flyology-http-server-http_2.adb:2453-2462`, via `Payloads.Header_Fragment`) while a
  self-dependent PRIORITY frame is a stream reset (`:2440-2452`). RFC 7540 section 5.3.1 required a stream error; RFC
  9113 section 5.3.2 deprecates the signalling and retains no such requirement, so this is
  an internal inconsistency and an h2spec 5.3.1 expectation, not a violation of RFC 9113.
- `Flyology.HTTP.HTTP_2_Client_Connection.Destroy` is documented as "Close wakes the pump;
  this call waits until it has stopped" (`.ads:103-105`); there is no `Close` and no pump
  task. Stale comment.
- `HTTP_2_HPACK` is documented as "used by HTTP/2 clients" (`.ads:6`); it is the server's
  decoder too.
- The client rejects a 204 response carrying `content-length`
  (`src/flyology-http-http_2_client_connection.adb:1142-1150`). RFC 9110 section 8.6
  forbids the server from sending it but imposes nothing on the recipient. Strict policy,
  not a defect.
- `Host` is compared byte-exactly against `:authority`
  (`src/flyology-http-server-http_2.adb:2350-2356`) and `te` must be exactly `trailers`
  (`src/flyology-http-http_2_hpack.adb:584`); RFC 9110 makes both case-insensitive.
  Browsers and curl do not send `Host` over HTTP/2 and gRPC sends lowercase `te`, so the
  practical exposure is nil.
- `:method: CONNECT` is refused with a stream reset
  (`src/flyology-http-server-http_2.adb:2341-2349`) rather than a 4xx or 501. Server
  policy.
- A response field section with a malformed regular field is a connection error in the
  client (`src/flyology-http-http_2_hpack.adb:337`, `:367`). RFC 9113 section 8.1.1 calls
  for a stream error, but `Decode_Response` raises mid-block, so the connection scope is
  the choice that keeps the HPACK table in step, and a stock server never produces such a
  section.
- The server's concurrency check counts only `Open` slots but refuses when all 32 slots
  are held, so `Complete`-but-unreaped streams can produce a transient REFUSED_STREAM
  under the advertised limit. Retry-safe by construction.
- `Advertised_Initial_Window_Size` (16384), `Maximum_Header_Block` (64 KiB),
  `Maximum_Control_Backlog` (32 KiB), `Window_Update_Threshold` (8 KiB),
  `Stream_History_Capacity` (4096) and `Maximum_Remembered_Closed_Streams` (256) are
  policy values reachable from the wire. Only the first has a protocol consequence, and
  that is H2-2.

## H3-QPACK

This area covers the HTTP/3 server driver, the HTTP/3 session and client-session bodies,
the client's HTTP/3 internals, and the eleven proved policy units that implement HTTP/3
framing, control, settings, message sequencing, header validation, stream receive, QPACK
field sections, QPACK integers, the QPACK static table and Huffman decoding. Discovery
read all of those plus the HTTP/3 tests under `tests/`, the conformance notes in
`tests/http3-conformance.md`, the oracle drivers under `tests/oracle/`, the h3spec report
under `build/oracle/`, and the vendored aioquic and quic-go peers. Verification reproduced
every one of the fourteen candidates and refuted none, which is unusual for this review:
discovery was accurate about mechanism throughout this area. One severity moved
(H3-QPACK-3, P0 to P1, because its browser trigger could not be checked) and two reaches
were narrowed (H3-QPACK-8 needs a concurrent origin; H3-QPACK-2's peer claim was settled
in the other direction, against vendored quic-go source). Final distribution: **P0 2, P1 7,
P2 5**, against discovery's P0 3, P1 6, P2 5. All fourteen bodies are drafted at
`review/filing/H3-QPACK-1.md` through `-14.md`.

### The shared premise behind H3-QPACK-1, -2 and -3

The three P0 candidates all rest on the claim that the QUIC per-stream receive window is
16,384 bytes and that nothing above the transport grows it or waits for credit. The
verifier settled this by reading before writing any spike, and it holds in both parts:
`flyology_quic/src/flyology-quic-connections.ads:103-108` sets the advertised defaults
(16,384 per stream, 524,288 per connection, 29 bidirectional streams), and
`flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:18-22` fixes the reassembly
buffer at the same figure as a compile-time constant whose type invariant at `:111-115`
enforces `Highest - Base <= Max_Stream_Data`. The buffer bound is therefore structural, not
a default: no configuration can raise it. `Encode_Max_Stream_Data` has exactly one call
site in the whole QUIC crate (`flyology-quic-application_space.adb:862`), inside
`Build_Receive_Credit_Packet`, whose only callers under `src/` are
`flyology-http-server-http_3.adb:1647` and `flyology-http-client.adb:2541`. Consuming
stream bytes does not move the advertised limit. The three findings do not collapse into
one: -1 is an advertised limit never raised while a body arrives, -2 is the fixed buffer
against whole-frame parsing (which bites even where credit is granted), and -3 is
unrelated to flow control.

### H3-QPACK-1: server returns no per-stream receive credit while a request body is arriving

- **Severity:** P0 (discovery said P0; unchanged)
- **Location:** `src/flyology-http-server-http_3.adb:1637-1663` (`Return_Request_Credit`),
  `:1665-1671` (`Request_Credit_Due`), consumed only at `:1821-1824`
- **Repro:** `./tests/repros/run.sh repro_h3_qpack_1 90` (exit 1, BUG REPRODUCED)
- **What is wrong:** The only emitter of MAX_STREAM_DATA is called from the `Stream_Ended`
  branch of `Process_Event`, which a request whose body is still arriving never reaches.
  A conformant peer stops at the advertised 16,384-byte window and waits forever. The
  spike uploads 20,000 bytes in 1,024-byte DATA frames and the transport accepts exactly
  15,360 of them, the window less the HEADERS frame and the per-frame envelopes, then
  blocks for 65 retries over twelve seconds with no credit. The server had already
  consumed every DATA frame into `Payload_Bytes` (`:1783-1788`), so this is not a buffering
  limit. RFC 9000 section 4.1 makes MAX_STREAM_DATA the receiver's only way to grant more.
- **Notes:** The documented contract is the opposite: `website/guide/server/index.html:369`
  promises a 1 MiB buffered-body limit, a figure no request over ~15 KiB can reach. The
  same starvation applies after a 413 from `Reject_Oversized_Request`, where the server
  discards further DATA (`:1776-1777`) and never sends STOP_SENDING; RFC 9114 section 4.1
  asks for H3_NO_ERROR there. The fix needs a maintainer decision on the rate at which an
  in-progress body earns credit and on any change to the advertised window. Green
  baselines do not cover it: the aioquic oracle posts seven bytes
  (`tests/oracle/aioquic_h3_client.py:70`), the quic-go oracle posts `payload`
  (`tests/oracle/quic-go/main.go:115`), and `tests/http3_server_integration.adb:107,139`
  declare 5 GiB and 64 GiB bodies but read nothing. No maintained test asserts the wrong
  behaviour, so none has to change. Not a proved unit.

### H3-QPACK-2: whole-frame buffering against a fixed 16 KiB reassembly window

- **Severity:** P0 (discovery said P0; unchanged)
- **Location:** `src/flyology-http-http_3_frame_policy.adb:72-81`,
  `src/flyology-http-http_3_connection.adb:419-425`,
  `flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:18-22` and `:111-115`
- **Repro:**
  `./tests/repros/run.sh flyology-http-http_3_stream_receive_policy-repro_h3_qpack_2`
  (exit 1, BUG REPRODUCED)
- **What is wrong:** `Parse` reports a truncated envelope with `Consumed = 0` until the
  whole payload is contiguous, and `http_3_connection.adb` calls `QUIC.Consume` only when
  something was consumed, so the reassembly base never advances for a frame larger than the
  window. The spike hands the policy the largest contiguous prefix that can ever exist for
  one frame (a full 16,384-byte window holding a DATA envelope declaring 20,000 bytes plus
  16,379 payload bytes) and gets `NEED_MORE_DATA`, consumed 0. The package's own
  specification at `http_3_stream_receive_policy.ads:11-13` states the assumption that
  fails: retry "when the transport exposes a longer contiguous prefix", which does not
  exist. Part B: a declared length above 65,535 becomes `Frame_Error` and a connection
  close, although RFC 9114 section 7.1 sets no maximum.
- **Notes:** The peer claim IS verified. quic-go 0.54.1 frames one DATA frame per `Write`
  (`http3/response_writer.go:177-181`, `l := uint64(len(w.smallResponseBuf) + len(p))`
  then `df := &dataFrame{Length: l}`) with `maxSmallResponseSize = 4096` at line 27, so
  `w.Write(make([]byte, 20000))` is a single 20,000-byte frame. On the upload side
  `request_writer.go:22` is `bodyCopyBufferSize = 8 * 1024`, so quic-go uploads stay under
  the bound and hit H3-QPACK-1 instead. `review/baselines/10-http3-interop.log` records
  PASS because the interop lane transfers only `hello` and `echo:payload` and the Ada
  server frames every response in 1,024-byte chunks (`server-http_3.adb:46`), two orders
  of magnitude below the threshold. **A maintained test asserts the current behaviour:**
  `tests/flyology-http-http_3_frame_policy-smoke.adb:45-47` pins a 65,536-byte length as
  `Frame_Length_Too_Large` and must change with the fix. Three proved units are in scope
  (`http_3_frame_policy`, `http_3_stream_receive_policy`, and QUIC's
  `stream_reassembly_policy`), and the reassembly change has to keep the type invariant
  provable. The fix needs a maintainer decision on the frame-length ceiling and on
  `Max_Stream_Data`.

### H3-QPACK-3: receive-side field-section limits close the connection and are never advertised

- **Severity:** P1 (discovery said P0; **lowered**, see notes)
- **Location:** `src/flyology-http-qpack_field_section_policy.adb:127-132` and `:346-350`,
  `src/flyology-http-http_3_stream_receive_policy.adb:292-295`,
  `src/flyology-http-server-http_3.adb:296` and `:305-329`, `:1525`
- **Repro:** `./tests/repros/run.sh repro_h3_qpack_3 90` (exit 1, BUG REPRODUCED)
- **What is wrong:** Every non-`Decoded` decode status, including the profile's own
  retention bounds `Too_Many_Fields` and `Field_Too_Large`, collapses to
  `QPACK_Decompression_Failed`, which the server maps to `0x200` and sends as a
  connection-scope close. The spike sends one well-formed 33-field section (297 encoded
  bytes, Required Insert Count 0, Delta Base 0) and the transport goes to `PEER_CLOSED`
  with no stream-local reset; a later unrelated request on the same connection returns
  `NOT_CONNECTED`. The limits are also undiscoverable: `server-http_3.adb:1525` calls
  `H3.Initialize` with no `Local_Settings`, so `Has_Max_Field_Size` stays False and no
  SETTINGS_MAX_FIELD_SECTION_SIZE is sent, which the spike's first failing check observes
  from the peer side. RFC 9114 section 4.2.2 names 431 as the intended remedy.
- **Notes:** **Lowered to P1 because the browser trigger could not be checked.** Discovery's
  P0 rested on Chrome's cookie crumbling pushing an ordinary navigation past 32 field
  lines; that is an estimate and no browser was driven, so the issue body says so plainly
  and its severity prose rests only on the mechanism: a wrong error class and a wrong
  error scope on valid input via a reachable path. The aggravating factor keeping it at
  the top of P1 is the blast radius, which the spike demonstrates directly. If a browser
  run established the trigger, P0 would follow; settling that needs a pinned browser peer.
  SETTINGS_MAX_FIELD_SECTION_SIZE is a byte limit, so the 32-field count bound is not
  expressible in it even when advertised. The fix needs a maintainer decision on the
  advertised value and on whether a new public `Operation_Status` variant is added. Two
  proved units in scope. Shares its fix with H3-QPACK-10.

### H3-QPACK-4: server leaks one send slot per cancelled response

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-http_3_connection.adb:664-676` (cancellation),
  `:135-145` (`Release_Message`), `:569-572` (`Add_Send`)
- **Repro:** `./tests/repros/run.sh repro_h3_qpack_4 90` (exit 1, BUG REPRODUCED)
- **What is wrong:** `Build_Request_Cancellation` marks the send slot finished and
  cancelled but clears it only for the client role, and `Release_Message`'s `Sending`
  cleanup is guarded by the same `if Item.Local_Role = Client`. The remaining `Send_Count`
  decrements are all Fin-send paths a cancelled stream never takes, so `Send_Count` is
  monotonic and `Add_Send` returns `Stream_Capacity_Exceeded` at `Max_Streams = 32`. The
  spike's count is exact with no slack: 32 of 40 responses arrive and the 33rd does not.
- **Notes:** The trigger is an ordinary handler shape, `X.Begin_Stream` followed by a
  return without `X.End_Stream`, which `server-http_3.adb:1584-1591` classifies as
  `Streaming_Response` and resolves with `X.Mark_Failed` into `H3.Cancel_Request`. The
  transport stays `CONNECTED` and simply goes mute, which is H3-QPACK-6 compounding this
  one. `tests/http3_public_smoke.adb:187-190` cancels once per role and never inspects
  capacity afterwards. No maintainer decision needed: the narrow fix is dropping the role
  guard at `http_3_connection.adb:135`. Not a proved unit.

### H3-QPACK-5: server never sends GOAWAY or CONNECTION_CLOSE at end of life

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-server-http_3.adb:1897-1900`, `:1919-1922`,
  `:1834-1842` (`Cleanup`), `:1923-1926`, `:2026-2033`
- **Repro:** `./tests/repros/run.sh repro_h3_qpack_5` (exit 1, BUG REPRODUCED)
- **What is wrong:** When the loop condition `Served < Max_Requests` fails, `Cleanup` frees
  the QUIC and request state and nothing is transmitted. The spike configures
  `Max_Requests => 1`, completes the one request, then polls for six seconds: no GOAWAY,
  no state change, transport still `CONNECTED`. The same silent path is taken on
  `Max_Connection_Age` expiry and on listener shutdown. RFC 9114 section 5.2 asks for a
  GOAWAY when closure is known in advance; RFC 9000 section 10.2 asks for a
  CONNECTION_CLOSE.
- **Notes:** `Send_Goaway` and `Build_Goaway` have no caller outside the HTTP/3 session
  packages themselves, confirmed by grep. Internal asymmetry: the HTTP/2 server does queue
  a GOAWAY (`src/flyology-http-server-http_2.adb:1309-1316`). The fix needs a maintainer
  decision on the grace period between the GOAWAY and the close, and on whether accepted
  requests drain first; sending immediately adds no value at all and is the minimal
  choice. `tests/http3_public_smoke.adb:202-205` exercises the `Send_Goaway` API in
  isolation and does not have to change. Not a proved unit.

### H3-QPACK-6: exceptions other than Timeout_Error abandon the connection silently

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-server-http_3.adb:1915-1918` (only `Timeout_Error`),
  `:1923-1926`, `:2026-2033`, raiser at `:1699-1702`; `:44` against
  `flyology_quic/src/flyology-quic-connections.ads:107`
- **Repro:** `./tests/repros/run.sh repro_h3_qpack_6` (exit 1, BUG REPRODUCED)
- **What is wrong:** The driver allocates `Maximum_Request_Streams = 8` request slots while
  the transport advertises `Max_Streams_Bidi = 29`, so a conformant peer can open nine
  concurrent request streams and the ninth `Headers_Received` raises `Resource_Exhausted`.
  The event loop handles only `Timeout_Error`; everything else reaches
  `when others => Cleanup; raise;` and the worker logs it only when `Debug.Enabled`. The
  spike opens nine POST streams with `Fin => False`, all nine are admitted by the
  transport, and the ninth gets no response, no reset and no close, with the transport
  still `CONNECTED`.
- **Notes:** The other raisers share the handler gap and were read but not separately
  reproduced: `Payload_Too_Large` (`:1778-1782`), the CONNECT rejection (`:1563-1566`),
  `Constraint_Error` from `To_Method` on a method over 64 bytes (`src/flyology-http.adb:12-20`),
  `Headers_Too_Large` from a trailer section over 16 KiB (`src/flyology-http-headers.ads:10,34`),
  and `Device_Error` on a non-`Succeeded` prepared-response status (`:396-400`, `:454-457`).
  The fix needs a maintainer decision on the relationship between `Maximum_Request_Streams`
  and the advertised `Max_Streams_Bidi`, and on how the ninth request is refused
  (H3_REQUEST_REJECTED per RFC 9114 section 4.1.1, a 503, or a larger table). Shares its
  missing-close half with H3-QPACK-5. Not a proved unit.

### H3-QPACK-7: send-side field sections are capped at 1,109 encoded bytes

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-qpack_field_section_policy.ads:17-21`,
  `src/flyology-http-http_3_connection.adb:862-866`,
  `src/flyology-http-client.adb:5223-5229`; contract at
  `src/flyology-http-http_3.ads:17-22` and `CHANGELOG.md:79-81`
- **Repro:**
  `./tests/repros/run.sh flyology-http-qpack_field_section_policy-repro_h3_qpack_7`
  (exit 1, BUG REPRODUCED)
- **What is wrong:** The public contract advertises `Max_Value_Length = 16 KiB` and names
  long `:path` values for presigned object requests; `Encode` refuses anything whose
  encoding exceeds `Max_Encode_Length = 1_109`. The spike measures the real ceiling for a
  single value in a two-field response section at **1,096 bytes**, roughly an order of
  magnitude below the advertised bound, which rules out any reading in which only the
  16 KiB extreme fails. The failure surfaces as `QPACK_Decompression_Failed`, which becomes
  a 500 on the server and `Transport_Failed` on the client, neither of which describes what
  happened.
- **Notes:** No RFC is violated; the violated contract is the repository's own `.ads` and
  CHANGELOG. The 1,109 figure follows from `Max_Stream_Payload = 1_100` at
  `flyology_quic/src/flyology-quic-connections.ads:21`, so a real fix has to frame a field
  section across several stream writes. The fix needs a maintainer decision either way,
  since raising `Max_Encode_Length` grows a stack-resident record and lowering
  `Max_Value_Length` narrows a published contract. `qpack_field_section_policy` is proved
  and its bounds contracts are written against `Max_Encode_Length`.
  `tests/http3_public_smoke.adb:92-99` covers only the peer-advertised
  `Peer_Field_Section_Too_Large` case; no maintained test asserts the current ceiling.

### H3-QPACK-8: client credit is connection-wide while its admission test is stream-local

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-client.adb:2517-2530`,
  `flyology_quic/src/flyology-quic-application_space.adb:878-895`,
  `src/flyology-http-http_3_client_connection.adb:411-421` and `.ads:114`
- **Repro:**
  `./tests/repros/run.sh flyology-http-http_3_client_connection-repro_h3_qpack_8 120`
  (exit 1, BUG REPRODUCED)
- **What is wrong:** `Build_Receive_Credit_Packet` raises every tracked stream's limit to
  that stream's own `Consumed_Offset + Window`, while `HTTP_3_Receive_Credit_Due` decides
  from the consumed length of the one stream whose owner is reading. A stream's consumed
  offset advances whenever `Poll` decodes its DATA into the ring, regardless of the owner,
  so an unread sibling keeps being granted credit it has no room for. The spike's stream B
  fails at 65,536 delivered bytes, one past `Response_Buffer_Capacity = 65_535`, and the
  admission test is `Stream.Phase := Failed`, not backpressure.
- **Notes:** **Reach narrowed by the verifier.** An earlier spike drove this repository's
  own server and passed, because `Serve_Connection` dispatches one request at a time and
  never interleaves two response bodies; stream B's head had not even arrived while A was
  being read. The finding needs a concurrent HTTP/3 origin, and the issue body is written
  to that narrower scope rather than discovery's implied "any pooled HTTP/3 connection".
  Not verified against a named third-party peer, and the body says so in the same sentence
  as the impact. The final spike supplies the interleaving with a raw in-process HTTP/3
  server session; it passed twice before it reproduced, the second time because the
  in-memory harness sent no ACKs and the congestion window rather than the ring was the
  binding constraint, and the final version removes both confounders. The fix needs a
  maintainer decision on per-stream headroom in the QUIC credit API or on the ring
  capacity. `receive_flow_control_policy` is proved in the QUIC suite.

### H3-QPACK-9: peer-reset request streams never refill MAX_STREAMS

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-server-http_3.adb:1640-1644`, `:1606`, `:1821-1824`,
  `:1825-1828`
- **Repro:** `./tests/repros/run.sh repro_h3_qpack_9 90` (exit 1, BUG REPRODUCED)
- **What is wrong:** The cumulative limit is `Max_Streams_Bidi + Served`, `Served` is
  incremented only by `Dispatch_Request`, and the credit datagram is built only in the
  `Stream_Ended` branch; `Stream_Reset` releases the local slot and sends nothing. Each
  cancellation therefore permanently removes one unit of concurrency. The spike opens and
  cancels requests and manages exactly 29, the advertised default, before the 30th
  `Open_Request` returns `Stream_Limit_Reached`. The connection is still `CONNECTED` and
  cannot recover, because nothing can complete to trigger the refill. RFC 9000 section 4.6
  makes the limit cumulative over every stream ever opened.
- **Notes:** Shares its root with H3-QPACK-1: `Return_Request_Credit` is the single emitter
  of both MAX_STREAMS and MAX_STREAM_DATA and is reachable only from `Stream_Ended`. The
  fix needs a maintainer decision only on the refill rate, and the existing
  `Stream_Credit_Interval` derived from `Max_Streams_Bidi / 2` (`:1497-1502`) is the
  natural precedent. A separate retired-stream counter is needed rather than reusing
  `Served`, which also drives connection retirement. No existing coverage. Not a proved
  unit.

### H3-QPACK-10: malformed requests are treated as connection errors

- **Severity:** P2 (discovery said P2; unchanged)
- **Location:** `src/flyology-http-http_3_connection.adb:426-440` (client role only),
  `src/flyology-http-server-http_3.adb:295`, `:320-321`, `:1910-1913`
- **Repro:** `./tests/repros/run.sh repro_h3_qpack_10` (exit 1, BUG REPRODUCED)
- **What is wrong:** The client role converts `Message_Error` and `Header_Error` into a
  stream-local `Stream_Reset` with `0x10E`, but the branch is guarded by
  `if Item.Local_Role = Client`, so on the server the same statuses reach
  `Close_For_H3_Error` and become a connection close. The spike sends one request with an
  uppercase field name and the whole connection dies with it; a later unrelated request
  returns `NOT_CONNECTED`. An empty request stream takes the same path through
  `Finish_Request` returning `Message_Incomplete`.
- **Notes:** Kept at P2 because RFC 9114 section 8 permits the escalation ("An endpoint MAY
  choose to treat a stream error as a connection error under certain circumstances ...
  Implementations need to consider the impact on outstanding requests before making this
  choice") and because the trigger is an invalid request from the peer's own connection, so
  the blast radius is that peer's other requests. The part worth fixing is the asymmetry
  between the two roles in one code path. The h3spec gate does not distinguish the scopes:
  its four H3_MESSAGE_ERROR cases pass with a connection close, so the conformance lane's
  expectations will need review with the fix.
  `tests/flyology-http-http_3_stream_receive_policy-smoke.adb:203-204` asserts the
  classifier only. Shares its fix with H3-QPACK-3. **Method note:** the spike carries a
  positive control, a well-formed section from the same hand encoder answered with 200 on
  the preceding stream, so the uppercase name is the only variable.

### H3-QPACK-11: empty DATA frame on a HEAD, 204 or 304 response is rejected

- **Severity:** P2 (discovery said P2; unchanged)
- **Location:** `src/flyology-http-http_3_message_policy.adb:113-117` and `:94-96`,
  `src/flyology-http-http_3_client_connection.adb:355-357` and `:411-421`
- **Repro:**
  `./tests/repros/run.sh flyology-http-http_3_message_policy-repro_h3_qpack_11`
  (exit 1, BUG REPRODUCED)
- **What is wrong:** `On_Response_Frame` rejects a DATA frame whenever `Body_Allowed` is
  False, with no exemption for `Data_Length = 0`. A zero-length DATA frame transfers no
  content, so it does not offend RFC 9110 section 6.4.1, and RFC 9114 does not list it
  among the malformed conditions. The spike confirms `MESSAGE_ERROR` for HEAD, 204 and 304.
- **Notes:** The layer disagreement is also confirmed, by reading:
  `http_3_client_connection.adb:355-357` sets `Body_Forbidden` for `204 | 205 | 304`
  including 205, while the proved policy's `Body_Allowed` excludes only 204 and 304. The
  spike records that the policy permits a body on 205; the resulting controller-versus-
  policy divergence was not separately reproduced. Commit 80e7f6b made this repository's
  HTTP/2 client accept exactly the shape HTTP/3 rejects, so the two families disagree; that
  change was driven by the repository's own `tests/http2_peer.py` and no stock server was
  identified. The 205 resolution is a maintainer decision (RFC 9110 section 15.3.6 suggests
  the controller is right and the policy should change), but it adds no new value.
  `http_3_message_policy` is proved.

### H3-QPACK-12: legal QPACK inputs rejected

- **Severity:** P2 (discovery said P2; unchanged; discovery's "low" confidence applied to
  whether a stock encoder emits either input, and the code behaviour is now certain)
- **Location:** `src/flyology-http-http_3_stream_receive_policy.adb:169-174`,
  `src/flyology-http-qpack_field_section_policy.adb:256-262`
- **Repro:**
  `./tests/repros/run.sh flyology-http-http_3_stream_receive_policy-repro_h3_qpack_12`
  (exit 1, BUG REPRODUCED)
- **What is wrong:** (a) Every byte on the peer's QPACK encoder stream is refused with
  `QPACK_Encoder_Stream_Error`, which maps to `0x201` and a connection close. With the
  advertised capacity limit at zero, `0x20` (Set Dynamic Table Capacity 0) is the one legal
  capacity and a conformant no-op; RFC 9204 section 4.3.1 reserves that error for a
  capacity that exceeds the limit. (b) Any nonzero Delta Base is `Invalid_Prefix`, although
  RFC 9204 section 4.5.1.2 gives Base = ReqInsertCount + DeltaBase with Sign 0 and
  constrains only that "The value of Base MUST NOT be negative"; Required Insert Count 0
  with Delta Base 1 gives Base 1.
- **Notes:** The spike carries a control for part (b): the identical section with Delta
  Base 0 decodes, so neither the field count nor the static index is the variable. All RFC
  text was fetched from rfc-editor.org and re-checked against the published text during
  drafting. Practical impact is small: with a zero-capacity dynamic table a nonzero Base
  addresses nothing, so only a gratuitously-emitting encoder is affected, and no such peer
  was identified. No maintainer decision needed; this is a correction of two conditions to
  the ones the RFC states. Both units are proved, and the prefix decoder carries bounds
  contracts on `Position` and `Consumed`.

### H3-QPACK-13: stale Stream_Reset re-emission above stream identifier 4092

- **Severity:** P2 (discovery said P2; unchanged; discovery's "medium-low" confidence is
  superseded, since the behaviour is deterministic and the boundary is demonstrated with a
  control)
- **Location:** `src/flyology-http-http_3_connection.adb:426-440`, `:155-160`, `:173-179`,
  `:105-114`, `.ads:18`; pump at `src/flyology-http-client-http_3_internals.adb:320-346`
- **Repro:** `./tests/repros/run.sh repro_h3_qpack_13 180` (exit 1, BUG REPRODUCED)
- **What is wrong:** On `Header_Error` the client role sets `Finished`, emits
  `Stream_Reset` and returns without consuming the offending bytes. `Abandon_Message`
  records a tombstone only when `ID / 4 <= Message_Ordinal'Last = 1023` and releases the
  QUIC stream only when it is complete or peer-reset. For a higher identifier on a stream
  the peer keeps open, `Is_Released_Message` stays false, `Poll` reaches `Find_Or_Open`,
  a fresh slot is opened for the same ID, the same bytes are reparsed and the same event
  is emitted again. The composable pump exits on any `Succeeded` event and calls
  `Receive_One` only on `No_Event`, so the peer's eventual RESET_STREAM is never read.
- **Notes:** This is a controlled experiment: the identical malformed response through the
  identical code path is reported **once** on stream 0 and **eight times in eight polls**
  on stream 4100, with the stream identifier as the only difference, and cancelling after
  each event (as the real pump does) does not stop it. The synchronous path avoids the spin
  by marking the pooled connection unusable and closing it
  (`src/flyology-http-client.adb:2165-2169`), at the cost of sibling exchanges. P2 stands
  because reaching it needs 1,025 requests on one connection plus a peer that answers
  malformed and leaves the stream open. The fix touches the same procedure as H3-QPACK-10.
  `Max_Message_Tombstones` is a visible capacity in a private specification, so its
  disposition is a maintainer decision, but enlarging it is not a fix. Not a proved unit.

### H3-QPACK-14: 204 or 1xx with Content-Length is treated as malformed

- **Severity:** P2 (discovery said P2; unchanged)
- **Location:** `src/flyology-http-http_3_header_policy.adb:414-418`,
  `src/flyology-http-http_3_client_connection.adb:367-373`
- **Repro:**
  `./tests/repros/run.sh flyology-http-http_3_header_policy-repro_h3_qpack_14`
  (exit 1, BUG REPRODUCED)
- **What is wrong:** `Validate_Response` sets `Invalid_Content_Length` when a response
  carries `content-length` together with an interim status or 204. RFC 9110 section 8.6
  constrains the sender only, and RFC 9114 section 4.1.2's list of malformed conditions
  does not include it. Drafting found a stronger citation than discovery had: RFC 9114
  section 4.1.2 states that "A response that is defined as never having content, even when
  a Content-Length is present, can have a non-zero Content-Length header field even though
  no content is included in DATA frames", so the specification explicitly contemplates the
  case and declines to call it malformed. Frameworks that emit `content-length: 0` on a 204
  are therefore unreachable over HTTP/3.
- **Notes:** The spike's control shows the identical field on a 200 validating, so
  content-length parsing is not the variable. The client controller enforces the 204 half
  independently at `http_3_client_connection.adb:367-373`, so a fix must touch both layers.
  No maintainer decision needed; `Invalid_Content_Length` stays for the syntax and
  duplication cases. `http_3_header_policy` is proved. No specific peer emitting this shape
  over HTTP/3 was identified, and the issue body says so.

### Coverage evidence

Read: the HTTP/3 server driver `src/flyology-http-server-http_3.adb` (2149 lines) and its
specification; `src/flyology-http-http_3_connection.adb` (1354) and
`src/flyology-http-http_3_client_connection.adb` (710) with their specifications;
`src/flyology-http-http_3.adb`/`.ads`; `src/flyology-http-client-http_3_internals.adb`;
the credit and cancel regions of `src/flyology-http-client.adb`; the eleven proved policy
units named above; and, for facts rather than review,
`flyology_quic/src/flyology-quic-connections.ads`,
`flyology-quic-application_space.adb:795-897`,
`flyology-quic-stream_reassembly_policy.ads` and `flyology-quic-flow_control_policy.ads`.

Executed: all fourteen spikes were re-run at commit `f078732` during drafting, sequentially
under the harness build lock. All fourteen print `BUG REPRODUCED` and exit 1, and the
output quoted in each issue body is from that run, not copied from the verification report.
Two spike outputs differ cosmetically from the verification report because the spikes now
carry the corrected hand encoder and its positive control: `repro_h3_qpack_3` now reports a
297-byte 33-field section (was 294) on stream 4 (was stream 0) and prints an extra control
check, and `repro_h3_qpack_10` likewise reports its control. The substance is unchanged.

Suites and peers bearing on this area: `tests/http3_server_integration.adb`,
`tests/http3_public_smoke.adb`, `tests/http3_client_composable_smoke.adb`,
`tests/http3_h3spec_server.adb`, `tests/http3-conformance.md`, every
`tests/flyology-http-http_3_*-smoke.adb` and `tests/flyology-http-qpack_*-smoke.adb`, the
oracle drivers under `tests/oracle/`, `build/oracle/h3spec-report.log`, and the vendored
aioquic and quic-go peers. `review/baselines/10-http3-interop.log` records PASS in both
roles and does not contradict any finding here, for the reasons given under H3-QPACK-1 and
H3-QPACK-2: the interop lane never moves a body or a frame near the relevant bounds. No
maintained script was run by this area; `tests/repros/run.sh` was the only build entry
point.

Could not be exercised: the Chrome cookie-crumbling trigger in H3-QPACK-3, which needs a
real browser; named third-party peer behaviour in H3-QPACK-8, which needs a concurrent
HTTP/3 origin; the controller-versus-policy 205 divergence in H3-QPACK-11, confirmed by
reading only; and the secondary raisers listed under H3-QPACK-6, also confirmed by reading
only. The quic-go claim in H3-QPACK-2 *was* settled, against vendored source at
`~/go/pkg/mod/github.com/quic-go/quic-go@v0.54.1/http3/`, re-verified during drafting at
`response_writer.go:27,177,181` and `request_writer.go:22`.

### Refuted and not counted

Nothing was refuted in this area: all fourteen candidates reproduced. Two sub-claims were
narrowed rather than refuted, both recorded above: H3-QPACK-3's browser trigger (unverified,
severity lowered to P1) and H3-QPACK-8's reach (needs a concurrent origin, which this
repository's own server is not, because `Serve_Connection` dispatches one request at a
time).

Areas reviewed with no findings: frame legality per stream kind; SETTINGS decoding
including reserved and greased identifiers and the mandatory-first-SETTINGS rule;
unidirectional stream type handling including duplicate control and QPACK streams, push
streams at a server, and closing a critical stream; frame length arithmetic, where the
62-bit length is compared before narrowing and no overflow path exists; QPACK prefixed
integers, where the pre-multiply check prevents wrap-around; static table bounds and
content against RFC 9204 Appendix A; Huffman decoding including EOS, padding and output
bounds; header validation covering pseudo-header order, duplicates, CONNECT shape,
uppercase names, control characters, connection-specific fields, `te`, content-length
syntax and `:status` shape; GOAWAY identifier validation in both roles; tombstone table
wrap, where only IDs 0..4092 use the table and higher IDs defer to `Is_Stream_Retired`
(the residual gap is H3-QPACK-13); and server request reconstruction, where the proved
validator guarantees no header injection into `Header_Block`.

Observations recorded but outside the rubric: the policy values themselves
(`Maximum_Buffered_Request_Body` 1 MiB, `Max_Fields` 32, `Max_Value_Length` 16 KiB,
`Max_Encode_Length` 1,109, `Maximum_Request_Streams` 8, `Response_Chunk_Size` 1,024) are
choices rather than defects, and appear above only where a finding turns on one; there is
no post-handshake idle or per-request receive deadline shorter than `Max_Connection_Age`,
so a peer that trickles a body holds one of eight request slots for up to 300 s;
`src/flyology-http-qpack_field_section_policy.ads:7-8` says Huffman strings are reported as
an error "until Huffman decoding is enabled" although the body decodes them;
`http_3_connection.adb:405-408` (`Length > Max_Event_Data`) is unreachable because the
reassembly window is 16 KiB, so `Frame_Too_Large` cannot arise from `Poll`; a truncated
SETTINGS payload is `Settings_Error` (0x109) where RFC 9114 section 7.1 would suggest
`Frame_Error` (0x106), which is a diagnostics-only difference; the server ignores `:scheme`
and reports every HTTP/3 exchange as `Secure_HTTPS` (`server-http_3.adb:1560`); the client
does not send CONNECTION_CLOSE with the HTTP/3 error code when it abandons a connection on
a `Poll` failure and does not distinguish `H3_REQUEST_REJECTED` resets for transparent
retry although the public API documents that reason; `Valid_Value` accepts leading and
trailing whitespace, which RFC 9110 section 5.5 treats as a parsing concern rather than a
validity requirement; and `Dispatch_Request` computes the handler deadline from
`Headers_Received`, so a slow upload can hand the handler an already-expired deadline.

## QUIC-TRANSPORT

This area covers the QUIC transport implementation in the nested `flyology_quic` crate: the connection driver and the three packet-number spaces, the public `Connections` facade, and the 27 `SPARK_Mode => On` policy units that carry the codecs, loss recovery, flow control and stream state. Discovery read the four drivers and the `Connections` facade in full, every proved policy unit's spec and body, the HTTP-crate consumers that reach them, and the crate's own `qualification.md`; verification reproduced all of it in eleven spikes built as child units of the private driver and application-space packages. Eleven findings are confirmed and none is refuted: one P0, four P1 and six P2. This crate was never covered by any previous audit, so none of these is a repeat and none is a regression; four of them sit in areas `qualification.md` itself already lists as not yet qualified, which is a statement about test coverage rather than about intended behaviour.

### QUIC-TRANSPORT-1: No anti-amplification limit before address validation

- **Severity:** P0 (discovery said P0; kept, but on the measured ratios, not the estimated ones)
- **Location:** `flyology_quic/src/flyology-quic-connection_driver.adb:976-985` and `:1523-1526`, `flyology_quic/src/flyology-quic-connections.adb:319-326`, `src/flyology-http-server-http_3.adb:2090-2099`
- **Repro:** `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_transport_1` (exit 1, BUG REPRODUCED, 5 of 6 checks fail)
- **What is wrong:** No state anywhere in the crate counts bytes received from or sent to a peer address. An exhaustive search settled the absence: the vocabulary sweep finds only the client-side `Peer_Validated` flag, which feeds `Has_Handshake_Timeout` and counts nothing; all four connection-state records were read in full and hold no byte counters; every occurrence of 1,200 in the crate is send-side padding or a transport-parameter floor; and Retry and address-validation tokens are not implemented, so there is no alternative mechanism. Separately, nothing enforces the RFC 9000 section 14.1 minimum on a received Initial, so a 216-byte datagram is accepted and answered in full.
- **Notes:** The discovery entry's ratio estimate for the default configuration is **refuted**. The measured values are 1.73x for a compliant 1,200-byte Initial against the pinned 320-byte test certificate, which is inside the three-times limit; 3.61x at a 1,024-byte certificate; 11.52x at 4,096 bytes; 9.64x for a 216-byte Initial against the pinned certificate; and 64.05x for 216 bytes against 4,096. The flight is 2 datagrams and 698 bytes, not the "up to 18,000 octets across up to 20 datagrams" discovery assumed, and three flights fit the 3.0 s handshake idle budget, not four. The certificate is copied into the Certificate message unparsed and carried by each of the three flights, so the break-even is about 825 bytes: an ordinary CA-issued leaf exceeds 3x even against a fully padded Initial, which is what makes this a production concern rather than only a spoofed-small-packet concern. aioquic 1.3.0 implements the same accounting in one line at `quic/connection.py:209`, cited in the issue as prior art. `flyology-quic-connections-recovery_smoke.adb:148-160` pins the current unbudgeted retransmission and must change. An uncounted side effect of the same missing mechanism: each spoofed Initial also holds one of the 256 listener slots for 3.0 s, so 256 datagrams occupy the whole listener; noted in the issue's Severity rather than filed twice. The three-times factor and the 1,200-byte minimum are externally mandated, so no maintainer decision is needed; the issue asks instead that their authority be recorded near the declaration.

### QUIC-TRANSPORT-2: The 64-entry sent-packet ledger fails large transfers and refuses probes

- **Severity:** P1 (discovery said P1; kept)
- **Location:** `flyology_quic/src/flyology-quic-application_space.adb:417-436`, `:695-705`, `:1087-1095`; `flyology_quic/src/flyology-quic-connection_driver.adb:1629-1645`; `src/flyology-http-http_3_connection.adb:39-48`
- **Repro:** `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_transport_2` (exit 1, BUG REPRODUCED, 2 of 2 checks fail)
- **What is wrong:** Every send path tests `Retained = Max_Sent_Packets` (64) before it asks `Recovery_Policy.Can_Send`. NewReno slow start has no ceiling, so after three round trips the window passes 64 packets and the ledger becomes the binding limit, returning `Recovery_Capacity_Exceeded`. `Send_Status_For`'s `when others` arm maps that to `Transport_Error`, `Send_Data` and `Flush_Pending_Responses` raise `Device_Error` on anything but `Transport_Blocked`, and the owner closes with H3_INTERNAL_ERROR. The spike measures the transition exactly: rounds 1 to 3 stop at 10, 20 and 40 packets with `CONGESTION_BLOCKED`, which is correct backpressure, and from round 4 the sender stops at 64 with `RECOVERY_CAPACITY_EXCEEDED` after about 77 KB. The probe path is worse than discovery stated: `Process_Timeout` returns `Timeout_Packet_Error` without backing off, and `Server.HTTP_3.Process_Recovery` raises `Device_Error` on any status other than `Probes_Ready`, `Not_Due` or `No_Pending_Recovery`.
- **Notes:** The verifier established that this and **H3-QPACK-2** are on opposite sides and neither masks the other: the 16 KiB reassembly ceiling is a receive-side limit on the Ada endpoint, this is a send-side limit, and the crate frames responses in 1,024-byte DATA chunks (`Response_Chunk_Size`, `src/flyology-http-server-http_3.adb:46`) so the ceiling never gates the sender. The ring does explain why the Ada-versus-Ada lanes never reach the ledger, so the two share a cause of the coverage gap; both are filed and the bodies cross-reference. The fix splits into a mechanical part (order the tests, map the status to backpressure, reserve a probe entry) and a maintainer decision about `Max_Sent_Packets`, a visible constant in `flyology-quic-sent_packet_policy.ads:22` that sizes the tracking arrays. `flyology-quic-sent_packet_policy-smoke.adb:87-99` pins the bound at the policy level and must change if the bound does. Both `sent_packet_policy` and `recovery_policy` are proved units.

### QUIC-TRANSPORT-3: Initial keys are never discarded

- **Severity:** P1 (discovery said P1; kept). P0 was considered and rejected: the attacker must first have observed the client's original Destination Connection ID, so this is not a blind off-path reset.
- **Location:** `flyology_quic/src/flyology-quic-connection_driver.adb:1382-1396`, `:906-911`, `:1029-1033`; `flyology_quic/src/flyology-quic-initial_space.adb:504-510`; `src/flyology-http-server-http_3.adb:112-123`
- **Repro:** `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_transport_3` (exit 1, BUG REPRODUCED, 2 of 4 checks fail)
- **What is wrong:** No endpoint has a "keys discarded" flag. `Scan_Datagram` dispatches Initial packets in every state, and `Process_Initial_Packet` honours `Processed.Peer_Closed` at `:906-911`, before the state check at `:1029-1033` runs at all. The spike builds a fresh Initial codec from nothing but plaintext wire values, advances past the replay window, protects a transport CONNECTION_CLOSE with the RFC 9001 section 5.2 keys, and both an established server and an established client report `Connection_Closed` and move to `Peer_Closed`. On the server side the listener registry resolves the forged datagram to the live slot on peer address plus a plaintext connection ID, so a spoofed source address reaches the worker; on the client side no registry is involved.
- **Notes:** This is the primary for **QUIC-TLS-1**, which the QUIC-TLS discovery reviewer found independently at the same site. QUIC-TLS-1 is folded into this body as a second reporting (the `Fail_Initial_With_Close` route for a conflicting CRYPTO frame or an ACK of an unsent packet) and no separate body was written. QUIC-TLS-1's quotation of RFC 9001 section 4.9.1, "packets protected with Initial keys received after this point are discarded", is a **paraphrase that is not in the RFC**; the body uses the real sentence about discarding keys plus the section's own rationale about spoofed packets. `qualification.md:137` already lists key discard as not covered. No existing test asserts the current behaviour.

### QUIC-TRANSPORT-4: A client fails on any post-handshake CRYPTO except one complete ticket at offset 0

**Also reported independently as QUIC-TLS-2.** The two are one defect at one site. The
filed issue carries the QUIC-TLS entry's body, which establishes that this client
advertises no `psk_key_exchange_modes`, so a server honouring RFC 8446 section 4.2.9
sends it no ticket at all and the multiple-ticket shapes are narrower than they look.
The split ticket is the reachability that does not depend on any peer's ticket policy.

- **Severity:** P1 (discovery said P1; kept)
- **Location:** `flyology_quic/src/flyology-quic-application_space.adb:1333-1349`; consumed at `flyology_quic/src/flyology-quic-connection_driver.adb:580` and `:1328-1332`
- **Repro:** `./tests/repros/run.sh flyology-quic-application_space-repro_quic_transport_4` (exit 1, BUG REPRODUCED, 3 of 4 checks fail)
- **What is wrong:** The application space judges each 1-RTT CRYPTO frame in isolation and accepts it only when the local role is client, the offset is 0, the first handshake byte is 4, and the declared body length equals the frame payload minus four. All three shapes a compliant server may produce fail that test: a second ticket at the next offset in the continuous CRYPTO offset space, two tickets sharing one frame, and one ticket split across two frames. Each becomes `Unexpected_TLS_Message`, CRYPTO_ERROR 0x10A and a CONNECTION_CLOSE, so a client connection fails after its handshake completed.
- **Notes:** Which stock TLS servers emit more than one ticket or split one across frames is **not verified against a peer**; the body says so in the same sentence as the claim and the Severity does not rest on it. The interop baseline is silent because neither oracle sends a post-handshake ticket in the qualified configuration. `flyology-quic-application_space-smoke.adb:418-459` pins the current behaviour for one ticket at offset 0 (`:445`) and for a KeyUpdate (`:458`); the ticket assertion must be extended and the KeyUpdate one must keep holding. The suggested fix reuses the already-proved `crypto_reassembly_policy`, and the buffering bound it needs is flagged as a maintainer decision.

### QUIC-TRANSPORT-5: `Transport_Settings` advertised unclamped against fixed reassembly bounds

- **Severity:** **P1 (raised from discovery's P2)** because `Transport_Settings` is a **public parameter** of `Serve_Listener` and `Serve_HTTP_3` (`src/flyology-http-server-http_3.ads:66`, `:103`, `:142`; `src/flyology-http-server-routing.ads:998`, `:1060`, `:1131`, `:1202`), its field is documented as "Receive credit on peer bidi streams", it is typed over the whole varint range, and no `.ads` text says the defaults are ceilings. A caller who raises it closes compliant peers with transport error 0x01.
- **Location:** `flyology_quic/src/flyology-quic-connections.adb:191-199`; `flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:18` and `.adb:72-76`; `flyology_quic/src/flyology-quic-stream_table_policy.ads:17`; `flyology_quic/src/flyology-quic-connection_driver.adb:581-582`
- **Repro:** `./tests/repros/run.sh repro_quic_transport_5` (exit 1, BUG REPRODUCED, 2 of 3 checks fail)
- **What is wrong:** `Encode_Parameters` copies each setting straight into the transport parameters with no comparison against `Max_Stream_Data` (16,384) or `Max_Streams` (32). With `Max_Stream_Data_Bidi_Remote => 32_768` the server accepts 16,500 of the 19,800 bytes the client sends inside the advertised credit and then transitions to `Failed`, via `Exceeds_Capacity` to `Stream_Data_Too_Large` to INTERNAL_ERROR.
- **Notes:** This is a "Decision authority" case in the strict sense: the ceiling exists but is implicit, and making it explicit means choosing where it lives. The body lists the full option set (private value with rejection, caller parameter, generic formal on the reassembly policy, discriminant, credit derived from the reassembly type's own bound, build-time configuration, deliberately public constant) and does not choose; it also asks that the `.ads` comment state the accepted range either way. No coverage exists because every maintained lane uses `Transport_Settings'(others => <>)`, whose 16,384 default equals the ring exactly. `stream_reassembly_policy` and `stream_table_policy` are proved units.

### QUIC-TRANSPORT-6: STOP_SENDING is validated and dropped

- **Severity:** P2 (discovery said P2; kept). P1 was considered because the reachability is far higher than discovery stated, but nothing fails: the peer discards the data it asked to stop and the connection survives. Wasted work, not a wrong result.
- **Location:** `flyology_quic/src/flyology-quic-application_space.adb:1392-1402`; `flyology_quic/src/flyology-quic-application_space.ads:241-252`
- **Repro:** `./tests/repros/run.sh flyology-quic-application_space-repro_quic_transport_6` (exit 1, BUG REPRODUCED, 2 of 3 checks fail)
- **What is wrong:** `Check_Stop_Sending` runs as an admission check and the branch then falls through. `Stop_Sending` appears nowhere else in the body and `Process_Result` has no field for it, so no higher layer can act either. The spike decrypts the next outgoing packet and finds only an ACK, and the local sender can still put more data on the cancelled stream.
- **Notes:** Reachability was checked **against the pinned oracles' own sources, not a new peer run**. quic-go 0.54.1 **does** send STOP_SENDING in ordinary use: `http3/body.go:70` on an early response-body close and `http3/server.go:674` on every handler that does not drain the request body, with `receive_stream.go:379-392` gating it. aioquic 1.3.0 sends it when the application aborts a read. **The interop lane passing is not evidence the peers do not send it**: the oracle calls `io.ReadAll` at `tests/oracle/quic-go/main.go:131` before closing, which makes `CancelRead` a no-op. A downstream flow-control stall (quic-go stops issuing MAX_STREAM_DATA for an abandoned stream, so an Ada server streaming a large response onto a cancelled stream would sit in `Wait_For_Transport`) is **not verified against a peer** and is stated as such. Surfacing the frame adds a `Process_Result` field or a new status, so the body flags a maintainer decision. `qualification.md:141` lists reset/stop semantics as not covered. The RESET_STREAM encoder already exists (`Encode_Stream_Abort`, used by `Build_Stream_Abort_Packet`).

### QUIC-TRANSPORT-7: PATH_CHALLENGE is parsed and ignored

- **Severity:** P2 (discovery said P2; kept). An unambiguous MUST, but it needs a path change to be reached, and `qualification.md:144` already lists NAT rebinding and path validation as not qualified.
- **Location:** `flyology_quic/src/flyology-quic-application_frame_policy.adb:386-395` parses it; `flyology_quic/src/flyology-quic-application_space.adb:1283-1512` has no branch for it
- **Repro:** `./tests/repros/run.sh flyology-quic-application_space-repro_quic_transport_7` (exit 1, BUG REPRODUCED, 1 of 2 checks fails)
- **What is wrong:** Both 0x1A and 0x1B decode into frame kinds that the application space never matches, so the frame is counted as ack-eliciting and discarded. The spike decrypts the next outgoing packet and finds only an ACK. After a NAT rebinding a stock peer challenges the new address, never gets a response, and cannot use the unvalidated path beyond the anti-amplification limit, so the connection blackholes until its idle timeout.
- **Notes:** Checked against the pinned oracles' sources rather than a new peer: **neither peer challenges a stable path**, so that lane is genuinely silent rather than merely passing. aioquic creates a client path pre-validated in `connect()` and validates a server path on a Handshake-epoch packet; quic-go challenges only a new remote address or a probed alternative path. Both would challenge a rebound path. While checking aioquic for this, the verifier also found `QuicNetworkPath.can_send` at `quic/connection.py:209`, which is exactly the accounting QUIC-TRANSPORT-1 lacks; it is cited there. Holding pending challenges needs a bound, flagged as a maintainer decision. `application_frame_policy` is a proved unit, so a PATH_RESPONSE encoder lands inside the proof.

### QUIC-TRANSPORT-8: The server's ack-eliciting Initial datagram is not expanded to 1,200 bytes

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_quic/src/flyology-quic-initial_space.adb:141-142` and `:336-340`; `flyology_quic/src/flyology-quic-connection_driver.adb:956-969`
- **Repro:** `./tests/repros/run.sh repro_quic_transport_8` (exit 1, BUG REPRODUCED, 1 of 3 checks fails)
- **What is wrong:** `Minimum` is 1,200 for a client and 0 for a server at both the emit site and the transport-close site, and the ServerHello Initial is appended as its own datagram rather than coalesced. The measured server Initial datagram is 142 bytes and carries CRYPTO, so it is ack-eliciting and exactly the case section 14.1 names. The comment at the second site states only the receive-side half of the rule.
- **Notes:** Stock clients do not discard a small server Initial, so this is not interop-breaking on its own. It is also the reason case A of QUIC-TRANSPORT-1 stays under 3x, so the two bodies cross-reference and the note says they should be resolved together: padding the server flight without adding the accounting would push the compliant case over the limit. No new value is introduced by the fix, since 1,200 is already declared. `connection_driver-smoke.adb:189-192` asserts the client side only. First bytes in the spike output vary per run because the long header is protected; the lengths are stable.

### QUIC-TRANSPORT-9: An ACK frame with 64 or more ranges closes the connection

- **Severity:** P2 (discovery said P2; kept). Reachability depends on the peer's own ACK-range cap, which is not verified against a peer here.
- **Location:** `flyology_quic/src/flyology-quic-ack_range_policy.adb:64-66` and `.ads:18`; `flyology_quic/src/flyology-quic-application_space.adb:1452-1460`; `flyology_quic/src/flyology-quic-connection_driver.adb:576-578`
- **Repro:** `./tests/repros/run.sh flyology-quic-application_space-repro_quic_transport_9` (exit 1, BUG REPRODUCED, 1 of 4 checks fails)
- **What is wrong:** `Decode` tests `ACK_Range_Count >= Max_Ranges` before any validity check, so a well-formed frame is refused purely on its range count and answered with CONNECTION_CLOSE PROTOCOL_VIOLATION. The spike put 200 real packets behind the sender, acknowledging every eighth so neither the congestion window nor the QUIC-TRANSPORT-2 ledger interferes, and every range names a packet the sender really sent: 62 and 63 ranges are processed, 64 is rejected. RFC 9000 section 19.3 sets no maximum, and section 13.2.3 constrains what an endpoint emits, not what it accepts.
- **Notes:** `Max_Ranges` is a visible constant in a **proved** unit that sizes the decoded array and two subtypes, so both the truncation strategy and the constant's value and visibility are a maintainer decision; the body lists the options and does not choose. The fix falls inside `flyology-quic-ack_range_policy.adb`, which `./scripts/prove.sh` proves, and must keep discharging with `--checks-as-errors=on`; that is the main constraint on how the truncation is written. `ack_range_policy-smoke.adb:42-47` pins the current rejection and must change. The same mapping exists in the Initial and Handshake spaces.

### QUIC-TRANSPORT-10: Connection-ID transport parameters are never compared with the wire CIDs

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_quic/src/flyology-quic-connections.adb:185-187` (the only non-codec uses); `flyology_quic/src/flyology-quic-connection_driver.adb:755-777`
- **Repro:** `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_transport_10` (exit 1, BUG REPRODUCED, 2 of 3 checks fail)
- **What is wrong:** `Transport_Parameter_Policy.Decode` checks presence and role only, and `Initialize_Application` reads the peer parameters for the ACK delay exponent and maximum ACK delay without comparing the connection IDs. The spike runs three handshakes differing only in the server's authenticated parameters, leaving the wire connection IDs correct: a server claiming a wrong `original_destination_connection_id` and one claiming a wrong `initial_source_connection_id` both complete the handshake.
- **Notes:** RFC 9000 section 7.3 makes the validation a MUST and a mismatch a connection error of type TRANSPORT_PARAMETER_ERROR or PROTOCOL_VIOLATION. Stays P2 because the practical effect is a missing diagnosis rather than a wrong result: on-path tampering with an Initial packet's connection IDs is not detected, and the handshake either succeeds or fails later with an unrelated status such as `Unexpected_Destination`. The fix is a comparison in the driver and introduces no new value, so no maintainer decision is needed. `transport_parameter_policy-smoke.adb` covers presence and role rules only.

### QUIC-TRANSPORT-11: Packet-driven operations dereference an uninitialized connection

- **Severity:** P2. Raised during verification; discovery recorded it under "Observations not counted". Numbered because it is a reproducible contract violation and because it was worth settling whether it is a memory-safety problem. It is not.
- **Location:** `flyology_quic/src/flyology-quic-connections.adb:416-420` (and every other packet-driven operation); documented contract at `flyology_quic/src/flyology-quic-connections.ads:314`
- **Repro:** `./tests/repros/run.sh repro_quic_transport_11` (exit 1, BUG REPRODUCED, 1 of 4 checks fails)
- **What is wrong:** `State`, `Is_Connected`, `Received_Data`, `Handshake_Confirmed` and `Has_Recovery_Timeout` guard the null backend; `Start_Client`, both `Process_Datagram` overloads, `Process_Timeout`, `Open_Stream` and all `Build_*_Datagram` procedures do not. The result is `Constraint_Error` from the access check at `connections.adb:417` where `Operation_Status` documents `Invalid_State` and `State` reports `Uninitialized`.
- **Notes:** Not a memory-safety issue: `flyology_quic/config/flyology_quic_config.gpr` builds `-O3 -gnatn` with no `-gnatp`, so the check is present in the release profile too. Not reachable through the maintained HTTP/3 server, because `Serve_Connection` raises `Protocol_Error` when initialisation does not return `Initialized`, before any `Process_Datagram` call, and the worker catches it. The alternative fix, stating `Pre => State (Item) /= Uninitialized` on each operation, is a public contract change, so the body presents both and does not choose.

### Coverage evidence

Read in full: `connection_driver` spec and body, `application_space`, `initial_space`, `handshake_space` (as a diff against the Initial space), `connections`, the three per-level connection packages, and all 27 proved policy units' specs and bodies. Read in region: the HTTP-crate consumers in `flyology-http-http_3_connection.adb`, `flyology-http-server-http_3.adb`, `flyology-http-client-http_3_internals.adb` and `flyology-http-client.adb`. Executed: eleven spikes, all reproducing, six of them child units of the private `Connection_Driver` or `Application_Space` packages as `tests/repros/README.md` prescribes; the harness self-tests `repro_smoke` and `seam_check` still PASS alongside them. Bearing on this area: `flyology_quic/tests/src/*` (the policy smokes, `connection_driver-smoke`, `connections-recovery_smoke`, `tls_transport_smoke`), the HTTP crate's `tests/http3_public_smoke.adb`, `tests/http3_interop_server.adb` and `tests/flyology-quic-test_connections.adb`, `scripts/test-http3-interop.sh`, and `review/baselines/10-http3-interop.log` with the pinned aioquic 1.3.0 and quic-go 0.54.1 oracles. `flyology_quic/tests/qualification.md` was read and is cited where it already declares a gap.

Not exercised: no new peer run was made. Peer behaviour for QUIC-TRANSPORT-6 and QUIC-TRANSPORT-7 was established by reading the pinned oracles' own sources, which is stated as such in both bodies; QUIC-TRANSPORT-4's peer breadth (which TLS servers send multiple or split tickets) and QUIC-TRANSPORT-9's reachability (whether any stock peer emits 64 ACK ranges) remain unestablished and both Severity sections say so. No NAT rebinding, no live amplification measurement against a real victim address, and no sustained-loss network lane were run.

Every finding is located in an unproved driver or in an HTTP-crate consumer, except QUIC-TRANSPORT-9, whose defect is a proved unit's contract choice consumed fatally by the driver, and QUIC-TRANSPORT-5, where one fix option would move a bound into proved units. `./scripts/prove.sh` was read rather than assumed: the proved set is the 27 units in `flyology_quic/scripts/prove.sh` plus the 22 HTTP-crate units in `scripts/prove.sh`. `connection_driver`, `application_space`, `initial_space`, `handshake_space` and `connections` are **not** proved, contrary to what a casual reading of the crate's proof status might suggest.

### Refuted and not counted

Nothing was refuted at the level of "this defect does not exist"; all eleven are confirmed. One numeric claim was refuted: the amplification ratio QUIC-TRANSPORT-1's discovery entry estimated for the compliant default configuration ("about 3.3-4.7x" against a 1,200-byte Initial with the pinned certificate). The measured value is 1.73x and is inside the limit. The estimate was wrong in two ways, both corrected in the body: the server flight is 698 bytes over 2 datagrams rather than up to 18,000 octets over 20, and three flights fit the idle budget rather than four. The limit is exceeded through the missing section 14.1 minimum or through a certificate above about 825 bytes.

Observations recorded and left outside the rubric: no loss timer is armed for the RFC 9002 section 6.1.2 time threshold, which the RFC makes a SHOULD; persistent congestion is not implemented and `Application_Limited` is always False; connection-level MAX_DATA is always `committed + Max_Data`, so connection-level flow control never applies backpressure; Version Negotiation, Retry, stateless reset, NEW_CONNECTION_ID, RETIRE_CONNECTION_ID and the QUIC idle timeout are absent and `qualification.md` declares them pending; a RETIRE_CONNECTION_ID with a sequence above any issued is silently accepted rather than treated as PROTOCOL_VIOLATION; a 1-RTT packet arriving before `Connected` is dropped rather than buffered, with the peer's PTO recovering it; and the sender sizes packet numbers as if nothing were ever acknowledged, capping a connection at 2^31 sent packets per space. The listener-slot exhaustion that follows from the missing address validation is folded into QUIC-TRANSPORT-1 rather than filed separately, since it is the same missing mechanism.

Areas discovery cleared and verification spot-checked without dispute: `Recovery_Policy` slow-start and `Can_Send` arithmetic (read in full while building the QUIC-TRANSPORT-2 spike), `Sent_Packet_Policy`'s `Acknowledges_Unsent_Packet` rule and `ACK_Range_Policy`'s ordering of checks (read in full for the QUIC-TRANSPORT-9 spike), and `Stream_Reassembly_Policy`'s capacity test (for QUIC-TRANSPORT-5). Nothing in them contradicted the discovery report's no-findings list, which also covers varint decoding, packet-number reconstruction, RTT and PTO arithmetic, loss detection, receive flow control and stream limits, transport parameter validation, the frame and envelope parsers, key update, the PR #20 to #22 handshake-recovery work, and the discard-without-closing rule for unauthenticated packets.

## QUIC-TLS

This area covers the TLS 1.3 handshake the QUIC crate implements in Ada: `TLS_Session`,
`TLS_Key_Schedule`, `TLS_Handshake_Policy`, `TLS_Extension_Policy`,
`TLS_Signature_Policy`, `TLS_Authentication_Policy`, `Crypto_Flight`,
`Crypto_Reassembly_Policy`, the OpenSSL binding `Crypto_OpenSSL` and its C bridge
`flyology_quic_openssl.c`, the parent crate's `Server.TLS` adapter and
`Server.Development_Certificates`, plus the parts of `Connection_Driver`,
`Application_Space`, `Initial_Space` and `Connections` that hold keys or map a TLS
status to a wire error code. Five entries came out of discovery; one is a duplicate of a
QUIC transport entry and is not filed, three are confirmed as written, and one is
confirmed in its code path but not in the peer breadth its discovery entry claimed. One
severity was raised. The single most important result in this area is not a finding: the
certificate-pinning path was attacked deliberately and held, including the man-in-the-middle
that replays the public pinned DER under a foreign key.

### QUIC-TLS-1: Initial keys are never discarded

- **Severity:** DUP, folded into `QUIC-TRANSPORT-3` and not filed. Discovery rated it P1
  in this area; the QUIC transport verifier owns the primary entry and the spike
  (`flyology-quic-connection_driver-repro_quic_transport_3`), and the filed issue is
  QUIC-TRANSPORT-3's.
- **Location:** `flyology_quic/src/flyology-quic-connection_driver.adb:1382-1409` and
  `:906-911`, `flyology_quic/src/flyology-quic-initial_space.adb:504-510`, routed from
  `src/flyology-http-server-http_3.adb:112-123`. The two entries cite the same lines.
- **Repro:** owned by QUIC-TRANSPORT; no second spike was written.
- **What is wrong:** `Scan_Datagram` dispatches long-header Initial packets in every
  connection state, `Process_Initial_Packet` acts on `Processed.Peer_Closed` before it
  reaches its state check, `Initial_Space.State` carries no "keys discarded" flag, and
  `Acknowledge_Flight` only stops retransmission. An observer of the client's first
  Initial can therefore compute the Initial keys and close an established connection in
  either role.
- **Notes:** the discovery entry's quotation of RFC 9001 section 4.9.1 is a paraphrase,
  not the RFC's wording: the sentence "packets protected with Initial keys received after
  this point are discarded" does not appear there. What section 4.9.1 says is that a
  client MUST discard Initial keys when it first sends a Handshake packet, that a server
  MUST discard them when it first successfully processes one, and that endpoints MUST NOT
  send Initial packets after that point; the security reason is given in the same section,
  that Initial-protected packets are not authenticated. QUIC-TRANSPORT-3's filed body
  should carry the corrected citation.

### QUIC-TLS-2: Client aborts on post-handshake CRYPTO that is not one whole NewSessionTicket at offset 0

**Folded into QUIC-TRANSPORT-4 and not filed separately.** The QUIC transport reviewer
found the same site independently. One issue is filed under the QUIC-TRANSPORT number,
and it carries this entry's body, which is the stronger of the two: it establishes that
the multiple-ticket shapes are narrower than they look for this client, because the
ClientHello advertises no `psk_key_exchange_modes` and a server honouring RFC 8446
section 4.2.9 therefore sends it no ticket at all. The reachability that survives that
gate is the split ticket. The detail below is retained for the record.

- **Severity:** P1 (discovery said P1; kept, with the peer-breadth claim withdrawn and the
  residual reachability restated)
- **Location:** `flyology_quic/src/flyology-quic-application_space.adb:1333-1349`, mapped
  at `flyology_quic/src/flyology-quic-connection_driver.adb:580` and closed at `:1328-1332`
  and `:606-608`
- **Repro:** `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_tls_2`
  (exit 1, BUG REPRODUCED, checks: 7 failures: 6), re-run at drafting time
- **What is wrong:** a 1-RTT CRYPTO frame is accepted only when `Crypto_Offset = 0`, the
  first body byte is handshake type 4, and the message's own three-byte length equals
  `Data_Length - 4`. There is no 1-RTT CRYPTO reassembly at all. Anything else is
  `Unexpected_TLS_Message`, which becomes CRYPTO_ERROR 0x10A and a CONNECTION_CLOSE, so a
  handshake that has just succeeded is destroyed. The spike reproduces it in three shapes:
  two tickets in one frame, a second ticket at offset 4, and one ticket split across two
  frames. All three leave the client `FAILED` after a `CONNECTED` handshake, and the
  accepted shape is kept as a passing control.
- **Notes:** the discovery entry's peer-breadth claim, that stock OpenSSL, quictls and
  BoringSSL servers trigger this by default because they send two tickets, does **not**
  hold as written, and the filed body says so in the same sentence as the claim. This
  client never advertises `psk_key_exchange_modes`
  (`flyology-quic-tls_extension_policy.adb:480-531` emits six extensions, none of them 45),
  and RFC 8446 section 4.2.9 says servers SHOULD NOT send NewSessionTicket incompatible
  with the advertised modes. Go 1.23.4 and aioquic 1.3.0 both implement that gate, verified
  by reading the pinned sources (`crypto/tls/handshake_server_tls13.go:829-845`,
  `aioquic/tls.py:1838-1841`); OpenSSL's behaviour is unverified, because no OpenSSL QUIC
  server is available on this host and no OpenSSL source tree is present. quic-go passes
  interop because it sends exactly one ticket at offset 0, which is the accepted case, and
  because Go's QUIC path bypasses the psk-mode gate; aioquic's oracle sends none. The
  residual reachability that depends on none of this is the SPLIT ticket, and the filed
  body's Severity leads with it. The same defect is `QUIC-TRANSPORT-4`, which is being
  filed separately by that area; both bodies should cross-reference, and the coordinator
  should decide whether to keep two issues for one code path.
- **Fix decision:** a reassembly buffer introduces a capacity, which is a maintainer
  decision under "Decision authority" and "Ada interface values"; the filed body lists the
  options and does not choose.

### QUIC-TLS-3: Handshake, master, exporter and traffic secrets are never wiped on the success path

- **Severity:** **P1** (discovery said P2; raised)
- **Location:** `flyology_quic/src/flyology-quic-tls_session.adb:789-791` (client) and
  `:850-853` (server), against `Mark_Failed` at `:33-46`;
  `flyology_quic/src/flyology-quic-tls_session.ads:148-175`;
  `flyology_quic/src/flyology-quic-connections.adb:29-30` and `:48-56`
- **Repro:** `./tests/repros/run.sh flyology-quic-tls_session-repro_quic_tls_3`
  (exit 1, BUG REPRODUCED, checks: 15 failures: 15), re-run at drafting time
- **What is wrong:** the success transitions clear only `X25519_Private`, the server's
  `Signing_Key` and a local `Resumption` temporary. All six fields of
  `Handshake_Secrets` and the `Application_Secrets.Exporter` survive on both roles at
  `Connected`, although their last consumers have already run and `TLS_Key_Schedule`
  exports a `Clear` for each. `Connections.Finalize` then releases the whole
  implementation block with `Unchecked_Deallocation` and nothing overwrites it.
- **Notes:** the raise from P2 to P1 rests on two things the discovery entry treated as
  hypothetical. First, the spike does not assume post-free exposure, it demonstrates it:
  it allocates the `Session` on the heap, records the master secret, releases it, and
  recovers the same 32 bytes from a freshly allocated block of the same size. That is an
  ordinary read of uninitialized storage the program owns, not a read of freed memory and
  not undefined behaviour. Second, and the stronger argument in the filed body, the crate
  already keeps this discipline: `Mark_Failed` clears every secret on the failure path, so
  the success path contradicts an internal contract the code holds elsewhere. It is still
  not P0: no remote peer can trigger or observe it and there is no memory-safety error.
  RFC 8446 mandates no erasure; RFC 9001 section 4.9 is directional only.
- **Fix decision:** the `Connected` half needs no decision. The finalization half does,
  because every option changes something declared in a specification (a controlled
  `Session`, a new `TLS_Session` wipe operation, or a block wipe in `Connections.Finalize`).
  The filed body lists the options and does not choose.

### QUIC-TLS-4: Server matches only the first ALPN entry of the ClientHello

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_quic/src/flyology-quic-tls_extension_policy.adb:220-224`,
  consumed at `flyology_quic/src/flyology-quic-tls_session.adb:180-189`, sent as 0x178 at
  `flyology_quic/src/flyology-quic-connection_driver.adb:945-951`
- **Repro:** `./tests/repros/run.sh flyology-quic-tls_session-repro_quic_tls_4`
  (exit 1, BUG REPRODUCED, checks: 2 failures: 1), re-run at drafting time
- **What is wrong:** `Parse_ALPN` walks the whole list but records only the first entry,
  and `Validate_Extensions` compares that one entry with the configured protocol. A client
  offering `["h3-29", "h3"]` to an `h3` server is refused with `ALPN_Mismatch` and closed
  with 0x178, although a mutually supported protocol was advertised. The spike patches the
  real ClientHello's ALPN body to the two-entry list and repairs both length fields; its
  control shows the same server accepts the unpatched single-entry Hello.
- **Notes:** the discovery entry's quotation of RFC 7301 section 3.2, "the server SHALL
  select a protocol from the list", is **wrong**. The RFC says the server "SHOULD select
  the most highly preferred protocol that it supports and that is also advertised by the
  client", and the SHALL applies to the `no_application_protocol` alert, whose trigger
  condition (the server supports none of the advertised protocols) is not met here. The
  filed body carries the corrected text and makes the point that the mandatory clause is
  being misapplied rather than the selection rule being violated. P2 stands because
  mainstream QUIC clients offer `h3` alone.
- **Proof:** `flyology-quic-tls_extension_policy.adb` is one of the units
  `./scripts/prove.sh` proves, through `flyology_quic/scripts/prove.sh`. The proof covers
  bounds and offsets, not which entry is reported, so it does not contradict the finding,
  but any fix must keep it discharging with `--checks-as-errors=on`. The filed body says so.
- **Fix decision:** recording more than one entry introduces a bound on `Parse_Result`,
  which is declared in a specification, and a preference-order policy. Both are maintainer
  decisions; the filed body lists the options, names a third route that needs neither
  (record the entry the caller asks for), and does not choose.

### QUIC-TLS-5: TLS failures close with internal_error (0x150) instead of the required alerts

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_quic/src/flyology-quic-connection_driver.adb:1108-1115`,
  `:945-951` and `:1160-1162`; the ALPN sub-claim's root cause at
  `flyology_quic/src/flyology-quic-tls_handshake_policy.ads:21-26` against
  `flyology-quic-tls_extension_policy.ads:19-26`, collapsed at
  `flyology-quic-tls_handshake_policy.adb:141` and `:227` and passed through at
  `flyology-quic-tls_session.adb:297-299`, `:521-522`, `:598-599`
- **Repro:** `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_tls_5`
  (exit 1, BUG REPRODUCED, checks: 6 failures: 2), re-run at drafting time
- **What is wrong:** `Certificate_Mismatch`, `Signature_Failed` and `Finished_Failed` all
  fall into a `when others => 16#150#` arm, so a peer-caused authentication failure is
  reported as `internal_error(80)`, which RFC 8446 section 6.2 defines as an error
  "unrelated to the peer or the correctness of the protocol". The required codes are 0x12A
  (`bad_certificate`) and 0x133 (`decrypt_error`, a MUST in RFC 8446 section 4.4.3 and
  section 4.4.4). The spike reads the code from the wire rather than decoding it by hand:
  it delivers the client's CONNECTION_CLOSE back to the live server driver, which decrypts
  it with its own Handshake keys, and reads `Peer_Close_Error`. Both cases report 336,
  which is 0x150.
- **Notes:** RFC 9001 section 4.8 does allow a generic substitute ("replacing any alert
  with a generic alert, such as handshake_failure (0x0128 in QUIC)"), but 0x150 is not a
  generic code, it is a specific and actively misleading one. The missing-ALPN sub-claim
  (0x16D where RFC 9001 section 8.1 requires 0x178) is confirmed by reading only and is
  **not reproduced**; the filed body says so in the Problem section and again in Severity.
  The four `ok` lines in the spike are load-bearing: they show the authentication decisions
  themselves are correct and only the reported reason is wrong.
- **Proof:** the ALPN half's fix lands in `flyology-quic-tls_handshake_policy.adb` and
  `flyology-quic-tls_extension_policy.adb`, both proved by `./scripts/prove.sh`. The
  driver itself is outside the proved set. The filed body names both.
- **Fix decision:** distinguishing a missing required extension from an invalid one means
  a new literal in `TLS_Handshake_Policy.Parse_Status`, declared in a specification. That
  is a maintainer decision; the filed body lists the options and does not choose. The
  error-code arms themselves need no decision, because the values are fixed by RFC 8446
  and the RFC 9001 section 4.8 mapping.

### Coverage evidence

Read in full: `flyology-quic-tls_session.adb`/`.ads`, `flyology-quic-tls_key_schedule.adb`/`.ads`,
`flyology-quic-tls_handshake_policy.adb`/`.ads`, `flyology-quic-tls_extension_policy.adb`/`.ads`,
`flyology-quic-tls_signature_policy.adb`/`.ads`, `flyology-quic-tls_authentication_policy.adb`/`.ads`,
`flyology-quic-crypto_openssl.adb`/`.ads`, `flyology-quic-crypto_flight.adb`/`.ads`,
`flyology-quic-crypto_reassembly_policy.adb`/`.ads`, `src/native/flyology_quic_openssl.c`,
`src/flyology-http-server-tls.adb`/`.ads` and `src/flyology-http-server-development_certificates.adb`/`.ads`.
Read in part, to trace callers and key lifetime: `connection_driver.adb` (640-1470),
`application_space.adb` (1300-1400), `application_connection.adb`, `initial_space.adb`
(420-520), `handshake_connection.adb`, `connections.ads`/`.adb`, and
`src/flyology-http-server-http_3.adb`. Tests read: `flyology_quic/tests/qualification.md`,
`flyology-quic-tls_session-smoke.adb`, `flyology-quic-tls_transport_smoke.adb`,
`flyology-quic-tls_extension_policy-smoke.adb`, `tests/oracle/quic-go/main.go`,
`tests/oracle/aioquic_h3_server.py`, `tests/development_certificates_smoke.adb`.

Executed: four spikes, all re-run at drafting time against commit `f078732`, all
BUG REPRODUCED with exit 1. Peer sources read at their pinned revisions on this host:
quic-go 0.54.1 (`internal/handshake/crypto_setup.go`, `internal/protocol/params.go`),
Go 1.23.4 `crypto/tls/handshake_server_tls13.go`, aioquic 1.3.0 `tls.py` from the oracle
virtual environment, and OpenSSL 3.6.3's installed `SSL_CTX_set_num_tickets` manual page.
`review/baselines/10-http3-interop.log` records PASS against quic-go 0.54.1 and aioquic
1.3.0 in both roles; the QUIC-TLS-2 entry explains why that green run does not contradict
the finding.

**Certificate pinning: a negative result, and the strongest one in this area.** The
discovery reviewer concluded the pinning path was sound. That conclusion was attacked and
it held. Four things were established by reading the code and then by execution.

1. *One supplier, one production caller.* `Connections.Initialize_Client`
   (`flyology_quic/src/flyology-quic-connections.ads:213-252`) is the only public entry,
   and in the whole HTTP crate it has exactly one production caller,
   `src/flyology-http-client.adb:3274-3278` inside `Start_HTTP_3_Connection`, which passes
   `Flyology.Bytes.To_Array (Owner.HTTP_3_Certificate)`. That field is written in exactly
   two places, the two `Configure` overloads that take `HTTP_3_Certificate_DER`.
2. *No empty or unset pin is reachable, with or without assertions.* Both certificate
   overloads validate the argument with an ordinary `if`/`raise Program_Error`
   (`src/flyology-http-client.adb:2443-2445` and `:2485-2487`, "HTTP/3 pinned certificate
   must contain 1 through 4096 bytes"), and both overloads that do **not** take a
   certificate reject HTTP/3 modes outright (`:2298-2300` and `:2402-2404`, "HTTP/3
   requires a pinned certificate Configure overload"). These are statements, not
   preconditions, so they hold with assertions disabled, unlike the
   `Pinned_Certificate'Length in 1 .. 4_096` preconditions further down the stack. Even
   with an empty pin the path stays fail-closed: the length check at
   `tls_session.adb:635-639` would demand a zero-length certificate entry,
   `Ed25519_Verify_Certificate` sets `Verified := False` first
   (`crypto_openssl.adb:572`), and the C bridge rejects a DER buffer it cannot fully parse.
3. *No path ignores the comparison result.* `Accept_Server_Authentication` is a straight
   line of early returns each calling `Mark_Failed`; the driver assigns
   `Item.Current := Connected` only after `TLS_Result.Status = Succeeded`
   (`connection_driver.adb:1105-1136`); and `Operation_Result.Status` defaults to
   `Invalid_State`, so an unwritten status is never read as success.
4. *The attack that matters was run and defeated.* The pinned DER is public, so the
   realistic attack is a man in the middle replaying the pinned certificate under its own
   key. `repro_quic_tls_5` case 2 does exactly that: the server is initialized with the
   genuine certificate and a different Ed25519 seed, and the client ends in `Failed`.
   Case 1 covers a pin differing by one byte of the subjectPublicKey, also `Failed`.
   Verification runs against `Item.Certificate`, the pinned bytes, not the received copy
   (`tls_session.adb:696-703`), so a replayed certificate gains the attacker nothing. The
   four `ok` lines in that spike's output are the evidence.

Chain building, name and wildcard matching, IP SANs and expiry remain absent. They are
outside the stated contract (`tls_session.ads:6-10`, `connections.ads:212-218`), which is
exact-DER pinning of an Ed25519 leaf, so their absence is a documented limitation of the
first authentication profile and is not counted as a defect.

Could not be exercised: whether an OpenSSL-based QUIC server applies the RFC 8446
section 4.2.9 psk-mode gate. `openssl s_server` in 3.6.3 on this host has no `-quic`
option and no OpenSSL source tree is present. What would settle it is a run against an
ngtcp2 or nginx-quic server with default ticket settings, observing whether it sends
NewSessionTicket to a ClientHello carrying no `psk_key_exchange_modes`. The BoringSSL
`kNumTickets = 2` claim in the discovery entry is likewise unverified and was dropped.

### Refuted and not counted

- **Certificate pinning.** Attacked as described above and upheld. No finding.
- **Finished verification.** Computed over the correct transcript prefixes (server Finished
  over ClientHello through CertificateVerify, client Finished over ClientHello through
  server Finished) and compared with a constant-time `Secure_Equal`; a mismatch marks the
  session `Failed` and clears every secret, which `tls_session-smoke.adb:215-218` asserts.
- **Key schedule.** HKDF-Expand-Label info layout, the Early/Derived/Handshake/Master
  extraction chain, every label, and the QUIC labels with the header-protection key
  retained across updates all match RFC 8446 section 7.1 and RFC 9001 sections 5.1 and 6.1.
  Every temporary is cleared on normal and on exception exit. The RFC 8448 trace test is
  recorded in `qualification.md:28-31`.
- **Initial secrets.** Salt and labels per RFC 9001 section 5.2, read in the C bridge.
- **Hello parsing and extension policy.** Legacy version, the single required cipher suite,
  compression bytes, session-id echo, unknown extensions ignored, duplicates rejected,
  per-context extension permissions, and the exactly-one-ALPN-entry rule in
  EncryptedExtensions are all correct. HelloRetryRequest cannot be mistaken for a
  ServerHello, and 0-RTT packets are dropped as `Unsupported_Packet`.
- **State machine and signature algorithms.** Every `Accept_*` checks its state first and
  returns `Invalid_State` without mutation; `Failed` is sticky; `Get_Application_Keys` is
  guarded by `Is_Connected`; the client accepts only ed25519 in CertificateVerify, so no
  downgrade to ECDSA or RSA-PSS is possible.
- **OpenSSL binding.** Every C entry point validates its arguments, clears the error queue
  before work, frees every handle on all exits, and cleanses outputs on failure; the Ada
  side raises `Crypto_Error` on anything but 0 or 1 and sets `Verified` only on the
  success value.
- Observations recorded and outside the rubric: `Application_Secrets.Exporter` is derived
  and never read anywhere in the crate, which is dead work rather than a defect, and is
  mentioned inside QUIC-TLS-3 rather than counted separately. The two handshake
  `QUIC_Traffic_Keys` records are likewise retained past the point RFC 9001 section 4.9.2
  describes, and are covered by the same entry.

## H1-CLIENT

This area covers the HTTP/1.x client: response head and body parsing, framing
selection, chunk decoding, trailers, informational responses, connection-reuse
decisions, request serialisation, the `Expect: 100-continue` handshake, and the
composable buffer exchange. Read in full: `src/flyology-http-client-http_1_internals.adb`,
`src/flyology-http-client.ads`, `src/flyology-http-client_policy.ads/.adb`,
`src/flyology-http_chunk_encoding.ads/.adb`, `src/flyology-http-headers.ads/.adb`,
`src/flyology-http-client-testing.ads/.adb`; read in large part:
`src/flyology-http-client.adb` (the engine, the drivers, the exchange lifecycle);
read for comparison: `src/flyology-http-http_2_client_connection.adb` and the HTTP/3
response validator; plus `tests/http_client_parser_matrix.adb`,
`tests/http_client_rfc_seeds.ads/.adb`, `tests/http_client_smoke.adb`,
`tests/http_client_pool_model.adb`, `tests/http_client_composable_smoke.adb`,
`tests/http_client_upload_controls_smoke.adb`, `tests/http-client-conformance.md`
and `tests/corpus/http-client-scenarios.json`. Seven findings, all confirmed by a
reproduction, none refuted: three P1 and four P2. The headline is the length
arithmetic. The HTTP/1 response parser carries `Content-Length` and chunk sizes in
`Natural` although the crate introduced `Flyology.HTTP.Body_Size` for exactly this
purpose and the HTTP/2 and HTTP/3 engines already use 64-bit types, and the
accumulator in `Parse_Natural` guards with the digit value while adding the
character code. Together those two facts make every response length above
2147483599 unusable and turn 48 of them into a raw `Constraint_Error` on a
release build. One new finding, H1-CLIENT-7, was raised during verification while
measuring H1-CLIENT-1's threshold.

### H1-CLIENT-1: HTTP/1 response `Content-Length` above 2147483599 is rejected as malformed

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-client-http_1_internals.adb:151-168` (`Parse_Natural`),
  `:170-206` (`Content_Length`), `:465-467` (`Select_Body_Mode`),
  `src/flyology-http-client.adb:308` (`Remaining_Body : Natural`)
- **Repro:** `./tests/repros/run.sh flyology-http-http_3_header_policy-repro_h1_client_1`
  (exit 1, BUG REPRODUCED, 7 checks, 4 failures)
- **What is wrong:** `Parse_Natural` and `Content_Length` return `Natural`, and the
  decoded length is stored in a `Natural` field, so a syntactically valid
  `Content-Length` above the measured threshold is refused with `Protocol_Error`
  "invalid or overflowing HTTP decimal value" on the parser oracle and on the live
  transport. RFC 9110 section 8.6 says "Any Content-Length field value greater than
  or equal to zero is valid" and makes anticipating large decimal numerals a MUST.
  The crate's own `src/flyology-http.ads:103-106` declares `Body_Size` as the
  "64-bit-safe" shared type "so message lengths do not depend on the implementation
  range of Natural", and `tests/http_smoke.adb:288-295` asserts that this crate's own
  HTTP/1 server emits `Content-Length: 5368709129`, so a Flyology-to-Flyology 5 GiB
  transfer fails at the client's response head.
- **Notes:** The measured threshold is **2147483599**, not `Natural'Last`: the spike
  binary-searches the whole `Body_Size` range rather than assuming. The 48 values
  between 2147483600 and `Natural'Last` fail for a distinct reason and are
  H1-CLIENT-7. Part C of the spike calls
  `Flyology.HTTP.HTTP_3_Header_Policy.Validate_Response` directly (the spike is a
  child of that private package) and shows the HTTP/3 validator accepting the identical
  field value with `Content_Length = 5_368_709_129`, so the comparison is a measurement
  rather than a claim. The fix is shared with H1-CLIENT-7 and H1-CLIENT-6. No new
  public constant is needed: `Remaining_Body` and `Chunk_Remaining` live in
  `Response_Data`, whose full record type is in the body at
  `src/flyology-http-client.adb:288` and which `src/flyology-http-client.ads:1391`
  declares only as an incomplete type, and the public contract already exists as
  `Flyology.HTTP.Body_Size`. No maintained test covers 2^31 to 2^63-1 on HTTP/1;
  `tests/http_client_parser_matrix.adb:163-166` jumps to a 36-digit value.

### H1-CLIENT-7: `Parse_Natural` guards with the digit value but accumulates `Character'Pos`

- **Severity:** P1 (new in verification; raised while measuring H1-CLIENT-1's threshold)
- **Location:** `src/flyology-http-client-http_1_internals.adb:157-166`, raising at `:165`
- **Repro:** `./tests/repros/run.sh repro_h1_client_7` (exit 1, BUG REPRODUCED,
  7 checks, 5 failures)
- **What is wrong:** The guard tests `Result > (Natural'Last - digit) / 10` but the
  statement is `Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0')`,
  which parses as `((Result * 10) + Character'Pos (Item)) - 48`. The `Integer`
  intermediate is therefore up to 48 larger than the value the guard admitted, and for
  the 48 lengths 2147483600 .. 2147483647 it exceeds `Integer'Last`. GNAT's overflow
  check raises `Constraint_Error` out of the production response head parser. The live
  half of the spike drives `Execute` against a raw loopback peer answering
  `Content-Length: 2147483647` and the caller receives
  `CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed`
  verbatim.
- **Notes:** The affected set is exactly 48 contiguous values; the spike enumerates
  2147483580 .. 2147483660 and reports the boundaries rather than asserting them. The
  check is live in a release build: `flyology_http.gpr:96-100` takes its switches from
  the Alire-generated crate configuration, whose default `release` profile supplies
  `-O3 -gnatn -ffunction-sections -fdata-sections -gnatW8` and no `-gnatp`, and the
  reproduction harness builds through the same library project. The engine's
  `when Error : others` arm (`src/flyology-http-client.adb:6017-6023`) destroys the
  transport with `Reusable => False`, and `Finish` re-raises the saved occurrence with
  its original identity (`:1736-1742`, `:1781-1787`), so no pooled transport is poisoned,
  but the application sees a language runtime check instead of the documented
  `Protocol_Error` / `Response_Invalid` vocabulary. Not P0: no memory unsafety, no
  smuggling. Shares one fix site with H1-CLIENT-1 and H1-CLIENT-6; the issue bodies
  cross-reference each other and none of the three needs a maintainer decision,
  because the widening stays inside the private `Response_Data` record.

### H1-CLIENT-2: a negative `Set_Expect_Continue` wait sends the body immediately

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-client.adb:3767-3782` (`Probe_Early_Response`),
  `:2217-2224` (`Set_Expect_Continue`), contract at `src/flyology-http-client.ads:217-226`
- **Repro:** `./tests/repros/run.sh repro_h1_client_2` (exit 1, BUG REPRODUCED,
  4 checks, 1 failure)
- **What is wrong:** `src/flyology-http-client.ads:220-222` promises that "a negative
  value waits within the whole exchange deadline". Both arming branches pass
  `Continue_Wait` through unchanged: `Duration'Min (Continue_Wait, Remaining (Deadline))`
  when the deadline is limited, and `Continue_Wait` itself when it is not. The pinned
  runtime treats any nonpositive interval as already due, so the next completion-set
  drive arrives with `Deadline_Reached`, the guard fails, the `else` arm clears
  `Expect_Waiting` and the body is sent. A negative wait is indistinguishable from
  zero, so a server that would have rejected the request on the head alone receives
  the whole body.
- **Notes:** The runtime contract was read from the revision this worktree actually
  builds: `alire/alire.lock` pins `flyology =0.1.1-dev` at `bd95746d`, whose
  `src/flyology-operations-drivers.ads:58-59` says "Set or replace one operation
  deadline. A nonpositive interval is due on the next completion-set drive", and whose
  body at `:80-91` implements `(if Interval <= 0.0 then Now elsif ...)`. The wire
  behaviour is legal under RFC 9110 section 10.1.1 ("such a client MAY proceed to send
  the content even if it has not yet received a response"), so the violated text is
  the `.ads` contract, which is what keeps this at P1 rather than P0.
  **CLIENT-POOL-3 is the same finding**, naming the same statement at the same site and
  the same `.ads` sentence; it is closed against this entry and folded into this issue
  body rather than filed separately. Discovery rated CLIENT-POOL-3 at medium
  confidence and this reproduction settles it. No maintained test passes a negative
  wait: `tests/http_client_upload_controls_smoke.adb` covers `1.0` at `:472`, `:488`
  and `:526`, `0.02` at `:510` and the default at `:657`.

### H1-CLIENT-3: an HTTP/1.0 response carrying both `close` and `keep-alive` is pooled

- **Severity:** P2 (discovery said P2; unchanged)
- **Location:** `src/flyology-http-client-http_1_internals.adb:410-413` (both tokens
  collected), `:416-418` (only one consulted per arm)
- **Repro:** `./tests/repros/run.sh repro_h1_client_3` (exit 1, BUG REPRODUCED,
  3 checks, 1 failure)
- **What is wrong:** `Data.Reusable := (if Version = HTTP_1_1 then not Close_Token else
  Keep_Token)` consults `Close_Token` only on the HTTP/1.1 arm, so
  `Connection: keep-alive, close` on an HTTP/1.0 response leaves the transport in the
  pool as idle and reusable. RFC 9112 section 9.3 tests `close` first and does not
  condition that step on the version. The next checkout takes `Verify` from
  `Undelivered_Framing` (`:480`), which is `False` here, so no verification probe runs
  and a non-idempotent request is written onto a closed socket.
- **Notes:** Both controls in the spike behave correctly (HTTP/1.0 with a lone
  `keep-alive` is pooled, HTTP/1.1 with `close` present is not), so the measurement
  isolates the one case. No stock server is known to emit both options; this is **not
  verified against a peer**, and the issue body says so in the same sentence as the
  impact. `tests/http_client_pool_model.adb:194-198` covers HTTP/1.0 with a lone
  `keep-alive` and `tests/http_client_smoke.adb:427-428` and `:461-462` cover HTTP/1.0
  with no `Connection` field, so the combination is uncovered. No maintainer decision
  needed; no existing test asserts the wrong behaviour.

### H1-CLIENT-4: heads of 16383-16384 bytes pass the oracle and are rejected on the live path

- **Severity:** P2 (discovery said P2; unchanged)
- **Location:** `src/flyology-http-client-http_1_internals.adb:367-381`
  (`Parse_Available_Final_Head`), same pair at `:515-528` (`Validate_Response`)
- **Repro:** `./tests/repros/run.sh repro_h1_client_4` (exit 1, BUG REPRODUCED,
  6 checks, 2 failures)
- **What is wrong:** Two comparisons bound the same 16 KiB limit differently. The
  post-terminator check `Head_Last - Text'First + 1 > Default_Max_Bytes` accepts a head
  of exactly 16384 bytes; the pre-terminator check `Text'Length >= Default_Max_Bytes`
  fires as soon as 16384 bytes are buffered without the terminator present.
  `Validate_Response` always sees the whole message, so only the second check ever
  applies there, and the parser matrix records the 16384-byte head as an accepted
  boundary the transport does not honour.
- **Notes:** The spike uses the parser matrix's own construction
  (`tests/http_client_parser_matrix.adb:118-123`) and splits the peer's write at
  8192 bytes, which is exactly what an ordinary kernel delivery does against the
  client's `Receive_Buffer_Size : constant Positive := 8 * 1_024`
  (`src/flyology-http-client.adb:65`), so the reproduction needs no test-only receive
  cap and no segmentation luck. `tests/http_client_parser_matrix.adb:201-206` asserts
  the boundary that the live path breaks; that test does not have to change if the
  fix moves the incomplete-head bound, but it does if the maintainer instead makes
  `Default_Max_Bytes` exclusive in both places. The live outcome depends on
  delivery, so the failure is nondeterministic between links; the issue body says so.
  A maintainer decision is flagged, because the fix moves where the incomplete-head
  bound sits relative to a documented limit.

### H1-CLIENT-5: a composable buffer exchange drains an over-capacity body with no byte bound

- **Severity:** P2 (discovery said P2; unchanged). Discovery recorded medium confidence
  and asked whether something upstream bounds the drain. It does not.
- **Location:** `src/flyology-http-client.adb:4014-4023` (head-time decision for a known
  length), `:3892-3895` (the same decision inside `Deliver` for a streamed one),
  `:3868-3869` (every later slice discarded), `:4042-4064` (`Receive_Content_Step`,
  which keeps reading anyway)
- **Repro:** `./tests/repros/run.sh repro_h1_client_5` (exit 1, BUG REPRODUCED,
  2 checks, 1 failure)
- **What is wrong:** Once `Pending_Result` is `Response_Body_Too_Large`, `Deliver`
  discards every slice but `Receive_Content_Step` keeps calling `Receive_One` until the
  framing completes. Nothing consults `Pending_Result` to abandon the transport. The
  spike measures the peer writing all **8388608** declared body bytes against a
  4096-byte destination, 2048 times the capacity. The repository answers the same
  question the other way on both sibling paths: `Drain` stops at
  `Max_Redirect_Drain_Bytes : constant Natural := 64 * 1_024` and destroys the
  transport (`:67-70`, applied at `:6399-6404`), and `Read_All` calls
  `Abandon_Response` on the first overflow (`:7257-7266`).
- **Notes:** Stays P2 for three reasons the issue body states explicitly: the typed
  result is correct (`Response_Body_Too_Large` with `Required_Body_Length` set and the
  buffer left empty), no `.ads` sentence is broken (`src/flyology-http-client.ads:695`
  documents only "Bounded response destination overflowed" and nothing promises when
  the exchange terminalizes), and there is no amplification, because the peer must
  transmit every byte the client discards and the caller's deadline bounds the
  exposure. **Choosing the bound is a maintainer decision** under "Decision authority"
  and "Ada interface values"; the issue body lists the options and does not choose. For
  a `Fixed_Body` the drain is bounded by the declared length, as measured; for
  `Chunked_Body` and `Until_Close_Body` no length is declared, so the same loop is
  bounded only by the deadline. That last part is from reading
  `Consume_Available_Content` (`src/flyology-http-client-http_1_internals.adb:859-1008`),
  **not measured**. `tests/corpus/http-client-scenarios.json:131-136` and
  `tests/http_client_composable_smoke.adb:572-577` assert the typed result on a
  40-byte overrun, which finishes instantly either way.

### H1-CLIENT-6: `Validate_Response` overflows on chunk sizes `7FFFFFFE` and `7FFFFFFF`

- **Severity:** P2 (discovery said P2; unchanged), including the scope claim, which is
  now measured rather than argued
- **Location:** `src/flyology-http-client-http_1_internals.adb:585-587`
  (`Length (Data.Pending) < Size + CRLF'Length` with `Size : Natural`), `:763-802`
  (`Chunk_Size` returning `Natural`)
- **Repro:** `./tests/repros/run.sh repro_h1_client_6` (exit 1, BUG REPRODUCED,
  5 checks, 2 failures)
- **What is wrong:** `Chunk_Size` admits any value up to `Natural'Last`, so for the two
  chunk sizes `7FFFFFFE` and `7FFFFFFF` the `Integer` intermediate `Size + 2` overflows
  and the check raises `Constraint_Error` where `7FFFFFF0` yields
  `Protocol_Error "incomplete HTTP chunk data"`. Both are legal `chunk-size = 1*HEXDIG`
  under RFC 9112 section 7.1, which also states "recipients MUST anticipate potentially
  large hexadecimal numerals and prevent parsing errors due to integer conversion
  overflows or precision loss due to integer representation".
- **Notes:** **Test-oracle only, and the issue body says so explicitly in the Severity
  section.** The spike calls `Flyology.HTTP.Client.Testing.Fuzz_Response`, which
  `tests/http-client-conformance.md:100-104` designates as the arbiter ("Documented
  protocol and size rejections are normal outcomes; assertion failures, runtime checks,
  hangs, and other exceptions remain crashes"), with a padded 1000-byte input exactly as
  a campaign would, and the `Constraint_Error` escapes it. The same spike serves the
  same bytes from a raw loopback peer and the production decoder answers
  `FLYOLOGY.HTTP.PROTOCOL_ERROR`, because `Consume_Available_Content` (`:859-1008`) and
  `Read_Response_Body` (`:1010-1180`) only assign `Chunk_Remaining := Chunk_Size (...)`
  and pass it to `Copy_Pending` as a limit reduced by `Natural'Min`, never adding to it.
  So no user-reachable path is affected; what degrades is a fuzzing oracle. Shares the
  widening fix with H1-CLIENT-1 and H1-CLIENT-7, and needs no maintainer decision for
  that route. Discovery's chunk sub-item is confirmed in passing: a single chunk of
  `80000000` or more is rejected with `Protocol_Error "overflowing HTTP chunk size"`,
  which the `arbiter 80000000 -> consumed` line records as a documented rejection; a
  2 GiB chunk is not something a stock server emits and that is **not verified against a
  peer**.

### Coverage evidence

Every one of the seven findings has a runtime reproduction that was re-run at
`f078732` for this write-up; all seven print `BUG REPRODUCED` and exit 1, and the
numbers quoted in the issue bodies are from those fresh runs, not copied from the
verification report. The harness self-tests `./tests/repros/run.sh seam_check` and
`./tests/repros/run.sh repro_smoke` both PASS, so the verdicts are not an artefact of
a broken harness.

Two of the seven were measured rather than asserted, which matters for the numbers in
the bodies: H1-CLIENT-1's spike binary-searches the whole `Body_Size` range to find the
threshold (2147483599 accepted, 2147483600 refused) instead of assuming `Natural'Last`,
and H1-CLIENT-7's enumerates 2147483580 .. 2147483660 to report the exact affected set
(48 values). H1-CLIENT-5's spike measures bytes actually written by the peer rather than
inferring the drain from the code.

Four of the seven are exercised on the live transport as well as through the parser
oracle: H1-CLIENT-1, H1-CLIENT-2, H1-CLIENT-4 and H1-CLIENT-7 drive the real
`Flyology.HTTP.Client` over loopback against a raw `Flyology.IO.Sockets` peer, and
H1-CLIENT-6 uses a live peer for its scope check. Every spike binds
`Sockets.Loopback_IPv4` with `Sockets.Any_Port` and reads the assigned port back through
`Get_Socket_Name`, the maintained pattern in `tests/http_client_fragmentation.adb`, so
no spike collides with a maintained suite's fixed port.

The pinned dependency was read rather than assumed for H1-CLIENT-2: `alire/alire.lock`
resolves `flyology =0.1.1-dev` to commit `bd95746d`, and the `Arm_Deadline` contract and
body were read from that revision.

None of the green baselines in `review/baselines/` bears on these paths. h2spec (13-) is
HTTP/2, Autobahn (14- through 16-, 20- through 23-) is WebSocket, h3spec and the interop
runs (10- through 12-) are HTTP/3, and the client differential (17-, 18-) exercises the
Ada client against PycURL at ordinary sizes. H1-CLIENT-1, -4, -5, -6 and -7 are HTTP/1
client response-parsing paths at sizes no differential run exercises (2 GiB and 5 GiB
lengths, a head within two bytes of 16 KiB, an 8 MiB over-capacity body, a 2 GiB chunk
size); H1-CLIENT-2 needs a negative `Wait_Timeout` that no suite passes; H1-CLIENT-3
needs a response carrying both `Connection` options, which no stock peer emits. That is
why seven entries survive a green suite.

Not exercised: no peer was found that emits `Connection: keep-alive, close` on an
HTTP/1.0 response (H1-CLIENT-3) or a single chunk of 2 GiB or more (H1-CLIENT-6's
sub-item), so both are recorded as not verified against a peer. The unbounded-drain
claim for `Chunked_Body` and `Until_Close_Body` (H1-CLIENT-5) is from reading, not
measurement. The runtime's `Flyology.IO.Connections.Drivers.Receive` contract, on which
the reuse probe and every receive depend, was not audited; it is outside this crate.

Prior findings 6, 18 and 36 were re-traced at `f078732` and have not regressed:
`Request_Incomplete` is set when the expectation is sent and forces `Reusable => False`
while set; bodiless responses set `Undelivered_Framing`, which becomes the pool's
`Verify_On_Reuse`; and `Drain` is bounded by `Max_Redirect_Drain_Bytes` and abandons the
transport past it.

### Refuted and not counted

Nothing was refuted in this area: all six discovery entries were confirmed and one
further finding was raised during verification.

Recorded during discovery and deliberately not counted, because each is conformant
strictness, a policy choice, or performance only:

- **Missing SP after the status code.** `HTTP/1.1 200\r\n` is rejected. RFC 9112
  section 4's ABNF requires the SP, so the rejection is conformant even though curl,
  Go `net/http` and Python `http.client` accept it. No stock server was named that
  emits it.
- **obs-fold in trailers is rejected** while it is unfolded in headers. RFC 9112
  section 5.2's user-agent MUST is phrased for a response message, and rejecting is the
  safe direction.
- **Bare-LF line endings are not recognised** (RFC 9112 section 2.2 MAY). Such a head is
  neither accepted nor promptly rejected: the client reads to 16 KiB or the deadline.
  Malformed input.
- **Empty retained body on POST/PUT/PATCH emits no `Content-Length: 0`**, while a
  known-length streaming source of length 0 does. RFC 9110 section 8.6 is a SHOULD.
  Flagged for consistency between the two paths, not as a defect.
- **Proved policy functions the engine does not call.** `Validate_Upload`,
  `Classify_Pull`, `Classify_Stale_Retry` and `Classify_Expectation_Response` in
  `Flyology.HTTP.Client_Policy` are referenced only by their smoke test; the engine
  re-implements each decision inline. The re-implementations were checked against the
  proved contracts and the outcomes are consistent. Drift risk, not a defect.
- **Two chunk-size encoders.** `src/flyology-http-client.adb:1984-1997` duplicates the
  SPARK-proved `Flyology.HTTP_Chunk_Encoding.Encode` in the other letter case. Both are
  valid `HEXDIG`.
- **Policy values seen and not questioned:** eight informational responses maximum,
  16 KiB head and 64 fields, 8 KiB receive buffer, 64 KiB redirect drain, and the
  `Status_Code` range 100 .. 599.
- **Performance only:** `Consume_Available_Content` zeroes the whole 8 KiB output array
  on every step, and `To_String (Data.Pending)` copies the pending buffer on every line
  scan.

## CLIENT-POOL

The HTTP client's synchronous wrapper, pool controller, lease lifecycle, redirect resolution, expectation handshake, retry eligibility, authentication, request-body sources and deadline arithmetic, plus the proved `Flyology.HTTP.Client_Policy` boundary that used to carry several of those decisions. Read in full: `src/flyology-http-client.ads` (1402 lines), the relevant regions of `src/flyology-http-client.adb` (7406 lines), `src/flyology-http-client-pool_controller.adb`, `-state_lifetime.adb`, `-authentication.ad[bs]`, `-request_bodies`, `-channels`, `-files`, `-testing`, `src/flyology-http-client_policy.ad[bs]`, plus the pinned `flyology` runtime at `bd95746d` for `Arm_Deadline`, `Wait_All`, `Continue_After` and `IO.Infinite`. Eight findings were raised and the verification confirmed every one of them at the discovery's own severity, which is unusual and worth stating plainly: this discovery set was accurate. Nothing was refuted. Two premises were corrected rather than two verdicts. Seven issues are filed: two P1 and five P2. CLIENT-POOL-3 is a duplicate of H1-CLIENT-2 and is folded there.

### CLIENT-POOL-1: Same-origin relative redirect whose query contains `://` raises `Redirect_Error`

- **Severity:** P1 (discovery said P1; unchanged)
- **Location:** `src/flyology-http-client.adb:6301-6315` (`Resolve_Redirect`), anchored classifier unused at `:6257-6265`; consumers at `:6663` and `src/flyology-http-client-sse.adb:761`
- **Repro:** `./tests/repros/run.sh repro_client_pool_1 120` (exit 1, BUG REPRODUCED, 4 checks / 4 failures)
- **What is wrong:** The absolute-URI branch is selected by `Ada.Strings.Fixed.Index (Reference, "://") /= 0`, an unanchored scan of the whole `Location` value. The anchored `Has_URI_Scheme`, which does require the colon to precede any `/` or `?`, sits in the *following* `elsif` and never sees such a reference. For `Location: /next?u=https://example.com/home` the scheme name becomes `/next?u=https` and `Redirect_Error "unsupported redirect URI scheme"` is raised, so `Follow_Same_Origin` refuses an ordinary return-to or OAuth `redirect_uri` shape. The spike shows the peer never receives the second request.
- **Notes:** Explicitly **not** a security defect, and the issue body says so: `Name` can equal `http`/`https` only when the reference genuinely starts with that scheme, and `Parse_Absolute` recomputes the split from the *first* `://`, so a hostile `http://good/x?u=https://evil/` still parses `good` as the authority. The failure mode is refusal, not retargeting. The fix already exists one file over: the identical unanchored scan in the server's `Raw_Path` was fixed and now uses the anchored `Absolute_Form_Authority` (`src/flyology-http-server-routing.adb:283-286`), comment and all; the issue points the maintainer at it. No maintainer decision is needed. No existing test asserts the wrong behaviour; the nearest case is `tests/http_client_redirects.adb:266` (`../next?x=1#ignored`), and no `Location` under `tests/` contains `://` after the first path character. None of the green baselines reach it: this is a client-side reference classifier, and h2spec, Autobahn, the HTTP/3 interop run and the PycURL differential do not drive redirect following with a URL-bearing query. RFC citation corrected to RFC 9110 s10.2.2 plus RFC 3986 s3.1 and s4.2.

### CLIENT-POOL-2: Synchronous 417 fallback retries after body transmission with a consumed, un-rewound source

- **Severity:** P1 (discovery said P1; unchanged. P0 was considered for the chunked shape under "silent corruption" and rejected: no byte is corrupted and the second request is a syntactically valid message)
- **Location:** `src/flyology-http-client.adb:6636-6647` (`Execute_Redirects`), contract at `src/flyology-http-client.ads:220-226`, engine side `:3767-3786` (`Probe_Early_Response`) and `:3609-3617` (`Pull_Source`)
- **Repro:** `./tests/repros/run.sh repro_client_pool_2 150` (exit 1, BUG REPRODUCED, 7 checks / 5 failures)
- **What is wrong:** The `.ads` scopes the fallback to "A 417 final response received **before body transmission**". The branch tests only `Status = 417`, `Current.Expect_Continue` and `not Retried`, consults no body-sent flag, and hands the same `Request_Body_Source` at its current position to the next `Execute_Operation_Once` without rewinding it or requiring `Rewindable_Request_Body_Source`. The engine does not enforce the precondition either: once `Continue_Wait` expires, `Probe_Early_Response` clears `Expect_Waiting`, resumes the body, and any later final response including 417 arrives as an ordinary `Response_Complete`.
- **Notes:** **Two shapes, and the issue leads with the second.** Known length: the retry announces `Content-Length: 17` on a fresh transport over an exhausted source, `Pull_Source` fails `Request_Source_Failed`, and the caller gets `Request_Body_Error` (`:6584`) instead of the 417. Unknown length (chunked) is **silent**: a second well-formed `POST` goes out with `0\r\n\r\n`, the origin answers 200, and the caller cannot learn it sent one 17-byte POST and one empty POST. This changes the fix: requiring a rewindable source and rewinding it repairs only the first shape. The guard that would have prevented this was removed in `f0d630d`, quoted in the body from `git show f0d630d -- src/flyology-http-client.adb`; the proved `Classify_Expectation_Response` still declares the `Body_Sent` input with a contract case (`src/flyology-http-client_policy.ads:171-188`). Cross-referenced to CLIENT-POOL-5. **Maintainer decisions listed in the body:** how the wrapper observes body-sent (private exchange-state field, new typed-result field, or derived from `Request_Incomplete`); whether the remaining before-body retry should require `Rewindable_Request_Body_Source`, which narrows the documented contract; whether the `.ads` should also state what the caller receives after transmission. `Flyology.HTTP.Client_Policy` is proved by `scripts/prove.sh:31`, so the body notes the `--checks-as-errors=on` obligation if the classifier itself changes. No existing test asserts the wrong behaviour: `tests/http_client_upload_controls_smoke.adb:316-321` and `:525-528` cover the before-body case, which stays correct. The PycURL differential does not script a late 417; h2spec and Autobahn are server-side.

### CLIENT-POOL-3: Negative `Expect: 100-continue` wait sends the body immediately

- **Severity:** DUP (discovery said P1; confirmed as P1 under its primary)
- **Location:** `src/flyology-http-client.adb:3767-3786` (`Probe_Early_Response`), contract at `src/flyology-http-client.ads:220-226`
- **Repro:** `./tests/repros/run.sh repro_h1_client_2` (owned by H1-CLIENT)
- **What is wrong:** Same statement, same site, same `.ads` sentence as H1-CLIENT-2. Neither `Duration'Min (Continue_Wait, Remaining (State.Deadline))` nor the unlimited-deadline branch normalizes a negative `Continue_Wait`, and `Set_Expect_Continue` stores it unchanged, so the next drive arrives with `Deadline_Reached` and the body goes out.
- **Notes:** **Folded into H1-CLIENT-2; no body written here.** The runtime half was re-confirmed independently against the pinned dependency rather than against the discovery text: `flyology-operations-drivers.ads:58-63` documents `Arm_Deadline` as "A nonpositive interval is due on the next completion-set drive." Close against H1-CLIENT-2; do not fix it twice.

### CLIENT-POOL-4: Synchronous safe-method exchanges can replay twice

- **Severity:** P2 (discovery said P2; unchanged. The rubric's "wrong diagnostics or contract drift" is exactly this)
- **Location:** `src/flyology-http-client.adb:927-956` (engine retry in `Fail_Exchange`), `:6528-6548` (wrapper retry), `:5456-5459` (`Checkout_Idle` re-sets `Was_Reused`), contract at `src/flyology-http-client.ads:162-163`
- **Repro:** `./tests/repros/run.sh repro_client_pool_4 150` (exit 1, BUG REPRODUCED, 4 checks / 1 failure)
- **What is wrong:** Two independent retry sites both fire for one `Execute`. The engine's retry is guarded by `Safe_Retry_Used` but re-enters `Exchange_Idle`, and the next `Checkout_Idle` sets `Was_Reused := True` again. Admission is monotonic across that retry, which the code states in place at `:945-947`, so it stays `Possibly_Admitted`, which disables the engine's second pass but still satisfies the wrapper's predicate. The wrapper's own `Retried.all` flag is never touched by the engine. Three transports are touched where the contract describes two, and `Stale_Retries` advances by 2 for one exchange.
- **Notes:** **Not reproduced, by inspection only:** the engine's *second* branch, the pre-handoff replay at `:957-972` (`Admission = Not_Admitted and then Was_Reused`), has no `Safe_Retry_Used`-style guard at all and also clears only `Was_Reused`, so on its own terms it could fire once per dead idle transport. The spike's count of 2 is equally consistent with branch 1 plus the wrapper, so the unbounded case is **not** claimed; the body says to check it when fixing. Only safe methods with no request source reach the engine branch, so there is no semantic harm on the wire. **Maintainer decision listed in the body:** what "retried once" counts (per exchange, per stale transport with an amended `.ads`, or a value derived from `Max_Idle`). Existing coverage that stays correct: `tests/http_client_composable_stale_reuse.adb:306` asserts `Stale_Retries = 1` with one stale idle connection; no maintained test primes two. Cross-referenced to CLIENT-POOL-5, whose dead `Classify_Stale_Retry` is why two predicates exist.

### CLIENT-POOL-5: Four proved `Client_Policy` classifiers have no production caller

- **Severity:** P2 (discovery said P2; unchanged). Not a runtime defect on its own
- **Location:** `src/flyology-http-client_policy.ads:15`, `:52`, `:86`, `:171`; false claims at `proof/proof-status.md:68-71` and `:403-404`
- **Repro:** none possible; there is no runtime behaviour to observe. Checked mechanically instead: searching `src/` for each of the four names matches only the declaration and the body, and `git log --oneline -S<name> -- src/flyology-http-client.adb` returns exactly `1a25f7f` (introduced) and `f0d630d` (last caller removed, 2026-08-23) for all four
- **What is wrong:** `Validate_Upload`, `Classify_Pull`, `Classify_Stale_Retry` and `Classify_Expectation_Response` have no caller anywhere under `src/`. `proof/proof-status.md:68-71` still calls all five named boundaries a "production-consumed SPARK boundary" and `:403-404` still ticks "Confirm production request, upload, response, and retry paths consume the proved classifications". Of the five, only informational-response accounting is consumed (`Classify_Informational`, `Next_Informational_Count` in `src/flyology-http-client-http_1_internals.adb:332,343,538,547`); `Classify_Redirect` is consumed at `src/flyology-http-client.adb:6629` but is not one of the five. The behaviour now lives in hand-written predicates with different inputs.
- **Notes:** Labelled `bug, documentation`. It is the mechanism behind CLIENT-POOL-2 (the dropped `Body_Sent` input) and CLIENT-POOL-4 (one classifier split into two disagreeing predicates), and the body cross-references both. `tests/flyology-http-client_policy-smoke.adb` calls all four directly, which is why both the behavioural suite and `./scripts/prove.sh` stay green; the line numbers in the discovery for `proof-status.md` (`:68-70`, `:402`) drifted and are corrected in the body to `:68-71` and `:403-404`. **Maintainer decision listed in the body:** restore the callers, which is also the fix CLIENT-POOL-2 needs, or delete the four declarations (the package is `private`, so this is not an API break) and rewrite the two document passages. Either way the body asks for a `scripts/test.sh` invariant that each declared policy function has a caller under `src/` outside its own unit, written with a tool the script already requires rather than `rg` (see LIFETIME-2).

### CLIENT-POOL-6: Shutdown racing HTTP/3 establishment reports `Transport_Failed`

- **Severity:** P2 (discovery said P2; unchanged)
- **Location:** `src/flyology-http-client.adb:5414-5417` (H3 handler), `:4963-4967` (`Pool.Install` in the `HTTP_3_Open_Request` arm), `:3272-3273` (`Publish_Connecting`) falling through to `:6017-6022`; contrast `:5560-5563`, `:5593-5596`, `:5653-5656`; wrapper mapping `:6550-6566` and `:6581-6582`; contracts at `src/flyology-http-client.ads:510` and `:690`
- **Repro:** none. PARTIALLY CONFIRMED
- **What is wrong:** `Pool_Controller.Install` (`src/flyology-http-client-pool_controller.adb:293-294`) and `Publish_Connecting` (`:338-339`) both raise `Client_Closed` when stopping. The DNS, TCP and TLS establishment handlers all test `Owner.Pool.Is_Stopping` and produce `Client_Unavailable`; the HTTP/3 handler is the only one of the four that does not, and the `Publish_Connecting` route has no arm-local handler at all. `Client_Closed` is not in the wrapper's re-raise set, so `Execute` raises `Flyology.IO.Device_Error` and a composable caller sees `Transport_Failed`.
- **Notes:** **What is established:** the three-way code disagreement, quoted in full in the body, and that neither HTTP/3 route has any other site that could restore the classification. **What is not:** the race was never driven, and the `Negotiate_HTTP_3` self-correction through `Checkout_Closed` (`:5494-5495`) is read from the code, not exercised. The body says both. **The discovery's premise was corrected:** it said a reproduction was "hard without a hook", but a barrier point already exists. `src/flyology-http-client.adb:3335-3337` parks at `Connection_Test_Hooks.Barrier (16)`, which is `Barrier_Point'Pos (Before_HTTP_Client_Connect)` from `tests/flyology-io-connections-testing.ads:3-19`, immediately before `Start_HTTP_3_Connection` at `:3348-3349`, and `Publish_Connecting` runs after a purely local UDP connect, so **no live QUIC peer is needed**. It was not built here because the seam is compiled out: `flyology_http.gpr:7-20` selects the enabled hook sources only when `FLYOLOGY_CONNECTION_TEST_HOOKS` is `"true"`, and turning that on would have rebuilt an object directory shared with other spikes then running. The body therefore puts the exact test instruction in Suggested treatment: park a `Require_HTTP_3` exchange at that barrier in `tests/http_client_pool_races.adb`, which `scripts/test.sh:173-186` already builds with the hooks, call `Shutdown` from a second task, release, and assert `Client_Unavailable` and `Client_Closed`; `tests/http_client_deadline_matrix.adb:387-392` is the pattern to copy. The `Pool.Install` route has no barrier and would need one added. The fix adds no task, which `scripts/test.sh:75-84` requires of the client units.

### CLIENT-POOL-7: `Exchange_Operation.Finalize` frees a response-head `Reply_Data` without returning its lease

- **Severity:** P2 (discovery said P2; unchanged. It would be P1 or P0 if reachable without abort)
- **Location:** `src/flyology-http-client.adb:1926-1929`, producer at `:1167-1175` and `:1177-1184`, the contradicted comment at `:1921-1922`, the routine that does it right at `:7369-7404`
- **Repro:** none. PARTIALLY CONFIRMED (defect yes; "reachable" as stated, no)
- **What is wrong:** `Finalize` frees a non-null `Reply_Data` with a plain `Ada.Unchecked_Deallocation` (`:535-536`). For `Response_Head_Target` that record carries `Connection`, `Slot_Index` and `Retains_Owner => True`, and `Finish_Response_Head` has already nulled the exchange's own aliases on purpose, so the two preceding `Release_Exchange_Transport` calls see nothing to release. If reached, the slot stays `Leased`, `Await_Drained` never opens, `Shutdown` raises `Timeout_Error`, and `Client_State` is never freed.
- **Notes:** **The discovery report's reachability claim was corrected and the body is written to the narrower claim.** The discovery said "reachable through abort or an exception between terminal completion and `Finish`"; only abort holds. Synchronous: `Wait_All`, one field read, `Finish` (`:6504-6506`), and nothing between them can raise on a normal path. Composable: `Exchange_To_Response` is declared in the *private* part (`src/flyology-http-client.ads:1322-1329`, `@exclude` at `:1317`) so no ordinary application can call it, SSE always retires through `Finish_Exchange` (`src/flyology-http-client-sse.adb:709-722`, called at `:787` and `:823`), and abandoning a terminal operation without `Finish` is itself a caller contract violation under the pinned runtime (`flyology-operations.ads:236-237` and `:252-253`). No abort spike was manufactured: a program that has to abort a task to hit a two-statement window says nothing the code reading does not. The hole is in the code whose own comment says "Never erase an unresolved pool lease". **Maintainer decision listed in the body:** a deterministic regression test needs a barrier point between `Wait_All` and `Finish`, which means a new `Barrier_Point` enumeral whose positions are matched numerically by `Barrier (16)` at `:3336`, so the options are append-at-end, renumber every call, or close by inspection. Cross-referenced to CLIENT-POOL-8, whose `Abandon_Response` this fix reuses.

### CLIENT-POOL-8: `Response.Finalize` frees the lease record without returning the pool slot

- **Severity:** P2 (discovery said P2; unchanged)
- **Location:** `src/flyology-http-client.adb:7388-7403` (the handler) and `:2156-2164` (`Abandon_Response`'s unguarded HTTP/2 teardown); the guarded sibling at `:725-760`
- **Repro:** none, and none possible in-process today. PARTIALLY CONFIRMED (defect yes; trigger needs a seam)
- **What is wrong:** `Response.Finalize`'s `when others` handler releases the lifetime retention and then frees the `Response_Data` without returning the lease. The window is narrow and was pinned precisely: `Abandon_Response` returns at once when `Data.Connection = null`, and `Release_Lease` nulls `Data.Connection` right after `Return_Lease` (`:2141-2143`), so a raise from `Owner.Lifetime.Release_Response` leaks nothing. The leak is specifically `Abandon_Response` raising before `Release_Lease` completes. Nothing is freed twice, so there is no use-after-free; the slot, the connection and its socket leak until the process exits and `Shutdown`'s drain barrier never opens.
- **Notes:** **LIFETIME-4 is folded in here as the second site.** LIFETIME-4 describes the same failure from the raising call's side (`Abandon_Response` at `client.adb:2157-2163`) rather than the handler's, with the same consequence, the same precondition and the same missing seam. What it adds is a **simpler fix**, which the body carries: guard the three calls in `Abandon_Response` the way `Release_Exchange_Transport` already guards its own, so `Release_Lease` always runs and the handler is never entered. Both fixes are presented, with the smaller one first. **The trigger search came up empty and the body says so:** `Is_Usable` would need a null `HTTP_2`, which `Take_Active_For_Interrupt`/`Finish_Interrupt` (`pool_controller.adb:543-597`) prevent; `Cancel_Stream` (`http_2_client_connection.adb:2366-2373` into the protected body at `:1625-1649`) can only raise `Storage_Error` from `Queue_Control_Frame` at `:1636` or a wake-source failure on EMFILE/ENFILE or an unexpected write errno; `Release_Stream` (`:1651-1670`) only from already-broken accounting. None is valid input via a reachable path. **Maintainer decision listed in the body:** the fault-injection seam that would settle it is a new test-only control surface on `Flyology.HTTP.HTTP_2_Client_Connection`, with options of a build-time selection like the existing connection hooks, a generic formal, a caller-supplied hook, or no test.

### Coverage evidence

**Read.** `src/flyology-http-client.ads` in full (1402 lines). `src/flyology-http-client.adb` (7406 lines): declarations, pool and lease release, `Fail_Exchange`, the `Finish_*` family, `Start_Exchange`, constructors, `Finish`, `Drive`, `Request_Cancellation`, both `Finalize` bodies, `Dispose_Connection`, `Close_And_Finish`, `Interrupt_Active`, `Release_Lease`, `Abandon_Response`, `Validate_Composable_Encoding`, the engine's admission, connect, TLS and verify states, `Send_*`, `Pull_Source`, `Probe_Early_Response`, `Receive_*`, `Resolve_Redirect`, `Execute_Operation_Once`, `Execute_Redirects`, the lease parts of `Read_Body`, `Read_All` and `Shutdown`. HTTP/1 head parsing and the HTTP/2 and HTTP/3 pump bodies were left to the other areas. Also `pool_controller.adb` (686), `state_lifetime.adb`, `client_policy.ad[bs]`, `authentication.ad[bs]`, `request_bodies`, `channels`, `files`, `testing`, and the named regions of `http_1_internals.adb` and `sse.adb`. Pinned runtime `flyology` at `bd95746d`: `IO.Infinite`, `Time_Math.Remaining`, `Operations.Drivers.Arm_Deadline`, `Operations.Wait_All`, `Operations.Continue_After`, `IO.DNS.Max_Addresses`, `IO.Files.File_Offset`. Tests: `http_client_redirects`, `http_client_audit`, `http_client_upload_controls_smoke`, `http_client_composable_stale_reuse`, `http_client_pool_races`, `http_client_deadline_matrix`, `flyology-http-client_policy-smoke`. Also `proof/proof-status.md`, `scripts/prove.sh`, `scripts/test.sh` and `flyology_http.gpr`.

**Executed.** Three spikes, all re-run at drafting time from the worktree root: `repro_client_pool_1` (exit 1, 4/4 failures), `repro_client_pool_2` (exit 1, 7 checks / 5 failures), `repro_client_pool_4` (exit 1, 4 checks / 1 failure). `repro_smoke` passes on the tree as left. No `alr`, `gprbuild` or maintained script was run directly; every build went through the spike runner. Mechanical checks for CLIENT-POOL-5: a name search over `src/` and `git log -S` per classifier, plus `git show f0d630d -- src/flyology-http-client.adb`.

**Suites and peers that bear on this area.** None of the green baselines reach any of these findings, and the issues say so rather than implying coverage. h2spec 2.6.0 and Autobahn are server-side. The HTTP/3 interop run does not drive the synchronous client wrapper. The PycURL differential exercises the client but scripts neither a URL-bearing redirect query nor a late 417. No peer-behaviour claim is made in any of the seven bodies, so no severity rests on one.

**Could not be exercised.** CLIENT-POOL-6's race: the barrier point exists (`Before_HTTP_Client_Connect`) but is compiled only into the `FLYOLOGY_CONNECTION_TEST_HOOKS=true` library, and enabling it would have rebuilt an object directory shared with concurrently running spikes; the exact test is specified in the body instead. CLIENT-POOL-7: reachable only by aborting a task inside a two-statement window with no barrier. CLIENT-POOL-8: needs a fault-injection point inside `H2_Connections` that does not exist. The second engine retry branch under CLIENT-POOL-4 (`:957-972`) was read but not driven.

### Refuted and not counted

Nothing was refuted. Two claims that would have changed a verdict were spot-checked and held: `Release_Lease` does null `Data.Connection` before any further step, which is what makes `Abandon_Response` idempotent and confines CLIENT-POOL-8 to its narrow window; and `Deadline_After` does map negative to `No_Deadline`, so the negative `Continue_Wait` is genuinely the only sentinel reaching an arm call.

Reviewed with no findings: the pool controller state machine (every transition traced for count coherence; prior finding 10 has not regressed; deferred-close handshakes checked in both orders); lease release on every composable exit path (`Release_Exchange_Transport` is idempotent and invoked from every leg); deadline arithmetic other than the duplicate; redirect policy other than CLIENT-POOL-1 (hop bound, cycle detection, method rewriting through the proved `Classify_Redirect`, `Rewrite_Without_Content`, cross-origin handling, `Remove_Dot_Segments` per RFC 3986 s5.2.4); authentication (preemptive only, so the challenge-parsing hunt list does not apply; Base64 correct for all three tail lengths; RFC 7617 s2 validation present); request body sources; replay eligibility against RFC 9110 s9.2.2; Unix-socket transport and origin binding; cancellation and shutdown wiring; `State_Lifetime` counts.

Observations recorded but outside the rubric: `Set_Bearer` accepts a token of only `=` characters (`authentication.adb:75-87`), which is application input rather than network input; `Deadline_After (Duration'Last)` raises `Constraint_Error` from `Clock + To_Time_Span`, and the `.ads` documents only negative and zero; `Execute_Redirects` raises the hop-limit error before resolving the target, so a cross-origin redirect arriving exactly at the limit raises instead of being returned; composable exchanges never replay REFUSED_STREAM or GOAWAY although the composable `.ads` claims the same semantics as `Execute`; `Finish` assigns `Reply.Data` without finalizing a previously initialized `Reply`; `Shutdown` uses a plain `select ... or delay` and holds the calling pthread; `Start_Exchange:1277-1285` reads `Source_Length` before assigning it, which is unreachable; the `Waiting_For_DNS` more-than-16-addresses branch is unreachable because the pinned resolver caps `Max_Addresses` at 16 (a refuted candidate); `Try_Checkout`'s `Can_Open` calls under the pool lock, where prior finding 37's contention note stands unchanged; and an orphaned comment before `Finish_Close` describing a procedure that no longer exists.

## WEBSOCKET

WebSocket on both sides: the client `flyology-http-websocket_client.adb/.ads` read in full,
the proved policies `flyology-websocket_policy`, `flyology-websocket_client_policy` and
`flyology-websocket_deflate_policy`, the server handlers
`flyology-http-server-websocket_handlers.adb/.ads`, the permessage-deflate codec
`flyology-http-server-websocket_deflate.adb/.ads`, and the WebSocket ranges of
`flyology-http-server.adb` covering the SHA-1 tail, Base64, key validation, token matching,
deflate negotiation, `Accept_WebSocket`, frame send, `Receive_WebSocket`, `Send_WebSocket`
and `Close_WebSocket`. Four findings: three CONFIRMED and one PARTIALLY CONFIRMED, all
reproduced, two P1 and two P2. WEBSOCKET-2 was raised from P2 to P1. **Three of the four are
client-side, which is exactly what the available evidence predicts**: Autobahn passed against
the **server** in this review and the client has never been run in Autobahn's
client-under-test role.

### WEBSOCKET-1: The client control-frame bound is scoped to one Receive call, so keepalive pings end a healthy session

- **Severity:** P1 (discovery said P1; kept). The intended long-wait usage of the API is what
  triggers it.
- **Location:** `src/flyology-http-websocket_client.adb:32` (the bound), `:1200` (the counter
  as a local of `Receive`), `:1252-1257` (the check), `:1315-1317` (the drop); contrast the
  server's identical bound at `src/flyology-http-server.adb:4577` and `:4591` with its resets
  at `:4302` and `:4611-4621`.
- **Repro:** `./tests/repros/run.sh repro_websocket_1` (exit 1, BUG REPRODUCED; re-run for the
  drafting pass, 3 checks, 2 failures).
- **What is wrong:** `Control_Count` is a local of `Receive` and nothing resets it inside a
  call, so every Ping and Pong a peer sends during one call accumulates toward 32. The only
  supported way to wait indefinitely is to stay inside one `Receive` with a negative timeout,
  because `websocket_client.ads:263-264` states that timeout or cancellation terminates the
  session and `Remaining` at `:39-48` maps a negative timeout to `Flyology.IO.Infinite`. The
  spike's raw peer writes 33 back-to-back Pings and then a text frame: the client answers
  exactly 32 with masked Pongs, which the peer counts, then raises
  `Protocol_Error "too many WebSocket control frames"` and drops the transport, so the text
  message is never delivered.
- **Notes:** The primary fix, matching the server's reset discipline, adds no value; the
  alternative of a rate bound introduces an interval and is flagged in the body as a
  **maintainer decision** with the options listed and none chosen. The body also records that
  if the counting decision is moved into `Flyology.WebSocket_Client_Policy`, that unit **is**
  proved by `./scripts/prove.sh` and the change must keep the proof discharging with
  `--checks-as-errors=on`; the counter as it stands is production code outside any proved
  unit. The "about 16 minutes at a 30-second ping interval" arithmetic was checked and is
  right: the 33rd ping falls between 960 s and 990 s. That common servers ping at intervals of
  tens of seconds is general knowledge and is **not verified against a peer**; the defect does
  not depend on it, only the time to trigger does, and the body says so. No existing test
  asserts the wrong behaviour; `tests/websocket_client_smoke.adb:339-346` interleaves exactly
  one ping. Autobahn would not catch it either way, since its cases never send more than a
  handful of control frames.

### WEBSOCKET-2: Close drains the peer close under the default 1 MiB bound and raises an exception its contract omits

- **Severity:** **P1** (discovery said P2; **raised**). The rubric places a documented-contract
  violation at P1, and two contracts are violated. `Receive`'s `@exception` list names both
  `Message_Too_Large` and `Protocol_Error` (`websocket_client.ads:272-278`) while `Close`'s
  names neither (`:310-314`), yet `Close` calls `Receive`; the two lists sit fourteen lines
  apart, so the omission reads as a statement about `Close` rather than as shorthand. The
  guide makes the same promise in prose (`website/guide/client/index.html:443`): `Close`
  "discards complete data messages that crossed the close before the peer observed it". It
  discards them only while they are under 1 MiB.
- **Location:** `src/flyology-http-websocket_client.adb:1372-1374` (the drain call with no
  `Max_Message`), the raise at `:1233`, the drop at `:1315-1317`; the default at
  `src/flyology-http-websocket_client.ads:17`; the server's retained-bound solution at
  `src/flyology-http-server.adb:4811-4817`.
- **Repro:** `./tests/repros/run.sh repro_websocket_2` (exit 1, BUG REPRODUCED; re-run,
  4 checks, 2 failures).
- **What is wrong:** The application consumes a message with `Max_Message => 2 MiB`; the peer
  then sends 1 MiB plus one byte, which crosses the client's Close on the wire. `Close` sends
  its masked Close frame and enters the drain loop, which calls `Receive` with no
  `Max_Message`, so `Maximum` is `Policy.Frame_Length (Default_Max_Message)`, 1 MiB.
  `Classify_Data` returns `Reject_Message_Too_Large` and `Receive` raises at
  `websocket_client.adb:1233`, exactly the line the spike's traceback names; the handler drops
  the transport and the exception leaves `Close`. `Close_Code` then raises `Program_Error`, so
  the application cannot learn how the session ended, and the peer's own `send` fails with
  `EPIPE` (`errno=32` in the spike output) because the socket is gone before it could read the
  Close frame the client had already written. The handshake is abandoned on both sides, which
  is exactly what RFC 6455 sections 5.5.1 and 7.1.1 make the sender of a Close wait for.
- **Notes:** The fix needs a **user-interface decision** and the body carries the decision
  paragraph with both shapes and the standard option list, choosing neither: a `Max_Message`
  parameter on `Close`, or retaining the last `Receive` bound in the `Client` record as the
  server already does. Independently of that choice, `Close`'s `@exception` list should be
  corrected, and the body says so separately because that part needs no decision. The causal
  chain needs no second control case: the application's own `Receive` accepted 2 MiB for the
  first message and the only `Maximum` in play on the failing call is the parameter default.
  No existing test asserts the wrong behaviour; `tests/websocket_client_smoke.adb:788-793`
  crosses only a small message past a close.

### WEBSOCKET-3: The client closes the TCP connection with no Close frame on every protocol failure it detects

- **Severity:** P2 (discovery said P2; kept). RFC 6455 section 7.1.7 is a **SHOULD**, and the
  severity prose in the body is written not to overstate it: the connection is still correctly
  failed, the exception is still correct, and no data is misdelivered, so the cost is
  diagnostic and conformance rather than correctness on the wire.
- **Location:** `src/flyology-http-websocket_client.adb:1310-1321` (the handler that catches
  every detected failure), `:546-557` (`Drop_Transport`), with the detections at `:1178-1182`,
  `:1232-1236`, `:1243-1248`, `:1252-1257` and `:1271-1287`; contrast the server's `Fail` at
  `src/flyology-http-server.adb:4243-4260`.
- **Repro:** `./tests/repros/run.sh repro_websocket_3` (exit 1, BUG REPRODUCED; re-run,
  5 checks, 2 failures).
- **What is wrong:** The peer sends `81 01 FF`, a text frame whose single payload byte cannot
  begin a UTF-8 sequence. The client detects it, raises `Protocol_Error`, and the handler
  calls `Drop_Transport`, which closes the socket and does nothing else. **The peer observes
  only EOF: no `0x88` frame arrives**, and the status code the spike reads back is `-1`, its
  sentinel for nothing received. Every protocol failure the client detects takes this path.
  The server engine does the opposite, sending the status before going terminal.
- **Notes:** **The Autobahn client-under-test role remains unexercised**, so this rests on the
  raw-peer spike rather than on a conformance harness; the body states that explicitly. The
  earlier audit recorded that gap, the maintained script is out of scope here and refuses a
  dirty worktree, and nothing in the baselines exercises the client in that role. This is
  precisely what such a run would report, as a close verdict on every failure case. The fix
  needs a write deadline for the failure Close, which is a policy value, so the body carries a
  **maintainer decision** naming the natural derivation (the time still remaining on the
  `Receive` call that detected the failure, already in scope through `Remaining`) alongside the
  other options, and chooses none. The status mapping itself is derived from RFC 6455 section
  7.4.1 and `Policy.Valid_Close_Code` already gates what the client may put on the wire, so no
  new classification is introduced. No existing test asserts the wrong behaviour;
  `tests/websocket_client_smoke.adb:741-754` asserts the exception and `not Is_Open` and never
  inspects what the peer received.

### WEBSOCKET-4: Accept_WebSocket refuses an upgrade whose Sec-WebSocket-Protocol list has a leading or interior empty element

- **Severity:** P2 (discovery said P2; kept).
- **Verdict:** **PARTIALLY CONFIRMED.** The defect is real for a leading or interior empty
  element and for adjacent commas. **The discovery report's second example, a trailing comma
  (`chat,`), is ACCEPTED, and that claim was wrong.**
- **Location:** `src/flyology-http-server.adb:3961-3973` (the probe that runs on every upgrade
  carrying the field), consuming `:3625-3638` (`Header_Has_Exact_Token`), which raises through
  `:319-320` (`Validate_Token`); contrast `:527-550` (`Header_Has_Token`) and `:3798-3799`
  (`Negotiate_WebSocket_Deflate`), which both skip empty elements.
- **Repro:** `./tests/repros/run.sh repro_websocket_4` (exit 1, BUG REPRODUCED; re-run,
  15 checks, 9 failures).
- **What is wrong:** `Accept_WebSocket` probes every upgrade that carries
  `Sec-WebSocket-Protocol` with `Header_Has_Exact_Token (..., "flyology-no-match")`, and that
  helper runs `Validate_Token` on each comma-separated element, which raises on the empty
  string. The probe runs even when the application selects no subprotocol, so the request is
  refused regardless of what the handler wanted, with no response written at all. The spike's
  control, `chat, superchat`, yields 101 with `Sec-WebSocket-Protocol: chat`;
  `chat, , superchat`, `, chat` and `chat,,superchat` each raise
  `Protocol_Error "header token is empty"`.
- **Notes:** **Why the trailing comma is accepted:** the loop condition at
  `src/flyology-http-server.adb:3625` is `while First <= List'Length` and `First` advances to
  `Comma + 1` at `:3638`, so for `"chat,"` the comma is the last character, `First` becomes 6
  while `List'Length` is 5, and the loop ends **before forming the empty final element**. A
  leading or interior empty element produces an empty `Candidate` and reaches `Validate_Token`.
  The issue body is written to what actually reproduces and keeps the trailing comma as the
  passing control; the discovery entry's example should not be reused. **Autobahn misses this
  because its fuzzing client never sends `Sec-WebSocket-Protocol` at all**:
  `tests/autobahn/fuzzingclient-native.json` configures only a URL, an agent name and the case
  selection, so `Header_Field_Count` is zero on every Autobahn upgrade and the probe never
  runs; the limits and compression configurations are the same. Whether any stock client emits
  an empty list element is **not verified against a peer**, and browsers and the common
  libraries do not, which is why P2 stands. No maintainer decision needed: the fix mirrors two
  existing parsers in the same file and adds no value. No existing test asserts the wrong
  behaviour; `tests/websocket_server_audit.adb:229-236` uses fixed well-formed headers.

### Coverage evidence

Read in full: `flyology-http-websocket_client.adb` (1402 lines) and `.ads` (369),
`flyology-websocket_client_policy`, `flyology-websocket_policy`,
`flyology-websocket_deflate_policy`, `flyology-http-server-websocket_handlers.adb/.ads` and
`flyology-http-server-websocket_deflate.adb/.ads`. Read in range: the WebSocket portions of
`flyology-http-server.adb` (lines 310-327, 473-600, 2663-2713, 3098-3165 and 3567-4838) and
`.ads` (820-960, 1035-1052), plus `flyology-http-server-applications.adb:864-990` and its
`.ads`. `flyology-http-server-websocket_handlers-lifecycle.adb` was not read; its spec is a
generic pass-through to `Run`. Tests read: `tests/websocket_client_smoke.adb` (933 lines, the
handshake, framing, close and crossed-data sections plus targeted greps),
`tests/websocket_server_audit.adb`, `tests/websocket_client_tls_smoke.adb` and the Autobahn
configurations. The runtime was consulted read-only from a local Alire release to refute one
candidate, and that checkout is **not** the pinned commit, which is recorded as a caveat on
the runtime statements in the refutation below.

Executed: all four spikes, twice, once during verification and once during drafting; every run
exits 1 with BUG REPRODUCED and the same check and failure counts. The three client spikes
drive the real `Flyology.HTTP.WebSocket_Client` over a loopback TCP socket against a raw peer
inside the program that performs the RFC 6455 opening handshake by hand, with SHA-1 through
`GNAT.SHA1` and Base64 written inline, and then writes crafted frames. The server spike uses
an in-memory `HTTP_Server.Transport`, as `tests/websocket_server_audit.adb` does.

**Autobahn passed against the SERVER in this review.** Core native: 240 OK, 4 NON-STRICT,
3 INFORMATIONAL, 244 OK close verdicts and no failures. Core lightweight, limits native (42
OK) and compression native (180 OK, 36 UNIMPLEMENTED, 216 close verdicts OK) are all green,
and the 36 UNIMPLEMENTED verdicts are the offers the server declines by policy. **Three of the
four findings are client-side, which is consistent with that evidence**, and the fourth,
WEBSOCKET-4, is server-side but on a header the Autobahn client never sends.

Not exercised: the client has never been run in Autobahn's client-under-test role, and it
still has not been. That gap is the one open item in this area and it is not closeable from
here: the maintained script is out of scope for this pass and refuses a dirty worktree.
WEBSOCKET-3 is the most visible thing such a run would report; WEBSOCKET-1 would not be caught
by it either way, since Autobahn's cases never send more than a handful of control frames.
Also not exercised: the TLS path (`TLS_Driver.Send_All` with `Await_TLS_Ready`) in the
refuted zero-timeout candidate below.

Proof boundary: `flyology-websocket_policy.adb`, `flyology-websocket_client_policy.adb` and
`flyology-websocket_deflate_policy.adb` are all in the `-u` list of `scripts/prove.sh`, and
`proof/proof-status.md:55-67` records what the client policy proves (header validation,
fragmentation, close-code decisions). **All four findings lie outside those units**: the
control-frame counter, the drain bound, the failure-close path and the header list parser are
production code. WEBSOCKET-1's body notes the one way a fix could cross that boundary.

### Refuted and not counted

Refuted or checked and found sound, with no finding raised: the client opening handshake (key
entropy, the `Sec-WebSocket-Accept` digest checked against FIPS 180-4 and RFC 4648, the status
line, the `Upgrade` and `Connection` comma lists, the extension and subprotocol rules of RFC
6455 section 4.1 steps 2 through 6, rejection of `Content-Length`, `Transfer-Encoding` and
obs-fold on a 101, the head bound, and request-side injection through `Add_Header`,
`Offer_Protocol` and `Set_Target`); client inbound framing, which is inside the proved
`Validate_Header` postcondition (RSV bits, masked server frames, unknown opcodes, fragmented
or oversized control frames, non-canonical lengths, the 64-bit MSB, the 16 MiB bound) and the
proved `Classify_Data` for fragmentation and size accounting; client UTF-8 validation on the
complete reassembled message and on the close reason, hand-checked for C0/C1, F5..FF, overlong
forms, surrogates, above U+10FFFF and truncated tails; client close handling (one-byte payload
rejected, the proved `Valid_Close_Code`, UTF-8 reason, echo only while open, `Close_Pending`
refusing data sends, wss close-notify); the server upgrade path, unchanged from the earlier
audit's sound reading, including the refuted candidate that a multi-line
`Sec-WebSocket-Protocol` or `Sec-WebSocket-Extensions` offer is not seen, which is wrong
because `Header` comma-joins repeated lines; server framing, fragmentation, UTF-8 and close,
confirmed by the green Autobahn baselines and by the proved `Frame_Cursor`; permessage-deflate
negotiation and the codec (parameter parsing with quoted-string awareness, the RFC 7692
section 7.1 declines, the window-bits restriction matching the encoder, RSV1 acceptance only
on opcodes 1 and 2, the virtual `00 00 FF FF` trailer, output and input size caps so a
compression bomb yields at most the message limit, Huffman tree validation, the proved
`Select_Distance_Tree`); and the `websocket_handlers` lifecycle `Run` (version pre-check,
single writer, outbox drain then close, the proved `Classify_Timeout`, admission refusing
oversized and non-UTF-8 text, reservations released on every path). The earlier audit's
WebSocket findings were checked for regression and all three are still fixed.

One candidate was refuted explicitly: a Pong or Close echo written with `Time_Left = 0.0` at a
quantum boundary would make the connection terminal if the transport refused a zero timeout,
but the runtime's `Send_All` issues a non-blocking `send()` first and raises `Timeout_Error`
only on EAGAIN with no time left, so a control frame of at most 131 bytes to a peer that is
reading lands in the socket buffer on the first call. **Caveat:** that reading was done in a
local Alire release rather than the pinned runtime commit, and the TLS path was not read.

Recorded but outside the rubric: a client data frame above 16 MiB is reported as
`Protocol_Error` rather than `Message_Too_Large`, which is diagnostic wording only; a present
but empty `Sec-WebSocket-Extensions` response header is rejected, which is stricter than RFC
6455 section 4.1 step 5; `Content-Length` or `Transfer-Encoding` on a 101 is rejected, which is
strictness with no practical cost; `Max_Control_Frames`, `Receive_Buffer_Size`,
`Send_Buffer_Size` and `Max_Target_Bytes` are body-private policy values and WEBSOCKET-1
concerns the first one's **scope**, not its value; zero-length non-final continuation frames
are unbounded in count on the client, the same CPU-only case the earlier audit refuted for the
server; the server's control-frame bound resets per message and per idle quantum and is
Autobahn-green; `Decode_Dynamic_Block` accepts HLIT up to 288, which is lenient and harmless;
compression applies only to payloads at or under 4 KiB, which is policy; a client Close
carrying 1010 is echoed verbatim, which is what section 5.5.1 describes; and
`Accept_WebSocket` raising when the configured `Protocol` was not offered is a design choice
consistent with section 4.2.2.

## SSE

Server-sent events on both sides: the client `flyology-http-client-sse.adb/.ads`, the
reconnect policy `flyology-http-sse_client_policy.adb/.ads`, the server handlers
`flyology-http-server-sse_handlers.adb/.ads`, and the three server serialisers,
`Begin_SSE` through `End_SSE` in `flyology-http-server.adb`,
`flyology-http-server-http_2.adb` and `flyology-http-server-http_3.adb`, together with the
client engine sites in `flyology-http-client.adb` that carry a streaming body into the SSE
sink. The formal artifacts under `formal/sse_client/` were read but not executed. Three
findings, all P1, all CONFIRMED, all reproduced; no severity moved and nothing was refuted.
All three spikes reached every backend or path they needed in process, so nothing in this
area is unverifiable by spike. Two caveats set the evidentiary frame for the whole area and
are recorded under Coverage evidence: the TLA+ gate could not be run here, and
`Flyology.HTTP.SSE_Client_Policy` is **not** a SPARK-proved unit, contrary to what was
assumed when the area was scoped.

### SSE-1: HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator that the HTTP/1.1 serialiser preserves

- **Severity:** P1 (discovery said P1; unchanged). A wrong result on valid input through a
  reachable public path: the same `Send_SSE` call delivers different event data depending on
  the negotiated protocol. Not P0, because the HTTP framing is well formed on every backend,
  a stock SSE client parses both bodies without complaint, and the loss is confined to one
  character of application data at the SSE field layer.
- **Location:** `src/flyology-http-server.adb:3346-3355` (the branch that exists) versus
  `src/flyology-http-server-http_2.adb:1986-1993` and
  `src/flyology-http-server-http_3.adb:1322-1329` (the two copies that lack it); reached from
  `Applications.Send_SSE` and `SSE_Handlers.Run`.
- **Repro:** `./tests/repros/run.sh repro_sse_1 150` (exit 1, BUG REPRODUCED; re-run for the
  drafting pass, 9 checks, 4 failures).
- **What is wrong:** One serialisation exists three times, once per backend, and the three
  copies disagree. The HTTP/1.1 data loop ends with a branch that appends an extra empty
  `data:` line when the terminator it just consumed was the final character of `Data`; the
  other two are character-for-character the same loop and stop after the CRLF skip. Because
  the WHATWG dispatch algorithm strips exactly one trailing LF, that extra field is the only
  way a trailing terminator can be conveyed. The verifier reached **all three backends in one
  spike**: HTTP/1.1 writes `data: a\ndata:\n\n` and the shipped client dispatches `"a\n"`;
  HTTP/2 and HTTP/3 write `data: a\n\n` and dispatch `"a"`. `Data => LF` alone is
  indistinguishable from `Data => ""` on two of the three.
- **Notes:** The issue body quotes both halves of the WHATWG mechanism, the data-field rule
  ("append the field value to the data buffer, then append a single U+000A LINE FEED (LF)
  character") and the dispatch rule ("if the data buffer's last character is a U+000A LINE
  FEED (LF) character, then remove the last character"), because the finding depends on the
  pair. The body does **not** mention the earlier audit and presents the defect simply as
  three implementations of one serialisation that disagree; the fact that this is the
  continuation of that audit's unification, with HTTP/3 now a third copy, is recorded here and
  not in the issue. No maintainer decision needed: either the missing branch is added to both
  copies or the three loops are replaced by one shared serialiser, and neither adds a value.
  No existing test asserts the wrong behaviour; no maintained test sends `Data` ending in a
  terminator on any backend, which is why `./scripts/test.sh` is green
  (`tests/http_smoke.adb:827-834` uses an embedded LF and CR,
  `tests/http2_server_audit.adb:71-87` covers injection and UTF-8 rejection only, and the
  HTTP/2 and HTTP/3 SSE integration tests drive raw `Begin_Stream` and `Write_Chunk`).
  `Send_SSE_Comment` has the same three-way duplication but no trailing-terminator branch on
  **any** backend including HTTP/1.1 (`server.adb:3395-3430`), so comments are consistent and
  are not a second instance. Outside every proved unit.

### SSE-2: Event_Too_Large and Reconnect_Delay_Too_Large raised while the body streams surface as Invalid_Event_Stream

- **Severity:** P1 (discovery said P1; unchanged). A documented `.ads` contract is violated on
  the common path.
- **Location:** `src/flyology-http-client.adb:3884-3891` (`Deliver`), consumed at
  `src/flyology-http-client-sse.adb:724-741` (`Handle_Exchange_Failure`) from `:819-825`;
  contract at `src/flyology-http-client-sse.ads:85-86`; the raises at
  `src/flyology-http-client-sse.adb:179-187` and `:307-334`.
- **Repro:** `./tests/repros/run.sh repro_sse_2 150` (exit 1, BUG REPRODUCED; re-run,
  4 checks, 2 failures).
- **What is wrong:** While the response body streams, the parser runs inside `Event_Sink.Write`
  and the engine converts any sink exception into the result kind `Response_Sink_Failed`
  without re-raising it. `Finish_Response_Body` then sees a non-complete result and
  `Handle_Exchange_Failure` falls into its `when others` arm, raising `Invalid_Event_Stream`.
  The identity the caller actually observes is
  `FLYOLOGY.HTTP.CLIENT.SSE.INVALID_EVENT_STREAM` with the message "SSE HTTP exchange failed
  during RECEIVING_RESPONSE_BODY"; the spike compares `Ada.Exceptions.Exception_Identity`
  against `SSE.Reconnect_Delay_Too_Large'Identity` and `SSE.Event_Too_Large'Identity`, so this
  is an identity check and not a message match. A caller cannot distinguish a breach of its
  own `Maximum_Event_Bytes` or `Maximum_Reconnect_Delay` from a malformed server response.
- **Notes:** **The verifier corrected the mechanism the discovery described.**
  `Remember_Failure` (`src/flyology-http-client.adb:675-692`) **does** preserve the identity in
  `State.Failure_Cause`; that field is simply never consulted on this path. It is read in
  exactly one place, the synchronous `Execute` wrapper at
  `src/flyology-http-client.adb:6550-6566`, and only for a result-kind and identity allowlist
  that excludes `Response_Sink_Failed`, and the SSE layer does not use that wrapper at all: it
  drives the composable exchange, whose `Finish` (`:1718-1742`) re-raises only when
  `Has_Saved_Error`, which no sink path sets. So the identity is available to a fix, which
  makes the fix cheap, and the issue body says so. The narrowing that sets the severity is
  also confirmed: with the offending field following a complete event **in the same written
  slice**, the remaining bytes stay in `Event_Source.Pending`, the next `Read` parses them in
  `Process_Buffered` (`:841-861`) outside the sink, and **both documented exceptions reach the
  caller intact**. The behaviour is therefore inconsistent rather than uniformly broken, and
  the failing case is the first violation in a stream, which is the common one. The modelled
  lifecycle is unaffected: `Drive`'s handler reaches `Connection_Fatal_Failure`, which is what
  `ASSURANCE.md:39` maps "caller limit" to, so only the exception identity is wrong. The two
  fix placements are presented without choosing, because the engine-side one changes what
  every composable sink caller observes for `Response_Sink_Failed`. No existing test asserts
  the wrong behaviour; there is no coverage at all
  (`tests/http1_sse_client_integration.adb:153-158` sends `retry: 0001` well within bounds).

### SSE-3: A cancellation token does not interrupt the reconnect wait of the blocking SSE Read

- **Severity:** P1 (discovery said P1; unchanged). A documented `.ads` contract is violated.
  Not P0: the delay is bounded by the caller's own `Maximum_Reconnect_Delay`, so this is a
  large unwanted latency rather than a hang.
- **Location:** `src/flyology-http-client-sse.adb:648-661` (`Begin_Reconnect`), `:890-896`
  (the `Waiting_Reconnect` arm), `:524-539` (the blocking `Read`), `:58-67`
  (`Check_Control`), `:934-961` (`Request_Cancellation`, the path a caller cannot reach);
  contract at `src/flyology-http-client-sse.ads:74-77`.
- **Repro:** `./tests/repros/run.sh repro_sse_3 90` (exit 1, BUG REPRODUCED; re-run,
  5 checks, 1 failure).
- **What is wrong:** `Begin_Reconnect` clamps the interval to the absolute deadline, so the
  **deadline half of the contract is honoured**, but arms `Flyology.IO.Timers.Sleep_For` with
  no token, and the `Waiting_Reconnect` arm calls `Check_Control` only *after*
  `Flyology.IO.Timers.Finish`. The exception identity is therefore right and **only the timing
  is wrong**. The one path that cancels the timer early is `Request_Cancellation`, reached
  through `Flyology.Operations.Cancel` on the `Read_Operation`, which the blocking overload
  constructs internally and never exposes, so a caller using the documented `Token` parameter
  cannot reach it.
- **Notes:** Measured, on the drafting re-run: **3.002937458 s** for a cancellation requested
  **0.200 s** into a **3.000 s** wait, that is about **2.80 s after `Token.Request`**, with no
  observable shortening; the verification run measured 3.0025 s for the same setup. The spike
  uses `retry: 3000` and `Maximum_Reconnect_Delay => 10.0` so it needs no long timeout; a
  server-chosen `retry` anywhere up to the caller's ceiling scales the same way. No maintainer
  decision needed: both fix shapes reuse existing mechanisms and add no public value. No
  existing test asserts the wrong behaviour; all three maintained SSE integration tests pass
  `Token => null` and use a one millisecond retry.

### Coverage evidence

Read in full: `flyology-http-client-sse.adb/.ads`, `flyology-http-sse_client_policy.adb/.ads`,
`flyology-http-server-sse_handlers.adb/.ads`, and the `formal/sse_client/` tree
(`ASSURANCE.md`, the TLA+ model and configuration, the recorded trace, the trace adapter and
the generated Ada). Read in range: `Begin_SSE` through `End_SSE` in
`flyology-http-server.adb`, `flyology-http-server-http_2.adb` and
`flyology-http-server-http_3.adb`, the HTTP/2 stream table, pump and `Queue_Data`, the HTTP/3
`Send_Data` and `Write_Response_Chunk`, and the `Remember_Failure`, `Finish`,
`Resume_Response_To_Sink` and `Deliver` sites in `flyology-http-client.adb`. Tests read:
`tests/http1_sse_client_integration.adb`, the SSE sections of
`tests/http2_server_integration.adb`, `tests/http3_server_integration.adb`,
`tests/http2_server_audit.adb` and `tests/http_smoke.adb`.

Executed: all three spikes, twice, once during verification and once during drafting; every
run exits 1 with BUG REPRODUCED and the same check and failure counts, with SSE-3's timing
reproducing at 3.0025 s and 3.0029 s. `repro_sse_1` reaches all three backends in process:
HTTP/1.1 and HTTP/2 over plain TCP loopback with `HTTP_1_Only` and `HTTP_2_Only` plus
`Client.HTTP_2_Prior_Knowledge`, and HTTP/3 over UDP loopback with `Routes.Serve_HTTP_3` and
`Flyology.QUIC.Test_Connections.Server_Certificate`, the setup
`tests/http3_handshake_recovery.adb:101-108` uses, so no OpenSSL provider or PEM fixture is
needed.

**`./scripts/check-sse-client-formal.sh` could not be run in this environment.** There is no
Java runtime (`/usr/bin/java` is the macOS stub) and no `flyology-tla` executable, and none of
`FLYOLOGY_TLA_JAVA`, `FLYOLOGY_TLA_TLC_JAR`, `FLYOLOGY_TLAPM` or `FLYOLOGY_TLA_CLI` is set.
The TLA+ model, the TLAPS proof, the generated-Ada regeneration and the trace replay are
therefore **unexercised evidence here**, whatever the code inspection concludes. The gate is
wired into CI at `.github/workflows/ci.yml:180-190`; whether it is green at `f078732` was not
checked. This caveat belongs to the area and is deliberately absent from all three issue
bodies.

**`Flyology.HTTP.SSE_Client_Policy` is NOT a SPARK-proved unit**, contrary to what was assumed
when the area was scoped. Verified directly: neither `flyology-http-sse_client_policy.ads` nor
its body carries `SPARK_Mode`, the unit is absent from the `-u` list in `scripts/prove.sh`,
and `proof/proof-status.md` never mentions it (it uses `Ada.Strings.Unbounded`, which
GNATprove does not support). Every site examined in this area therefore lies outside any
proved boundary, and the unit's only formal evidence is the TLA+ trace replay, which was not
run here. Ordinary tests are the only executed evidence that covered this code before this
review.

The TLA+ gate was still spot-checked by reading and does sit on the production path: the trace
adapter is a 1:1 wrapper whose every operation is a single call into
`Flyology.HTTP.SSE_Client_Policy`; the conformance main renames the adapter as `Policy` and
its project pins `flyology_http` at this repository's path, so it compiles against `src/`; the
production client still issues every modelled transition from `Drive`; and the difference
between the recorded `source_sha256` and the raw hash of `SSEClientTrace.tla` is normalisation
rather than drift, which the two commits that ever touched the file demonstrate. One scope
caveat: the committed trace exercises eight actions over twelve steps, and the adapter does
not expose `ConnectionRecoverableFailure`, `ConnectionFatalFailure` or `Stop` at all, so the
Ada-to-model conformance evidence is narrower than the model-checking evidence and narrower
than the transitions production `Drive` issues. `ASSURANCE.md:79-84` states that TLAPS "does not prove byte
parsing or transport code" and that replay "establishes conformance only for the retained
traces", leaving the byte-level field grammar to ordinary tests; the model's subject is the
reconnect lifecycle, so the exchange and timer children, redirect handling and the deadline
clamp in `Begin_Reconnect` are outside it. SSE-2 and SSE-3 both live in that uncovered layer
and SSE-1 is outside the model's subject entirely.

Pinned peers do not bear on this area: h2spec 2.6.0 tests HTTP/2 framing and header
conformance rather than SSE payload semantics, Autobahn is WebSocket, and the HTTP/3 interop
runs against aioquic 1.3.0 and quic-go 0.54.1 are request and response exchanges.

### Refuted and not counted

Checked and found sound, with no finding raised: BOM handling (exactly one leading EF BB BF
per accepted connection, with a short prefix deferred and replayed); line terminators (CR, LF
and CRLF, with a CRLF split across two `Write` slices treated as one terminator and CR CR as
two lines); the field grammar (no colon, colon at position 0, one optional space, unknown
names ignored, case-sensitive names, per-line UTF-8 with U+FFFD replacement and
maximal-subpart resynchronisation); dispatch (data accumulation with LF, the trailing strip,
empty data not dispatching, the event type reset, the `message` default, the id buffer
committed before the empty-data check, NUL in `id` ignored); reconnect state (204 terminal,
any other non-200 or wrong media type fatal, `Last-Event-ID` sent only when nonempty, the
deadline clamp and re-check, composable cancellation during the wait); redirects (same-origin
within the attempt, hop limit, loop detection, reconnect from the original template); server
validation across backends (CR/LF rejection in `Event` and `Id`, UTF-8 validation, NUL
rejection, newline splitting into repeated fields, all identical on the three backends apart
from SSE-1); HTTP/2 backpressure, which was the earlier audit's explicit gap and is handled by
`Queue_Data` chunking at 16384 into the per-stream ring with `Wait_For_Stream` and pump
notification, and where `Await_Drained` simply does not exist in the HTTP/2 server; HTTP/3
SSE through `Write_Response_Chunk` and `Send_Data`; and `SSE_Handlers` byte budgets, token and
deadline checks per quantum, and `Finalize`. The verification's own findings sweep beyond the
three entries raised no new findings.

Recorded but outside the rubric: the last-event-ID buffer is cleared per accepted connection,
which is the literal reading of the standard and is stated deliberately in `ASSURANCE.md`,
though whether shipping browsers keep the previous id across streams was not checked;
`Process_Buffered` handles one octet per drive and reschedules, which is a performance note
only; `Pending` is bounded by the engine's slice size rather than by `Maximum_Event_Bytes`,
which the `.ads` bound does not cover and which is not a defect; every comment, including the
`SSE_Handlers` heartbeat, is followed by an extra LF, which is a harmless dispatch boundary
with an empty data buffer; the API distinguishes 204 from other non-200 statuses where current
WHATWG treats both as terminal, which is API shape rather than a protocol deviation;
`Response_Invalid` is treated as recoverable, consistent with fetch reporting a network error;
an HTTP/2 peer that stops sending WINDOW_UPDATE pins the SSE handler until the route deadline,
which is the documented control; `Frames.Default_Maximum_Frame_Size` and
`Stream_Buffer_Capacity` are coupled at 16384 with no static check tying them; and a header
template already at capacity with neither `Accept` nor `Last-Event-ID` present would raise
`Headers_Too_Large` inside `Drive` rather than at `Open`.

## IRI

This area covers the `flyology_iri` crate: `flyology_iri.adb`/`.ads` (RFC 3986 and RFC 3987
parsing, `Diagnose`, `Try_Parse`, dot-segment removal, `Assemble_Into` and both `Resolve`
overloads), `flyology_iri-web.adb` (the WHATWG URL parser, percent-encode sets, IPv4 and
IPv6 hosts, `Canonical_Host`), `flyology_iri-idna.adb`/`.ads`, `flyology_iri-unicode`, the
project file's suppression scope, and the crate's tests, differential harness, WPT
conformance driver and gate wiring. Four entries came out of discovery and all four are
confirmed; one severity was raised. The entry that matters is the raised one: `Resolve`
recomposes a `//`-prefixed path that has no authority into an authority, so a relative
reference that looks like a path can set the host of the result. The other three are
over-permissive host-parsing gaps whose severity is held down by the same fact: nothing
tracked in this repository consumes the crate.

Two pieces of context bound the whole area. First, the crate is one of the three
independently indexed crates in this repository, so its intended consumers are external
and the "no in-repository consumer" argument bounds the blast radius here without bounding
it for a downstream user. Second, `flyology_iri` has no proof script and none of its units
appear in `scripts/prove.sh` or `flyology_quic/scripts/prove.sh`, so no finding in this
area carries a proof obligation.

### IRI-1: Overlong and out-of-range UTF-8 in a percent-decoded host decodes to a different host

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_iri/src/flyology_iri-web.adb:597` and `:627`,
  `flyology_iri/src/flyology_iri-idna.adb:237-243`, against the crate's own U+FFFD
  rejection at `flyology_iri/src/flyology_iri-idna.adb:189-190`
- **Repro:** `./tests/repros/run.sh repro_iri_1` (exit 1, BUG REPRODUCED, checks: 19
  failures: 8), re-run at drafting time
- **What is wrong:** `Canonical_Host` percent-decodes the host and hands the bytes to
  `IDNA.To_ASCII`, which decodes with
  `Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Decode` and handles only `Encoding_Error`.
  That decoder classifies the lead byte by shape alone, with no minimum-value test and no
  cap at U+10FFFF, so `C1 81` becomes `a`, `C0 AE C0 AE` becomes `..`, and `F4 90 80 80`
  becomes code point 16#110000#, which `Punycode` then encodes as `xn--en32g`.
  `http://%C1%A5xample.com/` is accepted with host `example.com`, and `Diagnose` reports
  `NO_ERROR` at offset 0 for every case, so nothing downstream can tell these apart from a
  clean host. The escaped and raw forms behave identically, so this is not a
  percent-decoding defect.
- **Notes:** the spike carries three controls that keep the claim honest: the same raw
  bytes are rejected under `IRI_Syntax` (so the two syntaxes disagree on one input), an
  overlong NUL is rejected incidentally by the separate NUL rule, and a surrogate is
  rejected because the standard-library decoder does check that one shape. The corpus
  absence was re-verified independently at drafting time: `urltestdata.json`,
  `ada_extra_urltestdata.json`, `toascii.json` and `ada_long_urltestdata.json` in the
  pinned checkout contain zero occurrences of `%C0`, `%C1`, `%E0%8`, `%F0%8`, `%F4%9` or
  `%F5` through `%FF`, and zero raw 0xC0, 0xC1 or 0xF5 through 0xFF bytes. The oracle's
  rejection was re-verified by reading `build/ada-url/src/ada_idna.cpp` at 32dabc8d: the
  two-byte branch returns 0 for `code_point < 0x80`, and the three- and four-byte branches
  range-check likewise. The out-of-Unicode `Wide_Wide_Character'Val (16#110000#)` is not
  erroneous execution in Ada: `Wide_Wide_Character` spans 2**31 positions and the category
  lookups are binary searches over sorted range tables, not indexed reads.
- **Severity reasoning:** the harm is the classic validate-then-forward overlong
  differential, which needs a consumer. There is none in this repository: no tracked `.ads`,
  `.adb` or `.gpr` file outside `flyology_iri/` references the crate, re-verified at
  drafting time over `git ls-files`. The HTTP client and server parse targets with their
  own code. The filed body states that in the Severity section, as the drafting brief
  requires.
- **Fix decision:** none required if the fix reuses an existing `Error_Kind`. A distinct
  diagnosis would add a literal to a public enumeration, which is a maintainer decision;
  the filed body lists the options and does not choose.

### IRI-2: IPv4-in-IPv6 tail accepts leading zeros the WHATWG IPv6 parser rejects

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_iri/src/flyology_iri-web.adb:487-506`
- **Repro:** `./tests/repros/run.sh repro_iri_2` (exit 1, BUG REPRODUCED, checks: 10
  failures: 6), re-run at drafting time
- **What is wrong:** the dotted tail accumulates every digit into `A`/`B`/`C`/`D` and
  validates only `Part /= 4`, `Digit_Count = 0` and `> 255`. There is no "second digit
  after a zero" test and no three-digit cap, so `01`, `04`, `00`, `0255` and `0127` are all
  accepted, and `http://[::01.2.3.4]/` normalizes to the same host as the canonical
  spelling.
- **Notes:** the gate cannot see it and the reason is exact. Ten IPv4-in-IPv6 cases exist
  in the pinned `urltestdata.json`, enumerated independently at drafting time, and only
  case 714 `https://[0:1.00.0.0.0]` carries a leading zero. It also carries five dotted
  parts, so the crate rejects it on the `Part < 4` guard and the zero rule is never
  exercised. `flyology_iri/tests/src/flyology_iri_tests.adb:476-481` pins leading-zero
  rejection for the RFC 3986 `Valid_IPv4` path only; `Canonical_IPv6` is a separate
  implementation with no such test. The spike's three acceptance controls pin that a single
  `0` part stays legal, and its last check shows the crate's own RFC path rejects the same
  literal, so the two syntaxes disagree on one input.
- **Severity reasoning:** the canonical form is correct whenever the input is accepted,
  there is no wire consequence, and the direction is over-permissive, so the only
  consequence is a normalized-host comparison that admits a spelling no stock parser
  admits, and that needs a consumer the repository does not have.
- **Fix decision:** none. Both bounds come from the WHATWG IPv6 parser, so under "Decision
  authority" the fix records the authority next to the check rather than asking for a
  choice.

### IRI-3: IDNA applies no NFC normalization and no leading-combining-mark check, and the disclosure names neither

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_iri/src/flyology_iri-idna.adb:174-211` (`Map_Input`, no
  normalization step) and `:256-305` (the label loop, no mark check); the disclosure at
  `flyology_iri/src/flyology_iri-idna.ads:5-14` and `flyology_iri/README.md:22-32`
- **Repro:** `./tests/repros/run.sh repro_iri_3` (exit 1, BUG REPRODUCED, checks: 7
  failures: 6), re-run at drafting time
- **What is wrong:** UTS #46 section 4 step 2 requires NFC normalization and section 4.1
  criteria 1 and 6 require an NFC label that does not begin with a
  `General_Category=Mark` code point. The crate does neither, so the NFD and NFC spellings
  of one host give two different ASCII hosts (`xn--bucher-xyd.de` against
  `xn--bcher-kva.de`) and a label beginning with U+0308 is accepted. The `=` U+0338 case
  shows the ordering constraint: normalization has to run after the mapping step, because
  the ignorable code points the mapping removes can otherwise block a composition.
- **Notes on the disclosure, which is the whole question for this entry.** The `.ads` and
  the README disclose a deliberately scoped UTS #46 subset, and a gap the disclosure names
  is not a finding. Both lists are about *which code points* are mapped or disallowed:
  the full mapping table, the unassigned and mapped-symbol parts of the disallowed set,
  the ContextJ joiner rules, the remaining bidi clauses, and the absent Punycode decoder.
  Neither text mentions normalization, NFC, or the combining-mark criterion. The README's
  closing sentence, "Hosts outside that subset can still differ from a full UTS #46
  implementation", is a blanket hedge rather than a naming. So the whole of this entry
  falls **outside** the disclosure, and it stays a finding rather than becoming a pure
  documentation issue. The mapping-table, case-folding, ContextJ and bidi gaps the
  discovery entry listed under observations *are* named and are not reported. The filed
  body carries both labels, `bug` and `documentation`, because if the maintainer declines
  the normalization work the documentation half is still owed.
- **Notes on the sweep.** The figures rest on `IdnaTestV2.json`, which the crate's
  conformance driver never runs: `flyology_iri/tests/wpt_conformance.py:45` reads
  `urltestdata.json` and `ada_extra_urltestdata.json` only, while `IdnaTestV2.json` and
  `toascii.json` sit beside them in the pinned corpus. The verifier's numbers were
  reproduced exactly at drafting time by re-running the sweep independently through the
  crate's URL command-line program: `IdnaTestV2.json`, 2671 object cases, 1899 match, 189
  both-accept-different-host, 518 accepted-where-failure-expected, 65
  rejected-where-host-expected, with 87 of the 189 fixed by NFC; `toascii.json`, 87 cases,
  60 match, 10 host mismatches, 7 over-accepts, 10 over-rejects, with 5 of the 10 fixed by
  NFC. The discovery entry said six for that last figure; five is the number that stands.
  The 278 figure for over-accepts whose label begins with a Mark after NFC reproduces only
  when labels are split on all four separators the crate itself maps (`.`, U+3002, U+FF0E,
  U+FF61); splitting on the ASCII dot alone gives 183, and 278 is the correct one. The
  caveat the verifier named is carried into the filed body: the `http://<input>/x` wrapper
  adds noise for the 138 cases whose input carries a URL-structural character and for the
  one empty input, so the real gap is marginally smaller than 189 and 518, in the
  maintainer's favour.
- **Fix decision:** NFC is not a constant-cost fix, because the crate carries no
  composition data and is published independently. That is a maintainer decision; the
  filed body lists the options, including declining the work and naming the gap instead,
  and does not choose. The combining-mark check needs no decision.

### IRI-4: `Resolve` recomposes a `//` path with no authority into an authority

- **Severity:** **P1** (discovery said P2; raised)
- **Location:** `flyology_iri/src/flyology_iri.adb:1666-1673` (`Resolve` is
  `Parse (Assemble (...))`), `:1462-1469` and `:1489-1504` (`Assemble_Into` emits `//`
  only for an authority and otherwise writes the dot-reduced path straight after the
  colon), `:1270-1284` (`Path` strips the WHATWG `/.` guard that `Assemble_Into` then
  needs), `:1675-1700` (the `String` overload's separate route)
- **Repro:** `./tests/repros/run.sh repro_iri_4` (exit 1, BUG REPRODUCED, checks: 13
  failures: 10), re-run at drafting time
- **What is wrong:** `Resolve` serializes the target and reparses it, and the
  serialization has no guard against a dot-reduced path beginning with `//` when there is
  no authority. The reparse then reads those two slashes as an authority, so an authority
  RFC 3986 leaves undefined becomes a defined one. `Resolve (file:/etc/x, "..//evil.com")`
  gives host `evil.com`; `Resolve (file:/var/www/index.html, "/.//evil.com")` gives host
  `evil.com`; `Resolve (sc:/a/b, "..//p")` gives host `p`. A separate defect in the same
  routine runs a WHATWG opaque path through `Append_Dot_Segments`, so `mailto:a/../b`
  becomes `mailto:/b`.
- **Notes:** the raise from P2 to P1 rests on reachability that the discovery entry did not
  draw out and the spike now executes. With `/.//` as the relative reference the base's
  path depth does not matter, so an ordinary absolute `file:` URI with no authority plus a
  plain absolute-path reference is enough; the reference carries no scheme and does not
  begin with `//`, so it looks like a path. That is host confusion through reference
  resolution. A base that *does* carry an authority is safe in every shape tried, which is
  exactly why the previous audit's finding-1 regression suite
  (`flyology_iri/tests/src/flyology_iri_tests.adb:577-598`), which uses authority-bearing
  bases throughout, cannot see it; the spike pins two such controls so a fix cannot trade
  one for the other, plus a third showing an explicit network-path reference must still
  supply the host. The crate gives two different answers for the same bytes:
  `Parse ("sc:/.//p", Web_URL_Syntax)` has no host while `Resolve` of the same reference
  has host `p`, and the spike prints both lines side by side. Both overloads have to be
  fixed together: the `String` overload validates a URI or IRI result with `Diagnose` on
  the assembled bytes rather than by building a second reference, `Diagnose` reports
  `NO_ERROR` for both `sc://p` and `file://evil.com`, and `Check_Resolution_Base` asserts
  `Text = Image (Actual)`. The crate's own comment at
  `flyology_iri/tests/src/flyology_iri_tests.adb:600-605` states that resolving with a web
  base is reachable whenever the relative reference is itself an absolute URL, so the
  web-base variant is on a supported path rather than an abuse.
- **Severity reasoning:** it is not P0. It is not a wire-level or memory defect, and the
  security consequence needs a consumer, which this repository does not have. The filed
  body says that plainly and names the exposed caller: an application resolving a
  reference against a trusted base.
- **Fix decision:** emitting the `/.` guard in URI or IRI mode changes the bytes the crate
  produces for every caller that stores the serialization, so it is a maintainer decision;
  the filed body lists the options, including the component-building route that needs no
  serialization device, and does not choose.
- **Harness note, recorded because it changed mid-review:** when this area was verified,
  `Flyology_IRI` was not on the reproduction harness project path, so the verifier worked
  around it with shell reproductions driving the crate's prebuilt
  `flyology_iri_url_cli` rather than modifying a shared project file. The harness project
  has since been given an explicit `with` of `flyology_iri.gpr`, so all four entries are
  now ordinary Ada spikes and the shell reproductions are gone. Every output quoted in the
  four filed bodies is from an Ada spike re-run at drafting time, and the Ada form is
  strictly better evidence because it reaches `Can_Parse`, `Diagnose` and `Resolve`, none
  of which the command-line program exposes.

### Coverage evidence

Read: `flyology_iri/src/flyology_iri.adb`/`.ads`, `flyology_iri-web.adb`,
`flyology_iri-idna.adb`/`.ads`, `flyology_iri-unicode`, `flyology_iri/flyology_iri.gpr`,
`flyology_iri/README.md`, `flyology_iri/tests/src/flyology_iri_tests.adb`,
`flyology_iri/tests/src/flyology_iri_url_cli.adb`,
`flyology_iri/tests/src/flyology_iri_differential.adb`,
`flyology_iri/tests/wpt_conformance.py`, `flyology_iri/scripts/wpt-gate-test.sh` and the
corpus wiring in `.github/workflows/ci.yml:97-111`.

Executed at drafting time: four Ada spikes, all BUG REPRODUCED with exit 1. Independently
re-run at drafting time rather than taken from a report: the IDNA corpus sweep over
`IdnaTestV2.json` and `toascii.json` (numbers above, all matching the verifier); the byte
scan of all four pinned corpus files for the IRI-1 sequences; the enumeration of the ten
IPv4-in-IPv6 cases in `urltestdata.json`; the `git ls-files` scan establishing that no
tracked source or project file outside `flyology_iri/` references the crate; and the read
of `build/ada-url/src/ada_idna.cpp` and `src/url.cpp` at the pinned 32dabc8d for the two
oracle behaviours cited.

**Regression check over the previous audit.** Eleven of the previous audit's forty-three
findings are located in `flyology_iri/`: numbers 1, 5, 13, 20, 21, 22, 39, 40, 41, 42 and
43 in its contents list. All eleven were re-checked and all eleven are still fixed. The
check was made by reading code, not by commit SHA, and the reason is worth recording: the
fix SHAs the previous audit cites (`4f2c065`, `822acac`, `c174069`, `63c60fb`, `d208434`,
`d273bf9`, `fa53e67`, `82f0099`, `01b1e69`) are **not ancestors of `f078732`**; the fixes
landed as re-authored commits on 2026-08-07 with matching subjects, so a SHA-based check
would have reported every one of them as missing. Three were additionally re-verified by
execution: finding 1 (the merge keeps the base's root slash, and `repro_iri_4`'s controls
confirm from the other direction that an authority-bearing base keeps its host), finding 20
(the lowercase fast path, the uppercase slow path and the percent-escaped slow path now
agree, and all three accept over-length labels and names as `VerifyDnsLength` false
requires), and finding 22 (the workflow pins `ada-url/ada@32dabc8d`, sets
`FLYOLOGY_IRI_REQUIRE_WPT`, and `review/baselines/02-test-sh.log:28` shows
`919/919 (100.0%), mismatches=0`).

*Count discrepancy to reconcile before the findings document goes out:* the discovery
report's heading and the drafting brief both say "fourteen" IRI findings in the previous
audit. The audit's own contents list attributes eleven to `flyology_iri/`, and the
discovery report's own regression table has eleven rows. Eleven is the number the evidence
supports; the narrative should use it.

**A clean negative result: the two items the previous audit flagged but could not settle
are both settled against the finding.** (1) `^` in the path percent-encode set
(`flyology_iri-web.adb:165-166`) is correct. The current WHATWG path percent-encode set is
the query set plus `?`, `^`, `` ` ``, `{` and `}`, and corpus cases 850-851 expect
`/…%5E_%60%7B|%7D~` for a path while 852-855 keep `^` raw in query and fragment; the crate
reproduces all three, giving `/a%5Eb?c^d#e^f`. (2) `Encode_Opaque_Path` encoding only a
single trailing space (`flyology_iri-web.adb:226-241`) is exactly the opaque-path-state
rule: cases 291-298 expect `non-special:opaque  ?hi` to give `opaque %20`, one space kept
and the last one encoded, and `opaque  x?hi` unchanged; the crate matches, including
`sc:  ` trimming to `sc:` and `sc: ?` giving `%20`. Both sets of cases are in
`urltestdata.json`, so the green gate already covers both, and neither needs a new test.

Also checked and sound, not counted: all six percent-encode sets character by character
against the current specification, with corpus cases 844-855 exercising each; scheme
detection and the special-scheme list with its default ports; the authority, userinfo, host
and port states including the last-`@` split, the empty-port and empty-host cases, ports
above 65535 and `file` with a port; every WHATWG IPv4 form including the overflow guard;
and `Diagnose` reduced to the same route `Try_Parse` takes, held to one answer over 10 000
seeded inputs by the differential harness.

Could not be exercised: nothing in this area was blocked. Every claim in the four entries
is reproduced by an Ada spike or by a re-run corpus sweep.

### Refuted and not counted

- **`Wide_Wide_Character'Val (16#110000#)` as erroneous execution.** Considered as a
  separate defect inside IRI-1's path and dropped. Ada's `Wide_Wide_Character` spans 2**31
  positions and the `Ada.Wide_Wide_Characters.Handling` category lookups are binary
  searches over sorted range tables, not indexed reads, so an out-of-Unicode code point is
  simply not found. There is no erroneous execution and no memory fault; the only
  consequence is the wrong host already counted in IRI-1.
- **`Canonical_Host` evaluating `Percent_Decode (Input)` before the IPv6 and opaque-host
  branches that never use it.** Cost only, in the same class as the `Parse (Input, Base)`
  observation the discovery entry recorded. Not a correctness defect.
- **`Host` returning an IPv6 address without its brackets.** This cost a wrong assertion in
  an early draft of the IPv6 spike and looks like a defect until the contract is read. It
  is documented behaviour: `flyology_iri/src/flyology_iri.ads:249`, "Return the host
  without IPv6 brackets, or an empty string." Not a finding.
- **`Port` as an unbounded digit string in the RFC modes.** Recorded by discovery as a
  known coverage gap of the previous audit rather than a new defect; not counted here.

## LIFETIME

Ownership, finalization and lifetime across the whole crate: every `Controlled` and `Limited_Controlled` type and every `Finalize` in `src/`, retain and release pairing, pool interrupt versus lease-holder ownership, server-side bounded resources, router generations, the two task lanes, the test-hook elision machinery, the `compile_fail` harness, and the two specification sentences that claim Ada-enforced lifetime. Read: `src/flyology-http-server-request_tasks.ad[bs]`, `-applications.ad[bs]`, `-exchange_backends.ads`, `-tls.ad[bs]`, `-development_certificates.ad[bs]`, `src/test_hooks/connection/*`, `flyology_http.gpr`, `scripts/check-test-hook-elision.sh`, `scripts/test.sh`, `tests/flyology-io-connections-testing.ad[bs]`, `tests/native/connection_test_hooks.c`, all three `tests/compile_fail/` cases, and the named finalization regions of `client.ad[bs]`, `pool_controller.adb`, `http_3_internals.adb`, `sse.adb`, `http_2_client_connection.adb`, `http_3_client_connection.adb`, `server.ad[bs]`, `routing.ad[bs]`, `middleware_bulkheads.adb`, `sse_handlers.ad[bs]`, `websocket_handlers.ad[bs]` and the server task bodies, plus the pinned `flyology` runtime at `bd95746d`. Four findings were raised. The discovery reviewer wrote "I found nothing I could honestly rate higher"; that restraint was right on two and wrong on two, in opposite directions. LIFETIME-1 is materially weaker than written, LIFETIME-3 is materially stronger and was raised to P1, LIFETIME-2 was raised to P1 on the test-integrity axis, and LIFETIME-4 is a duplicate. Three issues are filed: two P1 and one P2.

### LIFETIME-1: Finalizing an unread HTTP/3 `Response` never releases its stream

- **Severity:** P2 (discovery said P2; unchanged, but for weaker reasons than the discovery gives. It is not P1: there is no reachable path on which a caller or a peer observes anything different)
- **Location:** `src/flyology-http-client.adb:2151-2170` (`Abandon_Response`), consumed by `Response.Finalize` at `:7377-7378`; contract at `src/flyology-http-client.ads:485-490`; siblings that do release at `:762-801` and `src/flyology-http-client-http_3_internals.adb:442-449`
- **Repro:** none, and **none is constructible**. PARTIALLY CONFIRMED
- **What is wrong:** The `HTTP_3_Response` branch sets `Reusable := False` and nothing else, while both sibling teardown paths call `Release_Pump`, `Cancel_Stream` and `Release_Stream`. The residue, and the only thing the issue claims, is that `client.ads:485-490` says finalizing an incomplete HTTP/3 response "closes its transport", which is false while a sibling HTTP/3 exchange is live: the transport is *drained* and the abandoned stream is neither reset nor released inside it. With no sibling the sentence holds, because the slot goes straight to `Closing` and the connection is disposed.
- **Notes:** **Three of the discovery's four claimed consequences fail, and the body is written to the residue only.** (1) "Nothing signals the peer" is not a difference between the paths: `H3_Connections.Cancel_Stream` (`http_3_client_connection.adb:582-592`) is purely local bookkeeping and writes nothing to the wire, and the only site that emits a QUIC stream abort is `H3.Cancel_Request` in the `HTTP_3_Cancel_Request` stage (`client.adb:5232-5246`), reached only while the *exchange* is alive. This removes the RFC 9114 s4.1.1 angle entirely. (2) The leaked slot cannot stall a connection: `Reusable => False` forces the slot to `Draining` (`pool_controller.adb:396-409`), and `Try_Checkout` offers only `Shared` (`:113-120`) and `Idle` (`:156-163`), so drained slots are never re-offered and cannot accumulate toward the concurrent-stream bound; the abandoned `Response` also holds no pump, released at `client.adb:1155-1165`. (3) The unread bytes do not pin connection-level credit. **Two discovery citations corrected in the body:** the stream-handle transfer is in `Finish_Response_Head` (`client.adb:1123-1207`, allocation at `:1167`), not `Finish_Success`; and `Finish_Success` (`:1098-1121`) builds a lease-free `Response_Data` and calls `Release_Exchange_Transport` itself, so a `Response` from that path never reaches the HTTP/3 branch at all. **No reproduction is constructible and that is a property of the finding, not a budget excuse:** the fix is one `Release_Stream` call and nothing observable through any public API changes when it lands (the pool state is identical, `Client_Diagnostics` at `client.ads:165-169` counts no stream slots, the peer sees identical bytes, and `HTTP_3_Client_Connection` is a private package whose live session lives in the client's body). A program that watched the server keep streaming would still fail after the fix, which is the softened assertion to avoid. The body therefore proposes no regression test and explains why. Existing coverage that does *not* reach it: `tests/http3_client_composable_smoke.adb:655-687` abandons an `Exchange_Operation`, which finalizes through `Release_Exchange_Transport` and does release the stream. **Not a duplicate** of H3-QPACK-4 (that is the *server* role leaking a `Sending` slot in `flyology-http-http_3_connection.adb`: different file, role, table and cause) nor of CLIENT-POOL-7 or -8 (those are about a lease never *returned*; this one returns the lease correctly and leaks only the stream slot inside a still-live session). Cross-referenced to CLIENT-POOL-8, whose fix guards the HTTP/2 branch of the same procedure.

### LIFETIME-2: The "no helper task in client units" check fails open and is evadable

- **Severity:** **P1 on the test-and-CI-integrity axis; P2 if forced onto the product-correctness rubric** (discovery said P2). Stated on both scales rather than split: no product behaviour is wrong at f078732, and the invariant holds, so under a rubric whose P1 is "wrong result on valid input" this is not P1; but the rubric has no class for *a check that cannot fail*, and one evasion is unconditional while two more are reachable by ordinary formatting
- **Location:** `scripts/test.sh:75-84`, under `set -eu` at `:2`
- **Repro:** `sh tests/repros/repro_lifetime_2.sh` (exit 1, BUG REPRODUCED, 8 checks / 6 failures). A **shell** reproduction, not an Ada spike; it builds nothing and must be run directly, not through `run.sh`
- **What is wrong:** The check is `if rg -n '<pattern>' <three globs>; then ... exit 1; fi`. With `rg` off `PATH` the command exits 127 *inside an `if` condition*, where `set -e` does not fire, so the `if` takes the false branch and a tree containing the exact violation passes. Four further evasions: keyword case (`Task Probe;`, `TASK TYPE Probe;`), a line break between `task` and the name, a `Flyology.Task_Scopes` instantiation, which contains no `task` keyword, and file scope, since the three globs never reach `http_1_internals`, `websocket_client` or `http_3` although the client withs all three.
- **Notes:** **The invariant DOES hold at the reviewed commit and the body says so first.** The defect is that the check has almost no detection power left. The reproduction lifts the check **verbatim** out of the tracked script with `sed -n '74,84p'` rather than retyping it, so it cannot drift from the file it tests, and runs it against sandboxes built from real copies of the globbed sources. Its two controls are what make the six failures mean something: a plain lowercase `task Probe;` *is* rejected, and the unmodified sources pass. **All four claimed evasions reproduce, plus a fifth** (the file-scope one, which the discovery did not list as separate). `rg` appears **exactly once in the whole repository**, at `scripts/test.sh:75`; nothing in `scripts/test.sh`, `scripts/alire-test-context.sh`, `scripts/find-alr.sh` or `tests/alire_action_context.sh` checks for it, and no CI step installs it (`.github/workflows/ci.yml:63-111`, the `ubuntu-latest`/`macos-latest` matrix). Whether a hosted runner image ships ripgrep is a third-party property that cannot be checked against a pinned peer; what the repository controls is the undeclared dependency. The property is stated publicly at `website/guide/client/index.html:344` and `:383` and at `src/flyology-http-http_3_client_connection.ads:8`, so this is not an internal convention. **Maintainer decision listed in the body:** the line-break evasion needs a multi-line match (`grep -Pzo` is not portable across the macOS and Linux runners), an awk or python3 pass, or an explicit decision to leave it out of scope. The other four fixes are unambiguous and the body states them: require the tool or drop it for `grep -REi`, match case-insensitively, widen the file set to the client's closure, and reject the `Task_Scopes` instantiation. There is no test of the check; the check is itself the test, and the body asks for the shell reproduction to be kept as that test.

### LIFETIME-3: Two specification sentences claim an enforcement Ada does not perform

- **Severity:** **P1** (discovery said P2; **raised**). The discovery's own caveat was the load-bearing uncertainty: "I could not compile a negative case to confirm whether GNAT rejects each escape statically or only at run time". The answer is **neither**: for the cancellation token no check fires at all, statically or dynamically. Rubric P1 covers "a documented contract violated (`.ads` comment)", and this is not drift or missing coverage but a sentence that states a property of the language which is false for the exact idiom it mandates
- **Location:** `src/flyology-http-server-request_tasks.ads:30-31` and `src/flyology-http-server-applications.ads:63-65`; mechanism at `src/flyology-http-server-applications.adb:122-126`; harness at `scripts/test.sh:269-305`; only test at `tests/http_smoke.adb:4363-4379`
- **Repro:** `./tests/repros/run.sh repro_lifetime_3 90` (exit 1, BUG REPRODUCED, 3 checks / 2 failures), with three controls: `repro_lifetime_3b` (exit 2, BUILD FAILED, expected), `repro_lifetime_3c` (exit 2, BUILD FAILED, expected), `repro_lifetime_3d` (exit 1, BUG REPRODUCED)
- **What is wrong:** `request_tasks.ads:30-31` says "Item must be declared with Parent => X.Cancellation so Ada enforces the request-token borrow". `Exchange.Cancellation` returns `Item.Token_Handle.all'Unchecked_Access`, the attribute whose purpose is to suppress exactly that check (RM 13.10, RM 3.10.2), so the mandated idiom is the one with no enforcement. A heap-allocated `Operations.Scope` whose `Parent` is `X.Cancellation` compiles, runs, and outlives its token with no diagnostic and no `Program_Error`. Nothing downstream replaces the check: `Request_Tasks.Configure` (`request_tasks.adb:3-10`) forwards only `X.Deadline` and never compares `Item.Parent` with `X.Cancellation`.
- **Notes:** **The negative case was compiled, which is what makes this stronger than the discovery recorded.** `repro_lifetime_3b`, the identical program with `Parent => Stop'Access`, IS rejected, with `error: prefix of attribute has deeper level than allocator type`, *precisely* the diagnostic the repository already pins for the WebSocket session pool at `scripts/test.sh:303-305`. So the accessibility machinery is live and only the recommended idiom escapes it. `repro_lifetime_3c` and `3d` settle the second sentence: `Request` and `Connection` are rejected under RM 6.4.1(6.4), the token is not, so `applications.ads:63-65` lists three things and enforces two. That is reported as an observation about what the code enforces, not as a compiler-conformance claim. **A spike expected to FAIL to build is unusual, so the body explains what compiles and what does not and states that a build failure is reported as exit status 2 while a reproduced defect is exit status 1.** Labelled `bug` only, not `bug, documentation`: the verification rated it P1 because the sentence is the stated reason there is no run-time check, so the code is the likelier fix, and the body presents the disposition as a maintainer decision rather than concluding the prose should change. **Maintainer decision listed in the body, three options:** correct the two sentences; have `Configure` raise `Program_Error` when `Item.Parent /= X.Cancellation`, which is one comparison of a comparable anonymous-access pair and turns the documented "must" into a check; or stop returning `'Unchecked_Access` from `Exchange.Cancellation`, the only option that makes the sentence true as written and the only one that makes a `tests/compile_fail/` case possible. Coverage: `tests/compile_fail/` holds exactly the three cases `scripts/test.sh:269-305` pins, and neither sentence has one; `tests/http_smoke.adb:4363-4379` is the only `Request_Tasks` test and is a happy path that never requests `X.Cancellation` nor narrows `X.Deadline`, so neither half of "Inherit the Exchange cancellation identity and current absolute deadline" is asserted anywhere. The practical blast radius is small because the natural handler idiom declares the scope locally.

### LIFETIME-4: `Abandon_Response` runs the HTTP/2 stream teardown unguarded before `Release_Lease`

- **Severity:** DUP (discovery said P2; P2 under its primary)
- **Location:** `src/flyology-http-client.adb:2156-2164`, consumed by `Response.Finalize` at `:7377-7378`
- **Repro:** none, and none manufactured
- **What is wrong:** A raise inside `Abandon_Response` leaves the pool lease counted forever, because `Response.Finalize`'s handler frees the `Response_Data` without returning it. LIFETIME-4 writes this from the raising call's side; CLIENT-POOL-8 writes the same failure from the handler's side.
- **Notes:** **Folded into CLIENT-POOL-8 as a second site; no body written here.** Same procedure pair, same consequence (`Await_Drained` never opens, `Shutdown` hangs or raises `Timeout_Error`, `Client_State` never freed), same precondition (an `H2_Connections` primitive must raise), same missing seam. What LIFETIME-4 adds and CLIENT-POOL-8 did not have is a **simpler fix**, which is carried into that body: guard the three calls in `Abandon_Response` the way `Release_Exchange_Transport` already guards its own at `client.adb:725-760`, so `Release_Lease` always runs and the handler is never entered; it is local, needs no new state, and does not touch the handler at all. The full trigger search is also carried across: every raise reachable in `Is_Usable`, `Cancel_Stream` (`http_2_client_connection.adb:2366-2373` into `:1625-1649`) and `Release_Stream` (`:1651-1670`) is heap exhaustion, file-descriptor exhaustion, or an already-violated invariant, so none is valid input via a reachable path.

### Coverage evidence

**Read.** Every `Finalize` in `src/`: `Client_Control`, `Response`, `Exchange_Operation`, the SSE `Read_Operation`, the WebSocket `Client`, the HTTP/3 `Session`, the server `Connection`, `Router`/`Update_State`/`Snapshot_State`, the bulkhead `Guard`, `Reservation_Guard` and the SSE and WebSocket `Session` types, and `Development_Certificates.Identity`. Also `src/flyology-http-server-request_tasks.ad[bs]`, `-applications.ads:55-75,209-216` and `.adb:17-45,122-126`, `-exchange_backends.ads`, `-tls.ad[bs]`, `-development_certificates.ad[bs]`, the server task bodies in `-http_2.adb` and `-http_3.adb`, `src/test_hooks/connection/disabled/*` and `enabled/*`, `flyology_http.gpr`, `scripts/check-test-hook-elision.sh`, `scripts/test.sh`, `tests/flyology-io-connections-testing.ad[bs]`, `tests/native/connection_test_hooks.c`, all three `tests/compile_fail/` cases, `tests/http_smoke.adb:4340-4432` and `tests/http3_client_composable_smoke.adb:640-700`. Pinned runtime `flyology` 0.1.1-dev at `bd95746d5c9c31f5b41b611db9ba82a016ceaaa4` from `alire/alire.lock`, read out of the Alire cache: `flyology-task_scopes.ads` (217 lines), `flyology-operations.ad[bs]`, `flyology-cancellation.adb`, `flyology-io-tls.adb`, `flyology-bounded_channels.ad[bs]`, `flyology-io-connections-drivers.adb`, and the Darwin `flyology-wake_sources.adb`. The sibling 0.2.0 checkout was deliberately not used.

**Executed.** All five runs were repeated at drafting time from the worktree root. `sh tests/repros/repro_lifetime_2.sh`: exit 1, 8 checks / 6 failures, both controls green. `./tests/repros/run.sh repro_lifetime_3 90`: exit 1, 3 checks / 2 failures. `repro_lifetime_3b`: exit 2, rejected at `164:42` with `prefix of attribute has deeper level than allocator type`. `repro_lifetime_3c`: exit 2, rejected at `158:25` and `159:25` with `actual for aliased formal ... has wrong accessibility in allocator (RM 6.4.1(6.4))`. `repro_lifetime_3d`: exit 1, 3 checks / 2 failures. **Read the last lines, not the process status:** `run.sh` re-executes under `alr exec`, and `alr` reports a non-zero child as its own exit 1, so every run leaves the shell at 1; a rejected build is distinguished by `BUILD FAILED` and `exited with code 2`.

**Suites and peers.** No peer bears on this area and no body cites one; all three findings are local ownership, script and specification claims. The suites that bear on it are `tests/http_smoke.adb` (the one `Request_Tasks` test, a happy path), `tests/http3_client_composable_smoke.adb` (abandonment through `Exchange_Operation.Finalize`, not through `Response`), `tests/http2_client_integration.adb` (ordinary HTTP/2 abandonment, where nothing raises), the three `tests/compile_fail/` cases pinned by `scripts/test.sh:269-305`, and `scripts/check-test-hook-elision.sh`.

**Could not be exercised.** LIFETIME-1: no reproduction is constructible, for the reasons above, and the absence is itself the evidence for the severity. LIFETIME-4 and its primary: no fault-injection seam exists inside `H2_Connections`, and none was manufactured. For LIFETIME-2, whether a given CI runner image ships ripgrep could not be checked against a pinned peer and is not claimed; only the repository's own undeclared dependency is claimed.

### Refuted and not counted

Nothing was refuted outright, but LIFETIME-1's failure scenario lost three of its four steps, recorded in that entry above.

Reviewed with no findings: controlled types and abort safety across every `Finalize` in `src/` (none reachable half-initialised; finalize-twice unreachable because `Finalize` is abort-deferred under RM 9.8(10); the protected `Release` underflow guards are unreachable because every release site is paired with an acquire behind a flag cleared before the release); `State_Lifetime` retain and release pairing, one retain against four guarded release sites; `Release_State` idempotence, since `Free_Resolver`, `IO.TLS.Release` and `Free_State` all null their argument; pool interrupt versus lease-holder ownership, disposed exactly once on either interleaving, with `Await_Drained` counting shared slots correctly; server-side bounded resources, acquire and release counted, for HTTP/2 handler slots, HTTP/3 listener slots, ingress reservations, SSE and WebSocket reservation guards, and bulkhead permits; router generations, where `Reclaim` frees superseded generations under a documented, explicitly unchecked precondition (`routing.ads:797-804`), a contract rather than a defect; cancellation and deadlines in both lanes, with no path where one lane observes a cancellation the other does not; `App_Context` sharing, the prior audit's open question, where the library never writes to it and the task-safety obligation is stated, making race-freedom of application mutation an application contract; test-hook elision, where all six hook sites are guarded, both selections declare the same subprograms, and a disabled build cannot reach a hook; the `compile_fail` harness itself, which is sound because each case must both fail to compile and match a pinned diagnostic under `set -e`; `Development_Certificates` ownership; `Server.TLS.Connection_Transport`; and prior findings 10 and 12, whose fixes are present at f078732.

Observations recorded but outside the rubric: HTTP/2 `Serve` teardown waits unboundedly for a handler that ignores cancellation (`server-http_2.adb:2785-2796`), which is the structured-concurrency design, with a `Tasking_Error` path out of `Serve` for which no trigger was found; `Exchange_Operation.Finalize` deliberately leaks `Exchange_State` when a lease is unresolved after two release attempts, a chosen leak over a use-after-free; `Close_And_Finish` calls `Dispose_Connection` before `Finish_Close` with the same reachability caveat as the duplicate above; `Resume_Response_To_Sink` nulls `Reply.Data` before the record copy, not reachable on valid input; the `Stop_Task` handlers in the unified `Serve` variants call `Request_Stop` and not `TCP_Servers.Request_Shutdown`; barrier point numbering is duplicated by hand between `src/` literals, `Barrier_Point'Pos` and `barrier_count = 17` in the native hook, so reordering the enumeration silently retargets a test, which is also the obstacle CLIENT-POOL-7's regression test runs into; `Development_Certificates.Generate`'s `@exception` list is not exhaustive, which matches the repository's style elsewhere; generated private keys are written with the process umask into a default-permission directory, outside the rubric because the package states it is for local development only; the `App_Context` task-safety obligation is stated in one middleware spec and not in the three specs that say only "shared"; `Router.Reclaim` is a use-after-free by contract with an unchecked precondition; and the policy values seen and not questioned, namely `Maximum_Concurrent_Streams = 32`, the HTTP/3 inbox capacity of 32, `Worker'Storage_Size` of 4 MiB, `Max_Route_Length = 128`, the 50 ms `Send_For` slice, the 1 ms `'Terminated` poll, the 2 s barrier wait and the development certificate's one-day validity.

---

# Appendix: artifacts

| Path | What it is |
| --- | --- |
| `review/prior-audit.md` | The 2026-08-07 audit, recovered from `backup/pre-rewrite` at `f0e8fd3` |
| `review/discovery-<AREA>.md` | The twelve read-only subsystem reviews |
| `review/verification-<AREA>.md` | The twelve adversarial verification passes, with verdicts and spike output |
| `review/findings-sections/<AREA>.md` | The per-area sections assembled into this document |
| `review/baselines/SUMMARY.txt` and `review/baselines/*.log` | Every baseline suite, its exit status, its duration and its full output |
| `review/evidence/` | Peer captures: the h2 server SETTINGS flight, the curl GOAWAY, the hpack decoder result, and the Huffman table comparison |
| `review/REPRO_SWEEP.txt` | One clean sweep of every reproduction program |
| `review/TALLY.json`, `review/TALLY.txt` | Machine-readable verdicts and severities |
| `review/filing/` | The drafted issue bodies, the style guide and the filing tool |
| `review/TRIAGE_FOR_CODEX.md` | The triage brief |
| `tests/repros/` | The reproduction harness and every spike |

Everything above is untracked working material. No tracked file was modified by this review.
