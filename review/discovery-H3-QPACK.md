# Discovery: H3-QPACK

Scope (all under `src/` unless stated; line counts from `wc -l`):
`flyology-http-server-http_3.adb` (2149) / `.ads` (158);
`flyology-http-http_3_connection.adb` (1354) / `.ads` (249);
`flyology-http-http_3_client_connection.adb` (710) / `.ads` (212);
`flyology-http-http_3.adb` (491) / `.ads` (476);
`flyology-http-client-http_3_internals.adb` (466);
policy units `http_3_control_policy` (165/115), `http_3_frame_policy` (126/82),
`http_3_header_policy` (456/61), `http_3_message_policy` (153/86),
`http_3_settings_policy` (147/64), `http_3_stream_policy` (29/53),
`http_3_stream_receive_policy` (481/162), `qpack_field_section_policy`
(499/118), `qpack_integer_policy` (94/63), `qpack_static_table` (283/37),
`header_huffman_policy` (593/37).
Read for facts only, not reviewed: `flyology-http-client.adb` (credit and
cancel regions), `flyology_quic/src/flyology-quic-connections.ads`,
`flyology-quic-application_space.adb:795-897`,
`flyology-quic-stream_reassembly_policy.ads`, `flyology-quic-flow_control_policy.ads`,
the vendored peers `build/oracle/aioquic/.../h3/connection.py` and
`~/go/pkg/mod/github.com/quic-go/quic-go@v0.54.1/http3/`.
Tests read: `tests/http3_server_integration.adb`, `tests/http3_public_smoke.adb`,
`tests/http3_client_composable_smoke.adb`, `tests/http3_h3spec_server.adb`,
`tests/http3-conformance.md`, every `tests/flyology-http-http_3_*-smoke.adb` and
`tests/flyology-http-qpack_*-smoke.adb`, `tests/oracle/*`, `build/oracle/h3spec-report.log`.
Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

Proof boundary, stated once: every policy unit above is on the `scripts/prove.sh`
list (level 1, mode all). Their contracts are bounds contracts only
(`Consumed <= Data'Length`, `Length <= Maximum`, and the like); no postcondition
states a protocol rule. "Inside the proved boundary" below therefore means the
site cannot raise a runtime error and honours those bounds, not that the RFC
behaviour is proved. `proof/proof-status.md` does not mention any HTTP/3 or QPACK
unit by name.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| H3-QPACK-1 | Server returns no per-stream receive credit while a request body is arriving; any upload over the 16 KiB initial window deadlocks | P0 | high |
| H3-QPACK-2 | Whole-frame buffering against a 16 KiB QUIC reassembly window: a frame over 16,381 bytes is never consumed; quic-go and aioquic peers send such frames | P0 | high |
| H3-QPACK-3 | Receive-side field-section limits close the connection with QPACK_DECOMPRESSION_FAILED and are never advertised; Chrome's default cookie crumbling exceeds the 32-field cap | P0 | medium-high |
| H3-QPACK-4 | Server leaks one send slot per cancelled response; after 32 cancellations no response can be sent on the connection | P1 | high |
| H3-QPACK-5 | Server never sends GOAWAY or CONNECTION_CLOSE at end of life (Max_Requests, Max_Connection_Age, cancellation, listener shutdown) | P1 | high |
| H3-QPACK-6 | Any exception except Timeout_Error in the serve loop abandons the QUIC connection silently: 9th concurrent request, oversized body without Content-Length, CONNECT, long method, large trailers, prepared-response transport error | P1 | high |
| H3-QPACK-7 | Send-side field sections are capped at 1,109 encoded bytes while the API accepts 32 x 16 KiB; large response headers become 500, long client targets fail as Transport_Failed | P1 | high |
| H3-QPACK-8 | Client raises MAX_STREAM_DATA for every stream from transport-level consumption; a sibling stream whose owner is not reading overflows its 64 KiB ring and fails | P1 | medium |
| H3-QPACK-9 | Peer-reset request streams never refill the server's MAX_STREAMS credit; 29 cancelled requests exhaust stream concurrency for the connection | P1 | high |
| H3-QPACK-10 | Server maps malformed requests and empty request streams to CONNECTION_CLOSE(H3_MESSAGE_ERROR) instead of a stream error; the client role in the same body is stream-local | P2 | high |
| H3-QPACK-11 | Empty DATA frame on a HEAD, 204, 205 or 304 response is a message error; the HTTP/2 side of this repository accepts it | P2 | medium |
| H3-QPACK-12 | Legal QPACK inputs rejected: Set Dynamic Table Capacity 0 on the encoder stream, and Delta Base with Required Insert Count 0 | P2 | low |
| H3-QPACK-13 | Client re-emits the same Stream_Reset for a malformed response on stream IDs above 4092 until the peer's RESET arrives, which the spinning pump never reads | P2 | medium-low |
| H3-QPACK-14 | 204 or 1xx with Content-Length is treated as malformed by the proved policy and the client controller | P2 | low |

## Findings

### H3-QPACK-1: Server returns no per-stream receive credit while a request body is arriving

- **Location:** `src/flyology-http-server-http_3.adb:1637-1671` (credit routine and its due test), consumed only at `:1822-1824`; the transport's only MAX_STREAM_DATA emitter is `flyology_quic/src/flyology-quic-application_space.adb:848-866`; window default `flyology_quic/src/flyology-quic-connections.ads:105`.
- **Severity:** P0 (deadlock in normal operation)
- **Confidence:** high
- **Inside/outside proof:** outside (server driver and transport glue).
- **Evidence:**

