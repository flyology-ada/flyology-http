# Verification brief (read this first)

You are an adversarial verifier for one area of the correctness review of
`flyology-ada/flyology-http` at commit `f078732`. Work ONLY in the worktree
`/Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/exciting-lumiere-963c47`.
Use absolute paths. The Bash working directory persists between calls.

## Your job

For every finding in `review/discovery-<AREA>.md`:

1. **Try to refute it.** Re-read the cited code at `f078732`. Read the callers. Read the
   `.ads` contract. Read the RFC or standard clause the entry cites and check that it says
   what the entry claims. Most wrong findings are wrong because the guard is somewhere the
   discovery reviewer did not look, or because the path is unreachable, or because the
   cited standard text does not say what the entry says.
2. **If it survives, reproduce it.** Write one program per finding under the harness and
   run it. A finding without a passing reproduction is not CONFIRMED.
3. **Assign the corrected severity** with the rubric below. Severity moves in both
   directions; say the discovery severity and yours.

Verdicts: `CONFIRMED`, `REFUTED`, `PARTIALLY CONFIRMED`, `DOCUMENTED LIMITATION`,
`UNVERIFIABLE`.

## Severity rubric

- **P0** memory or aliasing unsafety; security-relevant (request smuggling, header or
  response splitting, authentication or TLS-verification bypass, key or secret exposure,
  path traversal through decoded paths, a single hostile packet or frame that stalls or
  amplifies); silent corruption of request or response bytes; hang or deadlock in normal
  operation; or an interop-breaking protocol violation that a stock peer rejects.
- **P1** wrong result or unexpected exception on valid input via a reachable path, or a
  documented contract violated (`.ads` comment, README, guide pages, conformance documents
  under `tests/`).
- **P2** edge-case incorrectness, wrong diagnostics, or contract drift needing unusual input.

## The reproduction harness

`tests/repros/` is built and working. Read `tests/repros/README.md` first.

```sh
cd /Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/exciting-lumiere-963c47
./tests/repros/run.sh <program_name> [timeout_seconds]
```

- One program per finding, `tests/repros/src/repro_<id>.adb`, where `<id>` is the finding
  id lowercased with `-` turned into `_` (finding `H2-3` gives `repro_h2_3`).
- A program asserts the CORRECT behaviour. On current sources it must print
  `BUG REPRODUCED` and exit 1. Exit 0 means the bug did not reproduce, which is evidence
  the finding is REFUTED, not a reason to weaken the assertion.
- `Repro_Support` gives `Check`, `Note`, `Expect_Equal`, `Finish`, `B`, `S`, `Hex`,
  `Printable`, `CRLF` and `Ephemeral_Port`. Read `tests/repros/src/repro_support.ads`.
- ALWAYS bind loopback ports through `Ephemeral_Port`. Fixed ports collide with the
  maintained suites.
- `src/seam_check.adb` and `src/repro_smoke.adb` are harness self-tests and must PASS.
  Do not edit them. Do not edit another finding's spike.
- Several policy units are `private package`; a spike that needs one must be a child unit,
  as `tests/flyology-http-decoded_path_policy-smoke.adb` is. The README says how.
- `tests/` is on the source path, so `flyology-io-connections-testing.ads`,
  `tls_test_provider.ads` and `flyology-quic-test_connections.ads` are available, and you
  can copy an in-memory transport from the nearest maintained test.
- The build takes a lock, so concurrent verifiers serialize. A build that waits is normal.
  Never run `alr`, `gprbuild`, `./scripts/test.sh` or any suite script yourself; the
  harness `run.sh` is the only build entry point you use.

## Four levels of spike

Pick the lightest one that proves the claim.

1. **Direct package calls.** Policy units, HPACK, frames, chunk encoding, QPACK, IRI.
2. **In-process loopback client and server** over Flyology sockets on an ephemeral port,
   as `tests/http_smoke.adb` does, or an in-memory `HTTP_Server.Transport`, which is the
   cheapest way to drive the server with crafted bytes.
3. **A raw peer inside the spike** that writes crafted bytes, frames or packets to the
   server, or answers the client, using `GNAT.Sockets` or `Flyology.IO.Sockets`, with
   `Flyology.QUIC.Test_Connections` for QUIC.
4. **A pinned independent peer.** Only for an interop claim you cannot settle in-process.
   These live behind the maintained scripts, which you must NOT run yourself. If a finding
   needs one, say so in the report and mark it UNVERIFIABLE-BY-SPIKE with what would settle
   it; the coordinator runs the script.

## Peer and baseline evidence already available

Do not re-derive these; read the log and cite it.

- `review/baselines/SUMMARY.txt` lists every baseline, its exit status and its duration.
- h2spec 2.6.0 against the server: **146 tests, 146 passed, 0 failed**
  (`review/baselines/13-http2-h2spec-docker.log`).
- Autobahn against the server: core native **240 OK, 4 NON-STRICT, 3 INFORMATIONAL, no
  failures**; core lightweight, limits native and compression native all green
  (`review/baselines/20-` through `23-`).
- HTTP/3 interop against aioquic 1.3.0 and quic-go 0.54.1, both client and server roles:
  PASS (`review/baselines/10-http3-interop.log`). h3spec and the stress campaign: PASS.
- Ada versus PycURL client differential: PASS (`review/baselines/18-differential-run.log`).
- `./scripts/test.sh`: PASS. `./scripts/prove.sh` at CI's `FLYOLOGY_PROOF_LEVEL=2`: PASS.
  At the script's default level 1 two QUIC checks hit the prover time limit; that is a
  level difference, not a regression.
- The HPACK Huffman table was compared symbol by symbol against RFC 7541 Appendix B using
  the pinned `hpack` package: **all 257 symbols match**
  (`review/evidence/huffman_table_check.out`).

**A claimed server-side defect that one of these green suites would have caught is
probably wrong.** Check the relevant log before confirming one, and if you confirm it
anyway, explain in the entry why the suite does not cover it.

## Citing a standard

Quote the clause. Do not cite an RFC from memory. The RFC text is fetchable; a claim about
what another implementation does (nghttp2, Go, curl, a browser) that you cannot check
against a pinned peer or a log above must say "not verified against a peer" in the entry.

## You may raise new findings

If you trip over something the discovery reviewer missed, give it the next number in your
area and verify it the same way.

## Report

Write `review/verification-<AREA>.md`. Create it after your first verdict and append as you
go.

```markdown
# Verification: <AREA>

Commit: f078732
Findings examined: <n>. Confirmed: <n>. Refuted: <n>. Partial: <n>. Other: <n>.

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| <AREA>-1 | P0 | CONFIRMED | P1 | repro_<id> |

## <AREA>-1: <title>

- **Verdict:** CONFIRMED
- **Severity:** P1 (discovery said P0; lowered because ...)
- **Repro:** `tests/repros/src/repro_<id>.adb`, run with
  `./tests/repros/run.sh repro_<id>`
- **Output:**

```
<verbatim output, exit status line included>
```

- **Description:** one paragraph: the mechanism, the reachable path, the standard clause
  with its quoted words, and what a caller or peer observes.
```

Be honest. REFUTED is a good outcome and saves the maintainer's time. Do not soften a
spike's assertion to manufacture a reproduction.
