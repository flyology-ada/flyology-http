# Verification: H1-CLIENT

Commit: f078732

Findings examined: 7 (6 from discovery, 1 new). Confirmed: 7. Refuted: 0.
Partial: 0. Other: 0.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| H1-CLIENT-1 | P1 | CONFIRMED | P1 | `flyology-http-http_3_header_policy-repro_h1_client_1` |
| H1-CLIENT-2 | P1 | CONFIRMED | P1 | `repro_h1_client_2` |
| H1-CLIENT-3 | P2 | CONFIRMED | P2 | `repro_h1_client_3` |
| H1-CLIENT-4 | P2 | CONFIRMED | P2 | `repro_h1_client_4` |
| H1-CLIENT-5 | P2 | CONFIRMED | P2 | `repro_h1_client_5` |
| H1-CLIENT-6 | P2 | CONFIRMED | P2 | `repro_h1_client_6` |
| H1-CLIENT-7 | (new) | CONFIRMED | P1 | `repro_h1_client_7` |

Entries below are in the order they were settled; H1-CLIENT-7 sits next to
H1-CLIENT-1 because it was found while measuring H1-CLIENT-1's threshold.

## H1-CLIENT-1: HTTP/1 response `Content-Length` of 2^31 or more is rejected as malformed

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged)
- **Repro:** `tests/repros/src/flyology-http-http_3_header_policy-repro_h1_client_1.adb`,
  run with
  `./tests/repros/run.sh flyology-http-http_3_header_policy-repro_h1_client_1`
  (a child of the private HTTP/3 policy package only so that the HTTP/3
  comparison in Part C is a direct call rather than a claim about code the
  spike cannot reach)
- **Output:**

```
  note Natural'Last is 2147483647; Body_Size'Last is 9223372036854775807
  note 2147483599 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: peer closed before Content-Length was received
  note 2147483647 -> UNEXPECTED CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed
  note 2147483648 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: invalid or overflowing HTTP decimal value
  note 5368709129 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: invalid or overflowing HTTP decimal value
  ok   control: Content-Length 2147483599 is a valid head
  FAIL Content-Length 2147483648 is a valid head
  FAIL Content-Length 5368709129, which this crate's own HTTP/1 server emits, is a valid head
  FAIL Content-Length 9223372036854775807 (Body_Size'Last) is a valid head
  note largest accepted Content-Length is 2147483599
  note smallest rejected Content-Length is 2147483600
  note Natural'Last is 2147483647, so the bound is not Natural'Last
  note HTTP/3 Validate_Response status is VALID
  ok   control: the HTTP/3 response validator accepts Content-Length 5368709129
  ok   control: the HTTP/3 validator keeps the 64-bit value
  FAIL live HTTP/1.1 path: Execute returns the 200 head, got FLYOLOGY.HTTP.PROTOCOL_ERROR: 
checks: 7  failures: 4
BUG REPRODUCED
(exit status 1)
```

- **Measured threshold.** `Natural'Last` on this target is 2 147 483 647, as
  the spike prints rather than assumes. The largest `Content-Length` the
  HTTP/1 response head parser accepts is **2 147 483 599**, and the smallest it
  refuses is **2 147 483 600** — that is, the effective bound is *below*
  `Natural'Last`, not equal to it. The 48 values from 2 147 483 600 to
  2 147 483 647 fail for a second, distinct reason and are recorded separately
  as H1-CLIENT-7. From 2 147 483 648 upward the failure is the one discovery
  described: `Protocol_Error` with the message "invalid or overflowing HTTP
  decimal value", raised by `Parse_Natural`'s guard.
