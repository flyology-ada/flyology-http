# Verification: H3-QPACK

Commit: f078732
Findings examined: 14. Confirmed: 14. Refuted: 0. Partial: 0. Other: 0.

Every finding reproduced. One severity moved: H3-QPACK-3 from P0 to P1. Final
distribution: **P0 2, P1 7, P2 5** (discovery had P0 3, P1 6, P2 5).

Nothing was refuted, which is itself worth flagging: this area's discovery pass
was accurate about mechanism throughout. The corrections below are to *reach*
and *severity*, not to existence — see H3-QPACK-3 (browser trigger unverified)
and H3-QPACK-8 (needs a concurrent origin, which this repository's own server
is not).

## The shared premise behind H3-QPACK-1, -2 and -3

All three P0 candidates rest on one claim: that the QUIC per-stream receive
window is 16,384 bytes and that nothing above the transport grows it or waits
for credit on the receive path. **The premise holds.** It was settled by reading
the code before any spike was written.

- `flyology_quic/src/flyology-quic-connections.ads:105-109` sets the advertised
  defaults: `Max_Stream_Data_Bidi_Local`, `Max_Stream_Data_Bidi_Remote` and
  `Max_Stream_Data_Uni` are each `16_384`, `Max_Data` is `524_288`,
  `Max_Streams_Bidi` is `29`.
- `flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:18-22` fixes the
  reassembly buffer at the same value as a compile-time constant
  (`Max_Stream_Data : constant := 16_384;`), and the private type invariant at
  `:157-160` enforces `Highest - Base <= Max_Stream_Data`. The buffer bound is
  therefore not merely a default: no configuration can raise it.
- `Encode_Max_Stream_Data` has exactly one call site in the whole QUIC crate:
  `flyology_quic/src/flyology-quic-application_space.adb:862`, inside
  `Build_Receive_Credit_Packet`. That routine raises every tracked stream's
  limit to `Consumed_Offset + Window` and is reached from application code only
  through `Build_Receive_Credit_Datagram`.
- `Build_Receive_Credit_Datagram` has exactly two callers under `src/`:
  `flyology-http-server-http_3.adb:1647` and `flyology-http-client.adb:2541`.
- Consuming stream bytes does **not** move the advertised limit.
  `Flyology.QUIC.Connections.Consume` reaches only `Stream_Table_Policy.Consume`
  (`application_space.adb:93-99`), which advances the reassembly cursor.
  The advertised limit lives in `Receive_Flow_Control_Policy` and changes only
  through `Raise_Stream_Data_Limit`, which `Build_Receive_Credit_Packet` calls.
- On the server, the single `Return_Request_Credit` call is at
  `src/flyology-http-server-http_3.adb:1822-1824`, inside the `H3.Stream_Ended`
  branch of `Process_Event`, further gated by `Request_Credit_Due`
  (`Served mod 14 = 0`, since `Stream_Credit_Interval` is
  `Max_Streams_Bidi / 2 = 14` at `:1497-1502`, or 256 KiB of connection data
  since the last call, `Data_Credit_Interval = Max_Data / 2 = 262_144` at
  `:1503-1504`).

So the premise holds in both of its parts, and the three findings do not
collapse. They are also genuinely distinct failures: -1 is the advertised limit
never being raised while a body arrives, -2 is the fixed 16 KiB reassembly
buffer against whole-frame parsing (which bites even when credit *is* granted,
as on the client receive path), and -3 is unrelated to flow control entirely.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| H3-QPACK-1 | P0 | CONFIRMED | P0 | `repro_h3_qpack_1` |
| H3-QPACK-2 | P0 | CONFIRMED | P0 | `flyology-http-http_3_stream_receive_policy-repro_h3_qpack_2` |
| H3-QPACK-3 | P0 | CONFIRMED | **P1** | `repro_h3_qpack_3` |
| H3-QPACK-4 | P1 | CONFIRMED | P1 | `repro_h3_qpack_4` |
| H3-QPACK-5 | P1 | CONFIRMED | P1 | `repro_h3_qpack_5` |
| H3-QPACK-6 | P1 | CONFIRMED | P1 | `repro_h3_qpack_6` |
| H3-QPACK-7 | P1 | CONFIRMED | P1 | `flyology-http-qpack_field_section_policy-repro_h3_qpack_7` |
| H3-QPACK-8 | P1 | CONFIRMED | P1 | `flyology-http-http_3_client_connection-repro_h3_qpack_8` |
| H3-QPACK-9 | P1 | CONFIRMED | P1 | `repro_h3_qpack_9` |
| H3-QPACK-10 | P2 | CONFIRMED | P2 | `repro_h3_qpack_10` |
| H3-QPACK-11 | P2 | CONFIRMED | P2 | `flyology-http-http_3_message_policy-repro_h3_qpack_11` |
| H3-QPACK-12 | P2 | CONFIRMED | P2 | `flyology-http-http_3_stream_receive_policy-repro_h3_qpack_12` |
| H3-QPACK-13 | P2 | CONFIRMED | P2 | `repro_h3_qpack_13` |
| H3-QPACK-14 | P2 | CONFIRMED | P2 | `flyology-http-http_3_header_policy-repro_h3_qpack_14` |

## H3-QPACK-1: server returns no per-stream receive credit while a body arrives

- **Verdict:** CONFIRMED
- **Severity:** P0 (discovery said P0; unchanged — deadlock in normal
  operation)
