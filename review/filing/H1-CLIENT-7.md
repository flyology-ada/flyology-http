Title: Parse_Natural accumulates Character'Pos, so 48 Content-Length values raise Constraint_Error
Labels: bug
Refs: H1-CLIENT-1, H1-CLIENT-6

## Summary

`Parse_Natural` in the HTTP/1 response head parser tests its accumulator against the digit value but adds `Character'Pos (Item)`, which is 48 larger, before subtracting 48. The `Integer` intermediate therefore overflows for the 48 `Content-Length` values 2147483600 to 2147483647, all of which `Natural` represents exactly and all of which the guard deliberately admits. A peer that answers with any of those lengths makes the production response head parser raise a raw `Constraint_Error` that reaches the caller of `Execute` verbatim, instead of a typed `Protocol_Error`.

## Problem

Commit `f078732`.

The guard and the accumulation disagree (`src/flyology-http-client-http_1_internals.adb:157-166`):

```ada
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
```

The guard reasons about `Character'Pos (Item) - Character'Pos ('0')`, the digit value in 0 .. 9. The statement parses as `((Result * 10) + Character'Pos (Item)) - 48`, so the intermediate `Result * 10 + Character'Pos (Item)` is an `Integer` expression up to 48 larger than the value the guard allowed. For a final value in 2147483600 .. 2147483647 that intermediate exceeds `Integer'Last` and the overflow check raises `Constraint_Error` at line 165.

The check is live in an ordinary build. The library takes its compiler switches from the Alire-generated crate configuration (`flyology_http.gpr:96-100`):

```ada
   package Compiler is
      for Default_Switches ("Ada") use
        Flyology_HTTP_Config.Ada_Compiler_Switches
        & ("-gnatwJ");
   end Compiler;
```

On this host that configuration's default `release` profile supplies `-O3`, `-gnatn`, `-ffunction-sections`, `-fdata-sections` and `-gnatW8`, and no `-gnatp`. Overflow checking is therefore not suppressed in a release build, and the program below is built through the same library project.

This is reachable from the wire, not only from a parser oracle. The engine's catch-all arm saves the occurrence, releases the transport with `Reusable => False` and terminalizes as `Transport_Failed` (`src/flyology-http-client.adb:6017-6023`):

```ada
      when Error : others =>
         Ada.Exceptions.Save_Occurrence (State.Saved_Error, Error);
         State.Has_Saved_Error := True;
         Release_Exchange_Transport (State, Reusable => False);
         Complete_Exchange
           (Item, Transport_Failed, Flyology.Operations.Failed);
```

and `Finish` re-raises the saved occurrence with its original identity (`src/flyology-http-client.adb:1736-1742` and `:1781-1787`):

```ada
      if Operation.State.Has_Saved_Error then
         Ada.Exceptions.Raise_Exception
           (Ada.Exceptions.Exception_Identity
              (Operation.State.Saved_Error),
            Ada.Exceptions.Exception_Message
              (Operation.State.Saved_Error));
      end if;
```

So no pooled transport is poisoned, but the application receives a language runtime check rather than the `Protocol_Error` and `Response_Invalid` vocabulary that `src/flyology-http-client.ads` and `tests/http-client-conformance.md` establish for a bad response. RFC 9110 section 8.6 states the requirement this breaks literally: "a recipient MUST anticipate potentially large decimal numerals and prevent parsing errors due to integer conversion overflows or precision loss due to integer conversion".

No maintained test covers this window. `tests/http_client_parser_matrix.adb:163-166` jumps from small values straight to a 36-digit value, so the whole neighbourhood of `Natural'Last` is unexercised.

Lengths above `Natural'Last` fail earlier and for a different reason, reported separately in {{ISSUE:H1-CLIENT-1}}; the two share one fix site, as does {{ISSUE:H1-CLIENT-6}}.

## What happens now

Spike: the program classifies response heads carrying a `Content-Length` through `Flyology.HTTP.Client.Testing.Validate_Response`, which runs the production head parser, and enumerates the neighbourhood 2147483580 .. 2147483660 to report the exact set of values that raise a runtime check rather than assuming it. It then drives the real `Flyology.HTTP.Client` over loopback against a raw `Flyology.IO.Sockets` peer answering `Content-Length: 2147483647`. Each check asserts that a length inside `Natural` yields a 200 head and that no raw `Constraint_Error` escapes.

