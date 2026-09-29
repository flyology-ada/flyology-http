Title: Synchronous safe-method exchanges can replay twice, one engine retry plus one wrapper retry
Labels: bug
Refs: CLIENT-POOL-5

## Summary

Two independent stale-transport retry sites can both fire for one `Execute`. The engine's internal retry re-enters `Exchange_Idle`, the next checkout sets `Was_Reused` again, and the synchronous wrapper's own predicate is still satisfied because the engine never touches the wrapper's retry flag. A single safe-method `Execute` against two dead idle transports therefore touches three transports and charges `Stale_Retries` twice, where `Client_Diagnostics` documents an idempotent exchange as "retried once". Only safe methods with no request source reach the engine branch, so nothing on the wire is semantically wrong; the documented retry bound and the diagnostic counter a caller would use to detect churn are what drift.

## Problem

Commit `f078732`.

The counter's contract (`src/flyology-http-client.ads:162-163`):

```ada
   --  @field Stale_Retries Idempotent exchanges retried once after an existing
   --     transport failed before producing response bytes
```

The engine's retry is guarded by a one-shot flag, but it recycles the exchange through the idle checkout (`src/flyology-http-client.adb:927-956`):

```ada
      if Item.State.Target in Buffer_Target | Response_Head_Target
        and then Item.State.Result.Admission = Possibly_Admitted
        and then Item.State.Was_Reused
        and then not Item.State.Safe_Retry_Used
        ...
         Item.State.Safe_Retry_Used := True;
         Item.State.Was_Reused := False;
         --  The replacement is allowed only for a safe method, but the first
         --  transport handoff remains observable: admission certainty is
         --  monotonic across an internal stale-connection retry.
         ...
         Item.State.Driver_State := Exchange_Idle;
```

Re-entering `Exchange_Idle` runs `Try_Checkout` again, and the idle arm sets the flag back (`src/flyology-http-client.adb:5456-5459`):

```ada
               when Checkout_Idle =>
                  State.Connection := Connection;
                  State.Slot_Index := Index;
                  State.Was_Reused := True;
```

Admission stays `Possibly_Admitted` across that retry, which the code states in place at `:945-947`. That disables the engine's own branch a second time, because of `Safe_Retry_Used`, but it still satisfies the wrapper's predicate, which accepts both admission values and reads a flag the engine never writes (`src/flyology-http-client.adb:6528-6537`):

```ada
      elsif not Retried.all
        and then Operation.State.Was_Reused
        and then Result.Admission in Not_Admitted | Possibly_Admitted
        and then Result.Result_Kind in
          Connection_Failed | Transport_Failed | Response_Invalid
        and then Is_Idempotent (Value.Method_Value)
        and then not Has_Mutation_Condition
        and then
          (Source = null
             or else Source.all in Rewindable_Request_Body_Source'Class)
```

`Retried.all` is the wrapper's own flag and is set only at `:6546`. Nothing in `Fail_Exchange` sets it, so the engine retry is invisible to the wrapper and the wrapper retry is invisible to the engine's guard.

By inspection and not reproduced: the second engine branch, the pre-handoff replay at `src/flyology-http-client.adb:957-972` (`Admission = Not_Admitted and then Was_Reused`), has no `Safe_Retry_Used`-style guard at all and also clears only `Was_Reused`, so on its own terms it can fire once per dead idle transport. The spike's count of 2 is equally consistent with the first branch plus the wrapper, so this issue does not claim an unbounded case; it is worth checking when the fix is made.

The replay decision used to be a single proved classifier, `Flyology.HTTP.Client_Policy.Classify_Stale_Retry`, which now has no caller anywhere under `src/`; the split into two hand-written predicates with different inputs is how the two sites came to disagree. That is {{ISSUE:CLIENT-POOL-5}}.

