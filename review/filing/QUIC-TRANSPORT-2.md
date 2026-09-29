Title: A large transfer fails the connection once 64 packets are unacknowledged, instead of applying backpressure
Labels: bug
Refs: H3-QPACK-2

## Summary

`Application_Space` refuses to build a packet once 64 packets are unacknowledged, and it tests that local ledger before it asks the congestion controller whether it may send. Once NewReno slow start has grown the window past 64 packets the ledger becomes the binding limit, and it reports `Recovery_Capacity_Exceeded`, which the HTTP/3 layer maps to a fatal `Transport_Error` rather than to backpressure. A response larger than about 77 KB to a peer with an ordinary stream window therefore ends with the server closing the connection with H3_INTERNAL_ERROR. The same check refuses the probe packet a probe timeout must send, so a full ledger plus one lost acknowledgement burst also tears the connection down.

## Problem

Commit `f078732`.

The ledger is checked before the congestion window in the stream send path (`flyology_quic/src/flyology-quic-application_space.adb:417-436`):

```ada
      if not Stream_Was_Opened (Item, Stream_ID) then
         Result.Status := Stream_Not_Sendable;
         return;
      elsif Sent_Packet_Policy.Retained (Item.Sent) =
        Sent_Packet_Policy.Max_Sent_Packets
      then
         Result.Status := Recovery_Capacity_Exceeded;
         return;
      ...
      elsif not Recovery_Policy.Can_Send
        (Item.Recovery,
         Sent_Packet_Policy.Packet_Byte_Count (Max_Datagram_Length))
      then
         Result.Status := Congestion_Blocked;
```

`Max_Sent_Packets` is 64 (`flyology_quic/src/flyology-quic-sent_packet_policy.ads:22`). The tracked-frame path (`:695-705`) and the probe path (`:1087-1095`) apply the same test:

```ada
      elsif Sent_Packet_Policy.Retained (Item.Sent) =
        Sent_Packet_Policy.Max_Sent_Packets
        or else Free_Packet_Frame_Mapping (Item) = 0
      then
         Packet := (others => 0);
         Result := (others => <>);
         Result.Status := Recovery_Capacity_Exceeded;
         return;
```

Slow start has no ceiling, so the window does grow past the ledger. `Slow_Start_Limit` is initialised to `Byte_Count'Last` (`flyology_quic/src/flyology-quic-recovery_policy.adb:116`) and the window simply adds every newly acknowledged byte while below it (`:240-241`):

```ada
               if Item.Window < Item.Slow_Start_Limit then
                  Item.Window := Saturating_Add (Item.Window, Amount);
```

`Recovery_Capacity_Exceeded` is not a backpressure status to the layer above. `Send_Status_For` maps everything it does not name to `Transport_Error` (`src/flyology-http-http_3_connection.adb:39-48`):

```ada
     (case Value is
         when QUIC.Sent => Succeeded,
         when QUIC.Congestion_Blocked => Transport_Blocked,
         when QUIC.Stream_Capacity_Exceeded => Stream_Capacity_Exceeded,
         when QUIC.Stream_Flow_Blocked | QUIC.Connection_Flow_Blocked =>
           Transport_Blocked,
         when others => Transport_Error);
```

`Server.HTTP_3.Send_Data` retries only on `Transport_Blocked` and otherwise raises (`src/flyology-http-server-http_3.adb:840-845`):

```ada
         exit when Status = H3.Succeeded;
         if Status /= H3.Transport_Blocked then
            raise Flyology.IO.Device_Error with
              "HTTP/3 response data failed: " &
              H3.Operation_Status'Image (Status);
         end if;
```

`Flush_Pending_Responses` does the same at `:396-399`, and `Application_Error_For` turns `Transport_Error` into H3_INTERNAL_ERROR 0x102 (`:299`).

