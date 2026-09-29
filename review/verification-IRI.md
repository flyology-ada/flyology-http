# Verification: IRI

Commit: f078732
Findings examined: 4. Confirmed: 4. Refuted: 0. Partial: 0. Other: 0.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| IRI-1 | P2 | CONFIRMED | P2 | `repro_iri_1` |
| IRI-2 | P2 | CONFIRMED | P2 | `repro_iri_2` |
| IRI-3 | P2 | CONFIRMED | P2 | `repro_iri_3` |
| IRI-4 | P2 | CONFIRMED | **P1** (raised) | `repro_iri_4` |

All four are reproduced by an Ada spike under `tests/repros/src/`, run with
`./tests/repros/run.sh repro_iri_<n>`.

## Harness note

The task brief said the repro harness could build against this crate "because
`flyology_iri` is withed by the harness project". That was not so at the time:
`repros.gpr` withed only `../../flyology_http.gpr`, whose closure
(`alire/alire.lock`) is `flyology`, `flyology_allocators`, `flyology_cachelines`,
`flyology_quic`, `gnat`, and no `.gpr` outside `flyology_iri/` withed
`flyology_iri.gpr`. I established that by building a spike rather than by reading
(`repro_iri_4.adb:10:06: error: file "flyology_iri.ads" not found`), reported it, and
worked around it with shell reproductions driving the crate's prebuilt
`flyology_iri_url_cli`, without touching the shared project file. `repros.gpr` has
since been given an explicit `with "../../flyology_iri/flyology_iri.gpr";`, so every
finding below is now an ordinary Ada spike; the shell reproductions have been
removed as superseded. The Ada form is strictly better evidence: it reaches
`Can_Parse`, `Diagnose` and `Resolve`, none of which the CLI exposes.

## Regression spot check over the previous audit's fourteen IRI findings

No regression found. I re-checked three, including the two the coordinator named.

**Prior finding 1 (critical: RFC 3986 merge drops the base's root slash) — still
fixed.** `flyology_iri.adb:1503-1540`: the merge scans `Base_Path` in reverse for a
`'/'` and sets `Prefix_Last := Index` — the index *of* the slash, not before it — so
`Prefix_Length := Prefix_Last - Base_Path'First + 1` retains it, and the separate
`Root` case (`Has_Authority (Base) and then Base_Path'Length = 0`) emits a bare `/`.
The regression tests are `Check_Resolution_Base` (`flyology_iri_tests.adb:577-598`),
which asserts `Host (Actual) = Expected_Host` as well as the image, for
`http://good.com/` + `index.html`, `http://good.com/x` + `evil.com/`, `../up`,
`./same`, `http://good.com` + `index.html`, the IRI-mode `https://例え.テスト/x` case
and a no-slash `mailto:` base. `review/baselines/02-test-sh.log:27` shows
`flyology_iri tests passed`, so those assertions ran green at this commit. My own
`repro_iri_4` adds execution evidence from the other direction: resolving
`/.//evil.com` and `..//evil.com` against `http://good.com/a/b` keeps
`Host = good.com`, so the merge is retaining the base authority and the slash.

**Prior finding 20 (host validity depends on letter case) — still fixed, verified by
execution.** Driving the CLI over the three paths that used to disagree:

```
label n=  63  lowercase=accepted(len=63)   uppercase=accepted(len=63)   pct-escaped=accepted(len=63)
label n=  64  lowercase=accepted(len=64)   uppercase=accepted(len=64)   pct-escaped=accepted(len=64)
label n=  70  lowercase=accepted(len=70)   uppercase=accepted(len=70)   pct-escaped=accepted(len=70)
label n= 100  lowercase=accepted(len=100)  uppercase=accepted(len=100)  pct-escaped=accepted(len=100)
name len=329  lowercase=accepted           uppercase=accepted
```

The all-lowercase fast path, the uppercase slow path and the percent-escaped slow
path now agree, and all three accept over-length labels and names, which is what
WHATWG's `VerifyDnsLength` = `beStrict` = false requires. `Valid_ASCII_Label`
(`flyology_iri-idna.adb:213-231`) applies only the forbidden code points.

**Prior finding 22 (WPT never ran in CI) — still fixed.** `.github/workflows/ci.yml:97-111`
checks out `ada-url/ada` at the pinned `32dabc8d39a919633f31f692c358012b2105fd61`,
sets `ADA_URL_ROOT` and `FLYOLOGY_IRI_REQUIRE_WPT=1`, and runs
`./flyology_iri/scripts/wpt-gate-test.sh` after the suite.
`review/baselines/02-test-sh.log:28` shows `WPT URL conformance: 919/919 (100.0%),
mismatches=0`. The local `build/ada-url` checkout is at that revision.

## IRI-1: Overlong and out-of-range UTF-8 in a percent-decoded special host decodes to a different host instead of failing

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged — see the reachability note)
- **Repro:** `tests/repros/src/repro_iri_1.adb`, run with
  `./tests/repros/run.sh repro_iri_1`
