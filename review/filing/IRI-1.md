Title: Overlong and out-of-range UTF-8 in a percent-decoded host decodes to a different host instead of failing
Labels: bug
Refs: none

## Summary

Web URL host parsing percent-decodes the host and hands the bytes to `Flyology_IRI.IDNA.To_ASCII`, which decodes them with the standard library's UTF-8 decoder and treats only `Encoding_Error` as a failure. That decoder classifies a lead byte by its shape alone, so an overlong encoding of an ASCII character decodes to that character and a four-byte form above U+10FFFF decodes to a code point outside Unicode. `http://%C1%A5xample.com/` is accepted with host `example.com`, and `Diagnose` reports no error, so nothing downstream can tell these inputs apart from a clean host.

## Problem

Commit `f078732`.

`Canonical_Host` percent-decodes first (`flyology_iri/src/flyology_iri-web.adb:597`) and converts the decoded bytes (`flyology_iri/src/flyology_iri-web.adb:627`):

```ada
      Decoded : constant String := Percent_Decode (Input);
```

```ada
         Domain : constant String := Flyology_IRI.IDNA.To_ASCII (Decoded, IDNA_OK);
```

`To_ASCII` guards the decode with one exception handler and nothing else (`flyology_iri/src/flyology_iri-idna.adb:237-243`):

```ada
      begin
         Decoded := Wide.To_Unbounded_Wide_Wide_String
           (UTF_32.Decode (UTF.UTF_8_String (Input)));
      exception
         when UTF.Encoding_Error =>
            return "";
      end;
```

`Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Decode` raises `Encoding_Error` for a malformed continuation byte, but it classifies the lead byte by shape alone and stores the assembled value with no minimum-value test and no cap at U+10FFFF. `Wide_Wide_Character` spans 2**31 positions, so a value above U+10FFFF is a legal position in the type and no check fires. The spike below shows the consequences: `C1 81` becomes `a`, `C0 AE C0 AE` becomes `..`, and `F4 90 80 80` becomes the code point 16#110000#, which `Punycode` then encodes as `xn--en32g`.

The crate's own mapping already agrees that a replacement character must fail (`flyology_iri/src/flyology_iri-idna.adb:189-190`):

```ada
         elsif Code in 16#0000# .. 16#001F# | 16#007F#
           or else Code = 16#FFFD#
```

That is the check the input never reaches, because nothing turns a malformed sequence into U+FFFD. The WHATWG URL Standard's host parser step 3 is "Let domain be the result of running UTF-8 decode without BOM on the percent-decoding of input", and the Encoding Standard's UTF-8 decoder emits U+FFFD for each malformed sequence, which UTS #46 then disallows. The pinned reference implementation does exactly that: `ada-url/ada` at revision `32dabc8d` range-checks every decoded value in its UTF-8 decoder, returning failure when a two-byte form yields a code point below 0x80, a three-byte form yields one below 0x800, or a four-byte form yields one at or below 0xFFFF or above 0x10FFFF, and its host parser then returns failure.

The conformance gate cannot see this. `flyology_iri/tests/wpt_conformance.py:45` reads `urltestdata.json` and `ada_extra_urltestdata.json`, and neither those two files nor `toascii.json` nor `ada_long_urltestdata.json` in the pinned corpus contains a single occurrence of `%C0`, `%C1`, `%E0%8`, `%F0%8`, `%F4%9` or `%F5` through `%FF`, or a single raw 0xC0, 0xC1 or 0xF5 through 0xFF byte. The crate's own suite has no case for a malformed UTF-8 host either.

## What happens now

Spike: for each input it calls `Can_Parse` and, when that succeeds, prints `Host` and `Image` of the parsed reference, then cross-checks that `Diagnose` agrees with `Can_Parse`. It asserts that each input is rejected. The last three checks are controls: the RFC 3987 syntax on the same bytes, an overlong NUL, and a surrogate.

```ada
   Must_Reject ("http://%C1%81/", "C1 81 (overlong two-byte 'a')");
   Must_Reject ("http://%E0%81%81/", "E0 81 81 (overlong three-byte 'a')");
   Must_Reject ("http://%F0%80%81%81/", "F0 80 81 81 (overlong four-byte 'a')");
   Must_Reject ("http://%C0%AE%C0%AE/", "C0 AE C0 AE (overlong '..')");
   Must_Reject ("http://%C1%A5xample.com/", "C1 A5 then 'xample.com'");
   ...
   Must_Reject ("http://%F4%90%80%80.com/", "F4 90 80 80 (U+110000)");
```

