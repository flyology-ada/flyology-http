# Changelog

All notable changes to Flyology QUIC will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Advanced the active development manifest to `flyology_quic=0.1.3-dev` in
  lockstep with Flyology HTTP; this work creates no stable release tag.

## [0.1.1] - 2026-08-21

### Added

- Added bounded CRYPTO-flight retention and sent-packet ledgers for the Initial
  and Handshake packet-number spaces. ([PR #21], [commit a3866c5])
- Added `Build_Handshake_Close_Datagram` and peer-close reporting so endpoints
  can close while Initial or Handshake keys are active. ([PR #22],
  [commit d7d8734])

### Changed

- Published the crate with a stable `flyology~0.1.0` dependency and validated
  it against the published Flyology 0.1.0 implementation. ([PR #26],
  [commit ffe9cb0])
- Made proof effort configurable for hosted qualification and made the nested
  test workspace generate its own Alire configuration instead of relying on a
  parent workspace side effect. ([commit 3d0df29], [commit 398153b])

### Fixed

- Implemented RFC 9002 loss detection and probe timeouts for Initial and
  Handshake traffic, including immediate ACKs, fresh packet numbers for
  retransmitted CRYPTO ranges, shared exponential backoff, and the client
  anti-deadlock probe. A lost handshake datagram no longer consumes the whole
  connection deadline. ([PR #21], [commit a3866c5])
- Accepted transport closes in the Initial and Handshake spaces and padded
  client Initial close packets to the required 1,200 bytes. ([PR #22],
  [commit d7d8734])

## [0.1.0] - 2026-08-14

### Added

- Initial release.

[Unreleased]: https://github.com/flyology-ada/flyology-http/compare/flyology_quic/v0.1.1...HEAD
[0.1.1]: https://github.com/flyology-ada/flyology-http/compare/flyology_quic/v0.1.0...flyology_quic/v0.1.1
[0.1.0]: https://github.com/flyology-ada/flyology-http/commit/6a66d23617a5bb5d86cf26087e4bc1ef97f47018
[PR #21]: https://github.com/flyology-ada/flyology-http/pull/21
[PR #22]: https://github.com/flyology-ada/flyology-http/pull/22
[PR #26]: https://github.com/flyology-ada/flyology-http/pull/26
[commit 398153b]: https://github.com/flyology-ada/flyology-http/commit/398153b0cdaed1897124376682fcfba2845a3615
[commit 3d0df29]: https://github.com/flyology-ada/flyology-http/commit/3d0df29f49b4363308f001630be181ab87cd578d
[commit d7d8734]: https://github.com/flyology-ada/flyology-http/commit/d7d87344b476f2323f167db5e4d738b0a4c7cbab
[commit a3866c5]: https://github.com/flyology-ada/flyology-http/commit/a3866c57b7aa89ea2adade894c216efe83ad65a3
[commit ffe9cb0]: https://github.com/flyology-ada/flyology-http/commit/ffe9cb00bcc6788f8556d50b7d1d01e63c6ef730
