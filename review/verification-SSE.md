# Verification: SSE

Commit: f078732
Findings examined: 3. Confirmed: 3. Refuted: 0. Partial: 0. Other: 0.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| SSE-1 | P1 | CONFIRMED | P1 | `repro_sse_1` |
| SSE-2 | P1 | CONFIRMED | P1 | `repro_sse_2` |
| SSE-3 | P1 | CONFIRMED | P1 | `repro_sse_3` |

All three spikes reached every backend or path they needed in process. No
finding in this area is UNVERIFIABLE-BY-SPIKE.

## Evidence caveats that apply to the whole area

- **`./scripts/check-sse-client-formal.sh` could NOT be run.** This machine has
  no Java runtime (`/usr/bin/java` is the macOS stub: `Unable to locate a Java
  Runtime`) and no `flyology-tla` executable, and none of `FLYOLOGY_TLA_JAVA`,
  `FLYOLOGY_TLA_TLC_JAR`, `FLYOLOGY_TLAPM` or `FLYOLOGY_TLA_CLI` is set. The
  TLA+ model, TLAPS proof, generated-Ada regeneration and trace replay are
  therefore **unexercised in this review**, whatever the code inspection below
  concludes. The gate is wired into CI at
  `.github/workflows/ci.yml:180-190`; whether it is green at `f078732` was not
  checked here.
- **`Flyology.HTTP.SSE_Client_Policy` is NOT a SPARK-proved unit.** Verified
  directly: `grep -n SPARK_Mode src/flyology-http-sse_client_policy.ads
  src/flyology-http-sse_client_policy.adb` returns nothing; the unit is absent
  from the `-u` list in `scripts/prove.sh:20-42`; and `proof/proof-status.md`
  contains no mention of it (`grep -in sse` matches only unrelated lines about
  the SSE *chunk-encoding* consumer at `:373`). The original area brief was
  wrong on this point and the discovery reviewer's correction stands. **This
  changes what evidence exists for the area:** every site examined here lies
  outside any proved boundary, and the unit's only formal evidence is the TLA+
  trace replay, which was not run here. Ordinary tests (`./scripts/test.sh`,
  PASS per `review/baselines/SUMMARY.txt`) are the only executed evidence that
  covered this code before this review.

## SSE-1: HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator that the HTTP/1.1 one preserves

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged). It is a wrong result on
  valid input through a reachable public path: the same `Send_SSE` call
  delivers different event data depending on the negotiated protocol. It is
  not P0 — the HTTP framing on every backend is well formed, a stock SSE
  client parses both bodies without complaint, and nothing is corrupted at the
  transport level. The loss is confined to one character of application data
  at the SSE field layer.
- **Repro:** `tests/repros/src/repro_sse_1.adb`, run with
  `./tests/repros/run.sh repro_sse_1 120`
- **Backends reached:** all three, in process. HTTP/1.1 and HTTP/2 over plain
  TCP loopback (`Routing.Serve` with `HTTP_1_Only` / `HTTP_2_Only`, client
  default and `Client.HTTP_2_Prior_Knowledge`); HTTP/3 over UDP loopback with
  `Routes.Serve_HTTP_3` and `Flyology.QUIC.Test_Connections.Server_Certificate`,
  the setup `tests/http3_handshake_recovery.adb:101-108` uses, so no OpenSSL
  provider or PEM fixture is needed.
- **Output:**

```
  note application sends Data => "a" & LF on one route, three backends
  note expected wire: data: a\x0adata:\x0a\x0a
  note expected dispatched data: a\x0a
  note HTTP/1.1 wire bytes: data: a\x0adata:\x0a\x0a
  ok   HTTP/1.1 serialised SSE body
  ok   HTTP/1.1 dispatched an event
  note HTTP/1.1 dispatched data: a\x0a
  ok   HTTP/1.1 dispatched event data
  note HTTP/2 wire bytes: data: a\x0a\x0a
  FAIL HTTP/2 serialised SSE body
         expected: [data: a\x0adata:\x0a\x0a]
         actual:   [data: a\x0a\x0a]
  ok   HTTP/2 dispatched an event
  note HTTP/2 dispatched data: a
  FAIL HTTP/2 dispatched event data
         expected: [a\x0a]
         actual:   [a]
  note HTTP/3 wire bytes: data: a\x0a\x0a
  FAIL HTTP/3 serialised SSE body
         expected: [data: a\x0adata:\x0a\x0a]
         actual:   [data: a\x0a\x0a]
  ok   HTTP/3 dispatched an event
  note HTTP/3 dispatched data: a
  FAIL HTTP/3 dispatched event data
         expected: [a\x0a]
         actual:   [a]
checks: 9  failures: 4
BUG REPRODUCED
ERROR: ... exited with code 1
```

