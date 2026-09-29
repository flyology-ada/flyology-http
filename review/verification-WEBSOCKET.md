# Verification: WEBSOCKET

Commit: f078732
Findings examined: 4. Confirmed: 3. Refuted: 0. Partial: 1. Other: 0.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| WEBSOCKET-1 | P1 | CONFIRMED | P1 | `repro_websocket_1` |
| WEBSOCKET-2 | P2 | CONFIRMED | **P1** (raised) | `repro_websocket_2` |
| WEBSOCKET-3 | P2 | CONFIRMED | P2 | `repro_websocket_3` |
| WEBSOCKET-4 | P2 | PARTIALLY CONFIRMED | P2 | `repro_websocket_4` |

Three of the four are client-side, which matches the evidence available: the Autobahn
baselines `review/baselines/20-` through `23-` cover the **server** only (core native 240 OK,
4 NON-STRICT, 3 INFORMATIONAL, 244 OK close verdicts, no failures; core lightweight, limits
native and compression native all green). The client has never been run in Autobahn's
client-under-test role, and it still has not been: I cannot run the maintained script and it
refuses a dirty worktree, so every client claim here rests on a raw-peer spike instead.

Run any spike with, for example:

```sh
./tests/repros/run.sh repro_websocket_1
```

The three client spikes drive the real `Flyology.HTTP.WebSocket_Client` over a loopback TCP
socket against a raw peer inside the program that performs the RFC 6455 opening handshake by
hand (SHA-1 through `GNAT.SHA1`, Base64 written inline) and then writes crafted frames.
The server spike uses an in-memory `HTTP_Server.Transport`, as
`tests/websocket_server_audit.adb` does.

## WEBSOCKET-1: The client's 32-control-frame bound is scoped to one `Receive` call

- **Verdict:** CONFIRMED.
- **Severity:** P1 (discovery said P1; kept).
- **Repro:** `tests/repros/src/repro_websocket_1.adb`, run with
  `./tests/repros/run.sh repro_websocket_1`
- **Output:**

```
  note WEBSOCKET-1: control-frame bound scoped to one Receive call
  ok   the upgrade completes
  note Receive raised Protocol_Error: too many WebSocket control frames
  FAIL Receive delivers the text message after 33 keepalive Pings
  FAIL the session survives the keepalive Pings
  note pongs the peer observed = 32
checks: 3  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description.** The raw peer completes the upgrade, writes 33 unmasked Ping frames
  (`89 00`) back to back and then the text frame `81 05 "hello"`. The application calls
  `Receive` once with `Timeout => -1.0`. The client answers 32 Pings with masked Pongs - the
  peer counts exactly 32 - and then raises `Protocol_Error "too many WebSocket control
  frames"` on the 33rd, dropping the transport, so the text message that follows is never
  delivered. `Control_Count` is a local of `Receive` (`websocket_client.adb:1200`), the bound
  is `Max_Control_Frames : constant Positive := 32` (`:32`), and the check at `:1252-1257`
  raises. Nothing resets the counter inside a call.
- **Why the per-call scope is the defect rather than the value.** The `.ads` states, for
  `Receive`, "Timeout or cancellation terminates the session because a partially consumed
  frame cannot be exposed as a resumable application value" (`websocket_client.ads:263-264`),
  and `Remaining` maps a negative `Timeout` to `Flyology.IO.Infinite` (`:39-48`). An
  application waiting for an infrequent event therefore has exactly one supported option -
  stay inside a single `Receive` with a negative timeout - and that is the option under which
  the counter never resets. The server engine uses the identical bound
  (`server.adb:4577`, `:4591`) but resets it at the end of every message (`:4302`) and on
  every idle quantum (`:4611-4621`), which is why the Autobahn server runs are green.
- **Arithmetic in the entry, checked.** "about 16 minutes at a 30-second ping interval" is
  right: the 33rd ping falls between 960 s (16.0 min, first ping at t = 0) and 990 s
  (16.5 min, first ping at t = 30 s). The spike sends the Pings back to back because the
  bound has no time component, so it reproduces in milliseconds what a keepalive reaches in
  a quarter of an hour.
