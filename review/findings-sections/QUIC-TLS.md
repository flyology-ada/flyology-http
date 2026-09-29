## QUIC-TLS

This area covers the TLS 1.3 handshake the QUIC crate implements in Ada: `TLS_Session`,
`TLS_Key_Schedule`, `TLS_Handshake_Policy`, `TLS_Extension_Policy`,
`TLS_Signature_Policy`, `TLS_Authentication_Policy`, `Crypto_Flight`,
`Crypto_Reassembly_Policy`, the OpenSSL binding `Crypto_OpenSSL` and its C bridge
`flyology_quic_openssl.c`, the parent crate's `Server.TLS` adapter and
`Server.Development_Certificates`, plus the parts of `Connection_Driver`,
`Application_Space`, `Initial_Space` and `Connections` that hold keys or map a TLS
status to a wire error code. Five entries came out of discovery; one is a duplicate of a
QUIC transport entry and is not filed, three are confirmed as written, and one is
confirmed in its code path but not in the peer breadth its discovery entry claimed. One
severity was raised. The single most important result in this area is not a finding: the
certificate-pinning path was attacked deliberately and held, including the man-in-the-middle
that replays the public pinned DER under a foreign key.

### QUIC-TLS-1: Initial keys are never discarded

- **Severity:** DUP, folded into `QUIC-TRANSPORT-3` and not filed. Discovery rated it P1
  in this area; the QUIC transport verifier owns the primary entry and the spike
  (`flyology-quic-connection_driver-repro_quic_transport_3`), and the filed issue is
  QUIC-TRANSPORT-3's.
- **Location:** `flyology_quic/src/flyology-quic-connection_driver.adb:1382-1409` and
  `:906-911`, `flyology_quic/src/flyology-quic-initial_space.adb:504-510`, routed from
  `src/flyology-http-server-http_3.adb:112-123`. The two entries cite the same lines.
- **Repro:** owned by QUIC-TRANSPORT; no second spike was written.
- **What is wrong:** `Scan_Datagram` dispatches long-header Initial packets in every
  connection state, `Process_Initial_Packet` acts on `Processed.Peer_Closed` before it
  reaches its state check, `Initial_Space.State` carries no "keys discarded" flag, and
  `Acknowledge_Flight` only stops retransmission. An observer of the client's first
  Initial can therefore compute the Initial keys and close an established connection in
  either role.
- **Notes:** the discovery entry's quotation of RFC 9001 section 4.9.1 is a paraphrase,
  not the RFC's wording: the sentence "packets protected with Initial keys received after
  this point are discarded" does not appear there. What section 4.9.1 says is that a
  client MUST discard Initial keys when it first sends a Handshake packet, that a server
  MUST discard them when it first successfully processes one, and that endpoints MUST NOT
  send Initial packets after that point; the security reason is given in the same section,
  that Initial-protected packets are not authenticated. QUIC-TRANSPORT-3's filed body
  should carry the corrected citation.

### QUIC-TLS-2: Client aborts on post-handshake CRYPTO that is not one whole NewSessionTicket at offset 0

**Folded into QUIC-TRANSPORT-4 and not filed separately.** The QUIC transport reviewer
found the same site independently. One issue is filed under the QUIC-TRANSPORT number,
and it carries this entry's body, which is the stronger of the two: it establishes that
the multiple-ticket shapes are narrower than they look for this client, because the
ClientHello advertises no `psk_key_exchange_modes` and a server honouring RFC 8446
section 4.2.9 therefore sends it no ticket at all. The reachability that survives that
gate is the split ticket. The detail below is retained for the record.

- **Severity:** P1 (discovery said P1; kept, with the peer-breadth claim withdrawn and the
  residual reachability restated)
- **Location:** `flyology_quic/src/flyology-quic-application_space.adb:1333-1349`, mapped
  at `flyology_quic/src/flyology-quic-connection_driver.adb:580` and closed at `:1328-1332`
  and `:606-608`
- **Repro:** `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_tls_2`
  (exit 1, BUG REPRODUCED, checks: 7 failures: 6), re-run at drafting time
