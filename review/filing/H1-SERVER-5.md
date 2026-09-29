Title: HEAD or HTTP/1.0 on an SSE route drops the connection with no response, via an escaping Program_Error
Labels: bug

## Summary

`Begin_SSE` raises `Program_Error` for a HEAD request and for HTTP/1.0, and `Accept_WebSocket` raises `Program_Error` when the upgrade request carries a body. `Connection_Handlers.Serve` catches `Payload_Too_Large`, `Resource_Exhausted`, `Protocol_Error` and the I/O errors, and nothing else, so the exception leaves `Serve` and the transport closes with zero bytes written. All three conditions are chosen by the peer. The maintained showcase routes `/events` straight into `Begin_SSE` with no method or version gate, so `curl -I` against it is answered with a dropped connection.

## Problem

Commit `f078732`.

`Begin_SSE` raises `Program_Error` for two peer-chosen request shapes (`src/flyology-http-server.adb:3059-3063`):

```ada
      if Item.Current_Is_Head then
         raise Program_Error with "SSE is not available for HEAD";
      elsif Item.Current_Version /= HTTP_1_1 then
         raise Program_Error with "SSE requires HTTP/1.1";
      end if;
```

`Accept_WebSocket` does the same for a third (`src/flyology-http-server.adb:3932-3938`):

```ada
      elsif not Item.Body_Done or else Item.Body_Total > 0
        or else Content (Value)'Length > 0
      then
         raise Program_Error with
           "WebSocket upgrade requests must not carry a body";
      end if;
```

`Connection_Handlers.Serve` wraps the handler call with a closed set of handlers (`src/flyology-http-server-connection_handlers.adb:125-142`):

```ada
         begin
            Handle (Item, Value);
         exception
            when Payload_Too_Large =>
               Best_Effort (413, "request content is too large");
               return;
            when Resource_Exhausted =>
               Best_Effort_Overloaded;
               return;
            when Protocol_Error =>
               Best_Effort_Bad_Request;
               return;
            when Flyology.IO.Timeout_Error |
                 Flyology.IO.Device_Error |
                 Flyology.IO.TLS.TLS_Error |
                 Flyology.IO.Sockets.Socket_Error =>
               return;
         end;
```

`Program_Error` is not among them, so it propagates out of `Serve` and out of the handler, and the peer receives nothing at all. That is the damage: not a wrong exception name, but a connection dropped mid-exchange with no status line.

The documented rejection channel is the one that is bypassed. `src/flyology-http-server.ads:857` declares:

```ada
   --  @exception Protocol_Error Request is not a valid version 13 upgrade
```

and `Begin_SSE` (`src/flyology-http-server.ads:767-776`) documents no exception at all.

The SSE cases are ordinary conformant requests. `HEAD /events` is what `curl -I` sends and `GET /events HTTP/1.0` is what `curl --http1.0` sends. The maintained showcase routes `/events` into `Begin_SSE` with no method or version gate (`showcases/http_server.adb:90-92`):

```ada
            elsif HTTP_Engine.Target (Value) = "/events" then
               HTTP_Engine.Begin_SSE
                 (Item, Timeout => 5.0, Token => Cancellation);
```

and serves it through the raw engine (`showcases/http_server.adb:153-160`):

```ada
         package Handler is new
           Flyology.HTTP.Server.Connection_Handlers (Route);
      begin
         HTTP_Engine.Configure_Ingress_Budget
           (Client, State.Budget'Access);
         Handler.Serve
           (Client, Timeout => 5.0, Buffer_Body => False,
            Token => Cancellation);
```

so a plain `curl -I` against the showcase gets a dropped connection. `tests/websocket_conformance_server.adb:105-106` uses the same raw engine for `Accept_WebSocket`.

The connection is the whole of the damage, and that is what keeps this below the worst case. Against the pinned dependency the worker recovers. `alire/alire.lock` pins `flyology` at `=0.1.1-dev`, commit `bd95746d5c9c31f5b41b611db9ba82a016ceaaa4`, and in that source the handler call is wrapped (`src/flyology-io-structured_servers.adb:452-460` of the pinned `flyology`):

```ada
                           begin
                              Handle (Context, Connection, Peer, Item.Handler_Stop'Access);
                           exception
                              when Connections.Operation_Cancelled =>
                                 Cancelled := True;
                              when Event : others =>
                                 Report (Handler_Callback, Event);
                                 Failed := True;
                           end;
```

followed by `Connections.Close (Connection)` and a completion that returns worker capacity. So the escaping `Program_Error` is caught, reported, the connection closed and the worker released: no stall and no capacity loss.

Through the router the same requests do not drop the connection. `Dispatch_Configuration` catches only `Route_Error`, `Payload_Too_Large`, `Expectation_Failed` and `Protocol_Error` (`src/flyology-http-server-routing.adb:2086-2109`), so the `Program_Error` falls to the outer `when others`, which answers 500 and closes (`src/flyology-http-server-routing.adb:2264-2276`). 500 is still the wrong channel for an input the peer chose, but the peer gets an answer. The `HEAD /events` router case is additionally screened by the route's method gate, pinned at `tests/http_smoke.adb:3731-3749`, so the router exposure is the WebSocket body case and HTTP/1.0 on SSE.

No maintained test covers an upgrade carrying a body, and `tests/http_smoke.adb:3731-3749` covers HEAD on an SSE route only through the router. `tests/http_smoke.adb:2034-2063` pins that `Serve` propagates application faults, which is the behaviour these raises borrow; the point here is that these inputs are the peer's choice, not the application's fault.

