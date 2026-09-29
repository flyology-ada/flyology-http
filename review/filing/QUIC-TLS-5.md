Title: TLS certificate, signature and Finished failures close the QUIC connection with internal_error instead of the required alerts
Labels: bug
Refs: none

## Summary

The driver maps four `TLS_Session` statuses to QUIC error codes by name and sends `internal_error` for everything else. `Certificate_Mismatch`, `Signature_Failed` and `Finished_Failed` all fall into that `others` arm, so a peer that fails authentication is told CRYPTO_ERROR 0x150, which is `internal_error(80)`, a code RFC 8446 reserves for failures unrelated to the peer. The peer and any log reader see a local fault where the truth is a rejected certificate or a signature that did not verify.

## Problem

Commit `f078732`.

The client maps the result of `Accept_Server_Authentication` like this (`flyology_quic/src/flyology-quic-connection_driver.adb:1108-1115`):

```ada
               Fail_Handshake_With_Close
                 (Item,
                  Error_Code =>
                    (case TLS_Result.Status is
                        when TLS_Session.ALPN_Mismatch => 16#178#,
                        when TLS_Session.Invalid_Extensions => 16#16D#,
                        when TLS_Session.Invalid_Message => 16#10A#,
                        when others => 16#150#),
```

The same `others => 16#150#` arm appears in the server's ClientHello path (`flyology_quic/src/flyology-quic-connection_driver.adb:945-951`) and in the client Finished path, which has only two arms (`flyology_quic/src/flyology-quic-connection_driver.adb:1160-1162`):

```ada
                  Error_Code =>
                    (if TLS_Result.Status = TLS_Session.Invalid_Message
                     then 16#10A# else 16#150#),
```

RFC 9001 section 4.8 maps a TLS alert to a QUIC error code by adding 0x100 to the alert number, and it does allow a generic substitute: "QUIC permits the use of a generic code in place of a specific error code ... this includes replacing any alert with a generic alert, such as handshake_failure (0x0128 in QUIC)". 0x150 is not a generic code. It is `internal_error(80)`, which RFC 8446 section 6.2 defines as "An internal error unrelated to the peer or the correctness of the protocol (such as a memory allocation failure)". The code therefore states the opposite of what happened.

The two codes the failures call for are in the same sections. RFC 8446 section 6.2 defines `bad_certificate(42)`, QUIC 0x12A, for a certificate that "was corrupt, contained signatures that did not verify correctly, etc.". RFC 8446 section 4.4.3 is mandatory for the signature case: "If the verification fails, the receiver MUST terminate the handshake with a 'decrypt_error' alert", which is alert 51 and QUIC 0x133; section 4.4.4 says the same for a Finished that does not verify.

There is a second site in the same family, reported here because it shares the mapping and the fix. An EncryptedExtensions message with no ALPN extension is `Missing_Required_Extension` in the extension policy (`flyology_quic/src/flyology-quic-tls_extension_policy.ads:19-26`), but `TLS_Handshake_Policy` has no such status and collapses it into `Invalid_Extensions` (`flyology_quic/src/flyology-quic-tls_handshake_policy.ads:21-26`, collapsed at `flyology-quic-tls_handshake_policy.adb:141` and `:227`). `TLS_Session` passes that through unchanged at `flyology_quic/src/flyology-quic-tls_session.adb:297-299`, `:521-522` and `:598-599`:

```ada
         Result.Status :=
           (if Hello.Status = TLS_Handshake_Policy.Invalid_Extensions
            then Invalid_Extensions else Invalid_Message);
```

so the driver sends 0x16D, `missing_extension`. RFC 9001 section 8.2 gives 0x16D to a missing `quic_transport_parameters` extension, which the driver does map correctly elsewhere, and RFC 9001 section 8.1 requires 0x178 when ALPN negotiation fails. This sub-claim is established by reading the code and is not reproduced below.

