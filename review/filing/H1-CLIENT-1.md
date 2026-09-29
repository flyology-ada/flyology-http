Title: HTTP/1 client rejects every response Content-Length above 2147483599 as an overflowing decimal value
Labels: bug
Refs: H1-CLIENT-7, H1-CLIENT-6

## Summary

The HTTP/1 response head parser decodes `Content-Length` through `Parse_Natural`, which returns `Natural`, and stores the result in a `Natural` field. Any syntactically valid length above 2147483599 is therefore refused at the response head with `Protocol_Error`, on the parser oracle and on the live transport. The crate's own shared length type is 64-bit and the HTTP/2 and HTTP/3 client paths accept the same field value, so a transfer of an object larger than 2 GiB from this crate's own HTTP/1 server fails at its own HTTP/1 client.

## Problem

Commit `f078732`.

`Parse_Natural` returns `Natural` and guards against `Natural'Last` (`src/flyology-http-client-http_1_internals.adb:151-168`):

```ada
   function Parse_Natural (Value : String) return Natural is
      Result : Natural := 0;
   begin
      if Value = "" then
         raise Protocol_Error with "empty HTTP decimal value";
      end if;
      for Item of Value loop
         if Item not in '0' .. '9'
           or else Result >
             (Natural'Last - (Character'Pos (Item) - Character'Pos ('0'))) / 10
         then
            raise Protocol_Error with
              "invalid or overflowing HTTP decimal value";
         end if;
         Result := Result * 10 + Character'Pos (Item) - Character'Pos ('0');
      end loop;
      return Result;
   end Parse_Natural;
```

`Content_Length` returns `Natural` as well (`src/flyology-http-client-http_1_internals.adb:170-172`):

```ada
   function Content_Length
     (Fields  : Flyology.HTTP.Headers.List;
      Present : out Boolean) return Natural
```

`Select_Body_Mode` stores it unchanged (`src/flyology-http-client-http_1_internals.adb:465-467`):

```ada
      elsif Length_Present then
         Data.Mode := (if Length_Value = 0 then No_Body else Fixed_Body);
         Data.Remaining_Body := Length_Value;
```

and the field it stores into is `Natural` (`src/flyology-http-client.adb:308`):

```ada
      Remaining_Body : Natural := 0;
```

The crate introduced a 64-bit type for exactly this purpose (`src/flyology-http.ads:103-106`):

```ada
   --  Nonnegative protocol representation byte count. This 64-bit-safe type
   --  is shared by clients and servers so message lengths do not depend on
   --  the implementation range of Natural.
   subtype Body_Size is Long_Long_Integer range 0 .. Long_Long_Integer'Last;
```

RFC 9110 section 8.6 states the requirement directly: "Any Content-Length field value greater than or equal to zero is valid.  Since there is no predefined limit to the length of content, a recipient MUST anticipate potentially large decimal numerals and prevent parsing errors due to integer conversion overflows or precision loss due to integer conversion".

The other two client engines already honour it. The HTTP/2 client parses the field into `Long_Long_Integer` (`src/flyology-http-http_2_client_connection.adb:301-305`):

```ada
   procedure Parse_Content_Length
     (Fields  : Flyology.HTTP.Headers.List;
      Present : out Boolean;
      Value   : out Long_Long_Integer;
      Valid   : out Boolean)
```

and the composable HTTP/2 and HTTP/3 buffer path uses `Body_Size'Value` (`src/flyology-http-client.adb:4186`). Part C of the spike below calls the HTTP/3 response header validator on the identical field value and it returns `VALID` with `Content_Length = 5_368_709_129`.

The value is not hypothetical. The maintained server suite asserts that this crate's own HTTP/1 server puts such a length on the wire (`tests/http_smoke.adb:288-295`):

```ada
            HTTP_Server.Begin_Response_Stream
              (Client, 200, "application/octet-stream",
               Content_Length => Five_GiB + 9);
            HTTP_Server.End_Response_Stream (Client);
         end;
         pragma Assert
           (Ada.Strings.Fixed.Index
              (To_String (Wire.Output), "Content-Length: 5368709129") /= 0);
```

So a Flyology HTTP/1.1 server to Flyology HTTP/1.1 client transfer of a 5 GiB object fails at the client's response head. The engine maps the parse failure to `Response_Invalid` and destroys the transport (`src/flyology-http-client.adb:6007-6009`).

No maintained test covers the range 2^31 to 2^63-1 on HTTP/1. The parser matrix jumps straight from small values to a 36-digit value that no 64-bit type can hold (`tests/http_client_parser_matrix.adb:163-166`):

```ada
   Reject_Protocol
     ("HTTP/1.1 200 OK" & CRLF &
      "Content-Length: 999999999999999999999999999999999999" &
      CRLF & CRLF);
```

and `tests/corpus/fixtures/h1-content-length-overflow.bin` carries the same kind of value.