- **Description:** One route registered with `Upgrade => Routing.Allow_SSE`
  calls `X.Send_SSE (Data => "a" & LF)`. The HTTP/1.1 writer's data loop ends
  with a branch (`src/flyology-http-server.adb:3352-3354`) that appends one
  more empty `data:` line when the terminator it just consumed was the final
  character of `Data`. The HTTP/2 copy
  (`src/flyology-http-server-http_2.adb:1985-1992`) and the HTTP/3 copy
  (`src/flyology-http-server-http_3.adb:1321-1328`) are otherwise
  character-for-character the same loop and stop after the CRLF skip, so
  neither emits that line. The spike reads the serialised body twice per
  backend: once as an ordinary GET, and once through
  `Flyology.HTTP.Client.SSE`, which is the WHATWG parser the library ships.
  HTTP/1.1 puts `data: a` LF `data:` LF LF on the wire and dispatches
  `"a\n"`; HTTP/2 and HTTP/3 put `data: a` LF LF on the wire and dispatch
  `"a"`. The round-trip mechanism is the WHATWG HTML "Server-sent events"
  section, "Interpreting an event stream". For a `data` field it says
  **"Append the field value to the data buffer, then append a single U+000A
  LINE FEED (LF) character to the data buffer."** and the dispatch algorithm
  says **"If the data buffer's last character is a U+000A LINE FEED (LF)
  character, then remove the last character from the data buffer."** A
  trailing LF in the application's value can therefore only be conveyed by an
  extra empty `data` field, because the LF the last real field contributes is
  the one that is stripped. A caller passing `Data => LF` alone is
  indistinguishable from `Data => ""` on HTTP/2 and HTTP/3.
- **Why the green suites did not catch it:** the baselines in
  `review/baselines/SUMMARY.txt` do not exercise this input. h2spec 2.6.0
  (`13-http2-h2spec-docker.log`, 146/146) tests HTTP/2 framing and header
  conformance, not SSE payload semantics; Autobahn (`20-` through `23-`) is
  WebSocket; the HTTP/3 interop runs against aioquic and quic-go
  (`10-http3-interop.log`) are request/response. Inside the repository,
  `grep -rn "Send_SSE\|Send_Event" tests showcases` shows that the only
  maintained callers are `tests/http_smoke.adb:827-832` (HTTP/1.1, embedded LF
  and embedded CR, never trailing) and `tests/http2_server_audit.adb:76-84`
  (injection and UTF-8 rejection only). The HTTP/2 and HTTP/3 SSE integration
  tests drive raw `Begin_Stream`/`Write_Chunk`, not `Send_SSE`. No maintained
  test sends `Data` ending in a terminator on any backend, which is why
  `./scripts/test.sh` is green. This is the direct continuation of the prior
  audit's finding 4, which unified the *validation* across serialisers and
  named unifying the serialisers themselves as the follow-up; HTTP/3 has since
  become a third copy with the same omission.

## SSE-2: `Event_Too_Large` and `Reconnect_Delay_Too_Large` surface as `Invalid_Event_Stream`

- **Verdict:** CONFIRMED, including the discovery reviewer's narrowing.
- **Severity:** P1 (discovery said P1; unchanged). A documented `.ads`
  contract is violated on the common path.
- **Repro:** `tests/repros/src/repro_sse_2.adb`, run with
  `./tests/repros/run.sh repro_sse_2 120`
- **Output:**

```
  note contract: client-sse.ads:85-86 documents Event_Too_Large and
  note Reconnect_Delay_Too_Large as Read exceptions
  note retry over caller maximum (first event) observed FLYOLOGY.HTTP.CLIENT.SSE.INVALID_EVENT_STREAM: SSE HTTP exchange failed during RECEIVING_RESPONSE_BODY
  FAIL retry over caller maximum (first event) raises Reconnect_Delay_Too_Large
  note event over caller byte bound (first event) observed FLYOLOGY.HTTP.CLIENT.SSE.INVALID_EVENT_STREAM: SSE HTTP exchange failed during RECEIVING_RESPONSE_BODY
  FAIL event over caller byte bound (first event) raises Event_Too_Large
  note retry over caller maximum (bytes left in Pending) warm-up read 1 returned EVENT_AVAILABLE data [x]
  note retry over caller maximum (bytes left in Pending) observed FLYOLOGY.HTTP.CLIENT.SSE.RECONNECT_DELAY_TOO_LARGE: SSE retry field exceeds caller maximum
  ok   retry over caller maximum (bytes left in Pending) raises Reconnect_Delay_Too_Large
  note event over caller byte bound (bytes left in Pending) warm-up read 1 returned EVENT_AVAILABLE data [x]
  note event over caller byte bound (bytes left in Pending) observed FLYOLOGY.HTTP.CLIENT.SSE.EVENT_TOO_LARGE: SSE retained event bytes exceed caller bound
  ok   event over caller byte bound (bytes left in Pending) raises Event_Too_Large
checks: 4  failures: 2
BUG REPRODUCED
ERROR: ... exited with code 1
```

