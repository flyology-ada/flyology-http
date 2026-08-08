# Flyology HTTP

Flyology HTTP is an experimental HTTP/1.1 client and server library, with
opt-in HTTP/2 client and application-server engines, for
[Flyology](https://flyology.org/) tasks. Its
synchronous Ada APIs work from native and lightweight tasks. The library
includes bounded client pools, an origin-bound WebSocket client, streaming
request and response bodies, routing, middleware, server-sent events,
WebSocket servers, and plain or TLS transports built on Flyology I/O.

This repository also contains `flyology_quic`, an independently built
Ada-native QUIC transport crate. `flyology_http` depends on that crate and
owns the HTTP/3 and QPACK layers; HTTP semantics do not live in the transport
crate. The public `Flyology.HTTP.HTTP_3` session API can exchange bounded
request and response HEADERS and DATA over live QUIC connections in client and
server roles. A routed server adapter also presents HTTP/3 requests through the
same `Applications.Exchange`, routes, middleware, body policies, streaming
response, and SSE APIs used by HTTP/1.1 and HTTP/2. The transport and HTTP/3
sessions interoperate in both directions with an aioquic black-box test peer.

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
# Optional aioquic black-box HTTP/3 interoperability:
./scripts/test-http3-interop.sh
# Optional Docker-based server protocol qualification:
./scripts/http2-test.sh h2spec
```

The test runner prepares a version-matched Flyology runtime, builds the HTTP
library as a separate GPR library, and runs its client, server, WebSocket, TLS,
policy, and negative lifetime tests. The separate HTTP/2 command uses a pinned
python-hyper/h2 peer for ALPN, prior-knowledge, multiplexing, flow-control, and
retry interoperability, plus differential HPACK testing. The explicit
`h2spec` target runs the pinned h2spec 2.6.0 image against the cleartext server
adapter; it requires Docker and is also part of `qualification` and `nightly`.
The HTTP/3 interoperability command creates an isolated Python test environment
for aioquic. aioquic is an oracle only and is not a crate or runtime dependency.

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

## Routed HTTP/3 server

Register ordinary application handlers, bind a UDP socket, and pass the server
identity to the router. `Serve_HTTP_3` generates a secure QUIC connection
identifier internally:

```ada
type Context is limited null record;
package Routing is new Flyology.HTTP.Server.Routing (Context);

procedure Hello (State : in out Context; X : in out Applications.Exchange) is
begin
   X.Text (200, "hello " & X.Parameter ("name"));
end Hello;

Routes.Get ("/hello/{name}", Hello'Access, Name => "hello");
Sockets.Create_Socket (Socket, Sockets.IPv4, Sockets.Socket_Datagram);
Sockets.Bind_Socket
  (Socket, Sockets.Network_Endpoint (Sockets.Any_IPv4, 4_433));
Routes.Serve_HTTP_3 (State, Socket, Certificate_DER, Private_Key);
```

`Certificate_DER` is an Ed25519 certificate and `Private_Key` is its 32-byte
raw private key. The maintained `showcases/http3_application_server.adb` loads
both from files and supplies a complete route. This first adapter exclusively
owns the bound socket and serves one QUIC peer per invocation; a listener-level
multi-client connection manager is not yet included.

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
- A low-level HTTP/3 client/server session over the Ada-native `flyology_quic`
  transport, with control streams, SETTINGS, a static-table QPACK profile,
  request and response sequencing, and bounded HEADERS and DATA events.
- An HTTP/3 routed-server adapter using the protocol-neutral application
  exchange, including middleware, route parameters, body policies, fixed and
  streamed responses, and SSE.

The HTTP/2 server uses the protocol-neutral `Applications.Exchange` and the
same routes and middleware as HTTP/1.1. The raw HTTP/1.x `Server.Connection`
API is not emulated because HTTP/2 has concurrent stream rather than
connection-scoped response state. HTTP/2 does not currently provide h2c
Upgrade, server push, extended CONNECT/WebSockets, or HTTP/1.1 fallback inside
the HTTP/2 connection adapter. Cleartext deployments can use HTTP/2 prior
knowledge, while TLS deployments can use ALPN and route HTTP/1.1 and HTTP/2
through the same `Routing.Router`. Server push is deliberately not exposed;
the client disables it and applications should use ordinary routed responses.
Extended CONNECT needs a stream-oriented tunnel API rather than the existing
HTTP/1.1 connection-borrowing WebSocket API. On the client, borrowed streaming
request sources and `Expect: 100-continue` remain HTTP/1.1-only. The library
does not provide proxying or content decoding. HTTP/3 is integrated with
routing and the application exchange on the server, but not with the
higher-level HTTP client pool. The current routed adapter serves one peer on an
exclusively owned UDP socket, dispatches request streams synchronously, and
buffers each complete request stream before entering the route handler. Its
bounded connection profile currently serves at most five requests. The QPACK
profile does not use the dynamic table. It is experimental and does not claim
production qualification. HTTP/3 server push is disabled. Because this profile
does not advertise MAX_PUSH_ID, received push promises and push streams are
rejected as required by RFC 9114.

Flyology HTTP is dual-licensed under MIT or Apache-2.0.
