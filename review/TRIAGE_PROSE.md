# Flyology HTTP issue triage: {{ISSUE_RANGE}}

77 confirmed findings from a correctness review of `flyology_http`, `flyology_quic` and
`flyology_iri` at commit `f078732`: 5 P0, 32 P1, 40 P2. Every issue is self-contained and
carries a runtime reproduction, except five P2 items that say in place why no reproduction
was made.

## Ground rules for every fix

- Read `AGENTS.md` first, in particular its sections "Flyology HTTP agent guide",
  "Decision authority", "Ada interface values", "Ada source style", "Review cycle",
  "Commits", "Performance testing", "Grounded communication" and "TLA+ assurance". They are
  the contract you are fixing against. After creating a worktree run `apm install --frozen`
  and `apm compile --target codex`, as the "Repository workflow" section requires, so
  `AGENTS.md` is current. Run `git status --short --branch` before changing anything.
- One issue per branch and per pull request, unless an entry below says two issues share a
  fix. Problem/Solution commit messages as the "Commits" section defines them, one problem
  per commit, no attribution footers. Reference the issue with `Closes #N`.
- Every fix needs a regression test that fails before and passes after. Every issue carries
  the spike that reproduced the defect. Turn that spike into a test in the suite it belongs
  to rather than inventing a new file:
  - `tests/http_server_audit.adb`, `tests/http_smoke.adb`, `tests/http_operations_smoke.adb`
    for HTTP/1 server cases over the in-memory transport.
  - `tests/http_routing_audit.adb` for routing, middleware, CORS, rate limits and metrics.
  - `tests/http2_server_audit.adb`, `tests/http2_server_integration.adb`,
    `tests/http2_client_integration.adb` and the `flyology-http-http_2_*-smoke.adb` units
    for HTTP/2.
  - `tests/http3_server_integration.adb`, `tests/http3_public_smoke.adb`,
    `tests/http3_client_composable_smoke.adb` and the `flyology-http-http_3_*-smoke.adb` and
    `flyology-http-qpack_*-smoke.adb` units for HTTP/3 and QPACK.
  - `flyology_quic/tests/` for the transport and TLS crate.
  - `tests/http_client_audit.adb`, `tests/http_client_parser_matrix.adb`,
    `tests/http_client_rfc_corpus.adb`, `tests/http_client_pool_model.adb`,
    `tests/http_client_pool_races.adb`, `tests/http_client_redirects.adb`,
    `tests/http_client_deadline_matrix.adb` for the client and the pool. A client parser case
    also belongs in the JSON corpus under `tests/corpus/` when it is expressible there.
  - `tests/websocket_server_audit.adb` and `tests/websocket_client_smoke.adb` for WebSocket.
  - `tests/http1_sse_client_integration.adb` for SSE.
  - `flyology_iri/tests/src/flyology_iri_tests.adb` for the IRI crate.
- Verification by area. Run the suites the change can affect, not all of them.
  - Any `src/` change: `./scripts/test.sh`. This is the gate; it also runs the
    `flyology_iri` and `flyology_quic` suites and the "no tasks in client units" check.
  - A change inside a unit `./scripts/prove.sh` proves: `./scripts/prove.sh` with
    `FLYOLOGY_PROOF_LEVEL=2`, which is what CI runs (`.github/workflows/ci.yml:193`). The
    script's own default is level 1, where two `flyology_quic` checks hit the prover time
    limit; use level 2 or you will chase a phantom. A change there is not done until
    GNATprove reports no unproved checks with `--checks-as-errors=on`.
  - HTTP/2: `./scripts/http2-test.sh all`, and `./scripts/http2-test.sh h2spec` where Docker
    is available. Note that h2spec 2.6.0 marks a test passed on connection close BEFORE
    comparing the GOAWAY code (`spec/verifier.go:53-92`), so a green h2spec run does not
    vouch for an error code; two issues below turn on exactly that.
  - HTTP/3 and QUIC: `./scripts/test-http3-interop.sh all`,
    `./scripts/test-http3-h3spec.sh`, `./scripts/test-http3-stress.sh`, plus
    `flyology_quic/scripts/test.sh` and `flyology_quic/scripts/prove.sh` for the transport
    crate. The QUIC test script refuses the default runtime and needs the one
    `./scripts/test.sh` prepares under `build/rts`, passed as `FLYOLOGY_QUIC_TEST_RTS`.
  - Client: `./scripts/http-client-differential.sh prepare` then `run` (Ada versus PycURL),
    and `./scripts/http-client-conformance.sh`.
  - Anything touching the SSE lifecycle: `./scripts/check-sse-client-formal.sh`. It needs a
    Java runtime and the `flyology-tla` CLI, and it could NOT be run during this review, so
    treat it as unverified ground until someone runs it.
  - WebSocket: `./scripts/websocket-conformance.sh <profile> <lane>` for the profiles under
    `tests/autobahn/`. The run refuses a dirty worktree; commit or stash first, or run from
    a clean worktree at the same commit.
  - IRI: `flyology_iri/scripts/test.sh` with `ADA_URL_ROOT` pointing at the pinned WPT
    corpus (ada-url/ada `32dabc8d`), and `flyology_iri/scripts/wpt-gate-test.sh`.
  - Anything touching the test hooks: `./scripts/check-test-hook-elision.sh`.
  - Public specification or API-documentation changes: `./scripts/docs.sh`, which must
    generate `docs/api/index.html` without errors.
  - Always: `git diff --check` and the maintained formatter project on touched handwritten
    Ada. Never hand-edit generated Ada; the only generated sources here are the SSE
    conformance adapter under `formal/sse_client/ada/generated`.