- **Standard.** RFC 6455 section 5.5.2: "Upon receipt of a Ping frame, an endpoint MUST send
  a Pong frame in response, unless it already received a Close frame", "An endpoint MAY send
  a Ping frame any time after the connection is established and before the connection is
  closed", and "NOTE: A Ping frame may serve either as a keepalive or as a means to verify
  that the remote endpoint is still responsive." Neither that section nor section 5.4 bounds
  how many control frames a peer may send. That common servers ping at intervals of tens of
  seconds is general knowledge and is **not verified against a peer**; the defect itself does
  not depend on it, only the time to trigger does.
- **Existing coverage.** None. `tests/websocket_client_smoke.adb:339-357` interleaves exactly
  one ping. The Autobahn baselines are server-side.

## WEBSOCKET-2: `Close` drains the peer close under the 1 MiB default rather than the application's bound

- **Verdict:** CONFIRMED.
- **Severity:** **P1** (discovery said P2; raised). This is a documented-contract violation,
  which the rubric places at P1. `Receive`'s contract lists `@exception Message_Too_Large`
  and `@exception Protocol_Error` (`websocket_client.ads:272-278`); `Close`'s contract lists
  only `Program_Error`, `Constraint_Error`, `Connection_Error`,
  `Flyology.IO.Timeout_Error` and `Flyology.Cancellation.Operation_Cancelled`
  (`:305-314`), yet `Close` calls `Receive`. The two contracts sit fourteen lines apart and
  the one for `Receive` names both exceptions the drain can raise, so the omission in
  `Close` reads as a statement about `Close`, not as shorthand. The guide makes the same promise in prose: "`Close` sends a validated masked
  status and waits for the peer close. It discards complete data messages that crossed the
  close before the peer observed it" (`website/guide/client/index.html:443`). It discards
  them only while they are under 1 MiB.
- **Repro:** `tests/repros/src/repro_websocket_2.adb`, run with
  `./tests/repros/run.sh repro_websocket_2`
- **Output:**

```
  note WEBSOCKET-2: Close drains under the 1 MiB default, not the application's bound
  ok   the upgrade completes
  ok   the first message is delivered under the application's bound
  note Close raised FLYOLOGY.HTTP.WEBSOCKET_CLIENT.MESSAGE_TOO_LARGE: flyology-http-websocket_client.adb:1233
  FAIL Close completes the handshake it started instead of raising an exception its contract does not list
  note Close_Code raised PROGRAM_ERROR
  note Close_Code =-1
  FAIL the peer close status is available after Close
  note peer saw the client Close frame = FALSE
  note raw peer note: raised FLYOLOGY.IO.SOCKETS.SOCKET_ERROR : send failed [errno=32]
checks: 4  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description.** The peer sends a small text message and then, still before the client has
  sent anything, a binary message of 1 MiB + 1 bytes. The application consumes the first
  message with its own bound, `Max_Message => 2 * 1_024 * 1_024`, and then calls
  `Close (Client, Timeout => 20.0)`. `Close` sends its masked Close frame and enters the
  drain loop at `websocket_client.adb:1366-1379`, which calls `Receive` with no
  `Max_Message`, so `Maximum := Policy.Frame_Length (Default_Max_Message)` - 1 MiB
  (`.ads:17`). `Classify_Data` returns `Reject_Message_Too_Large` and `Receive` raises at
  `websocket_client.adb:1233`, exactly the line the traceback names; the handler at
  `:1315-1317` drops the transport and the exception leaves `Close`. Afterwards `Close_Code`
  raises `Program_Error` because no peer close was ever received, so the application cannot
  learn how the session ended. The `errno=32` line is the peer's view: it was still writing
  the 1 MiB payload when the client dropped the socket, so its `send` failed with `EPIPE`
  and it never read the Close frame the client had already written. The close handshake the
  client initiated is therefore abandoned on both sides.
  The causal chain from the bound is direct and needs no second control case: the
  application's own `Receive` accepted `Max_Message => 2 MiB` for the first message, and the
  only `Maximum` in play on the failing call is the parameter default.
  RFC 6455 section 5.5.1 and section 7.1.1 make the sender of a Close wait for the peer's
  Close before closing the connection, which is exactly what the abandoned drain gives up.
- **Disposition.** As the discovery entry notes, the fix needs a user decision on the
  interface - a `Max_Message` parameter on `Close`, or retaining the last `Receive` bound in
  the `Client` record as the server does for prior finding 34
  (`server.adb:4813-4816`) - so this is a report, not a chosen design. Independently of that
  choice, `Close`'s `@exception` list should be corrected.
- **Existing coverage.** `tests/websocket_client_smoke.adb:788-793` crosses only a small
  message past a close.

## WEBSOCKET-3: The client fails the connection by TCP close, with no Close frame

- **Verdict:** CONFIRMED.
- **Severity:** P2 (discovery said P2; kept). RFC 6455 section 7.1.7 is a SHOULD, and the
  same paragraph grants an explicit exemption that does not apply here.
- **Repro:** `tests/repros/src/repro_websocket_3.adb`, run with
  `./tests/repros/run.sh repro_websocket_3`
- **Output:**

```
  note WEBSOCKET-3: no Close frame is sent when the client fails the connection
  ok   the upgrade completes
  note Receive raised Protocol_Error: invalid UTF-8 WebSocket text
  ok   the invalid UTF-8 text frame is detected
  ok   the session is no longer open
  note peer saw a Close frame = FALSE, status code =-1
  FAIL the client sends a Close frame before closing the connection
  FAIL the Close frame carries 1007 (invalid frame payload data)