- **Repro:** `tests/repros/src/repro_h3_qpack_1.adb`, run with
  `./tests/repros/run.sh repro_h3_qpack_1 90`
- **Output:**

```
  ok   client Initial is built
  ok   QUIC handshake completes
  ok   client control stream starts
  ok   server SETTINGS arrive
  ok   request stream opens
  ok   request HEADERS are sent
  note first Transport_Blocked after 10240 body bytes
  note body bytes accepted by the transport: 15360; Transport_Blocked retries: 65
  FAIL the whole 20,000-byte request body reaches the server within 12.000000000 s
  FAIL the server answers 200 for the buffered upload
checks: 8  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description:** The spike runs the real `Flyology.HTTP.Server.HTTP_3`
  listener over loopback UDP and uploads 20,000 bytes in 1,024-byte HTTP/3 DATA
  frames from a QUIC client that honours flow control. The upload stops
  permanently at 15,360 body bytes — the 16,384-byte stream window minus the
  HEADERS frame and the per-DATA-frame envelopes — and 65 further
  `Transport_Blocked` retries over twelve seconds produce no MAX_STREAM_DATA.
  The server had already consumed every DATA frame into `Payload_Bytes`
  (`server-http_3.adb:1783-1788`), so the stall is not a buffering limit; it is
  that the only emitter of MAX_STREAM_DATA, `Return_Request_Credit`, is called
  only from the `Stream_Ended` branch, which the request can never reach. The
  server's documented buffered-body limit is 1 MiB
  (`Maximum_Buffered_Request_Body` at `server-http_3.adb:45`, and
  `website/guide/server/index.html:369`), a figure no request over ~15 KiB can
  reach. RFC 9000 section 4.1 makes MAX_STREAM_DATA the receiver's only means of
  granting more credit; the peer here correctly refuses to exceed the advertised
  limit and waits forever. The same starvation applies after a 413 from
  `Reject_Oversized_Request`: the server discards further DATA
  (`:1776-1777`) but never sends STOP_SENDING, and RFC 9114 section 4.1 says
  "The error code H3_NO_ERROR SHOULD be used when requesting that the client
  stop sending on the request stream."
- **Why the green baselines do not cover it:** confirmed against the sources the
  discovery entry names. The aioquic oracle POSTs seven bytes
  (`tests/oracle/aioquic_h3_client.py:70`, `send_data(..., b"payload", ...)`
  with `content-length: 7`); the quic-go oracle POSTs the string `"payload"`
  (`tests/oracle/quic-go/main.go:113-114`). No HTTP/3 test in `tests/` moves a
  body over 16 KiB through any peer, so `review/baselines/10-http3-interop.log`
  (PASS in both roles) does not exercise this path.

## H3-QPACK-2: whole-frame buffering against a fixed 16 KiB reassembly window

- **Verdict:** CONFIRMED (both parts)
- **Severity:** P0 (discovery said P0; unchanged)
- **Repro:**
  `tests/repros/src/flyology-http-http_3_stream_receive_policy-repro_h3_qpack_2.adb`,
  run with
  `./tests/repros/run.sh flyology-http-http_3_stream_receive_policy-repro_h3_qpack_2`
- **Output:**

```
  note QUIC reassembly window = 16384 bytes; declared DATA frame length = 20000
  ok   the request field section encodes
  ok   the request stream opens
  ok   the HEADERS frame is consumed
  note largest contiguous DATA payload prefix the window can hold = 16379 bytes
  note Process_Compact status NEED_MORE_DATA, consumed 0
  FAIL a DATA frame larger than the reassembly window makes progress instead of stalling forever
  note Frame_Policy.Parse of a 65,536-byte DATA length: FRAME_LENGTH_TOO_LARGE
  note Process_Compact of the 65,536-byte DATA envelope: FRAME_ERROR
  FAIL a DATA frame length above 65,535 is not a connection error, RFC 9114 section 7.1 setting no maximum
checks: 5  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description:** The spike hands
  `HTTP_3_Stream_Receive_Policy.Process_Compact` the largest contiguous prefix
  the transport can ever present for one frame — a full 16,384-byte window
  holding a DATA envelope that declares 20,000 payload bytes followed by 16,379
  payload bytes — and the policy returns `NEED_MORE_DATA` with `Consumed = 0`.
  `HTTP_3_Frame_Policy.Parse` zeroes `Payload_Length` and leaves `Consumed = 0`
  whenever `Payload_Length > Data_Length - Position`
  (`http_3_frame_policy.adb:78-81`), and `http_3_connection.adb:418-421` calls
  `QUIC.Consume` only `if Result.Consumed > 0`. The reassembly base therefore
  never advances, the type invariant forbids the window from ever holding more,
  and the frame can never complete. The package's own specification states the
  assumption that fails: `http_3_stream_receive_policy.ads:11-13` says
  incomplete envelopes "consume no input and can be retried when the transport
  exposes a longer contiguous prefix" — a longer prefix than 16,384 bytes does
  not exist. This is independent of H3-QPACK-1: the buffer bound is a
  compile-time constant with a type invariant, so it bites even on the client
  receive path where `client.adb:2541` does grant credit.
