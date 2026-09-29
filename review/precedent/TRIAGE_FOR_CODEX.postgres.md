# Flyology Postgres issue triage: #31–#93

Sixty-three issues were filed on flyology-ada/flyology-postgres from a crate-wide correctness review
at commit 6f496f5. Each issue body has the mechanism, file:line locations, evidence (a spike program
and its output, or the running binary's output) and a suggested treatment. Work the layers in order:
protocol codec and server first (it decides whether stock PostgreSQL clients can talk to a Flyology
server at all), then the client session, then replication, then the SQL parser, then the examples.
Inside a layer, work P0 before P1 before P2, in the order listed. The severities below are the
reviewer's; the issue bodies state impact in prose and do not carry labels beyond `bug`.

## Ground rules for every fix

- Read `AGENTS.md` first, in particular its sections "Repository agent instructions" (the SQL
  parser rules, required test commands, validation ladder and generated-source discipline),
  "Decision authority", "Ada interface values", "Ada source style", "Review cycle" and "Commits";
  they are the contract you are fixing against. Run `apm install --frozen` and
  `apm compile --target codex` after creating a worktree, as the "Repository workflow" section
  requires, so `AGENTS.md` is current.
- One issue per branch and PR unless an item below says two issues share a fix. Problem/Solution
  commit messages, one problem per commit, no attribution footers. Reference the issue with
  `Closes #N`.
- Verification by area:
  - protocol, framing, client, server, SCRAM, replication, persistence (`src/`): `cd tests && alr -n
    build && ./scripts/test.sh`. The script needs the PostgreSQL test installation from
    `tests/scripts/ensure-postgres.sh` (`tests/.cache/postgres/`). Replication and base-backup
    changes also run `./scripts/run-replication-integration.sh` with `POSTGRES_REPLICATION_VERSIONS`
    set to each of 14.23, 15.18, 16.14, 17.10 and 18.4 in turn, matching the CI matrix.
  - anything under the SPARK proof boundary (`Flyology.Postgres.Wire`, `SCRAM_Core`): the two
    `alr gnatprove` commands in README.md, section "SPARK proof boundary". A change there is not
    done until GNATprove reports no unproved checks.
  - SQL parser (`sql/`): `cd sql/tests && ./scripts/test.sh` (generator `--check` for all five
    majors, action audit, strict build, archive-symbol assertion, runtime suite). The quick loop is
    `alr -n build && ./bin/sql_tests`. Parser changes that can affect pgish also run
    `cd examples/pgish && alr -n build && ./scripts/test.sh`.
  - examples: `cd examples/pgish && ./scripts/test.sh` and `cd examples/psqlish && ./scripts/test.sh`
    (both need the PostgreSQL test installation).
  - `git diff --check` and the repository's maintained formatter on touched handwritten Ada before
    committing. Never format or hand-edit a generated SQL package; change the generator under
    `sql/tools/`, regenerate all five majors, generate twice and confirm the second run changes
    nothing, and let `sql/tests/scripts/test.sh` run the `--check` path.
- Every fix needs a regression test that fails before and passes after. Every issue includes the
  spike that reproduced the defect; turn it into a test in the suite it belongs to rather than
  inventing a new one: `tests/src/tests.adb` for protocol, framing, client and server cases over the
  in-memory transport; `tests/src/replication_tests.adb` and
  `tests/src/replication_persistence_conformance.adb` for replication, pgoutput and persistence;
  `sql/tests/src/owned_ast_tests.adb` plus the differential corpus in
  `sql/tests/src/flyology-postgres-sql-differential_testing.adb` for the parser (the project rule is
  to add the input to both); `examples/pgish/src/pgish_tests.adb` and `examples/psqlish/tests` for
  the examples.
- Do not widen scope: an issue that asks for a one-line guard gets a one-line guard. Do not
  introduce new public constants, defaults, limits, variants or parameters without asking
  (`AGENTS.md`, sections "Ada interface values" and "Decision authority").
- Items marked DECISION need a maintainer choice before implementation; ask, do not guess.

## Confirm every finding before fixing it

The issues were written by a reviewer, not by the maintainer. Every one carries a runtime
reproduction on the reviewer's host (macOS, GNAT 16.1.0), but the interop claims about what libpq,
psql, pg_basebackup, pg_receivewal or a PostgreSQL subscriber sends were established by reading the
PostgreSQL 14.23 to 18.4 sources, not by running those programs against this library. Treat each
issue as a claim to verify, not an instruction to execute:

1. Re-read the cited locations at the current `main`, not at 6f496f5; line numbers may have moved
   and a later commit may already have changed the mechanism. Re-derive the failure scenario from
   the code yourself and write it down in the PR description in your own words.
2. Reproduce it. Rebuild the spike the issue quotes (each issue carries the essential source and
   the observed output) and confirm the output. For the interop claims, go one step further than
   the issue did: the test installation under `tests/.cache/postgres/<version>/` has real `psql`,
   `pg_basebackup`, `pg_receivewal`, `pg_recvlogical` and `postgres` binaries, so drive the real
   program against the library (the server issues) or the library against a real server (the
   client issues) and record what happened. The reproduction becomes the regression test.
3. If the reading or the reproduction disagrees with the issue, stop and report to the master with
   what you observed. The master takes it to the maintainer, who closes or amends the issue. Do not
   fix a finding you could not confirm, and do not widen a fix to cover a scenario the issue
   describes but you could not reproduce.
4. Confirm severity as well as mechanism: if a P0 or P1 turns out to need a precondition the issue
   did not state, say so in the PR and let the master reorder.

A finding confirmed by the lane, with its own reproduction, is the bar for opening a fix PR.

## Work organization: one master task, lanes of at most three

The task reading this brief is the master. It owns the queue below, the list of open DECISION items,
and the record of what each lane has merged. It does not implement issues itself; it starts lane
tasks, answers their questions, relays decisions to the maintainer, and reorders the queue when a
lane reports a dependency.

- A lane is one layer's worth of issues worked in one git worktree on one branch stack. Start with
  three lanes: **Layer 1 protocol and server**, **Layer 3 replication** (independent of Layer 1 except
  where an item says otherwise), and **Layer 4 SQL parser** (independent of everything else). Start
  **Layer 2 client** when Layer 1 has merged the server-side half of the COPY IN item
  (#41), because the client-side item (#51) is its mirror and the two
  must agree. Start **Layer 5 examples** when any lane finishes. Never run more than three lane tasks
  at once; the budget and the maintainer's review bandwidth are the limits.
- Lanes report to the master after every merged PR (issue number, PR URL, checks run) and before any
  step that changes a shared assumption: a change to `Flyology.Postgres.Protocol` or `Wire`, to the
  client or server session state machine, to a generator under `sql/tools/`, or to a public `.ads`.
  The master forwards such changes to the other live lanes so they rebase at their next PR boundary,
  not mid-branch.
- Lanes may message each other directly for coordination on a shared file, but every DECISION goes
  through the master, which asks the maintainer once and records the answer in this file.
- Serialize Alire and test-suite runs across lanes. Alire redeploys indexed releases into one shared
  cache on every command, so two lanes running `alr` at the same time corrupt each other, and the
  integration scripts start PostgreSQL instances and the example servers on ports. Use one lock (for
  example `flock` on a file under `/tmp`) around every Alire-driven command and every
  `scripts/test.sh` or integration script, or route all suite runs through the master.
- Each lane keeps its own worktree; never share a checkout, and never use bare `git stash` (the
  stash stack is shared across worktrees).

## Model first: contracts and models where they pay for themselves

This repository proves its wire core with SPARK (`proof/`) and has no TLA+ models yet, but its
`AGENTS.md` section "TLA+ assurance" sets the policy: model an algorithm whose ordering, interleaving
or liveness properties span several steps, use the `tla-plus` skill, run both TLC and TLAPM rather
than treating one as evidence for the other, replay TLC traces through the shared
`flyology-ada/tla` Ada harness as conformance evidence, and never let a finite model's bounds or
fairness assumptions become product policy. Use each where it fits; neither is a gate on the rest
of the queue.

- SPARK contracts, existing boundary. #37 (the typed-frame bound admits one byte
  more than the documented maximum) and #36 (an exhausted buffer is reported as an
  oversized one) both sit in or next to `Flyology.Postgres.Wire`. Express the corrected bound and the
  exhausted-cursor case as contracts so the wrong value is unrepresentable, and run the GNATprove
  commands. The startup-packet bound in #44 belongs there too once the maintainer
  has chosen the number.