The probe timeout is worse. `Process_Timeout` cannot build the probe, so it reports `Timeout_Packet_Error` and never reaches `On_Probe_Timeout`, which means the probe count does not back off either (`flyology_quic/src/flyology-quic-connection_driver.adb:1629-1645`):

```ada
      for Probe in 1 .. 2 loop
         Application_Space.Build_Probe_Packet
           (Item.Application, Now, Packet, Built);
         if Built.Status = Application_Space.Sent then
            ...
         elsif Output.Count = 0 then
            Status := Timeout_Packet_Error;
            return;
```

`Server.HTTP_3.Process_Recovery` raises on any status other than `Probes_Ready`, `Not_Due` or `No_Pending_Recovery` (`src/flyology-http-server-http_3.adb:340-344`):

```ada
         when QUIC.Not_Due | QUIC.No_Pending_Recovery =>
            null;
         when others =>
            raise Flyology.IO.Device_Error with
              "QUIC recovery failed: " & QUIC.Timeout_Status'Image (Status);
```

RFC 9002 section 6.2.4: "When a PTO timer expires, a sender MUST send at least one ack-eliciting packet in the packet number space as a probe." No RFC caps the number of packets an endpoint may have in flight, so the 64-entry bound is a local policy; the defect is that it is enforced ahead of congestion control and surfaced as a fatal status.

The green suites do not reach it. Every maintained Ada-versus-Ada lane uses `QUIC.Transport_Settings'(others => <>)` (`tests/flyology-quic-test_connections.adb:91`, `:102`, `tests/http3_public_smoke.adb:24`, `src/flyology-http-server-http_3.adb:1477`), whose `Max_Stream_Data_Bidi_Remote` is 16,384, so a sender is stream-flow-blocked at about fifteen packets. The interop server serves `/hello` and a `/echo` with `Max_Body => 64` (`tests/http3_interop_server.adb:48-54`). `flyology_quic/tests/src/flyology-quic-sent_packet_policy-smoke.adb:87-99` asserts `Table_Full` at the proved policy level only, which pins the bound but exercises no driver. `flyology_quic/tests/qualification.md:139` records that application-space probe timeouts under sustained loss are not covered.

This is the send side of the endpoint. The 16,384-byte reassembly ceiling reported as {{ISSUE:H3-QPACK-2}} is the receive side, and the two do not mask each other: this crate frames response bodies in 1,024-byte DATA chunks (`Response_Chunk_Size`, `src/flyology-http-server-http_3.adb:46`), so a several-hundred-kilobyte response is hundreds of small frames that a stock peer reassembles without difficulty, and the sender's only constraints are the peer's advertised credit and its own congestion window. The reassembly ring does explain why the Ada-versus-Ada lanes never reach the ledger, since there the receiver's ring and the default 16,384-byte credit coincide. Both need fixing.

## What happens now

Spike: two drivers complete a real handshake with the peer advertising 2,000,000 bytes of per-stream credit, which is the only non-default input and is within the range a stock peer's stream window auto-tunes to. The client then sends up to 200 STREAM packets per round trip, the server acknowledges everything sent in the previous round, and the program records which status stops each round. It then stops acknowledging, fills the ledger, and fires one probe timeout.

```ada
   Client_Parameters.Initial_Max_Stream_Data_Bidi_Remote :=
     (Present => True, Value => 2_000_000);
   ...
   for Trip in 1 .. 8 loop
      Round (200, True, Sent_Count, Last_Status);
   end loop;
   Round (200, False, Sent_Count, Last_Status);
   Check (Last_Status /= Application_Space.Recovery_Capacity_Exceeded, ...);
   Now := Recovery_Deadline (Client);
   Process_Timeout (Client, Now, Final_Batch, Timeout_Result);
   Check (Timeout_Result = Probes_Ready, ...);
```

