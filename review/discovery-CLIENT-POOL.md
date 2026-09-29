# Discovery: CLIENT-POOL

Scope (read in full unless noted):
- `src/flyology-http-client.ads` (1402)
- `src/flyology-http-client.adb` (7406): declarations, pool/lease release, `Fail_Exchange`,
  `Finish_*`, `Start_Exchange`, constructors, `Finish`, `Drive`, `Request_Cancellation`,
  `Finalize`, `Dispose_Connection`/`Close_And_Finish`/`Interrupt_Active`/`Release_Lease`/
  `Abandon_Response`, `Validate_Composable_Encoding`, engine admission/connect/TLS/verify
  states, `Send_*`/`Pull_Source`/`Probe_Early_Response`/`Receive_*`, `Resolve_Redirect`,
  `Execute_Operation_Once`, `Execute_Redirects`, `Read_Body` (lease parts), `Read_All`,
  `Shutdown`, both `Finalize`s. Not read: HTTP/1 head parsing, HTTP/2 and HTTP/3 pump
  bodies (other reviewers).
- `src/flyology-http-client-pool_controller.adb` (686)
- `src/flyology-http-client-state_lifetime.adb` (30)
- `src/flyology-http-client_policy.ads/.adb` (217/111)
- `src/flyology-http-client-authentication.ads/.adb` (40/112)
- `src/flyology-http-client-request_bodies.ads/.adb` (158/176, first 80 of body),
  `-channels.ads/.adb` (66/123), `-files.ads/.adb` (56/76)
- `src/flyology-http-client-testing.ads/.adb` (46/34)
- `src/flyology-http-client-http_1_internals.adb` lines 80-110, 400-445 only
- `src/flyology-http-client-sse.adb` lines 525-545, 670-712, 743-817, 897-999 only
- pinned runtime `flyology` at `bd95746d` (from `alire/alire.lock`): `Flyology.IO.Infinite`,
  `Time_Math.Remaining`, `Operations.Drivers.Arm_Deadline`, `Operations.Wait_All`,
  `IO.DNS.Max_Addresses`, `IO.Files.File_Offset`
- tests: `http_client_redirects`, `http_client_audit` (355-480), `http_client_upload_controls_smoke`
  (295-335, 495-540), `http_client_composable_stale_reuse` (270-312), grep sweeps of the
  others named in the assignment
- `review/prior-audit.md` findings 6, 10, 18, 36, 37, 38 and all three appendices;
  `CHANGELOG.md` Unreleased; `proof/proof-status.md` 62-76, 398-410

Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| CLIENT-POOL-1 | Same-origin relative redirect whose query contains `://` raises `Redirect_Error` | P1 | high |
| CLIENT-POOL-2 | Synchronous 417 fallback retries after body transmission with a consumed, un-rewound source | P1 | medium |
| CLIENT-POOL-3 | Negative `Expect: 100-continue` wait sends the body immediately instead of waiting to the deadline | P1 | medium |
| CLIENT-POOL-4 | Synchronous safe-method exchanges can replay twice (engine retry plus wrapper retry) | P2 | medium |
| CLIENT-POOL-5 | Four proved `Client_Policy` classifiers have no production caller; `proof-status.md` still says they are consumed | P2 | high |
| CLIENT-POOL-6 | Shutdown racing HTTP/3 establishment reports `Transport_Failed`/`Device_Error` instead of `Client_Unavailable`/`Client_Closed` | P2 | medium |
| CLIENT-POOL-7 | `Exchange_Operation.Finalize` frees a response-head `Reply_Data` without returning its lease or lifetime retention | P2 | medium (code) / low (reach) |
| CLIENT-POOL-8 | `Response.Finalize` exception path frees the lease record without returning the pool slot | P2 | medium (code) / low (reach) |

## Findings

### CLIENT-POOL-1: Same-origin relative redirect whose query contains `://` raises `Redirect_Error`

- **Location:** `src/flyology-http-client.adb:6301-6315` (`Resolve_Redirect`), consumed by
  `Execute_Redirects` at `:6675` and by the SSE client through `Resolve_Redirect_Target`
  (`src/flyology-http-client-sse.adb:761`)
- **Severity:** P1
- **Confidence:** high
- **Evidence:**

