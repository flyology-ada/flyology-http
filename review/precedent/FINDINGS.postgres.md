# Flyology Postgres correctness review — findings

Date: 2026-09-04

Every finding below was filed as a GitHub issue on flyology-ada/flyology-postgres (#31 to #93);
the finding-to-issue mapping is in `review/ISSUES.md`, and the Codex triage brief in
`review/TRIAGE_FOR_CODEX.md`.

## Scope and method

This document consolidates a correctness review of Flyology Postgres, an Ada 2022
PostgreSQL protocol library. The review covered the core library under `src/`, the
SQL parser under `sql/`, and the three examples `pgish`, `psqlish` and `psqlbench`.
Nine per-area discovery reviews produced candidate findings. Every candidate was
then verified adversarially by an independent agent, which re-derived each claim
from the source rather than from the discovery text. Where the claim depended on
server or client behaviour, the verifier read the cached PostgreSQL 14.23 to 18.4
sources and, for SQL, the pinned C oracle. Only confirmed findings are listed here.
Each confirmed finding has a runnable reproduction program that asserts the correct
behaviour and fails on the current sources.

The severity rubric used throughout:

- **P0** — memory or aliasing unsafety, security-relevant, hang or deadlock in
  normal operation, data-loss-class invariant violation, or interop-breaking
  protocol violation.
- **P1** — wrong result or unexpected exception on valid input via a reachable
  path, or a documented contract violated.
- **P2** — edge-case incorrectness, wrong diagnostics, or contract drift needing
  unusual input.

The severities in this document are the verifier's corrected ones. Where a
verifier raised, lowered or re-scoped a discovery severity, that is recorded in the
finding's Notes.

## How to reproduce

Three reproduction harnesses were added, one per area group. Each program asserts
the correct behaviour, so on the current sources it prints `BUG REPRODUCED` and
exits 1. After a fix it prints `PASS` and exits 0. A hang is reported as exit 124
by the harness `timeout` wrapper. Exit 2 means a build failure.

| Harness | Run one program | Run all |
| --- | --- | --- |
| `tests/repros` (core library) | `./run.sh repro_<id>` | `./run-all.sh` |
| `sql/tests/repros` (SQL parser) | `./run.sh repro_sql_<n>` | `./run-all.sh` |
| `examples/repros` (pgish, psqlish, psqlbench) | `./run.sh repro_examples_<n>` | `./run-all.sh` |

`run.sh` takes an optional second argument, a time limit in seconds (default 60).
Run each harness from its own directory.

All repros were re-run in a clean sweep. Every core-library, SQL and examples
program printed `BUG REPRODUCED` and exited 1. The core-library harness holds 42 finding
programs: `repro_proto_1` .. `_7`, `repro_server_1`, `_2`, `_3`, `_4`, `_6`, `_7`,
`_8`, `_9`, `_11`, `repro_scram_1` .. `_3`, `repro_logical_1` .. `_5`,
`repro_client_1` .. `_6`, `repro_repl_1` .. `_5` and `repro_backup_1` .. `_7`. The
examples harness holds 10 programs, `repro_examples_1` .. `_11` without `_8`;
EXAMPLES-8 was verified by running the prebuilt `examples/pgish/bin/flyology_pgish`
binary directly, because the defect lives in a main procedure's declarative part
and cannot be called from a test program. The SQL harness holds 9 programs,
`repro_sql_1` .. `_9`; SQL-8b shares `repro_sql_8`. Each harness also carries a smoke program
that passes, which shows its project file and switches are unmodified.

The three harness directories and the `review/` reports are untracked additions. No
library, test, or script was modified by the review. `git status` also shows three
modified files under `sql/tests/config/`; those were already modified before the
review started and are Alire-regenerated build configuration, not review output.

## Totals

| Area | P0 | P1 | P2 | Confirmed | Duplicates / partial |
| --- | --- | --- | --- | --- | --- |
| PROTO | 0 | 1 | 6 | 7 | — |
| SERVER | 1 | 4 | 4 | 9 | SERVER-5 duplicates PROTO-1; SERVER-10 duplicates PROTO-5; SERVER-7 partially confirmed |
| SCRAM | 0 | 1 | 2 | 3 | — |
| LOGICAL | 1 | 2 | 2 | 5 | — |
| CLIENT | 0 | 2 | 4 | 6 | — |
| REPL | 0 | 3 | 2 | 5 | — |
| BACKUP | 0 | 4 | 3 | 7 | — |
| EXAMPLES | 0 | 6 | 5 | 11 | — |
| SQL | 0 | 5 | 5 | 10 | SQL-6 partially confirmed (one sub-claim refuted); SQL-8b added by the verifier |
| **Total** | **2** | **28** | **33** | **63** | 2 duplicates, 2 partial |

The two duplicates are not counted as findings. SERVER-7 and SQL-6 are each counted
once, as confirmed findings with one sub-claim refuted.

## Index of findings

| ID | Sev | Title | Primary location | Repro |
| --- | --- | --- | --- | --- |
| PROTO-1 | P1 | Whole-message deadline re-armed on every transport read | `src/flyology-postgres-framing.adb:62-81` | `repro_proto_1` |
| PROTO-2 | P2 | Initial_Request accessors never raise the documented Protocol_Error | `src/flyology-postgres-protocol.adb:1217-1225` | `repro_proto_2` |
| PROTO-3 | P2 | Decode_Initial documented to take the complete packet | `src/flyology-postgres-protocol.ads:589-590` | `repro_proto_3` |
| PROTO-4 | P2 | Startup replication value parsing is case- and prefix-sensitive | `src/flyology-postgres-protocol.adb:1190-1202` | `repro_proto_4` |
| PROTO-5 | P2 | `_pq_.` protocol options discarded, so NegotiateProtocolVersion cannot list them | `src/flyology-postgres-protocol.adb:1183-1205` | `repro_proto_5` |
| PROTO-6 | P2 | Exhausted buffer diagnosed as exceeding the size limit | `src/flyology-postgres-protocol.adb:157-161` | `repro_proto_6` |
| PROTO-7 | P2 | Typed messages admit a frame of Maximum_Message_Size plus one | `src/flyology-postgres-protocol.adb:179-181` | `repro_proto_7` |
| SERVER-1 | P0 | First Read_Initial in a declarative part terminates the whole server | `src/flyology-postgres-server.adb:371-372` | `repro_server_1` |
| SERVER-2 | P1 | TLS_Required rejects a plaintext CancelRequest, breaking psql Ctrl-C | `src/flyology-postgres-server.adb:406-414` | `repro_server_2` |
| SERVER-3 | P1 | NegotiateProtocolVersion carries the bare minor version number | `src/flyology-postgres-server_sessions.adb:150-159` | `repro_server_3` |
| SERVER-4 | P1 | Read_Copy_Command rejects Sync and Flush during COPY IN | `src/flyology-postgres-server_sessions.adb:70-75` | `repro_server_4` |
| SERVER-5 | P1 | Duplicate of PROTO-1, restated on the server framing contracts | `src/flyology-postgres-server_sessions.ads:18` | duplicate, none |
| SERVER-6 | P2 | Serve and Serve_TLS lifecycle contracts drift from the body | `src/flyology-postgres-server.adb:622-625` | `repro_server_6` |
| SERVER-7 | P2 | Ada exception text sent to peers; no 57P01 on shutdown | `src/flyology-postgres-server.adb:537-548` | `repro_server_7` |
| SERVER-8 | P2 | Pre-authentication startup buffer committed before any payload byte | `src/flyology-postgres-framing.adb:30-31` | `repro_server_8` |
| SERVER-9 | P2 | TLS transport reports the same event differently with an observer | `src/flyology-postgres-transports-tls_sockets.adb:41-83` | `repro_server_9` |
| SERVER-10 | P2 | Duplicate of PROTO-5, with the backend rule for sending the message | `src/flyology-postgres-server_sessions.adb:157` | duplicate, none |
| SERVER-11 | P1 | Request_Shutdown cancels no handler under the default Drain_Timeout | `src/flyology-postgres-server.ads:89-90` | `repro_server_11` |
| SCRAM-1 | P1 | Mock SCRAM exchange uses a fixed salt published in the source | `src/flyology-postgres-server.adb:32-35` | `repro_scram_1` |
| SCRAM-2 | P2 | Optional SCRAM extension attributes are rejected, not ignored | `src/flyology-postgres-scram.adb:399-401` | `repro_scram_2` |
| SCRAM-3 | P2 | Iteration-count bounds are enforced when parsing a peer's value | `src/flyology-postgres-scram.ads:13-16` | `repro_scram_3` |
| LOGICAL-1 | P0 | Non-streamed data message accepted inside an open stream segment | `src/flyology-postgres-replication-logical-producer.adb:117-140` | `repro_logical_1` |
| LOGICAL-2 | P1 | Producer models one in-flight XID and treats every Stream Abort as terminal | `src/flyology-postgres-replication-logical-producer.adb:92-98` | `repro_logical_2` |
| LOGICAL-3 | P1 | Non-transactional logical decoding message rejected outside a transaction | `src/flyology-postgres-replication-logical-producer.adb:128-134` | `repro_logical_3` |
| LOGICAL-4 | P2 | Begin/Commit and BeginPrepare/Prepare LSN agreement unchecked | `src/flyology-postgres-replication-logical-producer.adb:54-60` | `repro_logical_4` |
| LOGICAL-5 | P2 | Constructed Stream Abort cannot report its own v4 metadata | `src/flyology-postgres-replication-logical.adb:460-471` | `repro_logical_5` |
| CLIENT-1 | P1 | Scoped receive derives Sync_Pending from state, not Pending_Syncs | `src/flyology-postgres-client.adb:1523` | `repro_client_1` |
| CLIENT-2 | P1 | Extended COPY IN miscounts the Sync the backend discards | `src/flyology-postgres-client.adb:43-50`, `:532` | `repro_client_2` |
| CLIENT-3 | P2 | Scoped Send_Query bypasses the pipeline-mode rejection | `src/flyology-postgres-client.adb:1205` (`Start_Send`) | `repro_client_3` |
| CLIENT-4 | P2 | DataRow column check uses whichever RowDescription arrived last | `src/flyology-postgres-client.adb:724`, `:973` | `repro_client_4` |
| CLIENT-5 | P2 | One session-wide suspended-portal flag rejects valid sequences | `src/flyology-postgres-client.adb:994` (`Portal_Is_Suspended`) | `repro_client_5` |
| CLIENT-6 | P2 | Rejected plaintext startup leaves the session state Not_Started | `src/flyology-postgres-client.adb:192-209`, `:1633-1650` | `repro_client_6` |
| REPL-1 | P1 | Valueless TWO_PHASE and FAILOVER slot options are rejected | `src/flyology-postgres-replication.adb:594-596` | `repro_repl_1` |
| REPL-2 | P1 | TEMPORARY and PHYSICAL slot creation cannot be decoded | `src/flyology-postgres-replication.adb:519-527` | `repro_repl_2` |
| REPL-3 | P1 | Standby-initiated CopyDone raises Protocol_Error | `src/flyology-postgres-replication-server_sessions.adb:201-206` | `repro_repl_3` |
| REPL-4 | P2 | Replication SHOW rejects dotted GUC names | `src/flyology-postgres-replication.adb:100-104` | `repro_repl_4` |
| REPL-5 | P2 | IDENTIFY_SYSTEM timeline column declared int4 for every peer | `src/flyology-postgres-replication-server_sessions.adb:47-79` | `repro_repl_5` |
| BACKUP-1 | P1 | Promote stores only the newest timeline history line | `src/flyology-postgres-replication-persistence-memory.adb:255-283` | `repro_backup_1` |
| BACKUP-2 | P1 | Retention floor is order-dependent when a live slot restarts at zero | `src/flyology-postgres-replication-persistence-memory.adb:163-175` | `repro_backup_2` |
| BACKUP-3 | P2 | Append on a drained store rewinds Current_LSN and reuses positions | `src/flyology-postgres-replication-persistence-memory.adb:206-217` | `repro_backup_3` |
| BACKUP-4 | P1 | Generation keeps returning the stale lease after Release | `src/flyology-postgres-replication-persistence.adb:43` | `repro_backup_4` |
| BACKUP-5 | P1 | Prepare overwrites a Target_Applied marker for the same GID | `src/flyology-postgres-replication-prepared_consumer.adb:7-20` | `repro_backup_5` |
| BACKUP-6 | P2 | Create accepts an active or invalidated snapshot as initial state | `src/flyology-postgres-replication-persistence-memory.adb:36-57` | `repro_backup_6` |
| BACKUP-7 | P2 | Base backup position result set declares tli as int4 | `src/flyology-postgres-replication-base_backups-server_sessions.adb:23-46` | `repro_backup_7` |
| EXAMPLES-1 | P1 | LIKE '%' raises Pattern_Error instead of matching every value | `examples/pgish/src/pgish_catalog.adb:444-466` | `repro_examples_1` |
| EXAMPLES-2 | P1 | NOT LIKE is silently evaluated as LIKE | `examples/pgish/src/pgish_sql.adb:413-436` | `repro_examples_2` |
| EXAMPLES-3 | P1 | ORDER BY compares integer columns as text | `examples/pgish/src/pgish_catalog.adb:623-651` | `repro_examples_3` |
| EXAMPLES-4 | P1 | psqlish raises Constraint_Error on any zero-column result | `examples/psqlish/src/psqlish_main.adb:234` | `repro_examples_4` |
| EXAMPLES-5 | P1 | information_schema.columns unusable without a table_name equality | `examples/pgish/src/pgish_catalog.adb:356-410` | `repro_examples_5` |
| EXAMPLES-6 | P2 | Quoted identifiers case-folded and qualifiers ignored | `examples/pgish/src/pgish_catalog.adb:92-96` | `repro_examples_6` |
| EXAMPLES-7 | P1 | Phantom sessions refuse admission with a false 28P01 error | `examples/pgish/src/pgish_handler.adb:419` | `repro_examples_7` |
| EXAMPLES-8 | P2 | Option and environment errors bypass the main exception handler | `examples/pgish/src/flyology_pgish.adb:136` | binary run, no program |
| EXAMPLES-9 | P2 | psqlish expanded output misaligns field names | `examples/psqlish/src/psqlish-display.adb:327-345` | `repro_examples_9` |
| EXAMPLES-10 | P2 | Empty and comment-only queries answered with error 42601 | `examples/pgish/src/pgish_handler.adb:305-316` | `repro_examples_10` |
| EXAMPLES-11 | P2 | SELECT star with no FROM produces a zero-column row | `examples/pgish/src/pgish_catalog.adb:519-527` | `repro_examples_11` |
| SQL-1 | P1 | `E'\v'` unescapes to the letter v on PostgreSQL 17 and 18 | `sql/src/flyology-postgres-sql-native-scanner.adb:197-204` | `repro_sql_1` |
| SQL-2 | P1 | Octal escapes above `\377` fail with a GNAT range-check message | `sql/src/flyology-postgres-sql-native-scanner.adb:386-394` | `repro_sql_2` |
| SQL-3 | P2 | `\U` escapes at or above 0x80000000 overflow `Natural` | `sql/src/flyology-postgres-sql-native-scanner.adb:70-77` | `repro_sql_3` |
| SQL-4 | P2 | Escape strings assembling invalid UTF-8 are accepted | `sql/src/flyology-postgres-sql-native-scanner.adb:386-403` | `repro_sql_4` |
| SQL-5 | P2 | `UESCAPE` check misses form feed and vertical tab | `sql/src/flyology-postgres-sql-native-scanner.adb:717-722` | `repro_sql_5` |
| SQL-6 | P1 | v14 `doNegate` folds minus into string and bit-string constants | `sql/src/flyology-postgres-sql-native-semantics.adb:330-360` | `repro_sql_6` |
| SQL-7 | P2 | Grammar `ereport` errors lose position and format arguments | `sql/tools/generate_native_actions.py:600-609` | `repro_sql_7` |
| SQL-8 | P2 | Scanner diagnostics quote the rest of the input; identifier cursor off by one | `sql/src/flyology-postgres-sql-native-engine.adb:112-119` | `repro_sql_8` |
| SQL-8b | P1 | v18-only parameter-number limit applied to 14 through 17 | `sql/src/flyology-postgres-sql-native-scanner.adb` (`{param}` action) | `repro_sql_8` |
| SQL-9 | P1 | Diagnostic cursors are byte offsets, not character offsets | `sql/src/flyology-postgres-sql-native-engine.adb:33` | `repro_sql_9` |

---

## Protocol codec and framing (PROTO-1 .. PROTO-7)

### PROTO-1: Whole-message deadline re-armed on every transport read

**Severity:** P1

**Location:** `src/flyology-postgres-framing.adb:62-81`; contract at
`src/flyology-postgres-framing.ads:15-17`

**Repro:** `repro_proto_1` — measured 0.750048292 s spent inside `Read_Message`
against a documented 0.3 s deadline, with three transport reads each granted the
full timeout.

**What is wrong:** `Framing.Read_Message` issues three independent
`Channel.Receive_Exactly` calls, for the tag, the length and the body, and passes
the caller's full `Timeout` to each without subtracting elapsed time. `Read_Initial`
(`src/flyology-postgres-framing.adb:48-60`) does the same across two calls. Every
concrete transport implements `Timeout` per transfer, as `src/flyology-postgres-transports.ads:28-40`
requires, so nothing below `Framing` accounts for the whole message. A peer that
stalls just under `Timeout` before each read keeps the call alive for nearly three
times `Timeout` without raising `Flyology.IO.Timeout_Error`. The spec at
`src/flyology-postgres-framing.ads:15-17` promises a single deadline for the whole
message, so callers that size `Timeout` as a liveness bound get one three times
looser than documented.

**Notes:** The overrun is bounded at three times `Timeout`, so this is a contract
violation and a weakened liveness bound, not a hang. Affected callers include
`Server.Run_Session`'s `Startup_Timeout` (`src/flyology-postgres-server.adb:372`,
`:403`) and the client's copy-event read (`src/flyology-postgres-client.adb:2266-2292`).
SERVER-5 is the same defect restated at the server layer; a fix must correct three
specifications, not one.

