# Discovery: H2

Scope (all under `src/`, read in full):
`flyology-http-server-http_2.adb` (2799), `.ads` (43);
`flyology-http-http_2_client_connection.adb` (2384), `.ads` (193);
`flyology-http-http_2_frames.adb` (93), `.ads` (84);
`flyology-http-http_2_hpack.adb` (807), `.ads` (78);
`flyology-http-http_2_huffman.adb` (180), `.ads` (12);
`flyology-http-http_2_payloads.adb` (101), `.ads` (47);
`flyology-http-http_2_settings.adb` (138), `.ads` (49);
`flyology-http-http_2_policy.adb` (110), `.ads` (111);
`flyology-http-http_2_requests.adb` (74), `.ads` (22);
`flyology-http-http_2_responses.adb` (59), `.ads` (14).
Read for call-site tracing: the HTTP/2 paths of `src/flyology-http-client.adb`,
`src/flyology-http-server-routing.adb` and `src/flyology-http-server-applications.adb`.
Tests read: `tests/http2_server_audit.adb`, `tests/http2_peer.py`,
`tests/http2_server_peer.py`, `tests/http_client_differential_peer.py`, the HTTP/2
settings, HPACK, frames, Huffman and client-connection smoke tests, and
`tests/http2-conformance.md`. Also `review/prior-audit.md` findings 3, 4, 7, 8, 9,
14, 15, 16, 31, 33 with the appendices, and `proof/proof-status.md` (the proved
`HTTP_2_Policy` unit covers the window arithmetic, stream transitions and retry
classification consumed here; it does not cover the pumps that call it). RFC 9113
was fetched from rfc-editor.org and is quoted verbatim where cited; RFC 7541 is cited
from memory. Nothing was built or executed.
Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| H2-1 | Client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0`, which RFC 9113 §6.5.2 permits and python-h2 servers send by default; the repository's own test peers are patched around it | P0 | high |
| H2-2 | Server enforces its reduced 16 KiB stream window from the first frame, before the peer can have processed the SETTINGS announcing it; a >16 KiB upload burst is answered with GOAWAY FLOW_CONTROL_ERROR (RFC 9113 §6.9.3) | P0 | high (code) / medium (curl burst not executed) |
| H2-3 | Client discards a complete response when the server follows END_STREAM with `RST_STREAM(NO_ERROR)`, which RFC 9113 §8.1 forbids and Go `net/http` servers do | P1 | high (code) / medium (peer behaviour recalled) |
| H2-4 | Client `Cancel_Stream` during a fragmented request field section pins the pump, then a non-CONTINUATION frame follows the unterminated HEADERS and the peer fails the whole connection | P1 | medium-high |
| H2-5 | A request body exceeding a route limit mid-stream can never receive the 413 over HTTP/2; the handler's 413 and fallback 500 both fail and the stream is reset with INTERNAL_ERROR | P1 | high |
| H2-6 | HPACK encoder never emits the dynamic-table size update RFC 7541 §4.2 requires after a peer lowers `SETTINGS_HEADER_TABLE_SIZE` | P1 | medium |
| H2-7 | `SETTINGS_INITIAL_WINDOW_SIZE` above 2^31-1 is reported as PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR in both engines | P2 | high |
| H2-8 | Server answers `WINDOW_UPDATE(0)` on an idle stream with RST_STREAM on that idle stream and advances `Last_Client_Stream` | P2 | high |
| H2-9 | Server sends RST_STREAM(STREAM_CLOSED) for every DATA frame on a closed stream, including streams it already reset | P2 | high |
| H2-10 | Server never resets a stream whose response completed while the request half is open; un-credited input from four such streams pins the connection window | P2 | medium |
| H2-11 | Client ignores RST_STREAM/WINDOW_UPDATE on idle streams and answers post-cancel in-flight frames with RST_STREAM(PROTOCOL_ERROR) | P2 | high |

No prior-audit finding in this area has regressed at f078732; each was re-checked
and is listed under "Areas reviewed with no findings".

## Findings

### H2-1: Client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0`

- **Location:** `src/flyology-http-http_2_settings.adb:45-51` (consumed at
  `src/flyology-http-http_2_client_connection.adb:1831-1835` with the default
  `Peer_Is_Server => True`)
- **Severity:** P0
- **Confidence:** high
- **Evidence:**

```ada
               when Enable_Push_Id =>
                  if Peer_Is_Server or else Value > 1 then
                     --  RFC 9113 prohibits SETTINGS_ENABLE_PUSH from a server.
                     Result := Settings_Protocol_Error;
                     return;
                  end if;
```

```ada
                  Settings.Apply
                    (State.Driver.Peer_Settings, Payload, Applied);
                  if Applied /= Settings.Settings_Accepted then
                     Protocol_Failure;
                  end if;
```

  `Protocol_Failure` (`client_connection.adb:1752-1761`) queues GOAWAY, calls
  `Fail_All`, and sets `Closing`; every stream on the session becomes
  `Connection_Failure` and is surfaced as `Head_Protocol_Failed`.

