# Discovery: WEBSOCKET

Scope (all paths relative to the worktree root):

- `src/flyology-http-websocket_client.adb` (1402) and `.ads` (369): read in full.
- `src/flyology-websocket_client_policy.adb` (70) / `.ads` (98), `src/flyology-websocket_policy.adb` (62) / `.ads` (194), `src/flyology-websocket_deflate_policy.adb` (24) / `.ads` (58): read in full.
- `src/flyology-http-server-websocket_handlers.adb` (706) / `.ads` (245): read in full. `-lifecycle.ads` (46) read; `-lifecycle.adb` (55) not read (thin generic adapter).
- `src/flyology-http-server-websocket_deflate.adb` (722) / `.ads` (32): read in full.
- `src/flyology-http-server.adb` (4838): lines 310-327, 473-600, 2663-2713, 3098-3165, 3567-4838 (SHA-1 tail, Base64, key validation, token matching, deflate negotiation, `Accept_WebSocket`, frame send, `Receive_WebSocket`, `Send_WebSocket`, `Close_WebSocket`). `src/flyology-http-server.ads` lines 820-960, 1035-1052.
- `src/flyology-http-server-applications.adb` 864-990, `.ads` 519-580; `src/flyology-http-headers.ads` and `Add` in `.adb`.
- `tests/websocket_client_smoke.adb` (933; lines 160-260, 380-470, 676-810 plus targeted greps), `tests/websocket_server_audit.adb` (447; greps), `tests/autobahn/*.json`, `review/baselines/20-autobahn-core-native.log`, `22-autobahn-limits-native.log`, `23-autobahn-compression-native.log` (summaries).
- `proof/proof-status.md` WebSocket entries; `review/prior-audit.md` findings 19, 34, 35 and the WebSocket parts of the appendices; `website/guide/client/index.html` WebSocket section.
- Runtime, out of scope and read only to refute one candidate: `flyology-io.ads` (`Infinite`), `flyology-time_math.ads/adb`, `flyology-io-connections.adb` (`Send_All`, `Acquire_Operation`), `flyology-io-sockets.adb` (`Send`, `Send_Prepared`), `flyology-operations-drivers.adb` (`Arm_Deadline`) from `~/.local/share/alire/releases/flyology_0.1.1_159210ca`. That checkout is not the pinned commit `bd95746d` (no local release matched it), so runtime statements below carry that caveat.

Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

Prior findings 19, 34 and 35 were checked for regression and are still fixed: admission validates text UTF-8 (`websocket_handlers.adb:152-155`), `Close_WebSocket` drains under the retained bound (`server.adb:4813-4816`), and `WebSocket_Reserved` no longer exists under `src/`.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| WEBSOCKET-1 | Client `Receive` fails a healthy session after 32 control frames in one call, so keepalive pings kill an indefinite wait | P1 | medium |
| WEBSOCKET-2 | Client `Close` drains the peer close under the 1 MiB default bound, not the application's, and can raise `Message_Too_Large` (undocumented) mid-handshake | P2 | high |
| WEBSOCKET-3 | Client fails the connection by TCP abort with no Close frame on every protocol failure (RFC 6455 §7.1.7 SHOULD) | P2 | medium |
| WEBSOCKET-4 | Server refuses an upgrade whose `Sec-WebSocket-Protocol` list contains an empty element | P2 | medium |

## Findings

### WEBSOCKET-1: Client `Receive` fails a healthy session after 32 control frames in one call

- **Location:** `src/flyology-http-websocket_client.adb:32` (bound), `:1200` (counter is a local of `Receive`), `:1253-1257` (check)
- **Severity:** P1
- **Confidence:** medium
- **Evidence:**

```ada
   Max_Control_Frames  : constant Positive := 32;
...
      Control_Count : Natural := 0;
...
            else
               Control_Count := Control_Count + 1;
               if Control_Count > Max_Control_Frames then
                  raise Protocol_Error with
                    "too many WebSocket control frames";
               end if;
```

The counter resets only when the application calls `Receive` again. The client's only way to wait indefinitely for a message is a negative `Timeout` (`Remaining` at `:39-48` maps it to `Flyology.IO.Infinite`, which the runtime defines as "no time limit", `flyology-io.ads:13-15`); a finite timeout that expires drops the transport (`.ads:263-264`, `:1311-1314`), so an application that subscribes to infrequent events must block in one `Receive` call. During that block every Ping and Pong from the server counts toward the bound. A server that sends keepalive pings, which RFC 6455 §5.5.2 explicitly allows ("may serve as a keepalive"), kills the session after the 33rd ping: with pings every 30 s that is about 16 minutes of idle waiting, ending in `Protocol_Error` and a dropped transport (`:1315-1317`).

