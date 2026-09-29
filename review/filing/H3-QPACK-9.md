Title: Peer-reset request streams never refill MAX_STREAMS, so 29 cancelled requests exhaust an HTTP/3 connection
Labels: bug
Refs: H3-QPACK-1

## Summary

The server's cumulative MAX_STREAMS limit is the advertised initial value plus the number of requests it has completed, and the credit datagram is built only when a request ends cleanly. A request stream the peer resets consumes an identifier without ever incrementing that counter, so each cancellation permanently removes one unit of stream concurrency. After 29 cancellations the peer cannot open another request stream, and the server will never raise the limit because nothing can complete.

## Problem

Commit `f078732`.

The limit is computed as the initial value plus completed requests (`src/flyology-http-server-http_3.adb:1640-1644`):

```ada
         Limit  : constant QUIC.Stream_Offset :=
           QUIC.Stream_Offset'Min
             (2**60,
              Transport_Settings.Max_Streams_Bidi
                + QUIC.Stream_Offset (Served));
```

`Served` is incremented only when a request is dispatched (`src/flyology-http-server-http_3.adb:1606`), and the credit datagram is built only in the `Stream_Ended` branch (`src/flyology-http-server-http_3.adb:1821-1824`). The `Stream_Reset` branch releases the local slot and sends nothing (`src/flyology-http-server-http_3.adb:1825-1828`):

```ada
            when H3.Stream_Reset =>
               if Slot /= 0 then
                  Release (Positive (Slot));
               end if;
```

The initial value is 29 (`flyology_quic/src/flyology-quic-connections.ads:107`):

```ada
      Max_Streams_Bidi            : Stream_Offset := 29;
```

RFC 9000 section 4.6 makes the limit cumulative over every stream ever opened: "Only streams with a stream ID less than `(max_streams * 4 + first_stream_id_of_type)` can be opened." A retired stream therefore returns no concurrency; the receiver has to raise the limit with MAX_STREAMS, and RFC 9000 section 4.6 states that "An endpoint that is unable to open a new stream due to the peer's limits SHOULD send a STREAMS_BLOCKED frame." The server never answers one.

This shares its root with {{ISSUE:H3-QPACK-1}}: `Return_Request_Credit` is the single emitter of both MAX_STREAMS and MAX_STREAM_DATA, and it is reachable only from the `Stream_Ended` branch.

No existing test opens and resets request streams in bulk.

## What happens now

Spike: the program starts the real listener, then opens a request and immediately cancels it, forty times, which is the shape of a browser abandoning image loads when a navigation starts. It asserts that all forty succeed.

```ada
         for Attempt in 1 .. Attempts loop
               H3.Open_Request (Session, Transport, Stream, H3_Status);
               H3.Append (Block, H3.Make_Field (":method", "GET"));
               H3.Append (Block, H3.Make_Field (":path", "/image"));
               H3.Send_Headers
                 (Session, Transport, Stream, Block, Fin => False,
                  Now => Now, Packet => Packet, Status => H3_Status);
               QUIC_IO.Send (Socket, Packet, 2.0);
               H3.Cancel_Request
                 (Session, Transport, Stream, H3.Cancel_Processing,
                  Now, Packet, H3_Status);
               QUIC_IO.Send (Socket, Packet, 2.0);
         end loop;
```

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  note attempt 30 Open_Request: STREAM_LIMIT_REACHED
  note requests opened and cancelled: 29 of 40; first unanswered attempt 30; transport state CONNECTED
  FAIL the client can open and cancel 40 requests, the server refilling MAX_STREAMS as streams retire
checks: 3  failures: 1
BUG REPRODUCED
exit status 1
```

The count matches the advertised initial limit exactly: 29 requests, then `Stream_Limit_Reached`. The connection is still `CONNECTED` and cannot recover, because no request can complete to trigger the credit that would raise the limit.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A request stream that the peer resets frees the same concurrency a completed request frees, so the server should raise its cumulative MAX_STREAMS when it retires a reset stream, exactly as it does for a completed one.

## Suggested treatment

Count retired streams rather than dispatched requests when computing the cumulative limit, and call `Return_Request_Credit` from the `Stream_Reset` branch at `src/flyology-http-server-http_3.adb:1825-1828` as well as from `Stream_Ended`. Introducing a separate retired-stream counter alongside `Served` keeps `Max_Requests` accounting unchanged, which matters because `Served` also drives the connection retirement condition; reusing `Served` for both would make a cancelled request count against the request limit.

This needs a maintainer decision only on the throttle: `Request_Credit_Due` currently fires every fourteenth completed request, so a reset-driven refill needs its own rate or it will emit a datagram per cancellation. Under "Decision authority" and "Ada interface values" the options for that rate are a private implementation value in the server body, a caller parameter, a generic formal, a value derived from the existing `Max_Streams_Bidi` in the `Transport_Settings` record the caller already supplies, build-time configuration, or a deliberately public constant. The existing `Stream_Credit_Interval` at `src/flyology-http-server-http_3.adb:1497-1502` is already derived from `Max_Streams_Bidi / 2` and is the natural precedent.

`src/flyology-http-server-http_3.adb` is not among the units `./scripts/prove.sh` proves, so no proof obligation changes. The regression test belongs in `tests/http3_server_integration.adb`; the spike above is the test. No maintained test asserts the current behaviour.

## Severity

A client that cancels requests, which is ordinary behaviour for any user agent that abandons in-flight subresource loads, loses one unit of concurrency per cancellation and is wedged after 29. From then on it cannot open a request stream on that connection at all, and the server sends nothing to indicate why, so the connection sits idle and apparently healthy until it ages out. No adversarial input is needed; the trigger is the documented cancellation API. Deterministic.
