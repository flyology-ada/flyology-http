Title: `Exchange_Operation.Finalize` frees a response-head `Reply_Data` without returning its lease or lifetime retention
Labels: bug
Refs: CLIENT-POOL-8

## Summary

`Exchange_Operation.Finalize` frees a non-null `Reply_Data` with a plain `Ada.Unchecked_Deallocation`. For a response-head exchange that record is the one `Finish_Response_Head` built, and it carries `Connection`, `Slot_Index` and `Retains_Owner => True`. `Finish_Response_Head` deliberately nulls the exchange's own aliases first, so the two `Release_Exchange_Transport` calls earlier in `Finalize` see nothing to release, and the record is discarded holding a live pool lease. The hole is in the code whose own comment two statements above says never to do this. The window is narrow: on every ordinary caller path `Finish` runs first, and the only route that is not itself a contract violation elsewhere is aborting the calling task.

## Problem

Commit `f078732`. This is reported from reading the code; no reproduction was made because the only route that is not a bug in the caller is `abort` of the task inside `Execute_Operation_Once`, and a program that has to abort a task to hit a two-statement window says nothing the code does not already say.

The statement (`src/flyology-http-client.adb:1926-1929`):

```ada
         Release_Exchange_Borrows (Item.State.all);
         if Item.State.Reply_Data /= null then
            Free_Response_Data (Item.State.Reply_Data);
         end if;
```

`Free_Response_Data` is a plain deallocation and nothing else (`src/flyology-http-client.adb:535-536`):

```ada
   procedure Free_Response_Data is new Ada.Unchecked_Deallocation
     (Response_Data, Response_Data_Access);
```

For a `Response_Head_Target` exchange the record it frees is the one `Finish_Response_Head` built, with a lifetime retention taken on it (`src/flyology-http-client.adb:1167-1175`):

```ada
      Candidate := new Response_Data'(State.Metadata);
      Candidate.Started := Ada.Real_Time.Clock;
      Candidate.Timeout := Remaining (State.Deadline);
      if not Candidate.Retains_Owner then
         Candidate.Owner.Lifetime.Retain_Response;
         Candidate.Retains_Owner := True;
      end if;
      State.Reply_Data := Candidate;
      Candidate := null;
```

and with the exchange's own aliases cleared immediately afterwards, on purpose (`src/flyology-http-client.adb:1177-1184`):

```ada
      --  Ownership is now exclusively in Reply_Data.  Clearing these aliases
      --  before Complete_Exchange prevents terminal borrow cleanup from
      --  returning or resetting the transferred stream.
      State.Connection := null;
      State.Slot_Index := 0;
      State.Creating := False;
      State.Metadata.Retains_Owner := False;
      State.Metadata := (others => <>);
```

So by the time `Finalize` runs, the two `Release_Exchange_Transport` calls at `:1915` and `:1923-1924` have nothing to release, and the lease lives only inside `Reply_Data`. The routine that knows how to retire such a record is `Response.Finalize` (`src/flyology-http-client.adb:7369-7404`), which calls `Abandon_Response` and then `Release_Response` before freeing. `Exchange_Operation.Finalize` calls neither.

This contradicts the stated purpose of the surrounding code (`src/flyology-http-client.adb:1921-1922`):

```ada
            --  Retry idempotent cleanup once after all operation children
            --  have been finalized. Never erase an unresolved pool lease.
```

Freeing a `Reply_Data` that still holds `Connection` and `Slot_Index` is erasing an unresolved pool lease.

### Reachability, narrowly

The discovery of this defect described it as reachable "through abort or an exception between terminal completion and `Finish`". Only the first half holds, and this issue is written to the narrower claim.

- **Synchronous.** `Execute_Operation_Once` runs `Wait_All (Set)`, then one field read, then `Finish`, which nulls `Reply_Data` (`src/flyology-http-client.adb:6504-6506` and `:1733-1734`). Nothing between those three statements can raise on a normal path. Only `abort` of the calling task, or `Wait_All` raising after the operation has already gone terminal, which would be an internal invariant failure, leaves `Reply_Data` set at finalization.
- **Composable.** `Exchange_To_Response` is declared in the *private* part of the specification (`src/flyology-http-client.ads:1322-1329`, after `private` at `:1226`) and is marked `@exclude` at `:1317`, so no ordinary application can call it; only child units can. `Flyology.HTTP.Client.SSE` is the one that does, and it always retires the child through `Finish_Exchange` (`src/flyology-http-client-sse.adb:709-722`, called at `:787` and `:823`). Abandoning a terminal operation without calling `Finish` is in any case a caller contract violation: the pinned `flyology` runtime dependency says at `flyology-operations.ads:236-237` that "Terminal operations are retained until their provider-specific Finish operation consumes them", and at `:252-253` that "Parent must call Child's provider-specific Finish and Release from that drive before continuing."

