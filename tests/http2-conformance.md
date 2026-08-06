# HTTP/2 conformance

The deterministic Ada tests cover frame bounds, RFC 7541 Huffman and HPACK
vectors, stream transitions, flow-control arithmetic, and replay policy.

`http2_peer.py` is the independent interoperability peer. It uses
python-hyper/h2 rather than Flyology HTTP code and exercises:

- TLS ALPN selection of `h2`;
- HTTP/1.1 ALPN fallback and required-`h2` rejection;
- cleartext HTTP/2 prior knowledge without Upgrade;
- a basic request and response;
- two multiplexed streams with interleaved response DATA;
- concurrent request field sections that require CONTINUATION frames;
- peer-advertised single-stream capacity and pool backpressure;
- monotonically increasing concurrent client stream creation order;
- a response larger than the initial flow-control window;
- a retained upload larger than the initial flow-control window;
- an early final response that cancels an unfinished retained upload;
- DATA racing with a locally reset stream while another request reuses the
  connection;
- zero-length application reads without invalid flow-control updates;
- rejection of a non-SETTINGS server preface and an informational response
  carrying END_STREAM;
- bounded processing of an 8,000-frame PING and extension-frame flood;
- concurrent response finalization and client shutdown;
- graceful GOAWAY with a provably unprocessed stream; and
- REFUSED_STREAM retry behavior, including the no-retry rule for POST.

The peer requires `h2==4.3.0`. It uses the repository's generated TLS fixture
and writes JSON-lines wire observations for assertions by the Ada test runner.
The same peer also exercises the maintained `http_client_cli` showcase over
required TLS HTTP/2, negotiated HTTP/1.1 fallback, and cleartext prior
knowledge, including its reported negotiated protocol.

## Independent peer qualification

`http2-interop.sh` runs one semantic contract against three unrelated server
implementations:

- Go's standard HTTP/2 server;
- Node's built-in `node:http2` server; and
- `nghttpd` from nghttp2.

For each peer and each Flyology execution lane, the contract covers a small
response, concurrent uniquely routed streams, a 256 KiB flow-controlled
response, a 64 KiB retained upload echoed by the peer, HEAD semantics, TLS
ALPN, connection reuse, shutdown drainage, and descriptor restoration. The
peer header is also checked where the server supports adding one. `nghttpd`
must be installed separately (`nghttp2-server` on Debian/Ubuntu or `nghttp2`
with Homebrew).

`http2_fault_proxy.py` is a deterministic TCP proxy used with the Go peer. It
currently covers one-byte TLS/TCP slicing, delayed 257-byte slices, and a reset
after 32 KiB of server traffic during a large response. Successful campaigns
run the complete semantic contract; the reset campaign must fail within its
deadline rather than hang.

## Soak qualification

`http2_client_soak.adb` continuously shares an HTTP/2 client across concurrent
callers. A seed determines its mix of empty, small, and 8 KiB responses,
retained uploads, and deliberately abandoned partial responses. Every normal
response carries a unique request identifier in its deterministic body, so a
cross-stream routing error is detected as data corruption. Each epoch asserts
pool drainage and descriptor restoration. After the first full epoch, current
RSS must remain within a configurable plateau allowance and the process thread
count must not grow.

The useful controls are:

- `FLYOLOGY_HTTP2_SOAK_REQUESTS` per worker and epoch;
- `FLYOLOGY_HTTP2_SOAK_SECONDS`, which selects duration instead of a request
  count and is divided across epochs;
- `FLYOLOGY_HTTP2_SOAK_EPOCHS`, `FLYOLOGY_HTTP2_SOAK_CONCURRENCY`, and
  `FLYOLOGY_HTTP2_SOAK_CAPACITY`;
- `FLYOLOGY_HTTP2_SOAK_MODELS` and `FLYOLOGY_HTTP2_SOAK_SEEDS`; and
- `FLYOLOGY_HTTP2_SOAK_RSS_TOLERANCE`, in bytes.

The pull-request qualification uses bounded request counts. The scheduled CI
job runs `nightly`, whose default is 30 minutes per execution lane. These runs
increase confidence but do not qualify the experimental client for production
use.

The HTTP/2 server behavioral test covers prior knowledge, route and middleware
dispatch through `Applications.Exchange`, concurrent streams, a buffered
20 KiB upload, and an 80 KiB streamed response. `http2_server_peer.py` uses
python-hyper/h2 independently of the Flyology client to cover cleartext prior
knowledge, TLS ALPN, concurrent streams, HEAD, a 128 KiB streamed response,
request flow control, malformed-stream isolation, and connection-credit
recovery after client resets.

`./scripts/http2-test.sh h2spec` builds a concurrent cleartext adapter and runs
the pinned `summerwind/h2spec:2.6.0` Docker image. The maintained baseline is
146 of 146 tests passing. The suite covers protocol startup, frame validation,
stream state and error scope, settings, flow control, request fields, HPACK,
and server rejection of client `PUSH_PROMISE`. This qualification increases
confidence in the experimental server; it does not imply production
qualification or cover h2c Upgrade, server push, or extended CONNECT.

`http2_hpack_differential.py` feeds a persistent Ada decoder with deterministic
blocks generated by python-hyper/hpack. This covers indexed and literal fields,
dynamic-table reuse and resizing, raw strings, and Huffman strings. A local run
can prepare the independent Python implementation with:

```sh
./scripts/http2-test.sh prepare
./scripts/test.sh
./scripts/http2-test.sh all
./scripts/http2-test.sh qualification

# Configurable duration campaign; defaults to 30 minutes per execution lane.
./scripts/http2-test.sh nightly
```
