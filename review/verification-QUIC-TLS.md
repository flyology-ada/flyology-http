# Verification: QUIC-TLS

Commit: f078732
Findings examined: 5 (plus one re-examined "no finding" conclusion).
Confirmed: 3. Refuted: 0. Partial: 1. Other: 1 (duplicate).

| ID | Discovery severity | Verdict | Final severity | Repro |
|----|--------------------|---------|----------------|-------|
| QUIC-TLS-1 | P1 | DUPLICATE of QUIC-TRANSPORT-3 | deferred to that entry | owned by the QUIC-TRANSPORT verifier |
| QUIC-TLS-2 | P1 | PARTIALLY CONFIRMED | P1 (code path certain; peer breadth not established) | `flyology-quic-connection_driver-repro_quic_tls_2` |
| QUIC-TLS-3 | P2 | CONFIRMED | **P1** (raised) | `flyology-quic-tls_session-repro_quic_tls_3` |
| QUIC-TLS-4 | P2 | CONFIRMED | P2 | `flyology-quic-tls_session-repro_quic_tls_4` |
| QUIC-TLS-5 | P2 | CONFIRMED | P2 | `flyology-quic-connection_driver-repro_quic_tls_5` |
| Certificate pinning ("no findings") | n/a | UPHELD after an adversarial attempt to break it | no finding | evidence inside `repro_quic_tls_5` |

Spikes are child units of the private packages they exercise, as
`tests/repros/README.md` prescribes. Run them with, for example:

```sh
./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_tls_2
```

## QUIC-TLS-1: Initial keys are never discarded

- **Verdict:** DUPLICATE. This is the same defect as `QUIC-TRANSPORT-3` in
  `review/discovery-QUIC-TRANSPORT.md` ("Initial keys are never discarded; a forged
  Initial ends an established connection"), which cites the same lines of
  `flyology_quic/src/flyology-quic-connection_driver.adb` (`:1382-1409`, `:901-911`),
  the same `flyology-quic-initial_space.adb:504-510`, and the same routing at
  `src/flyology-http-server-http_3.adb:112-123`. The primary entry and the
  reproduction belong to the QUIC-TRANSPORT verifier; per the coordinator's
  instruction I did not write a second spike.
- **Severity:** deferred to `QUIC-TRANSPORT-3`.
- **Re-read result:** the code path is as both entries describe.
  `Scan_Datagram` dispatches long-header Initial packets in every connection state;
  `Process_Initial_Packet` acts on `Processed.Peer_Closed` (`connection_driver.adb:906-911`)
  before it reaches the state check at `:1029-1033`; `Initial_Space.State` carries no
  "keys discarded" flag and `Acknowledge_Flight` only stops retransmission. RFC 9001
  section 4.9.1: "a client MUST discard Initial keys when it first sends a Handshake
  packet and a server MUST discard Initial keys when it first successfully processes
  a Handshake packet. Endpoints MUST NOT send Initial packets after this point", and
  the reason given in the same section is that "Packets protected with Initial
  secrets (Section 5.2) are not authenticated, meaning that an attacker could spoof
  packets with the intent to disrupt a connection."

## QUIC-TLS-2: Client aborts the connection on post-handshake CRYPTO that is not exactly one complete NewSessionTicket at offset 0

- **Verdict:** PARTIALLY CONFIRMED. The code path is confirmed end to end, in three
  distinct shapes. The entry's peer-breadth claim ("OpenSSL 3, quictls or BoringSSL
  ... send two NewSessionTicket messages by default", implying stock servers break
  this client) is **not established** and is materially weakened by a fact neither
  the discovery reviewer nor the entry mentions; see *Peer breadth* below.
- **Severity:** P1 (discovery said P1; kept, with the reachability caveat stated
  explicitly below). This is the same defect as `QUIC-TRANSPORT-4`.
- **Repro:** `tests/repros/src/flyology-quic-connection_driver-repro_quic_tls_2.adb`,
  run with `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_tls_2`
- **Output:**

