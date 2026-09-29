Title: A negative Set_Expect_Continue wait sends the request body immediately instead of waiting to the deadline
Labels: bug
Refs: none

## Summary

`Set_Expect_Continue` documents a negative `Wait_Timeout` as "waits within the whole exchange deadline", but `Probe_Early_Response` arms the continue wait with that value unchanged, and the pinned runtime treats any nonpositive interval as already due. The next completion-set drive therefore reports `Deadline_Reached`, the probe gives up and the body is transmitted at once. A negative wait behaves exactly like zero, so a caller who asked to wait for `100 Continue` for as long as the exchange allows sends the whole body to a server that may have rejected the request on the head alone.

## Problem

Commit `f078732`.

The contract (`src/flyology-http-client.ads:217-226`):

```ada
   --  Enable or disable the Expect: 100-continue handshake. When enabled for
   --  a nonempty retained or streaming body, Execute sends the request head
   --  first and waits up to Wait_Timeout for 100 Continue or a final response.
   --  A positive wait expiry with no partial response sends the body; a
   --  negative value waits within the whole exchange deadline and zero sends
   --  immediately after the head. A final response suppresses body reads and
   --  transmission. A 417 final response received before body transmission
   --  is retried once on a fresh transport without the expectation, within
   --  the same deadline and shared automatic-retry budget. The whole exchange
   --  deadline is never extended.
```

`Set_Expect_Continue` stores the value unchanged (`src/flyology-http-client.adb:2217-2224`):

```ada
   procedure Set_Expect_Continue
     (Item         : in out Request;
      Enabled      : Boolean := True;
      Wait_Timeout : Duration := 1.0) is
   begin
      Item.Expect_Continue := Enabled;
      Item.Continue_Wait := Wait_Timeout;
   end Set_Expect_Continue;
```

and nothing between it and the probe normalizes it.

`Probe_Early_Response` arms the wait in two branches, and neither treats a negative value specially (`src/flyology-http-client.adb:3767-3782`):

```ada
            when Connection_Drivers.Need_Read =>
               if State.Expect_Waiting
                 and then Event /= Flyology.Operations.Deadline_Reached
               then
                  Connection_Drivers.Arm_Transport
                    (State.IO, Item, Connection_Drivers.Need_Read);
                  if State.Deadline.Is_Limited then
                     Flyology.Operations.Drivers.Arm_Deadline
                       (Item,
                        Duration'Min
                          (State.Request_Item.Continue_Wait,
                           Remaining (State.Deadline)));
                  else
                     Flyology.Operations.Drivers.Arm_Deadline
                       (Item, State.Request_Item.Continue_Wait);
                  end if;
               else
                  State.Expect_Waiting := False;
```

Both branches reach the same outcome. With a limited deadline, `Duration'Min` of a negative value and the remaining budget is the negative value. With an unlimited deadline, the negative value is armed directly.

The pinned dependency decides what a negative interval means. `alire/alire.lock` pins `flyology` at `=0.1.1-dev`, commit `bd95746d5c9c31f5b41b611db9ba82a016ceaaa4`. In that source the contract is explicit (`src/flyology-operations-drivers.ads:58-59` of the pinned `flyology`): "Set or replace one operation deadline. A nonpositive interval is due on the next completion-set drive." The body implements exactly that:

```ada
      Item.Set.Slots (Id).Deadline :=
        (if Interval <= 0.0
         then Now
         elsif Interval >= Duration'Last - Now
         then Duration'Last
         else Now + Interval);
```

So the next drive arrives with `Event = Deadline_Reached`, the `and then Event /= Flyology.Operations.Deadline_Reached` guard fails, the `else` arm clears `Expect_Waiting` and resumes the body, and the negative value is indistinguishable from zero.

The wire behaviour is legal. RFC 9110 section 10.1.1 says "A client that sends a 100-continue expectation is not required to wait for any specific length of time; such a client MAY proceed to send the content even if it has not yet received a response." What is violated is the crate's own specification sentence, and with it the whole point of the opt-in: a server that would have answered 401, 413 or 417 on the head alone receives the entire body.

