Title: Shutdown racing HTTP/3 establishment reports `Transport_Failed` instead of `Client_Unavailable`
Labels: bug
Refs: none

## Summary

`Pool_Controller.Install` and `Publish_Connecting` both raise `Client_Closed` when the pool is stopping. On the DNS, TCP connect and TLS establishment paths the enclosing handler tests `Owner.Pool.Is_Stopping` and produces `Client_Unavailable`. The HTTP/3 path has no such test on either of its two routes, so a `Shutdown` that races HTTP/3 establishment produces `Transport_Failed`, which the synchronous wrapper turns into `Flyology.IO.Device_Error`. The caller of `Execute` sees a device error where the specification documents `Client_Closed` for a stopping client, and a composable caller sees `Transport_Failed` where the typed result defines `Client_Unavailable` for exactly this case.

## Problem

Commit `f078732`. This is reported from reading the code; the classification disagreement below is established by the three quoted sites, but the race itself was not driven, because parking an exchange at the HTTP/3 handoff requires the connection test-hook implementation, which `flyology_http.gpr:7-20` selects only when the external `FLYOLOGY_CONNECTION_TEST_HOOKS` is `"true"`, and that is a separate library build. The test belongs in the suite that is already built that way; see Suggested treatment.

### What is established

Four establishment handlers run on the same engine. Three carry the stopping test and one does not.

DNS (`src/flyology-http-client.adb:5560-5563`):

```ada
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
```

TCP connect, `Waiting_For_Connect` (`src/flyology-http-client.adb:5593-5596`):

```ada
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
```

TLS, `Waiting_For_TLS` (`src/flyology-http-client.adb:5653-5656`):

```ada
                  Fail_Exchange
                    (Item,
                     (if Owner.Pool.Is_Stopping
                      then Client_Unavailable else Connection_Failed));
```

HTTP/3, the handler closing `Drive_HTTP_3_Protocol` (`src/flyology-http-client.adb:5414-5417`):

```ada
      exception
         when Error : others =>
            Remember_Failure (State, Error);
            Fail_Exchange (Item, Transport_Failed);
      end Drive_HTTP_3_Protocol;
```

The two raises it has to classify are unconditional. `Pool_Controller.Install` raises at `src/flyology-http-client-pool_controller.adb:293-294` and `Publish_Connecting` at `:338-339`, both as `elsif Stopping then raise Client_Closed;`.

Both have a route into the HTTP/3 path and both lose the classification.

1. `Pool.Install` inside the `HTTP_3_Open_Request` arm (`src/flyology-http-client.adb:4963-4967`) is caught by the handler quoted above and becomes `Transport_Failed`.
2. `Publish_Connecting` at `src/flyology-http-client.adb:3272-3273` has no arm-local handler at all. Reached from `Preparing_Connect` or `Preparing_Resolved_Address` (`:5498-5502`), which is the path taken when the origin needs no name lookup, it falls through to the engine's outer handler (`:6017-6022`), which also produces `Transport_Failed`. Reached instead through `Waiting_For_DNS` it is mapped correctly, so the outcome depends on whether a name lookup was required, which is itself a reason to fix it.

The synchronous wrapper then re-raises `Failure_Cause` only for `TLS_Error`, `Protocol_Error`, `Response_Too_Large`, `Device_Error`, `Socket_Error` and `Request_Source_Failed` (`src/flyology-http-client.adb:6550-6566`). `Client_Closed` is not in that set, so the result falls to the kind mapping (`:6581-6582`):

```ada
            when Transport_Failed =>
               raise Flyology.IO.Device_Error;
```

The two contracts this contradicts. For the synchronous path (`src/flyology-http-client.ads:510`):

```ada
   --  @exception Client_Closed Client is stopping
```

For the composable path (`src/flyology-http-client.ads:690`):

```ada
   --  @enum Client_Unavailable Client is stopped or cannot admit new work
```

Under `Negotiate_HTTP_3` the outcome can self-correct: the address-retry branch replays through TCP, where `Try_Checkout` returns `Checkout_Closed` and the arm maps it directly (`src/flyology-http-client.adb:5494-5495`):

```ada
               when Checkout_Closed =>
                  Fail_Exchange (Item, Client_Unavailable);
```

Under `Require_HTTP_3` there is no such replay, so the misclassification stands.

### What is not established

The race was not driven, so this issue does not claim a measured frequency or a specific interleaving window. The `Negotiate_HTTP_3` self-correction above is read from the code and was not exercised either. What is established is that the three sibling handlers classify a stopping pool and the HTTP/3 handler does not, and that neither HTTP/3 route has any other site that could restore the classification before the caller sees it.

