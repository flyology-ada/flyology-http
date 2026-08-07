# QUIC qualification contract

Flyology QUIC uses layered oracles. Passing a lower layer does not substitute
for the next layer.

## Wire and cryptography

- RFC 9000 examples cover variable integers and packet-number reconstruction.
- RFC 8999 and RFC 9000 long-header invariants cover version dispatch,
  connection-ID boundaries, truncation, and QUIC v1 packet-type framing.
- RFC 9001 client and server Initial packets cover token and protected-length
  envelope boundaries, including coalesced packet accounting.
- RFC 9001 client and server header masks cover receive-side first-byte,
  packet-number-length, and truncated packet-number recovery.
- Boundary tests cover every variable-integer width and the maximum packet
  number gap representable by QUIC's four-byte packet-number field.
- RFC 9001 Appendix A covers both v1 Initial traffic secrets, keys, IVs,
  header-protection keys, AES-GCM output, authentication tag, and header mask.
- The complete RFC 9001 server Initial packet covers receive-side envelope
  parsing, header unprotection, packet-number reconstruction, AAD and nonce
  construction, AES-GCM authentication, and exact plaintext recovery.
- Client payload encryption and decryption use the RFC 9001 client Initial
  header, plaintext, ciphertext sample, authentication tag, and header mask.
  Tag corruption and an incorrect reconstructed packet number are rejected
  without releasing candidate plaintext; an authenticated packet with a set
  reserved bit is rejected separately as a protocol violation.
- The RFC 9001 server plaintext decodes as its exact ACK and 90-byte CRYPTO
  frames. The client plaintext decodes as its exact 241-byte CRYPTO frame and
  917-byte PADDING run. Boundary tests cover ACK/ACK_ECN range arithmetic,
  truncated frames, prohibited Initial-level types, CRYPTO offset overflow,
  and transport CONNECTION_CLOSE reason bounds.
- SPARK discharges the arithmetic, range, index, and contract checks in the
  wire-policy units.

These checks are deterministic and run in `./scripts/test.sh` and
`./scripts/prove.sh`.

## Network interoperability

Once the first complete Initial handshake exists, `scripts/interop.sh` will
run the Ada endpoint in both roles against two independent black-box peers:

- quic-go, for a separately implemented QUIC transport and HTTP/3 stack;
- aioquic, for packet-level diagnostics and scripted adverse-network cases.

The peers are test processes only. They are not linked, vendored into the
library, or used to implement protocol state. quiche and ngtcp2 are excluded
from both the library and the primary oracle matrix.

The interop lock will pin exact peer revisions and artifact hashes. The gate
will cover at least:

1. Ada client to each oracle server and each oracle client to the Ada server.
2. Version negotiation, Retry, connection-ID changes, and stateless reset.
3. Coalesced Initial and Handshake packets, reordered packets, duplicates,
   loss, PTO, and key discard.
4. Flow control, stream limits, reset/stop semantics, graceful close, and idle
   timeout.
5. Wildcard and concrete IPv4/IPv6 binds, local-address preservation,
   truncation rejection, NAT rebinding, and path validation.
6. Anti-amplification accounting, 1200-byte Initial datagrams, PMTU boundaries,
   and ECN when the platform exposes it.
7. HTTP/3 control streams, SETTINGS, QPACK blocking limits, requests,
   responses, cancellation, and malformed peer behavior.

The initial handshake milestone is not complete until both directions pass
against at least one oracle. Client/server publication is not complete until
the full two-oracle matrix passes in CI.
