## SSE

Server-sent events on both sides: the client `flyology-http-client-sse.adb/.ads`, the
reconnect policy `flyology-http-sse_client_policy.adb/.ads`, the server handlers
`flyology-http-server-sse_handlers.adb/.ads`, and the three server serialisers,
`Begin_SSE` through `End_SSE` in `flyology-http-server.adb`,
`flyology-http-server-http_2.adb` and `flyology-http-server-http_3.adb`, together with the
client engine sites in `flyology-http-client.adb` that carry a streaming body into the SSE
sink. The formal artifacts under `formal/sse_client/` were read but not executed. Three
findings, all P1, all CONFIRMED, all reproduced; no severity moved and nothing was refuted.
All three spikes reached every backend or path they needed in process, so nothing in this
area is unverifiable by spike. Two caveats set the evidentiary frame for the whole area and
are recorded under Coverage evidence: the TLA+ gate could not be run here, and
`Flyology.HTTP.SSE_Client_Policy` is **not** a SPARK-proved unit, contrary to what was
assumed when the area was scoped.

### SSE-1: HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator that the HTTP/1.1 serialiser preserves

- **Severity:** P1 (discovery said P1; unchanged). A wrong result on valid input through a
  reachable public path: the same `Send_SSE` call delivers different event data depending on
  the negotiated protocol. Not P0, because the HTTP framing is well formed on every backend,
  a stock SSE client parses both bodies without complaint, and the loss is confined to one
  character of application data at the SSE field layer.
- **Location:** `src/flyology-http-server.adb:3346-3355` (the branch that exists) versus
  `src/flyology-http-server-http_2.adb:1986-1993` and
  `src/flyology-http-server-http_3.adb:1322-1329` (the two copies that lack it); reached from
  `Applications.Send_SSE` and `SSE_Handlers.Run`.
- **Repro:** `./tests/repros/run.sh repro_sse_1 150` (exit 1, BUG REPRODUCED; re-run for the
  drafting pass, 9 checks, 4 failures).
- **What is wrong:** One serialisation exists three times, once per backend, and the three
  copies disagree. The HTTP/1.1 data loop ends with a branch that appends an extra empty
  `data:` line when the terminator it just consumed was the final character of `Data`; the
  other two are character-for-character the same loop and stop after the CRLF skip. Because
  the WHATWG dispatch algorithm strips exactly one trailing LF, that extra field is the only
  way a trailing terminator can be conveyed. The verifier reached **all three backends in one
  spike**: HTTP/1.1 writes `data: a\ndata:\n\n` and the shipped client dispatches `"a\n"`;
  HTTP/2 and HTTP/3 write `data: a\n\n` and dispatch `"a"`. `Data => LF` alone is
  indistinguishable from `Data => ""` on two of the three.