```
  note round trip 1: sent 10 packets, then CONGESTION_BLOCKED
  note round trip 2: sent 20 packets, then CONGESTION_BLOCKED
  note round trip 3: sent 40 packets, then CONGESTION_BLOCKED
  note round trip 4: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note round trip 5: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note round trip 6: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note round trip 7: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note round trip 8: sent 64 packets, then RECOVERY_CAPACITY_EXCEEDED
  note with nothing acknowledged: sent 64 further packets, then RECOVERY_CAPACITY_EXCEEDED
  FAIL a sender that runs out of room reports backpressure (Congestion_Blocked or a flow-control status), not Recovery_Capacity_Exceeded, which Flyology.HTTP.HTTP_3_Connection.Send_Status_For maps to Transport_Error
  note PTO with a full ledger: TIMEOUT_PACKET_ERROR, 0 datagrams
  FAIL a probe timeout with a full ledger still sends at least one ack-eliciting packet (RFC 9002 s6.2.4)
checks: 2  failures: 2
BUG REPRODUCED
```

Rounds one to three stop at 10, 20 and 40 packets with `CONGESTION_BLOCKED`, which is correct backpressure. From round four the window has passed 64 packets and the sender stops at 64 with `RECOVERY_CAPACITY_EXCEEDED`, having moved about 77 KB. No loss is injected anywhere.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A sender that has run out of local recovery room should report the same backpressure a congestion-limited sender reports, so the caller waits and retries, and a probe timeout should always be able to emit at least one ack-eliciting packet, as RFC 9002 section 6.2.4 requires.

## Suggested treatment

The narrow fix is to stop presenting a local capacity bound as a protocol failure. Order the tests so `Recovery_Policy.Can_Send` decides first, and either map `Recovery_Capacity_Exceeded` to `Transport_Blocked` in `Send_Status_For` (`src/flyology-http-http_3_connection.adb:39-48`) or give `Application_Space` a distinct blocked status for a full ledger. For the probe path, reserve one ledger entry for probes, or allow `Build_Probe_Packet` to reuse the oldest retained entry, so `Process_Timeout` can always meet section 6.2.4.

Whether 64 is also the right number is a separate question. Raising it would let the window grow further before the ledger binds, and capping `Slow_Start_Limit` would stop the window from outgrowing the ledger at all. This needs a maintainer decision: `Max_Sent_Packets` is a visible constant in `flyology-quic-sent_packet_policy.ads:22` that sizes the tracking arrays, and under "Decision authority" and "Ada interface values" the choice of its value and of where it lives is the maintainer's. The options are a private implementation value, a caller parameter, a generic formal on the policy package, a discriminant on the state type, a value derived from the advertised window or the congestion configuration, build-time configuration, or a deliberately public constant with its rationale recorded next to it.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-connections-recovery_smoke.adb`, which already drives two connections through loss and recovery; the assertions to add are that a sender past the window reports a blocked status rather than a capacity status, and that a probe timeout with a full ledger still emits a datagram. The spike is the test. `flyology_quic/tests/src/flyology-quic-sent_packet_policy-smoke.adb:87-99` asserts `Table_Full` at the policy level and stays correct either way, but it must change if the bound itself changes. `flyology-quic-sent_packet_policy.adb` and `flyology-quic-recovery_policy.adb` are both proved by `./scripts/prove.sh`; a change to either must keep the proof discharging with `--checks-as-errors=on`. `flyology-quic-application_space.adb` and `flyology-quic-connection_driver.adb` are not proved.

## Severity

An HTTP/3 server that sends a response larger than about 77 KB to a peer whose stream window exceeds that closes the connection with H3_INTERNAL_ERROR instead of delivering the body, and a streamed upload from the client fails the same way. The trigger is an ordinary peer with an ordinary window and no loss at all; it needs only enough bytes for slow start to outgrow 64 packets, which is three round trips. The probe case needs one round of acknowledgements to be lost or delayed while 64 packets are in flight, which on a lossy path is routine. Deterministic.
