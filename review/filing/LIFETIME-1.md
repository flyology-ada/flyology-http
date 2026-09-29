Title: Finalizing an unread HTTP/3 `Response` never releases its stream, so its transport is drained rather than closed
Labels: bug
Refs: CLIENT-POOL-8

## Summary

`Abandon_Response`'s HTTP/3 branch sets `Reusable := False` and does nothing else. The two sibling teardown paths both release the stream first. The specification says finalizing an incomplete HTTP/3 response "closes its transport"; when another HTTP/3 exchange is live on the same connection the transport is drained instead, and the abandoned stream is neither cancelled nor released inside it, so its slot stays occupied until the last sibling finishes and the whole session is disposed. This is contract drift and nothing more: the peer sees identical bytes either way, the leaked slot cannot stall a connection, and no public API reports a difference. Three of the four consequences originally suspected of this omission do not hold, and they are set out below so the fix is not oversold.

## Problem

Commit `f078732`. This is reported from reading the code; no reproduction was made, and none is constructible, which is itself the strongest evidence for how small this is. The reason is set out under "Why no reproduction was made" below.

The branch (`src/flyology-http-client.adb:2151-2170`):

```ada
   procedure Abandon_Response (Data : in out Response_Data) is
      Reusable : Boolean := False;
   begin
      if Data.Connection = null then
         return;
      elsif Data.Engine = HTTP_2_Response then
         ...
      elsif Data.Engine = HTTP_3_Response then
         Reusable := False;
      end if;
      Release_Lease
        (Data, Reusable => Data.Engine = HTTP_2_Response and then Reusable);
   end Abandon_Response;
```

The contract it does not satisfy (`src/flyology-http-client.ads:485-490`):

```ada
   --  Limited response owning one exchange lease until its body is consumed.
   --  Reading the complete body returns an HTTP/1.1 or HTTP/3 transport lease
   --  or an HTTP/2 stream lease to the pool. Finalizing an incomplete HTTP/1.1
   --  or HTTP/3 response closes its transport; finalizing an incomplete
   --  HTTP/2 response resets only its stream when the multiplexed transport
   --  remains usable.
```

Both sibling teardown paths do release the stream.

- `Release_Exchange_Transport`'s HTTP/3 branch (`src/flyology-http-client.adb:762-801`) calls `Release_Pump` when the exchange owns it, `Cancel_Stream` when `not State.HTTP_3_Finished`, then `Release_Stream`, each in its own handler.
- Normal body completion (`src/flyology-http-client-http_3_internals.adb:442-449`) calls `Release_Stream` and then `Release_Lease`.

And the `Response` really is the sole holder of the stream handle by then. Two corrections to how this has been described before, because they change which `Response` objects can reach the branch at all:

- The transfer is in `Finish_Response_Head` (`src/flyology-http-client.adb:1123-1207`, allocation at `:1167`), not in `Finish_Success`.
- `Finish_Success` (`src/flyology-http-client.adb:1098-1121`) builds a `Response_Data` with `Complete := True` and calls `Release_Exchange_Transport` itself, never setting `Connection`. A `Response` from that path holds no lease, so `Abandon_Response` returns at its first line and never reaches the HTTP/3 branch.

Only the `Response_Head_Target` path produces a `Response` that can reach it, which is what every `Execute` overload uses (`src/flyology-http-client.adb:6726` through `Execute_Redirects` at `:6596` to `Execute_Operation_Once`, which starts the exchange with `Target => Response_Head_Target` at `:6487-6497`).

### What is wrong, precisely

With no sibling exchange on the connection, the contract holds: `Return_Lease` finds `Active_Streams` at zero, the slot goes to `Closing`, and the connection is disposed. With a sibling live, the slot becomes `Draining` (`src/flyology-http-client-pool_controller.adb:396-409`) and the connection stays open for that sibling, which is correct pool behaviour. What is wrong is that the abandoned stream is left inside it: its `H3_Connections` slot keeps `Phase /= Free`, its receive ring, its wake and its credit bookkeeping, for the rest of the connection's life. The transport is drained, not closed, and the specification sentence says closed.

### Three consequences that do not hold

- **The peer is not signalled either way.** `H3_Connections.Cancel_Stream` is purely local bookkeeping (`src/flyology-http-http_3_client_connection.adb:582-592`):

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

  It writes nothing to the wire. The only client-side site that emits a QUIC stream abort is `H3.Cancel_Request` in the `HTTP_3_Cancel_Request` driver stage (`src/flyology-http-client.adb:5232-5246`), reached only from `Fail_Exchange` (`:1086`) and the request-incomplete path (`:3963`), that is, only while the *exchange* is alive. No `Response` finalization on any engine reaches it. So the composable path that this branch is being compared against is equally silent toward the server, and there is no RFC 9114 angle here: the server keeps sending the unwanted body in exactly the same way after `Release_Exchange_Transport`.
