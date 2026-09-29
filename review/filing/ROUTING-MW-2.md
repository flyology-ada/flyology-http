Title: A rejected Respond marks the exchange Failed, so the errors middleware closes instead of writing its 500
Labels: bug
Refs: none

## Summary

`Applications.Respond` validates its arguments before writing anything, then catches every exception in a blanket handler that sets `Response_Value := Failed`. An exchange with zero bytes on the wire therefore reports `Failed` instead of `Not_Started`. `Middleware_Errors` tests exactly that state before writing the closing 500 its specification promises, finds it false, and calls `Mark_Failed`, so the connection is closed with no response at all. Installing the documented safety net is what removes the safety: HTTP/1 without the errors middleware still answers 500, because the connection-level path consults the connection rather than the exchange. The same handler also relabels a fully written 200 as `Failed` when a second `Respond` is rejected, which closes the keep-alive connection and drops the next pipelined request.

## Problem

Commit `f078732`.

`Respond` raises before writing and then relabels the exchange (`src/flyology-http-server-applications.adb:436-446` and `:465-468`):

```ada
      Require_Owner (Item);
      if Item.Response_Value /= Not_Started then
         raise Program_Error with "HTTP exchange response already started";
      elsif Item.Authentication_Value = Required_Authentication
        and then not Item.Principal_Present
        and then Status < 400
      then
         raise Program_Error with
           "required-authentication route cannot send an unauthenticated"
           & " response";
      end if;
      ...
   exception
      when others =>
         Item.Response_Value := Failed;
         raise;
   end Respond;
```

The connection layer it calls validates again and only then commits (`src/flyology-http-server.adb:2733-2739`, `:2770`):

```ada
      if Status not in 200 .. 599 then
         raise Constraint_Error with
           "final HTTP status must be 200 through 599";
      end if;
      if Body_Forbidden and then Payload'Length /= 0 then
         raise Program_Error with
           "HTTP status does not permit response content";
      end if;
```

```ada
      Item.Response_Begun := True;
```

So `X.Respond (99, ...)` raises with nothing written and `Wire_Response_Started` still `False`, yet the exchange now reports `Failed`. The errors middleware reads that state (`src/flyology-http-server-middleware_errors.adb:52-65`):

```ada
            if not Handled then
               if X.Response = App.Not_Started
                 and then not X.Wire_Response_Started
               then
                  X.Respond
                    (500,
                     "application/problem+json",
                     "{""type"":""internal-server-error""," &
                     """status"":500," &
                     """detail"":""Internal server error""}",
                     Close => True);
               else
                  X.Mark_Failed;
               end if;
            end if;
```

Two contracts are violated. `src/flyology-http-server-middleware_errors.ads:8-9`:

```ada
--  exceptions into a response. Unexpected exceptions become a generic
--  closing 500 before response start; partial responses are failed and closed.
```

and `src/flyology-http-server-applications.ads:49`, which defines the state the middleware tests:

```ada
   --  @enum Not_Started No response bytes have been written
```

`Mark_Failed` then asks for the connection to close (`src/flyology-http-server-applications.adb:1001-1010`):

```ada
   procedure Mark_Failed (Item : in out Exchange) is
   begin
      Require_Owner (Item);
      if Item.Backend_Handle = null then
         Item.Connection_Handle.Request_Close := True;
```

Without the errors middleware, HTTP/1 still answers, because `Serve`'s own handler uses the connection-level `Respond`, which consults `Response_Started (Connection)` rather than the exchange state (`src/flyology-http-server-routing.adb:2264-2275`):

```ada
            when others =>
               if not Response_Started (Connection) then
                  begin
                     Respond
                       (Connection, 500, "text/plain; charset=utf-8",
                        "internal server error" & Character'Val (10),
                        Close => True, Timeout => Read_Timeout,
                        Token => Token);
```

The second call case is the mislabelling. A handler that writes one complete response and then makes a rejected second `Respond` call leaves `Response_Value = Failed` for a response that was written correctly, and the post-handler check turns that into a close (`src/flyology-http-server-routing.adb:2065-2074`):