- **Description:** `Flyology.HTTP.Client.HTTP_1_Internals.Parse_Natural`
  (`src/flyology-http-client-http_1_internals.adb:151-168`) returns `Natural`,
  and `Content_Length` (`:170-207`) returns `Natural`, so `Select_Body_Mode`
  (`:466-467`) can only store a `Natural` into `Response_Data.Remaining_Body`
  (`src/flyology-http-client.adb:307`). Any syntactically valid decimal at or
  above 2^31 is therefore refused at the response head, on both the parser
  oracle and the live transport. The live half of the spike drives the real
  `Flyology.HTTP.Client` over loopback against a raw `GNAT`/`Flyology.IO.Sockets`
  peer whose head is `HTTP/1.1 200 OK` + `Content-Length: 5368709129`;
  `Execute` raises `Protocol_Error` (the engine handler at
  `src/flyology-http-client.adb:6006-6008` maps the parse failure to
  `Response_Invalid` and destroys the transport) instead of returning the 200
  head that `tests/http_client_smoke.adb`'s `/short-body` case shows `Execute`
  normally returns before any body byte is read. RFC 9110 section 8.6 says
  "Any Content-Length field value greater than or equal to zero is valid" and
  that "a recipient MUST anticipate potentially large decimal numerals and
  prevent parsing errors due to integer conversion overflows or precision loss
  due to integer conversion". The crate's own contract says the same thing:
  `src/flyology-http.ads:103-106` declares `Body_Size` as the "64-bit-safe"
  shared length type introduced "so message lengths do not depend on the
  implementation range of Natural". Part C of the spike shows the other side
  of that contract working: `Flyology.HTTP.HTTP_3_Header_Policy.Validate_Response`
  — the HTTP/3 client's response header validator — returns `VALID` for the
  identical field value and keeps the 64-bit number
  (`Content_Length = 5_368_709_129`). The HTTP/2 client parses the same field
  into `Long_Long_Integer` (`src/flyology-http-http_2_client_connection.adb:301-304`),
  and the HTTP/2 composable buffer path uses `Body_Size'Value`
  (`src/flyology-http-client.adb:4186`). The value chosen for the live case is
  not hypothetical: `tests/http_smoke.adb:285-296` asserts that this crate's
  own HTTP/1 server puts `Content-Length: 5368709129` on the wire, so a
  Flyology server to Flyology HTTP/1.1 client transfer of a 5 GiB object fails
  at the client's response head. No maintained suite covers 2^31 .. 2^63-1 on
  HTTP/1 (`tests/http_client_parser_matrix.adb:162-165` and
  `tests/corpus/fixtures/h1-content-length-overflow.bin` only cover values no
  64-bit type can hold), and the green baselines in `review/baselines/` are
  server-side or HTTP/2 and HTTP/3 client suites, so none of them exercises
  this HTTP/1 client path.

## H1-CLIENT-7 (new): a `Content-Length` of 2 147 483 600 .. 2 147 483 647 raises `Constraint_Error` out of the HTTP/1 response parser

- **Verdict:** CONFIRMED (new finding, raised while measuring H1-CLIENT-1's
  threshold)
- **Severity:** P1
- **Repro:** `tests/repros/src/repro_h1_client_7.adb`, run with
  `./tests/repros/run.sh repro_h1_client_7`
- **Output:**

```
  note Natural'Last is 2147483647
  note 2147483599 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: peer closed before Content-Length was received
  note 2147483600 -> CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed
  note 2147483647 -> CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed
  note 2147483648 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: invalid or overflowing HTTP decimal value
  note Content-Length values raising a runtime check: 48, from 2147483600 to 2147483647
  ok   control: Content-Length 2147483599 is a valid head
  FAIL Content-Length 2147483600, inside Natural, is a valid head
  FAIL Content-Length 2147483647 (Natural'Last) is a valid head
  FAIL Content-Length 2147483600 does not escape as a runtime check
  ok   control: an out-of-range Content-Length is a typed rejection
  FAIL live HTTP/1.1 path: Content-Length 2147483647 yields the 200 head, got CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed
  FAIL live HTTP/1.1 path: no raw Constraint_Error reaches the caller
checks: 7  failures: 5
BUG REPRODUCED
(exit status 1)
```