---

### PROTO-2: Initial_Request accessors never raise the documented Protocol_Error

**Severity:** P2

**Location:** `src/flyology-postgres-protocol.adb:1217-1225`; contracts at
`src/flyology-postgres-protocol.ads:602`, `:607`, `:612`

**Repro:** `repro_proto_2` — on an SSLRequest, `Startup_Data` returns `major = 3`
with an empty user, `Process_Id` returns 0, and `Secret_Key` returns a zero-length
array, all without raising.

**What is wrong:** `Startup_Data`, `Process_Id` and `Secret_Key` are documented to
raise `Protocol_Error` when `Item` is not the matching variant. `Initial_Request`
(`src/flyology-postgres-protocol.ads:819-824`) is a plain record with defaults, not
a discriminated one, and the three accessors are expression functions that read
components with no `Require`. Calling them on the wrong variant therefore yields
record defaults instead of an exception. A consumer that follows the written
contract and uses the exception as its variant discriminator gets a plausible but
empty result. The most dangerous case is a zero-length cancellation secret compared
against a real one. The sibling `Backend_Message` accessors
(`src/flyology-postgres-protocol.adb:1051-1141`) do check, so the drift is local.

**Notes:** No in-repo caller is affected; `Server.Run_Session` guards on
`Protocol.Kind` first (`src/flyology-postgres-server.adb:416`, `:420`). The fix is
either three `Require` guards or a documentation correction. The two differ in
whether existing external callers start seeing a new exception, so the choice is the
maintainer's.

---

### PROTO-3: Decode_Initial documented to take the complete packet

**Severity:** P2

**Location:** `src/flyology-postgres-protocol.ads:589-590`; implementation at
`src/flyology-postgres-wire.adb:233` and `src/flyology-postgres-protocol.adb:1181`

**Repro:** `repro_proto_3` — complete SSLRequest, CancelRequest and startup packets
built by the library's own encoders all decode as `UNKNOWN_INITIAL`.

**What is wrong:** The specification documents `Decode_Initial` as decoding "an
untagged initial packet including its length field", with "@param Contents Complete
packet bytes". The implementation decodes the bytes after the length: `Wire.Decode_Initial`
reads `Contents (0 .. 3)` as the request code, and the protocol layer restarts
parameter parsing at `Contents'First + 4`. Passing the complete packet, as
documented, makes the length word decode as the request code. A length is neither a
recognised special code nor major version 3, so every such packet is classified
`Unknown_Initial` with status `Initial_Ok` and no exception is raised. Round-tripping
the library's own `Encode_SSL_Request`, `Encode_Cancel_Request` or `Encode_Startup`
output therefore fails silently.

**Notes:** Both in-repo callers strip the length first, so nothing in the repository
misbehaves. The verifier kept this at P2 for that reason but recorded that it reads
as P1 for an external consumer treating the published `.ads` as the contract. The
correct fix is almost certainly the documentation plus a renamed parameter, not the
behaviour.

---

### PROTO-4: Startup replication value parsing is case- and prefix-sensitive

**Severity:** P2

**Location:** `src/flyology-postgres-protocol.adb:1190-1202`

**Repro:** `repro_proto_4` — `replication=TRUE`, `True`, `t`, `On`, `Yes`, `f` and
`Off` each raise `Protocol_Error: invalid startup replication mode`, while the three
lowercase control cases decode correctly.

**What is wrong:** `Decode_Initial` matches the startup `replication` parameter
against fixed lowercase literals and raises `Protocol_Error` for anything outside
that set. PostgreSQL's `ProcessStartupPacket` compares against `"database"` and
otherwise calls `parse_bool`, whose `parse_bool_with_len` is case-insensitive and
accepts unique prefixes. So `TRUE`, `True`, `t`, `On`, `Yes`, `f` and `Off` are all
valid replication requests to a real backend and are rejected here. The rejection
happens while initialising `Initial` in `Run_Session`'s declarative part
(`src/flyology-postgres-server.adb:371-372`), so it escapes that subprogram's own
`Protocol_Error` handler at `:524-535`. The server therefore closes the connection
without the FATAL `ErrorResponse` it sends for any later protocol error.

**Notes:** Mainstream clients send lowercase `true` or `database` by default, which
are accepted; the rejected spellings appear only when a user writes them in a
conninfo string. Deciding whether to accept the full `parse_bool` grammar is a
compatibility-policy call for the maintainer. The escaping-handler mechanism is the
same defect as SERVER-1.

---

### PROTO-5: `_pq_.` protocol options discarded, so NegotiateProtocolVersion cannot list them

**Severity:** P2

**Location:** `src/flyology-postgres-protocol.adb:1183-1205`;
`src/flyology-postgres-protocol.ads:569-583`;
`src/flyology-postgres-server_sessions.adb:150-159`

**Repro:** `repro_proto_5` — a startup packet requesting `_pq_.some_option` decodes
to a `Startup_Information` value identical to one that requests nothing.

**What is wrong:** The PostgreSQL start-up flow requires a server to answer
`NegotiateProtocolVersion`, listing each unrecognised `_pq_.` option, whenever a
client requests options the server does not support. `Decode_Initial`'s parameter
walk examines only `replication` and discards every other name/value pair, and
`Startup_Information` has no field that could carry them. On the server side,
`Send_Negotiate_Protocol` hard-codes an unrecognised-option count of zero and is
reached only when `Protocol_Minor > 2` (`src/flyology-postgres-server.adb:443-447`).
A conforming server therefore cannot be built on this library: a client that asked
for an option is entitled to conclude it was accepted, and no application-visible
API can detect the request.

**Notes:** Re-scoped by the verifier from "wrong diagnostics" to a missing-capability
spec deviation on the server role; the P2 number is unchanged because libpq sends no
`_pq_.` options unless an application asks. Closing this needs an API decision: a new
`Startup_Information` field or accessor plus a `Send_Negotiate_Protocol` parameter.
SERVER-10 is the same finding seen from the server layer, and adds the backend's rule
at `backend_startup.c:853-855` that a 3.0 client requesting `_pq_.foo` is entitled to
a `v` message. Fixing this without fixing SERVER-3 would make matters worse, because
the `v` message would then reach ordinary 3.0 clients with a malformed version word.

---

### PROTO-6: Exhausted buffer diagnosed as exceeding the size limit

**Severity:** P2

**Location:** `src/flyology-postgres-protocol.adb:157-161`; contract at
`src/flyology-postgres-protocol.ads:690`

**Repro:** `repro_proto_6` — an empty `1 .. 0` buffer and an empty `Q` payload both
report "Postgres string exceeds the configured limit"; a one-byte unterminated
buffer correctly reports "unterminated Postgres string".

**What is wrong:** `Read_C_String` bundles three unrelated conditions into one
`Require`: an oversized buffer, a cursor before the buffer, and a cursor past the
end. Its single message is "Postgres string exceeds the configured limit". The
documented condition for this input is the opposite, "@exception Protocol_Error No
terminator remains in Source", and the accurate message at `:164` is reachable only
when at least one byte remains. The path is wire-reachable: a frontend `Q` message
with length field 4 yields a zero-length payload, and `Server_Sessions.Query_Text`
(`src/flyology-postgres-server_sessions.adb:471-487`) calls `Read_C_String` on it.
`Run_Session` forwards the exception message verbatim into the FATAL `ErrorResponse`
(`src/flyology-postgres-server.adb:524-531`), so a client that sends a zero-byte
query is told its string exceeded a 16 MiB limit.

**Notes:** The same applies to `Password_Text`, `SASL_Initial_Response` and the
client's SASL mechanism loop (`src/flyology-postgres-client.adb:263`). The existing
test `Test_Malformed_String` (`tests/src/tests.adb:404-422`) uses a one-byte buffer
and asserts only that some `Protocol_Error` is raised, so it does not catch this.
Splitting the `Require` into a size check and an exhaustion check resolves it without
changing which inputs are rejected.

---

### PROTO-7: Typed messages admit a frame of Maximum_Message_Size plus one

**Severity:** P2

**Location:** `src/flyology-postgres-protocol.adb:179-181` and
`src/flyology-postgres-wire.ads:319-320`; constant at `src/flyology-postgres.ads:6-8`

**Repro:** `repro_proto_7` — `Wire.Valid_Typed_Length (16777216)` returns True, which
describes a 16777217-byte frame, and `Make_Message` accepts a payload whose encoded
frame is 16777217 bytes. The `Max - 1` control case still passes.

**What is wrong:** `Maximum_Message_Size` is documented as the largest complete wire
message "including its type byte and encoded length", that is, a frame bound. On the
typed-message path both ends are one byte loose. `Make_Message` admits
`Payload'Length <= Maximum_Message_Size - 4`, and `Encode` then emits
`1 + 4 + Payload'Length` bytes. Symmetrically, `Wire.Valid_Typed_Length` accepts a
length field of `Maximum_Message_Size`, after which `Framing.Read_Message` reads
`1 + Length` bytes. The untagged initial-packet path honours the bound exactly, so
the two message families disagree about what the constant means.

**Notes:** Encoder and decoder are consistent with each other, and 16 MiB is far
below PostgreSQL's own limit, so there is no memory-safety or interop effect. The fix
is either a one-byte tightening of the two typed-message checks or a correction to the
constant's documented meaning; which one is right is a policy call about a published
limit.

---

## Server session and lifecycle (SERVER-1 .. SERVER-11)

### SERVER-1: First Read_Initial in a declarative part terminates the whole server

**Severity:** P0

**Location:** `src/flyology-postgres-server.adb:371-372`; handlers at `:524-548`;
`Process_Connection` at `:551-563`

**Repro:** `repro_server_1` — a control client is served, then a probe connects and
closes without sending a byte; the next identical client gets `connect failed
[errno=61]` and `Serve` raises `Server_Failed`.

**What is wrong:** `Run_Session` initialises its `Initial : Protocol.Initial_Request`
object from `Server_Sessions.Read_Initial` in its declarative part. In Ada, an
exception raised while elaborating a declarative part is not covered by that
subprogram's own handlers, so the `Protocol_Error` and catch-all handlers at `:524-548`
never run, although they do cover the identical `Read_Initial` at `:403`.
`Process_Connection` adds no handler, so the exception reaches the Flyology structured
worker, which records a server failure and requests `Accept_Stop`
(`flyology-io-structured_servers.adb:457-459`). Every worker leaves its accept loop,
the listener is closed, and `Serve` raises `Server_Failed`. The triggers are ordinary
client behaviour that PostgreSQL merely logs and drops: a connect-then-close probe
(`Device_Error`), a client silent past `Startup_Timeout` (`Timeout_Error`), and a
non-PostgreSQL first packet such as an HTTP request line (`Protocol_Error`).

**Notes:** The verifier corrected the discovery's mechanism. `Serve` does not block
waiting for `Request_Shutdown`; `Record_Failure` sets the phase to `Stop_Requested`
(`flyology-io-structured_servers.adb:126`), so `Serve` drains, closes the listener and
raises `Server_Failed` promptly. That is more severe than the discovery predicted, not
less: the repro's follow-up client is refused before the program calls
`Request_Shutdown`. Moving the first read into the statement part, or wrapping
`Process_Connection`'s body, closes it.

---

### SERVER-2: TLS_Required rejects a plaintext CancelRequest, breaking psql Ctrl-C

**Severity:** P1

**Location:** `src/flyology-postgres-server.adb:406-414`, before the `Cancel_Request`
branch at `:416-419`

**Repro:** `repro_server_2` — under `TLS_Required` a plaintext CancelRequest is
answered with `FATAL 08004 "TLS is required"`; the `TLS_Allowed` control server routes
it and closes silently, as PostgreSQL does.

**What is wrong:** `Run_Session` applies the `TLS_Required` gate before it inspects
the initial request's kind, so a `CancelRequest` on a plaintext connection never
reaches `Context.Router.Route`. PostgreSQL handles `CANCEL_REQUEST_CODE` first and
unconditionally (`src/backend/tcop/backend_startup.c:575-580`), because a cancel packet
carries no credential beyond the secret key it must already know. psql's Ctrl-C uses
`PQcancel`, which `src/interfaces/libpq/fe-cancel.c:528` documents as the "old,
non-encrypted, but signal-safe" path and which opens a raw socket with no SSLRequest.
Every driver built on `PQcancel` therefore has its cancels discarded against any
`TLS_Required` server. The library's own specification is narrower than its behaviour:
`src/flyology-postgres-server.ads:85` scopes `Policy` to plaintext startup.

**Notes:** This repository's own test server ships `TLS_Required`
(`tests/src/postgres_test_server.adb:287`), so the affected configuration is the one
under test. The verifier recorded that the rubric's "interop-breaking protocol
violation" clause makes P0 arguable, and kept P1 because nothing is corrupted and no
connection is broken. The fix is to move the `Cancel_Request` branch above the TLS gate.

---

### SERVER-3: NegotiateProtocolVersion carries the bare minor version number

**Severity:** P1

**Location:** `src/flyology-postgres-server_sessions.adb:150-159`; parameter declared
at `src/flyology-postgres-server_sessions.ads:85-92`; caller at
`src/flyology-postgres-server.adb:444-446`

**Repro:** `repro_server_3` — the emitted `v` frame carries the version word
`00 00 00 02` where PostgreSQL emits `00 03 00 02`. The tag, length and option-count
checks pass.

**What is wrong:** `Send_Negotiate_Protocol` encodes its `Latest_Minor` parameter
directly as the first Int32 of the `v` frame, and `Run_Session` passes the literal `2`.
PostgreSQL's `SendNegotiateProtocolVersion` sends a full `ProtocolVersion`,
`pq_sendint32(&buf, FrontendProtocol)` at `backend_startup.c:965`, where
`PG_PROTOCOL(3,2)` is `0x00030002`. libpq reads the field back as a `ProtocolVersion`
and fails with "server requested downgrade to pre-3.0 protocol version" for anything
below `PG_PROTOCOL(3, 0)` (`fe-protocol3.c:1482-1486`). Since this library sends the
message only when a client requests minor greater than 2, every `v` message it emits
is malformed and aborts the connection it was meant to rescue.

**Notes:** The `Latest_Minor` parameter name records the misreading in the public API,
so the fix is a renamed parameter carrying `major << 16 | minor` as well as a corrected
value. The path is live rather than theoretical: in the PostgreSQL 19 beta tree
examined, libpq defaults `max_pversion` to `PG_PROTOCOL_GREASE` = 3.9999
(`fe-connect.c:2149-2156`), specifically to exercise negotiation. That default is
annotated as temporary. Fixing PROTO-5 or SERVER-10 before this would send the
malformed word to ordinary 3.0 clients.

---

### SERVER-4: Read_Copy_Command rejects Sync and Flush during COPY IN

**Severity:** P1

**Location:** `src/flyology-postgres-server_sessions.adb:70-75`; decoder at
`src/flyology-postgres-protocol.adb:869-870`; contract at
`src/flyology-postgres-server_sessions.ads:32`

**Repro:** `repro_server_4` — the queued frontend bytes `S` then `d` make
`Read_Copy_Command` raise `Protocol_Error: message is not a frontend COPY command`,
and the following CopyData is never delivered.

**What is wrong:** `Read_Copy_Command` forwards the next frontend message to
`Protocol.Decode_Frontend_Copy`, whose `when others` arm raises `Protocol_Error`. A
`Sync` that libpq's `PQexecParams` already queued behind the Execute that started the
COPY is therefore rejected, `Run_Session`'s handler turns it into `FATAL 08P01`, and
the connection is dropped. PostgreSQL explicitly ignores `Flush` and `Sync` in the same
position and reads the following `CopyData` (`copyfromparse.c:326-335`), with a comment
naming client libraries such as libpq. Separately, the operation's specification
promises "CopyData, CopyDone, CopyFail, Flush, Sync, or Terminate event" while
`Protocol.Frontend_Copy_Kind` has only the first three values, so half the documented
result set is unrepresentable.

**Notes:** Drivers that always use the extended protocol, psycopg3 among them, hit this
as their normal COPY path; psql's `\copy` uses a simple `Query` and is unaffected. Three
in-repo consumers inherit the gap:
`src/flyology-postgres-replication-managed_primary.adb:55`,
`src/flyology-postgres-replication-base_backups-server_sessions.adb:204`, and
`tests/src/postgres_test_replication_server.adb:215`. Widening the documented result
set requires a new `Frontend_Copy_Kind` value, which is an API decision.

