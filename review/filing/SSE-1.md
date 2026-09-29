Title: HTTP/2 and HTTP/3 SSE serialisers drop a trailing line terminator that the HTTP/1.1 serialiser preserves
Labels: bug
Refs: none

## Summary

One serialisation of an SSE event exists three times, once per backend, and the three copies disagree. The HTTP/1.1 data loop ends with a branch that appends an extra empty `data:` line when the terminator it just consumed was the final character of `Data`; the HTTP/2 and HTTP/3 copies stop one branch earlier. Because a conformant client strips exactly one trailing line feed at dispatch, that extra field is the only way a trailing terminator can be conveyed, so the same `Send_SSE` call delivers different event data depending on the negotiated protocol. `Data => LF` alone becomes indistinguishable from `Data => ""` on two of the three backends.

## Problem

Commit `f078732`.

The HTTP/1.1 data loop (`src/flyology-http-server.adb:3346-3355`):

```ada
               First := Break + 1;
               if Data (Break) = Character'Val (13)
                 and then First <= Data'Last
                 and then Data (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
               if First > Data'Last then
                  Append (Payload, "data:" & Character'Val (10));
               end if;
```

The HTTP/2 copy is the same loop without the last branch (`src/flyology-http-server-http_2.adb:1986-1993`):

```ada
               First := Break + 1;
               if Data (Break) = Character'Val (13)
                 and then First <= Data'Last
                 and then Data (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
            end;
```

and so is the HTTP/3 copy (`src/flyology-http-server-http_3.adb:1322-1329`):

```ada
               First := Break + 1;
               if Data (Break) = Character'Val (13)
                 and then First <= Data'Last
                 and then Data (First) = Character'Val (10)
               then
                  First := First + 1;
               end if;
            end;
```

All three are reached from the same public call, `Applications.Send_SSE`, so the application cannot tell which one will run.

The WHATWG HTML Standard, "Server-sent events", section "Interpreting an event stream", fixes what the extra field means. For a `data` field:

> "Append the field value to the data buffer, then append a single U+000A LINE FEED (LF) character to the data buffer."

and in the dispatch algorithm:

> "If the data buffer's last character is a U+000A LINE FEED (LF) character, then remove the last character from the data buffer."

The line feed contributed by the last real `data` field is the one that is stripped, so a trailing terminator in the application's value survives only when a further empty `data` field contributes another.

No maintained test sends `Data` ending in a terminator on any backend, which is why the suites are green. `tests/http_smoke.adb:827-834` drives HTTP/1.1 with an embedded LF and an embedded CR but never a trailing one. `tests/http2_server_audit.adb:71-87` (`Events`) exercises injection and UTF-8 rejection only. The HTTP/2 and HTTP/3 SSE integration tests drive raw `Begin_Stream` and `Write_Chunk` rather than `Send_SSE`. The pinned conformance peers do not bear on this either: h2spec 2.6.0 tests HTTP/2 framing and header conformance rather than SSE payload semantics, the HTTP/3 interop runs against aioquic 1.3.0 and quic-go 0.54.1 are request and response exchanges, and Autobahn is WebSocket.

## What happens now

Spike: one route registered with `Upgrade => Routing.Allow_SSE` whose handler makes a single call, `X.Send_SSE (Data => "a" & LF)`. The program serves that route over all three backends in process, HTTP/1.1 and HTTP/2 over loopback TCP and HTTP/3 over loopback UDP, and for each backend reads the serialised body twice: once as an ordinary GET, to see the bytes, and once through `Flyology.HTTP.Client.SSE`, which is the parser the library ships.

```ada
   Sent_Data      : constant String := "a" & LF;
   Expected_Event : constant String := "a" & LF;
   Expected_Wire  : constant String :=
     "data: a" & LF & "data:" & LF & LF;
   ...
      X.Begin_SSE;
      X.Send_SSE (Data => Sent_Data);
      X.End_SSE;
```

```
  note application sends Data => "a" & LF on one route, three backends
  note expected wire: data: a\x0adata:\x0a\x0a
  note expected dispatched data: a\x0a
  note HTTP/1.1 wire bytes: data: a\x0adata:\x0a\x0a
  ok   HTTP/1.1 serialised SSE body
  ok   HTTP/1.1 dispatched an event
  note HTTP/1.1 dispatched data: a\x0a
  ok   HTTP/1.1 dispatched event data
  note HTTP/2 wire bytes: data: a\x0a\x0a
  FAIL HTTP/2 serialised SSE body
         expected: [data: a\x0adata:\x0a\x0a]
         actual:   [data: a\x0a\x0a]
  ok   HTTP/2 dispatched an event
  note HTTP/2 dispatched data: a
  FAIL HTTP/2 dispatched event data
         expected: [a\x0a]
         actual:   [a]
  note HTTP/3 wire bytes: data: a\x0a\x0a
  FAIL HTTP/3 serialised SSE body
         expected: [data: a\x0adata:\x0a\x0a]
         actual:   [data: a\x0a\x0a]
  ok   HTTP/3 dispatched an event
  note HTTP/3 dispatched data: a
  FAIL HTTP/3 dispatched event data
         expected: [a\x0a]
         actual:   [a]
checks: 9  failures: 4
BUG REPRODUCED
```

HTTP/1.1 writes `data: a` LF `data:` LF LF and the client dispatches `"a\n"`. HTTP/2 and HTTP/3 write `data: a` LF LF and the client dispatches `"a"`.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

One `Send_SSE` call should produce one event value on every backend. `Data` ending in LF, CR or CRLF should be serialised with the trailing empty `data` field the WHATWG dispatch algorithm requires, as the HTTP/1.1 writer already does, so the client reconstructs the value the application passed.

## Suggested treatment

The narrow fix is to append the missing branch to the two loops, matching `src/flyology-http-server.adb:3353-3355` exactly, at `src/flyology-http-server-http_2.adb:1992` and `src/flyology-http-server-http_3.adb:1328`.

The durable fix is to remove the duplication that produced the divergence: the three data loops build the same byte string from the same inputs and differ only in where the result is written, so one shared serialiser called by all three backends leaves nothing to drift. `Validate_SSE_Field`, the UTF-8 validation and the newline splitting of `Data` and of comments are already identical across `src/flyology-http-server.adb`, `src/flyology-http-server-http_2.adb` and `src/flyology-http-server-http_3.adb`, so the shared unit has a clean boundary. `Send_SSE_Comment` has the same three-way duplication but no trailing-terminator branch on any backend, so comments are consistent today and would stay consistent under either fix.

The regression tests belong in the maintained suites that already drive `Send_SSE`: `tests/http2_server_audit.adb` beside the `Events` handler at `:71-87` for HTTP/2, `tests/http3_server_integration.adb` for HTTP/3, and `tests/http_smoke.adb` beside `:827-834` for HTTP/1.1. Each should send `Data` ending in a terminator and assert the serialised bytes. The spike is the test, and it asserts both the wire bytes and the value the shipped client dispatches.

## Severity

An application that sends event data ending in a newline, which includes anything built by appending lines, loses that character on HTTP/2 and HTTP/3 and keeps it on HTTP/1.1, so the payload a consumer receives depends on ALPN rather than on the application. Nothing detects the loss: the framing is well formed on every backend, a stock SSE client parses both bodies without complaint, and the event still dispatches. The affected input is one trailing character of application data, and data with no trailing terminator is serialised identically on all three. Deterministic.