- **Failure scenario:**
  1. The client opens a connection to a server built on python-hyper/h2 (hypercorn,
     Twisted, the repository's own test peers). h2's `Settings.__init__` seeds
     `ENABLE_PUSH` with `int(client)`, so a server-side `H2Connection` sends
     `SETTINGS_ENABLE_PUSH = 0` in its first SETTINGS frame.
  2. `Settings.Apply` sees identifier 2 with `Peer_Is_Server = True` and returns
     `Settings_Protocol_Error` regardless of the value.
  3. The client sends GOAWAY(PROTOCOL_ERROR) and fails every stream. No request to
     that origin can ever succeed.
- **Reproduction test sketch:** `Settings.Apply (Item, (0, 2, 0, 0, 0, 0), Result)`
  with the default `Peer_Is_Server`; expected `Settings_Accepted` with
  `Item.Enable_Push = False`; actual `Settings_Protocol_Error`. At the engine level,
  feed the owner pump a server preface of `00 00 06 04 00 00 00 00 00  00 02 00 00 00 00`;
  expected a SETTINGS ACK, actual GOAWAY.
- **Existing coverage:** `tests/flyology-http-http_2_settings-smoke.adb:27-28` asserts
  the wrong behaviour as correct. `tests/http2_peer.py:124-126` and
  `tests/http_client_differential_peer.py:99-101` delete `ENABLE_PUSH` from the h2
  server's local settings before `initiate_connection()`, with the comment "RFC 9113
  forbids a server from sending this setting", so both integration peers are modified
  to avoid the defect rather than cover it. Introduced with the HTTP/2 client in
  `33b5705`.
- **Standard:** RFC 9113 §6.5.2, quoted from the fetched text: "A server MUST NOT
  explicitly set this value to 1. A server MAY choose to omit this setting when it
  sends a SETTINGS frame, but if a server does include a value, it MUST be 0. A client
  MUST treat receipt of a SETTINGS frame with SETTINGS_ENABLE_PUSH set to 1 as a
  connection error (Section 5.4.1) of type PROTOCOL_ERROR." Only the value 1 is an
  error; the source comment at `settings.adb:47` and the two test comments misstate
  the RFC.

### H2-2: Server enforces its reduced 16 KiB stream window before the peer can have processed the SETTINGS that announced it

- **Location:** `src/flyology-http-server-http_2.adb:100-101` (initial
  `Receive_Window`), `:1373-1374` (reset on slot reuse), `:633-641` (consume),
  `:2513-2521` (escalation to FLOW_CONTROL_ERROR), `:2417-2435` (SETTINGS ACK
  from the peer is ignored, so the server never learns when its settings took effect)
- **Severity:** P0
- **Confidence:** high on the code path; medium that curl's first write burst
  exceeds 16 KiB before it reads (recalled nghttp2 behaviour, not executed here)
- **Evidence:**

```ada
      Receive_Window : Policy.Window_Size :=
        Policy.Window_Size (Settings.Advertised_Initial_Window_Size);
```

```ada
         Stream_Result := Policy.Consume
           (Streams (Index).Receive_Window,
            Policy.Data_Length (Flow_Length));
         if not Connection_Result.Accepted or else not Stream_Result.Accepted
         then
            return;
         end if;
```

```ada
               if not Accepted then
                  --  RFC 9113 5.1: a frame other than HEADERS or PRIORITY on
                  --  an idle stream is a connection PROTOCOL_ERROR. Only a
                  --  genuinely exhausted window is FLOW_CONTROL_ERROR.
                  Protocol_Failure
                    ((if State.Streams.Is_Idle (Header.Stream_ID)
                      then Frames.Protocol_Error_Code
                      else Frames.Flow_Control_Error));
```

  `Settings.Advertised_Initial_Window_Size` is 16 384
  (`http_2_settings.ads:14-15`); the protocol default the peer must use until it
  processes the server's SETTINGS is 65 535. The connection window
  (`Connection_Receive_Window := 65_535`) is not affected.

- **Failure scenario:**
  1. A client connects (TLS/ALPN or prior knowledge). The server's first output is
     SETTINGS(INITIAL_WINDOW_SIZE = 16384) (`Pull_Output`, `:989-1011`).
  2. `curl --data-binary @20k.bin` (or any client) writes its preface, SETTINGS,
     HEADERS and DATA frames in one burst; per RFC 9113 §6.9.2 it must use the
     default 65 535 stream window until it has processed the server's SETTINGS, so it
     legitimately emits DATA(16384) followed by DATA(4096).
  3. `Publish_Data` for the second frame calls `Consume (0, 4096)`; not accepted;
     `Accepted` stays False; the stream is not idle, so `Protocol_Failure
     (Flow_Control_Error)`: GOAWAY, every stream on the connection failed.
  4. The same race exists between the Flyology client and the Flyology server: the
     client's `Send_Window` is the default 65 535 until `Apply_Peer_Settings` runs
     (`client_connection.adb:598-599`, `:1001-1025`), and it emits DATA frames
     one per pump step. The loopback tests win the race because the server's
     SETTINGS is written before the client reaches its second DATA frame; any
     real latency loses it.
- **Reproduction test sketch:** raw peer as in `tests/http2_server_audit.adb`
  (`Connect_Peer` sends the preface and an empty SETTINGS) but do not read the
  server's SETTINGS; send HEADERS(stream 1, `content-length: 20480`, END_HEADERS),
  DATA(16384), DATA(4096, END_STREAM). Expected: request served, or at minimum the
  bytes accepted and credited. Actual: GOAWAY(FLOW_CONTROL_ERROR). Alternatively run
  the 20 KiB upload of `http2_server_integration.adb` through
  `tests/http2_fault_proxy.py` with the server-to-client direction delayed.
- **Existing coverage:** `tests/http2_server_peer.py:133` sends only
  `local_flow_control_window(stream_id)` bytes after `receive_data`, so it never
  exceeds the acknowledged window; the audit's flow-control cases
  (`http2_server_audit.adb:603-717`) stay at or below 16 000 bytes; the 20 KiB
  upload in `http2_server_integration.adb` uses the Flyology client on loopback.
  None sends more than 16 384 bytes on a stream before consuming the server's
  SETTINGS.
- **Standard:** RFC 9113 §6.9.3 (quoted from the fetched text): "A receiver that
  wishes to use a smaller flow-control window than the current size can send a new
  SETTINGS frame. However, the receiver MUST be prepared to receive data that exceeds
  this window size, since the sender might send data that exceeds the lower limit
  prior to processing the SETTINGS frame." nghttp2 satisfies this by keeping its
  local window at 65 535 until the SETTINGS ACK arrives; this server never tracks the
  ACK. Prior audit finding 8 (slot reuse) and finding 7 (closed-stream charge) are
  intact; this is a different rule.

### H2-3: Client discards a complete response when the server follows END_STREAM with `RST_STREAM(NO_ERROR)`

- **Location:** `src/flyology-http-http_2_client_connection.adb:1370-1387`
  (`Reset_Stream`), `:1519-1531` (`Read` checks `Failure` before buffered data);
  consumed at `src/flyology-http-client.adb:7207-7223` (synchronous `Read_Body`
  raises `Protocol_Error`) and `:4473-4474` (composable `Fail_Exchange
  (Response_Invalid)`)
- **Severity:** P1
- **Confidence:** high on the code path; Go `net/http` server behaviour is recalled
  from `x/net/http2/server.go` (it sends `RST_STREAM(NO_ERROR)` when the handler
  completes while the request stream is still open), not executed here
- **Evidence:**

```ada
      procedure Reset_Stream
        (Stream_ID : Frames.Stream_Identifier;
         Error     : Frames.Error_Code)
      is
         Index : constant Natural := Find (Stream_ID);
      begin
         if Index = 0 then
            return;
         end if;
         Streams (Index).Response_Observed := True;
         Streams (Index).Failure :=
           (if Error = Frames.Refused_Stream
              and then not Streams (Index).Head_Available
            then Refused_Failure
            else Other_Stream_Failure);
         Streams (Index).Phase := Failed;
```

```ada
            if Item.Failure = Connection_Failure then
               Result := Body_Connection_Failed;
               return;
            elsif Item.Failure = Response_Protocol_Failure then
               Result := Body_Protocol_Failed;
               return;
            elsif Item.Failure /= No_Failure then
               Result := Body_Stream_Failed;
               return;
            elsif Item.Response_Count > 0 then
```

  `Find` returns a stream in phase `Complete` (only `Free` is excluded), so a
  stream whose response already ended with END_STREAM is flipped to `Failed`
  regardless of the error code or of `Remote_End`.

- **Failure scenario:**
  1. The client sends a request with a body (retained 64 KiB, or a streamed upload)
     to a Go HTTP/2 server whose handler responds without reading the body
     (authentication failure, 413, or an endpoint that ignores the body).
  2. Go writes HEADERS, DATA(END_STREAM) and RST_STREAM(NO_ERROR) back to back.
  3. `Publish_Data` with `End_Stream` sets `Phase := Complete`. The synchronous
     `Drive_HTTP_2_Until_Ready` deliberately keeps parsing the burst after the stream
     is ready (`client.adb:7003-7008`, "Keep draining the already-readable transport
     burst"), so `Reset_Stream` runs before the owner reads: `Phase := Failed`,
     `Failure := Other_Stream_Failure`.
  4. `Read` returns `Body_Stream_Failed` without delivering the buffered bytes;
     `Read_Body` raises `Protocol_Error with "HTTP/2 response stream failed before
     body completion"`. The composable driver maps the same result to
     `Response_Invalid`. The complete, valid response is discarded.
- **Reproduction test sketch:** extend the `early-final-body` scenario in
  `tests/http2_peer.py:170-183` with `connection.reset_stream (event.stream_id,
  ErrorCodes.NO_ERROR)` immediately after `send_data (..., end_stream=True)`.
  Expected: status 413 with body `rejected`. Actual: `Protocol_Error` from
  `Read_Body`; composable result `Response_Invalid`.
- **Existing coverage:** `tests/http2_peer.py` `early-final`/`early-final-body`
  send the early response without a reset (python-h2 never sends one on its own);
  `scripts/http2-interop.sh`'s Go echo handler reads the whole body, so Go never
  resets; `tests/flyology-http-http_2_client_connection-smoke.adb` has no
  RST_STREAM case. None.
- **Standard:** RFC 9113 §8.1: "a server MAY request that the client abort
  transmission of a request without error by sending a RST_STREAM with an error code
  of NO_ERROR after sending a complete response (i.e., a frame with the END_STREAM
  flag set). Clients MUST NOT discard responses as a result of receiving such a
  RST_STREAM".

### H2-4: Client `Cancel_Stream` during a fragmented request field section pins the pump, then a non-CONTINUATION frame follows an unterminated HEADERS

- **Location:** `src/flyology-http-http_2_client_connection.adb:1625-1649`
  (`Cancel_Stream`), `:679` and `:751-760` (`Pull_Output` honours
  `Continuation_Slot` by trying only that slot), `:813-815` (the header branch
  requires `Item.Phase = Open`), `:504-509` (`Clear_Stream` is the only place
  that clears the pin on this path). Callers: `src/flyology-http-client.adb:1066-1070`
  (composable cancel, waits for the pump before releasing), `:741-756`
  (synchronous cleanup, releases immediately).
- **Severity:** P1
- **Confidence:** medium-high. The code path is certain; reaching it needs a
  request head over 16 384 bytes (targets up to 16 KiB are a supported feature,
  CHANGELOG 0.1.1) and a cancellation or deadline expiry between the two fragments,
  which a slow peer or a `Need_Write` transport makes ordinary.
- **Evidence:**

```ada
            --  A stream whose request field section has not entered the pump
            --  is still idle at the peer. Sending RST_STREAM for that stream
            --  would itself be a connection-level protocol error. Once any
            --  header bytes have been pulled, continuation ordering ensures
            --  the reset follows the complete field section on the wire.
            if Streams (Handle.Slot).Head_Cursor > 1 then
               Queue_Control_Frame
                 (Frames.Reset_Stream_Frame, 0,
                  Streams (Handle.Slot).ID,
                  U31_Payload (Natural (Frames.Cancel)));
               Wake_Pump := True;
            end if;
            Streams (Handle.Slot).Remote_End := True;
            Streams (Handle.Slot).Phase := Complete;
```

```ada
               elsif Item.Phase = Open
                 and then Item.Head_Cursor <= Bytes.Length (Item.Request_Head)
               then
```

  The comment's claim ("continuation ordering ensures the reset follows the complete
  field section") is false: every emitting branch of `Pull_Output` requires
  `Phase = Open`, and `Cancel_Stream` sets `Complete`. The server engine handles
  exactly this case (`server-http_2.adb:1031-1039`, `(Item.Phase = Open or else
  Index = Required)`); the client does not.

- **Failure scenario:**
  1. A request with a 20 KiB head is opened. `Pull_Output` emits
     HEADERS(16384 bytes, no END_HEADERS) and sets `Continuation_Slot := Index`.
  2. Before the CONTINUATION is pulled (the socket returned `Need_Write`, or the pump
     was handed to a sibling), the exchange is cancelled or its deadline expires:
     `Cancel_Stream` queues RST_STREAM(CANCEL) and sets `Phase := Complete`; the pin
     stays.
  3. Every subsequent `Pull_Output`: `Continuation_Slot /= 0` skips control output;
     `Required_Header_Slot` is the pinned slot; no branch fires. Nothing leaves the
     connection: no SETTINGS ACK, PING ACK, WINDOW_UPDATE, RST_STREAM, and no
     sibling's frames.
  4. The composable driver observes `Outbound_Pending = False` and calls
     `Finish_Cancellation` → `Release_Stream` → `Clear_Stream`, which clears the pin
     (the synchronous path releases at once). The next `Pull_Output` emits the queued
     RST_STREAM or a sibling's HEADERS.
  5. The peer has received HEADERS without END_HEADERS on stream N followed by a
     different frame: a connection error PROTOCOL_ERROR under RFC 9113 §6.2, so the
     peer sends GOAWAY and every multiplexed exchange on the session fails. If the
     owner never releases, the freeze in step 3 lasts until the connection deadline.
- **Reproduction test sketch:** with the session object alone: `Open` with a
  20 000-byte header block; call `Pull_Output` once (HEADERS, no END_HEADERS);
  `Cancel_Stream`; call `Pull_Output`. Expected: CONTINUATION(END_HEADERS) then
  RST_STREAM(CANCEL). Actual: `Available = False`; after `Release_Stream`, the next
  `Pull_Output` yields RST_STREAM with no CONTINUATION ever emitted.
- **Existing coverage:** `tests/http2_server_audit.adb:728-799` covers the server's
  pin ("finding 14"); the conformance document lists "concurrent request field
  sections that require CONTINUATION frames" without cancellation;
  `tests/flyology-http-http_2_client_connection-smoke.adb` has no `Cancel_Stream`
  case. None.
- **Standard:** RFC 9113 §4.3 (quoted from the fetched text): "Field blocks MUST
  be transmitted as a contiguous sequence of frames, with no interleaved frames of
  any other type or from any other stream"; §6.10: "A CONTINUATION frame MUST be
  preceded by a HEADERS, PUSH_PROMISE or CONTINUATION frame without the END_HEADERS
  flag set. A recipient that observes violation of this rule MUST respond with a
  connection error (Section 5.4.1) of type PROTOCOL_ERROR." The peer's rejection of
  step 5 follows from the first rule; both engines in this repository enforce it on
  receipt (`server-http_2.adb:2412-2416`, `client_connection.adb:1820-1825`).

### H2-5: A request body exceeding a route limit mid-stream can never receive the 413 over HTTP/2; the stream is reset with INTERNAL_ERROR

- **Location:** `src/flyology-http-server-http_2.adb:644-651` (`Publish_Data`
  records `Body_Limit_Failure`), `:751-757` (`Read_Body` reports
  `Read_Body_Too_Large`), `:1535-1536` (backend raises `Payload_Too_Large`),
  `:839-846` (`Queue_Response_Head` refuses any stream with
  `Failure /= No_Failure`), `:1645-1649` (`Queue_Head` turns that into
  `Device_Error`), `:2123-2135` (handler task falls back to 500, then
  `Mark_Failed`). 413 producer: `src/flyology-http-server-routing.adb:2091-2096`.
- **Severity:** P1
- **Confidence:** high
- **Evidence:**

```ada
         elsif Body_Size (Data'Length) >
           Streams (Index).Body_Limit - Streams (Index).Body_Bytes
         then
            Streams (Index).Body_Bytes := Streams (Index).Body_Limit + 1;
            Streams (Index).Failure := Body_Limit_Failure;
            Streams (Index).Discarding := True;
```

```ada
      procedure Queue_Response_Head
        (Slot   : Positive;
         Block  : Stream_Element_Array;
         Result : out Queue_Result) is
      begin
         if Streams (Slot).Phase = Free
           or else Streams (Slot).Failure /= No_Failure
           or else Streams (Slot).Response_Started
         then
            Result := Queue_Failed;
            return;
         end if;
```

```ada
      when Payload_Too_Large =>
         if not X.Wire_Response_Started then
            X.Problem (413, "body-too-large", "Request body is too large");
         else
            X.Mark_Failed;
         end if;
```

  `Body_Limit_Failure` is a member of `Failure_Kind`, so once the limit is crossed
  the stream can no longer start any response; `Discarding := True` shows the
  intent was to keep draining while a 413 is sent.

- **Failure scenario:**
  1. A route declares `Policy.Max_Body` (narrowed at dispatch,
     `routing.adb:2030`) and buffers or streams its body. A client uploads more
     than that limit; the first bytes arrive before the handler starts, so
     `Narrow_Body_Limit` accepts (`Body_Bytes <= Maximum`).
  2. Later DATA crosses the limit inside `Publish_Data`: `Failure :=
     Body_Limit_Failure`.
  3. The handler's `Buffer_Body`/`Read_Body` gets `Read_Body_Too_Large` and raises
     `Payload_Too_Large`; routing catches it and calls `X.Problem (413, ...)`.
  4. `Problem` → HTTP/2 `Respond` → `Queue_Head` → `Queue_Response_Head` returns
     `Queue_Failed` → `Flyology.IO.Device_Error` propagates out of the routing
     handler.
  5. The handler task's `when others` tries `X.Problem (500, ...)`, which fails the
     same way, then `X.Mark_Failed` → RST_STREAM(INTERNAL_ERROR). The client sees no
     413 and no 500, only a reset with INTERNAL_ERROR. HTTP/1.1 delivers the 413
     (`routing.adb:2211-2218`).
- **Reproduction test sketch:** HTTP/2 route with `Max_Body => 4096` and a
  buffering handler; raw peer sends HEADERS(`content-length: 8192`) then two
  4096-byte DATA frames. Expected: HEADERS `:status 413` (problem+json). Actual:
  RST_STREAM(INTERNAL_ERROR), no HEADERS.
- **Existing coverage:** none; `rg "413|Too_Large|Body_Limit"` over
  `tests/http2_server_audit.adb`, `tests/http2_server_integration.adb` and
  `tests/http2_server_peer.py` finds nothing. The prior audit examined only the
  window credit on this path ("the `Discarding` and 413 paths credit correctly").
- **Standard:** n/a for the protocol; framework contract (`routing.adb` 413
  behaviour) and RFC 9110 §15.5.14.

### H2-6: HPACK encoder never emits the dynamic-table size update required after a peer lowers `SETTINGS_HEADER_TABLE_SIZE`

- **Location:** `src/flyology-http-http_2_settings.adb:43-44` stores the value;
  `rg -n Header_Table_Size src/` shows no other consumer. The encoder
  (`src/flyology-http-http_2_hpack.adb:779-802` `Add_Field`, `:774-777`
  `Add_Indexed`) has no size-update representation; `http_2_requests.adb:37-62`
  and `http_2_responses.adb:35-57` build every field section from it.
- **Severity:** P1
- **Confidence:** medium. The RFC obligation and the absence of any code path are
  certain; that nghttp2-based and QUICHE-based decoders reject the first block after
  a reduction (nghttp2 `NGHTTP2_HD_STATE_EXPECT_TABLE_SIZE`, "header table size
  change was expected") is recalled, not executed here.
- **Evidence:**

```ada
               when Header_Table_Size_Id =>
                  Item.Header_Table_Size := Value;
```

```ada
   procedure Add_Field
     (Item          : in out Builder;
      Name          : String;
      Value         : String;
      Never_Indexed : Boolean := False)
   is
      ...
      Encode_Integer
        (Item, Named, 4, (if Never_Indexed then 16#10# else 0));
```

  The encoder never inserts into a dynamic table, but its declared maximum is the
  protocol default of 4 096 until it says otherwise, and the peer's decoder cannot
  know the table is empty.

- **Failure scenario:**
  1. The peer's SETTINGS carries `HEADER_TABLE_SIZE` below 4 096 (0 is the common
     choice to disable HPACK dynamic tables: Envoy `hpack_table_size`, HAProxy
     `tune.h2.header-table-size`, nghttpx options). The client (or the server, for
     a client that sends it) ACKs it.
  2. The peer's decoder now requires the first field section after the ACK to begin
     with a dynamic table size update whose value is at or below the new maximum.
  3. Every field section this crate emits starts with an indexed or literal
     representation; the peer answers GOAWAY(COMPRESSION_ERROR). Every request to
     that peer fails.
- **Reproduction test sketch:** `Settings.Apply (Item, (0, 1, 0, 0, 0, 0), Result)`
  then `HTTP_2_Requests.Encode_Head (...)`: expected first octet `16#20#` (size
  update 0) followed by the fields; actual first octet `16#82#`/`16#00#`.
- **Existing coverage:** `tests/http2_hpack_differential.py` and the HPACK smoke
  test exercise the decoder's handling of size updates only; nothing checks the
  encoder's output against a lowered table size. None.
- **Standard:** RFC 7541 §4.2 "This dynamic table size update MUST occur at the
  beginning of the first header block following the change to the dynamic table
  size" and §6.3; RFC 9113 §6.5.2 `SETTINGS_HEADER_TABLE_SIZE` ("The encoder can
  select any size equal to or less than this value by using signaling specific to
  the compression format"). The decoder side of the same rule (`Set_Maximum`
  rejecting updates above 4 096) is implemented correctly.

### H2-7: `SETTINGS_INITIAL_WINDOW_SIZE` above 2^31-1 is reported as PROTOCOL_ERROR instead of FLOW_CONTROL_ERROR

- **Location:** `src/flyology-http-server-http_2.adb:2422-2427` and
  `src/flyology-http-http_2_client_connection.adb:1831-1835`; the distinct result is
  produced at `src/flyology-http-http_2_settings.adb:54-58`
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
                  Settings.Apply
                    (Peer_Settings, Payload, Applied,
                     Peer_Is_Server => False);
                  if Applied /= Settings.Settings_Accepted then
                     Protocol_Failure;
                  end if;
```

  `Protocol_Failure` defaults its error code to `Frames.Protocol_Error_Code`;
  `Settings_Flow_Control_Error` is collapsed into it. (`Apply_Peer_Settings`
  failure, the retroactive-adjustment overflow, correctly uses
  `Frames.Flow_Control_Error` two lines later.)
- **Failure scenario:** a peer sends SETTINGS with identifier 4 and value
  `16#8000_0000#`; both engines answer GOAWAY with error code 0x1 where 0x3 is
  required. Diagnostic only.
- **Reproduction test sketch:** raw peer sends `00 00 06 04 00 00 00 00 00  00 04 80 00
  00 00`; expected GOAWAY error code 3; actual 1.
- **Existing coverage:** `tests/flyology-http-http_2_settings-smoke.adb:35-36`
  asserts `Settings_Flow_Control_Error` from `Apply` only; no engine test. h2spec
  6.5.2/2 nominally checks this code; given that finding 33 of the prior audit
  (wrong idle-stream error code) coexisted with the "146 of 146" baseline, the
  harness evidently accepts the connection close that follows the GOAWAY, so the
  baseline does not vouch for error codes.
- **Standard:** RFC 9113 §6.5.2 `SETTINGS_INITIAL_WINDOW_SIZE`: "Values above the
  maximum flow-control window size of 2^31-1 MUST be treated as a connection error
  (Section 5.4.1) of type FLOW_CONTROL_ERROR."

### H2-8: Server answers `WINDOW_UPDATE(0)` on an idle stream with RST_STREAM on that idle stream and advances `Last_Client_Stream`

- **Location:** `src/flyology-http-server-http_2.adb:1217-1221` (`Window_Update`
  reports a stream failure for any non-zero stream), `:2533-2541` (the frame
  handler calls `Reject_Stream` before the idle check), `:1277-1286`
  (`Reject_Stream` with no slot advances `Last_Client_Stream` and queues
  RST_STREAM)
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
         Accepted := Increment > 0;
         Stream_Failure := False;
         if not Accepted then
            Stream_Failure := Stream_ID /= 0;
            return;
```

```ada
               State.Streams.Window_Update
                 (Header.Stream_ID, Increment, Accepted, Stream_Failure);
               if not Accepted and then Stream_Failure then
                  State.Streams.Reject_Stream
                    (Header.Stream_ID, Error, Slot, Accepted);
```

```ada
         elsif Slot = 0 then
            if Stream_ID > Last_Client_Stream then
               Last_Client_Stream := Stream_ID;
               Remember_Seen (Stream_ID);
            end if;
            Remember_Reset (Stream_ID);
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0, Stream_ID,
               U31_Payload (Natural (Error)));
            return;
