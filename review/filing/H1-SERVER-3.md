Title: A request with an unknown transfer coding is answered 400 where RFC 9112 asks for 501
Labels: bug

## Summary

The request parser raises one `Protocol_Error` for every rejection it makes, and the connection handler can only map that to 400. `Transfer-Encoding: gzip, chunked` on an HTTP/1.1 request is therefore answered 400 where RFC 9112 section 6.1 says a server SHOULD respond with 501. Four neighbouring rejections collapse to the same 400 for the same reason; none of those four is required by the standards to use a different status, but together they mean an application cannot tell an oversized head, an unsupported method, an unsupported version and a malformed request apart.

## Problem

Commit `f078732`.

An unrecognised transfer coding raises the general protocol error (`src/flyology-http-server.adb:1286-1292`):

```ada
         if Transfer_Count /= 0 then
            if Value.Version_Value /= HTTP_1_1
              or else Transfer_Count > 1
              or else Lower (Trim (Transfer_Value)) /= "chunked"
            then
               raise Protocol_Error with
                 "unsupported request Transfer-Encoding";
```

`Connection_Handlers.Serve` has one mapping for that exception (`src/flyology-http-server-connection_handlers.adb:109-111`):

```ada
            when Protocol_Error =>
               Best_Effort_Bad_Request;
               return;
```

and `Routing.Serve` answers 400 for it too (`src/flyology-http-server-routing.adb:2104-2109`).

RFC 9112 section 6.1 is the one clause here that asks for something else: "A server that receives a request message with a transfer coding it does not understand SHOULD respond with 501 (Not Implemented)."

### The neighbouring rejections

Four other inputs reach the same single 400, and it is worth saying precisely what the standards do and do not require of them, because none of the four is a normative deviation:

- A head over `Max_Header_Bytes` (`src/flyology-http-server.ads:22`, 32 KiB) raises "HTTP request headers are too large" at `src/flyology-http-server.adb:1059-1060`. 431 is defined in RFC 6585 section 5, not in RFC 9110, and it is permissive: "It can be used both when the set of request header fields in total is too large, and when a single header field is at fault." There is no MUST or SHOULD. RFC 9110 section 15.5.15 is 414 URI Too Long, not 431.
- `CONNECT` is refused at `src/flyology-http-server.adb:805-806`. RFC 9110 section 9.3.6 says only "An origin server MAY accept a CONNECT request, but most origin servers do not implement CONNECT", and imposes a status only for a bad port: "A server MUST reject a CONNECT request that targets an empty or invalid port number, typically by responding with a 400 (Bad Request) status code." 501 would fit RFC 9110 section 15.6.2 and 405 would require an `Allow` field under section 15.5.6, but neither is required here.
- `GET / HTTP/1.2` is refused at `src/flyology-http-server.adb:1182-1187`. There is no recipient requirement in RFC 9112 or RFC 9110 to process a higher minor version as the highest conformant one; that sentence is RFC 7230 section 2.6, which RFC 9112 obsoletes. RFC 9112 section 2.3 and RFC 9110 section 2.5 carry no such rule.
- `GET / HTTP/2.0` on a cleartext HTTP/1 listener is refused by the same branch. 505 is defined in RFC 9110 section 15.6.6, not in RFC 9112, and it is descriptive: "The 505 (HTTP Version Not Supported) status code indicates that the server does not support, or refuses to support, the major version of HTTP that was used in the request message."

`Transfer-Encoding: chunked` on an HTTP/1.0 request also reaches the 501 branch above, but that case is already conformant: RFC 9112 section 6.1 says of it only that a recipient "MUST treat the message as if the framing is faulty, even if a Content-Length is present, and close the connection after processing the message", which 400 plus close satisfies.

`Flyology.HTTP.Headers.Headers_Too_Large` exists (`src/flyology-http-headers.ads:19`) but the server parser never raises it, so an application cannot distinguish these cases through the exception either.

