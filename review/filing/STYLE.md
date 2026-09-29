# Issue style for flyology-ada/flyology-http findings

This mirrors the issues filed on flyology-ada/flyology (#105–#197) from the
2026-09-02 crate review and on flyology-ada/flyology-postgres (#31–#93) from the
2026-09-05 review. Every issue is self-contained: a maintainer or an
automated fixer must be able to confirm and fix it from the issue alone.

## File format (one file per finding, `review/filing/<ID>.md`)

```
Title: <one-sentence problem statement>
Labels: bug[, documentation]
Refs: <comma-separated finding IDs this body cross-references, or none>

<body markdown, starting with "## Summary">
```

The `<ID>` in the file name is the internal finding ID (H2-1, ROUTING-MW-3 ...). The
internal ID must NOT appear anywhere in Title or body. Where the body needs to
refer to another finding's issue, write the placeholder `{{ISSUE:<ID>}}`
(for example `{{ISSUE:H2-1}}`); the filing step replaces it with the issue
URL and lists it in `Refs:`.

## Title

- A present-tense statement of what is wrong, specific enough to be unique:
  "Scoped DNS resolution with the default deadline expires every attempt
  immediately", "Linux lightweight Timed_Sleep waits forever when the deadline
  has already passed".
- No prefix, no severity, no component tag, no trailing period. Under about
  110 characters. Name the subprogram or message when that is what makes it
  specific.

## Body sections, in this order

### `## Summary`
Two to four sentences: the mechanism in one breath, then the consequence for
a user of the library. Written so a reader who stops here knows what is broken
and why it matters.

### `## Problem`
- First line: `Commit \`f078732\`.` If there is no runtime reproduction, the
  same line continues: `This is reported from reading the code; <why no
  reproduction was made>.`
- The evidence: the exact code, quoted in fenced ` ```ada ` blocks with the
  location in backticks before each quote (`src/flyology-http-server-http_2.adb:70-80`).
  Quote the contract being violated the same way (`.ads` comment, README
  sentence, a guide page under `website/`, a conformance document under
  `tests/`, or the RFC or standard clause). Cite the RFC by number and section
  (RFC 9112 section 6.3, RFC 7541 section 5.1, RFC 9000 section 17.2, WHATWG
  URL section 4.4) and quote the sentence the code violates. Cite another
  peer's behaviour only when it was actually observed through one of the pinned
  peers the scripts provide (python-hyper h2, h2spec 2.6.0, aioquic 1.3.0,
  quic-go 0.54.1, h3spec, PycURL, Autobahn, the WPT URL corpus, curl); never
  cite a browser or another server from memory.
- Why the existing tests do not catch it, with the test file:line when known.
- Use `###` subsections only when one issue deliberately covers several sites.

### `## What happens now` (when there is a runtime reproduction)
- Start with `Spike:` and one or two sentences describing the program: what
  it sets up, what it sends or calls, what it asserts. The program asserts the
  behaviour the RFC or the documented contract requires, so its `FAIL`
  lines are the expectations the library does not meet.
- Quote the essential lines of the program in a ` ```ada ` block (the calls
  and the bytes, not the harness boilerplate), then the verbatim output in a
  plain fenced block. Trim repeated lines but never edit the numbers.
- End with the host line:
  `Host: macOS 26.6.2, arm64, GNAT via Alire.` Add the pinned peer when the
  spike relies on one, for example ` Checked against h2spec 2.6.0.`,
  ` Checked against aioquic 1.3.0.`, ` Checked against quic-go 0.54.1.`,
  ` Compared against PycURL.`, or ` Checked against the pinned WPT URL corpus
  (ada-url/ada 32dabc8d).`

### `## Failure scenario` (instead of the previous section, when not reproduced)
A concrete sequence: what the peer sends or the caller does, what the code
does at each cited line, what the caller observes.

### `## What should happen`
One or two sentences stating the correct behaviour, with the authority (the
`.ads` contract, the RFC section, the WHATWG clause, the observed behaviour of
a pinned peer).

### `## Suggested treatment`
The smallest fix that closes the defect, concrete enough to start from, and
the alternative when the choice is a maintainer decision (say
"This needs a maintainer decision:" and state the options). Say where the
regression test should live (the existing smoke, matrix, corpus, audit or
conformance suite under `tests/` it belongs to, not a new file) and that the
spike is the test. Mention an existing test that asserts the wrong behaviour
and must change, with file:line. When the fix falls inside a unit
`./scripts/prove.sh` proves, say so and name the unit: the fix must keep the
proof discharging with `--checks-as-errors=on`.

### `## Severity`
Prose only, no P-labels: what the impact is, who hits it and how (a default
configuration, a stock peer, an unusual call), and whether it is deterministic.
End with one of: `Deterministic.`, `Deterministic; not reproduced against a
live peer.`, `Not reproduced.`, or a platform or protocol qualifier such as
`HTTP/2 only.` or `macOS only.`

## Rules

- Plain, exact, unhedged prose. Short sentences. No em-dashes. No
  exclamation marks. No "we"; the author is not a character.
- No mention of the review, reviewers, verifiers, agents, AI, Claude, the
  scratchpad, `FINDINGS.md`, the `review/` directory, the previous audit or its
  finding numbers, or the reproduction harness directories. The program is "the
  spike" or "the program below".
- Refer to a repository rule by its `AGENTS.md` section name ("Decision
  authority", "Ada interface values", "Ada source style", "Review cycle",
  "Commits", "TLA+ assurance"). Never by a `.claude` path.
- Every file:line is relative to the repository root at commit `f078732`. A
  path inside the nested crates carries its prefix (`flyology_quic/src/...`,
  `flyology_iri/src/...`).
- Do not oversell: if a measured effect is small or the trigger is unusual,
  the Severity section says so in the same sentence as the impact.
- When a fix needs an API or policy decision under the repository's
  decision-authority rule (new public constant, new variant, new parameter,
  changed default), the Suggested treatment says "This needs a maintainer
  decision" and lists the options; it does not choose.
- Related findings that share a fix get one issue each with a
  `{{ISSUE:<ID>}}` cross-reference in both bodies; duplicates are not filed at
  all and are folded into the primary issue's body as an extra site.
- A fix that adds a public constant, a default, a capacity, a timeout, a retry
  count, a buffer bound, a new variant, or a new parameter is a maintainer
  decision under "Decision authority" and "Ada interface values". Say so and
  list the options: a private implementation value, a caller parameter, a
  generic formal, a discriminant, a value derived from a type or contract,
  build-time configuration, or a deliberately public constant.

## Reference examples

The five issue bodies below are verbatim from flyology-ada/flyology and set
the register.

---

### flyology #179 — Scoped DNS resolution with the default deadline expires every attempt immediately (label: bug)

## Summary

`Time_Left` returns the `Infinite` sentinel, which is `-1.0`, for a deadline of `Time_Last`. The scoped resolver feeds that value straight into a `Duration'Min` against the per-attempt timeout, so the attempt deadline becomes one second in the past and every socket child is armed with an already-expired deadline. A scoped resolution using the default deadline therefore fails immediately, before any answer can arrive.

## Problem

Commit `2d0f313`.

`Time_Left` uses the negative sentinel for an unbounded deadline (`src/flyology-io-dns.adb:1607-1616`):

```ada
function Time_Left (Deadline : Ada.Real_Time.Time) return Duration is
begin
   if Deadline = Ada.Real_Time.Time_Last then
      return Infinite;
   ...
```

`Infinite` is `-1.0` (`src/flyology-io.ads:16-18`).

`Begin_Attempt` first tests for expiry with an equality against zero, which `-1.0` does not satisfy (`src/flyology-io-dns.adb:2196`), and then combines the two limits with `Duration'Min` (`src/flyology-io-dns.adb:2218-2220`):

```ada
Left :=
  Duration'Min (Item.State.Configuration.Per_Attempt, Time_Left (Item.State.Family_Deadline));
Item.State.Attempt_Deadline := Ada.Real_Time.Clock + Ada.Real_Time.To_Time_Span (Left);
```

`Duration'Min (2.0, -1.0)` is `-1.0`, so `Attempt_Deadline` is one second before now. [...]

Every scoped DNS test passes an explicit `Clock + span` (`tests/dns_smoke.adb:59`, :921, ...), so the default deadline is not covered.

## What happens now

Spike: a fake name server that answers after 50 ms, resolved twice, once with the default `Time_Last` deadline and once with `Clock + 3.0`.

Two consecutive runs, identical:

```
server at 127.0.0.1:55273
server: query 1 ( 28 bytes)
Time_Last  : FAILED FLYOLOGY.IO.DNS.RESOLUTION_FAILED / DNS resolution failed after 0.001092083 s
server: query 2 ( 28 bytes)
server: query 3 ( 28 bytes)
Clock+3.0  : OK 192.0.2.1 after 0.151967458 s
```

The default-deadline resolution fails in one millisecond, having sent its query but given the server no time to answer. The same resolution with an explicit deadline succeeds.

Host: macOS 26.6.2, arm64, GNAT 16.1.0, runtime prepared with `FLYOLOGY_DEFAULT=native`.

## What should happen

An unbounded family deadline should leave the per-attempt timeout in force, so each attempt gets its configured interval.

## Suggested treatment

Handle the sentinel explicitly in `Begin_Attempt`:

```ada
Left := (if Item.State.Family_Deadline = Ada.Real_Time.Time_Last
         then Item.State.Configuration.Per_Attempt
         else Duration'Min (Item.State.Configuration.Per_Attempt, Time_Left (...)));
```

Every other consumer of `Time_Left` should be audited for the same `-1.0` sentinel [...]. A regression test using the default deadline would have caught this; the existing scoped DNS tests all pass an explicit one.

## Severity

Scoped DNS resolution does not work at all with the default deadline: every attempt expires before an answer can arrive, and the caller gets `Resolution_Failed` or a premature `Timeout_Error`. It is the default, so it is what a caller who does not think about deadlines gets. Deterministic.

---

### flyology #155 — Linux lightweight Timed_Sleep waits forever when the deadline has already passed (label: bug; not reproduced)

## Summary

The Linux `Timed_Sleep` patch for lightweight tasks has no past-deadline guard. [...] The task then parks with nothing to wake it, where stock GNARL and the Darwin patch report a timeout immediately.

## Problem

Commit `2d0f313`. Linux only; this host is macOS, so this is reported from reading the code and no Linux run was made.

The Linux hunk sleeps unconditionally (`runtime/patches/gnat-13-16/linux/s-taprop.adb.patch:184-211`):

```ada
+      Result :=
+        Lightweight_Sleep
+          (Self_ID.Common.LL.L'Address,
+           Lightweight_Deadline (Time, Mode),
+           Lightweight_Result'Access);
```

The Darwin patch guards the same call (prepared source `build/rts/adainclude/s-taprop.adb:673-684`) [...]

## Failure scenario

A lightweight task on Linux executes

```ada
select
   PO.E;
or
   delay until Ada.Real_Time.Time_First;
end select;
```

The delay alternative should be taken immediately. Instead `Timed_Sleep` computes a negative deadline, no timer is registered, and the task hangs until the entry is served, which may be never.

## What should happen

A timed sleep whose deadline has already passed reports a timeout at once, as stock GNARL does and as the Darwin patch does.

## Suggested treatment

Add the guard before the sleep in the Linux hunk [...] matching the Darwin patch and the Linux `Timed_Delay` hunk.

## Severity

A timed selective wait or timed entry call in a lightweight task never times out, so the task can hang indefinitely. It needs a deadline that is already in the past by more than the machine's uptime, which is unusual but reachable from `Ada.Real_Time.Time_First` and from arithmetic that underflows. Linux only.

---

### flyology #185 — Synchronous Resolve_Using raises Constraint_Error for a large Attempts value (label: bug; code-level only, short)

## Summary

The synchronous `Resolve_Using` multiplies the attempt count by the number of name servers with no overflow guard, so a large `Attempts` raises `Constraint_Error` instead of the documented `Resolution_Failed`. The scoped path already guards the same product.

## Problem

Commit `2d0f313`. This is reported from reading the code; no runtime reproduction was made.

The unguarded product (`src/flyology-io-dns.adb:1116-1118`):

```ada
for Attempt in 1 .. Attempts * Name_Servers'Length loop
```

The scoped path guards it (`src/flyology-io-dns.adb:1722-1726`) [...]

## What should happen

Both paths should reject an unusable attempt count the same way, with the documented exception.

## Suggested treatment

Apply the scoped guard in the synchronous path before the loop.

## Severity

A wrong exception for an out-of-range argument. It needs an `Attempts` value large enough to overflow when multiplied by the server count, which is not something a sensible caller writes. No wrong results in normal use.

---

### flyology #189 — Wake-source signalling and pipe creation run inside protected actions across channels, executors, tokens and the capacity gate (label: bug; several sites in one issue, cross-reference by URL)

[Structure: Summary; Problem with `### Sites` subsections, one per component, each with file:line quotes; What should happen; Suggested treatment ending with "it is the same change the separate report on per-subscriber channel wakes (https://github.com/flyology-ada/flyology/issues/137) asks for."; Severity ending "not reproduced."]

---

### flyology #164 — Dynamic.Hash_Maps growth trigger ignores tombstones, so compaction never fires and churn degrades every operation (no label: performance)

[Structure: Summary; Problem with three code quotes and a cross-reference to the sibling issue URL; What happens now with `Spike:` description, the two essential declarations in an ```ada block, a six-row measurement table in a plain block, a sentence on how to read the figures, and the Host line; What should happen; Suggested treatment with the primary fix and the alternative; Severity.]
