Title: Set Dynamic Table Capacity 0 and a nonzero Delta Base are rejected although RFC 9204 permits both
Labels: bug
Refs: none

## Summary

Two QPACK inputs that RFC 9204 permits are refused. The receive policy rejects every byte on the peer's QPACK encoder stream, including the one Set Dynamic Table Capacity instruction that a zero capacity limit allows, and answers with QPACK_ENCODER_STREAM_ERROR, which is a connection close. The field-section decoder rejects any nonzero Delta Base, although with Required Insert Count 0 and a Sign bit of 0 the resulting Base is a legal nonnegative value.

## Problem

Commit `f078732`.

Every byte on the encoder stream is refused (`src/flyology-http-http_3_stream_receive_policy.adb:169-174`):

```ada
      elsif Stream.Stream_Type = QPACK_Encoder_Stream then
         --  SETTINGS_QPACK_MAX_TABLE_CAPACITY is fixed at zero, which
         --  prohibits every encoder instruction in this profile.
         Result.Status := QPACK_Encoder_Stream_Error;
         return;
      end if;
```

The reasoning in that comment does not hold for one instruction. RFC 9204 section 4.3.1 states: "An encoder informs the decoder of a change to the dynamic table capacity using an instruction that starts with the '001' 3-bit pattern" and "The new capacity MUST be lower than or equal to the limit described in Section 3.2.3." With the advertised limit at zero, a capacity of zero is the one legal value, so the single octet `0x20` is a conformant no-op rather than an encoder-stream error. RFC 9204 section 4.3.1 reserves QPACK_ENCODER_STREAM_ERROR for "a new dynamic table capacity value that exceeds this limit".

The second rejection is in the field-section prefix (`src/flyology-http-qpack_field_section_policy.adb:256-262`):

```ada
      Read_Integer (7, Delta_Base, Success);
      if not Success then
         return;
      elsif Delta_Base /= 0 then
         Status := Invalid_Prefix;
         return;
      end if;
```

RFC 9204 section 4.5.1.2 states: "A Sign bit of 0 indicates that the Base is greater than or equal to the value of the Required Insert Count; the decoder adds the value of Delta Base to the Required Insert Count to determine the value of the Base", and the only stated constraint is "The value of Base MUST NOT be negative." Required Insert Count 0, Sign 0 and Delta Base 1 give Base 1, which is not negative and is therefore legal.

`src/flyology-http-server-http_3.adb:297` maps `QPACK_Encoder_Stream_Error` to `16#201#`, which `Close_For_H3_Error` sends as a connection-scope close, so the first case costs the whole connection.

The existing coverage does not reach either input: `tests/flyology-http-qpack_field_section_policy-smoke.adb` consumes the RFC 9204 Appendix B.1 vector, whose prefix has Delta Base 0, and no test writes anything on the peer's encoder stream.

## What happens now

Spike: the program opens a client-initiated unidirectional stream at the server, declares the QPACK encoder type, then sends the single octet `0x20`, which is Set Dynamic Table Capacity with capacity 0. It then decodes a field section whose prefix has Required Insert Count 0 and Delta Base 1 followed by one static indexed field line, and decodes the same section with Delta Base 0 as a control.

```ada
   Process_Compact (Connection, Stream, (1 => 16#02#), Headers, Result);
   Process_Compact (Connection, Stream, (1 => 16#20#), Headers, Result);
   ...
      Wire : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#01#, 16#D1#);
      Parsed : constant QPACK.Decode_Result := QPACK.Decode (Wire);
   ...
      Wire : constant Ada.Streams.Stream_Element_Array :=
        (16#00#, 16#00#, 16#D1#);
```

```
  note encoder-stream type octet: CONSUMED, stream kind QPACK_ENCODER_STREAM
  note Set Dynamic Table Capacity 0: QPACK_ENCODER_STREAM_ERROR
  FAIL Set Dynamic Table Capacity to zero, the only capacity the advertised limit permits, is not an encoder-stream error
  note Required Insert Count 0 with Delta Base 1: INVALID_PREFIX
  FAIL a nonzero Delta Base with Required Insert Count 0 decodes, Base being 1 and so not negative
  note control, Delta Base 0: DECODED
checks: 2  failures: 2
BUG REPRODUCED
exit status 1
```

The control line settles the second case: the identical section with Delta Base 0 decodes, so neither the field count nor the static index is the variable.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A Set Dynamic Table Capacity instruction whose capacity is within the advertised limit should be consumed and ignored, since with a zero-capacity table it changes nothing. A field-section prefix with Required Insert Count 0, Sign 0 and any Delta Base should decode, because the resulting Base is nonnegative; the profile can still refuse any representation that actually references a dynamic entry, which it already does through `Unsupported_Dynamic`.

## Suggested treatment

On the encoder stream, parse the instruction rather than refusing the byte: accept `001` Set Dynamic Table Capacity when the decoded capacity is zero, consume it, and keep QPACK_ENCODER_STREAM_ERROR for a nonzero capacity and for the insert instructions that a zero-capacity table genuinely prohibits. In the field-section prefix, read Delta Base, compute the Base, and refuse only a Sign bit of 1 whose Delta Base is at least the Required Insert Count, which is the condition RFC 9204 section 4.5.1.2 actually states; a nonzero Base with an empty dynamic table addresses nothing, so the existing `Unsupported_Dynamic` path still catches any representation that tries to use it.

No new constant, default, capacity or parameter is implied, so this is not a decision under "Decision authority"; it is a correction of two conditions to the ones the RFC states.

Both `src/flyology-http-http_3_stream_receive_policy.adb` and `src/flyology-http-qpack_field_section_policy.adb` are proved by `./scripts/prove.sh`, and the prefix decoder carries bounds contracts on `Position` and `Consumed`; the fix must keep both discharging with `--checks-as-errors=on`. The regression test belongs in `tests/flyology-http-qpack_field_section_policy-smoke.adb` for the prefix half and `tests/flyology-http-http_3_stream_receive_policy-smoke.adb` for the encoder-stream half; the spike above is the test for both. No maintained test asserts the current rejections.

## Severity

The encoder-stream half is a connection close in response to a conformant instruction, so a peer that emits it cannot use the server at all. The field-section half fails one message. Practical reach is small in both cases: an encoder facing a zero capacity limit has no reason to announce a capacity of zero, and a nonzero Base addresses nothing when the dynamic table is empty, so only a gratuitously-emitting encoder is affected. No peer that behaves this way was identified. Deterministic; not reproduced against a live peer.