```
  note QUIC-TLS-2: post-handshake CRYPTO handling in the QUIC client
  note two tickets in one frame: handshake complete, client state = CONNECTED
  note two tickets in one frame: client state after the crafted CRYPTO frame = FAILED, datagrams emitted = 1
  FAIL two tickets in one frame: connection survives the post-handshake CRYPTO frame
  FAIL two tickets in one frame: no CONNECTION_CLOSE is emitted
  note second ticket at offset 4: handshake complete, client state = CONNECTED
  ok   second ticket at offset 4: client still Connected after the first ticket
  note second ticket at offset 4: client state after the crafted CRYPTO frame = FAILED, datagrams emitted = 1
  FAIL second ticket at offset 4: connection survives the post-handshake CRYPTO frame
  FAIL second ticket at offset 4: no CONNECTION_CLOSE is emitted
  note ticket split across frames: handshake complete, client state = CONNECTED
  note ticket split across frames: client state after the crafted CRYPTO frame = FAILED, datagrams emitted = 1
  FAIL ticket split across frames: connection survives the post-handshake CRYPTO frame
  FAIL ticket split across frames: no CONNECTION_CLOSE is emitted
checks: 7  failures: 6
BUG REPRODUCED
exit status 1
```

- **Description:** the spike completes a real in-process QUIC/TLS handshake between two
  `Connection_Driver.Connection` objects (no socket), then takes the server's real
  application keys through `TLS_Session.Get_Application_Keys` and builds genuine 1-RTT
  packets carrying crafted CRYPTO frames. `Application_Space.Process_Packet`
  (`flyology-quic-application_space.adb:1333-1349`) accepts a 1-RTT CRYPTO frame only
  when `Crypto_Offset = 0`, the first body byte is handshake type 4, and the message's
  own 3-byte length equals `Data_Length - 4`; anything else is `Unexpected_TLS_Message`.
  `Transport_Error_For` maps that status to `16#10A#`
  (`connection_driver.adb:580`) and `Fail_Application_With_Close` sets
  `Item.Current := Failed` and emits a CONNECTION_CLOSE (`:589-618`). There is no 1-RTT
  CRYPTO reassembly at all. The third case shows the defect does not depend on ticket
  count: a single ticket whose bytes are split across two CRYPTO frames kills the
  connection on the first frame. The `ok` line shows the assertion is not over-broad:
  the one accepted shape (a single complete ticket at offset 0) still works.
  Standards: RFC 8446 section 4.6.1, "Servers MAY send multiple tickets on a single
  connection, either immediately after each other or after specific events";
  RFC 9001 section 4.5, QUIC "carr[ies] NewSessionTicket messages in CRYPTO frames after
  the handshake is complete"; RFC 9001 section 4.1.3 requires the receiver to sequence
  CRYPTO frames by offset - "As with STREAM frames, the offset is used to find the proper
  location in the data sequence. If the result of this process is that new data is
  available, then it is delivered to TLS in order." RFC 9000 section 7.5 gives the only
  sanctioned escape for a post-handshake CRYPTO frame an endpoint cannot handle: "it MAY
  discard that CRYPTO frame and all CRYPTO frames received in the future, or it MAY close
  the connection with a CRYPTO_BUFFER_EXCEEDED error code" - not CRYPTO_ERROR 0x10A.

- **Peer breadth (the part that does not hold as written).** The entry says stock
  OpenSSL/BoringSSL servers trigger this by default. Three checks on this machine:
  1. **The OpenSSL default is two tickets, as the entry says.** OpenSSL 3.6.3's own
     installed manual page (`/opt/homebrew/opt/openssl@3/share/doc/openssl/html/man3/SSL_CTX_set_num_tickets.html`)
     states: "The default number of tickets is 2." Read locally, not from memory.
  2. **But this client never advertises `psk_key_exchange_modes`.**
     `TLS_Extension_Policy.Encode_Client_Hello`
     (`flyology_quic/src/flyology-quic-tls_extension_policy.adb:480-531`) emits exactly
     five extensions: supported_versions, supported_groups, signature_algorithms,
     key_share, ALPN and quic_transport_parameters. Extension 45 is absent. RFC 8446
     section 4.2.9: "Servers SHOULD NOT send NewSessionTicket with tickets that are not
     compatible with the advertised modes". With no modes advertised, a conforming
     server sends no ticket at all.
  3. **The two TLS stacks whose source is pinned on this machine implement that gate.**
     Go 1.23.4 `crypto/tls/handshake_server_tls13.go:829-846` gates on
     `pskModeDHE` with the comment "Don't send tickets the client wouldn't use. See RFC
     8446, Section 4.2.9"; aioquic `tls.py:1838-1841` gates on
     `self.new_session_ticket_cb is not None and self._psk_key_exchange_mode is not None`.
     Whether OpenSSL applies the same gate is **not verified against a peer**: no OpenSSL
     QUIC server is available here (`openssl s_server` in 3.6.3 has no `-quic` option), and
     there is no OpenSSL source tree on this machine: a filesystem-wide search for
     `SSL_CTX_set_num_tickets*` returned only the installed header, manual page and HTML
     doc of Homebrew's openssl@3 3.6.3, with no `.pod` and hence no documentation source
     tree to accompany `ssl/statem/statem_srvr.c`. The entry's BoringSSL `kNumTickets = 2`
     claim is likewise **not verified against a peer**.
