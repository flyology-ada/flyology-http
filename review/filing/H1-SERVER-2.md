Title: Chunk-extension bad whitespace is rejected although the chunk-ext grammar admits it in all four positions
Labels: bug

## Summary

`Parse_Chunk_Size` ends the hex slice at the character before the first semicolon, so whitespace before the `;` lands inside the size and fails the HEXDIG scan. The extension scanner then hands raw slices to `Validate_Token`, so whitespace after the `;`, before the `=` or after the `=` becomes an invalid extension name or value. All four positions in which the `chunk-ext` grammar admits BWS are rejected, and a well-formed chunked body is answered with 400 and a closed connection.

## Problem

Commit `f078732`.

The size slice ends immediately before the semicolon (`src/flyology-http-server.adb:875-877`):

```ada
      Semicolon : constant Natural := Ada.Strings.Fixed.Index (Line, ";");
      Last      : constant Natural :=
        (if Semicolon = 0 then Line'Last else Semicolon - 1);
```

so `1 ;a=b` presents `"1 "` to the HEXDIG scan and fails at `src/flyology-http-server.adb:894`:

```ada
            raise Protocol_Error with "invalid HTTP chunk size";
```

The extension scanner walks to the next `=` or `;` and token-checks the raw slice (`src/flyology-http-server.adb:911-922`):

```ada
                  while Position <= Line'Last
                    and then Line (Position) not in '=' | ';'
                  loop
                     Position := Position + 1;
                  end loop;
                  if Position = Name_First then
                     raise Protocol_Error with
                       "invalid HTTP chunk extension";
                  end if;
                  Validate_Token
                    (Line (Name_First .. Position - 1),
                     "chunk extension name");
```

so `1; a=b` and `1;a =b` fail as invalid names and `1;a= b` fails as an invalid value.

RFC 9112 section 7.1.1 admits BWS in every one of those positions:

```
     chunk-ext      = *( BWS ";" BWS chunk-ext-name
                         [ BWS "=" BWS chunk-ext-val ] )

     chunk-ext-name = token
     chunk-ext-val  = token / quoted-string
```

and the same section says "A recipient MUST ignore unrecognized chunk extensions." RFC 9110 section 5.6.3 says what a recipient does with BWS: "The BWS rule is used where the grammar allows optional whitespace only for historical reasons.  A sender MUST NOT generate BWS in messages.  A recipient MUST parse for such bad whitespace and remove it before interpreting the protocol element."

Existing coverage handles extensions without BWS. `tests/http_smoke.adb:481-494` accepts a quoted extension with a quoted-pair, and `tests/http_smoke.adb:2174-2179` pins `1;=x` as a rejection:

```ada
      pragma Assert
        (Is_Rejected
           ("POST / HTTP/1.1" & CRLF
            & "Host: localhost" & CRLF
            & "Transfer-Encoding: chunked" & CRLF & CRLF
            & "1;=x" & CRLF & "x" & CRLF & "0" & CRLF & CRLF));
```

Neither exercises whitespace, so the four BWS positions are untested.

## What happens now

Spike: each size line is driven through `Read_Request` on an in-memory `Flyology.HTTP.Server.Transport` with a one-byte chunk followed by the last chunk. The extension `1;a=b` without whitespace is the baseline. Each check asserts that the body decodes to `"x"`, which is what RFC 9112 section 7.1.1 and RFC 9110 section 5.6.3 require.

```ada
      Channel.Input := To_Unbounded_String
        ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Transfer-Encoding: chunked" & CRLF & CRLF
         & Size_Line & CRLF & "x" & CRLF & "0" & CRLF & CRLF);
   ...
   Probe ("chunk extension without BWS (baseline)", "1;a=b");
   Probe ("BWS before the chunk-ext semicolon", "1 ;a=b");
   Probe ("HTAB before the chunk-ext semicolon", "1" & HT & ";a=b");
   Probe ("BWS after the chunk-ext semicolon", "1; a=b");
   Probe ("BWS before the chunk-ext equals sign", "1;a =b");
   Probe ("BWS after the chunk-ext equals sign", "1;a= b");
   Probe ("BWS around a valueless chunk extension", "1 ; a ");
```

```
  note RFC 9112 section 7.1.1 chunk-ext admits BWS before the semicolon,
  note after the semicolon, and around the equals sign
  ok   chunk extension without BWS (baseline)
  FAIL BWS before the chunk-ext semicolon
  note   raised Protocol_Error: invalid HTTP chunk size
  FAIL HTAB before the chunk-ext semicolon
  note   raised Protocol_Error: invalid HTTP chunk size
  FAIL BWS after the chunk-ext semicolon
  note   raised Protocol_Error: invalid chunk extension name
  FAIL BWS before the chunk-ext equals sign
  note   raised Protocol_Error: invalid chunk extension name
  FAIL BWS after the chunk-ext equals sign
  note   raised Protocol_Error: invalid chunk extension value
  FAIL BWS around a valueless chunk extension
  note   raised Protocol_Error: invalid HTTP chunk size
checks: 7  failures: 6
BUG REPRODUCED
```

The baseline is accepted, so only the whitespace is at issue. Both SP and HTAB are refused before the semicolon, and the valueless form `1 ; a ` fails as well.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

BWS in any of the four positions the `chunk-ext` grammar admits should be removed before the element is interpreted, and the chunk decoded as though it were absent. RFC 9110 section 5.6.3 makes that a MUST for a recipient.

## Suggested treatment

Trim SP and HTAB at both ends of each slice before it is interpreted: trim the right of the size slice in `Parse_Chunk_Size` (`src/flyology-http-server.adb:875-877`), and trim both ends of the extension name and value slices before `Validate_Token` in the scanner (`src/flyology-http-server.adb:911-922` and the value branch that follows). A quoted-string extension value keeps its interior whitespace, so the trim must apply to the slice boundaries only and must not reach inside the quotes handled at `tests/http_smoke.adb:481-494`.

`src/flyology-http-server.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in `tests/http_smoke.adb`, beside the existing chunk-extension cases at `:481-494` and the rejection at `:2174-2179`: the four BWS positions accepted, with the quoted-string case kept intact. The spike is the test. No existing test asserts the current rejections for BWS, so nothing has to change.

## Severity

A chunked request body that is well formed under the `chunk-ext` grammar is answered 400 and the connection closes, so the request is lost. The impact is low: chunk extensions are rare, and no stock client is known to emit them at all, let alone with bad whitespace. This is not verified against a peer. Deterministic given the input.
