# Discovery: IRI

Scope: `flyology_iri/src/flyology_iri.ads` (325), `flyology_iri/src/flyology_iri.adb` (1718),
`flyology_iri/src/flyology_iri-web.ads` (17), `flyology_iri/src/flyology_iri-web.adb` (1444),
`flyology_iri/src/flyology_iri-idna.ads` (20), `flyology_iri/src/flyology_iri-idna.adb` (311),
`flyology_iri/flyology_iri.gpr` (39); tests `flyology_iri/tests/src/flyology_iri_tests.adb` (788),
`flyology_iri_differential.adb` (305), `flyology_iri_url_cli.adb` (136), `flyology_iri/tests/wpt_conformance.py` (83),
`flyology_iri/scripts/test.sh`; `.github/workflows/ci.yml:91-111`; `proof/proof-status.md:85-110,254-260`;
`flyology_iri/README.md`; `website/guide/iri/index.html` (prose); `review/prior-audit.md` entries 1, 5, 13,
20, 21, 22, 39-43 and appendices; pinned corpus `build/ada-url/tests/wpt/{urltestdata,IdnaTestV2,toascii}.json`
and `build/ada-url/src/{url.cpp,ada_idna.cpp}` as the oracle's source.
Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

Method note: the CLI `flyology_iri/tests/bin/flyology_iri_url_cli` (already built, `Web_URL_Syntax` only) was run
on individual inputs and, as a sweep, on every case of `IdnaTestV2.json` (2671) and `toascii.json` (87), which
the conformance driver never feeds (`wpt_conformance.py:45` reads only `urltestdata.json` and
`ada_extra_urltestdata.json`). Nothing was built. URI/IRI mode and `Resolve` have no CLI, so those items are by
reading with reproduction sketches. No file under `src/`, `showcases/`, `tests/` or `flyology_quic/` withs
`Flyology_IRI` (`rg -l Flyology_IRI` over those trees is empty), so every item below is library-level: the
crate's own callers are the unit tests and the CLI.

## Regression pass over the previous audit's fourteen IRI findings

The fix SHAs cited in `review/prior-audit.md` (`4f2c065`, `822acac`, `c174069`, `63c60fb`, `d208434`,
`d273bf9`, `fa53e67`, `82f0099`, `01b1e69`) are not ancestors of `f078732`; the fixes landed as re-authored
commits on 2026-08-07 with matching subjects, so the pass below checks code, not SHAs.

| Prior | Fix at f078732 | Still in place | Evidence |
|---|---|---|---|
| 1 merge drops root slash | `6b84ebb` | yes | `flyology_iri.adb:1506-1542` keeps the byte at `Prefix_Last` (the `/`) and emits `/` for an authority+empty-path base (`Root`); tests `flyology_iri_tests.adb:577-598` cover `http://good.com/`, `/x`, no-path, and a no-slash `mailto:` base |
| 5 `Diagnose` was a third validator | `39bc28e` | yes | `Diagnose` → `Web_Validate` → `Web_Fast_Path`/`Web_Slow_Path` (`:1060-1066`, `:1703-1716`), the same route `Try_Parse` takes (`:1126-1146`); `Analyze` is only run on the normalized serialization; `flyology_iri_differential.adb` holds all entry points to one answer over 10 000 seeded inputs |
| 13 IDNA had no validity/bidi checks | `c0c42cb` | yes, as scoped | `Disallowed` (`idna.adb:132-137`), `Bidi_Consistent` (`:158-172`), rejections in `Map_Input` (`:189-197`); CLI: RLM in a host and a Hebrew+Latin label both fail. The fix deliberately did not add the symbol/unassigned tables, ContextJ, the remaining bidi clauses or a Punycode decoder, and `idna.ads:5-14` and `README.md:22-32` now say so; `http://a≠b.com/` therefore still parses (`xn--ab-miv.com`) and `xn--` labels are copied through, both as documented. See IRI-3 for a gap that disclosure does not name |
| 20 DNS length checks on one path only | `6dee22f` | yes | `Valid_ASCII_Label` (`idna.adb:213-231`) applies only the forbidden code points; tests `:436-457` pin 64-octet and 300-octet names in both cases |
| 21 `Can_Parse` True where `Parse` says `Too_Long` | `39bc28e` | yes | `Can_Parse` takes the fast path only when `Input'Length * 3 < Max_Length` (`:1052-1056`); `Web_Fast_Path` reports `Too_Long` when the inserted slash would exceed the bound (`:982-985`); test `:663-669`; `Check_Bound` in the differential |
| 22 WPT never ran in CI | `1769d80` | yes | `ci.yml:97-109` checks out `ada-url/ada@32dabc8d` and sets `ADA_URL_ROOT` and `FLYOLOGY_IRI_REQUIRE_WPT`; `test.sh` fails when required and unset; baseline `02-test-sh.log:28` shows `WPT URL conformance: 919/919` |
| 39 RFC IPv4 leading zeros | `367033d` | yes | `Valid_IPv4` rejects `Leading_0 and then Digit_Count > 1` unconditionally (`:525-528`); tests `:479-490` |
| 40 `IRI_Syntax` accepted any UTF-8 | `49b7c56` | yes | `Is_IRI_Upper_BMP`/`Is_IRI_Supplementary` (`:342-355`) and the U+00A0 floor (`:387-389`) match RFC 3987 `ucschar`/`iprivate` range by range (checked each bound); tests `:528-555` |
| 41 web failures collapsed to offset 0 | `39bc28e` | yes | `Web.Parse` returns a `Parse_Error` mapped back through `Input_Offset` (`web.adb:1433-1439`); test `:673-695` |
| 42 failed `Try_Parse` looked like `""` | `097b80f` | yes | `Set_Failure` keeps the requested syntax (`:954-958`); `Is_Valid` (`:1234`); test `:701-722` |
| 43 `-gnatp` without proof | `b205240` | yes, narrowed | `flyology_iri.gpr:21-31` suppresses only `flyology_iri.adb`; `Check_Suppression_Scope` (`tests:741-743`) reads the project file back. The justification comment is still accurate about scope and about which bodies decode; two small drifts are under Observations |

