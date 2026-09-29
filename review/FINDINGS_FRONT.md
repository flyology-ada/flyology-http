# Flyology HTTP correctness review: findings

Commit reviewed: `f078732` on `main`, 2026-09-22.
Crates: `flyology_http` (`src/`, about 53,000 lines in 159 files), `flyology_quic`
(`flyology_quic/src/`, about 20,000 lines), `flyology_iri` (`flyology_iri/src/`, about
3,800 lines).

**Confirmed: 77. 5 P0, 32 P1, 40 P2.** Four further findings were folded into a primary as
duplicates, and two adversarial probes refuted a suspected defect class.

## Scope and method

Twelve subsystem reviews, each read-only and independent, then an adversarial verification
pass per area that tried to refute every candidate and reproduced every survivor as a
runnable program. Verification is authoritative where it disagrees with discovery: it
corrected several standard citations that were wrong or drawn from an obsoleted RFC, it
narrowed several claims, and it moved nine severities. A tenth finding was folded as a
duplicate during drafting, when two areas turned out to have reported one site.

The twelve areas: H1-SERVER, H1-CLIENT, ROUTING-MW, CLIENT-POOL, H2, H3-QPACK,
QUIC-TRANSPORT, QUIC-TLS, WEBSOCKET, SSE, IRI, LIFETIME.

Seventy-two of the 77 have a reproduction program under `tests/repros/`. The five that do
not are all P2, and each says in place why no reproduction was made. A program asserts the CORRECT behaviour, so on
current sources it prints `BUG REPRODUCED` and exits 1.

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

Documented policy values are not counted as defects unless they break a protocol rule or a
documented invariant. Those appear under each area's "Refuted and not counted".

## The previous audit, and the regression pass

This repository was audited once before. That report is `FINDGINGS_FABLE5.md`, dated
2026-08-07, 43 confirmed findings, all closed on `main`. It is not present at `main`: it
survives only on the `backup/pre-rewrite` branch, at commit `f0e8fd3`. It was recovered for
this review with `git show f0e8fd3:FINDGINGS_FABLE5.md` and is kept at
`review/prior-audit.md`.

A separate document, `proof/proof-status.md`, uses a different and older finding numbering
that predates the split of this repository from the runtime repository. The two numbering
schemes do not correspond.

**Regression pass result: no prior finding has regressed at `f078732`.** Every area
reviewer re-checked the prior findings in its own files before looking for anything new.
The `flyology_iri` crate carried eleven of the 43 and was checked finding by finding, by
reading code rather than by commit SHA, because the fixes landed as re-authored commits
that are not ancestors of HEAD.

Two items the previous audit flagged and could not settle were settled here **against** the
finding: `Must_Encode` placing `^` in the path percent-encode set, and `Encode_Opaque_Path`
handling a single trailing space, both match the pinned WPT corpus and are already covered
by the gate.

One of the previous audit's explicit coverage gaps was closed: the 257 HPACK Huffman
code and length constants were compared symbol by symbol against RFC 7541 Appendix B using
the pinned `hpack` package. **All 257 match** (`review/evidence/huffman_table_check.out`).

The previous audit also recorded that **nothing was executed except the `flyology_iri`
crate**, so its HTTP/1, HTTP/2, WebSocket and client findings rested on source reading. That
gap is closed here: every confirmed finding in those areas has a runnable reproduction.

`flyology_quic` was never covered by the previous audit at all. Eleven findings here,
including one P0, are in that crate.

## Baselines

Run from the review worktree at `f078732` before any review work, serialized, because
Alire redeploys into one shared cache.

| Suite | Result | Seconds |
| --- | --- | --- |
| `alr build` | PASS | 26 |
| `./scripts/test.sh` (includes the `flyology_iri` and `flyology_quic` suites) | PASS | 228 |
| `flyology_iri` WPT URL conformance, inside the above | 919/919, 0 mismatches | |
| `./scripts/prove.sh` at CI's `FLYOLOGY_PROOF_LEVEL=2` | PASS | 157 |
| `./scripts/prove.sh` at the script's default level 1 | 2 QUIC checks unproved | 139 |
| `./scripts/check-test-hook-elision.sh` | PASS | 159 |
| `./flyology_iri/scripts/wpt-gate-test.sh` | PASS | 2 |
| `./scripts/http2-test.sh prepare` then `all` | PASS | 394 |
| `./scripts/http2-test.sh h2spec` (h2spec 2.6.0, Docker) | PASS, 146/146 | 6 |
| `./scripts/http-client-differential.sh prepare` then `run` (PycURL) | PASS | 83 |
| `./scripts/http-client-conformance.sh` | PASS | 189 |
| `./scripts/test-http3-interop.sh all` (aioquic 1.3.0, quic-go 0.54.1, both roles) | PASS | 89 |
| `./scripts/test-http3-h3spec.sh` | PASS | 85 |
| `./scripts/test-http3-stress.sh` | PASS | 100 |
| Autobahn core, native | 240 OK, 4 NON-STRICT, 3 INFORMATIONAL, 0 failed | 127 |
| Autobahn core, lightweight | 240 OK, 4 NON-STRICT, 3 INFORMATIONAL, 0 failed | 105 |
| Autobahn limits, native | 42 OK, 0 failed | 111 |
| Autobahn compression, native | 180 OK, 36 UNIMPLEMENTED, 0 failed | 483 |
| `./scripts/check-sse-client-formal.sh` | **NOT RUN** | |

