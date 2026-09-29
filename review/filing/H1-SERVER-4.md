Title: Absolute-form request-target with a differing Host is refused instead of the Host field being ignored
Labels: bug, documentation

## Summary

`Validate_Target_And_Authority` compares the `Host` field against the authority of an absolute-form request-target and raises `Protocol_Error "Host conflicts with request target"` when they differ. RFC 9112 section 3.2.2 requires an origin server to ignore `Host` in exactly that case, and section 3.2 does not list a disagreeing but valid `Host` among the cases that must answer 400. The rejection is pinned by a maintained test, so it reads as a chosen hardening rather than an oversight, and the right first step is to say so in the documentation.

## Problem

Commit `f078732`.

The comparison sits in the target validator (`src/flyology-http-server.adb:843-848`):

```ada
            elsif Host'Length > 0
              and then Lower (Host) /= Lower
                (Request_Target (Authority_First .. Authority_Last))
            then
               raise Protocol_Error with "Host conflicts with request target";
```

The parser already selects the target's authority as `Authority_Value` (`src/flyology-http-server.adb:1211-1247`), so the "instead use the host information of the request-target" half of the requirement is honoured. Only the extra refusal deviates.

RFC 9112 section 3.2.2 states: "When an origin server receives a request with an absolute-form of request-target, the origin server MUST ignore the received Host header field (if any) and instead use the host information of the request-target."

RFC 9112 section 3.2 enumerates the `Host` cases that must answer 400: "A server MUST respond with a 400 (Bad Request) status code to any HTTP/1.1 request message that lacks a Host header field and to any request message that contains more than one Host header field line or a Host header field with an invalid field value." A valid `Host` that merely disagrees with the target is not among them.

The rejection is asserted as intended by the maintained suite (`tests/http_smoke.adb:2152-2155`):

```ada
      pragma Assert
        (Is_Rejected
           ("GET http://example.test/ HTTP/1.1" & CRLF
            & "Host: other.test" & CRLF & CRLF));
```

so this is contract drift the maintainer chose, not a defect that slipped in. Changing the behaviour would require that assertion to be inverted.

One consequence the test does not cover is worth flagging. The comparison is exact, so `GET http://example.test:8080/p?q HTTP/1.1` with `Host: example.test` is also refused. Such a client is itself non-conformant, because RFC 9112 section 3.2 says "If the target URI includes an authority component, then a client MUST send a field value for Host that is identical to that authority component, excluding any userinfo subcomponent and its "@" delimiter", so the refusal is defensible. It does widen the set of inputs the policy rejects beyond the literal MUST at issue, and nothing in the documentation says so.

## What happens now

Spike: three absolute-form requests are driven through `Read_Request` on an in-memory `Flyology.HTTP.Server.Transport`. The baseline is an absolute-form target with an agreeing `Host`, which shows that the absolute form itself is supported and only the disagreement is refused. Each check asserts the RFC 9112 section 3.2.2 outcome: the request is served and the target's authority wins.

```ada
   Probe
     ("absolute form with an agreeing Host (baseline)",
      "GET http://example.test/ HTTP/1.1" & CRLF
      & "Host: example.test" & CRLF & CRLF,
      "http://example.test/", "example.test");

   Probe
     ("absolute form with a differing Host",
      "GET http://example.test/ HTTP/1.1" & CRLF
      & "Host: other.test" & CRLF & CRLF,
      "http://example.test/", "example.test");

   Probe
     ("absolute form with a differing Host port",
      "GET http://example.test:8080/p?q HTTP/1.1" & CRLF
      & "Host: example.test" & CRLF & CRLF,
      "http://example.test:8080/p?q", "example.test:8080");
```

```
  note RFC 9112 section 3.2.2 origin-server MUST-ignore of Host under an
  note absolute-form request-target
  ok   absolute form with an agreeing Host (baseline) target
  ok   absolute form with an agreeing Host (baseline) authority
  FAIL absolute form with a differing Host target
  note   raised Protocol_Error: Host conflicts with request target
  FAIL absolute form with a differing Host port target
  note   raised Protocol_Error: Host conflicts with request target
checks: 4  failures: 2
BUG REPRODUCED
```

The baseline passes, so the absolute form is supported; both the differing-host and the differing-port cases are refused.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

An origin server that receives an absolute-form request-target should ignore the `Host` field and serve the request against the target's authority, as RFC 9112 section 3.2.2 requires. If the stricter refusal is the intended posture, the documentation should state it as a deliberate deviation and say that the comparison is exact, including the port.

## Suggested treatment

Treat this as a documentation change unless the maintainer wants the behaviour changed, because `tests/http_smoke.adb:2152-2155` pins the rejection as intended. Record in `src/flyology-http-server.ads`, beside the request-parsing contract, that an absolute-form request-target whose authority disagrees with a present `Host` field is refused with `Protocol_Error` rather than having the `Host` ignored, that this is a deliberate hardening against host-based confusion at an intermediary, and that the comparison is exact so a differing port is refused as well. The guide page that covers request parsing under `website/` should carry the same sentence.

If the maintainer instead wants the MUST honoured, delete the comparison at `src/flyology-http-server.adb:843-848` and invert the assertion at `tests/http_smoke.adb:2152-2155` to expect `Target = "http://example.test/"` and `Authority = "example.test"`. That is a behaviour change to a validation the suite currently pins, so it needs the owner's decision rather than a silent edit. A middle option is to keep the refusal but restrict it to the case the hardening actually targets, comparing only the host subcomponent and ignoring a port mismatch.

`src/flyology-http-server.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

If the behaviour changes, the regression test is the inverted assertion in `tests/http_smoke.adb` at `:2152-2155`, extended with the differing-port case the spike adds. The spike is the test.

## Severity

A conformant absolute-form request whose `Host` disagrees with the target is answered 400 and the connection closes, where the standard requires the `Host` to be ignored. No stock client produces this without operator intervention, since a conformant client must send a `Host` identical to the target authority, and the refusal is the safer posture against host-based confusion at an intermediary. The wider effect is that a differing port is refused too, which is not documented anywhere. Deterministic.
