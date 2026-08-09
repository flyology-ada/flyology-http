# HTTP stack performance notebook, 2026-08-09

These are local experimental measurements, not portable or production-level
claims. The server, route, clients, machine power state, and process lifecycle
all materially affect the results.

## Scope and environment

- Baseline: `main` at `8b09b0f4830683d6d76c4e31ffa5dd31a2386988`.
- Working branch: `codex/http-stack-performance`.
- Flyology: Alire `0.1.0-dev` at
  `3808aabcb33d75b06a6a9472eb2342094a66d018`.
- Machine: MacBook Pro `Mac15,9`, Apple M3 Max, 16 cores (12 performance,
  4 efficiency), 48 GB RAM.
- OS: macOS 26.5.2, Darwin 25.5.0, arm64.
- Clients: oha 1.7.0 for H1/H2; aioquic 1.3.0 for H3.
- Route: the same Routing API handler at `GET /hello/{name}` over H1, H2,
  and H3. The default benchmark target was `/hello/test`, status 200 and body
  `hello test` (10 bytes).
- Build: release switches (`-O3`, inlining), assertions and validity checks
  retained by the showcase project, `FLYOLOGY_QUIC_TRACE=false`.

## Runtime preparation and fail-closed checks

Every performance and standalone H3 qualification/stress binary used an
explicit Flyology lightweight RTS. No H3 performance harness was built or run
with GNAT's default RTS. The one-loop and 16-loop roots were
`build/perf-rts-l1` and `build/perf-rts-l16`.

Representative 16-loop preparation and clean build:

```sh
alr update
alr with flyology=0.1.0-dev

FLYOLOGY_RTS_DIR="$PWD/build/perf-rts-l16" \
FLYOLOGY_DEFAULT=lightweight \
FLYOLOGY_LOOP_POOL_SIZE=16 \
  /path/to/resolved/flyology/scripts/prepare-rts.sh

test -f build/perf-rts-l16/.flyology-rts-root
grep -q 'Flyology prepared RTS version' \
  build/perf-rts-l16/.flyology-rts-root
grep -q 'Lightweight : constant Boolean := True;' \
  build/perf-rts-l16/adainclude/s-fldeex.ads

./showcases/prepare-alire.sh release
cd showcases
FLYOLOGY_RTS_DIR=../build/perf-rts-l16 \
  alr exec -- env -u GPR_CONFIG gprclean -r -q -P showcases.gpr
FLYOLOGY_RTS_DIR=../build/perf-rts-l16 \
FLYOLOGY_SHOWCASE_PROFILE=release \
FLYOLOGY_QUIC_TRACE=false \
  alr exec -- env -u GPR_CONFIG gprbuild \
    --RTS=../build/perf-rts-l16 -p -P showcases.gpr \
    http3_application_server.adb http_benchmark_runtime_probe.adb
./bin/http_benchmark_runtime_probe
```

The last command must print `16` (`1` for the single-loop build). A prior
incremental build retained a one-loop binder despite selecting the 16-loop
directory. Cleaning recursively and requiring the runtime probe prevents that
metadata error. The H3 interop, h3spec, and stress scripts now also verify both
the Flyology root marker and the lightweight constant before building.

Server and client commands:

```sh
FLYOLOGY_QUIC_TRACE=false \
  ./showcases/bin/http3_application_server 18443 18080

oha -n 200000 -c 64 --http-version 1.1 --insecure --no-tui --json \
  https://127.0.0.1:18443/hello/test
oha -n 200000 -c 4 -p 16 --http-version 2 --insecure --no-tui --json \
  https://127.0.0.1:18443/hello/test
build/oracle/aioquic/bin/python showcases/http3_benchmark.py \
  --port 18443 --path /hello/test --requests 800000 \
  --workers 8 --connections 128 --streams 16 --timeout 20
```

