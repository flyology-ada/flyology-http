Title: HTTP/3 server sends no MAX_STREAM_DATA while a request body arrives, so an upload over 15 KiB never completes
Labels: bug
Refs: H3-QPACK-2, H3-QPACK-9

## Summary

The HTTP/3 server emits a per-stream receive-credit update only from the `Stream_Ended` branch of its event loop, which a request whose body is still arriving never reaches. The QUIC transport advertises a 16,384-byte per-stream receive window, so a client that honours flow control stops after about 15 KiB of body and waits for a MAX_STREAM_DATA frame that never arrives. Any request body larger than the initial window therefore deadlocks until the connection age limit expires, although the server documents a 1 MiB buffered-body limit.

## Problem

Commit `f078732`.

`Return_Request_Credit` is the server's only path to a receive-credit update (`src/flyology-http-server-http_3.adb:1637-1663`):

```ada
      procedure Return_Request_Credit is
         Packet : QUIC.Datagram;
         Status : QUIC.Send_Status;
         Limit  : constant QUIC.Stream_Offset :=
           QUIC.Stream_Offset'Min
             (2**60,
              Transport_Settings.Max_Streams_Bidi
                + QUIC.Stream_Offset (Served));
      begin
         loop
            QUIC.Build_Receive_Credit_Datagram
              (State.Transport,
               Connection_Window => Transport_Settings.Max_Data,
               Direction => QUIC.Bidirectional,
               Maximum_Streams => Limit,
               Now => Now (State.all), Packet => Packet, Status => Status);
```

It has exactly one call site, in the `Stream_Ended` branch of `Process_Event`, and that call is further gated (`src/flyology-http-server-http_3.adb:1821-1824`):

```ada
               Release (Positive (Slot));
               if Served < Max_Requests and then Request_Credit_Due then
                  Return_Request_Credit;
               end if;
```

`Request_Credit_Due` fires on every fourteenth completed request or after 256 KiB of connection-level data (`src/flyology-http-server-http_3.adb:1665-1671`):

```ada
      function Request_Credit_Due return Boolean is
         Current : constant QUIC.Stream_Offset :=
           QUIC.Received_Data (State.Transport);
      begin
         return Served mod Stream_Credit_Interval = 0
           or else Current - Last_Credit_Data >= Data_Credit_Interval;
      end Request_Credit_Due;
```

`Build_Receive_Credit_Datagram` is the only route to the QUIC crate's single `Encode_Max_Stream_Data` call site (`flyology_quic/src/flyology-quic-application_space.adb:862`). Consuming stream bytes does not move the advertised limit: the server appends each DATA payload to its buffer at `src/flyology-http-server-http_3.adb:1783-1788` without raising any window.

The window a peer is held to is 16,384 bytes (`flyology_quic/src/flyology-quic-connections.ads:105`):

```ada
      Max_Stream_Data_Bidi_Remote : Stream_Offset := 16_384;
```

RFC 9000 section 4.1 states that "A receiver can advertise a larger limit for a stream by sending a MAX_STREAM_DATA frame with the corresponding stream ID", and RFC 9000 section 4.1 also requires that "Senders MUST NOT send data in excess of either limit." A conformant peer therefore stops and waits indefinitely.

The documented contract says the opposite. `website/guide/server/index.html:369` states that the HTTP/3 profile "buffers each complete request before routing it and limits each retained request body to 1 MiB", a figure no request over roughly 15 KiB can reach. The same page states that after a 413 "The server discards subsequent DATA until that request stream ends or resets"; the discard path at `src/flyology-http-server-http_3.adb:1776-1777` never lets the client finish sending, and no STOP_SENDING is sent, so the request slot stays occupied.

No existing test moves an HTTP/3 body over the window. The aioquic oracle posts seven bytes (`tests/oracle/aioquic_h3_client.py:70`) and the quic-go oracle posts the string `payload` (`tests/oracle/quic-go/main.go:115`). `tests/http3_server_integration.adb:107` and `:139` declare 5 GiB and 64 GiB bodies but read nothing from them.

## What happens now

Spike: the program starts the real `Flyology.HTTP.Server.HTTP_3` listener over loopback UDP, completes the QUIC handshake and the HTTP/3 SETTINGS exchange, then uploads 20,000 bytes in 1,024-byte DATA frames from a QUIC client that honours flow control. It asserts that the whole body arrives and that the server answers 200.