- **The leaked slot cannot stall a connection.** `Abandon_Response` forces `Reusable => False` for HTTP/3, so `Return_Lease` moves the `Shared` slot to `Draining` on the first abandonment. `Try_Checkout` offers only `Phase = Shared` (`src/flyology-http-client-pool_controller.adb:113-120`) and `Phase = Idle` (`:156-163`), so a `Draining` slot is never handed out again and no later exchange can need the leaked slot. Leaked slots therefore cannot accumulate toward the connection's concurrent-stream bound. The abandoned `Response` also holds no pump: `Finish_Response_Head` releases it before the transfer (`src/flyology-http-client.adb:1155-1165`).
- **The unread bytes do not pin connection-level credit.** The QUIC layer consumes each DATA frame when it is decoded, before it is copied to an owner, so credit keeps flowing whether or not anyone reads. When the abandoned slot's receive ring is exceeded its phase simply becomes `Failed` and copying stops, and nothing propagates to the sibling.

### Why no reproduction was made

A reproduction must assert the correct behaviour and flip from failing to passing once the defect is fixed. The fix here is one `Release_Stream` call, and nothing observable through any public API changes when it lands: the pool returns to the same state either way because the slot is already `Draining`; `Client_Diagnostics` (`src/flyology-http-client.ads:165-169`) reports exchanges and reusable transports, neither of which counts HTTP/3 stream slots; the peer sees identical bytes, per the first point above; and `Flyology.HTTP.HTTP_3_Client_Connection` is a private package whose live session lives in the body of `Flyology.HTTP.Client`, so no child unit can inspect it either. A program that watched the server keep streaming would observe something real and would still fail after the fix. The absence is recorded instead.

Why the tests do not catch it: `tests/http3_client_composable_smoke.adb:655-687` deliberately abandons an HTTP/3 exchange ("Deliberately omit Finish. Finalization must drain before returning the detached token to its pool", `:675-676`), but it abandons an `Exchange_Operation`, which finalizes through `Release_Exchange_Transport` and does release the stream. No test drops an unread `Response` returned by `Execute` over HTTP/3.

## Failure scenario

1. An application configures an HTTP/3 client and issues two `Execute` calls that share one connection, the second admitted while the first response body is still pending.
2. It drops the first `Response` without reading the body, so `Response.Finalize` calls `Abandon_Response`.
3. The HTTP/3 branch sets `Reusable := False` and calls `Release_Lease`. No `Release_Pump`, no `Cancel_Stream`, no `Release_Stream`.
4. The slot becomes `Draining` and the connection stays open for the sibling. Inside it, the abandoned stream's slot keeps its phase, its receive ring and its bookkeeping until the sibling completes and `Close_And_Finish` disposes the whole session.
5. Between steps 3 and 4 the specification sentence at `src/flyology-http-client.ads:485-490` is false: the transport is not closed, and the stream inside it is not released.

## What should happen

Finalizing an incomplete HTTP/3 `Response` releases its stream inside the connection, so that the state the specification describes is reached whether or not a sibling exchange keeps the transport alive.

## Suggested treatment

Give the `HTTP_3_Response` branch of `Abandon_Response` (`src/flyology-http-client.adb:2165-2166`) the same guarded `Release_Pump`, `Cancel_Stream`, `Release_Stream` sequence that `Release_Exchange_Transport` uses at `:762-801`, each call in its own `exception when others` block so the lease is always returned afterwards. It is safe to release there: `Publish` already ignores events for a released stream, and says so in place at `src/flyology-http-http_3_client_connection.adb:292-293`, "A late event for a released stream is stream-local and does not poison concurrent exchanges". The fix needs no task and no new state, which matters because `scripts/test.sh:75-84` requires the client units to declare no helper task.

Making the same three calls guarded in the HTTP/2 branch of this procedure is the separate fix {{ISSUE:CLIENT-POOL-8}} asks for, and both branches should end up written the same way.

If the maintainer prefers to leave the code as it is, the alternative is to amend `src/flyology-http-client.ads:485-490` to say that an abandoned HTTP/3 response drains rather than closes a transport that still carries other exchanges. That is a specification change rather than a fix, and it would leave the stream slot occupied.

No regression test is proposed, for the reason given above: no public API distinguishes the fixed state from the current one, so a test placed in `tests/http3_client_composable_smoke.adb` beside the existing abandonment case at `:655-687` would have to assert something that is true before and after the change. If the maintainer wants the property pinned, the honest way is a check inside `Flyology.HTTP.Client`'s own body rather than a behavioural test.

The fix is confined to `src/flyology-http-client.adb`, which `./scripts/prove.sh` does not prove.

## Severity

The specification sentence about closing the transport is false for the duration of one connection when an unread HTTP/3 response is dropped while a sibling exchange is live. Nothing a caller or a peer can observe differs: the server is not signalled either way, the drained slot is never re-offered so it cannot exhaust the connection's stream budget, and no diagnostic counts it. It needs two overlapping HTTP/3 exchanges with one dropped unread, which is an unusual shape. Not reproduced; HTTP/3 only.
