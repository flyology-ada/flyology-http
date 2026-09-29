Title: The metrics series key includes the client-chosen request method and nothing evicts a filled table
Labels: bug
Refs: none

## Summary

`Metric_State.End_Request` keys a series on the triple route, method and status class. The route name is bounded by registration, but the method is the token the peer sent, and nothing in the sink ever clears an entry or reduces `Series`. A peer that sends distinct method tokens to any existing path fills the table with 405 series of its own choosing, after which every legitimate route, method and class combination first seen later is counted only in `Dropped_Series`. The capacity itself is documented and sound; what is not documented is that one of the three key components is peer-chosen and that a filled table is fill-once for the life of the sink.

## Problem

Commit `f078732`.

The metrics middleware passes the request method straight through (`src/flyology-http-server-middleware_metrics.adb:23-30`):

```ada
            Metrics.End_Request
              (Output.all,
               X.Request_Method,
               X.Route_Name,
               X.Response_Status,
               Ada.Real_Time.To_Duration (Ada.Real_Time.Clock - Started),
               X.Request_Body_Bytes,
               X.Response_Bytes);
```

The sink scans for the triple, appends while there is room, and otherwise counts a drop (`src/flyology-http-server-metrics.adb:54-72`):

```ada
         for Index in 1 .. Value.Series loop
            if Values (Index).Route_Length = Route'Length
              and then Values (Index).Method_Length = Method'Length
              and then Values (Index).Status_Class = Class
              and then Values (Index).Route (1 .. Route'Length) = Route
              and then Values (Index).Method (1 .. Method'Length) = Method
            then
               Found := Index;
               exit;
            end if;
         end loop;
         if Found = 0 then
            if Value.Series = Capacity then
               Value.Dropped_Series :=
                 Saturating_Add (Value.Dropped_Series, 1);
               return;
            end if;
            Value.Series := Value.Series + 1;
```

Nothing anywhere in `src/flyology-http-server-metrics.adb` clears a `Used` entry or reduces `Value.Series`, so the table only ever fills.

The capacity is a documented policy value and is not what this reports (`src/flyology-http-server-metrics.ads:80-83`):

```ada
   --  Default bounded-cardinality in-memory metric sink. Capacity is the
   --  maximum route/method/status-class series.
   type In_Memory (Capacity : Positive := 256) is
     limited new Sink with private;
```

and `website/guide/server/index.html:469` states that the default sink "caps route/method/status-class series and reports dropped series rather than growing without bound".

The route component is bounded as documented (`src/flyology-http-server-metrics.ads:39`):

```ada
   --  @param Route Stable route name, never an arbitrary raw path
```

The method component is not. HTTP/1 validates the method as a token with no length bound (`src/flyology-http-server.adb:1164-1168`):

```ada
         Validate_Token
           (Request_Line (Request_Line'First .. First_Space - 1),
            "HTTP method");
         Value.Method_Value := To_Unbounded_String
           (Request_Line (Request_Line'First .. First_Space - 1));
```

and HTTP/2 and HTTP/3 accept any token up to 64 bytes (`src/flyology-http.adb:14`):

```ada
      if Value'Length not in 1 .. 64
```

Anything at or under `Max_Method_Length`, which is 16 (`src/flyology-http-server-metrics.ads:120`), becomes a stored key. Every unknown method to an existing path is answered 405 through `Run_Automatic`, which runs the metrics middleware with `Route_Name = "flyology.method_not_allowed"`, so the method is the only component that varies.

The existing coverage pins the bound but never varies the method: `tests/http_smoke.adb:3322-3323` asserts `Metrics.Series = 1` and `Metrics.Dropped_Series > 0` with a capacity-limited sink driven by a single method.

## What happens now

Spike: an in-memory sink with `Capacity => 4`, one route `GET /x`, and the metrics middleware. It sends four requests with distinct five-byte method tokens to `/x`, each answered 405, then a legitimate `GET /x` answered 200, then repeats the legitimate request and reads the snapshot.

```ada
   Sink : aliased Metrics.In_Memory (Capacity => 4);
   ...
   function Flood_Method (Index : Natural) return String is
      Digits_Text : constant String := "0123456789";
   begin
      return "M" & Digits_Text (Digits_Text'First + (Index / 1_000) mod 10)
        & Digits_Text (Digits_Text'First + (Index / 100) mod 10)
        & Digits_Text (Digits_Text'First + (Index / 10) mod 10)
        & Digits_Text (Digits_Text'First + Index mod 10);
   end Flood_Method;
```

```
  note series before flood 0, dropped 0
  note flood M0000 /x -> 405
  ok   an unknown method to an existing path answers 405
  note flood M0001 /x -> 405
  ok   an unknown method to an existing path answers 405
  note flood M0002 /x -> 405
  ok   an unknown method to an existing path answers 405
  note flood M0003 /x -> 405
  ok   an unknown method to an existing path answers 405
  note series after flood 4, dropped 0
  ok   the flood filled the series table (evidence the method is the varying key)
  note legitimate GET /x -> 200
  ok   the real route still answers 200
  note series after the real request 4, dropped 1
  FAIL a legitimate route/method/class series first seen after a method flood is not dropped
  note final requests 15, series 4, dropped 11
  FAIL the sink recovers: repeated legitimate traffic is counted per series again
checks: 8  failures: 2
BUG REPRODUCED
```

Four peer-chosen method tokens fill the table with `Dropped_Series` still zero. The `GET` 200 that follows is dropped, and so is every legitimate request after it: fifteen requests counted in the aggregate and none in any series.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

Which series occupy a bounded table should be decided by the server, not by the peer, and a table filled by traffic that no longer arrives should not permanently exclude traffic that does. The documented behaviour, that the sink "caps route/method/status-class series and reports dropped series rather than growing without bound" (`website/guide/server/index.html:469`), is compatible with both a server-chosen method key and an eviction rule; it is the absence of either that makes a peer the owner of the table.

## Suggested treatment

Two independent changes close this, and both are policy choices rather than mechanical fixes.

The method key can be made server-chosen: count a request whose method is not one the router has registered, or not one of the standard tokens, under a single fixed key instead of storing the peer's token. That bounds the third component the way `Route` is already bounded and leaves ordinary traffic unchanged.

The table can be made recoverable rather than fill-once: an entry that has not been observed recently can be replaced instead of a new series being dropped, the way the rate limiter's bucket table already takes over its least recently seen slot (`src/flyology-http-server-middleware_rate_limits.adb:94-95`).

This needs a maintainer decision: both changes introduce externally visible policy. For the method key, the options are a private implementation value holding the accepted token set, a value derived from the router's registered methods, a generic formal on the sink, or a deliberately public constant. For eviction, the options are a private implementation value for the idle threshold, a discriminant on `In_Memory` beside `Capacity`, a generic formal, build-time configuration, or a deliberately public constant; the alternative is to leave the table fill-once and document that a peer can choose its contents. Neither the number 256 nor `Max_Method_Length` needs to change for either option.

The regression test belongs in `tests/http_smoke.adb` beside the existing capacity assertions at `:3322-3323`, extended to vary the method across a capacity-limited sink and then assert that a legitimate route, method and class series is still recorded. The spike is the test.

## Severity

Observability only. Memory stays bounded, the loss is counted in `Dropped_Series`, and the aggregate request, latency and byte counters keep working, so no request is mishandled and nothing grows without limit. The cost is that a peer that sends a few hundred distinct method tokens to any existing path decides, permanently, which per-series metrics a deployment can see, and the effect survives until the sink is recreated. It needs no authentication and works on any protocol. Deterministic.
