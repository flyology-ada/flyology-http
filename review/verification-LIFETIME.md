# Verification: LIFETIME

Commit: f078732

Findings examined: 4. Confirmed: 2. Refuted: 0. Partial: 1. Other: 1
(LIFETIME-4 is the same defect as CLIENT-POOL-8, which is primary).

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| LIFETIME-1 | P2 | PARTIALLY CONFIRMED (omission yes; every runtime consequence the entry claims, no) | P2 | none possible — see entry |
| LIFETIME-2 | P2 | CONFIRMED (all four claimed evasions, plus a fifth) | P1 on the test-integrity axis; P2 if forced onto the product rubric | `repro_lifetime_2.sh` (shell) |
| LIFETIME-3 | P2 | CONFIRMED, and stronger than recorded: both `.ads` sentences are false, not merely unpinned | P1 | `repro_lifetime_3`, with controls `repro_lifetime_3b`/`3c`/`3d` |
| LIFETIME-4 | P2 | DUPLICATE of CLIENT-POOL-8 (primary); on its own terms DOCUMENTED LIMITATION | P2 | none, and none manufactured |

The discovery reviewer said "I found nothing I could honestly rate higher." That
restraint was right on two of four and wrong on two, in opposite directions:

- **LIFETIME-1 is weaker than written.** Three of the entry's four claimed
  consequences do not hold. The omission is real; its blast radius is nil.
- **LIFETIME-3 is stronger than written.** The entry's own caveat — "I could not
  compile a negative case" — was the load-bearing uncertainty. I compiled it.
  Both `.ads` sentences claim an enforcement that does not exist, and a control
  build proves the compiler *would* have enforced it had the code not used
  `'Unchecked_Access`.

Run everything from the worktree root:

```sh
./tests/repros/repro_lifetime_2.sh          # shell; no Ada build; BUG REPRODUCED
./tests/repros/run.sh repro_lifetime_3 60   # BUG REPRODUCED
./tests/repros/run.sh repro_lifetime_3b 60  # control: BUILD FAILED (expected)
./tests/repros/run.sh repro_lifetime_3c 60  # control: BUILD FAILED (expected)
./tests/repros/run.sh repro_lifetime_3d 60  # BUG REPRODUCED
```

## LIFETIME-1: finalizing an unread HTTP/3 `Response` never releases its stream

- **Verdict:** PARTIALLY CONFIRMED. The code omission is certain. The failure
  scenario built on it is not: of its four steps, step 4 is wrong in both of its
  halves, and the "stall a connection" question the brief asked me to settle
  answers **no**.
- **Severity:** P2 (discovery said P2; unchanged, but for weaker reasons than the
  entry gives). It is not P1: there is no reachable path on which a caller or a
  peer observes anything different.
- **Repro:** none, and **none is constructible**. See "Why no spike" below; this
  is not a budget excuse, it is a property of the defect and is itself the
  strongest evidence for the severity.

### What is true

`Abandon_Response` (`src/flyology-http-client.adb:2151-2170`) really does nothing
but `Reusable := False` on the `HTTP_3_Response` branch, while the two sibling
teardown paths both release the stream:

- `Release_Exchange_Transport` (`client.adb:762-802`, the H3 branch of a procedure spanning `:694-850`) — `Release_Pump` when owned,
  `Cancel_Stream` when `not State.HTTP_3_Finished`, then `Release_Stream`, each in
  its own handler.
- normal body completion (`client-http_3_internals.adb:442-449`) — `Release_Stream`
  then `Release_Lease`.

The `Response` really is the sole holder of the handle by then. One correction to
the entry's citation: the transfer is in **`Finish_Response_Head`**
(`client.adb:1123-1207`, allocation at `:1167`), not `Finish_Success`
(`:1098-1121`). `Finish_Success` builds a `Response_Data` with `Complete := True`
and calls `Release_Exchange_Transport` itself, so a `Response` from that path
holds no lease and `Abandon_Response` returns at its first line. Only the
`Response_Head_Target` path produces a `Response` that can reach the H3 branch at
all — and that is what every `Execute` overload uses: `client.adb:6726-6779` →
`Execute_Redirects` (`:6596`) → `Execute_Operation_Once` (`:6423-6594`), which
starts the exchange with `Target => Response_Head_Target` at `:6487-6497`.

