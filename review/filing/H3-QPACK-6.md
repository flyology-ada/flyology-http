Title: Resource_Exhausted on the ninth concurrent request abandons the QUIC connection with no close frame
Labels: bug
Refs: H3-QPACK-4, H3-QPACK-5

## Summary

`Serve_Connection`'s event loop handles only `Timeout_Error`. Every other exception reaches `when others => Cleanup; raise;`, which frees the QUIC state without transmitting anything, and the listener worker then swallows the exception. The driver allocates eight request slots while the transport advertises 29 concurrent bidirectional streams, so a conformant peer that opens nine concurrent requests triggers `Resource_Exhausted` and loses the connection silently. Several other ordinary inputs reach the same handler gap.

## Problem

Commit `f078732`.

The driver's request table is fixed at eight (`src/flyology-http-server-http_3.adb:44`):

```ada
   Maximum_Request_Streams : constant Positive := 8;
```

while the transport advertises 29 (`flyology_quic/src/flyology-quic-connections.ads:107`):

```ada
      Max_Streams_Bidi            : Stream_Offset := 29;
```

so a peer that stays inside its advertised limit can exhaust the table. `Process_Event` then raises (`src/flyology-http-server-http_3.adb:1699-1702`):

```ada
                  if Slot = 0 then
                     raise Resource_Exhausted with
                       "HTTP/3 request capacity is full";
                  end if;
```

The event loop catches one exception only (`src/flyology-http-server-http_3.adb:1915-1918`):

```ada
         exception
            when Flyology.IO.Timeout_Error =>
               exit when Remaining (Connection_Deadline) = 0.0;
         end;
```

so `Resource_Exhausted` falls through to the outer handler (`src/flyology-http-server-http_3.adb:1923-1926`):

```ada
   exception
      when others =>
         Cleanup;
         raise;
```

and the worker logs it only when debugging is enabled (`src/flyology-http-server-http_3.adb:2026-2033`):

```ada
                  exception
                     when Error : others =>
                        if Debug.Enabled then
                           Debug.Log
                             ("h3", "worker-exception",
                              Ada.Exceptions.Exception_Information (Error));
                        end if;
                  end;
```

Nothing is sent, so the peer sees neither a stream reset nor a CONNECTION_CLOSE. RFC 9000 section 10.2 states: "An endpoint uses a CONNECTION_CLOSE frame (Section 19.19) to signal that a connection is being closed." RFC 9114 section 4.1.1 names the alternative: "When the server cancels a request without performing any application processing, the request is considered \"rejected\". The server SHOULD abort its response stream with the error code H3_REQUEST_REJECTED."

Other reachable inputs share the handler gap and were confirmed by reading rather than exercised separately: an undeclared request body over the 1 MiB buffered bound raises `Payload_Too_Large` at `src/flyology-http-server-http_3.adb:1778-1782`, a CONNECT request raises `Protocol_Error` at `:1563-1566`, a method over 64 bytes raises `Constraint_Error` in `To_Method` (`src/flyology-http.adb:12-20`), a trailer section over 16 KiB raises `Headers_Too_Large` from `Headers.Add` (`src/flyology-http-headers.ads:10`, `:34`), and a non-`Succeeded` prepared-response status raises `Device_Error` at `:396-400` and `:454-457`.

No existing test opens more concurrent request streams than the driver can hold, and none asserts what a peer observes when a request handler path raises. `website/guide/server/index.html:369` documents the 1 MiB limit as "A larger declared `Content-Length` receives 413", which covers only the declared case.

## What happens now

Spike: the program starts the real listener, then opens nine POST streams with `Fin => False` and a declared `content-length`, so no request reaches `Stream_Ended` and all nine slots are wanted at once. It asserts that the server either answers the ninth request or closes the connection explicitly.

```ada
         for Index in 1 .. Open_Streams loop
               H3.Open_Request
                 (Session, Transport, Streams (Index), H3_Status);
               H3.Append (Block, H3.Make_Field (":method", "POST"));
               H3.Append (Block, H3.Make_Field (":path", "/slow"));
               H3.Append (Block, H3.Make_Field ("content-length", "4"));
               H3.Send_Headers
                 (Session, Transport, Streams (Index), Block, Fin => False,
                  Now => Now, Packet => Packet, Status => H3_Status);
               QUIC_IO.Send (Socket, Packet, 2.0);
         end loop;
```

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  ok   the transport admits nine concurrent request streams
  note opened 9 request streams
  note ninth stream answered: FALSE; transport state CONNECTED
  FAIL the server either answers the ninth request or closes the connection explicitly instead of abandoning it silently
checks: 4  failures: 1
BUG REPRODUCED
exit status 1
```

The transport admits all nine streams, which is the point: the peer did nothing the server told it not to do. After the ninth request the connection stays `CONNECTED` and mute for the rest of the peer's idle timeout. {{ISSUE:H3-QPACK-4}} produces the same symptom from a different cause, and {{ISSUE:H3-QPACK-5}} is the same missing close on the planned-retirement path.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A server that cannot accept a request it advertised room for should refuse that request, not the connection. RFC 9114 section 4.1.1 covers exactly this case: a request cancelled without any application processing is rejected, and the server should abort its response stream with H3_REQUEST_REJECTED, which lets the client retry it elsewhere. If the server does decide to close the connection, RFC 9000 section 10.2 has it signal that with a CONNECTION_CLOSE frame while it still can. The advertised stream limit and the driver's request capacity should also agree, so that a conformant peer cannot provoke the condition at all.

## Suggested treatment

Two changes, independent of each other. First, handle the raising statuses inside the event loop: catch `Resource_Exhausted` and answer the offending stream with a reset carrying H3_REQUEST_REJECTED, and give `Payload_Too_Large`, the CONNECT rejection, `Constraint_Error` from `To_Method` and `Headers_Too_Large` stream-scoped answers in the same place. Second, add a `when others` arm that builds and sends a QUIC application close before `Cleanup`, so no path frees the connection state without telling the peer; that is the same close {{ISSUE:H3-QPACK-5}} asks for on the retirement path.

This needs a maintainer decision on the relationship between `Maximum_Request_Streams` at `src/flyology-http-server-http_3.adb:44` and `Max_Streams_Bidi` in the transport settings the caller supplies. Under "Decision authority" and "Ada interface values" the options are keeping the eight-slot table as a private implementation value and lowering the advertised stream limit to match it, deriving the table size from the `Transport_Settings` record the caller already passes to `Serve`, a caller parameter, a generic formal, a discriminant on the connection state, build-time configuration, or a deliberately public constant. Whether the ninth request is refused with H3_REQUEST_REJECTED, answered with 503, or accepted by growing the table is the same decision seen from the other side.

`src/flyology-http-server-http_3.adb` is not among the units `./scripts/prove.sh` proves, so no proof obligation changes. The regression test belongs in `tests/http3_server_integration.adb`; the spike above is the test. No maintained test asserts the current silence.

## Severity

A conformant peer that opens nine concurrent requests, which the server's own advertised transport parameters invite, loses the whole connection and every request on it, with no close frame and no log line unless debugging is enabled. The other inputs in the same handler gap are equally ordinary: a chunked upload over 1 MiB, a CONNECT request, a long method, a large trailer section. Nothing about the trigger is adversarial, and a browser that opens several parallel subresource requests reaches it in normal operation. Deterministic.
