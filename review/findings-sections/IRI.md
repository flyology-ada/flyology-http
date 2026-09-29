## IRI

This area covers the `flyology_iri` crate: `flyology_iri.adb`/`.ads` (RFC 3986 and RFC 3987
parsing, `Diagnose`, `Try_Parse`, dot-segment removal, `Assemble_Into` and both `Resolve`
overloads), `flyology_iri-web.adb` (the WHATWG URL parser, percent-encode sets, IPv4 and
IPv6 hosts, `Canonical_Host`), `flyology_iri-idna.adb`/`.ads`, `flyology_iri-unicode`, the
project file's suppression scope, and the crate's tests, differential harness, WPT
conformance driver and gate wiring. Four entries came out of discovery and all four are
confirmed; one severity was raised. The entry that matters is the raised one: `Resolve`
recomposes a `//`-prefixed path that has no authority into an authority, so a relative
reference that looks like a path can set the host of the result. The other three are
over-permissive host-parsing gaps whose severity is held down by the same fact: nothing
tracked in this repository consumes the crate.

Two pieces of context bound the whole area. First, the crate is one of the three
independently indexed crates in this repository, so its intended consumers are external
and the "no in-repository consumer" argument bounds the blast radius here without bounding
it for a downstream user. Second, `flyology_iri` has no proof script and none of its units
appear in `scripts/prove.sh` or `flyology_quic/scripts/prove.sh`, so no finding in this
area carries a proof obligation.

### IRI-1: Overlong and out-of-range UTF-8 in a percent-decoded host decodes to a different host

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_iri/src/flyology_iri-web.adb:597` and `:627`,
  `flyology_iri/src/flyology_iri-idna.adb:237-243`, against the crate's own U+FFFD
  rejection at `flyology_iri/src/flyology_iri-idna.adb:189-190`
- **Repro:** `./tests/repros/run.sh repro_iri_1` (exit 1, BUG REPRODUCED, checks: 19
  failures: 8), re-run at drafting time
- **What is wrong:** `Canonical_Host` percent-decodes the host and hands the bytes to
  `IDNA.To_ASCII`, which decodes with
  `Ada.Strings.UTF_Encoding.Wide_Wide_Strings.Decode` and handles only `Encoding_Error`.
  That decoder classifies the lead byte by shape alone, with no minimum-value test and no
  cap at U+10FFFF, so `C1 81` becomes `a`, `C0 AE C0 AE` becomes `..`, and `F4 90 80 80`
  becomes code point 16#110000#, which `Punycode` then encodes as `xn--en32g`.
  `http://%C1%A5xample.com/` is accepted with host `example.com`, and `Diagnose` reports
  `NO_ERROR` at offset 0 for every case, so nothing downstream can tell these apart from a
  clean host. The escaped and raw forms behave identically, so this is not a
  percent-decoding defect.
- **Notes:** the spike carries three controls that keep the claim honest: the same raw
  bytes are rejected under `IRI_Syntax` (so the two syntaxes disagree on one input), an
  overlong NUL is rejected incidentally by the separate NUL rule, and a surrogate is
  rejected because the standard-library decoder does check that one shape. The corpus
  absence was re-verified independently at drafting time: `urltestdata.json`,
  `ada_extra_urltestdata.json`, `toascii.json` and `ada_long_urltestdata.json` in the
  pinned checkout contain zero occurrences of `%C0`, `%C1`, `%E0%8`, `%F0%8`, `%F4%9` or
  `%F5` through `%FF`, and zero raw 0xC0, 0xC1 or 0xF5 through 0xFF bytes. The oracle's
  rejection was re-verified by reading `build/ada-url/src/ada_idna.cpp` at 32dabc8d: the
  two-byte branch returns 0 for `code_point < 0x80`, and the three- and four-byte branches
  range-check likewise. The out-of-Unicode `Wide_Wide_Character'Val (16#110000#)` is not
  erroneous execution in Ada: `Wide_Wide_Character` spans 2**31 positions and the category
  lookups are binary searches over sorted range tables, not indexed reads.
