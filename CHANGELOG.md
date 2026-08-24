# Changelog

All notable changes to Flyology HTTP will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Added owner-driven complete client exchange operations for bounded buffers
  and streaming sinks, with established-child composition, monotonic admission
  certainty, absolute deadlines, and typed environmental outcomes.
- Added one executable JSON client corpus for synchronous and composable H1,
  H2, and H3 scenarios, with binary fixtures, Ada golden checks, PycURL and
  aioquic differentials, and explicit execution coverage.

### Changed

- Routed synchronous client request admission, connection setup, request
  upload, and response-head processing through the same composable H1, H2,
  and H3 engine. Owner-driven H2 and H3 streams share multiplexed sessions
  without connector or protocol-pump helper tasks.
- Kept the active development manifests at `flyology_http=0.1.1-dev` and
  `flyology_quic=0.1.1-dev`; this work creates no stable release tags.

### Fixed

- Added rolling HTTP/3 stream receive credit for complete responses larger
  than the initial QUIC stream window, including retransmission below the
  consumed receive base.
- Prevented ambiguous conditional mutations from automatic replay after
  request handoff, and preserved stream-local H2/H3 failures without failing
  unrelated multiplexed exchanges.

## [0.1.2] - 2026-08-21

### Added

- Added exact 64-bit fixed-length server response streams through the raw and
  application APIs across HTTP/1.1, HTTP/2, and HTTP/3. Known-length streams
  emit `Content-Length` without retaining the whole response, while the
  existing unknown-length API remains available. ([PR #28])

### Fixed

- Reject fixed-response overruns before transport writes, fail underruns at
  stream completion, isolate failed HTTP/2 and HTTP/3 streams, and preserve the
  declared representation length while suppressing `HEAD` response bodies.
  ([PR #28])
- Accept legal HTTP/2 `HEAD` responses that complete with an empty DATA frame
  after advertising the representation's nonzero `Content-Length`. ([PR #29])

## [0.1.1] - 2026-08-21

### Added

- Added transactional runtime router reconfiguration with atomic publication,
  stable route and middleware identities, snapshots, stale-update detection, and
  explicit reclamation of retained generations. ([PR #10], [PR #10 commits])
- Exposed the exact request authority, raw target and query, physical header
  occurrences, and completed request trailers to server applications across
  HTTP/1.1, HTTP/2, and HTTP/3. ([PR #25], [commit ca058ef])
- Extended borrowed request-body streaming and request trailers to HTTP/2 and
  HTTP/3, with bounded flow control and explicit replay rules. ([PR #25],
  [commit ca058ef])

### Changed

- Added the shared 64-bit-safe `Flyology.HTTP.Body_Size` type and carried it
  through client and server length, limit, routing, logging, and metrics APIs.
  The streaming request ceiling is now 50 TB while the HTTP/3 buffered-server
  profile retains its independent 1 MiB body cap. ([PR #24], [commit 7a4ec6c])
- Raised bounded metadata limits for S3-style requests: client request targets
  to 16 KiB, HTTP/1 request heads to 32 KiB, and QPACK field values to 16 KiB.
  ([PR #25], [commit ca058ef])
- Sealed direct router registration and setters after the first dispatch;
  running routers must use the transactional update API. ([PR #10],
  [PR #10 commits])
- Restricted the generated API reference to Flyology HTTP units, removing
  broken links and dependency-internal pages. ([PR #23], [commit 8210643])
- Published against the stable dependency set `flyology=0.1.0`,
  `flyology_cachelines=0.1.0`, and `flyology_quic=0.1.1`. ([commit dac7fa9],
  [PR #27], [commit 5638f1c])
- Automated the full SPARK proof and WebSocket qualification campaigns, made
  proof effort configurable for hosted runners, bounded network-dependent CI
  steps, and made the HTTP benchmark locate the resolved Flyology runtime.
  ([PR #9], [PR #9 commits], [PR #19], [commit 8cae2c8], [commit d99490c])

### Fixed

- Prevented server request framing, limits, byte counters, diagnostics, and
  metrics from overflowing or narrowing on multi-gigabyte bodies. ([PR #24],
  [commit 7a4ec6c])
- Hardened HTTP/2 and HTTP/3 streamed uploads against zero progress, source
  overruns and exceptions, cancellation, expired deadlines, early final
  responses, unsafe connection reuse, and backpressure wake-up races.
  ([PR #25], [commit ca058ef])
- Recovered HTTP/3 handshakes after a lost Initial or Handshake datagram by
  using QUIC probe timeouts and retransmitted CRYPTO ranges. ([PR #21],
  [commit a3866c5])
- Released HTTP/3 listener capacity promptly when a dual-stack race abandons a
  handshake or a peer goes silent, using protected handshake closes and a
  no-progress deadline. ([PR #22], [PR #22 commits])
- Kept the raw HTTP/3 integration exchange alive when a full listener discards
  an Initial datagram. ([PR #20], [commit 83db8c4])

## [0.1.0] - 2026-08-14

### Added

- Initial release.

[Unreleased]: https://github.com/flyology-ada/flyology-http/compare/flyology_http/v0.1.2...HEAD
[0.1.2]: https://github.com/flyology-ada/flyology-http/compare/flyology_http/v0.1.1...flyology_http/v0.1.2
[0.1.1]: https://github.com/flyology-ada/flyology-http/compare/flyology_http/v0.1.0...flyology_http/v0.1.1
[0.1.0]: https://github.com/flyology-ada/flyology-http/commit/398153b0cdaed1897124376682fcfba2845a3615
[PR #9]: https://github.com/flyology-ada/flyology-http/pull/9
[PR #9 commits]: https://github.com/flyology-ada/flyology-http/compare/ddbba90dba757971afb2d5fda35e884ee3813fc2...3d0df29f49b4363308f001630be181ab87cd578d
[PR #10]: https://github.com/flyology-ada/flyology-http/pull/10
[PR #10 commits]: https://github.com/flyology-ada/flyology-http/compare/d99490cf90ca3ba122741ec0e13cabc59bc8f9c0...926fed4b72ec5f940e5bd9c14c429b87bc952975
[PR #19]: https://github.com/flyology-ada/flyology-http/pull/19
[PR #20]: https://github.com/flyology-ada/flyology-http/pull/20
[PR #21]: https://github.com/flyology-ada/flyology-http/pull/21
[PR #22]: https://github.com/flyology-ada/flyology-http/pull/22
[PR #22 commits]: https://github.com/flyology-ada/flyology-http/compare/83db8c4d1da3303697c0c68d64682187bf71d93a...439a9fb6fc1dd2ba66d41dadc1996e13b0900439
[PR #23]: https://github.com/flyology-ada/flyology-http/pull/23
[PR #24]: https://github.com/flyology-ada/flyology-http/pull/24
[PR #25]: https://github.com/flyology-ada/flyology-http/pull/25
[PR #27]: https://github.com/flyology-ada/flyology-http/pull/27
[PR #28]: https://github.com/flyology-ada/flyology-http/pull/28
[PR #29]: https://github.com/flyology-ada/flyology-http/pull/29
[commit 83db8c4]: https://github.com/flyology-ada/flyology-http/commit/83db8c4d1da3303697c0c68d64682187bf71d93a
[commit a3866c5]: https://github.com/flyology-ada/flyology-http/commit/a3866c57b7aa89ea2adade894c216efe83ad65a3
[commit 7a4ec6c]: https://github.com/flyology-ada/flyology-http/commit/7a4ec6c326634ae06ad1efd94a01152bede68fba
[commit ca058ef]: https://github.com/flyology-ada/flyology-http/commit/ca058efae4b6d6799b8974ece98fdad2220122dc
[commit 8210643]: https://github.com/flyology-ada/flyology-http/commit/821064355f414a555c4a39f2d301f6093599b87d
[commit dac7fa9]: https://github.com/flyology-ada/flyology-http/commit/dac7fa90be9e9e719d78e7a607837b44dfae76a5
[commit 5638f1c]: https://github.com/flyology-ada/flyology-http/commit/5638f1c6eeba522eba4a7422edea49e43f3f1f77
[commit 8cae2c8]: https://github.com/flyology-ada/flyology-http/commit/8cae2c896e56d5e0d2adc48cba315f54e04d193d
[commit d99490c]: https://github.com/flyology-ada/flyology-http/commit/d99490cf90ca3ba122741ec0e13cabc59bc8f9c0