- **What is wrong:** a 1-RTT CRYPTO frame is accepted only when `Crypto_Offset = 0`, the
  first body byte is handshake type 4, and the message's own three-byte length equals
  `Data_Length - 4`. There is no 1-RTT CRYPTO reassembly at all. Anything else is
  `Unexpected_TLS_Message`, which becomes CRYPTO_ERROR 0x10A and a CONNECTION_CLOSE, so a
  handshake that has just succeeded is destroyed. The spike reproduces it in three shapes:
  two tickets in one frame, a second ticket at offset 4, and one ticket split across two
  frames. All three leave the client `FAILED` after a `CONNECTED` handshake, and the
  accepted shape is kept as a passing control.
- **Notes:** the discovery entry's peer-breadth claim, that stock OpenSSL, quictls and
  BoringSSL servers trigger this by default because they send two tickets, does **not**
  hold as written, and the filed body says so in the same sentence as the claim. This
  client never advertises `psk_key_exchange_modes`
  (`flyology-quic-tls_extension_policy.adb:480-531` emits six extensions, none of them 45),
  and RFC 8446 section 4.2.9 says servers SHOULD NOT send NewSessionTicket incompatible
  with the advertised modes. Go 1.23.4 and aioquic 1.3.0 both implement that gate, verified
  by reading the pinned sources (`crypto/tls/handshake_server_tls13.go:829-845`,
  `aioquic/tls.py:1838-1841`); OpenSSL's behaviour is unverified, because no OpenSSL QUIC
  server is available on this host and no OpenSSL source tree is present. quic-go passes
  interop because it sends exactly one ticket at offset 0, which is the accepted case, and
  because Go's QUIC path bypasses the psk-mode gate; aioquic's oracle sends none. The
  residual reachability that depends on none of this is the SPLIT ticket, and the filed
  body's Severity leads with it. The same defect is `QUIC-TRANSPORT-4`, which is being
  filed separately by that area; both bodies should cross-reference, and the coordinator
  should decide whether to keep two issues for one code path.
- **Fix decision:** a reassembly buffer introduces a capacity, which is a maintainer
  decision under "Decision authority" and "Ada interface values"; the filed body lists the
  options and does not choose.

### QUIC-TLS-3: Handshake, master, exporter and traffic secrets are never wiped on the success path

- **Severity:** **P1** (discovery said P2; raised)
- **Location:** `flyology_quic/src/flyology-quic-tls_session.adb:789-791` (client) and
  `:850-853` (server), against `Mark_Failed` at `:33-46`;
  `flyology_quic/src/flyology-quic-tls_session.ads:148-175`;
  `flyology_quic/src/flyology-quic-connections.adb:29-30` and `:48-56`
- **Repro:** `./tests/repros/run.sh flyology-quic-tls_session-repro_quic_tls_3`
  (exit 1, BUG REPRODUCED, checks: 15 failures: 15), re-run at drafting time
- **What is wrong:** the success transitions clear only `X25519_Private`, the server's
  `Signing_Key` and a local `Resumption` temporary. All six fields of
  `Handshake_Secrets` and the `Application_Secrets.Exporter` survive on both roles at
  `Connected`, although their last consumers have already run and `TLS_Key_Schedule`
  exports a `Clear` for each. `Connections.Finalize` then releases the whole
  implementation block with `Unchecked_Deallocation` and nothing overwrites it.
- **Notes:** the raise from P2 to P1 rests on two things the discovery entry treated as
  hypothetical. First, the spike does not assume post-free exposure, it demonstrates it:
  it allocates the `Session` on the heap, records the master secret, releases it, and
  recovers the same 32 bytes from a freshly allocated block of the same size. That is an
  ordinary read of uninitialized storage the program owns, not a read of freed memory and
  not undefined behaviour. Second, and the stronger argument in the filed body, the crate
  already keeps this discipline: `Mark_Failed` clears every secret on the failure path, so
  the success path contradicts an internal contract the code holds elsewhere. It is still
  not P0: no remote peer can trigger or observe it and there is no memory-safety error.
  RFC 8446 mandates no erasure; RFC 9001 section 4.9 is directional only.
- **Fix decision:** the `Connected` half needs no decision. The finalization half does,
  because every option changes something declared in a specification (a controlled
  `Session`, a new `TLS_Session` wipe operation, or a block wipe in `Connections.Finalize`).
  The filed body lists the options and does not choose.