```

- **Failure scenario:** with `Last_Client_Stream = 1`, the peer sends
  WINDOW_UPDATE(stream 5, increment 0). `Reject_Stream` finds no slot, sets
  `Last_Client_Stream := 5`, sends RST_STREAM(5, PROTOCOL_ERROR) and reports
  `Accepted = True`, so the connection survives. Two rules are broken: a frame other
  than HEADERS/PRIORITY on an idle stream must be a connection error, and RST_STREAM
  must not be sent for an idle stream. A following legitimate HEADERS on stream 3 is
  then refused as `Headers_Invalid_Lower_ID` with a connection PROTOCOL_ERROR. The
  non-zero-increment idle case (fixed by prior finding 33) is handled correctly
  because it never reaches `Reject_Stream`.
- **Reproduction test sketch:** after `Connect_Peer`, send `00 00 04 08 00 00 00 00
  05  00 00 00 00`; expected GOAWAY(PROTOCOL_ERROR); actual RST_STREAM(5,
  PROTOCOL_ERROR) and the connection stays open.
- **Existing coverage:** `tests/http2_server_audit.adb:807-846` ("idle
  WINDOW_UPDATE is a connection PROTOCOL_ERROR") uses increment 100 (`U32 (100)`
  at `:838`), so the zero-increment branch is untested.
- **Standard:** RFC 9113 §5.1 idle: "Receiving any frame other than HEADERS or
  PRIORITY on a stream in this state MUST be treated as a connection error (Section
  5.4.1) of type PROTOCOL_ERROR"; §6.4: "RST_STREAM frames MUST NOT be sent for a
  stream in the 'idle' state"; §6.9 (zero increment is a stream error only for a
  stream that exists).

### H2-9: Server sends RST_STREAM(STREAM_CLOSED) for every DATA frame on a closed stream, including streams it has already reset

- **Location:** `src/flyology-http-server-http_2.adb:618-631` (`Publish_Data`
  closed-stream branches); `Reset_Failure` paths set `Remote_End := True` at
  `:912`, `:1254`, `:1295`, so a stream the server reset takes the same branch
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
         if Index = 0 then
            if Stream_ID /= 0 and then Stream_ID <= Last_Client_Stream then
               Queue_Control_Frame
                 (Frames.Reset_Stream_Frame, 0, Stream_ID,
                  U31_Payload (Natural (Frames.Stream_Closed_Error)));
               Charge_Closed_Stream (Flow_Length, Accepted);
            end if;
            return;
         elsif Streams (Index).Remote_End then
            Queue_Control_Frame
              (Frames.Reset_Stream_Frame, 0, Stream_ID,
               U31_Payload (Natural (Frames.Stream_Closed_Error)));
            Charge_Closed_Stream (Flow_Length, Accepted);
            return;
         end if;
```

  The branch does not distinguish half-closed (remote), where a stream error is
  required, from closed. After the server's own RST_STREAM (`Mark_Failed`,
  `Reset_Stream`, `Reject_Stream`, or a refused `Open_Request`) the stream is
  closed, and the RFC requires the frames to be minimally processed and
  discarded; instead a RST_STREAM is sent on a closed stream for each one. The
  window accounting (`Charge_Closed_Stream`, prior finding 7) is correct.