The H3 fixture keeps connections open, validates every status/body, separates
handshake and request latency, reports connection reuse, and uses multiple
processes when one Python event loop would be the limiting component. A fresh
server was used for each high-connection trial. Reusing one server across
successive 128-new-connection trials degraded from 53.9k to 41.7k to 35.4k
requests/s while median handshake latency rose from 69 to 200 ms; this is a
connection-retirement/lifecycle pressure signal, not a steady-state result.

## Baselines and final measurements

The baseline table uses medians of three controlled trials where available.
The final H3 row is the last clean 16-loop post-change run after qualification.
Latency values are milliseconds. All requests succeeded.

| Configuration | Requests/s | p50 | p95 | p99 | Concurrency and reuse |
| --- | ---: | ---: | ---: | ---: | --- |
| H1, 1 loop, baseline | 34,784 | 0.431 | 0.540 | 0.737 | 16 connections, keep-alive |
| H2, 1 loop, baseline | 19,783 | 3.17 | 4.09 | 4.54 | 4 connections x 16 streams |
| H2, 1 loop, reusable handlers median | **29,002** | 1.929 | 3.198 | 6.005 | same; +49.2% against fresh 19,444 median |
| H2, 1 loop, direct HPACK match median | **39,187** | 1.637 | 1.710 | 1.891 | same; +35.1% over reusable handlers |
| H2, 1 loop, retained wake sources median | **44,804** | 1.4 | 1.5 | 1.6 | same; +14.3% over direct HPACK match |
| H3, 1 Python worker, baseline | 13,768 | 10.320 | 18.111 | 19.454 | 16 connections x 16 streams |
| H3, 1 server loop saturated, baseline | 25,725 | 36.64 | — | — | 4 workers, 64 connections x 16 streams |
| H3, 1 server loop, ACK candidate | 26,827 | 35.25 | — | — | same; +4.3% rate, -3.8% p50 |
| H3, 1 loop, pre-QPACK median | 27,310 | 32.8 | — | — | 4 workers, 64 connections x 16 streams |
| H3, 1 loop, QPACK median | **30,097** | 29.6 | — | — | same; +10.2% rate, about -10% p50 |
| H1, 16 loops, baseline median | 98,299 | 0.459 | 1.700 | 3.285 | 64 connections |
| H2, 16 loops, baseline median | 32,035 | 1.946 | 2.552 | 2.795 | 4 connections x 16 streams |
| H2, 16 loops, reusable handlers median | **89,856** | 0.533 | 0.987 | 5.762 | same; +180.5% |
| H2, 16 loops, direct HPACK match median | 90,237 | 0.540 | 0.855 | 3.927 | same; +0.4%, neutral |
| H2, 16 loops, retained wake sources median | **147,435** | 0.3 | 0.6 | 3.0 | same; +63.4% over direct HPACK match |
| H3, 16 loops, baseline | 54,123 | — | — | — | 8 workers, 128 connections x 16 streams |
| H3, 16 loops, pre-QPACK best | **58,935** | 24.896 | 51.082 | 78.762 | 8 workers, 128 connections x 16 streams; reuse 6,250x |
| H3, 16 loops, QPACK median | 57,222 | 26.617 | 46.145 | 65.833 | same; neutral within run noise |

The pre-QPACK 58.9k H3 run took 13.574 s for 800,000 requests. Handshake
latency was
55.118 ms mean, 54.984 ms p50, 58.172 ms p95, and 97.680 ms max. The final H1
and H2 spot checks after the long qualification session were 79,340 and 29,091
requests/s respectively; both were below their earlier controlled medians, so
they are recorded as thermal/order-sensitive spot checks rather than
regressions. Their success rates were 100%.

The original approximately 13.9k H3 result is reproducible, but it measures a
single aioquic process: the Python client was about 98.5% of one core while the
server was about 66% of one core. Multiprocess load exposes server capacity.
With 16 positively probed Flyology loops, sustained H3 crossed 50k and peaked
in a clean run at 58.9k. Scaling saturated around 8 client workers:
16 workers regressed to about 42k because handshake/process/packet pressure
grew faster than useful server work.