The neighbouring window 2147483600 to 2147483647 fails for a second and distinct reason, reported separately in {{ISSUE:H1-CLIENT-7}}; the two share one fix site.

## What happens now

Spike: the program is a child of the private HTTP/3 policy package so that the HTTP/3 comparison is a direct call rather than a claim. Part A runs the production head parser through `Flyology.HTTP.Client.Testing.Validate_Response` and then binary-searches the whole `Body_Size` range to report the largest accepted and the smallest refused `Content-Length` rather than assuming where the bound is. Part B drives the real `Flyology.HTTP.Client` over loopback against a raw `Flyology.IO.Sockets` peer. Part C calls the HTTP/3 response header validator on the same field value. Each check asserts that a `Content-Length` the shared type can represent yields a 200 head.

```ada
   Server_Emitted : constant String := "5368709129";
   ...
      Sockets.Send
        (Peer,
         B ("HTTP/1.1 200 OK" & CRLF
            & "Content-Length: " & Server_Emitted & CRLF
            & "Content-Type: application/octet-stream" & CRLF
            & "Connection: close" & CRLF & CRLF
            & "abcd"),
         Timeout => 5.0);
   ...
         Check (HC.Status (Reply) = 200,
                "live HTTP/1.1 path: Execute returns the 200 head");
```

```
  note Natural'Last is 2147483647; Body_Size'Last is 9223372036854775807
  note 2147483599 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: peer closed before Content-Length was received
  note 2147483647 -> UNEXPECTED CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed
  note 2147483648 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: invalid or overflowing HTTP decimal value
  note 5368709129 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: invalid or overflowing HTTP decimal value
  ok   control: Content-Length 2147483599 is a valid head
  FAIL Content-Length 2147483648 is a valid head
  FAIL Content-Length 5368709129, which this crate's own HTTP/1 server emits, is a valid head
  FAIL Content-Length 9223372036854775807 (Body_Size'Last) is a valid head
  note largest accepted Content-Length is 2147483599
  note smallest rejected Content-Length is 2147483600
  note Natural'Last is 2147483647, so the bound is not Natural'Last
  note HTTP/3 Validate_Response status is VALID
  ok   control: the HTTP/3 response validator accepts Content-Length 5368709129
  ok   control: the HTTP/3 validator keeps the 64-bit value
  FAIL live HTTP/1.1 path: Execute returns the 200 head, got FLYOLOGY.HTTP.PROTOCOL_ERROR: 
checks: 7  failures: 4
BUG REPRODUCED
```

The measured bound is 2147483599, not `Natural'Last`. The 48 values between 2147483600 and `Natural'Last` are admitted by the guard and fail later, which is the separate defect.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

An HTTP/1 response carrying any `Content-Length` representable in `Flyology.HTTP.Body_Size` should be accepted and its length carried at 64 bits, as RFC 9110 section 8.6 requires and as the HTTP/2 and HTTP/3 client paths already do.

## Suggested treatment

Widen the HTTP/1 response length arithmetic to `Flyology.HTTP.Body_Size`: have `Parse_Natural` and `Content_Length` accumulate and return `Body_Size`, and change `Response_Data.Remaining_Body` and `Response_Data.Chunk_Remaining` (`src/flyology-http-client.adb:308-309`) from `Natural` to `Body_Size`. `Response_Data` is declared incomplete in the private part of `src/flyology-http-client.ads:1391` and its full record type lives in the body at `src/flyology-http-client.adb:288`, so this is a private implementation change: no new public constant, default, capacity or bound is introduced, and the public contract already exists as `Flyology.HTTP.Body_Size`. The conversion at `src/flyology-http-client.adb:4022` becomes an identity and the `Natural` conversions on the delivery path need refitting against the buffer offsets.

Accumulating the digit value rather than `Character'Pos (Item)` in the same subprogram settles {{ISSUE:H1-CLIENT-7}}, and widening `Chunk_Size` the same way settles {{ISSUE:H1-CLIENT-6}}. One change closes all three.

Neither `src/flyology-http-client-http_1_internals.adb` nor `src/flyology-http-client.adb` is a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in the existing parser matrix, `tests/http_client_parser_matrix.adb`, beside the 36-digit rejection at `:163-166`: add accepted cases at 2147483600, `Natural'Last`, 2^31, 5368709129 and `Body_Size'Last`, and keep the 36-digit value as the rejection. The spike is the test. The live half belongs in `tests/http_client_smoke.adb`, which already drives a raw loopback peer.

## Severity

Every HTTP/1.1 response declaring more than 2147483599 body bytes is refused as malformed, so no HTTP/1 client in this crate can fetch an object of 2 GiB or more with a known length. The trigger is a stock origin serving a large object with an exact `Content-Length`, including this crate's own HTTP/1 server, and the default `Configure` overloads select HTTP/1. The caller sees `Protocol_Error` and `Response_Invalid` and the transport is destroyed. Deterministic.