```ada
      elsif Ada.Strings.Fixed.Index (Reference, "://") /= 0 then
         declare
            Separator : constant Natural :=
              Ada.Strings.Fixed.Index (Reference, "://");
            Name : constant String :=
              Ada.Characters.Handling.To_Lower
                (Reference (Reference'First .. Separator - 1));
         begin
            if Name /= "http" and then Name /= "https" then
               raise Redirect_Error with "unsupported redirect URI scheme";
            end if;
            Parse_Absolute (Reference, False);
         end;
      elsif Has_URI_Scheme (Reference) then
         raise Redirect_Error with "unsupported redirect URI scheme";
```

The absolute-URI branch is selected by the presence of `://` anywhere in the reference, not by
a scheme at the start. `Has_URI_Scheme` (which does check that the colon precedes any `/` or
`?`) is only consulted in the following `elsif`, so it never sees these references.

- **Failure scenario:**
  1. Application enables `Follow_Same_Origin` (`Set_Redirects`) and executes `GET /login`.
  2. Server answers `302 Found` with `Location: /login?next=https://example.com/home`, a
     relative-path reference with an absolute URL in its query. This is the ordinary shape
     of "return-to" and OAuth `redirect_uri` parameters.
  3. `Resolve_Redirect`: the first branch (`//` prefix) does not match, the second finds
     `://` at the query, `Name` becomes `"/login?next=https"`, and `Redirect_Error
     "unsupported redirect URI scheme"` is raised.
  4. `Execute` raises `Redirect_Error` for a same-origin redirect the `.ads` promises to
     follow ("Follow eligible redirects within the client origin"). Under
     `Return_Redirects` the response is returned untouched, so only following is affected.
  The same reference misparses when the `://` is in the path (`/a/b://c`) but the query form
  is the common one.
- **Reproduction test sketch:** extend `tests/http_client_redirects.adb` with a script
  serving `HTTP/1.1 302 Found\r\nLocation: /next?u=http://127.0.0.1:1/x\r\nContent-Length:
  0\r\n\r\n` then `200` on `/next?u=http://127.0.0.1:1/x`; execute with
  `Default_Same_Origin_Redirects`. Expected: status 200 on the resolved target. Actual:
  `Redirect_Error`. A pure-function check is also possible through
  `Resolve_Redirect_Target` (private, reachable from a child package):
  `Location => "/next?u=http://h/x"` should yield `Is_Same = True`, `Target =
  "/next?u=http://h/x"`.
- **Existing coverage:** `tests/http_client_redirects.adb:266` tests `../next?x=1#ignored`
  (query without a scheme); no Location value in the suite contains `://` after the first
  path character. `git log -S` shows the check has been in this form since the initial
  import (`1a25f7f`), so it is not a regression of a prior-audit fix; the prior audit's
  "safe by construction" appendix covered origin binding, not reference classification.
- **Standard:** RFC 9110 s10.2.2 (`Location` is a URI-reference resolved per RFC 3986 s5);
  RFC 3986 s3.1 and s4.2 (a scheme is `ALPHA *( ALPHA / DIGIT / "+" / "-" / "." )` ending at
  the first `:`; a relative-path reference whose first segment contains a colon must be
  written `./` but one starting with `/` is unambiguous), s4.2 note that a reference is
  relative when it does not begin with a scheme.

### CLIENT-POOL-2: Synchronous 417 fallback retries after body transmission with a consumed, un-rewound source

- **Location:** `src/flyology-http-client.adb:6636-6647` (`Execute_Redirects`), source
  contract at `:6423-6470` (`Execute_Operation_Once`), engine side `:3743-3760`
  (`Probe_Early_Response`) and `:3574-3600` (`Pull_Source`)
- **Severity:** P1
- **Confidence:** medium (the code path is certain; how often a real origin answers 417
  after the client has begun the body is the uncertain part)
- **Evidence:**

```ada
               if Status (Reply) = 417
                 and then Current.Expect_Continue
                 and then not Retried
               then
                  --  A complete 417 conclusively rejects the expectation
                  --  before this adapter has consumed Source. Retry once
                  --  without the Expect field, inside the original absolute
                  --  budget.
                  Drain (Reply, Max_Redirect_Drain_Bytes, Token);
                  Current.Expect_Continue := False;
                  Retried := True;
                  Retry_Expectation := True;
```