- **Output:**

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
EXIT=1
```

- **Description:** `Canonical_Host` (`flyology_iri-web.adb:589-597`) percent-decodes
  the host and hands the bytes to `Flyology_IRI.IDNA.To_ASCII`, which decodes them
  with `Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Decode` and handles only
  `Encoding_Error` (`flyology_iri-idna.adb:235-243`). I read the runtime unit the
  crate actually links (`a-suezst.adb` in the version-matched RTS, lines 125-166): it
  classifies the lead byte by shape alone (`C <= 2#110_11111#`, `<= 2#1110_1111#`,
  `<= 2#11110_111#`), checks each continuation byte only for the `10xxxxxx` form, and
  stores `Wide_Wide_Character'Val (R)` with no minimum-value test and no U+10FFFF cap.
  So `C1 81` becomes `a`, `C0 AE C0 AE` becomes `..`, and `F4 90 80 80` becomes code
  point 16#110000#, which is a legal `Wide_Wide_Character` position in Ada (that type
  spans 2**31 positions) but is above Unicode; `Punycode` then encodes it, and I
  confirmed with an independent RFC 3492 encoder that the Punycode of the single code
  point U+110000 is exactly `en32g`, matching the observed `xn--en32g.com`.
  The spike also shows `Diagnose` returns `NO_ERROR` for every one, so nothing
  downstream of `Parse` can tell these apart from a clean host.
  WHATWG URL Standard host parsing step 3 is "Let domain be the result of running
  UTF-8 decode without BOM on the percent-decoding of input" (quoted from the live
  specification), and the Encoding Standard's UTF-8 decoder turns each malformed
  sequence into U+FFFD, which UTS #46 disallows — the crate's own `Map_Input` agrees
  that U+FFFD must fail (`flyology_iri-idna.adb:183`). The oracle rejects:
  `ada::idna::utf8_to_utf32` (`build/ada-url/src/ada_idna.cpp:57-123`) returns 0 for
  `code_point < 0x80` after a two-byte lead, `< 0x800` after a three-byte lead,
  `<= 0xffff || 0x10ffff <` after a four-byte lead, and for surrogates; `to_ascii`
  (`:6237-6238`) then returns false.
- **Why the green gate cannot see it.** I searched the pinned corpus myself:
  `urltestdata.json`, `ada_extra_urltestdata.json`, `toascii.json` and
  `ada_long_urltestdata.json` contain zero occurrences of `%C0`, `%C1`, `%E0%8`,
  `%F0%8`, `%F4%9`, `%F5`..`%FF`, and zero raw `0xC0`, `0xC1` or `0xF5`..`0xFF` bytes.
- **Why P2 holds.** I re-ran the consumer search the discovery reviewer relied on,
  because it is what holds the severity down. Nothing outside `flyology_iri/` withs
  `Flyology_IRI` — `rg -i flyology_iri` over every `.ad[sb]` in the tree returns only
  files inside the crate, and no `.gpr` outside the crate withs `flyology_iri.gpr`.
  The HTTP client and server parse targets with their own code. So no request path in
  this repository reaches this, and a client that connects to the crate's own `Host`
  fails closed. The harm is the classic validate-then-forward overlong differential,
  which needs a consumer this repository does not have — though note `flyology_iri` is
  one of the three independently indexed crates here, so its intended consumers are
  external.