### H2 handler-task profile and scaling

The maintained H2 load command uses four reused TLS connections and up to 16
concurrent streams on each connection, for 64 maximum in-flight requests:

```sh
oha -n 200000 -c 4 -p 16 --http-version 2 --insecure --no-tui --json \
  https://127.0.0.1:18443/hello/test
```

On a fresh one-loop server before handler reuse, three runs were 19.444k,
20.077k, and 18.773k requests/s (19.444k median). After reuse, the same command
measured 27.892k, 32.250k, and 29.002k (29.002k median, +49.2%). A 30-second
candidate run sustained 31.032k and validated 930,965 responses. With a clean
16-loop rebuild and a runtime probe of 16, three runs were 89.856k, 91.088k,
and 78.060k (89.856k median), versus the earlier 32.035k baseline. The short
16-loop trials show larger run-order tails, so the median is useful local
evidence rather than a portable capacity claim.

The before profile used:

```sh
oha -z 30s -c 4 -p 16 --http-version 2 --insecure --no-tui --json \
  https://127.0.0.1:18443/hello/test
sample SERVER_PID 8 -file /tmp/flyology-h2-one-loop-20260809.sample.txt
```

Per-request task activation and destruction dominated HPACK and TLS: leading
top-of-stack counts included `mprotect` 570, scheduler current-task 399,
task-local storage lookup 310, `munmap` 266, `madvise` 221, context trampoline
219, context creation 169, `close` 152, `pipe` 117, and `mmap` 99. The corrected
candidate sample used the same command and duration. Context creation,
destruction, mapping, protection, and task activation/finalization disappeared
from the leading list. The next visible work was TLS/socket `write` 674,
scheduler current-task 644, task-local lookup 456, `fcntl` 314, `read` 271,
`memcmp` 254, and HPACK static lookup 253. Differing sample totals make the
counts mechanism evidence, not percentages.

The next profile-led change combined the encoder's exact and name-only HPACK
static-table searches and matched canonical names directly. One-loop trials
were 38.942k, 39.187k, and 39.453k requests/s (39.187k median, +35.1% over
reusable handlers alone). A 30-second run sustained 39.116k with 1,173,561
validated responses. Static lookup fell from 253 to 135 samples even though
sampled throughput increased by about 26%. At 16 loops, three trials were
90.629k, 89.036k, and 90.237k (90.237k median, +0.4%); the change is neutral
once other work limits throughput.

The next profile showed that stream teardown still called `close` 181 times
and `pipe` 136 times in the sample, beside `fcntl` 301. Each completed request
released the wake source owned by its bounded stream slot, so the next stream
occupying that slot recreated and configured a pipe pair. The controller now
drains any pending notification but retains the descriptor generation until
the connection's controlled finalization. Ownership remains bounded to at
most 32 lazy wake sources per H2 connection.

With the identical one-loop command, three retained-source trials were
44.804k, 44.862k, and 43.991k requests/s (44.804k median, +14.3% over
39.187k). The median p50 was 1.4 ms, p95 1.5 ms, and p99 1.6 ms. In the
candidate sample, `pipe`, `close`, and `fcntl` disappeared from the leading
list while sampled throughput rose; the remaining named leaders included
socket `write` 678, scheduler current-task 421, task-local lookup 301, socket
`read` 275, `memcmp` 263, and HPACK static lookup 110.

A clean 16-loop build, positively probed as 16, measured 147.643k, 143.649k,
and 147.435k requests/s (147.435k median, +63.4%). A longer 30-second run
sustained 149.576k requests/s and validated 4,489,030 responses before the
time deadline. These short-body localhost results are machine-local and show
that descriptor lifecycle had also limited scaling; they are not a portable
server rating.

