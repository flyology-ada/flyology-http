Title: An HTTP/1.0 response carrying both keep-alive and close is left in the pool as reusable
Labels: bug

## Summary

`Select_Body_Mode` decides connection reuse with `(if Version = HTTP_1_1 then not Close_Token else Keep_Token)`. Both `Connection` tokens are collected, but on the HTTP/1.0 arm only `keep-alive` is consulted, so an HTTP/1.0 response carrying `Connection: keep-alive, close` leaves the transport in the pool as idle and reusable. RFC 9112 section 9.3 tests for `close` first and does not condition that step on the version. The next checkout writes onto a socket the peer has already closed.

## Problem

Commit `f078732`.

Both tokens are collected (`src/flyology-http-client-http_1_internals.adb:410-413`):

```ada
      Close_Token : constant Boolean := Header_Has_Token
        (Data.Fields, "Connection", "close");
      Keep_Token : constant Boolean := Header_Has_Token
        (Data.Fields, "Connection", "keep-alive");
```

Only one of them is consulted on each arm (`src/flyology-http-client-http_1_internals.adb:416-418`):

```ada
      Data.Reusable :=
        (if Data.Version_Value = HTTP_1_1
         then not Close_Token else Keep_Token);
```

RFC 9112 section 9.3 orders the test the other way and makes the first step unconditional:

```
   *  If the "close" connection option is present (Section 9.6), the
      connection will not persist after the current response; else,

   *  If the received protocol is HTTP/1.1 (or later), the connection
      will persist after the current response; else,

   *  If the received protocol is HTTP/1.0, the "keep-alive" connection
      option is present, either the recipient is not a proxy or the
      message is a response, and the recipient wishes to honor the
      HTTP/1.0 "keep-alive" mechanism, the connection will persist after
      the current response; otherwise,

   *  The connection will close after the current response.
```

The onward effect is what bounds this. `Release_Lease` takes its `Verify` argument from `Undelivered_Framing` (`src/flyology-http-client-http_1_internals.adb:480`), which is `False` for a response that framed and delivered normally, so the stale slot is handed out without a verification probe. A non-idempotent request is then written onto a closed socket and fails; a safe or idempotent one is replayed once by the stale-lease recovery.

Existing coverage stops one case short. `tests/http_client_pool_model.adb:194-198` covers HTTP/1.0 with a lone `keep-alive`:

```ada
      Send
        ("HTTP/1.0 200 OK" & CRLF &
         "Content-Length: 0" & CRLF &
         "Connection: keep-alive" & CRLF & CRLF);
```

and `tests/http_client_smoke.adb:427-428` and `:461-462` cover HTTP/1.0 with no `Connection` field at all. No test sends both options on an HTTP/1.0 response.

## What happens now

Spike: three exchanges are served from one raw `Flyology.IO.Sockets` peer, each on its own client, and `Diagnostics (Item).Reusable_Transports` is read immediately after the body completes. The two controls are HTTP/1.0 with a lone `keep-alive`, which must stay pooled, and HTTP/1.1 with `close` present, which must not. Each check asserts the RFC 9112 section 9.3 outcome.

```ada
      Eleven_Both => To_Unbounded_String
        ("HTTP/1.1 200 OK" & CRLF
         & "Connection: keep-alive, close" & CRLF
         & "Content-Length: 2" & CRLF & CRLF & "ok"),
      Ten_Both => To_Unbounded_String
        ("HTTP/1.0 200 OK" & CRLF
         & "Connection: keep-alive, close" & CRLF
         & "Content-Length: 2" & CRLF & CRLF & "ok"));
   ...
      Answer := HC.Diagnostics (Item).Reusable_Transports;
```

```
  note HTTP/1.0 'keep-alive'        -> Reusable_Transports = 1
  note HTTP/1.1 'keep-alive, close' -> Reusable_Transports = 0
  note HTTP/1.0 'keep-alive, close' -> Reusable_Transports = 1
  ok   control: HTTP/1.0 with a lone keep-alive is pooled
  ok   control: HTTP/1.1 with close present is not pooled
  FAIL HTTP/1.0 with close present is not pooled (RFC 9112 9.3 evaluates close first)
checks: 3  failures: 1
BUG REPRODUCED
```

Both controls behave correctly, so the measurement isolates the one case: only HTTP/1.0 with both options leaves a reusable transport behind after the peer has closed the socket.

Host: macOS 26.6.2, arm64, GNAT via Alire.

## What should happen

A `close` connection option must end persistence regardless of the response version, as RFC 9112 section 9.3 states before it considers the version at all.

## Suggested treatment

Evaluate `close` first and fall back to the version rule:

```ada
      Data.Reusable :=
        (if Close_Token then False
         elsif Data.Version_Value = HTTP_1_1 then True
         else Keep_Token);
```

`src/flyology-http-client-http_1_internals.adb` is not a unit `./scripts/prove.sh` proves, so no proof obligation changes.

The regression test belongs in `tests/http_client_pool_model.adb`, beside the HTTP/1.0 keep-alive case at `:194-198`: add an HTTP/1.0 response carrying `Connection: keep-alive, close` and assert that no reusable transport remains. The spike is the test. No existing test asserts the wrong behaviour, so nothing has to change.

## Severity

A transport the peer is about to close is kept as reusable, so the next request on that pooled slot is written onto a dead socket. The client recovers for safe and idempotent methods by replaying once, and a non-idempotent request fails instead. It needs a response that carries both `Connection` options on HTTP/1.0, which is unusual: no stock server is known to emit both, and this is not verified against a peer. Deterministic given such a response.