- **Exception identity the caller actually observes:** the first two cases
  print `FLYOLOGY.HTTP.CLIENT.SSE.INVALID_EVENT_STREAM` with the message
  `SSE HTTP exchange failed during RECEIVING_RESPONSE_BODY`. The spike compares
  `Ada.Exceptions.Exception_Identity` against
  `SSE.Reconnect_Delay_Too_Large'Identity` and `SSE.Event_Too_Large'Identity`,
  so this is an identity check, not a message match.
- **The narrowing is confirmed:** cases 3 and 4 send `data: x` LF LF followed
  by the offending field in a single write, so the first `Read` dispatches the
  event and the remaining bytes stay in `Event_Source.Pending`. The second
  `Read` starts in phase `Processing_Buffered`
  (`src/flyology-http-client-sse.adb:569`) and parses those bytes through
  `Process_Buffered` (`:840-861`), outside the sink. There the raise
  propagates to `Drive`'s `when Error : others` handler (`:924-931`), is saved,
  and `Finish` (`:988-996`) re-raises it with its identity intact. Both
  documented exceptions reach the caller in that case. **That narrowing is what
  sets the severity**: the behaviour is inconsistent rather than uniformly
  broken, and the failing case is the first violation in a stream, which is the
  common one.
- **Description:** `Flyology.HTTP.Client.SSE.Read` documents
  `@exception Event_Too_Large` and `@exception Reconnect_Delay_Too_Large` at
  `src/flyology-http-client-sse.ads:85-86`. Both are raised by the parser:
  `Require_Capacity` (`client-sse.adb:179-187`, reached from `Append_Bounded`
  at `:216` and so from `Process_Octet` at `:441`) and `Parse_Retry`
  (`:307-334`). While the response body is being streamed, those calls run
  inside `Event_Sink.Write` (`:488-518`), which the client engine invokes from
  `Deliver` (`src/flyology-http-client.adb:3882-3891`):

  ```ada
  if State.Target = Sink_Target then
     begin
        Write (State.Sink_Item.all, Data);
     exception
        when Error : others =>
           Remember_Failure (State, Error);
           State.Pending_Result := Response_Sink_Failed;
     end;
  ```

  `Remember_Failure` (`:675-690`) does record the identity in
  `State.Failure_Cause`, but that field is consulted in exactly one place —
  the *synchronous* `Execute` wrapper at `src/flyology-http-client.adb:6550-6566`
  — and only for `Result_Kind in Connection_Failed | Transport_Failed |
  Response_Invalid | Request_Source_Failed` with a fixed identity allowlist.
  `Response_Sink_Failed` is not in that set, and the SSE layer does not use
  that wrapper at all: it drives the composable `Exchange_Operation`, whose
  `Finish` (`:1718-1742`) re-raises only when `Has_Saved_Error`, which no sink
  path sets. `Finish_Response_Body` (`client-sse.adb:819-825`) therefore sees a
  non-complete result and `Handle_Exchange_Failure` (`:724-741`) falls into its
  `when others` arm and raises `Invalid_Event_Stream`. The caller cannot
  distinguish a breach of its own configured `Maximum_Event_Bytes` or
  `Maximum_Reconnect_Delay` from a malformed server response. The modelled
  lifecycle state is unaffected — `ASSURANCE.md:39` maps "caller limit" to
  `ConnectionFatalFailure`, which `Drive`'s handler does reach (`:925-929`) —
  so only the exception identity is wrong.
- **Existing coverage:** none, as the discovery reported.
  `tests/http1_sse_client_integration.adb:153-161` sends `retry: 0001` well
  within bounds; the HTTP/2 and HTTP/3 integration tests use `retry: 1`.

## SSE-3: a cancellation token does not interrupt the reconnect wait of the blocking `Read`

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P1; unchanged). A documented `.ads`
  contract is violated. Not P0: the delay is bounded by the caller's own
  `Maximum_Reconnect_Delay`, so this is a large unwanted latency rather than a
  hang.