The post-change 16-loop connection sweep held streams per connection at 16
and sent 100,000 validated requests per point:

| Connections | Maximum in flight | Requests/s | p50 | p95 | p99 |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 16 | 48,816 | 0.306 | 0.373 | 0.430 |
| 2 | 32 | 71,480 | 0.390 | 0.527 | 0.607 |
| 4 | 64 | 95,758 | 0.502 | 0.708 | 1.820 |
| 8 | 128 | 99,342 | 0.801 | 3.528 | 10.144 |
| 16 | 256 | 96,980 | 0.725 | 8.204 | 46.515 |

Throughput saturates around 128 in flight. Doubling concurrency beyond that
reduces rate and sharply worsens tail latency.

A second post-change sweep held total maximum concurrency at 64 while trading
connections against streams per connection. This separates useful parallel
connection ownership from merely adding more in-flight work:

| Connections x streams | Maximum in flight | Requests/s |
| ---: | ---: | ---: |
| 2 x 32 | 64 | 93,273 |
| 4 x 16 | 64 | **146,961** |
| 8 x 8 | 64 | 127,019 |
| 16 x 4 | 64 | 71,391 |
| 32 x 2 | 64 | 38,779 |
| 64 x 1 | 64 | 22,923 |

Four reused connections were the local optimum. Two connections expose
per-connection controller serialization; eight or more add TLS/socket and
scheduling work faster than they add useful parallelism. Consequently, the
147k result is not evidence that connection count itself should be maximized.

### H3 client concurrency

The one-loop stream sweep held the client at four Python processes and 64
total QUIC connections. Maximum in-flight request concurrency is therefore
`connections x streams`:

| Streams/connection | Maximum in flight | Requests/s | p50 (ms) |
| ---: | ---: | ---: | ---: |
| 1 | 64 | 15,231 | 4.271 |
| 4 | 256 | 19,824 | — |
| 8 | 512 | 23,482 | — |
| 16 | 1,024 | 24,804 | — |

This is why a one-loop result can be either about 15k or 25k without a server
change: 64 in-flight requests do not saturate the same path as 1,024. The
16-loop final campaign used eight Python processes, 128 total connections,
and 16 streams per connection, for a maximum of 2,048 in-flight requests.

### Size sensitivity

The maintained H3 fixture's `--response-bytes` option expands the same route
parameter, so both request target and response grow without changing routing
or protocol behavior. A 1,024-byte case used:

```sh
build/oracle/aioquic/bin/python showcases/http3_benchmark.py \
  --port 18443 --response-bytes 1024 --requests 200000 \
  --workers 8 --connections 128 --streams 16 --timeout 20
```

| Protocol, 16 loops | Bytes | Requests/s | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| H1 | 1,024 | 86,548 | 0.620 | 1.432 | 3.101 |
| H2 | 1,024 | 25,054 | 2.546 | 2.858 | 3.004 |
| H3 | 1,024 | 33,746 | 28.916 | 73.220 | 179.143 |

H1's larger-body rate exceeded its immediately preceding 10-byte spot check,
which confirms material run-order/noise on this laptop; use the latency and H3
rate drop as the useful size signal, not a cross-run H1 throughput conclusion.

## Profiles and ranked hypotheses

macOS `sample` was used for low-drag server and client sampling. Trace-enabled
builds were excluded from all reported rates.

1. **HTTP/2 created and destroyed a lightweight handler task per request.**
   Stream slots were already bounded to 32 per connection and protected by an
   explicit completion/continuation-pin state. Each connection now creates a
   handler lazily per used slot, rendezvouses it for later requests assigned to
   that slot, frees the per-request backend only when the existing state says
   it is safe, and shuts workers down deterministically with the connection.
   One-loop median throughput improved 49.2%; 16-loop median throughput
   improved 180.5%. The task/context mapping hot path disappeared. Full tests
   and the complete H2 qualification, including h2spec 146/146, passed.