### QUIC-TLS-4: Server matches only the first ALPN entry of the ClientHello

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_quic/src/flyology-quic-tls_extension_policy.adb:220-224`,
  consumed at `flyology_quic/src/flyology-quic-tls_session.adb:180-189`, sent as 0x178 at
  `flyology_quic/src/flyology-quic-connection_driver.adb:945-951`
- **Repro:** `./tests/repros/run.sh flyology-quic-tls_session-repro_quic_tls_4`
  (exit 1, BUG REPRODUCED, checks: 2 failures: 1), re-run at drafting time
- **What is wrong:** `Parse_ALPN` walks the whole list but records only the first entry,
  and `Validate_Extensions` compares that one entry with the configured protocol. A client
  offering `["h3-29", "h3"]` to an `h3` server is refused with `ALPN_Mismatch` and closed
  with 0x178, although a mutually supported protocol was advertised. The spike patches the
  real ClientHello's ALPN body to the two-entry list and repairs both length fields; its
  control shows the same server accepts the unpatched single-entry Hello.
- **Notes:** the discovery entry's quotation of RFC 7301 section 3.2, "the server SHALL
  select a protocol from the list", is **wrong**. The RFC says the server "SHOULD select
  the most highly preferred protocol that it supports and that is also advertised by the
  client", and the SHALL applies to the `no_application_protocol` alert, whose trigger
  condition (the server supports none of the advertised protocols) is not met here. The
  filed body carries the corrected text and makes the point that the mandatory clause is
  being misapplied rather than the selection rule being violated. P2 stands because
  mainstream QUIC clients offer `h3` alone.
- **Proof:** `flyology-quic-tls_extension_policy.adb` is one of the units
  `./scripts/prove.sh` proves, through `flyology_quic/scripts/prove.sh`. The proof covers
  bounds and offsets, not which entry is reported, so it does not contradict the finding,
  but any fix must keep it discharging with `--checks-as-errors=on`. The filed body says so.
- **Fix decision:** recording more than one entry introduces a bound on `Parse_Result`,
  which is declared in a specification, and a preference-order policy. Both are maintainer
  decisions; the filed body lists the options, names a third route that needs neither
  (record the entry the caller asks for), and does not choose.

### QUIC-TLS-5: TLS failures close with internal_error (0x150) instead of the required alerts

- **Severity:** P2 (discovery said P2; kept)
- **Location:** `flyology_quic/src/flyology-quic-connection_driver.adb:1108-1115`,
  `:945-951` and `:1160-1162`; the ALPN sub-claim's root cause at
  `flyology_quic/src/flyology-quic-tls_handshake_policy.ads:21-26` against
  `flyology-quic-tls_extension_policy.ads:19-26`, collapsed at
  `flyology-quic-tls_handshake_policy.adb:141` and `:227` and passed through at
  `flyology-quic-tls_session.adb:297-299`, `:521-522`, `:598-599`
- **Repro:** `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_tls_5`
  (exit 1, BUG REPRODUCED, checks: 6 failures: 2), re-run at drafting time
- **What is wrong:** `Certificate_Mismatch`, `Signature_Failed` and `Finished_Failed` all
  fall into a `when others => 16#150#` arm, so a peer-caused authentication failure is
  reported as `internal_error(80)`, which RFC 8446 section 6.2 defines as an error
  "unrelated to the peer or the correctness of the protocol". The required codes are 0x12A
  (`bad_certificate`) and 0x133 (`decrypt_error`, a MUST in RFC 8446 section 4.4.3 and
  section 4.4.4). The spike reads the code from the wire rather than decoding it by hand:
  it delivers the client's CONNECTION_CLOSE back to the live server driver, which decrypts
  it with its own Handshake keys, and reads `Peer_Close_Error`. Both cases report 336,
  which is 0x150.
