# Verification: H2

Commit: f078732

Findings examined: 11. Confirmed: 9. Refuted: 0. Partial: 2. Other: 0.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| H2-1 | P0 | CONFIRMED | P0 | `flyology-http-http_2_settings-repro_h2_1` |
| H2-2 | P0 | CONFIRMED | P0 | `repro_h2_2` |
| H2-3 | P1 | PARTIALLY CONFIRMED | P1 | `repro_h2_3` |
| H2-4 | P1 | CONFIRMED | P1 | `repro_h2_4` |
| H2-5 | P1 | CONFIRMED | P1 | `repro_h2_5` |
| H2-6 | P1 | CONFIRMED | P1 | `flyology-http-http_2_requests-repro_h2_6` |
| H2-7 | P2 | CONFIRMED | P2 | `repro_h2_7` |
| H2-8 | P2 | CONFIRMED | P2 | `repro_h2_8` |
| H2-9 | P2 | CONFIRMED | P2 | `repro_h2_9` |
| H2-10 | P2 | CONFIRMED | P2 | `repro_h2_10` |
| H2-11 | P2 | PARTIALLY CONFIRMED | P2 | `repro_h2_11` |

No severity moved in either direction. Every spike is run with
`./tests/repros/run.sh <name>` from the worktree root; `repro_h2_4` needs a longer limit
(`./tests/repros/run.sh repro_h2_4 180`). `repro_smoke` and `seam_check` still PASS.
`tests/repros/src/h2_wire.ad?` is a shared frame-building helper for these spikes, not a
finding spike; its shapes mirror `tests/http2_server_audit.adb`.

## What I settled about the peer claims the discovery reviewer flagged

The discovery report said RFC 7541 and every peer-behaviour claim were cited from memory.
All of them are now checked against a pinned artefact, and none had to be marked
"not verified against a peer":

- **RFC 7541 §4.2 and §6.3** fetched from rfc-editor.org and quoted verbatim under H2-6;
  RFC 9113 §4.3, §5.1, §6.4, §6.5.2, §6.9.3, §6.10 and §8.1 re-fetched and re-checked
  against every entry that cites them. Every quotation in the discovery report that I
  checked was accurate.
- **python-h2 sends `SETTINGS_ENABLE_PUSH = 0` from a server**: verified by driving the
  repository's own pinned install (`h2==4.3.0` in `build/http2-tester`, from
  `tests/requirements-http2.txt`) — `review/evidence/h2_1_h2_server_settings.log`.
- **curl/nghttp2 writes its whole upload before processing the server's SETTINGS**:
  verified by running stock `curl 8.7.1 (nghttp2/1.68.1)` against this server —
  `review/evidence/h2_2_curl.log`. The discovery entry's "medium confidence, curl burst
  not executed" caveat is now discharged.
- **Go `net/http2` sends `RST_STREAM(NO_ERROR)` after a complete response**: verified in
  `golang.org/x/net@v0.57.0/http2/server.go:1218-1235`, the module version in this
  machine's Go module cache that `scripts/http2-interop.sh:77-78` builds the Go peer
  against.
- **An HPACK decoder rejects the first block after a table-size reduction**: verified by
  feeding the crate's own encoded bytes to the pinned `hpack 4.2.0` decoder —
  `review/evidence/h2_6_hpack_decoder.log`.
- **h2spec's 146/146 baseline and the findings it could have caught**: I read h2spec
  2.6.0's source. `spec/verifier.go:53-92` accepts a `ConnectionClosedEvent` as a pass
  before comparing any GOAWAY code, so the baseline does not vouch for error codes (H2-7).
  `http2/5_1_stream_states.go:55-66` sends `WriteWindowUpdate(1, 100)` and
  `http2/6_9_window_update.go:39-62` opens stream 1 with HEADERS first, so neither covers
  H2-8's idle + zero-increment case. Nothing in the suite sends over-window DATA before
  processing the server's SETTINGS (H2-2), runs an application route body limit (H2-5), or
  tests the *encoder* side of HPACK table sizing (H2-6). h2spec tests servers only, so it
  cannot reach H2-1, H2-3, H2-4 or H2-11.
- The Huffman table proof in `review/evidence/huffman_table_check.out` was taken as given
  and not re-derived.

## H2-1: Client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0`

- **Verdict:** CONFIRMED
- **Severity:** P0 (discovery said P0; kept)
- **Repro:** `tests/repros/src/flyology-http-http_2_settings-repro_h2_1.adb`, run with
  `./tests/repros/run.sh flyology-http-http_2_settings-repro_h2_1`
- **Output:**