```ada
         H3.Append (Headers, H3.Make_Field (":method", "POST"));
         H3.Append (Headers, H3.Make_Field (":path", "/upload"));
         H3.Append (Headers, H3.Make_Field ("content-length", "20000"));
         H3.Send_Headers
           (Session, Transport, Stream, Headers, Fin => False,
            Now => Now, Packet => Packet, Status => H3_Status);
         ...
               H3.Send_Data
                 (Session, Transport, Stream,
                  Payload (Sent + 1 .. Last),
                  Fin => Last = Body_Length,
                  Now => Now, Packet => Packet, Status => H3_Status);
               if H3_Status = H3.Succeeded then
                  QUIC_IO.Send (Socket, Packet, 2.0);
                  Sent := Last;
               elsif H3_Status = H3.Transport_Blocked then
                  Blocked := Blocked + 1;
                  Pump (0.25);
```

```
  ok   client Initial is built
  ok   QUIC handshake completes
  ok   client control stream starts
  ok   server SETTINGS arrive
  ok   request stream opens
  ok   request HEADERS are sent
  note first Transport_Blocked after 10240 body bytes
  note body bytes accepted by the transport: 15360; Transport_Blocked retries: 65
  FAIL the whole 20,000-byte request body reaches the server within 12.000000000 s
  FAIL the server answers 200 for the buffered upload
checks: 8  failures: 2
BUG REPRODUCED
exit status 1
```

The upload stops permanently at 15,360 body bytes, which is the 16,384-byte window less the HEADERS frame and the per-frame DATA envelopes, and 65 further blocked retries over twelve seconds produce no credit.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A server that is consuming a request body must raise that stream's receive limit as it consumes, so the sender can continue up to the documented 1 MiB buffered-body bound. RFC 9000 section 4.1 makes MAX_STREAM_DATA the receiver's only means of granting that credit. When the server has already answered with 413 and is discarding the rest, RFC 9114 section 4.1 applies instead: "The error code H3_NO_ERROR SHOULD be used when requesting that the client stop sending on the request stream", so the server should send STOP_SENDING rather than let the peer stall.

## Suggested treatment

Call `Return_Request_Credit` from the `Data_Received` branch of `Process_Event` as well, after the payload has been appended, so that consumed body bytes translate into an advertised limit. The existing `Request_Credit_Due` gate is the natural throttle, but its stream-count term is meaningless while a single body is arriving, so the data term has to fire on the stream that is actually consuming. In the `Reject_Oversized_Request` path, send STOP_SENDING with H3_NO_ERROR instead of silently discarding. The same routine is also the only emitter of MAX_STREAMS, which is why {{ISSUE:H3-QPACK-9}} has the same root and should be fixed alongside this one.

This needs a maintainer decision: the rate at which an in-progress body earns credit is a new policy value, and so is any change to the advertised 16,384-byte window in `flyology_quic/src/flyology-quic-connections.ads:105`. Under "Decision authority" and "Ada interface values" the options are a private implementation value inside the server body, a caller parameter on `Serve` and `Serve_Listener`, a generic formal, a value derived from the existing `Transport_Settings` record the caller already supplies, build-time configuration, or a deliberately public constant. Raising the transport window alone is not sufficient and interacts with {{ISSUE:H3-QPACK-2}}, where the same 16,384 bytes is a compile-time reassembly bound rather than a default.

The regression test belongs in `tests/http3_server_integration.adb`, which already drives the listener with request-body sources; the spike above is the test. No maintained test asserts the current behaviour, so none has to change. The fix is in `src/flyology-http-server-http_3.adb`, which `./scripts/prove.sh` does not prove, so no proof obligation changes.

## Severity

Every HTTP/3 request body larger than about 15 KiB fails against a conformant peer in the default configuration: the client blocks on flow control and the server never answers, so the exchange ends at the client's timeout or at the 300-second connection age limit. It needs no unusual peer and no unusual call; an ordinary form post or file upload over the advertised window is enough. The same starvation keeps a rejected oversized request occupying one of eight request slots for the life of the connection. Deterministic.