```ada
      procedure Return_Request_Credit is
         ...
            QUIC.Build_Receive_Credit_Datagram
              (State.Transport,
               Connection_Window => Transport_Settings.Max_Data,
               Direction => QUIC.Bidirectional,
               Maximum_Streams => Limit,
      ...
      function Request_Credit_Due return Boolean is
         ...
         return Served mod Stream_Credit_Interval = 0
           or else Current - Last_Credit_Data >= Data_Credit_Interval;
      ...
            when H3.Stream_Ended =>
               ...
               Release (Positive (Slot));
               if Served < Max_Requests and then Request_Credit_Due then
                  Return_Request_Credit;
               end if;
```

`Build_Receive_Credit_Packet` is the only place the QUIC crate encodes a
MAX_STREAM_DATA frame (`grep -n Encode_Max_Stream_Data flyology_quic/src/*.adb`
returns the definition and the one call at `application_space.adb:862`), and it
raises each stream's limit to `Consumed + Window` at that moment. The server
calls it only from the `Stream_Ended` branch, and only when `Served mod 14 = 0`
or 256 KiB of connection data arrived since the last call.
`Max_Stream_Data_Bidi_Remote` defaults to 16,384.

- **Failure scenario:**
  1. A client opens a request stream and sends HEADERS plus a body larger than
     about 16,000 bytes (16,384 minus the HEADERS frame), in DATA frames of any
     size.
  2. After 16,384 stream bytes the client is blocked by the server's initial
     `max_stream_data_bidi_remote` and sends STREAM_DATA_BLOCKED.
  3. The server's `Poll` has consumed the frames it saw into `Payload_Bytes`,
     but `Stream_Ended` never arrives, so `Return_Request_Credit` never runs and
     no MAX_STREAM_DATA is ever sent for the stream.
  4. The loop sits in `Receive_One (Remaining (Connection_Deadline))` until the
     client gives up or `Max_Connection_Age` (300 s) expires. If unrelated
     requests complete on the same connection, the upload advances by 16 KiB
     each time `Served` crosses a multiple of 14.
  5. The same starvation applies after `Reject_Oversized_Request`
     (`:1620-1635`): the 413 is sent, but the client can never finish sending
     the body the server is discarding (`:1776-1777`), so the request slot stays
     occupied; the server also never sends STOP_SENDING.