2. **HPACK response encoding scanned the static table twice per field.** The
   exact-value and name-only searches each constructed up to 61 unconstrained
   static-name string results. A direct canonical-name matcher now collects
   both indexes in one pass while preserving every RFC table index and encoded
   representation. One-loop median throughput improved from 29.002k to
   39.187k requests/s (+35.1%); the 16-loop result was neutral after saturation.
   The independent 500-case HPACK and 1,000-case Huffman differential suites,
   full repository tests, and complete H2 qualification passed.

3. **HTTP/2 stream-slot reuse recreated wake descriptors per request.** Each
   released slot destroyed its lazy wake source, so reuse paid for pipe
   creation, descriptor configuration, and close even though the controller
   and its 32 slots remained alive. Completed slots now drain pending wakeups
   and retain their source until connection finalization. One-loop median
   throughput improved from 39.187k to 44.804k requests/s (+14.3%), and the
   16-loop median improved from 90.237k to 147.435k (+63.4%). `pipe`, `close`,
   and `fcntl` disappeared from the leading post-change sample. Full repository
   tests and the complete H2 qualification passed again.

4. **Packet output and descriptor/source-address work dominate the H3
   server.** In the active 16-loop server sample the leading stacks included
   `sendmsg` (56,142 samples), `kevent` (7,759), `memmove` (4,822), `fcntl`
   (3,052), `memset` (1,684), `setsockopt` (1,364), scheduler current-fiber
   work (850), `recvmsg` (715), and `getsockname` (681). QPACK field-name work
   was only 533 samples and crypto was sparse. Routing and response construction
   did not dominate. Flyology's native `flyology_socket_send_datagram` calls
   `getsockname` for every source-selected datagram and emits one `sendmsg` per
   call. Caching verified local endpoint data and packet batching are plausible
   upstream work. This crate was not changed to work around Flyology core.

5. **QPACK response encoding repeatedly constructed static-table names.** At
   one-loop server saturation, the encoder's exact lookup called the static
   table `Name` function for up to 99 entries per response header. Returning
   unconstrained strings drove secondary-stack allocation and lightweight-task
   lookup work. A direct name matcher plus one combined exact/name pass keeps
   the canonical table API and wire representation unchanged. Three controlled
   200,000-request medians improved from 27,310 to 30,097 requests/s (+10.2%).
   A 1,000,000-request pair improved from 29,436 to 32,646 requests/s (+10.9%).
   In comparable active samples, secondary-stack allocation samples fell from
   125 to 42, scheduler current-task samples from 392 to 231, and static `Name`
   disappeared. Differing sample totals make those counts mechanism evidence,
   not exact time percentages. Three 16-loop repetitions were 57.22k, 57.38k,
   and 55.65k, neutral relative to the previous 58.94k best once client and
   packet I/O dominate.

6. **ACK processing copied large retransmission tables per packet.** The
   application-space packet transaction copied a roughly 72 KiB
   retransmittable table plus packet-frame table before applying ACK events.
   The accepted change stages only the bounded packet-event resolution log,
   applies it after all fallible frame processing succeeds, then commits the
   smaller sent/recovery candidates. Controlled one-loop median rate improved
   25,725 to 26,827 requests/s (+4.3%); 16-loop results were neutral within
   noise, so no multi-loop gain is attributed to this change.

7. **The Ada H3 client allocated a large event object twice per request.** A
   pooled connection now retains one event object and frees it with the
   transport. In a 640,000-request, 64-connection optimized Ada-client run,
   rate improved from 31,543 to 35,284 requests/s (+11.9%) and mean latency
   from 1.990 to 1.790 ms (-10.1%). Pool diagnostics were 64 created, 639,936
   reused, 64 idle, zero closed. Before, `madvise` appeared 2,944 times and the
   body reader's allocation path was hot; afterward `madvise` disappeared from
   the leading sample and `memset` samples fell from 5,577 to 2,276. Sample
   totals differed, so counts support the allocation mechanism rather than an
   exact percentage claim.