- Bounded TLA+ models, new (DECISION: which of the two to build first, and the bounds; the
  "TLA+ assurance" policy already answers whether). Two state machines produced most of the P0 and
  P1 findings and meet that section's bar (ordering and interleaving properties across several
  steps). Each should get a `_broken` configuration that reproduces the filed bug as a TLC
  counterexample before the fix, and a TLAPM proof of the safety invariant where TLAPS can express
  it:
  - the pgoutput Producer ordering model for #56, #57,
    #58 and #59: transactions, stream segments with their xid,
    sub-transaction abort followed by continuation, interleaving of other transactions between
    segments, non-transactional messages outside any transaction, and the invariant that every
    message emitted inside a segment carries the segment's xid. Bound it to two transactions and two
    segments.
  - the client extended-protocol state machine for #50, #51,
    #53 and #54: batches, pending Syncs, per-batch descriptions and
    portals, COPY IN with a Sync the backend discards. The two receive paths (synchronous and scoped)
    must refine the same model; that is exactly the property #50 and
    #52 break.
  Until a model exists, the exhaustive message-sequence tests over the in-memory transport are the
  evidence; write them as tables of sequences, not as one-off cases. The remaining issues are
  straight-line logic or a single decode step, which that policy says are better served by
  Ada/SPARK contracts and tests than by a model.

