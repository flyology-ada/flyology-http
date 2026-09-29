Title: The client control-frame bound is scoped to one Receive call, so keepalive pings end a healthy session
Labels: bug
Refs: none

## Summary

`Receive` counts control frames in a local variable and fails the connection after 32 of them. The counter is reset only by returning, and the only supported way to wait indefinitely for a message is to stay inside one `Receive` with a negative timeout, so every Ping and Pong a peer sends during that wait accumulates. A server that pings as a keepalive, which RFC 6455 explicitly allows, kills the session on the 33rd ping with `Protocol_Error` and a dropped transport. The server engine uses the identical bound and resets it per message and per idle interval, so only the client is affected.

## Problem

Commit `f078732`.

The bound (`src/flyology-http-websocket_client.adb:32`):

```ada
   Max_Control_Frames  : constant Positive := 32;
```

The counter is a local of `Receive` (`src/flyology-http-websocket_client.adb:1200`):

```ada
      Control_Count : Natural := 0;
```

and the check fails the connection (`src/flyology-http-websocket_client.adb:1252-1257`):

```ada
            else
               Control_Count := Control_Count + 1;
               if Control_Count > Max_Control_Frames then
                  raise Protocol_Error with
                    "too many WebSocket control frames";
               end if;
```

with the handler dropping the socket (`src/flyology-http-websocket_client.adb:1315-1317`):

```ada
      when Message_Too_Large | Protocol_Error =>
         Drop_Transport (Item);
         raise;
```

Nothing resets the counter inside a call, and staying inside one call is the documented way to wait. `Receive` states that leaving it is destructive (`src/flyology-http-websocket_client.ads:263-264`):

```ada
   --  Timeout or cancellation terminates the session because a partially
   --  consumed frame cannot be exposed as a resumable application value.
```

and an unbounded wait is expressed by a negative timeout (`src/flyology-http-websocket_client.adb:39-48`):

```ada
   function Remaining
     (Started : Ada.Real_Time.Time; Timeout : Duration) return Duration is
   begin
      if Timeout < 0.0 then
         return Flyology.IO.Infinite;
      end if;
```

So an application waiting for an infrequent event has exactly one supported option, and it is the option under which the counter never resets.

The server engine shows the intended discipline. It uses the same bound (`src/flyology-http-server.adb:4577`, `:4591`) but clears the counter at the end of every message (`src/flyology-http-server.adb:4302`):

```ada
         Item.WebSocket_Control_Count := 0;
```

and again on every idle receive quantum when nothing is buffered and no message is in progress (`src/flyology-http-server.adb:4611-4621`):

```ada
         elsif Length (Item.Pending) = 0
           and then Flyology.Bytes.Length (Item.WebSocket_Message) = 0
           and then not Item.WebSocket_Fragmented
           and then Item.WebSocket_Frame.Phase =
             WebSocket_Policy.Awaiting_Header
         then
            Item.WebSocket_Receive_Active := False;
            Item.WebSocket_Message_Deadline := Ada.Real_Time.Time_Last;
            Item.WebSocket_Message_Limit := 0;
            Item.WebSocket_Control_Count := 0;
```

so the server bound fires only for more than 32 control frames inside one message with no idle gap. The guide records that a bound exists (`website/guide/client/index.html:441`, `Receive` "bounds control-frame churn"), which is a statement about churn inside a message rather than about total frames across an open-ended wait.

RFC 6455 section 5.5.2 permits what the peer is doing:

> "An endpoint MAY send a Ping frame any time after the connection is established and before the connection is closed."

> "NOTE: A Ping frame may serve either as a keepalive or as a means to verify that the remote endpoint is still responsive."

and requires the response that increments the counter:

> "Upon receipt of a Ping frame, an endpoint MUST send a Pong frame in response, unless it already received a Close frame."

Neither that section nor section 5.4 bounds how many control frames a peer may send.

No maintained test sends more than a handful. `tests/websocket_client_smoke.adb:339-346` interleaves exactly one ping into a fragmented message. The Autobahn baselines exercise the server, not the client.

## What happens now

Spike: a raw loopback peer completes the RFC 6455 opening handshake by hand, writes 33 unmasked Ping frames back to back and then one text frame, and counts the masked Pongs it receives. The application calls `Receive` once with `Timeout => -1.0`, the unbounded wait, and asserts that the text message is delivered and the session survives. The Pings are sent back to back because the bound has no time component, so the program reproduces in milliseconds what a keepalive reaches in a quarter of an hour.

```ada
   Ping_Count : constant := 33;
   ...
      for Index in 1 .. Ping_Count loop
         Sockets.Send_All (Peer, (16#89#, 16#00#), Timeout => 5.0);
      end loop;
      Sockets.Send_All
        (Peer,
         (16#81#, 16#05#, 16#68#, 16#65#, 16#6C#, 16#6C#, 16#6F#),
         Timeout => 5.0);
   ...
         WS.Receive (Client, Kind, Data, Closed, Timeout => -1.0);
```

```
  ok   the upgrade completes
  note Receive raised Protocol_Error: too many WebSocket control frames
  FAIL Receive delivers the text message after 33 keepalive Pings
  FAIL the session survives the keepalive Pings
  note pongs the peer observed = 32
checks: 3  failures: 2
BUG REPRODUCED
```

The client answers exactly 32 Pings with masked Pongs, raises on the 33rd, and drops the transport, so the text frame that follows is never delivered.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A peer that pings a healthy idle connection should not be able to end it. The control-frame bound should limit churn inside one message and inside one idle interval, as the server engine's does at `src/flyology-http-server.adb:4302` and `:4611-4621`, rather than accumulate across an unbounded wait.

## Suggested treatment

Give the client the reset discipline the server already has: clear `Control_Count` in `Receive` whenever a complete message is returned, and whenever the receive loop finds itself idle with no partial frame and no buffered bytes. That keeps the bound doing its job against a burst inside one message and removes the dependence on how long the caller has been waiting. It changes no public value.

An alternative is to replace the count with a rate, so that the bound is control frames per interval rather than per call. That introduces an interval. This needs a maintainer decision: the options are a private implementation value beside `Max_Control_Frames` at `src/flyology-http-websocket_client.adb:29-32`, a caller parameter on `Receive`, a generic formal, a value derived from the caller's `Timeout`, build-time configuration, or a deliberately public constant. This report does not choose. The reset discipline needs none of them, which is why it is the primary suggestion.

If the counting decision is moved into `Flyology.WebSocket_Client_Policy`, note that `./scripts/prove.sh` proves that unit and the change must keep the proof discharging with `--checks-as-errors=on`. The counter as it stands is production code outside any proved unit.

The regression test belongs in `tests/websocket_client_smoke.adb`, whose fake server already interleaves a ping at `:339-346`: extend it to write more than 32 control frames before a text frame and assert that `Receive` returns the message and `Is_Open` stays true. The spike is the test.

## Severity

An application that waits inside one `Receive` for an infrequent event, which is the only supported way to wait indefinitely, loses the session to valid peer behaviour and sees `Protocol_Error` with an abnormal closure. It needs no malicious peer and no unusual configuration: any server that pings a quiet connection reaches the bound eventually, and at a thirty second interval the 33rd ping falls between sixteen and sixteen and a half minutes. That ping interval is general knowledge and is not verified against a peer here; the defect does not depend on it, only the time to reach it does. Deterministic.