```
  note H2-1: a server may send SETTINGS_ENABLE_PUSH = 0 (RFC 9113 6.5.2)
  FAIL Apply accepts the pinned h2 4.3.0 server's first SETTINGS payload
  note   Apply returned SETTINGS_PROTOCOL_ERROR
  FAIL Apply accepts ENABLE_PUSH = 0 from a server peer
  note   Apply returned SETTINGS_PROTOCOL_ERROR
  ok   Apply still rejects ENABLE_PUSH = 1 from a server peer
  note   client raised FLYOLOGY.HTTP.PROTOCOL_ERROR: flyology-http-client.adb:6586
  FAIL the client serves a request to a server that sent ENABLE_PUSH = 0
checks: 4  failures: 3
BUG REPRODUCED
EXIT=1
```

- **Description:** `src/flyology-http-http_2_settings.adb:45-50` rejects setting
  identifier 2 whenever `Peer_Is_Server` is True, *regardless of the value*:
  `if Peer_Is_Server or else Value > 1 then Result := Settings_Protocol_Error;`.
  The client passes the default `Peer_Is_Server => True`
  (`src/flyology-http-http_2_client_connection.adb:1831-1835`) and maps any non-accepted
  result to `Protocol_Failure`, which queues GOAWAY, calls `Fail_All` and sets `Closing`.
  RFC 9113 §6.5.2, fetched from rfc-editor.org, says the opposite of the source comment:
  "A server MUST NOT explicitly set this value to 1. A server MAY choose to omit this
  setting when it sends a SETTINGS frame, but if a server does include a value, it MUST be
  0. A client MUST treat receipt of a SETTINGS frame with SETTINGS_ENABLE_PUSH set to 1 as
  a connection error (Section 5.4.1) of type PROTOCOL_ERROR." Only the value 1 is an error.
  Reachability is settled against the pinned peer, not from memory: `h2==4.3.0` is pinned in
  `tests/requirements-http2.txt` and `tests/requirements-client-differential.txt`, and
  driving that exact installed copy (`build/http2-tester/bin/python`) shows a server-side
  `H2Connection.initiate_connection()` emitting `setting 0x02 = 0` in its first SETTINGS
  frame (`review/evidence/h2_1_h2_server_settings.log`; the mechanism is
  `SettingCodes.ENABLE_PUSH: collections.deque([int(client)])` in `h2/settings.py:138`
  combined with `initiate_connection` serializing every entry of `local_settings`,
  `h2/connection.py:528-530`). The spike's raw peer replays that SETTINGS payload byte for
  byte; the library client answers GOAWAY and `Client.Execute` raises
  `Flyology.HTTP.Protocol_Error`. The repository already works around its own defect: both
  pinned Python peers delete the setting before `initiate_connection()` —
  `tests/http2_peer.py:124-126` ("hyper-h2 retains the obsolete RFC 7540 server-side
  ENABLE_PUSH=0 default. RFC 9113 forbids a server from sending this setting.
  `del connection.local_settings[SettingCodes.ENABLE_PUSH]`") and
  `tests/http_client_differential_peer.py:99-101` with the same comment. Both comments
  misstate RFC 9113. No maintained suite covers this: h2spec tests the server role only,
  and `tests/flyology-http-http_2_settings-smoke.adb:27-28` asserts the defect as correct.
  Every request to a python-h2-based origin (hypercorn, Twisted, the repository's own
  unpatched peers) fails permanently, which is an interop-breaking protocol violation
  against a stock, conforming peer.

## H2-2: Server enforces its reduced 16 KiB stream window before the peer can have processed the SETTINGS that announced it

- **Verdict:** CONFIRMED
- **Severity:** P0 (discovery said P0; kept, and the "curl burst not executed" caveat is
  now removed — stock curl was executed against this server)
- **Repro:** `tests/repros/src/repro_h2_2.adb`, run with `./tests/repros/run.sh repro_h2_2`
- **Output:**

```
  note H2-2: over-window DATA before the peer processed our SETTINGS
  note   <- SETTINGS stream 0 length 18
  note   <- SETTINGS stream 0 length 0
  note   <- GOAWAY stream 0 length 8
  note   GOAWAY error code 3 (0x3 is FLOW_CONTROL_ERROR, 0x1 is PROTOCOL_ERROR)
  FAIL 20480 octets of DATA sent before the peer could process the server's reduced SETTINGS is not a connection error
checks: 1  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Stock peer:** the same program run as `repro_h2_2 serve` holds one loopback HTTP/2
  server open; stock `curl 8.7.1 (libcurl/8.7.1 ... nghttp2/1.68.1)` posting a 20480-octet
  file to it is killed (`review/evidence/h2_2_curl.log`):

```
} [20480 bytes data]
* upload completely sent off: 20480 bytes
* received GOAWAY, error=3, last_stream=1
* Recv failure: Connection reset by peer
* Failed receiving HTTP2 data: 56(Failure when receiving data from the peer)
curl exit: 56
```

- **Description:** every server stream starts at
  `Receive_Window := Policy.Window_Size (Settings.Advertised_Initial_Window_Size)` =
  16384 (`src/flyology-http-server-http_2.adb:100-101`,
  `src/flyology-http-http_2_settings.ads:14-15`), and `Publish_Data` consumes against it
  from the very first DATA frame (`:633-641`). The protocol default a peer must use until
  it has processed the server's SETTINGS is 65535, so a peer that pipelines its first
  flight legitimately sends more than 16384 octets on one stream. The second frame's
  `Consume` is refused, `Accepted` stays False, the stream is not idle, and the frame
  handler escalates to `Protocol_Failure (Frames.Flow_Control_Error)` (`:2513-2521`) —
  a GOAWAY that fails every stream on the connection. RFC 9113 §6.9.3, fetched verbatim:
  "A receiver that wishes to use a smaller flow-control window than the current size can
  send a new SETTINGS frame. However, the receiver MUST be prepared to receive data that
  exceeds this window size, since the sender might send data that exceeds the lower limit
  prior to processing the SETTINGS frame." The same section allows at most a stream error:
  "The receiver MAY instead send a RST_STREAM with an error code of FLOW_CONTROL_ERROR for
  the affected streams." A connection error is not among the permitted responses. The
  server also never tracks the peer's SETTINGS ACK (`:2417-2435` ignores it), so it has no
  way to know when its reduced window became binding. h2spec 2.6.0 does not cover this: its
  6.9.1/1 sets the *peer's* initial window to 1 and checks the server's sending side, 6.9.2
  changes INITIAL_WINDOW_SIZE mid-connection, and no case sends over-window DATA before
  processing the server's SETTINGS (`review/baselines/13-http2-h2spec-docker.log:214-227`).
  The repository's own peers avoid it by construction: `tests/http2_server_peer.py:133`
  sends only `local_flow_control_window(stream_id)` octets.

## H2-3: Client discards the response body when the server follows END_STREAM with `RST_STREAM(NO_ERROR)`

- **Verdict:** PARTIALLY CONFIRMED (the response *head* survives; the buffered body is
  discarded and `Read_Body` raises)
- **Severity:** P1 (discovery said P1; kept)
- **Repro:** `tests/repros/src/repro_h2_3.adb`, run with `./tests/repros/run.sh repro_h2_3`
- **Output:**

```
  note H2-3: RST_STREAM(NO_ERROR) after a complete response
  note   client raised FLYOLOGY.HTTP.PROTOCOL_ERROR: HTTP/2 response stream failed before body completion
  note   status 413 body ""
  ok   the complete 413 response survives RST_STREAM(NO_ERROR)
  FAIL the buffered response body is delivered
         expected: [rejected]
         actual:   []
