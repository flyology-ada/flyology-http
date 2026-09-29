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
