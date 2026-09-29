Title: HTTP/3 client credit raises every stream's limit, so an unread sibling response fails instead of blocking
Labels: bug
Refs: none

## Summary

When the HTTP/3 client grants receive credit it builds one packet that raises the advertised limit of every tracked stream, while the decision to grant is taken from the consumed length of the one stream whose owner is reading. A stream's QUIC consumed offset advances whenever `Poll` copies its DATA into the response ring, regardless of whether the exchange owner has read any of it, so a sibling exchange on the same pooled connection keeps being granted credit it has no room for. When its ring passes 65,535 bytes the exchange is failed rather than flow-controlled.

## Problem

Commit `f078732`.

`Build_Receive_Credit_Packet` raises the limit of every tracked stream in one pass (`flyology_quic/src/flyology-quic-application_space.adb:878-895`):

```ada
         for Index in 1 .. Stream_Table_Policy.Stream_Count (Item.Streams) loop
            declare
               ID : constant Varint_Policy.Value_Type :=
                 Stream_Table_Policy.Stream_At (Item.Streams, Index);
               Consumed : constant Varint_Policy.Value_Type :=
                 Stream_Table_Policy.Consumed_Offset (Item.Streams, ID);
               Window : constant Varint_Policy.Value_Type :=
                 Receive_Flow_Control_Policy.Stream_Window
                   (Item.Receive_Flow, ID);
               ...
            begin
               Receive_Flow_Control_Policy.Raise_Stream_Data_Limit
                 (Item.Receive_Flow, ID, Maximum);
            end;
         end loop;
```

The client decides when to grant from one stream's consumed length (`src/flyology-http-client.adb:2517-2530`):

```ada
   function HTTP_3_Receive_Credit_Due
     (Connection         : Pooled_Connection;
      Stream_Consumed    : QUIC.Stream_Offset;
      Last_Stream_Credit : QUIC.Stream_Offset) return Boolean
   is
      Current : constant QUIC.Stream_Offset :=
        QUIC.Received_Data (Connection.QUIC_Transport);
   begin
      return Current - Connection.HTTP_3_Last_Credit_Data >=
        HTTP_3_Data_Credit_Interval
        or else
          (Stream_Consumed >= Last_Stream_Credit
           and then Stream_Consumed - Last_Stream_Credit >=
             HTTP_3_Transport_Settings.Max_Stream_Data_Bidi_Local / 2);
```

A stream's consumed offset advances as soon as `Poll` decodes its DATA into the ring (`src/flyology-http-http_3_connection.adb:419-425`), with no reference to the owner. The admission test on the client's side of the ring is a failure, not backpressure (`src/flyology-http-http_3_client_connection.adb:411-421`):

```ada
               when H3.Data_Received =>
                  if not Stream.Head_Available
                    or else Stream.Trailers_Seen
                    or else Stream.Body_Forbidden
                    ...
                    or else Stream.Content_Count + Event.Data_Length >
                      Response_Buffer_Capacity
                  then
                     Stream.Phase := Failed;
```

with `Response_Buffer_Capacity : constant Positive := 65_535;` at `src/flyology-http-http_3_client_connection.ads:114`.

RFC 9000 section 4.1 states: "A receiver can advertise a larger limit for a stream by sending a MAX_STREAM_DATA frame with the corresponding stream ID." The limit is per stream precisely so that it can reflect what the receiver can absorb on that stream.

The reach is narrower than it first looks. The finding needs an origin that interleaves two response bodies on one connection, and this repository's own HTTP/3 server never does: `Serve_Connection` dispatches one request at a time, so a second response body does not start while the first is in flight. It therefore needs a concurrent HTTP/3 origin, and it was not verified against a named third-party peer.

No existing test reads one pooled response while another is in flight; `tests/http3_client_composable_smoke.adb` reads each response as it completes.

## What happens now

Spike: the program connects two real HTTP/3 sessions back to back, opens two request streams, answers both heads, then interleaves DATA frames on both streams while playing the role `src/flyology-http-client.adb` plays: every polled event is published into a real `HTTP_3_Client_Connection.Session`, only stream A's owner reads, and credit is granted when the client's own `HTTP_3_Receive_Credit_Due` rule fires on A's consumed length. It asserts that stream B is flow-controlled rather than failed.