- **Notes:** The issue body quotes both halves of the WHATWG mechanism, the data-field rule
  ("append the field value to the data buffer, then append a single U+000A LINE FEED (LF)
  character") and the dispatch rule ("if the data buffer's last character is a U+000A LINE
  FEED (LF) character, then remove the last character"), because the finding depends on the
  pair. The body does **not** mention the earlier audit and presents the defect simply as
  three implementations of one serialisation that disagree; the fact that this is the
  continuation of that audit's unification, with HTTP/3 now a third copy, is recorded here and
  not in the issue. No maintainer decision needed: either the missing branch is added to both
  copies or the three loops are replaced by one shared serialiser, and neither adds a value.
  No existing test asserts the wrong behaviour; no maintained test sends `Data` ending in a
  terminator on any backend, which is why `./scripts/test.sh` is green
  (`tests/http_smoke.adb:827-834` uses an embedded LF and CR,
  `tests/http2_server_audit.adb:71-87` covers injection and UTF-8 rejection only, and the
  HTTP/2 and HTTP/3 SSE integration tests drive raw `Begin_Stream` and `Write_Chunk`).
  `Send_SSE_Comment` has the same three-way duplication but no trailing-terminator branch on
  **any** backend including HTTP/1.1 (`server.adb:3395-3430`), so comments are consistent and
  are not a second instance. Outside every proved unit.

### SSE-2: Event_Too_Large and Reconnect_Delay_Too_Large raised while the body streams surface as Invalid_Event_Stream

- **Severity:** P1 (discovery said P1; unchanged). A documented `.ads` contract is violated on
  the common path.
- **Location:** `src/flyology-http-client.adb:3884-3891` (`Deliver`), consumed at
  `src/flyology-http-client-sse.adb:724-741` (`Handle_Exchange_Failure`) from `:819-825`;
  contract at `src/flyology-http-client-sse.ads:85-86`; the raises at
  `src/flyology-http-client-sse.adb:179-187` and `:307-334`.
- **Repro:** `./tests/repros/run.sh repro_sse_2 150` (exit 1, BUG REPRODUCED; re-run,
  4 checks, 2 failures).
- **What is wrong:** While the response body streams, the parser runs inside `Event_Sink.Write`
  and the engine converts any sink exception into the result kind `Response_Sink_Failed`
  without re-raising it. `Finish_Response_Body` then sees a non-complete result and
  `Handle_Exchange_Failure` falls into its `when others` arm, raising `Invalid_Event_Stream`.
  The identity the caller actually observes is
  `FLYOLOGY.HTTP.CLIENT.SSE.INVALID_EVENT_STREAM` with the message "SSE HTTP exchange failed
  during RECEIVING_RESPONSE_BODY"; the spike compares `Ada.Exceptions.Exception_Identity`
  against `SSE.Reconnect_Delay_Too_Large'Identity` and `SSE.Event_Too_Large'Identity`, so this
  is an identity check and not a message match. A caller cannot distinguish a breach of its
  own `Maximum_Event_Bytes` or `Maximum_Reconnect_Delay` from a malformed server response.
- **Notes:** **The verifier corrected the mechanism the discovery described.**
  `Remember_Failure` (`src/flyology-http-client.adb:675-692`) **does** preserve the identity in
  `State.Failure_Cause`; that field is simply never consulted on this path. It is read in
  exactly one place, the synchronous `Execute` wrapper at
  `src/flyology-http-client.adb:6550-6566`, and only for a result-kind and identity allowlist
  that excludes `Response_Sink_Failed`, and the SSE layer does not use that wrapper at all: it
  drives the composable exchange, whose `Finish` (`:1718-1742`) re-raises only when
  `Has_Saved_Error`, which no sink path sets. So the identity is available to a fix, which
  makes the fix cheap, and the issue body says so. The narrowing that sets the severity is
  also confirmed: with the offending field following a complete event **in the same written
  slice**, the remaining bytes stay in `Event_Source.Pending`, the next `Read` parses them in
  `Process_Buffered` (`:841-861`) outside the sink, and **both documented exceptions reach the
  caller intact**. The behaviour is therefore inconsistent rather than uniformly broken, and
  the failing case is the first violation in a stream, which is the common one. The modelled
  lifecycle is unaffected: `Drive`'s handler reaches `Connection_Fatal_Failure`, which is what
  `ASSURANCE.md:39` maps "caller limit" to, so only the exception identity is wrong. The two
  fix placements are presented without choosing, because the engine-side one changes what
  every composable sink caller observes for `Response_Sink_Failed`. No existing test asserts
  the wrong behaviour; there is no coverage at all
  (`tests/http1_sse_client_integration.adb:153-158` sends `retry: 0001` well within bounds).

### SSE-3: A cancellation token does not interrupt the reconnect wait of the blocking SSE Read

- **Severity:** P1 (discovery said P1; unchanged). A documented `.ads` contract is violated.
  Not P0: the delay is bounded by the caller's own `Maximum_Reconnect_Delay`, so this is a
  large unwanted latency rather than a hang.
- **Location:** `src/flyology-http-client-sse.adb:648-661` (`Begin_Reconnect`), `:890-896`
  (the `Waiting_Reconnect` arm), `:524-539` (the blocking `Read`), `:58-67`
  (`Check_Control`), `:934-961` (`Request_Cancellation`, the path a caller cannot reach);
  contract at `src/flyology-http-client-sse.ads:74-77`.
- **Repro:** `./tests/repros/run.sh repro_sse_3 90` (exit 1, BUG REPRODUCED; re-run,
  5 checks, 1 failure).
- **What is wrong:** `Begin_Reconnect` clamps the interval to the absolute deadline, so the
  **deadline half of the contract is honoured**, but arms `Flyology.IO.Timers.Sleep_For` with
  no token, and the `Waiting_Reconnect` arm calls `Check_Control` only *after*
  `Flyology.IO.Timers.Finish`. The exception identity is therefore right and **only the timing
  is wrong**. The one path that cancels the timer early is `Request_Cancellation`, reached
  through `Flyology.Operations.Cancel` on the `Read_Operation`, which the blocking overload
  constructs internally and never exposes, so a caller using the documented `Token` parameter
  cannot reach it.
- **Notes:** Measured, on the drafting re-run: **3.002937458 s** for a cancellation requested
  **0.200 s** into a **3.000 s** wait, that is about **2.80 s after `Token.Request`**, with no
  observable shortening; the verification run measured 3.0025 s for the same setup. The spike
  uses `retry: 3000` and `Maximum_Reconnect_Delay => 10.0` so it needs no long timeout; a
  server-chosen `retry` anywhere up to the caller's ceiling scales the same way. No maintainer
  decision needed: both fix shapes reuse existing mechanisms and add no public value. No
  existing test asserts the wrong behaviour; all three maintained SSE integration tests pass
  `Token => null` and use a one millisecond retry.

### Coverage evidence

Read in full: `flyology-http-client-sse.adb/.ads`, `flyology-http-sse_client_policy.adb/.ads`,
`flyology-http-server-sse_handlers.adb/.ads`, and the `formal/sse_client/` tree
(`ASSURANCE.md`, the TLA+ model and configuration, the recorded trace, the trace adapter and
the generated Ada). Read in range: `Begin_SSE` through `End_SSE` in
`flyology-http-server.adb`, `flyology-http-server-http_2.adb` and
`flyology-http-server-http_3.adb`, the HTTP/2 stream table, pump and `Queue_Data`, the HTTP/3
`Send_Data` and `Write_Response_Chunk`, and the `Remember_Failure`, `Finish`,
`Resume_Response_To_Sink` and `Deliver` sites in `flyology-http-client.adb`. Tests read:
`tests/http1_sse_client_integration.adb`, the SSE sections of
`tests/http2_server_integration.adb`, `tests/http3_server_integration.adb`,
`tests/http2_server_audit.adb` and `tests/http_smoke.adb`.

Executed: all three spikes, twice, once during verification and once during drafting; every
run exits 1 with BUG REPRODUCED and the same check and failure counts, with SSE-3's timing
reproducing at 3.0025 s and 3.0029 s. `repro_sse_1` reaches all three backends in process:
HTTP/1.1 and HTTP/2 over plain TCP loopback with `HTTP_1_Only` and `HTTP_2_Only` plus
`Client.HTTP_2_Prior_Knowledge`, and HTTP/3 over UDP loopback with `Routes.Serve_HTTP_3` and
`Flyology.QUIC.Test_Connections.Server_Certificate`, the setup
`tests/http3_handshake_recovery.adb:101-108` uses, so no OpenSSL provider or PEM fixture is
needed.

**`./scripts/check-sse-client-formal.sh` could not be run in this environment.** There is no
Java runtime (`/usr/bin/java` is the macOS stub) and no `flyology-tla` executable, and none of
`FLYOLOGY_TLA_JAVA`, `FLYOLOGY_TLA_TLC_JAR`, `FLYOLOGY_TLAPM` or `FLYOLOGY_TLA_CLI` is set.
The TLA+ model, the TLAPS proof, the generated-Ada regeneration and the trace replay are
therefore **unexercised evidence here**, whatever the code inspection concludes. The gate is
wired into CI at `.github/workflows/ci.yml:180-190`; whether it is green at `f078732` was not
checked. This caveat belongs to the area and is deliberately absent from all three issue
bodies.

**`Flyology.HTTP.SSE_Client_Policy` is NOT a SPARK-proved unit**, contrary to what was assumed
when the area was scoped. Verified directly: neither `flyology-http-sse_client_policy.ads` nor
its body carries `SPARK_Mode`, the unit is absent from the `-u` list in `scripts/prove.sh`,
and `proof/proof-status.md` never mentions it (it uses `Ada.Strings.Unbounded`, which
GNATprove does not support). Every site examined in this area therefore lies outside any
proved boundary, and the unit's only formal evidence is the TLA+ trace replay, which was not
run here. Ordinary tests are the only executed evidence that covered this code before this
review.

The TLA+ gate was still spot-checked by reading and does sit on the production path: the trace
adapter is a 1:1 wrapper whose every operation is a single call into
`Flyology.HTTP.SSE_Client_Policy`; the conformance main renames the adapter as `Policy` and
its project pins `flyology_http` at this repository's path, so it compiles against `src/`; the
production client still issues every modelled transition from `Drive`; and the difference
between the recorded `source_sha256` and the raw hash of `SSEClientTrace.tla` is normalisation
rather than drift, which the two commits that ever touched the file demonstrate. One scope
caveat: the committed trace exercises eight actions over twelve steps, and the adapter does
not expose `ConnectionRecoverableFailure`, `ConnectionFatalFailure` or `Stop` at all, so the
Ada-to-model conformance evidence is narrower than the model-checking evidence and narrower
than the transitions production `Drive` issues. `ASSURANCE.md:79-84` states that TLAPS "does not prove byte
parsing or transport code" and that replay "establishes conformance only for the retained
traces", leaving the byte-level field grammar to ordinary tests; the model's subject is the
reconnect lifecycle, so the exchange and timer children, redirect handling and the deadline
clamp in `Begin_Reconnect` are outside it. SSE-2 and SSE-3 both live in that uncovered layer
and SSE-1 is outside the model's subject entirely.

Pinned peers do not bear on this area: h2spec 2.6.0 tests HTTP/2 framing and header
conformance rather than SSE payload semantics, Autobahn is WebSocket, and the HTTP/3 interop
runs against aioquic 1.3.0 and quic-go 0.54.1 are request and response exchanges.

### Refuted and not counted

Checked and found sound, with no finding raised: BOM handling (exactly one leading EF BB BF
per accepted connection, with a short prefix deferred and replayed); line terminators (CR, LF
and CRLF, with a CRLF split across two `Write` slices treated as one terminator and CR CR as
two lines); the field grammar (no colon, colon at position 0, one optional space, unknown
names ignored, case-sensitive names, per-line UTF-8 with U+FFFD replacement and
maximal-subpart resynchronisation); dispatch (data accumulation with LF, the trailing strip,
empty data not dispatching, the event type reset, the `message` default, the id buffer
committed before the empty-data check, NUL in `id` ignored); reconnect state (204 terminal,
any other non-200 or wrong media type fatal, `Last-Event-ID` sent only when nonempty, the
deadline clamp and re-check, composable cancellation during the wait); redirects (same-origin
within the attempt, hop limit, loop detection, reconnect from the original template); server
validation across backends (CR/LF rejection in `Event` and `Id`, UTF-8 validation, NUL
rejection, newline splitting into repeated fields, all identical on the three backends apart
from SSE-1); HTTP/2 backpressure, which was the earlier audit's explicit gap and is handled by
`Queue_Data` chunking at 16384 into the per-stream ring with `Wait_For_Stream` and pump
notification, and where `Await_Drained` simply does not exist in the HTTP/2 server; HTTP/3
SSE through `Write_Response_Chunk` and `Send_Data`; and `SSE_Handlers` byte budgets, token and
deadline checks per quantum, and `Finalize`. The verification's own findings sweep beyond the
three entries raised no new findings.

Recorded but outside the rubric: the last-event-ID buffer is cleared per accepted connection,
which is the literal reading of the standard and is stated deliberately in `ASSURANCE.md`,
though whether shipping browsers keep the previous id across streams was not checked;
`Process_Buffered` handles one octet per drive and reschedules, which is a performance note
only; `Pending` is bounded by the engine's slice size rather than by `Maximum_Event_Bytes`,
which the `.ads` bound does not cover and which is not a defect; every comment, including the
`SSE_Handlers` heartbeat, is followed by an extra LF, which is a harmless dispatch boundary
with an empty data buffer; the API distinguishes 204 from other non-200 statuses where current
WHATWG treats both as terminal, which is API shape rather than a protocol deviation;
`Response_Invalid` is treated as recoverable, consistent with fetch reporting a network error;
an HTTP/2 peer that stops sending WINDOW_UPDATE pins the SSE handler until the route deadline,
which is the documented control; `Frames.Default_Maximum_Frame_Size` and
`Stream_Buffer_Capacity` are coupled at 16384 with no static check tying them; and a header
template already at capacity with neither `Accept` nor `Last-Event-ID` present would raise
`Headers_Too_Large` inside `Drive` rather than at `Open`.
