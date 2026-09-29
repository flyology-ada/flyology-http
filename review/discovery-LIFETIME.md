# Discovery: LIFETIME

Scope (read in full unless a line range is given):
- `src/flyology-http-client-state_lifetime.adb` (30), `src/flyology-http-server-request_tasks.ads/.adb` (40/12), `src/flyology-http-server-exchange_backends.ads` (255), `src/flyology-http-server-tls.ads/.adb` (44/24), `src/flyology-http-server-development_certificates.ads/.adb` (79/349)
- `src/test_hooks/connection/disabled/*.ads` (26), `src/test_hooks/connection/enabled/*.ads/.adb` (15/47), `flyology_http.gpr` (128), `scripts/check-test-hook-elision.sh` (147), `scripts/test.sh` (307)
- `tests/flyology-io-connections-testing.ads/.adb` (47/88), `tests/native/connection_test_hooks.c` (145), `tests/compile_fail/*.adb` (20/20/22), `tests/http_smoke.adb:4340-4432`, `tests/http3_client_composable_smoke.adb:640-700`
- Every `Limited_Controlled`/`Controlled` type and every `Finalize` in `src/`: `src/flyology-http-client.ads:1240-1402` and `.adb` (7406; regions 262-330, 530-905, 1055-1200, 1596-1692, 1866-1960, 2015-2240, 7330-7406), `src/flyology-http-client-pool_controller.adb:340-660` (686), `src/flyology-http-client-http_3_internals.adb:340-466`, `src/flyology-http-client-sse.adb:955-999`, `src/flyology-http-http_2_client_connection.adb` (regions 400-460, 1620-1730, 2360-2384), `src/flyology-http-http_3_client_connection.adb:582-710`, `src/flyology-http-server.ads:1000-1133` and `.adb:100-300`, `src/flyology-http-server-routing.ads:1400-1471` and `.adb` (120-200, 670-700, 1490-1565, 2470-2600, 2758-2860), `src/flyology-http-server-middleware_bulkheads.adb:60-200`, `src/flyology-http-server-sse_handlers.ads/.adb` (131/301), `src/flyology-http-server-websocket_handlers.ads/.adb` (245/706, regions 16-70, 255-300, 380-440, 690-706), `src/flyology-http-http_3.adb:40-95`, `src/flyology-http-websocket_client.adb:1385-1402`, `src/flyology-http-server-applications.ads:55-75,209-216` and `.adb:17-45,122-126`
- Server task bodies: `src/flyology-http-server-http_2.adb:2075-2225,2765-2799` and `.ads` (43), `src/flyology-http-server-http_3.adb:1975-2200`
- Runtime dependency, read from the Alire cache: **`flyology` 0.1.1-dev at commit `bd95746d5c9c31f5b41b611db9ba82a016ceaaa4`** (`alire/alire.lock`), directory `~/.local/share/alire/releases/flyology_0.1.1_bd95746d`: `src/flyology-task_scopes.ads` (217), `src/flyology-operations.ads:95-130,240-270` and `.adb` (Finalize body), `src/flyology-cancellation.adb` (48), `src/flyology-io-tls.adb:1-60`, `src/flyology-bounded_channels.ads/.adb`, `src/flyology-io-connections-drivers.adb` (Signal/Wait_Source/Consume), `src/platform/darwin/flyology-wake_sources.adb` (Ensure/Signal/Try_Signal_Borrowed). The sibling checkout at `/Users/yrashk/Projects/flyology-ada/flyology` (0.2.0) was not used.
- `review/prior-audit.md` findings 10, 12, 37 and all three appendices.

Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| LIFETIME-1 | Finalizing an unread HTTP/3 `Response` never cancels or releases its stream, unlike HTTP/2 and unlike the composable path | P2 | medium |
| LIFETIME-2 | The "no helper task in client units" invariant check fails open and is evadable | P2 | high |
| LIFETIME-3 | Two `.ads` contracts claim Ada-enforced lifetime with no `compile_fail` case pinning them; `Request_Tasks` cancellation inheritance is untested | P2 | medium |
| LIFETIME-4 | `Abandon_Response` runs the HTTP/2 stream teardown unguarded before `Release_Lease`, so a raise there leaks the pool lease permanently | P2 | low |