- **Why the green interop baseline does not contradict this.**
  `review/baselines/10-http3-interop.log` records PASS against quic-go 0.54.1 and
  aioquic 1.3.0 in both roles.
  * quic-go sends **exactly one** ticket and places it at CRYPTO offset 0. Its own
    comment in the pinned module
    (`quic-go@v0.54.1/internal/handshake/crypto_setup.go:365-367`) reads "Due to
    limitations in crypto/tls, it's only possible to generate a single session ticket per
    connection", and Go's `QUICConn.SendSessionTicket` (`crypto/tls/quic.go:303-316`)
    refuses a second call. quic-go's ticket is written to a fresh 1-RTT crypto stream and
    packetized at `MaxPostHandshakeCryptoFrameSize = 1000`
    (`internal/protocol/params.go:113`), so a ticket of this size is one frame at offset 0,
    the single shape this client accepts. Note that Go's QUIC path bypasses the psk-mode
    gate, so quic-go does send its one ticket to this client - the interop run is
    exercising precisely the accepted case.
  * aioquic sends none: the oracle (`tests/oracle/aioquic_h3_server.py:163-182`)
    configures no `session_ticket_handler`, and aioquic additionally requires an
    advertised psk_key_exchange_mode.
- **Residual reachability.** The split-ticket case is the one that does not depend on
  ticket count or on the psk-mode gate: any peer whose post-handshake CRYPTO packetization
  splits a ticket (quic-go's own 1000-byte cap shows this is ordinary implementation
  behaviour) kills the connection. If the maintainer weights "no stock peer demonstrated"
  heavily, P2 is defensible; I keep P1 because the client destroys a successfully
  established connection in response to input the standards explicitly permit, and
  because the fix (offset-sequenced 1-RTT CRYPTO buffering, or simply discarding
  post-handshake CRYPTO per RFC 9000 section 7.5) is not conditional on which peer does it.

## QUIC-TLS-3: Handshake, master, exporter and traffic secrets are never wiped on the success path

- **Verdict:** CONFIRMED, and stronger than the entry claims.
- **Severity:** **P1** (discovery said P2; raised). The entry treated post-free exposure
  as a hypothetical. It is not: the spike recovers the master secret from heap storage
  the allocator hands back after the session is released, which is an ordinary read of
  uninitialized storage the program owns, not a read of freed memory and not undefined
  behaviour. It is still not P0 under this rubric: no remote peer can trigger or observe
  it, and there is no memory-safety error. I raise it to P1 because the crate's own
  discipline is violated - `Mark_Failed` (`tls_session.adb:33-46`) clears every secret on
  the failure path and `TLS_Key_Schedule` exports a `Clear` for every secret type, so the
  success path is an inconsistency with an established internal contract, not a missing
  feature.
- **Repro:** `tests/repros/src/flyology-quic-tls_session-repro_quic_tls_3.adb`,
  run with `./tests/repros/run.sh flyology-quic-tls_session-repro_quic_tls_3`
- **Output:**

