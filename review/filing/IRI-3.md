Title: IDNA host conversion applies no NFC normalization and no leading-combining-mark check
Labels: bug, documentation
Refs: none

## Summary

`Flyology_IRI.IDNA` maps and case-folds a domain but never normalizes it, and its label loop never tests whether a label begins with a combining mark. The decomposed and precomposed spellings of one host therefore produce two different ASCII hosts, so `bücher.de` typed on a system that produces NFD yields `xn--bucher-xyd.de` where every full implementation yields `xn--bcher-kva.de`, and a host whose label starts with U+0308 is accepted. Neither gap is among the ones the unit's own documented subset names, so the disclosure does not cover it.

## Problem

Commit `f078732`.

`Map_Input` walks the input once, dropping ignorables, rejecting code points with no glyph, mapping the three alternative label separators to `.`, folding fullwidth and mathematical forms, and lower-casing (`flyology_iri/src/flyology_iri-idna.adb:174-211`). There is no normalization step anywhere in it, and the separator mapping shows why normalization has to run over the whole string rather than per character:

```ada
         elsif Code in 16#3002# | 16#FF0E# | 16#FF61# then
            Wide.Append (Result, '.');
```

The label loop that follows validates ASCII labels, checks bidi consistency and Punycode-encodes the rest (`flyology_iri/src/flyology_iri-idna.adb:256-305`). It has no test on the first code point of a label.

UTS #46 puts both requirements in its processing algorithm. Section 4 "Processing" step 2 is "Normalize the domain_name string to Unicode Normalization Form C." Section 4.1 "Validity Criteria" states as criterion 1 "The label must be in Unicode Normalization Form NFC" and as criterion 6 "The label must not begin with a combining mark, that is: General_Category=Mark." The pinned reference implementation `ada-url/ada` at revision `32dabc8d` carries both: it normalizes the mapped string when it is not already NFC, and its label validator carries the comment "The label must not begin with a combining mark."

The unit discloses a deliberately scoped subset, and these two items are not in it (`flyology_iri/src/flyology_iri-idna.ads:5-14`):

```ada
   --  Convert a UTF-8 domain to lower-case ASCII with the subset of UTS #46
   --  this crate carries: the ignorable and fullwidth mappings, case
   --  folding, rejection of the code points that carry no glyph, RFC 5893's
   --  prohibition on mixing letter directions inside one label, and RFC
   --  3492 Punycode encoding. It does not carry the full UTS #46 mapping
   --  table, the unassigned and mapped-symbol parts of the disallowed set,
   --  the ContextJ joiner rules, the remaining clauses of the bidi rule, or
   --  a Punycode decoder, so an already-encoded "xn--" label is copied
   --  through rather than decoded and revalidated. Per WHATWG, ToASCII runs
   --  with VerifyDnsLength false, so no DNS length limit is applied.
```

Both halves of that sentence are about which code points are mapped or disallowed. `flyology_iri/README.md:22-32` repeats the same list and closes with "Hosts outside that subset can still differ from a full UTS #46 implementation." That is a blanket hedge, not a naming: neither text mentions normalization, neither mentions NFC, and neither mentions the combining-mark criterion. So the mapping-table, case-folding, ContextJ and bidi gaps are disclosed and are not reported here, and these two are not disclosed.

The conformance gate cannot see this, by construction. `flyology_iri/tests/wpt_conformance.py:45` reads `urltestdata.json` and `ada_extra_urltestdata.json` only. `IdnaTestV2.json` and `toascii.json` sit beside them in the pinned corpus and are never fed to the crate. Driving every case of those two files through the crate's URL command-line program (`flyology_iri/tests/src/flyology_iri_url_cli.adb`), as `http://<input>/x`, and comparing the reported `hostname` with each case's expected output, with a null expectation read as an expected failure:

```
IdnaTestV2.json   2671 cases   1899 match   189 different host   518 accepted where failure expected   65 rejected where a host was expected
toascii.json        87 cases     60 match    10 different host      7 accepted where failure expected   10 rejected where a host was expected
```

Of the 189 host mismatches in `IdnaTestV2.json`, 87 become correct when the input is NFC-normalized before the same call, and 5 of the 10 host mismatches in `toascii.json` do. Of the 518 over-accepts, 278 have a label that begins with a `General_Category=Mark` code point after NFC, splitting labels on all four separators the crate itself maps. One caveat about how the sweep is built: the `http://<input>/x` wrapper adds noise for the 138 cases whose input carries a URL-structural character and for the one empty input, and that noise sits inside the mismatch counts, so the real gap is marginally smaller than 189 and 518.

The crate's own suite pins only precomposed spellings. `flyology_iri/tests/src/flyology_iri_tests.adb:372-375` asserts that `https://bücher.example/` serializes to `https://xn--bcher-kva.example/`, and the source of that test is itself NFC, so no test distinguishes the two spellings of one host.

## What happens now

