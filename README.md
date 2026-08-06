# Flyology HTTP

Flyology HTTP is an experimental HTTP/1.1 client and server library, with
opt-in HTTP/2 client and application-server engines, for
[Flyology](https://flyology.org/) tasks. Its
synchronous Ada APIs work from native and lightweight tasks. The library
includes bounded client pools, an origin-bound WebSocket client, streaming
request and response bodies, routing, middleware, server-sent events,
WebSocket servers, and plain or TLS transports built on Flyology I/O.

Documentation is published at [http.flyology.org](https://http.flyology.org/).
The [client guide](https://http.flyology.org/guide/client/), dedicated
[HTTP/2 guide](https://http.flyology.org/guide/http2/), and
[server guide](https://http.flyology.org/guide/server/) describe outbound and
inbound lifecycles separately.

## Build and test

```sh
alr build
./scripts/test.sh
./scripts/http2-test.sh prepare
./scripts/http2-test.sh all
```

The test runner prepares a version-matched Flyology runtime, builds the HTTP
library as a separate GPR library, and runs its client, server, WebSocket, TLS,
policy, and negative lifetime tests. The separate HTTP/2 command uses a pinned
python-hyper/h2 peer for ALPN, prior-knowledge, multiplexing, flow-control, and
retry interoperability, plus differential HPACK testing.

## Use with Alire

Add the Flyology organization index ahead of the community index and depend on
the HTTP crate:

```sh
alr index --reset-community
alr index --add=git+https://github.com/flyology-ada/alire-index.git \
  --name=flyology --before=community
alr with flyology_http
```

The `flyology_http` dependency brings in Flyology. Applications configure and
prepare Flyology's version-matched runtime as described in the
[Flyology guide](https://flyology.org/guide/).

## Scope

- HTTP/1.0 response compatibility and HTTP/1.1 client and server messages.
- Opt-in HTTP/2 clients with ALPN fallback or requirement, cleartext prior
  knowledge, multiplexed streams, and bounded receive flow control.
- HTTP/2 application servers over cleartext prior knowledge or an
  ALPN-negotiated Flyology connection, with multiplexed stream handlers,
  bounded request and response buffers, routing, middleware, SSE, and
  flow-controlled streaming bodies.
- Origin-bound HTTP pools with one monotonic exchange deadline and
  single-session WebSocket clients with monotonic operation deadlines.
- Fixed-length and chunked bodies with bounded streaming adapters.
- Optional routing, middleware, native offload, SSE, and WebSocket facilities.
- Provider-neutral TLS integration through Flyology I/O.

The HTTP/2 server uses the protocol-neutral `Applications.Exchange` and the
same routes and middleware as HTTP/1.1. The raw HTTP/1.x `Server.Connection`
API is not emulated because HTTP/2 has concurrent stream rather than
connection-scoped response state. HTTP/2 does not currently provide h2c
Upgrade, server push, extended CONNECT/WebSockets, or HTTP/1.1 fallback inside
the HTTP/2 connection adapter. On the client, borrowed streaming request
sources and `Expect: 100-continue` remain HTTP/1.1-only. The library does not
provide proxying or content decoding. It is experimental and does not claim
production qualification.

Flyology HTTP is dual-licensed under MIT or Apache-2.0.
