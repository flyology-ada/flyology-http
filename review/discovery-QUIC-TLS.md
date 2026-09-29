# Discovery: QUIC-TLS

Scope (read in full unless a range is given):

- `flyology_quic/src/flyology-quic-tls_session.adb` (895) / `.ads` (176)
- `flyology_quic/src/flyology-quic-tls_key_schedule.adb` (276) / `.ads` (103)
- `flyology_quic/src/flyology-quic-tls_handshake_policy.adb` (433) / `.ads` (91)
- `flyology_quic/src/flyology-quic-tls_extension_policy.adb` (577) / `.ads` (95)
- `flyology_quic/src/flyology-quic-tls_signature_policy.adb` (23) / `.ads` (17)
- `flyology_quic/src/flyology-quic-tls_authentication_policy.adb` (380) / `.ads` (87)
- `flyology_quic/src/flyology-quic-crypto_openssl.adb` (598) / `.ads` (146)
- `flyology_quic/src/flyology-quic-crypto_flight.adb` (131) / `.ads` (105)
- `flyology_quic/src/flyology-quic-crypto_reassembly_policy.adb` (110) / `.ads` (89)
- `flyology_quic/src/native/flyology_quic_openssl.c` (851)
- `src/flyology-http-server-tls.adb` (24) / `.ads` (44)
- `src/flyology-http-server-development_certificates.adb` (349) / `.ads` (79)
- Adjacent, read to trace callers and key lifetime: `flyology_quic/src/flyology-quic-connection_driver.adb`
  (640-1470), `flyology-quic-application_space.adb` (1300-1400), `flyology-quic-application_connection.adb`
  (1-60, 120-200), `flyology-quic-initial_space.adb` (420-520), `flyology-quic-handshake_connection.adb`
  (1-45), `flyology-quic-connections.ads` (1-30, 205-320) and `.adb` (Release/Finalize),
  `src/flyology-http-server-http_3.adb` (108-140, 1855-1885, 1995-2125), `src/flyology-http-http_3_client_connection.ads`
- Tests: `flyology_quic/tests/qualification.md`, `flyology_quic/tests/src/flyology-quic-tls_session-smoke.adb`,
  `flyology-quic-tls_transport_smoke.adb`, `flyology-quic-tls_extension_policy-smoke.adb`,
  `tests/oracle/quic-go/main.go`, `tests/tls_test_provider.ads`, `tests/flyology-io-tls-testing.ads`,
  `tests/development_certificates_smoke.adb`, `tests/fixtures/tls/README.md`
- Proof status: `flyology_quic/src/proof-status.md`, `proof/proof-status.md`

Commit: f078732
Rubric: P0/P1/P2 as defined in review/DISCOVERY_BRIEF.md

Prior audit: `review/prior-audit.md` covers client TLS only through the `flyology` runtime's
TLS controller (`SSL_VERIFY_PEER`, `SSL_set1_host`), declares that controller out of scope in
its coverage-gaps appendix, and never mentions QUIC. The whole Ada TLS 1.3 handshake, key
schedule, OpenSSL primitive bridge, and the server TLS/development-certificate units reviewed
here postdate it or were outside it. No prior finding touches this area, so nothing here is a
regression.

Proved boundary: `TLS_Handshake_Policy`, `TLS_Extension_Policy`, `TLS_Signature_Policy`,
`TLS_Authentication_Policy`, and `Crypto_Reassembly_Policy` are `SPARK_Mode => On`. The QUIC
proof-status file records only the stream insertion policies as proved at level 1; for the
TLS policy units the proof establishes absence of run-time errors and the stated
postconditions (bounds, offsets, "if Parsed then required extensions present"), not
protocol semantics such as which ALPN entry is selected. `TLS_Session`, `TLS_Key_Schedule`,
`Crypto_OpenSSL`, the C bridge, `Crypto_Flight`, and both parent-crate units are outside
SPARK. Each entry below says which side of that boundary it sits on.