checks: 2  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** `Reset_Stream` (`src/flyology-http-http_2_client_connection.adb:1370-1387`)
  looks the stream up with `Find`, which excludes only `Free` slots, so a stream already in
  phase `Complete` (END_STREAM received, body buffered) is flipped to `Failed` with
  `Other_Stream_Failure` regardless of the error code. `Read` (`:1519-1531`) tests
  `Item.Failure /= No_Failure` *before* `Item.Response_Count > 0`, so the buffered body is
  never handed out and `Read_Body` raises
  `Flyology.HTTP.Protocol_Error with "HTTP/2 response stream failed before body
  completion"`; the composable driver maps the same result to `Response_Invalid`
  (`src/flyology-http-client.adb:7207-7223`, `:4473-4474`). RFC 9113 §8.1, fetched
  verbatim: "a server MAY request that the client abort transmission of a request without
  error by sending a RST_STREAM with an error code of NO_ERROR after sending a complete
  response (i.e., a frame with the END_STREAM flag set). Clients MUST NOT discard responses
  as a result of receiving such a RST_STREAM". The discovery entry overstates the effect
  slightly: `Client.Status` still returns 413, because the head was published before the
  reset; what is lost is the response body, which is the part a caller usually needs. The
  peer behaviour is verified, not recalled: `golang.org/x/net@v0.57.0/http2/server.go`
  (the module version in this machine's Go module cache, which
  `scripts/http2-interop.sh:77-78` builds `tests/interop/http2_go_peer.go` against) does
  exactly this when a handler finishes while the request stream is still `stateOpen`,
  with the comment "Section 8.1: a server MAY request that the client abort transmission
  of a request without error by sending a RST_STREAM with an error code of NO_ERROR after
  sending a complete response." followed by `sc.resetStream(streamError(st.id,
  ErrCodeNo))`. No maintained suite covers it: the `early-final-body` scenario
  (`tests/http2_peer.py:170-183`, `tests/http2_client_integration.adb:955-968`) sends the
  same early 413 without a reset, and `scripts/http2-interop.sh`'s Go handler reads the
  whole body so Go never resets. h2spec does not test clients.

## H2-4: Cancelling a client stream mid field section abandons the section and freezes the pump

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; kept — see the note on why I did not raise it to P0)
- **Repro:** `tests/repros/src/repro_h2_4.adb`, run with `./tests/repros/run.sh repro_h2_4 180`
- **Output** (the trace prints only the last nine frames of the capture):

```
  note H2-4: cancelling a stream mid field section
  note   -> HEADERS stream 41 length 16384 (no END_HEADERS)
  note   -> CONTINUATION stream 41 length 15559 END_HEADERS
  note   -> HEADERS stream 43 length 16384 (no END_HEADERS)
  note   -> CONTINUATION stream 43 length 15559 END_HEADERS
  note   -> HEADERS stream 45 length 16384 (no END_HEADERS)
  note   -> CONTINUATION stream 45 length 15559 END_HEADERS
  note   -> HEADERS stream 47 length 16384 (no END_HEADERS)
  note   -> CONTINUATION stream 47 length 15559 END_HEADERS
  note   -> HEADERS stream 49 length 16384 (no END_HEADERS)
  note   !! the capture ends inside the field section of stream 49: its CONTINUATION was never emitted
  note   captured 783484 octets in 50 complete frames
  FAIL a cancelled request never leaves its field section unterminated on the wire