```ada
         if X.Response = App.Not_Started then
            X.No_Content;
         elsif X.Response in App.Streaming_Response | App.Streaming_SSE |
           App.Upgraded | App.Failed
         then
            --  A lifecycle must finish before its borrowed exchange returns.
            --  Returning while framing is active makes another HTTP read
            --  unsafe, so contain the fault to this connection.
            X.Mark_Failed;
         end if;
```

The existing coverage exercises only the shapes that still work. `tests/http_smoke.adb:2930-2942` sends `/unexpected`, whose handler raises `Constraint_Error` before calling `Respond` (`tests/http_smoke.adb:2804-2811`), and asserts the 500 and `Connection: close`; `tests/http_smoke.adb:2944-2956` covers a failure after a stream has started. No maintained test makes `Respond` itself raise.

## What happens now

Spike: three routes served over an in-memory transport. One handler calls `X.Respond (99, ...)` under the errors middleware and the spike reads the bytes written. One handler catches the same rejected call itself and reports `X.Response`. One handler writes a complete `X.Text (200, "first")`, makes a rejected second call, reports `X.Response`, and is driven on a keep-alive connection with a second pipelined request behind it.

```ada
   procedure Raise_Status
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
   begin
      X.Respond (99, "text/plain; charset=utf-8", "x");
   end Raise_Status;

   procedure Double_Respond
     (State : in out Context;
      X     : in out Applications.Exchange)
   is
   begin
      X.Text (200, "first");
      begin
         X.Text (200, "second");
      exception
         when others => null;
      end;
      State.After_Second := X.Response;
   end Double_Respond;
```

```
  note errors-middleware output []
  note bytes written 0
  FAIL errors middleware writes the promised 500 for a pre-write Respond failure
  note state after pre-write raise: FAILED
  FAIL exchange stays Not_Started when Respond raised before writing
  note state after rejected second Respond: FAILED
  FAIL a fully written response stays Completed when a second Respond is rejected
  note responses on the pipelined connection 1
  FAIL the pipelined request after a rejected second Respond is still served
checks: 4  failures: 4
BUG REPRODUCED
```

Zero bytes are written where a closing 500 is promised. The exchange reports `FAILED` both when nothing was written and when a complete response was. One response is served on the pipelined connection where two are due.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

`Respond` should leave `Response_Value` unchanged when it raises before any byte reaches the wire, so the exchange still reports `Not_Started` and the errors middleware writes the closing 500 that `src/flyology-http-server-middleware_errors.ads:8-9` promises. A rejected second `Respond` should leave the already completed response reporting `Completed`, so the keep-alive connection continues serving.

## Suggested treatment

Narrow the blanket handler at `src/flyology-http-server-applications.adb:465-468` so it sets `Failed` only for a failure that can leave the wire in an indeterminate state. The pre-write validation at `:436-446` can raise outside the handled region, and the handler around the two `Respond` calls can restore the entry value when `Wire_Response_Started` is still `False`, which distinguishes the rejected call from a write that failed part way. The same treatment applies to the connection-layer rejections at `src/flyology-http-server.adb:2733-2739`, which also raise before `Item.Response_Begun := True` at `:2770`.

Add the regression cases to `tests/http_smoke.adb` beside the existing errors-middleware routes at `:2930-2956`: one route whose handler calls `X.Respond (99, "", "")` under the errors middleware, asserting `500 Internal Server Error` and `Connection: close` in the output, and one route that writes a complete response and then makes a rejected second call, asserting `X.Response = Completed` and that a pipelined follow-up request is still served. The spike is the test.

## Severity

Any application defect that makes `Respond` reject its own arguments turns into an empty reply and a dropped connection, in the one component whose documented purpose is to contain application defects. The rejections are reachable from ordinary handler code: a status outside 200 through 599, a payload with 204, 205 or 304, a control byte in the content type, a second response, or a sub-400 status on a required-authentication route with no principal. The trigger is application-side rather than peer-side, and the connection closes cleanly with nothing corrupted and nothing hanging, but the promised 500 is never written and a correct response is relabelled as a failure. Deterministic.