---

### SERVER-5: Duplicate of PROTO-1, restated on the server framing contracts

**Severity:** P1

**Location:** `src/flyology-postgres-server_sessions.ads:18` and `:24`

**Repro:** none written; covered by `repro_proto_1`.

**What is wrong:** `Read_Command` and `Read_Initial` promise one deadline for the
complete message and re-arm `Timeout` for every transport read. This is PROTO-1 seen
one layer up. The server layer adds two contract sites the PROTO write-up did not cite:
`Read_Initial`'s "@param Timeout Maximum time allowed for the complete packet" and
`Read_Command`'s "the complete message". The server-specific consequence is a weakened
liveness bound: a pre-authentication client that fragments its startup packet holds a
worker for roughly twice `Startup_Timeout`, and any later typed message for three times.

**Notes:** Counted as a duplicate of PROTO-1, not as a separate finding. A fix must
correct three specifications. This also lengthens the hold in SERVER-8, though it does
not widen it.

---

### SERVER-6: Serve and Serve_TLS lifecycle contracts drift from the body

**Severity:** P2

**Location:** `src/flyology-postgres-server.adb:622-625` against
`src/flyology-postgres-server.ads:87`; `src/flyology-postgres-server.adb:184-186`
against `src/flyology-postgres-server.ads:65` and `:80-81`

**Repro:** `repro_server_6` — `Serve_TLS (Policy => TLS_Disabled)` raises
`PROGRAM_ERROR`, not the documented `Constraint_Error`; a second sequential `Serve`
raises `PROGRAM_ERROR: Postgres server is one-shot` after the first returned cleanly.

**What is wrong:** Two lifecycle promises do not match the body. The specification
documents `@exception Constraint_Error Policy is TLS_Disabled`, while `Serve_TLS`
raises `Program_Error` directly in its own body, so a caller handling the documented
exception does not catch the one raised. The specification also says Serve and
Serve_TLS "may be called only once at a time", which permits sequential reuse, while
`Inner_Holder.Install` enforces one-shot with `Program_Error "Postgres server is
one-shot"`. The body otherwise supports the sequential reading: every `Serve_Internal`
allocates, installs, clears and frees a fresh `Structured.Server` on both the normal and
the exceptional path. Only the never-reset `Serve_Started` flag makes it one-shot.

**Notes:** Either the specifications or the guards should move; today neither text is
safe to program against. Kept at P2 because both halves need unusual input: a
`TLS_Disabled` policy handed to `Serve_TLS` is a programming error, and sequential
restart is uncommon. Contrast SERVER-11, also a documented-contract violation, which is
P1 because it sits on the default shutdown path.

---

### SERVER-7: Ada exception text sent to peers; no 57P01 on shutdown

**Severity:** P2

**Location:** `src/flyology-postgres-server.adb:537-548`; nested handler at `:545-547`;
cancellation token bound at `:557-558`

**Repro:** `repro_server_7` — a real GNAT range-check failure inside the application
handler reached the client as SQLSTATE `XX000` with message
`repro_server_7.adb:102 index check failed`; a session terminated by `Request_Shutdown`
received no ErrorResponse at all.

**What is wrong:** `Run_Session`'s catch-all builds the client's `ErrorResponse` from
`Ada.Exceptions.Exception_Message (Error)` under SQLSTATE `XX000`. Any
`Constraint_Error` or `Storage_Error` raised inside the application's `Handle` callback
is therefore reported to the peer, authenticated or not, with GNAT's message, which
names the server source file and line of the failing check. Separately, when
`Request_Shutdown` plus a finite `Drain_Timeout` forces handler cancellation,
`Read_Command` raises `Operation_Cancelled` and the catch-all attempts its `XX000`
answer through the very `Handler_Stop` token that was just cancelled. That write fails
and the nested `exception when others => null` discards it. PostgreSQL sends
`FATAL 57P01 terminating connection due to administrator command`, the SQLSTATE client
libraries key their reconnect logic on.

**Notes:** The discovery's claim that shutdown cancellation "is reported the same way
(XX000)" is **refuted as stated**. The catch-all does try to answer `XX000`, but the
answer is written through the cancelled token and swallowed, so the peer receives no
diagnostic at all. That is worse than the discovery described. Both halves stay at P2:
the disclosure is a source file name and line, no secrets, and the missing diagnostic
sits on an administrative path. Sending a fixed message for internal errors, and
recognising `Operation_Cancelled` as `57P01` through an uncancelled path, addresses both.

---

### SERVER-8: Pre-authentication startup buffer committed before any payload byte

**Severity:** P2

**Location:** `src/flyology-postgres-framing.adb:30-31`, reached from `:53-56`; bound at
`src/flyology-postgres-wire.ads:316-317`

**Repro:** `repro_server_8` — a client-declared initial packet length of 16777216 made
the library commit and then ask for 16777212 payload bytes after two transport reads,
against PostgreSQL's cap of 10004 on the same unauthenticated packet.

**What is wrong:** `Framing.Read_Initial` validates the client's length word only
against `Wire.Valid_Initial_Length`, which admits anything up to `Maximum_Message_Size`
of 16 MiB, and then calls `Read_Contents`, which allocates a heap buffer of that size
before asking the peer for a single payload byte. A pre-authentication peer that writes
four bytes and then stalls commits about 16 MiB for the whole startup window, doubled
while the buffer is copied to the local `Result` at `:36-37`, on every worker the
listener admits. PostgreSQL bounds exactly this allocation at
`MAX_STARTUP_PACKET_LENGTH = 10000` (`pqcomm.h:148`) and rejects anything larger before
allocating (`backend_startup.c:543-556`). The library has no startup-specific bound at
all.

**Notes:** The exposure is bounded by the configured session capacity,
`Worker_Capacity = Capacity + 1` (`src/flyology-postgres-server.adb:209-216`), which is
why this is P2 rather than an unbounded denial of service. The discovery's "materialised
three times" is imprecise: the concurrent peak is twice the declared length, with a third
copy transient at most. Choosing a bound is a policy decision under
`.claude/rules/decision-authority.md`; the repro asserts parity with PostgreSQL's
published cap only because that is the one externally established reference point. The
finding is the absence of any startup-specific bound, not the specific number.

---

### SERVER-9: TLS transport reports the same event differently with an observer

**Severity:** P2

**Location:** `src/flyology-postgres-transports-tls_sockets.adb:41-50` versus `:52-83`;
`TLS_Error` raised at `:69-71`; zero-timeout path at `:52-59`

**Repro:** `repro_server_9` — on identical loopback sockets, an early peer close reports
`FLYOLOGY.IO.DEVICE_ERROR` without an observer and
`FLYOLOGY.IO.TLS.TLS_ERROR: TLS peer closed before receive completed` with one;
`Timeout => 0.0` with an observer raises `Timeout_Error` although all eight bytes were
already buffered.

**What is wrong:** `TLS_Socket_Transport.Receive_Exactly` takes two different routes
depending on whether the caller supplied an observer. Without one it delegates to
`Flyology.IO.Sockets.Receive_Exactly`, whose documented early-close report is
`Device_Error`. With one, the chunked loop sees `Last < Cursor` and raises
`Flyology.IO.TLS.TLS_Error`, even on a transport that was never upgraded, so a caller's
exception handler must depend on its own choice of `On_Wait` rather than on the event.
Separately, `Timeout => 0.0` is treated as bounded, `Deadline` equals the current
`Clock`, and the loop raises `Timeout_Error` before `Receive_Chunk` is called, so bytes
already in the receive buffer are never read. The observer-less path passes `0.0` down,
where it means one immediate attempt.

**Notes:** `src/flyology-postgres-transports.ads:28-40` documents only `Timeout_Error`,
so neither `Device_Error` nor `TLS_Error` is specified; what is indefensible is that the
choice depends on `On_Wait`. Both halves reach the replication-feedback path, where
`Replication.Feedback.Standby_Reporter` is the intended `On_Wait` for
`Client.Receive_Copy_Event` (`src/flyology-postgres-client.adb:2288-2292`).

---

### SERVER-10: Duplicate of PROTO-5, with the backend rule for sending the message

**Severity:** P2

**Location:** `src/flyology-postgres-server_sessions.adb:157`;
`src/flyology-postgres-server.adb:443-447`

**Repro:** none written; covered by `repro_proto_5`.

**What is wrong:** `_pq_.` protocol-extension parameters are silently dropped instead of
being reported in NegotiateProtocolVersion. `Send_Negotiate_Protocol` hard-codes
`Append_U32 (Contents, 0)` and is reached only when `Protocol_Minor > 2`. PostgreSQL
sends the message when the requested minor exceeds the latest supported **or**
`unrecognized_protocol_options != NIL` (`backend_startup.c:853-855`). A 3.0 client that
requests `_pq_.foo` is therefore entitled to a `v` message and this library sends none,
so the `Protocol_Minor > 2` gate is a second, independent reason the message is missing.

**Notes:** Counted as a duplicate of PROTO-5, not as a separate finding. Fixing it
without fixing SERVER-3 would make things worse, because the `v` message would then reach
ordinary 3.0 clients carrying a malformed version word.

---

### SERVER-11: Request_Shutdown cancels no handler under the default Drain_Timeout

**Severity:** P1

**Location:** `src/flyology-postgres-server.ads:89-90`; delegation at
`src/flyology-postgres-server.adb:635-638`; defaults at
`src/flyology-postgres-server.ads:63`, `:76` and `:37`

**Repro:** `repro_server_11` — with `Drain_Timeout => 1.0` the control server's `Serve`
returned within 5 s of `Request_Shutdown`; with the default it did not, and only closing
the client socket released it.

**What is wrong:** `Request_Shutdown` is documented as "Request listener shutdown and
cancellation of active connection work". It delegates to the Flyology runtime's
`Request_Shutdown`, which requests only the accept token
(`flyology-io-structured_servers.adb:184-191`). The handler token is requested
exclusively by `Force_Handlers`, which runs only from the `delay Drain_Timeout` arm of
`Serve`'s timed select. Both `Serve` and `Serve_TLS` default `Drain_Timeout` to
`Flyology.IO.Infinite`, so with the shipped defaults `Serve` takes the unguarded
`Await_All_Workers` branch and no handler is ever cancelled. Because the generic formal
`Command_Timeout` also defaults to `Infinite`, a session parked in `Read_Command` waits
indefinitely, and an operator with one idle client attached sees `Serve` never return.

**Notes:** Severity raised from the discovery's P2 by the verifier, because this is what
an application gets by writing nothing at all. The rubric's "hang in normal operation"
clause is arguable but was not applied: a graceful drain that waits for clients is a
legitimate design, and the caller can set a finite `Drain_Timeout`. What is wrong is the
specification. Either the default should be finite or the specification should say
cancellation is contingent on a finite `Drain_Timeout`. No existing test covers the
default, because the repository's test server passes `Drain_Timeout => 1.0`
(`tests/src/postgres_test_server.adb:288`).

---

## SCRAM-SHA-256 (SCRAM-1 .. SCRAM-3)

### SCRAM-1: Mock SCRAM exchange uses a fixed salt published in the source

**Severity:** P1

**Location:** `src/flyology-postgres-server.adb:32-35`, used at `:295`; emitted through
`src/flyology-postgres-scram.adb:444-447`

**Repro:** `repro_scram_1` — over a real loopback socket, two different roles with no
verifier both received `s=Zml4ZWQgZHVtbXkgc2FsdA==,i=4096`, while a role with a verifier
received a different salt.

**What is wrong:** A server built on `Flyology.Postgres.Server` with
`Authentication => SCRAM_SHA_256` answers every role for which the application's
`Lookup_SCRAM_Verifier` returns `""` with the same `AuthenticationSASLContinue` salt and
iteration count. That constant is compiled into the library source and is therefore
public. A role that does have a verifier answers with that verifier's own random salt. An
unauthenticated client learns whether a role exists from the server's second message,
before sending any proof and without triggering an authentication failure, simply by
comparing the salt against the published constant. PostgreSQL avoids this: `mock_scram_secret`
derives the salt with `scram_mock_salt`, a SHA-256 over the role name and the per-cluster
`mock_authentication_nonce`, so unknown roles get stable, per-user, unpredictable salts.

**Notes:** An application cannot safely work around this through the existing callback.
`Has_Credential` is derived from the returned string being non-empty, so returning any
non-empty mock makes `Admit` accept a proof that matches it
(`src/flyology-postgres-server.adb:288-295`, `:340`). A fix changes an externally visible
policy, the mock scheme, so it needs the maintainer's decision rather than a silent edit.
The verifier kept P1 rather than P0 because no secret escapes and the server still returns
`False` for a role with no verifier, and recorded that a broader reading of
"security-relevant" would justify P0. The existing integration check
(`tests/scripts/run-integration.sh:188-197`) asserts only that an unknown user is rejected.

---

### SCRAM-2: Optional SCRAM extension attributes are rejected, not ignored

**Severity:** P2

**Location:** `src/flyology-postgres-scram.adb:399-401` (client-first), `:589-590`
(client-final), `:554-555` (server-final)

**Repro:** `repro_scram_2` — client-first raises "malformed SCRAM client-first-message",
client-final raises "malformed SCRAM attribute; expected p", and server-final raises
"invalid base64 data".

**What is wrong:** RFC 5802 section 7 places an optional `extensions` list at the end of
`client-first-message-bare`, `client-final-message-without-proof` and
`server-final-message`, and requires unrecognized attributes to be ignored. This library
rejects all three. In the server role `Parse_Client_First` raises `SCRAM_Error` for any
token after the nonce, and `Verify_Client_Final` requires the token after the nonce to be
the `p=` proof, so an extension fails parsing before the proof is examined; `Admit`
converts both to `Protocol.Protocol_Error`. In the client role `Verify_Server_Final`
passes everything after `v=` to `Base64_Decode`, so a trailing extension is reported as
invalid base64 instead of verifying. PostgreSQL's own server ignores extensions in both
client messages, so the first two cases diverge from the reference server as well as from
the RFC.

**Notes:** The discovery's mechanism for the client-final case is mis-stated: the failure
comes from the `p` attribute check at `:590`, not from the composite trailing-data test at
`:593-597`. The outcome is the same. One supporting claim is **refuted**: the discovery
asserted that libpq's `read_server_final_message` does not check for trailing data. libpq's
`read_attr_value` does stop at the first comma, but fe-auth-scram.c also carries a "garbage
at end of server-final-message" diagnostic whose fatality the verifier could not confirm.
The server-final case is therefore an RFC conformance gap, not a demonstrated libpq
divergence. Kept at P2 because no mainstream PostgreSQL client or server emits an extension.

---

### SCRAM-3: Iteration-count bounds are enforced when parsing a peer's value

**Severity:** P2

**Location:** `src/flyology-postgres-scram.ads:13-16`; enforced by
`src/flyology-postgres-scram.adb:174-176`, used at `:209` (server) and `:483` (client)

**Repro:** `repro_scram_3` — a real rolpassword built at 1000 iterations fails
`Parse_Verifier`, a server-first carrying `i=1000` fails `Client_Final_Message`, and
`Client.Startup` against a scripted server offering `i=1000` raises
`Protocol.Protocol_Error`.

**What is wrong:** `Minimum_Iterations` (4096) and `Maximum_Iterations` (1_000_000) are
enforced by `Parse_Positive` on parsing as well as on generation, on both roles. A client
connecting to a PostgreSQL 16 or newer server whose role verifier was created under
`scram_iterations = 1000` receives `i=1000` and fails with `Protocol_Error "SCRAM
iteration count is outside the supported range"`, where libpq authenticates normally; its
`read_server_first_message` requires only `iterations >= 1`. A server whose
`Lookup_SCRAM_Verifier` returns such a rolpassword fails in `Parse_Verifier` before
`AuthenticationSASL` is sent, where PostgreSQL's `parse_scram_secret` applies no floor. The
same applies above 1_000_000, which PostgreSQL 16 and later permit up to `INT_MAX`. RFC
5802 and 7677 make 4096 a SHOULD-level recommendation to the party choosing the count, not
an obligation on a peer to refuse a lower one.

**Notes:** Labelled by the verifier as a **policy value with interop consequence**, not a
plain bug. `Minimum_Iterations` and `Maximum_Iterations` are visible constants in an `.ads`
whose documented meaning is exactly the observed behaviour, so under the repository's
Ada-interface-values rule the decision belongs to the maintainer. The stated options are:
keep both bounds and document the interop limit; keep the floor for `Make_Verifier_Raw`
only and accept any count `>= 1` when parsing, which is libpq-compatible; or expose the
bounds as configuration. The failure surfaces to the application as `Protocol_Error`, not as
an authentication failure, so it cannot be distinguished from a broken server.

---

## Logical replication, pgoutput codec and Producer (LOGICAL-1 .. LOGICAL-5)

### LOGICAL-1: Non-streamed data message accepted inside an open stream segment

**Severity:** P0

**Location:** `src/flyology-postgres-replication-logical-producer.adb:117-140`;
constructors at `src/flyology-postgres-replication-logical.adb:352`, `:366`;
`Append_Stream_Xid` at `:636-642`

