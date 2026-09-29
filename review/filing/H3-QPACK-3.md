Title: A well-formed 33-field request section closes the whole QUIC connection with QPACK_DECOMPRESSION_FAILED
Labels: bug
Refs: H3-QPACK-10

## Summary

The bounded QPACK profile retains at most 32 field lines, 16 KiB per value and 256 bytes per name. Exceeding any of those is reported as `QPACK_Decompression_Failed`, which the server maps to application error `0x200` on a connection-scope close, so one oversized but perfectly well-formed field section destroys every other request in flight on that connection. The limits are also undiscoverable: the server sends no SETTINGS_MAX_FIELD_SECTION_SIZE, so a peer has no way to learn what it may send.

## Problem

Commit `f078732`.

`Append_Field` refuses the thirty-third field (`src/flyology-http-qpack_field_section_policy.adb:127-132`):

```ada
      procedure Append_Field (Item : Header_Field; Success : out Boolean) is
      begin
         Success := False;
         if Block.Count = Max_Fields then
            return;
         end if;
```

and the caller turns that into `Too_Many_Fields` (`src/flyology-http-qpack_field_section_policy.adb:346-350`):

```ada
         Append_Field (Item, Success);
         if not Success then
            Status := Too_Many_Fields;
            return;
         end if;
```

The receive policy collapses every non-`Decoded` decode status, including the profile's own local bounds, into one protocol error (`src/flyology-http-http_3_stream_receive_policy.adb:292-295`):

```ada
         if Decode_Status /= QPACK_Field_Section_Policy.Decoded then
            Result.Status := QPACK_Decompression_Failed;
            return;
         end if;
```

The server maps that to `0x200` (`src/flyology-http-server-http_3.adb:296`):

```ada
         when H3.QPACK_Decompression_Failed => 16#200#,
```

and `Close_For_H3_Error` builds a connection-scope close from it (`src/flyology-http-server-http_3.adb:305-329`), reached from the event loop's `when others` arm at `src/flyology-http-server-http_3.adb:1910-1913`. The same path is taken for a single value over 16 KiB or a name over 256 bytes, in both roles: a response carrying 33 `set-cookie` or `link` fields kills a client's connection the same way.

The limits are never advertised. `Settings` carries the field-section size and defaults to not sending it (`src/flyology-http-http_3.ads:46-49`):

```ada
   type Settings is record
      Has_Max_Field_Size : Boolean := False;
      Max_Field_Size     : QUIC.Stream_Offset := 0;
   end record;
```

and the server starts its session without supplying any (`src/flyology-http-server-http_3.adb:1525`):

```ada
         H3.Initialize (State.Session, H3.Server);
```

so `Has_Max_Field_Size` stays `False`. Note that SETTINGS_MAX_FIELD_SECTION_SIZE is a byte limit in any case, so the 32-field count bound is not expressible in it even when it is sent.

RFC 9114 section 4.2.2 gives the intended remedy: "A server that receives a larger header section than it is willing to handle can send an HTTP 431 (Request Header Fields Too Large) status code." RFC 9204 section 6 reserves QPACK_DECOMPRESSION_FAILED for the case where "the decoder failed to interpret an encoded field section and is not able to continue decoding that field section", which is not what happened here: the section decoded correctly and was then refused for exceeding a local retention bound.

No existing test sends an oversized well-formed section on a live connection. `tests/flyology-http-qpack_field_section_policy-smoke.adb` exercises the RFC 9204 Appendix B.1 vector, and `tests/http3_public_smoke.adb:92-99` covers only the peer-advertised `Peer_Field_Section_Too_Large` case on the send side.

## What happens now

Spike: the program starts the real listener, completes one ordinary GET to show the connection is healthy, sends a second hand-encoded six-field request as a positive control for the encoder, and then writes one hand-encoded QPACK field section of 33 literal field lines in a HEADERS frame on a fresh request stream. Every line is a well-formed Literal Field Line with Literal Name, Required Insert Count 0 and Delta Base 0. It asserts that the server advertises a field-section limit, that the oversized section does not close the connection, and that a later request on the same connection still works.