```
  FAIL client: handshake secret cleared at Connected
  FAIL client: master secret cleared at Connected
  FAIL client: client handshake traffic secret cleared
  FAIL client: server handshake traffic secret cleared
  FAIL client: client finished key cleared
  FAIL client: server finished key cleared
  FAIL client: exporter secret cleared (never used by this crate)
  FAIL server: handshake secret cleared at Connected
  FAIL server: master secret cleared at Connected
  FAIL server: client handshake traffic secret cleared
  FAIL server: server handshake traffic secret cleared
  FAIL server: client finished key cleared
  FAIL server: server finished key cleared
  FAIL server: exporter secret cleared (never used by this crate)
  note client master secret at Connected = 3b 44 25 61 98 3c 42 a6 ce 03 b5 2d 26 97 23 20 e5 4b bd 96 30 d1 d5 01 b4 38 b7 39 52 89 48 cd
  note heap Session size = 83368 bytes; master secret = 76 8f 22 d9 76 ea 99 cc 56 ee 2c 7a 52 f2 f5 df 5e 03 0a f5 3c f9 8e f8 ac 0c fb 9a 32 9b a0 bd
  note master secret copies found in reused heap storage = 1
  FAIL the master secret is not recoverable from reused heap storage after the session is released
checks: 15  failures: 15
BUG REPRODUCED
exit status 1
```

