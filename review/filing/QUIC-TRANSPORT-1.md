Title: A QUIC server applies no anti-amplification limit and accepts undersized client Initial packets
Labels: bug
Refs: QUIC-TRANSPORT-8

## Summary

Nothing in the QUIC crate counts the bytes a server has received from a peer address against the bytes it sends to that address, and nothing rejects a client Initial packet carried in a UDP datagram smaller than 1,200 bytes. One datagram with a spoofed source address therefore draws the server's whole handshake flight plus two probe retransmissions, all delivered to the address the attacker named. With this repository's own pinned 320-byte test certificate a 216-byte Initial draws 2,084 bytes, 9.64 times what was received. The compliant case is not safe either: the flight grows by three bytes per certificate byte, so with an ordinary 1,024-byte leaf a fully padded, fully compliant 1,200-byte Initial still draws 3.61 times.

## Problem

Commit `f078732`.

RFC 9000 section 8.1 states the limit and the accounting it needs: "Prior to validating the client address, servers MUST NOT send more than three times as many bytes as the number of bytes they have received." The same section adds: "servers MUST count all of the payload bytes received in datagrams that are uniquely attributed to a single connection."

RFC 9000 section 14.1 states the receive-side rule that keeps the received count honest: "A server MUST discard an Initial packet that is carried in a UDP datagram with a payload that is smaller than the smallest allowed maximum datagram size of 1200 bytes."

Neither rule is implemented.

The whole connection state is `Connection_Driver.Connection` and the three per-space states it holds. None of them has a field counting bytes sent to or received from the peer address. The only address-validation vocabulary in the crate is one client-side flag (`flyology_quic/src/flyology-quic-connection_driver.ads:333-335`):

```ada
      --  RFC 9002 PeerCompletedAddressValidation: a client that has processed
      --  a Handshake packet no longer needs the anti-deadlock probe.
      Peer_Validated        : Boolean := False;
```

It is read in one place, to keep a client's anti-deadlock probe armed (`flyology_quic/src/flyology-quic-connection_driver.adb:56-62`), and it counts nothing. Retry packets and address-validation tokens are not implemented, so there is no alternative validation mechanism either.

A server accepts any parseable Initial regardless of datagram size. `Initialize_Server_From_Initial` gates only on the envelope parsing, and never looks at `First_Datagram'Length` (`flyology_quic/src/flyology-quic-connections.adb:319-326`):

```ada
      Envelope : constant Initial_Packet_Policy.Parse_Result :=
        Initial_Packet_Policy.Parse (First_Datagram);
      Original, Peer : Connection_ID;
   begin
      if Envelope.Status /= Initial_Packet_Policy.Parsed then
         Status := Invalid_Initial;
         return;
      end if;
```

The listener above it admits any untruncated datagram and allocates a slot for any Initial (`src/flyology-http-server-http_3.adb:2090-2099`):

```ada
            if Last >= Message.Data'First
              and then not Message.Metadata.Truncated
            then
               ...
               Candidate :=
                 (if Header.Is_Initial then QUIC.Random_Connection_ID
                  else (others => <>));
```

The only citation of section 14.1 in the crate is about what this endpoint emits, not what it accepts (`flyology_quic/src/flyology-quic-initial_space.adb:336-340`).

Having accepted the Initial, the server emits the ServerHello Initial and then every Handshake CRYPTO chunk of the authentication flight, with no byte budget anywhere in the loop (`flyology_quic/src/flyology-quic-connection_driver.adb:976-985`):

```ada
            while Offset < TLS_Result.Authentication_Length loop
               Chunk := Natural'Min
                 (Handshake_Space.Max_Crypto_Payload,
                  TLS_Result.Authentication_Length - Offset);
               Handshake_Space.Build_Crypto_Packet
                 (Item.Handshake, Varint_Policy.Value_Type (Offset),
                  ...
```

Each probe timeout then retransmits every CRYPTO range that is still unacknowledged, again with no budget (`flyology_quic/src/flyology-quic-connection_driver.adb:1523-1526`):

```ada
      Status := Probes_Ready;
      for Index in 1 .. Max_Output_Datagrams loop
         Initial_Space.Build_Probe_Packet
           (Item.Initial, Index, Now, Packet, Initial_Built);
```