- Alire redeploys into one shared cache on every command, so two `alr` invocations must
  never run concurrently across lanes. The suites bind fixed loopback ports and start
  Python peers, so suite runs must be serialized too. Any new probe binds an ephemeral port.
- Do not widen scope. An issue that asks for a one-line guard gets a one-line guard.
- Items tagged **DECISION** need a maintainer choice before implementation. Ask; do not
  guess. Under "Decision authority" and "Ada interface values", authorization to fix a
  defect does not authorize a new public constant, default, capacity, timeout, retry count,
  buffer bound, variant or parameter.
- Items tagged **MODEL FIRST** get their model or contract before their code change. See
  the section below.

## Confirm every finding before fixing it

The issues were written by a reviewer, not by the maintainer. Each one was reproduced on
macOS 26.6.2 arm64 with GNAT via Alire. Before you change code:

1. Re-read the cited code at current `main`. Line numbers drift.
2. Rebuild and run the spike the issue quotes. If it no longer reproduces, say so on the
   issue and stop; do not fix what is already fixed, and do not weaken the spike to make it
   reproduce.
3. Where the issue rests on what another implementation does, drive the real peer if a
   maintained script provides one. Several issues say "not verified against a peer" in
   place; those claims are reading, and if driving the peer contradicts the issue, that is
   a finding of its own and goes back to the master task.
4. Peer claims that WERE established: the pinned `h2` 4.3.0 peer sends
   `SETTINGS_ENABLE_PUSH = 0`; stock curl 8.7.1 with nghttp2 1.68.1 gets a GOAWAY on a
   20 KiB HTTP/2 POST; `golang.org/x/net@v0.57.0/http2/server.go:1218-1235` sends
   `RST_STREAM(NO_ERROR)` after a response; quic-go 0.54.1 frames one DATA frame per
   `Write` and does send STOP_SENDING in ordinary use. Those are quoted with file:line in
   the issues that use them.
5. Two issues reason about browser behaviour. No browser was driven in this review. Neither
   rests its severity on the browser claim, and neither should be fixed on that basis alone.

## Work organization: one master task, lanes of at most three

- One master task owns the queue, the layer order and every DECISION. Lanes do not talk to
  each other; they report to the master after every merged pull request.
- At most three lanes at a time, each in its own git worktree. More than three contend on
  the shared Alire cache and on loopback ports, and the wall-clock gain disappears.
- Serialize every `alr` command and every suite run across lanes. A lane that needs the
  Docker peers (h2spec, Autobahn) takes them exclusively.
- A lane that hits a DECISION stops on that issue and moves to the next one in its layer.
  It does not choose a value, a default or a public name.
- A lane that finds an issue wrong reports it to the master rather than closing it.

## Model first: contracts and models where they pay for themselves

This is the "TLA+ assurance" section of `AGENTS.md` applied to this queue.

- **Inside the proved policy boundary**, the fix is the contract. The units
  `./scripts/prove.sh` proves are listed in that script; several findings sit in the
  unproved code that consumes a proved classifier, and for those the right move is often to
  widen the classifier's postcondition so the consuming code cannot get it wrong, rather
  than to add another check in the consumer. Note that two units a reviewer assumed were
  proved are not: `flyology-http-sse_client_policy` has no `SPARK_Mode` and is absent from
  `scripts/prove.sh`. Check the script rather than assuming.
- **The existing SSE model** in `formal/sse_client/` covers the reconnect lifecycle and its
  adapter wraps `SSE_Client_Policy` one to one. The SSE cancellation finding touches the
  wait state that model describes, so extend the model and its trace rather than only
  patching the Ada. Its gate could not be run in this review, so the first lane to touch it
  should run `./scripts/check-sse-client-formal.sh` and report whether it is green before
  changing anything.
- **New bounded TLA+ models**, each with a `_broken` configuration that must fail, for the
  three multi-step state machines this queue keeps tripping over:
  1. **HTTP/2 stream state and flow control together.** Six findings are about the
     interaction, not either half: the window announced before the peer can have read the
     SETTINGS, a stream completed early leaving input uncredited, a cancel mid field
     section pinning the pump, and a reset stream's window accounting. A model whose state
     is (stream state, connection window, stream window, pending field section) and whose
     invariant is that a conforming peer is never failed would have caught them as a class.
  2. **The client pool lease lifecycle.** Admission, release, stale retry, replay
     eligibility and finalization, with the invariant that every lease is released exactly
     once and that a replayed request never sends a partly consumed body. Three findings
     live there, including the silent double POST.
  3. **QUIC recovery and packet-space transitions.** The sent-packet ledger, the congestion
     window, the PTO path and key discard, with the invariants that a full ledger never
     escalates to a connection error and that Initial keys are unusable after the handshake
     completes. Three findings live there.
  Run TLC and TLAPM both, and replay the traces through the shared `flyology-ada/tla`
  harness, as the "TLA+ assurance" section requires.
- **Do not model** the single-site fixes: a wrong error code, a missing `Vary` header, a
  citation correction. A model there costs more than it returns.

## Layer order

The layers below put the surfaces a hostile peer reaches first. Within each layer, P0
before P1 before P2.

One caveat the master should weigh before starting: **all five P0 findings sit in layers 2
and 3**, not in layer 1. A queue optimised for severity rather than for attack surface
would run layers 2 and 3 first. The order below is the proposal; the master decides.