- **Severity reasoning:** the harm is the classic validate-then-forward overlong
  differential, which needs a consumer. There is none in this repository: no tracked `.ads`,
  `.adb` or `.gpr` file outside `flyology_iri/` references the crate, re-verified at
  drafting time over `git ls-files`. The HTTP client and server parse targets with their
  own code. The filed body states that in the Severity section, as the drafting brief
  requires.
- **Fix decision:** none required if the fix reuses an existing `Error_Kind`. A distinct
  diagnosis would add a literal to a public enumeration, which is a maintainer decision;
  the filed body lists the options and does not choose.

### IRI-2: IPv4-in-IPv6 tail accepts leading zeros the WHATWG IPv6 parser rejects

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_iri/src/flyology_iri-web.adb:487-506`
- **Repro:** `./tests/repros/run.sh repro_iri_2` (exit 1, BUG REPRODUCED, checks: 10
  failures: 6), re-run at drafting time
- **What is wrong:** the dotted tail accumulates every digit into `A`/`B`/`C`/`D` and
  validates only `Part /= 4`, `Digit_Count = 0` and `> 255`. There is no "second digit
  after a zero" test and no three-digit cap, so `01`, `04`, `00`, `0255` and `0127` are all
  accepted, and `http://[::01.2.3.4]/` normalizes to the same host as the canonical
  spelling.
- **Notes:** the gate cannot see it and the reason is exact. Ten IPv4-in-IPv6 cases exist
  in the pinned `urltestdata.json`, enumerated independently at drafting time, and only
  case 714 `https://[0:1.00.0.0.0]` carries a leading zero. It also carries five dotted
  parts, so the crate rejects it on the `Part < 4` guard and the zero rule is never
  exercised. `flyology_iri/tests/src/flyology_iri_tests.adb:476-481` pins leading-zero
  rejection for the RFC 3986 `Valid_IPv4` path only; `Canonical_IPv6` is a separate
  implementation with no such test. The spike's three acceptance controls pin that a single
  `0` part stays legal, and its last check shows the crate's own RFC path rejects the same
  literal, so the two syntaxes disagree on one input.
- **Severity reasoning:** the canonical form is correct whenever the input is accepted,
  there is no wire consequence, and the direction is over-permissive, so the only
  consequence is a normalized-host comparison that admits a spelling no stock parser
  admits, and that needs a consumer the repository does not have.
- **Fix decision:** none. Both bounds come from the WHATWG IPv6 parser, so under "Decision
  authority" the fix records the authority next to the check rather than asking for a
  choice.