### What is not true

**1. "nothing signals the peer" is not a difference between the paths.**
`H3_Connections.Cancel_Stream` (`http_3_client_connection.adb:582-592`) is purely
local bookkeeping:

```ada
      procedure Cancel_Stream (Handle : Stream_Handle) is
      begin
         if Valid (Handle) then
            Streams (Handle.Slot).Phase := Failed;
            if Pump_Owner = Handle.Slot then
               Pump_Owner := 0;
               Wake_Pump;
            end if;
            Wake_Stream (Handle.Slot);
         end if;
      end Cancel_Stream;
```

It writes nothing to the wire. The only client-side site that emits a QUIC stream
abort is `H3.Cancel_Request` in the `HTTP_3_Cancel_Request` driver stage
(`client.adb:5232-5260`), reached from `Fail_Exchange` (`:1073-1092`) and from the
request-incomplete path (`:3954-3967`) — that is, only while the *exchange* is
alive. No `Response` finalization on any engine reaches it. So the composable
path the entry holds up as correct does not signal the peer either, and the
server keeps sending the unwanted body in exactly the same way after
`Release_Exchange_Transport`. This removes the entry's RFC 9114 §4.1.1 angle: the
omission does not change what the peer sees.

**2. The leaked slot cannot stall a connection.** The brief asked me to settle
this. Two independent reasons:

- `Abandon_Response` forces `Reusable => False` for H3, so `Return_Lease`
  (`pool_controller.adb:370-435`) moves the `Shared` slot to `Draining` on the
  first abandonment. `Try_Checkout` offers only `Phase = Shared` (`Select_Shared`,
  `:113-171`) and `Phase = Idle` (`Select_Idle`, `:156-203`); a `Draining` slot is
  never handed out again. No later exchange can ever need the leaked slot, so
  leaked slots cannot accumulate toward `Maximum_Concurrent_Streams = 32`
  (`http_3_client_connection.ads:13`). When the last sibling returns, the slot
  goes `Closing` → `Return_Close` → `Close_And_Finish` → `Dispose_Connection`, and
  the whole session, leaked slots included, is freed.
- The abandoned `Response` holds **no pump**, so it cannot deny the pump to a
  sibling. `Finish_Response_Head` releases it before the transfer
  (`client.adb:1155-1165`), and in the synchronous read path `Pump_One` and
  `Return_Credit_If_Due` each claim and release it inside a handler
  (`client-http_3_internals.adb:308-405`). This matters because
  `Try_Claim_Pump` (`http_3_client_connection.adb:155-176`) refuses a claimant
  while any *other* slot has `Outbound_Pending`, and `Release_Stream` is what
  clears that flag (`:614`) — a genuine stall shape, but one the pump-release
  ordering closes before a `Response` ever exists.

**3. The unread bytes do not pin connection-level credit.** The QUIC layer
consumes each DATA frame when `Poll` decodes it, before `Publish` copies it, so
credit keeps flowing regardless of whether an owner reads. When the abandoned
slot's 65,535-byte ring is exceeded, `Publish` sets `Phase := Failed`
(`http_3_client_connection.adb:411-424`) and simply stops copying; nothing
propagates to the sibling.

### Residue

One thing the entry gets right that survives everything above: the `.ads` sentence
(`client.ads:485-490`) "finalizing an incomplete HTTP/1.1 or HTTP/3 response
**closes its transport**" is not satisfied when a sibling H3 stream is live. With
no sibling it is (the slot goes straight to `Closing` and the connection is
disposed). With a sibling the transport is *drained*, and the abandoned stream is
neither reset nor released inside it. That is contract drift needing an unusual
input — two overlapping H3 exchanges, one dropped unread — which is P2.

### Why no spike

A harness spike must assert the correct behaviour and flip from exit 1 to exit 0
once the defect is fixed. The fix here is one `Release_Stream` call, and **nothing
observable through any public API changes when it lands**:

- the pool returns to the same state either way (the slot is already `Draining`);
- `Client.Diagnostics` (`client.ads:165-169,1212`) reports exchanges and reusable
  transports, neither of which counts H3 stream slots;