## What happens now

Spike: five peer-chosen request shapes are driven through `Connection_Handlers.Serve` on an in-memory `Flyology.HTTP.Server.Transport`, three into `Accept_WebSocket` and two into `Begin_SSE`. A bodiless handshake is the baseline. Each case is checked twice: that no exception escapes `Serve`, and that the bytes written to the transport carry a 4xx status.

```ada
   Probe_SSE
     ("HEAD on an SSE route",
      "HEAD /events HTTP/1.1" & CRLF & "Host: h" & CRLF & CRLF);

   Probe_SSE
     ("HTTP/1.0 on an SSE route",
      "GET /events HTTP/1.0" & CRLF & "Host: h" & CRLF & CRLF);
   ...
      Check (Escaped = "", Label & ": no exception escapes Serve");
      ...
      Check
        (Status'Length = 3 and then Status (Status'First) = '4',
         Label & ": peer receives a client-error response");
```

```
  note peer-chosen shapes reaching Accept_WebSocket and Begin_SSE through
  note the raw Connection_Handlers engine
  ok   baseline: a bodiless handshake upgrades (101)
  FAIL upgrade with Content-Length body, buffered: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "WebSocket upgrade requests must not carry a body"
  FAIL upgrade with Content-Length body, buffered: peer receives a client-error response
  note   wire status: (no response)
  FAIL upgrade with Content-Length body, unbuffered: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "WebSocket upgrade requests must not carry a body"
  FAIL upgrade with Content-Length body, unbuffered: peer receives a client-error response
  note   wire status: (no response)
  FAIL upgrade with a chunked body, unbuffered: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "WebSocket upgrade requests must not carry a body"
  FAIL upgrade with a chunked body, unbuffered: peer receives a client-error response
  note   wire status: (no response)
  FAIL HEAD on an SSE route: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "SSE is not available for HEAD"
  FAIL HEAD on an SSE route: peer receives a client-error response
  note   wire status: (no response)
  FAIL HTTP/1.0 on an SSE route: no exception escapes Serve
  note   escaped: PROGRAM_ERROR "SSE requires HTTP/1.1"
  FAIL HTTP/1.0 on an SSE route: peer receives a client-error response
  note   wire status: (no response)
checks: 11  failures: 10
BUG REPRODUCED
```

`(no response)` is the spike reporting that nothing at all was written to the transport. The baseline upgrades with 101, so only the peer-chosen shapes are at issue, and both `Buffer_Body => True` and `Buffer_Body => False` reach the same outcome.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A request shape the peer chose should be refused on the documented rejection channel, so that `Connection_Handlers.Serve` writes a 4xx and closes rather than letting the exception escape. `src/flyology-http-server.ads:857` names `Protocol_Error` for an invalid upgrade, and the same treatment fits an SSE request whose method or version the route cannot serve.

## Suggested treatment

Raise `Protocol_Error` rather than `Program_Error` for the three peer-chosen conditions, at `src/flyology-http-server.adb:3059-3063` and `:3932-3938`. `Serve` already maps `Protocol_Error` to a best-effort 400 with `Connection: close` (`src/flyology-http-server-connection_handlers.adb:134-136`), and `Dispatch_Configuration` already maps it to a 400 problem response (`src/flyology-http-server-routing.adb:2104-2109`), so both engines answer correctly with no further change. The two `Program_Error` raises that guard genuine application faults in the same subprograms, "HTTP response already started" and "SSE request body has not been consumed", must stay as they are: those are the application's mistakes, not the peer's, and `tests/http_smoke.adb:2034-2063` pins that they propagate.

This needs a maintainer decision on the status, because 400 may not be the intended answer for every row. The options are the existing `Protocol_Error` with the 400 the handlers already produce, a distinct exception mapped to 405 for `HEAD` on an SSE route with an `Allow` field, a 505 or 400 for HTTP/1.0, or leaving the choice to the application by having `Begin_SSE` and `Accept_WebSocket` report the refusal through an out parameter instead of an exception. The last option changes a public profile in `src/flyology-http-server.ads` and is a larger change.

`Begin_SSE`'s declaration at `src/flyology-http-server.ads:767-776` documents no exception, so whichever choice is made, an `@exception` line belongs there.

`src/flyology-http-server.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in `tests/http_smoke.adb`, which already owns the in-memory transport, beside the SSE route cases at `:3731-3749`: drive `HEAD /events`, `GET /events HTTP/1.0` and an upgrade carrying a body through `Connection_Handlers.Serve` and assert a 4xx status line rather than an escaping exception. The spike is the test. `tests/websocket_conformance_server.adb:105-106` uses the same raw engine and is unaffected by the change.

## Severity

A conformant `HEAD /events` or `GET /events HTTP/1.0` against a route that calls `Begin_SSE` closes the connection with zero bytes written, so the client sees a dropped connection rather than a status. `curl -I` and `curl --http1.0` produce exactly those requests, and the maintained showcase at `showcases/http_server.adb:90-92` routes `/events` into `Begin_SSE` with no method or version gate, so this is reachable from a default build with a stock client. The damage is confined to the one connection: against the pinned `flyology` dependency the escaping exception is caught by the structured server's worker, the connection is closed and worker capacity is returned, so there is no stall and no capacity loss. The WebSocket case needs a GET carrying content, which RFC 9110 section 9.3.1 advises against, so it is the narrower of the two. Deterministic. HTTP/1 only.
