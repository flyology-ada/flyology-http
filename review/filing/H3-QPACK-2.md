Title: An HTTP/3 frame larger than the 16,384-byte QUIC reassembly window can never be consumed
Labels: bug
Refs: H3-QPACK-1

## Summary

HTTP/3 frames are consumed whole: the frame parser reports a truncated envelope with `Consumed = 0` until the entire payload is contiguous, and the session calls `QUIC.Consume` only when something was consumed. The QUIC reassembly buffer is a compile-time 16,384 bytes enforced by a type invariant, so the longest contiguous prefix any stream can ever present is 16,384 bytes. A frame whose envelope plus payload exceeds that is never completed, nothing is consumed, the reassembly base never advances, and the stream stalls until the deadline. A separate ceiling in the same parser turns a declared frame length above 65,535 into a connection error that RFC 9114 does not sanction.

## Problem

Commit `f078732`.

`Parse` zeroes the payload length and leaves `Consumed` at zero when the payload is not yet contiguous, and rejects a declared length above the 16-bit offset type outright (`src/flyology-http-http_3_frame_policy.adb:72-81`):

```ada
      elsif Length_Value > Varint_Policy.Value_Type (Frame_Offset'Last) then
         Result.Status := Frame_Length_Too_Large;
         return Result;
      end if;

      Result.Payload_Length := Frame_Offset (Length_Value);
      if Result.Payload_Length > Data_Length - Position then
         Result.Payload_Length := 0;
         return Result;
      end if;
```

The session consumes stream bytes only when the policy reported progress (`src/flyology-http-http_3_connection.adb:419-425`):

```ada
            if Result.Consumed > 0 then
               if Result.Event /= HTTP_3_Stream_Receive_Policy.No_Event then
                  Copy_Event (ID, Buffer, Result, Output);
               end if;
               QUIC.Consume
                 (Transport, ID, QUIC.Stream_Offset (Result.Consumed));
            end if;
```

The bound that makes this unsatisfiable is structural, not a default. `flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:18-22` declares it as a compile-time constant and derives the buffer subtypes from it:

```ada
   Max_Stream_Data : constant := 16_384;

   subtype Stream_Offset is
     Ada.Streams.Stream_Element_Offset range 0 .. Max_Stream_Data;
   subtype Stream_Index is Stream_Offset range 0 .. Max_Stream_Data - 1;
```

and the record's type invariant enforces it on every state (`flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:111-115`):

```ada
   with Type_Invariant =>
     Reassembly_State.Base <= Reassembly_State.Contiguous
     and then Reassembly_State.Contiguous <= Reassembly_State.Highest
     and then Reassembly_State.Highest - Reassembly_State.Base <=
       Absolute_Offset (Max_Stream_Data)
```

No configuration can raise it. `Transport_Settings` in `flyology_quic/src/flyology-quic-connections.ads:103-108` is a caller-supplied record, but the reassembly buffer is fixed by the constant above, so even a larger advertised `Max_Stream_Data_Bidi_Remote` would not give the parser a longer prefix. This is what distinguishes the present defect from {{ISSUE:H3-QPACK-1}}, which is about an advertised limit that is never raised; the bound here bites even on the client receive path, where credit is granted.

The package's own specification records the assumption that fails (`src/flyology-http-http_3_stream_receive_policy.ads:11-13`):

```ada
--  QUIC retains bytes until this policy reports them consumed. Incomplete
--  stream-type prefixes and frame envelopes therefore consume no input and
--  can be retried when the transport exposes a longer contiguous prefix.
```

A longer contiguous prefix than 16,384 bytes does not exist.

RFC 9114 section 7.1 defines the Length field as "A variable-length integer that describes the length in bytes of the Frame Payload" and sets no maximum, and RFC 9114 section 7 states that "Note that, unlike QUIC frames, HTTP/3 frames can span multiple packets." Stock peers emit frames well over the bound. In quic-go 0.54.1 the response writer builds one DATA frame per `Write` once its small-response buffer is exceeded (`http3/response_writer.go:177-181`):

```go
	l := uint64(len(w.smallResponseBuf) + len(p))
	if l == 0 {
		return 0, nil
	}
	df := &dataFrame{Length: l}
```

with `const maxSmallResponseSize = 4096` at `http3/response_writer.go:27`, so a handler doing `w.Write(make([]byte, 20000))` emits a single 20,000-byte DATA frame. On the upload side quic-go uses `const bodyCopyBufferSize = 8 * 1024` (`http3/request_writer.go:22`), so quic-go request bodies stay under the bound and hit {{ISSUE:H3-QPACK-1}} instead.

The second half of the defect is the 65,535-byte ceiling. `Frame_Length_Too_Large` becomes `Frame_Error` at `src/flyology-http-http_3_stream_receive_policy.adb:403-405`, and `Application_Error_For` maps `Frame_Error` to `16#106#` at `src/flyology-http-server-http_3.adb:289`, which `Close_For_H3_Error` sends as a connection-scope close. RFC 9114 section 7.1 imposes no such maximum.