Nothing here consults whether the body was transmitted (`Reply.Data.Request_Incomplete`, or
a body-sent flag), and `Current_Source` is neither rewound nor checked for
`Rewindable_Request_Body_Source` before being handed to the next `Execute_Operation_Once`.
The `.ads` says: "A 417 final response received before body transmission is retried once on
a fresh transport without the expectation". The engine does not enforce "before body
transmission" either: after `Continue_Wait` expires it sends the body
(`Probe_Early_Response`, `Need_Read` with `Deadline_Reached`) and any later final response,
including 417, is delivered as an ordinary `Response_Complete`. The previously proved guard
that carried this condition, `Client_Policy.Classify_Expectation_Response (..., Body_Sent,
...)`, has no caller since `f0d630d` (see CLIENT-POOL-5).

- **Failure scenario:**
  1. `POST /upload` with `Set_Expect_Continue (Request, Wait_Timeout => 1.0)` and a streamed
     `Source` (a `Channels.Channel_Source`, or an `Array_Source`, which is rewindable).
  2. Origin is slow: no interim response within 1 s. The client sends the body
     (`Expect_Waiting := False; Request_Incomplete := False`), fully or in part.
  3. Origin then answers `417 Expectation Failed` (RFC 9110 s10.1.1 permits a 417 whenever
     the expectation cannot be met; nothing requires it to precede the body).
  4. Wrapper drains the 417, clears `Expect_Continue`, and re-executes with the same
     `Source` object at its current position.
     - Known length, source fully consumed: retry sends `Content-Length: N`, `Pull_Source`
       gets `Source_Finished` with `Source_Transferred = 0 /= N`, fails
       `Request_Source_Failed`, and `Execute` raises `Request_Body_Error` instead of returning
       the 417 the server sent.
     - Known length, partially consumed (417 raced the upload): retry sends the remaining
       bytes under a full `Content-Length`, then `Request_Body_Error`; the transport is
       discarded as mid-message.
     - Unknown length (chunked) one-shot source consumed: retry silently sends
       `0\r\n\r\n`, i.e. an empty body under the same method and target. The server may
       act on an empty POST; the caller sees whatever the server returns.
- **Reproduction test sketch:** in `tests/http_client_upload_controls_smoke.adb` style:
  script `Expect_Head_Only ("/late-417")`, sleep past the 20 ms `Wait_Timeout`, receive the
  17-byte body, then `Send_Empty ("417 Expectation Failed")`, then `Accept_Peer` and read
  the retried head and body. Client: `POST /late-417`, `One_Shot_Source` of 17 known bytes,
  `Set_Expect_Continue (Request, Wait_Timeout => 0.02)`. Expected per `.ads`: the 417
  response is returned (body already sent, so no retry). Actual: `Request_Body_Error`
  (known length) or an empty chunked body on the wire (`Unknown_Length`).
- **Existing coverage:** `tests/http_client_upload_controls_smoke.adb:318-330,522-528`
  covers 417 arriving before the body (`Expect_Head_Only` then 417), where the retry is
  correct. `tests/http_client_audit.adb:376-395,455-466` covers 417 after a stale retry has
  spent the budget. Neither sends 417 after the body has started.
- **Standard:** RFC 9110 s10.1.1 (client SHOULD repeat without the expectation on 417;
  client MAY send the body after waiting), s9.2.2 (POST is not idempotent, so re-sending it
  with different content is a semantic change the client must not make silently); the
  `.ads` contract quoted above.

### CLIENT-POOL-3: Negative `Expect: 100-continue` wait sends the body immediately instead of waiting to the deadline

- **Location:** `src/flyology-http-client.adb:3768-3782` (`Probe_Early_Response`), contract
  `src/flyology-http-client.ads:227-241` (`Set_Expect_Continue`)
- **Severity:** P1 (documented contract violated on valid input; practical harm is limited
  to losing the wait, since the server must accept an early body)
- **Confidence:** medium
- **Evidence:**

```ada
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

`.ads`: "a negative value waits within the whole exchange deadline and zero sends immediately
after the head". With `Continue_Wait < 0`, `Duration'Min` yields the negative value (or the
negative value is armed directly when unlimited). The pinned runtime documents
`Arm_Deadline` as "A nonpositive interval is due on the next completion-set drive"
(`flyology-operations-drivers.ads:58-63` at `bd95746d`). The next drive therefore arrives
with `Deadline_Reached`, takes the `else` branch, and sends the body: negative behaves as
zero.