## Findings

### LIFETIME-1: Finalizing an unread HTTP/3 `Response` never cancels or releases its stream, unlike HTTP/2 and unlike the composable path

- **Location:** `src/flyology-http-client.adb:2151-2170` (`Abandon_Response`), consumed by `Response.Finalize` at `:7369-7378`; contract at `src/flyology-http-client.ads:485-490`
- **Severity:** P2
- **Confidence:** medium (the omission is certain by comparison with the two sibling paths; the runtime consequence is bounded by the pool's Draining phase, and whether the unread stream data pins QUIC connection-level credit for sibling streams is in the QUIC reviewer's area and was not verified here)
- **Evidence:**

```ada
   procedure Abandon_Response (Data : in out Response_Data) is
      Reusable : Boolean := False;
   begin
      if Data.Connection = null then
         return;
      elsif Data.Engine = HTTP_2_Response then
         Reusable := H2_Connections.Is_Usable (Data.Connection.HTTP_2.all);
         if Data.HTTP_2_Stream /= H2_Connections.No_Stream then
            H2_Connections.Cancel_Stream
              (Data.Connection.HTTP_2.all, Data.HTTP_2_Stream);
            H2_Connections.Release_Stream
              (Data.Connection.HTTP_2.all, Data.HTTP_2_Stream);
            Data.HTTP_2_Stream := H2_Connections.No_Stream;
         end if;
      elsif Data.Engine = HTTP_3_Response then
         Reusable := False;
      end if;
      Release_Lease
        (Data, Reusable => Data.Engine = HTTP_2_Response and then Reusable);
   end Abandon_Response;
```

  The `.ads` promise (`client.ads:485-490`): "Finalizing an incomplete HTTP/1.1 or HTTP/3 response closes its transport; finalizing an incomplete HTTP/2 response resets only its stream when the multiplexed transport remains usable."

  The two sibling teardown paths both release the HTTP/3 stream. `Release_Exchange_Transport` (`client.adb:762-798`) calls `H3_Connections.Owns_Pump`/`Release_Pump`, `Cancel_Stream` when `not State.HTTP_3_Finished`, and `Release_Stream`, each guarded. The normal body-completion path (`src/flyology-http-client-http_3_internals.adb:442-449`) calls `H3_Connections.Release_Stream` then `Release_Lease`. `Finish_Success` (`client.adb:1166-1183`) copies the stream handle into the `Response` (`Candidate := new Response_Data'(State.Metadata)`) and clears the exchange's own aliases, so after `Execute` returns the `Response` is the sole holder of `HTTP_3_Handle`, and `Abandon_Response` is the only release site left.

  HTTP/3 pool slots are multiplexed (`src/flyology-http-client-pool_controller.adb:299-300`: `HTTP_2_Transport | HTTP_3_Transport then Shared else Leased`). In `Return_Lease` (`:389-433`) a `Shared` slot returned with `Reusable = False` becomes `Draining`; while `Active_Streams > 0` the result is `Returned_Shared` and the connection stays open for the siblings. Only when the last sibling returns does it go `Closing` and get disposed.

- **Failure scenario:**
  1. An application configures a client with an HTTP/3 policy and issues two `Execute` calls that share one HTTP/3 connection (the second is admitted while the first response body is still pending).
  2. It drops the first `Response` without reading the body (`Finalize` → `Abandon_Response`).
  3. `Abandon_Response` takes the `HTTP_3_Response` branch: no `Cancel_Stream`, no `Release_Stream`, no `Release_Pump`. `Release_Lease` returns the lease with `Reusable = False`; the slot becomes `Draining`, `Returned_Shared`.
  4. For the rest of the connection's life (until the second response completes) the abandoned stream's `H3_Connections` slot stays `Phase /= Free` with its receive buffer, `Wake` and credit bookkeeping intact, and nothing signals the peer, so the server keeps sending the unwanted body into that stream. The `.ads` says the transport is closed; it is drained instead, and the abandoned stream is never released within it.
  5. When the second response completes the whole session is disposed (`Close_And_Finish` → `Dispose_Connection`), which is why this stays bounded: the slot leak lasts one connection lifetime, and no reuse is lost beyond the connection the doc already promises to close.