## Layer 1 — protocol codec, framing, server session and lifecycle, SCRAM

Everything a stock client sees first. #40 must land before #35: fixing
the option reporting first would send the malformed version word to ordinary 3.0 clients.

P0
1. **#38 The first Read_Initial in Run_Session's declarative part terminates the
   whole server.** Move the read into the statement part (or wrap Process_Connection's body) so the
   existing Protocol_Error and catch-all handlers cover it. Regression test: connect-and-close probe,
   silent client past Startup_Timeout, HTTP request line; the server must keep serving afterwards.
   Same Ada mechanism as #34 and, in the examples, #90.

P1
2. **#39 TLS_Required rejects a plaintext CancelRequest, so psql's Ctrl-C never
   cancels.** Move the Cancel_Request branch above the TLS gate, as backend_startup.c does. Test with
   real psql from the test installation against the test server.
3. **#40 NegotiateProtocolVersion carries the bare minor number.** Send the full
   version word (major << 16 | minor) and rename the parameter. DECISION on the parameter's new name
   and type since it is public API.
4. **#41 Read_Copy_Command rejects Sync and Flush during COPY IN.** Ignore them as
   copyfromparse.c does. DECISION: the documented result set names Flush, Sync and Terminate events
   that `Frontend_Copy_Kind` cannot represent; either widen the type or correct the documentation.
   Coordinate with #51 (Layer 2) so both sides implement the same reading.
5. **#31 Framing.Read_Message re-arms the timeout on every transport read.** Compute
   one deadline per message and pass the remaining time to each read; correct the three
   specifications (Framing and the two Server_Sessions sentences). Regression test: a transport that
   stalls just under the timeout before each read.
6. **#46 Request_Shutdown cancels no handler under the default Drain_Timeout.** DECISION:
   cancel active handlers when the drain deadline is infinite, or change the documented promise or the
   default. The issue's Drain_Timeout => 1.0 control shows the intended behaviour.
7. **#47 The mock SCRAM exchange uses a fixed salt published in the source.** Derive
   the mock salt per role from a per-server secret, as scram_mock_salt does, and use the same
   iteration count as real roles. Also make Lookup_SCRAM_Verifier usable as an application-side
   workaround (a non-empty return must not imply Has_Credential).

P2, correctness
8. **#34 Startup replication value parsing is case- and prefix-sensitive.** DECISION:
   accept the full parse_bool grammar or document the strict set; either way the rejection must
   reach the peer as a FATAL ErrorResponse, which #38 makes possible.
9. **#36 An exhausted buffer is diagnosed as exceeding the size limit.** Split the
   Require into a size check and an exhaustion check. MODEL FIRST: a Wire contract.
10. **#43 Raw exception text is sent to peers; no 57P01 on shutdown.** Fixed message
    for internal errors; recognise Operation_Cancelled and answer 57P01 through an uncancelled path.
11. **#44 The pre-authentication startup buffer is committed before any payload
    byte.** DECISION on the bound (PostgreSQL's is 10000); then check the length before allocating.
12. **#45 The TLS transport reports the same event differently with and without an
    observer, and a zero timeout fails before any read.** One exception class per event; treat a
    zero timeout as one immediate attempt on both paths.
13. **#35 `_pq_.` options are discarded, so NegotiateProtocolVersion cannot list
    them.** DECISION: new Startup_Information field or accessor plus a Send_Negotiate_Protocol
    parameter. After #40.
14. **#48 Optional SCRAM extension attributes are rejected instead of ignored.** Skip
    unknown attributes at the three sites; keep the strict order of the mandatory ones.
15. **#49 Iteration-count bounds reject counts a PostgreSQL 16+ server can use.**
    DECISION: policy value in a public spec; the options are listed in the issue.
16. **#37 Typed messages admit a frame of Maximum_Message_Size plus one.** DECISION:
    tighten the two checks or re-document the constant. MODEL FIRST: a Wire contract.
17. Contract drift, one small PR each or one documentation PR if the maintainer prefers:
    **#32** Initial_Request accessors never raise the documented Protocol_Error;
    **#33** Decode_Initial is documented to take the complete packet;
    **#42** Serve and Serve_TLS lifecycle contracts drift from the body.

## Layer 2 — client session

The scoped (operation-based) receive and send paths came in with pull request #14 and the pipeline
mode with pull request #13; three of the six issues are divergences between the scoped path and the
synchronous path, so fix them by making the two paths share the same decision, not by patching one.

P1
18. **#50 The scoped receive derives Sync_Pending from the state instead of
    Pending_Syncs.** Use the same `Pending_Syncs > 0` rule as the synchronous path. Regression test:
    the issue's pipelined ErrorResponse and PortalSuspended sequences on both paths.
19. **#51 Extended COPY IN with a Sync pipelined before CopyInResponse miscounts the
    Sync the backend discards.** DECISION: do not count a Sync written before CopyInResponse toward
    Pending_Synchronizations (matching what the backend does), or refuse Synchronize until the COPY
    ends. Mirror of #41; land after it and test against a real server with the
    libpq sequence (PBESdcS).

P2
20. **#53 The DataRow column check uses whichever RowDescription arrived last.**
    Track the description per described statement or portal, or only check when the description
    belongs to the executing portal; clear the stale description on error.
21. **#54 One session-wide suspended-portal flag rejects valid multi-portal
    sequences.** Track suspension per portal name.
22. **#52 The scoped Send_Query bypasses the pipeline-mode rejection.** Apply the
    same check as the synchronous overload.
23. **#55 A rejected plaintext startup leaves the session Not_Started.** DECISION:
    set Closed as the TLS path does, or document Not_Started as retryable and make the retry safe.

## Layer 3 — replication: pgoutput Producer, replication commands, persistence and consumers

P0
24. **#56 The Producer accepts a non-streamed data message inside an open stream
    segment and emits it without the xid prefix.** Reject it, or stamp the open segment's xid. One
    branch with items 25 and 26: the Producer's ordering model is the defect. MODEL FIRST.

P1
25. **#57 The Producer models one in-flight xid and treats every Stream Abort as
    terminal.** Track the top-level xid separately from sub-transaction aborts; allow interleaving
    of other transactions between segments. MODEL FIRST.
26. **#58 A non-transactional logical decoding message is rejected outside a
    transaction.** Accept it in the Idle state, which is the only place pgoutput emits it.
27. **#61 Valueless TWO_PHASE and FAILOVER slot options are rejected.** Treat a bare
    option as true, as defGetBoolean does. `tests/src/replication_tests.adb:427-429` asserts the
    current rejection and must change.
28. **#62 TEMPORARY and PHYSICAL slot creation cannot be decoded.** Accepting
    TEMPORARY in its grammatical position is a parser fix; representing a physical slot needs a new
    Command_Kind variant and a RESERVE_WAL accessor: DECISION. Test with real pg_basebackup against
    the managed primary.
29. **#63 A standby-initiated CopyDone raises Protocol_Error.** DECISION: a
    CopyDone-carrying result from Read_Standby_Message, or a distinct end-of-stream signal; either
    way the slot must be advanced to the feedback already reported. Test with real pg_receivewal.
30. **#67 The retention floor is order-dependent when a live slot restarts at zero.**
    Separate the "no candidate" sentinel from a zero LSN. Regression test: both creation orders in
    the conformance fixture, and a retention pass that must not discard WAL a live slot needs.
31. **#66 Promote stores only the newest timeline history line.** Copy the parent's
    history before appending, as writeTimeLineHistory does. Regression test: two promotions, and a
    real PostgreSQL standby following through both (the replication integration script has the
    scaffolding).
32. **#70 Prepare overwrites a Target_Applied marker for the same GID.** Do not demote
    an existing applied marker; handle GID reuse after commit as a distinct transaction.
33. **#69 Generation keeps returning the stale lease after Release.** DECISION: clear
    the lease on Release, or re-document Generation as a retained fencing epoch.

P2
34. **#59 Begin/Commit and BeginPrepare/Prepare LSN agreement is unchecked.**
    DECISION: enforce (a PostgreSQL apply worker rejects the mismatch) or document; the unit test at
    `tests/src/replication_tests.adb:1387-1397` currently asserts the mismatched pair is accepted.
35. **#60 A constructed Stream Abort cannot report its own v4 metadata.** Set
    Parallel_Stream in the constructor when the metadata is supplied.
36. **#64 Replication SHOW rejects dotted GUC names.** Accept `var_name '.' IDENT`.
37. **#65 IDENTIFY_SYSTEM declares the timeline column int4 for every peer.** DECISION
    on how the peer major reaches Send_Identify_System; then int8 for 16 and later. Shares its
    shape with #72.
38. **#72 The base backup position result set declares tli as int4.** Unconditional
    int8 (all five majors agree).
39. **#68 Append on a drained store rewinds Current_LSN.** DECISION: keep the drained
    end position and raise Store_Error, or document that a drained store may be rebased.
40. **#71 Create accepts an active or invalidated snapshot as initial state.** One
    more clause in the existing validation.

## Layer 4 — SQL parser: scanner, semantic actions, diagnostics

Every file here is generated; fix the generator or its per-major input, regenerate all five majors,
generate twice, and add each issue's SQL to both the owned corpus and the differential corpus so the
C oracle keeps checking it. Run the pgish suite as well, since pgish validates with the 18 grammar.

P1
41. **#74 Octal escapes above `\377` fail with a GNAT range-check message.** Truncate to
    the low byte as scan.l's `unsigned char` does. All majors.
42. **#73 `E'\v'` unescapes to the letter v on PostgreSQL 17 and 18.** The shared
    scanner body has no major; either give it one or generate the escape table per major. DECISION
    on which, since it changes the generator's shape.
43. **#81 The PostgreSQL 18 parameter-number limit is applied to 14 through 17.** Gate
    the range check on the major. Same generator shape question as item 42; do them together.
44. **#78 v14 doNegate folds a minus sign into string and bit-string constants.**
    Check the node's type before folding, as gram.y does. PostgreSQL 14 only.
45. **#82 Diagnostic cursors are byte offsets, not character offsets.** Convert the byte
    offset to a character count before publishing, as scanner_errposition does. The README's
    "preserves cursor positions" claim becomes true.

P2
46. **#79 Grammar ereport errors lose their position and format arguments.** Teach
    `generate_native_actions.py` to carry the parser_errposition argument and to substitute the
    printf arguments. The expected cursor is major-dependent for two templates; the issue says which.
47. **#80 Scanner diagnostics quote the rest of the input; the zero-length identifier
    cursor is off by one.** Quote only the matched token; report the identifier at its opening quote.
48. **#75** `\U` escapes at or above 0x80000000 overflow Natural (accumulate in a wider
    type and let the Unicode check reject it); **#76** escape strings assembling invalid
    UTF-8 are accepted (add the pg_verifymbstr equivalent after an escape produced a NUL or high-bit
    byte); **#77** the UESCAPE character check misses form feed and, on 17 and 18,
    vertical tab.

## Layer 5 — examples: pgish and psqlish

P1
49. **#83 pgish `LIKE '%'` raises Pattern_Error.** Treat an empty needle as
    match-all; never call Index with an empty pattern.
50. **#84 pgish evaluates NOT LIKE as LIKE.** Consult the operator name (`!~~`) or
    reject the statement.
51. **#85 pgish ORDER BY compares integer columns as text.** Use the column's type
    OID in Sort.Before as Matches already does.
52. **#87 information_schema.columns is unusable without a table_name equality.**
    Apply projection, filters and LIMIT before the row cap, or push every filter down.
53. **#89 Phantom sessions refuse admission with a false 28P01.** DECISION: an
    example-side fix (release the registry slot when the handler's connection ends, which needs a
    way to observe that) or a library-side disconnect hook in the Server generic. Test: sixteen
    abrupt disconnects followed by sixteen fresh connections.
54. **#86 psqlish raises Constraint_Error on any zero-column result.** Change the
    two Positive narrowings to Natural; Display already handles an empty column array.

P2
55. **#93** `SELECT *` with no FROM produces a zero-column row (reject with
    42601 as PostgreSQL does); **#92** empty and comment-only queries are answered
    with 42601 instead of EmptyQueryResponse (guard on whitespace of every kind and on a parsed tree
    with zero statements, on both the Query and the Parse branch); **#88** quoted
    identifiers are case-folded and qualifiers ignored; **#90** option and
    environment errors bypass the main handler (same mechanism as #38);
    **#91** psqlish expanded output misaligns field names.

## Explicitly out of scope

Issue #1 (sslnegotiation=direct) is a feature request on the startup path; do not fold it into
#38 or #39.
