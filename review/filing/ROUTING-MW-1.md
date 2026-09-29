Title: The 400 for a path with more than 64 segments bypasses the middleware chain and automatic admission
Labels: bug
Refs: none

## Summary

`Dispatch_Configuration` converts a `Decode_Path` failure into a flag so the malformed-path 400 is issued through `Run_Automatic`, but the `Split_Path` call that rejects an over-segmented path sits outside that conversion. Its `Route_Error` unwinds to the outermost handler, which writes the 400 directly with no route configured and no pipeline. `Set_Automatic_Admission` names exactly this response as one it meters, so a peer gets an unmetered, unlogged, header-less 400 that it can repeat without limit on any router that relies on that setter to bound unmatched-path traffic.

## Problem

Commit `f078732`.

The decode failure is converted into a flag inside a local function (`src/flyology-http-server-routing.adb:1828-1835`):

```ada
      function Decode_For_Dispatch return String is
      begin
         return (if Raw = "*" then "*" else Decode_Path (Raw));
      exception
         when Route_Error =>
            Invalid_Path := True;
            return "/";
      end Decode_For_Dispatch;
```

`Split_Path` is called after it, outside any such conversion (`src/flyology-http-server-routing.adb:1894-1895`):

```ada
   begin
      Split_Path (Path_Value, Path_Segments);
```

and raises its own `Route_Error` at the segment bound (`src/flyology-http-server-routing.adb:399-401`), where `Max_Segments` is 64 (`src/flyology-http-server-routing.ads:1350`):

```ada
         if Result.Count = Max_Segments then
            raise Route_Error with "too many HTTP path segments";
         end if;
```

That raise reaches the outermost handler, which answers directly (`src/flyology-http-server-routing.adb:2086-2090`):

```ada
   exception
      when Route_Error =>
         if not X.Wire_Response_Started then
            X.Problem (400, "invalid-path", "Request path is malformed");
         end if;
```

No `Configure_Route`, no `Seal_Route` and no `Run_Automatic` run on that path, so the response carries no request id, no security headers, is not logged or counted, and is not admitted through the automatic-response policy. The contract names this response explicitly (`src/flyology-http-server-routing.ads:806-811`):

```ada
   --  Set the per-client admission policy applied to the router's own
   --  automatic responses: 404, 405, CORS preflight, OPTIONS, the trailing
   --  slash redirect, and the malformed-path 400. Those responses match no
   --  route, so they carry no route policy of their own, yet they run the
   --  whole global middleware chain and write a response. Zero is unlimited
   --  and is the default, which leaves that surface unmetered.
```

No maintained test sends more than 64 segments. `tests/http_routing_audit.adb:503` (`Check_Automatic_Response_Admission`) covers the five automatic responses that do go through `Run_Automatic`, including the `Decode_Path` 400, and asserts both the middleware headers and the rate limit on them.

## What happens now

Spike: one router with a security-headers middleware, a rate-limiting middleware and `Set_Automatic_Admission (Rate_Per_Second => 1)`. It sends `/%2e%2e/x` twice as a control, then a 130-byte target of 65 single-character segments twice, each on a fresh connection, and asserts that both malformed-path 400s carry the middleware header and that the second of each pair is rate limited.

```ada
   function Long_Target return String is
      Result : Unbounded_String;
   begin
      for Index in 1 .. 65 loop
         Append (Result, "/a");
      end loop;
      return To_String (Result);
   end Long_Target;
   ...
   Routes.Add_Middleware (Guards.Call'Access);
   Routes.Add_Middleware (Rates.Call'Access);
   Routes.Set_Automatic_Admission (Rate_Per_Second => 1);
```

```
  note target length 130 bytes, 65 segments
  note control first status 400
  ok   control: decode-failure answers 400
  ok   control: decode-failure 400 runs security-headers middleware
  note control second status 429
  ok   control: second decode-failure 400 is rate limited
  note over-segment first status 400
  ok   65-segment target answers 400
  FAIL 65-segment 400 runs the global security-headers middleware
  note over-segment second status 400
  FAIL second 65-segment 400 is metered by automatic admission
checks: 6  failures: 2
BUG REPRODUCED
```

The control 400 carries `X-Content-Type-Options: nosniff` and the repeat is answered 429. The over-segmented 400 carries neither header nor limit, and repeats indefinitely.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

An over-segmented path should produce the same 400 the `Decode_Path` failure produces: written through `Run_Automatic ("flyology.bad_request")`, so it runs the whole global middleware chain and is admitted through `Set_Automatic_Admission`, as `src/flyology-http-server-routing.ads:806-811` states for the malformed-path 400.

## Suggested treatment

Bring the segmentation failure under the same conversion the decode failure uses. Calling `Split_Path` inside `Decode_For_Dispatch`, or wrapping the call at `src/flyology-http-server-routing.adb:1895` in a handler that sets `Invalid_Path := True` and leaves `Path_Segments` empty, puts the response back on the `Run_Automatic` path with no other change. The outermost `Route_Error` handler at `:2086-2090` then remains as the backstop it was meant to be. `Max_Segments` itself does not change.

The regression test belongs in `tests/http_routing_audit.adb`, beside `Check_Automatic_Response_Admission` at `:503`, which already builds the router, the middleware and the admission policy this needs. The spike is the test: it asserts the middleware header and the 429 on both the decode failure and the over-segmented target.

## Severity

Every router that installs global middleware gets one error surface that skips it, and every router that sets an automatic-response rate limit gets one response class that ignores it. The trigger is a plain `GET` with 65 short segments, 130 bytes, on any protocol, from any peer, with no authentication and no special configuration. The response itself is a correct 400 and nothing is corrupted or stalled, so the cost is the missing headers, the missing log and metric records, and an unbounded repeat rate. Deterministic.
