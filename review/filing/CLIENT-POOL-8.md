Title: `Response.Finalize` frees a lease record without returning the pool slot when `Abandon_Response` raises
Labels: bug
Refs: CLIENT-POOL-7

## Summary

`Response.Finalize` calls `Abandon_Response` and, if anything inside it raises, its `when others` handler releases the lifetime retention and then frees the `Response_Data` outright. The lease is not returned, so the pool slot stays `Leased` holding a `Pooled_Connection` pointer nothing will ever dispose, `Await_Drained`'s barrier never opens, and `Shutdown` hangs or raises `Timeout_Error`. The same failure has a second site: `Abandon_Response`'s own HTTP/2 branch runs three fallible calls unguarded before `Release_Lease`, where the sibling routine `Release_Exchange_Transport` wraps every one of the same calls in a handler so the lease is always returned. Each site can be fixed on its own and the second fix is the smaller one.

## Problem

Commit `f078732`. This is reported from reading the code; no reproduction was made and none is possible in-process today, because the handler runs only when `Abandon_Response` itself raises, which requires an `H2_Connections` or lease primitive to raise, and there is no fault-injection seam that can make one do so.

### Sites

**1. `Response.Finalize`'s handler frees the record without returning the lease** (`src/flyology-http-client.adb:7388-7403`):

```ada
   exception
      when others =>
         if Item.Data /= null and then Item.Data.Retains_Owner
           and then Owner /= null
         then
            Item.Data.Retains_Owner := False;
            begin
               Owner.Lifetime.Release_Response (Final_Reference);
            exception
               when others => null;
            end;
         end if;
         Free_Response_Data (Item.Data);
```

The handler releases the lifetime retention and never the lease.

Which raise actually leaves a lease outstanding is narrower than it looks. `Abandon_Response` returns immediately when `Data.Connection = null` (`src/flyology-http-client.adb:2154-2155`), and it otherwise ends in `Release_Lease`, which calls `Return_Lease` and then nulls `Data.Connection` (`:2141-2143`). So a raise from `Owner.Lifetime.Release_Response`, the statement after `Abandon_Response` in the normal path at `:7380-7382`, finds `Connection` already null and leaks nothing. The leak is specifically a raise inside `Abandon_Response` *before* `Release_Lease` completes: `H2_Connections.Is_Usable`, `Cancel_Stream` or `Release_Stream` raising on an HTTP/2 response, or `Return_Lease` raising its own `Program_Error`. Then `Item.Data.Connection` is still set when `Free_Response_Data` discards the record.

Nothing is freed twice, so there is no use-after-free. The slot, the connection object and its socket simply leak until the process exits.

**2. `Abandon_Response` runs the HTTP/2 teardown unguarded** (`src/flyology-http-client.adb:2156-2164`):

```ada
      elsif Data.Engine = HTTP_2_Response then
         Reusable := H2_Connections.Is_Usable (Data.Connection.HTTP_2.all);
         if Data.HTTP_2_Stream /= H2_Connections.No_Stream then
            H2_Connections.Cancel_Stream
              (Data.Connection.HTTP_2.all, Data.HTTP_2_Stream);
            H2_Connections.Release_Stream
              (Data.Connection.HTTP_2.all, Data.HTTP_2_Stream);
            Data.HTTP_2_Stream := H2_Connections.No_Stream;
         end if;
```

The asymmetry is deliberate elsewhere in the same body. `Release_Exchange_Transport` (`src/flyology-http-client.adb:694-801`) makes the same three calls and wraps each one, so a raise degrades reuse instead of skipping the release. Its `Cancel_Stream` and `Release_Stream` blocks (`:739-760`):

```ada
         if not State.HTTP_2_Finished then
            begin
               H2_Connections.Cancel_Stream
                 (State.Metadata.Connection.HTTP_2.all,
                  State.Metadata.HTTP_2_Stream);
               May_Reuse := False;
            exception
               when Error : others =>
                  May_Reuse := False;
                  Save (Error);
            end;
         end if;
         begin
            H2_Connections.Release_Stream
              (State.Metadata.Connection.HTTP_2.all,
               State.Metadata.HTTP_2_Stream);
            State.Metadata.HTTP_2_Stream := H2_Connections.No_Stream;
         exception
            when Error : others =>
               May_Reuse := False;
               Save (Error);
         end;
```

`Abandon_Response` wraps none of them, so any raise there skips `Release_Lease` entirely and hands control to site 1.

### What the trigger search found

Every call in the branch was traced and none of them is reachable on valid input:

