# Flyology HTTP

Flyology HTTP is an experimental HTTP/1.1 client and server library, with
opt-in HTTP/2 and HTTP/3 client and application-server engines, for
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
# Required aioquic and quic-go black-box HTTP/3 interoperability:
./scripts/test-http3-interop.sh all
# Required published error suite and bounded HTTP/3 resilience campaign:
./scripts/test-http3-h3spec.sh
./scripts/test-http3-stress.sh
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
for pinned aioquic and builds a separately pinned quic-go test executable. Both
peers exercise Ada client and server roles and are CI gates; neither is a crate
or runtime dependency. The separately pinned h3spec command gates published
QUIC and HTTP/3 error-case coverage. The stress command checks hostile UDP
input, mutated authenticated streams, bounded server churn, and concurrent Ada
client use against aioquic. See
[`tests/http3-conformance.md`](tests/http3-conformance.md) for the exact matrix.
Rebuild with `FLYOLOGY_QUIC_TRACE=true` to emit tagged QUIC and HTTP/3 state
failures on standard error. Tracing is compiled out by default.

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

## Unified HTTP/1.1, HTTP/2, and HTTP/3 server

Register the routes once and call the router's unified `Serve` overload. It
binds TLS/TCP and QUIC/UDP to the same endpoint. TLS ALPN selects HTTP/2 or
HTTP/1.1 on TCP; HTTP/3 is served on UDP. Every protocol dispatches through
the same router, middleware, body policies, and application context:

```ada
type Context is limited null record;
package Routing is new Flyology.HTTP.Server.Routing (Context);

Routes  : aliased Routing.Router
  (Capacity => 1, Slashes => Routing.Strict_Slashes);
State   : aliased Context;
Backend : aliased OpenSSL.OpenSSL_Provider;
Stop    : aliased Flyology.Cancellation.Token;

procedure Hello (State : in out Context; X : in out Applications.Exchange) is
begin
   X.Text (200, "hello " & X.Parameter ("name"));
end Hello;

Routes.Get ("/hello/{name}", Hello'Access, Name => "hello");
OpenSSL.Initialize_Server
  (Backend, "certificate.pem", "private-key.pem",
   Protocols => ALPN."&" (ALPN.Offer ("h2"), "http/1.1"));
Routes.Serve
  (State,
   HTTP_Endpoint  => Sockets.Network_Endpoint (Sockets.Any_IPv4, 80),
   HTTPS_Endpoint => Sockets.Network_Endpoint (Sockets.Any_IPv4, 443),
   HTTPS_Origin   => Flyology.HTTP.Parse_Origin
     ("https://www.example.com"),
   TLS_Backend     => Backend,
   Certificate_DER => Certificate_DER,
   Private_Key     => Private_Key,
   Token           => Stop'Access);
```

The default cleartext policy returns a method-preserving 308 using the
configured `HTTPS_Origin`; it does not trust the request's `Host` field.
Select `Cleartext => Routing.Serve_Cleartext` to route cleartext HTTP/1.x
through the same application instead. Handlers can inspect
`X.Request_Scheme` independently of `X.Request_Protocol`. Cleartext direct
responses do not advertise HTTP/3, and cleartext, secure TCP, and QUIC each
have an independent capacity.

For explicit dual-stack HTTP and HTTPS service, use the four-endpoint overload.
The IPv4 and IPv6 cleartext endpoints share one port, the IPv4 and IPv6 secure
endpoints share another, and the cleartext, secure TCP, and HTTP/3 capacities
are divided independently between address families:

```ada
Routes.Serve
  (State,
   IPv4_HTTP_Endpoint  =>
     Sockets.Network_Endpoint (Configured_IPv4, 80),
   IPv6_HTTP_Endpoint  =>
     Sockets.Network_Endpoint (Configured_IPv6, 80),
   IPv4_HTTPS_Endpoint =>
     Sockets.Network_Endpoint (Configured_IPv4, 443),
   IPv6_HTTPS_Endpoint =>
     Sockets.Network_Endpoint (Configured_IPv6, 443),
   HTTPS_Origin        => Flyology.HTTP.Parse_Origin
     ("https://www.example.com"),
   TLS_Backend         => Backend,
   Certificate_DER     => Certificate_DER,
   Private_Key         => Private_Key,
   Cleartext           => Routing.Redirect_To_HTTPS,
   Cleartext_Capacity  => 64,
   TCP_Capacity        => 64,
   HTTP_3_Capacity     => 128,
   Token               => Stop'Access);
```

