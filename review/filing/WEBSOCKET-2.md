Title: Close drains the peer close under the default 1 MiB bound and raises an exception its contract omits
Labels: bug
Refs: none

## Summary

`Close` sends its masked Close frame and then drains the peer's reply by calling `Receive` without `Max_Message`, so the drain runs under `Default_Max_Message` whatever bound the application has been using. A data message the application already permits, but larger than 1 MiB, that crossed the Close on the wire makes the inner `Receive` raise `Message_Too_Large`, drop the transport, and propagate an exception that `Close`'s contract does not list. The close handshake the client started is abandoned, `Close_Code` then raises `Program_Error`, and the peer's own send fails because the socket is gone.

## Problem

Commit `f078732`.

The drain calls `Receive` with no bound (`src/flyology-http-websocket_client.adb:1372-1374`):

```ada
            Receive
              (Item, Kind, Data, Closed_Result,
               Timeout => Remaining (Started, Timeout), Token => Token);
```

so `Maximum` is the parameter default (`src/flyology-http-websocket_client.ads:16-17`):

```ada
   --  Default application receive bound: one MiB after reassembly.
   Default_Max_Message : constant := 1_024 * 1_024;
```

and a larger message is rejected (`src/flyology-http-websocket_client.adb:1232-1233`):

```ada
                     when Policy.Reject_Message_Too_Large =>
                        raise Message_Too_Large;
```

after which the transport is dropped and the exception leaves `Close` (`src/flyology-http-websocket_client.adb:1315-1317`):

```ada
      when Message_Too_Large | Protocol_Error =>
         Drop_Transport (Item);
         raise;
```

Two contracts are violated. `Receive` names both exceptions the drain can raise (`src/flyology-http-websocket_client.ads:272-278`):

```ada
   --  @exception Message_Too_Large Message exceeds Max_Message
   --  @exception Program_Error Item is not active
   --  @exception Constraint_Error Max_Message exceeds Max_Frame_Length
   --  @exception Connection_Error Control-frame masking entropy is unavailable
   --  @exception Protocol_Error Peer framing or content is invalid
   --  @exception Flyology.IO.Timeout_Error Deadline expires
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
```

while `Close`, fourteen lines further down and calling `Receive` itself, names neither (`src/flyology-http-websocket_client.ads:310-314`):

```ada
   --  @exception Program_Error Item is not active
   --  @exception Constraint_Error Code or Reason is invalid
   --  @exception Connection_Error Masking entropy is unavailable
   --  @exception Flyology.IO.Timeout_Error Deadline expires
   --  @exception Flyology.Cancellation.Operation_Cancelled Token is requested
```

The guide makes the same promise in prose (`website/guide/client/index.html:443`): `Close` "sends a validated masked status and waits for the peer close. It discards complete data messages that crossed the close before the peer observed it." It discards them only while they are under 1 MiB.

RFC 6455 section 5.5.1 and section 7.1.1 make the endpoint that sent a Close wait for the peer's Close before closing the connection, which is exactly what the abandoned drain gives up.

The server engine solved the same problem by retaining the bound the application last used (`src/flyology-http-server.adb:4811-4817`). The client keeps no such state and `Close` has no `Max_Message` parameter a caller could use instead.

The existing coverage crosses only a small message past a close (`tests/websocket_client_smoke.adb:788-793`):

```ada
      --  Data already queued before the peer observes our Close is discarded
      --  while the client continues the closing handshake.
      WS.Connect (Client, Request, Timeout => 5.0);
      WS.Close (Client, Timeout => 5.0);
      pragma Assert (WS.Close_Code (Client) = 1_000);
      pragma Assert (WS.Close_Reason (Client) = "queued");
```

## What happens now

Spike: a raw loopback peer completes the opening handshake by hand, sends a small text message, then a binary message of 1 MiB plus one byte, and finally watches for the client's Close frame. The application consumes the small message with its own bound, `Max_Message => 2 * 1_024 * 1_024`, and then calls `Close`.