- **Description:** `Parse_Natural`
  (`src/flyology-http-client-http_1_internals.adb:151-168`) guards its
  accumulator with the *digit value*

  ```ada
  Result > (Natural'Last - (Character'Pos (Item) - Character'Pos ('0'))) / 10
  ```

  but accumulates with `Character'Pos (Item)` itself:

  ```ada
  Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0');
  ```

  which parses as `((Result * 10) + Character'Pos (Item)) - 48`. The guard
  therefore admits every value up to `Natural'Last`, while the intermediate
  `Result * 10 + Character'Pos (Item)` is an `Integer` expression that is up to
  48 larger than the final value. For the 48 lengths 2 147 483 600 ..
  2 147 483 647 — all of them representable in `Natural`, all of them
  deliberately inside the guard's own bound — the intermediate exceeds
  `Integer'Last` and GNAT's overflow check raises `Constraint_Error` at line
  165. The spike enumerates the neighbourhood 2 147 483 580 .. 2 147 483 660 and
  reports exactly 48 such values, contiguous from 2 147 483 600 to
  2 147 483 647. The crate's release profile
  (`config/flyology_http_config.gpr:14-22`: `-O3 -gnatn -ffunction-sections
  -fdata-sections -gnatW8`) does not pass `-gnatp`, so the check is live in an
  ordinary build; the repro harness uses the same library project. This is
  reachable from the wire, not only from the test oracle: the live half of the
  spike drives `Flyology.HTTP.Client.Execute` against a raw loopback peer that
  answers `Content-Length: 2147483647`, and the caller receives
  `CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow
  check failed` verbatim. The engine's `when Error : others` arm
  (`src/flyology-http-client.adb:6017-6023`) saves the occurrence, releases the
  transport with `Reusable => False`, terminalizes as `Transport_Failed`, and
  `Finish` re-raises the saved occurrence with its original identity
  (`:1736-1742`, `:1781-1787`) — so no pooled transport is poisoned, but the
  application sees a raw language runtime check instead of the documented
  `Protocol_Error` / `Response_Invalid` vocabulary that
  `src/flyology-http-client.ads` and `tests/http-client-conformance.md`
  establish for a bad response. RFC 9110 section 8.6 states the requirement
  this breaks literally: a recipient "MUST anticipate potentially large decimal
  numerals and prevent parsing errors due to integer conversion overflows".
  A 2 GiB object served with an exact `Content-Length` in this 48-value window
  is ordinary valid traffic, so this is an unexpected exception on valid input
  over a reachable path: P1. It is not P0 — no memory unsafety, no
  smuggling, and the transport is destroyed rather than returned to the pool.
  Fixing `Parse_Natural` to accumulate the digit value (and to accumulate in
  `Body_Size`) settles this finding and H1-CLIENT-1 together. No maintained
  test covers this window: `tests/http_client_parser_matrix.adb:162-165` jumps
  straight to a 36-digit value.

## H1-CLIENT-2: a negative `Set_Expect_Continue` wait sends the body immediately

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged)
- **Same defect as CLIENT-POOL-3.** `review/discovery-CLIENT-POOL.md`'s
  CLIENT-POOL-3 names the same statement at the same site
  (`src/flyology-http-client.adb:3768-3782`) and the same `.ads` sentence.
  This is one finding found twice; H1-CLIENT-2 is the primary number and
  CLIENT-POOL-3 should be closed against it. Discovery rated CLIENT-POOL-3 at
  medium confidence; this reproduction settles it.
- **Repro:** `tests/repros/src/repro_h1_client_2.adb`, run with
  `./tests/repros/run.sh repro_h1_client_2`
- **Output:**

```
  note request body is 4096 bytes; the peer withholds 100 Continue for 0.400000000 s; the exchange deadline is 10.0 s
  ok   POSITIVE_WAIT: the exchange completes
  ok   NEGATIVE_WAIT: the exchange completes
  note body bytes seen before 100 Continue, Wait_Timeout =>  1.0: 0
  note body bytes seen before 100 Continue, Wait_Timeout => -1.0: 4096
  ok   control: a positive wait sends no body before 100 Continue
  FAIL a negative wait sends no body before 100 Continue, because it waits within the whole exchange deadline
checks: 4  failures: 1
BUG REPRODUCED
(exit status 1)
```

