Title: The connection-ID transport parameters are decoded but never compared with the connection IDs on the wire
Labels: bug
Refs: none

## Summary

`Transport_Parameter_Policy.Decode` checks that `original_destination_connection_id` and `initial_source_connection_id` are present and allowed for the sender's role, and nothing then compares their values with the connection IDs the endpoint actually used and received. A server can claim any values and the handshake completes. RFC 9000 requires a mismatch to be a connection error, precisely so that on-path tampering with an Initial packet's connection IDs is detected.

## Problem

Commit `f078732`.

RFC 9000 section 7.3: "The values provided by a peer for these transport parameters MUST match the values that an endpoint used in the Destination and Source Connection ID fields of Initial packets that it sent (and received, for servers). Endpoints MUST validate that received transport parameters match received connection ID values." The section then requires "a mismatch between values received from a peer in these transport parameters and the value sent in the corresponding Destination or Source Connection ID fields of Initial packets" to be treated as "a connection error of type TRANSPORT_PARAMETER_ERROR or PROTOCOL_VIOLATION".

The only uses of these parameters outside the codec are the two encode sites (`flyology_quic/src/flyology-quic-connections.adb:185-187`):

```ada
      Value.Initial_Source_Connection_ID := Parameter (Initial_Source);
      if Sender = Transport_Parameter_Policy.Server then
         Value.Original_Destination_Connection_ID := Parameter (Original);
      end if;
```

`Initialize_Application` reads the decoded peer parameters and uses them only for the ACK delay exponent and the maximum ACK delay; it never looks at `Item.Peer_ID`, `Item.Local_ID` or the original destination connection ID it was initialised with (`flyology_quic/src/flyology-quic-connection_driver.adb:755-777`):

```ada
      Peer := TLS_Session.Peer_Parameters (Item.TLS);
      Application_Space.Initialize
        (Item.Application, Sending, Receiving, Item.Peer_ID, Item.Local_ID,
         ...
      Item.Peer_ACK_Exponent :=
        (if Peer.ACK_Delay_Exponent.Present
```

`flyology_quic/tests/src/flyology-quic-transport_parameter_policy-smoke.adb` covers presence and role rules only.

## What happens now

Spike: it runs three handshakes that differ only in the transport parameters the server authenticates, leaving the connection IDs on the wire correct in all three. The first establishes that matching parameters complete a handshake. The second has the server claim an `original_destination_connection_id` that is not the Destination Connection ID the client put in its Initial. The third has it claim an `initial_source_connection_id` that is not the Source Connection ID it used on the wire.

```ada
   Run ("honest parameters", ID (Original_ID), Server_ID, Connected);
   Check (Connected, "precondition: matching parameters complete a handshake");

   Run ("original_destination_connection_id does not match the client's DCID",
        Wrong_ID, Server_ID, Connected);
   Check (not Connected, ...);

   Run ("initial_source_connection_id does not match the server's wire SCID",
        ID (Original_ID), Wrong_ID, Connected);
   Check (not Connected, ...);
```

```
  note honest parameters: client state CONNECTED
  ok   precondition: matching parameters complete a handshake
  note original_destination_connection_id does not match the client's DCID: client state CONNECTED
  FAIL a client rejects a server whose original_destination_connection_id does not match the Destination Connection ID it sent (RFC 9000 s7.3)
  note initial_source_connection_id does not match the server's wire SCID: client state CONNECTED
  FAIL a client rejects a server whose initial_source_connection_id does not match the Source Connection ID it received (RFC 9000 s7.3)
checks: 3  failures: 2
BUG REPRODUCED
```

Both dishonest handshakes complete.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

An endpoint must compare the connection-ID transport parameters it received against the connection IDs it used and received on the wire, and close the connection with TRANSPORT_PARAMETER_ERROR or PROTOCOL_VIOLATION on a mismatch, as RFC 9000 section 7.3 requires.

## Suggested treatment

Do the comparison where the peer parameters first become available, in `Initialize_Application` (`flyology_quic/src/flyology-quic-connection_driver.adb:755-777`): a client compares the peer's `original_destination_connection_id` with the original destination connection ID it sent and the peer's `initial_source_connection_id` with `Item.Peer_ID`; a server compares the peer's `initial_source_connection_id` with `Item.Peer_ID`. A mismatch should reach the existing close path with error 0x08. `Retry_Source_Connection_ID` needs no handling while Retry is not implemented, beyond rejecting it when it is present.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-transport_parameter_policy-smoke.adb` for the parameter half, and in a driver-level test alongside `flyology_quic/tests/src/flyology-quic-connection_driver-smoke.adb` for the handshake half, since the comparison is a driver responsibility rather than a codec one. The spike is the test. No existing test asserts the current behaviour. `flyology-quic-connection_driver.adb` is not among the units `./scripts/prove.sh` proves; `flyology-quic-transport_parameter_policy.adb` is, and would only need a change if the comparison were moved into the codec, in which case the proof must keep discharging with `--checks-as-errors=on`.

## Severity

On-path tampering with the connection IDs of an Initial packet is not detected, because Initial packets have no integrity against an on-path party and this is the check that is meant to catch it. The practical effect is not a wrong result but a missing diagnosis: the handshake either completes on tampered values or fails later with an unrelated status such as `Unexpected_Destination`, so an operator sees a confusing failure instead of a transport error naming the cause. It needs an on-path attacker. Deterministic.