The interoperability lane passes because no frame in it approaches the bound: the oracles exchange the strings `hello` and `echo:payload` (`tests/oracle/quic-go/main.go:114-115`, `tests/oracle/aioquic_h3_client.py:70`), and every response the Ada server produces is framed in 1,024-byte DATA frames (`Response_Chunk_Size : constant Positive := 1_024` at `src/flyology-http-server-http_3.adb:46`). One maintained test pins the ceiling: `tests/flyology-http-http_3_frame_policy-smoke.adb:45-47` asserts that a declared length of 65,536 is `Frame_Length_Too_Large`.

## What happens now

Spike: the program opens a server-side request stream in the proved receive policy, consumes a normal HEADERS frame so the reassembly base has advanced, then hands `Process_Compact` the largest contiguous prefix the transport can ever present for one frame: a full 16,384-byte window holding a DATA envelope that declares 20,000 payload bytes followed by 16,379 payload bytes. It asserts that the policy makes forward progress. Part B feeds the parser a DATA envelope declaring 65,536 bytes and asserts that it is not a connection error.

```ada
      --  DATA (type 0x00) with a four-byte QUIC varint length of 20,000
      --  (0x4E20 with the 0b10 prefix): 00 80 00 4E 20.
      Envelope : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#80#, 16#00#, 16#4E#, 16#20#);
      Buffer : Ada.Streams.Stream_Element_Array (1 .. Window) :=
        (others => Character'Pos ('a'));
   begin
      Buffer (1 .. Envelope'Length) := Envelope;
      Process_Compact (Connection, Stream, Buffer, Headers, Result);
      ...
      --  DATA with a four-byte varint length of 65,536 (0x10000).
      Oversize : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#80#, 16#01#, 16#00#, 16#00#);
      Parsed : constant Frames.Parse_Result := Frames.Parse (Oversize);
```

```
  note QUIC reassembly window = 16384 bytes; declared DATA frame length = 20000
  ok   the request field section encodes
  ok   the request stream opens
  ok   the HEADERS frame is consumed
  note largest contiguous DATA payload prefix the window can hold = 16379 bytes
  note Process_Compact status NEED_MORE_DATA, consumed 0
  FAIL a DATA frame larger than the reassembly window makes progress instead of stalling forever
  note Frame_Policy.Parse of a 65,536-byte DATA length: FRAME_LENGTH_TOO_LARGE
  note Process_Compact of the 65,536-byte DATA envelope: FRAME_ERROR
  FAIL a DATA frame length above 65,535 is not a connection error, RFC 9114 section 7.1 setting no maximum
checks: 5  failures: 2
BUG REPRODUCED
exit status 1
```

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A DATA frame of any length permitted by RFC 9114 section 7.1 must be receivable. Either the receive path consumes a DATA payload incrementally rather than requiring the whole frame to be contiguous, or the reassembly buffer is large enough to hold the largest frame the profile accepts. A declared length above the profile's own capacity is a resource decision, not a `Frame_Error`; RFC 9114 section 7.1 sets no maximum on the field.

## Suggested treatment

The smallest fix that closes the stall is to let `Process_Compact` consume a DATA frame's payload in pieces: once the envelope has been parsed, report the payload bytes present in the current prefix as consumed and carry the outstanding payload count in `Stream_State`, so the reassembly base advances and the remaining payload can arrive. HEADERS sections still have to be whole, but they are bounded by the field-section limits already. The alternative is to enlarge the reassembly buffer, which does not generalise: a frame larger than whatever the new bound is has the same fate.

For the second half, an oversized declared length should become the profile's resource error rather than `Frame_Error`, or the frame-length type should be widened to what the profile can actually accept.

This needs a maintainer decision: both directions change a value with external effect. Under "Decision authority" and "Ada interface values" the options for the frame-length ceiling and for `Max_Stream_Data` in `flyology_quic/src/flyology-quic-stream_reassembly_policy.ads:18` are a private implementation value, a caller parameter, a generic formal, a discriminant on the reassembly state, a value derived from the existing `Transport_Settings` contract, build-time configuration, or a deliberately public constant. Picking incremental consumption instead adds no constant but changes the documented consumption rule quoted above, which is itself an interface statement.

`src/flyology-http-http_3_frame_policy.adb` and `src/flyology-http-http_3_stream_receive_policy.adb` are both proved by `./scripts/prove.sh`, and `flyology_quic/src/flyology-quic-stream_reassembly_policy.adb` is proved by the QUIC suite that `./scripts/prove.sh` runs first; a fix has to keep all three discharging with `--checks-as-errors=on`, and the reassembly change in particular has to keep the type invariant provable. The regression test belongs in `tests/flyology-http-http_3_stream_receive_policy-smoke.adb`, and the spike above is the test. `tests/flyology-http-http_3_frame_policy-smoke.adb:45-47` asserts the current 65,535 ceiling and must change with it.

## Severity

A response body written in one call by a stock HTTP/3 origin is a single DATA frame, so the Ada client stalls on it and the exchange fails at its deadline; quic-go 0.54.1 writes exactly that shape, confirmed from its vendored source above. On the server side the same bound blocks any peer that frames a request body in one piece. The stall is silent: no event, no error, no close, just no progress until the deadline. The second half converts a legal large frame into a connection-scope close that destroys unrelated requests. Deterministic.