- the peer sees identical bytes before and after the fix, per point 1 above;
- `HTTP_3_Client_Connection` is a `private package`, and the live `Session` lives
  in `Flyology.HTTP.Client`'s **body**, so no child unit can reach it either.

A spike that watched the server keep streaming would reproduce something real but
would still fail after the fix, which is exactly the "softened assertion" the
brief warns against. I am recording the absence instead.

- **Fix shape, for the maintainer:** give the `HTTP_3_Response` branch of
  `Abandon_Response` the same guarded `Release_Pump` / `Cancel_Stream` /
  `Release_Stream` sequence `Release_Exchange_Transport` uses. It is safe:
  `Publish` already ignores events for a released stream ("A late event for a
  released stream is stream-local and does not poison concurrent exchanges",
  `http_3_client_connection.adb:292-295`).

### Relationship to the other areas (the brief asked)

- **`review/discovery-H3-QPACK.md` H3-QPACK-4 is a different defect.** That is the
  *server* role leaking a `Sending` slot in `src/flyology-http-http_3_connection.adb`
  because `Release_Message` clears `Sending` only when `Local_Role = Client`. It is
  CONFIRMED P1 with its own spike (`repro_h3_qpack_4`) and a hard symptom — the
  connection answers exactly 32 requests and then goes mute. LIFETIME-1 is the
  *client* role failing to call `Release_Stream` in `src/flyology-http-client.adb`.
  Different file, different role, different table, no shared cause. Not a
  duplicate.
- **`review/discovery-CLIENT-POOL.md` CLIENT-POOL-7 and -8 are also different**
  from LIFETIME-1: both are about a lease that is never *returned*, whereas
  LIFETIME-1 returns the lease correctly and leaks only the stream slot inside the
  still-live session. CLIENT-POOL-8 *is* the same defect as LIFETIME-4; see there.

## LIFETIME-2: the "no helper task in client units" gate fails open and is evadable

- **Verdict:** CONFIRMED. All four evasions the entry claims reproduce, and a
  fifth does too.
- **Severity:** **P1 on the test-and-CI-integrity axis; P2 if forced onto the
  product-correctness rubric** (discovery said P2). Being explicit rather than
  splitting the difference: no product behaviour is wrong at f078732 — the
  invariant holds, as my own control run confirms — so under a rubric whose P1 is
  "wrong result ... on valid input" this is not P1, and its P2 line names "wrong
  diagnostics". But the rubric has no class for *a check that cannot fail*, and
  treating this as an ordinary P2 understates it: one of the six evasions is
  unconditional (no `rg`, no failure, ever) and two others (keyword case, a line
  break) are reachable by ordinary formatting, so the gate has no detection power
  left to speak of. The property it guards is stated publicly —
  `website/guide/client/index.html:344` "the composable path creates no helper
  task or thread", `:383` "the client creates no connector or protocol-pump helper
  task", and `src/flyology-http-http_3_client_connection.ads:8` "Bounded,
  task-free coordination". I am rating it P1 and saying exactly which scale that
  is on, so the coordinator can file it wherever gate defects belong.
- **Repro:** `tests/repros/repro_lifetime_2.sh` — a **shell reproduction**, not an
  Ada spike, as the brief allows. It does not build anything. Run it with:

```sh
./tests/repros/repro_lifetime_2.sh
```

  It lifts the gate **verbatim** out of the tracked script (`sed -n '74,84p'
  scripts/test.sh`) rather than retyping it, so it cannot drift from the file it
  tests, and it runs the gate against sandboxes built from real copies of the
  globbed sources.

- **Output:**

```
  note gate extracted from scripts/test.sh:74-84
  ok   control: lowercase 'task Probe;' is rejected (exit 1)
  ok   control: unmodified sources pass (exit 0) -- the invariant holds at HEAD
  FAIL no rg on PATH: gate PASSED a tree containing 'task Probe;' (exit 0)
  note rg exits 127 inside the if condition; set -e does not fire there
  FAIL capitalised 'Task Probe;' was NOT rejected (exit 0)
  FAIL upper-case 'TASK TYPE Probe;' was NOT rejected (exit 0)
  FAIL 'task' + newline + name was NOT rejected (exit 0)
  FAIL Task_Scopes instantiation in a client unit was NOT rejected (exit 0)
  FAIL task in withed sibling units (http_1_internals, websocket_client, http_3) was NOT rejected (exit 0)
  note the three globs do not cover them
checks: 8  failures: 6
BUG REPRODUCED
exit status 1
```