- **Reproduction test sketch:** In-process, using the HTTP/3 server from `tests/http3_server_integration.adb` (or the `Flyology.QUIC.Test_Connections` seam) serving a route whose body is larger than the initial stream window: (1) `Execute` request A and request B on one client so B is admitted on A's connection (assert via the pool model that both share a slot); (2) let A's `Response` go out of scope unread; (3) assert on the server that A's stream receives a STOP_SENDING/RESET_STREAM (expected) versus keeps its stream open and continues writing until connection close (actual); (4) assert on the client that `H3_Connections` reports the slot free after A's finalization (expected) versus occupied until B completes (actual). A byte-level alternative: capture the QUIC frames after step 2 and expect a STOP_SENDING for A's stream ID before B's response completes.

- **Existing coverage:** `tests/http3_client_composable_smoke.adb:660-691` ("Deliberately omit Finish. Finalization must drain...") exercises abandonment only through `Exchange_Operation.Finalize` → `Release_Exchange_Transport`, which does release the stream. No test drops an unread `Response` returned by `Execute` over HTTP/3 (searched `tests/http3_*.adb` and `tests/http_client_*.adb` for abandon/unread/Finalize).

- **Standard:** RFC 9114 §4.1.1 describes client-side request cancellation as aborting the request stream (RESET_STREAM and/or STOP_SENDING with H3_REQUEST_CANCELLED). Not sending one is permitted; the interoperability cost is only wasted server transmission, which is why this is P2. I could not check a real peer's behaviour here.

### LIFETIME-2: The "no helper task in client units" invariant check fails open and is evadable

- **Location:** `scripts/test.sh:75-84` (under `set -eu` at `:2`)
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```sh
cd "$http_root"
if rg -n \
  '^[[:space:]]*task([[:space:]]+(type|body))?[[:space:]]' \
  src/flyology-http-client*.ad[bs] \
  src/flyology-http-http_2_client_connection.ad[bs] \
  src/flyology-http-http_3_client_connection.ad[bs]
then
  printf '%s\n' \
    "HTTP client owner-driven engine declares a forbidden helper task" >&2
  exit 1
fi
```

  The invariant itself holds at f078732: `rg -n '^\s*task\b' src/` finds task declarations only in `src/flyology-http-server-http_2.adb`, `-http_3.adb` and `-routing.adb`, and the only `Flyology.Task_Scopes` instantiation is the server-side `src/flyology-http-server-request_tasks.ads:22`. The finding is about the check.

- **Failure scenario (four independent evasions):**
  1. **Fails open without `rg`.** `rg` is not checked for anywhere in `scripts/test.sh`, `scripts/alire-test-context.sh`, `scripts/find-alr.sh` or `tests/alire_action_context.sh`. If it is absent the command exits 127 inside the `if` condition, `set -e` does not fire on a condition, the `if` takes the false branch, and the check silently passes.
  2. **Case.** Ada keywords are case-insensitive (RM 2.9(1)); the pattern is case-sensitive. `Task Foo;` or `TASK type Foo` is a task declaration the pattern does not match.
  3. **Line break.** `task` followed by a newline and the name on the next line is legal Ada and does not match `task[[:space:]]` on a single line.
  4. **Indirection.** A task type reached through a generic instantiation (`package P is new Flyology.Task_Scopes (...)`) contains no `task` keyword, and a task declared in a unit the client withs outside the three globs (`src/flyology-http-http_1_*`, `src/flyology-http-websocket_client*`, `src/flyology-http-sse*`, `src/flyology-http-http_3.*`) is not scanned at all. The runtime's `Task_Scopes` allocates lightweight workers in `Configure` (`flyology-task_scopes.ads:164-178`), so this is the most plausible way a future client-side helper task would appear.

- **Reproduction test sketch:** (a) `PATH=/usr/bin sh -c 'command -v rg || true; ./scripts/test.sh'` on a machine without `rg` — expected: the invariant check aborts with a diagnostic; actual: passes through. (b) Temporarily add `Task Probe;` (capitalised) or `task` + newline + `Probe;` to `src/flyology-http-client-state_lifetime.adb` and run only lines 75-84 — expected: exit 1; actual: no match. Both are dry checks on the script and do not need a build.

