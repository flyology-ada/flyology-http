Title: Response heads of 16383 and 16384 bytes pass the parser oracle and fail on the live transport
Labels: bug

## Summary

`Parse_Available_Final_Head` applies two different comparisons to the same 16 KiB bound. Once the terminator is present it accepts a head of exactly `Default_Max_Bytes`; while the terminator is still missing it refuses as soon as `Default_Max_Bytes` bytes are buffered. A head of 16383 or 16384 bytes therefore passes `Validate_Response`, which always sees the whole message at once, and raises `Flyology.HTTP.Client.Response_Too_Large` on the live transport whenever the head arrives in more than one delivery. The parser matrix records the 16384-byte head as an accepted boundary that the transport path does not honour.

## Problem

Commit `f078732`.

The two comparisons sit in one loop (`src/flyology-http-client-http_1_internals.adb:367-381`):

```ada
            if Mark = 0 then
               if Text'Length >= Flyology.HTTP.Headers.Default_Max_Bytes then
                  raise Response_Too_Large;
               end if;
               return;
            end if;

            declare
               Head_Last : constant Natural := Mark + CRLF'Length - 1;
            begin
               if Head_Last - Text'First + 1 >
                 Flyology.HTTP.Headers.Default_Max_Bytes
               then
                  raise Response_Too_Large;
               end if;
```

`Head_Last - Text'First + 1 > Default_Max_Bytes` accepts a head of exactly 16384 bytes. `Text'Length >= Default_Max_Bytes` fires at 16384 buffered bytes with no terminator yet seen, so it rejects the last two heads of the accepted range as soon as the terminator lands in a second delivery.

`Validate_Response` contains the same two checks (`src/flyology-http-client-http_1_internals.adb:515-528`), but it is handed the whole message in one string, so `Mark` is never zero at the boundary and only the second check ever applies there.

The two bounds therefore disagree exactly when the head does not arrive whole, which is the ordinary case. The client's receive buffer is 8 KiB (`src/flyology-http-client.adb:65`):

```ada
   Receive_Buffer_Size : constant Positive := 8 * 1_024;
```

so a 16 KiB head is always read in at least two receives.

The maintained parser matrix pins the accepting side of the disagreement. It builds a head of exactly `Default_Max_Bytes` (`tests/http_client_parser_matrix.adb:118-123`):

```ada
   Head_Prefix : constant String :=
     "HTTP/1.1 200 OK" & CRLF & "X: ";
   Head_Suffix : constant String := CRLF;
   Exact_Value_Length : constant Natural :=
     Flyology.HTTP.Headers.Default_Max_Bytes
       - Head_Prefix'Length - Head_Suffix'Length;
```

and validates it (`tests/http_client_parser_matrix.adb:201-206`):

```ada
   Validate
     (Head_Prefix & String'(1 .. Exact_Value_Length => 'a') &
      Head_Suffix & CRLF);
   Reject_Size
     (Head_Prefix & String'(1 .. Exact_Value_Length + 1 => 'a') &
      Head_Suffix & CRLF);
```

The matrix runs through the oracle only, so it records an "exact" boundary at 16384 that the live path does not honour for the last two bytes of the range.

## What happens now

Spike: the program builds heads of 16382, 16383 and 16384 bytes with the parser matrix's own construction, runs each through `Flyology.HTTP.Client.Testing.Validate_Response`, and then serves the same bytes from a raw `Flyology.IO.Sockets` peer that writes the head in two pieces split around the client's 8 KiB receive buffer, which is what an ordinary kernel delivery does. The 16382-byte head is the control. Each check asserts that the oracle and the transport agree.

```ada
     (Head_Prefix & String'(1 .. Exact_Value_Length - Shrink => 'a')
      & Head_Suffix & CRLF);
   ...
         --  Two deliveries around the client's 8 KiB receive buffer.
         Sockets.Send_All
           (Peer, B (Payload (Payload'First .. Cut)), Timeout => 5.0);
         delay 0.15;
         Sockets.Send_All
           (Peer, B (Payload (Cut + 1 .. Payload'Last)), Timeout => 5.0);
```

```
  note Default_Max_Bytes is 16384
  note H_16382: head length 16382, wire bytes 16384
  note H_16383: head length 16383, wire bytes 16385
  note H_16384: head length 16384, wire bytes 16386
  note H_16382: oracle accepted, live status 200
  ok   H_16382: the parser oracle accepts the head
  ok   H_16382: the live transport accepts the same head
  note H_16383: oracle accepted, live FLYOLOGY.HTTP.CLIENT.RESPONSE_TOO_LARGE
  ok   H_16383: the parser oracle accepts the head
  FAIL H_16383: the live transport accepts the same head
  note H_16384: oracle accepted, live FLYOLOGY.HTTP.CLIENT.RESPONSE_TOO_LARGE
  ok   H_16384: the parser oracle accepts the head
  FAIL H_16384: the live transport accepts the same head
checks: 6  failures: 2
BUG REPRODUCED
```

The control passes both ways. The two heads at the top of the accepted range pass the oracle and are refused on the wire.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

The oracle and the transport should apply one bound to the same quantity, so that a head the parser matrix records as valid is also accepted when it arrives in pieces. No standard is at issue here; the 16 KiB limit is the crate's own documented bound, and the defect is that the two code paths measure it differently.

## Suggested treatment

Make the pre-terminator check bound the same quantity the post-terminator check bounds. The buffered length may legitimately exceed the head bound by the terminator itself, so the incomplete-head test should allow the terminator's width before giving up:

```ada
            if Mark = 0 then
               if Text'Length
                 > Flyology.HTTP.Headers.Default_Max_Bytes + CRLF'Length
               then
                  raise Response_Too_Large;
               end if;
               return;
            end if;
```

and the same correction applies to the copy in `Validate_Response` at `src/flyology-http-client-http_1_internals.adb:515-519`, so the two paths stay identical. This needs a maintainer decision: the change alters where the incomplete-head bound sits relative to `Default_Max_Bytes`, which is an externally observable limit. The options are a private implementation value derived from `Default_Max_Bytes` and `CRLF'Length` as above, a value derived from the existing contract by moving the check after the terminator search, a caller parameter or a generic formal on the head bound, build-time configuration, or a deliberately public constant for the incomplete-head allowance. The alternative reading is that `Default_Max_Bytes` should be an exclusive bound in both places, which would make the parser matrix's `Validate` case at `:201-203` wrong and require that test to change.

`src/flyology-http-client-http_1_internals.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in `tests/http_client_parser_matrix.adb`, which already owns this boundary at `:201-206`, paired with a live case in `tests/http_client_fragmentation.adb`, which already caps connection receives and drives a fragmented head. The spike is the test.

## Severity

A response head within two bytes of the 16 KiB limit is refused with `Response_Too_Large` although the documented bound admits it, and the exchange fails. The live outcome depends on delivery: a head that arrives whole is accepted, so on a fast loopback link the same response may succeed and on a real network fail. It takes a head within two bytes of the limit, which is unusual, and the conformance record is the sharper problem: the parser matrix asserts a boundary the transport does not honour. Deterministic for the two affected lengths once the head is split, nondeterministic between links.
