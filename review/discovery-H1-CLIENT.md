# Discovery: H1-CLIENT

Scope (files read, with line counts; ranges given where a file was read in part):

- `src/flyology-http-client-http_1_internals.adb` (1181, whole)
- `src/flyology-http-client.ads` (1402, whole)
- `src/flyology-http-client.adb` (7406; read 50-135, 286-530, 551-694, 694-1412,
  1972-2270, 2568-2745, 3086-3200, 3468-3508, 3500-3860, 3864-4064, 5429-5500,
  5655-5720, 5997-6040, 6383-6600, 6881-7300, 7369-7406, plus grep of the rest)
- `src/flyology-http_chunk_encoding.ads` (18) / `.adb` (47), whole
- `src/flyology-http-headers.ads` (89) / `.adb` (105), whole
- `src/flyology-http-methods.ads` (27), whole
- `src/flyology-http.ads` (1-130), `src/flyology-http.adb` (1-162)
- `src/flyology-http-client_policy.ads` (217) / `.adb` (111), whole
- `src/flyology-http-client-testing.adb` (34), whole
- `src/flyology-http-client-pool_controller.adb` (150-220, 365-480 only; the pool is
  another reviewer's area, read only for the `Verify` handshake)
- `src/flyology-http-http_2_client_connection.adb` (grep only, for the Content-Length
  width comparison)
- Tests: `tests/http_client_rfc_seeds.adb` (259, whole), `tests/http_client_parser_matrix.adb`
  (209, 100-209), `tests/http-client-conformance.md` (118, whole), `tests/http_client_audit.adb`
  (header and finding-18 section), `tests/http_client_smoke.adb` (268-290, 420-510),
  `tests/http_client_upload_controls_smoke.adb` (grep), `tests/http_client_composable_stale_reuse.adb`
  (1-60), `tests/http_client_parser_randomized.adb` (grep), `tests/http_client_pool_model.adb` (grep),
  `tests/corpus/http-client-scenarios.json` (grep), `tests/corpus/fixtures/h1-content-length-overflow.bin`,
  `tests/corpus/fixtures/h1-invalid-chunk-size.bin`
- Pinned dependency: `~/.local/share/alire/releases/flyology_6f91b1af` (flyology 0.1.1-dev),
  `src/flyology-operations-drivers.ads:58-63` and `.adb:86` (for the `Arm_Deadline` contract only)
- Prior audit: findings 6, 18, 36 and the client parts of the three appendices
> **Correction.** `flyology_6f91b1af` is the pinned **`flyology_allocators`**
> crate, not the runtime. `alire/alire.lock` resolves `flyology = bd95746d`,
> `flyology_allocators = 6f91b1af`, `flyology_cachelines = 8e046108`,
> `flyology_quic = eb09a80a`. The quoted `Arm_Deadline` sentence is word for word
> identical in the correct release, so the finding is unaffected; only the path
> above is wrong. The filed issue cites `bd95746d` and needs no change.

Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

Read-only: no file other than this report was created or modified. No build or test
was run; every claim below is from reading.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| H1-CLIENT-1 | HTTP/1 response `Content-Length` of 2^31 or more is rejected as malformed; HTTP/2 and HTTP/3 accept 64-bit lengths | P1 | high |
| H1-CLIENT-2 | A negative `Set_Expect_Continue` wait sends the body immediately instead of waiting within the whole-exchange deadline | P1 | high |
| H1-CLIENT-3 | An HTTP/1.0 response carrying both `close` and `keep-alive` connection options is returned to the pool | P2 | high |
| H1-CLIENT-4 | Response heads of 16383-16384 bytes are accepted by the parser oracle but rejected on the live transport path | P2 | high |
| H1-CLIENT-5 | A composable buffer exchange drains an over-capacity response body with no byte bound | P2 | medium |
| H1-CLIENT-6 | `Validate_Response` overflows on a chunk size of `7FFFFFFE`/`7FFFFFFF`, escaping the fuzz oracle as `Constraint_Error` (test oracle only) | P2 | high |

Prior findings 6, 18 and 36 were re-traced at f078732 and have not regressed (see
"Areas reviewed with no findings").

## Findings

### H1-CLIENT-1: HTTP/1 response `Content-Length` of 2^31 or more is rejected as malformed

- **Location:** `src/flyology-http-client-http_1_internals.adb:151-168` (`Parse_Natural`),
  `:170-207` (`Content_Length`), consumed at `:466-467` (`Select_Body_Mode`) and stored in
  `src/flyology-http-client.adb:307` (`Remaining_Body : Natural`); widened only at
  `src/flyology-http-client.adb:4020-4022` (`Body_Size (State.Metadata.Remaining_Body)`).
  Compare the HTTP/2 path `src/flyology-http-http_2_client_connection.adb:301-304`
  (`Parse_Content_Length ... Value : out Long_Long_Integer`) and the HTTP/3 path
  `src/flyology-http-client.adb:4807` (`Required := Body_Size'Value (Text)`).
- **Severity:** P1
- **Confidence:** high
- **Evidence:**

```ada
   function Parse_Natural (Value : String) return Natural is
      Result : Natural := 0;
   begin
      if Value = "" then
         raise Protocol_Error with "empty HTTP decimal value";
      end if;
      for Item of Value loop
         if Item not in '0' .. '9'
           or else Result >
             (Natural'Last - (Character'Pos (Item) - Character'Pos ('0'))) / 10
         then
            raise Protocol_Error with
              "invalid or overflowing HTTP decimal value";
         end if;
         Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0');
      end loop;
      return Result;
   end Parse_Natural;
```

`src/flyology-http-client.adb:307`:

```ada
      Remaining_Body : Natural := 0;
```

The shared type this repository introduced for exactly this purpose,
`src/flyology-http.ads:103-106`:

```ada
   --  Nonnegative protocol representation byte count. This 64-bit-safe type
   --  is shared by clients and servers so message lengths do not depend on
   --  the implementation range of Natural.
   subtype Body_Size is Long_Long_Integer range 0 .. Long_Long_Integer'Last;
```

`Natural'Last` is 2_147_483_647 on every GNAT target this crate builds on, so the
overflow guard rejects any syntactically valid `Content-Length` of 2^31 or more with the
diagnostic "invalid or overflowing HTTP decimal value". The same head is accepted by the
HTTP/2 and HTTP/3 client paths, which parse into `Long_Long_Integer`/`Body_Size`.
`CHANGELOG.md` (0.1.1, "Changed") states the type was "carried it through client and
server length, limit, routing, logging, and metrics APIs", and the server does emit
such lengths (`tests/http_smoke.adb:295` asserts `Content-Length: 5368709129` on the
wire), so a Flyology server to Flyology HTTP/1.1 client transfer of a 5 GiB object
fails at the client's response head.

- **Failure scenario:**
  1. An application configures an `HTTP_1_Only` client (the default `Configure`
     overloads) and calls `Execute` with a `GET` for a large object.
  2. Any stock origin (nginx, Apache, S3, or a Flyology server using the exact
     fixed-length stream added in 0.1.2) answers
     `HTTP/1.1 200 OK\r\nContent-Length: 3221225472\r\n\r\n` followed by the body.
  3. `Receive_Head` -> `Parse_Available_Final_Head` -> `Select_Body_Mode` ->
     `Content_Length` -> `Parse_Natural` raises `Protocol_Error`; the engine's handler
     (`src/flyology-http-client.adb:6006-6008`) maps it to `Response_Invalid`, the
     transport is destroyed, and `Execute` raises `Protocol_Error` for a valid response.
  4. `Read_Body` streams without a size cap and would have handled the body; only the
     head parse and the `Natural` countdown are narrow.
  The same applies to `Exchange_To_Buffer`/`Exchange_To_Sink` (typed `Response_Invalid`)
  and to the SSE client on HTTP/1.1, which shares this parser.
- **Reproduction test sketch:** through the existing parser oracle:
  `Flyology.HTTP.Client.Testing.Validate_Response (Bytes ("HTTP/1.1 200 OK" & CRLF &
  "Content-Length: 2147483648" & CRLF & CRLF))`. Expected: `Protocol_Error` whose message
  is "peer closed before Content-Length was received" (the head is valid and the body is
  absent), exactly as `Content-Length: 2147483647` produces. Actual: `Protocol_Error`
  "invalid or overflowing HTTP decimal value" raised from the head. Through a scripted
  peer (as in `tests/http_client_smoke.adb`): send the head above, then `Status (Reply)`
  is expected to be 200 with `Body_Complete = False`; actual: `Execute` raises.
- **Existing coverage:** `tests/http_client_parser_matrix.adb:162-165` (a 36-digit value) and
  `tests/corpus/fixtures/h1-content-length-overflow.bin` (`184467440737095516160`, above
  2^64, expected `response-invalid` for h1/h2/h3 at
  `tests/corpus/http-client-scenarios.json:403-406`) assert rejection only of lengths that
  no 64-bit representation can hold. No test exercises 2^31 .. 2^63-1 on HTTP/1. No test
  pins the wrong behaviour; the range is simply uncovered.
- **Standard:** RFC 9110 section 8.6 (`Content-Length = 1*DIGIT`; "Any Content-Length
  field value greater than or equal to zero is valid"; a recipient "MUST anticipate
  potentially large decimal numerals and prevent parsing errors due to integer
  conversion overflows"). RFC 9112 section 6.3 items 5-6. Contract: the `Body_Size`
  declaration comment quoted above.
- **Related sub-item (P2, same root cause):** `Chunk_Size` (`:763-802`) also returns
  `Natural`, so a single chunk of 2^31 bytes or more (`80000000` and up, legal under
  RFC 9112 section 7.1 `chunk-size = 1*HEXDIG`) is rejected as "overflowing HTTP chunk
  size". Unusual on real servers, so P2 on its own.

### H1-CLIENT-2: A negative `Set_Expect_Continue` wait sends the body immediately

- **Location:** `src/flyology-http-client.adb:3767-3792` (`Probe_Early_Response`, `Need_Read`
  branch); contract at `src/flyology-http-client.ads:217-226`; runtime contract in the
  pinned dependency `flyology_6f91b1af/src/flyology-operations-drivers.ads:58-63`.
- **Severity:** P1 (documented `.ads` contract violated on a reachable public path)
- **Confidence:** high
- **Evidence:**

`src/flyology-http-client.ads:217-226` (the promise):

```ada
   --  Enable or disable the Expect: 100-continue handshake. When enabled for
   --  a nonempty retained or streaming body, Execute sends the request head
   --  first and waits up to Wait_Timeout for 100 Continue or a final response.
   --  A positive wait expiry with no partial response sends the body; a
   --  negative value waits within the whole exchange deadline and zero sends
   --  immediately after the head.
```

`src/flyology-http-client.adb:3767-3792` (the behaviour):

```ada
            when Connection_Drivers.Need_Read =>
               if State.Expect_Waiting
                 and then Event /= Flyology.Operations.Deadline_Reached
               then
                  Connection_Drivers.Arm_Transport
                    (State.IO, Item, Connection_Drivers.Need_Read);
                  if State.Deadline.Is_Limited then
                     Flyology.Operations.Drivers.Arm_Deadline
                       (Item,
                        Duration'Min
                          (State.Request_Item.Continue_Wait,
                           Remaining (State.Deadline)));
                  else
                     Flyology.Operations.Drivers.Arm_Deadline
                       (Item, State.Request_Item.Continue_Wait);
                  end if;
               else
                  State.Expect_Waiting := False;
                  State.Metadata.Request_Incomplete := False;
                  State.Driver_State := State.Resume_After_Probe;
```

Pinned runtime `flyology-operations-drivers.ads:58-63` (identical text in the released
0.1.1 and in the 0.1.1-dev revision this manifest pins):

```ada
   --  Set or replace one operation deadline. A nonpositive interval is due on
   --  the next completion-set drive. A deadline can coexist with readiness.
   --  @param Item Pending operation whose deadline changes
   --  @param Interval Relative monotonic interval in seconds
   --  @exception Operation_Error Item is stale or terminal
   procedure Arm_Deadline (Item : in out Operation'Class; Interval : Duration);
```

With `Continue_Wait < 0.0`, `Duration'Min (Continue_Wait, Remaining (...))` is
`Continue_Wait` itself (negative), and the unlimited branch passes the negative value
directly. A nonpositive interval is due on the next drive, so the very next drive
arrives with `Event = Deadline_Reached`, takes the `else` branch, clears
`Expect_Waiting`, and transmits the body. Nothing in `Set_Expect_Continue`
(`:2217-2224`), `Start_Exchange`, or `Send_Head` (`:3508-3540`) handles the negative case
differently from zero. The negative value therefore behaves as "zero sends immediately",
not as "waits within the whole exchange deadline".

- **Failure scenario:**
  1. Application: `Set_Expect_Continue (R, Wait_Timeout => -1.0)`, `Set_Body (R, 1 MiB)`,
     `Execute (C, R, Timeout => 30.0)` on an `HTTP_1_Only` client.
  2. `Send_Head` writes the head with `Expect: 100-continue`, sets `Expect_Waiting`,
     enters `Probing_Early_Response`.
  3. `Probe_Early_Response` sees `Need_Read` (the server has not answered yet) and arms a
     deadline of -1.0 s.
  4. The next completion-set drive is `Deadline_Reached`; the probe takes the `else`
     branch and the 1 MiB body is written at once. A server that would have answered
     `401`/`413`/`417` on the head alone now receives the whole body, which is precisely
     what the caller opted out of by choosing the negative value.
  No pool desynchronisation follows (the body is sent in full, so
  `Request_Incomplete` is correctly `False`); the defect is functional.
- **Reproduction test sketch:** scripted peer in the style of
  `tests/http_client_upload_controls_smoke.adb:472-530`: read the request head, sleep
  200 ms, then send `HTTP/1.1 100 Continue\r\n\r\n`, then read the body and answer 200.
  With `Wait_Timeout => -1.0`, expected: no body byte reaches the peer before it sends
  the `100`. Actual: the body arrives immediately after the head (the peer's post-head
  read returns body bytes before it writes the `100`).
- **Existing coverage:** `tests/http_client_upload_controls_smoke.adb:472,488,526`
  (`Wait_Timeout => 1.0`), `:510` (`0.02`, the "bounded continue fallback" row of
  `tests/http-client-conformance.md`), `:657` (default), `tests/http_client_audit.adb:411,455`
  (`1.0`). No test uses a negative wait, so the documented branch is unexercised.
- **Standard:** RFC 9110 section 10.1.1 permits a client to send the content after any
  wait, so the wire behaviour is legal; the violated text is the `.ads` contract quoted
  above.

### H1-CLIENT-3: An HTTP/1.0 response carrying both `close` and `keep-alive` is pooled

- **Location:** `src/flyology-http-client-http_1_internals.adb:410-418` (`Select_Body_Mode`).
- **Severity:** P2 (protocol rule broken on unusual input; impact bounded by the stale-lease
  recovery)
- **Confidence:** high on mechanism; medium on impact (I cannot name a stock server that
  emits both options)
- **Evidence:**

```ada
      Close_Token : constant Boolean := Header_Has_Token
        (Data.Fields, "Connection", "close");
      Keep_Token : constant Boolean := Header_Has_Token
        (Data.Fields, "Connection", "keep-alive");
      Undelivered_Framing : Boolean := False;
   begin
      Data.Reusable :=
        (if Data.Version_Value = HTTP_1_1
         then not Close_Token else Keep_Token);
```

For `HTTP_1_0` the expression consults only `Keep_Token`; `Close_Token` is ignored.
`Connection: keep-alive, close` (or two `Connection` lines) on an HTTP/1.0 response
therefore yields `Reusable = True`, although RFC 9112 section 9.3 evaluates `close`
first and unconditionally.

- **Failure scenario:**
  1. `HTTP_1_Only` client; an HTTP/1.0 origin or intermediary answers
     `HTTP/1.0 200 OK\r\nConnection: keep-alive, close\r\nContent-Length: 2\r\n\r\nok`
     and closes the socket, as the `close` option announces.
  2. `Select_Body_Mode` marks the transport reusable; after the two-byte body
     `Read_Response_Body` (`:1066-1071`) returns the lease idle.
  3. The next `Execute` on the client checks the idle slot out (`Verify` is `False`
     because no framing was undelivered), writes the request onto the closed socket.
     For a safe or idempotent method the stale-lease recovery replays it once; for a
     `POST`, `Send_Bytes`/`Receive_Head` observe `Peer_Closed` and the caller gets
     `Flyology.IO.Device_Error` or `Protocol_Error` for a request the server never saw.
- **Reproduction test sketch:** scripted peer as above, two exchanges, no
  `Accept_Peer` between them. Expected after the first response:
  `Diagnostics (C).Transports_Closed = 1` and `Reusable_Transports = 0`. Actual:
  `Reusable_Transports = 1`. Alternatively assert that the second (non-idempotent)
  request is served on a fresh connection (a second `Accept_Peer` succeeds) rather than
  raising.
- **Existing coverage:** `tests/http_client_pool_model.adb:196-201` (HTTP/1.0 with a
  lone `keep-alive`), `tests/http_client_smoke.adb:428,462` (HTTP/1.0 with no
  `Connection` field, close-delimited). None sends both options.
- **Standard:** RFC 9112 section 9.3: "If the 'close' connection option is present
  (Section 9.6), the connection will not persist after the current response; else, ...
  If the received protocol is HTTP/1.0, the 'keep-alive' connection option is present
  ... the connection will persist"; section 9.6.

### H1-CLIENT-4: Heads of 16383-16384 bytes are accepted by the oracle but rejected on the live path

- **Location:** `src/flyology-http-client-http_1_internals.adb:363-381`
  (`Parse_Available_Final_Head`) and `:511-528` (`Validate_Response`, same logic);
  receive granularity at `src/flyology-http-client.adb:65` (`Receive_Buffer_Size := 8 * 1_024`),
  `:3801-3846` (`Receive_One`) and `:73-74` (`Receive_More`).
- **Severity:** P2 (wrong exception for a head within the documented bound; needs a head
  within two bytes of the limit)
- **Confidence:** high
- **Evidence:**

```ada
            Text : constant String := To_String (Data.Pending);
            Mark : constant Natural := Ada.Strings.Fixed.Index
              (Text, CRLF & CRLF);
         begin
            if Mark = 0 then
               if Text'Length >= Flyology.HTTP.Headers.Default_Max_Bytes then
                  raise Response_Too_Large;
               end if;
               return;
            end if;

            declare
               Head_Last : constant Natural := Mark + CRLF'Length - 1;
            begin
               if Head_Last - Text'First + 1 >
                 Flyology.HTTP.Headers.Default_Max_Bytes
               then
                  raise Response_Too_Large;
               end if;
```

Let H be the head length through the CRLF that ends the last field line (the wire head
is H + 2 bytes). The second check accepts H <= 16384. The first check fires whenever
16384 or more bytes are buffered without the terminating `CRLF CRLF` present. With the
8 KiB receive buffer, a head with H in {16383, 16384} normally arrives as 8192 + 8192
bytes, at which point `Pending` holds exactly 16384 bytes ending in `\r\n` (H = 16384)
or `\r\n\r` (H = 16383) and the first check raises `Response_Too_Large` before the final
`\n` or `\r\n` is read. Delivered in one piece, as the parser oracle and
`Validate_Response` see it, the same head passes the second check.
`tests/http_client_parser_matrix.adb:117-122` builds H = 16384 exactly and validates it
through the oracle (`:201-203`), so the ledger records an "exact" boundary the transport
path does not honour.

- **Failure scenario:**
  1. A server sends a 16386-byte head (long `Set-Cookie`, `Link`, or CSP fields).
  2. The kernel delivers it in two 8 KiB reads; after the second, `Pending` is 16384
     bytes with no `CRLF CRLF`.
  3. `Parse_Available_Final_Head` raises `Response_Too_Large`; `Execute` fails with
     `Response_Too_Large` for a head that the documented limit
     (`Flyology.HTTP.Headers.Default_Max_Bytes`) and the repository's own parser matrix
     accept. Whether the failure occurs depends on segmentation, so it is also
     nondeterministic between loopback and real links.
- **Reproduction test sketch:** send the parser matrix's accepted payload
  (`Head_Prefix & String'(1 .. Exact_Value_Length => 'a') & Head_Suffix & CRLF`) from a
  scripted peer, or run it through `tests/http_client_fragmentation.adb`'s one-byte
  receive cap. Expected: `Status = 200` (as the oracle accepts it). Actual:
  `Response_Too_Large` whenever the head crosses a receive boundary at 16384 buffered
  bytes (deterministic under the one-byte cap).
- **Existing coverage:** `tests/http_client_parser_matrix.adb:201-207` (oracle only);
  `tests/http_client_smoke.adb:284` `Expect_Head_Size_Error ("/oversized-head")` covers a
  clearly oversized head; `tests/http_client_fragmentation.adb` covers small heads only.
  Nothing exercises the exact boundary on the transport path.
- **Standard:** n/a (a documented bound); this is contract drift between the parser
  oracle that the conformance ledger cites and the live path.

### H1-CLIENT-5: A composable buffer exchange drains an over-capacity body with no byte bound

- **Location:** `src/flyology-http-client.adb:3864-3908` (`Deliver`), `:4013-4025`
  (`Receive_Head`), `:4042-4064` (`Receive_Content_Step`), `:3918-3991`
  (`Finish_Decoded_Body`). Contrast `:67-70` and `:6644,6688` (`Max_Redirect_Drain_Bytes`,
  the fix for prior finding 36) and `Read_All` `:7255-7262`.
- **Severity:** P2 (same class and same rating the prior audit gave finding 36; time-bounded
  by the exchange deadline, memory not at risk)
- **Confidence:** medium (mechanism is certain; whether draining to keep the transport is
  intended is a design question the repository answered the other way for redirects and
  `Read_All`)
- **Evidence:**

`Deliver`, `:3868-3869`:

```ada
         if Count = 0 or else State.Pending_Result /= Response_Complete then
            return;
```

`Receive_Head`, `:4014-4025`:

```ada
            if State.Target = Buffer_Target
              and then State.Metadata.Mode = Fixed_Body
              and then State.Metadata.Remaining_Body >
                Flyology.Buffers.Drivers.Capacity (State.Destination)
            then
               State.Pending_Result := Response_Body_Too_Large;
               State.Result.Required :=
                 (Known => True,
                  Bytes => Body_Size (State.Metadata.Remaining_Body));
            end if;
            State.Driver_State := Receiving_Content;
            Reschedule;
```

`Receive_Content_Step`, `:4056-4062`:

```ada
         if Complete then
            Finish_Decoded_Body;
         elsif Need_Input then
            Receive_One;
         else
            Reschedule;
         end if;
```

Once `Pending_Result` becomes `Response_Body_Too_Large` (at head time for a known
length, or in `Deliver` `:3892-3895` for chunked and close-delimited bodies) every
subsequent slice is discarded and the engine keeps issuing `Receive_One` until the
framing completes or the deadline expires; nothing consults `Pending_Result` to abandon
the transport early. The repository's own policy for the two sibling paths is the
opposite: `Drain` for redirects stops at 64 KiB and destroys the transport ("Past this
bound the transport costs more than it saves", `:67-70`), and `Read_All` calls
`Abandon_Response` on the first overflow.

- **Failure scenario:**
  1. `Exchange_To_Buffer` with a 64 KiB destination and the default 30 s deadline.
  2. The server answers `Content-Length: 2147483647` (or `Transfer-Encoding: chunked`
     without end) and streams at link speed.
  3. The operation reads and discards for the whole remaining deadline before
     terminalising with `Response_Body_Too_Large`; the owner's completion set is busy
     for that time and the bytes are wasted. A hostile server can do this per exchange.
- **Reproduction test sketch:** scripted peer sends a 200 with `Content-Length: 1048576`
  and a 1 MiB body slowly (or counts bytes written) to a 4 KiB destination. Expected
  (by analogy with `Drain`): the exchange terminalises after at most a bounded number of
  body bytes and `Transports_Closed` increments. Actual: all 1 MiB are consumed before
  `Finish` returns `Response_Body_Too_Large`.
- **Existing coverage:** `tests/corpus/http-client-scenarios.json:131-136`
  ("known-capacity-overflow", 40-byte body) and `tests/http_client_composable_smoke.adb:573`
  assert the typed result on tiny overruns, which finish instantly either way. No test
  measures bytes drained after the overflow decision.
- **Standard:** n/a; internal policy consistency (prior finding 36, fixed in 84f891b).

### H1-CLIENT-6: `Validate_Response` overflows on chunk sizes `7FFFFFFE`/`7FFFFFFF` (test oracle only)

- **Location:** `src/flyology-http-client-http_1_internals.adb:585-587` (`Validate_Response`,
  chunked branch); `Chunk_Size` returns up to `Natural'Last` (`:793-796`). The production
  decoders (`Consume_Available_Content` `:995`, `Read_Response_Body` `:1143`) store the
  size without adding to it and are unaffected. Reachable only through
  `Flyology.HTTP.Client.Testing.Validate_Response`/`Fuzz_Response`
  (`src/flyology-http-client-testing.adb:15-33`), not from a network peer.
- **Severity:** P2 (unreachable from the wire; wrong diagnostic in the fuzz oracle that
  `tests/http-client-conformance.md` designates as the crash arbiter)
- **Confidence:** high
- **Evidence:**

```ada
                  if Length (Data.Pending) < Size + CRLF'Length then
                     raise Protocol_Error with "incomplete HTTP chunk data";
                  end if;
```

`Size` is `Natural`; `Chunk_Size` accepts any value up to `16#7FFFFFFF#` (its guard is
`Result > (Natural'Last - Digit) / 16`). For `Size >= Natural'Last - 1` the expression
`Size + CRLF'Length` overflows `Integer`; with checks enabled (the crate has no
`-gnatp`, per the prior audit) this raises `Constraint_Error`, not `Protocol_Error`.
`Fuzz_Response` handles only `Protocol_Error | Response_Too_Large`
(`flyology-http-client-testing.adb:31-33`), and the conformance document says of that
wrapper that "assertion failures, runtime checks, hangs, and other exceptions remain
crashes", so a campaign would report a crash the production decoder cannot exhibit.

- **Failure scenario:** a GNATfuzz or hand-written oracle run feeds
  `HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n7FFFFFFF\r\n`; the oracle dies
  with `Constraint_Error` and the campaign records a false crash.
- **Reproduction test sketch:**
  `Flyology.HTTP.Client.Testing.Validate_Response (Bytes ("HTTP/1.1 200 OK" & CRLF &
  "Transfer-Encoding: chunked" & CRLF & CRLF & "7FFFFFFF" & CRLF))`. Expected:
  `Protocol_Error` "incomplete HTTP chunk data" (as `7FFFFFF0` produces). Actual:
  `Constraint_Error`.
- **Existing coverage:** `tests/http_client_parser_matrix.adb:170-173` uses a 32-hex-digit
  size (rejected inside the digit loop); `tests/corpus/fixtures/h1-invalid-chunk-size.bin`
  uses `Z`. `tests/http_client_parser_randomized.adb` mutates seed 15 (`000A`) by at most
  eight bytes with a fixed seed; it evidently does not land on an eight-digit value in
  the overflowing range. No case covers `7FFFFFFE..7FFFFFFF`.
- **Standard:** n/a.

## Areas reviewed with no findings

- **Prior finding 6 (Expect with suppressed body) has not regressed.** `Send_Head`
  (`client.adb:3524-3532`) sets `Metadata.Request_Incomplete := True` when the
  expectation is sent; `Probe_Early_Response` (`:3749-3757`) recomputes it from
  `Resume_After_Probe` and the transferred count when any byte arrives; `Receive_Head`
  (`:4028-4034`) clears it only when an interim response arrived with nothing else
  pending; `Select_Body_Mode` (`http_1_internals.adb:419-423`) and `Finish_Decoded_Body`
  (`client.adb:3929-3936`) both force `Reusable := False` while it is set.
  `tests/http_client_audit.adb` finding-6 section covers the 401 and spent-417 cases.
- **Prior finding 18 (bodyless responses) has not regressed.** `HEAD`/1xx/204/205/304 are
  `No_Body`; a nonzero `Content-Length` or any `Transfer-Encoding` on 204/205 is
  rejected (`:424-433`); on `HEAD`/304 it sets `Undelivered_Framing`, which becomes the
  pool's `Verify_On_Reuse` (`Release_Lease` `client.adb:2126-2149`,
  `Return_Lease` `pool_controller.adb:454`, `Try_Checkout` `:179-180`), and the next
  checkout probes the socket before writing (`Verify_Reused_Transport` `client.adb:3155-3183`:
  any byte or EOF discards the transport). Bytes already pending after a `No_Body` head
  mark the transport non-reusable (`:472-478`). The composable path carries the same flag
  through `Release_Exchange_Transport` (`:833-836`).
- **Prior finding 36 has not regressed:** `Drain` is bounded by `Max_Redirect_Drain_Bytes`
  and abandons the transport past it (`:6383-6406`).
- **Status line.** Version must be exactly `HTTP/1.1` or `HTTP/1.0` (`:241-255`);
  three digits, `100..599` via the `Status_Code` subtype (`:260-275`); reason phrase
  rejects controls below 32 except HTAB and rejects DEL, accepts obs-text (`:276-284`,
  RFC 9112 section 4); over-long lines fall under the 16 KiB head bound.
- **Response fields.** Split strictly on CRLF; a bare CR or bare LF inside a line survives
  into the value and is rejected by `Headers.Add` (`headers.adb:20-30`, RFC 9112
  section 2.2); a name with whitespace before the colon or any non-token byte fails the
  token check (`:14-19`, RFC 9112 section 5.1); obs-fold is unfolded to a single SP
  (`http_1_internals.adb:303-310`), which is what RFC 9112 section 5.2 requires of a user
  agent; whitespace before the first field is rejected (`:304-307`). Field count (64) and
  byte (16 KiB) bounds raise `Response_Too_Large`, and the engine's handler
  (`client.adb:6006-6008`) maps every `Protocol_Error`/`Response_Too_Large` to
  `Response_Invalid`, whose `Fail_Exchange` path always calls
  `Release_Exchange_Transport (Reusable => False)`; the connection is never reused after
  a bound is exceeded. The one-shot stale retry in `Fail_Exchange` (`:928-948`) is gated
  on `not Saw_Response_Bytes`, so a malformed head never triggers a replay.
- **Framing precedence (RFC 9112 section 6.3).** `Transfer-Encoding` with `Content-Length`
  is rejected (`:452-454`); `Transfer-Encoding` must be exactly one field whose trimmed,
  lower-cased value is `chunked` (`:455-463`), so `chunked, chunked`, `gzip, chunked`,
  `chunked, gzip`, `identity`, and `chunked;q=1` are all rejected rather than resolved;
  HTTP/1.0 with `Transfer-Encoding` is rejected (`:434-437`); `Content-Length` lists are
  parsed per member with conflict detection, and empty, signed, `+`-prefixed, non-digit
  and (64-bit) overflowing members are rejected (`:151-207`, seeds 26-29); absent framing
  yields close-delimited reading with `Reusable := False` (`:468-471`).
- **Chunk decoding (RFC 9112 section 7.1).** Hex digits only with an overflow guard
  (`:780-797`); leading zeros accepted (seed 15); `+`/`-`/`0x`/leading whitespace rejected;
  chunk-size line bounded at 16 KiB (`:820-823`, `:886-889`); extensions validated with
  full `quoted-string`/`quoted-pair` handling (`:678-761`); CRLF after data checked
  (`:950-964`, `:1109-1121`); the final empty line is required and a close before it is a
  `Protocol_Error`; trailers reject `connection`, `content-length`, `host`, `trailer`,
  `transfer-encoding` and are stored only in `Data.Trailers`, never merged into
  `Fields`, so no trailer can override a header the application already read
  (`:832-857`, `client.ads:1092-1130`).
- **1xx handling (RFC 9110 section 15.2).** Unsolicited `100` and other 1xx are consumed
  (`Classify_Informational`, SPARK-proved, `client_policy.ads:136-159`); at most eight;
  `101` is rejected; a 1xx carrying `Content-Length`/`Transfer-Encoding` is rejected
  (seed 42); an interim response arriving during an upload resumes the upload
  (`client.adb:4028-4034`) rather than abandoning it.
- **Connection reuse decisions.** Every completion path checks `Length (Pending) > 0` and
  clears `Reusable` (`http_1_internals.adb:922-924`, `977-979`, `1067-1069`, `1129-1131`);
  every exception path in `Read_Response_Body` releases with `Reusable => False`
  (`:1157-1180`); `Response.Finalize` abandons an incomplete body (`client.adb:7369-7380`);
  `Abandon_Response` never reuses an HTTP/1 transport (`:2151-2170`); `Read_All`
  abandons on overflow. I found no path by which a transport with unread response
  bytes returns to the pool as idle.
- **Request serialisation / splitting.** Method: `To_Method` enforces a 1..64-byte token
  (`flyology-http.adb:12-20`); target: `Set_Target` rejects anything outside 33..126, `#`,
  and non-`/` starts except `*` (`client.adb:2177-2193`); header names and values on every
  public entry point (`Add_Header`, `Add_Trailer`) pass through `Headers.Add`, which
  rejects CR, LF, NUL, DEL and all controls but HTAB (`headers.adb:11-30`);
  `Add_Header` refuses the framing and connection fields (`:2201-2215`); `Host` is built
  from `Parse_Origin`, which rejects bytes outside 33..126 and brackets/backslash in the
  host and digit-checks the port (`flyology-http.adb:138-160`). The generated `Trailer:`
  list and trailer lines reuse validated names/values. No CR, LF or NUL can reach the
  wire from application input.
- **Streamed uploads.** Known-length sources that produce more than declared
  (`client.adb:3580-3592`), finish short (`:3607-3616`), report progress with zero bytes
  (`:3580`, `:3641-3644`), or raise (`:3674-3681`) all set `Request_Incomplete` and fail
  with `Request_Source_Failed`, and `Fail_Exchange` destroys the transport. The
  synchronous adapter (`:628-650`) correctly splits a legacy `Read` that returns bytes
  and `Finished` together into a progress step and a finished step, and turns a
  zero-byte non-finished `Read` into the documented `Request_Body_Error`.
- **Fixed-length and close-delimited bodies.** Countdown arithmetic and `Copy_Pending`
  bounds (`:617-641`, `:1046-1071`) are sound; a peer close mid-`Content-Length` is a
  `Protocol_Error`; close-delimited completion releases with `Reusable => False`.
- **`Flyology.HTTP_Chunk_Encoding.Encode`** is SPARK-proved and correct (uppercase hex,
  no leading zeros); note the client does not use it (see observations).

## Observations not counted

- **Missing SP after the status code.** `HTTP/1.1 200\r\n` is rejected (`:263-266`, seed 19
  pins this). RFC 9112 section 4 ABNF requires the SP, so this is conformant, but curl,
  Go `net/http` and Python `http.client` all accept it. I could not name a stock server
  that emits it, so this is strictness, not a defect.
- **obs-fold in trailers** is rejected (`:839-842`) while it is unfolded in headers. RFC
  9112 section 5.2's user-agent MUST is phrased for "a response message"; no server I
  know of folds trailer lines, and rejecting is the safe direction.
- **Bare-LF line endings** are not recognised (RFC 9112 section 2.2 MAY). A response
  whose head uses bare LF is neither accepted nor promptly rejected: the client keeps
  reading until 16 KiB or the deadline. Malformed input, so not counted.
- **Empty retained body on `POST`/`PUT`/`PATCH` emits no `Content-Length: 0`**
  (`Request_Head` `:43-45` emits it only for `Body_Length > 0`, while a known-length
  streaming source of length 0 does emit it, `:37-40`). RFC 9110 section 8.6 is a SHOULD;
  servers that answer 411 to a bodyless `POST` exist (curl without `-d` has the same
  behaviour). Policy, not a rule violation; flagged for consistency between the two
  paths.
- **Proved policy functions that the engine does not call.** `Validate_Upload`,
  `Classify_Pull`, `Classify_Stale_Retry` and `Classify_Expectation_Response` in
  `Flyology.HTTP.Client_Policy` are referenced only by their smoke test; the engine
  re-implements each decision inline (`Start_Exchange` `:1330-1380`, `Pull_Source`,
  `Fail_Exchange`, `Execute_Operation_Once` `:6505-6547`). I checked the re-implementations
  against the proved contracts and found the outcomes consistent with the `.ads`
  promises (the composable path retries only safe methods after handoff, which the
  `Fail_Exchange` comment documents; the synchronous path retries idempotent methods as
  `Execute`'s comment promises). This is drift risk, not a defect.
- **Two chunk-size encoders.** `client.adb:1984-1997` `Hexadecimal` (lowercase) duplicates
  the SPARK-proved `HTTP_Chunk_Encoding.Encode` (uppercase). Both are valid `HEXDIG`.
- **Policy values seen and not questioned:** eight informational responses maximum,
  16 KiB head and 64 fields, 8 KiB receive buffer, 64 KiB redirect drain, `Status_Code`
  range 100..599 (600-999 rejected; RFC 9110 section 15 makes the first digit the class,
  so this is a defensible strictness).
- **Strictness on chunk-size lines:** trailing whitespace without an extension (`5 \r\n`)
  and a leading `;` with no name are rejected; conformant with the ABNF.
- **Performance only:** `Consume_Available_Content` zeroes the whole 8 KiB output array on
  every step (`:901`) and `To_String (Data.Pending)` copies the pending buffer on every
  line scan; neither affects correctness.
- **Out of scope but load-bearing:** the `Verify` probe and every receive rely on
  `Flyology.IO.Connections.Drivers.Receive` distinguishing "would block" from "zero
  bytes"; I did not audit the runtime.
