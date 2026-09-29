Title: QUIC client closes a live connection on post-handshake CRYPTO that is not one whole NewSessionTicket at offset 0
Labels: bug
Refs: none

## Summary

The QUIC client accepts a 1-RTT CRYPTO frame only when its stream offset is zero and its bytes are exactly one complete NewSessionTicket. There is no reassembly of the 1-RTT CRYPTO stream at all, so a second ticket, two tickets in one frame, or one ticket whose bytes are split across two frames all become `Unexpected_TLS_Message`. The driver maps that status to CRYPTO_ERROR 0x10A and sends CONNECTION_CLOSE, so a handshake that has just succeeded is destroyed by input the standards permit, and every HTTP/3 request on that connection fails.

## Problem

Commit `f078732`.

The whole of the client's post-handshake CRYPTO handling is one condition (`flyology_quic/src/flyology-quic-application_space.adb:1333-1349`):

```ada
               if Stream_ID_Policy.Local_Role (Item.Allocator) =
                    Stream_ID_Policy.Client
                 and then Frame.Base.Crypto_Offset = 0
                 and then Data_Length >= 4
                 and then Plaintext
                   (Plaintext'First
                      + Ada.Streams.Stream_Element_Offset (Data_Offset)) = 4
                 and then Body_Length = Natural (Data_Length) - 4
               then
                  --  A client that does not implement resumption may ignore
                  --  a complete post-handshake NewSessionTicket. Other
                  --  messages, including KeyUpdate, remain fatal in QUIC.
                  null;
               else
                  Result.Status := Unexpected_TLS_Message;
                  return;
               end if;
```

`Crypto_Offset = 0` rejects every frame after the first. `Body_Length = Natural (Data_Length) - 4` rejects a frame that carries more than one message and a frame that carries less than one whole message. Nothing buffers the bytes for a later frame.

`Unexpected_TLS_Message` is a transport error (`flyology_quic/src/flyology-quic-connection_driver.adb:580`):

```ada
         when Application_Space.Unexpected_TLS_Message => 16#10A#,
```

and `Scan_Datagram` routes every application-space status outside `Processed`, `Duplicate` and `Too_Old` into `Fail_Application_With_Close` (`flyology_quic/src/flyology-quic-connection_driver.adb:1328-1332`), which sets the connection to `Failed` and emits the close (`flyology_quic/src/flyology-quic-connection_driver.adb:606-608`):

```ada
      Application_Space.Build_Transport_Close_Packet
        (Item.Application, Error_Code, Frame_Type, Packet, Built);
      Item.Current := Failed;
```

RFC 8446 section 4.6.1: "Servers MAY send multiple tickets on a single connection, either immediately after each other or after specific events". RFC 9001 section 4.1.3 requires the receiver to sequence CRYPTO frames by offset rather than to treat frame boundaries as message boundaries: "As with STREAM frames, the offset is used to find the proper location in the data sequence. If the result of this process is that new data is available, then it is delivered to TLS in order." RFC 9000 section 7.5 gives the only sanctioned escape for a post-handshake CRYPTO frame an endpoint will not buffer: "it MAY discard that CRYPTO frame and all CRYPTO frames received in the future, or it MAY close the connection with a CRYPTO_BUFFER_EXCEEDED error code". CRYPTO_ERROR 0x10A is neither.

How often a stock server triggers this is narrower than it first looks, and the body of this report does not rest on it. This client's ClientHello carries exactly six extensions and none of them is `psk_key_exchange_modes` (`flyology_quic/src/flyology-quic-tls_extension_policy.adb:480-531` emits supported_versions, supported_groups, signature_algorithms, key_share, ALPN and quic_transport_parameters). RFC 8446 section 4.2.9 says "Servers SHOULD NOT send NewSessionTicket with tickets that are not compatible with the advertised modes", so a server that applies that gate sends no ticket to this client at all. Two of the pinned peers implement the gate: Go 1.23.4, which is quic-go's TLS stack, tests `pskModeDHE` in `crypto/tls/handshake_server_tls13.go:829-845` under the comment "Don't send tickets the client wouldn't use. See RFC 8446, Section 4.2.9", and aioquic 1.3.0 requires both a handler and an advertised mode before it builds a ticket (`tls.py:1838-1841`). Whether an OpenSSL-based QUIC server applies the same gate is not verified against a peer; no OpenSSL QUIC server is available here.

No test covers a 1-RTT CRYPTO frame. `scripts/test-http3-interop.sh` runs the client against quic-go 0.54.1 and aioquic 1.3.0 and both pass, for reasons that leave this path unexercised. quic-go sends exactly one ticket and places it at offset 0, which is the one shape this client accepts: its own comment in the pinned module reads "Due to limitations in crypto/tls, it's only possible to generate a single session ticket per connection" (`internal/handshake/crypto_setup.go:365-367`), and its post-handshake CRYPTO frames are capped at `MaxPostHandshakeCryptoFrameSize = 1000` (`internal/protocol/params.go:113`), which one ticket fits. Go's QUIC path returns early from the psk-mode gate above, so quic-go does send its one ticket, and the interop run therefore exercises precisely the accepted case. The aioquic oracle configures no session-ticket handler (`tests/oracle/aioquic_h3_server.py:163-182`), so it sends none.

## What happens now