- **Failure scenario:**
  1. `Set_Expect_Continue (Request, Wait_Timeout => -1.0)` on an `HTTP_1_Only` client,
     `Execute (..., Timeout => 30.0)`.
  2. Head is sent; `Probing_Early_Response` arms a negative deadline.
  3. Body is transmitted on the following drive, before any 100 Continue, although the
     caller asked to wait up to the 30 s exchange deadline.
- **Reproduction test sketch:** server script reads the head, waits 200 ms, then sends
  `100 Continue`, then reads the body; client uses `Wait_Timeout => -1.0` and a source that
  counts reads. Expected: first `Read` happens after the 100 arrives. Actual: the source is
  read before the server sends anything (observable by having the server assert that no body
  bytes arrive before it writes the 100).
- **Existing coverage:** none. `grep` finds no negative `Wait_Timeout` in `tests/`; the
  only nonpositive-like case is `Wait_Timeout => 0.02`
  (`tests/http_client_upload_controls_smoke.adb:510`).
- **Standard:** n/a (local contract). RFC 9110 s10.1.1 permits sending after any wait, so
  interop is unaffected.

### CLIENT-POOL-4: Synchronous safe-method exchanges can replay twice (engine retry plus wrapper retry)

- **Location:** `src/flyology-http-client.adb:925-957` (`Fail_Exchange` first branch),
  `:6529-6548` (`Execute_Operation_Once` second retry branch), `:5455-5459`
  (`Checkout_Idle` sets `Was_Reused := True`)
- **Severity:** P2
- **Confidence:** medium
- **Evidence:**

```ada
      if Item.State.Target in Buffer_Target | Response_Head_Target
        and then Item.State.Result.Admission = Possibly_Admitted
        and then Item.State.Was_Reused
        and then not Item.State.Safe_Retry_Used
        ...
         Item.State.Safe_Retry_Used := True;
         Item.State.Was_Reused := False;
         ...
         Item.State.Driver_State := Exchange_Idle;
```

and in the wrapper:

```ada
      elsif not Retried.all
        and then Operation.State.Was_Reused
        and then Result.Admission in Not_Admitted | Possibly_Admitted
        and then Result.Result_Kind in
          Connection_Failed | Transport_Failed | Response_Invalid
        and then Is_Idempotent (Value.Method_Value)
```

The engine's internal retry re-enters `Exchange_Idle`; a second `Checkout_Idle` sets
`Was_Reused := True` again. Admission is monotonic, so after the first handoff it stays
`Possibly_Admitted`, which disables the engine's second branch but still satisfies the
wrapper's predicate. `Retried.all` is untouched by the engine's retry.

- **Failure scenario:** pool `Max_Idle => 2`, two idle HTTP/1 connections both dead (origin
  restarted). `Execute (GET)`: attempt 1 on idle A fails after the head is sent (engine
  retry, `Stale_Retries = 1`); attempt 2 on idle B fails likewise (wrapper retry,
  `Stale_Retries = 2`); attempt 3 creates a fresh transport. The `.ads` promises "retried
  once"; `Client_Diagnostics.Stale_Retries` documents "retried once after an existing
  transport failed". Only safe methods reach the engine branch, so no semantic harm; the
  contract and the counter are what drift.
- **Reproduction test sketch:** model test with `Max_Idle => 2`: prime two connections, have
  the server close both, then one `GET`; assert `Diagnostics.Stale_Retries = 1` and three
  accepted peers total. Actual: `Stale_Retries = 2`.
- **Existing coverage:** `tests/http_client_composable_stale_reuse.adb:305-306` asserts
  `Stale_Retries = 1` for a single stale idle connection; no test primes two.
- **Standard:** n/a (local contract; RFC 9110 s9.2.2 permits any number of automatic
  retries of idempotent requests).

### CLIENT-POOL-5: Four proved `Client_Policy` classifiers have no production caller; `proof-status.md` still says they are consumed

- **Location:** `src/flyology-http-client_policy.ads:15-40,52-77,86-127,171-188`;
  `proof/proof-status.md:68-76` and `:402-404`