**Repro:** `repro_logical_1` — inside an open segment, an Insert without an xid is emitted
and then rejected by an in-stream consumer; a logical decoding message is silently misread,
with xid `16843267` invented from the flags and LSN bytes and the prefix read as `"efgh"`
instead of `"abcdefgh"`.

**What is wrong:** In `Producer.Emit` the stream check is one-directional. A message for
which `Logical.Is_Streamed` is True must be inside `Stream_Segment` with a matching XID, but
a message inside `Stream_Segment` is never required to be streamed. Every `Make_*`
constructor for the xid-bearing kinds derives `Streamed := Xid /= 0`, and `Encode` writes the
four-byte prefix only when `Item.Streamed`. A caller who omits the defaulted `Xid` parameter
while the Producer is tracking an open segment therefore gets bytes with no xid prefix, and
`Producer.State` still reports `Stream_Segment`. pgoutput sets `xid = txn->xid` whenever
`in_streaming` is set and prefixes every message written between `S` and `E`; PostgreSQL's
apply worker consumes those four bytes unconditionally while `in_streamed_transaction` is
set.

**Notes:** Severity raised from the discovery's P1 by the verifier, because the failure is
silent and produces corrupted data on the wire. `Managed_Primary.Stream_Logical`
(`src/flyology-postgres-replication-managed_primary.adb:255-272`) sends the Producer's output
verbatim to a live subscriber, and there is no second validation layer. The mitigating factor
is that it takes a caller who omits `Xid`, but `Xid` is defaulted and the Producer holds all
the information needed to reject it. Fix direction: inside `Stream_Segment`, require
`Is_Streamed (Message)` for `Logical_Decoding_Message`, `Relation_Message`, `Type_Message`,
`Insert_Message`, `Update_Message`, `Delete_Message` and `Truncate_Message`; `Origin_Message`
correctly carries no xid.

---

### LOGICAL-2: Producer models one in-flight XID and treats every Stream Abort as terminal

**Severity:** P1

**Location:** `src/flyology-postgres-replication-logical-producer.adb:92-98`; state
transitions at `:54-60`, `:68-84`, `:123-126`, `:128-134`

**Repro:** `repro_logical_2` — a StreamAbort naming subtransaction 21 of transaction 20 drops
the Producer to `Idle` with `Transaction = 0`; the continuation segment for xid 20 is rejected
as "continued StreamStart changed transaction identity"; an unrelated transaction and a second
streamed transaction are both rejected while xid 30 is paused.

**What is wrong:** `Producer.Emit` handles `Stream_Commit_Message` and `Stream_Abort_Message`
identically, dropping to `Idle` and clearing `XID`, and never reads
`Logical.Subtransaction (Message)`. pgoutput's `pgoutput_stream_abort` writes the top-level
`toptxn->xid` together with the aborting `txn->xid`, so a `ROLLBACK TO SAVEPOINT` inside a
streamed transaction produces an `'A'` message whose subxid differs while the top-level
transaction stays streamed. PostgreSQL's `apply_handle_stream_abort` finishes the transaction
only when `xid == subxid`. Two consequences follow. The public queries lie with no further
call, and `Managed_Primary` (`managed_primary.adb:275-277`) uses `Producer.State = Idle` as its
"logical source ended inside a transaction" guard, so a stream truncated mid-transaction would
be accepted as complete. Separately, pgoutput interleaves transactions by design, and the
Producer's `Stream_Paused` state admits only `S`, `c`, `A` and `p` for the same XID.

**Notes:** Not a documented limitation. `producer.ads:1-60` never states that only one
transaction may be in flight, and `README.md:366-372` says only that the Producer "validates
transaction ordering". Contrast the library's own stateful `Decoder`
(`src/flyology-postgres-replication-logical.adb:1220-1249`), which tracks only `In_Stream` and
accepts every one of these sequences. The natural workaround for the abort case, resending
`S(20, first_segment = true)`, would make PostgreSQL's `stream_open_file` recreate the spool
file and discard changes already streamed. The `producer.ads:35-37` monotonic
`WAL_Start >= Last_WAL_End` envelope rule has the same root and must be revisited with this
finding, because pgoutput's per-message `write_location` is not monotonic across interleaved
transactions.

---

### LOGICAL-3: Non-transactional logical decoding message rejected outside a transaction

**Severity:** P1

**Location:** `src/flyology-postgres-replication-logical-producer.adb:128-134`; constructor
default at `src/flyology-postgres-replication-logical.ads:242-254`

**Repro:** `repro_logical_3` — a non-transactional message outside a transaction, and one
between two segments of a paused streamed transaction, are both rejected with "pgoutput data
message is outside a transaction". The `Transactional => True` control case is still rejected
correctly.

**What is wrong:** `Producer.Emit` applies one blanket rule to the whole data-message group,
`Logical_Decoding_Message` included, without consulting `Logical.Is_Transactional (Message)`.
In pgoutput, `pgoutput_message` emits a `BEGIN` first only for transactional messages. A
message written by `pg_logical_emit_message(false, ...)` is queued by
`ReorderBufferQueueMessage` and written out immediately at decode time, outside any `B`/`C`
pair and outside any `S`/`E` pair. The Producer therefore refuses to emit the message in the
only position pgoutput ever puts it, and it does so for the constructor's default setting,
since `Make_Logical_Decoding_Message` declares `Transactional : Boolean := False`. The result
is an unexpected `Protocol_Error` on valid input; through `Managed_Primary` it aborts the whole
replication stream.

**Notes:** The fix must be narrowed by `Is_Transactional`, not removed: the repro confirms that
a `Transactional => True` message outside a transaction is still correctly rejected.

---

### LOGICAL-4: Begin/Commit and BeginPrepare/Prepare LSN agreement unchecked

**Severity:** P2

**Location:** `src/flyology-postgres-replication-logical-producer.adb:54-60` and `:100-106`
(store), `:62-66` and `:108-113` (compare)

**Repro:** `repro_logical_4` — a Commit at `commit_lsn 16#103#` is accepted after a Begin with
`final_lsn 16#101#`, and a Prepare at `16#302#` after a BeginPrepare at `16#301#`. The agreeing
control pair is still accepted.

**What is wrong:** `Producer.Emit` stores only the XID at `Begin_Message` and
`Begin_Prepare_Message`, and compares only the XID at `Commit_Message` and `Prepare_Message`.
The Begin `final_lsn` is never retained, so a Commit whose `commit_lsn` disagrees is accepted
and encoded. PostgreSQL's apply worker records `begin_data.final_lsn` into `remote_final_lsn`
and raises `ERRCODE_PROTOCOL_VIOLATION`, "incorrect commit LSN in commit message", when
`commit_data.commit_lsn != remote_final_lsn`; `apply_handle_prepare` performs the identical
comparison. pgoutput writes `txn->final_lsn` into both fields, so the pair always agrees on the
wire. An application logical source that gets the two LSNs out of step produces a stream that a
`CREATE SUBSCRIPTION` worker errors on and then retries forever.

**Notes:** Reclassified by the verifier from a violated contract to a **validation gap that
requires a design decision**. The Producer's published promise is to validate transaction
ordering (`producer.ads:2-3`, `:41-43`); LSN values are caller data elsewhere in the API. An
existing maintained test asserts the current behaviour: `tests/src/replication_tests.adb:1387-1397`
emits `Make_Begin (101, 0, 10)` followed by `Make_Commit (103, 104, 0)` and asserts success, so
adding the check would fail it. Under the repository's decision-authority rule this is the
maintainer's call. `pg_recvlogical`, which the interop matrix uses, does not perform the check,
so the existing test matrix cannot detect it. The related missing GID comparison is harmless,
since the apply worker keys on `prepare_lsn`.

---

### LOGICAL-5: Constructed Stream Abort cannot report its own v4 metadata

**Severity:** P2

**Location:** `src/flyology-postgres-replication-logical.adb:460-471`; accessors at
`:1348-1355` and `:1357-1371`; flag set only at `:874`

**Repro:** `repro_logical_5` — `Abort_LSN` and `Event_Timestamp` on a freshly built message
raise `Protocol_Error`, while the same values, 53 and 54, are read back correctly after a
v4/parallel encode-decode round trip.

**What is wrong:** `Make_Stream_Abort` accepts and stores `Abort_LSN` and `Aborted_At` in
`First_Position` and `First_Time` but never sets the private `Parallel_Stream` flag, which only
`Decode` sets. Both accessors require that flag, so the two values the caller just supplied are
unreadable from the message object, while `Encode (Item, 4, Parallel)` writes them out
correctly. This contradicts the accessors' own documented exception condition at
`src/flyology-postgres-replication-logical.ads:555-559` and `:560-565`, "Protocol_Error Item
lacks version-4 abort metadata", which is false for this message. No wire bytes are affected and
decoded messages behave correctly.

**Notes:** The discovery offered an alternative reading, that a constructed message reports
version 1 and therefore lacks v4 metadata by definition. The verifier refuted it: the gate is
`Item.Parallel_Stream`, not `Wire_Version`. The observable defect is that an application which
builds a parallel-stream abort cannot inspect it, and that a caller round-tripping through
`Encode`/`Decode` gets different behaviour from the identical logical value.

---

## Client session (CLIENT-1 .. CLIENT-6)

### CLIENT-1: Scoped receive derives Sync_Pending from state, not Pending_Syncs

**Severity:** P1

**Location:** `src/flyology-postgres-client.adb:1523` (`Start_Receive`), against the synchronous path at `:2226`

**Repro:** `repro_client_1` — the same byte stream leaves the open batch active through the
synchronous receive, but drives the session to `RECOVERY_REQUIRED` through the scoped one;
`Execute_Portal` and the follow-up receive then both raise `Program_Error`.

**What is wrong:** `Start_Receive` sets `Operation.Sync_Pending := Item.Current_State =
Awaiting_Ready`, whereas the synchronous `Receive_Extended_Event` uses `Item.Pending_Syncs > 0`.
`Apply_Extended_Event` uses that flag to decide whether a response belongs to an earlier,
already Sync-terminated batch. In pipeline mode, once the next batch's Parse/Bind has been
written, the state is `Extended_Query_Active` while the earlier batch's Sync is still
outstanding. A scoped receive therefore misattributes the earlier batch's `ErrorResponse` to
the open batch: the session is driven to `Recovery_Required` and `Bound_In_Cycle` is cleared.
The open batch's bound portal can no longer be executed, and the earlier batch's
`ReadyForQuery`, the very next byte on the wire, can no longer be received. The only escape is
an extra `Synchronize`, which prematurely closes the open batch.

**Notes:** The `Pending_Syncs` behaviour is the documented one: `tests/src/tests.adb`
(`Test_Pipelined_Client_State`) and the README's "Pipelined batches" section both codify it, so
the scoped path is the deviation. The same flag gates `Portal_Is_Suspended` for
`CommandComplete` and `PortalSuspended`, so an earlier batch's `PortalSuspended` received
through the scoped path likewise corrupts the open batch's portal state. This and CLIENT-3 are
the same class of defect: the scoped `Flyology.Operations` overloads reimplement the synchronous
entry points' guards and drop one each. The verifier recommends sweeping `Start_Send`,
`Start_Receive` and `Start_Startup_Operation` against their synchronous counterparts.

---

### CLIENT-2: Extended COPY IN miscounts the Sync the backend discards

**Severity:** P1

**Location:** `src/flyology-postgres-client.adb:43-50` (`Enter_Copy`), called with a pipelined
Sync at `:532`; `Send_Command` counts every Sync

**Repro:** `repro_client_2` — with the libpq ordering the client wrote frontend tags `PBESdcS`
and ended with `Pending_Synchronizations = 1` after the single `ReadyForQuery`; a following
`Prepare_Statement` raised `Program_Error`. Without the second Sync, `Synchronize` also raised
`Program_Error`.

**What is wrong:** `Send_Command` counts every `Sync` in `Pending_Syncs`, and
`Apply_Extended_Event` passes that count into `Enter_Copy` as `Copy_Sync_Pending` when a
`CopyInResponse` arrives. The session therefore models a Sync the backend has already
discarded as one that will still be answered; PostgreSQL's `CopyGetData` consumes and discards
`Flush` and `Sync` while in copy-in mode. With libpq's ordering, Sync after Execute and Sync
after `CopyDone`, the client counts two outstanding batches and the server sends one
`ReadyForQuery`. The session is left permanently in `Awaiting_Ready` with
`Pending_Synchronizations = 1`, where `Send_Command`, `Prepare_Statement`, `Send_Query` and
`Synchronize` all refuse and `Receive_Extended_Event` blocks until `Timeout_Error`. If the
caller instead trusts `Pending_Synchronizations` and omits the second Sync, the backend waits
for a message the client can no longer write.

**Notes:** The triggering sequence is what libpq puts on the wire: `PQsendQueryParams` appends a
Sync after Execute, and `PQputCopyEnd` writes a second one in extended-query mode. The verifier
kept P1 and recorded that P0 is defensible, because on a real socket variant (b) degrades to a
permanent block with no recovery short of discarding the connection. COPY OUT is correct as it
stands: it never reads from the frontend, so the pipelined Sync is honoured. The fix belongs
where the writable COPY direction starts: a Sync outstanding when `CopyInResponse`, or the
writable half of `CopyBothResponse`, arrives must be dropped from `Pending_Syncs` and must not
set `Copy_Sync_Pending`. `Exit_Pipeline_Mode` bookkeeping is off by one for the same reason.

---

### CLIENT-3: Scoped Send_Query bypasses the pipeline-mode rejection

**Severity:** P2

**Location:** `src/flyology-postgres-client.adb:1255-1262` (scoped `Send_Query`, which checks
only `State = Ready`), against the synchronous overload at `:558`

**Repro:** `repro_client_3` — the synchronous `Send_Query` raises `Program_Error` and writes
nothing, while the scoped call writes 14 frontend bytes and leaves the session in
`SIMPLE_QUERY_ACTIVE` with `In_Pipeline_Mode` still True.

**What is wrong:** The scoped `Send_Query` overload checks only `Item.Current_State /= Ready`
and omits the `Item.Pipelined` guard that both the synchronous `Send_Query` and `Send_Command`
apply. `Start_Send` does not re-check: it writes the encoded message directly and never passes
through `Send_Command`, where the "simple queries are not allowed in Postgres pipeline mode"
check lives. On the same session and in the same state, one entry point raises and the other
puts a `Query` frame on the wire. The documented promise, in `Enter_Pipeline_Mode` and repeated
in the README's "Pipelined batches" section, that simple queries are rejected while pipeline
mode is active, is therefore honoured by only one of the two public entry points.

**Notes:** Kept at P2 because nothing invalid reaches the wire and no counter is corrupted: the
window is reachable only with zero outstanding batches, and `Apply_Query_Event`'s
`ReadyForQuery` branch sets `Ready` directly without touching `Pending_Syncs`. Same class as
CLIENT-1.

---

### CLIENT-4: DataRow column check uses whichever RowDescription arrived last

**Severity:** P2

**Location:** `src/flyology-postgres-client.adb:724` and `:973` (column-count checks against the
last retained `RowDescription`)

**Repro:** `repro_client_4` — `Receive_Extended_Event` raises `Protocol_Error: DataRow column
count does not match RowDescription` on a legal batch, and the executed portal's single-column
DataRow is never delivered.

**What is wrong:** `Apply_Extended_Event` stores `Described_Columns` and
`Has_Row_Description` for every `RowDescription` regardless of which statement or portal it
describes, and validates every subsequent `DataRow` against it. In a batch that does
`Parse "one"`, `Parse "two"`, `Bind "p1" -> "one"`, `Describe_Statement "two"`, `Execute "p1"`,
`Flush`, the server's `RowDescription` for the two-column statement arrives before the
one-column rows of portal "p1". `Receive_Extended_Event` then raises `Protocol_Error` on a
message sequence PostgreSQL legitimately produced. `Has_Row_Description` is cleared only by
`CommandComplete`, `EmptyQueryResponse`, `NoData`, `ErrorResponse` and `ReadyForQuery`, none of
which occurs in between. The same happens with `Describe_Portal (P2)` followed by
`Execute_Portal (P1)`.

**Notes:** The `client.ads` sentence "the column count is checked only against a description
the server actually sent" is about tolerating a missing description, not about matching
descriptions to objects. Kept at P2, close to the boundary, because it needs the unusual shape
of describing one object while executing another inside a single batch. Note the blast radius:
`Protocol_Error` propagates out without clearing the stale description, so every subsequent
`DataRow` of that portal fails the same way and the batch's result set becomes unreadable. The
check needs to be bound to the portal whose Execute is being answered.

---

### CLIENT-5: One session-wide suspended-portal flag rejects valid sequences

**Severity:** P2

**Location:** `src/flyology-postgres-client.adb:860` and `:1290` (`Execute_Portal`), `:815`
(`Bind_Portal`), flag set at `:994`

**Repro:** `repro_client_5` — after `Bind p1`, `Bind p2`, `Execute p1 (Maximum_Rows => 1)` and a
`PortalSuspended`, `Execute_Portal ("p2")` raises `Program_Error: use Resume_Portal for a
suspended portal`; after p2 runs, `Resume_Portal ("p1")` raises `Program_Error: no suspended
Postgres portal can be resumed`.

