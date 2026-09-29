Title: A composable buffer exchange drains an over-capacity response body with no byte bound
Labels: bug

## Summary

Once a composable buffer exchange has decided `Response_Body_Too_Large`, `Deliver` discards every slice but `Receive_Content_Step` keeps calling `Receive_One` until the framing completes. Nothing consults `Pending_Result` to abandon the transport, so the client reads and throws away the entire declared body. Against a 4096-byte destination and a response declaring 8388608 body bytes, the peer succeeds in writing all 8388608 of them before the exchange terminalizes. The two sibling paths in the same file answer the same question with a bound.

## Problem

Commit `f078732`.

The decision is taken at head time for a known length (`src/flyology-http-client.adb:4014-4023`):

```ada
            if State.Target = Buffer_Target
              and then State.Metadata.Mode = Fixed_Body
              and then State.Metadata.Remaining_Body >
                Flyology.Buffers.Drivers.Capacity (State.Destination)
            then
               State.Pending_Result := Response_Body_Too_Large;
               State.Result.Required :=
                 (Known => True,
                  Bytes => Body_Size (State.Metadata.Remaining_Body));
            end if;
```

and inside `Deliver` for a streamed one (`src/flyology-http-client.adb:3892-3895`). From then on every slice is dropped (`src/flyology-http-client.adb:3868-3869`):

```ada
         if Count = 0 or else State.Pending_Result /= Response_Complete then
            return;
```

but the receive loop is unchanged (`src/flyology-http-client.adb:4042-4064`):

```ada
      procedure Receive_Content_Step is
         Last       : Ada.Streams.Stream_Element_Offset;
         Complete   : Boolean;
         Need_Input : Boolean;
      begin
         HTTP_1_Internals.Consume_Available_Content
           (State.Metadata, State.Buffer, Last, Complete, Need_Input,
            State.Peer_Closed);
         if Last >= State.Buffer'First then
            Deliver (State.Buffer (State.Buffer'First .. Last));
         end if;
         if Sink_Paused then
            Finish_Response_Head (Item);
            return;
         end if;
         if Complete then
            Finish_Decoded_Body;
         elsif Need_Input then
            Receive_One;
         else
            Reschedule;
         end if;
      end Receive_Content_Step;
```

No path consults `Pending_Result` to stop early.

The repository answers the same question the other way on both sibling paths. `Drain` stops at a named bound and destroys the transport (`src/flyology-http-client.adb:67-70`):

```ada
   --  An intermediate redirect body is never delivered to the caller, so it
   --  is read only to leave the transport reusable. Past this bound the
   --  transport costs more than it saves and is destroyed instead.
   Max_Redirect_Drain_Bytes : constant Natural := 64 * 1_024;
```

applied at `src/flyology-http-client.adb:6399-6404`, and `Read_All` calls `Abandon_Response` on the first overflow (`src/flyology-http-client.adb:7257-7266`):

```ada
               if Flyology.Bytes.Length (Result) > Maximum
                 or else Count > Maximum - Flyology.Bytes.Length (Result)
               then
                  if Item.Data /= null
                    and then Item.Data.Connection /= null
                  then
                     Abandon_Response (Item.Data.all);
                  end if;
                  raise Response_Too_Large;
               end if;
```

No documented sentence is broken. `src/flyology-http-client.ads:695` says only:

```ada
   --  @enum Response_Body_Too_Large Bounded response destination overflowed
```

and nothing promises when the exchange terminalizes, which is why this is a behavioural inconsistency rather than a contract violation.

Existing coverage cannot see it. `tests/corpus/http-client-scenarios.json:131-136` and `tests/http_client_composable_smoke.adb:572-577` assert the typed result on a 40-byte overrun:

```ada
         pragma Assert
           (Client.Kind (Result) = Client.Response_Body_Too_Large);
         pragma Assert (Buffers.Length (Destination) = 0);
         pragma Assert (Client.Required_Body_Length (Result).Known);
         pragma Assert
           (Client.Required_Body_Length (Result).Bytes = 40);
```