- **Severity:** P2 (documentation/proof-evidence drift; the dropped `Body_Sent` guard is
  the mechanism behind CLIENT-POOL-2)
- **Confidence:** high
- **Evidence:** `rg 'Classify_Stale_Retry|Classify_Expectation_Response|Validate_Upload|Classify_Pull' src/`
  matches only `client_policy.ads/.adb`. `git log -S` on each name against the client
  bodies shows the last caller removed in `f0d630d` (2026-08-23, "HTTP client exchanges
  block inside duplicate protocol engines"). `proof-status.md` still states:

```text
The HTTP client upload-policy review adds a production-consumed SPARK boundary
for request/source compatibility, exact known-length pull completion,
informational-response accounting, stale-connection replay eligibility, and
the one-attempt `417 Expectation Failed` fallback.
...
- [x] Confirm production request, upload, response, and retry paths consume the
      proved classifications
```

Only `Classify_Informational`, `Next_Informational_Count` (both in `http_1_internals.adb`)
and `Classify_Redirect` (`client.adb:6629`) are consumed. The replay decision now lives in
`Fail_Exchange` and `Execute_Operation_Once` as hand-written predicates with different
inputs (safe-vs-idempotent split, `Has_Mutation_Condition`) and the 417 decision has no
`Body_Sent` input at all.

- **Failure scenario:** a reader of `proof-status.md` or the CHANGELOG takes the SPARK proof
  as evidence for the shipped replay and 417 behaviour; it is evidence about dead code.
- **Reproduction test sketch:** n/a (documentation); a `scripts/test.sh` invariant could
  grep that each proved policy function has at least one caller under `src/` outside its
  own unit.
- **Existing coverage:** `tests/flyology-http-client_policy-smoke.adb` exercises the
  functions directly, which is why the drift is invisible to the suite.
- **Standard:** n/a

### CLIENT-POOL-6: Shutdown racing HTTP/3 establishment reports `Transport_Failed`/`Device_Error` instead of `Client_Unavailable`/`Client_Closed`

- **Location:** `src/flyology-http-client.adb:4963-4969` (HTTP/3 `Pool.Install`), `:3272`
  (HTTP/3 `Publish_Connecting`), handler `:5413-5417`; contrast `:5634-5657` (TLS path maps
  `Is_Stopping` to `Client_Unavailable`) and `:6564-6600` (wrapper mapping)
- **Severity:** P2
- **Confidence:** medium
- **Evidence:**

```ada
            when HTTP_3_Open_Request =>
               if State.Creating then
                  Owner.Pool.Install
                    (Positive (State.Slot_Index), State.Connection,
                     Ada.Real_Time.Clock);
   ...
      exception
         when Error : others =>
            Remember_Failure (State, Error);
            Fail_Exchange (Item, Transport_Failed);
      end Drive_HTTP_3_Protocol;
```

`Pool_Controller.Install` and `Publish_Connecting` raise `Client_Closed` when `Stopping`
(`pool_controller.adb:292-295,337-340`). On the TCP/TLS paths the enclosing handlers check
`Owner.Pool.Is_Stopping` and produce `Client_Unavailable`; on the HTTP/3 path the generic
handler produces `Transport_Failed` with `Failure_Cause = Client_Closed`. The synchronous
wrapper re-raises `Failure_Cause` only for TLS/Protocol/Device/Socket identities, so
`Execute` raises `Flyology.IO.Device_Error` for a stopped client, while the `.ads` lists
`Client_Closed` for that case and the typed contract says "Client_Unavailable: Client is
stopped". In `Negotiate_HTTP_3` mode the address-retry branch first replays through TCP,
where `Try_Checkout` returns `Checkout_Closed`, so the outcome self-corrects; in
`Require_HTTP_3` it does not.

- **Failure scenario:** `Require_HTTP_3` client; task A is mid-QUIC-handshake in
  `Exchange_To_Buffer`; task B calls `Shutdown`. A's `Install` raises `Client_Closed`;
  A's `Finish` reports `Transport_Failed` (composable) or `Execute` raises `Device_Error`
  (synchronous).
- **Reproduction test sketch:** hard without a hook; the connection test-hook barrier
  (`Connection_Test_Hooks.Barrier`) has no point inside the HTTP/3 handshake. A unit-level
  check: drive an H3 composable exchange to `HTTP_3_Open_Request` against the aioquic
  fixture with `Set_HTTP_2_Settlement_Grace`-style test seam, request shutdown, assert
  `Kind = Client_Unavailable`.
- **Existing coverage:** none for shutdown during H3 establishment.
- **Standard:** n/a (local typed-outcome contract, `flyology-http-client.ads:620-650`).

### CLIENT-POOL-7: `Exchange_Operation.Finalize` frees a response-head `Reply_Data` without returning its lease or lifetime retention

- **Location:** `src/flyology-http-client.adb:1906-1940` (`Finalize`), producer
  `:1167-1173` (`Finish_Response_Head` creates a lease-holding `Reply_Data` and calls
  `Lifetime.Retain_Response`)
- **Severity:** P2 (normal control flow always calls `Finish` first; reachable through
  abort or an exception between terminal completion and `Finish`)
- **Confidence:** medium on the code, low on reachability
- **Evidence:**

```ada
         Release_Exchange_Borrows (Item.State.all);
         if Item.State.Reply_Data /= null then
            Free_Response_Data (Item.State.Reply_Data);
         end if;
```

For `Response_Head_Target` the `Reply_Data` carries `Connection`, `Slot_Index`, and
`Retains_Owner = True`; `Finish_Response_Head` has already nulled `State.Connection` and
reset `State.Metadata`, so the preceding `Release_Exchange_Transport` sees nothing to
release. `Response.Finalize` (`:7369-7404`) is the routine that knows how to return such a
record (`Abandon_Response` + `Release_Response`); `Finalize` here does not call it.

- **Failure scenario:** `Execute_Operation_Once` completes the head, then `Wait_All` or the
  `Finish` prologue is abandoned by task abort (or a `Program_Error` from the completion
  set). `Operation` finalizes: slot stays `Leased`, `Leased_Count` never decrements,
  `Await_Drained` never opens, `Shutdown` raises `Timeout_Error`, and `Client_State` is never
  freed because `Responses` never reaches zero. Same shape for the SSE `Read_Operation`,
  which owns an `Exchange_To_Response` child (`sse.adb:678-684,977`).
- **Reproduction test sketch:** not expressible without abort; a unit test could construct
  the state by hand (private child package) and assert `Diagnostics.Active_Exchanges = 0`
  after finalization.
- **Existing coverage:** none.
- **Standard:** n/a

### CLIENT-POOL-8: `Response.Finalize` exception path frees the lease record without returning the pool slot

- **Location:** `src/flyology-http-client.adb:7369-7404`
- **Severity:** P2 (only when `Abandon_Response` itself raises: `Cancel_Stream`,
  `Release_Stream`, `Return_Lease`'s `Program_Error`, or `Close_And_Finish`)
- **Confidence:** medium on the code, low on reachability
- **Evidence:**

```ada
   exception
      when others =>
         if Item.Data /= null and then Item.Data.Retains_Owner
           and then Owner /= null
         then
            ...
         end if;
         Free_Response_Data (Item.Data);
```

The handler releases the lifetime retention but not the lease (`Item.Data.Connection` is
still set). The slot remains `Leased` with a dangling `Connection` pointer held by the pool;
a later `Interrupt_Active` or `Take_Idle` would dereference it after the exchange's
`Pooled_Connection` was never disposed (it is not freed either, so no use-after-free, but
the slot and the socket leak until the process exits).

- **Failure scenario:** HTTP/2 response abandoned while the session's `Cancel_Stream`
  raises (peer already tore the connection down and the session reports it as an
  exception rather than a result). Reachability depends on `H2_Connections` internals not
  reviewed here.
- **Reproduction test sketch:** none without a fault-injection seam.
- **Existing coverage:** none.
- **Standard:** n/a

## Areas reviewed with no findings

- **Pool controller state machine** (`pool_controller.adb`): every transition was traced
  for count coherence. `Idle_Count` includes `Shared` slots with zero streams and nothing
  else; `Draining` with zero streams cannot exist (it transitions to `Closing` inside
  `Return_Lease`); `Await_Drained`'s barrier (`Connecting + Leased + Idle + Closing = 0`)
  covers every non-`Empty` phase because a `Shared`/`Draining` slot with streams is in
  `Leased_Count`. `Has_Capacity`, `Try_Checkout`'s wake-drain scan, and `Wait_Source` use
  the same predicate, so prior finding 10 has not regressed. Deferred-close handshakes
  (`Interrupting`/`Owner_Done`/`Interrupt_Sent`) were checked in both orders
  (`Creation_Failed`/`Return_Lease` before or after `Finish_Interrupt`): exactly one party
  disposes and calls `Finish_Close`/`Finish_Interrupt`. `Install` when `Stopping` raises
  before mutating the slot, and the caller still owns `Creating`, so `Creation_Failed`
  cleans up.
- **Lease release on every exit path (composable engine).** `Release_Exchange_Transport` is
  idempotent (guards on `Is_Engaged`, `Metadata.Connection /= null`, `Creating`,
  `Pool_Waiter`) and is invoked from `Finish_Success`, every `Fail_Exchange` leg, the engine's
  `others` handler, and `Finalize` (twice, deliberately). `Release_Lease` nulls
  `Data.Connection` before any further step, so a second call is a no-op. `Return_Lease`
  mutates `Leased_Count` before its multiplexed double-return guard (`Active_Streams = 0`
  raises `Program_Error` after the decrement), but that guard is only reachable through a
  second return of the same lease, which the null check above prevents; every other raise
  precedes mutation. `Finish_Response_Head` nulls `State.Connection`/`Slot_Index` and resets
  `Metadata` before `Complete_Exchange`, so the transferred lease is not also returned by
  borrow cleanup; its exception path frees the candidate without the lease and lets
  `Fail_Exchange` return it.
- **Deadline arithmetic.** `Deadline_After` maps negative to `No_Deadline`;
  `Remaining (Monotonic_Deadline)` clamps to `0.0` and returns `Flyology.IO.Infinite` (which
  is `-1.0` in the pinned runtime, so `Deadline_After (Remaining (...))` round-trips) for
  unlimited; `Drive` checks `Expired` before every engine step; `Arm_Deadline` treats `0.0`
  as due immediately per its contract. No negative or sentinel value reaches an arm call
  except the one reported in CLIENT-POOL-3. `Deadline_After (Duration'Last)` would overflow
  `Clock + To_Time_Span`; noted under observations.
- **Redirect policy other than CLIENT-POOL-1.** Hop bound checked before increment
  (`Hops = Maximum_Hops`), `Seen` sized `0 .. 20` with `Seen_Last <= Maximum_Hops <= 20`,
  cycle detection by resolved target, method rewriting through the proved
  `Classify_Redirect` (301/302+POST and 303 to GET, 303+HEAD to HEAD, 307/308 preserved),
  `Rewrite_Without_Content` clears `content-*`, `digest`, trailers, body, and `Expect`;
  non-rewindable sources on a preserving hop raise `Redirect_Error`; cross-origin (scheme,
  host, port) is returned, `//host` is resolved then origin-checked, non-http(s) schemes are
  rejected, `Set_Target` re-validates the resolved target. `Remove_Dot_Segments` follows RFC
  3986 s5.2.4 including the root-slash case fixed by prior finding 1. Composable exchanges
  refuse `Follow_Same_Origin` at start, so the rework did not open a second redirect path.
- **Authentication.** `Client.Authentication` is preemptive only: `Set_Basic`, `Set_Bearer`,
  `Clear`. There is no `WWW-Authenticate` parsing, no Digest, no challenge reaction, no
  per-origin credential store, so the challenge-parsing hunt list does not apply. Base64 is
  correct for all three tail lengths; `Set_Basic` rejects `:` in the user-id and controls in
  both fields (RFC 7617 s2); the generated field goes through `Headers.Add` validation.
  Credentials are request fields; the client is origin-bound and redirects never leave it.
- **Request body sources.** `Array_Source`/`Byte_String_Source`/`Bytes_Source`/`Buffer_Source`
  produce at least one byte or `Finished`; `Range_Source` reports a short file as
  `Finished` and the engine turns that into `Request_Source_Failed`; `Validate_Range` is
  sound because `Body_Size` and `File_Offset` share `0 .. 2**63-1`; `Channel_Source` raises
  `Request_Body_Error` before copying a buffer that would cross the declared total, maps
  channel timeouts to `IO.Timeout_Error`, and is one-shot by design. The engine rejects a
  source that yields more than declared, fewer than declared at `Finished`, or zero bytes
  without `Finished` (`Pull_Source`). The synchronous adapter converts a legacy
  `Finished`-with-data read into progress followed by a deferred `Source_Finished`.
- **Replay eligibility (RFC 9110 s9.2.2).** Composable: after any handoff only safe methods
  with no source replay, and only with no response byte seen; before handoff any method
  replays because nothing was consumed. Synchronous: idempotent methods without conditional
  headers, rewindable or retained bodies only, admission not `Response_Observed`, source
  failures excluded. Both are within the RFC's permission. The CHANGELOG's "ambiguous
  conditional mutations" fix is present (`Has_Mutation_Condition`).
- **Unix-socket transport and origin binding.** `Unix_Socket` validates through
  `Sockets.Unix_Pathname`; the Unix `Configure` overloads reject HTTPS origins and modes
  other than `HTTP_1_Only`/`HTTP_2_Prior_Knowledge`; `Start_Connect` uses the retained path
  and never DNS; `Host_Field` is derived from the origin only, brackets IPv6, and omits the
  default port. The pool is keyed by construction (one origin per client).
- **Cancellation and shutdown wiring.** `Arm_Pool`, `Arm_HTTP_3_Pump_Wait`, and the
  connect/DNS/TLS children include the shutdown wake and the token descriptor;
  `Request_Cancellation` cancels the active child or fails the exchange; `Cancelling_Child`
  finishes and releases the child before `Fail_Exchange`. `Read_Body` waits include the
  shutdown and token descriptors. Per the assignment, no helper task exists in the client
  units.
- **State lifetime.** `State_Lifetime` counts are exact; `Release_Client` plus the last
  `Release_Response` free the state exactly once; `Finish_Response_Head`'s failure path
  releases its own retention.

## Observations not counted

- `Set_Bearer` accepts a token consisting only of `=` characters (`authentication.adb:75-87`):
  the loop never requires a non-padding character, although the `.ads` says "one or more
  letters ... followed by optional '=' padding" (RFC 6750 s2.1 `b64token`). Application
  input, not network input.
- `Deadline_After (Duration'Last)` raises `Constraint_Error` from `Clock + To_Time_Span`.
  The `.ads` documents negative and zero only.
- `Execute_Redirects` raises `Redirect_Error "redirect hop limit exceeded"` before
  resolving the target, so a cross-origin redirect arriving exactly at the hop limit (or any
  redirect with `Maximum_Hops => 0` and `Follow_Same_Origin`) raises instead of being
  returned to the caller as the cross-origin rule promises.
- Composable exchanges never replay REFUSED_STREAM/GOAWAY (`Complete_HTTP_2_Unprocessed`
  completes with `Transport_Failed`); only the synchronous wrapper does. The composable
  `.ads` says these overloads share "the same ... semantics as synchronous Execute".
- `Finish` (both forms) assigns `Reply.Data` without finalizing a previously initialized
  `Reply`; a caller reusing one `Response` object across `Finish` calls leaks the previous
  lease-free record. The `Execute (..., Result : in out Response)` form finalizes first;
  `Finish` does not say either way.
- `Shutdown` uses a plain `select ... or delay Timeout` and blocks the calling pthread;
  in a lightweight lane this holds the lane for up to `Timeout`. Design, not correctness.
- `Start_Exchange:1277-1285` reads `Operation.State.Source_Length` before assigning it from
  `Declared_Length`; the stale value can only matter when `Source /= null` and
  `Expect_Continue`, which the same procedure rejects for every target that can carry a
  source, so it is unreachable.
- DNS: `Waiting_For_DNS` fails on more than 16 addresses, but the pinned resolver caps
  `Max_Addresses` at 16, so the branch is unreachable (refuted candidate).
- `Try_Checkout` calls `H2_Connections.Can_Open`/`H3_Connections.Can_Open` under the pool
  lock only on the shared-slot scan and the wake-drain scan; prior finding 37's contention
  note stands as documented, no change.
- The orphaned comment before `Finish_Close` ("Undo a reuse whose transport turned out to
  be desynchronized ...") describes a procedure that no longer exists.