checks: 1  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** `Cancel_Stream`
  (`src/flyology-http-http_2_client_connection.adb:1625-1649`) queues RST_STREAM and sets
  `Phase := Complete`, but leaves `Continuation_Slot` pointing at that slot. Every output
  branch of `Pull_Output` requires `Item.Phase = Open` (`:813-815`, `:751-760`), and the
  control-output branch is guarded by `Continuation_Slot = 0` (`:719-721`), so once the pin
  is set on a non-`Open` stream the pump can emit nothing at all: not the CONTINUATION that
  would terminate the field section, not the queued RST_STREAM, not a sibling's HEADERS,
  not a SETTINGS or PING ACK. The comment at `:1629-1632` ("continuation ordering ensures
  the reset follows the complete field section on the wire") is false; the server engine
  handles the same case correctly with `(Item.Phase = Open or else Index = Required)`
  (`src/flyology-http-server-http_2.adb:1031-1039`). The spike runs 30 concurrent
  exchanges whose heads are 32 KiB (a 15900-octet target plus a 16000-octet field, both
  within `Max_Request_Target_Bytes` and `Headers.Default_Max_Bytes`), against a peer that
  drains at about 100 KB/s so the pump parks on `Need_Write` while a section is in flight;
  the 3-second exchange deadlines then expire. After the cancel the spike waits 13 further
  seconds, issues one more request on the same pooled client, and lets the peer drain to
  end of stream. The capture ends on a clean frame boundary at
  `HEADERS stream 49 (no END_HEADERS)`: no CONTINUATION, no RST_STREAM for any of the 25
  cancelled streams, no head for streams 51-59, and nothing for the follow-up request.
  RFC 9113 §4.3, fetched verbatim: "Field blocks MUST be transmitted as a contiguous
  sequence of frames, with no interleaved frames of any other type or from any other
  stream"; §6.10: "If the END_HEADERS flag is not set, this frame MUST be followed by
  another CONTINUATION frame. A receiver MUST treat the receipt of any other type of frame
  or a frame on a different stream as a connection error (Section 5.4.1) of type
  PROTOCOL_ERROR." Both engines in this repository enforce that rule on receipt, so a peer
  receiving the next frame on this connection fails it. I did not raise this to P0 because
  reaching it needs write backpressure concurrent with a cancellation, which I had to
  arrange with a deliberately slow peer; the consequences once reached (a frozen shared
  connection and a connection error at the peer) are P0-shaped. No maintained suite covers
  it: `tests/http2_server_audit.adb:728-799` covers the *server's* equivalent pin, and
  `tests/flyology-http-http_2_client_connection-smoke.adb` has no `Cancel_Stream` case.

## H2-5: A body limit crossed mid-stream can never receive the 413 over HTTP/2

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; kept)
- **Repro:** `tests/repros/src/repro_h2_5.adb`, run with `./tests/repros/run.sh repro_h2_5`
- **Output:**