### IRI-3: IDNA applies no NFC normalization and no leading-combining-mark check, and the disclosure names neither

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_iri/src/flyology_iri-idna.adb:174-211` (`Map_Input`, no
  normalization step) and `:256-305` (the label loop, no mark check); the disclosure at
  `flyology_iri/src/flyology_iri-idna.ads:5-14` and `flyology_iri/README.md:22-32`
- **Repro:** `./tests/repros/run.sh repro_iri_3` (exit 1, BUG REPRODUCED, checks: 7
  failures: 6), re-run at drafting time
- **What is wrong:** UTS #46 section 4 step 2 requires NFC normalization and section 4.1
  criteria 1 and 6 require an NFC label that does not begin with a
  `General_Category=Mark` code point. The crate does neither, so the NFD and NFC spellings
  of one host give two different ASCII hosts (`xn--bucher-xyd.de` against
  `xn--bcher-kva.de`) and a label beginning with U+0308 is accepted. The `=` U+0338 case
  shows the ordering constraint: normalization has to run after the mapping step, because
  the ignorable code points the mapping removes can otherwise block a composition.
- **Notes on the disclosure, which is the whole question for this entry.** The `.ads` and
  the README disclose a deliberately scoped UTS #46 subset, and a gap the disclosure names
  is not a finding. Both lists are about *which code points* are mapped or disallowed:
  the full mapping table, the unassigned and mapped-symbol parts of the disallowed set,
  the ContextJ joiner rules, the remaining bidi clauses, and the absent Punycode decoder.
  Neither text mentions normalization, NFC, or the combining-mark criterion. The README's
  closing sentence, "Hosts outside that subset can still differ from a full UTS #46
  implementation", is a blanket hedge rather than a naming. So the whole of this entry
  falls **outside** the disclosure, and it stays a finding rather than becoming a pure
  documentation issue. The mapping-table, case-folding, ContextJ and bidi gaps the
  discovery entry listed under observations *are* named and are not reported. The filed
  body carries both labels, `bug` and `documentation`, because if the maintainer declines
  the normalization work the documentation half is still owed.
- **Notes on the sweep.** The figures rest on `IdnaTestV2.json`, which the crate's
  conformance driver never runs: `flyology_iri/tests/wpt_conformance.py:45` reads
  `urltestdata.json` and `ada_extra_urltestdata.json` only, while `IdnaTestV2.json` and
  `toascii.json` sit beside them in the pinned corpus. The verifier's numbers were
  reproduced exactly at drafting time by re-running the sweep independently through the
  crate's URL command-line program: `IdnaTestV2.json`, 2671 object cases, 1899 match, 189
  both-accept-different-host, 518 accepted-where-failure-expected, 65
  rejected-where-host-expected, with 87 of the 189 fixed by NFC; `toascii.json`, 87 cases,
  60 match, 10 host mismatches, 7 over-accepts, 10 over-rejects, with 5 of the 10 fixed by
  NFC. The discovery entry said six for that last figure; five is the number that stands.
  The 278 figure for over-accepts whose label begins with a Mark after NFC reproduces only
  when labels are split on all four separators the crate itself maps (`.`, U+3002, U+FF0E,
  U+FF61); splitting on the ASCII dot alone gives 183, and 278 is the correct one. The
  caveat the verifier named is carried into the filed body: the `http://<input>/x` wrapper
  adds noise for the 138 cases whose input carries a URL-structural character and for the
  one empty input, so the real gap is marginally smaller than 189 and 518, in the
  maintainer's favour.
- **Fix decision:** NFC is not a constant-cost fix, because the crate carries no
  composition data and is published independently. That is a maintainer decision; the
  filed body lists the options, including declining the work and naming the gap instead,
  and does not choose. The combining-mark check needs no decision.

### IRI-4: `Resolve` recomposes a `//` path with no authority into an authority