Why the tests do not catch it: `tests/http_client_pool_races.adb` exercises shutdown races and asserts `Client.Client_Closed` on the paths it covers (`:293`, `:348`, `:480`), but none of its cases drives an HTTP/3 establishment. No maintained test requests shutdown while an exchange is between `Publish_Connecting` and a completed HTTP/3 handshake.

## Failure scenario

1. A client is configured `Require_HTTP_3` against an origin whose address needs no name lookup.
2. Task A calls `Execute`. The exchange reaches `Preparing_Resolved_Address`, runs a purely local UDP `Connect_Socket`, and calls `Publish_Connecting` at `src/flyology-http-client.adb:3272-3273`. No live peer is needed to get this far.
3. Task B calls `Shutdown`. The pool becomes `Stopping`.
4. `Publish_Connecting` raises `Client_Closed` at `src/flyology-http-client-pool_controller.adb:338-339`. The arm has no handler, so the engine's outer handler at `src/flyology-http-client.adb:6017-6022` completes the exchange as `Transport_Failed`.
5. Task A's `Execute` raises `Flyology.IO.Device_Error` (`:6581-6582`). A composable caller's `Finish` reports `Transport_Failed`. Both contradict the contract for a stopping client, and a caller that distinguishes "the client is shutting down" from "the network broke" takes the wrong branch, for example by retrying against an origin it should be abandoning.

The same shape through the second route ends in the handler at `:5414-5417` with the same two outcomes.

## What should happen

An exchange failed because the pool is stopping reports `Client_Unavailable` on the composable path and raises `Client_Closed` from `Execute`, on every establishment path including HTTP/3, as `src/flyology-http-client.ads:510` and `:690` state and as the DNS, TCP and TLS handlers already do.

## Suggested treatment

Give the HTTP/3 path the classification its three siblings have. In the handler at `src/flyology-http-client.adb:5414-5417`, replace the unconditional `Fail_Exchange (Item, Transport_Failed)` with the same conditional the other three use, and give the `HTTP_3_Open_Request` arm's `Pool.Install` call at `:4963-4967` an arm-local handler so a stopping pool is classified there rather than by the generic handler. The second route needs `Publish_Connecting` at `:3272-3273` covered as well, either by an arm-local handler in `Preparing_Connect` and `Preparing_Resolved_Address` or by teaching the engine's outer handler at `:6017-6022` to test `Owner.Pool.Is_Stopping`. Testing `Is_Stopping` rather than the exception identity keeps the four handlers written the same way; matching on `Client_Closed'Identity` would work too and is the narrower change.

The fix needs no task and no new state, which matters because `scripts/test.sh:75-84` requires the client units to declare no helper task.

The regression test belongs in `tests/http_client_pool_races.adb`, which is one of the three mains `scripts/test.sh:173-186` builds with `FLYOLOGY_CONNECTION_TEST_HOOKS=true`, so the barrier is already linked there. The barrier point to use exists: `src/flyology-http-client.adb:3335-3337` parks at `Connection_Test_Hooks.Barrier (16)`, and `16` is `Barrier_Point'Pos (Before_HTTP_Client_Connect)` from `tests/flyology-io-connections-testing.ads:3-19`. It sits immediately before `if State.Creating_HTTP_3 then Start_HTTP_3_Connection (Address);` at `:3348-3349`, and `Publish_Connecting` runs after a purely local UDP connect, so no live QUIC peer is needed. The test should park a `Require_HTTP_3` exchange at that point, call `Shutdown` from a second task, release the barrier, and assert that the composable result is `Client_Unavailable` and that `Execute` raises `Client_Closed`. `tests/http_client_deadline_matrix.adb:387-392` already parks at the same point and is the pattern to copy. The `Pool.Install` route has no barrier of its own and would need one added beside `:4963` to be covered the same way.

The fix is confined to `src/flyology-http-client.adb`, which `./scripts/prove.sh` does not prove.

## Severity

A caller that shuts a client down while an HTTP/3 exchange is establishing gets `Flyology.IO.Device_Error` from `Execute`, or `Transport_Failed` from a typed `Finish`, instead of the stopping-client outcome both specifications document. No request is sent twice, no bytes are wrong, and the exchange fails either way; what is wrong is which failure the caller is told about, which is the difference between abandoning the origin and retrying it. It needs a concurrent `Shutdown` during HTTP/3 establishment, and under `Negotiate_HTTP_3` the TCP replay usually corrects the outcome, so the reliably wrong case is `Require_HTTP_3`. Not reproduced; HTTP/3 only.
