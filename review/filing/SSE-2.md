Title: Event_Too_Large and Reconnect_Delay_Too_Large raised while the body streams surface as Invalid_Event_Stream
Labels: bug
Refs: none

## Summary

`Read` documents `Event_Too_Large` and `Reconnect_Delay_Too_Large` as the exceptions a caller sees when its own `Maximum_Event_Bytes` or `Maximum_Reconnect_Delay` is breached. While the response body is streaming, the parser runs inside the response sink, and the client engine converts any sink exception into the result kind `Response_Sink_Failed` without re-raising it. The SSE layer then falls into the catch-all arm of its result mapping and raises `Invalid_Event_Stream`, so a caller cannot tell a breach of its own configured limit from a malformed server response. The first violation in a stream, which is the common one, always takes that path.

## Problem

Commit `f078732`.

The contract (`src/flyology-http-client-sse.ads:85-86`):

```ada
   --  @exception Event_Too_Large Retained parser state would exceed the bound
   --  @exception Reconnect_Delay_Too_Large A retry field exceeds caller policy
```

Both are raised by the parser. `Require_Capacity` (`src/flyology-http-client-sse.adb:179-187`):

```ada
   procedure Require_Capacity (Item : Event_Source; Added : Natural) is
   begin
      if Added > Item.Maximum_Event_Bytes
        or else Retained_Bytes (Item) > Item.Maximum_Event_Bytes - Added
      then
         raise Event_Too_Large with
           "SSE retained event bytes exceed caller bound";
      end if;
   end Require_Capacity;
```

and `Parse_Retry` (`src/flyology-http-client-sse.adb:307-334`):

```ada
         if Reconnect_Value > Item.Maximum_Delay then
            raise Reconnect_Delay_Too_Large with
              "SSE retry field exceeds caller maximum";
         end if;
```

While the body streams, both run inside `Event_Sink.Write` (`src/flyology-http-client-sse.adb:488`), which the engine calls from `Deliver` (`src/flyology-http-client.adb:3884-3891`):

```ada
         if State.Target = Sink_Target then
            begin
               Write (State.Sink_Item.all, Data);
            exception
               when Error : others =>
                  Remember_Failure (State, Error);
                  State.Pending_Result := Response_Sink_Failed;
            end;
```

`Remember_Failure` does preserve the identity (`src/flyology-http-client.adb:683-685`):

```ada
      if State.Failure_Cause = Ada.Exceptions.Null_Id then
         State.Failure_Cause := Ada.Exceptions.Exception_Identity (Error);
      end if;
```

but `Failure_Cause` is consulted in exactly one place, the synchronous `Execute` wrapper, and only for a fixed result-kind and identity allowlist that does not include `Response_Sink_Failed` (`src/flyology-http-client.adb:6550-6566`):

```ada
         if Failure_Cause /= Ada.Exceptions.Null_Id
           and then
             ((Result.Result_Kind in
                 Connection_Failed | Transport_Failed | Response_Invalid
                 and then
                   (Failure_Cause = Flyology.IO.TLS.TLS_Error'Identity
                      or else Failure_Cause = Protocol_Error'Identity
                      or else Failure_Cause = Response_Too_Large'Identity))
                or else
                  (Result.Result_Kind = Transport_Failed
                     and then
                       (Failure_Cause = Flyology.IO.Device_Error'Identity
                          or else Failure_Cause =
                            Flyology.IO.Sockets.Socket_Error'Identity))
                or else Result.Result_Kind = Request_Source_Failed)
         then
            Ada.Exceptions.Raise_Exception (Failure_Cause);
         end if;
```

The SSE layer does not use that wrapper. It drives the composable exchange, whose `Finish` re-raises only when `Has_Saved_Error`, which no sink path sets (`src/flyology-http-client.adb:1733-1740`):

```ada
      if Operation.State.Has_Saved_Error then
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity
              (Operation.State.Saved_Error),
            Ada.Exceptions.Exception_Message
              (Operation.State.Saved_Error));
      end if;
```

`Finish_Response_Body` therefore sees a non-complete result (`src/flyology-http-client-sse.adb:819-825`) and `Handle_Exchange_Failure` takes its catch-all arm (`src/flyology-http-client-sse.adb:736-739`):

```ada
            when others =>
               raise Invalid_Event_Stream with
                 "SSE HTTP exchange failed during " &
                 Exchange_Phase'Image (Phase (Result));
```

The path is not uniformly broken. When the offending field follows a complete event inside the same written slice, the remaining bytes stay in `Event_Source.Pending` and the next `Read` parses them in `Process_Buffered` (`src/flyology-http-client-sse.adb:841-861`), outside the sink, where the raise reaches `Drive`'s handler at `:920-931`, is saved, and is re-raised with its identity intact by `Finish` at `:988-996`. Both documented exceptions reach the caller in that case.

The modelled reconnect lifecycle is unaffected: `Drive`'s handler still issues `Connection_Fatal_Failure`, so the policy state is right and only the exception identity is wrong.

There is no existing coverage. `tests/http1_sse_client_integration.adb:153-158` sends `retry: 0001`, well inside the caller's maximum, and small events; the HTTP/2 and HTTP/3 integration tests do the same.

