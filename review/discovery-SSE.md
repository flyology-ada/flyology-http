# Discovery: SSE

Scope (read in full unless a range is given):
- `src/flyology-http-client-sse.adb` (999), `src/flyology-http-client-sse.ads` (236)
- `src/flyology-http-sse_client_policy.adb` (144), `src/flyology-http-sse_client_policy.ads` (117)
- `src/flyology-http-server-sse_handlers.adb` (301), `src/flyology-http-server-sse_handlers.ads` (131)
- `src/flyology-http-server.adb` (4838): `Begin_SSE`..`End_SSE` at 3047-3461
- `src/flyology-http-server-http_2.adb` (2799): stream table 853-960, pump DATA emission
  1070-1135, `Wait_For_Stream` 1399-1425, `Queue_Data` 1653-1680, `Begin_SSE`..`End_SSE` 1828-2062
- `src/flyology-http-server-http_3.adb` (2149): `Send_Data` 827-850, `Write_Response_Chunk`
  1098-1160, `Begin_SSE`..`End_SSE` 1180-1391
- `src/flyology-http-client.adb` (7000+): `Remember_Failure` 675-690, `Finish` 1718-1790,
  `Resume_Response_To_Sink` 1622-1687, `Deliver`/`Sink_Paused` 3870-3920, saved-error sites
- `src/flyology-http-server-applications.adb` 715-820, `src/flyology-http-headers.adb` 1-40
- `formal/sse_client/`: `ASSURANCE.md`, `model/*.tla`, `model/*.cfg`, `traces/sse-client.trace.json`,
  `ada/src/*`, `ada/generated/*`; `scripts/check-sse-client-formal.sh`; `.github/workflows/ci.yml:187-190`
- `proof/proof-status.md`, `proof/http_policy.gpr`, `scripts/prove.sh`
- Tests: `tests/http1_sse_client_integration.adb` (253), `tests/http2_server_integration.adb`
  180-215 and 392-430, `tests/http3_server_integration.adb` 272-310 and 1007-1044,
  `tests/http2_server_audit.adb` 60-90, `tests/http_smoke.adb` 815-866 and 3604-3795
- Flyology dependency specs consulted read-only from a sibling checkout (`flyology 0.2.0`):
  `flyology-io-timers.ads/.adb`, `flyology-operations.ads`
- `review/prior-audit.md`: finding 4, "SSE on the HTTP/1.1 path", coverage gaps

Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

Evidence caveats that apply to every entry below:

- `./scripts/check-sse-client-formal.sh` was NOT run (no Java, no `flyology-tla` here). Every
  statement about the TLA+ model, its trace, and the replay adapter is from reading only.
- No build or test was executed. Every claim rests on source reading.
- The brief describes `Flyology.HTTP.SSE_Client_Policy` as a SPARK-proved unit. It is not:
  neither file carries `SPARK_Mode`, the unit is absent from the `-u` list in
  `scripts/prove.sh:20-42`, and `proof/proof-status.md` never mentions it (it uses
  `Ada.Strings.Unbounded`, which GNATprove does not support). There is therefore no proved
  boundary for this unit; every site in this report is outside one. Its only formal evidence is
  the TLA+ trace replay, unexercised here.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| SSE-1 | HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator from event data that the HTTP/1.1 serialiser preserves | P1 | high |
| SSE-2 | `Event_Too_Large` and `Reconnect_Delay_Too_Large` raised while the exchange streams into the sink are re-raised as `Invalid_Event_Stream` | P1 | high |
| SSE-3 | A cancellation token does not interrupt the reconnect wait of the blocking `Read`, contrary to the `.ads` contract | P1 | high |

## Findings

### SSE-1: HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator from event data that the HTTP/1.1 serialiser preserves

- **Location:** `src/flyology-http-server-http_2.adb:1966-1996` (`Send_Event` data loop) and
  `src/flyology-http-server-http_3.adb:1302-1331` (`Send_Event` data loop); compare
  `src/flyology-http-server.adb:3353-3355`. Reached from `Applications.Send_SSE`
  (`src/flyology-http-server-applications.adb:747-778`) and `SSE_Handlers.Run`
  (`src/flyology-http-server-sse_handlers.adb:272-275`).
- **Severity:** P1
- **Confidence:** high
- **Evidence:**

The HTTP/1.1 writer's data loop ends each iteration with a branch the other two backends lack:

```ada
               First := Break + 1;
               if Data (Break) = Character'Val (13)
                 and then First <= Data'Last
                 and then Data (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
               if First > Data'Last then
                  Append (Payload, "data:" & Character'Val (10));
               end if;
```

(`src/flyology-http-server.adb:3346-3355`). The HTTP/2 copy (`:1986-1993`) and the HTTP/3 copy
(`:1322-1329`) stop after the CRLF skip; neither emits the empty `data:` line when the last
terminator is the final character of `Data`.

- **Failure scenario:**
  1. A route registered with `Allow_SSE` is served with ALPN-negotiated HTTP/2 or HTTP/3.
  2. The application calls `X.Send_SSE (Data => "line" & LF)` (or `"line" & CR & LF`).
  3. Over HTTP/1.1 the body is `data: line` LF `data:` LF LF; a conformant client concatenates
     `"line\n" & "\n"`, strips one trailing LF, and dispatches `"line\n"`.
  4. Over HTTP/2 or HTTP/3 the body is `data: line` LF LF; the client dispatches `"line"`.
  5. `Data => LF` alone: HTTP/1.1 dispatches `"\n"`; HTTP/2 and HTTP/3 emit `data:` LF LF and
     dispatch `""`, indistinguishable from `Data => ""`.
  The same application code delivers different event data depending on the negotiated
  transport, and the trailing terminator is silently lost on two of the three. This is the
  divergence the prior audit's finding 4 closed with "the two serializers remain separate
  implementations" and named unifying them as the follow-up; HTTP/3 is now a third copy with
  the same omission.
- **Reproduction test sketch:** in `tests/http2_server_audit.adb` `Events` (line 72), add a
  target `/sse/trailing` that calls `X.Send_SSE (Data => "a" & LF)`; over h2 assert the
  decoded DATA payload contains `"data: a" & LF & "data:" & LF & LF`. Expected: present (as
  the HTTP/1.1 writer produces for the same call in `tests/http_smoke.adb`). Actual:
  `"data: a" & LF & LF`. Alternatively, in `tests/http2_server_integration.adb` `Event_Stream`
  (line 181) replace one `Write_Chunk` with `X.Begin_SSE; X.Send_SSE ("gamma" & LF); X.End_SSE`
  and assert `SSE.Data (Event) = "gamma" & LF`; actual `"gamma"`.
- **Existing coverage:** `tests/http_smoke.adb:826-833` covers HTTP/1.1 with an embedded LF and
  an embedded CR but no trailing terminator; `tests/http2_server_audit.adb:74-84` covers
  injection rejection only; `tests/http3_server_integration.adb:272-310` and
  `tests/http2_server_integration.adb:181-215` drive the SSE client through raw
  `Begin_Stream`/`Write_Chunk`, not `Send_SSE`. No test sends data with a trailing terminator
  on any backend.
- **Standard:** WHATWG HTML, "Server-sent events", 9.2.6 "Interpreting an event stream",
  dispatch step: "If the data buffer's last character is a U+000A LINE FEED (LF) character,
  then remove the last character from the data buffer." A trailing LF can only be conveyed by an
  extra empty `data` field, which HTTP/1.1 emits and the other two do not.

### SSE-2: `Event_Too_Large` and `Reconnect_Delay_Too_Large` raised while the exchange streams into the sink are re-raised as `Invalid_Event_Stream`

- **Location:** `src/flyology-http-client.adb:3884-3891` (`Deliver`), consumed at
  `src/flyology-http-client-sse.adb:724-741` (`Handle_Exchange_Failure`) from
  `:819-825` (`Finish_Response_Body`). Contract: `src/flyology-http-client-sse.ads:85-86`.
- **Severity:** P1
- **Confidence:** high
- **Evidence:**

The engine converts any sink exception into a typed result and does not save the occurrence:

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