- **Failure scenario:** the server rejects an upload (413 path, handler failure,
  or REFUSED_STREAM). The client's already-in-flight DATA frames, which RFC 9113
  says it may legitimately have queued, each draw a 13-byte RST_STREAM. A hostile
  peer can keep this going with 9-byte empty DATA frames; the ratio is below 2:1 and
  `Maximum_Control_Backlog` applies read backpressure at 32 KiB, so this is not an
  amplification finding, but every such RST_STREAM is a frame the server must not
  send.
- **Reproduction test sketch:** open stream 1, have the handler fail so the server
  sends RST_STREAM(INTERNAL_ERROR); send DATA(1) three times. Expected: no
  response frames (bytes charged to and credited on the connection window).
  Actual: three RST_STREAM(1, STREAM_CLOSED).
- **Existing coverage:** `tests/http2_server_audit.adb:603-646` ("finding 7")
  asserts only the connection-window credit for closed-stream DATA and tolerates
  the resets; `tests/http2_server_peer.py` "connection-credit recovery after client
  resets" likewise. Nothing asserts silence.
- **Standard:** RFC 9113 §5.1 closed: "An endpoint MUST NOT send frames other than
  PRIORITY on a closed stream"; "An endpoint that sends a RST_STREAM frame on a
  stream that is in the 'open' or 'half-closed (local)' state could receive any type
  of frame ... An endpoint MUST minimally process and then discard any frames it
  receives in this state." Half-closed (remote): "it MUST respond with a stream
  error (Section 5.4.2) of type STREAM_CLOSED", which is the only case the current
  code matches.