- **Reproduction test sketch:** quic-go or aioquic client, POST 20,000 bytes with
  `content-length: 20000` to the routed Ada server; expected 200 with the
  buffered body (the server's own limit is 1 MiB); actual: no response, client
  times out; a packet capture shows STREAM_DATA_BLOCKED from the client and no
  MAX_STREAM_DATA from the server. quic-go uploads in 8 KiB frames
  (`http3/request_writer.go:22 bodyCopyBufferSize = 8 * 1024`), so the frame
  size of H3-QPACK-2 is not a factor in this reproduction.
- **Existing coverage:** none moves a body over 16 KiB through HTTP/3. The
  aioquic oracle POSTs 7 bytes (`tests/oracle/aioquic_h3_client.py:65-70`); the
  quic-go oracle sends small string bodies (`tests/oracle/quic-go/main.go:110-121`);
  the composable smoke uploads `"commit-bytes"` (`tests/http3_client_composable_smoke.adb:392-394`)
  and its 1,048,577-byte `Blocked_Source` (`:128`) exercises the declared-too-large
  413 path without sending bytes; `tests/http3_server_integration.adb:107,139`
  declare 5 GiB and 64 GiB but read nothing. The guide promises the
  opposite of step 5: `website/guide/server/index.html:369` states that after
  a 413 "the server discards subsequent DATA until that request stream ends or
  resets", and that it "buffers each complete request before routing it" with a
  1 MiB body limit, which a body over 16 KiB can never reach.
- **Standard:** RFC 9000 section 4.1 (a sender MUST NOT exceed the advertised
  limit; the receiver must send MAX_STREAM_DATA to allow more); RFC 9114
  section 4.1.1 (a server that sends a final response before reading the whole
  request SHOULD abort reading with H3_NO_ERROR).

### H3-QPACK-2: Whole-frame buffering against a 16 KiB reassembly window

- **Location:** `src/flyology-http-http_3_frame_policy.adb:72-81` (inside the proved
  boundary; the 65,535 cap and truncation rule are policy constants, not proved
  protocol facts), consumed by `src/flyology-http-http_3_stream_receive_policy.adb:399-409`
  and `src/flyology-http-http_3_connection.adb:403-424`; buffer bound
  `flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:18-22`.
- **Severity:** P0 (deterministic stall until timeout against stock peers)
- **Confidence:** high
- **Evidence:**

```ada
      elsif Length_Value > Varint_Policy.Value_Type (Frame_Offset'Last) then
         Result.Status := Frame_Length_Too_Large;
         return;
      end if;

      Result.Payload_Length := Frame_Offset (Length_Value);
      if Result.Payload_Length > Data_Length - Position then
         Result.Payload_Length := 0;
         return;
      end if;
```

```ada
   Max_Stream_Data : constant := 16_384;
   ...
     Reassembly_State.Highest - Reassembly_State.Base <=
       Absolute_Offset (Max_Stream_Data)
```

`Parse` consumes nothing until the whole payload is contiguous (`Truncated`,
`Consumed = 0`). The QUIC reassembly state can never hold more than 16,384
bytes beyond the consumed base, and credit only advances on `Consume`
(H3-QPACK-1). A frame whose type, length and payload exceed 16,384 bytes can
therefore never become contiguous, and a length above 65,535 is
`Frame_Length_Too_Large`, mapped to `Frame_Error` (H3_FRAME_ERROR connection
close) at `stream_receive_policy.adb:403-405`.

- **Failure scenario (client):**
  1. The Ada client requests a resource from a quic-go or Caddy server whose
     handler writes the body in one call, or through `io.Copy` (32 KiB chunks).
  2. quic-go emits one DATA frame per `Write` after its 4 KiB small-response
     buffer (`http3/response_writer.go:172-193`: `l := uint64(len(w.smallResponseBuf)
     + len(p)); df := &dataFrame{Length: l}`), so a 32 KiB write is one
     32 KiB frame.
  3. The client receives 16,384 bytes (3-byte envelope plus 16,381 payload),
     `Parse` reports `Truncated`, `Poll` returns `No_Event`, no credit is
     returned, the server is flow-blocked, and `Receive_One` waits until the
     request deadline. Every such response fails with a timeout.
  4. aioquic's `send_data` is likewise one frame per call
     (`aioquic/h3/connection.py:530-552`), so any aioquic application passing a
     body over 16 KiB in one call produces the same stall on the server side of
     an upload (in addition to H3-QPACK-1).
- **Reproduction test sketch:** run a quic-go `http3.Server` whose handler does
  `w.Write(make([]byte, 20000))`; drive `Client.Get` over HTTP/3; expected a
  20,000-byte body, actual `Timeout_Error`. For the frame-length branch, send
  `00 80 01 00 00` (DATA, length 65,536) on a request stream to the server;
  actual CONNECTION_CLOSE 0x106 although RFC 9114 defines no frame length ceiling.
- **Existing coverage:** the only responses over 16 KiB come from the Ada server,
  which frames in 1,024-byte DATA frames (`server-http_3.adb:46`,
  `tests/http3_h3spec_server.adb:100`, `tests/http3_client_composable_smoke.adb:287`).
  `tests/flyology-http-http_3_frame_policy-smoke.adb:45-47` pins the disputed
  branch: `Parse ((16#04#, 16#80#, 16#01#, 16#00#, 16#00#)).Status =
  Frame_Length_Too_Large` asserts that a 65,536-byte length is rejected, so
  that test asserts the current behaviour and would need to change with it.
- **Standard:** RFC 9114 section 7.1: "Unlike QUIC frames, HTTP/3 frames can
  span multiple packets"; the Length field is "a variable-length integer that
  describes the length in bytes of the Frame Payload" with no maximum.

### H3-QPACK-3: Receive-side field-section limits close the connection and are never advertised

- **Location:** `src/flyology-http-qpack_field_section_policy.adb:127-136` (`Append_Field`
  at 32), `:212-217` (`Field_Too_Large`), `:346-349` (`Too_Many_Fields`), inside
  the proved boundary; consumed at `src/flyology-http-http_3_stream_receive_policy.adb:292-295`
  and `src/flyology-http-server-http_3.adb:296,305-328`; limits in
  `src/flyology-http-http_3.ads:15-22`; SETTINGS default `:46-49`.
- **Severity:** P0 (a stock browser's legal request kills the connection)
- **Confidence:** medium-high (code path certain; browser header count estimated)
- **Evidence:**

```ada
         if Decode_Status /= QPACK_Field_Section_Policy.Decoded then
            Result.Status := QPACK_Decompression_Failed;
            return;
         end if;
```

```ada
         when H3.QPACK_Decompression_Failed => 16#200#,
```

Every non-`Decoded` status, including the local bounds `Too_Many_Fields`,
`Field_Too_Large` and Huffman `Output_Too_Large`, becomes QPACK_DECOMPRESSION_FAILED
and, on the server, `Close_For_H3_Error` sends CONNECTION_CLOSE 0x200. The
server sends no SETTINGS_MAX_FIELD_SECTION_SIZE (`Has_Max_Field_Size` defaults
False), and that setting is a byte limit anyway; the 32-field count limit is not
expressible.

- **Failure scenario:**
  1. Chrome constructs `QpackEncoder` with `cookie_crumbling_ = CookieCrumbling::kEnabled`
     (QUICHE `quic_spdy_session.h`) and `FirstPassEncode` iterates
     `ValueSplittingHeaderList(&header_list, cookie_crumbling_)`, which splits
     the `cookie` value on `;` into one field line per cookie
     (`value_splitting_header_list.cc`). Verified from the QUICHE sources on
     2026-09-22.
  2. A top-level navigation carries roughly 17 non-cookie fields (`:method`,
     `:authority`, `:scheme`, `:path`, three `sec-ch-ua*`, `upgrade-insecure-requests`,
     `user-agent`, `accept`, four `sec-fetch-*`, `accept-encoding`,
     `accept-language`, `priority`); this count is from general knowledge, not
     measured here.
  3. With about 15 or 16 cookies the section has 33 fields; `Append_Field` fails
     on the 33rd, the server closes the connection with 0x200, and the browser
     cannot load the site over HTTP/3.
  4. The same close happens for any single field value over 16 KiB or name over
     256 bytes, in both roles (a response with 33 `set-cookie` or `link` fields
     kills the client's connection).
- **Reproduction test sketch:** raw peer sends a valid request with 33 literal
  fields (`00 00` prefix, 33 x `2x` literal lines); expected per RFC 9114
  section 4.2.2 a 431 or at worst a stream reset; actual CONNECTION_CLOSE
  0x200. h3spec's static-index case (`build/oracle/h3spec-report.log`) checks a
  genuinely malformed section, not a well-formed oversized one.
- **Existing coverage:** none for 33 fields or a 16 KiB value on a live
  connection; `tests/flyology-http-qpack_field_section_policy-smoke.adb`
  exercises the RFC 9204 B.1 vector.
- **Standard:** RFC 9114 section 4.2.2 ("A server that receives a larger header
  section than it is willing to handle can send an HTTP 431"); RFC 9204
  section 6 (QPACK_DECOMPRESSION_FAILED: "decoder failed to interpret an
  encoded field section"). The 32-field and 16 KiB limits themselves are
  documented policy; the error class and the absent advertisement are the
  defect.

### H3-QPACK-4: Server leaks one send slot per cancelled response

- **Location:** `src/flyology-http-http_3_connection.adb:624-677` (cancellation),
  `:116-146` (`Release_Message`), `:556-587` (`Add_Send`), consumed by
  `src/flyology-http-server-http_3.adb:1393-1409` (`Mark_Failed`) and
  `:1592-1604`.
- **Severity:** P1
- **Confidence:** high
- **Inside/outside proof:** outside.
- **Evidence:**

```ada
      Find_Or_Add_Message (Item, Transport, Stream, Slot, Status);
      ...
      QUIC.Build_Stream_Abort_Datagram
        (Transport, Stream, Application_Error,
         Item.Sending (Slot).Offset, Now, Packet, Sent);
      Status := Send_Status_For (Sent);
      if Status = Succeeded then
         Item.Sending (Slot).Finished := True;
         Item.Sending (Slot).Cancelled := True;
         if Item.Local_Role = Client then
            ...
            Abandon_Message (Item, Transport, Stream);
         end if;
      end if;
```

For the server role the `Sending` slot allocated by `Find_Or_Add_Message` is
never cleared: `Release_Message` touches `Sending` only when
`Item.Local_Role = Client` (`:135-145`), and the only other decrements are the
Fin sends in `Build_Headers`, `Build_Data`, `Build_Response` and
`Build_Prepared_Responses`, none of which run for a cancelled stream.
`Send_Count` therefore grows by one per cancellation until `Max_Streams` (32).

- **Failure scenario:**
  1. A handler raises after starting a streaming response, returns while a
     streaming or SSE response is open, overruns a fixed length, or the client
     stops reading so `Wait_For_Transport` times out; each path calls
     `X.Mark_Failed` -> `H3.Cancel_Request`.
  2. After 32 such events on one connection `Add_Send` returns
     `Stream_Capacity_Exceeded`; `Send_Headers` raises `Device_Error`
     ("HTTP/3 response headers failed: STREAM_CAPACITY_EXCEEDED"), the 500
     fallback fails the same way, `Mark_Failed` cannot allocate a slot either,
     and every later request on the connection receives nothing until
     `Max_Connection_Age`.
  3. A hostile client reaches this deliberately by sending 32 requests and
     never extending response credit (each times out after 30 s).
- **Reproduction test sketch:** `tests/http3_public_smoke.adb`-style pair;
  server calls `Cancel_Request (Reject_Unprocessed)` on 32 successive request
  streams; the 33rd `Send_Headers` returns `Stream_Capacity_Exceeded`.
- **Existing coverage:** `tests/http3_public_smoke.adb:185-197` cancels once per
  role and does not inspect capacity afterwards.
- **Standard:** n/a (local resource accounting).

### H3-QPACK-5: Server never sends GOAWAY or CONNECTION_CLOSE at end of life

- **Location:** `src/flyology-http-server-http_3.adb:1897-1927` (loop exit and
  `Cleanup`), `:2026-2035` (worker), `:1919-1922`; `Send_Goaway`/`Build_Goaway`
  have no caller under `src/` outside `http_3.adb` and `http_3_connection.adb`
  (`grep -rn 'Send_Goaway\|Build_Goaway' src/`).
- **Severity:** P1
- **Confidence:** high
- **Evidence:**

```ada
      while not State.Closed
        and then Served < Max_Requests
        and then Remaining (Connection_Deadline) /= 0.0
      loop
      ...
      end loop;
      Flush_Pending_Responses
        (State.all, Remaining (Connection_Deadline));
      Cleanup;
```

When `Max_Requests` or `Max_Connection_Age` is reached, or the listener token
fires (`Channel_Closed` -> `Operation_Cancelled` -> `Cleanup; raise`), the QUIC
state is freed and nothing is transmitted. `QUIC.Connection.Finalize` has no
socket and cannot send.

- **Failure scenario:** a browser keeps a connection for five minutes; the
  server abandons it silently; the browser's next request on it receives no ACK
  and is retried only after its own QUIC idle timeout. The HTTP/2 server in this
  repository does send GOAWAY (`src/flyology-http-server-http_2.adb:1313`).
- **Reproduction test sketch:** `Serve` with `Max_Requests => 1`; one GET; then a
  second GET on the same connection from quic-go; expected GOAWAY or
  CONNECTION_CLOSE(H3_NO_ERROR) observed by the client; actual silence.
- **Existing coverage:** none; `tests/http3_public_smoke.adb:202-235` exercises
  the low-level `Send_Goaway` API only. `website/guide/server/index.html:369`
  documents that "the request limit controls connection rotation" without
  saying the rotation is silent.
- **Standard:** RFC 9114 section 5.2 ("Servers SHOULD send a GOAWAY frame when
  the closing of a connection is known in advance"); section 5.3 (graceful
  shutdown "SHOULD use the H3_NO_ERROR error code").

### H3-QPACK-6: Exceptions other than Timeout_Error abandon the connection without a close

- **Location:** `src/flyology-http-server-http_3.adb:1901-1918` (only
  `Timeout_Error` handled), `:1923-1926`, `:2026-2033`; the raisers:
  `:1699-1702` (`Resource_Exhausted`, `Maximum_Request_Streams = 8` at `:44`
  against `Max_Streams_Bidi = 29` in `flyology_quic/src/flyology-quic-connections.ads:107`),
  `:1778-1782` (`Payload_Too_Large`), `:1563-1566` (CONNECT), `:1550`
  (`To_Method` raises `Constraint_Error` for methods over 64 bytes,
  `src/flyology-http.adb:12-20`), `:1765-1767` (`Headers.Add` raises
  `Headers_Too_Large` above 16 KiB, `src/flyology-http-headers.ads:10,34`),
  `:396-400` and `:454-457` (`Device_Error` on any non-`Succeeded` prepared
  response status).
- **Severity:** P1
- **Confidence:** high
- **Evidence:**

```ada
                  if Slot = 0 then
                     raise Resource_Exhausted with
                       "HTTP/3 request capacity is full";
                  end if;
```

```ada
         exception
            when Flyology.IO.Timeout_Error =>
               exit when Remaining (Connection_Deadline) = 0.0;
         end;
```

- **Failure scenario:**
  1. A client opens nine request streams whose bodies are still in flight
     (the QUIC transport advertises 29); the ninth `Headers_Received` raises and
     the worker logs and frees the connection with no CONNECTION_CLOSE.
  2. A POST without `content-length` exceeds 1 MiB (legal HTTP; the cap is the
     documented buffered-server policy): same silent drop instead of 413 or a
     stream reset; with `content-length` the graceful 413 path at `:1620-1635`
     is taken.
  3. A CONNECT request passes the proved validator and raises
     `Protocol_Error` in `Dispatch_Request`; a 65-byte method or a trailer
     section over 16 KiB raises likewise.
  4. If the transport reports a non-`Succeeded`, non-`Frame_Too_Large` status
     for a batched prepared response (for example a stream the peer stopped),
     `Flush_Pending_Responses` raises `Device_Error` for the whole batch. The
     QUIC-side condition is not verified here.
- **Reproduction test sketch:** aioquic client opens 9 POST streams sending
  HEADERS then pausing; expected the 9th to be refused with 503 or
  H3_REQUEST_REJECTED; actual the connection dies without a close frame and
  aioquic reports an idle timeout.
- **Existing coverage:** none. `website/guide/server/index.html:369` documents
  the 1 MiB limit as "A larger declared Content-Length receives 413", which
  describes only the declared case; the undeclared case is the silent drop.
- **Standard:** RFC 9000 section 10.2 (an endpoint that closes "MUST use a
  CONNECTION_CLOSE frame if it is able"); RFC 9114 section 4.1.2 (a server MAY
  respond before resetting a stream).

### H3-QPACK-7: Send-side field sections are capped at 1,109 encoded bytes

- **Location:** `src/flyology-http-qpack_field_section_policy.ads:21` and
  `.adb:380-386,494-496` (inside the proved boundary; the bound is a policy
  constant); consumed at `src/flyology-http-http_3_connection.adb:862-874`,
  `:947-962`, `:1073-1088`; `src/flyology-http-server-http_3.adb:861-871`,
  `:1592-1604`; `src/flyology-http-client.adb:5218-5229`. Contract:
  `src/flyology-http-http_3.ads:15-22` and CHANGELOG 0.1.1 ("QPACK field values
  to 16 KiB", "client request targets to 16 KiB").
- **Severity:** P1 (documented contract violated on valid input)
- **Confidence:** high
- **Evidence:**

```ada
   --  Bounded field-value size, including long :path values used by
   --  presigned object requests.
   Max_Value_Length : constant := 16 * 1_024;
```

```ada
      Encoded := QPACK_Field_Section_Policy.Encode (Headers);
      if Encoded.Status /= QPACK_Field_Section_Policy.Encoded then
         Status := QPACK_Decompression_Failed;
         return;
      end if;
```

`Encode` fails at 1,109 bytes (`Max_Encode_Length`), and `Build_Stream_Datagram`
takes at most 1,100 bytes, so no HEADERS frame over about 1,097 bytes can be
sent by either role. The failure is reported as `QPACK_Decompression_Failed`,
which `Try_Send_Response` and `Send_Headers` turn into `Device_Error`, which
`Dispatch_Request` turns into a 500; the client turns it into
`Fail_Exchange (Transport_Failed)`.

- **Failure scenario:** a handler sets a 1.5 KiB `content-security-policy`, a
  1 KiB `set-cookie`, or several `link` preloads; the response becomes a 500. A
  client request with a 1.2 KiB presigned `:path` (accepted by `Set_Target` up
  to 16 KiB) fails as a transport failure.
- **Reproduction test sketch:** `X.Text (200, "ok", Extra_Headers => "X-Long: " & 1200 * 'a' & CRLF)`;
  expected 200 with the header; actual 500. Client: `Set_Target` with a
  1,200-byte path over HTTP/3; expected the request to reach the server;
  actual `Transport_Failed`.
- **Existing coverage:** none; `tests/http3_public_smoke.adb:97` covers the
  peer-advertised `Peer_Field_Section_Too_Large` case only, and
  `tests/corpus/http-client-scenarios.json` has no long-target scenario
  (`rg -i presign` returns nothing) although its scenarios run over `h3`.
- **Standard:** n/a for the RFC; `.ads` contract and CHANGELOG.

### H3-QPACK-8: Client raises MAX_STREAM_DATA for every stream from transport-level consumption

- **Location:** `src/flyology-http-client.adb:2517-2552`;
  `flyology_quic/src/flyology-quic-application_space.adb:848-866`;
  `src/flyology-http-http_3_client_connection.adb:411-423`, `.ads:114`.
- **Severity:** P1
- **Confidence:** medium
- **Evidence:**

```ada
                  if not Stream.Head_Available
                    or else Stream.Trailers_Seen
                    or else Stream.Body_Forbidden
                    ...
                    or else Stream.Content_Count + Event.Data_Length >
                      Response_Buffer_Capacity
                  then
                     Stream.Phase := Failed;
```

`Build_Receive_Credit_Packet` raises every stream's limit to its QUIC
`Consumed_Offset + Window`; `Poll` consumes each DATA frame at the QUIC level
when it copies it into the 65,535-byte ring, whether or not the owner has read
it. The due test uses the pumping owner's own decoded length.

- **Failure scenario:** two exchanges share a pooled HTTP/3 connection; the
  owner of A reads and pumps; B's owner has not started reading; A's credit
  packets keep advancing B's window; B's ring exceeds 65,535 bytes and B fails
  with `Body_Stream_Failed` instead of being flow-controlled.
- **Reproduction test sketch:** two concurrent `Exchange_To_Buffer` operations on
  one connection against a server that returns 200 KiB on both; read A to
  completion before touching B; expected B complete; actual B `Response_Invalid`.
- **Existing coverage:** none; the composable smoke reads each response as it
  completes.
- **Standard:** RFC 9000 section 4.1 (credit should reflect what the receiver
  can buffer).

### H3-QPACK-9: Peer-reset request streams never refill MAX_STREAMS credit

- **Location:** `src/flyology-http-server-http_3.adb:1637-1663` (`Limit :=
  Max_Streams_Bidi + Served`), `:1825-1828` (`Stream_Reset` only releases the
  slot), `:1822-1824` (credit only at `Stream_Ended`).
- **Severity:** P1
- **Confidence:** high (mechanism); medium (frequency)
- **Evidence:**

```ada
         Limit  : constant QUIC.Stream_Offset :=
           QUIC.Stream_Offset'Min
             (2**60,
              Transport_Settings.Max_Streams_Bidi
                + QUIC.Stream_Offset (Served));
      ...
            when H3.Stream_Reset =>
               if Slot /= 0 then
                  Release (Positive (Slot));
               end if;
```

The cumulative MAX_STREAMS limit is 29 plus completed requests; a stream the
peer resets before `Stream_Ended` consumed an ID but never increments `Served`,
so each cancellation permanently removes one unit of concurrency, and credit is
only transmitted when a request completes.

- **Failure scenario:** a browser aborts 29 requests over the life of a
  connection (navigation cancels image loads); the client's stream limit is
  exhausted, it sends STREAMS_BLOCKED, and no MAX_STREAMS will ever be sent
  because nothing can complete.
- **Reproduction test sketch:** aioquic client opens and resets 29 request
  streams, then issues a GET; expected 200; actual the GET cannot be opened
  (aioquic raises on stream limit) and the server never raises the limit.
- **Existing coverage:** none.
- **Standard:** RFC 9000 section 4.6 (an endpoint that wants to permit more
  streams sends MAX_STREAMS; the limit is cumulative over all streams opened).

### H3-QPACK-10: Server treats malformed requests and empty request streams as connection errors

- **Location:** `src/flyology-http-http_3_connection.adb:426-440` (client role
  only), `src/flyology-http-server-http_3.adb:295,305-328`;
  `src/flyology-http-http_3_stream_receive_policy.adb:466-470` and
  `src/flyology-http-http_3_message_policy.adb:138-144` (inside the proved
  boundary; classification only).
- **Severity:** P2 (permitted by RFC 9114 section 8 but costly and asymmetric)
- **Confidence:** high
- **Evidence:**

```ada
            if Item.Local_Role = Client
              and then Status in Message_Error | Header_Error
            then
               --  RFC 9114 assigns malformed HTTP message semantics to this
               --  response stream. Surface a stream-local failure ...
```

On the server the same statuses propagate to `Close_For_H3_Error` and become
CONNECTION_CLOSE 0x10E, killing every other request in flight. An empty
request stream (open, FIN, no bytes) is `Finish_Request -> Message_Incomplete
-> Message_Error` and closes the connection too.

- **Failure scenario:** one tab issues a request with `te: gzip` or an
  uppercase field name (browsers do not; curl strips connection-specific
  headers for h2/h3, but a custom client can); all sibling requests on the
  connection are lost.
- **Existing coverage:** h3spec's four H3_MESSAGE_ERROR cases pass with a
  connection close (`build/oracle/h3spec-report.log`), so the gate does not
  distinguish the two; `tests/flyology-http-http_3_stream_receive_policy-smoke.adb:204`
  asserts the classifier only.
- **Standard:** RFC 9114 section 4.1.2 ("MUST be treated as a stream error of
  type H3_MESSAGE_ERROR"; "a server MAY send an HTTP response indicating the
  error prior to closing or resetting the stream"); section 4.1 (incomplete
  request: "SHOULD abort its response stream with the error code
  H3_REQUEST_INCOMPLETE"); section 8 ("An endpoint MAY choose to treat a stream
  error as a connection error under certain circumstances ... Implementations
  need to consider the impact on outstanding requests").

### H3-QPACK-11: Empty DATA frame on a HEAD, 204, 205 or 304 response is rejected

- **Location:** `src/flyology-http-http_3_message_policy.adb:113-117` (inside
  the proved boundary), `src/flyology-http-http_3_client_connection.adb:355-357,411-423`.
- **Severity:** P2
- **Confidence:** medium
- **Evidence:**

```ada
      elsif Frame_Type = HTTP_3_Frame_Policy.Data_Frame then
         if State.Phase /= Final_Response_Open then
            Result.Status := Frame_Unexpected;
         elsif not State.Body_Allowed then
            Result.Status := Message_Error;
```

`Data_Length = 0` is not exempted. The client controller also fails on an
empty DATA frame for 205, which the policy allows (`Body_Allowed` excludes only
204 and 304, `:94-96`), so the two layers disagree.

- **Failure scenario:** a server that terminates a HEAD response with a
  zero-length DATA frame carrying FIN; the response fails with
  `Stream_Reset 0x10E`. Commit 80e7f6b made the HTTP/2 client accept exactly this
  shape ("accept empty HEAD stream completion"), driven by the repository's own
  `tests/http2_peer.py`, so no stock server is identified.
- **Existing coverage:** none for HTTP/3.
- **Standard:** RFC 9110 section 6.4.1 (HEAD response MUST NOT include content);
  RFC 9114 section 4.1 does not address zero-length DATA frames.

### H3-QPACK-12: Legal QPACK inputs rejected

- **Location:** `src/flyology-http-http_3_stream_receive_policy.adb:169-174`;
  `src/flyology-http-qpack_field_section_policy.adb:256-262`; both inside the
  proved boundary.
- **Severity:** P2
- **Confidence:** low (no stock encoder known to send either)
- **Evidence:**

```ada
      elsif Stream.Stream_Type = QPACK_Encoder_Stream then
         --  SETTINGS_QPACK_MAX_TABLE_CAPACITY is fixed at zero, which
         --  prohibits every encoder instruction in this profile.
         Result.Status := QPACK_Encoder_Stream_Error;
```

```ada
      Read_Integer (7, Delta_Base, Success);
      ...
      elsif Delta_Base /= 0 then
         Status := Invalid_Prefix;
```

- **Standard:** RFC 9204 section 4.3.1 ("The new capacity MUST be lower than or
  equal to the limit"; zero is permitted), so `20` on the encoder stream is
  legal; section 4.5.1.2 (with Sign 0, Base = ReqInsertCount + DeltaBase; the
  only constraint is "The value of Base MUST NOT be negative"), so a nonzero
  Delta Base with Required Insert Count 0 is legal. Both quoted verbatim from
  rfc-editor.org during this review.
- **Existing coverage:** `tests/flyology-http-qpack_field_section_policy-smoke.adb`
  consumes the B.1 vector only.

### H3-QPACK-13: Stale Stream_Reset re-emission for malformed responses on stream IDs above 4092

- **Location:** `src/flyology-http-http_3_connection.adb:426-440`, `:148-180`
  (`Abandon_Message`), `:105-114`, `.ads:18` (`Max_Message_Tombstones = 1_024`).
- **Severity:** P2
- **Confidence:** medium-low
- **Evidence:** after `Header_Error` the client role sets `Finished := True` and
  returns a `Stream_Reset` event but consumes none of the offending bytes
  (`Consumed` is only set on `Consumed` status). `Abandon_Message` records a
  tombstone only for `ID / 4 <= 1023` and releases the QUIC stream only if it is
  complete or reset. For a later stream the next `Poll` finds no tombstone,
  `Find_Or_Open` opens a fresh slot for the same ID, re-parses the same bytes and
  re-emits the event; the synchronous pump (`client-http_3_internals.adb:320-346`)
  exits on any `Succeeded` event and only calls `Receive_One` on `No_Event`, so
  the peer's RESET_STREAM that would end the loop is never read. The synchronous
  path closes the whole connection on `Body_Stream_Failed`
  (`client.adb:2151-2167`), which avoids the spin at the cost of sibling
  exchanges; the composable path cancels and may spin.
- **Reproduction test sketch:** after 1,025 requests on one connection, a raw
  server sends a response with an uppercase field name and leaves the stream
  open; observe the pump loop.
- **Existing coverage:** none.
- **Standard:** n/a.

### H3-QPACK-14: 204 or 1xx with Content-Length is treated as malformed

- **Location:** `src/flyology-http-http_3_header_policy.adb:414-418` (inside the
  proved boundary), `src/flyology-http-http_3_client_connection.adb:366-372`.
- **Severity:** P2
- **Confidence:** low (reach over HTTP/3 not established)
- **Evidence:**

```ada
         if Result.Has_Content_Length
           and then (Result.Is_Interim or else Code = 204)
         then
            Result.Status := Invalid_Content_Length;
```

- **Standard:** RFC 9110 section 8.6 constrains the sender ("A server MUST NOT
  send a Content-Length header field in any response with a status code of 1xx
  or 204"); RFC 9114 section 4.1.2's list of malformed conditions does not
  include it, and HTTP/1.1 recipients ignore it (RFC 9112 section 6.3). Some
  frameworks emit `content-length: 0` on 204.

## Areas reviewed with no findings

- Frame legality per stream kind (`http_3_control_policy.adb:48-130`,
  `http_3_message_policy.adb:20-136`): DATA, HEADERS, PUSH_PROMISE, a second
  SETTINGS and the HTTP/2-reserved types 0x02, 0x06, 0x08, 0x09 on the control
  stream are `Frame_Unexpected`; SETTINGS, GOAWAY, CANCEL_PUSH, MAX_PUSH_ID and
  reserved types on request streams are `Frame_Unexpected`; DATA before HEADERS
  and HEADERS or DATA after trailers are `Frame_Unexpected`; unknown and
  greased types are ignored in every phase (RFC 9114 sections 4.1, 7.2, 9,
  11.2.1). The mapping to 0x105 at `server-http_3.adb:288` is correct.
- SETTINGS decoding (`http_3_settings_policy.adb:11-111`): reserved identifiers
  0x02-0x05 are `Settings_Error`, duplicates are rejected, greased identifiers
  are ignored, the first control frame must be SETTINGS (`Missing_Settings`).
- Unidirectional stream types (`http_3_stream_receive_policy.adb:73-115,444-480`):
  second control, encoder or decoder stream is `Stream_Creation_Error`; push
  streams at a server and server-initiated bidirectional streams at a client are
  `Stream_Creation_Error`; unknown types are consumed and discarded; closing the
  control or either QPACK stream is `Closed_Critical_Stream`; a stream closed
  before its type is tolerated; a clean FIN inside a frame is `Frame_Error`
  (RFC 9114 sections 6.1, 6.2, 7.1).
- Frame length arithmetic (`http_3_frame_policy.adb:15-86`): the 62-bit length
  is compared before narrowing; no overflow path exists (proved). The only
  problem is the policy bound, H3-QPACK-2.
- QPACK prefixed integers (`qpack_integer_policy.adb:4-57`): at most one prefix
  and three continuation octets, a division-based pre-multiply check, no
  wrap-around; values above 65,535 are refused, which the bounded profile can
  represent as `QPACK_DECOMPRESSION_FAILED` since no legal field exceeds it.
- Static table bounds and content (`qpack_static_table.adb`): indices 0..98
  match RFC 9204 Appendix A on inspection of names and values; indices above 98
  are `Invalid_Static_Index`; dynamic references, post-base representations and
  nonzero Required Insert Count are `Unsupported_Dynamic` ->
  QPACK_DECOMPRESSION_FAILED, which RFC 9204 section 4.5.1.1 requires for a
  value no conformant encoder could produce with a zero-capacity table.
- Huffman (`header_huffman_policy.adb:536-592`): EOS anywhere, padding longer
  than 7 bits or not all ones, and output over the bound are rejected; the
  bit-by-bit walk cannot index outside `Nodes`. The table itself is covered by
  the differential test `tests/flyology-http-header_huffman_policy-differential.adb`
  and was not re-derived here. Huffman strings are decoded, contrary to the
  stale spec comment (see observations).
- Header validation (`http_3_header_policy.adb`): pseudo-header order,
  duplicates, unknown pseudo-headers, pseudo-headers in trailers, missing
  `:method`/`:scheme`/`:path`, `:authority`/`host` presence and agreement,
  userinfo in `:authority`, CONNECT shape, uppercase names, control characters
  in values, connection-specific fields, `te` other than `trailers`,
  content-length syntax, overflow and duplication, `:status` shape, 101, and
  content-length on 1xx (RFC 9114 sections 4.2, 4.3.1, 4.4; RFC 9110 section 8.6).
- GOAWAY identifiers (`http_3_control_policy.adb:72-91`,
  `http_3_connection.adb:679-728`): a client rejects non-request-stream IDs,
  both roles reject an increasing repeat, the server refuses to send a
  non-request-stream ID or an increase; `Open_Request` refuses after GOAWAY
  (RFC 9114 sections 5.2, 7.2.6).
- Tombstone table wrap (`http_3_connection.adb:105-127`): only IDs 0..4092 use
  the table; higher IDs defer to `QUIC.Is_Stream_Retired`, so no modulo aliasing
  exists (the residual gap is H3-QPACK-13).
- Server request reconstruction (`server-http_3.adb:1715-1750`): names are
  tokens and values contain no CR, LF or NUL by the proved validator before they
  are re-serialised, so no header injection into `Header_Block`.

## Observations not counted

- Policy values, not defects: `Max_Stream_Data_*` 16 KiB and the 16 KiB
  reassembly buffer; `Maximum_Buffered_Request_Body` 1 MiB; `Max_Fields` 32;
  `Max_Value_Length` 16 KiB; `Max_Encode_Length` 1,109; `Maximum_Request_Streams`
  8 (its interaction with the advertised 29 is in H3-QPACK-6);
  `Response_Chunk_Size` 1,024 sends every response in 1 KiB DATA frames, one
  QUIC packet each.
- No post-handshake idle or per-request receive deadline shorter than
  `Max_Connection_Age`; a peer that trickles a body holds one of eight request
  slots for up to 300 s.
- `src/flyology-http-qpack_field_section_policy.ads:7-8` says Huffman strings
  are reported as an error "until Huffman decoding is enabled"; the body decodes
  them.
- `http_3_connection.adb:405-408` (`Length > Max_Event_Data`) is unreachable
  because the reassembly window is 16 KiB; `Frame_Too_Large -> 0x106` at
  `server-http_3.adb:289` cannot arise from `Poll`.
- A truncated SETTINGS payload is `Settings_Error` (0x109) rather than
  `Frame_Error` (0x106); RFC 9114 section 7.1 would suggest the latter.
  Diagnostics only.
- The server ignores `:scheme` and reports every HTTP/3 exchange as
  `Secure_HTTPS` (`server-http_3.adb:1560`).
- The client does not send CONNECTION_CLOSE with the HTTP/3 error code when it
  abandons a connection on a `Poll` failure (`client-http_3_internals.adb:339-345`),
  and does not distinguish `H3_REQUEST_REJECTED` (0x10B) resets for transparent
  retry, although the public API documents that reason
  (`http_3.ads:29-30,259-261`).
- `Valid_Value` accepts leading and trailing whitespace; RFC 9110 section 5.5
  treats that as a parsing concern, not a validity MUST, so it is not counted.
- `Dispatch_Request` computes the handler deadline from `Headers_Received`, so a
  slow upload can hand the handler an already-expired deadline.