Abort is therefore the only route that is not itself a bug somewhere else. That is why this is worth fixing rather than urgent: `Finalize` is written as a safety net for exactly the abort case, and this is the one thing the net does not catch.

Why the tests do not catch it: `tests/http_client_pool_races.adb` does abort a response reader and then asserts the pool drained (`:378-399`, `Assert_Drained` at `:216-229`), but the abort lands while the body is being read, after `Finish` has already moved `Reply_Data` into the `Response`. No test aborts between `Wait_All` returning and `Finish` running.

## Failure scenario

1. An application calls `Execute`. The exchange completes the response head, so `Finish_Response_Head` transfers `Connection`, `Slot_Index` and the lifetime retention into `Reply_Data` and clears the exchange's aliases.
2. `Wait_All` returns. Before `Finish` runs at `src/flyology-http-client.adb:6506`, the calling task is aborted.
3. `Exchange_Operation.Finalize` runs. Both `Release_Exchange_Transport` calls find `Connection` and `Metadata.Connection` null and do nothing. `Free_Response_Data` discards the record.
4. The pool slot stays `Leased` and `Leased_Count` never decrements. `Await_Drained`'s barrier never opens, so `Client.Shutdown` raises `Timeout_Error`, and `Client_State` is never freed because the retained response count never reaches zero. The connection object and its socket are never disposed.

## What should happen

A `Reply_Data` still holding a pool lease is retired, not discarded: the lease is returned and the lifetime retention released before the record is freed, which is what `Response.Finalize` does for the same record at `src/flyology-http-client.adb:7369-7404` and what the comment at `:1921-1922` says this code must never fail to do.

## Suggested treatment

In `Exchange_Operation.Finalize`, retire a non-null `Reply_Data` through the same sequence `Response.Finalize` uses instead of `Free_Response_Data` alone: call `Abandon_Response` when `Reply_Data.Connection` is not null, release the lifetime retention when `Retains_Owner` is set, and only then free. Both routines already exist in the same body and neither needs new state. Guard the added calls with their own `when others => null` so that `Finalize` stays non-propagating, the way the existing `Flyology.Operations.Finalize` call at `:1908-1913` is guarded. {{ISSUE:CLIENT-POOL-8}} is the mirror defect in the routine being reused here, and fixing that one first keeps this fix from inheriting the same hole.

The fix needs no task, which matters because `scripts/test.sh:75-84` requires the client units to declare no helper task. It is confined to `src/flyology-http-client.adb`, which `./scripts/prove.sh` does not prove.

The regression test belongs in `tests/http_client_pool_races.adb`, beside the existing aborted-reader case at `:378-399`, and should assert `Assert_Drained` and a completing `Shutdown` after an `Execute` aborted at the head-completion boundary. Reaching that boundary deterministically needs a barrier point between `Wait_All` and `Finish` in `Execute_Operation_Once`, which does not exist today. This needs a maintainer decision: adding one means a new enumeral in `Flyology.IO.Connections.Testing.Barrier_Point` (`tests/flyology-io-connections-testing.ads:3-19`), whose positions are matched numerically by `Connection_Test_Hooks.Barrier (16)` at `src/flyology-http-client.adb:3336`, so the options are to append the new point at the end of the enumeration, to renumber and update every numeric `Barrier` call, or to accept that this one is closed by inspection and add no test.

## Severity

If it is reached, the effect is permanent for the process: one pool slot stays leased forever, `Client.Shutdown` raises `Timeout_Error` instead of completing, and the client state, the connection and its socket are never freed. Nothing is freed twice, so there is no use-after-free. It is not reachable on any ordinary caller path: `Finish` always runs first on the synchronous path, and the composable entry point is private to child units, all of which retire the child correctly. The one route that is not a caller bug is aborting the task in a two-statement window. Not reproduced.
