Title: A malformed HTTP/3 response on a stream identifier above 4092 is reported once per poll without end
Labels: bug
Refs: H3-QPACK-10

## Summary

When the client role rejects a malformed response it emits a `Stream_Reset` event without consuming the offending bytes, then retires the message. Retirement records a tombstone only for stream identifiers the fixed 1,024-entry table covers, and releases the QUIC stream only when it is complete or already reset. On a higher identifier that the peer keeps open, the next `Poll` finds no tombstone, opens a fresh slot for the same identifier, reparses the same bytes and emits the same event again, for as long as polling continues.

## Problem

Commit `f078732`.

The client role returns the event without consuming anything: `Consumed` is set only on the `Consumed` status, and this branch returns before `QUIC.Consume` (`src/flyology-http-http_3_connection.adb:426-440`). Retirement is bounded by the tombstone table (`src/flyology-http-http_3_connection.adb:155-160` and `:173-179`):

```ada
      if ID mod 4 = 0
        and then ID / 4 <= QUIC.Stream_ID (Message_Ordinal'Last)
      then
         Item.Released_Messages (Message_Ordinal (ID / 4)) := True;
      end if;
      ...
      if QUIC.Has_Stream (Transport, ID)
        and then
          (QUIC.Is_Complete (Transport, ID)
             or else QUIC.Was_Reset (Transport, ID))
      then
         QUIC.Release_Stream (Transport, ID);
      end if;
```

with `Max_Message_Tombstones : constant := 1_024;` at `src/flyology-http-http_3_connection.ads:18`, so the table covers identifiers up to 4092. Above that the retirement test falls back to the transport (`src/flyology-http-http_3_connection.adb:105-114`):

```ada
   function Is_Released_Message
     (Item      : Connection;
      Transport : QUIC.Connection;
      ID        : QUIC.Stream_ID) return Boolean is
     (ID mod 4 = 0
      and then
        ((ID / 4 <= QUIC.Stream_ID (Message_Ordinal'Last)
          and then Item.Released_Messages (Message_Ordinal (ID / 4)))
         or else QUIC.Is_Stream_Retired (Transport, ID))
      and then Find (Item, ID) = 0);
```

For a stream the peer has not reset and not finished, neither disjunct holds, so `Poll` reaches `Find_Or_Open` at `src/flyology-http-http_3_connection.adb:355` and opens a fresh slot for the same identifier.

The composable pump does not break the cycle: it exits on any `Succeeded` event and calls `Receive_One` only on `No_Event` (`src/flyology-http-client-http_3_internals.adb:320-346`), so the peer's eventual RESET_STREAM, which would make `Was_Reset` true, is never read. The synchronous path avoids the spin by a different route: for the HTTP/3 engine `Abandon_Response` marks the pooled connection unusable and closes it (`src/flyology-http-client.adb:2165-2169`), at the cost of every sibling exchange on it.

No existing test drives more than a thousand exchanges over one connection.

## What happens now

Spike: the program connects two real HTTP/3 sessions, sends the same malformed response twice, once on stream 0 as a control and once on a stream identifier past the tombstone table after 1,024 completed warm-up exchanges, in both cases leaving the stream open. It polls eight times, cancelling the exchange after each event the way the pump does, and asserts that one malformed response produces one failure.

```ada
      Frame (1) := 16#01#;
      Frame (2) := Ada.Streams.Stream_Element (Section'Length);
      Frame (3 .. Frame'Last) := Section;
      QUIC.Build_Stream_Datagram
        (Server_Transport, Stream, Offset => 0, Fin => False,
         Data => Frame, Now => Tick, Packet => Packet, Status => Sent);
      Fixtures.Deliver (Packet, Client_Transport);

      for Attempt in 1 .. 8 loop
         H3.Poll (Client_H3, Client_Transport, Event, Status);
         if Status = H3.Succeeded
           and then Event.Kind = H3.Stream_Reset
           and then Event.Stream = Stream
         then
            Resets := Resets + 1;
            H3.Cancel_Request
              (Client_H3, Client_Transport, Stream,
               H3.Malformed_Message, Tick, Packet, Status);
         end if;
      end loop;
```

```
  ok   the sessions exchange SETTINGS
  note control stream id 0 reported the failure 1 times in 8 polls
  ok   inside the tombstone table one malformed response is reported once
  note completed 1024 warm-up exchanges; last stream id 4096
  ok   the connection retires 1,024 request streams
  note offending stream id 4100; the tombstone table covers ids up to 4092
  ok   the offending stream identifier is past the tombstone table
  note Stream_Reset events emitted for the same malformed response: 8 in 8 polls
  FAIL one malformed response produces one stream failure, whatever the stream identifier
checks: 5  failures: 1
BUG REPRODUCED
exit status 1
```

This is a controlled comparison: the identical malformed response, delivered through the identical code path, is reported once on stream 0 and eight times in eight polls on stream 4100, with the stream identifier as the only difference. Cancelling after each event, which is what the real pump does, does not stop the re-emission.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

One malformed response should produce one stream failure regardless of the stream identifier. A message the session has decided to abandon must not be reparsed, so abandoning it has to be effective for every identifier the connection can reach, not only the first 1,024.

## Suggested treatment

Make abandonment unconditional. Either consume the offending bytes before returning the `Stream_Reset` event, so the reassembly cursor moves past them and the same bytes cannot be reparsed, or abort reading the stream at the transport when the message is abandoned, so `Was_Reset` becomes true and `Is_Released_Message` holds. Aborting the read is the more complete answer, since it also tells the peer to stop sending. The composable pump at `src/flyology-http-client-http_3_internals.adb:320-346` should additionally keep receiving after a stream failure rather than returning on the first `Succeeded` event, so a peer reset can arrive.

This needs a maintainer decision on the tombstone table itself: `Max_Message_Tombstones` is a visible capacity in a private package specification, and the fixes above leave it in place while removing the dependence on it. Under "Decision authority" and "Ada interface values" the options for that capacity are keeping it as a private implementation value, a caller parameter, a generic formal, a discriminant on the connection, a value derived from the connection's own stream capacity, build-time configuration, or a deliberately public constant. Enlarging the table is not a fix, since any fixed size has the same boundary.

`src/flyology-http-http_3_connection.adb` and `src/flyology-http-client-http_3_internals.adb` are not among the units `./scripts/prove.sh` proves, so no proof obligation changes. The regression test belongs in `tests/flyology-http-http_3_connection-smoke.adb`, which already drives paired sessions; the spike above is the test. No maintained test asserts the current behaviour. The correct scoping of malformed-message handling on the server side is {{ISSUE:H3-QPACK-10}}, which touches the same procedure.

## Severity

A composable client exchange can loop emitting the same failure without terminating, burning the caller's deadline and never making progress. Reaching it needs three things at once: more than 1,024 requests on one pooled connection, a peer that answers one of them with a malformed response, and a peer that leaves that stream open afterwards. The synchronous client path is not exposed to the loop but pays for it by closing the whole pooled connection, which loses sibling exchanges. Within its conditions the behaviour is deterministic and the boundary is exact at identifier 4092. Deterministic.