- **Notes:** RFC 9001 section 4.8 does allow a generic substitute ("replacing any alert
  with a generic alert, such as handshake_failure (0x0128 in QUIC)"), but 0x150 is not a
  generic code, it is a specific and actively misleading one. The missing-ALPN sub-claim
  (0x16D where RFC 9001 section 8.1 requires 0x178) is confirmed by reading only and is
  **not reproduced**; the filed body says so in the Problem section and again in Severity.
  The four `ok` lines in the spike are load-bearing: they show the authentication decisions
  themselves are correct and only the reported reason is wrong.
- **Proof:** the ALPN half's fix lands in `flyology-quic-tls_handshake_policy.adb` and
  `flyology-quic-tls_extension_policy.adb`, both proved by `./scripts/prove.sh`. The
  driver itself is outside the proved set. The filed body names both.
- **Fix decision:** distinguishing a missing required extension from an invalid one means
  a new literal in `TLS_Handshake_Policy.Parse_Status`, declared in a specification. That
  is a maintainer decision; the filed body lists the options and does not choose. The
  error-code arms themselves need no decision, because the values are fixed by RFC 8446
  and the RFC 9001 section 4.8 mapping.

### Coverage evidence

Read in full: `flyology-quic-tls_session.adb`/`.ads`, `flyology-quic-tls_key_schedule.adb`/`.ads`,
`flyology-quic-tls_handshake_policy.adb`/`.ads`, `flyology-quic-tls_extension_policy.adb`/`.ads`,
`flyology-quic-tls_signature_policy.adb`/`.ads`, `flyology-quic-tls_authentication_policy.adb`/`.ads`,
`flyology-quic-crypto_openssl.adb`/`.ads`, `flyology-quic-crypto_flight.adb`/`.ads`,
`flyology-quic-crypto_reassembly_policy.adb`/`.ads`, `src/native/flyology_quic_openssl.c`,
`src/flyology-http-server-tls.adb`/`.ads` and `src/flyology-http-server-development_certificates.adb`/`.ads`.
Read in part, to trace callers and key lifetime: `connection_driver.adb` (640-1470),
`application_space.adb` (1300-1400), `application_connection.adb`, `initial_space.adb`
(420-520), `handshake_connection.adb`, `connections.ads`/`.adb`, and
`src/flyology-http-server-http_3.adb`. Tests read: `flyology_quic/tests/qualification.md`,
`flyology-quic-tls_session-smoke.adb`, `flyology-quic-tls_transport_smoke.adb`,
`flyology-quic-tls_extension_policy-smoke.adb`, `tests/oracle/quic-go/main.go`,
`tests/oracle/aioquic_h3_server.py`, `tests/development_certificates_smoke.adb`.

Executed: four spikes, all re-run at drafting time against commit `f078732`, all
BUG REPRODUCED with exit 1. Peer sources read at their pinned revisions on this host:
quic-go 0.54.1 (`internal/handshake/crypto_setup.go`, `internal/protocol/params.go`),
Go 1.23.4 `crypto/tls/handshake_server_tls13.go`, aioquic 1.3.0 `tls.py` from the oracle
virtual environment, and OpenSSL 3.6.3's installed `SSL_CTX_set_num_tickets` manual page.
`review/baselines/10-http3-interop.log` records PASS against quic-go 0.54.1 and aioquic
1.3.0 in both roles; the QUIC-TLS-2 entry explains why that green run does not contradict
the finding.

**Certificate pinning: a negative result, and the strongest one in this area.** The
discovery reviewer concluded the pinning path was sound. That conclusion was attacked and
it held. Four things were established by reading the code and then by execution.

1. *One supplier, one production caller.* `Connections.Initialize_Client`
   (`flyology_quic/src/flyology-quic-connections.ads:213-252`) is the only public entry,
   and in the whole HTTP crate it has exactly one production caller,
   `src/flyology-http-client.adb:3274-3278` inside `Start_HTTP_3_Connection`, which passes
   `Flyology.Bytes.To_Array (Owner.HTTP_3_Certificate)`. That field is written in exactly
   two places, the two `Configure` overloads that take `HTTP_3_Certificate_DER`.
2. *No empty or unset pin is reachable, with or without assertions.* Both certificate
   overloads validate the argument with an ordinary `if`/`raise Program_Error`
   (`src/flyology-http-client.adb:2443-2445` and `:2485-2487`, "HTTP/3 pinned certificate
   must contain 1 through 4096 bytes"), and both overloads that do **not** take a
   certificate reject HTTP/3 modes outright (`:2298-2300` and `:2402-2404`, "HTTP/3
   requires a pinned certificate Configure overload"). These are statements, not
   preconditions, so they hold with assertions disabled, unlike the
   `Pinned_Certificate'Length in 1 .. 4_096` preconditions further down the stack. Even
   with an empty pin the path stays fail-closed: the length check at
   `tls_session.adb:635-639` would demand a zero-length certificate entry,
   `Ed25519_Verify_Certificate` sets `Verified := False` first
   (`crypto_openssl.adb:572`), and the C bridge rejects a DER buffer it cannot fully parse.
3. *No path ignores the comparison result.* `Accept_Server_Authentication` is a straight
   line of early returns each calling `Mark_Failed`; the driver assigns
   `Item.Current := Connected` only after `TLS_Result.Status = Succeeded`
   (`connection_driver.adb:1105-1136`); and `Operation_Result.Status` defaults to
   `Invalid_State`, so an unwritten status is never read as success.
4. *The attack that matters was run and defeated.* The pinned DER is public, so the
   realistic attack is a man in the middle replaying the pinned certificate under its own
   key. `repro_quic_tls_5` case 2 does exactly that: the server is initialized with the
   genuine certificate and a different Ed25519 seed, and the client ends in `Failed`.
   Case 1 covers a pin differing by one byte of the subjectPublicKey, also `Failed`.
   Verification runs against `Item.Certificate`, the pinned bytes, not the received copy
   (`tls_session.adb:696-703`), so a replayed certificate gains the attacker nothing. The
   four `ok` lines in that spike's output are the evidence.

Chain building, name and wildcard matching, IP SANs and expiry remain absent. They are
outside the stated contract (`tls_session.ads:6-10`, `connections.ads:212-218`), which is
exact-DER pinning of an Ed25519 leaf, so their absence is a documented limitation of the
first authentication profile and is not counted as a defect.

Could not be exercised: whether an OpenSSL-based QUIC server applies the RFC 8446
section 4.2.9 psk-mode gate. `openssl s_server` in 3.6.3 on this host has no `-quic`
option and no OpenSSL source tree is present. What would settle it is a run against an
ngtcp2 or nginx-quic server with default ticket settings, observing whether it sends
NewSessionTicket to a ClientHello carrying no `psk_key_exchange_modes`. The BoringSSL
`kNumTickets = 2` claim in the discovery entry is likewise unverified and was dropped.

### Refuted and not counted

- **Certificate pinning.** Attacked as described above and upheld. No finding.
- **Finished verification.** Computed over the correct transcript prefixes (server Finished
  over ClientHello through CertificateVerify, client Finished over ClientHello through
  server Finished) and compared with a constant-time `Secure_Equal`; a mismatch marks the
  session `Failed` and clears every secret, which `tls_session-smoke.adb:215-218` asserts.
- **Key schedule.** HKDF-Expand-Label info layout, the Early/Derived/Handshake/Master
  extraction chain, every label, and the QUIC labels with the header-protection key
  retained across updates all match RFC 8446 section 7.1 and RFC 9001 sections 5.1 and 6.1.
  Every temporary is cleared on normal and on exception exit. The RFC 8448 trace test is
  recorded in `qualification.md:28-31`.
- **Initial secrets.** Salt and labels per RFC 9001 section 5.2, read in the C bridge.
- **Hello parsing and extension policy.** Legacy version, the single required cipher suite,
  compression bytes, session-id echo, unknown extensions ignored, duplicates rejected,
  per-context extension permissions, and the exactly-one-ALPN-entry rule in
  EncryptedExtensions are all correct. HelloRetryRequest cannot be mistaken for a
  ServerHello, and 0-RTT packets are dropped as `Unsupported_Packet`.
- **State machine and signature algorithms.** Every `Accept_*` checks its state first and
  returns `Invalid_State` without mutation; `Failed` is sticky; `Get_Application_Keys` is
  guarded by `Is_Connected`; the client accepts only ed25519 in CertificateVerify, so no
  downgrade to ECDSA or RSA-PSS is possible.
- **OpenSSL binding.** Every C entry point validates its arguments, clears the error queue
  before work, frees every handle on all exits, and cleanses outputs on failure; the Ada
  side raises `Crypto_Error` on anything but 0 or 1 and sets `Verified` only on the
  success value.
- Observations recorded and outside the rubric: `Application_Secrets.Exporter` is derived
  and never read anywhere in the crate, which is dead work rather than a defect, and is
  mentioned inside QUIC-TLS-3 rather than counted separately. The two handshake
  `QUIC_Traffic_Keys` records are likewise retained past the point RFC 9001 section 4.9.2
  describes, and are covered by the same entry.