### H2-10: Server never resets a stream whose response completed while the request half is still open; its buffered input pins the connection window

- **Location:** `src/flyology-http-server-http_2.adb:419-428` (`Maybe_Complete`
  requires `Remote_End`), `:2112-2139` (handler task performs no body drain or
  reset after `Handle` returns), `:926-932` (`Handler_Finished`); 413 without drain at
  `src/flyology-http-server-applications.adb:1020-1027` (`Reject_Body`)
- **Severity:** P2
- **Confidence:** medium (the mechanics are certain; whether a given stock client
  keeps sending after a complete response was not verified: Go's transport and
  curl are believed to reset on their own, python-h2 clients do not)
- **Evidence:**

```ada
      procedure Maybe_Complete (Index : Positive) is
      begin
         if Streams (Index).Phase = Open
           and then Streams (Index).Remote_End
           and then Streams (Index).Local_End
           and then Streams (Index).Handler_Done
         then
            Streams (Index).Phase := Complete;
         end if;
      end Maybe_Complete;
```

- **Failure scenario:**
  1. A client starts a large upload; the route rejects it early (401 from
     middleware, `Reject_Body` 413, or a handler that responds without reading).
     The handler task finishes; `Local_End` becomes True after the response is
     pulled; `Remote_End` stays False.
  2. The client continues sending (permitted by RFC 9113 §8.1). Up to 16 384 bytes
     land in `Input` and are never read, so no stream or connection credit is
     returned for them; the client then stalls on the stream window.
  3. The slot stays `Open` (counted against the 32-stream limit) until the client
     resets it or `Max_Connection_Age` (default 300 s) ends the connection.
  4. Four such streams hold 65 536 bytes of un-credited input, more than the
     65 535-byte connection window, so every other upload on that connection stalls
     too. Go's server avoids exactly this by sending RST_STREAM(NO_ERROR) after the
     complete response (the behaviour that trips H2-3 on the client side).
