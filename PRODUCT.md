# Flyology HTTP product context

## Product

Flyology HTTP is an experimental HTTP/1.1 client and application-server
library, with opt-in HTTP/2 client and application-server engines, for Ada
programs using Flyology. Its
synchronous APIs work from native and lightweight tasks while keeping
transport ownership, resource limits, deadlines, cancellation, and shutdown
explicit.

The library has two deliberate entry points:

- an origin-bound client with a bounded connection pool and streaming request
  and response bodies;
- a protocol server with optional routing, middleware, native offload, SSE,
  and WebSocket facilities.

It depends on Flyology Runtime for task-aware I/O and does not contain the
runtime integration itself.

## Audience

Ada developers evaluating Flyology for network services and tools. Readers
should be able to begin with either the client or server lifecycle without
first learning the other one.

## Current boundaries

Flyology HTTP supports HTTP/1.1 messages, compatible HTTP/1.0 responses, and
opt-in HTTP/2 client and application-server engines. HTTP/2 supports TLS ALPN,
cleartext prior knowledge, multiplexing, flow-controlled bodies, and streamed
responses. The application server reuses `Applications.Exchange`, routing,
and middleware; the raw HTTP/1.x connection API remains protocol-specific.
HTTP/2 does not currently provide h2c Upgrade, server push, extended
CONNECT/WebSockets, or automatic HTTP/1.1 fallback in its connection adapter.
The library does not provide proxying, content decoding, or challenge-driven
client authentication. It is experimental and does not claim production
qualification.

## Public surfaces

- Source: https://github.com/flyology-ada/flyology-http
- Website: https://http.flyology.org/
- Runtime dependency: https://flyology.org/
- Alire crate: `flyology_http`
