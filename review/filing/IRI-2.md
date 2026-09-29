Title: Web URL IPv6 parsing accepts leading zeros in the IPv4-in-IPv6 tail that the WHATWG parser rejects
Labels: bug
Refs: none

## Summary

The dotted tail of an IPv6 literal accumulates digits without ever testing for a leading zero or capping a part at three digits. `http://[::01.2.3.4]/`, `http://[::1.2.3.04]/` and `http://[::0255.1.1.1]/` are all accepted and normalized to the same hosts as their canonical spellings, where the WHATWG IPv6 parser fails them. The crate's own RFC 3986 path rejects the same literal, so the two syntaxes it offers disagree on one input.

## Problem

Commit `f078732`.

The tail parser validates only the part count, an empty part, and a value above 255 (`flyology_iri/src/flyology_iri-web.adb:487-506`):

```ada
               for Ch of IPv4 loop
                  if Is_Digit (Ch) then
                     Digit_Count := Digit_Count + 1;
                     if Part = 1 then A := A * 10 + Character'Pos (Ch) - 48;
                     elsif Part = 2 then B := B * 10 + Character'Pos (Ch) - 48;
                     elsif Part = 3 then C := C * 10 + Character'Pos (Ch) - 48;
                     else D := D * 10 + Character'Pos (Ch) - 48;
                     end if;
                  elsif Ch = '.' and then Digit_Count > 0 and then Part < 4 then
                     Part := Part + 1;
                     Digit_Count := 0;
                  else
                     return "";
                  end if;
               end loop;
               if Part /= 4 or else Digit_Count = 0
                 or else A > 255 or else B > 255 or else C > 255 or else D > 255
               then
                  return "";
               end if;
```

There is no test for a second digit after a zero and no three-digit cap, so `01`, `04`, `00` and `0255` all pass. The WHATWG URL Standard's IPv6 parser states the rule directly: "If ipv4Piece is 0, IPv4-in-IPv6-invalid-code-point validation error, return failure." The pinned reference implementation `ada-url/ada` at revision `32dabc8d` implements exactly that: it takes `ipv4_piece` from the first digit and fails when a second digit follows a zero, then caps the part at three digits with a `> 255` test.

The conformance gate cannot see this, and neither can the crate's own suite. There are ten IPv4-in-IPv6 cases in the pinned `urltestdata.json`, and exactly one carries a leading zero: case 714, `https://[0:1.00.0.0.0]`. It also carries five dotted parts, and the crate rejects it on the part count, because the `.` before the fifth part is reached with `Part = 4` and falls through to `return ""`. The gate is therefore satisfied without the zero rule ever being exercised. `flyology_iri/tests/src/flyology_iri_tests.adb:476-481` does pin leading-zero rejection, but only for the RFC 3986 path:

```ada
   --  RFC 3986 dec-octet forbids a leading zero, so an IPv4-in-IPv6 literal
   --  has exactly one accepted spelling and cannot be zero-padded past a
   --  host comparison.
   Reject ("http://[::1.2.3.04]/", URI_Syntax, Invalid_Authority);
   Reject ("http://[::01.2.3.4]/", URI_Syntax, Invalid_Authority);
   Reject ("http://[::1.2.3.004]/", URI_Syntax, Invalid_Authority);
```

`Canonical_IPv6` is a separate implementation reached only under `Web_URL_Syntax`, and it has no such test.

## What happens now

Spike: it asserts that each zero-padded literal is rejected under `Web_URL_Syntax`, prints the normalized host when it is not, then asserts that three canonical spellings are still accepted with the right hosts, and finally that the RFC 3986 path rejects one of the same literals. `Host` is documented to return the address without its IPv6 brackets (`flyology_iri/src/flyology_iri.ads:249`), which is why the expectations are bracketless.

```ada
   Must_Reject ("http://[::01.2.3.4]/");
   Must_Reject ("http://[::1.2.3.04]/");
   Must_Reject ("http://[::0255.1.1.1]/");
   Must_Reject ("http://[::00.0.0.0]/");
   Must_Reject ("http://[::0127.0.0.1]/");
   Must_Reject ("http://[::ffff:01.2.3.4]/");
```

```
  note a leading zero anywhere in the dotted tail must fail
  FAIL http://[::01.2.3.4]/ accepted, normalized to host [::102:304]
  FAIL http://[::1.2.3.04]/ accepted, normalized to host [::102:304]
  FAIL http://[::0255.1.1.1]/ accepted, normalized to host [::ff01:101]
  FAIL http://[::00.0.0.0]/ accepted, normalized to host [::]
  FAIL http://[::0127.0.0.1]/ accepted, normalized to host [::7f00:1]
  FAIL http://[::ffff:01.2.3.4]/ accepted, normalized to host [::ffff:102:304]
  note a single zero piece is legal and must still be accepted
  ok   http://[::0.0.0.0]/ host
  ok   http://[::1.2.3.4]/ host
  ok   http://[::127.0.0.1]/ host
  note the RFC 3986 path already rejects the same shape, so the two syntaxes disagree
  ok   URI_Syntax rejects [::01.2.3.4]
checks: 10  failures: 6
BUG REPRODUCED
```

`http://[::01.2.3.4]/` and `http://[::1.2.3.04]/` both normalize to `::102:304`, the same host as the canonical `http://[::1.2.3.4]/`, so the zero-padded spellings are silently folded onto the canonical one. The three `ok` host checks show a single zero part is still accepted, so the assertion does not overreach.

Host: macOS 26.6.2, arm64, GNAT via Alire. Checked against the pinned WPT URL corpus (ada-url/ada 32dabc8d).

## What should happen

A dotted part in an IPv6 literal must fail when it begins with a zero and has more than one digit, and must fail when it has more than three digits, as the WHATWG IPv6 parser specifies. A single `0` part stays legal.

## Suggested treatment

Track the value of the first digit of each part in the loop at `flyology_iri/src/flyology_iri-web.adb:487-501` and fail when `Digit_Count` grows past one while that first digit was `0`, and fail when `Digit_Count` reaches four. Both bounds come from the WHATWG IPv6 parser rather than from a local choice, so under "Decision authority" the fix should record that authority next to the check the way the comment at `flyology_iri/tests/src/flyology_iri_tests.adb:476-478` records the RFC 3986 rule for the other path. No maintainer decision is needed: the standard fixes both values and the existing `> 255` test keeps its meaning.

The regression test belongs beside the RFC 3986 pins in the existing crate suite at `flyology_iri/tests/src/flyology_iri_tests.adb:476-490`, with `Web_URL_Syntax` cases added next to the `URI_Syntax` ones, not in a new file. The spike is the test, including its three acceptance controls. No existing test asserts the current behaviour, so none has to change. No unit `./scripts/prove.sh` proves is involved.

## Severity

The parser is over-permissive, not wrong about what it accepts: whenever a literal is accepted the canonical form it produces is correct, and there is no wire consequence, because the crate does not connect to anything. The cost is that a normalized-host comparison admits spellings no stock parser admits, so two components that disagree about which spellings are legal can be made to disagree about which host a URL names. It needs a consumer, and no source file or project file outside `flyology_iri/` references the crate. Deterministic; `Web_URL_Syntax` only.