Existing coverage pins only that CONNECT is rejected (`tests/http_smoke.adb:2156-2159`), through `Is_Rejected` (`tests/http_smoke.adb:2098-2113`), which checks only that `Protocol_Error` is raised and never inspects the status. No test asserts a status for any of the rows.

## What happens now

Spike: each input is driven through `Connection_Handlers.Serve` on an in-memory `Flyology.HTTP.Server.Transport` and the status line in the written output is read back. The four rows with no normative requirement are recorded as observations. The single assertion is the row RFC 9112 section 6.1 backs.

```ada
   Note
     ("head over Max_Header_Bytes -> "
      & Serve_Once (Oversized) & " (431 would be RFC 6585 section 5)");
   ...
   --  The one normative row: RFC 9112 section 6.1 SHOULD respond with 501.
   Expect_Equal
     (Serve_Once
        ("POST / HTTP/1.1" & CRLF & "Host: h" & CRLF
         & "Transfer-Encoding: gzip, chunked" & CRLF & CRLF
         & "0" & CRLF & CRLF),
      "501",
      "unknown transfer coding answers 501 (RFC 9112 section 6.1)");
```

```
  note head over Max_Header_Bytes -> 400 (431 would be RFC 6585 section 5)
  note CONNECT with a matching Host -> 400 (405 or 501 would be RFC 9110 section 15.5.6 or 15.6.2)
  note GET / HTTP/1.2 -> 400 (RFC 9112 no longer carries the RFC 7230 minor-version SHOULD)
  note GET / HTTP/2.0 on a cleartext HTTP/1 listener -> 400 (505 is RFC 9110 section 15.6.6, described not required)
  note Transfer-Encoding: chunked on HTTP/1.0 -> 400 (RFC 9112 section 6.1 requires only faulty-framing plus close)
  FAIL unknown transfer coding answers 501 (RFC 9112 section 6.1)
         expected: [501]
         actual:   [400]
checks: 1  failures: 1
BUG REPRODUCED
```

Every row answers a single 400 and closes.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A request carrying a transfer coding the server does not understand should be answered 501, as RFC 9112 section 6.1 states. The other four rows are conformant as they stand; improving their statuses is a diagnostics change, not a correctness fix.

## Suggested treatment

Distinguish the unknown-transfer-coding case from the general malformed-request case so that the handler can select 501. The narrow change is a distinct exception, or a discriminated reason carried with `Protocol_Error`, raised at `src/flyology-http-server.adb:1291-1292` and mapped in `Connection_Handlers.Serve` (`src/flyology-http-server-connection_handlers.adb:109-111`) and in `Dispatch_Configuration` (`src/flyology-http-server-routing.adb:2104-2109`). The HTTP/1.0-with-`Transfer-Encoding` branch must keep answering 400 plus close, so the condition at `:1287-1289` has to be split rather than given one status.

This needs a maintainer decision, because it adds to the rejection vocabulary that `src/flyology-http-server.ads` and the routing layer expose. The options are a new exception in the server specification, a reason discriminant or classification function kept private to the body with the status chosen inside the handler, reusing the existing `Flyology.HTTP.Headers.Headers_Too_Large` for the oversized-head row and adding a sibling for transfer codings, a caller parameter or generic formal on `Connection_Handlers` that supplies the status mapping, or leaving the status mapping as it is and treating the whole entry as a documentation change. The choice also settles whether the four conformant rows get their conventional statuses at the same time.

`src/flyology-http-server.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in `tests/http_smoke.adb`, beside the CONNECT rejection at `:2156-2159`, and it needs a status-observing helper rather than `Is_Rejected` at `:2098-2113`, which discards the status. The spike is the test. No existing test asserts the current 400 for an unknown transfer coding, so nothing has to change.

## Severity

An unknown transfer coding is answered with the wrong status. No message-boundary ambiguity results, because the connection closes either way, and no stock peer is broken by the difference. What is lost is diagnosis: a client or proxy that keys retry or fallback behaviour on 501 cannot distinguish an unsupported coding from a malformed request, and four further rejections are indistinguishable from each other and from a genuinely malformed request. Deterministic.