- **Reproduction test sketch:** route with `Reject_Body`; python-h2 client sends
  HEADERS(`content-length: 65536`) then 16 384 bytes of DATA, receives the 413, keeps
  sending to the window; expected a RST_STREAM(NO_ERROR) or continued credit;
  actual: no frame after the 413, the stream and its input stay pinned; repeat on
  four streams and a fifth stream's DATA is never credited on the connection window.
- **Existing coverage:** `tests/http2_peer.py` `early-final` scenarios exercise the
  Flyology client against an early server response, not the Flyology server; the
  server audit has no early-response-with-open-request case. None.
- **Standard:** RFC 9113 §8.1 makes the server's RST_STREAM(NO_ERROR) a MAY, so this
  is a resource-lifetime defect rather than a conformance violation.

### H2-11: Client ignores RST_STREAM and WINDOW_UPDATE on idle streams and answers post-cancel in-flight frames with RST_STREAM(PROTOCOL_ERROR)

- **Location:** `src/flyology-http-http_2_client_connection.adb:1374-1378`
  (`Reset_Stream` returns for any unknown stream), `:1344-1346` (`Window_Update`
  returns for any unknown stream); `:1115-1118` and `:1229-1241`
  (`Publish_Headers`/`Publish_Data` call `Reject_Stream` on a stream in phase
  `Complete`), `:1066-1081` (`Reject_Stream` sends RST_STREAM(PROTOCOL_ERROR) and
  marks the stream `Failed`)
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
         Index : constant Natural := Find (Stream_ID);
      begin
         if Index = 0 then
            return;
         end if;