```
  note H2-5: a body limit crossed mid-stream must still answer 413
  note   <- SETTINGS stream 0 length 18
  note   <- SETTINGS stream 0 length 0
  note   <- WINDOW_UPDATE stream 0 length 4
  note   <- WINDOW_UPDATE stream 1 length 4
  note   <- RST_STREAM stream 1 length 4
  note   the server reset the stream with error code 2 (2 is INTERNAL_ERROR)
  FAIL HTTP/2 answers an over-limit body with a response head, not a reset
  note   HTTP/1.1 control status line: HTTP/1.1 413 Content Too Large
  ok   HTTP/1.1 delivers the 413 for the same route and body
checks: 2  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** The spike registers one route, `POST /upload` with
  `Body_Handling => Buffer_Body` and `Max_Body => 4096`, and serves it through the same
  `Routing.Router` twice: once with `Mode => HTTP_2_Only` and once with
  `Mode => HTTP_1_Only`. The peer sends no `content-length` (so the limit can only be
  discovered mid-stream, past `Narrow_Body_Limit` at
  `src/flyology-http-server-routing.adb:2030`) and then two 4096-octet DATA frames. The
  second crosses the limit, so `Publish_Data` sets
  `Streams (Index).Failure := Body_Limit_Failure` (`src/flyology-http-server-http_2.adb:644-651`).
  `Read_Body` then reports `Read_Body_Too_Large`, the backend raises `Payload_Too_Large`
  (`:1535-1536`), and routing's handler calls `X.Problem (413, "body-too-large", ...)`
  (`routing.adb:2091-2096`). That response can never be queued, because
  `Queue_Response_Head` refuses any stream with `Failure /= No_Failure` (`:839-846`), which
  `Queue_Head` turns into `Flyology.IO.Device_Error` (`:1645-1649`); the handler task's
  `when others` retries with `X.Problem (500, ...)`, which fails identically, and falls
  through to `X.Mark_Failed` (`:2123-2135`). The client sees only
  `RST_STREAM(stream 1, INTERNAL_ERROR)` — error code 2 in the trace — where the identical
  router over HTTP/1.1 answers `HTTP/1.1 413 Content Too Large`. `Discarding := True` on the
  same line shows the intent was to keep draining while a 413 is sent. No maintained suite
  covers the case (nothing in `tests/http2_server_audit.adb`,
  `tests/http2_server_integration.adb` or `tests/http2_server_peer.py` exercises a route
  body limit over HTTP/2), and h2spec does not run application routes.

## H2-6: HPACK encoder never emits the dynamic-table size update after a peer lowers `SETTINGS_HEADER_TABLE_SIZE`

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; kept. Discovery's confidence was "medium" because the
  peer-decoder behaviour was recalled; it is now settled against the pinned decoder.)
- **Repro:** `tests/repros/src/flyology-http-http_2_requests-repro_h2_6.adb`, run with
  `./tests/repros/run.sh flyology-http-http_2_requests-repro_h2_6`
- **Output:**

```
  note H2-6: dynamic table size update after a lowered HEADER_TABLE_SIZE
  ok   the reduction is accepted
  ok   the peer's HEADER_TABLE_SIZE is recorded as 0
  note   first field section begins 82 86 01 09 6c 6f 63 61
  FAIL the first field section after the reduction begins with a dynamic table size update (2#001xxxxx#)
  FAIL the signalled maximum is 0, at or below the peer's limit
  note   encoded field section written to tests/repros/obj/repro_h2_6_block.bin
checks: 4  failures: 2
BUG REPRODUCED
EXIT=1
```

- **Pinned peer:** the emitted block fed to the pinned `hpack 4.2.0` decoder that
  `h2==4.3.0` uses, with `max_allowed_table_size = 0` exactly as
  `h2/connection.py:2004` sets it on settings acknowledgement
  (`review/evidence/h2_6_hpack_decoder.log`):

```
block: 82 86 01 09 6c 6f 63 61 6c 68 6f 73 74 84
RESULT: InvalidTableSizeError: Encoder did not shrink table size to within the max
with 0x20 prefix: [(':method', 'GET'), (':scheme', 'http'), (':authority', 'localhost'), (':path', '/')]
RESULT: accepted
```

- **Description:** `Settings.Apply` stores `Item.Header_Table_Size := Value`
  (`src/flyology-http-http_2_settings.adb:43-44`) and `rg -n Header_Table_Size src/` shows
  no other consumer in the tree; neither `HTTP_2_HPACK`'s builder nor
  `HTTP_2_Requests.Encode_Head` / `HTTP_2_Responses.Encode_Head` has a size-update
  representation, so the encoder's declared maximum stays at the protocol default 4096
  forever. RFC 7541 §4.2, fetched verbatim: "A change in the maximum size of the dynamic
  table is signaled via a dynamic table size update (see Section 6.3). This dynamic table
  size update MUST occur at the beginning of the first header block following the change to
  the dynamic table size. In HTTP/2, this follows a settings acknowledgment"; §6.3: "A
  dynamic table size update starts with the '001' 3-bit pattern". Both engines do
  acknowledge the peer's SETTINGS (`Queue_Settings_Ack`), so the obligation is live. The
  consequence is not theoretical: the pinned decoder's `_assert_valid_table_size`
  (`hpack/hpack.py:561-568`, called from `decode` at `:554`) raises `InvalidTableSizeError`
  on the very bytes this crate emits, which h2 reports as a COMPRESSION_ERROR connection
  error, and accepts the same bytes once the required `0x20` update is prefixed. The
  defect is symmetric: the server stores the client's `HEADER_TABLE_SIZE` and ignores it
  the same way. It needs a peer configured to lower the setting (Envoy `hpack_table_size`,
  HAProxy `tune.h2.header-table-size`, nghttpx, or any h2 application calling
  `update_settings({HEADER_TABLE_SIZE: 0})`); the stock defaults are 4096, which is why it
  has not been seen. h2spec's HPACK 4.2 and 6.3 cases test the *decoder* side only
  (`review/baselines/13-http2-h2spec-docker.log`, "Sends a dynamic table size update at the
  end of header block", "Sends a dynamic table size update larger than the value of
  SETTINGS_HEADER_TABLE_SIZE").

## H2-7: `SETTINGS_INITIAL_WINDOW_SIZE` above 2^31-1 is reported as PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR

- **Verdict:** CONFIRMED (in both engines)
- **Severity:** P2 (discovery said P2; kept)
- **Repro:** `tests/repros/src/repro_h2_7.adb`, run with `./tests/repros/run.sh repro_h2_7`
- **Output:**

```
  note H2-7: SETTINGS_INITIAL_WINDOW_SIZE above 2^31-1
  note   server GOAWAY error code 1
  FAIL the server answers an oversized INITIAL_WINDOW_SIZE with FLOW_CONTROL_ERROR (0x3)
         expected: 3   actual: 1
  note   client GOAWAY error code 1
  FAIL the client answers an oversized INITIAL_WINDOW_SIZE with FLOW_CONTROL_ERROR (0x3)
         expected: 3   actual: 1
checks: 2  failures: 2
BUG REPRODUCED
EXIT=1
```

- **Description:** `HTTP_2_Settings.Apply` distinguishes the case correctly and returns
  `Settings_Flow_Control_Error` (`src/flyology-http-http_2_settings.adb:54-58`), but both
  frame handlers collapse every non-accepted result into `Protocol_Failure` with its
  default `Frames.Protocol_Error_Code` (`src/flyology-http-server-http_2.adb:2422-2427`,
  `src/flyology-http-http_2_client_connection.adb:1831-1835`); the adjacent
  `Apply_Peer_Settings` overflow path does pass `Frames.Flow_Control_Error`. RFC 9113
  §6.5.2, fetched verbatim: "Values above the maximum flow-control window size of 2^31-1
  MUST be treated as a connection error (Section 5.4.1) of type FLOW_CONTROL_ERROR."
  The discovery's aside about the h2spec baseline is correct and I verified it in h2spec
  2.6.0's own source: `spec/verifier.go:53-92` `VerifyConnectionError` sets `passed = true`
  on a `ConnectionClosedEvent` before it ever compares the GOAWAY code, so the
  "146 tests, 146 passed" baseline does not vouch for any GOAWAY error code, including
  6.5.2/2's. Diagnostic impact only: a conforming peer closes either way.

## H2-8: Server answers `WINDOW_UPDATE(0)` on an idle stream with RST_STREAM on that idle stream and advances `Last_Client_Stream`

- **Verdict:** CONFIRMED (all three predicted symptoms)
- **Severity:** P2 (discovery said P2; kept)
- **Repro:** `tests/repros/src/repro_h2_8.adb`, run with `./tests/repros/run.sh repro_h2_8`
- **Output:**

```
  note H2-8: WINDOW_UPDATE with increment 0 on an idle stream
  note   <- SETTINGS stream 0 length 18
  note   <- SETTINGS stream 0 length 0
  note   <- RST_STREAM stream 5 length 4
  note   <- PING stream 0 length 8
  note   the server sent RST_STREAM on the idle stream 5
  note   the server answered the PING, so the connection survived
  FAIL a zero-increment WINDOW_UPDATE on an idle stream is a connection error
  FAIL the server never sends RST_STREAM for a stream in the idle state
  note   <- GOAWAY stream 0 length 8
  FAIL a legitimate request on stream 3 is still served afterwards
checks: 3  failures: 3
BUG REPRODUCED
EXIT=1
```

- **Description:** `Window_Update` sets `Accepted := Increment > 0` and
  `Stream_Failure := Stream_ID /= 0` and returns before any idle check
  (`src/flyology-http-server-http_2.adb:1217-1221`); the frame handler then calls
  `Reject_Stream` (`:2533-2541`), which for an odd stream with no slot advances
  `Last_Client_Stream`, records the stream as seen and reset, queues
  `RST_STREAM(5, PROTOCOL_ERROR)` and returns `Accepted = True` (`:1277-1286`), so the
  outer `if not Accepted then Protocol_Failure` never fires. The PING ACK in the trace is
  the proof that the connection survived. RFC 9113 §5.1, idle: "Receiving any frame other
  than HEADERS or PRIORITY on a stream in this state MUST be treated as a connection error
  (Section 5.4.1) of type PROTOCOL_ERROR"; §6.4: "RST_STREAM frames MUST NOT be sent for a
  stream in the 'idle' state." The third failure is the knock-on the discovery predicted:
  with `Last_Client_Stream` now 5, the later legitimate `HEADERS` on stream 3 is refused as
  a lower identifier and the connection is failed with GOAWAY. h2spec 2.6.0 covers neither
  combination — I read its source: 5.1/3 sends `conn.WriteWindowUpdate(1, 100)`
  (`http2/5_1_stream_states.go:55-66`) and 6.9/2 opens stream 1 with HEADERS before sending
  the zero increment (`http2/6_9_window_update.go:39-62`), so the stream is not idle. The
  repository's own audit uses `U32 (100)` at `tests/http2_server_audit.adb:838`, as the
  discovery entry says. Self-inflicted only: a conforming peer never sends a zero
  increment, so this poisons only the offending peer's own connection.

## H2-9: Server sends RST_STREAM(STREAM_CLOSED) for every DATA frame on a stream it already reset

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; kept)
- **Repro:** `tests/repros/src/repro_h2_9.adb`, run with `./tests/repros/run.sh repro_h2_9`
- **Output:**

```
  note H2-9: DATA on a stream the server itself reset
  note   <- SETTINGS stream 0 length 18
  note   <- SETTINGS stream 0 length 0
  note   <- RST_STREAM stream 1 length 4
  ok   the server resets the overrun stream (precondition)
  note   sent three DATA frames on the closed stream 1
  note   <- RST_STREAM stream 1 length 4
  note   <- RST_STREAM stream 1 length 4
  note   <- RST_STREAM stream 1 length 4
  note   (no further frames)
  note   extra RST_STREAM frames: 3, WINDOW_UPDATE frames: 0
  FAIL no further RST_STREAM is sent on the closed stream
checks: 2  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** the handler overruns a fixed-length response, so the engine resets
  stream 1 itself; `Reset_Failure` paths set `Remote_End := True`
  (`src/flyology-http-server-http_2.adb:912`, `:1254`, `:1295`), so the three in-flight
  DATA frames take the `Streams (Index).Remote_End` branch of `Publish_Data` (`:618-631`)
  and each draws another RST_STREAM. RFC 9113 §5.1, closed: "An endpoint MUST NOT send
  frames other than PRIORITY on a closed stream", and for a stream the endpoint reset
  itself: "An endpoint MUST minimally process and then discard any frames it receives in
  this state." The half-closed (remote) case the branch was written for — "it MUST respond
  with a stream error (Section 5.4.2) of type STREAM_CLOSED" — is the only one it matches.
  The discovery's amplification assessment is right: three 109-octet DATA frames produced
  three 13-octet RST_STREAM frames, a ratio well under 1, and no WINDOW_UPDATE appeared
  because 300 octets is below `Window_Update_Threshold` (8 KiB). h2spec's 5.1/8 sends DATA
  after the *client's* RST_STREAM, not the server's, so it does not cover this;
  `tests/http2_server_audit.adb:603-646` asserts only the connection-window credit and
  tolerates the resets.

## H2-10: Server never resets a stream whose response completed while the request half is open; its un-credited input pins the connection window

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; kept)
- **Repro:** `tests/repros/src/repro_h2_10.adb`, run with `./tests/repros/run.sh repro_h2_10`
- **Output:**