Authentication model: the `.ads` contract (`tls_session.ads:8-10`, `connections.ads:213-217`)
is exact-DER pinning of an Ed25519 leaf. Chain building, name matching, wildcards, IP SANs,
and expiry are therefore not part of the contract and their absence is not reported as a
defect; see "Areas reviewed with no findings" for what the pinning path does check.

## Summary

| ID | Title | Severity | Confidence |
|----|-------|----------|------------|
| QUIC-TLS-1 | Initial keys are never discarded, so a post-handshake Initial packet built with the public Initial keys can close an established connection | P1 | high (code), medium (attacker model) |
| QUIC-TLS-2 | Client aborts the connection when a server sends more than one NewSessionTicket, or one ticket split across CRYPTO frames | P1 | high (code), medium (stock-peer breadth) |
| QUIC-TLS-3 | Handshake, master, exporter and traffic secrets are never wiped after a successful handshake or on finalization | P2 | high |
| QUIC-TLS-4 | Server matches only the first ALPN entry of the ClientHello instead of selecting from the list | P2 | high |
| QUIC-TLS-5 | TLS failures close with `internal_error` (0x150) and missing ALPN with `missing_extension` (0x16D) instead of the alerts the RFCs require | P2 | high |

## Findings

### QUIC-TLS-1: Initial keys are never discarded, so a post-handshake Initial packet built with the public Initial keys can close an established connection

- **Location:** `flyology_quic/src/flyology-quic-connection_driver.adb:1382-1396` (dispatch), `:906-911`
  (close honoured before the state check), `flyology_quic/src/flyology-quic-initial_space.adb:504-509`;
  routing on the server side `src/flyology-http-server-http_3.adb:112-121`. Outside the proved boundary.
  The files are shared with the QUIC-transport area; recorded here because RFC 9001 §4.9 is a key-handling
  rule.
- **Severity:** P1
- **Confidence:** high on the code path; medium on how much an attacker gains, see below.
- **Evidence:**

```ada
--  connection_driver.adb:1382-1396 (Scan_Datagram): Initial packets are dispatched in every state
            elsif (First and 16#30#) = 16#00# then
               declare
                  ...
                  Process_Initial_Packet
                    (Item,
```

```ada
--  connection_driver.adb:906-911 (Process_Initial_Packet), reached before any check of Item.Current
      elsif Processed.Peer_Closed then
         Item.Close_Is_Application := False;
         Item.Close_Error := Processed.Close_Error;
         Item.Current := Peer_Closed;
         Result.Status := Connection_Closed;
         return;
```

```ada
--  initial_space.adb:504-509: a CONNECTION_CLOSE (0x1c) in an Initial packet sets Peer_Closed
         elsif Frame.Kind = Initial_Frame_Policy.Transport_Close then
            --  RFC 9000 10.2.2 puts the receiver into the draining state, so
            --  the remaining frames of this packet cannot change the outcome.
            Result.Peer_Closed := True;
```

  `Initial_Space.State` has no "keys discarded" flag; `Acknowledge_Flight` (`initial_space.ads:173`) only
  stops retransmission. The only inputs that reject a post-handshake Initial are the packet-number
  window (`Duplicate_Packet`/`Packet_Too_Old`) and AEAD authentication under the Initial keys, which are
  derived from the client's original Destination Connection ID (`crypto_openssl.ads:24-26`,
  RFC 9001 §5.2) and are therefore computable by anyone who saw the first client Initial.

- **Failure scenario:**
  1. A client and server complete the handshake; both reach `Connected` and `Is_Handshake_Confirmed`.
  2. An observer of the client's first Initial (same Wi-Fi, a logging middlebox) records the original
     DCID and the server's chosen SCID. It need not stay on path.
  3. Later it sends one UDP datagram to the server, source address spoofed to the client's, containing an
     Initial packet with DCID = server SCID, a packet number above the last one the server processed,
     protected with the RFC 9001 §5.2 keys for the recorded original DCID, carrying a CONNECTION_CLOSE
     (0x1c) frame.
  4. `Registry.Resolve` matches the slot by peer address and DCID (`server-http_3.adb:112-121`) and
     delivers it to the worker. `Scan_Datagram` dispatches it to `Process_Initial_Packet`;
     `Initial_Connection.Process_Initial` authenticates it; `Initial_Space.Process_Packet` sets
     `Peer_Closed`; the driver moves the connection to `Peer_Closed` and reports `Connection_Closed`.
  5. The same datagram sent to the client's UDP port (DCID = client's SCID) closes the client side.
  A CRYPTO frame whose bytes conflict with the recorded ClientHello reaches `Fail_Initial_With_Close`
  instead, with the same result.