A secure-only dual-stack overload remains available when no cleartext listener
is wanted. It takes just the IPv4 and IPv6 HTTPS endpoints, on the same port,
and serves TLS/TCP plus QUIC/UDP on both families.

The unified server automatically adds `Alt-Svc: h3=":443"; ma=86400` to
HTTP/1.1 and HTTP/2 responses. The advertised port follows the bound endpoint,
and `Alt_Svc_Max_Age` configures the lifetime. HTTP/3 responses omit this
discovery header. The TLS provider must be initialized for server-side ALPN as
shown above. `Certificate_DER` is an Ed25519 certificate and `Private_Key` is
its 32-byte raw private key for QUIC. TLS/TCP may use a distinct certificate,
but clients must be able to validate both identities for the requested host.

For local development, the public
`Flyology.HTTP.Server.Development_Certificates` package generates both forms:

```ada
package Certificates renames
  Flyology.HTTP.Server.Development_Certificates;

Credentials : Certificates.Identity;

Certificates.Generate (Credentials);
declare
   Certificate_DER : constant Ada.Streams.Stream_Element_Array :=
     Certificates.QUIC_Certificate_DER (Credentials);
   Private_Key : constant Flyology.QUIC.Connections.Ed25519_Private_Key :=
     Certificates.QUIC_Private_Key (Credentials);
begin
   OpenSSL.Initialize_Server
     (Backend,
      Certificates.TLS_Certificate_File (Credentials),
      Certificates.TLS_Private_Key_File (Credentials),
      Protocols => ALPN."&" (ALPN.Offer ("h2"), "http/1.1"));
   Certificates.Discard (Credentials);

   Routes.Serve
     (State, Sockets.Network_Endpoint (Sockets.Any_IPv4, 4_433), Backend,
      Certificate_DER => Certificate_DER,
      Private_Key     => Private_Key,
      Token           => Stop'Access);
end;
```

The package uses RSA for compatibility with common TLS/TCP clients and the
Ed25519 DER certificate and raw key required by the current QUIC profile. It
removes any remaining files when the limited identity object finalizes;
`Discard` removes them earlier after the TLS provider and QUIC values have
loaded them. Because the certificates are self-signed, development clients
must explicitly disable certificate verification or trust them.

The maintained `showcases/http3_application_server.adb` uses this API when run
with no identity arguments:

```sh
./showcases/bin/http3_application_server 4433 4080
```

Passing `TLS_CERT.pem TLS_KEY.pem QUIC_CERT.der QUIC_KEY.raw` retains the
explicit stable-identity form; optional trailing arguments select the HTTPS
and HTTP ports. Lower-level
`Serve_HTTP_3_Listener` and single-connection `Serve_HTTP_3` adapters remain
available when an application owns the UDP listener itself.

Automatic generation requires an OpenSSL command with Ed25519 support. The
package recognizes conventional OpenSSL 3 installation paths and the
`FLYOLOGY_HTTP_OPENSSL` environment variable before falling back to `PATH`.
The certificates are self-signed, so use an HTTP/3-enabled curl and explicitly
accept them when testing the H3 listener:

```sh
curl -i http://127.0.0.1:4080/hello/test
curl --version  # The Features line must include HTTP3.
curl -k --http3-only https://127.0.0.1:4433/hello/test
```

macOS's system curl currently lacks HTTP/3 support. A normal H2-capable curl
will negotiate HTTP/2 instead. Use the IPv4 address because this showcase
listener binds `Any_IPv4`.

## HTTP/3 client

The ordinary origin-bound client can learn the unified server's HTTP/3 port
without changing request or response code. Configure an ALPN-capable TCP TLS
provider together with the exact DER certificate expected from QUIC:

```ada
HTTP : aliased Client.Client (Capacity => 2);

OpenSSL.Initialize_Client (Backend);
Client.Configure
  (HTTP,
   Flyology.HTTP.Parse_Origin ("https://api.example.com"),
   Backend'Access,
   Client.Negotiate_HTTP_3,
   HTTP_3_Certificate_DER => Pinned_Certificate_DER,
   Pool =>
     (Max_Idle => 2,
      Idle_Timeout => 30.0,
      Max_Connection_Age => 300.0,
      Max_Requests_Per_Connection => 0));
```