- **Description.** Which secrets survive, precisely. On the success path the client
  (`tls_session.adb:788-791`) and the server (`:849-853`) clear only `X25519_Private`
  (and, on the server, `Signing_Key`) and the local `Resumption` temporary. Every field
  of `Item.Handshake_Secrets` - `Handshake`, `Master`, `Client_Traffic`, `Server_Traffic`,
  `Client_Finished`, `Server_Finished` - is dead once the session reaches `Connected`
  (their last consumers are `Derive_Application`, `Derive_Resumption`, `Derive_QUIC_Keys`
  and `Finished_Verify_Data`, all already run), yet all six remain, on both roles, as the
  first fourteen checks show. `Application_Secrets.Exporter` also remains and is never
  read anywhere in the crate. The four `QUIC_Traffic_Keys` records stay too; the two
  handshake ones are dead once the handshake is confirmed (RFC 9001 section 4.9.2).
  For the post-free part, the spike allocates the `Session` on the heap, records
  `Handshake_Secrets.Master`, and releases it with `Ada.Unchecked_Deallocation`, which is
  exactly what `Connections.Finalize` does to the whole connection implementation
  (`flyology-quic-connections.adb:29-30`, `:48-56`, where `Connection_Impl` holds the
  driver, which holds the `TLS_Session.Session` and every space's key copies). Nothing
  overwrites the storage. A subsequent allocation of the same size returns storage still
  containing the master secret, and the spike finds it. The realistic consumers of that
  residue are a later heap over-read in the same process, a core dump, and a swap or
  hibernation image - the reasons TLS stacks zeroize. RFC 9001 section 4.9 is the
  directional authority ("Discarding Unused Keys"); RFC 8446 mandates no erasure, which
  is why this is not higher than P1.

## QUIC-TLS-4: Server matches only the first ALPN entry of the ClientHello

- **Verdict:** CONFIRMED. The mechanism and the consequence are exactly as described.
  One correction: the entry's quotation of RFC 7301 section 3.2 ("the server SHALL select
  a protocol from the list") is not what the RFC says; see below.
- **Severity:** P2 (discovery said P2; kept).
- **Repro:** `tests/repros/src/flyology-quic-tls_session-repro_quic_tls_4.adb`,
  run with `./tests/repros/run.sh flyology-quic-tls_session-repro_quic_tls_4`
- **Output:**

```
  note QUIC-TLS-4: ALPN selection from a multi-entry ClientHello list
  note patched ClientHello ALPN list = 05 'h3-29' 02 'h3'; server ALPN = h3
  note Accept_Client_Hello status = ALPN_MISMATCH
  FAIL the server selects h3 from the offered ALPN list
  ok   control: the single-entry list h3 is accepted
checks: 2  failures: 1
BUG REPRODUCED
exit status 1
```

- **Description.** The spike takes the real ClientHello that `TLS_Session.Start_Client`
  produces, replaces its ALPN extension body with the two-entry list
  `05 "h3-29" 02 "h3"`, and repairs the extensions-block length and the handshake message
  length, then hands it to a server initialized with ALPN `h3`. The control case shows the
  same server accepts the unpatched single-entry list, so the patching itself is sound.
  `TLS_Extension_Policy.Parse` records only the first entry
  (`tls_extension_policy.adb:220-224`, `if not Result.Has_ALPN then ... end if`), and
  `Validate_Extensions` (`tls_session.adb:160-189`) compares that one recorded entry with
  the configured ALPN, so a client offering `["h3-29", "h3"]` to an `h3` server is refused
  with `ALPN_Mismatch`, which the driver sends as 0x178.
  **Standard, corrected.** RFC 7301 section 3.2 says: "the server SHOULD select the most
  highly preferred protocol that it supports and that is also advertised by the client.
  In the event that the server supports no protocols that the client advertises, then the
  server SHALL respond with a fatal 'no_application_protocol' alert." The selection rule
  is a SHOULD, not a SHALL. The SHALL is the *alert*, and its trigger condition - the
  server supports none of the advertised protocols - is not met here, so sending 0x178
  when `h3` was advertised misuses the mandatory clause. RFC 9001 section 8.1 requires
  0x178 only "if an application protocol is not negotiated". P2 stands because current
  mainstream QUIC clients offer `h3` alone.

## QUIC-TLS-5: TLS failures close with internal_error (0x150) instead of the required alerts

- **Verdict:** CONFIRMED on the wire, for both the certificate path and the signature
  path. The missing-ALPN-in-EncryptedExtensions sub-claim is confirmed by reading only.
- **Severity:** P2 (discovery said P2; kept). RFC 9001 section 4.8 does give latitude -
  "QUIC permits the use of a generic code in place of a specific error code ... this
  includes replacing any alert with a generic alert, such as handshake_failure (0x0128 in
  QUIC)" - but 0x150 is not a generic code. It is `internal_error(80)`, which RFC 8446
  section 6.2 defines as "An internal error *unrelated to the peer or the correctness of
  the protocol* (such as a memory allocation failure)". The emitted code therefore
  actively misdescribes a peer-caused authentication failure.
- **Repro:** `tests/repros/src/flyology-quic-connection_driver-repro_quic_tls_5.adb`,
  run with `./tests/repros/run.sh flyology-quic-connection_driver-repro_quic_tls_5`
- **Output:**

```
  note QUIC-TLS-5: CONNECTION_CLOSE error codes for TLS failures
  note pinned certificate mismatch: client state = FAILED, datagrams emitted = 1
  ok   pinned certificate mismatch: the client rejects the server authentication
  ok   pinned certificate mismatch: the client sends a CONNECTION_CLOSE
  note pinned certificate mismatch: error code on the wire = 336
  FAIL pinned certificate mismatch: closes with CRYPTO_ERROR + bad_certificate ( 298)
  note CertificateVerify signed with a foreign key: client state = FAILED, datagrams emitted = 1
  ok   CertificateVerify signed with a foreign key: the client rejects the server authentication
  ok   CertificateVerify signed with a foreign key: the client sends a CONNECTION_CLOSE
  note CertificateVerify signed with a foreign key: error code on the wire = 336
  FAIL CertificateVerify signed with a foreign key: closes with CRYPTO_ERROR + decrypt_error ( 307)
checks: 6  failures: 2
BUG REPRODUCED
exit status 1
```

- **Description.** The spike does not decode the datagram by hand: it delivers the
  client's CONNECTION_CLOSE back to the live server driver, which decrypts it with its own
  Handshake keys, and reads `Peer_Close_Error`. Both cases report 336 = 0x150.
  Case 1 pins a certificate that differs from the server's by one byte of the
  subjectPublicKey, producing `Certificate_Mismatch`; RFC 8446 section 6.2 defines
  `bad_certificate(42)` for "A certificate was corrupt, contained signatures that did not
  verify correctly, etc.", QUIC 0x12A by the 0x0100 + alert rule of RFC 9001 section 4.8.
  Case 2 pins the genuine certificate but has the server sign CertificateVerify with a
  different Ed25519 seed, producing `Signature_Failed`; RFC 8446 section 4.4.3 is explicit:
  "If the verification fails, the receiver MUST terminate the handshake with a
  'decrypt_error' alert" (51, QUIC 0x133), and section 4.4.4 says the same for Finished.
  The root cause is the `when others => 16#150#` arm of the case expression at
  `connection_driver.adb:1109-1115` (and the equivalents at `:945-951` and `:1160-1163`),
  under which `Certificate_Mismatch`, `Signature_Failed` and `Finished_Failed` all fall.
  The missing-ALPN sub-claim is confirmed by reading: `TLS_Extension_Policy` reports
  `Missing_Required_Extension`, `TLS_Handshake_Policy` collapses it to
  `Invalid_Extensions` (`tls_extension_policy.ads:26`, `tls_handshake_policy.ads:26`),
  `TLS_Session` passes it through (`tls_session.adb:298-299`, `:521-522`, `:598-599`), and
  the driver sends 0x16D (`missing_extension`), where RFC 9001 section 8.1 requires 0x178.
  That path is not reproduced here.

## Certificate pinning: the discovery's "no findings" conclusion, re-examined

The discovery concluded that certificate verification is sound because the contract is
exact-DER pinning of an Ed25519 leaf. I tried to break it and could not. Result: **upheld**.

- **Every supplier of the pinned bytes.** `Flyology.QUIC.Connections.Initialize_Client`
  is the only public entry (`flyology-quic-connections.ads:220-252`), and in the whole HTTP
  crate it has exactly one production caller:
  `src/flyology-http-client.adb:3274-3282` inside `Start_HTTP_3_Connection`, which passes
  `Flyology.Bytes.To_Array (Owner.HTTP_3_Certificate)`. That field is written in exactly
  two places, both `Configure` overloads that take `HTTP_3_Certificate_DER`
  (`flyology-http-client.adb:2451-2452`, `:2501-2502`).
- **No path reaches a connected state with an empty or unset pin.** Both of those
  overloads validate the argument with a real `raise Program_Error`, not an assertion:
  `elsif HTTP_3_Certificate_DER'Length not in 1 .. 4_096 then raise Program_Error with
  "HTTP/3 pinned certificate must contain 1 through 4096 bytes"`
  (`:2443-2445`, `:2485-2487`). The two `Configure` overloads that do **not** take a
  certificate both reject HTTP/3 modes outright - `elsif Mode in Negotiate_HTTP_3 |
  Require_HTTP_3 then raise Program_Error with "HTTP/3 requires a pinned certificate
  Configure overload"` (`:2298-2300` and `:2402-2404`) - so `HTTP_3_Certificate` cannot
  still hold its empty default when `Start_HTTP_3_Connection` runs. These are ordinary
  `if`/`raise` statements, so they hold with assertions disabled, unlike the
  `Pinned_Certificate'Length in 1 .. 4_096` preconditions below them in the stack.
  Even if an empty pin were somehow supplied, the path stays fail-closed: the length check
  at `tls_session.adb:635-639` would demand a zero-length certificate entry, and
  `Ed25519_Verify_Certificate` sets `Verified := False` first thing
  (`crypto_openssl.adb:572`) and the C bridge rejects a DER buffer it cannot fully parse,
  so the handshake would end in `Signature_Failed`.
- **No path ignores the comparison result.** `Accept_Server_Authentication` is a straight
  line of early returns, each calling `Mark_Failed`; the client driver assigns
  `Item.Current := Connected` only after `TLS_Result.Status = TLS_Session.Succeeded`
  (`connection_driver.adb:1105-1136`), and `Operation_Result.Status` defaults to
  `Invalid_State`, so an unwritten status is never mistaken for success.
- **The strongest attack, tried and defeated.** The pinned DER is public, so the attack
  that matters is a man in the middle that replays the pinned certificate with its own
  key. `repro_quic_tls_5` case 2 does exactly that - the server is initialized with the
  genuine certificate and a different Ed25519 seed - and the client ends in `Failed`
  (the two `ok` lines in that run). Case 1 covers a one-byte-different pin, also `Failed`.
  Verification runs against `Item.Certificate`, the pinned bytes, not the received copy
  (`tls_session.adb:696-703`), so a replayed certificate gains the attacker nothing.
- Chain building, name and wildcard matching, IP SANs and expiry are outside the stated
  contract (`tls_session.ads:6-10`, `connections.ads:212-218`) and remain absent; that is
  a documented limitation of the first authentication profile, not a defect.

## Notes for the coordinator

- `QUIC-TLS-2` and `QUIC-TRANSPORT-4` are the same defect, as are `QUIC-TLS-1` and
  `QUIC-TRANSPORT-3`. Two of the four entries should be folded into the other two before
  filing.
- Nothing in this area is `UNVERIFIABLE-BY-SPIKE`. The one claim a spike cannot settle is
  QUIC-TLS-2's peer breadth for OpenSSL- and BoringSSL-based QUIC servers. What would
  settle it: a run against an ngtcp2 or nginx-quic server with default ticket settings,
  observing whether it sends NewSessionTicket to a ClientHello carrying no
  `psk_key_exchange_modes` extension.