Spike: it builds each host from explicit UTF-8 bytes, so the source file's own encoding cannot influence the result, then compares the ASCII host the crate produces for the decomposed and the precomposed spelling of the same name, asserts that a label beginning with a combining mark is rejected, and asserts that `=` followed by U+0338 normalizes to U+2260 before validation. The last check is a control: the precomposed spelling the crate's own tests pin must keep working.

```ada
   Same_Host ("http://bu" & Combining_Diaeresis & "cher.de/",
              "http://b" & U_Diaeresis & "cher.de/",
              "bucher.de decomposed versus precomposed");
   Must_Reject ("http://" & Combining_Diaeresis & "a.com/",
                "leading U+0308 in the first label");
   Must_Reject ("http://a." & Combining_Diaeresis & "b.com/",
                "leading U+0308 in an interior label");
```

```
  note UTS #46 step 2: the NFD and NFC spellings of one host must give one ASCII host
  FAIL bucher.de decomposed versus precomposed
         expected: [xn--bcher-kva.de]
         actual:   [xn--bucher-xyd.de]
  FAIL fo-grave.bar.com decomposed versus precomposed
         expected: [xn--fo-3ja.bar.com]
         actual:   [xn--foo-idc.bar.com]
  note   decomposed gives [xn--bucher-xyd.de], precomposed gives [xn--bcher-kva.de]
  note UTS #46 criterion 6: a label must not begin with a combining mark
  FAIL leading U+0308 in the first label accepted with host [xn--a-bcb.com]
  FAIL leading U+0308 in an interior label accepted with host [a.xn--b-bcb.com]
  FAIL leading U+0301 in the first label accepted with host [xn--x-wbb.com]
  note NFC must run before the forbidden-code-point scan: '=' U+0338 composes to U+2260
  FAIL '=' + U+0338 must normalize to U+2260 before validation
         expected: [xn--1ch.com]
         actual:   [xn--=-2eb.com]
  note controls: the precomposed spellings the crate's own tests pin still work
  ok   precomposed bucher.de
checks: 7  failures: 6
BUG REPRODUCED
```

The two spellings of one name give two ASCII hosts, both of which the crate reports as valid. The single `ok` shows the precomposed path is unaffected, so a fix must not trade one for the other. The `=` case shows the ordering constraint: normalization has to run after the mapping step, because the ignorable code points the mapping removes can otherwise block a composition.

Host: macOS 26.6.2, arm64, GNAT via Alire. Checked against the pinned WPT URL corpus (ada-url/ada 32dabc8d).

## What should happen

`To_ASCII` should normalize the mapped string to NFC before it validates and splits labels, as UTS #46 section 4 step 2 requires, and should reject a label whose first code point has `General_Category=Mark`, as section 4.1 criterion 6 requires. Until it does, the documented subset should name both gaps, so that a caller reading the specification learns that two spellings of one host can give two answers.

## Suggested treatment

Two changes, which can land separately. The combining-mark check is self-contained: test the first code point of each non-ASCII label in the loop at `flyology_iri/src/flyology_iri-idna.adb:256-305` before Punycode encoding, using the same `Flyology_IRI.Unicode` category tables the bidi rule already consults. NFC is the larger change, because the crate carries no normalization data today and the composition has to run after `Map_Input` rather than on the raw input, as the `=` case above shows.

This needs a maintainer decision, because NFC is not a defect fix at constant cost: it means either carrying composition data in the crate or taking a dependency, and the crate is published independently. The options are to implement normalization in the crate behind the existing private unit, to derive the behaviour from a type or contract by restricting the accepted input to already-normalized hosts and rejecting the rest, to make it a build-time configuration, to expose it as a caller parameter or generic formal, or to decline it and instead name the gap in the specification and the README, which makes this a documentation change alone. Do not settle it here. If the decision is to decline, the documentation half is still required, because the present disclosure names neither gap.

The regression test belongs in the existing crate suite at `flyology_iri/tests/src/flyology_iri_tests.adb`, beside the IDNA host cases it already pins, not in a new file, and `flyology_iri/tests/wpt_conformance.py` should be extended to read `IdnaTestV2.json` from the same pinned corpus so that the gap is measured rather than assumed. The spike is the test, including its precomposed control. No existing test asserts the current behaviour, so none has to change. No unit `./scripts/prove.sh` proves is involved.

## Severity

A host that arrives decomposed, which is what several input methods and one common desktop filesystem produce, is converted to an ASCII label that decodes back to a non-NFC label. A full implementation rejects that on the way back, so the name resolves nowhere, and a comparison against the precomposed spelling reports two different hosts. The combining-mark half is over-permissive in the direction that admits confusable labels no stock parser admits. Both need a consumer to become an exposure, and no source file or project file outside `flyology_iri/` references the crate. The behaviour is in a unit that discloses a scoped subset, which bounds the surprise, but the disclosure names neither of these two gaps. Deterministic; `Web_URL_Syntax` only.