- **Description:** `src/flyology-http-client.ads:217-226` documents
  `Set_Expect_Continue`'s `Wait_Timeout` as "A positive wait expiry with no
  partial response sends the body; a negative value waits within the whole
  exchange deadline and zero sends immediately after the head."
  `Probe_Early_Response` (`src/flyology-http-client.adb:3767-3782`) arms the
  continue wait through `Flyology.Operations.Drivers.Arm_Deadline` with either
  `Duration'Min (Continue_Wait, Remaining (State.Deadline))` or `Continue_Wait`
  itself, and neither expression treats a negative value specially.
  `Set_Expect_Continue` (`:2217-2224`) stores `Wait_Timeout` unchanged, and
  nothing between it and the probe normalizes it. I read the pinned runtime
  rather than assuming: `flyology = "=0.1.1-dev"` resolves to
  `~/.local/share/alire/releases/flyology_6f91b1af`, whose
  `src/flyology-operations-drivers.ads:58-63` says "Set or replace one
  operation deadline. A nonpositive interval is due on the next completion-set
  drive", and whose body (`.adb:80-91`) implements exactly that:
  `Deadline := (if Interval <= 0.0 then Now elsif ...)`. So the next drive
  arrives with `Event = Deadline_Reached`, the `and then Event /=
  Flyology.Operations.Deadline_Reached` guard fails, the `else` arm clears
  `Expect_Waiting` and resumes the body, and the negative value behaves
  identically to zero. The spike drives the real client over loopback against
  a raw peer that withholds its `100 Continue` for 0.4 s while watching the
  socket: with `Wait_Timeout => 1.0` the peer sees **0** body bytes before it
  answers, and with `Wait_Timeout => -1.0` it sees all **4096**. A server that
  would have rejected the request on the head alone (401, 413, 417) therefore
  receives the whole body, which is what the caller opted out of. The wire
  behaviour is legal — RFC 9110 section 10.1.1 lets a client send the content
  after any wait — so the violated text is the `.ads` contract, which is what
  makes this P1 rather than P0. `tests/http_client_upload_controls_smoke.adb`
  covers `1.0`, `0.02` and the default; no maintained test passes a negative
  wait, so the documented branch is unexercised.
> **Correction.** `flyology_6f91b1af` is the pinned **`flyology_allocators`**
> crate, not the runtime. `alire/alire.lock` resolves `flyology = bd95746d`,
> `flyology_allocators = 6f91b1af`, `flyology_cachelines = 8e046108`,
> `flyology_quic = eb09a80a`. The quoted `Arm_Deadline` sentence is word for word
> identical in the correct release, so the finding is unaffected; only the path
> above is wrong. The filed issue cites `bd95746d` and needs no change.

## H1-CLIENT-3: an HTTP/1.0 response carrying both `close` and `keep-alive` is returned to the pool

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_h1_client_3.adb`, run with
  `./tests/repros/run.sh repro_h1_client_3`
- **Output:**

```
  note HTTP/1.0 'keep-alive'        -> Reusable_Transports = 1
  note HTTP/1.1 'keep-alive, close' -> Reusable_Transports = 0
  note HTTP/1.0 'keep-alive, close' -> Reusable_Transports = 1
  ok   control: HTTP/1.0 with a lone keep-alive is pooled
  ok   control: HTTP/1.1 with close present is not pooled
  FAIL HTTP/1.0 with close present is not pooled (RFC 9112 9.3 evaluates close first)
checks: 3  failures: 1
BUG REPRODUCED
(exit status 1)
```

- **Description:** `Select_Body_Mode`
  (`src/flyology-http-client-http_1_internals.adb:410-418`) computes
  `Data.Reusable := (if Data.Version_Value = HTTP_1_1 then not Close_Token
  else Keep_Token)`. Both tokens are collected, but on the HTTP/1.0 arm only
  `Keep_Token` is consulted, so `Connection: keep-alive, close` on an HTTP/1.0
  response leaves the transport in the pool as idle and reusable. RFC 9112
  section 9.3 orders the test the other way and does not condition the first
  step on the version: "If the 'close' connection option is present
  (Section 9.6), the connection will not persist after the current response;
  else, * If the received protocol is HTTP/1.1 (or later), the connection will
  persist after the current response; else, * If the received protocol is
  HTTP/1.0, the 'keep-alive' connection option is present ... the connection
  will persist after the current response". The spike serves three exchanges
  from one raw peer, each on its own client, and reads
  `Diagnostics (Item).Reusable_Transports` immediately after the body
  completes. Both controls behave correctly (HTTP/1.0 with a lone
  `keep-alive` is pooled; HTTP/1.1 with `close` present is not), and only the
  HTTP/1.0-with-both case leaves a reusable transport behind after the peer
  has closed the socket. The onward impact is what bounds the severity: the
  next checkout of that slot sets `Verify` from `Undelivered_Framing`, which
  is `False` here, so a non-idempotent request is written onto a closed socket
  and fails, while a safe or idempotent one is replayed once by the stale-lease
  recovery. Needing a response that carries both options keeps this at P2; I
  did not find a stock server that emits them either, and this is not verified
  against a peer. `tests/http_client_pool_model.adb:196-201` covers HTTP/1.0
  with a lone `keep-alive` and `tests/http_client_smoke.adb:428,462` covers
  HTTP/1.0 with no `Connection` field, so the combination is uncovered.

## H1-CLIENT-4: response heads of 16383-16384 bytes pass the parser oracle and are rejected on the live path

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_h1_client_4.adb`, run with
  `./tests/repros/run.sh repro_h1_client_4`