- **Peer claim, verified:** the discovery entry's quic-go assertion checks out
  against the vendored source at
  `~/go/pkg/mod/github.com/quic-go/quic-go@v0.54.1/http3/`. `response_writer.go`
  lines 177-180 read `l := uint64(len(w.smallResponseBuf) + len(p))` followed by
  `df := &dataFrame{Length: l}` — one DATA frame per `Write`, with only a
  4,096-byte small-response buffer (`maxSmallResponseSize = 4096`, line 27). A
  handler doing `w.Write(make([]byte, 20000))` emits a single 20,000-byte DATA
  frame. On the upload side `request_writer.go:22` is
  `const bodyCopyBufferSize = 8 * 1024`, so quic-go request bodies arrive in
  8 KiB frames and stay under the bound — which is why H3-QPACK-1, not this
  finding, is what a quic-go upload hits.
- **Why `review/baselines/10-http3-interop.log` records a PASS anyway:** the
  interop lane never transfers a frame over the bound in either direction. The
  quic-go and aioquic oracles exchange the strings `"hello"` and
  `"echo:payload"` (`tests/oracle/quic-go/main.go:112-114`,
  `tests/oracle/aioquic_h3_client.py:70-79`), and every response the Ada server
  produces is framed in 1,024-byte DATA frames
  (`Response_Chunk_Size : constant Positive := 1_024` at
  `server-http_3.adb:46`). The interop lane therefore only ever sees frames two
  orders of magnitude below the threshold.
- **Second part (the 65,535 ceiling):** `Parse` maps a declared length above
  `Frame_Offset'Last` to `Frame_Length_Too_Large`
  (`http_3_frame_policy.adb:74-77`), `stream_receive_policy.adb:403-405` maps
  that to `Frame_Error`, and `server-http_3.adb:289` maps `Frame_Error` to
  application error `0x106` on a connection close. RFC 9114 section 7.1
  describes the field as "A variable-length integer that describes the length in
  bytes of the Frame Payload" and states "Note that, unlike QUIC frames, HTTP/3
  frames can span multiple packets"; it sets no maximum. Both sentences were
  fetched from rfc-editor.org during this verification, not quoted from memory.
  Note that `tests/flyology-http-http_3_frame_policy-smoke.adb:45-47` pins the
  current behaviour, so a fix must change that maintained assertion.

## H3-QPACK-3: field-section limits close the connection and are never advertised

- **Verdict:** CONFIRMED (mechanism); the browser trigger is UNVERIFIED
- **Severity:** P1 (discovery said P0; lowered — see below)
- **Repro:** `tests/repros/src/repro_h3_qpack_3.adb`, run with
  `./tests/repros/run.sh repro_h3_qpack_3`
- **Output:**

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  FAIL the server advertises SETTINGS_MAX_FIELD_SECTION_SIZE so a peer can respect its field-section bound
  ok   the first request succeeds
  ok   the oversized request stream opens
  note 33-field section is 294 encoded bytes
  ok   the oversized HEADERS frame builds
  note event DATA_RECEIVED on stream 0
  note event STREAM_ENDED on stream 0
  note poll after the oversized section: NOT_CONNECTED
  (... eleven further NOT_CONNECTED polls ...)
  note transport state after the oversized section: PEER_CLOSED; stream-local reset for the offending stream: FALSE
  FAIL the oversized field section does not close the QUIC connection
  note Open_Request: NOT_CONNECTED
  FAIL a later, unrelated request on the same connection still works
checks: 8  failures: 3
BUG REPRODUCED
exit status 1
```

- **Description:** The spike drives the real listener, completes one ordinary
  GET to show the connection is healthy, then writes one hand-encoded QPACK
  field section of 33 literal field lines (294 bytes, well formed, Required
  Insert Count 0 and Delta Base 0) in a HEADERS frame on a fresh request
  stream. The server's QUIC connection goes to `PEER_CLOSED`, no stream-local
  reset is delivered for the offending stream, and every later request on that
  connection fails with `NOT_CONNECTED`. The chain is
  `QPACK_Field_Section_Policy.Append_Field` refusing the 33rd field at
  `qpack_field_section_policy.adb:130-132` → `Too_Many_Fields` at `:346-349` →
  `stream_receive_policy.adb:292-295` collapsing every non-`Decoded` status to
  `QPACK_Decompression_Failed` → `server-http_3.adb:1911` calling
  `Close_For_H3_Error` → `Application_Error_For` mapping it to `0x200` at
  `:296` → `Build_Application_Close_Datagram`, a connection-scope close. The
  same path is taken for any single value over 16 KiB or name over 256 bytes.
  The limit is also undiscoverable: `server-http_3.adb:1525` is
  `H3.Initialize (State.Session, H3.Server)` with no `Local_Settings`, so
  `Has_Max_Field_Size` stays `False` and no SETTINGS_MAX_FIELD_SECTION_SIZE is
  sent — the spike's first failing check observes exactly that from the peer
  side. RFC 9114 section 4.2.2 offers the intended remedy: "A server that
  receives a larger header section than it is willing to handle can send an HTTP
  431 (Request Header Fields Too Large) status code." Note in any case that
  SETTINGS_MAX_FIELD_SECTION_SIZE is a byte limit, so the 32-field count bound
  is not expressible in it even if it were advertised.
- **Why P1 and not P0, stated plainly:** the discovery entry's severity rested
  on a browser trigger — Chrome's cookie crumbling pushing an ordinary
  navigation past 32 field lines — that the entry itself calls an estimate. **No
  browser was driven here and that trigger is not verified.** On the mechanism
  alone the finding is a wrong error class and a wrong error scope on valid
  input via a reachable path, which is the P1 definition. It is not memory
  unsafety, not silent corruption, not a hang, and not a case where a stock peer
  rejects the server's output; the peer is told immediately and can retry on a
  fresh connection. RFC 9114 section 8 also permits escalating a stream error to
  a connection error. The aggravating factor, and the reason this is at the top
  of P1 rather than the bottom, is that the blast radius is the whole
  connection: the spike shows an unrelated, already-successful request lane
  destroyed by one frame on a different stream. If the browser trigger were
  established by an actual browser run, P0 would follow, because a stock browser
  could then not load the site over HTTP/3 at all. Settling that needs a
  pinned browser peer, which is outside what a spike can do here.

## H3-QPACK-4: server leaks one send slot per cancelled response

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged)
- **Repro:** `tests/repros/src/repro_h3_qpack_4.adb`, run with
  `./tests/repros/run.sh repro_h3_qpack_4 90`
- **Output:**

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  note responses received: 32 of 40; first unanswered attempt 33; transport state CONNECTED
  FAIL every one of 40 cancelled responses still reaches the client
checks: 3  failures: 1
BUG REPRODUCED
exit status 1
```