No regression found. The differential harness and the gate are green in the baselines.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| IRI-1 | Overlong and out-of-range UTF-8 in a percent-decoded special host decodes to a different host instead of failing | P2 | high |
| IRI-2 | IPv4-in-IPv6 tail accepts leading zeros the WHATWG IPv6 parser rejects | P2 | high |
| IRI-3 | IDNA applies no NFC normalization and no leading-combining-mark check, and the disclosure does not name either | P2 | high |
| IRI-4 | `Resolve` recomposes a `//`-prefixed path without authority into an authority, and rewrites WHATWG opaque paths under a web base | P2 | high |

## Findings

### IRI-1: Overlong and out-of-range UTF-8 in a percent-decoded special host decodes to a different host instead of failing

- **Location:** `flyology_iri/src/flyology_iri-web.adb:597` and `:627` (percent-decode then `IDNA.To_ASCII`), consumed at `flyology_iri/src/flyology_iri-idna.adb:237-243` (`UTF_32.Decode` with only `Encoding_Error` handled)
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
   function Canonical_Host
     (Input : String; Is_Special : Boolean; Success : out Boolean) return String
   is
      Decoded : constant String := Percent_Decode (Input);
...
      declare
         Domain : constant String := Flyology_IRI.IDNA.To_ASCII (Decoded, IDNA_OK);
```

```ada
      begin
         Decoded := Wide.To_Unbounded_Wide_Wide_String
           (UTF_32.Decode (UTF.UTF_8_String (Input)));
      exception
         when UTF.Encoding_Error =>
            return "";
      end;