The flight size is dominated by the certificate, which `TLS_Session` copies into the Certificate message without parsing it (`flyology_quic/src/flyology-quic-tls_session.adb:155-156`):

```ada
      Item.Certificate_Length := Natural (Certificate_DER'Length);
      Item.Certificate (1 .. Certificate_DER'Length) := Certificate_DER;
```

Each of the three flights carries it, so the bytes sent grow by about three per certificate byte. `Serve_Listener` accepts `Certificate_DER'Length in 1 .. 4_096` (`src/flyology-http-server-http_3.ads:75`), and the break-even against a fully padded 1,200-byte Initial is about 825 bytes, so a publicly trusted CA-issued leaf is inside the documented contract and over the limit.

aioquic 1.3.0 implements this accounting in one line, `QuicNetworkPath.can_send` at `quic/connection.py:209`: `return self.is_validated or (self.bytes_sent + size) <= 3 * self.bytes_received`.

No test covers it. `flyology_quic/tests/src/flyology-quic-connections-recovery_smoke.adb:148-160` asserts that the server does retransmit its flight with nothing received from the client, pinning the current behaviour, and applies no byte budget. No test presents an undersized client Initial to a server. `flyology_quic/tests/qualification.md:145` lists "Anti-amplification accounting, 1200-byte Initial datagrams" among the areas not yet covered.

## What happens now

Spike: it builds one client Initial with the crate's own ClientHello, once padded to 1,200 bytes and once with no padding at all, hands each to a fresh server connection, and then drives `Process_Timeout` at every recovery deadline inside the 3.0 s handshake idle budget, summing the bytes the server emits. It asserts the section 8.1 ratio on each case and the section 14.1 discard on the undersized one. The 320-byte certificate is the same pinned material as `tests/flyology-quic-test_connections.adb`; the 1,024-byte and 4,096-byte cases are opaque arrays, which measures faithfully because the DER is never parsed.

```ada
   Build_Client_Initial (1_200, Padded_Packet, Padded_Length);
   Build_Client_Initial (0, Short_Packet, Short_Length);
   ...
      Process_Datagram (Server, Initial_Datagram, Output, Result, Now);
      Emitted := Batch_Bytes (Output);
      while Has_Recovery_Timeout (Server) loop
         Now := Recovery_Deadline (Server);
         exit when Now > Idle_Budget;
         Process_Timeout (Server, Now, Output, Timeout_Result);
         exit when Timeout_Result /= Probes_Ready;
         Emitted := Emitted + Batch_Bytes (Output);
      end loop;
```

```
  note padded client Initial: 1200 bytes
  note minimal client Initial: 216 bytes
  note    flight 1 at 0 us: 2 datagrams, 698 bytes
  note    flight 2 at 999000 us: 2 datagrams, 693 bytes
  note    flight 3 at 2997000 us: 2 datagrams, 693 bytes
  note A 1200-byte Initial, 320-byte certificate: status SUCCEEDED, flights 3, sent 2084 bytes, received 1200 bytes
  note    amplification 1.73x
  ok   A: at most 3x the bytes received (RFC 9000 s8.1)
  note    flight 1 at 0 us: 5 datagrams, 4615 bytes
  note    flight 2 at 999000 us: 5 datagrams, 4610 bytes
  note    flight 3 at 2997000 us: 5 datagrams, 4610 bytes
  note B 1200-byte Initial, 4096-byte certificate: status SUCCEEDED, flights 3, sent 13835 bytes, received 1200 bytes
  note    amplification 11.52x
  FAIL B: at most 3x the bytes received (RFC 9000 s8.1)
  note    flight 1 at 0 us: 3 datagrams, 1449 bytes
  note    flight 2 at 999000 us: 3 datagrams, 1444 bytes
  note    flight 3 at 2997000 us: 3 datagrams, 1444 bytes
  note E 1200-byte Initial, 1024-byte certificate: status SUCCEEDED, flights 3, sent 4337 bytes, received 1200 bytes
  note    amplification 3.61x
  FAIL E: at most 3x the bytes received (RFC 9000 s8.1)
  note    flight 1 at 0 us: 2 datagrams, 698 bytes
  note    flight 2 at 999000 us: 2 datagrams, 693 bytes
  note    flight 3 at 2997000 us: 2 datagrams, 693 bytes
  note C minimal Initial, 320-byte certificate: status SUCCEEDED, flights 3, sent 2084 bytes, received 216 bytes
  FAIL C: a server discards a client Initial in a datagram under 1200 bytes (RFC 9000 s14.1)
  note    amplification 9.64x
  FAIL C: at most 3x the bytes received (RFC 9000 s8.1)
  note    flight 1 at 0 us: 5 datagrams, 4615 bytes
  note    flight 2 at 999000 us: 5 datagrams, 4610 bytes
  note    flight 3 at 2997000 us: 5 datagrams, 4610 bytes
  note D minimal Initial, 4096-byte certificate: status SUCCEEDED, flights 3, sent 13835 bytes, received 216 bytes
  note    amplification 64.05x
  FAIL D: at most 3x the bytes received (RFC 9000 s8.1)
checks: 6  failures: 5
BUG REPRODUCED
```