The first exchange uses authenticated HTTP/2 or HTTP/1.1. A response containing
a same-origin `Alt-Svc: h3=":port"` field records a bounded alternative while
healthy TCP transports remain reusable. Later requests prefer HTTP/3 on UDP.
When an H3 transport is already busy or connecting, concurrent requests can
immediately use retained HTTP/2 or HTTP/1.1 capacity; the client never
duplicates one application request across protocols. A failed H3 establishment
clears the alternative and makes one TCP attempt inside the original exchange
deadline. `Negotiated_Protocol` reports the protocol used by each response.
Set pool capacity and `Max_Idle` to at least two to keep both protocol stacks
warm while idle, as in the example.

When DNS returns both families, the client runs one bounded establishment lane
per family under the same filter, cancellation sources, and exchange deadline.
The first complete TCP connect or QUIC handshake wins. A losing connected QUIC
leg sends an application close before releasing UDP, so server admission is
returned immediately.

Use `Require_HTTP_3` with the certificate overload that has no TCP provider to
send QUIC directly to the HTTPS origin's UDP port. Both modes authenticate the
exact peer certificate supplied as 1 through 4,096 DER bytes. The current H3
pool reuses each connection sequentially rather than multiplexing requests;
retained request bodies are bounded to 16 KiB, and streaming request sources
and `Expect: 100-continue` remain unavailable on H3.

## Scope

- HTTP/1.0 response compatibility and HTTP/1.1 client and server messages.
- Opt-in HTTP/2 clients with ALPN fallback or requirement, cleartext prior
  knowledge, multiplexed streams, and bounded receive flow control.
- HTTP/2 application servers over cleartext prior knowledge or an
  ALPN-negotiated Flyology connection, with multiplexed stream handlers,
  bounded request and response buffers, routing, middleware, SSE, and
  flow-controlled streaming bodies.
- Origin-bound HTTP pools with one monotonic exchange deadline and
  single-session WebSocket clients with monotonic operation deadlines,
  including direct or same-origin Alt-Svc-discovered HTTP/3 transports.
- Fixed-length and chunked bodies with bounded streaming adapters.
- Optional routing, middleware, native offload, SSE, and WebSocket facilities.
- Provider-neutral TLS integration through Flyology I/O.
- A low-level HTTP/3 client/server session over the Ada-native `flyology_quic`
  transport, with control streams, SETTINGS, a static-table QPACK profile,
  request and response sequencing, and bounded HEADERS and DATA events.
- An HTTP/3 routed-server adapter using the protocol-neutral application
  exchange, including middleware, route parameters, body policies, fixed and
  streamed responses, and SSE.
- A unified routed server with a distinct cleartext HTTP/1.x endpoint plus
  TLS HTTP/1.1 and HTTP/2 and QUIC HTTP/3 on one secure TCP/UDP port. It can
  route or redirect cleartext requests and advertises HTTP/3 through
  `Alt-Svc` only on secure TCP responses.

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
request sources and `Expect: 100-continue` remain HTTP/1.1-only. HTTP/3
currently accepts retained request bodies through 16 KiB and reuses pooled
connections sequentially. The library does not provide proxying or content
decoding. The managed UDP adapter uses a bounded
connection registry and fixed worker set, dispatches request streams
synchronously, and buffers each complete request stream before entering the
route handler. Each connection retains at most 32 concurrent QUIC stream
reassembly buffers and recycles completed request state. The unified server
defaults to 128 concurrent HTTP/3 connections alongside 64 TCP connections,
serves 100,000 requests per H3 connection by default, and accepts explicit
limits up to 256 concurrent H3 connections and 1,000,000 requests per
connection. Completed exchanges do not accumulate in the connection, so this
lifetime limit controls connection rotation rather than retained request
memory. Connection capacity separately controls the fixed worker set. The
QPACK profile does not use the dynamic table. It is experimental and does not
claim production qualification. HTTP/3 server push is disabled. Because this
profile does not advertise MAX_PUSH_ID, received push promises and push
streams are rejected as required by RFC 9114.

Flyology HTTP is dual-licensed under MIT or Apache-2.0.