```

Observed against the built CLI (`Web_URL_Syntax`), percent-encoded and as raw bytes alike:

```
http://%C1%81/            -> host 'a'   href 'http://a/'        (overlong 2-byte 'a')
http://%E0%81%81/         -> host 'a'                            (overlong 3-byte)
http://%F0%80%81%81/      -> host 'a'                            (overlong 4-byte)
http://%C0%AE%C0%AE/      -> host '..'  href 'http://../'       (overlong '..')
http://%F4%90%80%80.com/  -> host 'xn--en32g.com'               (U+110000, above Unicode)
raw bytes C1 81 in host   -> host 'a'
http://%C0%80/            -> FAIL (only because the decoded NUL is rejected afterwards)
http://%ED%A0%80.com/     -> FAIL (surrogate rejected by Map_Input)
```

The Ada runtime's UTF-8 decoder accepts the overlong two-, three- and four-byte forms and the `F4 90..` form
above U+10FFFF: `Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Decode` (GNAT 16.1.0 `a-suezst.adb`, the unit the
crate calls) classifies the lead byte by shape only (`C <= 2#110_11111#`, `<= 2#1110_1111#`, `<= 2#11110_111#`),
checks each continuation byte for the `10xxxxxx` form in `Get_Continuation`, and stores
`Wide_Wide_Character'Val (R)` with no minimum-value or U+10FFFF test; only a bad continuation byte or a lead
byte outside those shapes raises `Encoding_Error`. The crate then lowercases and emits the decoded ASCII. The oracle does the opposite:
`build/ada-url/src/ada_idna.cpp:32-95` (`utf8_to_utf32`) returns 0 for `code_point < 0x80` after a two-byte
lead, `< 0x800` after a three-byte lead, and for surrogates, and `to_ascii` at `ada_idna.cpp:6230-6238` then
returns failure.

- **Failure scenario:** 1) A URL arrives from a peer (redirect `Location`, link, configuration) with an overlong
  encoding of an ASCII host, e.g. `http://%C1%A5xample.com/` or the raw bytes `C1 A5`. 2) `Parse (…, Web_URL_Syntax)`
  succeeds and `Host` returns `example.com`; every browser and ada-url reject the same bytes. 3) Any consumer that
  keys an allow or deny decision on this crate's `Host` and then hands the original bytes to another component
  (browser, curl, another resolver) has validated a string that component will not resolve the same way. Within
  this repository nothing consumes the crate, and a client that connects to the crate's own `Host` fails closed
  (`example.com` is where it goes), which is why this is P2 rather than P1; in a validate-then-forward pipeline it
  is the classic overlong-encoding differential.
- **Reproduction test sketch:** `flyology_iri_url_cli $(printf 'http://%%C1%%81/' | xxd -p) -` prints `OK` with
  hostname `a`; expected `FAIL`. Same for the raw bytes `687474703a2f2fc1812f`. Unit form:
  `Can_Parse ("http://" & Character'Val (16#C1#) & Character'Val (16#81#) & "/", Web_URL_Syntax)` is `True`;
  expected `False`, and `Diagnose` should report `Invalid_Authority`.
- **Existing coverage:** none for the outcome. `flyology_iri_tests.adb:782-785` (`bare continuation`,
  `truncated four byte leads`) only assert that no exception escapes. The pinned corpus has no overlong case
  (grep of `urltestdata.json`, `ada_extra_urltestdata.json`, `toascii.json` for `%C0`, `%C1`, `%E0%80`,
  `%E0%81`, `%F0%80`, `%F4%90`, `%F5..%FC` and raw `C0`/`C1` bytes returns nothing), so the 919/919 gate cannot
  see it. Contrast: `IRI_Syntax` rejects the same bytes correctly (`Is_Valid_UTF_8_At`, `flyology_iri.adb:380`,
  `:399`, `:418`), so the two syntaxes disagree on the same input.
- **Standard:** WHATWG URL Standard §3.5 "host parsing" step 3 ("Let domain be the result of running UTF-8
  decode without BOM on the percent-decoding of input"); Encoding Standard "UTF-8 decoder" (lead bytes 0xC0 and
  0xC1 are errors, 0xE0 requires a second byte ≥ 0xA0, 0xF0 requires ≥ 0x90, 0xF4 requires ≤ 0x8F; each error
  yields U+FFFD); UTS #46 §4.1 (U+FFFD is disallowed, so the host fails); RFC 3629 §3 ("implementations of the
  decoding algorithm MUST protect against decoding invalid sequences").

### IRI-2: IPv4-in-IPv6 tail accepts leading zeros the WHATWG IPv6 parser rejects