- **Severity:** **P1** (discovery said P2; raised)
- **Location:** `flyology_iri/src/flyology_iri.adb:1666-1673` (`Resolve` is
  `Parse (Assemble (...))`), `:1462-1469` and `:1489-1504` (`Assemble_Into` emits `//`
  only for an authority and otherwise writes the dot-reduced path straight after the
  colon), `:1270-1284` (`Path` strips the WHATWG `/.` guard that `Assemble_Into` then
  needs), `:1675-1700` (the `String` overload's separate route)
- **Repro:** `./tests/repros/run.sh repro_iri_4` (exit 1, BUG REPRODUCED, checks: 13
  failures: 10), re-run at drafting time
- **What is wrong:** `Resolve` serializes the target and reparses it, and the
  serialization has no guard against a dot-reduced path beginning with `//` when there is
  no authority. The reparse then reads those two slashes as an authority, so an authority
  RFC 3986 leaves undefined becomes a defined one. `Resolve (file:/etc/x, "..//evil.com")`
  gives host `evil.com`; `Resolve (file:/var/www/index.html, "/.//evil.com")` gives host
  `evil.com`; `Resolve (sc:/a/b, "..//p")` gives host `p`. A separate defect in the same
  routine runs a WHATWG opaque path through `Append_Dot_Segments`, so `mailto:a/../b`
  becomes `mailto:/b`.
- **Notes:** the raise from P2 to P1 rests on reachability that the discovery entry did not
  draw out and the spike now executes. With `/.//` as the relative reference the base's
  path depth does not matter, so an ordinary absolute `file:` URI with no authority plus a
  plain absolute-path reference is enough; the reference carries no scheme and does not
  begin with `//`, so it looks like a path. That is host confusion through reference
  resolution. A base that *does* carry an authority is safe in every shape tried, which is
  exactly why the previous audit's finding-1 regression suite
  (`flyology_iri/tests/src/flyology_iri_tests.adb:577-598`), which uses authority-bearing
  bases throughout, cannot see it; the spike pins two such controls so a fix cannot trade
  one for the other, plus a third showing an explicit network-path reference must still
  supply the host. The crate gives two different answers for the same bytes:
  `Parse ("sc:/.//p", Web_URL_Syntax)` has no host while `Resolve` of the same reference
  has host `p`, and the spike prints both lines side by side. Both overloads have to be
  fixed together: the `String` overload validates a URI or IRI result with `Diagnose` on
  the assembled bytes rather than by building a second reference, `Diagnose` reports
  `NO_ERROR` for both `sc://p` and `file://evil.com`, and `Check_Resolution_Base` asserts
  `Text = Image (Actual)`. The crate's own comment at
  `flyology_iri/tests/src/flyology_iri_tests.adb:600-605` states that resolving with a web
  base is reachable whenever the relative reference is itself an absolute URL, so the
  web-base variant is on a supported path rather than an abuse.
- **Severity reasoning:** it is not P0. It is not a wire-level or memory defect, and the
  security consequence needs a consumer, which this repository does not have. The filed
  body says that plainly and names the exposed caller: an application resolving a
  reference against a trusted base.
- **Fix decision:** emitting the `/.` guard in URI or IRI mode changes the bytes the crate
  produces for every caller that stores the serialization, so it is a maintainer decision;
  the filed body lists the options, including the component-building route that needs no
  serialization device, and does not choose.
- **Harness note, recorded because it changed mid-review:** when this area was verified,
  `Flyology_IRI` was not on the reproduction harness project path, so the verifier worked
  around it with shell reproductions driving the crate's prebuilt
  `flyology_iri_url_cli` rather than modifying a shared project file. The harness project
  has since been given an explicit `with` of `flyology_iri.gpr`, so all four entries are
  now ordinary Ada spikes and the shell reproductions are gone. Every output quoted in the
  four filed bodies is from an Ada spike re-run at drafting time, and the Ada form is
  strictly better evidence because it reaches `Can_Parse`, `Diagnose` and `Resolve`, none
  of which the command-line program exposes.

### Coverage evidence

Read: `flyology_iri/src/flyology_iri.adb`/`.ads`, `flyology_iri-web.adb`,
`flyology_iri-idna.adb`/`.ads`, `flyology_iri-unicode`, `flyology_iri/flyology_iri.gpr`,
`flyology_iri/README.md`, `flyology_iri/tests/src/flyology_iri_tests.adb`,
`flyology_iri/tests/src/flyology_iri_url_cli.adb`,
`flyology_iri/tests/src/flyology_iri_differential.adb`,
`flyology_iri/tests/wpt_conformance.py`, `flyology_iri/scripts/wpt-gate-test.sh` and the
corpus wiring in `.github/workflows/ci.yml:97-111`.

Executed at drafting time: four Ada spikes, all BUG REPRODUCED with exit 1. Independently
re-run at drafting time rather than taken from a report: the IDNA corpus sweep over
`IdnaTestV2.json` and `toascii.json` (numbers above, all matching the verifier); the byte
scan of all four pinned corpus files for the IRI-1 sequences; the enumeration of the ten
IPv4-in-IPv6 cases in `urltestdata.json`; the `git ls-files` scan establishing that no
tracked source or project file outside `flyology_iri/` references the crate; and the read
of `build/ada-url/src/ada_idna.cpp` and `src/url.cpp` at the pinned 32dabc8d for the two
oracle behaviours cited.

**Regression check over the previous audit.** Eleven of the previous audit's forty-three
findings are located in `flyology_iri/`: numbers 1, 5, 13, 20, 21, 22, 39, 40, 41, 42 and
43 in its contents list. All eleven were re-checked and all eleven are still fixed. The
check was made by reading code, not by commit SHA, and the reason is worth recording: the
fix SHAs the previous audit cites (`4f2c065`, `822acac`, `c174069`, `63c60fb`, `d208434`,
`d273bf9`, `fa53e67`, `82f0099`, `01b1e69`) are **not ancestors of `f078732`**; the fixes
landed as re-authored commits on 2026-08-07 with matching subjects, so a SHA-based check
would have reported every one of them as missing. Three were additionally re-verified by
execution: finding 1 (the merge keeps the base's root slash, and `repro_iri_4`'s controls
confirm from the other direction that an authority-bearing base keeps its host), finding 20
(the lowercase fast path, the uppercase slow path and the percent-escaped slow path now
agree, and all three accept over-length labels and names as `VerifyDnsLength` false
requires), and finding 22 (the workflow pins `ada-url/ada@32dabc8d`, sets
`FLYOLOGY_IRI_REQUIRE_WPT`, and `review/baselines/02-test-sh.log:28` shows
`919/919 (100.0%), mismatches=0`).

*Count discrepancy to reconcile before the findings document goes out:* the discovery
report's heading and the drafting brief both say "fourteen" IRI findings in the previous
audit. The audit's own contents list attributes eleven to `flyology_iri/`, and the
discovery report's own regression table has eleven rows. Eleven is the number the evidence
supports; the narrative should use it.

**A clean negative result: the two items the previous audit flagged but could not settle
are both settled against the finding.** (1) `^` in the path percent-encode set
(`flyology_iri-web.adb:165-166`) is correct. The current WHATWG path percent-encode set is
the query set plus `?`, `^`, `` ` ``, `{` and `}`, and corpus cases 850-851 expect
`/…%5E_%60%7B|%7D~` for a path while 852-855 keep `^` raw in query and fragment; the crate
reproduces all three, giving `/a%5Eb?c^d#e^f`. (2) `Encode_Opaque_Path` encoding only a
single trailing space (`flyology_iri-web.adb:226-241`) is exactly the opaque-path-state
rule: cases 291-298 expect `non-special:opaque  ?hi` to give `opaque %20`, one space kept
and the last one encoded, and `opaque  x?hi` unchanged; the crate matches, including
`sc:  ` trimming to `sc:` and `sc: ?` giving `%20`. Both sets of cases are in
`urltestdata.json`, so the green gate already covers both, and neither needs a new test.

Also checked and sound, not counted: all six percent-encode sets character by character
against the current specification, with corpus cases 844-855 exercising each; scheme
detection and the special-scheme list with its default ports; the authority, userinfo, host
and port states including the last-`@` split, the empty-port and empty-host cases, ports
above 65535 and `file` with a port; every WHATWG IPv4 form including the overflow guard;
and `Diagnose` reduced to the same route `Try_Parse` takes, held to one answer over 10 000
seeded inputs by the differential harness.

Could not be exercised: nothing in this area was blocked. Every claim in the four entries
is reproduced by an Ada spike or by a re-run corpus sweep.

### Refuted and not counted

- **`Wide_Wide_Character'Val (16#110000#)` as erroneous execution.** Considered as a
  separate defect inside IRI-1's path and dropped. Ada's `Wide_Wide_Character` spans 2**31
  positions and the `Ada.Wide_Wide_Characters.Handling` category lookups are binary
  searches over sorted range tables, not indexed reads, so an out-of-Unicode code point is
  simply not found. There is no erroneous execution and no memory fault; the only
  consequence is the wrong host already counted in IRI-1.
- **`Canonical_Host` evaluating `Percent_Decode (Input)` before the IPv6 and opaque-host
  branches that never use it.** Cost only, in the same class as the `Parse (Input, Base)`
  observation the discovery entry recorded. Not a correctness defect.
- **`Host` returning an IPv6 address without its brackets.** This cost a wrong assertion in
  an early draft of the IPv6 spike and looks like a defect until the contract is read. It
  is documented behaviour: `flyology_iri/src/flyology_iri.ads:249`, "Return the host
  without IPv6 brackets, or an empty string." Not a finding.
- **`Port` as an unbounded digit string in the RFC modes.** Recorded by discovery as a
  known coverage gap of the previous audit rather than a new defect; not counted here.
