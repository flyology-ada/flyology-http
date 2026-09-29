Title: HTTP/3 server abandons a connection at its request limit without sending GOAWAY or CONNECTION_CLOSE
Labels: bug
Refs: none

## Summary

When `Serve_Connection` reaches `Max_Requests`, the connection age limit, or a listener shutdown, it frees the QUIC and request state and returns. Nothing is transmitted, so the peer still believes the connection is usable and keeps sending on it until its own idle timeout expires. The HTTP/2 server in this repository sends GOAWAY in the same situation.

## Problem

Commit `f078732`.

The serve loop exits on its own conditions and goes straight to `Cleanup` (`src/flyology-http-server-http_3.adb:1897-1900` and `:1919-1922`):

```ada
      while not State.Closed
        and then Served < Max_Requests
        and then Remaining (Connection_Deadline) /= 0.0
      loop
      ...
      end loop;
      Flush_Pending_Responses
        (State.all, Remaining (Connection_Deadline));
      Cleanup;
```

`Cleanup` frees both allocations and sends nothing (`src/flyology-http-server-http_3.adb:1834-1842`):

```ada
      procedure Cleanup is
      begin
         if Requests /= null then
            Free_Request_Array (Requests);
         end if;
         if State /= null then
            Free_Connection_State (State);
         end if;
      end Cleanup;
```

The same path is taken when the listener token fires: the channel close becomes `Operation_Cancelled`, which reaches `when others => Cleanup; raise;` at `src/flyology-http-server-http_3.adb:1923-1926`, and the worker swallows it at `src/flyology-http-server-http_3.adb:2026-2033`.

The session has a GOAWAY builder that nothing calls. `grep -rn 'Send_Goaway\|Build_Goaway' src/` returns only the declarations and bodies in `src/flyology-http-http_3.ads:296`, `src/flyology-http-http_3.adb:305-323`, `src/flyology-http-http_3_connection.ads:120` and `src/flyology-http-http_3_connection.adb:679-728`; there is no caller in the server driver.

RFC 9114 section 5.2 states: "Servers SHOULD send a GOAWAY frame when the closing of a connection is known in advance, even if the advance notice is small, so that the remote peer can know whether or not a request has been partially processed." RFC 9000 section 10.2 states: "An endpoint uses a CONNECTION_CLOSE frame (Section 19.19) to signal that a connection is being closed." Reaching a configured request limit is exactly the advance notice RFC 9114 section 5.2 describes.

The HTTP/2 server does queue a GOAWAY on the equivalent path (`src/flyology-http-server-http_2.adb:1309-1316`), so the two protocol families disagree inside this repository.

No existing test observes connection retirement from the peer side. `tests/http3_public_smoke.adb:202-205` exercises the low-level `Send_Goaway` API in isolation. `website/guide/server/index.html:369` tells the reader that "the request limit controls connection rotation" without saying the rotation is silent.

## What happens now

Spike: the program starts the real listener with `Max_Requests => 1`, completes the one permitted request, then polls for six seconds watching for any end-of-life signal. It asserts that a GOAWAY arrives or that the transport reaches `Peer_Closed`.

```ada
            while not Saw_Goaway
              and then QUIC.State (Transport) = QUIC.Connected
              and then Ada.Real_Time.Clock < Deadline
            loop
               H3.Poll (Session, Transport, Event, H3_Status);
               if H3_Status = H3.Succeeded then
                  Saw_Goaway := Event.Kind = H3.Goaway_Received;
               elsif H3_Status = H3.No_Event then
                  Pump (0.25);
               end if;
            end loop;
```

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  ok   the single permitted request succeeds
  note event DATA_RECEIVED
  note event STREAM_ENDED
  note after the request limit: GOAWAY seen FALSE, transport state CONNECTED
  FAIL the retiring server sends GOAWAY or CONNECTION_CLOSE instead of abandoning the connection silently
checks: 4  failures: 1
BUG REPRODUCED
exit status 1
```

Six seconds of polling yield no GOAWAY and no state change. From the peer's point of view the connection is still healthy and available for the next request.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A server that knows it is retiring a connection should send GOAWAY before it stops serving, so the peer learns which requests were processed and can open a fresh connection, and should then close the QUIC connection explicitly. RFC 9114 section 5.2 asks for the GOAWAY, and adds that "An endpoint that completes a graceful shutdown SHOULD use the H3_NO_ERROR error code when closing the connection."

## Suggested treatment

Before `Cleanup` at `src/flyology-http-server-http_3.adb:1922`, and on the cancellation path at `:1923-1926`, build and send a GOAWAY through the existing `H3.Send_Goaway`, then build and send a QUIC application close with H3_NO_ERROR. The identifier to advertise is the one the existing `Build_Goaway` validation already constrains for a server: the next request stream identifier that will not be processed.

This needs a maintainer decision: how long the server waits between the GOAWAY and the close is a new timeout, and whether the server drains already-accepted requests before closing is a policy choice with an externally visible effect. Under "Decision authority" and "Ada interface values" the options for that grace period are a private implementation value in the server body, a caller parameter on `Serve` and `Serve_Listener` beside the existing `Max_Connection_Age`, a generic formal, a value derived from the existing connection deadline, build-time configuration, or a deliberately public constant. Sending the GOAWAY with no grace period and closing immediately is the minimal choice and adds no value at all.

`src/flyology-http-server-http_3.adb` is not among the units `./scripts/prove.sh` proves, so no proof obligation changes. The regression test belongs in `tests/http3_server_integration.adb`, which already drives the listener with a configured request limit; the spike above is the test. `tests/http3_public_smoke.adb:202-205` tests the GOAWAY API itself and does not have to change.

## Severity

A peer that has a connection retired under it gets no signal at all: it keeps the connection in its pool, sends the next request into it, and discovers the loss only at its own idle timeout. Requests already sent and not yet answered cannot be distinguished from requests the server never saw, which is precisely what GOAWAY exists to communicate. It happens on every connection retirement in the default configuration, since `Max_Requests` and `Max_Connection_Age` both have defaults, and on every listener shutdown. Deterministic.