- **Description:** The gate is `if rg -n '<pattern>' <three globs>; then ... exit 1; fi`
  at `scripts/test.sh:74-84`, under `set -eu`. Both controls pass, which is what
  makes the six failures mean something: the extraction is faithful (a plain
  lowercase `task Probe;` *is* rejected, exit 1) and the invariant genuinely holds
  at f078732 (the unmodified tree passes). Then:
  1. **Fail-open.** With `rg` off `PATH`, the command exits 127 *inside an `if`
     condition*, where `set -e` does not fire; the `if` takes the false branch and
     the script walks on. A tree containing the exact violation the gate was
     written for passes. `rg` is used **exactly once in the whole repository** —
     this line — and nothing checks for it: not `scripts/test.sh`, not
     `scripts/alire-test-context.sh`, not `scripts/find-alr.sh`, not
     `tests/alire_action_context.sh`, and no CI step installs it
     (`.github/workflows/ci.yml:63-112`, the `ubuntu-latest`/`macos-latest` test
     matrix, has no such step). Whether the hosted runner images happen to ship
     ripgrep is a property of a third party I cannot check against a pinned peer;
     what the repository controls is that the gate's correctness rests on an
     undeclared tool, and that a developer running `./scripts/test.sh` without it
     gets a silent pass.
  2. **Case.** Ada reserved words are case-insensitive (RM 2.9(1)); the pattern is
     case-sensitive. `Task Probe;` and `TASK TYPE Probe;` both slip through.
  3. **Line break.** `task` on one line and the name on the next is legal Ada and
     does not match `task[[:space:]]` on a single line.
  4. **Indirection.** `package Helpers is new Flyology.Task_Scopes (...)` contains
     no `task` keyword. The pinned runtime's `Task_Scopes` allocates its workers in
     `Configure` (`flyology-task_scopes.ads:66`; the `Worker` task type at `:164`), so this is the most
     plausible shape a future client-side helper task would take.
  5. **Not in the entry — scope.** The three globs cover
     `src/flyology-http-client*`, `-http_2_client_connection*` and
     `-http_3_client_connection*` only. A `task` declared in
     `src/flyology-http-http_1_internals.adb`,
     `src/flyology-http-websocket_client.adb` or `src/flyology-http-http_3.adb`
     — all withed from the client — is not scanned at all, in any case, with `rg`
     present.
- **Fix shape:** require the tool (`command -v rg >/dev/null || exit 1`), or drop
  the dependency and use `grep -REi` with `-i` for the case rule, widen the file
  set to the client's actual closure, and invert the test so a missing tool is a
  failure rather than a pass.

## LIFETIME-3: two `.ads` sentences claim an enforcement Ada does not perform

- **Verdict:** CONFIRMED, and materially stronger than the entry records. The
  entry's confidence caveat was "I could not compile a negative case to confirm
  whether GNAT rejects each escape statically or only at run time". The answer is
  **neither**: for the cancellation token, no check fires at all — not statically,
  not at run time.
- **Severity:** **P1** (discovery said P2; raised). Rubric P1 covers "a documented
  contract violated (`.ads` comment ...)". This is not drift and not missing
  coverage: `src/flyology-http-server-request_tasks.ads:29-31` states a property
  of the language that is false for the exact idiom it mandates, and
  `src/flyology-http-server-applications.ads:63-65` states the same for one of the
  three things it lists. Being fair to the discovery's instinct: the practical
  blast radius is small, because the natural handler idiom
  (`tests/http_smoke.adb:4369-4370`) declares the scope locally where nothing can
  escape. The reason to rate it P1 anyway is that the sentence is the stated
  justification for there being no run-time check, so a reader who believes it is
  told not to be careful.