- **Existing coverage:** none; the check is itself the test.

- **Standard:** RM 2.9(1) (reserved words are case-insensitive); n/a otherwise.

### LIFETIME-3: Two `.ads` contracts claim Ada-enforced lifetime with no `compile_fail` case pinning them; `Request_Tasks` cancellation inheritance is untested

- **Location:** `src/flyology-http-server-request_tasks.ads:25-31` and `src/flyology-http-server-applications.ads:63-65`; harness at `scripts/test.sh:270-305`; only test at `tests/http_smoke.adb:4358-4380`
- **Severity:** P2
- **Confidence:** medium (I could not compile a negative case to confirm whether GNAT rejects each escape statically or only at run time; the drift is that the claims are unpinned, and the test gap is certain)
- **Evidence:**

```ada
   --  Inherit the Exchange cancellation identity and current absolute
   --  deadline. Subsequent Exchange narrowing does not retroactively update a
   --  configured scope, so configure it after request middleware completes.
   --  The scope links parent cancellation downward into a private child token;
   --  sibling failure never requests the parent request token.
   --  Item must be declared with Parent => X.Cancellation so Ada enforces the
   --  request-token borrow.
```

```ada
   --  Construct one exchange around values owned by the active handler.
   --  Access discriminants let Ada reject an exchange whose request,
   --  connection, or token would not outlive it.
```

  The body of `Request_Tasks.Configure` (`request_tasks.adb:3-10`) passes only `X.Deadline` to `Operations.Configure`; the cancellation identity is inherited solely through the `Parent` access discriminant the caller must supply, and nothing checks that the supplied `Parent` is `X.Cancellation` rather than `null` or another token. `Exchange.Cancellation` (`applications.adb:122-126`) returns `Item.Token_Handle.all'Unchecked_Access`, which is what the accessibility of the discriminant actual is derived from.

  The three cases the harness pins (`test.sh:275-305`) are the `Client.Execute` result escape (`.*accessibility.*return`), the `Array_Source` payload escape (`access discriminant.*statically too deep`), and the `WebSocket_Handlers.Session` pool escape (`deeper level than allocator type|accessibility`). Neither of the two claims above has a case. The only `Request_Tasks` test spawns two children and checks the sum is 42 (`http_smoke.adb:4371-4380`); it never requests `X.Cancellation` or narrows the deadline, so neither half of "Inherit the Exchange cancellation identity and current absolute deadline" is asserted in this repository.

- **Failure scenario:** 1. A handler declares `Item : Operations.Scope (Capacity => 2, Parent => null)` or `Parent => Some_Other_Token'Access` and calls `Request_Tasks.Configure (Item, X)`. 2. `Configure` succeeds; children receive the deadline but are not linked to the request token. 3. The request is cancelled by the connection (`Backend.Token.Request` at `server-http_2.adb:2780-2784`); the children run to their deadline instead. The doc's "so Ada enforces" is true only of the lifetime of whatever token was passed, not of its identity. Separately, if a later compiler or a future change to `Cancellation`'s implementation lets a `Scope` or an `Exchange` outlive its token, nothing in the suite would notice.

- **Reproduction test sketch:** (a) Add `tests/compile_fail/request_task_scope_lifetime_fail.adb` that returns an allocated `Operations.Scope (1, Parent => X.Cancellation)` from a function or stores it in a longer-lived access; expected: an accessibility error pinned by a `grep -E` line in `test.sh` like the three existing ones. (b) Add a smoke case that requests `X.Cancellation` while a spawned child is blocked on its token and asserts the child's `Result` re-raises `Operation_Cancelled`, plus one that narrows `X.Deadline` before `Configure` and asserts the child sees `Timeout_Error`. (c) In `Request_Tasks.Configure`, `Item.Parent = X.Cancellation` is a comparable anonymous-access pair; raising `Program_Error` on mismatch would turn the doc's "must" into a check.

- **Existing coverage:** `tests/http_smoke.adb:4358-4380` (happy path only); `scripts/test.sh:270-305` (three other lifetime claims).