`Remember_Failure` (`:675-690`) records only `Failure_Cause` and a name string in
`Result.Detail`. `Finish` (`:1718-1742`) re-raises only when `Has_Saved_Error`, which is set at
`:704-706`, `:866-869`, `:3673-3677`, `:4424-4428`, `:5152-5156`, `:6018-6019`; none of these is
on the sink path (they cover transport release, source release, request-source failures with a
head target, and the engine's own unexpected-exception handler). The SSE layer then maps the
result:

```ada
            when Cancelled =>
               raise Flyology.Cancellation.Operation_Cancelled;
            when Timed_Out =>
               raise Flyology.IO.Timeout_Error;
            when Client_Unavailable =>
               raise Client_Closed;
            when others =>
               raise Invalid_Event_Stream with
                 "SSE HTTP exchange failed during " &
                 Exchange_Phase'Image (Phase (Result));
```

- **Failure scenario:**
  1. `Open (..., Maximum_Reconnect_Delay => 1.0, ...)`; `Read`.
  2. The server answers 200 `text/event-stream` and sends `retry: 5000` LF.
  3. Those bytes reach the parser through `Event_Sink.Write` (`client-sse.adb:488-518`) while
     `Resume_Response_To_Sink` is driving the body; `Parse_Retry` (`:307-334`) raises
     `Reconnect_Delay_Too_Large`.
  4. `Deliver` swallows it and completes the exchange as `Response_Sink_Failed`.
  5. `Finish_Response_Body` sees a non-complete result, `Handle_Exchange_Failure` raises
     `Invalid_Event_Stream` with the message "SSE HTTP exchange failed during
     RECEIVING_RESPONSE_BODY"; `Drive`'s `when others` (`:920-931`) saves that occurrence and
     `Finish` (`:981-997`) re-raises it to the caller.
  The identical sequence applies to `Event_Too_Large` (`Require_Capacity`, `:179-187`) when a
  line, data buffer, or id exceeds `Maximum_Event_Bytes`. The documented exceptions surface only
  when the violating byte happens to be processed by `Process_Buffered` (`:849-861`), i.e. it
  was left over in `Pending` after an earlier event completed within the same delivered slice.
  For the first violation in a stream, which is the common case, the caller cannot distinguish
  a caller-limit breach from a malformed response.
- **Reproduction test sketch:** copy `tests/http1_sse_client_integration.adb`; make the raw
  server's first body `"retry: 5000" & LF & LF`, keep `Maximum_Reconnect_Delay => 1.0`, wrap
  the first `SSE.Read` in a handler. Expected: `SSE.Reconnect_Delay_Too_Large`. Actual:
  `SSE.Invalid_Event_Stream`. Second variant: `Maximum_Event_Bytes => 16`, body
  `"data: " & (1 .. 32 => 'a') & LF & LF`; expected `SSE.Event_Too_Large`, actual
  `SSE.Invalid_Event_Stream`.
- **Existing coverage:** none. `tests/http1_sse_client_integration.adb:153-161` sends
  `retry: 0001` within bounds and small events; the HTTP/2 and HTTP/3 integration tests do the
  same.
- **Standard:** n/a (documented contract at `client-sse.ads:85-86`; also `ASSURANCE.md:39`
  maps "caller limit" to `ConnectionFatalFailure`, which the lifecycle does reach, so the
  policy state is right and only the exception identity is wrong).

### SSE-3: A cancellation token does not interrupt the reconnect wait of the blocking `Read`, contrary to the `.ads` contract

- **Location:** `src/flyology-http-client-sse.adb:648-661` (`Begin_Reconnect`), `:890-896`
  (`Waiting_Reconnect` branch of `Drive`), `:524-539` (blocking `Read`). Contract:
  `src/flyology-http-client-sse.ads:74-77`.
- **Severity:** P1
- **Confidence:** high
- **Evidence:**

The contract:

```ada
   --  Return the next event, reconnecting after clean EOF or recoverable
   --  transport failure.  HTTP 204 returns Stream_Stopped and permanently
   --  disables reconnect.  Cancellation and the absolute deadline interrupt
   --  requests, reads, and reconnect waits using their ordinary exceptions.
```

The wait:

```ada
      procedure Begin_Reconnect is
         Interval : Duration :=
           Policy.Selected_Wait_Delay (Item.Source.Lifecycle);
      begin
         Finalize (Item.Source.Reply);
         Item.Source.Connected := False;
         if Item.Source.Deadline.Is_Limited then
            Interval := Duration'Min
              (Interval, Remaining (Item.Source.Deadline));
         end if;
         Flyology.IO.Timers.Sleep_For (Interval, Item.Timer.all);
         Item.Phase := Waiting_Reconnect;
         Flyology.Operations.Continue_After (Item, Item.Timer.all);
      end Begin_Reconnect;
```

and its completion:

```ada
         when Waiting_Reconnect =>
            Flyology.IO.Timers.Finish (Item.Timer.all);
            Flyology.Operations.Release (Item.Timer.all);
            Policy.Reconnect_Wait_Elapsed (Item.Source.Lifecycle);
            Check_Control (Item.Source.all, Item.Token);
```

The deadline is honoured (the interval is clamped to it). The token is not: `Timer_Operation`
takes no token (`flyology-io-timers.ads:95-98`), `Wait_All (Set)` takes none
(`flyology-operations.ads:250`), and `Check_Control` runs only after the timer has fired. The
only thing that cancels the timer early is `Request_Cancellation` (`:934-961`), reached through
`Flyology.Operations.Cancel` on the `Read_Operation`, which the blocking overload never exposes.
- **Failure scenario:**
  1. `Open (..., Initial_Reconnect_Delay => 0.0, Maximum_Reconnect_Delay => 300.0, Deadline => No_Deadline)`.
  2. The server sends `retry: 300000` LF `data: x` LF LF and closes.
  3. `Read (Source, Result, Event, Token => T'Access)` returns the event; the next `Read` with
     the same token reaches `End_Of_Body` and `Begin_Reconnect` with a 300 s timer.
  4. Another task calls `T.Request`.
  5. `Read` stays blocked in `Wait_All` for the full 300 s, then raises
     `Operation_Cancelled` from `Check_Control`. A server-chosen `retry` anywhere up to the
     caller's maximum pins the calling task despite cancellation.
- **Reproduction test sketch:** raw server as in `tests/http1_sse_client_integration.adb`,
  first body `"retry: 5000" & LF & "data: a" & LF & LF`, close; client `Maximum_Reconnect_Delay
  => 10.0`; after the first `Read` returns, start a task that calls `Token.Request` after
  0.1 s; time the second `Read (..., Token => Token'Access)`. Expected: returns within well
  under 1 s with `Operation_Cancelled`. Actual: about 5 s.
- **Existing coverage:** none. All three SSE integration tests pass `Token => null` and use a
  1 ms retry.
- **Standard:** n/a (documented contract).

## The high-value question: does the TLA+ gate still sit on the production path?

Answer from reading: yes for the reconnect-lifecycle policy, with the declared limits, subject
to the caveat that the gate itself was not run here.

- The adapter (`formal/sse_client/ada/src/flyology-http-sse_client_trace_adapter.adb`) is a
  1:1 wrapper over `Flyology.HTTP.SSE_Client_Policy`, and the conformance main
  (`sse_client_conformance.adb:141-176`) drives exactly that unit, including the production
  `Retry_Delay_From_Milliseconds`. The rework onto the owner-driven engine kept the lifecycle
  state in `Event_Source.Lifecycle : Policy.State` and every transition is still issued from
  `Drive` at the boundary `ASSURANCE.md:34-45` documents: `Connection_Accepted` at
  `client-sse.adb:811`, `Connection_No_Content` at `:791`, `Connection_Recoverable_Failure` at
  `:667` (for `Connection_Failed | Transport_Failed | Response_Invalid`, `:728`),
  `Connection_Fatal_Failure` at `:802`, `:806`, `:928`, `Set_Event_ID_Buffer` at `:373`,
  `Set_Retry_Delay` at `:332`, `Dispatch_Event` at `:390` (every blank line, data or not),
  `End_Of_Body` at `:835` and `:869`, `Reconnect_Wait_Elapsed` at `:893` after the timer child's
  `Finish`, `Stop` at `:909`, `:917`, `:946`.
- The model's action set (`SSEClient.tla:40-98`) and the proof module agree with the policy
  body transition by transition, including the `Require_Phase` guards. The trace
  (`traces/sse-client.trace.json`) uses only actions the adapter accepts.
- The recorded source hash (`fe8f6b6f...`) does not equal the raw SHA-256 of
  `SSEClientTrace.tla` (`8302075a...`), but that is not staleness: at `6bd88f7` the recorded
  hash already differed from the raw file hash, and `64131ea` regenerated all three artifacts
  together with the `.tla` comment change, so the tool hashes a normalised form. The `.tla` is
  unchanged since `64131ea`. CI runs the gate (`.github/workflows/ci.yml:190`); whether it is
  green at `f078732` was not checked.
- What the model does not cover, and says so (`ASSURANCE.md:79-84`): byte parsing, the
  exchange and timer children, redirect handling, and the deadline clamp in `Begin_Reconnect`.
  SSE-2 and SSE-3 both live in that uncovered layer: SSE-2 leaves the modeled state correct
  (Failed) and only mislabels the exception; SSE-3 does not violate `WaitingProgress`
  (the wait does eventually end) but the model has no notion of prompt cancellation, so it
  cannot express the `.ads` promise that the code breaks.

## Areas reviewed with no findings

- **BOM.** `Process_Stream_Octet` (`client-sse.adb:444-486`) strips exactly one leading
  EF BB BF per accepted connection (`At_Stream_Start` reset in `Reset_Parser`, called at
  `:813`); a 1- or 2-byte BOM prefix is deferred and replayed if the third byte differs. The
  `exit when Available` in the replay loop cannot lose bytes because no dispatch is possible
  within the first three bytes of a freshly reset parser.
- **Line terminators.** CR, LF, CRLF handled in `Process_Octet` (`:421-442`); `Skip_Next_LF`
  lives in `Event_Source`, so a CRLF split across two `Write` slices is one terminator; CR CR is
  two lines (the second CR is a blank line, a dispatch boundary), as the standard requires.
- **Field grammar.** `Process_Field` (`:336-381`): no colon gives the whole line as name with
  empty value; colon at position 0 is a comment; exactly one optional space after the colon;
  unknown names ignored; names compared case-sensitively; UTF-8 decoded per line with U+FFFD
  replacement (`Decode_UTF8`, `:88-169`, maximal-subpart resynchronisation). Decoding per line
  is equivalent to decoding the stream because no continuation byte equals CR or LF.
- **Dispatch.** `Finish_Line` (`:383-413`): data lines accumulate with LF, the trailing LF is
  stripped, empty data does not dispatch, the event type resets after every blank line, the
  type defaults to `message`, and `Policy.Dispatch_Event` commits the id buffer before the
  empty-data check, exactly the standard's step order. `id` with NUL is ignored (`:368`); an
  empty `id` sets the buffer to empty. `retry` accepts ASCII digits only, ignores empty, converts
  without floating point (`policy.adb:72-97`), and the value drives `Wait_Delay_Value` at the next
  `End_Of_Body`/`Connection_Recoverable_Failure`.
- **Reconnect state.** 204 is terminal (`Connection_No_Content`; a later `Read` returns
  `Stream_Stopped` from `:846-848`). Any other non-200, or a Content-Type whose essence is not
  `text/event-stream` (`Is_Event_Stream`, `:290-305`, parameters stripped, case-insensitive),
  is fatal and never reconnects. `Last-Event-ID` is sent only when nonempty
  (`Replace_Controlled_Headers`, `:233-259`) from the value snapshotted at
  `Reconnect_Wait_Elapsed`; `Headers.Add` accepts the obs-text bytes a UTF-8 id may contain.
  The deadline clamps the wait and is re-checked after it. Cancelling the composable operation
  during the wait cancels the timer and `Timers.Finish` raises `Operation_Cancelled`
  (`flyology-io-timers.adb:140-152`), so `Drive` completes as Cancelled without starting a new
  connection.
- **Redirects.** Same-origin 301/302/303/307/308 are followed within the current attempt with
  a hop limit and loop detection (`Follow_Redirect`, `:747-785`); every reconnect starts again
  from the original template (`Start_Response_Head`, `:685-694`). Current WHATWG uses fetch
  with redirect mode "follow" and never updates the EventSource URL, so the legacy 301/307
  distinction does not apply.
- **Server validation across backends.** `Validate_SSE_Field` (CR/LF in `Event` and `Id`),
  UTF-8 validation of `Data`/`Event`/`Id`, NUL rejection in `Id`, newline-splitting of `Data`
  and comments into repeated fields: identical in `server.adb:3088-3096, 3304-3312`,
  `http_2.adb:1854-1863, 1944-1953`, `http_3.adb:1196-1205, 1281-1290`, except the trailing
  terminator (SSE-1). No application-supplied value can end a field line or start another
  event on any backend. `retry:` is emitted from a `Natural` only.
- **HTTP/2 backpressure (the prior audit's explicit gap).** `Queue_Data` (`:1653-1680`)
  chunks at `Frames.Default_Maximum_Frame_Size` (16384, always at or below any peer
  `SETTINGS_MAX_FRAME_SIZE`, RFC 9113 6.5.2) into a per-stream ring of
  `Stream_Buffer_Capacity` = `Advertised_Initial_Window_Size` = 16384; on `Queue_Would_Block`
  it waits in `Wait_For_Stream` (`:1399-1425`) on the stream's wake source until that many
  bytes are free, the stream fails, the connection token cancels, or the exchange deadline
  expires. The pump (`:1083-1131`) emits DATA bounded by the stream and connection send windows,
  decrements both, and `Notify`s the stream so the waiter wakes. Stream failure or reset
  (`Mark_Failed`, `:905-922`) makes the queue return `Queue_Failed`, so a dead peer unblocks the
  handler with `Device_Error`. `Await_Drained` from the prior audit's note does not exist in
  the HTTP/2 server; this is the path.
- **HTTP/3 SSE.** `Send_Event` goes through `Write_Response_Chunk` (`:1098-1131`) whose
  fixed-length tracker is `Idle` for an SSE response (`Fixed_Response_Policy.Write` returns
  `Inactive`), then `Send_Data` (`:827-850`) with QUIC-level blocking and the stream deadline.
- **`SSE_Handlers`.** Byte budgets are reserved before enqueue and released after write or on
  failure (`Reservation_Guard`, `:26-46`); `Run` (`:218-292`) checks token and deadline every
  quantum, drains and signals producers on any failure, and `Finalize` does the same.

## Observations not counted

- **Last-event-ID buffer reset per accepted connection.** `Connection_Accepted`
  (`policy.adb:25-30`) clears `Event_ID_Value`, and the model's `ConnectionAccepted` does the
  same. Consequence: after a reconnect that sent `Last-Event-ID: 5`, a stream that dispatches an
  event without an `id` field commits `""`, so the following reconnect sends no
  `Last-Event-ID`. This is the literal reading of the standard ("a last event ID buffer must be
  associated with [the stream] ... initialized to the empty string") and `ASSURANCE.md:8-9`
  states it deliberately. Whether shipping browsers keep the previous id across streams
  instead was not checked here; if they do, this is an interoperability difference for
  resumable servers, not a defect against the text.
- **One octet per drive.** `Process_Buffered` (`client-sse.adb:849-861`) processes a single
  byte per `Drive` and `Reschedule`s, so leftover bytes after an event cost one scheduler pass
  each. Performance only.
- **`Pending` is not under `Maximum_Event_Bytes`.** The `.ads` bound covers line, fields, and
  ids; `Pending` (`:499-507`) holds one delivered slice and is cleared when consumed, so it is
  bounded by the engine's slice size rather than the caller's bound. Not a defect.
- **Comment framing.** Every comment, including the `SSE_Handlers` heartbeat, is followed by
  an extra LF (`server.adb:3423`, `http_2.adb:2046`, `http_3.adb:1380`), which is a blank line
  and therefore a dispatch boundary on the client. Harmless: the data buffer is empty so no
  event fires, and the id buffer persists.
- **204 versus other statuses.** Current WHATWG treats any non-200 as "fail the connection";
  the API distinguishes 204 (`Stream_Stopped`) from the rest (`Invalid_Event_Stream`). Both are
  terminal, so this is API shape, not a protocol deviation.
- **`Response_Invalid` reconnects.** Malformed response framing is treated as recoverable
  (`:728`), consistent with fetch reporting it as a network error.
- **Stalled peer with a closed window.** An HTTP/2 peer that stops sending WINDOW_UPDATE pins
  the SSE handler task in `Wait_For_Stream` until the route deadline; with an unlimited route
  timeout that is indefinite. Per-connection, and the route timeout is the documented control.
- **Two coupled constants.** `Queue_Data`'s per-chunk wait is satisfiable only while
  `Frames.Default_Maximum_Frame_Size` <= `Stream_Buffer_Capacity`; both are 16384 today with no
  static check tying them.
- **Header capacity at `Open`.** `Replace_Controlled_Headers` rebuilds the list with the same
  capacity and adds up to two fields; a template already at `Capacity` with neither `Accept` nor
  `Last-Event-ID` present would raise `Headers_Too_Large` inside `Drive` and fail the lifecycle
  rather than at `Open`. Unusual input; not rated.
- **Formal gate not exercised.** See the caveats at the top and the high-value section.
