# PROTO verification report (adversarial)

Method: every finding was re-derived from the sources (`rg`/`sed`/`cat`) before
any repro was written, and each claimed caller path was followed to a real
consumer. Seven reproduction programs were added under
`tests/repros/src/repro_proto_<n>.adb` and run with
`cd tests/repros && ./run.sh repro_proto_<n>`. No file under `src/`, `sql/`,
`examples/`, or `tests/src/` was touched, nothing was committed, and no full
suite was run.

All seven candidates survived refutation. Two severities are adjusted below
(PROTO-3 argued up to the P1/P2 boundary, PROTO-5 re-scoped), and one piece of
supporting evidence in the discovery report (PROTO-4's "no FATAL
ErrorResponse") was checked against a handler the discovery did not mention and
still holds, for a reason worth recording.

Rubric used, as given: P0 = memory/aliasing unsafety, security-relevant,
hang/deadlock in normal operation, or interop-breaking protocol violation;
P1 = wrong result or unexpected exception on valid input via a reachable path,
or a documented contract violated; P2 = edge-case incorrectness, wrong
diagnostics, or contract drift needing unusual input.

---

### PROTO-1: `Framing.Read_Message`/`Read_Initial` re-arm `Timeout` for every transport read instead of one deadline per message

**Verdict:** CONFIRMED.

Refutation attempts and what they found:

- *Could a concrete transport already implement whole-message deadline
  accounting, making the synthetic transport unrepresentative?* No. All three
  concrete transports treat `Timeout` as per-call:
  `src/flyology-postgres-transports-sockets.adb:3-13` forwards it verbatim to
  `Flyology.IO.Sockets.Receive_Exactly`;
  `src/flyology-postgres-transports-connections.adb:34-45` forwards it verbatim
  to `Item.Channel.Receive_Exactly`; and
  `src/flyology-postgres-transports-tls_sockets.adb:26-36` computes
  `Deadline := Clock + Timeout` *inside each call*. Nothing between
  `Framing` and the transport subtracts elapsed time.
- *Is `Framing` perhaps counting on `Transport.Receive_Exactly`'s own
  contract?* The transport contract at
  `src/flyology-postgres-transports.ads:28-40` is explicitly per-transfer
  ("Maximum time allowed for the complete transfer"), which is exactly what the
  transports implement. The mismatch is in `Framing`, which layers three such
  transfers under a documented single message deadline.
- *Is it a hang (P0)?* No. The overrun is bounded at 3x `Timeout` for
  `Read_Message` and 2x for `Read_Initial`; it is not unbounded, so P0 does not
  apply.

**Severity:** P1 (unchanged). A documented contract
(`src/flyology-postgres-framing.ads:15-17`: "Read one typed message under a
single deadline. @param Timeout Maximum time allowed for the whole message.")
is not implemented, on the path every message read in the library takes.

**Repro:** `tests/repros/src/repro_proto_1.adb`

**Output** (`./run.sh repro_proto_1`, exit status 1):

```
  -- frame bytes: 5a 00 00 00 05 49
  -- Read_Message Timeout = 0.300000000s; peer stalls 0.250000000s before satisfying each transport read
  -- Read_Message returned a 'Z' message
  -- transport reads issued: 3
  --   read 1 was granted a timeout of 0.300000000s
  --   read 2 was granted a timeout of 0.300000000s
  --   read 3 was granted a timeout of 0.300000000s
  -- wall-clock time spent inside Read_Message: 0.750048292s
  ok: Read_Message raises no unrelated exception
  FAILED: Read_Message honors its documented single deadline: it either completes within Timeout or raises Timeout_Error
  -- the whole-message deadline was exceeded by 0.450048292s because each read re-armed the full timeout
BUG REPRODUCED: 1 failed expectation(s)
```

The repro uses real wall-clock time (a busy-wait, not a simulated clock) and a
transport that answers every read, so the measured 0.75 s against a 0.30 s
deadline is the actual elapsed time inside `Read_Message`.

**Description:** `Flyology.Postgres.Framing.Read_Message`
(`src/flyology-postgres-framing.adb:62-81`) issues three independent
`Channel.Receive_Exactly` calls -- one for the tag, one via `Read_Length` for
the four-byte length, one via `Read_Contents` for the body -- and passes the
caller's full `Timeout` to each, never subtracting elapsed time.
`Read_Initial` (`:48-60`) does the same across two calls. Every concrete
transport implements `Timeout` per transfer, as its own contract requires, so a
peer that stalls just under `Timeout` before each of the three reads keeps the
call alive for nearly `3 * Timeout` without any `Flyology.IO.Timeout_Error`.
The spec at `src/flyology-postgres-framing.ads:15-17` promises "a single
deadline ... for the whole message". Callers that size `Timeout` as a liveness
bound get one three times looser than documented: `Server.Run_Session`'s
`Startup_Timeout` (`src/flyology-postgres-server.adb:372` and `:403`) and the
client's copy-event read (`src/flyology-postgres-client.adb:2266-2292`, the
replication-feedback path) are both affected. The overrun is bounded, so this
is a contract violation and a liveness-bound weakening rather than a hang.

---

### PROTO-2: `Startup_Data`, `Process_Id`, and `Secret_Key` document `Protocol_Error` on the wrong variant but never raise

**Verdict:** CONFIRMED.

Refutation attempts:

- *Is `Initial_Request` discriminated, so that a wrong-variant read would raise
  `Constraint_Error` instead?* No. `src/flyology-postgres-protocol.ads:819-824`
  declares it as a plain record with defaults (`Backend_Pid : UInt32 := 0`,
  `Secret : Unbounded_Bytes`, `Startup : Startup_Information` whose `User`
  defaults to the empty string). The three accessors
  (`src/flyology-postgres-protocol.adb:1217-1225`) are expression functions
  that read those components with no `Require`. Confirmed empirically: they
  return `major = 3`, `user = ""`, `0`, and a zero-length array.
- *Is the drift already compensated elsewhere?* Only by accident: the sibling
  `Backend_Message` accessors do check
  (`src/flyology-postgres-protocol.adb:1051-1141` use `Require (Item.Response = ...)`),
  and the one in-repo consumer, `Server.Run_Session`, guards on
  `Protocol.Kind` first (`src/flyology-postgres-server.adb:416`, `:420`). So no
  in-repo caller is wrong today.

**Severity:** P2 (unchanged) -- contract drift. Reaching it requires calling an
accessor on the wrong variant, which no in-repo caller does; the harm falls on
an external consumer that uses the documented exception as its variant check.

**Repro:** `tests/repros/src/repro_proto_2.adb`

**Output** (`./run.sh repro_proto_2`, exit status 1):

```
  -- SSLRequest contents: 04 d2 16 2f
  -- Protocol.Kind = SSL_REQUEST
  ok: the packet decodes as SSL_Request (so it is neither Startup nor Cancel_Request)
  -- Startup_Data returned a record instead of raising: major = 3, user = ""
  FAILED: Startup_Data raises Protocol_Error when Item is not Startup (protocol.ads:602)
  -- Process_Id returned 0 instead of raising
  FAILED: Process_Id raises Protocol_Error when Item is not Cancel_Request (protocol.ads:607)
  -- Secret_Key returned a 0-byte array instead of raising
  FAILED: Secret_Key raises Protocol_Error when Item is not Cancel_Request (protocol.ads:612)
BUG REPRODUCED: 3 failed expectation(s)
```

**Description (contract drift):**
`src/flyology-postgres-protocol.ads:602`, `:607`, and `:612` document
`@exception Protocol_Error Item is not Startup` / `... is not Cancel_Request`
for `Startup_Data`, `Process_Id`, and `Secret_Key`. The bodies
(`src/flyology-postgres-protocol.adb:1217-1225`) are unchecked component reads
of a non-discriminated record, so calling them on the wrong variant silently
yields the record defaults instead of raising: a `Startup_Information` with an
empty `User` for an SSLRequest or CancelRequest, `Process_Id = 0`, and a
zero-length `Secret_Key`. A consumer that follows the written contract and uses
the exception as its variant discriminator gets a plausible-looking but empty
result -- most dangerously a zero-length cancellation secret compared against a
real one. The fix is either three `Require` guards matching the
`Backend_Message` accessors' style, or a documentation correction; the two
choices differ in whether existing external callers see a new exception.

---

### PROTO-3: `Protocol.Decode_Initial` is documented as taking the complete packet "including its length field" but decodes the post-length contents

**Verdict:** CONFIRMED.

Refutation attempts:

- *Does the wire decoder tolerate a leading length word?* No. Both the wire
  layer and the protocol layer treat byte 0 of `Contents` as the request code:
  `src/flyology-postgres-wire.adb:233` reads the first `U32` as `Code` and
  branches on `SSL_Request_Code` / `GSS_Request_Code` / `Cancel_Request_Code` /
  `Shift_Right (Code, 16) = 3`, and
  `src/flyology-postgres-protocol.adb:1181` restarts the parameter walk at
  `Contents'First + 4`, i.e. immediately after the version word.
- *Do the in-repo callers agree with the doc or the code?* With the code.
  `Framing.Read_Initial` (`src/flyology-postgres-framing.adb:57-59`) reads and
  validates the length itself and passes only
  `Read_Contents (Channel, Content_Length (Length), ...)`. The unit tests
  (`tests/src/tests.adb:271-275`) slice `Packet (Cursor .. Packet'Last)` after
  a `Read_U32`. So the `.ads` sentence is the only thing that is wrong.
- *Is the misclassification loud?* No -- and this is the aggravating factor.
  A complete packet's length word is neither a special code nor a version-3
  major, so `src/flyology-postgres-wire.adb:264-267` returns `Unknown_Request`
  with status `Initial_Ok`, and `Decode_Initial` maps that to
  `Unknown_Initial`. No exception is raised for any of the three packet kinds.

**Severity:** P2, at the P1 boundary. Kept at P2 because no in-repo path passes
a complete packet, so nothing in this repository misbehaves. Worth reading as
P1 by anyone treating the published `.ads` as the contract for external
consumers: `Decode_Initial` is a public entry point, the documented usage is
the natural one, and following it produces a silently wrong classification with
no diagnostic.

**Repro:** `tests/repros/src/repro_proto_3.adb`

**Output** (`./run.sh repro_proto_3`, exit status 1):

```
  -- protocol.ads:589 -- "Strictly decode an untagged initial packet including its length field."
  -- protocol.ads:590 -- "@param Contents Complete packet bytes."
  -- complete 8-byte SSLRequest packet: Decode_Initial -> UNKNOWN_INITIAL (expected SSL_REQUEST)
  FAILED: complete 8-byte SSLRequest packet decodes as SSL_REQUEST when the complete packet is passed, as documented
  -- complete CancelRequest packet: Decode_Initial -> UNKNOWN_INITIAL (expected CANCEL_REQUEST)
  FAILED: complete CancelRequest packet decodes as CANCEL_REQUEST when the complete packet is passed, as documented
  -- complete startup packet: Decode_Initial -> UNKNOWN_INITIAL (expected STARTUP)
  FAILED: complete startup packet decodes as STARTUP when the complete packet is passed, as documented
BUG REPRODUCED: 3 failed expectation(s)
```

The repro feeds `Decode_Initial` the library's own encoder output --
`Encode_SSL_Request`, `Encode_Cancel_Request`, `Encode_Startup` -- which is the
most natural reading of "Complete packet bytes".

**Description (contract drift):**
`src/flyology-postgres-protocol.ads:589-590` documents `Decode_Initial` as
decoding "an untagged initial packet including its length field" with
"@param Contents Complete packet bytes". The implementation decodes the bytes
*after* the length: `Wire.Decode_Initial` reads `Contents (0 .. 3)` as the
request code (`src/flyology-postgres-wire.adb:233`) and the protocol layer
restarts parameter parsing at `Contents'First + 4`
(`src/flyology-postgres-protocol.adb:1181`). Passing the complete packet, as
documented, makes the length word decode as the request code; because a length
is neither a recognised special code nor major version 3, every such packet is
classified `Unknown_Initial` with status `Initial_Ok` and no exception. Round
tripping the library's own `Encode_SSL_Request` / `Encode_Cancel_Request` /
`Encode_Startup` output therefore fails silently. Both in-repo callers strip the
length first, so the correct fix is almost certainly the documentation plus a
renamed parameter, not the behaviour.

---

### PROTO-4: startup `replication` value parsing is case-sensitive and rejects boolean spellings PostgreSQL accepts

**Verdict:** CONFIRMED.

Refutation attempts:

- *Is the value normalised (case-folded) before the comparison?* No.
  `src/flyology-postgres-protocol.adb:1190-1202` compares the raw `Value`
  string against the literal sets `"database"`, `"true" | "on" | "yes" | "1"`,
  and `"false" | "off" | "no" | "0"`, and raises `Protocol_Error` for anything
  else. Ada's `=` on `String` is case-sensitive, and no prefix matching exists.
- *Is the discovery's stated consequence -- connection dropped with no FATAL
  ErrorResponse -- right, given that `Run_Session` does have a handler the
  discovery did not mention?* Yes, and for a reason worth recording.
  `Run_Session` ends with `when Error : Protocol.Protocol_Error =>
  Server_Sessions.Send_Error (... SQL_State => "08P01", Severity => "FATAL")`
  (`src/flyology-postgres-server.adb:524-535`), but the failing call is the
  *initialisation of a declared object* in `Run_Session`'s declarative part
  (`src/flyology-postgres-server.adb:371-372`), and an exception raised there
  propagates past that subprogram's own handler. The second `Read_Initial`
  (`:403`, inside the loop body) *is* covered. Since `replication` rides on the
  first startup packet, the discovery's claim holds exactly where it matters.
- *Do mainstream clients send the rejected spellings?* Not by default:
  `pg_basebackup`, `pg_receivewal` and the walreceiver send lowercase `true` or
  `database`, all of which are accepted here. The spellings only appear when a
  user writes `replication=TRUE` (or a prefix such as `t`) in a conninfo string
  or URI, which libpq passes through verbatim. That keeps this at P2.

**Severity:** P2 (unchanged) -- edge-case incorrectness requiring an unusual but
entirely legal input.

**Repro:** `tests/repros/src/repro_proto_4.adb`

**Output** (`./run.sh repro_proto_4`, exit status 1):

```
  -- PostgreSQL matches `replication` with strcmp against "database" and otherwise parse_bool, which is case-insensitive and
  -- accepts unique prefixes: t, tr, tru, true, y, ye, yes, on, 1 and f, fa, fal, fals, false, n, no, of, off, 0.
  -- replication="true" -> PHYSICAL_REPLICATION_CONNECTION
  ok: replication="true" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="database" -> LOGICAL_REPLICATION_CONNECTION
  ok: replication="database" decodes as LOGICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="false" -> NORMAL_CONNECTION
  ok: replication="false" decodes as NORMAL_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="TRUE" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="TRUE" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="True" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="True" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="t" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="t" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="On" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="On" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="Yes" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="Yes" decodes as PHYSICAL_REPLICATION_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="f" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="f" decodes as NORMAL_CONNECTION, as PostgreSQL's parse_bool accepts it
  -- replication="Off" -> Protocol_Error: invalid startup replication mode
  FAILED: replication="Off" decodes as NORMAL_CONNECTION, as PostgreSQL's parse_bool accepts it
BUG REPRODUCED: 7 failed expectation(s)
```

The three lowercase control cases pass, isolating the defect to case and prefix
handling rather than to the repro's packet construction.

**Description:** `Decode_Initial` matches the startup `replication` parameter
value against fixed lowercase literals
(`src/flyology-postgres-protocol.adb:1190-1202`) and raises
`Protocol_Error "invalid startup replication mode"` for anything outside that
set. PostgreSQL's `ProcessStartupPacket` compares against `"database"` and
otherwise calls `parse_bool`, whose `parse_bool_with_len` is case-insensitive
and accepts unique prefixes, so `TRUE`, `True`, `t`, `On`, `Yes`, `f` and `Off`
are all valid replication requests to a real backend and are rejected here.
Because the rejection happens while initialising `Initial` in `Run_Session`'s
declarative part (`src/flyology-postgres-server.adb:371-372`), it escapes that
subprogram's own `Protocol_Error` handler at `:524-535`, so the server closes
the connection without the FATAL `ErrorResponse` it would send for any later
protocol error -- the client sees an unexplained disconnect rather than a
diagnosis. Deciding whether to accept the full `parse_bool` grammar is a
compatibility-policy call, not a mechanical fix.

---

### PROTO-5: `_pq_.*` protocol options are discarded by `Decode_Initial`, so the server cannot send the NegotiateProtocolVersion the spec requires

**Verdict:** CONFIRMED, with the scope of the repro stated explicitly.

Refutation attempts:

- *Is the option preserved anywhere else -- a raw-packet accessor, a
  parameter list?* No. `Startup_Information`
  (`src/flyology-postgres-protocol.ads:569-583`) has exactly six fields and no
  parameter collection; `Initial_Request` (`:819-824`) keeps only the kind, the
  startup record, a pid and a secret. The parameter walk at
  `src/flyology-postgres-protocol.adb:1183-1205` inspects only
  `Name = "replication"`; every other pair, `_pq_.`-prefixed or not, is read
  and dropped. `rg '_pq_'` finds no occurrence under `src/` or `tests/`.
- *Could the server layer compensate?*
  `Server_Sessions.Send_Negotiate_Protocol`
  (`src/flyology-postgres-server_sessions.adb:150-159`) has no parameter for
  unrecognised options and unconditionally encodes `Append_U32 (Contents, 0)`,
  and `Server.Run_Session` calls it only when `Protocol_Minor > 2`
  (`src/flyology-postgres-server.adb:443-447`). A 3.2 client sending
  `_pq_.foo` therefore gets no NegotiateProtocolVersion at all.
- *Can the correct behaviour be asserted directly?* Not as a value comparison
  against a field that does not exist. The repro instead asserts the weakest
  property any spec-compliant decoder must have: a startup packet requesting
  `_pq_.some_option` must decode to something distinguishable from one
  requesting nothing. That assertion compiles against today's API and fails
  today; any fix that surfaces the option makes it pass.

**Severity:** P2 (unchanged as a number, re-scoped in kind). Not "wrong
diagnostics" but a missing-capability spec deviation on the server role: the
protocol requires an answer the library gives its users no way to produce.
Mainstream interop is unaffected because libpq sends no `_pq_.` options unless
an application asks for them, which is why it stays below P1.

**Repro:** `tests/repros/src/repro_proto_5.adb`

**Output** (`./run.sh repro_proto_5`, exit status 1):

```
  -- startup without options:   00 03 00 00 75 73 65 72 00 61 6c 69 63 65 00 00
  -- startup with _pq_.some_option=1: 00 03 00 00 75 73 65 72 00 61 6c 69 63 65 00 5f 70 71 5f 2e 73 6f 6d 65 5f 6f 70 74 69 6f 6e 00 31 00 00
  -- Decode_Initial accepted both packets without error.
  FAILED: a startup packet requesting _pq_.some_option decodes differently from one that requests nothing, so a server can list the unrecognized option in NegotiateProtocolVersion
  -- the two decoded Startup_Information values are identical, so the requested protocol option is unrecoverable and
  -- Send_Negotiate_Protocol can only ever encode 0 unrecognized options (server_sessions.adb:156-157).
BUG REPRODUCED: 1 failed expectation(s)
```

**Description:** The PostgreSQL start-up message flow requires a server to
answer `NegotiateProtocolVersion`, listing each unrecognised `_pq_.` option,
whenever a client requests protocol options the server does not support; only
when the version and all options are supported may it go straight to
authentication. `Decode_Initial`'s parameter walk
(`src/flyology-postgres-protocol.adb:1183-1205`) examines only `replication`
and discards every other name/value pair, and `Startup_Information`
(`src/flyology-postgres-protocol.ads:569-583`) has no field that could carry
them, so a startup packet requesting `_pq_.some_option` decodes to a value
byte-identical to one requesting nothing. On the server side
`Send_Negotiate_Protocol` (`src/flyology-postgres-server_sessions.adb:150-159`)
hard-codes an unrecognised-option count of `0` and is reached only for
`Protocol_Minor > 2` (`src/flyology-postgres-server.adb:443-447`). A conforming
server therefore cannot be built on this library: a client that asked for an
option is entitled to conclude it was accepted, and no application-visible API
can even detect the request. Closing this needs an API decision (a new
`Startup_Information` field or accessor plus a `Send_Negotiate_Protocol`
parameter), not a local edit.

---

### PROTO-6: `Read_C_String` reports "exceeds the configured limit" when the cursor is already past the end of the buffer

**Verdict:** CONFIRMED, including the wire-reachable path.

Refutation attempts:

- *Is the empty-buffer case caught earlier with a better message?* No.
  `src/flyology-postgres-protocol.adb:157-161` is the first check, and it
  conjoins three unrelated conditions -- `Source'Length <= Maximum_Message_Size`,
  `Cursor >= Source'First`, `Cursor <= Source'Last` -- under the single message
  "Postgres string exceeds the configured limit". For a `1 .. 0` buffer with
  `Cursor = 1`, the third conjunct fails. The accurate message
  "unterminated Postgres string" at `:164` is only reachable once at least one
  byte remains, which the repro confirms by contrast (a one-byte unterminated
  buffer does produce it).
- *Is the empty-payload path reachable from the wire, or only by direct API
  misuse?* Reachable. A frontend `Q` message with length field 4 is accepted by
  `Wire.Valid_Typed_Length`, yields `Content_Length = 0`, and
  `Framing.Read_Message` builds `Make_Message ('Q', <1 .. 0>)`.
  `Server_Sessions.Query_Text` (`src/flyology-postgres-server_sessions.adb:471-487`)
  then calls `Read_C_String` with `Cursor = Contents'First = 1` on that empty
  array. The repro drives exactly that call and gets the size-limit message.
  The same applies to `Password_Text`, `SASL_Initial_Response`, and the
  client's SASL mechanism loop (`src/flyology-postgres-client.adb:263`).
- *Does the wrong text reach a peer?* Yes: `Run_Session`'s handler forwards
  `Exception_Message` verbatim into the FATAL `ErrorResponse`
  (`src/flyology-postgres-server.adb:524-531`), so a client that sends an empty
  `Q` is told its string exceeded a size limit.

**Severity:** P2 (unchanged) -- wrong diagnostic. No wrong result and no
unexpected exception type; the rejection itself is correct.

**Repro:** `tests/repros/src/repro_proto_6.adb`

**Output** (`./run.sh repro_proto_6`, exit status 1):

```
  -- protocol.ads:690 -- "@exception Protocol_Error No terminator remains in Source."
  -- empty (1 .. 0) buffer, cursor 1 -> "Postgres string exceeds the configured limit"
  -- one-byte unterminated buffer      -> "unterminated Postgres string"
  ok: an unterminated non-empty buffer reports a missing terminator
  FAILED: an empty buffer reports a missing terminator, not a size-limit violation
  -- Server_Sessions.Query_Text on an empty 'Q' payload -> "Postgres string exceeds the configured limit"
  FAILED: an empty Query payload is diagnosed as an unterminated string, not as exceeding the configured message-size limit
BUG REPRODUCED: 2 failed expectation(s)
```

**Description:** `Protocol.Read_C_String`
(`src/flyology-postgres-protocol.adb:157-161`) bundles an oversized buffer, a
cursor before the buffer, and a cursor past the end of the buffer into one
`Require` whose message is "Postgres string exceeds the configured limit". The
documented condition for this input is the opposite
(`src/flyology-postgres-protocol.ads:690`:
"@exception Protocol_Error No terminator remains in Source"), and the accurate
"unterminated Postgres string" message at `:164` is only reachable when at
least one byte remains. A client that sends a zero-payload `Q`, `p`, or SASL
message therefore receives a FATAL `ErrorResponse` claiming its string exceeded
a 16 MiB limit when the payload was zero bytes long, because
`Run_Session` forwards the exception message verbatim
(`src/flyology-postgres-server.adb:524-531`). Splitting the `Require` into a
size check and an exhaustion check that reports a missing terminator resolves
it without changing which inputs are rejected. `Test_Malformed_String`
(`tests/src/tests.adb:404-422`) does not catch this: it uses a one-byte buffer
and only asserts that some `Protocol_Error` is raised.

---

### PROTO-7: `Maximum_Message_Size` is documented as including the type byte, but `Make_Message` and `Valid_Typed_Length` admit a frame of `Maximum_Message_Size + 1` bytes

**Verdict:** CONFIRMED.

Refutation attempts:

- *Could the doc mean the payload plus length only?* The wording is explicit:
  "Largest complete PostgreSQL wire message accepted by the library, including
  its type byte and encoded length" (`src/flyology-postgres.ads:6-8`), echoed at
  `src/flyology-postgres-protocol.ads:33-34` ("including header bytes"). A
  frame of `1 + 4 + (Max - 4) = Max + 1` bytes contradicts it.
- *Is the bound honoured on the initial-packet path, making this a local
  slip rather than a systematic one?* Yes, which sharpens the finding.
  `Encode_Startup` checks `Length (Contents) + 4 <= Maximum_Message_Size`
  (`src/flyology-postgres-protocol.adb:1261-1263`) and `Valid_Initial_Length`
  requires `Length <= Maximum_Frame_Size` for an untagged packet whose frame
  *is* `Length` bytes -- both exact. The drift is specific to typed messages,
  where the frame is `1 + Length`.
- *Any memory-safety or interop consequence?* None found. Encoder and decoder
  agree with each other (`Make_Message` admits `Max - 4` of payload,
  `Valid_Typed_Length` admits a length field of `Max`, both describing
  `Max + 1` bytes), buffers are sized from the actual length, and 16 MiB is far
  below PostgreSQL's own ~1 GB limit, so no peer rejects the extra byte.

**Severity:** P2 (unchanged) -- an off-by-one in a documented bound, with no
behavioural consequence beyond the documentation being wrong by one byte.

**Repro:** `tests/repros/src/repro_proto_7.adb`

**Output** (`./run.sh repro_proto_7`, exit status 1):

```
  -- Maximum_Message_Size = 16777216; documented as the largest complete message INCLUDING the type byte and the encoded length
  -- Wire.Valid_Typed_Length ( 16777216 ) -> TRUE; that length describes a 16777217-byte frame
  FAILED: a typed length field of Maximum_Message_Size is rejected, because the resulting frame is Maximum_Message_Size + 1 bytes
  ok: a typed length field of Maximum_Message_Size - 1 is still accepted
  -- Make_Message ('d', payload of 16777212 bytes) succeeded; Encode would emit 16777217 bytes
  FAILED: Make_Message rejects a payload whose complete frame would exceed Maximum_Message_Size
  -- the encoded frame would be 1 byte(s) larger than the documented maximum
BUG REPRODUCED: 2 failed expectation(s)
```

The repro covers both directions: the read side (`Wire.Valid_Typed_Length`) and
the write side (`Make_Message` with a real `Maximum_Message_Size - 4` byte
payload, whose accepted `Payload_Length` shows the encoded frame would be
16777217 bytes). The `Max - 1` control case still passes, isolating the failure
to the last admissible value.

**Description (contract drift):** `Maximum_Message_Size`
(`src/flyology-postgres.ads:6-8`) is documented as the largest complete wire
message "including its type byte and encoded length", i.e. a frame bound. On
the typed-message path both ends are one byte loose relative to that:
`Make_Message` (`src/flyology-postgres-protocol.adb:179-181`) admits
`Payload'Length <= Maximum_Message_Size - 4`, and `Encode` (`:222-229`) then
emits `1 + 4 + Payload'Length` = `Maximum_Message_Size + 1` bytes; symmetrically
`Wire.Valid_Typed_Length` (`src/flyology-postgres-wire.ads:319-320`) accepts a
length field of `Maximum_Message_Size`, after which `Framing.Read_Message` reads
`1 + Length` = `Maximum_Message_Size + 1` bytes. The untagged initial-packet
path honours the bound exactly (`Valid_Initial_Length`, and `Encode_Startup`'s
`Length (Contents) + 4 <= Maximum_Message_Size` at
`src/flyology-postgres-protocol.adb:1261-1263`), so the two message families
disagree about what the constant means. There is no memory-safety or interop
effect, since encoder and decoder are consistent with each other; the fix is a
one-byte tightening of the two typed-message checks or a correction to the
constant's documented meaning, and which one is right is a policy call about
the published limit.

---

## Notes on the working tree

`tests/repros/src/repro_proto_1.adb` through `repro_proto_7.adb` are the only
files this verification created. No file under `src/`, `sql/`, `examples/`, or
`tests/src/` was modified, and nothing was committed.

`git status` also shows three modified files under
`sql/tests/config/` (`flyology_postgres_sql_tests_config.{ads,gpr,h}`). These
were not touched by this verification -- the only builds run here were
`tests/repros/repros.gpr`, which depends on `flyology_postgres` and not on the
SQL test crate. They are presumably Alire-regenerated configuration from a
concurrent build in the same worktree.
