Title: A stray CRLF before a request-line is rejected as malformed, and at EOF becomes a spurious 400
Labels: bug

## Summary

The request-line is taken as everything up to the first CRLF of the buffered head, and nothing skips an empty line first. A `CRLF` left over from a previous request therefore makes the request-line the empty string and the next request is rejected with `Protocol_Error "malformed HTTP request line"`. When the stray `CRLF` is the last thing the peer sends before closing, the parser sees two available octets instead of none and raises "peer closed inside HTTP headers", so the connection handler writes a 400 after an exchange that already succeeded.

## Problem

Commit `f078732`.

The request-line is split without skipping empty lines (`src/flyology-http-server.adb:1140-1148`):

```ada
         Available : constant String := To_String (Item.Pending);
         Head      : constant String := Available (1 .. Header_End - 1);
         Line_End  : constant Natural := Ada.Strings.Fixed.Index (Head, CRLF);
         Request_Line : constant String :=
           (if Line_End = 0 then Head else Head (Head'First .. Line_End - 1));
         Header_First : constant Natural :=
           (if Line_End = 0 then Head'Last + 1 else Line_End + CRLF'Length);
         First_Space : constant Natural :=
           Ada.Strings.Fixed.Index (Request_Line, " ");
```

When `Pending` begins with `CRLF`, `Line_End` is 1, `Request_Line` is empty and `First_Space` is 0, so the first guard fires (`src/flyology-http-server.adb:1155-1162`):

```ada
         if First_Space <= Request_Line'First
           or else Second_Space = 0
           or else Second_Space = First_Space + 1
           or else Second_Space = Request_Line'Last
           or else Ada.Strings.Fixed.Index
             (Request_Line (Second_Space + 1 .. Request_Line'Last), " ") /= 0
         then
            raise Protocol_Error with "malformed HTTP request line";
```

The EOF variant is the sharper one for an operator. `Inspect_Request_Head_Input` distinguishes a clean close from a truncated head by the number of buffered octets (`src/flyology-http-server.adb:1061-1067`):

```ada
      elsif not Input_Closed then
         return Request_Input_Needed;
      elsif Available'Length = 0 then
         Item.State := Terminal;
         return Request_Peer_Closed;
      else
         raise Protocol_Error with "peer closed inside HTTP headers";
```

A trailing `CRLF` makes `Available'Length` two rather than zero, so a peer that finishes its last exchange and closes is reported as having truncated a header block. `Connection_Handlers.Serve` then answers the `Protocol_Error` with a best-effort 400 and closes (`src/flyology-http-server-connection_handlers.adb:109-111`).

RFC 9112 section 2.2 asks for the opposite: "In the interest of robustness, a server that is expecting to receive and parse a request-line SHOULD ignore at least one empty line (CRLF) received prior to the request-line." The same section names where the input comes from: "Older HTTP/1.0 user agent implementations might send an extra CRLF after a POST request as a workaround for some early server applications that failed to read message body content that was not terminated by a line-ending." An HTTP/1.1 user agent "MUST NOT preface or follow a request with an extra CRLF", which is what keeps the impact narrow.

No maintained test places a `CRLF` before a request-line: neither `tests/http_smoke.adb` nor `tests/http_server_audit.adb` contains such a case.

## What happens now

Spike: both variants are driven through `Read_Request` on an in-memory `Flyology.HTTP.Server.Transport`. Variant A pipelines `POST /a` with a one-byte body, the stray `CRLF`, then `GET /b`; variant B ends the input after the stray `CRLF`. Each check asserts the RFC 9112 section 2.2 outcome: the empty line is skipped and the request behind it is served, or the close is clean.

```ada
      Channel.Input := To_Unbounded_String
        (First_Request & CRLF & Second_Request);
   ...
            Expect_Equal
              (HTTP_Server.Target (Value), "/b",
               "pipelined request behind a stray CRLF is served");
   ...
      Channel.Input := To_Unbounded_String (First_Request & CRLF);
   ...
            Check
              (Closed,
               "a stray CRLF then FIN is a clean close between requests");
```

```
  note RFC 9112 section 2.2 SHOULD-ignore of one empty line before a
  note request-line; the extra CRLF an HTTP/1.0 agent sends after a POST
  ok   first request target
  ok   first request content
  FAIL pipelined request behind a stray CRLF is served
  note   raised Protocol_Error: malformed HTTP request line
  ok   first request target (EOF)
  FAIL a stray CRLF then FIN is a clean close between requests
  note   raised Protocol_Error: peer closed inside HTTP headers
checks: 5  failures: 2
BUG REPRODUCED
```

The first request is served correctly in both variants, so only the handling of the stray `CRLF` is at issue.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

At least one empty line received before a request-line should be discarded, and an input that holds nothing but such an empty line when the peer closes should be reported as a clean close between requests rather than as a truncated header block.

## Suggested treatment

Consume a leading `CRLF` from `Pending` before the head is inspected, in one place that both `Inspect_Request_Head_Input` and `Read_Request_Head_Impl` see, so the empty-line skip and the clean-close test agree. Discarding exactly one empty line meets the SHOULD without opening an unbounded prefix.

This needs a maintainer decision if more than one empty line is to be tolerated: the count is a new bound under "Decision authority" and "Ada interface values". The options are a private implementation value in `src/flyology-http-server.adb`, a value derived from the existing `Max_Header_Bytes` contract, a caller parameter on `Read_Request`, a generic formal on `Connection_Handlers`, build-time configuration, or a deliberately public constant. RFC 9112 section 2.2 requires only "at least one", so discarding exactly one introduces no new number.

`src/flyology-http-server.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in `tests/http_smoke.adb`, which already owns the in-memory transport and the request-parsing cases: a pipelined request behind a stray `CRLF`, and a stray `CRLF` followed by end of input. The spike is the test. No existing test asserts the current behaviour, so nothing has to change.

## Severity

A peer that emits the legacy extra `CRLF` after a POST loses the next pipelined request to a 400 and the connection is closed, and a peer that emits it before closing gets a 400 written after a response that already succeeded, which an operator sees as an error on a healthy connection. An HTTP/1.1 agent is forbidden from sending the extra `CRLF`, and it was not verified against a pinned peer that any current stock client still emits it, so that part of the exposure is not verified against a peer. Deterministic given the input.