- **Description:** The count is exact and matches the predicted mechanism with
  no slack: `Max_Streams` is `32` (`http_3_connection.ads:16`), and the
  connection answers exactly 32 requests before going silent on the 33rd. The
  handler used is the ordinary reachable trigger — `X.Begin_Stream` followed by
  a return without `X.End_Stream`, which `server-http_3.adb:1585-1590`
  classifies as `Streaming_Response` and resolves with `X.Mark_Failed`, which
  calls `H3.Cancel_Request` (`:1393-1408`). In
  `Build_Request_Cancellation` the send slot is marked
  `Finished`/`Cancelled` but cleared only for the client role
  (`http_3_connection.adb:668-676`), and the server's later `Release_Request`
  reaches `Release_Message`, whose `Sending` cleanup is guarded by
  `if Item.Local_Role = Client` (`:133-145`). The remaining `Send_Count`
  decrements at `:891`, `:1140`, `:1266` and `:1350` are all Fin-send paths
  that a cancelled stream never takes. `Send_Count` is therefore monotonic
  across cancellations, `Add_Send` returns `Stream_Capacity_Exceeded` at 32
  (`:569-570`), and every later request on the connection receives nothing.
  Note that the transport is still `CONNECTED` at that point: the connection is
  not closed, it simply stops answering, which is the H3-QPACK-6 behaviour
  compounding this one.
- **Existing coverage:** as the discovery entry says, `tests/http3_public_smoke.adb`
  cancels once per role and never inspects capacity afterwards.

## H3-QPACK-5: server never sends GOAWAY or CONNECTION_CLOSE at end of life

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged)
- **Repro:** `tests/repros/src/repro_h3_qpack_5.adb`, run with
  `./tests/repros/run.sh repro_h3_qpack_5`
- **Output:**

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  ok   the single permitted request succeeds
  note event DATA_RECEIVED
  note event STREAM_ENDED
  note after the request limit: GOAWAY seen FALSE, transport state CONNECTED
  FAIL the retiring server sends GOAWAY or CONNECTION_CLOSE instead of abandoning the connection silently
checks: 4  failures: 1
BUG REPRODUCED
exit status 1
```

- **Description:** The listener is configured with `Max_Requests => 1`. After
  the one permitted request completes, `Serve_Connection`'s loop condition
  `Served < Max_Requests` (`server-http_3.adb:1898`) fails, `Cleanup` frees the
  QUIC and request state (`:1922`, `:1834-1842`), and nothing is transmitted.
  Six seconds of polling afterwards yield no GOAWAY and no state change: the
  peer still believes the connection is `CONNECTED` and will keep using it. RFC
  9114 section 5.2 says "Servers SHOULD send a GOAWAY frame when the closing of
  a connection is known in advance, even if the advance notice is small", and
  RFC 9000 section 10.2 says "An endpoint uses a CONNECTION_CLOSE frame (Section
  19.19) to signal that a connection is being closed" — both quoted from
  rfc-editor.org during this verification. The same silent path is taken on
  `Max_Connection_Age` expiry and on listener shutdown. The HTTP/2 server in
  this repository does send GOAWAY (`src/flyology-http-server-http_2.adb:1313`),
  so this is also an internal asymmetry. `grep -rn 'Send_Goaway\|Build_Goaway'
  src/` confirms neither has a caller outside the HTTP/3 session packages
  themselves.

## H3-QPACK-6: exceptions other than Timeout_Error abandon the connection silently

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged)
- **Repro:** `tests/repros/src/repro_h3_qpack_6.adb`, run with
  `./tests/repros/run.sh repro_h3_qpack_6`
- **Output:**

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  ok   the transport admits nine concurrent request streams
  note opened 9 request streams
  note ninth stream answered: FALSE; transport state CONNECTED
  FAIL the server either answers the ninth request or closes the connection explicitly instead of abandoning it silently
checks: 4  failures: 1
BUG REPRODUCED
exit status 1
```