Forty bytes finish instantly either way, so nothing measures bytes drained after the overflow decision.

## What happens now

Spike: a composable buffer exchange is driven against a raw `Flyology.IO.Sockets` peer with a 4096-byte destination and a response declaring 8388608 body bytes. The peer writes the body in 8 KiB pieces and counts what it manages to send before the exchange terminalizes. The typed result is checked as a control, and the second check asserts the repository-consistent behaviour: the client does not consume an entire body it has already decided to discard.

```ada
   Capacity   : constant := 4_096;
   Body_Bytes : constant := 8 * 1_024 * 1_024;
   Chunk      : constant := 8 * 1_024;
   ...
            while Written < Body_Bytes loop
               Sockets.Send_All (Peer, Piece, Timeout => 3.0);
               Written := Written + Chunk;
            end loop;
   ...
   Check (Coordination.Sent < Body_Bytes,
          "the client does not consume the whole over-capacity body it has"
          & " already decided to discard");
```

```
  note destination capacity is 4096 bytes; the response declares 8388608 body bytes
  note exchange result is RESPONSE_BODY_TOO_LARGE
  ok   control: the typed result is Response_Body_Too_Large
  note response body bytes the peer managed to write: 8388608 of 8388608
  FAIL the client does not consume the whole over-capacity body it has already decided to discard
checks: 2  failures: 1
BUG REPRODUCED
```

The whole body is read and discarded: 8388608 bytes against a 4096-byte destination, 2048 times the capacity.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

Once the exchange has decided `Response_Body_Too_Large`, it should stop reading within a bounded number of further bytes and abandon the transport, the way `Drain` and `Read_All` already do in the same file.

## Suggested treatment

Consult `State.Pending_Result` in `Receive_Content_Step` and stop once the discarded count passes a bound, abandoning the transport rather than returning it to the pool.

This needs a maintainer decision: the bound is a new resource budget, and under "Decision authority" and "Ada interface values" the authorization to fix the drain does not authorize inventing the number or deciding where it is visible. The options are a private implementation value in `src/flyology-http-client.adb` alongside `Max_Redirect_Drain_Bytes`, the existing `Max_Redirect_Drain_Bytes` reused directly on the strength of its stated rationale, a value derived from the destination capacity already in `State.Destination`, a caller parameter on the composable exchange, a generic formal, build-time configuration, or a deliberately public constant in `src/flyology-http-client.ads`. A second decision goes with it: whether the exchange should abandon immediately on the overflow decision, as `Read_All` does, or read up to a bound first so that the transport can stay reusable when the remainder is small.

For a `Fixed_Body` the drain is bounded by the declared `Content-Length`, which is what the spike measures. For `Chunked_Body` and `Until_Close_Body` no length is declared, so the same loop is bounded only by the caller's exchange deadline; that part is from reading `Consume_Available_Content` (`src/flyology-http-client-http_1_internals.adb:859-1008`) and was not measured.

`src/flyology-http-client.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in `tests/http_client_composable_smoke.adb`, beside the 40-byte overrun assertion at `:572-577`: a declared length far above the destination capacity, with the peer counting the bytes it manages to write. The spike is the test. The corpus scenario at `tests/corpus/http-client-scenarios.json:131-136` asserts only the typed result and stays valid.

## Severity

A caller who bounds a response destination still pays for the whole body: the client reads and discards every declared byte, which costs time inside the caller's exchange deadline and keeps the transport busy. The typed result is correct, the destination is left empty and `Required_Body_Length` is set, so nothing the caller observes is wrong. There is no amplification, because the peer must actually transmit every byte the client discards, and the caller's own deadline bounds the exposure. Measured at 8388608 bytes drained against a 4096-byte destination. Deterministic.