checks: 5  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description.** The peer completes the upgrade and sends `81 01 FF`, a text frame whose
  single payload byte cannot begin a UTF-8 sequence. The client detects it
  (`websocket_client.adb:1243-1248`), raises `Protocol_Error`, and the handler at
  `:1310-1321` calls `Drop_Transport` (`:546-557`), which closes the socket. The peer reads
  to EOF and receives no frame at all: the first byte of a masked client Close would be
  `0x88` and nothing arrives. Every protocol failure the client detects takes this path -
  masked server frame, reserved bits, bad opcode, non-canonical length, bad fragmentation,
  invalid UTF-8 text, malformed close, oversized message.
- **Standard.** RFC 6455 section 7.1.7: "If _The WebSocket Connection is Established_ prior to
  the point where the endpoint is required to _Fail the WebSocket Connection_, the endpoint
  SHOULD send a Close frame with an appropriate status code (Section 7.4) before proceeding
  to _Close the WebSocket Connection_." The same paragraph permits omitting the frame only
  when the endpoint "believes the other side is unlikely to be able to receive and process
  the Close frame, due to the nature of the error that led the WebSocket connection to fail
  in the first place" - a TCP connection that is healthy apart from one bad payload byte is
  not that case, and section 7.4.1 assigns 1007 to exactly this failure. The server engine
  does send the code before going terminal, in `Fail` (`server.adb:4243-4260`).
- **Autobahn client role.** This is precisely what an Autobahn client-under-test run reports,
  as a close verdict on every failure case. **That run has still not happened.** The prior
  audit recorded the gap, the maintained script is out of scope for this verification and
  refuses a dirty worktree, and nothing in `review/baselines/` exercises the client in that
  role. The finding is established here by a raw-peer spike, not by a conformance harness.

## WEBSOCKET-4: The server refuses an upgrade whose `Sec-WebSocket-Protocol` list contains an empty element

- **Verdict:** PARTIALLY CONFIRMED. The defect is real for an empty element in the interior
  or at the head of the list, and for adjacent commas. The entry's second example, a
  **trailing comma** (`Sec-WebSocket-Protocol: chat,`), is **accepted** - that claim is wrong.
- **Severity:** P2 (discovery said P2; kept).
- **Repro:** `tests/repros/src/repro_websocket_4.adb`, run with
  `./tests/repros/run.sh repro_websocket_4`
- **Output:**

