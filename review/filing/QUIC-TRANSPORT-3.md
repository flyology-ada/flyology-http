Title: Initial keys are never discarded, so a forged Initial packet closes an established connection in both roles
Labels: bug
Refs: none

## Summary

Neither endpoint ever discards its Initial keys. `Scan_Datagram` dispatches Initial packets in every connection state, and `Process_Initial_Packet` honours a CONNECTION_CLOSE carried in one before it reaches the state check at all. Initial keys are derived from the client's original Destination Connection ID, which travels in plaintext, so anyone who saw the first client Initial can protect a packet that both an established server and an established client will accept. One such datagram moves the connection to `Peer_Closed` and the HTTP/3 session is torn down.

## Problem

Commit `f078732`.

RFC 9001 section 4.9.1: "a client MUST discard Initial keys when it first sends a Handshake packet and a server MUST discard Initial keys when it first successfully processes a Handshake packet. Endpoints MUST NOT send Initial packets after this point." The same section gives the reason: "Packets protected with Initial secrets ... are not authenticated, meaning that an attacker could spoof packets with the intent to disrupt a connection."

Nothing discards them. Neither `Initial_Space.State` nor `Connection_Driver.Connection` carries a "keys discarded" flag, and `Acknowledge_Flight` only stops retransmission.

`Scan_Datagram` dispatches any long-header Initial packet regardless of state (`flyology_quic/src/flyology-quic-connection_driver.adb:1382-1396`):

```ada
            elsif (First and 16#30#) = 16#00# then
               declare
                  ...
                  Envelope : constant Initial_Packet_Policy.Parse_Result :=
                    Initial_Packet_Policy.Parse (Remaining);
               begin
                  ...
                  Process_Initial_Packet
                    (Item,
```

Inside `Process_Initial_Packet` the peer close is acted on before any test of `Item.Current` (`flyology_quic/src/flyology-quic-connection_driver.adb:906-911`):

```ada
      elsif Processed.Peer_Closed then
         Item.Close_Is_Application := False;
         Item.Close_Error := Processed.Close_Error;
         Item.Current := Peer_Closed;
         Result.Status := Connection_Closed;
         return;
```

The state check that would have rejected the packet is reached only afterwards, and it accepts the established states anyway (`:1029-1033`):

```ada
      elsif Item.Current in Client_Handshake | Server_Handshake | Connected then
         Result.Status := Succeeded;
      else
         Result.Status := Invalid_State;
      end if;
```

The close itself is set by the Initial frame loop (`flyology_quic/src/flyology-quic-initial_space.adb:504-510`):

```ada
         elsif Frame.Kind = Initial_Frame_Policy.Transport_Close then
            --  RFC 9000 10.2.2 puts the receiver into the draining state, so
            --  the remaining frames of this packet cannot change the outcome.
            Result.Peer_Closed := True;
            Result.Close_Error := Frame.Close_Error_Code;
            Result.Status := Processed;
            return;
```

The same defect is reachable through a second path, and was reported a second time against the key-handling side of the same code. A CRYPTO frame whose bytes conflict with the recorded ClientHello, or an ACK naming a packet the endpoint never sent, does not reach the close branch but reaches `Fail_Initial_With_Close` two lines above it (`flyology_quic/src/flyology-quic-connection_driver.adb:901-905`), which closes the connection with a transport error. Either way one forged Initial ends an established connection.

The server side is routable from off the path. The HTTP/3 listener registry matches a live slot on the peer address plus either the server's source connection ID or the original destination connection ID, both plaintext on the wire (`src/flyology-http-server-http_3.adb:112-123`):

```ada
         for Slot in Used'Range loop
            if Used (Slot)
              and then Peers (Slot) = Peer
              and then
                (Same_ID (Sources (Slot), Header.Destination)
                 or else Same_ID (Originals (Slot), Header.Destination))
```

Against a client no registry is involved at all.

There is no coverage. `flyology_quic/tests/src/flyology-quic-tls_transport_smoke.adb` stops at handshake completion, and `flyology_quic/tests/src/flyology-quic-application_space-smoke.adb:388-415` exercises an application close inside a 1-RTT packet, which needs the real keys. `flyology_quic/tests/qualification.md:137` lists key discard among the areas not yet covered. The interop peers never send an Initial packet after the handshake, so the interop lane cannot see this.

## What happens now

Spike: two drivers complete a real handshake, both reaching `Connected` with the handshake confirmed. The program then builds a fresh Initial codec from nothing but values that travel in plaintext, the original destination connection ID and the two endpoints' connection IDs, advances its packet number past the replay window, protects a transport CONNECTION_CLOSE with the RFC 9001 section 5.2 Initial keys, and feeds the resulting 1,200-byte datagram to each established endpoint in turn.

```ada
      Close : constant Initial_Frame_Policy.Transport_Close_Encode_Result :=
        Initial_Frame_Policy.Encode_Transport_Close
          (Error_Code => 16#0A#, Frame_Type => 16#06#);
      ...
      Initial_Connection.Initialize
        (Codec, Role, Original_ID, Destination, Source);
      --  Advance past the packet numbers the real handshake already used, so
      --  the receiver's replay window cannot be the thing that rejects this.
      for Index in 1 .. Skip loop
         Initial_Connection.Build_Initial_At_Least
           (Codec, (1 .. 0 => 0), (1 => 16#01#), 1_200, Scratch, Built);
      end loop;
```

```
  ok   precondition: the server handshake completed
  ok   precondition: the client handshake completed
  note forged Initial for the server: 1200 bytes
  note server reports CONNECTION_CLOSED, state PEER_CLOSED
  FAIL an established server discards an Initial packet protected with the publicly derivable Initial keys (RFC 9001 s4.9.1)
  note forged Initial for the client: 1200 bytes
  note client reports CONNECTION_CLOSED, state PEER_CLOSED
  FAIL an established client discards an Initial packet protected with the publicly derivable Initial keys (RFC 9001 s4.9.1)
checks: 4  failures: 2
BUG REPRODUCED
```

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A client should discard its Initial keys when it first sends a Handshake packet and a server when it first successfully processes one, and an Initial packet arriving after that point should be discarded without affecting the connection, as RFC 9001 section 4.9.1 requires.

## Suggested treatment

Record the discard in `Connection_Driver.Connection`: set a flag where the client first emits a Handshake packet and where the server first processes one, and have `Scan_Datagram` drop a long-header Initial packet without parsing it once the flag is set (`flyology_quic/src/flyology-quic-connection_driver.adb:1382-1396`). Dropping before `Process_Initial_Packet` closes both routes, the CONNECTION_CLOSE branch and `Fail_Initial_With_Close`, in one place. The Initial space state can be released at the same point, which also satisfies the "MUST NOT send Initial packets after this point" half of the rule.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-connections-recovery_smoke.adb`, which already runs two drivers through a complete handshake; the assertion to add is that a post-handshake Initial packet leaves `State` at `Connected`. The spike is the test. No existing test asserts the current behaviour, so nothing has to change. Neither `flyology-quic-connection_driver.adb` nor `flyology-quic-initial_space.adb` is among the units `./scripts/prove.sh` proves.

## Severity

One UDP datagram ends an established HTTP/3 connection in either direction, and against the server it does so from off the path, because the listener registry resolves it on plaintext connection IDs and a spoofed source address. The attacker must have observed the client's first Initial packet, since the original destination connection ID is random and at least eight bytes, so this is not a blind reset; observing that packet is enough for the rest, and the connection ID stays usable for the whole connection. Deterministic.