Why the tests do not catch it: `tests/http_client_composable_stale_reuse.adb:306` asserts `Stale_Retries = 1` with a single stale idle connection, which is the case that behaves. The post-handoff shape is deliberately arranged there (`:239-246`, "Delay this deterministic oracle until the next safe request has reached the peer so the client must exercise its guarded Possibly_Admitted/no-response retry"), but no maintained test primes two idle transports.

## What happens now

Spike: an `HTTP_1_Only` client with `Pool => (Max_Idle => 2, others => <>)` primes two idle transports, then issues one `GET`. The origin closes each pooled transport only after reading the retried head, which is the post-handoff shape, and answers 200 on the third. The program asserts the documented bound: one retry charged for one exchange.

```ada
      Client.Configure
        (HTTP, Origin, Client.HTTP_1_Only,
         Pool => (Max_Idle => 2, others => <>));
      declare
         Prime_1, Prime_2 : Primer;
      begin
         null;
      end;
...
         Before : constant Natural :=
           Client.Diagnostics (HTTP).Stale_Retries;
...
         Client.Set_Target (Request, "/retry");
...
         Retry_Count :=
           Client.Diagnostics (HTTP).Stale_Retries - Before;
```

```
  note pooled transports that received the retried head: 2
  note Stale_Retries charged to the exchange: 2
  ok   Execute completes the exchange
  ok   the fresh transport answers 200
  ok   the response body arrives
  FAIL the .ads documents Stale_Retries as an idempotent exchange 'retried once'
         expected: 1   actual: 2
checks: 4  failures: 1
BUG REPRODUCED
```

Both pooled transports received the retried head, so three transports are touched where the contract describes two. The exchange still completes and the response is correct.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

One `Execute` retries a stale transport at most once, and `Client_Diagnostics.Stale_Retries` advances by at most one for that exchange, as `src/flyology-http-client.ads:162-163` states.

## Suggested treatment

Make the two retry sites share one budget instead of keeping two private flags. The smallest change is for the engine's retry at `src/flyology-http-client.adb:927-956` to record its use where the wrapper can see it, so that the wrapper's `not Retried.all` test at `:6528` is already false when the engine has replayed; `Safe_Retry_Used` is already on the exchange state and is a candidate carrier. While making that change, give the pre-handoff branch at `:957-972` an explicit bound as well.

This needs a maintainer decision: the fix has to settle what "retried once" counts, and the options differ in what the documented bound and the counter then mean.

- one retry per exchange, shared by both sites, which matches the current `.ads` sentence and the counter as documented;
- one retry per stale transport, which is what the code does today and would require amending `src/flyology-http-client.ads:162-163` and stating the bound in terms of the pool's idle capacity;
- a value derived from the pool configuration, for example at most `Max_Idle` replacements, which introduces a new relationship between the pool capacity and the retry budget.

Do not resolve this by relaxing the counter alone: the observable effect is the number of transports the origin sees, not just the diagnostic.

The regression test belongs in the existing stale-reuse suite, `tests/http_client_composable_stale_reuse.adb`, beside the single-transport case at `:306`: prime two idle transports, close both after handoff, run one `GET`, and assert `Stale_Retries` advances by one and that three peers are accepted in total. The spike above is that test. The existing assertion at `:306` stays correct under either decision above, since it primes only one transport.

The fix is confined to `src/flyology-http-client.adb`, which `./scripts/prove.sh` does not prove. If the fix instead restores `Flyology.HTTP.Client_Policy.Classify_Stale_Retry` as the single decision point, that unit is proved and the proof must keep discharging with `--checks-as-errors=on`.

## Severity

A safe-method `Execute` can replay one more time than documented and charge the diagnostic counter twice. Only safe methods with no request source reach the engine branch, so no request is duplicated in a way a server can act on and no response is wrong; the visible effects are an extra connection attempt against the origin and a retry counter that cannot be used to detect churn. It needs at least two dead idle transports in the pool, which happens after an origin restart. Deterministic.
