Title: Cancelling an HTTP/3 response leaks its send slot, so the 33rd cancellation silences the connection
Labels: bug
Refs: H3-QPACK-6

## Summary

`Build_Request_Cancellation` marks a send slot finished and cancelled but clears it only for the client role. On the server the slot stays occupied for the life of the connection, so `Send_Count` grows by one per cancelled response. After 32 cancellations `Add_Send` returns `Stream_Capacity_Exceeded` and no further response can be sent, while the QUIC connection stays open and simply stops answering.

## Problem

Commit `f078732`.

The cancellation path retires the local message state only for a client (`src/flyology-http-http_3_connection.adb:664-676`):

```ada
      Status := Send_Status_For (Sent);
      if Status = Succeeded then
         Item.Sending (Slot).Finished := True;
         Item.Sending (Slot).Cancelled := True;
         if Item.Local_Role = Client then
            --  A composable client owns the complete exchange lifecycle and
            --  has no later Release_Request call. Retire its local message
            --  state once RESET_STREAM/STOP_SENDING has been built. The
            --  server keeps request state until its normal Release_Request
            --  step.
            Abandon_Message (Item, Transport, Stream);
         end if;
      end if;
```

The server's "normal `Release_Request` step" does not recover the slot either. `Release_Message` guards its `Sending` cleanup on the same role test (`src/flyology-http-http_3_connection.adb:135-145`):

```ada
      if Item.Local_Role = Client then
         for Index in Slot_Index loop
            if Item.Sending (Index).Occupied
              and then Item.Sending (Index).ID = ID
            then
               Item.Sending (Index) := (others => <>);
               Item.Send_Count := Item.Send_Count - 1;
               exit;
            end if;
         end loop;
      end if;
```

The only other decrements of `Send_Count` are on the Fin-send paths in `Build_Headers`, `Build_Data`, `Build_Response` and `Build_Prepared_Responses`, none of which a cancelled stream takes. `Send_Count` is therefore monotonic across cancellations, and `Add_Send` refuses at the bound (`src/flyology-http-http_3_connection.adb:569-572`):

```ada
      elsif Item.Send_Count = Max_Streams then
         Status := Stream_Capacity_Exceeded;
         return;
      end if;
```

with `Max_Streams : constant := 32;` at `src/flyology-http-http_3_connection.ads:16`.

The reachable trigger is ordinary. A handler that starts a streaming response and returns without ending it is classified `Streaming_Response` and resolved with `X.Mark_Failed` (`src/flyology-http-server-http_3.adb:1584-1591`):

```ada
            if X.Response = Applications.Not_Started then
               X.No_Content;
            elsif X.Response in
              Applications.Streaming_Response | Applications.Streaming_SSE |
              Applications.Upgraded | Applications.Failed
            then
               X.Mark_Failed;
            end if;
```

and `Mark_Failed` calls `H3.Cancel_Request` (`src/flyology-http-server-http_3.adb:1402-1404`). The same route is taken when a handler raises after starting a stream, when a fixed length is overrun, and when the client stops reading so the transport wait times out.

`tests/http3_public_smoke.adb:187-190` cancels once per role and never inspects capacity afterwards, so no existing test observes the accumulation.

## What happens now

Spike: the program starts the real listener with a handler that begins a streaming response and returns without ending it, then issues 40 successive requests on one QUIC connection and counts the responses that arrive.

```ada
   procedure Handle (Application : in out Context; X : in out App.Exchange) is
   begin
      X.Begin_Stream (200, "text/plain");
      X.Write_Chunk ("partial");
   end Handle;
   ...
               H3.Open_Request (Session, Transport, Stream, H3_Status);
               H3.Append (Block, H3.Make_Field (":method", "GET"));
               H3.Append (Block, H3.Make_Field (":path", "/stream"));
               H3.Send_Headers
                 (Session, Transport, Stream, Block, Fin => True,
                  Now => Now, Packet => Packet, Status => H3_Status);
```

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  note responses received: 32 of 40; first unanswered attempt 33; transport state CONNECTED
  FAIL every one of 40 cancelled responses still reaches the client
checks: 3  failures: 1
BUG REPRODUCED
exit status 1
```

The count is exact and matches the mechanism with no slack: 32 responses arrive, the 33rd does not, and the transport is still `CONNECTED` afterwards, so the peer has no indication that anything is wrong. The muteness rather than a close is the behaviour {{ISSUE:H3-QPACK-6}} describes, compounding this defect.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A cancelled response must release its send slot in both roles. The send capacity is a per-connection concurrency bound, not a lifetime budget, so a connection that has cancelled any number of responses should still be able to send the next one.

## Suggested treatment

Release the send slot for the server role too. The narrow fix is to drop the `if Item.Local_Role = Client` guard in `Release_Message` at `src/flyology-http-http_3_connection.adb:135`, so the server's existing `Release_Request` step recovers the slot; the cancelled-stream path already reaches `Release_Message` through `Release_Request`. Clearing the slot in `Build_Request_Cancellation` for both roles is the alternative, but it removes the state a server still needs between the cancellation and its `Release_Request`, so the `Release_Message` side is the safer place.

`src/flyology-http-http_3_connection.adb` is not among the units `./scripts/prove.sh` proves, so no proof obligation changes. The regression test belongs in `tests/http3_public_smoke.adb`, beside the existing cancellation case at `:187-190`, which should be extended to cancel repeatedly and then assert that a further `Send_Headers` still succeeds; the spike above is the end-to-end form of the same test. No maintained test asserts the current behaviour.

## Severity

A server whose handlers ever fail, abandon a stream, or overrun a declared length stops answering that connection after 32 such events, with no close frame and no error visible to the peer. Every later request on the connection is lost until the 300-second age limit. A hostile client reaches the state deliberately by opening 32 requests and never reading the responses, so each times out. The handler shapes that trigger it, a raise after `Begin_Stream` or a return without `End_Stream`, are ordinary application mistakes rather than unusual calls. Deterministic.