- **Output:**

```
  note Default_Max_Bytes is 16384
  note H_16382: head length 16382, wire bytes 16384
  note H_16383: head length 16383, wire bytes 16385
  note H_16384: head length 16384, wire bytes 16386
  note H_16382: oracle accepted, live status 200
  ok   H_16382: the parser oracle accepts the head
  ok   H_16382: the live transport accepts the same head
  note H_16383: oracle accepted, live FLYOLOGY.HTTP.CLIENT.RESPONSE_TOO_LARGE
  ok   H_16383: the parser oracle accepts the head
  FAIL H_16383: the live transport accepts the same head
  note H_16384: oracle accepted, live FLYOLOGY.HTTP.CLIENT.RESPONSE_TOO_LARGE
  ok   H_16384: the parser oracle accepts the head
  FAIL H_16384: the live transport accepts the same head
checks: 6  failures: 2
BUG REPRODUCED
(exit status 1)
```

- **Description:** `Parse_Available_Final_Head`
  (`src/flyology-http-client-http_1_internals.adb:363-381`) applies two
  different comparisons to the same 16 KiB bound. The post-terminator check is
  `Head_Last - Text'First + 1 > Default_Max_Bytes`, which accepts a head of
  exactly 16384 bytes; the pre-terminator check is `Text'Length >=
  Default_Max_Bytes`, which fires as soon as 16384 bytes are buffered without
  the terminating `CRLF CRLF` yet present. `Validate_Response` (`:511-528`)
  contains the same two checks but always sees the whole message at once, so
  only the second ever applies there. The spike uses the parser matrix's own
  construction (`tests/http_client_parser_matrix.adb:117-122`,
  `Head_Prefix & 'a'*Exact_Value_Length & Head_Suffix & CRLF`) and drives it
  both ways. The raw peer writes the response head in two pieces split at
  8192 bytes — exactly what an ordinary kernel delivery does against the
  client's `Receive_Buffer_Size : constant Positive := 8 * 1_024`
  (`src/flyology-http-client.adb:65`) — so the reproduction needs no
  test-only receive cap and no reliance on segmentation luck. Head lengths
  16383 and 16384 are accepted by the oracle and raise
  `Flyology.HTTP.Client.Response_Too_Large` on the live path; 16382, the
  largest head that survives both, is the control and passes both ways. So
  `tests/http_client_parser_matrix.adb:201-203` records an "exact" boundary at
  `Default_Max_Bytes` that the transport path does not honour for the last two
  bytes of the range. No standard is at issue — this is a documented bound —
  and it takes a head within two bytes of the limit, which keeps it at P2.
  The live outcome also depends on segmentation: a head delivered in one piece
  would pass, so the failure is nondeterministic between links, which is worth
  saying in the fix.

## H1-CLIENT-5: a composable buffer exchange drains an over-capacity body with no byte bound

- **Verdict:** CONFIRMED (mechanism and measurement; see the severity note)
- **Severity:** P2 (discovery said P2; unchanged). Discovery recorded medium
  confidence and asked whether something upstream bounds the drain. **It does
  not.** The only bounds are the caller's own exchange deadline and whatever
  length the peer declared.
- **Repro:** `tests/repros/src/repro_h1_client_5.adb`, run with
  `./tests/repros/run.sh repro_h1_client_5`
- **Output:**

```
  note destination capacity is 4096 bytes; the response declares 8388608 body bytes
  note exchange result is RESPONSE_BODY_TOO_LARGE
  ok   control: the typed result is Response_Body_Too_Large
  note response body bytes the peer managed to write: 8388608 of 8388608
  FAIL the client does not consume the whole over-capacity body it has already decided to discard
checks: 2  failures: 1
BUG REPRODUCED
(exit status 1)
```

