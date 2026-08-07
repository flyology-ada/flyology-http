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
bounds.

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
