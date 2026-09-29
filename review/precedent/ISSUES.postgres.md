# Filed issues

Repository: https://github.com/flyology-ada/flyology-postgres. Filed from review commit 6f496f5.

| Finding | Issue | Title |
| --- | --- | --- |
| PROTO-1 | [#31](https://github.com/flyology-ada/flyology-postgres/issues/31) | Framing.Read_Message promises a single deadline but re-arms the full Timeout for each of its three reads |
| PROTO-2 | [#32](https://github.com/flyology-ada/flyology-postgres/issues/32) | Startup_Data, Process_Id and Secret_Key return record defaults instead of the documented Protocol_Error |
| PROTO-3 | [#33](https://github.com/flyology-ada/flyology-postgres/issues/33) | Decode_Initial is documented as taking the complete packet but decodes the bytes after the length field |
| PROTO-4 | [#34](https://github.com/flyology-ada/flyology-postgres/issues/34) | Startup replication values are matched case-sensitively, rejecting spellings PostgreSQL accepts |
| PROTO-5 | [#35](https://github.com/flyology-ada/flyology-postgres/issues/35) | Startup _pq_. protocol options are discarded, so a server cannot answer with NegotiateProtocolVersion |
| PROTO-6 | [#36](https://github.com/flyology-ada/flyology-postgres/issues/36) | Read_C_String reports a size-limit violation for an empty buffer instead of a missing terminator |
| PROTO-7 | [#37](https://github.com/flyology-ada/flyology-postgres/issues/37) | Maximum_Message_Size is documented as a frame bound but typed messages may be one byte larger |
| SERVER-1 | [#38](https://github.com/flyology-ada/flyology-postgres/issues/38) | Run_Session's first Read_Initial runs in the declarative part, so a bare TCP probe terminates the server |
| SERVER-2 | [#39](https://github.com/flyology-ada/flyology-postgres/issues/39) | TLS_Required rejects a plaintext CancelRequest, so psql's Ctrl-C never cancels a running query |
| SERVER-3 | [#40](https://github.com/flyology-ada/flyology-postgres/issues/40) | NegotiateProtocolVersion carries the bare minor number instead of the full protocol version word |
| SERVER-4 | [#41](https://github.com/flyology-ada/flyology-postgres/issues/41) | Read_Copy_Command rejects a Sync during COPY IN and documents results its type cannot represent |
| SERVER-6 | [#42](https://github.com/flyology-ada/flyology-postgres/issues/42) | Serve_TLS raises Program_Error where its specification documents Constraint_Error, and Serve is one-shot |
| SERVER-7 | [#43](https://github.com/flyology-ada/flyology-postgres/issues/43) | Run_Session sends raw GNAT exception text to peers, and a shutdown-cancelled session gets no diagnostic |
| SERVER-8 | [#44](https://github.com/flyology-ada/flyology-postgres/issues/44) | Read_Initial has no startup-specific length bound, so four unauthenticated bytes commit a 16 MiB buffer |
| SERVER-9 | [#45](https://github.com/flyology-ada/flyology-postgres/issues/45) | TLS_Socket_Transport.Receive_Exactly changes its exception and zero-timeout behaviour given an observer |
| SERVER-11 | [#46](https://github.com/flyology-ada/flyology-postgres/issues/46) | Request_Shutdown cancels no connection work with the default Drain_Timeout, so Serve never returns |
| SCRAM-1 | [#47](https://github.com/flyology-ada/flyology-postgres/issues/47) | SCRAM server answers every role without a verifier using one fixed salt published in the library source |
| SCRAM-2 | [#48](https://github.com/flyology-ada/flyology-postgres/issues/48) | Optional SCRAM extension attributes are rejected in client-first, client-final and server-final messages |
| SCRAM-3 | [#49](https://github.com/flyology-ada/flyology-postgres/issues/49) | Parsing refuses SCRAM iteration counts below 4096, locking out PostgreSQL roles with a lower scram_iterations |
| CLIENT-1 | [#50](https://github.com/flyology-ada/flyology-postgres/issues/50) | Scoped Receive_Extended_Event puts an open pipelined batch into Recovery_Required on an earlier batch's error |
| CLIENT-2 | [#51](https://github.com/flyology-ada/flyology-postgres/issues/51) | Extended COPY IN counts the Sync the backend discards, leaving the session one ReadyForQuery short |
| CLIENT-3 | [#52](https://github.com/flyology-ada/flyology-postgres/issues/52) | Scoped Send_Query writes a simple query while pipeline mode is active |
| CLIENT-4 | [#53](https://github.com/flyology-ada/flyology-postgres/issues/53) | A RowDescription for another statement makes the executed portal's DataRows unreadable |
| CLIENT-5 | [#54](https://github.com/flyology-ada/flyology-postgres/issues/54) | One session-wide suspended-portal flag rejects executing and resuming portals in the same batch |
| CLIENT-6 | [#55](https://github.com/flyology-ada/flyology-postgres/issues/55) | A rejected plaintext startup leaves the session in Not_Started and accepts a second startup packet |
| LOGICAL-1 | [#56](https://github.com/flyology-ada/flyology-postgres/issues/56) | Logical.Producer emits a data message without the streamed xid prefix inside an open stream segment |
| LOGICAL-2 | [#57](https://github.com/flyology-ada/flyology-postgres/issues/57) | Logical.Producer ends the top-level transaction on a subtransaction Stream Abort and bars interleaving |
| LOGICAL-3 | [#58](https://github.com/flyology-ada/flyology-postgres/issues/58) | Logical.Producer rejects a non-transactional logical decoding message outside a transaction |
| LOGICAL-4 | [#59](https://github.com/flyology-ada/flyology-postgres/issues/59) | Logical.Producer accepts a Commit whose commit LSN disagrees with the pending Begin's final LSN |
| LOGICAL-5 | [#60](https://github.com/flyology-ada/flyology-postgres/issues/60) | Abort_LSN and Event_Timestamp raise on a Stream Abort built with version-4 metadata by Make_Stream_Abort |
| REPL-1 | [#61](https://github.com/flyology-ada/flyology-postgres/issues/61) | Decode_Command rejects the valueless TWO_PHASE and FAILOVER options PostgreSQL subscribers send |
| REPL-2 | [#62](https://github.com/flyology-ada/flyology-postgres/issues/62) | Decode_Command rejects the TEMPORARY and PHYSICAL forms of CREATE_REPLICATION_SLOT that pg_basebackup sends |
| REPL-3 | [#63](https://github.com/flyology-ada/flyology-postgres/issues/63) | Read_Standby_Message raises Protocol_Error on the standby-initiated CopyDone PostgreSQL treats as normal |
| REPL-4 | [#64](https://github.com/flyology-ada/flyology-postgres/issues/64) | Replication SHOW rejects the dotted GUC names PostgreSQL's replication grammar accepts |
| REPL-5 | [#65](https://github.com/flyology-ada/flyology-postgres/issues/65) | Send_Identify_System advertises the IDENTIFY_SYSTEM timeline column as int4 for PostgreSQL 16 and newer peers |
| BACKUP-1 | [#66](https://github.com/flyology-ada/flyology-postgres/issues/66) | Memory.Promote drops the parent history, so a third timeline's history file omits every earlier ancestor |
| BACKUP-2 | [#67](https://github.com/flyology-ada/flyology-postgres/issues/67) | Memory.Oldest_Restart_LSN treats restart LSN zero as no candidate and discards WAL a live slot needs |
| BACKUP-3 | [#68](https://github.com/flyology-ada/flyology-postgres/issues/68) | Memory.Append rebases a fully retained-away store, moving Current_LSN backwards and reusing WAL positions |
| BACKUP-4 | [#69](https://github.com/flyology-ada/flyology-postgres/issues/69) | Persistence.Generation keeps returning the stale nonzero lease after a slot is released |
| BACKUP-5 | [#70](https://github.com/flyology-ada/flyology-postgres/issues/70) | Prepared_Consumer.Prepare overwrites the Target_Applied marker for the same GID, defeating the replay guard |
| BACKUP-6 | [#71](https://github.com/flyology-ada/flyology-postgres/issues/71) | Memory.Create accepts an active leased snapshot as initial state, creating a slot nobody can acquire or drop |
| BACKUP-7 | [#72](https://github.com/flyology-ada/flyology-postgres/issues/72) | Base backup Send_Position declares the tli column as int4 where PostgreSQL 14 through 18 declare int8 |
| SQL-1 | [#73](https://github.com/flyology-ada/flyology-postgres/issues/73) | E'\v' unescapes to the letter v instead of vertical tab on PostgreSQL 17 and 18 |
| SQL-2 | [#74](https://github.com/flyology-ada/flyology-postgres/issues/74) | Octal escapes E'\400' through E'\777' fail the parse with a GNAT range-check message |
| SQL-3 | [#75](https://github.com/flyology-ada/flyology-postgres/issues/75) | \U escapes at or above 0x80000000 overflow Natural and report a GNAT overflow message |
| SQL-4 | [#76](https://github.com/flyology-ada/flyology-postgres/issues/76) | Escape strings whose octal or hex escapes form invalid UTF-8 are accepted instead of rejected |
| SQL-5 | [#77](https://github.com/flyology-ada/flyology-postgres/issues/77) | UESCAPE accepts form feed on every major and vertical tab on PostgreSQL 17 and 18 |
| SQL-6 | [#78](https://github.com/flyology-ada/flyology-postgres/issues/78) | On PostgreSQL 14, SELECT -'abc' folds the sign into the constant instead of building an A_Expr |
| SQL-7 | [#79](https://github.com/flyology-ada/flyology-postgres/issues/79) | Grammar-level ereport diagnostics keep the raw %s format and report the wrong cursor |
| SQL-8 | [#80](https://github.com/flyology-ada/flyology-postgres/issues/80) | Scanner diagnostics quote the rest of the statement instead of the offending token |
| SQL-8b | [#81](https://github.com/flyology-ada/flyology-postgres/issues/81) | PostgreSQL 18's parameter-number range check is applied to PostgreSQL 14 through 17 |
| SQL-9 | [#82](https://github.com/flyology-ada/flyology-postgres/issues/82) | Diagnostic cursor positions are byte offsets where PostgreSQL reports character offsets |
| EXAMPLES-1 | [#83](https://github.com/flyology-ada/flyology-postgres/issues/83) | pgish answers LIKE '%' with an internal XX000 error carrying a GNAT runtime source location |
| EXAMPLES-2 | [#84](https://github.com/flyology-ada/flyology-postgres/issues/84) | pgish evaluates NOT LIKE as LIKE and returns the inverse row set with no diagnostic |
| EXAMPLES-3 | [#85](https://github.com/flyology-ada/flyology-postgres/issues/85) | pgish ORDER BY compares integer columns as text while WHERE compares them numerically |
| EXAMPLES-4 | [#86](https://github.com/flyology-ada/flyology-postgres/issues/86) | psqlish raises Constraint_Error on a zero-column result and abandons the connection |
| EXAMPLES-5 | [#87](https://github.com/flyology-ada/flyology-postgres/issues/87) | pgish information_schema.columns exceeds the 32-row bound unless a table_name equality filter is supplied |
| EXAMPLES-6 | [#88](https://github.com/flyology-ada/flyology-postgres/issues/88) | pgish case-folds double-quoted identifiers and accepts any table or schema qualifier |
| EXAMPLES-7 | [#89](https://github.com/flyology-ada/flyology-postgres/issues/89) | pgish keeps a session slot after an abrupt disconnect, then refuses live clients with FATAL 28P01 |
| EXAMPLES-8 | [#90](https://github.com/flyology-ada/flyology-postgres/issues/90) | flyology_pgish option and environment errors escape the main handler and print a GNAT traceback |
| EXAMPLES-9 | [#91](https://github.com/flyology-ada/flyology-postgres/issues/91) | psqlish expanded output pads each field name to its column's data width instead of the widest name |
| EXAMPLES-10 | [#92](https://github.com/flyology-ada/flyology-postgres/issues/92) | pgish answers a semicolon, comment or whitespace-only query with 42601 instead of EmptyQueryResponse |
| EXAMPLES-11 | [#93](https://github.com/flyology-ada/flyology-postgres/issues/93) | pgish returns a zero-column row for SELECT * with no FROM clause instead of rejecting it |