```
  note WEBSOCKET-4: empty elements in the Sec-WebSocket-Protocol list
  ok   control: the upgrade offering "chat, superchat" is accepted
  ok   control: the response is 101 Switching Protocols
  ok   control: the response selects chat
  note interior empty element: Accept_WebSocket raised Protocol_Error "header token is empty"
  FAIL interior empty element: the upgrade offering "chat, , superchat" is accepted
  FAIL interior empty element: the response is 101 Switching Protocols
  FAIL interior empty element: the response selects chat
  note leading empty element: Accept_WebSocket raised Protocol_Error "header token is empty"
  FAIL leading empty element: the upgrade offering ", chat" is accepted
  FAIL leading empty element: the response is 101 Switching Protocols
  FAIL leading empty element: the response selects chat
  note adjacent commas: Accept_WebSocket raised Protocol_Error "header token is empty"
  FAIL adjacent commas: the upgrade offering "chat,,superchat" is accepted
  FAIL adjacent commas: the response is 101 Switching Protocols
  FAIL adjacent commas: the response selects chat
  ok   trailing comma: the upgrade offering "chat," is accepted
  ok   trailing comma: the response is 101 Switching Protocols
  ok   trailing comma: the response selects chat
checks: 15  failures: 9
BUG REPRODUCED
exit status 1
```

- **Description.** The spike drives `Read_Request` and then
  `Accept_WebSocket (Client, Request, Protocol => "chat")` over an in-memory transport. The
  control case shows the fixture is sound: `chat, superchat` yields 101 with
  `Sec-WebSocket-Protocol: chat`. `chat, , superchat`, `, chat` and `chat,,superchat` all
  raise `Protocol_Error "header token is empty"` and no response is written at all.
  The mechanism is as the entry describes: `Accept_WebSocket` probes every upgrade that
  carries the field with `Header_Has_Exact_Token (Value, "Sec-WebSocket-Protocol",
  "flyology-no-match")` (`server.adb:3961-3973`), and that helper runs `Validate_Token` on
  each comma-separated element (`:3617-3642`), which raises on the empty string
  (`:317-327`). The probe runs even when the application selects no subprotocol, so the
  request is refused regardless of what the handler wanted.
- **Why the trailing comma is accepted, and why the entry is wrong about it.** The loop
  condition at `server.adb:3625` is `while First <= List'Length`, and `First` is advanced to
  `Comma + 1` at `:3638`. For `"chat,"` the comma is the last character, so `First` becomes
  6 while `List'Length` is 5 and the loop ends without ever forming the empty final element.
  A leading or interior empty element, by contrast, produces an empty `Candidate` and
  reaches `Validate_Token`. The defect is therefore real but narrower than the entry states.
- **Standard.** RFC 9110 section 5.6.1.2: "Empty elements do not contribute to the count of
  elements present. A recipient MUST parse and ignore a reasonable number of empty list
  elements", and the section lists `"foo , ,bar,charlie"` among its valid examples of a
  `1#element` list. RFC 6455 section 11.3.4 defines `Sec-WebSocket-Protocol` with that list
  rule. The same file already skips empty elements in `Header_Has_Token` (`:527-550`, used
  for `Connection` and `Upgrade`) and in `Negotiate_WebSocket_Deflate` (`:3798-3799`), so
  this is an inconsistency inside the file rather than a deliberate policy.
- **Why the green Autobahn baselines do not cover it.** The fuzzing client never sends the
  field. `tests/autobahn/fuzzingclient-native.json` configures only a URL, an agent name and
  the case selection; no subprotocol is offered, so `Header_Field_Count (Value,
  "Sec-WebSocket-Protocol")` is zero on every Autobahn upgrade and the probe never runs.
  The same is true of the limits and compression configurations.
  Whether any stock client emits an empty list element is **not verified against a peer**.
  Browsers and the common libraries do not, which is why P2 stands.

## Notes for the coordinator

- Nothing in this area is `UNVERIFIABLE-BY-SPIKE`, but one gap remains open and is not mine
  to close: the client has never been exercised in Autobahn's client-under-test role.
  `WEBSOCKET-3` is the most visible thing such a run would report, and `WEBSOCKET-1` would
  not be caught by it either way, since Autobahn's cases never send more than a handful of
  control frames. Running `scripts/` Autobahn in the client role on a clean worktree would
  give the close-verdict evidence this report had to substitute a raw peer for.
- `WEBSOCKET-2` needs a user decision on the interface before it can be fixed; its
  `@exception` list correction does not.
- The discovery entry for `WEBSOCKET-4` should drop its trailing-comma example and replace it
  with a leading or interior empty element.