```
  note overlong encodings of ASCII in a percent-decoded special host
  FAIL C1 81 (overlong two-byte 'a') accepted, host [a] image [http://a/]
  ok   C1 81 (overlong two-byte 'a'): Can_Parse and Diagnose agree
  note C1 81 (overlong two-byte 'a'): Diagnose = NO_ERROR at 0
  FAIL E0 81 81 (overlong three-byte 'a') accepted, host [a] image [http://a/]
  ok   E0 81 81 (overlong three-byte 'a'): Can_Parse and Diagnose agree
  note E0 81 81 (overlong three-byte 'a'): Diagnose = NO_ERROR at 0
  FAIL F0 80 81 81 (overlong four-byte 'a') accepted, host [a] image [http://a/]
  ok   F0 80 81 81 (overlong four-byte 'a'): Can_Parse and Diagnose agree
  note F0 80 81 81 (overlong four-byte 'a'): Diagnose = NO_ERROR at 0
  FAIL C0 AE C0 AE (overlong '..') accepted, host [..] image [http://../]
  ok   C0 AE C0 AE (overlong '..'): Can_Parse and Diagnose agree
  note C0 AE C0 AE (overlong '..'): Diagnose = NO_ERROR at 0
  FAIL C1 A5 then 'xample.com' accepted, host [example.com] image [http://example.com/]
  ok   C1 A5 then 'xample.com': Can_Parse and Diagnose agree
  note C1 A5 then 'xample.com': Diagnose = NO_ERROR at 0
  note the same bytes unescaped, straight into the host
  FAIL raw C1 81 accepted, host [a] image [http://a/]
  ok   raw C1 81: Can_Parse and Diagnose agree
  note raw C1 81: Diagnose = NO_ERROR at 0
  FAIL raw C1 A5 then 'xample.com' accepted, host [example.com] image [http://example.com/]
  ok   raw C1 A5 then 'xample.com': Can_Parse and Diagnose agree
  note raw C1 A5 then 'xample.com': Diagnose = NO_ERROR at 0
  note a four-byte form above U+10FFFF
  FAIL F4 90 80 80 (U+110000) accepted, host [xn--en32g.com] image [http://xn--en32g.com/]
  ok   F4 90 80 80 (U+110000): Can_Parse and Diagnose agree
  note F4 90 80 80 (U+110000): Diagnose = NO_ERROR at 0
  note contrast: IRI_Syntax rejects the same bytes, so the two syntaxes disagree on one input
  ok   IRI_Syntax rejects raw C1 81
  note contrast: sequences the crate already rejects
  ok   overlong NUL rejected (after decoding, by the NUL rule)
  ok   surrogate rejected
checks: 19  failures: 8
BUG REPRODUCED
```

The percent-escaped and the raw forms behave identically, so this is not a percent-decoding defect. `Diagnose` returns `NO_ERROR` at offset 0 for every accepted case. The overlong NUL is rejected only incidentally, by the separate rule that forbids a NUL in a host after decoding, and the surrogate is rejected because the standard-library decoder does check that one shape. The same raw bytes are rejected under the RFC 3987 syntax, so the two syntaxes this crate offers disagree on one input.

Host: macOS 26.6.2, arm64, GNAT via Alire. Checked against the pinned WPT URL corpus (ada-url/ada 32dabc8d).

## What should happen

A host whose UTF-8 is malformed must fail to parse. The WHATWG URL Standard routes it through a UTF-8 decode that produces U+FFFD for each malformed sequence, and UTS #46 disallows U+FFFD, so an overlong form, a surrogate, and any value above U+10FFFF all end in a rejected host rather than in a different host.

## Suggested treatment

Validate the decoded sequence inside `To_ASCII` rather than relying on the standard library's decoder: after `UTF_32.Decode`, reject any code point above 16#10FFFF#, and check the byte sequence for overlong forms before decoding, since the assembled value alone cannot distinguish `C1 81` from `61`. Alternatively decode in the crate and substitute U+FFFD for each malformed sequence, which is what the WHATWG algorithm says and which `Map_Input` already rejects at `flyology_iri/src/flyology_iri-idna.adb:190`, so the second half of the fix already exists.

This needs a maintainer decision if the failure is to be distinguishable through `Diagnose`. `Error_Kind` is a public enumeration (`flyology_iri/src/flyology_iri.ads:38-47`) and today the nearest existing literal is `Invalid_Authority`. The options are to reuse an existing literal, a value derived from a type or contract, a caller parameter, a generic formal, build-time configuration, or a deliberately public new enumeration literal, which changes the public API. Do not settle it here; reusing `Invalid_Authority` needs no decision and closes the defect.

The regression test belongs in the existing crate suite at `flyology_iri/tests/src/flyology_iri_tests.adb`, beside the other host-rejection cases, not in a new file. The spike is the test, including its three controls. No existing test asserts the current behaviour, so none has to change. No unit `./scripts/prove.sh` proves is involved.

## Severity

Two different byte strings that a conforming parser distinguishes are folded to one host, in the over-permissive direction: the crate accepts a spelling no stock parser accepts, and reports it as an ordinary host. The harm is the validate-then-forward differential, where one component checks the unusual spelling and another resolves the folded one, and that needs a consumer. This repository does not have one: no source file and no project file outside `flyology_iri/` references the crate, so no request path here reaches it, and a caller that connects to the crate's own `Host` result fails closed against a server that rejects the same bytes. The crate is published independently, so its intended consumers are outside this repository and are not bounded by that. Deterministic.