- **Location:** `flyology_iri/src/flyology_iri-web.adb:477-518` (dotted tail inside `Canonical_IPv6`)
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

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
```

Only `> 255` is checked (`:519-523`); a zero followed by another digit is accumulated. Observed:

```
http://[::01.2.3.4]/     -> host '[::102:304]'   expected FAIL
http://[::1.2.3.04]/     -> host '[::102:304]'   expected FAIL
http://[::0255.1.1.1]/   -> host '[::ff01:101]'  expected FAIL
http://[::00.0.0.0]/     -> host '[::]'          expected FAIL
http://[::0.0.0.0]/      -> host '[::]'          correct
```

The oracle rejects: `build/ada-url/src/url.cpp:163-172` sets `ipv4_piece` from the first digit and, on a second
digit, `if (ipv4_piece == 0) return false`. The same code is at `url_aggregator.cpp:1123-1132`.

- **Failure scenario:** 1) A peer supplies `http://[::0127.0.0.1]/`. 2) `Parse` succeeds and normalizes to
  `[::7f00:1]`; browsers and ada-url reject the input. 3) The crate's answer is more permissive than every stock
  parser; a normalized-host comparison built on it admits a spelling nothing else admits. No wire consequence and
  the canonical form is right when the input is accepted, so P2.
- **Reproduction test sketch:** `flyology_iri_url_cli $(printf 'http://[::01.2.3.4]/' | xxd -p) -` prints `OK`;
  expected `FAIL`. Unit form: `Can_Parse ("http://[::01.2.3.4]/", Web_URL_Syntax)` should be `False`.
- **Existing coverage:** none. Corpus cases `urltestdata.json` 714 (`https://[0:1.00.0.0.0]`) and 715 fail on
  part count (5 parts), not on the zero, so the gate is satisfied without this rule. `flyology_iri_tests.adb:479-481`
  pins leading-zero rejection for `URI_Syntax` only (`Valid_IPv4`, RFC 3986 `dec-octet`); the WHATWG path is a
  separate implementation (`Canonical_IPv6`) with no such test.
- **Standard:** WHATWG URL Standard §3.7 "IPv6 parser", step 6.5.5.4.2: "Otherwise, if ipv4Piece is 0,
  IPv4-in-IPv6-invalid-code-point validation error, return failure."

### IRI-3: IDNA applies no NFC normalization and no leading-combining-mark check, and the disclosure does not name either

- **Location:** `flyology_iri/src/flyology_iri-idna.adb:174-211` (`Map_Input`, no normalization step) and
  `:256-305` (`To_ASCII` label loop, no mark check); disclosure at `flyology_iri/src/flyology_iri-idna.ads:5-14`
  and `flyology_iri/README.md:22-32`
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
   --  Convert a UTF-8 domain to lower-case ASCII with the subset of UTS #46
   --  this crate carries: the ignorable and fullwidth mappings, case
   --  folding, rejection of the code points that carry no glyph, RFC 5893's
   --  prohibition on mixing letter directions inside one label, and RFC
   --  3492 Punycode encoding. It does not carry the full UTS #46 mapping
   --  table, the unassigned and mapped-symbol parts of the disallowed set,
   --  the ContextJ joiner rules, the remaining clauses of the bidi rule, or
   --  a Punycode decoder, ...
```

UTS #46 processing has a normalization step between mapping and label validation, and a validity criterion that
a label must not begin with a combining mark. Neither is implemented and neither is in the "does not carry"
list. Observed against the CLI:

```
http://bu<U+0308>cher.de/   -> 'xn--bucher-xyd.de'   expected 'xn--bcher-kva.de'  (decomposed ü; the precomposed
                                                       form at flyology_iri_tests.adb:372-375 gives the expected answer)
http://<U+0308>a.com/       -> 'xn--a-bcb.com'        expected FAIL (label begins with a combining mark)
http://a.<U+0308>b.com/     -> 'a.xn--b-bcb.com'      expected FAIL
http://<.<U+0338>.com/      -> FAIL                    expected 'xn--gdh.com' (NFC composes to U+226E, which is allowed;
                                                       without NFC the raw '<' trips the forbidden-code-point scan)
```

Sweep of the corpus the driver never runs (`IdnaTestV2.json`, 2671 cases, each as `http://<input>/x`):
1899 match, 189 both-accept-different-host, 518 accepted-where-failure-expected, 65 rejected-where-host-expected.
Of the 189 host mismatches, 87 become correct when the input is NFC-normalized first (Python
`unicodedata.normalize('NFC', …)` then the same CLI call). Of the 518 over-accepts, 278 have a label that begins
with a combining mark after NFC. `toascii.json` (87 cases): 60 match, 10 host mismatches (six are NFC), 7
over-accepts, 10 over-rejects. The remaining disagreements fall inside the classes the disclosure does name;
they are quantified under Observations.