- **Description:** The spike opens nine POST streams with `Fin => False` and
  `content-length: 4`, so no request reaches `Stream_Ended` and all nine slots
  stay occupied. The mismatch the discovery entry identifies is real and is the
  whole trigger: the driver allocates `Maximum_Request_Streams = 8` request
  slots (`server-http_3.adb:44`) while the transport advertises
  `Max_Streams_Bidi = 29` (`flyology-quic-connections.ads:106`), so a
  conformant peer may open 29 concurrent request streams and the ninth
  `Headers_Received` hits `raise Resource_Exhausted with "HTTP/3 request
  capacity is full"` at `:1699-1702`. The event loop's only handler is
  `when Flyology.IO.Timeout_Error` (`:1916-1918`); `Resource_Exhausted` reaches
  `when others => Cleanup; raise` at `:1923-1926`, and the listener worker
  logs it only when `Debug.Enabled`. The observable result is exactly what the
  spike records: the peer gets no response for the ninth request, no stream
  reset, and no CONNECTION_CLOSE, and its transport remains `CONNECTED` for the
  rest of its idle timeout. RFC 9000 section 10.2: "An endpoint uses a
  CONNECTION_CLOSE frame (Section 19.19) to signal that a connection is being
  closed." The other raisers the discovery entry lists share the same handler
  gap and were read but not separately reproduced: `Payload_Too_Large`
  (`:1778-1782`), the CONNECT rejection (`:1563-1566`), `Constraint_Error` from
  `To_Method` on a method over 64 bytes (`src/flyology-http.adb:12-20`),
  `Headers_Too_Large` from a trailer section over 16 KiB
  (`src/flyology-http-headers.ads:10,34`), and `Device_Error` on a
  non-`Succeeded` prepared-response status (`:396-400`, `:454-457`).
- **Interaction with H3-QPACK-4:** the two findings produce the same symptom
  from different causes, and the H3-QPACK-4 spike shows the compounding — after
  the 33rd cancellation the connection is likewise `CONNECTED` and mute.

## H3-QPACK-7: send-side field sections are capped at 1,109 encoded bytes

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged — a documented contract
  violated on valid input)
- **Repro:**
  `tests/repros/src/flyology-http-qpack_field_section_policy-repro_h3_qpack_7.adb`,
  run with
  `./tests/repros/run.sh flyology-http-qpack_field_section_policy-repro_h3_qpack_7`
- **Output:**

```
  note Max_Value_Length = 16384, Max_Fields = 32, Max_Encode_Length = 1109
  note 1,200-byte value: Encode returns SECTION_TOO_LARGE, length 8
  FAIL a 1,200-byte field value, inside the documented 16 KiB bound, encodes for sending
  note 16 KiB :path: Encode returns SECTION_TOO_LARGE
  FAIL a 16 KiB :path, the exact size the contract names, encodes
  note largest sendable single x-long value: 1096 bytes
checks: 2  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description:** The public contract at `src/flyology-http-http_3.ads:17-22`
  advertises `Max_Value_Length : constant := 16 * 1_024;` with the comment
  "Bounded field-value size, including long `:path` values used by presigned
  object requests", and the 0.1.1 CHANGELOG repeats it. The send path cannot
  honour it: `Encode` refuses anything over `Max_Encode_Length = 1_109`
  (`qpack_field_section_policy.ads:21`), and the measured ceiling for a single
  value in a two-field response section is **1,096 bytes**. A 1.5 KiB
  `content-security-policy`, a 1 KiB `set-cookie` or a set of `link` preloads
  therefore cannot be sent. The failure surfaces as
  `Status := QPACK_Decompression_Failed` at `http_3_connection.adb:865-868`,
  which `Send_Headers` and `Try_Send_Response` turn into `Device_Error`, which
  `Dispatch_Request` turns into a 500, and which the client turns into
  `Fail_Exchange (Transport_Failed)` (`client.adb:5218-5229`). The measurement
  also rules out an explanation in which only the 16 KiB extreme fails: the
  cutoff is three orders of magnitude below the advertised bound. No RFC is
  violated; the violated contract is the repository's own `.ads` and CHANGELOG.

## H3-QPACK-8: client credit is connection-wide while its admission test is stream-local

- **Verdict:** CONFIRMED, with a scoping correction the discovery entry does
  not make
- **Severity:** P1 (discovery said P1; unchanged)
- **Repro:**
  `tests/repros/src/flyology-http-http_3_client_connection-repro_h3_qpack_8.adb`,
  run with
  `./tests/repros/run.sh flyology-http-http_3_client_connection-repro_h3_qpack_8 120`
- **Output:**

```
  ok   both HTTP/3 sessions exchange SETTINGS
  ok   two request streams are open
  ok   stream A's response head is ready
  ok   stream B's response head is ready
  note stream A: sent 65536 bytes, owner read 65536; consecutive stalled rounds at exit 0
  note stream B: sent 65536 bytes, owner read none; body result BODY_STREAM_FAILED
  note Response_Buffer_Capacity = 65535
  FAIL the sibling stream whose owner had not read is flow-controlled, not failed