- `H2_Connections.Is_Usable (Data.Connection.HTTP_2.all)`: a null `HTTP_2` would be `Constraint_Error`, but `Data.Connection` is nulled only by `Release_Lease`, and a connection whose lease is outstanding is never disposed, because `Take_Active_For_Interrupt` and `Finish_Interrupt` (`src/flyology-http-client-pool_controller.adb:543-597`) transfer disposal only after the holder has moved the slot to `Closing`.
- `H2_Connections.Cancel_Stream` (`src/flyology-http-http_2_client_connection.adb:2366-2373`) reaches the protected body at `:1625-1649`, whose only fallible statement is `Queue_Control_Frame` at `:1636` appending a RST_STREAM to an unbounded byte buffer, that is `Storage_Error` on heap exhaustion, and then `Drivers.Signal` on the outbound wake source, which can fail on pipe creation with EMFILE or ENFILE or raise `Program_Error` when the write fails with an errno other than EAGAIN or EINTR.
- `H2_Connections.Release_Stream` (`src/flyology-http-http_2_client_connection.adb:1651-1670`): its buffered-byte arithmetic could raise `Constraint_Error`, but only from an accounting invariant that is already broken.

Every one of these is heap or file-descriptor exhaustion, or an invariant already violated. Confidence in the code reading is high; confidence that it can be reached at all is low, which is why this is reported as a hole to close rather than a defect to reproduce.

Why the tests do not catch it: `tests/http2_client_integration.adb` covers ordinary HTTP/2 response abandonment, where nothing raises. No maintained test perturbs an `H2_Connections` primitive, and there is no seam that would let one.

## Failure scenario

1. An application drops an unread HTTP/2 `Response` while its lease is outstanding. `Response.Finalize` runs and calls `Abandon_Response` at `src/flyology-http-client.adb:7377-7378`.
2. `H2_Connections.Cancel_Stream` raises, for example because signalling the outbound wake source fails on a write errno other than EAGAIN or EINTR, or because appending the RST_STREAM exhausts the heap.
3. Nothing in `Abandon_Response` catches it, so `Release_Lease` never runs and `Data.Connection` is still set.
4. `Response.Finalize`'s handler releases the lifetime retention and frees the record. The pool slot stays `Leased` with a `Pooled_Connection` pointer no one holds any more.
5. `Await_Drained` never opens. `Client.Shutdown` without a timeout does not return, and with a timeout raises `Timeout_Error`. `Client_Control.Finalize` reaches `Interrupt_Active`, which finds the slot and closes the channel, but `Finish_Interrupt` sees a phase other than `Closing` and never disposes the connection, which then leaks when the pool is freed.

## What should happen

Finalizing a `Response` returns its pool lease, whether or not the protocol-level teardown succeeded. A failure to cancel or release an HTTP/2 stream makes the transport unreusable; it does not make the lease unreturnable.

## Suggested treatment

Two independent fixes, either of which closes the window. The second is smaller and does not touch the handler at all.

**Site 2, the smaller fix.** Wrap the three calls in `Abandon_Response`'s HTTP/2 branch (`src/flyology-http-client.adb:2156-2164`) in their own `exception when others` blocks that set `Reusable := False` and continue, exactly the way `Release_Exchange_Transport` wraps the same calls at `:725-760`. `Release_Lease` then always runs, the lease is always returned, and site 1 is never entered. This is local, needs no new state and no task, which matters because `scripts/test.sh:75-84` requires the client units to declare no helper task.

**Site 1, the defence in depth.** In `Response.Finalize`'s handler at `:7388-7403`, attempt the lease return again before `Free_Response_Data`, guarded by its own `when others => null`, so that a record still holding `Connection` is not discarded. This mirrors the doubled `Release_Exchange_Transport` that `Exchange_Operation.Finalize` already performs for the same reason at `:1915` and `:1923-1924`. {{ISSUE:CLIENT-POOL-7}} is the matching hole in that same finalizer and should be fixed together with this one, since both end in a `Response_Data` being freed while it still owns a lease.

Doing both is preferable: site 2 removes the trigger, site 1 keeps the invariant true if another raise is ever introduced.

The fix is confined to `src/flyology-http-client.adb`, which `./scripts/prove.sh` does not prove.

Verifying it needs a seam that does not exist. What would settle it is a fault-injection point in `H2_Connections.Cancel_Stream` or `Release_Stream`, then a case in `tests/http2_client_integration.adb` that finalizes a `Response` holding an HTTP/2 lease while that primitive raises, asserting that `Client.Diagnostics` returns `Active_Exchanges` to zero and that `Shutdown` completes. This needs a maintainer decision: such a seam is a new test-only control surface on `Flyology.HTTP.HTTP_2_Client_Connection`, and the options are a build-time-selected implementation like the existing connection test hooks in `flyology_http.gpr:7-20`, a generic formal on the session, a caller-supplied injection hook, or accepting that this one is closed by inspection and adding no test.

## Severity

If it is reached, one pool slot is lost for the life of the process, `Client.Shutdown` raises `Timeout_Error` instead of completing, and the connection and its socket are never disposed. Nothing is freed twice, so there is no use-after-free and no wrong bytes. Reaching it requires an `H2_Connections` primitive to raise, and every raise found in the three of them is heap exhaustion, file-descriptor exhaustion, or an invariant that is already violated, so this is not reachable on valid input through any path found. Not reproduced; HTTP/2 only.