## IRI-2: IPv4-in-IPv6 tail accepts leading zeros the WHATWG IPv6 parser rejects

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_iri_2.adb`, run with
  `./tests/repros/run.sh repro_iri_2`
- **Output:**

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
EXIT=1
```

- **Description:** The dotted tail inside `Canonical_IPv6`
  (`flyology_iri-web.adb:477-523`) accumulates every digit into `A`/`B`/`C`/`D` and
  validates only `Part /= 4`, `Digit_Count = 0` and `> 255`. There is no "second digit
  after a zero" test and no three-digit cap, so `01`, `04`, `00` and `0255` are all
  accepted. The WHATWG URL Standard's IPv6 parser says verbatim: "If ipv4Piece is 0,
  IPv4-in-IPv6-invalid-code-point validation error, return failure." (quoted from the
  live specification, not from memory). The oracle implements exactly that:
  `build/ada-url/src/url.cpp:163-166` sets `ipv4_piece` from the first digit and, when
  a second digit follows, does `if (ipv4_piece == 0) return is_valid = false;`. The
  spike's last check shows the crate's own RFC 3986 path rejects the same host, so the
  two syntaxes disagree on one input.
- **Why the green gate cannot see it.** I enumerated every IPv4-in-IPv6 case in
  `urltestdata.json` myself — there are eight, and only case 714
  `https://[0:1.00.0.0.0]` carries a leading zero. It also carries five dotted parts,
  and the crate rejects it on the part count (the `Part < 4` guard falls through to
  `return ""`), so the gate is satisfied without the zero rule ever being exercised.
  `flyology_iri_tests.adb:479-490` pins leading-zero rejection for RFC `Valid_IPv4`
  only; `Canonical_IPv6` is a separate implementation with no such test.
- **Why P2.** The canonical form is correct whenever the input is accepted, there is
  no wire consequence, and the direction is over-permissive, so the only consequence
  is a normalized-host comparison that admits a spelling no stock parser admits.

## IRI-3: IDNA applies no NFC normalization and no leading-combining-mark check, and the disclosure does not name either

- **Verdict:** CONFIRMED
- **Severity:** P2 (discovery said P2; unchanged)
- **Repro:** `tests/repros/src/repro_iri_3.adb`, run with
  `./tests/repros/run.sh repro_iri_3`
- **Output:**

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
EXIT=1
```

- **My own sweep — these numbers replace the discovery entry's.** I re-ran the sweep
  rather than taking it on trust, feeding every case as `http://<input>/x` to the CLI
  and comparing `hostname` with the case's `output` (`null` = expected failure, which
  is how `build/ada-url/tests/wpt_url_tests.cpp:73-107` reads the file).

  `IdnaTestV2.json`, 2671 object cases: **1899 match, 189 both-accept-different-host,
  518 accepted-where-failure-expected, 65 rejected-where-host-expected.** Of the 189
  host mismatches, **87** become correct when the input is NFC-normalized before the
  same CLI call. Of the 518 over-accepts, **278** have a label that begins with a
  `General_Category=Mark` code point after NFC. Every one of those figures matched the
  discovery entry exactly.

  `toascii.json`, 87 cases: **60 match, 10 host mismatches, 7 over-accepts, 10
  over-rejects**; **5** of the 10 host mismatches are fixed by NFC. The discovery
  entry said six; mine is five, and mine is the number that stands. The five that NFC
  does not fix are U+04C0, U+2183, U+1E9E (twice), and `=` U+00AD U+0338 — the last
  because the ignorable U+00AD blocks composition until UTS #46's mapping step removes
  it, which is itself evidence that normalization has to run *after* mapping rather
  than on the raw input.

  One caveat I will name about the sweep's construction: the `http://<input>/x`
  wrapper adds noise for the 138 cases whose input carries a URL-structural character
  and for the one empty input (which becomes `http:///x` and reports host `x`). That
  noise sits inside the mismatch counts, in the maintainer's favour — the real gap is
  marginally smaller than 189/518.