checks: 5  failures: 1
BUG REPRODUCED
exit status 1
```

- **Description:** Two exchanges share one HTTP/3 connection. The spike plays
  exactly the role `client.adb` plays: publish every polled event into a real
  `HTTP_3_Client_Connection.Session`, read only stream A, and grant credit
  when `HTTP_3_Receive_Credit_Due`'s rule fires on A's consumed length. Stream
  B's owner never reads. B fails at 65,536 delivered bytes, one past
  `Response_Buffer_Capacity = 65_535`. The coupling is that
  `Build_Receive_Credit_Datagram` raises **every** tracked stream's limit to
  that stream's own `Consumed_Offset + Window`
  (`application_space.adb:849-866` and again at `:879-895`), while a stream's
  `Consumed_Offset` advances whenever `Poll` decodes its DATA into the ring
  (`http_3_connection.adb:418-421`) regardless of whether the owner read it.
  B therefore keeps being granted credit it has no room for, and the overflow
  test at `http_3_client_connection.adb:414-416` is
  `Stream.Phase := Failed`, not backpressure. RFC 9000 section 4.1: "A receiver
  can advertise a larger limit for a stream by sending a MAX_STREAM_DATA frame
  with the corresponding stream ID" — the limit is meant to reflect what the
  receiver can absorb on *that* stream.
- **Scoping correction, important for triage:** an earlier version of this
  spike drove this repository's own server and **passed**, because
  `Serve_Connection` dispatches one request at a time and so never interleaves
  two response bodies; stream B's head had not even arrived while A was being
  read. The finding therefore needs a peer that multiplexes response bodies —
  quic-go, nginx, Caddy or any concurrent HTTP/3 origin. The spike above
  supplies that interleaving with a raw in-process HTTP/3 server session. Both
  runs are real results and the second is the one that matters, but the
  discovery entry's implied reach (any pooled HTTP/3 connection) should be
  narrowed to "any pooled HTTP/3 connection to a concurrent origin". Not
  verified against a named third-party peer.

## H3-QPACK-9: peer-reset request streams never refill MAX_STREAMS

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged)
- **Repro:** `tests/repros/src/repro_h3_qpack_9.adb`, run with
  `./tests/repros/run.sh repro_h3_qpack_9 90`
- **Output:**

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  note attempt 30 Open_Request: STREAM_LIMIT_REACHED
  note requests opened and cancelled: 29 of 40; first unanswered attempt 30; transport state CONNECTED
  FAIL the client can open and cancel 40 requests, the server refilling MAX_STREAMS as streams retire
checks: 3  failures: 1
BUG REPRODUCED
exit status 1
```

- **Description:** The client opens a request and immediately cancels it — the
  shape of a browser abandoning image loads when a navigation starts. It
  manages exactly 29, `Max_Streams_Bidi`'s default
  (`flyology-quic-connections.ads:106`), and the 30th `Open_Request` returns
  `Stream_Limit_Reached`. The connection is still `CONNECTED` and will never
  recover, because `Return_Request_Credit` computes its cumulative limit as
  `Max_Streams_Bidi + Served` (`server-http_3.adb:1640-1644`), `Served` is
  incremented only by `Dispatch_Request`, and the credit datagram is built only
  in the `Stream_Ended` branch (`:1822-1824`); the `Stream_Reset` branch
  (`:1825-1828`) releases the local slot and sends nothing. RFC 9000 section
  4.6: "Only streams with a stream ID less than
  `(max_streams * 4 + first_stream_id_of_type)` can be opened" — the limit is
  cumulative over all streams ever opened, so a retired stream returns no
  concurrency unless MAX_STREAMS is raised.

## H3-QPACK-10: malformed requests are treated as connection errors

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_h3_qpack_10.adb`, run with
  `./tests/repros/run.sh repro_h3_qpack_10`
- **Output:**

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  ok   the first request succeeds
  note hand-encoded well-formed control answered '200'
  ok   the hand-encoded control request is well formed and answered, so the encoder is not the variable under test
  ok   the malformed request stream opens
  note malformed section is 73 encoded bytes
  ok   the malformed HEADERS frame builds
  (... twelve NOT_CONNECTED polls ...)
  note transport state after the malformed request: PEER_CLOSED; stream-local reset for the offending stream: FALSE
  FAIL the malformed request does not close the QUIC connection
  note Open_Request: NOT_CONNECTED
  FAIL a later, unrelated request on the same connection still works
checks: 8  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description:** One request carrying an uppercase field name kills the
  connection and every other request on it. RFC 9114 section 4.2: "Characters
  in field names MUST be converted to lowercase prior to their encoding" and "A
  request or response containing uppercase characters in field names MUST be
  treated as malformed"; section 4.1.2: "Malformed requests or responses that
  are detected MUST be treated as a stream error of type H3_MESSAGE_ERROR."
  The client role of the same body does exactly that
  (`http_3_connection.adb:426-440` converts `Message_Error` and `Header_Error`
  into a stream-local `Stream_Reset` with `0x10E`), but the guard is
  `if Item.Local_Role = Client`, so on the server the status reaches
  `Close_For_H3_Error` at `server-http_3.adb:1911` and becomes a connection
  close. **Severity kept at P2** because RFC 9114 section 8 permits the
  escalation — "An endpoint MAY treat a stream error as a connection error
  under certain conditions", with the note that implementations should consider
  the consequences for requests in progress — and because the trigger is an
  invalid request from the peer's own connection, so the blast radius is that
  peer's other requests. The asymmetry between the two roles in one code path
  is the part worth fixing.
- **Method note:** the run includes a control. The same hand encoder produces a
  well-formed four-field section on the previous stream and the server answers
  200, so the only variable in the failing case is the uppercase name. The
  first version of this spike had a defective QPACK integer encoding (a
  seven-character field name overflows the three-bit length prefix) and would
  have proved the wrong thing; the control was added for that reason and the
  encoder corrected to RFC 9204 section 4.1.1 prefixed-integer rules.

## H3-QPACK-11: empty DATA frame on a HEAD, 204 or 304 response is rejected

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:**
  `tests/repros/src/flyology-http-http_3_message_policy-repro_h3_qpack_11.adb`,
  run with
  `./tests/repros/run.sh flyology-http-http_3_message_policy-repro_h3_qpack_11`
- **Output:**

```
  note a HEAD response: Body_Allowed FALSE, empty DATA gives MESSAGE_ERROR
  FAIL an empty DATA frame on a HEAD response is accepted
  note a 204 response: Body_Allowed FALSE, empty DATA gives MESSAGE_ERROR
  FAIL an empty DATA frame on a 204 response is accepted
  note a 304 response: Body_Allowed FALSE, empty DATA gives MESSAGE_ERROR
  FAIL an empty DATA frame on a 304 response is accepted
  note a 205 response: Body_Allowed TRUE (the policy permits a body on 205)