- **Repro:** `tests/repros/src/repro_sse_3.adb`, run with
  `./tests/repros/run.sh repro_sse_3 90`
- **Output:**

```
  note contract: client-sse.ads:74-77 says cancellation interrupts
  note reconnect waits using its ordinary exception
  ok   first read returned an event
  ok   first event data
  ok   server retry adopted as the reconnect delay
  note cancellation requested 0.200000000 s into a 3.000000000 s reconnect wait
  note second Read outcome: FLYOLOGY.CANCELLATION.OPERATION_CANCELLED
  note second Read took 3.002506459 s
  ok   cancelled reconnect wait raises Operation_Cancelled
  FAIL cancelled Read returns within 1.000000000 s (took 3.002506459 s)
checks: 5  failures: 1
BUG REPRODUCED
ERROR: ... exited with code 1
```

- **Measured delay:** **3.0025 s** for a cancellation requested 0.200 s into a
  3.000 s wait, i.e. the call returned only when the timer fired — about
  **2.80 s after `Token.Request`**, with no observable shortening. The spike
  uses a short `retry: 3000` and `Maximum_Reconnect_Delay => 10.0` so it needs
  no long timeout; the discovery's `retry: 300000` scenario scales the same way
  up to the caller's ceiling.
- **Description:** `Read` promises at `src/flyology-http-client-sse.ads:74-77`
  that "Cancellation and the absolute deadline interrupt requests, reads, and
  **reconnect waits** using their ordinary exceptions." `Begin_Reconnect`
  (`src/flyology-http-client-sse.adb:648-661`) clamps the interval to the
  absolute deadline — so the *deadline* half of the sentence holds — but arms
  `Flyology.IO.Timers.Sleep_For` with no token, and the `Waiting_Reconnect` arm
  of `Drive` (`:890-896`) calls `Check_Control` only *after*
  `Flyology.IO.Timers.Finish`. `Check_Control` (`:58-67`) is what raises
  `Operation_Cancelled`, which is why the exception identity is right and only
  the timing is wrong. The one path that cancels the timer early is
  `Request_Cancellation` (`:934-961`), reached through
  `Flyology.Operations.Cancel` on the `Read_Operation`; the blocking `Read`
  overload (`:524-539`) constructs that operation internally and never exposes
  it, so a caller using the documented `Token` parameter has no way to reach
  it. In the spike the peer sends `retry: 3000` LF `data: a` LF LF and closes;
  the first `Read` returns the event and adopts a 3 s delay, the second `Read`
  enters the wait, a second task requests the token 0.2 s later, and the call
  still blocks for the full interval. A server-chosen `retry` anywhere up to
  the caller's `Maximum_Reconnect_Delay` pins the calling task despite
  cancellation.
- **Existing coverage:** none. All three maintained SSE integration tests pass
  `Token => null` and use a 1 ms retry.

## Does the TLA+ gate still sit on the production path?

Spot-checked as instructed, and the discovery reviewer's conclusion holds on
both points. Remember that the gate itself was not executed here.

**The adapter is a 1:1 wrapper over production code.**
`formal/sse_client/ada/src/flyology-http-sse_client_trace_adapter.adb` does
nothing but delegate: every one of its ten operations is a single call into
`Flyology.HTTP.SSE_Client_Policy`, and its `State` is a record holding one
`Policy.State`. The conformance main declares `package Policy renames
Flyology.HTTP.SSE_Client_Trace_Adapter`
(`formal/sse_client/ada/src/sse_client_conformance.adb:15`), so every
`Policy.*` call in its `Apply` procedure (`:141-176`) lands in the production
unit, including `Retry_Delay_From_Milliseconds`. The conformance project
`with "flyology_http"` and its `alire.toml` pins
`flyology_http = { path = "../../.." }`, so it compiles against this
repository's `src/`, not a copy.

**The production client still issues those transitions.** `client-sse.adb:14`
declares `package Policy renames Flyology.HTTP.SSE_Client_Policy` and the body
calls it at 22 sites, covering every modelled action: `Initialize` (`:286`),
`Connection_Accepted` (`:811`), `Connection_No_Content` (`:791`),
`Connection_Recoverable_Failure` (`:667`), `Connection_Fatal_Failure` (`:802`),
`Set_Event_ID_Buffer` (`:373`), `Set_Retry_Delay` (`:332`),
`Retry_Delay_From_Milliseconds` (`:322`), `Dispatch_Event` (`:390`),
`End_Of_Body` (`:835`), `Reconnect_Wait_Elapsed` (`:893`), `Stop` (`:909`),
plus the `Selected_Wait_Delay` (`:650`) and `Sent_Last_Event_ID` (`:176`)
readers the reconnect path depends on. The composable rework kept the
lifecycle in `Event_Source.Lifecycle : Policy.State`, so the model's subject is
still the shipped code.