- **Which gaps the disclosure names, exactly.** `flyology_iri-idna.ads:5-14` says the
  unit carries "the ignorable and fullwidth mappings, case folding, rejection of the
  code points that carry no glyph, RFC 5893's prohibition on mixing letter directions
  inside one label, and RFC 3492 Punycode encoding", and that "It does not carry the
  full UTS #46 mapping table, the unassigned and mapped-symbol parts of the disallowed
  set, the ContextJ joiner rules, the remaining clauses of the bidi rule, or a Punycode
  decoder". `flyology_iri/README.md:22-32` repeats that list and closes with "Hosts
  outside that subset can still differ from a full UTS #46 implementation."

  Both lists are about *which code points* are mapped or disallowed. Neither names
  UTS #46 §4 "Processing" step 2, "Normalize the domain_name string to Unicode
  Normalization Form C", and neither names the §4.1 validity criteria "The label must
  be in Unicode Normalization Form NFC" (criterion 1) or "The label must not begin
  with a combining mark, that is: General_Category=Mark" (criterion 6) — all three
  quoted from the live UTS #46. So these are gaps the disclosure does not name, and
  the discovery reviewer's distinction is exact. The README's closing hedge is a
  blanket statement rather than a naming; I record it so the maintainer can weigh it.
  By contrast the mapping-table, case-folding and ContextJ items the discovery listed
  under "Observations not counted" *are* named, and I agree those are not findings.
- **Why it matters, and why P2.** `Map_Input` (`flyology_iri-idna.adb:174-211`) has no
  normalization step and the `To_ASCII` label loop (`:256-305`) has no mark check. The
  oracle has both: `ada_idna.cpp:6250-6252` runs `normalize` when the mapped string is
  not already NFC, and `is_label_valid` at `:5832` carries the comment "The label must
  not begin with a combining mark." A host typed on macOS or produced by several input
  methods arrives in NFD, so `bücher.de` yields `xn--bucher-xyd.de` where every browser
  yields `xn--bcher-kva.de`; the crate's answer decodes to a non-NFC label that a full
  UTS #46 implementation rejects on the way back, so it resolves nowhere, while a
  comparison against the precomposed spelling reports two different hosts. P2 stands:
  unusual input, no in-repository consumer, and the impact class is the one prior
  finding 13 already described.

## IRI-4: `Resolve` recomposes a `//`-prefixed path without authority into an authority, and rewrites WHATWG opaque paths under a web base

- **Verdict:** CONFIRMED
- **Severity:** **P1** (discovery said P2; raised — see "Reachability")
- **Repro:** `tests/repros/src/repro_iri_4.adb`, run with
  `./tests/repros/run.sh repro_iri_4`
- **Output:**