**What is wrong:** The session tracks suspension with a single Boolean `Portal_Is_Suspended`
that carries no portal name. `Execute_Portal` refuses any execute while it is set, and
`Bind_Portal` clears it unconditionally. So a bound, never-executed portal cannot be executed
while another portal of the same batch is suspended, and a portal that is still suspended on
the server cannot be resumed once an unrelated portal has been bound. Both sequences are legal
extended-query traffic inside one Flush-driven batch, which is the case `client.ads`
`Resume_Portal` describes as resumable: "Sync ends the batch that owns the portal, so only a
batch whose responses arrive through Flush can be resumed". The protocol does not forbid two
live portals in one batch; portals live until the transaction ends.

**Notes:** Kept at P2 because valid sequences are refused before anything is written, so the
transport is never desynchronised. The caller has to fall back to `Send_Command` with a raw
Execute message. `Bind_Portal`'s unconditional reset is the second half of the defect: binding
an unrelated portal makes the session forget that another portal is still suspended server-side.

---

### CLIENT-6: Rejected plaintext startup leaves the session state Not_Started

**Severity:** P2

**Location:** `src/flyology-postgres-client.adb:192-209` (`Complete_Startup`) and `:1633-1650`
(`Fail_Startup`, which sets `Closed` only for `TLS_Negotiation_Stage`)

**Repro:** `repro_client_6` — after a `28P01` rejection the state is `NOT_STARTED` on both the
synchronous and the scoped path, and a retried `Startup` wrote another 56-byte startup packet.

**What is wrong:** `Complete_Startup`'s `'E'` branch raises `Database_Error` without touching
`Current_State`, so a session whose authentication the server rejected stays in `Not_Started`,
while `Startup_TLS` and the scoped `TLS_Negotiation_Stage` set `Closed` for the same class of
failure. The README's "API outline" says of `Startup_TLS` that "any negotiation or
encrypted-startup failure permanently closes the session state", so the identical
authentication `ErrorResponse` produces `Closed` on a TLS session and `Not_Started` on a
plaintext one. A caller that dispatches on `State` cannot distinguish "never started" from
"rejected". `Complete_Startup` then accepts a second `Startup` on that session and writes
another startup packet to a connection the server closed after the ErrorResponse; the retry
fails with a transport error instead of a clean `Program_Error` precondition.

**Notes:** The observable behaviour is confirmed; which state is the **correct** one is a design
choice, not a documented promise. No sentence promises `Closed` for a rejected plaintext
startup, so this is contract drift and an inter-path inconsistency. The repro asserts `Closed`
on the precedent set by `Startup_TLS`. If a different terminal state name is preferred, the
actionable part stands: a rejected session must stop accepting `Startup` and must stop writing
to the connection. The scoped path does not compensate: `Fail_Startup` sets `Closed` only when
`Item.Kind = TLS_Negotiation_Stage`.

---

## Streaming replication protocol core (REPL-1 .. REPL-5)

### REPL-1: Valueless TWO_PHASE and FAILOVER slot options are rejected

**Severity:** P1

**Location:** `src/flyology-postgres-replication.adb:594-596` and `:611-614`; option parser at
`:447-452`; contract at `src/flyology-postgres-replication.ads:161-166`

**Repro:** `repro_repl_1` — the PostgreSQL 15+ two-phase subscriber's command raises
`Protocol_Error: TWO_PHASE requires a value`, and the 17+ failover form raises `unsupported
logical slot option FAILOVER`.

**What is wrong:** `Decode_Command` requires an explicit value for `TWO_PHASE`, because
`Parse_Options` attaches a value only when the next non-space character is a quote, and rejects
`FAILOVER` outright in its `else` arm. Both are exactly the forms PostgreSQL emits. A
PostgreSQL 15+ subscriber with `two_phase` enabled writes
`CREATE_REPLICATION_SLOT "s" LOGICAL pgoutput (TWO_PHASE, SNAPSHOT 'nothing')`, a 17+
subscriber with `failover = true` appends a bare `FAILOVER` the same way, and
`pg_recvlogical --create-slot --two-phase` produces the identical list. On the server side the
bare token is a valid boolean true: `repl_gram.y` builds a NULL-argument `DefElem` and
`walsender.c` reads it with `defGetBoolean`, whose rule is "If no parameter value given, assume
true is meant." A Flyology server acting as a logical-replication primary therefore answers a
valid slot-creation command with `Protocol_Error`, so the subscription cannot create its slot.

**Notes:** An existing test asserts the current wrong behaviour:
`tests/src/replication_tests.adb:427-429` asserts that
`CREATE_REPLICATION_SLOT sync_slot LOGICAL pgoutput (TWO_PHASE)` is rejected, so a fix must
change that assertion. Surfacing `FAILOVER` also needs an API decision: no accessor exists
today, and `managed_primary.adb:338-350` inspects only `Snapshot` and `Two_Phase`. P1 rather
than P0 because both options default to false in `CREATE SUBSCRIPTION`. The constructor side is
correct: `Create_Logical_Slot (..., Two_Phase => True)` emits `TWO_PHASE 'true'`, which
PostgreSQL accepts.

---

### REPL-2: TEMPORARY and PHYSICAL slot creation cannot be decoded

**Severity:** P1

**Location:** `src/flyology-postgres-replication.adb:519-527`, `Expect_Keyword (Text, Cursor,
"LOGICAL")` at `:527`

**Repro:** `repro_repl_2` — `pg_basebackup`'s default
`CREATE_REPLICATION_SLOT "pg_basebackup_1234" TEMPORARY PHYSICAL (RESERVE_WAL)`,
`pg_receivewal --create-slot`'s physical form, and the temporary logical form all raise
`Protocol_Error: expected LOGICAL in replication command`.

