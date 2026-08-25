# Uniform HTTP client scenario corpus

`corpus/http-client-scenarios.json` is the protocol- and API-neutral source of
behavioral expectations for the HTTP client. Each vector names its wire
fixture, applicable protocols and public API styles, terminal result,
admission certainty, and ownership-visible effects. The validator rejects
duplicate IDs, unknown dimensions, contradictory pre-admission outcomes,
nonzero failed buffer results, incomplete protocol/API coverage, unsourced
external claims, and any reduction below the maintained 67-vector floor.

`corpus/http-client-execution.json` is the execution manifest. It identifies
the exact case/protocol/API tuples driven by a maintained runner and the native
and lightweight lanes used. Every tuple not listed there is explicitly
`evidence-only`; it remains a standards-backed design vector, not an executable
qualification claim. The current manifest records 61 executable tuples and
346 evidence-only tuples. Consumer-critical lost-response, stale-reuse,
cancellation,
abandonment, blocked-source, and established-child tuples are required across
H1/H2/H3 and cannot silently fall back to evidence-only status.

The source catalog at the top of the JSON gives a stable RFC Editor or upstream
suite URL for every external evidence family. Each standard-derived vector
names an exact section. Project-only ownership and admission rules cite the
public client declaration instead, so the corpus does not attribute Flyology
policy to an RFC.

The corpus translates relevant behavior from RFC 9110–9114, the pinned
h2spec 2.6.0 and h3spec 0.1.13 error suites, curl's declarative reply-fixture
model, and llhttp's H1 parser fixtures. It does not copy upstream test bodies.
`provenance` entries identify the source that motivated each locally maintained
fixture. Flyology-only vectors cover operation ownership, absolute deadlines,
admission ambiguity, cancellation drain, source release, sink visibility, and
parent composition—properties the external wire tools cannot observe.

`fixture` is a stable symbolic scenario name, not an opaque captured packet.
Its protocol encodings are interpreted by the maintained peers:

- H1 lifecycle and ownership fixtures are in
  `http_client_composable_smoke.adb` and the existing parser corpus tests.
- H2 response, upload, reset, and multiplex fixtures are in `http2_peer.py`
  and `http2_client_integration.adb`.
- H3 response, reset, QPACK, and multiplex fixtures are in
  `oracle/aioquic_h3_server.py`, `http3_h3spec_server.adb`, and
  `http3_client_composable_smoke.adb`.
- Legal cross-implementation fixtures are in
  `http_client_differential_peer.py`, with PycURL and aioquic adapters in
  `http_client_pycurl.py` and `scripts/http-client-differential.sh`.

Where exact octets are themselves normative, `payloads` refers to a canonical
`.bin` file under `corpus/fixtures/` and records its SHA-256 digest. Adjacent
`.hex` files are review mirrors. The corpus validator checks the digest and
byte-for-byte mirror on every test run. It also rejects orphan files and any
reduction below the maintained 20-payload floor. The H1 Ada parser adapter,
H2 scripted peer, and H3 QPACK adapter consume these files directly.
The remaining symbolic cases intentionally have no invented binary capture; a
`.bin` exists only when exact octets are part of the oracle.

Keeping stateful wire construction beside the protocol peer makes frame
ordering and fault injection reviewable as code, while byte-exact fragments
remain reusable data and the JSON remains the one golden semantic oracle
shared by synchronous and composable Ada adapters.

Legal vectors marked with `differential` are also executed over the listed
protocols. Pinned PycURL 7.46.0 easy and multi handles provide the independent
H1/H2 implementation, while pinned aioquic 1.3.0 provides an independent H3
peer because the pinned libcurl build has no HTTP/3 backend. The differential
compares normalized status, selected protocol, body octets, corpus-owned
headers and trailers, and the independent peer transcript with synchronous Ada
and both composable owner models. These external implementations are corroborating
evidence, not the golden oracle for malformed framing or Flyology-specific
ownership and admission state.

Adapters may filter the corpus with:

```sh
python3 tests/http_client_corpus.py \
  tests/corpus/http-client-scenarios.json \
  --execution tests/corpus/http-client-execution.json \
  --protocol h2 --api composable-buffer
```

The pinned h2spec server suite qualifies the H2 server, and pinned h2specd runs
57 client tests against both synchronous and composable Ada entry points in both
owner models. Upstream h3spec is server-oriented, so it qualifies the H3 server
only. H3 client behavior is instead checked with the independent aioquic peer,
deterministic QPACK/field-section adapters, and composable wire scenarios. A vector
is not considered covered merely because a server-side tool or codec component
passed; its public API/protocol/lane tuple must appear in the execution
manifest.

Run the current legal H1/H2/H3 differential with:

```sh
./scripts/http-client-differential.sh prepare
./scripts/http-client-differential.sh run
```
