Title: The server's ack-eliciting Initial datagram is not expanded to 1200 bytes
Labels: bug
Refs: QUIC-TRANSPORT-1

## Summary

`Initial_Space` pads an Initial datagram to 1,200 bytes only in the client role, and the driver emits the ServerHello Initial as its own datagram rather than coalescing it with the Handshake packets that follow. The server's first datagram therefore leaves at about 142 bytes while carrying CRYPTO, which makes it ack-eliciting, so it is exactly the case RFC 9000 section 14.1 requires a server to expand.

## Problem

Commit `f078732`.

RFC 9000 section 14.1: "Similarly, a server MUST expand the payload of all UDP datagrams carrying ack-eliciting Initial packets to at least the smallest allowed maximum datagram size of 1200 bytes."

The padding target is zero for a server, both when emitting and when building a transport close (`flyology_quic/src/flyology-quic-initial_space.adb:141-142`):

```ada
      Minimum : constant Natural :=
        (if Item.Role = Initial_Connection.Client then 1_200 else 0);
```

and again at `:336-340`, where the comment attributes the rule to the client side only:

```ada
      --  RFC 9000 14.1 has a server discard any client Initial packet whose
      --  datagram payload is under 1,200 bytes, closes included.
      Minimum : constant Natural :=
        (if Item.Role = Initial_Connection.Client
         then 1_200 else 0);
```

Coalescing would have made the point moot, but the ServerHello Initial is appended to the output batch as a datagram of its own before the Handshake CRYPTO packets are built (`flyology_quic/src/flyology-quic-connection_driver.adb:956-969`):

```ada
            Initial_Space.Build_Crypto_Packet
              (Item.Initial, 0,
               Server_Hello
                 (1 .. Ada.Streams.Stream_Element_Offset
                         (TLS_Result.Server_Hello_Length)),
               Now, Packet_Out, Initial_Built);
            if Initial_Built.Status /= Initial_Space.Built
              or else not Append
                (Output, Packet_Out, Initial_Built.Packet_Length)
```

`flyology_quic/tests/src/flyology-quic-connection_driver-smoke.adb:189-192` asserts that the client's Initial datagram is 1,200 bytes; nothing asserts the server's. `flyology_quic/tests/qualification.md:145` lists 1,200-byte Initial datagrams among the areas not yet covered.

## What happens now

Spike: it starts a client, checks that its Initial datagram is padded, initialises a server from that datagram, processes it, and reports the first byte and length of every datagram the server emits. Long-header type bits 00 identify an Initial packet.

```ada
   Expect_Equal (Client_Output.Items (1).Length, 1_200,
                 "the client Initial datagram is padded to 1200 bytes");
   ...
   --  Long header with type bits 00 is an Initial packet (RFC 9000 s17.2.2).
   Check ((Server_Output.Items (1).Data (1) and 16#F0#) = 16#C0#, ...);
   Check (Server_Output.Items (1).Length >= 1_200,
          "a UDP datagram carrying an ack-eliciting server Initial packet is"
          & " expanded to at least 1200 bytes (RFC 9000 s14.1)");
```

```
  ok   the client Initial datagram is padded to 1200 bytes
  note server datagram 1: first byte c6, length 142
  note server datagram 2: first byte ea, length 560
  ok   precondition: the server's first datagram is a long-header Initial packet
  FAIL a UDP datagram carrying an ack-eliciting server Initial packet is expanded to at least 1200 bytes (RFC 9000 s14.1)
checks: 3  failures: 1
BUG REPRODUCED
```

The first bytes vary between runs because the long header is protected; the lengths do not.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A server must expand any UDP datagram carrying an ack-eliciting Initial packet to at least 1,200 bytes, as RFC 9000 section 14.1 requires, either by padding it or by coalescing it with the rest of its flight until it reaches that size.

## Suggested treatment

Use the same 1,200-byte minimum for both roles in `Initial_Space` when the packet is ack-eliciting (`flyology_quic/src/flyology-quic-initial_space.adb:141-142` and `:336-340`), and correct the comment at the second site, which currently states only the receive-side half of section 14.1. Coalescing the ServerHello Initial with the first Handshake packet into one datagram (`flyology_quic/src/flyology-quic-connection_driver.adb:956-969`) would satisfy the same rule with fewer bytes on the wire and is the more common implementation choice. The 1,200-byte value is fixed by RFC 9000 and is already declared here, so no new value is introduced either way.

Note that padding the server's Initial makes its first flight larger, which interacts with the missing anti-amplification accounting reported as {{ISSUE:QUIC-TRANSPORT-1}}: today the small server Initial is part of why the compliant, fully padded case measures inside the three-times limit. The accounting is the fix that keeps both rules satisfiable at once, so the two should be resolved together.

The regression test belongs in `flyology_quic/tests/src/flyology-quic-connection_driver-smoke.adb`, next to the client-side assertion at :189-192 that is already there; the assertion to add is the server's. The spike is the test. `flyology-quic-initial_space.adb` and `flyology-quic-connection_driver.adb` are not among the units `./scripts/prove.sh` proves.

## Severity

A MUST that is not met on every server handshake. Stock clients do not discard a small server Initial, so it is not interop-breaking on its own, and no failure is observed today. What is lost is the path's confirmed ability to carry 1,200-byte datagrams, which section 14.1 exists to establish before the handshake commits to that size. Deterministic.