- **Reproduction test sketch:** In-process, no peer needed. Drive `Connections.Initialize_Client` /
  `Initialize_Server` through the handshake as `flyology-quic-tls_transport_smoke.adb` does until both
  `Is_Connected`. Then, on the client object, call the driver's Initial-space close builder
  (`Initial_Space.Build_Transport_Close_Packet` via `Connections.Build_Handshake_Close_Datagram` or a
  test-only hook) to obtain an Initial packet carrying CONNECTION_CLOSE, and feed that datagram to the
  server's `Process_Datagram`. Expected per RFC 9001 §4.9.1: the packet is discarded, `State` stays
  `Connected`. Actual: `Operation_Status = Connection_Closed`, `State = Peer_Closed`. (Using the real
  client's Initial space sidesteps the packet-number window; a forged packet just needs a higher number.)
- **Existing coverage:** none. `flyology_quic/tests/src/flyology-quic-tls_transport_smoke.adb` stops at
  handshake completion; `qualification.md:46` covers CRYPTO reassembly of the ServerHello only. The
  interop peers never send Initial packets after the handshake, so the aioquic/quic-go runs cannot see this.
- **Standard:** RFC 9001 §4.9.1: "a server MUST discard Initial keys when it first successfully processes
  a Handshake packet ... a client MUST discard Initial keys when it first sends a Handshake packet ...
  packets protected with Initial keys received after this point are discarded"; §5.2 explains that Initial
  protection only defends against off-path attackers who did not observe the handshake, which is exactly
  the attacker this rule shuts out. Rated P1 rather than P0 because the attacker must have seen the client's
  first Initial (the original DCID is random and at least 8 bytes), so this is not a blind single-packet
  reset; it is still a MUST violation with a documented security consequence.

### QUIC-TLS-2: Client aborts the connection when a server sends more than one NewSessionTicket, or one ticket split across CRYPTO frames

- **Location:** `flyology_quic/src/flyology-quic-application_space.adb:1332-1347`. Outside the proved
  boundary. The file belongs to the QUIC-transport area; recorded here because it is the client's TLS
  post-handshake message handling.
- **Severity:** P1 (arguably P0 under the interop clause; see Standard)
- **Confidence:** high that the code behaves as described; medium on which stock servers trigger it,
  because I could not run a peer in this review.
- **Evidence:**

```ada
--  application_space.adb:1332-1347
               if Stream_ID_Policy.Local_Role (Item.Allocator) =
                    Stream_ID_Policy.Client
                 and then Frame.Base.Crypto_Offset = 0
                 and then Data_Length >= 4
                 and then Plaintext
                   (Plaintext'First
                      + Ada.Streams.Stream_Element_Offset (Data_Offset)) = 4
                 and then Body_Length = Natural (Data_Length) - 4
               then
                  --  A client that does not implement resumption may ignore
                  --  a complete post-handshake NewSessionTicket. Other
                  --  messages, including KeyUpdate, remain fatal in QUIC.
                  null;
               else
                  Result.Status := Unexpected_TLS_Message;
                  return;
```

  A 1-RTT CRYPTO frame is accepted only when it starts at stream offset 0 and contains exactly one
  complete NewSessionTicket. There is no 1-RTT CRYPTO reassembly. `Unexpected_TLS_Message` is mapped
  by `Scan_Datagram` (`connection_driver.adb:1315-1333`) to `Fail_Application_With_Close`.

- **Failure scenario:**
  1. The Ada client pins the server's Ed25519 DER and completes the handshake with a server built on
     OpenSSL 3, quictls or BoringSSL (ngtcp2 examples, Cloudflare quiche, nginx-quic, msquic with
     OpenSSL). Those libraries send two NewSessionTicket messages by default (OpenSSL
     `SSL_CTX_set_num_tickets(3)`: "The default number of tickets is 2"; BoringSSL
     `ssl/tls13_server.cc` `kNumTickets = 2`).
  2. The server's TLS stack hands both messages to the QUIC layer, which sends them either in one
     CRYPTO frame at offset 0 (then `Body_Length /= Data_Length - 4`) or in two frames (then the second has
     `Crypto_Offset /= 0`). A single ticket larger than one packet is split the same way.
  3. On the first non-matching frame the client sends CONNECTION_CLOSE and moves to `Failed`, immediately
     after a handshake that succeeded. Every HTTP/3 request on that connection fails.
- **Reproduction test sketch:** After an in-memory handshake reaches `Connected` on both sides, build on
  the server a 1-RTT packet whose plaintext is one CRYPTO frame at offset 0 carrying two back-to-back
  NewSessionTicket messages (`04 00 00 LL ...` twice; body content is irrelevant), for example with
  `Crypto_Frame_Policy.Encode` and `Application_Connection.Build_One_RTT`. Feed it to the client's
  `Process_Datagram`. Expected: `Succeeded`, `State = Connected`. Actual: `Fail_Application_With_Close`,
  `State = Failed`. Second case: two packets, the second CRYPTO frame at offset = length of the first
  message.
- **Existing coverage:** `scripts/test-http3-interop.sh` runs the Ada client against quic-go
  (`tests/oracle/quic-go/main.go:46-84`, default `quic.Config`), whose server sends one ticket well under
  its 1000-byte post-handshake CRYPTO frame size, and against aioquic, which sends no ticket unless a
  `session_ticket_handler` is configured. Neither exercises a second ticket or a split ticket. No unit
  test covers 1-RTT CRYPTO frames.
- **Standard:** RFC 8446 §4.6.1: "At any time after the server has received the client Finished message,
  it MAY send a NewSessionTicket message ... The server MAY send multiple tickets on a single connection".
  RFC 9000 §7.5 requires CRYPTO stream data to be delivered in order by offset, so message boundaries are
  not frame boundaries. RFC 9001 §4.1 places post-handshake messages in 1-RTT CRYPTO frames. RFC 9001 §6
  is honoured correctly for KeyUpdate (rejected with 0x10a).

### QUIC-TLS-3: Handshake, master, exporter and traffic secrets are never wiped after a successful handshake or on finalization

- **Location:** `flyology_quic/src/flyology-quic-tls_session.adb:790-791` and `:851-853` (success
  transitions), `tls_session.ads:148-175` (`Session` is a plain `limited record`, no finalizer),
  `flyology_quic/src/flyology-quic-connections.adb:29` and `:53` (`Unchecked_Deallocation` of the whole
  implementation with no zeroization), `flyology-quic-handshake_connection.adb:26-28` and
  `flyology-quic-application_connection.adb:29-31` (traffic keys copied into space state that is never
  cleared), `connection_driver.adb:756`, `:933`, `:1005` (stack copies of traffic keys not cleared).
  Outside the proved boundary.
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
--  tls_session.adb:788-791 (client) and :851-853 (server): only the ephemeral private keys are cleared
      TLS_Key_Schedule.Clear (Resumption);
      Item.X25519_Private := (others => 0);
      Item.Current_State := Connected;
```

```ada
--  connections.adb:29 / :53
   procedure Release is new Ada.Unchecked_Deallocation
     (Connection_Impl, Impl_Conversions.Object_Pointer);
   ...
         Release (Value);
```

  `Mark_Failed` (`tls_session.adb:33-46`) does clear every secret on the failure paths, and
  `TLS_Key_Schedule` clears its temporaries on both normal and exception exit, so the failure side is
  sound. On the success side `Item.Handshake_Secrets` (handshake secret, master secret, both handshake
  traffic secrets, both finished keys), `Item.Application_Secrets` (including the exporter secret) and
  all four `QUIC_Traffic_Keys` records stay in the `Session` for the life of the connection, and the
  Initial, Handshake and 1-RTT key copies stay in their spaces. When the `Connection` is finalized the
  heap block is released without being overwritten, so every secret survives in freed memory.

- **Failure scenario:** A process memory disclosure, core dump, or reuse of the freed block after a
  connection ends exposes the master secret and handshake traffic secrets of completed connections, not
  only the current 1-RTT keys. RFC 9001 §4.9 asks endpoints to discard Initial and Handshake keys once they
  are no longer needed precisely so they are not retained.
- **Reproduction test sketch:** After an in-memory handshake, inspect the private `Session` from a test
  child package: `Handshake_Secrets.Master /= (others => 0)` while `State = Connected`. Finalize the
  owning `Connections.Connection` and observe that no `Clear`/`Mark_Failed` runs on the success path
  (no finalizer exists to call).
- **Existing coverage:** `flyology-quic-tls_session-smoke.adb:196-219` asserts clearing only on the
  failure path (`State = Failed and then not Has_Peer_Parameters`). Nothing checks the success path or
  finalization.
- **Standard:** RFC 9001 §4.9 (discarding unused keys), §4.9.2 (Handshake keys discarded when the
  handshake is confirmed). RFC 8446 does not mandate erasure, hence P2.

### QUIC-TLS-4: Server matches only the first ALPN entry of the ClientHello instead of selecting from the list

- **Location:** `flyology_quic/src/flyology-quic-tls_extension_policy.adb:220-224` (inside the proved
  boundary; the proof covers bounds, not which entry is reported), consumed at
  `flyology_quic/src/flyology-quic-tls_session.adb:180-189` (outside).
- **Severity:** P2
- **Confidence:** high
- **Evidence:**

```ada
--  tls_extension_policy.adb:220-224
            if not Result.Has_ALPN then
               Result.Has_ALPN := True;
               Result.ALPN_Protocol_Offset := Cursor_Pos;
               Result.ALPN_Protocol_Length := Name_Length;
            end if;
```

```ada
--  tls_session.adb:180-189
      if Parsed.Extensions.ALPN_Protocol_Length /= Item.ALPN_Length
        or else Input
          (ALPN_Start
             .. ALPN_Start
                  + Ada.Streams.Stream_Element_Offset
                      (Item.ALPN_Length - 1)) /=
            Item.ALPN
              (1 .. Ada.Streams.Stream_Element_Offset (Item.ALPN_Length))
      then
         return ALPN_Mismatch;
```

  The same code path serves the client's EncryptedExtensions check, where "exactly one entry" is
  correct (`extension_policy.adb:369-370` enforces it). For the ClientHello the parser records only the
  first entry, so a client offering `["h3-29", "h3"]` to a server configured for `h3` is refused with
  0x178 even though `h3` was offered.

- **Failure scenario:** 1. A client sends a ClientHello whose ALPN list is `[h3-29, h3]` (older aioquic
  and quic-go examples did this; current mainstream clients send `h3` alone, which is why P2). 2. The
  server's `Accept_Client_Hello` returns `ALPN_Mismatch`; the driver sends CONNECTION_CLOSE 0x178. 3. The
  client never connects although a mutually supported protocol exists.
- **Reproduction test sketch:** Hand-build a ClientHello identical to `Encode_Client_Hello`'s output but
  with the ALPN extension body `00 09 05 'h3-29' 02 'h3'`; call `TLS_Session.Accept_Client_Hello` on a
  server initialized with ALPN `h3`. Expected: `Succeeded`. Actual: `ALPN_Mismatch`.
- **Existing coverage:** `flyology-quic-tls_extension_policy-smoke.adb:80-89` checks a single-entry
  list and its offset only; the multi-entry case is not tested.
- **Standard:** RFC 7301 §3.2: the server "SHALL select a protocol from the list"; RFC 9001 §8.1 requires
  0x178 only when no application protocol can be negotiated.

### QUIC-TLS-5: TLS failures close with `internal_error` (0x150) and missing ALPN with `missing_extension` (0x16D) instead of the alerts the RFCs require

- **Location:** `flyology_quic/src/flyology-quic-connection_driver.adb:945-951`, `:1109-1115`,
  `:1160-1163` (mapping), root cause in `flyology_quic/src/flyology-quic-tls_session.adb:148-152`
  (`Missing_Required_Extension` collapsed into `Invalid_Extensions`; no distinct status for a missing ALPN).
  Outside the proved boundary; shared with the QUIC-transport area.
- **Severity:** P2 (wrong diagnostics on the wire)
- **Confidence:** high
- **Evidence:**

```ada
--  connection_driver.adb:1109-1115 (client, after Accept_Server_Authentication)
                    (case TLS_Result.Status is
                        when TLS_Session.ALPN_Mismatch => 16#178#,
                        when TLS_Session.Invalid_Extensions => 16#16D#,
                        when TLS_Session.Invalid_Message => 16#10A#,
                        when others => 16#150#),
```

  `Certificate_Mismatch`, `Signature_Failed` and `Finished_Failed` all fall to `others` and are reported
  as CRYPTO_ERROR + `internal_error` (80 = 0x50). An EncryptedExtensions without ALPN is
  `Missing_Required_Extension` in the extension policy, surfaces as `Invalid_Extensions`, and is sent as
  0x16D.

- **Failure scenario:** A peer or a qlog reader sees `internal_error` for a bad certificate, a bad
  signature or a bad Finished, and `missing_extension` for a missing ALPN, and misdiagnoses the failure.
- **Reproduction test sketch:** Flip one byte of the server Finished as
  `flyology-quic-tls_session-smoke.adb:205-209` does, but drive it through
  `Connections.Process_Datagram`; inspect the CONNECTION_CLOSE error code in the output datagram.
  Expected 0x133 (`decrypt_error`); actual 0x150.
- **Existing coverage:** none inspects the emitted error code.
- **Standard:** RFC 8446 §4.4.3 and §4.4.4: verification failure of CertificateVerify or Finished "MUST
  terminate the handshake with a 'decrypt_error' alert" (51 = 0x33, QUIC 0x133); §6.2 `bad_certificate`
  (42, QUIC 0x12A) for a certificate the client will not accept; RFC 9001 §8.1: a client "MUST use error
  0x178 to terminate a connection when ALPN negotiation fails"; §8.2: 0x16D is for a missing
  `quic_transport_parameters` extension (that case is mapped correctly).

## Areas reviewed with no findings

- **Certificate pinning path** (`tls_session.adb:629-706`, outside SPARK): the Certificate message must
  parse, carry an empty `certificate_request_context`, contain at least one entry, and its first entry
  must equal the pinned DER in length and bytes; the CertificateVerify must use scheme 0x0807 with a
  64-byte signature over `TLS_Signature_Policy.Build (Server, Transcript-Hash(CH..Certificate))`, verified
  by `Ed25519_Verify_Certificate` against the pinned bytes (not the received copy). The C bridge
  (`flyology_quic_openssl.c:812-851`) requires `d2i_X509` to consume the whole buffer, extracts the key,
  maps `EVP_DigestVerify` 1/0/negative to verified/not/error, and returns "not verified" for any parse or
  init failure, so there is no path to `Connected` with the result ignored. Extra certificate entries and
  per-entry extensions are ignored, which is harmless under exact-leaf pinning.
- **Finished verification** (`tls_session.adb:722-738`, `:826-836`): computed over the correct transcript
  prefixes (server Finished over CH..CertificateVerify, client Finished over CH..server Finished), compared
  with a constant-time `Secure_Equal`; a mismatch marks the session `Failed` and clears secrets
  (`tls_session-smoke.adb:196-219` asserts this).
- **Key schedule** (`tls_key_schedule.adb`, outside SPARK): HKDF-Expand-Label info layout
  (length, `"tls13 "` prefix, context, single block for outputs of at most 32 bytes), Early/Derived/
  Handshake/Master extraction chain, `c hs traffic`/`s hs traffic`/`finished`/`c ap traffic`/
  `s ap traffic`/`exp master`/`res master`, and QUIC labels `quic key`(16)/`quic iv`(12)/`quic hp`(16)/
  `quic ku`(32) with header-protection key retained across updates all match RFC 8446 §7.1 and RFC 9001
  §5.1/§6.1. Every temporary is cleared on normal and exception exit. `qualification.md:28-31` records the
  RFC 8448 trace test.
- **Initial secrets** (`flyology_quic_openssl.c:356-359`): salt `38762cf7f55934b34d179ae6a4c80cadccbb7f0a`,
  labels `client in`/`server in`, per RFC 9001 §5.2.
- **CertificateVerify input** (`tls_signature_policy.adb`, SPARK): 64 x 0x20, 33-byte context string,
  single zero, 32-byte hash; total 130, per RFC 8446 §4.4.3.
- **Hello parsing** (`tls_handshake_policy.adb`, SPARK): legacy_version 0x0303, cipher suite 0x1301
  required (offered by the client, selected by the server), compression exactly `01 00` / `00`,
  session id at most 32 bytes and echoed empty by the client check at `tls_session.adb:518`, extensions
  must fill the message exactly. HelloRetryRequest cannot be mistaken for a ServerHello because its
  `key_share` is 2 bytes and the ServerHello context requires exactly a 36-byte X25519 entry; the client
  offers no PSK or early_data, and the server drops 0-RTT packets as `Unsupported_Packet`
  (`connection_driver.adb:1438-1444`), so both are rejected fail-closed.
- **Extension policy** (`tls_extension_policy.adb`, SPARK): unknown extensions ignored (RFC 8446 §9.3),
  duplicates rejected (§4.2), `supported_versions`/`key_share` forbidden in EncryptedExtensions,
  `signature_algorithms` only in ClientHello, ALPN and `quic_transport_parameters` forbidden in
  ServerHello, both required in ClientHello and EncryptedExtensions (RFC 9001 §8.1/§8.2), exactly one ALPN
  entry in EncryptedExtensions (RFC 7301 §3.1), and a TLS 1.2 ServerHello (no `supported_versions`) is
  refused. A selected ALPN that was not offered is `ALPN_Mismatch` and closes with 0x178.
- **State machine**: every `Accept_*` checks the current state first and returns `Invalid_State` without
  mutation; a duplicated EncryptedExtensions or a Certificate before EncryptedExtensions is refused by
  message-kind checks; `Failed` is sticky; `Get_Application_Keys` is guarded by `Is_Connected`. The driver
  only calls into the session once `Message_Length`/`Authentication_Length`
  (`connection_driver.adb:658-728`) report a complete message or a complete EE..Finished flight, so
  partial CRYPTO data never reaches a parser that would treat `Need_More_Data` as fatal.
- **Signature algorithms**: the client accepts only ed25519 in CertificateVerify
  (`tls_session.adb:680`), so no downgrade to ECDSA or RSA-PSS is possible.
- **OpenSSL binding** (`crypto_openssl.adb`, `flyology_quic_openssl.c`): every C entry point validates
  arguments, calls `ERR_clear_error` before work and `provider_error` on failure, frees every
  `EVP_PKEY`/`EVP_PKEY_CTX`/`EVP_MD_CTX`/`X509` on all exits, and cleanses outputs on failure; the Ada side
  checks every return value, raises `Crypto_Error` on anything but 0/1, and sets `Verified`/`Authenticated`
  only on 0. `Unprotect` zeroes the plaintext on authentication failure, satisfying its postcondition.
  An all-zero X25519 shared secret is rejected by OpenSSL's derive (returns 0), which surfaces as
  `Crypto_Failed`; this relies on OpenSSL behaviour, not Ada code.
- **Crypto flight and reassembly** (`crypto_flight.adb`; `crypto_reassembly_policy.adb`, SPARK): bounds
  checked before conversion, conflicting overlaps rejected atomically, 64 KiB capacity exceeds the RFC 9000
  §7.5 4096-byte minimum.
- **Server TLS adapter** (`server-tls.adb`): pure forwarding to `Flyology.IO.TLS`; nothing to review.
- **Development certificates** (`development_certificates.adb`): reachable only through an explicit
  `Generate` call from the application (`showcases/http3_application_server.adb`,
  `showcases/http_application_server.adb`, the smoke test); it generates files and returns paths/bytes and
  touches no verification setting, so it cannot weaken a production path. Predictable temp names are
  handled by skipping existing directories; private-key file modes rely on the OpenSSL CLI's 0600 policy
  (observation below).

## Observations not counted

- **Handshake keys are not discarded after confirmation** (RFC 9001 §4.9.2): `Process_Handshake_Packet`
  in `Connected` still decrypts Handshake packets (`connection_driver.adb:1200-1208`). Only the real peer
  holds those keys, so unlike QUIC-TLS-1 there is no injection risk; a spec deviation only.
- **Client-side TLS failure on the ServerHello does not send CONNECTION_CLOSE**
  (`connection_driver.adb:1011-1015` sets `Failed` silently). RFC 9000 §10.2 says an endpoint "MUST use a
  CONNECTION_CLOSE frame if it is able"; the peer keeps retransmitting until idle timeout. Driver area.
- **Server signs with Ed25519 even when the client did not offer 0x0807**
  (`tls_extension_policy.adb:268` accepts 0x0403/0x0804 as "compatible"). RFC 8446 §4.4.3 permits this
  when no other chain exists, but such a client (BoringSSL-based browsers do not offer ed25519 by
  default) fails at CertificateVerify instead of receiving `handshake_failure` at the ClientHello.
- **Client offers ecdsa_secp256r1_sha256 and rsa_pss_rsae_sha256 that it will never accept**
  (`tls_extension_policy.adb:500-506` versus `tls_session.adb:680`). Misleading but harmless under
  Ed25519 pinning.
- **CertificateRequest is unsupported**: a server that requests client authentication is refused as
  `Certificate_Mismatch`; RFC 8446 §4.4.2 would have the client send an empty Certificate. Unusual
  configuration for a pinned deployment.
- **Provider contexts are shared per provider and not task-safe**: `protect_context`,
  `unprotect_context` and especially `header_context` (used by both send and receive) live in the
  `quic_crypto_module`. Neither `crypto_openssl.ads` nor `connections.ads` states that a connection must
  be driven by one task at a time. The maintained callers do serialize (HTTP/3 server: one `Worker` task
  owns a connection, `server-http_3.adb:2001-2040`; HTTP/3 client: pump claim in
  `http_3_client_connection.ads:48-52`), which I did not audit exhaustively (HTTP/3 area). A contract
  statement would make the requirement visible.
- **Four providers per connection**: `TLS_Session`, `Initial_Connection`, `Handshake_Connection` and
  `Application_Connection` each `dlopen` libcrypto and allocate three `EVP_CIPHER_CTX`
  (`initial_connection.adb:26`, `handshake_connection.adb:26`, `application_connection.adb:29`,
  `tls_session.adb:122`). Correct because OpenSSL 3 pins itself and dlopen refcounts; a resource cost only.
- **Development certificates**: the temporary directory is created with `Ada.Directories.Create_Directory`
  (umask-dependent, typically 0755) and key confidentiality rests on the `openssl` CLI writing private keys
  0600; certificates are valid for one day; `FLYOLOGY_HTTP_OPENSSL` names an executable to run. All
  development-only and opt-in.
- **Policy values seen and not questioned**: `Max_Certificate_DER` 16 000 / public bound 4 096,
  `Max_Transcript` 65 535, `Max_Crypto_Data` 65 536, 8 certificate entries, 128 extensions, 32 retained
  CRYPTO chunks. None breaks a protocol rule.