- **Standard:** RM 3.10.2 (accessibility of access discriminants and anonymous access function results); n/a otherwise.

### LIFETIME-4: `Abandon_Response` runs the HTTP/2 stream teardown unguarded before `Release_Lease`, so a raise there leaks the pool lease permanently

- **Location:** `src/flyology-http-client.adb:2157-2163`, consumed by `Response.Finalize` `:7369-7395`
- **Severity:** P2 (no reachable trigger found; recorded because the asymmetry with `Release_Exchange_Transport` is deliberate elsewhere and the failure mode is a permanent lease loss plus a hang)
- **Confidence:** low
- **Evidence:**

```ada
      elsif Data.Engine = HTTP_2_Response then
         Reusable := H2_Connections.Is_Usable (Data.Connection.HTTP_2.all);
         if Data.HTTP_2_Stream /= H2_Connections.No_Stream then
            H2_Connections.Cancel_Stream
              (Data.Connection.HTTP_2.all, Data.HTTP_2_Stream);
            H2_Connections.Release_Stream
              (Data.Connection.HTTP_2.all, Data.HTTP_2_Stream);
```

  versus the same calls in `Release_Exchange_Transport` (`client.adb:736-757`), each wrapped in `exception when Error : others => May_Reuse := False; Save (Error);`. In `Response.Finalize`'s handler (`:7388-7395`) the response data is freed with `Item.Data.Connection /= null`, i.e. `Release_Lease` never ran, so the slot stays `Leased`/`Shared` with an active stream count that is never decremented.

- **Failure scenario:** 1. `Response.Finalize` → `Abandon_Response` → `H2_Connections.Cancel_Stream` → `Drivers.Signal (Item.State.Outbound)` → `Wake_Sources.Signal` raises `Program_Error` ("cannot signal borrowed wake source", `flyology-wake_sources.adb`, only on a write failure other than EAGAIN/EINTR), or `Queue_Control_Frame` raises `Storage_Error`. 2. The handler releases the owner retain and frees `Data`; the lease is gone from the response but still counted by the pool. 3. `Await_Drained` (`pool_controller.adb:599`) can never open: `Client.Shutdown` without a timeout hangs; `Client_Control.Finalize` → `Interrupt_Active` finds the slot, closes the channel, but `Finish_Interrupt` sees `Phase /= Closing` and never disposes the connection, which is then leaked when `Release_State` frees the pool.

- **Reproduction test sketch:** Needs fault injection: close the session's outbound wake descriptor (or use the runtime's `Worker_Pool_Test_Hooks.Cancellation_Failure`-style seam if one is added for `Drivers.Signal`) before dropping an unread HTTP/2 `Response`; expected: the lease is returned and `Shutdown` completes; actual: `Shutdown (Timeout => 1.0)` raises `Timeout_Error`. Without a seam I could not construct the trigger, which is why the confidence is low.

- **Existing coverage:** none for the exception path; `tests/http2_client_integration.adb` covers the normal HTTP/2 abandonment.

- **Standard:** n/a.

## Areas reviewed with no findings