```ada
   --  QPACK "Literal Field Line with Literal Name" (RFC 9204 section 4.5.6):
   --  001NHxxx with a three-bit name-length prefix and the Huffman bit at
   --  0x08 clear, the name octets, then Hxxxxxxx with a seven-bit
   --  value-length prefix and the value octets.
   function Literal_Line
     (Name, Value : String) return Ada.Streams.Stream_Element_Array is
     (Prefixed (2#0010_0000#, 3, Name'Length) & To_Bytes (Name) &
      Prefixed (16#00#, 7, Value'Length) & To_Bytes (Value));
   ...
         Payload : constant Ada.Streams.Stream_Element_Array :=
           Section (33);
         ...
         QUIC.Build_Stream_Datagram
           (Transport, Oversized_Stream, Offset => 0, Fin => True,
            Data => Frame, Now => Now, Packet => Packet,
            Status => Send_Result);
```

```
  ok   QUIC handshake completes
  ok   server SETTINGS arrive
  FAIL the server advertises SETTINGS_MAX_FIELD_SECTION_SIZE so a peer can respect its field-section bound
  ok   the first request succeeds
  note hand-encoded 6-field control answered '200'
  ok   the hand-encoded control request is well formed and answered, so the encoder is not the variable under test
  ok   the oversized request stream opens
  note 33-field section is 297 encoded bytes
  ok   the oversized HEADERS frame builds
  note event DATA_RECEIVED on stream 4
  note event STREAM_ENDED on stream 4
  note poll after the oversized section: NOT_CONNECTED
  note poll after the oversized section: NOT_CONNECTED
  note transport state after the oversized section: PEER_CLOSED; stream-local reset for the offending stream: FALSE
  FAIL the oversized field section does not close the QUIC connection
  note Open_Request: NOT_CONNECTED
  FAIL a later, unrelated request on the same connection still works
checks: 9  failures: 3
BUG REPRODUCED
exit status 1
```

Ten further `NOT_CONNECTED` poll lines are trimmed from the middle of that block. The control matters: the same hand encoder produces a six-field section the server answers with 200, so the only variable in the failing case is the field count.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A well-formed field section that exceeds what the recipient is willing to retain is a message-level condition, not a decoding failure. On the server it should produce a 431 response or a stream error, per RFC 9114 section 4.2.2, and leave the connection and its other requests intact. The byte-size half of the bound should also be advertised in SETTINGS so a peer can stay inside it.

## Suggested treatment

Separate the profile's retention bounds from genuine decode failures. `Too_Many_Fields` and `Field_Too_Large`, which is also what an over-long name produces, should reach the server as a distinct status that `Dispatch_Request` answers with 431 and that the client surfaces as a stream-local failure, while a malformed encoding keeps `QPACK_Decompression_Failed` and its connection close. The server should also pass `Local_Settings` to `H3.Initialize` at `src/flyology-http-server-http_3.adb:1525` with `Has_Max_Field_Size => True` and a size derived from the profile bounds. Scoping the close correctly is the same change {{ISSUE:H3-QPACK-10}} asks for on the malformed-request path, and both should land together.

This needs a maintainer decision on two points. First, the advertised SETTINGS_MAX_FIELD_SECTION_SIZE value: under "Decision authority" and "Ada interface values" the options are a private implementation value in the server body, a caller parameter on `Serve` and `Serve_Listener`, a generic formal, a value derived from the existing `Max_Fields`, `Max_Name_Length` and `Max_Value_Length` contract in `src/flyology-http-http_3.ads:15-22`, build-time configuration, or a deliberately public constant. Second, adding a new `Operation_Status` variant for the retention bounds is a public enumeration change in `src/flyology-http-http_3.ads`, and so is any new error code; the alternative is to reuse an existing status and keep the distinction private to the server body.

`src/flyology-http-qpack_field_section_policy.adb` and `src/flyology-http-http_3_stream_receive_policy.adb` are both proved by `./scripts/prove.sh`; a new status must keep both discharging with `--checks-as-errors=on`. The regression test belongs in `tests/http3_server_integration.adb`, which already drives the listener end to end, and the spike above is the test. No maintained test asserts the current connection close, so none has to change.

## Severity

One oversized but legal field section destroys the whole QUIC connection, and the spike shows an unrelated, already-successful request lane going with it: after the close, `Open_Request` returns `NOT_CONNECTED`. The error class is also wrong, so a peer that reads the code learns that its encoding was corrupt when it was not, and the bound it violated is not advertised anywhere it could read. The trigger is a valid request, reachable by any peer that sends more than 32 field lines, a long cookie header or a large value. It has been suggested that a stock browser's cookie handling reaches 33 field lines on an ordinary navigation; no browser was driven here and that trigger is not established, so it forms no part of this assessment. Deterministic.
