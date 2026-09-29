Title: Validate_Response raises Constraint_Error for chunk sizes 7FFFFFFE and 7FFFFFFF
Labels: bug
Refs: H1-CLIENT-1, H1-CLIENT-7

## Summary

The chunked branch of `Validate_Response` compares the buffered length against `Size + CRLF'Length` with `Size : Natural`. `Chunk_Size` admits any value up to `Natural'Last`, so for the two chunk sizes `7FFFFFFE` and `7FFFFFFF` the `Integer` intermediate overflows and the overflow check raises `Constraint_Error` where `7FFFFFF0` yields `Protocol_Error "incomplete HTTP chunk data"`. `Flyology.HTTP.Client.Testing.Fuzz_Response`, which the conformance document designates as the crash arbiter, therefore reports a crash for two legal chunk sizes. The production decoder is not affected.

## Problem

Commit `f078732`.

The comparison (`src/flyology-http-client-http_1_internals.adb:585-587`):

```ada
                  if Length (Data.Pending) < Size + CRLF'Length then
                     raise Protocol_Error with "incomplete HTTP chunk data";
                  end if;
```

`Size` comes from `Chunk_Size`, which returns `Natural` and guards only against `Natural'Last` (`src/flyology-http-client-http_1_internals.adb:793-796`):

```ada
         if Result > (Natural'Last - Digit) / 16 then
            raise Protocol_Error with "overflowing HTTP chunk size";
         end if;
         Result := Result * 16 + Digit;
```

so `Size` can be `Natural'Last` or one below it, and `Size + 2` exceeds `Integer'Last`.

Both values are legal. RFC 9112 section 7.1 gives `chunk-size = 1*HEXDIG` and states the requirement directly: "Therefore, recipients MUST anticipate potentially large hexadecimal numerals and prevent parsing errors due to integer conversion overflows or precision loss due to integer representation."

What makes this worth fixing is the arbiter. `tests/http-client-conformance.md:100-104` designates the wrapper and says what counts as a crash:

```
`Flyology.HTTP.Client.Testing.Fuzz_Response` is a stateless wrapper around the
production status, header, length, chunk, and trailer validators. It accepts a
fixed 1,000-byte array plus a prefix length. Documented protocol and size
rejections are normal outcomes; assertion failures, runtime checks, hangs, and
other exceptions remain crashes.
```

A `Constraint_Error` escaping that wrapper is by this definition a crash, so a mutation or fuzzing campaign records a finding the production decoder cannot exhibit.

The scope is genuinely limited to the oracle. `Consume_Available_Content` (`src/flyology-http-client-http_1_internals.adb:859-1008`) and `Read_Response_Body` (`:1010-1180`) only assign `Chunk_Remaining := Chunk_Size (...)` and pass it to `Copy_Pending` as a limit reduced by `Natural'Min`, never adding to it, so no user-reachable path evaluates `Size + CRLF'Length`.

`tests/http_client_parser_randomized.adb:58` calls the same wrapper, and `tests/corpus/fixtures/h1-invalid-chunk-size.bin` covers a syntactically invalid size rather than a large valid one, so no maintained test reaches these two values.

## What happens now

Spike: the program builds a chunked response head followed by one chunk-size line and calls `Flyology.HTTP.Client.Testing.Fuzz_Response` with a padded 1000-byte input, exactly as a campaign does. `7FFFFFF0` and `80000000` are the controls, the first a documented incomplete-data rejection and the second a documented size rejection. It then serves the same bytes from a raw `Flyology.IO.Sockets` peer to check the scope claim against the production decoder.

```ada
   function Wire (Size_Text : String) return String is
     ("HTTP/1.1 200 OK" & CRLF
      & "Transfer-Encoding: chunked" & CRLF & CRLF
      & Size_Text & CRLF);
   ...
      HC.Testing.Fuzz_Response (Input, Text'Length);
      return "consumed";
   ...
   Check (Arbiter ("7FFFFFFE") = "consumed",
```

```
  note Natural'Last is 2147483647 = 16#7FFFFFFF#
  note arbiter 7FFFFFF0 -> consumed
  note arbiter 7FFFFFFE -> CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:585 overflow check failed
  note arbiter 7FFFFFFF -> CONSTRAINT_ERROR: flyology-http-client-http_1_internals.adb:585 overflow check failed
  note arbiter 80000000 -> consumed
  ok   control: chunk size 7FFFFFF0 is a documented rejection
  ok   control: chunk size 80000000 is a documented size rejection
  FAIL chunk size 7FFFFFFE is a documented rejection, not a crash
  FAIL chunk size 7FFFFFFF is a documented rejection, not a crash
  note live production decoder on the same bytes -> FLYOLOGY.HTTP.PROTOCOL_ERROR
  ok   scope: the production decoder rejects the same bytes with a typed Protocol_Error
checks: 5  failures: 2
BUG REPRODUCED
```

Both controls are consumed as documented rejections, and the live scope check confirms that the production decoder answers `Protocol_Error` on the identical bytes.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A legal `chunk-size` must produce a documented rejection, not a runtime check, on every path including the fuzz arbiter. RFC 9112 section 7.1 requires a recipient to prevent parsing errors due to integer conversion overflows.

## Suggested treatment

Widen the chunk arithmetic to `Flyology.HTTP.Body_Size`: have `Chunk_Size` (`src/flyology-http-client-http_1_internals.adb:763-802`) return `Body_Size`, change `Response_Data.Chunk_Remaining` (`src/flyology-http-client.adb:309`) from `Natural` to `Body_Size`, and let the comparison at `:585` be evaluated at 64 bits. `Response_Data` is declared incomplete in the private part of `src/flyology-http-client.ads:1391` and its full record type is in the body at `src/flyology-http-client.adb:288`, so this is a private implementation change and introduces no new public constant, default, capacity or bound; the public contract already exists as `Flyology.HTTP.Body_Size`. This is the same widening that {{ISSUE:H1-CLIENT-1}} and {{ISSUE:H1-CLIENT-7}} need, so one change settles all three.

The narrower alternative, keeping `Size : Natural` and rewriting the comparison as `Length (Data.Pending) - CRLF'Length < Size` with an underflow guard, closes the crash without touching the type, but leaves the chunk decoder unable to accept a chunk of 2 GiB or more.

`src/flyology-http-client-http_1_internals.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in the seed corpus `tests/http_client_rfc_seeds.adb`, beside the existing chunk cases at `:230-246`, since `tests/http_client_parser_randomized.adb:58` drives every seed through the arbiter. Adding seeds widens `Seed_Index` at `tests/http_client_rfc_seeds.ads:4`, which is a test-side bound rather than a library one. The spike is the test.

## Severity

No user-reachable path is affected. The production decoder answers `Protocol_Error` for the same bytes, as the spike measures on a live transport, because the decoder never evaluates the overflowing expression. What degrades is the test oracle: the crash arbiter that `tests/http-client-conformance.md` designates reports a runtime check for two legal chunk sizes, so a mutation or fuzzing campaign records a false crash and the conformance claim built on that arbiter is weaker than it reads. Deterministic, and confined to the arbiter.