## What happens now

Spike: a raw loopback server that answers 200 `text/event-stream` with a chosen body, and a client opened with a chosen `Maximum_Event_Bytes` and `Maximum_Reconnect_Delay`. Four cases run; each compares `Ada.Exceptions.Exception_Identity` of what `Read` raised against the documented exception, so the check is on identity and not on the message. Two cases put the offending field first in the stream, and two put it after a complete event in the same write, which is the path through `Pending`.

```ada
   Run_Case
     (Label           => "retry over caller maximum (first event)",
      Stream_Body     => "retry: 5000" & LF & LF,
      Max_Delay       => 1.0,
      Warmup_Reads    => 0,
      Expected_Id     => SSE.Reconnect_Delay_Too_Large'Identity);
   ...
   Run_Case
     (Label           => "retry over caller maximum (bytes left in Pending)",
      Stream_Body     =>
        "data: x" & LF & LF & "retry: 5000" & LF & LF,
      Warmup_Reads    => 1,
      Expected_Id     => SSE.Reconnect_Delay_Too_Large'Identity);
```

```
  note contract: client-sse.ads:85-86 documents Event_Too_Large and
  note Reconnect_Delay_Too_Large as Read exceptions
  note retry over caller maximum (first event) observed FLYOLOGY.HTTP.CLIENT.SSE.INVALID_EVENT_STREAM: SSE HTTP exchange failed during RECEIVING_RESPONSE_BODY
  FAIL retry over caller maximum (first event) raises Reconnect_Delay_Too_Large
  note event over caller byte bound (first event) observed FLYOLOGY.HTTP.CLIENT.SSE.INVALID_EVENT_STREAM: SSE HTTP exchange failed during RECEIVING_RESPONSE_BODY
  FAIL event over caller byte bound (first event) raises Event_Too_Large
  note retry over caller maximum (bytes left in Pending) warm-up read 1 returned EVENT_AVAILABLE data [x]
  note retry over caller maximum (bytes left in Pending) observed FLYOLOGY.HTTP.CLIENT.SSE.RECONNECT_DELAY_TOO_LARGE: SSE retry field exceeds caller maximum
  ok   retry over caller maximum (bytes left in Pending) raises Reconnect_Delay_Too_Large
  note event over caller byte bound (bytes left in Pending) warm-up read 1 returned EVENT_AVAILABLE data [x]
  note event over caller byte bound (bytes left in Pending) observed FLYOLOGY.HTTP.CLIENT.SSE.EVENT_TOO_LARGE: SSE retained event bytes exceed caller bound
  ok   event over caller byte bound (bytes left in Pending) raises Event_Too_Large
checks: 4  failures: 2
BUG REPRODUCED
```

The first violation in a stream raises `FLYOLOGY.HTTP.CLIENT.SSE.INVALID_EVENT_STREAM`. The same violation reached through `Pending` raises the documented exception with the documented message.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

`Read` should raise `Event_Too_Large` or `Reconnect_Delay_Too_Large` for a breach of the caller's own `Maximum_Event_Bytes` or `Maximum_Reconnect_Delay` wherever the offending byte is parsed, as `src/flyology-http-client-sse.ads:85-86` states, and reserve `Invalid_Event_Stream` for a response that violates the EventSource contract.

## Suggested treatment

The identity is already preserved in `State.Failure_Cause`, so the fix is plumbing rather than new information, and there are two places to add it.

Inside the engine, a sink failure can set `Has_Saved_Error` alongside `Failure_Cause` so the composable `Finish` at `src/flyology-http-client.adb:1718-1742` re-raises it. That is the smaller edit, and it changes what every composable caller that installs a response sink observes for `Response_Sink_Failed`, not only the SSE layer, so it is an externally visible behaviour change on a public client path.

Inside the SSE layer, `Handle_Exchange_Failure` at `src/flyology-http-client-sse.adb:724-741` can read the preserved identity for a `Response_Sink_Failed` result and re-raise it before falling into the catch-all arm, leaving every other composable caller unchanged. That needs the identity to be readable from the exchange result.

Either placement keeps `Invalid_Event_Stream` for the cases that really are a bad response. Neither adds a public constant, default or parameter.

The regression test belongs in `tests/http1_sse_client_integration.adb`, whose raw server already writes a chosen first body: one case with a `retry` value above the caller's `Maximum_Reconnect_Delay` as the first field, asserting `Reconnect_Delay_Too_Large`, and one with a line above `Maximum_Event_Bytes`, asserting `Event_Too_Large`. The spike is the test, and it also pins the `Pending` path that already behaves correctly.

## Severity

A caller that sets its own limits cannot act on them. The two exceptions exist so that a caller can distinguish its own policy from a broken peer, retry with a larger bound, or report the right diagnostic; instead it sees `Invalid_Event_Stream` with a phase name and must guess. The trigger is ordinary: a server that sends a `retry` field larger than the caller allows, or an event larger than the caller allows, as the first thing on the stream. The behaviour is inconsistent rather than uniformly broken, because the same violation raises the documented exception when it follows a complete event in the same written slice, and the reconnect lifecycle reaches the correct state either way. Deterministic.
