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