Contrast the server engine, whose identical bound of 32 (`src/flyology-http-server.adb:4577`, `:4591`) is reset at the end of every message (`:4302`) and on every idle receive quantum (`:4611-4621`), so it only fires for more than 32 control frames with no 50 ms gap inside one message. The website guide (`website/guide/client/index.html:441`) says `Receive` "bounds control-frame churn", so a bound is intended; the defect is its scope (per call, spanning unbounded idle time) rather than per message or per idle interval. A reviewer who reads that sentence as authorising exactly this behaviour would rate this P2; I rate it P1 because the intended long-wait usage of the API is what triggers it.

- **Failure scenario:**
  1. Application calls `Connect`, then `Receive (Client, Kind, Data, Closed, Timeout => -1.0)` to wait for the next event.
  2. The server sends `Ping` every 30 s and no data. The client answers each with a Pong (`:1260-1263`) and increments `Control_Count`.
  3. On the 33rd ping (about 16 min), `Receive` raises `Protocol_Error "too many WebSocket control frames"` and `Drop_Transport` closes the socket without a Close frame. The peer observes an abnormal closure (1006); the application loses the session for valid peer behaviour.
- **Reproduction test sketch:** In `tests/websocket_client_smoke.adb`'s fake server, after the 101 response write 33 unmasked ping frames `16#89# 16#00#` back-to-back, then the text frame `16#81# 16#05# "hello"`. Expected: `Receive` returns `Kind = Text_Message`, `Data = "hello"`, having sent 33 masked pongs. Actual: `Protocol_Error` after the 33rd ping and `Is_Open = False`. Back-to-back pings show the defect without waiting 16 minutes because the counter has no time component.
- **Existing coverage:** `tests/websocket_client_smoke.adb:339-357` covers exactly one interleaved ping, and only on the server side of that fixture. No test sends more than 32 control frames to the client. The prior audit recorded that the client has never been run in Autobahn's client-under-test role; Autobahn's cases never send more than a handful of pings either, so that run would not catch it.
- **Standard:** RFC 6455 §5.5.2 (an endpoint MUST respond to a Ping with a Pong; pings may serve as a keepalive), §5.4 (control frames MAY be injected in the middle of a fragmented message). Neither imposes a count. That common servers ping at intervals of tens of seconds is stated from general knowledge; no specific peer's source was checked here.
- **Proof boundary:** outside. `Flyology.WebSocket_Client_Policy` proves header validation, fragmentation and close-code decisions (`proof/proof-status.md:55-66`); the control-frame counter is production-only.

### WEBSOCKET-2: Client `Close` drains the peer close under the 1 MiB default bound, not the application's

- **Location:** `src/flyology-http-websocket_client.adb:1372-1374` (consumed at `:1210`, `:1222-1233`, `:1315-1317`)
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
            Receive
              (Item, Kind, Data, Closed_Result,
               Timeout => Remaining (Started, Timeout), Token => Token);