**What is wrong:** After the slot name, `Decode_Command` unconditionally demands `LOGICAL`.
PostgreSQL's grammar is `CREATE_REPLICATION_SLOT IDENT opt_temporary { PHYSICAL | LOGICAL IDENT }
create_slot_options`, so both `TEMPORARY` and `PHYSICAL` sit exactly where the decoder expects
`LOGICAL`. The interop-critical case is `pg_basebackup` with default options:
`temp_replication_slot` is initialised true and the default `-X stream` renders
`CREATE_REPLICATION_SLOT "pg_basebackup_NNNN" TEMPORARY PHYSICAL (RESERVE_WAL)`. A Flyology
server that routes `BASE_BACKUP`, a capability documented at `docs/BASE_BACKUP.md:102-108`,
therefore fails on the first command a default `pg_basebackup` invocation sends, before
`BASE_BACKUP` is ever reached.

**Notes:** Severity raised from the discovery's P2 by the verifier. One discovery sub-claim is
**refuted**: it states that `libpqrcv_create_slot` appends `TEMPORARY` after the slot name when
a temporary *logical* slot is requested. The code can do that
(`libpqwalreceiver.c` 18.4:925-926), but no stock PostgreSQL caller does; `walreceiver.c`
18.4:362 passes `temporary => true` only on the physical path. So `TEMPORARY LOGICAL` is
grammar-valid but not emitted by a stock client, while `TEMPORARY PHYSICAL` is. Two distinct
fixes are needed. Accepting `TEMPORARY` in its grammatical position is a pure parser correction
with no API change. Representing a physical-slot creation needs a new `Command_Kind` variant,
because `src/flyology-postgres-replication.ads:151` documents only
`CREATE_REPLICATION_SLOT LOGICAL`, plus a `RESERVE_WAL` accessor. That is an API decision.

---

### REPL-3: Standby-initiated CopyDone raises Protocol_Error

**Severity:** P1

**Location:** `src/flyology-postgres-replication-server_sessions.adb:201-206`; requirement at
`src/flyology-postgres-replication.adb:929-931`

**Repro:** `repro_repl_3` — a bare `CopyDone` while the primary awaits feedback makes
`Read_Standby_Message` raise `Protocol_Error: replication streaming requires a CopyData
message`, while `Sessions.Read_Copy_Command` classifies the same bytes as
`FRONTEND_COPY_DONE`.

**What is wrong:** `Read_Standby_Message` feeds whatever `Sessions.Read_Command` returns
straight into `Decode`, which requires a CopyData frame. A standby closing its send direction
mid-stream is not an error in PostgreSQL: `walsender.c` 18.4:2323-2330 answers `PqMsg_CopyDone`
with its own `CopyDone`. PostgreSQL's WAL clients send exactly that while the server is still
streaming; `receivelog.c` calls `PQputCopyEnd` with `still_sending` true at a WAL segment
boundary and in `CheckCopyStreamStop`, which is how `pg_receivewal` and `pg_basebackup`'s
background WAL streamer stop. The path is reachable inside this library:
`managed_primary.adb:80-102` loops on `Read_Standby_Message` and is invoked at `:161` and
`:281`, before `Complete_Copy` switches to `Sessions.Read_Copy_Command`. A standby that stops
at a normal point therefore turns a clean end-of-COPY into `Protocol_Error`, which propagates
out through `Stream_Physical`'s handler (`managed_primary.adb:178-184`), so the physical slot is
never advanced to the feedback LSN the standby already reported.

**Notes:** Severity raised from the discovery's P2 by the verifier, because valid, routine
input produces an unexpected exception on a path the library itself drives in a loop, and the
unwind loses standby progress. The caller receives the same exception text a genuinely
malformed frame produces, with no typed way to tell them apart. A fix needs an API decision:
either a `CopyDone`-carrying result from `Read_Standby_Message` or a distinct end-of-stream
exception or predicate. The current spec
(`src/flyology-postgres-replication-server_sessions.ads:106-112`) documents neither.

---

### REPL-4: Replication SHOW rejects dotted GUC names

**Severity:** P2

**Location:** `src/flyology-postgres-replication.adb:100-104` (`Is_Option_Name`), used by the
`Show` constructor at `:183-189` and the SHOW branch of `Decode_Command` at `:503-514`

**Repro:** `repro_repl_4` — both `Replication.Show ("myext.my_setting")` and
`Decode_Command ("SHOW myext.my_setting")` raise `Protocol_Error: invalid replication SHOW
parameter name`; the `SHOW wal_segment_size` control still round-trips.

**What is wrong:** `Is_Option_Name` admits only `[A-Za-z0-9_]` and therefore rejects `.`.
PostgreSQL's replication grammar builds a dotted GUC name explicitly: `show: K_SHOW var_name`
with `var_name: IDENT | var_name '.' IDENT`, and the replication scanner returns `.` as itself.
So `SHOW myext.my_setting` is valid replication-mode syntax on every supported major, and
namespaced GUCs are the standard way PostgreSQL extensions expose settings. A caller issuing
`SHOW` for a namespaced GUC, or a Flyology server decoding such a `SHOW` from a client, gets a
`Protocol_Error` for a parameter PostgreSQL would accept.

**Notes:** No stock PostgreSQL client sends a dotted `SHOW`; the only replication-mode `SHOW`
commands stock clients issue are `SHOW wal_segment_size` and `SHOW data_directory_mode`, and
`managed_primary.adb:318-331` answers only core GUCs. Related but not separately reported:
`Is_Option_Name` also rejects `$` and 8-bit bytes, which PostgreSQL's `ident_cont` allows.

---

### REPL-5: IDENTIFY_SYSTEM timeline column declared int4 for every peer

**Severity:** P2

**Location:** `src/flyology-postgres-replication-server_sessions.adb:47-79`; API at
`src/flyology-postgres-replication-server_sessions.ads:9-15`

**Repro:** `repro_repl_5` — column 2 is `timeline` with type OID 23 and width 4, where
PostgreSQL 16, 17 and 18 send OID 20 and width 8.

**What is wrong:** `Send_Identify_System` builds the four-column result set with
`Make_Field_Description ("timeline", Type_Oid => 23, Type_Size => 4)`, an unconditional int4
declaration. `walsender.c` `IdentifySystem()` splits on the major: 14.23 and 15.18 declare
column 2 with `INT4OID` and fill it with `Int32GetDatum`, while 16.14, 17.10 and 18.4 declare
it with `INT8OID` and `Int64GetDatum`. A Flyology-based primary or proxy therefore advertises
the wrong column type, and the wrong width, to three of the five supported majors. The
transmitted DataRow payload is still the correct decimal text.

**Notes:** Protocol fidelity only. Both stock consumers read the value as text without
inspecting the descriptor, so walreceiver, `pg_basebackup` and `pg_receivewal` are unaffected,
as is this library's own client path. What breaks is a typed or generic client that binds by
result type, or a fidelity test that diffs the RowDescription against a real server. Unlike
BACKUP-7, whose `tli` column is int8 in all five majors, this column has two correct answers
and `Send_Identify_System` takes no server major, so the API cannot express the 16+ answer at
all. A fix needs a user decision on how the peer major reaches the call: a new `Server_Major`
parameter (precedent exists at
`src/flyology-postgres-replication-base_backups.ads:11` and
`src/flyology-postgres-replication.ads:95`), carrying the major on the `Sessions.Session`, or
exposing the column descriptors. A defaulted parameter changes the answer for existing callers
at `managed_primary.adb:311`, `tests/src/postgres_test_replication_server.adb:254` and
`examples/psqlbench/src/psqlbench_links.adb:669`, which is itself a policy decision.

---

## Base backup, persistence and prepared consumer (BACKUP-1 .. BACKUP-7)

### BACKUP-1: Promote stores only the newest timeline history line

**Severity:** P1

**Location:** `src/flyology-postgres-replication-persistence-memory.adb:255-283`; read back at
`:244-253`; forwarded by `managed_primary.adb:332-337`

**Repro:** `repro_backup_1` — after two promotions, `00000003.history` is
`"2\t0/C8\tpromotion\n"` alone, without the inherited timeline-1 line.

**What is wrong:** `Memory.Promote` writes exactly one
`<parentTLI>\t<switchpoint>\tpromotion\n` line into a fresh history entry and never reads the
parent's entry. PostgreSQL's `writeTimeLineHistory` copies the parent history file verbatim
before appending that line, so a genuine `0000000N.history` enumerates every ancestor; all five
cached majors contain the "If a history file exists for the parent, copy it verbatim" comment
at `timeline.c:332`. `Persistence.History` is documented as "a timeline history file exactly as
sent to a standby" (`persistence.ads:219-224`), and `Managed_Primary` forwards those bytes
unchanged over `TIMELINE_HISTORY` with no reformatting on the path. After a second promotion,
the file for timeline 3 no longer mentions timeline 1, so a standby still on timeline 1 logs
"new timeline 3 is not a child of database system timeline 1" (`xlogrecovery.c:4188`) and
cannot follow the primary.

**Notes:** It stops short of P0 only because it needs two promotions, which no current test or
CI shard performs; the PostgreSQL 18 shard exercises a single 1 to 2 switch, which one line
happens to satisfy. The repro asserts containment of the inherited line rather than exact bytes,
because PostgreSQL's extra separator newline makes a byte-exact expectation brittle.
`Persistence.Memory` is the only implementation of `Timeline_Store` and `WAL_Store` in the tree,
and `tests/src/replication_test_durable_store.adb` delegates to it, so the defect propagates to
the test backend unchanged.

---

### BACKUP-2: Retention floor is order-dependent when a live slot restarts at zero

**Severity:** P1

**Location:** `src/flyology-postgres-replication-persistence-memory.adb:163-175`; consumed by
`src/flyology-postgres-replication-managed_primary.adb:104-114`

**Repro:** `repro_backup_2` — the same two slots yield `Oldest_Restart_LSN = 50` in one creation
order and `0` in the other; after `Apply_Retention`, `First_LSN` moves to 50 and `Read (0, 10)`
raises `Store_Error`.

**What is wrong:** `Oldest_Restart_LSN` uses `Result = 0` as its "no candidate yet" sentinel
while zero is also a valid restart LSN, so the minimum it computes depends on which array index
each slot occupies. `Managed_Primary.Apply_Retention` feeds that value directly into
`Retain_From`, so in the unlucky order it discards every WAL byte below 50 while a live slot
still restarts from 0. A slot at restart 0 is not contrived: `Managed_Primary`'s
`CREATE_REPLICATION_SLOT` handler (`managed_primary.adb:339-359`) creates logical slots at
`Current_LSN`, which is zero on a fresh Memory store, and `Make_Slot` accepts
`Restart_LSN => 0` without complaint. The interface documents this function as "the retention
floor across all non-invalidated slots" (`persistence.ads:175-178`), so it must be the true
minimum and must not depend on iteration order.

**Notes:** Severity raised from the discovery's P2 by the verifier, which also established that
the wrong value is not merely order-dependent but a retention floor above a live slot's restart
LSN, so WAL the slot needs is destroyed. The verifier stopped at P1 rather than P0 because the
defect is confined to the reference `Memory` store and the test store that wraps it, and
recorded that applying the P0 "WAL retention floor too high" example literally would justify P0.
The conformance fixture `tests/src/replication_persistence_conformance.adb:123` checks a single
nonzero value and cannot catch it.

---

### BACKUP-3: Append on a drained store rewinds Current_LSN and reuses positions

**Severity:** P2

**Location:** `src/flyology-postgres-replication-persistence-memory.adb:206-217`;
`Retain_From` at `:219-239`

**Repro:** `repro_backup_3` — after `Append (100, 6)`, `Retain_From (106)` and `Append (50, 4)`,
the store reports `First_LSN = 50` and `Current_LSN = 54`, with no `Store_Error`.

**What is wrong:** `Memory.Append` decides contiguity solely from whether the retained byte
buffer is empty, so a store whose bytes were all trimmed by `Retain_From` is treated as
brand-new and silently rebased to whatever `Start` the caller passes.
`Retain_From (Oldest = Current_LSN)` is exactly what `Managed_Primary.Apply_Retention` performs
once the only slot's restart LSN has caught up with the end of WAL, and it produces such a store
while `First_LSN = Current_LSN` is still a real, already-streamed position. The end position
therefore moves backwards, and positions already handed to a standby become reusable for
different bytes. The mistake surfaces only later, as a misleading "slot retention floor exceeds
available WAL" from `Apply_Retention`.

**Notes:** The verifier recorded a partial defence: the `Append` contract does say "@param Start
Current_LSN, or the base position of an empty store" (`persistence.ads:199-206`), and a fully
drained store is byte-empty. What the documentation does not permit is the observable effect,
since `Retain_From` is documented only to discard bytes before `Oldest`. Kept at P2 because
reaching it needs a caller to pass a `Start` that is not the store's end position, and no
library code path does. Either `Memory` should keep the drained end position and raise
`Store_Error`, or the `Append` contract should say a drained store may be rebased; the outcome
should not depend on the size of an internal buffer.

---

### BACKUP-4: Generation keeps returning the stale lease after Release

**Severity:** P1

**Location:** `src/flyology-postgres-replication-persistence.adb:43`; `Memory.Release` at
`src/flyology-postgres-replication-persistence-memory.adb:147-161`; contract at
`persistence.ads:72-75`

**Repro:** `repro_backup_4` — after `Release`, `Is_Active = FALSE` but `Generation = 1`.

**What is wrong:** `Persistence.Generation` is documented to return "Nonzero generation for an
acquired slot, otherwise zero", but `Memory.Release` clears only the `Active` flag and leaves
the `Lease` field set, and the accessor returns that field unconditionally. After the ordinary
`Acquire` then `Release` cycle, `Load` returns a snapshot reporting `Is_Active = False` together
with `Generation = 1`. Application code that follows the accessor's documentation and uses
`Generation (State) /= 0` as its "this slot is currently leased" test therefore sees a free slot
as held, for the entire remaining life of the slot. Nothing else in the library clears the
field, and no library code consumes `Generation`, so only application code can observe the
contract, and application code is exactly who the accessor is documented for.

**Notes:** Severity raised from the discovery's P2 by the verifier, because the rubric puts a
violated documented contract at P1 and this needs no unusual input. It sits at the low end of
P1: `Is_Active` on the same snapshot still gives the right answer, so the fix may equally be to
correct the accessor's documentation and state that `Generation` is a retained fencing epoch.
Code and documentation cannot both stand as they are. The persistence conformance fixture never
asserts `Generation` after a release, so the reference behaviour it pins is the wrong one.

---

### BACKUP-5: Prepare overwrites a Target_Applied marker for the same GID

**Severity:** P1

**Location:** `src/flyology-postgres-replication-prepared_consumer.adb:7-20`; `Put` contract at
`persistence.ads:281-286`, implementation at
`src/flyology-postgres-replication-persistence-memory.adb:299-326`

**Repro:** `repro_backup_5` — a replayed PREPARE and COMMIT PREPARED applied the target a second
time; after the source reused the GID, `Acknowledge_Commit` for the first transaction raised
`Protocol_Error: prepared commit acknowledgement precedes target application`.

**What is wrong:** `Prepared_Consumer.Prepare` persists the incoming payload with an
unconditional `Stores.Put`, which is documented to insert or replace state for `(slot, GID)`. A
second PREPARE for a GID whose transaction has already reached `Target_Applied` therefore
demotes the durable phase back to `Prepared` and destroys the replay guard the package header
promises: "an applied marker prevents replay after target application has been recorded"
(`prepared_consumer.ads:3-5`). Two consequences follow. A consumer that applied and marked a
transaction but failed before its feedback confirmed the commit LSN receives the same PREPARE
again when PostgreSQL re-decodes from the confirmed flush position, and `Apply_Target` runs
twice. Separately, PostgreSQL permits a GID to be reused once the earlier prepared transaction
has committed; when the source does so before the consumer has acknowledged the earlier commit
LSN, the pending `Acknowledge_Commit` raises `Protocol_Error`. The defect is in the consumer,
not in the store: `Put` behaves per contract.

**Notes:** Severity raised from the discovery's P2 by the verifier. Scenario 2 is an unexpected
exception on valid input via a reachable path, because the API explicitly directs the
application to defer `Acknowledge_Commit` until the source commit LSN is durably acknowledged,
which is what opens the window. The discovery's P2 is defensible if one weights only the
same-XID crash-replay case, where the header's documented `Apply_Target` idempotence
requirement absorbs the extra apply; that requirement does not cover scenario 2, where the XID
differs. `Prepare` must not clear an existing applied marker for the same `(slot, GID)`.

---

### BACKUP-6: Create accepts an active or invalidated snapshot as initial state

**Severity:** P2

**Location:** `src/flyology-postgres-replication-persistence-memory.adb:36-57`; documented
`Store_Error` at `memory.ads:29`; parameter contract at `persistence.ads:93-102`

**Repro:** `repro_backup_6` — `Create` with an active, leased snapshot returned `CREATED`;
`Acquire` then returns `ALREADY_ACTIVE` with lease 0, `Drop` returns `FALSE`, and the slot still
pins the retention floor at 10.

**What is wrong:** `Memory.Create` validates only that the supplied `Slot_State` has `Present`
set, then copies the entire record including `Active`, `Lease` and `Invalid`. Seeding one store
from another store's snapshot, the obvious use for `Load` returning a value the same package's
`Create` accepts, therefore produces a slot that is permanently active under a lease no owner of
the receiving store holds. `Acquire` returns `Already_Active` with a zero lease forever, `Drop`
refuses because the slot is active, and `Oldest_Restart_LSN` keeps the slot's restart LSN as the
WAL retention floor. The `Store_Error` that `memory.ads:29` documents for an invalid state is
never raised.

**Notes:** Kept at P2: the parameter is documented as "Initial state created by Make_Slot", so
producing an active snapshot requires passing a `Load` result instead, which is out-of-contract
input. It is worth fixing because the failure mode has no recovery path short of discarding the
store, and because `Create` already performs a partial validation, so the check is one clause
wider.

---

### BACKUP-7: Base backup position result set declares tli as int4

**Severity:** P2

**Location:** `src/flyology-postgres-replication-base_backups-server_sessions.adb:23-46`, used
by `Send_Start_Position` at `:45-52` and `Send_End_Position` at `:179-188`

**Repro:** `repro_backup_7` — column 2 is `tli` with type OID 23 and width 4, where PostgreSQL
14 through 18 all send OID 20.

**What is wrong:** `Send_Position` advertises the base backup start- and end-position result
set's `tli` column as int4. PostgreSQL 14 through 18 all declare it as int8, deliberately and
with an explanatory comment, because `TimeLineID` is unsigned and would not fit in int4;
`basebackup.c:1047` in 14.23, `basebackup_copy.c:337` in 15.18, and `basebackup_copy.c:358` in
16.14, 17.10 and 18.4 were each checked. Both position result sets go through this one
procedure, so a server or proxy built on this package advertises a row shape that differs from
the server it stands in for. The transmitted value is text and remains correct.

**Notes:** Low impact: this library's own `Base_Backups.Receiver` and `pg_basebackup` read the
column as text and never inspect the type OID. A client that decodes by declared type would
mis-handle timelines above 2^31-1. Unlike REPL-5, this column has a single correct answer across
all five majors, so it admits an unconditional correction. Two adjacent observations, offered
for the fixer rather than as findings: the `IDENTIFY_SYSTEM` `timeline` column has the same
shape of defect and is REPL-5; and PostgreSQL's `SendXlogRecPtrResult` ends with
`pq_puttextmessage ('C', "SELECT")` where the library sends `"SELECT 1"`
(`server_sessions.adb:42`), which is cosmetic.

---

## Examples: pgish, psqlish, psqlbench (EXAMPLES-1 .. EXAMPLES-11)

### EXAMPLES-1: LIKE '%' raises Pattern_Error instead of matching every value

**Severity:** P1

**Location:** `examples/pgish/src/pgish_catalog.adb:444-466`; SQLSTATE mapping at
`examples/pgish/src/pgish_handler.adb:111-124`

**Repro:** `repro_examples_1` — `LIKE '%'` and `LIKE '%%'` both raise
`ADA.STRINGS.PATTERN_ERROR : a-strsea.adb:300`. On the wire, the client receives
`ErrorResponse severity=ERROR code=XX000 msg=a-strsea.adb:300`.

**What is wrong:** `Pgish_Catalog.Like` strips a leading and a trailing `%`, so for the patterns
`'%'` and `'%%'` it is left with a null needle. The `Leading and Trailing` branch then calls
`Ada.Strings.Fixed.Index (Value, "")`, which RM A.4.3 requires to propagate
`Ada.Strings.Pattern_Error`. The exception escapes `Pgish_Catalog.Execute`, and
`Pgish_Handler.SQL_State_For` matches only pgish's own exception names, so it reports SQLSTATE
`XX000` with the GNAT runtime's message as the client-visible error text. The pgish README
documents substring `%` patterns and `LIKE '%'` is a normal "everything non-NULL" idiom, so a
documented, valid query returns an internal-error diagnostic instead of the six
`flyology_settings` rows.

**Notes:** The error text leaks an internal runtime source location to the network. Not P0: the
session survives, `ReadyForQuery` still arrives, and psql recovers.

---

### EXAMPLES-2: NOT LIKE is silently evaluated as LIKE

**Severity:** P1

**Location:** `examples/pgish/src/pgish_sql.adb:413-436`

**Repro:** `repro_examples_2` — `NOT LIKE 'maximum%'` returns the four `maximum_*` rows.
Confirmed on the wire: `CommandComplete 'SELECT 4'` with the four excluded rows.

**What is wrong:** `Pgish_SQL.Add_Predicate` computes the operator name but, on the
`A_Expr_Kind_Aexpr_Like` branch, never consults it: it unconditionally stores `Like_Match`. The
PostgreSQL grammar lowers `a NOT LIKE b` to the same `AEXPR_LIKE` kind with operator name `!~~`,
visible in the checked-in grammar at
`sql/backends/v18/vendor/native_source/backend/parser/gram.y:15039` and `:15048`, so pgish
stores an un-negated LIKE predicate. `SELECT name FROM flyology_settings WHERE name NOT LIKE
'maximum%'` therefore returns exactly the four rows PostgreSQL excludes and omits
`authentication` and `tls`. No error is emitted, so the client cannot tell the answer is
inverted.

**Notes:** The pgish README lists `LIKE` but not `NOT LIKE`, and states that unsupported
constructs "return an ErrorResponse with a specific SQLSTATE". Either negating correctly or
rejecting the statement satisfies the documented contract, and the repro accepts either.

---

### EXAMPLES-3: ORDER BY compares integer columns as text

**Severity:** P1

**Location:** `examples/pgish/src/pgish_catalog.adb:623-651` (`Sort.Before`), against
`Matches` at `:486-503`

**Repro:** `repro_examples_3` — ascending `ORDER BY ordinal_position` yields
`1,10,11,12,13,14,15,16,2,3,4,5,6,7,8,9`, while `WHERE ordinal_position > 9` correctly yields
seven rows.

**What is wrong:** `Pgish_Catalog.Sort.Before` always compares `SQL.Image (...)` values as Ada
strings, ignoring the column's type OID, while `Pgish_Catalog.Matches` detects two numeric
operands and compares them as `Long_Long_Integer`. The two halves of the same query therefore
disagree. The same applies to every integer column in the catalog, including `session_id`,
`group_id`, `members`, `dispatches`, `query_count`, `listen_port` and `uptime_seconds`, so
`ORDER BY dispatches DESC` ranks 9 above 1000. Three README example queries are affected as soon
as any value reaches two digits: `ORDER BY group_id`, `ORDER BY session_id` and
`ORDER BY committed_at DESC`.

**Notes:** Independently observed on the wire: the README's own `ORDER BY session_id` example
returned `1, 10, 11, 12, 13, 14, 15, 17, 2, 3, ...` once a server had served ten connections.

---

### EXAMPLES-4: psqlish raises Constraint_Error on any zero-column result

**Severity:** P1

**Location:** `examples/psqlish/src/psqlish_main.adb:234` and `:262`; accessors declared
`Natural` at `src/flyology-postgres-protocol.ads:370` and `:414`

**Repro:** `repro_examples_4` — a zero-field RowDescription and a zero-column DataRow decode
correctly through the library, then fail the two narrowing declarations copied from
`psqlish_main.adb` with `CONSTRAINT_ERROR ... range check failed`.

**What is wrong:** `psqlish_main.adb` narrows the library's `Natural`-valued accessors to
`Positive`: `Count : constant Positive := Protocol.Field_Count (Description);` and
`Count : constant Positive := Protocol.Column_Count (Row);`. A zero-field RowDescription is
legal on the wire; real PostgreSQL produces one for `SELECT;` and pgish produces one for
`SELECT *;`. The range check fails, the `Constraint_Error` leaves `Execute_Query`, `Run`'s
handler at `psqlish_main.adb:516-522` closes the socket without sending Terminate and re-raises,
and the top-level handler prints `Exception_Information` and exits nonzero. An interactive
session is destroyed rather than showing an empty result.

**Notes:** `Psqlish.Display.Begin_Result` already accepts an empty `Column_Array` and renders
just the command tag, so the defect is confined to the two narrowings in the client main.
psqlish is not built in this worktree and building it would have written into a directory the
review was not permitted to touch, so the client binary was not exercised; the reachability of a
zero-field RowDescription was confirmed on the wire against pgish, which is EXAMPLES-11. Not P0
because it needs the unusual though valid `SELECT;` or `SELECT *;`.

---

### EXAMPLES-5: information_schema.columns unusable without a table_name equality

**Severity:** P1

**Location:** `examples/pgish/src/pgish_catalog.adb:356-410`
(`Add_Information_Columns`); row cap at `:83-90`; filter push-down at `:653-706`

**Repro:** `repro_examples_5` — `SELECT column_name FROM information_schema.columns LIMIT 5`,
and the `table_schema =` and `table_name LIKE` variants, all raise
`PGISH_CATALOG.RESOURCE_LIMIT_ERROR : result row limit exceeded`. On the wire: SQLSTATE 54000.

**What is wrong:** `Add_Information_Columns` materializes one row per column of every virtual
table before any projection, filtering or `LIMIT` is applied, which is 55 rows. `Add_Row` raises
`Resource_Limit_Error` at `Maximum_Rows = 32`, and `Pgish_Catalog.Execute` pushes a filter into
the generator only for the first predicate whose base column name is `table_name` **and** whose
operator is `Equal_To`. A bare `LIMIT`, a `table_schema =` filter, or a `table_name LIKE` filter
therefore all abort with "result row limit exceeded" even though the requested result is one to
five rows, far inside the documented 32-row bound. Only psqlish's `\d TABLE` shape works, which
always supplies `table_name = ...`.

**Notes:** Severity raised from the discovery's P2 by the verifier: the failing query is built
entirely from documented subset features, a documented table and the documented `LIMIT 0..32`,
so the P2 "unusual input" clause does not apply. The discovery's P2 is defensible because the
failure is a clean ErrorResponse with a plausible SQLSTATE and the session stays usable. The
working shape is exactly the one `pgish_tests.adb:156-168` covers.

---

### EXAMPLES-6: Quoted identifiers case-folded and qualifiers ignored

**Severity:** P2

**Location:** `examples/pgish/src/pgish_catalog.adb:92-96` (`Base_Name`), used by `Find_Column`
at `:98-108`, `Load_Source` at `:412-434` and `Add_Projected_Column` at `:515-558`

**Repro:** `repro_examples_6` — `"PROTOCOL_VERSION"`, `"FLYOLOGY_SERVER_INFO"`, an unknown
column qualifier and an unknown schema qualifier are all accepted and answered with rows.

**What is wrong:** `Base_Name` drops everything before the last dot and lower-cases the
remainder, and it is the only name normalizer pgish uses. The PostgreSQL parser preserves the
case of a double-quoted identifier and folds only unquoted ones, so
`SELECT "PROTOCOL_VERSION" FROM flyology_server_info` reaches pgish with its case intact and is
then folded away: the query succeeds and the result column is labelled `protocol_version`, where
PostgreSQL raises 42703. The same folding makes `FROM "FLYOLOGY_SERVER_INFO"` resolve. Because
the qualifier is discarded rather than checked,
`SELECT nowhere.protocol_version FROM flyology_server_info` and
`SELECT * FROM bogus_schema.flyology_tables` both succeed. This violates the README's
"Identifiers are case-insensitive unless double quoted".

**Notes:** Kept at P2 because it needs upper-case quoted identifiers or bogus qualifiers. No
valid query returns a wrong value; pgish accepts queries PostgreSQL would reject. A client that
relies on quoting to disambiguate, or that mistypes a schema, gets silent success instead of an
error.

---

### EXAMPLES-7: Phantom sessions refuse admission with a false 28P01 error

**Severity:** P1

**Location:** `examples/pgish/src/pgish_handler.adb:419` (`Remove_Session` called only from the
Terminate branch); registry at `examples/pgish/src/pgish_state.adb:28-65`; per-connection loop at
`src/flyology-postgres-server.adb:486-521`

**Repro:** `repro_examples_7` — `flyology_sessions` still reported 16 sessions after every peer
disconnected, and a fresh client was not admitted. End-to-end against the pgish binary: 16 of 16
admitted on a clean server, 8 of 16 admitted after 16 abrupt disconnects, the refusals reported
as `FATAL 28P01 password authentication failed` on a trust-authentication server.

**What is wrong:** `Pgish_Handler.Handle` calls `Pgish_State.Remove_Session` only from the
`Protocol.Terminate_Command` branch, and `Flyology.Postgres.Server`'s generic formals offer no
disconnect callback. When `Read_Command` raises on peer EOF or reset, on a TLS failure, or on
the 300 s `Command_Timeout`, the library's per-connection loop removes only its own
cancellation-router entry and re-raises, leaving the pgish registry slot occupied with state
"idle". `Pgish_State.Register` reuses an occupied slot only when its owner is the same handler
task, so the slot is consumed until that one task happens to serve another connection. Sixteen
slots are shared by 17 handler workers, because `Worker_Capacity` returns `Capacity + 1`, so once
phantoms fill the registry a new connection served by a worker without a slot gets
`Accepted = False` from `Authenticate` and the library answers `FATAL 28P01`.

**Notes:** Severity raised from the discovery's P2 by the verifier, and one sub-claim is
**refuted by measurement**: the discovery concluded "No slot exhaustion is possible (one slot per
handler task), so this is a state/observability error, not a denial of service". Phantom slots do
block admission for legitimate clients. It stops short of P0 because it takes an accumulation of
abrupt disconnects rather than a single ordinary input, and the refusal is a well-formed FATAL
ErrorResponse rather than a protocol violation. The README's "The server admits at most 16
sessions" becomes untrue after ordinary client churn, and the README's `flyology_sessions`
example reports dead sessions with their old `session_id`, `query_count` and `connected_at`.

---

### EXAMPLES-8: Option and environment errors bypass the main exception handler

**Severity:** P2

**Location:** `examples/pgish/src/flyology_pgish.adb:136`; intended handler at `:242-249`

**Repro:** none written. Verified by running the prebuilt
`examples/pgish/bin/flyology_pgish` under `timeout`. `--port abc`, `--port 70000`, `--bogus`,
`--task-mode weird`, a lone `--tls-cert`, and `FLYOLOGY_PGISH_PORT=x` each produced GNAT's
unhandled-exception report with a load address and raw traceback, and exit 1.

**What is wrong:** The main procedure elaborates
`Options : constant Parsed_Configuration := Read_Configuration;` in its declarative part.
`Read_Configuration` raises `Constraint_Error` for an unknown option, a missing option value, a
non-numeric or out-of-range `--port`, a bad `--task-mode`, a lone `--tls-cert` or `--tls-key`,
and a non-numeric `FLYOLOGY_PGISH_PORT`. Per RM 11.2 an exception raised while elaborating a
body's declarative part is not handled by that body's own handler, so the handler at `:242-249`,
which prints `flyology_pgish: <message>` and calls `Set_Exit_Status (Failure)`, never runs. Users
get a raw traceback instead of the intended one-line diagnostic.

**Notes:** No repro program was written because the defect lives in a main procedure's
declarative part and cannot be called from a test program. No hang occurs: `Shutdown_Watcher` is
never activated when the declarative part fails, and the process exits 1. Moving the elaboration
into the statement part, or wrapping it in a block with its own handler, restores the intended
behaviour. This is the same Ada mechanism as SERVER-1 and PROTO-4.

---

### EXAMPLES-9: psqlish expanded output misaligns field names

**Severity:** P2

**Location:** `examples/psqlish/src/psqlish-display.adb:327-345`; widths computed at `:304-322`

**Repro:** `repro_examples_9` — psqlish renders `n | 7` and `value | alpha`, separators in
columns 3 and 7, where psql renders both separators in column 7.

**What is wrong:** `Psqlish.Display.Finish_Result` computes `Widths (Index)` as the per-column
maximum of the header text and every value in that column, which is the right quantity for the
tabular layout. The expanded renderer then reuses the same array to pad the field name:
`Line (Name & Spaces (Widths (Index) - Name'Length) & " | " & Value);`. In expanded mode each
field occupies its own line, so the name column must be padded to the widest field name, not to
each column's data width. Conversely, a short name with a wide value pushes that one separator
far to the right, so the separator column wanders from line to line within a single record.

**Notes:** Cosmetic misrendering; no data is lost or altered.

---

### EXAMPLES-10: Empty and comment-only queries answered with error 42601

**Severity:** P2

**Location:** `examples/pgish/src/pgish_handler.adb:305-316` (Query branch) and `:318-329`
(Parse branch); `Pgish_SQL.Parse` raises at `examples/pgish/src/pgish_sql.adb:705-709`

**Repro:** `repro_examples_10` — a bare semicolon, a line comment, a block comment, a
newline-only query, a tab-only query and an empty string all produce
`Syntax_Error "expected SELECT or SHOW statement"` mapped to SQLSTATE 42601. Confirmed on the
wire for the semicolon and comment cases.

**What is wrong:** The Query branch sends EmptyQueryResponse only when
`Ada.Strings.Fixed.Trim (Query_Text, Both)` is empty; everything else reaches `Pgish_SQL.Parse`,
which raises `Syntax_Error` whenever the parsed tree contains zero statements.
`Pgish_Handler.SQL_State_For` maps that to 42601. PostgreSQL's `exec_simple_query` answers
EmptyQueryResponse for a query string containing no statement, so a bare `;`, a comment-only
submission, or a whitespace-only submission is reported by pgish as a syntax error where the
reference server reports an empty query.

**Notes:** Broader than the discovery reported. RM A.4.3 defines `Trim` as removing space
characters only, so tab-, newline- and carriage-return-only Query messages bypass the intended
guard as well. The extended-query `Parse` branch has no emptiness guard at all, so preparing an
empty statement, which PostgreSQL permits, is rejected too. Kept at P2 because real psql strips a
bare `;` client-side and libpq tolerates the error, so impact is limited to scripted or
programmatic clients.

---

### EXAMPLES-11: SELECT star with no FROM produces a zero-column row

**Severity:** P2

**Location:** `examples/pgish/src/pgish_catalog.adb:519-527` and `:569-573` (star expansion),
with the row still added at `:600-607`

**Repro:** `repro_examples_11` — `SELECT *` and `SELECT *;` are accepted with `Column_Count = 0`
and `Row_Count = 1`. On the wire: `RowDescription fields=0`, `DataRow []`,
`CommandComplete 'SELECT 1'`.

**What is wrong:** In `Pgish_Catalog.Project`, star expansion loops over `Source.Column_Count`.
With no FROM clause `Source` is the default empty `Result_Set`, so neither a column nor a value
is added. The code then still calls `Add_Projected_Row (Empty_Row)` for the no-table case, so the
result is one row of zero columns. `Pgish_Handler.Send_Result` faithfully puts a RowDescription
with 0 fields, a DataRow with 0 columns, and `CommandComplete 'SELECT 1'` on the wire.
PostgreSQL rejects `SELECT *` without tables with SQLSTATE 42601, "SELECT * with no tables
specified is not valid".

**Notes:** pgish itself stays healthy and the wire messages are well formed. The practical harm
is that it hands psqlish exactly the input that trips EXAMPLES-4, so `SELECT *;` typed into
psqlish against pgish crashes the client, where real psql prints `--` and `(1 row)` and survives.

---

## SQL parser (SQL-1 .. SQL-9, SQL-8b)

The SQL findings were verified against the version-pinned C oracle (pg_query) for
each major, and against the vendored `scan.l`, `gram.y`, `parser.c` and `scansup.c`
under `sql/backends/v*/vendor`. Every repro below compares the native Ada parser
with the oracle on the same input. SQL-8b was found by the verifier while
reproducing SQL-8; it is not in the discovery report.

### SQL-1: `E'\v'` unescapes to the letter v instead of vertical tab on 17 and 18

**Severity:** P1

**Location:** `sql/src/flyology-postgres-sql-native-scanner.adb:197-204`
(`Unescaped_Character`), used by the escape action at `:381-385`

**Repro:** `repro_sql_1` — on v17 and v18 the oracle's `A_Const.sval` for
`SELECT E'a\vb'` is `a<0x0B>b` and the native value is `avb`; v14 to v16 agree.

**What is wrong:** `Unescaped_Character` maps only `b f n r t` and returns every
other escaped character unchanged, and it has no version parameter. PostgreSQL 17
added `case 'v': return '\v';` to `unescape_single_char` in `scan.l`
(`v17/.../scan.l:1406-1421`, `v18/.../scan.l:1398-1413`); the v14 to v16 copies stop
at `case 't'`. From v17 on, `E'a\vb'` is the three bytes `0x61 0x0B 0x62`, while the
Ada scanner stores `0x61 0x76 0x62`. The statement is valid SQL and parses
successfully on both sides, so the wrong byte reaches the consumer silently.

**Notes:** Affects PostgreSQL 17 and 18 only. Fixing it needs the scanner to know
the major, or a per-major generated table, since the body is shared by all five
backends.

---

### SQL-2: Octal escapes `\400` to `\777` fail the parse with a GNAT range-check message

**Severity:** P1

**Location:** `sql/src/flyology-postgres-sql-native-scanner.adb:386-394`
(`Octal_Escape` action)

**Repro:** `repro_sql_2` — `SELECT E'\401'` is valid for the oracle on all five
majors and yields an `A_Const`; native returns an invalid tree whose diagnostic is
`flyology-postgres-sql-native-scanner.adb:393 range check failed` at cursor 1.

**What is wrong:** The action decodes up to three octal digits into a `Natural`
(maximum 511) and calls `Character'Val (Code)`, which raises `Constraint_Error` for
any value above 255. PostgreSQL's `<xe>{xeoctesc}` rule stores the value in an
`unsigned char` (`v18/.../scan.l:722-729`), so `\400` to `\777` are truncated to
their low byte and `E'\401'` is the single byte `0x01`. The engine's generic handler
catches the `Constraint_Error` and publishes GNAT's check text as the public
`Diagnostic`, pointing at the first token. The same check also masks the real
PostgreSQL diagnostics for `\400` and `\777`, which are encoding errors for the
bytes `0x00` and `0xff`.

**Notes:** No exception escapes `Parse`, so this is not a crash. Three-digit octal
escapes at or above `\400` are unusual input, which is why it stays P1 rather than
P0. The published diagnostic is an implementation detail of the Ada runtime.

---

### SQL-3: `\U` escapes at or above 0x80000000 overflow `Natural`

**Severity:** P2

**Location:** `sql/src/flyology-postgres-sql-native-scanner.adb:70-77`
(`Based_Value`)

**Repro:** `repro_sql_3` — `SELECT E'\UFFFFFFFF'` yields
`flyology-postgres-sql-native-scanner.adb:74 overflow check failed` at cursor 1
natively, against the oracle's `invalid Unicode escape value at or near
"\UFFFFFFFF"` at cursor 10; the control `\U7FFFFFFF` reaches the intended path.

**What is wrong:** `Based_Value` accumulates into `Natural`, whose upper bound is
2**31-1 on this toolchain, so the eight hex digits of the `\UXXXXXXXX` form
overflow on the final multiply for any value at or above 0x80000000. `scan.l` reads
the digits with `strtoul` into a `pg_wchar` and lets `addunicode` reject the value
with `invalid Unicode escape value` at the backslash. Both parsers reject the
statement; only the diagnostic text and cursor diverge.

**Notes:** Affects all five majors, inside `E'...'` strings only.

---

### SQL-4: Escape strings that assemble invalid UTF-8 are accepted

**Severity:** P2

**Location:** `sql/src/flyology-postgres-sql-native-scanner.adb:386-403`
(`Octal_Escape`, `Hex_Escape`) and `:206-218` (`Finish_Quoted`)

**Repro:** `repro_sql_4` — native accepts `SELECT E'\377'` and `SELECT E'\xC3'`
on every major; the oracle rejects both with `invalid byte sequence for encoding
"UTF8": 0xff` / `0xc3`. `E'\303\251'` agrees on both sides.

**What is wrong:** The escape actions append `Character'Val (Code)`
unconditionally and `Finish_Quoted` returns the literal without validating its
encoding. PostgreSQL's `scan.l` sets `saw_non_ascii` when an escape produces a NUL
or high-bit byte and calls `pg_verifymbstr` before returning `SCONST`
(`v18/.../scan.l:616-624`, `:722-737`). The native parser hands the consumer an
`A_Const.sval` that is not valid UTF-8. The zero-byte case fails on both sides but
with a different message and cursor.

**Notes:** Malformed, unusual input is accepted; no valid statement is misparsed.

---

### SQL-5: `UESCAPE` character check misses form feed and, on 17 and 18, vertical tab

**Severity:** P2

**Location:** `sql/src/flyology-postgres-sql-native-scanner.adb:717-722`

**Repro:** `repro_sql_5` — `SELECT U&'a' UESCAPE E'\f'` parses natively on every
major and `SELECT U&'a' UESCAPE E'\v'` parses on v17 and v18, where the oracle
reports `invalid Unicode escape character at or near "E'\f'"` (respectively
`E'\v'`) at cursor 22.

**What is wrong:** The Ada check validates the `UESCAPE` character against a
hand-written set that omits form feed (`Character'Val (12)`) on all majors and
vertical tab (`Character'Val (11)`) on v17 and v18. `parser.c`'s
`check_uescapechar` delegates to `scanner_isspace`, which lists form feed in every
major (`v14/.../src_backend_parser_scansup.c:126-136`) and adds vertical tab in
v17 and v18. On v14 to v16 the vertical-tab case legitimately succeeds because
`E'\v'` there denotes the letter `v` (see SQL-1).

**Notes:** The discovery report stated the oracle cursor as 21; the verifier
measured 22. Invalid input accepted; no valid statement is misparsed.

---

### SQL-6: v14 `doNegate` folds a minus sign into string and bit-string constants

**Severity:** P1

**Location:** `sql/src/flyology-postgres-sql-native-semantics.adb:330-360`
(`doNegate`); compared with v14 `gram.y:16877-16898`

**Repro:** `repro_sql_6` — on v14, `SELECT -'abc'` produces
`A_Const{sval "-abc"}` natively where the oracle produces
`A_Expr{AEXPR_OP "-", rexpr A_Const{sval "abc"}}`, and the native tree is
indistinguishable from `SELECT '-abc'`; `SELECT -B'101'` diverges the same way.
`-1`, `-1.5` and `-TRUE` agree.

**What is wrong:** `doNegate` decides how to negate an `A_Const` by probing
member paths: when `val.val.str` holds text it rewrites that member in place and
returns the constant. The v14 `Value` union stores `T_Float`, `T_String` and
`T_BitString` payloads in the same `val.val.str` member, so string and bit-string
constants take the float branch. PostgreSQL 14 folds the sign only for `T_Integer`
and `T_Float` and builds `makeSimpleA_Expr (AEXPR_OP, "-", NULL, n, location)` for
everything else. The result is a silent wrong AST for valid SQL. PostgreSQL 15 and
later use distinct `sval`, `fval` and `bsval` members, so the probe selects
correctly there.

**Notes:** Partially confirmed: the discovery's third case, `SELECT -TRUE`, is
refuted because v14's `makeBoolAConst` returns a `TypeCast`, so `doNegate` never
sees an `A_Const`. PostgreSQL 14 only. Unary minus applied directly to a string
literal is uncommon, which keeps this out of P0.

---

### SQL-7: Grammar-level `ereport` errors lose their position and format arguments

**Severity:** P2

**Location:** `sql/tools/generate_native_actions.py:600-609`; reporting at
`sql/src/flyology-postgres-sql-native-engine.adb:128-129`

**Repro:** `repro_sql_7` — `CREATE TABLE t (a int, CHECK (a > 0) DEFERRABLE)`
reports `%s constraints cannot be marked DEFERRABLE` at cursor 48 natively against
the oracle's `CHECK constraints cannot be marked DEFERRABLE` at cursor 38;
`SELECT 1 LIMIT 1, 2` reports `LIMIT #,# syntax is not supported` at 20 against 10.

**What is wrong:** The generator translates a `gram.y`
`ereport (ERROR, (errcode (...), errmsg (FMT, args...), parser_errposition (@n)))`
into `raise Semantics.Parser_Error with Semantics.Text_Of (Builders.Text (FMT))`,
discarding both the `parser_errposition` argument and every `%s` or `%d`
substitution. The engine then reports the message at `Last_Location`, the location
of whichever lookahead token finished the production. Native therefore emits the raw
format string for every template that takes arguments (`processCASbits` variants,
`unrecognized role option "%s"`, `unrecognized JSON encoding: %s`, `column number
must be in range from 1 to %d`) and a wrong cursor for every grammar-level
`ereport`, including argument-free ones.

**Notes:** Affects all five majors; the JSON-encoding template exists from v16. The
verifier placed this at the top of P2 and noted that it becomes P1 if
PostgreSQL-identical diagnostics are treated as part of the public contract, which
`sql/README.md:319-322` comes close to claiming. The oracle carries cursor 0 for the
`processCASbits` and JSON `ereport`s on v14 to v17, so the exact expected cursor is
major-dependent.

---

### SQL-8: Non-EOF scanner diagnostics quote the rest of the input; zero-length identifier cursor off by one

**Severity:** P2

**Location:** `sql/src/flyology-postgres-sql-native-engine.adb:112-119`;
`sql/src/flyology-postgres-sql-native-scanner.adb:431-435`

**Repro:** `repro_sql_8` — every listed case reproduces, including `SELECT ""`
reported at cursor 9 natively against the oracle's 8; the three genuine EOF cases
(`SELECT 'unterminated`, `SELECT $$unterminated`, `SELECT /* unterminated`) agree
and are asserted as controls.

**What is wrong:** The engine builds the "at or near" context for every
`Scanner_Error` as the text from the error offset to the end of the statement. In
flex, `YY_DO_BEFORE_ACTION` NUL-terminates `yytext` at the end of the current
match, so PostgreSQL's `scanner_yyerror` quotes only the matched token; only the
`<<EOF>>` rules quote through end of input. Three related divergences ride along:
`str_udeescape` errors carry no "at or near" suffix in PostgreSQL but get one
natively; `base_yylex` un-truncates the current token before scanning a `UESCAPE`
string so a syntax error quotes the whole `U&'t' UESCAPE '!'` sequence; and the
zero-length delimited identifier is reported at the opening quote in C but at the
closing quote in Ada.

**Notes:** Affects all five majors. Wrong diagnostic text and one off-by-one
cursor, all on input that is invalid on both sides.

---

### SQL-8b: The v18-only `parameter number too large` check is applied to 14 through 17

**Severity:** P1

**Location:** the shared `{param}` scanner action in
`sql/src/flyology-postgres-sql-native-scanner.adb` (see the SQL-8 report section
for the exact lines the verifier cites)

**Repro:** `repro_sql_8` (the `SELECT $12345678901, 1` block) — on v14 to v17 the
oracle accepts the statement and returns a valid tree; native returns
`parameter number too large at or near "$12345678901, 1"` at cursor 8. On v18 both
reject it.

**What is wrong:** The Ada scanner's parameter rule enforces the int32 range check
that PostgreSQL added in version 18, but the rule is shared across all five
generated backends. On PostgreSQL 14 through 17, `scan.l`'s `{param}` action is a
bare `atol` with no range test, so the statement is one those servers accept.
Consumers targeting v14 to v17 therefore see a rejection, with a diagnostic those
servers never produce, for input the real server accepts.

**Notes:** New finding raised by the verifier. The discovery report explicitly
cleared this area ("Parameters `$n`: overflow check matches `strtoint` ERANGE");
that clearance holds for v18 only.

---

### SQL-9: Diagnostic cursor positions are byte offsets; PostgreSQL reports character offsets

**Severity:** P1

**Location:** `sql/src/flyology-postgres-sql-native-engine.adb:33`
(`Error_Offset`); published at `sql/src/flyology-postgres-sql-native-backend.adb:22-24`
and in the generated `ast_parser_v*.adb`

**Repro:** `repro_sql_9` — `SELECT 'é', 1 1` reports cursor 16 natively against
the oracle's 15, and the scanner-level `SELECT 'é', 'x` reports 14 against 13; the
messages are byte-for-byte identical and the ASCII controls agree.

**What is wrong:** The engine stores the error position as a byte offset into the
statement and publishes `Error_Offset + 1` as `Cursor_Position`. PostgreSQL
converts the byte offset to a character number in `scanner_errposition`
(`pos = pg_mbstrlen_with_len (scanbuf, location) + 1`,
`v18/.../src_backend_parser_scan.c:10538-10549`), and grammar-level positions go
through the same function via `parser_errposition`. The pinned oracle passes that
`cursorpos` through unchanged, so the two agree only for ASCII input, and the drift
grows with every non-ASCII character before the error. Any consumer that indexes
the query text by `Cursor_Position`, to underline the offending token for instance,
points at the wrong character.

**Notes:** Systematic unit mismatch across the whole public `Cursor_Position`
surface, and it contradicts `sql/README.md:319-322`, which says the native/oracle
comparison preserves cursor positions. The verifier called it the weakest P1 in the
set, because it only affects diagnostics for input that is invalid on both sides;
a reviewer scoping P1 strictly to valid input would file it P2. Affects all five
majors and both the scanner and grammar error paths.

---

## Appendix A: coverage evidence

Each area's discovery review recorded what it examined and found correct, and what it noticed
but deliberately did not raise. These lists are summarized below.

### PROTO

Reviewed with no findings: wire primitives and their cursor and bounds behaviour;
`Wire.Decode_Initial` packet classification, including CancelRequest secret sizes 4..256 and the
`database` default; the startup, SSLRequest and CancelRequest encoders; every frontend
constructor's field order, counts and format-code shapes; NUL rejection in `Append_C_String` and
`Make_Field_Description`; every strict backend decoder, including trailing-payload checks and
unknown-tag handling; `Decode_Frontend_Copy`; signed and unsigned conversions at both boundaries;
public cursor readers; ownership and aliasing across `Message` and its relatives, with no view
escaping into freed storage; framing length validation; server encoders in `Server_Sessions`;
client consumption of BackendKeyData and the SASL mechanism list.

Observations not counted: the 16 MiB `Maximum_Message_Size` is far below PostgreSQL's ~1 GB
limit, which is a documented policy value; the client always requests 3.2 and ignores
NegotiateProtocolVersion; `Decode_Copy_Format_Description` does not enforce all-zero column codes
for text, as libpq does not either; client format-code collapsing is lenient but never wrong;
AuthenticationMD5Password raises `Unsupported_Authentication` by design.

### SERVER

Reviewed with no findings: SSLRequest and GSSENC handling and the two-negotiation-packet window;
TLS upgrade ordering and buffering, including the CVE-2021-23214 pattern and connection
ownership; startup packet parsing rules and version negotiation; cancel-key generation, encoding,
constant-time matching, routing, and operation-token lifetime under the registry lock;
authentication message-kind checks and signature wiping; startup completion ordering; the command
loop's exception, terminate and registry-full paths; framing of partial and zero-length frames;
transport timeout mapping and the TLS socket's handshake-failure close; `Serve_Internal`
lifecycle and capacity accounting; `Server_Sessions` encoder size, count and SQLSTATE checks.

The SERVER discovery report has no separate "observations not counted" section. One leniency is
recorded inline: with `TLS_Disabled`, a second SSLRequest gets a second `N` rather than a FATAL.

### SCRAM

Reviewed with no findings: base64 encoding and strict decoding, including padding and
non-canonical trailing bits; `Parse_Positive` overflow guard; `Parse_Verifier` field splitting and
size checks; `Make_Verifier_Raw` layout and key wiping; nonce generation and validation; username
escaping; GS2 header handling, including why accepting `y,,` is correct while PLUS is not
advertised; strict attribute order and duplicate rejection; client-side server-first validation;
PBKDF2 and proof math against RFC 5802 and the RFC 7677 vector, with constant-time comparison;
client-side enforcement of server-final verification and SASL message ordering; mechanism
selection; SASL wire framing; failure mapping and wiping on every exit path; identical work for
known and unknown users.

Observations not counted: SASLprep is deliberately not applied, with an interop consequence worth
documenting; `Verify_Server_Final` discards `e=` error text, which PostgreSQL never sends; the
server never advertises `SCRAM-SHA-256-PLUS`; nonce-length policy values interact so a client
nonce over 232 characters fails later; `Next_Token` accepts a trailing comma; a non-SCRAM
verifier from the application raises before `AuthenticationSASL`; `Base64_Decode` is stricter than
`pg_b64_decode`; empty passwords are processed on the client; `Admit` parses client-first three
times.

### LOGICAL

Reviewed with no findings: byte layout of all 19 encoders and decoders against `proto.c`;
signedness of typmod, timestamps and LSNs; replica identity characters and flag bit validation;
TupleData variants and bounded lengths; string termination and NUL rejection; decoder strictness
and trailing-byte rejection; version and mode gating, including the `Streaming = Parallel` gate on
abort metadata; the stateful `Decoder`'s XID insertion and segment ordering rules; encode/decode
round-trip symmetry; ownership with no access types; the Producer's atomic rollback on failure.

Observations not counted: `Relation_Id` leniently accepts `Type_Message`; oversized input to the
stateless `Decode` produces a misleading "truncated" diagnostic; the stateful `Decoder` does not
reject `B`/`C`/`b`/`P`/`K`/`r` inside a segment, which pgoutput never emits there; `Make_*`
constructors infer `Streamed` from `Xid /= 0`; `Decode` accepts binary tuple values without
knowing the negotiated option; the `Maximum_Message_Size - 29` encode ceiling and the monotonic
WAL envelope are documented policy values; `Version (Item)` returning 1 for constructed messages
is documented and is the root of LOGICAL-5.

### CLIENT

Reviewed with no findings: the simple-query state machine and its result-set, error and
pass-through handling; simple-query COPY IN, OUT and BOTH transitions, including BASE_BACKUP and
walsender timeline-switch shapes and the `On_Wait` observer; extended COPY OUT with a pipelined
Sync and the Flush-driven variants; pipeline mode through the synchronous receive, including
`Pending_Syncs` counting and `Exit_Pipeline_Mode` preconditions; extended-send preconditions and
recovery gating; the startup message loop on both synchronous and scoped paths, including SASL
phase checks and wiping; `Startup_TLS`; cancel-request encoding and socket ownership in
`Client_Sockets`; scoped operation acquisition, release, rollback and retained-exception
behaviour; `Send_Command` state gating.

Observations not counted: several documented policies, including `Resume_Portal` after Sync and
pipeline-mode COPY OUT closing the session; deliberate leniencies in `Receive_Message` and
`Send_Command`; a `Receive_Query_Event` documentation drift where `Awaiting_Ready` is unreachable;
sessions keeping their pre-transfer state after a transport failure; `Unknown_Response` rejected
inside `Receive_Copy_Event`, which no valid stream triggers; per-read timeout re-arming, excluded
because it is PROTO-1.

### REPL

Reviewed with no findings: LSN `Image`/`Value` round trips and their rejection cases; CopyData
constructor and decoder symmetry with exact-length and flag validation; timestamp signedness for
negative epochs; `Read_U64` bounds; command text generation and quoting against the replication
scanner's rules; option parse round trips, including quoted names, values and the empty list;
stream-message accessor variant guards; `Send_Identify_System` column labels and NULL handling;
`Send_Create_Logical_Slot` column order; `Timeline_File_Name` formatting; `Begin_Streaming`
CopyBothResponse shape; feedback reporter monotonicity and interval gating; the client COPY BOTH
state machine, including the timeline-switch trailing result set.

Observations not counted: the TIMELINE_HISTORY `content` column is declared text where the docs
say bytea, which is cosmetic; `Report_Timeout := 5.0` is a private body policy value; the feedback
reporter conflates "no position set" with `0/0`; `Send_Identify_System` requires nonzero systemid
and timeline, which a real primary always supplies.

### BACKUP

Reviewed with no findings: BASE_BACKUP command text for each major against the grammar and
`parse_basebackup_options`, including the legacy and parenthesised option forms; the initial
suspicion that omitting `TARGET 'client'` selects the legacy sink, which was refuted in the
sources; the v14 receiver state machine against `perform_base_backup`; the v15+ multiplexed
decoder against `basebackup_copy.c`, including frame offsets and trailing-byte rejection; numeric
decoding and NULL handling; error and cancel behaviour mid-stream; the UPLOAD_MANIFEST client path
and its server-session mirror; server-session frame encoders and the double CommandComplete;
persistence lease semantics, including stale-lease fencing and monotonic Advance; `Managed_Primary`
slot acquisition, advancement and retention ordering; `Prepared_Consumer` apply-once and
acknowledgement preconditions.

Observations not counted: `Begin_Manifest_Upload` can produce a misleading message when an
ErrorResponse leaves a ReadyForQuery unread; `Managed_Primary` ignores the physical `TIMELINE`
clause, which is a documented composition boundary; `Await_Feedback` has no overall deadline;
`Memory.Current_LSN` and `Memory.Read` copy the whole buffer, a performance matter;
`Memory.Invalidate` on an active slot matches PostgreSQL invalidation semantics; some v14 setters
are over-strict but documented; `Rollback`/`Commit` for an unknown GID raise where PostgreSQL's
apply worker skips; the `Send_Position` CommandComplete tag differs cosmetically.

### EXAMPLES

Reviewed with no findings: the pgish extended-protocol state machine, including the
discard-until-Sync behaviour that matches PostgreSQL's `ignore_till_sync`; pgish command tags,
NULL versus empty text, cancellation between rows, NULL comparison and ordering semantics, LIMIT
ordering and rejection, literal folding and alias naming; the pgish psql compatibility adapter
against psql 18's `\dt` and `\d` query shapes; pgish session identity keyed by task id; the
signal and shutdown path; `Load_Commits` argument handling and cleanup; psqlish input handling,
meta-command dispatch and `\d` splitting; psqlish display width, escaping, truncation, numeric
alignment, batching and error formatting; psqlish option parsing and defaults; psqlbench JSON
output, which delegates all escaping and number encoding to `utilada`.

Observations not counted: pgish `LIKE` rejects `_` with 0A000, which the README's "percent only"
scope covers; `Psql_Compatibility` matches raw query text before parsing, which needs contrived
input; `LIMIT ALL`, `SELECT NULL`, `SELECT true` and `SELECT 1.5` are rejected with a misleading
comparison message; unsupported-but-valid statements are reported as 42601 rather than 0A000 and
unknown portals as 26000 rather than 34000; boolean columns are sent as `true`/`false` rather than
`t`/`f`; cancellation during an extended Execute does not enter the failed state; a non-zero
Execute row limit is rejected with 0A000; a FunctionCall message leaves a client that omits Sync
without ReadyForQuery; psqlish truncation can split a multibyte sequence, which the README's
byte-oriented width covers; `\pset null` with two spaces keeps a leading space; `\x` without an
argument prints a usage error; `\d+` would fail because `pg_get_viewdef` is not answered.

---

### SQL

Reviewed with no findings: keyword case folding and ASCII-only downcasing;
identifier truncation to 63 bytes on character boundaries; quoted, `U&` and
escape-string de-escaping state machines apart from the cases above; string
continuation across newlines; dollar quoting and its push-back cases; bit and hex
strings; every numeric literal form including PG16+ underscores and non-decimal
literals and the int32 boundary; operator lexing, including the trailing `+`/`-`
rule and the two-character fallbacks resolved in all five generated tables;
nested and line comments; NUL rejection; the flex `-CF` DFA walk; the LALR engine
and lookahead token rewriting; builder list semantics; converters and the owned
parser's default elision; owned-AST ownership (clear before parse, release on
exception, `Limited_Controlled` finalization); parse-option version wiring.

Observations not counted: `YYLLOC_DEFAULT` differs between v14 to v17 and v18 and
the Ada engine applies the v18 rule everywhere, with no observable consumer found;
the generator hard-codes flex rule numbers to action kinds, a maintenance hazard;
the unused `Escape_String_Warning` option; invalid-UTF-8 input handling where
pg_query itself has no reference behaviour.

## Appendix B: review artifacts

All of the following are untracked additions to the worktree. Paths are relative to the
repository root.

Verification reports, authoritative for this document:

- `review/verification-PROTO.md`
- `review/verification-SERVER.md`
- `review/verification-SCRAM.md`
- `review/verification-LOGICAL.md`
- `review/verification-CLIENT.md`
- `review/verification-REPL.md` (REPL-5 is appended after the summary table)
- `review/verification-BACKUP.md`
- `review/verification-EXAMPLES.md`
- `review/verification-SQL.md` (SQL-8b is inside the SQL-8 section)

Discovery reports, used here only for Appendix A:

- `review/discovery-PROTO.md`
- `review/discovery-SERVER.md`
- `review/discovery-SCRAM.md`
- `review/discovery-LOGICAL.md`
- `review/discovery-CLIENT.md`
- `review/discovery-REPL.md`
- `review/discovery-BACKUP.md`
- `review/discovery-EXAMPLES.md`
- `review/discovery-SQL.md`

Reproduction harnesses:

- `tests/repros/` — core library. `run.sh`, `run-all.sh`, `README.md`, `repros.gpr`,
  `src/repro_support.ad?`, and 42 finding programs plus `repro_smoke.adb`.
- `sql/tests/repros/` — SQL parser. `run.sh`, `run-all.sh`, `sql_repros.gpr`,
  `src/sql_repro_support.ad?`, `src/flyology-postgres-sql-repro_oracle.ad?`, and 9 finding
  programs `repro_sql_1` .. `_9` plus `repro_sql_smoke.adb`.
- `examples/repros/` — pgish, psqlish and psqlbench. `run.sh`, `run-all.sh`,
  `example_repros.gpr`, `src/example_repro_support.ad?`, 10 finding programs plus
  `repro_examples_smoke.adb`.