checks: 3  failures: 3
BUG REPRODUCED
exit status 1
```

- **Description:** `On_Response_Frame` rejects a DATA frame whenever
  `Body_Allowed` is False (`http_3_message_policy.adb:113-117`) with no
  exemption for `Data_Length = 0`, and `Body_Allowed` is
  `not Request_Is_Head and then Response_Code not in 204 | 304` (`:94-96`). A
  zero-length DATA frame carries no content and so does not offend RFC 9110
  section 6.4.1; RFC 9114 section 4.1 does not address zero-length DATA frames.
  Commit 80e7f6b made this repository's HTTP/2 client accept exactly that
  shape, so the two protocol families disagree.
- **The layer disagreement the discovery entry reports is also confirmed, by
  reading:** `http_3_client_connection.adb:356-357` sets
  `Stream.Body_Forbidden := ... or else Code in 204 | 205 | 304`, including
  205, while the proved policy's `Body_Allowed` excludes only 204 and 304. The
  spike records that the policy permits a body on 205; the resulting
  controller-versus-policy divergence was not separately reproduced.

## H3-QPACK-12: legal QPACK inputs rejected

- **Verdict:** CONFIRMED (both parts)
- **Severity:** P2 (discovery said P2; unchanged). The discovery's "low"
  confidence applied to whether a stock encoder emits either input; the code
  behaviour is now certain.
- **Repro:**
  `tests/repros/src/flyology-http-http_3_stream_receive_policy-repro_h3_qpack_12.adb`,
  run with
  `./tests/repros/run.sh flyology-http-http_3_stream_receive_policy-repro_h3_qpack_12`
- **Output:**

```
  note encoder-stream type octet: CONSUMED, stream kind QPACK_ENCODER_STREAM
  note Set Dynamic Table Capacity 0: QPACK_ENCODER_STREAM_ERROR
  FAIL Set Dynamic Table Capacity to zero, the only capacity the advertised limit permits, is not an encoder-stream error
  note Required Insert Count 0 with Delta Base 1: INVALID_PREFIX
  FAIL a nonzero Delta Base with Required Insert Count 0 decodes, Base being 1 and so not negative
  note control, Delta Base 0: DECODED
checks: 2  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description:** Part (a): `stream_receive_policy.adb:169-174` rejects every
  byte on the peer's QPACK encoder stream. RFC 9204 section 4.3.1: "An encoder
  informs the decoder of a change to the dynamic table capacity using an
  instruction that starts with the '001' 3-bit pattern" and "The new capacity
  MUST be lower than or equal to the limit described in Section 3.2.3." With
  the advertised limit at zero, `0x20` (capacity 0) is the single legal value
  and a conformant no-op, but it is answered with
  QPACK_ENCODER_STREAM_ERROR (0x201, a connection close). Part (b):
  `qpack_field_section_policy.adb:256-262` rejects any nonzero Delta Base. RFC
  9204 section 4.5.1.2: "A Sign bit of 0 indicates that the Base is greater
  than or equal to the value of the Required Insert Count; the decoder adds the
  value of Delta Base to the Required Insert Count to determine the value of
  the Base", with the only constraint being "The value of Base MUST NOT be
  negative." Required Insert Count 0, Sign 0 and Delta Base 1 give Base 1. The
  control line in the output shows the identical section with Delta Base 0
  decoding, so the field count and the static index are not the variable. All
  RFC text was fetched from rfc-editor.org during this verification. Practical
  impact is small: with a zero-capacity dynamic table a nonzero Base addresses
  nothing, so only a gratuitously-emitting encoder is affected.

## H3-QPACK-13: stale Stream_Reset re-emission above stream identifier 4092

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged). The discovery's
  "medium-low" confidence is superseded: the behaviour is deterministic and
  the boundary is now demonstrated with a control.
- **Repro:** `tests/repros/src/repro_h3_qpack_13.adb`, run with
  `./tests/repros/run.sh repro_h3_qpack_13 180`
- **Output:**

```
  ok   the sessions exchange SETTINGS
  note control stream id 0 reported the failure 1 times in 8 polls
  ok   inside the tombstone table one malformed response is reported once
  note completed 1024 warm-up exchanges; last stream id 4096
  ok   the connection retires 1,024 request streams
  note offending stream id 4100; the tombstone table covers ids up to 4092
  ok   the offending stream identifier is past the tombstone table
  note Stream_Reset events emitted for the same malformed response: 8 in 8 polls
  FAIL one malformed response produces one stream failure, whatever the stream identifier
checks: 5  failures: 1
BUG REPRODUCED
exit status 1
```

