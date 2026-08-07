# QUIC qualification contract

Flyology QUIC uses layered oracles. Passing a lower layer does not substitute
for the next layer.

## Wire and cryptography

- RFC 9000 examples cover variable integers and packet-number reconstruction.
- RFC 8999 and RFC 9000 long-header invariants cover version dispatch,
  connection-ID boundaries, truncation, and QUIC v1 packet-type framing.
- Boundary tests cover every variable-integer width and the maximum packet
  number gap representable by QUIC's four-byte packet-number field.
- RFC 9001 Appendix A covers both v1 Initial traffic secrets, keys, IVs,
  header-protection keys, AES-GCM output, authentication tag, and header mask.
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