```ada
   Big_Length : constant := 1_024 * 1_024 + 1;
   ...
      Sockets.Send_All
        (Peer, (16#81#, 16#02#, 16#68#, 16#69#), Timeout => 5.0);
      Sockets.Send_All
        (Peer,
         (16#82#, 16#7F#, 0, 0, 0, 0, 0, 16#10#, 0, 1),
         Timeout => 10.0);
   ...
      WS.Receive
        (Client, Kind, Data, Closed,
         Max_Message => 2 * 1_024 * 1_024, Timeout => 10.0);
      ...
      WS.Close (Client, Timeout => 20.0);
```

```
  ok   the upgrade completes
  ok   the first message is delivered under the application's bound
  note Close raised FLYOLOGY.HTTP.WEBSOCKET_CLIENT.MESSAGE_TOO_LARGE: flyology-http-websocket_client.adb:1233
  FAIL Close completes the handshake it started instead of raising an exception its contract does not list
  note Close_Code raised PROGRAM_ERROR
  note Close_Code =-1
  FAIL the peer close status is available after Close
  note peer saw the client Close frame = FALSE
  note raw peer note: raised FLYOLOGY.IO.SOCKETS.SOCKET_ERROR : send failed [errno=32]
checks: 4  failures: 2
BUG REPRODUCED
```

The traceback names `src/flyology-http-websocket_client.adb:1233`, the `Message_Too_Large` raise. `Close_Code` then raises `Program_Error` because no peer close was ever received, so the application cannot learn how the session ended. The `errno=32` line is the peer's view: it was still writing the payload when the client dropped the socket, so its send failed with `EPIPE` and it never read the Close frame the client had already written. The handshake is abandoned on both sides.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

`Close` should discard a complete data message that crossed the close and keep waiting for the peer Close, as `website/guide/client/index.html:443` states and as RFC 6455 section 7.1.1 requires of the endpoint that sent the Close, for any message the application's own bound permits. Whatever exceptions the drain can still raise should appear in `Close`'s `@exception` list.

## Suggested treatment

This needs a maintainer decision: the bound the drain uses is part of the public interface and there are two shapes.

`Close` can take a `Max_Message` parameter, defaulting as `Receive` does, and pass it to the drain. That is an explicit caller parameter and keeps the `Client` record stateless, at the cost of one more argument on the close path and of callers having to repeat the bound they used.

Alternatively the `Client` record can retain the bound of the last `Receive`, and the drain can use it, which is what the server engine does at `src/flyology-http-server.adb:4811-4817`. That needs no interface change and no caller cooperation, at the cost of a retained value whose lifetime the specification must describe.

The options are the ordinary ones: a caller parameter on `Close`, a retained value private to the body, a discriminant on `Client`, a value derived from an existing contract, build-time configuration, or a deliberately public constant. This report does not choose.

Independently of that choice, `Close`'s `@exception` list at `src/flyology-http-websocket_client.ads:310-314` should name `Message_Too_Large` and `Protocol_Error`, both of which the inner `Receive` can raise today and one of which will remain reachable whichever bound the drain uses.

The regression test belongs in `tests/websocket_client_smoke.adb`, beside the crossed-message case at `:788-793`: make the fake server send a message above `Default_Max_Message` before its close echo, have the application receive with a larger `Max_Message` first, and assert that `Close` returns and `Close_Code` is available. The spike is the test.

## Severity

An application that raises its receive bound above the default, which is the documented way to accept larger messages, gets a close handshake that fails whenever a message it has already permitted crosses the close. The exception it sees is not in `Close`'s contract, so a caller following the specification does not handle it; afterwards `Close_Code` and `Close_Reason` raise `Program_Error`, so the session's outcome is unavailable, and the peer sees an abnormal closure and a failed send rather than the close echo it was waiting for. The trigger needs no malicious peer, only a large message in flight when the application decides to close. Deterministic.