```

`Close` calls `Receive` without `Max_Message`, so the drain runs under `Default_Max_Message` (1 MiB, `.ads:17`) whatever bound the application has been using. A data message larger than 1 MiB that the application already permits, in flight when the client sends its Close (the situation the comment at `:1375-1377` describes), makes `Receive` raise `Message_Too_Large`, drop the transport (`:1315-1317`) and propagate out of `Close`. The close handshake the client initiated is aborted with a TCP abort instead of completing, and the peer sees an abnormal closure.

This is the client-side analogue of prior finding 34, fixed on the server (`340b05b`) by retaining the last bound (`src/flyology-http-server.adb:4813-4816`, `WebSocket_Limit`). The client retains no such state and `Close` has no `Max_Message` parameter with which a caller could correct it. The `Close` contract (`.ads:305-314`) lists `Program_Error`, `Constraint_Error`, `Connection_Error`, `Timeout_Error` and `Operation_Cancelled` and does not mention `Message_Too_Large` or `Protocol_Error`, both of which the inner `Receive` can raise.

- **Failure scenario:**
  1. Application streams with `Receive (…, Max_Message => 8 * 1_024 * 1_024)`; the peer sends 2 MiB messages.
  2. Application calls `Close (Client)`; a 2 MiB message the peer sent just before observing the Close is on the wire.
  3. The inner `Receive` classifies the first data frame with `Maximum = 1 MiB`, raises `Message_Too_Large`, and drops the transport. `Close` propagates an exception it does not document; `Close_Code` is unavailable; the peer never receives the close echo it is waiting for.
- **Reproduction test sketch:** Fake server: on receiving the client's Close, first send a binary frame of 1 MiB + 1 bytes (`16#82# 16#7F#`, 8-byte length, payload), then the close echo. Client: `Receive (…, Max_Message => 2 * 1_024 * 1_024)` once, then `Close (Client)`. Expected: `Close` returns and `Close_Code = 1000`. Actual: `Close` raises `Message_Too_Large`.
- **Existing coverage:** `tests/websocket_client_smoke.adb:788-793` (`Queued_Before_Close`) crosses only a small message; it asserts the drain but never a message above 1 MiB.
- **Standard:** RFC 6455 §5.5.1 and §7.1.1 (the endpoint that sent Close waits for the peer's Close before closing TCP); the bound itself is an implementation value.
- **Proof boundary:** outside. `Classify_Data` is proved for the `Maximum` it is given; the choice of `Maximum` is production code.
- **Disposition note:** the fix needs a user decision on the interface: a `Max_Message` parameter on `Close`, or retaining the last `Receive` bound in the `Client` record as the server does. Both are reported, neither is chosen here. Independently of that choice, the `Close` contract should list the exceptions the drain can raise.

### WEBSOCKET-3: Client fails the connection with no Close frame on every protocol failure

- **Location:** `src/flyology-http-websocket_client.adb:1310-1321` (all `Receive` failures), `:1178-1182`, `:1232-1236`, `:1247`, `:1255-1256`, `:1271-1287` (the raises), `:546-557` (`Drop_Transport`)
- **Severity:** P2
- **Confidence:** medium
- **Evidence:**

```ada
   exception
      when Flyology.IO.Timeout_Error |
           Flyology.Cancellation.Operation_Cancelled =>
         Drop_Transport (Item);
         raise;
      when Message_Too_Large | Protocol_Error =>
         Drop_Transport (Item);
         raise;
```

Every protocol failure the client detects (masked server frame, reserved bits, bad opcode, non-canonical length, bad fragmentation, invalid UTF-8 text, malformed close, oversized message) is handled by closing the socket. No Close frame with 1002, 1007 or 1009 is ever written. The server engine does the opposite in `Fail` (`src/flyology-http-server.adb:4243-4260`), sending the status code before going terminal.

- **Failure scenario:**
  1. Session is open. The server sends a text frame with invalid UTF-8.
  2. Client `Receive` raises `Protocol_Error` and drops the TCP connection.
  3. The server sees an abnormal closure (1006) and cannot distinguish a client crash from a detected protocol violation. A conformance harness in the client-under-test role records a non-clean close for every failure case.
- **Reproduction test sketch:** Fake server sends `16#81# 16#01# 16#FF#` after the 101. Expected per RFC 6455 §7.1.7: a masked close frame with code 1007 before the client's TCP close. Actual: only a TCP close.
- **Existing coverage:** `tests/websocket_client_smoke.adb:741-754` (`Masked_Frame`) asserts `Protocol_Error` and `not Is_Open` and does not inspect what the server receives. `tests/websocket_client_tls_smoke.adb` likewise.
- **Standard:** RFC 6455 §7.1.7: once the connection is established, the endpoint "SHOULD send a Close frame with an appropriate status code (Section 7.4) before proceeding to _Close the WebSocket Connection_". A SHOULD, hence P2. The prior audit named the missing Autobahn client-under-test run as a gap; this is the most visible thing that run would report (close verdicts), and it was established here by reading, not by running the harness.
- **Proof boundary:** outside.

### WEBSOCKET-4: Server refuses an upgrade whose `Sec-WebSocket-Protocol` list contains an empty element

- **Location:** `src/flyology-http-server.adb:3961-3973` (consumes `:3617-3642`, which raises through `:317-327`)
- **Severity:** P2
- **Confidence:** medium
- **Evidence:**

```ada
      if Header_Field_Count (Value, "Sec-WebSocket-Protocol") > 0 then
         ...
         declare
            Validated : constant Boolean := Header_Has_Exact_Token
              (Value, "Sec-WebSocket-Protocol", "flyology-no-match");
```

```ada
            Candidate : constant String := Trim (List (First .. Last));
         begin
            Validate_Token (Candidate, "header token");
```

```ada
      if Value'Length = 0 then
         raise Protocol_Error with Description & " is empty";
```

`Header_Has_Exact_Token` validates every comma-separated element as a token, and `Validate_Token` raises on the empty string. So `Sec-WebSocket-Protocol: chat, , superchat` or `Sec-WebSocket-Protocol: chat,` makes `Accept_WebSocket` raise `Protocol_Error` even when the application selects no subprotocol at all, because the "flyology-no-match" probe runs on every upgrade that carries the header. The other list parsers in the same file skip empty elements: `Header_Has_Token` (`:527-550`, used for `Connection` and `Upgrade`) and `Negotiate_WebSocket_Deflate` (`:3798-3799`, `elsif Offer'Length = 0 then null`).

- **Failure scenario:**
  1. A client sends a valid upgrade with `Sec-WebSocket-Protocol: chat,` (trailing comma, or two lists merged with a stray separator).
  2. `Accept_WebSocket` raises `Protocol_Error "header token is empty"`; the upgrade is refused although the request is acceptable under the HTTP list rule.
- **Reproduction test sketch:** In `tests/websocket_server_audit.adb` (raw upgrade requests are built at `:228-235`), add `Sec-WebSocket-Protocol: chat, , superchat` and run a handler with `Protocol => "chat"`. Expected: 101 with `Sec-WebSocket-Protocol: chat`. Actual: the upgrade is rejected.
- **Existing coverage:** none. Autobahn sends no subprotocol lists with empty elements; `tests/websocket_server_audit.adb` uses fixed well-formed headers.
- **Standard:** RFC 9110 §5.6.1.2 (formerly RFC 7230 §7): "a recipient MUST parse and ignore a reasonable number of empty list elements". RFC 6455 §11.3.4 defines the field as `1#token`, i.e. that list rule. Whether any stock client emits such a list was not checked; browsers and the common libraries do not, which is why this is P2 rather than P1.
- **Proof boundary:** outside.

## Areas reviewed with no findings

1. **Client opening handshake** (`websocket_client.adb:728-931`). The key is Base64 of 16 `getentropy` bytes; the expected `Sec-WebSocket-Accept` is `Base64 (SHA1 (Key & GUID))` and the response must carry it exactly once, byte-equal after OWS trim (`:803-807`). SHA-1 (padding, big-endian length, message schedule, round functions and constants, big-endian digest) and Base64 (6-bit slicing, `=` padding) were checked by reading against FIPS 180-4 and RFC 4648. The status line must be `HTTP/1.1 101 ` with a control-free reason phrase; `Upgrade` and `Connection` are parsed as comma lists and compared case-insensitively (RFC 6455 §4.1 steps 2-3); any `Sec-WebSocket-Extensions` is rejected because the client offers none (§4.1 step 5); `Sec-WebSocket-Protocol` must be a single header, non-empty and byte-equal to an offered token (§4.1 step 6); `Content-Length`/`Transfer-Encoding` on the 101 and obs-fold are rejected; the head is bounded by `Headers.Default_Max_Bytes` (16 KiB) and 64 fields. Bytes after the head are retained as frame data (`:910`). Request-side injection: `Add_Header` refuses owned names (`:494-501`) and `Headers.Add` rejects CR, LF, NUL, DEL and controls in names and values (`headers.adb:14-30`); `Offer_Protocol` requires a token; `Set_Target` rejects controls, space and `#`. The smoke test exercises wrong status, missing SP, wrong Accept, empty and unoffered protocol, unexpected extension, malformed lists, framing headers, folded and oversized heads (`:393-404`).
2. **Client inbound framing** (`Read_Header` `:1124-1185`, inside the proved `Validate_Header`). RSV bits, a masked server frame (§5.1: a client MUST close on a masked frame), unknown opcodes, fragmented or >125-byte control frames, 16-bit lengths below 126 and 64-bit lengths below 65536, the 64-bit MSB (clamped to `Long_Long_Integer'Last` and rejected as too large) and the 16 MiB bound are all in the proved contract's postcondition; the 8-byte accumulation cannot overflow `Unsigned_64`. Fragmentation is the proved `Classify_Data` (continuation without a fragment, new data frame inside a fragment, size accounting with `Current_Size <= Maximum` maintained by construction). Control frames interleaved in a fragmented message do not touch `Fragmented` (`:1252-1307`). Outbound frames always set FIN, mask with `getentropy`, use the proved canonical length form, and apply the mask at `(Offset + Index) mod 4` across 8 KiB chunks (`:1039-1047`).
3. **Client UTF-8** (`Valid_UTF8` `:164-217`). Validation runs on the complete reassembled text message (`:1243-1248`), so a multi-byte sequence split across fragments is accepted and an invalid one is rejected when the message completes (not fail-fast; Autobahn 6.4.x are non-strict on that point). Hand-checked: C0/C1 and F5..FF leads rejected; overlong forms via `Minimum`; surrogates D800..DFFF; code points above 10FFFF; truncated tails. The close reason is validated the same way (`:1284`). Outbound text is validated before any byte is written (`:1073`, `:1091`).
4. **Client close** (`:1264-1305`, `:1339-1381`). A one-byte close payload is a `Protocol_Error`; the code goes through the proved `Valid_Close_Code` (1000-1003, 1007-1014, 3000-4999, so 1004/1005/1006/1015 and out-of-range codes are refused, §7.4.1/§7.4.2); the reason must be UTF-8; the echo is sent only while still `Open` (§5.5.1); `Close_Pending` refuses data sends (§5.5.1); a wss close completes TLS close-notify before the drop; `Close` validates the code (a client may send 1010), a reason of at most 123 bytes and its UTF-8 before writing.
5. **Server upgrade** (`Accept_WebSocket` `server.adb:3914-4026`). Unchanged from the prior audit's "found sound" reading: GET and HTTP/1.1, `Connection`/`Upgrade` token lists, a 24-character key ending `==`, version 13 else a 426 carrying `Sec-WebSocket-Version: 13` (§4.2.2, §4.4), origin policy failing closed, a subprotocol selected only from the offered list by exact token. Repeated header lines are comma-joined by `Header` (`:491-525`), so multi-line `Sec-WebSocket-Protocol` and `Sec-WebSocket-Extensions` offers are seen (§11.3.2, §11.3.4); I had this as a candidate and it is refuted. The response is written only after the state switch and a write failure marks the connection terminal.
6. **Server framing, fragmentation, UTF-8, close** (`Receive_WebSocket` `:4171-4640`). Every MUST-reject the prior audit listed is present, and the green Autobahn baselines confirm the behaviour (`20-…`: 240 OK, 4 NON-STRICT, 3 INFORMATIONAL; `22-…` limits: 42 OK; `23-…` compression: 180 OK, 36 UNIMPLEMENTED, 216 close verdicts OK). The persistent cursor is the proved `Frame_Cursor` (mask offset, `Remaining = Total - Position`, control frames final and at most 125 bytes); header parsing is phase-gated. Close codes accepted on receive are 1000-1003, 1007-1014 and 3000-4999; `Close_WebSocket` additionally refuses 1010 for the server (client-only code). Peer TCP EOF after the server's own Close is treated as closed, before it as `Protocol_Error`.
7. **permessage-deflate** (`Negotiate_WebSocket_Deflate` `:3644-3906`; `websocket_deflate.adb`). Parameters are parsed with quoted-string awareness; duplicates, unknown parameters, `server_max_window_bits` without a value, and window values outside 8..15 or with a leading zero decline the offer (RFC 7692 §7.1); `server_max_window_bits` is accepted only at 15 through the proved `Negotiated_Server_Window_Bits`, matching the encoder's 32 KiB window (`Find_Match` distance ≤ 32768, `deflate.adb:615-616`); both no-context-takeover parameters are always returned (allowed regardless of the offer, §7.1.1); `client_max_window_bits` is never echoed, so the 8-bit zlib incompatibility never arises for the client's compressor. Inbound RSV1 is accepted only when negotiated and only on opcodes 1 and 2, so RSV1 on a continuation or control frame is 1002 (§6, §7.2.3); RSV2/RSV3 are always 1002. The 00 00 FF FF trailer is appended virtually (`Input_Byte`, `deflate.adb:131-134`) and decoding ends at the sync-flush empty stored block or at a BFINAL block (§7.2.2). Decompressed size is capped at the message limit before each growth step (`Ensure_Output` `:188-224`) and compressed size at the frame level (`server.adb:4416-4419`), so a compression bomb yields at most `Message_Limit` bytes of output; `Append_Match` rejects distance 0 or beyond the history; Huffman trees reject over-subscription, incomplete non-single-code sets, duplicate codes and a missing end-of-block; reserved block type 3, length symbols 286/287 and distance symbols 30/31 are rejected; the proved `Select_Distance_Tree` and `Distance_Requirement_Is_Satisfied` govern the "no distance tree" case. Outbound: one non-final fixed-Huffman block plus the empty stored-block header with LEN/NLEN removed (§7.2.1); the fixed code tables and MSB-first code reversal were checked by reading; control frames are never compressed; payloads above 4 KiB go uncompressed, which is allowed per message. No codec state survives between messages, matching the negotiated no-takeover.
8. **Lifecycle `Run`** (`websocket_handlers.adb:517-693`). Version pre-check with 426; single connection writer; outbox drained then `Close_WebSocket`; quantum-timeout retry through the proved `Classify_Timeout`, with the exchange deadline authoritative (`Applications.Receive_WebSocket` caps both timeouts by `Remaining`, `applications.adb:873-889`, and marks the exchange `Failed` only when the connection went terminal); admission refuses oversized and non-UTF-8 text (the finding 19 fix); reservations are released on every path through `Reservation_Guard`.
9. **Refuted candidate: Pong or Close echo written with `Time_Left = 0.0` at a quantum boundary** (`server.adb:4581-4585`, `:4561-4565`). If the transport refused a zero timeout before attempting the write, a ping arriving as the 50 ms quantum expired would make the connection terminal (`Writing_Control` path, `:4604-4610`). The runtime's `Send_All` (`flyology-io-connections.adb:1954-2031`) takes the lease and calls `Sockets.Send`, whose `Send_Prepared` (`flyology-io-sockets.adb:1924-1966`) issues the non-blocking `send()` first and raises `Timeout_Error` only on EAGAIN with no time left, so a control frame of at most 131 bytes to a peer that is reading lands in the socket buffer on the first call. Caveat: read in release `flyology_0.1.1_159210ca`, not the pinned `bd95746d`, and the TLS path (`TLS_Driver.Send_All` with `Await_TLS_Ready`) was not read.
10. **Prior findings 19, 34, 35**: not regressed (see the header).

## Observations not counted

- Client: a data frame above 16 MiB is reported as `Protocol_Error` (`Reject_Frame_Too_Large`, `:1178-1182`) rather than `Message_Too_Large`; both drop the transport. Diagnostic wording only.
- Client: a present but empty `Sec-WebSocket-Extensions:` response header is rejected (`:816-820`) although it selects no extension; stricter than RFC 6455 §4.1 step 5, no stock server observed sending it.
- Client: `Content-Length` or `Transfer-Encoding` on a 101 is rejected (`:810-815`); strictness, RFC 9110 §15.2.2 gives a 101 no body anyway.
- Client: `Max_Control_Frames`, `Receive_Buffer_Size`, `Send_Buffer_Size` and `Max_Target_Bytes` (`:29-32`) are body-private policy values; WEBSOCKET-1 concerns the first one's scope, not its value.
- Client: zero-length non-final continuation frames are unbounded in count (bounded only by `Timeout`), the same CPU-only case the prior audit refuted for the server.
- Server: the control-frame bound of 32 per message (`server.adb:4577`, `:4591`, close 1008) resets per message and per idle quantum; it is reachable only by more than 32 control frames with no 50 ms gap inside one message. Autobahn-green; policy.
- Server: `Decode_Dynamic_Block` accepts HLIT up to 288 (zlib rejects above 286 at table build); symbols 286/287 are rejected only if decoded. Lenient and harmless.
- Server: compression applies only to payloads of at most `WebSocket_Compression_Limit` (4 KiB, `server.adb:45`); policy.
- Server: a client Close carrying 1010 is echoed verbatim; echoing the received code is what §5.5.1 describes.
- Server: `Accept_WebSocket` raises `Protocol_Error` when the configured `Protocol` was not offered rather than silently selecting none; a design choice consistent with §4.2.2 (a server must not select an unoffered protocol), and the raw API lets an application inspect the offer first.
- Autobahn compression run: the 36 UNIMPLEMENTED verdicts are the 13.x offers the server declines by policy (window bits below 15); consistent with the `.ads:828-834` statement.
- `flyology-http-server-websocket_handlers-lifecycle.adb` was not read; its spec is a generic pass-through to `Run`.