- **Repro:** `tests/repros/src/repro_lifetime_3.adb`, with three control builds.

```sh
./tests/repros/run.sh repro_lifetime_3 60    # BUG REPRODUCED: the escape compiles and runs
./tests/repros/run.sh repro_lifetime_3b 60   # BUILD FAILED: control, the rule IS live
./tests/repros/run.sh repro_lifetime_3c 60   # BUILD FAILED: Request/Connection ARE checked
./tests/repros/run.sh repro_lifetime_3d 60   # BUG REPRODUCED: the token alone is NOT checked
```

  **Read the last lines, not the process status.** `run.sh` uses exit 2 for a
  build failure, but it re-executes itself under `alr exec`, and `alr` reports a
  non-zero child as its own exit 1. Every one of the four runs therefore leaves
  the shell with status 1. The two outcomes are distinguished by the output: a
  rejected build ends with `BUILD FAILED: <name>` and
  `ERROR: Command [...] exited with code 2`, while a reproduced bug ends with
  `BUG REPRODUCED` and `exited with code 1`.

  Per the brief, for these programs a **build failure is the expected, passing
  result** — it means the compiler rejected the escape, so the contract holds —
  and a run that reaches `BUG REPRODUCED` means the escape compiled and ran, so
  the contract is false. `3b` and `3c` are controls for `3`; `3d` settles the
  second `.ads` sentence. None of them is a separate finding.

- **Output — `repro_lifetime_3` (the escape the `.ads` says Ada rejects):**

```
  note request_tasks.ads:29-31 claims Ada enforces the request-token
  note borrow; applications.ads:63-65 claims access discriminants let Ada
  note reject an exchange that outlives its token.  Neither has a
  note tests/compile_fail case (scripts/test.sh:275-305 pins three others).
  ok   fixture request parsed
  FAIL a Scope whose Parent is X.Cancellation cannot outlive the token
  note the allocator compiled and ran; no accessibility check fired
  note Escaped.Parent now designates a token that is about to die
  FAIL no Scope survives the cancellation token it borrowed
checks: 3  failures: 2
BUG REPRODUCED
exit status 1
```

- **Output — `repro_lifetime_3b`, the control (identical program, `Parent =>
  Stop'Access` instead of `Parent => X.Cancellation`):**

```
repro_lifetime_3b.adb:164:42: error: prefix of attribute has deeper level than allocator type

   compilation of repro_lifetime_3b.adb failed
BUILD FAILED: repro_lifetime_3b
ERROR: Command [...] exited with code 2
```

- **Output — `repro_lifetime_3c`, allocating an `Exchange` that outlives its
  request and connection:**

```
repro_lifetime_3c.adb:158:25: error: actual for aliased formal "Value" has wrong accessibility in allocator (RM 6.4.1(6.4))
repro_lifetime_3c.adb:159:25: error: actual for aliased formal "Item" has wrong accessibility in allocator (RM 6.4.1(6.4))

   compilation of repro_lifetime_3c.adb failed
BUILD FAILED: repro_lifetime_3c
ERROR: Command [...] exited with code 2
```

- **Output — `repro_lifetime_3d`, the same allocation with the request and
  connection at the allocator's own level so that only the *token* is deeper:**

```
  ok   fixture request parsed
  FAIL an Exchange cannot outlive its request, connection or token
  FAIL no Exchange survives the request it borrowed
checks: 3  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description.** The four runs read as one experiment.

  `3b` establishes that the accessibility machinery is live for
  `Operations.Scope`'s `Parent` discriminant: with a direct `Stop'Access` the
  compiler rejects the allocator with *precisely* the diagnostic this repository
  already pins for the WebSocket session pool
  (`scripts/test.sh:299-302`, `tests/compile_fail/websocket_pool_lifetime_fail.adb`).

  `3` is the same program with the one substitution the `.ads` sentence
  **mandates** — "Item must be declared with `Parent => X.Cancellation` so Ada
  enforces the request-token borrow" — and it compiles, runs, and leaves a
  heap-allocated `Scope` whose `Parent` designates a `Flyology.Cancellation.Token`
  that goes out of scope one line later. The mechanism is visible in one line of
  `src/flyology-http-server-applications.adb:122-126`:

```ada
   function Cancellation
     (Item : Exchange) return access Flyology.Cancellation.Token
   is
     (if Item.Token_Handle = null then null
      else Item.Token_Handle.all'Unchecked_Access);
```

  `'Unchecked_Access` exists to suppress exactly the check the sentence promises
  (RM 13.10 / RM 3.10.2). So the recommended idiom is the one with no enforcement,
  and the enforcement the sentence describes is only available through the idiom
  it does not recommend. Nothing downstream replaces it: `Request_Tasks.Configure`
  (`src/flyology-http-server-request_tasks.adb:3-10`) forwards `X.Deadline` and
  nothing else, and never compares `Item.Parent` with `X.Cancellation`, so a
  `Scope` configured with `Parent => null` or a foreign token is accepted and its
  children are linked to that token's fate instead of the request's — while the
  comment four lines above says "Inherit the Exchange cancellation identity".

  `3c` and `3d` settle the second sentence,
  `applications.ads:63-65` — "Access discriminants let Ada reject an exchange whose
  request, connection, or token would not outlive it". Two thirds of it hold:
  `Request` and `Connection` are `aliased in out` formals of `Create`, and GNAT
  rejects an exchange allocated above them under RM 6.4.1(6.4). The third does not:
  with only the token deeper, the same allocator compiles and runs, and no
  `Program_Error` is raised either, so the token discriminant is unchecked at both
  compile time and run time. I am reporting the observation and not claiming a
  compiler non-conformance; what matters here is that the sentence lists three
  things and enforces two.

  The entry's provable half — no `compile_fail` case pins either claim — also
  holds by inspection: `tests/compile_fail/` contains exactly
  `http_client_response_lifetime_fail.adb`,
  `http_client_body_source_lifetime_fail.adb` and
  `websocket_pool_lifetime_fail.adb`, matching the three `grep -E` pins at
  `scripts/test.sh:275-305`.

- **Existing coverage:** `tests/http_smoke.adb:4342-4380` is the only
  `Request_Tasks` test and is a happy path: it spawns two children and checks
  20 * 2 + 1 * 2 = 42. It never requests `X.Cancellation`, never narrows
  `X.Deadline`, and so asserts neither half of "Inherit the Exchange cancellation
  identity and current absolute deadline".
- **Fix shape, for the maintainer.** Three independent options, in increasing
  order of strength: (a) correct the two sentences to say what is actually
  enforced; (b) have `Request_Tasks.Configure` raise `Program_Error` when
  `Item.Parent /= X.Cancellation` — `Item.Parent` and `X.Cancellation` are a
  comparable anonymous-access pair, so this is one line and turns the doc's "must"
  into a check; (c) add `tests/compile_fail/request_task_scope_lifetime_fail.adb`
  pinned on `deeper level than allocator type`, which only becomes possible once
  `Cancellation` stops returning `'Unchecked_Access`.

## LIFETIME-4: `Abandon_Response`'s HTTP/2 teardown is unguarded before `Release_Lease`

- **Verdict:** **DUPLICATE of CLIENT-POOL-8**, which is the primary entry, plus
  DOCUMENTED LIMITATION on the part that is its own. No reproduction, and I did
  not manufacture one.
- **Severity:** P2 (discovery said P2; unchanged).
- **Repro:** none. The brief's instruction applies: no reachable trigger was
  found, so this is the honest verdict.

- **Why it is the same defect as CLIENT-POOL-8.** Both entries describe one
  failure: *a raise inside `Abandon_Response` leaves the pool lease counted
  forever, because `Response.Finalize`'s handler frees the `Response_Data` without
  returning it.* CLIENT-POOL-8 (`review/discovery-CLIENT-POOL.md:409-431`) writes
  it from the handler's side (`client.adb:7387-7401`); LIFETIME-4 writes it from
  the raising call's side (`client.adb:2157-2163`). Same procedure pair, same
  consequence (`Await_Drained` never opens, `Shutdown` hangs or raises
  `Timeout_Error`, `Client_State` never freed), same precondition (an
  `H2_Connections` primitive must raise), same missing seam.
  `review/verification-CLIENT-POOL.md` already carries it as PARTIALLY CONFIRMED
  with the exact fault-injection point that would settle it. **Primary:
  CLIENT-POOL-8.** I am not duplicating the spike.