No maintained test passes a negative wait. `tests/http_client_upload_controls_smoke.adb` covers `1.0` at `:472`, `:488` and `:526`, `0.02` at `:510` and the default at `:657`, so the documented negative branch is unexercised.

## What happens now

Spike: a raw `Flyology.IO.Sockets` peer reads the request head, then watches the socket for 0.4 s before answering `100 Continue`, counting any body octet that arrives in that window. The real `Flyology.HTTP.Client` runs two exchanges against it on one client with a 4096-byte retained body and a 10.0 s exchange deadline, one with `Wait_Timeout => 1.0` and one with `Wait_Timeout => -1.0`. Each check asserts that no body byte precedes the `100 Continue`.

```ada
         HC.Set_Expect_Continue (Request, Wait_Timeout => Wait);
         HC.Set_Body (Request, Payload);
   ...
      One (Positive_Wait, 1.0, "/positive-wait");
      One (Negative_Wait, -1.0, "/negative-wait");
   ...
   Check (Coordination.Early (Negative_Wait) = 0,
          "a negative wait sends no body before 100 Continue, because it"
          & " waits within the whole exchange deadline");
```

```
  note request body is 4096 bytes; the peer withholds 100 Continue for 0.400000000 s; the exchange deadline is 10.0 s
  ok   POSITIVE_WAIT: the exchange completes
  ok   NEGATIVE_WAIT: the exchange completes
  note body bytes seen before 100 Continue, Wait_Timeout =>  1.0: 0
  note body bytes seen before 100 Continue, Wait_Timeout => -1.0: 4096
  ok   control: a positive wait sends no body before 100 Continue
  FAIL a negative wait sends no body before 100 Continue, because it waits within the whole exchange deadline
checks: 4  failures: 1
BUG REPRODUCED
```

With a positive wait the peer sees zero body octets before it answers. With a negative wait it sees all 4096.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A negative `Wait_Timeout` should leave the continue wait bounded only by the exchange deadline, so the body is withheld until `100 Continue`, a final response or the exchange deadline arrives. That is what `src/flyology-http-client.ads:220-222` promises.

## Suggested treatment

Normalize the negative case where the wait is armed, so that a negative `Continue_Wait` selects the remaining exchange budget rather than being passed through:

```ada
                  if State.Request_Item.Continue_Wait < 0.0 then
                     if State.Deadline.Is_Limited then
                        Flyology.Operations.Drivers.Arm_Deadline
                          (Item, Remaining (State.Deadline));
                     else
                        Flyology.Operations.Drivers.Clear_Deadline (Item);
                     end if;
                  elsif State.Deadline.Is_Limited then
                     ...
```

Both branches at `src/flyology-http-client.adb:3773-3782` need the guard, because an unlimited exchange deadline reaches the second one. The alternative is to normalize once in `Set_Expect_Continue` (`src/flyology-http-client.adb:2217-2224`), which loses the distinction between a negative value and zero in the stored request and would change what `Continue_Wait` means to any later reader.

`src/flyology-http-client.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in `tests/http_client_upload_controls_smoke.adb`, beside the existing `1.0` and `0.02` cases at `:472-526`: a raw peer that withholds `100 Continue` and asserts that no body byte arrives first under a negative wait. The spike is the test.

## Severity

A caller who opts into `Expect: 100-continue` with a negative wait gets no wait at all, so the body is transmitted before the server has had any chance to reject the request on the head. The effect is the loss of the opt-in, not a protocol violation: the exchange still completes and the server is required to cope with an early body, so an interoperating peer sees nothing wrong. It needs a negative `Wait_Timeout`, which is one of the three documented values and the one a caller picks to bound the wait by the exchange deadline. Deterministic. HTTP/1 only, since the HTTP/2 and HTTP/3 engines reject the handshake.