Read the measured table as two independent multipliers, either of which alone breaks the limit:

```
client Initial       certificate      bytes sent   ratio
1,200 B (compliant)  320 B (pinned)        2,084   1.73x, inside the limit
1,200 B (compliant)  1,024 B               4,337   3.61x
1,200 B (compliant)  4,096 B              13,835   11.52x
216 B (undersized)   320 B (pinned)        2,084   9.64x
216 B (undersized)   4,096 B              13,835   64.05x
```

The compliant case against the repository's own test certificate is inside the three-times limit. It is inside by accident, not by accounting: the flight happens to be small because that certificate is 320 bytes and because the server's own Initial datagram is not expanded to 1,200 bytes either, which is reported separately as {{ISSUE:QUIC-TRANSPORT-8}}.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A server should count the payload bytes it has received on a connection and refuse to send more than three times that many until the client address is validated, as RFC 9000 section 8.1 requires, and it should discard a client Initial packet whose UDP datagram payload is under 1,200 bytes, as section 14.1 requires.

## Suggested treatment

Two separate changes, both small.

Add a received-byte and sent-byte pair to `Connection_Driver.Connection`, credit the received count in `Process_Datagram` for every datagram attributed to the connection, and gate each `Append` into the output batch on `Sent + Length <= 3 * Received` while the address is unvalidated, clearing the gate when a Handshake packet from the client is first processed. `aioquic`'s `can_send` is the shape of the test. RFC 9002 section 6.2.2.1 also asks that a server not arm the probe timer while it is amplification limited, so `Has_Handshake_Timeout` (`flyology_quic/src/flyology-quic-connection_driver.adb:56-62`) should take the same gate into account.

Add the datagram-length check where the server first sees the datagram: `Initialize_Server_From_Initial` can return `Invalid_Initial` for `First_Datagram'Length < 1_200`, and `Serve_Listener` should not allocate a listener slot for such a datagram (`src/flyology-http-server-http_3.adb:2090-2099`).

Both the factor of three and the 1,200-byte minimum are fixed by RFC 9000 rather than chosen here. Under "Decision authority" their authority should be recorded next to their declaration or validation.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-connections-recovery_smoke.adb`, which already drives a server through its flight and its probe timeouts with nothing arriving from the client; the assertion to add is the running byte budget. That file at :148-160 currently asserts the unbudgeted retransmission and will need to change. The spike is the test. Neither `flyology-quic-connection_driver.adb` nor `flyology-quic-connections.adb` is among the units `./scripts/prove.sh` proves, so the proof obligations are unaffected.

## Severity

A server with a default configuration is a usable traffic amplifier. One UDP datagram with a forged source address makes it deliver 2,084 bytes to the forged address over three seconds using this repository's own test certificate, and 13,835 bytes with a 4 KB certificate that the public contract accepts. It also holds one of the 256 listener slots for the 3.0 s handshake idle timeout while it does so, so the same missing mechanism lets a small number of forged datagrams occupy the whole listener. The compliant, fully padded case with the small test certificate measures 1.73x and is inside the limit; the violation needs either an undersized Initial, which nothing rejects, or a certificate above about 825 bytes, which is ordinary for a publicly trusted leaf. Deterministic.