- **Failure scenario:** 1) A URL carries a host in NFD, which macOS filesystems and several input methods
  produce for any accented name (`bu\u0308cher.de`). 2) `Parse` yields host `xn--bucher-xyd.de`; every browser
  yields `xn--bcher-kva.de` (`bücher.de`). 3) A client built on `Origin (URL)` connects to a label no registry can
  hold (its decoded form is not NFC, which UTS #46 rejects on the way back), so the request fails to resolve,
  while a comparison against the precomposed spelling says the two hosts differ although browsers treat them as
  one. The leading-mark case is the same class in the accept direction: a host browsers refuse is accepted with a
  synthetic Punycode label. Both are unusual input, hence P2; the impact class is the one prior finding 13
  described.
- **Reproduction test sketch:** `Host (Parse ("http://bu" & Character'Val (16#CC#) & Character'Val (16#88#) & "cher.de/", Web_URL_Syntax))`
  returns `xn--bucher-xyd.de`; expected `xn--bcher-kva.de`, equal to
  `Host (Parse ("http://bücher.de/", Web_URL_Syntax))`. And
  `Can_Parse ("http://" & Character'Val (16#CC#) & Character'Val (16#88#) & "a.com/", Web_URL_Syntax)` is `True`;
  expected `False`.
- **Existing coverage:** none. `flyology_iri_tests.adb:372-383` use precomposed `ü`, `例え`, `ß` only. The
  driver reads neither `IdnaTestV2.json` nor `toascii.json` (`wpt_conformance.py:45`). The finding-13 fix commit
  (`c0c42cb`) swept single BMP code points against ada-url, which never exercises composition.
- **Standard:** UTS #46 §4 "Processing", step 2 ("Normalize: Normalize the domain_name string to Unicode
  Normalization Form C"); §4.1 "Validity Criteria", the criterion "The label must be in Unicode Normalization
  Form NFC" and the criterion "The label must not begin with a combining mark, that is: General_Category=Mark"
  (numbered V1 and V5 in `IdnaTestV2.txt`). WHATWG URL Standard §3.5 "domain to ASCII" invokes UTS #46 ToASCII
  with CheckBidi, CheckJoiners and Transitional_Processing=false, which does not switch either off.

### IRI-4: `Resolve` recomposes a `//`-prefixed path without authority into an authority, and rewrites WHATWG opaque paths under a web base

- **Location:** `flyology_iri/src/flyology_iri.adb:1462-1469` and `:1475-1476, :1503-1504` (`Assemble_Into`
  emits `scheme ":"` then the dot-reduced path with no guard), consumed at `:1671-1673` (Reference form reparses
  the bytes) and `:1687-1688` (String form reparses in web mode); `Path` strips the WHATWG guard at `:1276-1282`
- **Severity:** P2
- **Confidence:** high (by reading; every step traced twice, no CLI for `Resolve`)
- **Evidence:**

```ada
      if Has_Scheme (Rel) then
         Put (Scheme (Rel));
         Put (":");
         if Has_Authority (Rel) then
            Put ("//");
            Put (Authority (Rel));
         end if;
         Append_Dot_Segments (Rel_Path, Output, Last, Overflow);
```

```ada
   function Resolve
     (Base       : Reference;
      Relative   : String;
      Max_Length : Positive := Default_Max_Length) return Reference
   is
     (Parse (Assemble (Base, Relative, Max_Length),
             Base.Syntax_Value,
             Max_Length));
```

Traced results (each `Append_Dot_Segments` step checked against `:1389-1431`):

| Base (syntax) | Relative | Assembled bytes | `Resolve` result components | Expected |
|---|---|---|---|---|
| `http://base/` (web) | `sc:/.//p` | `sc://p` | `Has_Authority` True, `Host` = `p`, `Path` = `` | WHATWG: no host, path `//p`, serialization `sc:/.//p` (which `Parse` alone gives, `tests:507-512`) |
| `http://base/` (web) | `mailto:a/../b` | `mailto:/b` | path `/b`, hierarchical | WHATWG: opaque path `a/../b` unchanged (`Parse` alone gives `mailto:a/../b`, confirmed by CLI) |
| `http://base/` (web) | `sc:..` | `sc:` | empty opaque path | WHATWG: opaque path `..` |
| `sc:/a/b` (URI) | `/.//p` or `..//p` | `sc://p` | `Has_Authority` True, `Host` = `p` | RFC 3986 §5.2.2: `T.authority = Base.authority` (undefined), `T.path = //p` |
| `http://a/b/c` (URI) | `sc:/.//p` | `sc://p` | `Host` = `p` | §5.2.2: `T.authority = R.authority` (undefined) |

- **Failure scenario:** 1) An application resolves a reference it received against a base it trusts; the
  reference is `sc:/.//evil` (or, with a base that has no authority such as `file:/a/b` or `sc:/a/b`, a plain
  `..//evil`). 2) `Resolve` returns a `Reference` with `Has_Authority = True` and `Host = evil`, although
  `Parse` of the same reference reports no authority, and RFC 3986 §5.2.2 leaves `T.authority` undefined. 3) A
  check keyed on `Host` or `Has_Authority` of the resolved reference sees a host that was never in the input.
  This needs a non-special scheme or an authority-less base, so it is P2. The web-base variant is reachable by
  design: `flyology_iri_tests.adb:600-619` pins that `Resolve` with a web base accepts an absolute web URL and
  returns its normalized image, and that promise is broken for opaque paths and `/.//` paths. The URI variant
  follows RFC 3986 §5.3 literally, and §3.3 says the recomposed string is not a valid authority-less URI; the
  crate resolves that conflict by reparsing, which is the unsafe direction.