```
  note H2-10: un-credited input on early-answered streams
  note   sent 64000 octets across 4 streams, against a 65535-octet connection window
  note   (no further frames)
  note   responses: 4  resets: 0  connection credit returned: 0 octets
  ok   every stream receives its early response (precondition)
  FAIL the connection receive window is recovered for body octets no handler will ever read
checks: 2  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** the handler answers 401 without reading the body, as an authentication
  middleware or a `Reject_Body` route does. Each of the four streams sends HEADERS without
  END_STREAM (which RFC 9113 §8.1 permits while the server answers early) followed by
  16000 octets of DATA. `Publish_Data` charges those octets to both windows and buffers
  them; `Return_Stream_Credit` and `Return_Connection_Credit` only run as bytes leave the
  buffer, and no handler ever reads them. `Maybe_Complete` requires `Remote_End`
  (`src/flyology-http-server-http_2.adb:419-428`), which never becomes True, and the
  handler task does no drain or reset after `Handle` returns (`:2112-2139`), so the streams
  stay `Open`, hold their slots against the 32-stream limit, and hold 64000 of the
  65535-octet connection receive window for the connection's whole life
  (`Max_Connection_Age`, 300 s by default). The spike observed four responses, **zero**
  RST_STREAM frames and **zero** octets of connection credit; a peer is left with 1535
  octets of connection window and no event that can ever replenish it, so every later
  upload on that connection stalls. This is not a conformance violation — RFC 9113 §8.1
  makes the server's RST_STREAM(NO_ERROR) a MAY — which is why it stays P2; it is the same
  behaviour Go's server implements deliberately (the behaviour that trips H2-3 on this
  repository's client side). No maintained suite covers it: `tests/http2_peer.py`'s
  `early-final` scenarios drive the Flyology *client*, and the server audit has no
  early-response-with-open-request case.

## H2-11: Client ignores RST_STREAM and WINDOW_UPDATE on idle streams; post-cancel frames

- **Verdict:** PARTIALLY CONFIRMED — part (a) reproduced; part (b) is a real code path but
  I could not reach it from the synchronous API and did not reproduce it
- **Severity:** P2 (discovery said P2; kept)
- **Repro:** `tests/repros/src/repro_h2_11.adb`, run with `./tests/repros/run.sh repro_h2_11`
- **Output:**

```
  note H2-11: client stream-state handling for idle and closed streams
  note   the exchange returned status 200
  FAIL RST_STREAM and WINDOW_UPDATE on idle streams fail the connection
  note   RST_STREAM frames the client sent for the cancelled stream after its own CANCEL: 0
  ok   the client sends no further frame on a stream it already cancelled