Notes on the three rows that are not a plain PASS.

- **`prove.sh` at level 1** leaves two `flyology_quic` checks unproved,
  `stream_reassembly_policy.adb:155` and `stream_table_policy.adb:231`, both reported as
  "provers reached time limit before completing the proof". CI runs the script with
  `FLYOLOGY_PROOF_LEVEL: "2"` (`.github/workflows/ci.yml:193`), where both discharge. This
  is a level difference, not a regression. It is worth noting only because the script's own
  default does not reproduce the gate CI runs.
- **Autobahn** refuses to run in a worktree with untracked files: its provenance guard
  (`scripts/websocket-run-provenance.mjs:167`) requires a clean worktree or the exact
  in-tree QUIC pin. The four profiles above were therefore run from a pristine detached
  worktree at the same commit. The full CI matrix is fourteen profiles including the `wss`
  and `performance` variants; four were run here.
- **`check-sse-client-formal.sh` could not run.** It requires a Java runtime and the
  `flyology-tla` CLI, and neither is installed on this machine (`/usr/bin/java` is the
  macOS stub). The SSE reconnect TLA+ model, its TLAPS proof and its Ada trace replay are
  therefore unexercised evidence in this review. Inspection concluded the model still sits
  on the production path after the composable rework, and the recorded source hash
  differing from the raw file hash is a normalisation rather than staleness, but that is
  reading, not a gate run.

The PycURL differential initially failed because its `prepare` step had not been run; it
passes with the environment prepared. That first failure was a harness mistake in this
review, not a defect.

## What was not exercised

- The SSE formal gate, as above.
- Ten of the fourteen Autobahn profiles, including every `wss` and `performance` variant.
- The Autobahn **client**-under-test role. The previous audit recorded that the WebSocket
  client had never been run in that role, and it still has not been. Three of the four
  WebSocket findings are client-side.
- No browser was driven. Two findings reason about browser behaviour; both say so in place
  and neither rests its severity on it.
- Peer behaviour was checked against pinned sources and pinned binaries only. Where an
  entry could not check a claim against a peer, it says "not verified against a peer".

## How to reproduce

```sh
./scripts/test.sh                      # once, to prepare build/rts
cd tests/repros
./run.sh <program> [seconds]           # one finding
./run-all.sh                           # every program, one line each
```

Exit 1 with `BUG REPRODUCED` is the expected result for a finding spike. Exit 0 is expected
for `repro_smoke`, `seam_check` and the two H1-SERVER probes. Exit 2 is expected for
`repro_lifetime_3b` and `repro_lifetime_3c`, which are negative controls that must fail to
compile. `tests/repros/README.md` has the details, including how to write a spike for a
private package.

The full sweep is recorded at `review/REPRO_SWEEP.txt`.

## Totals by area

| Area | P0 | P1 | P2 | Confirmed | Folded as duplicate | Refuted |
| --- | --- | --- | --- | --- | --- | --- |
| H2 | 2 | 4 | 5 | 11 | | |
| H3-QPACK | 2 | 7 | 5 | 14 | | |
| QUIC-TRANSPORT | 1 | 4 | 6 | 11 | | |
| H1-CLIENT | | 3 | 4 | 7 | | |
| CLIENT-POOL | | 2 | 5 | 7 | 1 | |
| QUIC-TLS | | 1 | 2 | 3 | 2 | |
| ROUTING-MW | | 2 | 3 | 5 | | |
| WEBSOCKET | | 2 | 2 | 4 | | |
| SSE | | 3 | 0 | 3 | | |
| LIFETIME | | 2 | 1 | 3 | 1 | |
| H1-SERVER | | 1 | 4 | 5 | | 2 probes |
| IRI | | 1 | 3 | 4 | | |
| **Total** | **5** | **32** | **40** | **77** | **4** | **2** |

Nine severities moved during verification, all but one upward: H1-SERVER-5, IRI-4,
LIFETIME-2, LIFETIME-3, QUIC-TLS-3, QUIC-TRANSPORT-5, ROUTING-MW-2 and WEBSOCKET-2 rose
from P2 to P1; H3-QPACK-3 fell from P0 to P1 because its trigger could not be checked
against a browser.

## The five P0 findings

- **H2-1** the client fails the connection when a server sends `SETTINGS_ENABLE_PUSH = 0`,
  which RFC 9113 section 6.5.2 expressly permits. The pinned `h2` 4.3.0 peer sends it by
  default, and both Python peers in this repository delete the setting to work around the
  rejection.
- **H2-2** the server enforces its reduced 16 KiB stream window before the peer can have
  processed the SETTINGS that announced it. Stock `curl 8.7.1` with `nghttp2 1.68.1`
  POSTing 20 KiB gets a GOAWAY.
- **H3-QPACK-1** the server returns no per-stream receive credit while a request body is
  arriving, so an HTTP/3 upload stops permanently at 15,360 body bytes.
- **H3-QPACK-2** HTTP/3 frames are buffered whole against a 16 KiB reassembly bound that no
  configuration can raise, so a DATA frame above 16,381 bytes is never consumed. quic-go
  writes one DATA frame per `Write`.
- **QUIC-TRANSPORT-1** there is no RFC 9000 section 8.1 anti-amplification accounting
  anywhere in the crate, and no enforcement of the section 14.1 minimum on a received
  Initial. Measured: a 216-byte Initial draws 2,084 bytes, 9.64 times, with the
  repository's own test certificate.