Spike: two connection drivers complete a real QUIC and TLS handshake in process with no socket, the spike then takes the server's real application keys through `TLS_Session.Get_Application_Keys` and builds genuine 1-RTT packets carrying crafted CRYPTO frames, and delivers them to the client. It asserts that the client stays `Connected` and emits no CONNECTION_CLOSE. Three shapes are sent, and one control case sends the accepted shape first.

```ada
   --  Case A: two complete NewSessionTicket messages in one CRYPTO frame at
   --  offset 0.
   Run_Case
     ("two tickets in one frame", Empty,
      (16#06#, 16#00#, 16#08#, 4, 0, 0, 0, 4, 0, 0, 0));

   --  Case B: an accepted ticket at offset 0, then a second ticket at the
   --  next CRYPTO stream offset.
   Run_Case
     ("second ticket at offset 4",
      (16#06#, 16#00#, 16#04#, 4, 0, 0, 0),
      (16#06#, 16#04#, 16#04#, 4, 0, 0, 0));

   --  Case C: one ticket split across two CRYPTO frames; only the first
   --  frame is delivered here, so the client must buffer and wait.
   Run_Case
     ("ticket split across frames", Empty,
      (16#06#, 16#00#, 16#06#, 4, 0, 0, 8, 16#AA#, 16#BB#));
```

```
  note two tickets in one frame: handshake complete, client state = CONNECTED
  note two tickets in one frame: client state after the crafted CRYPTO frame = FAILED, datagrams emitted = 1
  FAIL two tickets in one frame: connection survives the post-handshake CRYPTO frame
  FAIL two tickets in one frame: no CONNECTION_CLOSE is emitted
  note second ticket at offset 4: handshake complete, client state = CONNECTED
  ok   second ticket at offset 4: client still Connected after the first ticket
  note second ticket at offset 4: client state after the crafted CRYPTO frame = FAILED, datagrams emitted = 1
  FAIL second ticket at offset 4: connection survives the post-handshake CRYPTO frame
  FAIL second ticket at offset 4: no CONNECTION_CLOSE is emitted
  note ticket split across frames: handshake complete, client state = CONNECTED
  note ticket split across frames: client state after the crafted CRYPTO frame = FAILED, datagrams emitted = 1
  FAIL ticket split across frames: connection survives the post-handshake CRYPTO frame
  FAIL ticket split across frames: no CONNECTION_CLOSE is emitted
checks: 7  failures: 6
BUG REPRODUCED
```

Every case reaches `CONNECTED` first, so the handshake itself succeeds and the failure is post-handshake. The single `ok` line is case B's control: the accepted shape, one whole ticket at offset 0, leaves the client `Connected`, so the assertion is not over-broad. Case C shows the defect does not depend on ticket count: one ticket split across two frames kills the connection on the first frame.

Host: macOS 26.6.2, arm64, GNAT via Alire. Peer behaviour read from quic-go 0.54.1 and aioquic 1.3.0 as pinned by the interop script.

## What should happen

The client should treat the 1-RTT CRYPTO stream as an ordered byte stream, sequence frames by offset, and deliver whole handshake messages to TLS, as RFC 9001 section 4.1.3 requires. If it will not buffer, RFC 9000 section 7.5 lets it discard post-handshake CRYPTO frames instead. In neither case may a well-formed sequence of NewSessionTicket messages end an established connection.

## Suggested treatment

The smallest correct fix is to ignore post-handshake CRYPTO on the client rather than to inspect it: accept any CRYPTO frame in the application space, discard its bytes, and keep `Unexpected_TLS_Message` only for the KeyUpdate case RFC 9001 section 6 forbids, which needs the message type and therefore still needs the frame at offset 0 to be inspected. The larger fix is a real reassembly buffer for the 1-RTT CRYPTO stream, reusing `Crypto_Reassembly_Policy`, with the message dispatched once a whole message is contiguous.

This needs a maintainer decision: a reassembly buffer introduces a capacity, and discarding introduces the choice of what to do with a KeyUpdate that arrives at a non-zero offset. The options for the capacity are a private implementation value, a caller parameter, a generic formal, a discriminant, a value derived from a type or contract such as `Crypto_Reassembly_Policy`'s existing bound, build-time configuration, or a deliberately public constant. Do not settle it here.

The regression test belongs in the existing QUIC transport smoke suite, `flyology_quic/tests/src/flyology-quic-tls_transport_smoke.adb`, which today stops at handshake completion. The spike is the test: the two-ticket frame, the second ticket at a later offset and the split ticket, with the single whole ticket at offset 0 kept as the control. No existing test asserts the current behaviour, so none has to change. `flyology_quic/src/flyology-quic-application_space.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation is affected.

The same code path is the subject of this issue, reported from the transport side; one fix closes both.

## Severity

The client destroys a connection that has just been established successfully, and every request on it fails. The reachability that does not depend on any peer's ticket policy is the split ticket: a single NewSessionTicket whose bytes do not fit one post-handshake CRYPTO frame kills the connection on the first frame, and quic-go's own 1000-byte cap on those frames shows that splitting is ordinary implementation behaviour rather than an attack. The multiple-ticket shapes are narrower than they look, because this client advertises no `psk_key_exchange_modes` and a server that honours RFC 8446 section 4.2.9 sends it no ticket at all; the two peers whose sources are pinned here implement that gate, and OpenSSL's behaviour is not verified against a peer. Deterministic.