```ada
   procedure Push (Stream : QUIC.Stream_ID; Moved : out Boolean) is
   begin
      H3.Send_Data
        (Server_H3, Server_Transport, Stream, Payload, Fin => False,
         Now => Tick, Packet => Packet, Status => Status);
      Moved := Status = H3.Succeeded;
      if Moved then
         Fixtures.Deliver (Packet, Client_Transport);
      end if;
   end Push;
   ...
   for Round in 1 .. 2_000 loop
         Push (Stream_A, Moved_A);
         Push (Stream_B, Moved_B);
         Drain_Client;
         Acknowledge;
         Grant_Credit_If_Due;
         exit when Peek_B = Body_Stream_Failed;
   end loop;
```

```
  ok   both HTTP/3 sessions exchange SETTINGS
  ok   two request streams are open
  ok   stream A's response head is ready
  ok   stream B's response head is ready
  note stream A: sent 65536 bytes, owner read 65536; consecutive stalled rounds at exit 0
  note stream B: sent 65536 bytes, owner read none; body result BODY_STREAM_FAILED
  note Response_Buffer_Capacity = 65535
  FAIL the sibling stream whose owner had not read is flow-controlled, not failed
checks: 5  failures: 1
BUG REPRODUCED
exit status 1
```

Stream B fails at 65,536 delivered bytes, one past the ring capacity, while stream A completes the same volume without stalling once.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A stream's advertised receive limit should reflect the room left in that stream's own buffer, so a stream whose owner is not reading stops being granted credit and the peer is held by flow control. Overflowing a receive buffer that the receiver itself kept advertising room for is a bug in the credit calculation, not a protocol error by the peer, so it should not fail the exchange.

## Suggested treatment

Grant credit per stream rather than for the whole connection: compute each stream's new limit from what its owner has read out of the ring, not from what the transport has consumed into it, and skip a stream whose ring is full. `Build_Receive_Credit_Packet` currently derives every stream's limit from `Stream_Table_Policy.Consumed_Offset`, so either it needs the per-stream headroom passed in, or the client needs a narrower entry point that raises one stream's limit at a time.

This needs a maintainer decision: exposing per-stream headroom through `Build_Receive_Credit_Datagram` is a new parameter on a public QUIC operation, and any separate per-stream credit entry point is a new public subprogram. Under "Decision authority" and "Ada interface values" the options are a private implementation value or routine inside the QUIC application space, a caller parameter carrying the per-stream headroom, a generic formal, a discriminant, a value derived from the existing `Response_Buffer_Capacity` contract at `src/flyology-http-http_3_client_connection.ads:114`, build-time configuration, or a deliberately public constant if the answer is instead to fix the ring capacity to the transport window. Deciding that the ring should simply be at least as large as the advertised window is the cheapest option and is also a capacity decision.

Neither `src/flyology-http-client.adb` nor `src/flyology-http-http_3_client_connection.adb` is among the units `./scripts/prove.sh` proves. `flyology_quic/src/flyology-quic-receive_flow_control_policy.adb` is proved by the QUIC suite that `./scripts/prove.sh` runs first, so a change to the limit calculation there must keep it discharging with `--checks-as-errors=on`. The regression test belongs in `tests/http3_client_composable_smoke.adb`, which already drives two exchanges over a pooled connection; the spike above is the test. No maintained test asserts the current failure.

## Severity

An exchange that the caller has not started reading fails with a body-stream error once a concurrent origin has pushed 64 KiB on it, even though the caller did nothing wrong and the data was never at risk of being lost by the peer. It needs a pooled HTTP/3 connection to an origin that interleaves two response bodies; this repository's own server dispatches one request at a time and so does not produce the interleaving, and the behaviour was not checked against a named third-party peer. Within that scope it is deterministic and reproduces at the exact ring capacity. Deterministic; not reproduced against a live peer.
