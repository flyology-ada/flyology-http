Title: The client closes the TCP connection with no Close frame on every protocol failure it detects
Labels: bug
Refs: none

## Summary

Every protocol failure the client detects while receiving is handled by closing the socket. No Close frame carrying 1002, 1007 or 1009 is ever written, so the peer observes an abnormal closure and cannot distinguish a detected protocol violation from a crash. RFC 6455 says an endpoint that has an established connection should send a Close frame with an appropriate status code before closing it, and the server engine in this repository does exactly that.

## Problem

Commit `f078732`.

The handler that catches every detected failure (`src/flyology-http-websocket_client.adb:1310-1321`):

```ada
   exception
      when Flyology.IO.Timeout_Error |
           Flyology.Cancellation.Operation_Cancelled =>
         Drop_Transport (Item);
         raise;
      when Message_Too_Large | Protocol_Error =>
         Drop_Transport (Item);
         raise;
      when others =>
         Drop_Transport (Item);
         raise;
   end Receive;
```

`Drop_Transport` closes the socket and nothing else (`src/flyology-http-websocket_client.adb:546-557`):

```ada
   procedure Drop_Transport (Item : in out Client) is
   begin
      if Connections.Is_Open (Item.Channel) then
         begin
            Connections.Close (Item.Channel);
         exception
            when others => null;
         end;
      end if;
      Item.Phase := Closed;
      Item.Pending := Null_Unbounded_String;
   end Drop_Transport;
```

Every detection reaches that handler: a masked server frame, reserved bits, a bad opcode, a non-canonical length, bad fragmentation, a malformed close, an oversized message, and invalid UTF-8 in text (`src/flyology-http-websocket_client.adb:1243-1248`):

```ada
               if Final then
                  if Message_Kind = Text_Message
                    and then not Valid_UTF8
                      (Flyology.Bytes.To_Byte_String (Data))
                  then
                     raise Protocol_Error with "invalid UTF-8 WebSocket text";
                  end if;
```

The server engine writes the status before going terminal (`src/flyology-http-server.adb:4243-4260`):

```ada
      procedure Fail (Code : Positive; Message : String) is
         Payload : constant String :=
           Character'Val (Code / 256) & Character'Val (Code mod 256);
      begin
         Item.State := Terminal;
         begin
            if not Item.WebSocket_Close_Sent
              and then (Timeout < 0.0 or else Time_Left > 0.0)
            then
               Send_Frame (Item, 8, Payload, Time_Left, Token);
               Item.WebSocket_Close_Sent := True;
            end if;
```

RFC 6455 section 7.1.7:

> "If _The WebSocket Connection is Established_ prior to the point where the endpoint is required to _Fail the WebSocket Connection_, the endpoint SHOULD send a Close frame with an appropriate status code (Section 7.4) before proceeding to _Close the WebSocket Connection_."

The same paragraph permits omitting the frame only when the endpoint "believes the other side is unlikely to be able to receive and process the Close frame, due to the nature of the error that led the WebSocket connection to fail in the first place". A TCP connection that is healthy apart from one bad payload byte is not that case, and section 7.4.1 assigns 1007 to exactly this failure.

The existing coverage asserts the exception and the closed session but never inspects what the peer received (`tests/websocket_client_smoke.adb:741-754`):

```ada
         begin
            WS.Receive (Client, Kind, Data, Closed, Timeout => 5.0);
         exception
            when Flyology.HTTP.Protocol_Error => Rejected := True;
         end;
         pragma Assert (Rejected and then not WS.Is_Open (Client));
```

`tests/websocket_client_tls_smoke.adb` does the same. The Autobahn baselines exercise the server role only; the client has never been run in Autobahn's client-under-test role, and it was not run in that role for this report either, so what follows rests on a raw peer rather than on a conformance harness.

## What happens now

Spike: a raw loopback peer completes the opening handshake by hand, sends `81 01 FF`, a text frame whose single payload byte cannot begin a UTF-8 sequence, and then reads until EOF looking for a masked Close frame and its status code.

```ada
      Sockets.Send_All (Peer, (16#81#, 16#01#, 16#FF#), Timeout => 5.0);
```

```
  ok   the upgrade completes
  note Receive raised Protocol_Error: invalid UTF-8 WebSocket text
  ok   the invalid UTF-8 text frame is detected
  ok   the session is no longer open
  note peer saw a Close frame = FALSE, status code =-1
  FAIL the client sends a Close frame before closing the connection
  FAIL the Close frame carries 1007 (invalid frame payload data)
checks: 5  failures: 2
BUG REPRODUCED
```

The client detects the violation correctly and raises the right exception. The peer reads to EOF and receives no frame at all: the first byte of a masked client Close would be `0x88` and nothing arrives.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

When the client fails an established connection because of something it detected in the peer's framing or content, it should write a masked Close frame carrying the status RFC 6455 section 7.4.1 assigns to that failure, then close the transport, as the server engine does in `Fail` at `src/flyology-http-server.adb:4243-4260`.

## Suggested treatment

Send the Close before `Drop_Transport` in the `Message_Too_Large | Protocol_Error` arm at `src/flyology-http-websocket_client.adb:1315-1317`, guarded so it runs only while the session is still open and never after a Close has already been sent, and swallowing any write failure the way the server's `Fail` does. The status follows RFC 6455 section 7.4.1: 1002 for framing and protocol violations, 1007 for invalid UTF-8 in text or in a close reason, 1009 for a message above the bound. `Policy.Valid_Close_Code` already gates the codes the client may put on the wire, so no new classification is introduced. The timeout and cancellation arm at `:1311-1314` should keep dropping without a frame, since the caller has just abandoned the operation.

This needs a maintainer decision: the failure Close needs a write deadline, and the deadline is a policy value. The natural derivation is the time still remaining on the `Receive` call that detected the failure, which is already in scope through `Remaining (Started, Timeout)` at `src/flyology-http-websocket_client.adb:39-48`, and which makes an unbounded `Receive` write the frame with no deadline. The alternatives are a private implementation value in the body beside the other bounds at `:29-32`, a parameter on `Receive`, build-time configuration, or a deliberately public constant. This report does not choose.

The regression test belongs in `tests/websocket_client_smoke.adb` beside the framing-rejection cases at `:741-754`, extended so the fake server reads what the client sent after the violation and asserts the Close frame and its status code. The spike is the test. Running the maintained Autobahn configuration in the client-under-test role would give the same evidence as a conformance verdict on every failure case.

## Severity

The peer of a Flyology client sees an abnormal closure for every protocol violation the client detects, so it cannot tell a crash or a network failure from a deliberate rejection, and it learns nothing about what was wrong. RFC 6455 section 7.1.7 states this as a SHOULD rather than a MUST, and the connection is still correctly failed, the exception is still correct, and no data is misdelivered, so the cost is diagnostic and conformance rather than correctness on the wire. Every detected violation takes this path, and a conformance harness running the client under test would report a non-clean close on each of them; that run has not been made, so this rests on a raw peer. Deterministic.
