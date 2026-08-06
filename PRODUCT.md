# Flyology HTTP product context

## Product

Flyology HTTP is an experimental HTTP/1.1 client and application-server
library, with an opt-in HTTP/2 client, for Ada programs using Flyology. Its
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

Flyology HTTP supports HTTP/1.1 messages, compatible HTTP/1.0 responses, and an
opt-in HTTP/2 client. HTTP/2 supports TLS ALPN fallback or requirement,
cleartext prior knowledge, multiplexing, retained request bodies, and streamed
responses. It does not provide an HTTP/2 server, proxying, content decoding, or
challenge-driven client authentication. It is experimental and does not claim
production qualification.

## Public surfaces

- Source: https://github.com/flyology-ada/flyology-http
- Website: https://http.flyology.org/
- Runtime dependency: https://flyology.org/
- Alire crate: `flyology_http`
