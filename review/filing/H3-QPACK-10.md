Title: A malformed HTTP/3 request closes the whole QUIC connection instead of resetting the one request stream
Labels: bug
Refs: H3-QPACK-3

## Summary

The session body already knows how to scope a malformed message to one stream: for the client role it converts `Message_Error` and `Header_Error` into a stream-local reset with H3_MESSAGE_ERROR. The guard is `if Item.Local_Role = Client`, so on the server the same statuses reach `Close_For_H3_Error` and become a connection-scope close, destroying every other request in flight on that connection. An empty request stream takes the same path.

## Problem

Commit `f078732`.

The stream-local handling exists but is restricted to one role (`src/flyology-http-http_3_connection.adb:426-440`):

```ada
            if Item.Local_Role = Client
              and then Status in Message_Error | Header_Error
            then
               --  RFC 9114 assigns malformed HTTP message semantics to this
               --  response stream. Surface a stream-local failure so another
               --  multiplexed response remains usable; the client commits
               --  H3_MESSAGE_ERROR before releasing this state. Server-side
               --  request diagnostics retain their existing typed status.
               Item.Streams (Slot).Finished := True;
               Output.Kind := Stream_Reset;
               Output.Stream := ID;
               Output.Application_Error := 16#10E#;
               Status := Succeeded;
               return;
            end if;
```

On the server the status propagates out of `Poll` and reaches the event loop's `when others` arm (`src/flyology-http-server-http_3.adb:1910-1913`), which calls `Close_For_H3_Error`; `Application_Error_For` maps `Message_Error` and `Header_Error` to `16#10E#` (`src/flyology-http-server-http_3.adb:295`) and the close is built with `Build_Application_Close_Datagram` at connection scope (`src/flyology-http-server-http_3.adb:320-321`). An empty request stream, opened and finished with no bytes, reaches the same place through `Finish_Request` returning `Message_Incomplete` (`src/flyology-http-http_3_stream_receive_policy.adb:466-470`, `src/flyology-http-http_3_message_policy.adb:138-144`).

RFC 9114 section 4.2 makes the trigger malformed: "Characters in field names MUST be converted to lowercase prior to their encoding. A request or response containing uppercase characters in field names MUST be treated as malformed." RFC 9114 section 4.1.2 says what to do about it: "Malformed requests or responses that are detected MUST be treated as a stream error of type H3_MESSAGE_ERROR", and adds "For malformed requests, a server MAY send an HTTP response indicating the error prior to closing or resetting the stream." For the empty-stream case RFC 9114 section 4.1 says "If a client-initiated stream terminates without enough of the HTTP message to provide a complete response, the server SHOULD abort its response stream with the error code H3_REQUEST_INCOMPLETE."

RFC 9114 section 8 does permit the escalation: "An endpoint MAY choose to treat a stream error as a connection error under certain circumstances, closing the entire connection in response to a condition on a single stream. Implementations need to consider the impact on outstanding requests before making this choice." The defect is that the impact is not considered and that the two roles of one code path disagree.

The h3spec gate does not distinguish the two scopes: its four H3_MESSAGE_ERROR cases pass with a connection close. `tests/flyology-http-http_3_stream_receive_policy-smoke.adb:203-204` asserts the classifier's status only, not what the server does with it.

## What happens now

Spike: the program starts the real listener, completes one ordinary GET, then sends a hand-encoded four-field request as a positive control for the encoder, then sends one request whose fifth field line has the uppercase name `X-Bad`. It asserts that the malformed request does not close the connection and that a later request on the same connection still works.

```ada
      Put (Literal_Line (":method", "GET"));
      Put (Literal_Line (":scheme", "https"));
      Put (Literal_Line (":path", "/hello"));
      Put (Literal_Line (":authority", "localhost"));
      for Index in 5 .. Field_Count loop
         --  An uppercase field name: RFC 9114 section 4.2 requires field
         --  names to be lowercase on the wire.
         Put (Literal_Line ("X-Bad", "v"));
      end loop;
```

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  ok   the first request succeeds
  note hand-encoded well-formed control answered '200'
  ok   the hand-encoded control request is well formed and answered, so the encoder is not the variable under test
  ok   the malformed request stream opens
  note malformed section is 73 encoded bytes
  ok   the malformed HEADERS frame builds
  note event DATA_RECEIVED on stream 4
  note event STREAM_ENDED on stream 4
  note poll after the malformed request: NOT_CONNECTED
  note poll after the malformed request: NOT_CONNECTED
  note transport state after the malformed request: PEER_CLOSED; stream-local reset for the offending stream: FALSE
  FAIL the malformed request does not close the QUIC connection
  note Open_Request: NOT_CONNECTED
  FAIL a later, unrelated request on the same connection still works
checks: 8  failures: 2
BUG REPRODUCED
exit status 1
```

Ten further `NOT_CONNECTED` poll lines are trimmed from the middle of that block. The control is what makes the result readable: the same hand encoder produces a four-field section the server answers with 200, so the uppercase name is the only variable.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A malformed request should be a stream error of type H3_MESSAGE_ERROR, per RFC 9114 section 4.1.2, optionally preceded by an HTTP response describing the problem. A request stream that ends before a complete message should be aborted with H3_REQUEST_INCOMPLETE, per RFC 9114 section 4.1. In both cases the connection and its other requests should survive.

## Suggested treatment

Extend the stream-local branch at `src/flyology-http-http_3_connection.adb:426-440` to the server role, so that `Message_Error` and `Header_Error` produce a `Stream_Reset` event rather than a status the driver escalates. The server driver then handles that event on the affected slot and keeps serving. Scoping the close correctly is the same change {{ISSUE:H3-QPACK-3}} asks for on the oversized-field-section path, so the two should land together.

This needs a maintainer decision on one point: whether the server answers a malformed request with an HTTP status before resetting the stream, which RFC 9114 section 4.1.2 permits, or resets it silently. If it answers, the status code chosen is a new policy value. Under "Decision authority" and "Ada interface values" the options are a private implementation value in the server body, a caller parameter, a generic formal, a value derived from the existing error mapping, build-time configuration, or a deliberately public constant. Resetting without a response adds no value at all and is the minimal choice.

`src/flyology-http-http_3_connection.adb` is not among the units `./scripts/prove.sh` proves, so no proof obligation changes; the classification in `src/flyology-http-http_3_stream_receive_policy.adb` and `src/flyology-http-http_3_message_policy.adb` is correct and does not need to move. The regression test belongs in `tests/http3_server_integration.adb`; the spike above is the test. The h3spec conformance lane will need its expectations reviewed, since its H3_MESSAGE_ERROR cases currently pass with a connection close and would pass with a stream reset instead.

## Severity

One malformed request destroys every other request on the connection, and the peer that sent it may not be the one that loses work: a browser or a proxy multiplexes unrelated requests onto the same connection, so an error in one of them takes the rest down. RFC 9114 section 8 permits the escalation, which is why this is not a conformance failure, but it also asks the implementation to weigh the impact on outstanding requests, and the client role of the very same procedure already weighs it the other way. The trigger requires a peer that sends an invalid request: browsers and curl do not, so it is not something a stock client produces by accident. Deterministic.