```ada
   for Value in Long_Long_Integer range 2_147_483_580 .. 2_147_483_660 loop
      if Classify (Decimal (Value)) = Runtime_Check then
   ...
      Sockets.Send_All
        (Peer,
         B ("HTTP/1.1 200 OK" & CRLF
            & "Content-Length: " & Live_Length & CRLF
            & "Content-Type: application/octet-stream" & CRLF
            & "Connection: close" & CRLF & CRLF
            & "abcd"),
         Timeout => 5.0);
   ...
         Check (Ada.Exceptions.Exception_Identity (Occurrence)
                  /= Constraint_Error'Identity,
                "live HTTP/1.1 path: no raw Constraint_Error reaches the"
                & " caller");
```

```
  note Natural'Last is 2147483647
  note 2147483599 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: peer closed before Content-Length was received
  note 2147483600 -> CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed
  note 2147483647 -> CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed
  note 2147483648 -> FLYOLOGY.HTTP.PROTOCOL_ERROR: invalid or overflowing HTTP decimal value
  note Content-Length values raising a runtime check: 48, from 2147483600 to 2147483647
  ok   control: Content-Length 2147483599 is a valid head
  FAIL Content-Length 2147483600, inside Natural, is a valid head
  FAIL Content-Length 2147483647 (Natural'Last) is a valid head
  FAIL Content-Length 2147483600 does not escape as a runtime check
  ok   control: an out-of-range Content-Length is a typed rejection
  FAIL live HTTP/1.1 path: Content-Length 2147483647 yields the 200 head, got CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:165 overflow check failed
  FAIL live HTTP/1.1 path: no raw Constraint_Error reaches the caller
checks: 7  failures: 5
BUG REPRODUCED
```

The affected set is exactly 48 contiguous values, 2147483600 through 2147483647, and the caller of `Execute` receives the runtime check message verbatim.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A `Content-Length` the guard admits must be decoded without a runtime check, and any `Content-Length` outside the decoder's range must be refused with `Protocol_Error`, never with `Constraint_Error`. RFC 9110 section 8.6 requires a recipient to prevent parsing errors due to integer conversion overflows.

## Suggested treatment

Accumulate the digit value rather than the character code in `Parse_Natural`, binding it once so the guard and the accumulation agree:

```ada
         Digit := Character'Pos (Item) - Character'Pos ('0');
         ...
         Result := Result * 10 + Digit;
```

Widening the same arithmetic to `Flyology.HTTP.Body_Size` at the same time settles {{ISSUE:H1-CLIENT-1}}, and widening `Chunk_Size` settles {{ISSUE:H1-CLIENT-6}}. `Remaining_Body` and `Chunk_Remaining` (`src/flyology-http-client.adb:308-309`) live inside `Response_Data`, whose full record type is in the body at `src/flyology-http-client.adb:288` and which the specification declares only as an incomplete type at `src/flyology-http-client.ads:1391`. The widening is therefore a private implementation change and introduces no new public constant, default, capacity or bound.

Neither `src/flyology-http-client-http_1_internals.adb` nor `src/flyology-http-client.adb` is a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in the existing parser matrix, `tests/http_client_parser_matrix.adb`, beside the 36-digit rejection at `:163-166`: add accepted cases at 2147483600 and `Natural'Last` and a boundary sweep across the window. The spike is the test. The live half belongs in `tests/http_client_smoke.adb`, which already drives a raw loopback peer.

## Severity

A 2 GiB object served with an exact `Content-Length` that happens to fall in this 48-value window is ordinary valid traffic, and the response makes the client raise a raw `Constraint_Error` that reaches the application with the file name and line number of the parser in its message. The window is narrow, which is what keeps this from being worse, but it needs no hostile peer and no unusual call: a stock origin and the default HTTP/1 configuration are enough. The transport is destroyed rather than returned to the pool, so no later exchange is affected. Deterministic.