**The hash difference is normalisation, not staleness — and the history proves
it.** The recorded `configuration_sha256`
(`43829c3cf250d32a...`) equals the raw SHA-256 of `SSEClientTrace.cfg`
exactly, while the recorded `source_sha256` (`fe8f6b6f180f7871...`) does not
equal the raw SHA-256 of `SSEClientTrace.tla` (`8302075af73b4715...`). Walking
the two commits that ever touched the `.tla`:

| commit | raw `.tla` | recorded `source_sha256` | raw `.cfg` | recorded `configuration_sha256` |
|---|---|---|---|---|
| `6bd88f7` | `917be18e8de49fb8` | `f256f90360b2a66b` | `43829c3cf250d32a` | `43829c3cf250d32a` |
| `64131ea` | `8302075af73b4715` | `fe8f6b6f180f7871` | `43829c3cf250d32a` | `43829c3cf250d32a` |

The recorded source hash changed in lockstep with the file at both commits and
was never equal to the raw hash at either, which is the signature of a
normalised hash, not of drift. The `.cfg` matches raw at both because it
normalises to itself. `git log 64131ea..HEAD -- formal/sse_client/model/
formal/sse_client/ada/generated/` is empty, so the model and generated Ada are
unchanged since that regeneration. The only later touch, `5473d8f`, changed
exactly one field in the trace — `toolchain` from `tla2tools-1.8.0+9787e65` to
`tla2tools-1.8.0+b123b22` — leaving both hashes and all twelve steps
byte-identical, consistent with its stated purpose of repinning the toolchain.
The gate is also self-checking on this point: `check-sse-client-formal.sh`
regenerates the trace, normalises it and runs `cmp` against the committed file,
and regenerates the Ada and `cmp`s all three generated files, so a `.tla` that
had really drifted from the recorded trace would fail the gate rather than pass
it silently.

**One scope caveat worth recording.** The committed trace exercises eight
actions over twelve steps (`ConnectionAccepted`, `ReceiveRetry`,
`ReceiveIDOne`, `ReceiveIDTwo`, `DispatchEvent`, `EndOfBody`,
`ReconnectWaitElapsed`, `ConnectionNoContent`). The model
(`model/SSEClient.tla:40-110`) also has `ConnectionRecoverableFailure`,
`ConnectionFatalFailure`, `Stop` and `CorruptReconnectId`, and the trace
adapter does not expose the first three at all. TLC explores them; the *Ada
replay* does not. This is disclosed — `ASSURANCE.md` says "Replay establishes
conformance only for the retained traces" — so it is not a finding, but it
does mean the Ada-to-model conformance evidence is narrower than the
model-checking evidence, and narrower than the set of transitions the
production `Drive` issues.

**What the model does not cover, and how that relates to the findings.**
`ASSURANCE.md:79-84` excludes byte parsing, the exchange and timer children,
redirects and the deadline clamp. SSE-2 and SSE-3 both live in that excluded
layer. SSE-2 leaves the modelled state correct (the lifecycle does reach
`Failed` through `Connection_Fatal_Failure`) and only mislabels the exception,
so the model could not have caught it. SSE-3 does not violate `WaitingProgress`
— the wait does eventually end — because the model has no notion of *prompt*
cancellation; it cannot express the `.ads` promise the code breaks. SSE-1 is
server-side and entirely outside the model's subject.

## Findings sweep

Beyond the three entries above, this verification re-read the cited code, the
callers, the `.ads` contracts, the WHATWG clause and the formal artifacts, and
raised **no new findings**. Specifically checked and found sound:

- `Remember_Failure` does preserve the exception identity, so SSE-2 is a
  plumbing gap rather than information loss — a fix has the identity available.
- The deadline half of the `client-sse.ads:74-77` promise is honoured:
  `Begin_Reconnect` clamps the interval to `Remaining (Deadline)` and
  `Check_Control` re-checks expiry afterwards. Only the token half fails.
- `Send_SSE_Comment` has the same three-way duplication as `Send_Event` but no
  trailing-terminator branch on *any* backend, including HTTP/1.1
  (`server.adb:3395-3430`), so comments are consistent across backends and are
  not a second instance of SSE-1.