checks: 2  failures: 1
BUG REPRODUCED
EXIT=1
```

- **Description:** (a) The peer sends `RST_STREAM(stream 7, CANCEL)` and
  `WINDOW_UPDATE(stream 9, 100)` in its first flight, before the client has opened either
  stream, then answers the client's request normally. Both engines' handlers reach
  `Reset_Stream` / `Window_Update`, whose first action is `Find (Stream_ID)`; `Find`
  returns 0 for an unknown stream and both procedures return silently
  (`src/flyology-http-http_2_client_connection.adb:1374-1378`, `:1344-1346`). The exchange
  completes with status 200. RFC 9113 §6.4, fetched verbatim: "RST_STREAM frames MUST NOT
  be sent for a stream in the 'idle' state. If a RST_STREAM frame identifying an idle
  stream is received, the recipient MUST treat this as a connection error (Section 5.4.1)
  of type PROTOCOL_ERROR"; §5.1 idle extends the same rule to WINDOW_UPDATE. This is
  leniency rather than harm on its own — the asymmetry is that `Publish_Headers` *does*
  return `Publish_Connection_Rejected` for an unknown, never-closed stream
  (`:1106-1112`), so HEADERS on an idle stream is handled correctly and the other two
  frame types are not.
  (b) `Cancel_Stream` leaves the stream `Complete` with `Remote_End` set rather than
  `Free`, so while the owner has not yet called `Release_Stream`, `Find` still resolves it
  and `Publish_Headers`/`Publish_Data` take the `Remote_End` branch into `Reject_Stream`,
  which sends a second RST_STREAM with PROTOCOL_ERROR and marks the stream
  `Response_Protocol_Failure` (`:1115-1118`, `:1229-1241`, `:1066-1081`; `Reject_Stream`
  returns early only for `Free | Failed`, not `Complete`). The window is real, but the
  synchronous `Execute` path releases the slot immediately after cancelling
  (`src/flyology-http-client.adb:741-756`), so by the time my peer's late HEADERS arrived
  `Find` returned 0 and the frames were ignored — the spike observed zero extra
  RST_STREAM frames. Reaching (b) needs the composable driver's deferred release
  (`client.adb:1066-1070`, which waits for the pump before releasing) with the late frame
  landing inside that window; I did not find a deterministic way to place it. Part (b) is
  therefore reported as code-path-confirmed but not reproduced, and it should not carry
  the finding's severity.