8. **Eager per-connection request header slots inflated server memory.** Eight
   bounded slots embedded full header blocks even when unused. Header blocks
   are now allocated on first slot use, retained for the connection, and freed
   during cleanup. At 64 H3 connections peak physical memory fell from 309.9
   to 250.1 MB (about 19%); at 128 connections RSS fell from about 632 to 495
   MB (about 22%). Throughput remained in the 50k+ band. This is a capacity
   improvement, not a claimed request-rate win.

9. **Single-process aioquic is an oracle bottleneck.** One worker stayed near
   13k even against 16 loops. Four workers sustained about 50k; eight reached
   54-59k. The benchmark now records workers explicitly so “single client” is
   not confused with “single Flyology loop.”

Timer scans, routing, and cryptography were not leading server samples. QPACK
was material only in the saturated one-loop profile; it was small in the
16-loop packet-I/O-dominated profile.
`kevent` and scheduler samples show normal waits/wakeups, but no lock hotspot
larger than packet I/O was found. A 2,000,000-request eight-worker run declined
to 43.1k requests/s with worse tails; client time was 46.97 s real, 168.03 s
user, 15.86 s system, 156.7 MB maximum RSS, and 588,945 involuntary context
switches, reinforcing client/process scheduling and long-run connection
lifecycle pressure.

## Rejected experiments

- A direct QPACK static-name scan passed exhaustive checks but measured
  13.606k, 12.530k, and 13.533k requests/s against the 13.768k one-worker
  baseline, with no latency gain. Reverted.
- Lazy staging of flow/ACK candidates only when affected frames appeared
  passed all 42 QUIC tests but measured 13.099k, 13.383k, and 13.314k. Typical
  packets carried ACK work, so the branch did not avoid the dominant copy.
  Reverted.
- Increasing workers beyond eight and repeatedly opening new 128-connection
  generations worsened handshake latency and throughput. Those runs are useful
  saturation evidence, not accepted tuning changes.
- Raising the default bidirectional-stream flow-credit refill threshold from
  one-half to three-quarters measured 25.742k, 25.809k, and 26.387k requests/s
  versus a reverse-order baseline median of 27.310k (-5.5%). Reverted.
- Adding direct static-table value matching after the accepted QPACK name
  matcher measured a 29.752k median versus 30.097k (-1.1%). Reverted.
- A round-robin HTTP/3 request-slot polling cursor was rejected before code:
  completed streams are released immediately, so the common path reuses the
  first free transport entry; retaining a cursor would keep more bounded
  request state live without evidence of scan pressure.
- Replacing response-validation and QPACK-encoding string results with
  variable-bound slice renames measured 25.644k and 21.295k requests/s versus
  a fresh-server baseline median of 28.484k. Tail latency also worsened. The
  generated variable-slice path was more expensive than the compiler's
  existing scalarized string-result path. Reverted.
- Copying only meaningful HTTP/3 field bytes across the public/internal QPACK
  boundary stalled one load run and measured 23.428k on a clean repeat. Fixed
  bounded-record assignment was cheaper than the added variable-length work.
  Reverted.
- Removing redundant-looking QPACK decoder buffer and record clears measured
  28.219k, 28.281k, and 28.443k requests/s (28.281k median, -0.7%). Reverted.
- Additive indexed name/value accessors avoided returning a complete bounded
  field record but measured 26.241k and 26.486k requests/s. Cross-package
  string-result overhead outweighed the saved copy. The API addition was
  removed.
- Collapsing four high-level request-header searches into one positional pass
  measured 28.588k, 26.826k, and 29.309k requests/s (28.588k median, +0.36%).
  The result was inside noise with worse variance, so it was reverted.