```
  note Parse  (sc:/.//p): image=[sc:/.//p] has_authority=FALSE host=[] path=[//p]
  note Resolve(sc:/.//p): image=[sc://p] has_authority=TRUE host=[p] path=[]
  FAIL Resolve (http://base/, "sc:/.//p") must have no authority
  FAIL resolved host for sc:/.//p
         expected: []
         actual:   [p]
  FAIL Resolve of an absolute reference must equal Parse of it
         expected: [sc:/.//p]
         actual:   [sc://p]
  note Parse  (mailto:a/../b): image=[mailto:a/../b] has_authority=FALSE host=[] path=[a/../b]
  note Resolve(mailto:a/../b): image=[mailto:/b] has_authority=FALSE host=[] path=[/b]
  FAIL an opaque path must not be dot-reduced by Resolve
         expected: [mailto:a/../b]
         actual:   [mailto:/b]
  note Resolve(sc:/a/b, ..//p): image=[sc://p] has_authority=TRUE host=[p] path=[]
  FAIL Resolve (sc:/a/b, "..//p") must have no authority
  FAIL resolved host for ..//p
         expected: []
         actual:   [p]
  note Resolve(file:/etc/x, ..//evil.com): image=[file://evil.com] has_authority=TRUE host=[evil.com] path=[]
  FAIL Resolve (file:/etc/x, "..//evil.com") must have no authority
  FAIL resolved host for ..//evil.com
         expected: []
         actual:   [evil.com]
  note Resolve(file:/var/www/index.html, /.//evil.com): image=[file://evil.com] has_authority=TRUE host=[evil.com] path=[]
  FAIL Resolve (file:/var/www/index.html, "/.//evil.com") must have no authority
  FAIL resolved host for /.//evil.com
         expected: []
         actual:   [evil.com]
  note controls: shapes that must resolve correctly
  note Resolve(http://good.com/a/b, /.//evil.com): image=[http://good.com//evil.com] has_authority=TRUE host=[good.com] path=[//evil.com]
  ok   authority-bearing base keeps its host (/.//)
  ok   authority-bearing base keeps its host (..//)
  note Resolve(file:/a/b, //evil.com): image=[file://evil.com] has_authority=TRUE host=[evil.com] path=[]
  ok   an explicit network-path reference does supply the host
  note Diagnose ("sc://p", URI_Syntax) = NO_ERROR; Diagnose ("file://evil.com", URI_Syntax) = NO_ERROR
  note the String-returning Resolve gives [file://evil.com]
checks: 13  failures: 10
BUG REPRODUCED
EXIT=1
```

- **Description:** `Resolve` is
  `Parse (Assemble (Base, Relative, Max_Length), Base.Syntax_Value, Max_Length)`
  (`flyology_iri.adb:1663-1670`), and `Assemble_Into` (`:1434-1588`) emits
  `scheme ":"` followed by the dot-reduced path with no guard against that path
  beginning with `//`. `Path` strips the WHATWG `/.` serialization guard
  (`:1270-1283`), so `Parse ("sc:/.//p")` carries `Image = sc:/.//p` but
  `Path = //p`, and `Assemble_Into` consumes `Path`; the reparse then reads the two
  slashes as an authority. The same happens in RFC mode whenever dot-segment removal
  leaves a path starting with `//` and neither the base nor the relative reference
  supplies an authority. A second, separate defect in the same routine: a WHATWG
  opaque path is run through `Append_Dot_Segments`, so `mailto:a/../b` becomes
  `mailto:/b` and `sc:..` becomes `sc:`.
- **Reachability, which is why I raise this to P1.** The discovery entry framed the
  URI variant as needing "a non-special scheme or an authority-less base" and left it
  at P2. I characterized the condition precisely and then executed it: the defect
  fires exactly when the base has a scheme but **no authority** and the relative
  reference reduces to a path beginning with `//`. Two consequences the discovery
  entry did not draw out, both now in the spike:
  - With `/.//evil.com` as the relative reference, the base's path depth does not
    matter, so `file:/var/www/index.html` — an ordinary absolute `file:` URI with no
    authority — plus a plain absolute-path reference is enough. The reference carries
    no scheme and does not begin with `//`; it looks like a path. `Resolve` returns a
    `Reference` with `Has_Authority = True` and `Host = evil.com`.
  - A base that *does* carry an authority is safe in every shape I tried, because the
    emitted `//authority` makes the recomposition unambiguous. That is exactly why the
    prior audit's finding-1 regression suite, which uses authority-bearing bases
    throughout, cannot see this — and the spike pins those two controls so a future
    fix cannot trade one for the other.

  By the rubric that is a wrong result on valid input via a reachable path — P1 — with
  a host-confusion flavour. It is not P0: it is not a wire-level or memory defect, and
  the security consequence needs a consumer, which this repository does not have.