No test inspects an emitted CONNECTION_CLOSE error code. `flyology_quic/tests/src/flyology-quic-tls_session-smoke.adb:215-218` asserts `Result.Status = Finished_Failed` at the session level and stops there, so the mapping from a session status to a wire code is untested in either direction.

## What happens now

Spike: it drives a real in-process handshake between two connection drivers and makes the server fail authentication in two ways, then delivers the client's CONNECTION_CLOSE datagram back to the live server driver so that the server decrypts it with its own Handshake keys and reports `Peer_Close_Error`. The code on the wire is read from the server, not decoded by hand. Case 1 pins a certificate that differs from the server's by one byte of the subjectPublicKey. Case 2 pins the genuine certificate and has the server sign CertificateVerify with a different Ed25519 seed.

```ada
   --  RFC 8446 6.2: bad_certificate(42) for a certificate the peer will not
   --  accept; QUIC maps a TLS alert A to 0x100 + A, so 0x12A.
   Run_Case
     ("pinned certificate mismatch", Wrong_Pin, Private_Key,
      16#12A#, "CRYPTO_ERROR + bad_certificate");

   --  RFC 8446 4.4.3: a CertificateVerify that does not verify "MUST
   --  terminate the handshake with a decrypt_error alert" (51), QUIC 0x133.
   Run_Case
     ("CertificateVerify signed with a foreign key", Certificate, Foreign_Key,
      16#133#, "CRYPTO_ERROR + decrypt_error");
```

```
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
```

336 is 0x150. The expected codes print as 298 (0x12A) and 307 (0x133). The four `ok` lines show the authentication itself is correct in both cases: the client ends in `Failed` and does send a close. Only the code it carries is wrong.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A certificate the client will not accept should close with CRYPTO_ERROR 0x12A, and a CertificateVerify or Finished that does not verify should close with CRYPTO_ERROR 0x133, as RFC 8446 sections 6.2, 4.4.3 and 4.4.4 require through the RFC 9001 section 4.8 mapping. An EncryptedExtensions with no ALPN extension should close with 0x178, not 0x16D.

## Suggested treatment

Replace the `others` arm at all three sites with explicit arms for `Certificate_Mismatch` (0x12A), `Signature_Failed` (0x133) and `Finished_Failed` (0x133), and keep a generic code only for statuses that really are local faults, such as `Crypto_Failed` and `Transcript_Too_Large`. Giving the three sites one shared mapping function would also stop them drifting apart, which is how the Finished path came to have two arms where the others have five.

The ALPN half needs a maintainer decision, because fixing it means adding a status to `TLS_Handshake_Policy.Parse_Status` so that a missing required extension is distinguishable from an invalid one, and that enumeration is declared in a specification. The options are a private implementation value, a caller parameter, a generic formal, a discriminant, a value derived from a type or contract by having `TLS_Session` consult the extension policy's own `Missing_Required_Extension` result directly, build-time configuration, or a deliberately public enumeration literal. Do not settle it here.

`flyology-quic-tls_handshake_policy.adb` and `flyology-quic-tls_extension_policy.adb` are both units `./scripts/prove.sh` proves, through `flyology_quic/scripts/prove.sh`. A new status literal or a changed collapse must keep those proofs discharging with `--checks-as-errors=on`. The driver itself is outside the proved set.

The regression test belongs in the existing QUIC transport smoke suite, `flyology_quic/tests/src/flyology-quic-tls_transport_smoke.adb`, which already drives datagrams between two drivers and can therefore read `Peer_Close_Error` the way the spike does. The spike is the test. No existing test asserts the current codes, so none has to change.

## Severity

No connection succeeds that should fail and none fails that should succeed: the authentication decisions are correct and only the reported reason is wrong. The cost is diagnostic. A peer, a qlog reader or an operator sees a code that says the failure had nothing to do with the peer or the protocol, when in fact the certificate was rejected or a signature did not verify, and `internal_error` is the one code that positively misdirects that investigation. It happens on every certificate, signature and Finished failure, which is the whole authentication failure surface of the pinning profile. Deterministic; the missing-ALPN case is reported from reading the code and is not reproduced.
