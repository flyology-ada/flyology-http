Title: A cancellation token does not interrupt the reconnect wait of the blocking SSE Read
Labels: bug
Refs: none

## Summary

`Read` promises that cancellation and the absolute deadline interrupt reconnect waits. `Begin_Reconnect` honours the deadline, by clamping the interval to the time remaining, but arms the timer with no token, and the `Waiting_Reconnect` arm of the driver checks the token only after the timer has fired. A token requested during the wait therefore has no effect until the full interval has elapsed, so the call blocks for whatever reconnect delay the server chose, up to the caller's own `Maximum_Reconnect_Delay`, and only then raises `Operation_Cancelled`.

## Problem

Commit `f078732`.

The contract (`src/flyology-http-client-sse.ads:74-77`):

```ada
   --  Return the next event, reconnecting after clean EOF or recoverable
   --  transport failure.  HTTP 204 returns Stream_Stopped and permanently
   --  disables reconnect.  Cancellation and the absolute deadline interrupt
   --  requests, reads, and reconnect waits using their ordinary exceptions.
```

The wait (`src/flyology-http-client-sse.adb:648-661`):

```ada
      procedure Begin_Reconnect is
         Interval : Duration :=
           Policy.Selected_Wait_Delay (Item.Source.Lifecycle);
      begin
         Finalize (Item.Source.Reply);
         Item.Source.Connected := False;
         if Item.Source.Deadline.Is_Limited then
            Interval := Duration'Min
              (Interval, Remaining (Item.Source.Deadline));
         end if;
         Flyology.IO.Timers.Sleep_For (Interval, Item.Timer.all);
         Item.Phase := Waiting_Reconnect;
         Flyology.Operations.Continue_After (Item, Item.Timer.all);
      end Begin_Reconnect;
```

The deadline half of the promise is the `Duration'Min` at `:655-656`. The token is never passed to `Sleep_For`, and the completion arm consults it only after the timer has finished (`src/flyology-http-client-sse.adb:890-896`):

```ada
         when Waiting_Reconnect =>
            Flyology.IO.Timers.Finish (Item.Timer.all);
            Flyology.Operations.Release (Item.Timer.all);
            Policy.Reconnect_Wait_Elapsed (Item.Source.Lifecycle);
            Check_Control (Item.Source.all, Item.Token);
```

`Check_Control` is what turns a requested token into the exception (`src/flyology-http-client-sse.adb:58-67`):

```ada
   procedure Check_Control
     (Item  : Event_Source;
      Token : access Flyology.Cancellation.Token) is
   begin
      if Token /= null and then Token.Requested then
         raise Flyology.Cancellation.Operation_Cancelled;
```

so the exception identity is right and only the timing is wrong. The one path that cancels the timer early is `Request_Cancellation` (`src/flyology-http-client-sse.adb:934-961`), reached through `Flyology.Operations.Cancel` on the `Read_Operation`; the blocking overload builds that operation internally and never exposes it (`src/flyology-http-client-sse.adb:524-539`):

```ada
      Set       : aliased Flyology.Operations.Completion_Set (4);
      Operation : Read_Operation := Read
        (Set'Access, Item'Unchecked_Access, Token);
   begin
      Flyology.Operations.Wait_All (Set);
      Finish (Operation, Result, Value);
   end Read;
```

A caller that uses the documented `Token` parameter has no way to reach it.

There is no existing coverage: all three maintained SSE integration tests pass `Token => null` and use a one millisecond retry.

## What happens now

Spike: a raw loopback server that sends `retry: 3000` LF `data: a` LF LF and closes. The client is opened with `Maximum_Reconnect_Delay => 10.0`, so it adopts the server's three second delay. The first `Read` returns the event; a second task requests the token 0.2 s after the second `Read` enters the reconnect wait; the program times that second `Read` and checks both the exception and the elapsed time against a one second budget.

```ada
   Server_Retry_Seconds  : constant Duration := 3.0;
   Caller_Maximum_Delay  : constant Duration := 10.0;
   Cancel_After_Seconds  : constant Duration := 0.2;
   Prompt_Return_Seconds : constant Duration := 1.0;

   Stream_Body : constant String :=
     "retry: 3000" & LF & "data: a" & LF & LF;
   ...
      task body Canceller is
      begin
         while not Armed loop
            delay 0.005;
         end loop;
         delay Cancel_After_Seconds;
         Stop.Request;
      end Canceller;
```

```
  note contract: client-sse.ads:74-77 says cancellation interrupts
  note reconnect waits using its ordinary exception
  ok   first read returned an event
  ok   first event data
  ok   server retry adopted as the reconnect delay
  note cancellation requested 0.200000000 s into a 3.000000000 s reconnect wait
  note second Read outcome: FLYOLOGY.CANCELLATION.OPERATION_CANCELLED
  note second Read took 3.002937458 s
  ok   cancelled reconnect wait raises Operation_Cancelled
  FAIL cancelled Read returns within 1.000000000 s (took 3.002937458 s)
checks: 5  failures: 1
BUG REPRODUCED
```

The call returned after 3.002937458 s, that is when the timer fired, about 2.80 s after the token was requested, with no observable shortening. The exception is the documented one.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A token requested during a reconnect wait should end the wait promptly and raise `Operation_Cancelled`, as `src/flyology-http-client-sse.ads:74-77` states, rather than only being noticed once the interval has elapsed. The deadline half of that sentence already behaves this way through the clamp at `src/flyology-http-client-sse.adb:654-657`.

## Suggested treatment

Make the token reach the timer child while it is armed. Two shapes are available and neither adds a public value.

The blocking `Read` at `src/flyology-http-client-sse.adb:524-539` already receives the token and constructs the `Read_Operation` and its completion set. It can cancel that operation when the token is requested, which routes through `Request_Cancellation` at `:934-961`, the path that already cancels the timer child and that `Flyology.IO.Timers.Finish` already turns into `Operation_Cancelled`. That reuses the working mechanism and leaves the composable overload unchanged.

Alternatively, `Begin_Reconnect` can arm the wait so that a requested token completes it, in the same way the deadline already bounds it, rather than sleeping for the whole interval and testing afterwards.

The regression test belongs in `tests/http1_sse_client_integration.adb`, whose raw server already controls the first body: send a `retry` large enough to be observable, close, request a token shortly after the next `Read` enters the wait, and assert both `Operation_Cancelled` and an elapsed time well under the retry interval. The spike is the test.

## Severity

An application that cancels a blocked `Read`, at shutdown or when switching streams, keeps a task parked for as long as the reconnect interval the server chose. The delay is bounded by the caller's own `Maximum_Reconnect_Delay`, so this is a large unwanted latency rather than a hang, and the call does eventually raise the documented exception. The server controls the magnitude: a `retry` field anywhere up to that ceiling pins the calling task, and the measured case is three seconds for a cancellation requested two tenths of a second in. Every caller that passes a `Token` to `Read` is affected, which is the documented way to cancel one. Deterministic.