- **What LIFETIME-4 adds and CLIENT-POOL-8 does not have.** A different and
  simpler fix. The asymmetry is deliberate elsewhere in the same file:
  `Release_Exchange_Transport` wraps *every* one of these calls in
  `exception when Error : others => May_Reuse := False; Save (Error);`
  (`client.adb:694-850`; the guarded H2 calls at `:730-748` and the H3 branch at `:762-802`, shown under LIFETIME-1).
  `Abandon_Response` wraps none. Guarding the three calls there so `Release_Lease`
  always runs is local and needs no new state, and it closes the window without
  touching `Response.Finalize`'s handler at all.

- **Trigger search, and why it came up empty.** I traced every call in the branch:
  - `H2_Connections.Is_Usable (Data.Connection.HTTP_2.all)` — a null `HTTP_2`
    would be `Constraint_Error`, but `Data.Connection` is nulled only by
    `Release_Lease`, and a connection whose lease is outstanding is never
    disposed: `Take_Active_For_Interrupt`/`Finish_Interrupt`
    (`pool_controller.adb:543-597`) transfer disposal only after the holder has
    already moved the slot to `Closing` with `Owner_Done`.
  - `H2_Connections.Cancel_Stream` (`http_2_client_connection.adb:2366-2373`) →
    the protected `Cancel_Stream` (`:1625-1649`), whose only fallible statement is
    `Queue_Control_Frame` appending a RST_STREAM to `Control_Output :
    Bytes.Unbounded_Bytes`, i.e. `Storage_Error` on heap exhaustion; then
    `Drivers.Signal (Item.State.Outbound)` →
    `Flyology.Wake_Sources.Signal` → `Ensure` (pipe creation, so EMFILE/ENFILE)
    and `Signal_Borrowed`, which raises `Program_Error with "cannot signal
    borrowed wake source"` only when `write` fails with an errno other than
    EAGAIN or EINTR (`flyology-wake_sources.adb`, pinned runtime
    `flyology_0.1.1_bd95746d`).
  - `H2_Connections.Release_Stream` (`:1651-1670`) — `Buffered_Data - Unread`
    could raise `Constraint_Error`, but only from an already-broken accounting
    invariant.
  Every one of these is heap or file-descriptor exhaustion, or an invariant that
  is already violated. None is "valid input via a reachable path", and none is
  reachable in-process without the fault-injection seam that does not exist. What
  would settle it is what CLIENT-POOL-8's verification already names: an injection
  point in `H2_Connections.Cancel_Stream` or `Release_Stream`, then a test that
  finalizes a `Response` holding an HTTP/2 lease while that primitive raises,
  asserting `Client.Shutdown` completes and `Diagnostics.Active_Exchanges` returns
  to zero.

## Findings sweep beyond the four entries

Nothing new rose to a finding. Recorded so the maintainer knows it was looked at:

- **The discovery's `Finish_Success` citation under LIFETIME-1 is wrong** — the
  stream-handle transfer is in `Finish_Response_Head` (`client.adb:1123-1207`).
  Corrected in place above; it does not change that entry's conclusion.
- **`H3_Connections.Cancel_Stream` sends nothing to the peer.** This makes the
  *composable* H3 abandonment path (`Release_Exchange_Transport`) equally silent
  toward the server. It is not a separate defect — nothing documents a client-side
  H3 reset, and RFC 9114 §4.1.1 permits not sending one — but it does mean the
  repository has no path at all by which a dropped H3 response tells the server to
  stop, which is worth knowing when H3-QPACK-9 (server stream-credit refill) is
  triaged.
- **`scripts/test.sh` has exactly one `rg` invocation** in the whole `scripts/`
  and `tests/*.sh` surface. Removing the dependency costs nothing elsewhere.
- **The `compile_fail` harness itself is sound**: each case must both fail to
  compile *and* match a pinned `grep -E` diagnostic under `set -e`, so a case that
  stops compiling for an unrelated reason fails the suite. The gap is only that
  two claims have no case, which is LIFETIME-3.