- **Description:** `Receive_Head` (`src/flyology-http-client.adb:4013-4025`)
  sets `State.Pending_Result := Response_Body_Too_Large` the moment a known
  `Content-Length` exceeds the destination capacity, and `Deliver` (`:3868-3869`)
  then discards every slice. `Receive_Content_Step` (`:4042-4062`) nevertheless
  keeps calling `Receive_One` until the framing completes; no code path
  consults `Pending_Result` to abandon the transport early. The spike measures
  it: a 4096-byte destination against a response declaring 8 388 608 body
  bytes, and the raw peer succeeds in writing **all 8 388 608** of them — 2048
  times the destination capacity — before the exchange terminalizes. The
  repository answers the same question the other way on both sibling paths:
  `Drain` stops at `Max_Redirect_Drain_Bytes : constant Natural := 64 * 1_024`
  and destroys the transport, with the comment "Past this bound the transport
  costs more than it saves and is destroyed instead" (`:67-70`, `:6383-6406`),
  and `Read_All` calls `Abandon_Response` on the first overflow (`:7255-7267`).
  What keeps this at P2 rather than higher: the typed result is correct
  (`Response_Body_Too_Large` with `Required_Body_Length` set), the buffer is
  left empty, and `src/flyology-http-client.ads:695` documents only "Bounded
  response destination overflowed" — no `.ads` sentence promises when the
  exchange terminalizes, so no documented contract is broken. It is not P0
  either: there is no amplification, because a peer must actually transmit
  every byte the client discards, and the caller's own deadline bounds the
  exposure. For a `Fixed_Body` the drain is bounded by the declared
  `Content-Length`, as measured; for `Chunked_Body` and `Until_Close_Body` no
  length is declared, so the same loop is bounded only by the deadline — that
  part is from reading `Consume_Available_Content`
  (`src/flyology-http-client-http_1_internals.adb:937-1000`), not measured.
  Choosing the bound is a policy decision for the maintainer under
  `.claude/rules/decision-authority.md`, not something this review should
  invent; the obvious candidate is the existing `Max_Redirect_Drain_Bytes`
  rationale. `tests/corpus/http-client-scenarios.json:131-136` and
  `tests/http_client_composable_smoke.adb:573` assert the typed result on a
  40-byte overrun, which finishes instantly either way, so nothing measures
  bytes drained after the overflow decision.

## H1-CLIENT-6: `Validate_Response` raises `Constraint_Error` for chunk sizes 7FFFFFFE and 7FFFFFFF (fuzz oracle only)

- **Verdict:** CONFIRMED, including the scope claim
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_h1_client_6.adb`, run with
  `./tests/repros/run.sh repro_h1_client_6`
- **Output:**

```
  note Natural'Last is 2147483647 = 16#7FFFFFFF#
  note arbiter 7FFFFFF0 -> consumed
  note arbiter 7FFFFFFE -> CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:585 overflow check failed
  note arbiter 7FFFFFFF -> CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:585 overflow check failed
  note arbiter 80000000 -> consumed
  ok   control: chunk size 7FFFFFF0 is a documented rejection
  ok   control: chunk size 80000000 is a documented size rejection
  FAIL chunk size 7FFFFFFE is a documented rejection, not a crash
  FAIL chunk size 7FFFFFFF is a documented rejection, not a crash
  note live production decoder on the same bytes -> FLYOLOGY.HTTP.PROTOCOL_ERROR
  ok   scope: the production decoder rejects the same bytes with a typed Protocol_Error
checks: 5  failures: 2
BUG REPRODUCED
(exit status 1)
```

- **Description:** `Validate_Response`'s chunked branch
  (`src/flyology-http-client-http_1_internals.adb:585-587`) evaluates
  `Length (Data.Pending) < Size + CRLF'Length` with `Size : Natural`.
  `Chunk_Size` (`:763-801`) admits any value up to `Natural'Last`, so for the
  two chunk sizes `7FFFFFFE` and `7FFFFFFF` the `Integer` intermediate
  `Size + 2` overflows and the overflow check raises `Constraint_Error`
  instead of the `Protocol_Error "incomplete HTTP chunk data"` that
  `7FFFFFF0` produces. Both are legal `chunk-size = 1*HEXDIG` under RFC 9112
  section 7.1, which also states that "recipients MUST anticipate potentially
  large hexadecimal numerals and prevent parsing errors due to integer
  conversion overflows or precision loss due to integer representation". The
  spike calls `Flyology.HTTP.Client.Testing.Fuzz_Response` — the wrapper
  `tests/http-client-conformance.md:99-104` designates as the arbiter, where
  "Documented protocol and size rejections are normal outcomes; assertion
  failures, runtime checks, hangs, and other exceptions remain crashes" — with
  a padded 1000-byte input, exactly as a campaign would, and the
  `Constraint_Error` escapes it. A GNATfuzz or mutation campaign would
  therefore record a crash the production decoder cannot exhibit.
  **The scope claim holds and is now measured rather than argued:** the spike
  serves the same bytes from a raw loopback peer and the production decoder
  answers `FLYOLOGY.HTTP.PROTOCOL_ERROR`, not `Constraint_Error`, because
  `Consume_Available_Content` (`:937-1000`) and `Read_Response_Body`
  (`:1090-1150`) only assign `Chunk_Remaining := Chunk_Size (...)` and pass it
  to `Copy_Pending` as a `Limit` that is reduced by `Natural'Min`, never
  adding to it. That containment to a test oracle is what keeps this at P2:
  it degrades a fuzzing oracle, not a user-reachable path.

