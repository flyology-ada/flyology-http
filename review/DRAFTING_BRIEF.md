# Drafting brief (read this first)

You draft the public issue bodies and the consolidated findings sections for one or two
areas of the correctness review of `flyology-ada/flyology-http` at commit `f078732`.

WORKTREE: `/Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/exciting-lumiere-963c47`.
Use absolute paths. The Bash working directory persists between calls.

## Read first, in this order

1. `review/filing/STYLE.md` IN FULL, including the five reference issue bodies at the end.
   They set the register. Match them.
2. `review/discovery-<AREA>.md` and `review/verification-<AREA>.md` for each of your areas.
   The verification report is authoritative where the two disagree: it corrected several
   discovery claims, including wrong RFC citations, and it moved several severities.
3. `review/TALLY.json`, which lists every finding with its final severity and its repro.

## What you produce

### A. One issue body per confirmed finding, at `review/filing/<ID>.md`

Only for findings whose severity in `review/TALLY.json` is `P0`, `P1` or `P2`. Skip
`DUP` and `REFUTED`; a duplicate is folded into its primary's body as an extra site, and
the verification report says which primary.

The file format, the section order and the rules are in `STYLE.md`. The things that most
often go wrong, so check each one before you finish a body:

- **Re-run the spike and paste the fresh output.** Run
  `./tests/repros/run.sh <program> [seconds]` and quote what it prints, verbatim, numbers
  unedited. Do not copy the output out of the verification report; run it again. If a
  finding has no spike, use `## Failure scenario` instead of `## What happens now`, and
  the `## Problem` first line must say it is reported from reading the code and why no
  reproduction was made.
- **Verify every file:line with `sed -n '<range>p' <file>` before you quote it.** Line
  numbers drift between a discovery report and the current file. Quote what is actually
  there at `f078732`.
- **Cite the standard by number and section and quote the sentence.** The verification
  reports corrected several citations that were wrong or came from an obsoleted RFC; use
  the corrected one. If the verifier marked a peer-behaviour claim "not verified against
  a peer", the body must say so in the same sentence as the claim, and the Severity
  section must not rest on it.
- **Name the existing test that asserts the wrong behaviour**, with file:line, when the
  verification report identifies one. Say where the regression test belongs: an existing
  smoke, matrix, corpus, audit or conformance suite under `tests/`, never a new file.
- **Say "This needs a maintainer decision:" and list the options** wherever the fix adds a
  public constant, a default, a capacity, a timeout, a retry count, a buffer bound, a new
  variant or a new parameter. That is the "Decision authority" and "Ada interface values"
  rule in `AGENTS.md`. Options to choose among: a private implementation value, a caller
  parameter, a generic formal, a discriminant, a value derived from a type or contract,
  build-time configuration, or a deliberately public constant. Do not choose.
- **If the fix falls inside a unit `./scripts/prove.sh` proves, say so and name the unit.**
  The fix must keep the proof discharging with `--checks-as-errors=on`. The proved units
  are listed in `scripts/prove.sh`; check rather than guess, and note that some units a
  discovery report called "proved" are not.
- **Cross-reference with `{{ISSUE:<ID>}}`**, never with a finding id in prose.
- **No forbidden words.** No mention of this review, of reviewers or agents, of the
  previous audit or its finding numbers, of `FINDINGS.md`, `review/`, `.claude`, or the
  reproduction harness directory. The program is "the spike" or "the program below".
  Refer to a repository rule by its `AGENTS.md` section name, never by a path.
- **No em-dashes.** No internal finding id in the title or the body.
- Host line: `Host: macOS 26.6.2, arm64, GNAT via Alire.` plus the pinned peer when the
  spike relies on one.

### B. One consolidated section per area, at `review/findings-sections/<AREA>.md`

This is the per-area section of the review's findings document. It is internal, so the
forbidden-word rules above do NOT apply to it, and you may name the previous audit and the
review freely. Format:

```markdown
## <AREA>

<one paragraph: what the area covers, what was read, and the headline result>

### <ID>: <title>

- **Severity:** P1 (discovery said P2; raised because ...)
- **Location:** `src/file.adb:123`
- **Repro:** `./tests/repros/run.sh repro_x` (exit 1, BUG REPRODUCED)
- **What is wrong:** <two to five sentences: the mechanism and the consequence>
- **Notes:** <maintainer decisions the fix needs; tests that assert the current wrong
  behaviour; sub-claims the verifier refuted or narrowed; duplicates folded in; anything
  the verifier could not exercise>

### Coverage evidence

<what was read, what was executed, which suites and peers bear on this area, and what
could not be exercised>

### Refuted and not counted

<candidates refuted, and observations recorded but outside the rubric>
```

## Validation

When your bodies are drafted, run:

```sh
cd /Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/exciting-lumiere-963c47
python3 review/filing/file_issues.py --dry-run
```

It validates required sections, the commit line, forbidden words, leaked internal ids and
em-dashes across every drafted body, not only yours. Fix every problem it reports for YOUR
ids. Ignore problems reported for ids belonging to other areas; another agent owns those.
Never run it with `--file` or `--resolve`.

## Constraints

- Do not modify any tracked file. Do not modify another area's issue body or spike.
- `./tests/repros/run.sh` is the only build entry point you use. Never run `alr`,
  `gprbuild`, or a maintained script under `scripts/`.
- A full harness sweep may be running; a build that waits on the lock is normal.