- **Standard.** RFC 3986 §5.2.2 computes components, not a string: with `R.scheme`
  defined it sets `T.authority = R.authority`, and with neither a scheme nor an
  authority in `R` it sets `T.authority = Base.authority`; in both shapes above that
  value is undefined. §3.3 says "If a URI does not contain an authority component,
  then the path cannot begin with two slash characters ("//")", and §5.3 recomposition
  appends `//` only "if defined(authority)". The crate resolves that conflict by
  serializing without a guard and reparsing, which turns the undefined authority into
  a defined one. For the web base, the WHATWG URL serializer's step 3 exists precisely
  to prevent this (append `/.` when the host is null, the path is not opaque and
  `path[0]` is empty): the crate emits that guard from `Image` but strips it in
  `Path`, and `Assemble_Into` consumes `Path`. WHATWG opaque paths (§4.4) are never
  subject to dot-segment removal. All RFC and WHATWG wording was read from the live
  specifications for this verification.
- **Two things that make this reachable by the crate's own design.** (a)
  `flyology_iri_tests.adb:600-619` states in a comment that "Resolving with a web base
  is reachable whenever the relative reference is itself an absolute URL" and pins
  that case, so the web-base variant is on a supported path, not an abuse. (b) The
  crate gives two different answers for the same bytes: `Parse (Input, Base)` with the
  same web base returns the correct `sc:/.//p` with no host, while
  `Resolve (Base, Input)` returns `sc://p` with host `p` — the spike shows both lines
  side by side.
- **Note for whoever fixes this.** The `Resolve`-returning-`String` overload takes a
  different route for URI and IRI bases — `Diagnose` on the assembled bytes rather
  than a second `Parse` (`flyology_iri.adb:1672-1697`). The spike's last two lines
  show why that matters: `Diagnose` reports `NO_ERROR` for both `sc://p` and
  `file://evil.com`, and the String overload returns `file://evil.com` for the
  realistic case, so the two overloads currently agree on the wrong answer. A guard
  added to only the `Reference` overload would make them disagree, and
  `Check_Resolution_Base` asserts `Text = Image (Actual)`, so both must be fixed
  together.

## Also checked

- **The two items the previous audit could not settle** are correctly closed by the
  discovery entry; I re-ran both. `http://h/a^b?c^d#e^f` gives path `/a%5Eb` with `^`
  left raw in query and fragment; `non-special:opaque  ?hi` gives `opaque %20`,
  `non-special:opaque  x?hi` is unchanged, `sc:  ` trims to `sc:` and `sc: ?` gives
  `%20`. All match the corpus, so the green gate already covers them.
- **An independent model of the resolution code.** Before the harness could build
  against the crate I transcribed `Append_Dot_Segments` and `Assemble_Into` into
  Python to reason about IRI-4, and validated the transcription against 39
  reference/expectation pairs from RFC 3986 §5.4.1 and §5.4.2 (including all 13 the
  crate's suite pins) plus all 7 `Check_Resolution_Base` cases. Once `repro_iri_4`
  became runnable, every prediction the model made — `sc://p`, `mailto:/b`, `sc:`,
  `file://evil.com`, and the two safe authority-bearing controls — matched the real
  execution byte for byte. I mention it only because it is why the reachability
  characterization above is exhaustive rather than a handful of samples.
- **No new findings.** Two candidates I looked at and dropped. The out-of-range
  `Wide_Wide_Character'Val (16#110000#)` inside IRI-1's path is not erroneous
  execution: Ada's `Wide_Wide_Character` spans 2**31 positions, and the
  `Ada.Wide_Wide_Characters.Handling` category lookups are binary searches over sorted
  range tables (`s-utf_32.adb:12456-12516`), not indexed reads, so an out-of-Unicode
  code point is simply "not found". And `Canonical_Host` evaluating
  `Percent_Decode (Input)` before the IPv6 and opaque-host branches that never use it
  is cost only, in the same class as the discovery entry's `Parse (Input, Base)`
  observation. `Host` returning an IPv6 address without its brackets, which cost me a
  wrong assertion in `repro_iri_2`, is documented behaviour
  (`flyology_iri.ads:249`, "Return the host without IPv6 brackets").