## Summary

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| H1-CLIENT-1 | P1 | CONFIRMED | P1 | `flyology-http-http_3_header_policy-repro_h1_client_1` |
| H1-CLIENT-2 | P1 | CONFIRMED | P1 | `repro_h1_client_2` |
| H1-CLIENT-3 | P2 | CONFIRMED | P2 | `repro_h1_client_3` |
| H1-CLIENT-4 | P2 | CONFIRMED | P2 | `repro_h1_client_4` |
| H1-CLIENT-5 | P2 | CONFIRMED | P2 | `repro_h1_client_5` |
| H1-CLIENT-6 | P2 | CONFIRMED | P2 | `repro_h1_client_6` |
| H1-CLIENT-7 | (new) | CONFIRMED | P1 | `repro_h1_client_7` |

Findings examined: 7 (6 from discovery, 1 new). Confirmed: 7. Refuted: 0.
Partial: 0. Other: 0.

### Notes carried forward

- **H1-CLIENT-2 and CLIENT-POOL-3 are one finding.** Same statement, same
  `.ads` sentence, same fix. Close CLIENT-POOL-3 against H1-CLIENT-2.
- **H1-CLIENT-1, H1-CLIENT-7 and H1-CLIENT-1's chunk sub-item share one fix
  site.** Widening the HTTP/1 length arithmetic to `Body_Size` and accumulating
  the digit value rather than `Character'Pos (Item)` settles all three, and
  widening `Chunk_Size` the same way settles H1-CLIENT-6 as well. Changing
  `Remaining_Body` and `Chunk_Remaining` from `Natural` to `Body_Size` is a
  visible-type decision in the sense of `.claude/rules/ada-interface-values.md`
  only inside the private `Response_Data` record, so it needs no new public
  constant; the public contract already exists as
  `Flyology.HTTP.Body_Size`.
- **H1-CLIENT-1's chunk sub-item is confirmed in passing.** `Chunk_Size`
  returns `Natural`, so a single chunk of `80000000` or more is rejected with
  `Protocol_Error "overflowing HTTP chunk size"` — the
  `arbiter 80000000 -> consumed` line of `repro_h1_client_6` is that rejection
  being consumed as documented. RFC 9112 section 7.1 carries the same MUST as
  section 8.6. P2 on its own: a single chunk of 2 GiB or more is not something
  a stock server emits, and this is not verified against a peer.
- **Why the green baselines do not cover any of this.** `review/baselines/`
  holds h2spec and Autobahn against the *server*, HTTP/3 interop in both roles,
  and an Ada-versus-PycURL *client* differential. H1-CLIENT-1, -4, -5, -6 and
  -7 are HTTP/1 *client* response-parsing paths at sizes no differential run
  exercises (2 GiB and 5 GiB lengths, a head within two bytes of 16 KiB, an
  8 MiB over-capacity body, a 2 GiB chunk size); H1-CLIENT-2 needs a negative
  `Wait_Timeout` that no suite passes; H1-CLIENT-3 needs a response carrying
  both `Connection` options, which no stock peer emits.
- **Harness self-tests.** `./tests/repros/run.sh seam_check` and
  `./tests/repros/run.sh repro_smoke` both PASS at the end of this work
  (exit 0), so the verdicts above are not an artefact of a broken harness.
- **Port binding.** Every spike binds `Sockets.Loopback_IPv4` with
  `Sockets.Any_Port` and reads the assigned port back through
  `Get_Socket_Name`, which is the maintained pattern in
  `tests/http_client_fragmentation.adb` and the same kernel-assigned mechanism
  `Repro_Support.Ephemeral_Port` implements, without its close-then-rebind
  window. No spike binds a fixed port.
