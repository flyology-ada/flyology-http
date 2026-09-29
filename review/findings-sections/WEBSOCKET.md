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
