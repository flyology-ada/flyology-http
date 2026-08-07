# Flyology QUIC

Flyology QUIC is an experimental, Ada-native QUIC transport crate. Protocol
state, packet parsing, recovery, congestion control, streams, and connection
management live in Ada. The native cryptography adapter supplies only the
standard cryptographic operations required by QUIC.

The crate lives in the Flyology HTTP repository because HTTP/3 is its first
consumer, but it is built and tested independently. Task-aware UDP sockets,
buffers, deadlines, cancellation, and runtime integration remain in Flyology.

The current foundation implements proved QUIC variable integers, QUIC v1
long-header invariant and Initial packet envelope parsing, packet-number
selection and reconstruction, nonce and header-protection policy, and the
QUIC v1 Initial key schedule and packet protection using OpenSSL 3. The
bounded Initial receive path parses the envelope, removes header protection,
reconstructs the packet number, and releases plaintext only after AES-GCM
authentication and reserved-bit validation. A proved, allocation-free frame
cursor validates Initial-level PADDING, PING, ACK/ACK_ECN, CRYPTO, and transport
CONNECTION_CLOSE frames and reports borrowed payload bounds. A proved 64 KiB
CRYPTO buffer reassembles out-of-order handshake fragments, accepts matching
retransmissions, and rejects conflicting overlaps atomically. The Initial
transmit path encodes packet envelopes and packet numbers, applies AES-GCM and
header protection, and supports token-bearing packets and arbitrary Ada array
bounds. Initial client/server state derives directional keys, reserves packet
numbers only after successful construction, suppresses authenticated replays
through a proved 256-packet window, and exchanges datagrams through Flyology's
portable UDP sockets.
The native primitive boundary also supplies cryptographic randomness, SHA-256,
HMAC-SHA256, X25519, and Ed25519 signing and verification for the Ada TLS 1.3
handshake state. Certificate public-key extraction accepts bounded DER input;
trust and endpoint-identity policy remain outside the primitive adapter.
The Ada key schedule derives no-PSK TLS 1.3 handshake, Finished, application,
exporter, and resumption secrets together with QUIC traffic keys and updates.
A proved bounded wire policy parses and encodes TLS 1.3 Certificate,
CertificateVerify, and SHA-256 Finished messages without owning certificate or
signature payloads.
A proved builder constructs the role-separated TLS 1.3 CertificateVerify input
from the Ada-owned transcript hash.

## Build and test

```sh
alr build
./scripts/test.sh
./scripts/prove.sh
```

The tests use published RFC 9000 and RFC 9001 vectors. Network interoperability
qualification will use external QUIC implementations as black-box peers; they
are test oracles, not library dependencies.

The staged acceptance matrix is recorded in
[`tests/qualification.md`](tests/qualification.md).