- **Controlled types and abort safety.** Every `Finalize` in `src/` was read: `Client_Control`, `Response`, `Exchange_Operation` (client), `Read_Operation` (client SSE), `Client` (WebSocket client), `Session` (HTTP/3), `Connection` (server), `Router`/`Update_State`/`Snapshot_State` (routing), `Guard` (bulkheads), `Reservation_Guard` and `Session` (SSE and WebSocket handlers), `Identity` (development certificates). None can be reached half-initialised in a way that dereferences an uninitialised part: every one tests its access components for null or an `Is_Generated`/`Held`/`Reserved` flag first, and a `Storage_Error` in a record component default (for example `WebSocket_Handlers.Session.Buffer_Outbox := new ...`) means the enclosing object's `Finalize` is never invoked (RM 7.6.1(9-10)). Finalize-twice is not reachable through abort because `Finalize` is abort-deferred (RM 9.8(10)), and no `Finalize` here is callable by users. On raising: `Identity.Finalize` and the two operation finalizers swallow; `Response.Finalize` catches and still releases the retain; the remaining bodies can only raise via protected `Release` underflow guards (`"... permit underflow"`, `"... budget underflow"`), all of which are unreachable because every release site is paired with an acquire behind a `Held`/`Reserved`/`Retains_Owner` flag that is cleared before the release (`middleware_bulkheads.adb:145-151`, `sse_handlers.adb:36-45`, `websocket_handlers.adb:49-62`, `client.adb:7380-7382`, `client.adb:882-884`). `Session.Finalize` (SSE/WebSocket) calls `Item.Stop.Request` unguarded, but `Cancellation.Token.Request` (`flyology-cancellation.adb:8-27`) sets `Is_Requested` first and signals only an already-created descriptor, treating `EAGAIN` as delivered, so it raises only through a test hook or a closed pipe. `Finalize` propagating is a bounded error (RM 7.6.1(14-18)); I found no reachable instance.
- **Retain/release pairing of `State_Lifetime`.** One retain (`client.adb:1171-1172`, in `Finish_Success`) against four release sites, each guarded by `Retains_Owner`: `Response.Finalize` (`:7380-7382` and the handler `:7390-7395`), `Release_Exchange_Borrows` (`:882-884`), and the `Finish_Success` handler (`:1188-1207`). `Resume_Response_To_Sink` (`:1652-1673`) moves the retain into the exchange's metadata with a plain record copy before clearing the flag on the source. `Release_Client` sets `Client_Live := False` before returning the final-reference decision, so a client finalised under a live response defers `Release_State` to the last response, and `Retain_Response` refuses new responses once finalising.
- **`Release_State` idempotence.** `Free_Resolver`, `Flyology.IO.TLS.Release` (`flyology-io-tls.adb:14-17`, an `Unchecked_Deallocation`) and `Free_State` all null their argument, so the retry of `Release_State` inside `Response.Finalize`'s handler cannot double-free.
- **Pool interrupt versus lease-holder ownership.** `Take_Active_For_Interrupt`/`Finish_Interrupt` (`pool_controller.adb:543-597`) transfer disposal to the interrupter only when the holder already moved the slot to `Closing` with `Owner_Done`; otherwise the holder's `Return_Lease` sees `Interrupting` and returns `Return_Close_Deferred`, so the connection is disposed exactly once on either interleaving. `Await_Drained` counts `Leased` per multiplexed stream (`Return_Lease` decrements `Leased_Count` before the `Shared` branch), so shared slots are not invisible to it.
- **Server-side bounded resources, acquire/release counted.** HTTP/2 handler slots: `Start_Handler` allocates the backend and task once per slot, `Handler_Finished` (`server-http_2.adb:926-931`) is called on every loop iteration after the application returns (the `when others` covers `Handle`), and `Reap` frees the backend only after `Can_Reap`. HTTP/3 listener slots: `Registry.Release (Slot)` runs after `Serve_Connection` on both the normal and the caught-exception path (`server-http_3.adb:2012-2040`) and in the listener when `Try_Send` fails on a `Starts` message (`:2103-2111`); `Connection_Registry.Release` cannot raise. `Close_Inboxes` runs on both exits of `Serve_Listener` (`:2120-2124`), so the procedure's master can join the `Workers` allocator. Ingress reservations: `Reserve_Buffered` releases before reserving, `Resize_Buffered` nulls the budget at zero, and `Connection.Finalize` releases; the `Configure_Ingress_Budget` contract (`server.ads:463-465`) makes the budget's lifetime the caller's obligation. SSE/WebSocket reservation guards: each `Guard` shares a declarative part with the `Queued`/`Value` objects its `Unchecked_Access` points at (`sse_handlers.adb:112-200`, `websocket_handlers.adb:280-440`), and the `Moved` check keeps the reservation with whichever side owns the buffer after `Send_Move`. Bulkhead permits: `Acquire` only takes over a slot whose `Active = 0`, so a held `Guard` cannot lose its slot.
- **Router generations.** `Commit` links each candidate to the current head and `Router.Finalize` walks that chain; `Snapshot` drops a reference only; `Reclaim` frees superseded generations under a documented, explicitly unchecked precondition (`routing.ads:797-804`), which is a contract rather than a defect.
- **Cancellation and deadlines in both lanes.** The HTTP/2 `Handler_Task` is pinned to `Flyology.Lightweight_Task`; the HTTP/3 `Worker` and `Task_Scopes` workers take their lane from the formal or are lightweight. The only `select`/`delay` uses in `src/` are the selective accept in `Handler_Task`, the timed entry call in `Client.Shutdown`, and the 1 ms `'Terminated` poll in HTTP/2 `Serve`; `Bounded_Channels.Send_For` (used by SSE/WebSocket `Publish_For`) is an ordinary timed entry call the runtime suspends cooperatively for lightweight callers (`flyology-bounded_channels.ads:24-25`). Cancellation reaches HTTP/2 stream handlers through `Backend.Token.Request` before the `Shutdown` entry call, and reaches `Task_Scopes` children through the linked scope token. I found no path where a cancellation or deadline is observed in one lane and not the other.
- **`App_Context` sharing (the prior audit's open question).** The library never writes to it: `rg -n 'Context\.[A-Za-z_]+\s*:='` over `src/` finds nothing; middleware keeps mutable state in package-level protected objects (`middleware_bulkheads.adb:138`). It is shared by reference across HTTP/1 connection tasks, HTTP/2 stream handlers and HTTP/3 workers (`routing.adb:2519-2523` stores `Context'Unchecked_Access`; `Handle (Context, X)` at `server-http_2.adb:2113`), and the obligation is stated: `middleware_request_ids.ads:15` "Mutable Context state must be task-safe", with `routing.ads:19` and `server-http_2.ads:8` saying "shared". Race-freedom of application mutation is therefore an application contract, not a library defect.
- **Test-hook elision, the sharper question.** All six hook sites in `src/` (`client.adb:3335,3426,3482,3805,3809,3828`; `client-http_1_internals.adb:83`) are guarded by `if Connection_Test_Hooks.Enabled`, and both selections declare the same three subprograms, so no site exists in only one selection. In the enabled selection with no barrier armed and no receive cap set, `Barrier` returns immediately, `Receive_Limit` returns `Requested` (`connection_test_hooks.c:49-54`), and `Receive_Observed` only counts, so the sole behavioural difference is the hooks firing when a test arms them. A production (disabled) build cannot reach a hook: `Enabled` is a literal `False`, and the disabled bodies are `Import`ed sentinels whose survival the script rejects via `nm -u` in strict `-O0` and every `-O` level, in both directions (real symbols must survive in the enabled archive). The script also rejects `-gnateD` and `#if` reappearing. What it does not check is behavioural, and I found nothing behavioural to check.
- **`compile_fail` harness.** Each case must both fail to compile and fail with the pinned diagnostic (`grep -E` under `set -e`), so a case that stops compiling for an unrelated reason fails the suite. The three cases match the three claims they pin (see LIFETIME-3 for the two claims without a case).
- **`Development_Certificates` ownership.** `Generate` discards first, sets the paths only after creating the directory, and on any exception frees the OpenSSL path and discards again; `Finalize` swallows; `Discard` is idempotent; `Read_File` closes on the exception path; the PKCS#8 tail check (`04 20` + 32 bytes, RFC 8410 §7) is correct for OpenSSL's Ed25519 DER.
- **`Server.TLS.Connection_Transport`.** A borrowing adapter with the borrow as a `not null access` discriminant and a stated lifetime rule (`tls.ads:8-9`); it forwards `Timeout` and `Token` to `Flyology.IO.TLS.Receive`/`Send_All` unchanged. Nothing to own, nothing to leak.
- **Prior audit regressions.** Finding 10's fix (`Wait_Source` using `Has_Capacity`, `pool_controller.adb:606-626`) and finding 12's release paths are present at f078732.

## Observations not counted

- **HTTP/2 `Serve` teardown waits unboundedly for a handler that ignores cancellation** (`server-http_2.adb:2785-2796`): `Handlers (Slot).Shutdown` is an entry call the handler accepts only after the application returns; cancellation is delivered via `Backend.Token.Request` first, and the comment says so. This is the structured-concurrency design; an application that blocks without observing its token holds the connection task. If `Applications.Internals.Create` or the `Backend` rename ever raised in the task's declarative part, the task would die without `Handler_Finished`, and the unguarded `Shutdown` call would raise `Tasking_Error` out of `Serve`, skipping `Free_Handler`/`Free_Backend` for later slots. I found no trigger (`Create` is field assignment; only `Storage_Error`), so it is recorded here rather than as a finding.
- **`Exchange_Operation.Finalize` deliberately leaks `Exchange_State` when a pool lease is unresolved after two release attempts** (`client.adb:1921-1937`, "Never erase an unresolved pool lease"). This is a chosen leak over a use-after-free; the only way to reach it is a `Creation_Failed`/`Unregister_Waiter`/`Release_Lease` raise that `Save` swallowed, which needs a pool-state invariant already broken.
- **`Close_And_Finish`** (`client.adb:2072-2091`) calls `Dispose_Connection` before `Finish_Close`; `Dispose_Connection` guards socket work but not `H2_Connections.Destroy` or the deallocations. A raise there leaves the slot `Closing` forever. Same reachability caveat as LIFETIME-4.
- **`Resume_Response_To_Sink`** (`client.adb:1652-1656`) nulls `Reply.Data` before the record copy into `Operation.State.Metadata`; a `Storage_Error` in that copy drops the lease and the retain. Not reachable on valid input.
- **`Stop_Task` handlers in the unified `Serve` variants** (`routing.adb:2562-2569`, `2841-2848`) call `Request_Stop` (token only) and not `TCP_Servers.Request_Shutdown`; `TCP_Servers.Serve` takes no token, so a raise from `Token.Await_Request` (a protected entry, so not in practice) would leave the TCP task running.
- **`Request_Tasks.Configure` inherits only the deadline; token inheritance is the caller's `Parent` discriminant.** Covered under LIFETIME-3; noted here because a `Parent = X.Cancellation` check would be one line.
- **Barrier point numbering is duplicated by hand.** `src/` calls `Barrier (16)`, `(15)`, `(2)`, `(3)` as literals; the meanings live in `tests/flyology-io-connections-testing.ads` (`Barrier_Point'Pos`) and `barrier_count = 17` in `tests/native/connection_test_hooks.c`. `Barrier (3)` (`Active_Operation_Park`) is reused for the HTTP client receive site; reordering the enum silently retargets a test. Test-only.
- **`Development_Certificates.Generate`'s `@exception` lists only `Program_Error`** while `Ada.Directories.Create_Directory`/`Delete_Tree`, `Ada.Text_IO.Create` and `Read_File` can raise `Use_Error`, `Name_Error`, `Constraint_Error` and `End_Error`. The repository's `@exception` tags elsewhere are not exhaustive either (`client.ads:124,194,210,248` list only the validation `Constraint_Error`), so this is documentation style, not a contract I can call violated. Also: the exception handler in `Generate` calls `Discard`, which can itself raise and replace the original occurrence.
- **Generated private keys are written with the process umask into a directory created with default permissions** (`development_certificates.adb:178,249-302`; GNAT's `Create_Directory` uses mode 0777 & ~umask, OpenSSL's `-out` respects umask). On macOS `$TMPDIR` is per-user; on Linux `/tmp` is shared, so another local user can read the one-day localhost key. The package states it is for local development and "does not provide or replace production certificate management", so this is outside the rubric; a `umask 077`-equivalent or `chmod 600` after generation would close it.
- **The `App_Context` task-safety obligation is stated in one middleware spec** (`middleware_request_ids.ads:15`) and not in `routing.ads`, `server-http_2.ads` or `server-http_3.ads`, which say only "shared". Documentation placement, not a defect.
- **`Router.Reclaim`** is a use-after-free by contract with an unchecked precondition (`routing.ads:797-804`); a snapshot count would make it checkable. Design suggestion.
- **Policy values seen and not questioned:** `Maximum_Concurrent_Streams = 32`, HTTP/3 inbox capacity 32, `Worker'Storage_Size = 4 MiB`, `Max_Route_Length = 128`, the 50 ms `Send_For` slice in `Publish_For`, the 1 ms `'Terminated` poll, the 2 s barrier wait in `Wait_Reached`, and the development certificate's 1-day validity.
