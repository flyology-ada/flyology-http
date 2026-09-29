Title: QUIC server matches only the first ALPN entry of the ClientHello instead of selecting from the list
Labels: bug
Refs: none

## Summary

The ClientHello extension parser records only the first entry of the ALPN protocol list, and the server compares that single entry with its configured protocol. A client that offers `["h3-29", "h3"]` to a server configured for `h3` is therefore refused with `ALPN_Mismatch`, which the driver sends as CONNECTION_CLOSE 0x178, although a mutually supported protocol was advertised. The server selects nothing; it only tests whether the client's first preference happens to be its own.

## Problem

Commit `f078732`.

`Parse_ALPN` walks the whole list but keeps only the first name (`flyology_quic/src/flyology-quic-tls_extension_policy.adb:220-224`):

```ada
            if not Result.Has_ALPN then
               Result.Has_ALPN := True;
               Result.ALPN_Protocol_Offset := Cursor_Pos;
               Result.ALPN_Protocol_Length := Name_Length;
            end if;
```

`Validate_Extensions` compares that one recorded entry with the configured protocol and rejects anything else (`flyology_quic/src/flyology-quic-tls_session.adb:180-189`):

```ada
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
      end if;
```

`ALPN_Mismatch` reaches the wire as 0x178 through the case expression at `flyology_quic/src/flyology-quic-connection_driver.adb:945-951`.

The same parser also serves the client's check of EncryptedExtensions, where recording one entry is correct, because exactly one entry is required there and the length test at `flyology_quic/src/flyology-quic-tls_extension_policy.adb:369-370` enforces it:

```ada
                   (Context = Encrypted_Extensions
                    and then Value_Length /= 3 + Result.ALPN_Protocol_Length)
```

There is no equivalent constraint on a ClientHello, and there must not be: RFC 7301 section 3.2 says "the server SHOULD select the most highly preferred protocol that it supports and that is also advertised by the client. In the event that the server supports no protocols that the client advertises, then the server SHALL respond with a fatal 'no_application_protocol' alert." The selection rule is a SHOULD. The SHALL is the alert, and its trigger condition, that the server supports none of the advertised protocols, is not met when `h3` appears anywhere in the list. RFC 9001 section 8.1 attaches 0x178 to the case where "an application protocol is not negotiated", which is likewise not this case.

The existing test covers a single-entry list only (`flyology_quic/tests/src/flyology-quic-tls_extension_policy-smoke.adb:80-89`), asserting `Has_ALPN`, a length of 4 and the bytes at the recorded offset. A multi-entry list is not tested anywhere, and neither is the ALPN path of `Accept_Client_Hello`.

## What happens now

Spike: it takes the real ClientHello that `TLS_Session.Start_Client` produces, replaces the single-entry ALPN body with the two-entry list `05 "h3-29" 02 "h3"`, repairs the extensions-block length and the handshake message length, and hands the result to a server initialized with ALPN `h3`. It asserts that `Accept_Client_Hello` succeeds. A control case feeds the same server the unpatched single-entry Hello, so a failure of the patching itself would show up as a failing control.

```ada
      Accept_Client_Hello
        (Server_Session, Patched (1 .. New_Length),
         Server_Hello, Authentication, Server_Result);
```

The assertion is `Server_Result.Status = Succeeded`.


```
  note patched ClientHello ALPN list = 05 'h3-29' 02 'h3'; server ALPN = h3
  note Accept_Client_Hello status = ALPN_MISMATCH
  FAIL the server selects h3 from the offered ALPN list
  ok   control: the single-entry list h3 is accepted
checks: 2  failures: 1
BUG REPRODUCED
```

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

The server should select a protocol it supports from the offered list, wherever in the list it appears, and should send `no_application_protocol` only when the list contains none of the protocols it supports, as RFC 7301 section 3.2 states.

## Suggested treatment

`Parse_ALPN` already walks every entry. The smallest change is to record enough of the list for `Validate_Extensions` to search it, then have `Validate_Extensions` look for the configured protocol among the recorded entries rather than testing the first one.

This needs a maintainer decision, in two parts. First, recording more than one entry introduces a bound on how many entries `Parse_Result` carries, and `Parse_Result` is declared in a specification. The options are a private implementation value, a caller parameter, a generic formal, a discriminant, a value derived from a type or contract such as the existing extension-count bound, build-time configuration, or a deliberately public constant. Second, when the server supports more than one protocol the RFC leaves the preference order open, so whether the client's order or the server's order wins is a policy choice. Do not settle either here. An alternative that avoids both decisions is to keep one recorded entry but have `Parse_ALPN` record the entry that matches a protocol the caller supplies, which turns the parser's job from "first entry" into "requested entry" and needs no new bound.

`flyology-quic-tls_extension_policy.adb` is one of the units `./scripts/prove.sh` proves, through `flyology_quic/scripts/prove.sh`. Any change to `Parse_ALPN` or to `Parse_Result` must keep that proof discharging with `--checks-as-errors=on`.

The regression test belongs in the existing extension-policy smoke suite at `flyology_quic/tests/src/flyology-quic-tls_extension_policy-smoke.adb`, extending the single-entry case at :80-89 rather than replacing it, with the end-to-end case added to `flyology_quic/tests/src/flyology-quic-tls_session-smoke.adb`. The spike is the test. No existing test asserts the current behaviour, so none has to change.

## Severity

A client that offers more than one protocol cannot connect to this server even when the server supports one of them, and the failure is a connection close rather than a negotiation result. The trigger is unusual with current peers: mainstream QUIC clients offer `h3` alone, which is why the interop runs and every existing test pass. It becomes reachable as soon as a client offers a draft alias alongside `h3`, or any second protocol. Deterministic.
