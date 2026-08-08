# Flyology QUIC

Flyology QUIC is an experimental, Ada-native QUIC transport crate. Protocol
state, packet parsing, recovery, congestion control, streams, and connection
management live in Ada. The native cryptography adapter supplies only the
standard cryptographic operations required by QUIC.

The crate lives in the Flyology HTTP repository because HTTP/3 is its first
consumer, but it is built and tested independently. Task-aware UDP sockets,
buffers, deadlines, cancellation, and runtime integration remain in Flyology.

The transport implements proved QUIC variable integers, QUIC v1
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
The bounded Ada TLS session now runs the no-PSK client and server handshake,
splits the server flight at QUIC's Initial/Handshake key boundary, validates a
pinned Ed25519 leaf, verifies both Finished messages, decodes peer transport
parameters, and derives matching directional Handshake and 1-RTT keys.
An end-to-end transport test carries those messages in protected Initial and
Handshake CRYPTO frames, including the client's required 1,200-byte Initial,
with independent packet-number and replay state at each encryption level.

After the handshake, the public connection API allocates bounded bidirectional
and unidirectional streams, protects and receives 1-RTT packets, reassembles
STREAM data, enforces peer flow-control limits, acknowledges application
traffic, and tracks RTT, loss, congestion, and PTO state. PTO probes retransmit
retained STREAM and critical control frames. The caller owns socket I/O and
uses the connection's recovery deadline to drive timer expiration.

HTTP/3 and QPACK are intentionally outside this crate. They are implemented by
`Flyology.HTTP.HTTP_3` in the parent `flyology_http` crate, which depends on
`flyology_quic` as its transport.

## Build and test

```sh
alr build
./scripts/test.sh
./scripts/prove.sh
```

The tests use published RFC 9000 and RFC 9001 vectors. The parent HTTP crate
also runs client- and server-role HTTP/3 interoperability against aioquic.
External implementations are black-box test oracles, not library dependencies.

The implementation remains bounded and experimental. It does not yet cover
the complete QUIC v1 feature set or claim production qualification.

The staged acceptance matrix is recorded in
[`tests/qualification.md`](tests/qualification.md).
