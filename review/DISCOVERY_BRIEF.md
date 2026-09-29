# Discovery brief (read this first)

You are one of twelve independent reviewers performing a correctness review of
`flyology-ada/flyology-http` at commit `f078732` (branch `main`). Work ONLY in the
worktree `/Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/exciting-lumiere-963c47`.
Use absolute paths. The Bash working directory persists between calls.

## You are READ ONLY

- Do not modify, create, or delete any file under the worktree EXCEPT your own report
  at `review/discovery-<AREA>.md`.
- Do not run `alr`, `gprbuild`, `./scripts/test.sh`, or any build or test script. A
  long serialized baseline run is in progress and a concurrent `alr` invocation
  corrupts the shared Alire cache. Reading, `rg`, `sed -n`, `git log`, `git show` are
  all fine.
- You may read `review/prior-audit.md` (the previous audit of this repository) and any
  file under `tests/`, `proof/`, `formal/`, `docs/`, `website/`, `showcases/`.

## What counts as a finding

A defect in the code as written: wrong behaviour, a protocol violation, unsafe memory
or aliasing, a lifetime or cancellation defect, a contract the `.ads` comment or a
document promises and the body does not deliver. Prioritise surfaces a hostile peer
reaches: bytes parsed from the network, request smuggling and header injection, TLS and
QUIC key handling, path decoding before routing, flow-control and window arithmetic,
pool and lease lifetime under cancellation and abort.

Documented policy values (limits, defaults, capacities, timeouts) are NOT bugs unless
they break a protocol rule or a documented invariant. Put those under "Observations not
counted".

## Severity rubric

- **P0** memory or aliasing unsafety; security-relevant (request smuggling, header or
  response splitting, authentication or TLS-verification bypass, key or secret exposure,
  path traversal through decoded paths, a single hostile packet or frame that stalls or
  amplifies); silent corruption of request or response bytes; hang or deadlock in normal
  operation; or an interop-breaking protocol violation that a stock peer (curl, browsers,
  nginx, python h2, aioquic, quic-go) rejects.
- **P1** wrong result or unexpected exception on valid input via a reachable path, or a
  documented contract violated (`.ads` comment, README, guide pages, conformance
  documents under `tests/`).
- **P2** edge-case incorrectness, wrong diagnostics, or contract drift needing unusual
  input.

## The previous audit

`review/prior-audit.md` is the 2026-08-07 audit of this repository: 43 confirmed
findings, all closed on `main`, each with the commit that closed it. Before you look for
anything new:

1. Read every entry in that report that touches your area, including the appendices
   ("attack classes checked and found sound", "refuted candidates", "coverage gaps").
2. Treat those findings as KNOWN. Do not re-report one. The single exception is a fix
   that has since REGRESSED at `f078732` — then it is a new finding and your entry must
   say which prior finding regressed and which commit had fixed it.
3. Its "coverage gaps" and "found sound" appendices tell you where it did not look.
   Aim there, and at everything added since. `CHANGELOG.md` "Unreleased" and the merged
   pull requests since #24 list the new surface: composable owner-driven client
   exchanges, the SSE client across all three protocols, scoped HTTP/1 stale-lease
   recovery, exact fixed-length response streams, S3-driven request fidelity and streamed
   HTTP/2 and HTTP/3 uploads, HTTP/3 stream receive credit and settlement, and QUIC
   handshake recovery and listener slots.

## Method

1. Read the `.ads` contracts for your area first. They are the promises.
2. Read the bodies. Trace each defect to a real caller: an entry point a peer or an
   application can actually reach. A defect in an unreachable path is at most P2 and must
   say so.
3. Check the existing tests under `tests/` for your area before claiming something is
   untested, and name the test that asserts the current wrong behaviour when one does.
4. Try to REFUTE each of your own candidates before recording it. Most first-pass
   candidates are wrong. A candidate you cannot refute gets recorded with the confidence
   you actually have.
5. Cite the RFC section or standard clause for every protocol claim. If you cannot check
   a claim about what a real peer does, say so in the entry.

## Report

Write `review/discovery-<AREA>.md`. Create the file after your FIRST finding and append
to it as you go, so a crash preserves partial results; rewrite the header at the end.

```markdown
# Discovery: <AREA>

Scope: <files you read, with line counts>
Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| <AREA>-1 | ... | P0 | high |

## Findings

### <AREA>-1: <one-line title>

- **Location:** `src/file.adb:123` (consumed at `:456`)
- **Severity:** P0
- **Confidence:** high | medium | low
- **Evidence:**

```ada
<exact quoted lines from the file>
```

- **Failure scenario:** <numbered steps from an entry point a peer or application reaches>
- **Reproduction test sketch:** <concrete calls, bytes, or frames; expected versus actual;
  expressible without an external peer where possible>
- **Existing coverage:** <the test that covers or mis-covers this, with file:line, or "none">
- **Standard:** <RFC section / WHATWG clause, or "n/a">

## Areas reviewed with no findings

<list, with why each is sound>

## Observations not counted

<policy values, style, performance guesses, anything outside the rubric>
```

Be specific and be honest. A short report with four real findings beats a long one with
twenty guesses. Report confidence you actually have.