```

```ada
         if Streams (Index).Remote_End then
            Result := Publish_Stream_Rejected;
            Reject_Stream (Positive (Index));
            return;
```

- **Failure scenario:** (a) a server sends RST_STREAM or WINDOW_UPDATE for stream 7
  before the client has opened it, or for an even stream; RFC 9113 requires a
  connection error PROTOCOL_ERROR; the client ignores the frame. Lenient and
  harmless on its own. (b) After `Cancel_Stream` (RST_STREAM(CANCEL) sent, phase
  `Complete`, `Remote_End := True`), the server's already-queued HEADERS or DATA
  for that stream arrives; the client answers each with a second RST_STREAM
  (PROTOCOL_ERROR) and flips the stream to `Failed` with
  `Response_Protocol_Failure`. The RFC requires these frames to be minimally
  processed and discarded and forbids sending non-PRIORITY frames on the closed
  stream. The extra reset is ignored by conforming peers, so the observable effect
  is limited to the wire and to `Head_Protocol_Failed` being reported for a stream
  the owner had already abandoned.
- **Reproduction test sketch:** open a stream, pump its head, `Cancel_Stream`,
  then feed HEADERS(`:status 200`, END_STREAM) for it. Expected: no output frame
  beyond the CANCEL. Actual: RST_STREAM(PROTOCOL_ERROR) queued.
- **Existing coverage:** `tests/http2_peer.py` `composable-cancel` and
  `reset-race` cover cancellation races from the owner's perspective (the session
  survives), not the frames the client emits. The idle-stream cases: none.
- **Standard:** RFC 9113 §6.4 ("If a RST_STREAM frame identifying an idle stream is
  received, the recipient MUST treat this as a connection error ... of type
  PROTOCOL_ERROR"), §5.1 idle and closed as quoted under H2-8 and H2-9.

## Areas reviewed with no findings

- **Frame layer** (`http_2_frames.adb`, both engines' `Parse_Input`/`Parse_One`):
  length is checked against the advertised 16 384 (never raised, so the default is
  the correct bound); SETTINGS/PING/GOAWAY with a non-zero stream and
  DATA/HEADERS/PRIORITY/RST_STREAM/PUSH_PROMISE/CONTINUATION with stream 0 are
  PROTOCOL_ERROR; fixed lengths (PRIORITY 5, RST_STREAM/WINDOW_UPDATE 4, PING 8,
  GOAWAY >= 8, SETTINGS ACK 0, SETTINGS mod 6) are FRAME_SIZE_ERROR; unknown types
  are accepted and ignored (`server-http_2.adb:2572-2573`); the reserved bit is
  masked on decode and cleared on encode; the client preface is matched byte for
  byte, and the first frame in both directions must be a non-ACK SETTINGS.
- **Padding** (`http_2_payloads.adb:32-78`): PADDED with an empty payload, a pad
  length greater than the remaining payload, and a short priority block are each
  rejected before any slice is formed; the padded length (not the data length) is
  charged to both windows and the padding is credited back immediately.
- **HPACK decoder**: continuation octets are capped at five with a pre-multiply
  overflow check; string length is bounded by both the 16 KiB field budget and the
  remaining block; index 0 and indices past static+dynamic are COMPRESSION_ERROR;
  a size update above 4 096 or after a field is COMPRESSION_ERROR; eviction
  subtracts `Name + Value + 32` and cannot underflow; list size is accounted with
  the 32-byte overhead against the advertised MAX_HEADER_LIST_SIZE; a refused
  request section is drained to the end so the table stays in step (prior finding
  9 holds). Uppercase names, unknown pseudo-headers, duplicates, pseudo after
  regular, pseudo in trailers, connection-specific fields, `te` other than
  `trailers`, CONNECT shape and the required set are all enforced.
- **Huffman**: EOS anywhere, padding longer than 7 bits, and padding that is not
  all ones are rejected; output is capped. The 257-entry tables are exercised by
  the python-hpack differential.
- **Flow control**: `Consume`/`Increase`/`Adjust_Initial_Window` are the proved
  SPARK unit; `Window_Size` is `Long_Long_Integer range -(2^31-1) .. 2^31-1`, so a
  negative window after a SETTINGS_INITIAL_WINDOW_SIZE decrease is representable
  and both `Pull_Output`s refuse to send while it is not positive; the retroactive
  adjustment is applied to every non-free stream in both engines and overflow is
  FLOW_CONTROL_ERROR; WINDOW_UPDATE(0) on an open stream is a stream error and on
  stream 0 a connection error; window overflow on stream 0 is FLOW_CONTROL_ERROR;
  closed-stream DATA is charged to and credited on the connection window (prior
  finding 7 holds); a reused slot starts from the advertised window (prior finding
  8 holds); the server's stream buffer cannot overflow with a peer that respects
  the window because credit is returned only after bytes leave the buffer.
- **SETTINGS**: ENABLE_PUSH other than 0/1 from a client, MAX_FRAME_SIZE outside
  2^14..2^24-1, and the payload-length rules are enforced; unknown identifiers are
  ignored; each accepted frame is ACKed; the ACK path in `Frames.Validate`
  requires an empty payload.
- **Stream state machine (server)**: even and non-increasing stream identifiers,
  HEADERS on a reset stream (stream STREAM_CLOSED), on a completed stream
  (connection STREAM_CLOSED), and on a skipped lower identifier (PROTOCOL_ERROR);
  RST_STREAM on an idle stream (connection PROTOCOL_ERROR) and on a closed stream
  (ignored); concurrency refusal with REFUSED_STREAM; GOAWAY last-stream-id
  carries the highest identifier acted upon. Idle DATA/WINDOW_UPDATE with a
  non-zero increment report PROTOCOL_ERROR (prior finding 33 holds).
- **CONTINUATION**: an interleaved frame, a CONTINUATION with no open section,
  and a section over 64 KiB are connection errors in both engines (prior finding
  15 holds); the server's pin is released on reap (prior finding 14 holds).
- **Pseudo-header octets**: `Valid_Pseudo_Value` rejects controls, space and DEL on
  all four request pseudo-fields (prior findings 3, 16, 31 hold); the response
  `:status` is exactly three digits in range and never 101.
- **SSE over HTTP/2**: event, id and comment validation match the HTTP/1.1 writer
  (prior finding 4 holds).
- **Streamed uploads (client)**: `Write_Request_Data` is bounded by the 16 KiB
  upload ring; the composable driver hands it at most one `Exchange_Buffer`
  (`Receive_Buffer_Size` = 8 KiB, `client.adb:65`, `:424-427`), so
  `Upload_Would_Block` always clears once the pump drains; trailers are emitted after the last DATA with
  END_HEADERS|END_STREAM; an empty final DATA carries END_STREAM only when no
  trailers exist.
- **Owner-driven exchange operations**: the pump is single-owner with fair handoff;
  `Wait_Source`/`Upload_Wait_Source`/`Pump_Wait_Source` report readiness on failure
  so a failed stream never sleeps to its deadline; stream failures reach the owner
  as `Head_Refused`/`Head_Goaway_Unprocessed` (retry-classified by the proved
  `Classify_Retry`), `Head_Protocol_Failed`/`Body_Protocol_Failed` (peer response
  framing) or `Body_Stream_Failed`; REFUSED_STREAM after a head is not retried.

## Observations not counted

- **Self-dependent HEADERS priority is a connection error** (`server-http_2.adb:
  2458-2462`, via `Payloads.Locate:57-59`) while a self-dependent PRIORITY frame is
  a stream reset (`:2448-2451`). RFC 7540 §5.3.1 required a stream error; RFC 9113
  §5.3.2 deprecates the signalling and retains no such MUST, so this is an internal
  inconsistency and an h2spec 5.3.1 expectation, not a 9113 violation.
- `Flyology.HTTP.HTTP_2_Client_Connection.Destroy` is documented as "Close wakes
  the pump; this call waits until it has stopped" (`.ads:103-105`); there is no
  `Close` and no pump task. Stale comment.
- `HTTP_2_HPACK` is documented as "used by HTTP/2 clients" (`.ads:6`); it is the
  server's decoder too.
- The client rejects a 204 response that carries `content-length`
  (`client_connection.adb:1142-1150`). RFC 9110 §8.6 forbids the server from
  sending it but imposes nothing on the recipient; stock servers comply, so this
  is strict policy.
- `Host` versus `:authority` is compared byte-exactly (`server-http_2.adb:2350-
  2354`) and `te` must be exactly `trailers` (`hpack.adb:584`); both are
  case-insensitive in RFC 9110. Browsers and curl never send `Host` over HTTP/2
  and gRPC sends lowercase `te`.
- `:method: CONNECT` is refused with a stream reset (`server-http_2.adb:2341-2349`)
  rather than a 4xx/501 response; server policy.
- Response field sections with a malformed regular field (uppercase name,
  connection-specific field, bad octet) are a connection error in the client
  (`hpack.adb:337`, `:367`). RFC 9113 §8.1.1 calls for a stream error, but because
  `Decode_Response` raises mid-block the connection scope is the choice that keeps
  the HPACK table in step; a stock server never produces such a section.
- The server's concurrency check counts only `Open` slots but refuses when all 32
  slots are held, so `Complete`-but-unreaped streams can trigger a transient
  REFUSED_STREAM under the advertised limit; retry-safe by definition of the code,
  and noted by the prior audit.
- `Advertised_Initial_Window_Size` (16 384), `Maximum_Header_Block` (64 KiB),
  `Maximum_Control_Backlog` (32 KiB), `Window_Update_Threshold` (8 KiB),
  `Stream_History_Capacity` (4 096) and `Maximum_Remembered_Closed_Streams` (256)
  are policy values; the only protocol consequence of the first is H2-2.
- The published h2spec "146 of 146" baseline cannot be relied on for GOAWAY error
  codes (see H2-7 and prior finding 33).
- The prior-audit coverage gap on Huffman table digits remains formally open, but
  the python-hpack differential decodes Huffman strings through the same table.