- Caching a validated and QPACK-encoded HTTP/3 response field section per
  connection for exact repeated headers used strict byte matching and bounded
  itself to eight fields and 1,024 input bytes. It measured 27.250k and
  27.947k requests/s versus a fresh 28.484k baseline median. The lookup and
  retained state cost more than encoding the small response; reverted.
- Replacing the HTTP/3 datagram channel's fixed-record copies with a bounded
  preallocated handle pool targeted the leading one-loop `memmove` stack. A
  clean explicit-custom-RTS baseline measured 30.801k requests/s and the
  candidate measured 30.837k (+0.12%) with `--requests 400000 --workers 4
  --connections 64 --streams 16 --timeout 20`. P50/p95/p99 latency was
  effectively unchanged. The extra ownership machinery had no material
  benefit, so it was reverted.

## Correctness qualification

Commands and final results:

```sh
./scripts/test.sh
./scripts/http2-test.sh qualification
FLYOLOGY_QUIC_TRACE=false ./scripts/test-http3-interop.sh all
FLYOLOGY_QUIC_TRACE=false ./scripts/test-http3-h3spec.sh
FLYOLOGY_QUIC_TRACE=false \
FLYOLOGY_HTTP3_STRESS_PEAK_CONCURRENCY=128 \
FLYOLOGY_HTTP3_CLIENT_STRESS_WORKERS=64 \
FLYOLOGY_HTTP3_CLIENT_STRESS_REQUESTS=16 \
FLYOLOGY_HTTP3_STRESS_LOOP_POOL_SIZE=16 \
  ./scripts/test-http3-stress.sh
```

- Full repository behavioral suite: pass, including all 42 QUIC checks.
- H2: Go, Node, and nghttpd peers passed in native and lightweight models;
  fault campaign and bounded soak passed; h2spec 146/146 passed. The full H2
  qualification was repeated after all three accepted H2 changes. The HPACK and
  Huffman differential suites passed 500 and 1,000 cases respectively.
- H3: aioquic and quic-go passed in both Ada client and Ada server roles.
- h3spec 0.1.13: a first run passed all HTTP/3 and QPACK cases but was 48/49
  because one randomized QUIC Handshake reserved-bit case did not observe its
  expected exception; an immediate fresh-server rerun passed 49/49.
- Bounded H3 stress: hostile UDP and 64 malformed cases passed; server load
  passed through 128 connections and 128-way concurrency; Ada client passed
  1,024/1,024 requests. One preceding identical run had one 60-second aioquic
  handshake timeout at the 64-connection phase; a fresh-server rerun passed
  all phases and the isolated timeout is retained here rather than hidden.

## Remaining bottlenecks

- Minimize or batch one-datagram-at-a-time output and cache safe source/local
  endpoint metadata in Flyology core. The minimal upstream profile is an
  optimized 16-loop server, tracing off, eight aioquic processes, 128 QUIC
  connections and 16 streams each: the send stack configures descriptor/socket
  state, obtains the local endpoint for source-selected datagrams, then issues
  one `sendmsg`. `fcntl`, `setsockopt`, and `getsockname` all remain visible
  beside `sendmsg`. This repository deliberately does not modify Flyology core.
- Investigate delayed retirement of old H3 connection generations and long-run
  throughput decay with a lifecycle-focused diagnostic build.
- Reduce multi-process client scheduling and packet receive overhead before
  treating 59k as a server ceiling.
- The post-wake-source H2 profile is led by TLS/socket calls,
  scheduler/task-local lookup, byte comparison, and remaining bounded header
  construction. One loop reached a 44.8k median and 16 loops a 147.4k median
  with four connections x 16 streams. At the same total concurrency, both
  fewer and additional connections regress, locating the next scaling work in
  per-connection serialization versus TLS/socket/scheduler overhead rather
  than another indiscriminate concurrency increase.
- Repeat on a quiescent, thermally controlled machine and on Linux before
  making cross-platform claims.