- **Description:** This is a controlled experiment: the identical malformed
  response, delivered by the identical code path, is reported **once** on
  stream 0 and **eight times in eight polls** on stream 4100, with the stream
  identifier as the only difference. The client is cancelled after each event,
  as the real pump does, and the re-emission continues. On `Header_Error` the
  client role sets `Finished`, emits `Stream_Reset` and returns without
  consuming the offending bytes (`http_3_connection.adb:426-440`; `Consumed` is
  set only on the `Consumed` status). `Abandon_Message` then records a
  tombstone only when `ID / 4 <= Message_Ordinal'Last = 1023`
  (`:148-160`, `.ads:18`) and calls `QUIC.Release_Stream` only when the stream
  is complete or was reset by the peer (`:172-179`). For a higher identifier on
  a stream the peer keeps open, `Is_Released_Message` stays false
  (`:105-113`), `Poll` reaches `Find_Or_Open` at `:355`, a fresh slot is opened
  for the same ID, the same bytes are parsed again and the same event is
  emitted again. The composable pump (`client-http_3_internals.adb:320-346`)
  exits on any `Succeeded` event and calls `Receive_One` only on `No_Event`, so
  the peer's eventual RESET_STREAM is never read and the loop does not
  terminate on its own. The synchronous path avoids the spin by closing the
  whole connection on `Body_Stream_Failed` (`client.adb:2151-2167`), at the
  cost of sibling exchanges. P2 stands because reaching it needs 1,025
  requests on one connection plus a peer that answers malformed and leaves the
  stream open.

## H3-QPACK-14: 204 or 1xx with Content-Length is treated as malformed

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:**
  `tests/repros/src/flyology-http-http_3_header_policy-repro_h3_qpack_14.adb`,
  run with
  `./tests/repros/run.sh flyology-http-http_3_header_policy-repro_h3_qpack_14`
- **Output:**

```
  note 204 with content-length: 0: INVALID_CONTENT_LENGTH
  FAIL 204 with content-length: 0 is not a malformed message for the recipient
  note 103 with content-length: 0: INVALID_CONTENT_LENGTH
  FAIL 103 with content-length: 0 is not a malformed message for the recipient
  note control, 200 with content-length: 0: VALID
checks: 2  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description:** `Validate_Response` sets `Invalid_Content_Length` when a
  response carries `content-length` together with an interim status or 204
  (`http_3_header_policy.adb:414-418`). The control line shows the identical
  field on a 200 validating, so `content-length` parsing is not the variable.
  RFC 9110 section 8.6 constrains the sender, and RFC 9114 section 4.1.2's list
  of malformed conditions does not include it; RFC 9112 section 6.3 has HTTP/1
  recipients ignore it. Frameworks that emit `content-length: 0` on a 204
  therefore become unreachable over HTTP/3. The client controller enforces the
  204 half independently at `http_3_client_connection.adb:365-371`
  (`Code = 204 and then Stream.Has_Expected_Length` sets `Phase := Failed`), so
  a fix must touch both layers.

## Method notes

- Every spike listed above was re-run in one final pass at commit `f078732`.
  All fourteen print `BUG REPRODUCED` and exit 1. The harness self-tests
  `repro_smoke` and `seam_check` still print `PASS` and exit 0, so the
  toolchain and the harness are not the variable in any result.
- No spike hung; no run needed the exit-124 hang convention. `repro_h3_qpack_1`
  bounds the upload at twelve seconds and reports the exact byte count at which
  the transport stops, which is stronger evidence than a timeout would be.
- No maintained script (`scripts/test.sh`, `scripts/prove.sh`, the interop or
  Autobahn lanes) was run by this verifier; `tests/repros/run.sh` was the only
  build entry point.
- Two claims could not be settled in process and are reported as unverified
  rather than assumed: the Chrome cookie-crumbling trigger in H3-QPACK-3, which
  needs a real browser, and the named third-party peer behaviour in
  H3-QPACK-8, which needs a concurrent HTTP/3 origin. The quic-go claim in
  H3-QPACK-2 *was* settled, against vendored source at
  `~/go/pkg/mod/github.com/quic-go/quic-go@v0.54.1/http3/`.
- Three spikes (`repro_h3_qpack_3`, `repro_h3_qpack_10`, `repro_h3_qpack_13`)
  build QPACK field sections by hand. The first version of that encoder was
  wrong — a seven-character field name overflows the three-bit name-length
  prefix of RFC 9204 section 4.5.6 and needs a continuation octet — and it made
  `repro_h3_qpack_13` report the wrong status and would have let
  `repro_h3_qpack_3` and `-10` "reproduce" for the wrong reason, since a
  malformed encoding and a 33-field section both end at
  QPACK_DECOMPRESSION_FAILED. The encoder was corrected to the RFC's
  prefixed-integer rules and each of those spikes now carries a positive
  control: the same encoder producing a section the server accepts with 200, on
  the stream before the offending one. Read those controls as part of the
  evidence.
- `flyology-http-http_3_client_connection-repro_h3_qpack_8` passed twice before
  it reproduced, and both failures were informative rather than noise: the
  first because this repository's server does not interleave responses, the
  second because the in-memory harness sent no ACKs and the peer's congestion
  window, not the ring, was the binding constraint. The final spike removes
  both confounders.