- **Reproduction test sketch:**

```ada
declare
   Web_Base : constant Reference := Parse ("http://base/", Web_URL_Syntax);
   R1 : constant Reference := Resolve (Web_Base, "sc:/.//p");
   R2 : constant Reference := Resolve (Web_Base, "mailto:a/../b");
   URI_Base : constant Reference := Parse ("sc:/a/b", URI_Syntax);
   R3 : constant Reference := Resolve (URI_Base, "..//p");
begin
   --  actual: Image (R1) = "sc://p", Host (R1) = "p"; expected Image "sc:/.//p", Has_Authority False
   --  actual: Image (R2) = "mailto:/b";               expected "mailto:a/../b"
   --  actual: Image (R3) = "sc://p", Host (R3) = "p"; expected Has_Authority False, Path "//p"
end;
```

- **Existing coverage:** `flyology_iri_tests.adb:557-598` (RFC 3986 §5.4 suite and the site-root bases) all use
  a base with an authority, where the emitted `//authority` makes the recomposition unambiguous;
  `:606-619` pins web-base `Resolve` for one special-scheme absolute URL only. The corpus cases 750-761
  (`non-spec:/.//path`, `..//path` against `non-spec:/p`) cover `Parse (Input, Base)`, not `Resolve`.
- **Standard:** RFC 3986 §5.2.2 (component-wise result), §5.3 (recomposition, no guard), §3.3 ("If a URI does not
  contain an authority component, then the path cannot begin with two slash characters"); WHATWG URL Standard
  §4.5 "URL serializer" step 3 (append `/.` when host is null, the path is not opaque, and `path[0]` is empty)
  and §4.4 opaque paths (never subject to dot-segment handling).

## Areas reviewed with no findings

- **The two items the previous audit could not settle.** (1) `^` in `Path_Set` (`web.adb:165-166`) is correct:
  corpus `urltestdata.json` cases 850-851 expect `/…%5E_%60%7B|%7D~` for a path and 852-855 keep `^` raw in
  query and fragment; the CLI reproduces all three (`/a%5Eb?c^d#e^f`). The current WHATWG path percent-encode
  set is the query set plus `? ^ \` { }`. (2) `Encode_Opaque_Path` encoding only a single trailing space
  (`web.adb:226-241`) is exactly the opaque-path-state rule: cases 291-298 expect `non-special:opaque  ?hi` →
  `opaque %20` (one space kept, the last one encoded) and `opaque  x?hi` unchanged; the CLI matches, including
  `sc:  ` (trimmed) and `sc: ?` → `%20`. Both are in `urltestdata.json`, so the green gate already covers them.
- **All six percent-encode sets** (`web.adb:153-176`) match the current spec definitions character by character
  (C0 control set includes 0x7F and ≥ 0x80; space is in every set except the C0 set; special-query adds `'`;
  fragment has `` ` `` but not `#`), and corpus 844-855 exercises each.
- **Scheme detection and the special schemes.** `Special` lists exactly `ftp file http https ws wss`
  (`web.adb:56-57`); default ports `21/80/443` and none for `file`; `Parse_Absolute` slash skipping for special
  schemes, the `file:` two-slash rule, the non-special `//` rule and opaque-path detection all follow the scheme
  and path-or-authority states.
- **Authority, userinfo, host, port.** Last-`@` split with `%40` for earlier `@`, first-`:` password split,
  bracket hosts, `host:` with an empty port, `:` with an empty host (failure), port > 65535, default-port
  elision, `file` with a port (failure): all verified against the CLI and the spec's authority/host/port states.
- **IPv4.** All WHATWG forms (`0x7f.1`, `0177.0.0.1`, `256`, `4294967295`, `1.2.0x300`, `0x`, one trailing dot,
  two trailing dots, five parts, overflow, octal `09`, `a.1`, `a.0x`) give the expected verdicts; the
  ends-in-a-number checker and the number parser overflow guard (`web.adb:288-307`) are correct.
- **IPv6 apart from IRI-2.** Compression, too many pieces with `::` (`1::2:3:4:5:6:7:8` correctly fails, because
  `::` occupies a piece), the IPv4 tail with 5 or 6 leading pieces, zone identifiers (rejected), 5-hex-digit
  pieces, `[1:]`, `[:1]`, and canonical serialization of the longest zero run.
- **Opaque hosts** (`Canonical_Host` non-special branch): forbidden host code points, C0-set encoding, no
  percent-decoding, `[…]` still parsed as IPv6, all consistent with the opaque-host parser.
- **`file:` URLs.** Windows drive letters (`file:C|/x`, `file://C:/x`, `file:///C:/x`), UNC host
  (`file://server/share`), `localhost` elision, drive-letter protection in `Shorten_Path`: corpus-covered and
  spot-checked.
- **Preprocessing and offsets.** Leading/trailing C0-or-space trim and tab/LF/CR removal match the spec's
  "basic URL parser" step 1; `Input_Offset` maps a reported offset back to the caller's byte (test `:686-695`).
- **Fast paths versus the WHATWG path.** `Fast_Web_Analysis` and `Fast_Can_Parse_Web` (`flyology_iri.adb:107-330`)
  are strictly conservative: every byte class they accept is one the WHATWG path leaves unchanged (checked
  `Fast_Host_Class`, `Fast_Rest_Class`, the numeric-last-label and trailing-dot rules, dot-segment detection
  including `%2e` forms), and the seeded differential (`flyology_iri_differential.adb`) holds all entry points to
  one answer. Every index expression in both fast paths, `Is_Valid_UTF_8_At`, `Validate_Range`, `Valid_IPv4`,
  `Valid_IP_Literal`, `Analyze`, `Append_Dot_Segments`, `Assemble_Into` and `Assemble` was checked for an
  out-of-bounds read or write under `-gnatp`: every access is guarded by a short-circuit length test or an exact
  slice bound, `Put` is subtraction-guarded, `Fill` writes exactly `Span` bytes, and `Drop_Last_Segment` never
  goes below `Floor`. No unchecked access was found.
- **RFC mode grammar (`Analyze`).** Scheme first-character and body classes, authority terminators, `userinfo`
  (`unreserved / pct-encoded / sub-delims / ":"`), `reg-name`, `port = *DIGIT` including empty, IP-literal with
  `IPv6address` piece counting and `ls32`, `IPvFuture`, `path-noscheme` first-segment colon rule, `pchar`, query
  and fragment classes, and the rejection of controls, space and DEL: all match RFC 3986 §3 and Appendix A.
  Non-ASCII bytes are rejected in `URI_Syntax` and validated as UTF-8 plus `ucschar`/`iprivate` in `IRI_Syntax`
  (overlong, surrogate and > U+10FFFF sequences are rejected there, unlike IRI-1's web path).
- **Reference resolution apart from IRI-4.** The merge for bases `""` (no authority, no slash → relative path
  alone), `/`, `/x`, an authority with an empty path (`/` prefix), a base with a query (dropped unless the
  relative path is empty and the relative has no query), fragment handling, the strict same-scheme rule of
  §5.2.2, and the order of the five `remove_dot_segments` cases including the complete-segment tests for `/.`
  and `/..` were each traced; the assembled result never exceeds `Image_Length (Base) + Image_Length (Rel) + 16`.
- **Public contracts.** `Can_Parse` ≡ `Diagnose = No_Error` (single route plus differential), `Parse` raises
  only `Malformed_Reference` on rejected input (`Program_Error` in `Assemble` is guarded by the bound above),
  `Try_Parse` failure values satisfy `Is_Valid = False` with the requested `Syntax`, `Inspect` agrees with
  `Try_Parse`, `Origin` and `Target` raise for non-HTTP/WS schemes and for a missing host, `Path` hides the `/.`
  guard only when no authority is present.

## Observations not counted

- **IDNA gaps the disclosure does name, quantified.** From the same sweeps: (a) code points UTS #46 maps to
  plain ASCII that the crate Punycode-encodes instead, so browsers and the crate resolve different hosts and the
  browser's is the ASCII one: `ſ.com` → `xn--kha.com` (browsers `s.com`), `ﬁ.com` → `xn--jm6c.com` (`fi.com`),
  `№.com` → `xn--m2g.com` (`no.com`), `².com`, `ª.com`, `paypaℓ.com` → `xn--paypa-y34b.com` (`paypal.com`),
  `⑷.four` → `xn--csh.four` (`(4).four`); (b) GNAT's `To_Lower` stands in for UTS #46 case folding and misses
  newer pairs: U+1E9E `ẞ` (expected `ß`), U+04C0 (expected U+04CF), U+2183 (expected U+2184), U+0130 `İ`
  (expected `i̇`); (c) ContextJ: 20 of the 65 over-rejects contain ZWJ/ZWNJ; (d) U+180E and U+206B, which the
  corpus expects to be ignored, are rejected as format characters; (e) an `xn--` label that contains non-ASCII is
  not "copied through" as `idna.ads:12-13` says but Punycode-encoded again: `xn--a-ä.pt` → `xn--xn--a--gua.pt`,
  `xn--tešla` → `xn--xn--tela-bxb` (UTS #46 requires failure). Item (a) is the dangerous subclass of the
  documented mapping gap because the crate's host is valid-looking and different; it is listed here because
  prior finding 13 and the README already record the mapping table as absent.
- **`-gnatp` justification drift.** `flyology_iri.gpr:22-31` is accurate about scope and about which bodies
  keep checks, but it says the other bodies "decode … punycode" while the crate has only an encoder, and
  `proof/proof-status.md:254-260` lists the suppressed subprograms as `Char_At` … `Analyze`, omitting
  `Append_Dot_Segments`, `Assemble_Into`, `Assemble`, `Slice`, `Path` and the `Try_Parse` slash-insertion slice
  that later commits (`cfb25ef`, `616fdfd`, `bf79ef4`) added to the same body. The Stress corpus does drive
  `Resolve` (`tests:290-304`), so the dynamic guard covers them; only the record is stale.
- **`Resolve` scope.** `flyology_iri.ads:158-168` documents `Resolve` for "a URI or IRI reference" while the
  body accepts a `Web_URL_Syntax` base and the tests pin that; the guide (`website/guide/iri/index.html:165`)
  directs web resolution to `Parse (Input, Base)`. Either the spec should say web bases are accepted only for
  absolute inputs, or the body should refuse them; IRI-4 is what falls in the gap.
- **`Parse (Input, Base)` with a non-web base** evaluates `Web.Parse` on the input before checking the base's
  syntax (`flyology_iri.adb:1180-1187`), doing a full parse it then discards. Cost only.
- **Error category consistency in `Analyze`.** A rejected userinfo byte is reported as `Invalid_Character`
  (`:753-757`) while the same byte in a host is mapped to `Invalid_Authority` (`:802-805`); `Error_Kind`'s
  documentation (`flyology_iri.ads:34`) groups "authority, host, IP literal, or port" together. Diagnostic wording
  only.
- **`Port` is an unbounded digit string in RFC modes** (known: prior audit coverage gaps), and `Origin`/`Target`
  are web-only by contract.
- **No in-repository consumer.** Nothing under `src/`, `showcases/`, `tests/` or `flyology_quic/` withs
  `Flyology_IRI`; the HTTP client and server parse targets with their own code, so none of the above reaches an
  HTTP endpoint in this repository.
