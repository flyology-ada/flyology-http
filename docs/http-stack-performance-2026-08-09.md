# HTTP stack performance notebook, 2026-08-09

These are local experimental measurements, not portable or production-level
claims. The server, route, clients, machine power state, and process lifecycle
all materially affect the results.

## Scope and environment

- Baseline: `main` at `8b09b0f4830683d6d76c4e31ffa5dd31a2386988`.
- Working branch: `codex/http-stack-performance`.
- Flyology: Alire `0.1.0-dev` at
  `1acfd59312ea36a8c0d2e2112cf242a66c78a4ae`, resolved from the project
  index after [Flyology PR #31](https://github.com/flyology-ada/flyology/pull/31)
  and [alire-index PR #4](https://github.com/flyology-ada/alire-index/pull/4)
  were merged. Their merge commits were `1acfd59312ea36a8c0d2e2112cf242a66c78a4ae`
  and `dd5c12ded8ccb3fd754732842203150acb51d65e` respectively.
- Machine: MacBook Pro `Mac15,9`, Apple M3 Max, 16 cores (12 performance,
  4 efficiency), 48 GB RAM.
- OS: macOS 26.5.2, Darwin 25.5.0, arm64.
- Clients: oha 1.7.0 for H1/H2; aioquic 1.3.0 for H3.
- Route: the same Routing API handler at `GET /hello/{name}` over H1, H2,
  and H3. The default benchmark target was `/hello/test`, status 200 and body
  `hello test` (10 bytes).
- Build: release switches (`-O3`, inlining), assertions and validity checks
  retained by the showcase project, `FLYOLOGY_QUIC_TRACE=false`.

Accepted implementation commits from the `8b09b0f` baseline are:

```text
65269d4  transactional ACK event staging
9f5a157  lazy H3 request-header slots
27c5408  retained Ada H3 client event storage
e7cf51d  allocation-free QPACK static-name matching
5d8414c  reusable H2 handler tasks
7041891  direct HPACK static matching
44450d4  retained H2 stream wake sources
3e80047  compact H3 request slots
6a73671  bounded common QPACK lookup ranges
a6485e1  QUIC key-update send-key synchronization
2a2612e  compiled multiprocess aioquic benchmark path
05db017  bounded transactional H3 response packet batching
3432181  one timeout context per validated aioquic batch
```

Notebook-only commits between those implementation slices preserve the raw
campaign history in Git. No branch from this worktree was pushed and no HTTP
repository pull request was opened.

## Runtime preparation and fail-closed checks

Every performance and standalone H3 qualification/stress binary used an
explicit Flyology lightweight RTS. No H3 performance harness was built or run
with GNAT's default RTS. The one-loop and 16-loop roots were
`build/perf-rts-l1-1acfd593` and `build/perf-rts-l16-1acfd593`.

Representative 16-loop preparation and clean build:

```sh
alr update
alr with flyology=0.1.0-dev
flyology_root=$(./scripts/resolve-flyology-root.sh)

FLYOLOGY_RTS_DIR="$PWD/build/perf-rts-l16-1acfd593" \
FLYOLOGY_DEFAULT=lightweight \
FLYOLOGY_LOOP_POOL_SIZE=16 \
  "$flyology_root/scripts/prepare-rts.sh"

test -f build/perf-rts-l16-1acfd593/.flyology-rts-root
grep -q 'Flyology prepared RTS version' \
  build/perf-rts-l16-1acfd593/.flyology-rts-root
grep -q 'Lightweight : constant Boolean := True;' \
  build/perf-rts-l16-1acfd593/adainclude/s-fldeex.ads

./showcases/prepare-alire.sh release
cd showcases
FLYOLOGY_RTS_DIR=../build/perf-rts-l16-1acfd593 \
  alr exec -- env -u GPR_CONFIG gprclean -r -q -P showcases.gpr
FLYOLOGY_RTS_DIR=../build/perf-rts-l16-1acfd593 \
FLYOLOGY_SHOWCASE_PROFILE=release \
FLYOLOGY_QUIC_TRACE=false \
  alr exec -- env -u GPR_CONFIG gprbuild \
    --RTS=../build/perf-rts-l16-1acfd593 -p -P showcases.gpr \
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
  --workers 8 --connections 8 --streams 16 --timeout 20
```

The H3 fixture keeps connections open, validates every status/body, separates
handshake and request latency, reports connection reuse, and uses multiple
processes when one Python event loop would be the limiting component. The
final topology uses eight total persistent connections, one per worker, and
16 concurrent streams per connection: 128 maximum requests in flight and
100,000 validated requests per connection. Earlier 128-connection trials are
retained below as lifecycle and saturation evidence, not the final operating
point.

## Baselines and final measurements

The baseline table uses medians of three controlled trials where available.
The final H3 median uses fresh servers; the strict spot check was repeated
after the full qualification campaign. Latency values are milliseconds. All
requests succeeded.

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
| H3, 1 loop, compact request slots | **31,713** | about 29.8 | — | — | same; +5.6% against fresh 30,019 median |
| H3, 1 loop, bounded common QPACK lookup | **32,819** | 28.802 | — | — | same; +3.5% over compact slots, +9.3% over fresh 30,019 median |
| H3, 1 loop, final comparable topology | **42,733** | 20.761 | 21.832 | 22.480 | 64 connections x 16 streams; +30.2% over 32,819 |
| H3, 1 loop, final low-connection topology | **47,013** | 1.114 | 1.418 | 1.650 | 4 persistent connections x 16 streams; 64 in flight |
| H1, 16 loops, baseline median | 98,299 | 0.459 | 1.700 | 3.285 | 64 connections |
| H2, 16 loops, baseline median | 32,035 | 1.946 | 2.552 | 2.795 | 4 connections x 16 streams |
| H2, 16 loops, reusable handlers median | **89,856** | 0.533 | 0.987 | 5.762 | same; +180.5% |
| H2, 16 loops, direct HPACK match median | 90,237 | 0.540 | 0.855 | 3.927 | same; +0.4%, neutral |
| H2, 16 loops, retained wake sources median | **147,435** | 0.3 | 0.6 | 3.0 | same; +63.4% over direct HPACK match |
| H3, 16 loops, baseline | 54,123 | — | — | — | 8 workers, 128 connections x 16 streams |
| H3, 16 loops, pre-QPACK best | **58,935** | 24.896 | 51.082 | 78.762 | 8 workers, 128 connections x 16 streams; reuse 6,250x |
| H3, 16 loops, QPACK median | 57,222 | 26.617 | 46.145 | 65.833 | same; neutral within run noise |
| H3, 16 loops, compact request slots median | 57,578 | — | — | — | same; neutral, best 61,596 |
| H3, 16 loops, final bounded lookup median | 54,390 | 26.982 | 54.148 | 71.293 | same; neutral-to-uncertain in the 16-loop run band |
| H3, 16 loops, response packet batching | 125,915 | — | — | — | 8 persistent connections x 16 streams; 128 in flight |
| H3, 16 loops, final median | **143,709** | 0.673 | 0.858 | 0.969 | same; 100,000 requests/connection |
| H3, 16 loops, post-qualification spot | **146,562** | 0.653 | 0.807 | 0.894 | same; 800,000/800,000 validated |
| H1, 16 loops, post-qualification spot | 79,856 | 0.746 | 1.446 | 2.519 | 64 persistent connections |
| H2, 16 loops, post-qualification spot | **148,167** | 0.337 | 0.573 | 3.180 | 4 connections x 16 streams |

The pre-QPACK 58.9k H3 run took 13.574 s for 800,000 requests. Its 128
connections and 2,048 in-flight requests generated far more client and
connection-lifecycle work than the final eight-connection topology. The final
H3 median is 97.5% of the retained 147.435k H2 median. The strict
post-qualification spot checks put H3 at 98.9% of the matching 148.167k H2
spot check. This is local parity for the short route on this M3 Max, not a
portable claim that the protocols have equal cost.

The three final fresh-server H3 runs, in requests/s with p50/p95/p99
milliseconds, were `141545.3377 (0.6767/0.8746/1.0106)`, `145327.4412
(0.6652/0.8325/0.9346)`, and `143708.9714 (0.6733/0.8578/0.9693)`. The strict
post-qualification run was `146562.4085 (0.6531/0.8072/0.8935)`, completed
800,000 validated responses in 5.458 s, reused each of eight connections
100,000 times, and had a 22.088 ms median handshake. The adjacent oha H2 spot
check was 148166.7055 requests/s; H1 was 79856.4328 requests/s.

The original approximately 13.9k H3 result is reproducible, but it measures a
single aioquic process: the Python client was about 98.5% of one core while the
server was about 66% of one core. Multiprocess load exposes server capacity.
With 16 positively probed Flyology loops, sustained H3 first crossed 50k with
many connections, reached 125.9k after response packet batching, then reached
a 143.7k median after removing per-event timeout-task overhead from the
maintained Python oracle. Eight client workers remained the local optimum.

The pre-coalescing one-loop campaign used this client command against a fresh
server for each trial:

```sh
build/oracle/aioquic/bin/python showcases/http3_benchmark.py \
  --port 18443 --path /hello/test --requests 400000 \
  --workers 4 --connections 64 --streams 16 --timeout 20
```

That is 1,024 maximum in-flight requests, 6,250 requests per connection, and
64 reused QUIC connections. The earlier 16-loop command used 800,000
requests, eight workers, 128 connections, and 16 streams, for 2,048 maximum
in flight and the same 6,250x connection reuse. The final topology sweep
instead found eight connections x 16 streams to be substantially faster.

The final source was rebuilt cleanly with
`build/perf-rts-l1-1acfd593`, and the runtime probe printed `1`. A comparable
200,000-request run at four workers, 64 connections, and 16 streams measured
42.733k requests/s, +30.2% over the 32.819k pre-coalescing median. Reducing
that topology to four persistent connections x 16 streams measured 47.013k
requests/s with p50/p95/p99 of 1.114/1.418/1.650 ms. Both commands were the
final command above with `--requests 200000 --workers 4`, changing
`--connections` between 64 and 4.

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

This historical sweep is why a pre-coalescing one-loop result could be either
about 15k or 25k without a server change: 64 in-flight requests did not
saturate the same path as 1,024. With response batching, four connections x
16 streams instead reached 47.013k at only 64 in flight. The
earlier 16-loop campaign used eight Python processes, 128 total connections,
and 16 streams per connection, for 2,048 in flight. After packet batching,
the final campaign used eight processes, eight total persistent connections,
and 16 streams per connection, for 128 in flight.

The final topology sweep held the server and eight persistent connections
constant after response batching:

| Connections x streams | Maximum in flight | Requests/s | p50 | p99 |
| ---: | ---: | ---: | ---: | ---: |
| 8 x 8 | 64 | 89,748 | — | — |
| 8 x 16 | 128 | **125,915** | — | — |
| 8 x 32 | 256 | 128,146 | 1.210 | 4.020 |

Sixteen streams supplied most of the useful scaling. Doubling to 32 added
only 1.8% while materially worsening latency, so 128 in flight was retained
as the local operating point.

### H1 lightweight follow-up

The H1 follow-up started from merged `main` at `9e0040f` and kept the same
explicitly probed 16-loop lightweight RTS, unified TLS route, disabled QUIC
tracing, oha 1.7.0 client, and 16 persistent H1 connections. Three initial
200,000-request trials measured 93.791k, 96.293k, and 94.385k requests/s
(94.385k median), with median p50/p95/p99 of approximately
0.152/0.286/0.403 ms. Splitting the same 16 connections across four concurrent
oha processes measured 96.373k aggregate, so one oha process was not the
observed ceiling.

The server sample showed the request-head path in 1,636 of 2,942 active
samples on a representative worker. Of those, 854 were the expected readiness
wait and 675 were active `SSL_read` work. Header parsing and allocation were
visible in the remainder, but were not dominant.

Reusing the pending-string allocation and overwriting same-shaped method,
target, and header fields was rejected. An initial interleaved run was
invalidated because background compilation loaded the preserved-baseline half
of the comparison. After all builds stopped, candidate trials measured
94.955k and 99.629k requests/s while adjacent preserved-baseline trials
measured 99.214k and 93.747k. The candidate median was 97.292k versus 96.481k,
only +0.84%, within run variance. All 1.2 million measured responses returned
status 200. The command shape for each trial was:

```sh
oha -n 300000 -c 16 --http-version 1.1 --insecure --no-tui --json \
  https://127.0.0.1:21443/hello/test
```

A five-million-request steady TLS run measured 86.480k requests/s overall;
its per-second median was 94.962k and the p50/p95/p99 latency was
0.154/0.322/0.904 ms. Simultaneous ten-second server and client samples are
retained as `/tmp/flyology-h1-lightweight-server-20260809.sample.txt` and
`/tmp/flyology-h1-oha-20260809.sample.txt`. The server sample again placed the
serial request path under `SSL_read`, `Wait_Interruptibly`, and
`Runtime_Wait_IO_Many`. Every wait registers the socket together with stable
connection-close, server-shutdown, and token descriptors plus a timeout, then
the scheduler removes those interests after the wake. Event-loop active work
was uneven: scheduler samples ranged from 4,019 to 5,882 of 6,691 per loop,
leaving approximately 0.8k to 2.7k samples per loop for fibers.

The maintained cleartext engine fixture separated TLS from runtime and HTTP
costs. With the same release profile and explicitly probed 16-loop RTS, a
300,000-request concurrency sweep measured:

| Concurrency | Requests/s | p50 | p95 | p99 |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 95,691 | 0.145 | 0.309 | 0.486 |
| 32 | 83,468 | 0.281 | 0.942 | 1.905 |
| 64 | 99,927 | 0.446 | 1.726 | 3.735 |
| 128 | **109,693** | 0.788 | 3.137 | 6.649 |
| 256 | 108,314 | 2.000 | 5.278 | 9.221 |

Cleartext and TLS are therefore both about 96k at the 16-connection operating
point; crypto is not the missing 40--45k requests/s. Sixteen separate
one-loop processes sharing the cleartext port with `SO_REUSEPORT` were also
rejected as a placement diagnostic. They reached only 49.984k and 50.122k at
concurrency 16 and 32, then degraded to 42.368k/29.989k/29.983k at
64/128/256. Multiplying processes and runtimes costs more than any connection
distribution benefit; no portal change was retained.

Removing the request deadline was tested only to bound timer-registration
cost, not as a proposed configuration. A short interleave initially suggested
an 8.1% improvement, but longer one-million-request trials rejected it:
no-timeout candidates measured 87.882k and 96.539k around a 95.278k
finite-timeout baseline. The candidate median was 3.2% lower and latency
distributions overlapped. Bounded timeout behavior was retained unchanged.

Raising the showcase TCP request lifetime from 1,000 to 100,000 was rejected:
three trials measured a 75.100k median, below the earlier 94.385k baseline.
Keeping the initial small connection set indefinitely preserves uneven loop
placement; bounded reconnection periodically redistributes it. A response-head
rewrite with one-second Date caching was also rejected after an adjacent
300,000-request A/B measured 71.638k versus 72.434k for the preserved binary
(-1.1%). Native TCP handlers were explicitly excluded from this follow-up; the
goal remains the 16-loop lightweight runtime.

### Size sensitivity

The maintained H3 fixture's `--response-bytes` option expands the same route
parameter, so both request target and response grow without changing routing
or protocol behavior. A 1,024-byte case used:

```sh
build/oracle/aioquic/bin/python showcases/http3_benchmark.py \
  --port 18443 --response-bytes 1024 --requests 50000 \
  --workers 8 --connections 8 --streams 16 --timeout 20
```

| Protocol, 16 loops | Bytes | Requests/s | p50 | p95 | p99 |
| --- | ---: | ---: | ---: | ---: | ---: |
| H1 | 1,024 | 86,548 | 0.620 | 1.432 | 3.101 |
| H2 | 1,024 | 25,054 | 2.546 | 2.858 | 3.004 |
| H3, final fallback | 1,024 | 28,409 | 2.263 | 3.871 | 4.639 |

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

4. **The Flyology UDP send path repeated socket setup and endpoint discovery.**
   In the active 16-loop server sample the leading stacks included `sendmsg`
   (56,142 samples), `fcntl` (3,052), `setsockopt` (1,364), and `getsockname`
   (681); crypto and QPACK were sparse. The separately reviewed Flyology PR
   #31 removed repeated work in the task-aware datagram path and added portable
   `SO_REUSEPORT` support without changing this HTTP crate. Its maintained UDP
   benchmark median improved from 34,373 to 38,512 datagrams/s (+12.0%). The
   exact Flyology commit was then published through alire-index PR #4 and used
   to prepare both explicit lightweight RTS roots above.

5. **One small H3 response consumed one QUIC packet and one `sendmsg`.** The
   unified server now prepares complete bounded responses and transactionally
   combines up to eight independent STREAM frames into one protected 1-RTT
   packet. Flow-control reservations, sent-packet accounting, recovery data,
   final sizes, and request release commit only after the complete batch is
   accepted. Oversize batches fall back to individual response packets, so
   1,024-byte responses preserve the previous path. At eight connections x
   eight streams, rate rose from the 73--74k band to 85.459k and 89.748k.
   With eight connections x 16 streams it reached 125.915k. In comparable
   active samples, `sendmsg` fell from 8,353 to 732 observations, roughly the
   expected eight-response aggregation effect; differing sample totals make
   this mechanism evidence rather than an exact percentage. The post-change
   sample was led by waits, then `memmove` 1,503, `sendmsg` 732, `memset` 592,
   flow reservation 115, and `recvmsg` 80. Routing, QPACK, timers, and crypto
   were not the limiting stacks.

6. **The maintained aioquic oracle created and cancelled a timeout task for
   every received H3 event.** A single `asyncio.timeout` now bounds each
   validated request batch while the inner loop awaits the queue directly.
   This preserves the same timeout, status, body, and completion checks. Three
   fresh 800,000-request trials at eight workers, eight connections, and 16
   streams measured 141.545k, 145.327k, and 143.709k requests/s (143.709k
   median). A representative before run consumed 33.44 s client user CPU over
   6.36 s real; a representative after run consumed 30.25 s user CPU over
   5.96 s real. System CPU and context-switch counts did not improve
   consistently, so no broader CPU reduction is claimed. This experiment
   demonstrated that the earlier 125.9k result still included material oracle
   overhead.

7. **QPACK response encoding repeatedly constructed static-table names.** At
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

8. **ACK processing copied large retransmission tables per packet.** The
   application-space packet transaction copied a roughly 72 KiB
   retransmittable table plus packet-frame table before applying ACK events.
   The accepted change stages only the bounded packet-event resolution log,
   applies it after all fallible frame processing succeeds, then commits the
   smaller sent/recovery candidates. Controlled one-loop median rate improved
   25,725 to 26,827 requests/s (+4.3%); 16-loop results were neutral within
   noise, so no multi-loop gain is attributed to this change.

9. **The Ada H3 client allocated a large event object twice per request.** A
   pooled connection now retains one event object and frees it with the
   transport. In a 640,000-request, 64-connection optimized Ada-client run,
   rate improved from 31,543 to 35,284 requests/s (+11.9%) and mean latency
   from 1.990 to 1.790 ms (-10.1%). Pool diagnostics were 64 created, 639,936
   reused, 64 idle, zero closed. Before, `madvise` appeared 2,944 times and the
   body reader's allocation path was hot; afterward `madvise` disappeared from
   the leading sample and `memset` samples fell from 5,577 to 2,276. Sample
   totals differed, so counts support the allocation mechanism rather than an
   exact percentage claim.

10. **Eager per-connection request header slots inflated server memory.** Eight
   bounded slots embedded full header blocks even when unused. Header blocks
   are now allocated on first slot use, retained for the connection, and freed
   during cleanup. At 64 H3 connections peak physical memory fell from 309.9
   to 250.1 MB (about 19%); at 128 connections RSS fell from about 632 to 495
   MB (about 22%). Throughput remained in the 50k+ band. This is a capacity
   improvement, not a claimed request-rate win.

11. **Materializing a second full H3 header block per active request was still
   expensive.** A fresh optimized one-loop baseline at `e6272f4` measured
   30.019k requests/s. The server adapter now writes decoded method, target,
   authority, and ordinary headers directly into the unified request retained
   by each bounded slot instead of retaining a separate, roughly 139 KiB
   public H3 header block and copying it at dispatch. Three trials at
   `3e80047` measured a 31.713k median (+5.6%), with p50 consistently about
   29.6--29.8 ms instead of about 30.8--31.9 ms. A 1,000,000-request run
   reached 32.123k with p50/p95/p99 of 30.257/32.995/33.689 ms. In comparable
   server samples, active physical footprint fell from 247.8 to 189.1 MB and
   `memmove` samples fell from 2,242 to 1,960 despite higher throughput. The
   16-loop median was 57.578k, neutral in the existing run band.

12. **Common response fields still searched irrelevant QPACK ranges.** The
    prior accepted QPACK matcher removed secondary-stack-heavy name
    construction, but `:status`, `content-type`, and `content-length` still
    walked entries that cannot match those names. Restricting exact lookup to
    their RFC 9204 static-table ranges while preserving the generic fallback
    raised the one-loop median from 31.713k to 32.819k (+3.5%); the three
    trials were 31.974k, 33.068k, and 32.819k. A 1,000,000-request run measured
    32.678k with p50/p95/p99 of 29.606/31.968/44.142 ms. Comparable profile
    samples in `QPACK_Static_Table.Find` fell from 227 to 23, about 90%. The
    16-loop trials were 58.074k, 54.390k, and 53.994k (54.390k median), below
    the preceding compact-slot median but within the broad 47.5--61.6k
    multi-loop band. No 16-loop gain is claimed.

13. **Single-process aioquic is an oracle bottleneck.** One worker stayed near
   13k even against 16 loops. Four workers sustained about 50k; eight reached
   54-59k before packet batching and over 140k afterward. The benchmark now
   records workers explicitly so “single client” is not confused with “single
   Flyology loop.”

14. **Connections and in-flight streams have distinct costs.** The old
   128-connection topology required 2,048 in-flight requests to reach 54--59k
   and accumulated retirement pressure across generations. With response
   batching, eight persistent connections x 16 streams reached 125.915k before
   the oracle fix and the 143.709k final median afterward. Eight x 32 reached
   128.146k before the oracle fix, only 1.8% above eight x 16 while p50/p99
   rose to 1.210/4.020 ms. More concurrency was not free capacity.

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
- Moving one redundant public `QUIC.Datagram` clear to the uninitialized error
  path measured 33.058k, 33.039k, and 32.966k requests/s (33.039k median), only
  +0.67% over the final QPACK baseline. It was reverted as non-material.
- Leaving the internal 1,109-byte combined HEADERS/DATA staging array
  uninitialized, after proving the transmitted slice is fully assigned,
  measured 33.130k, 33.130k, and 32.946k requests/s (33.130k median), +0.95%.
  This was also reverted rather than trading easier initialization reasoning
  for a sub-one-percent result.
- Replacing transactional flow-control candidate state with repeated no-copy
  preflight scans passed the batching test but regressed an exact 800,000
  request pair from 91.272k to 82.948k requests/s. The bounded candidate copy
  was restored.
- Preparing directly into the pending response slot removed one 1,100-byte
  record copy. Three fresh baseline trials had an 86.535k median and three
  candidate trials an 87.349k median (+0.94%) with wide overlap. The more
  complicated calling convention was reverted.
- Raising the response batch cap from eight to 16 measured 126.595k at eight
  connections x 16 streams, only +0.54% with a worse median latency. The cap
  returned to eight. Raising streams to 32 reached 128.146k, only +1.8% over
  the 16-stream point while p50/p99 rose to 1.210/4.020 ms; no code or default
  was changed for that operating point.
- Replacing the aioquic driver's fixed per-connection batches with rolling
  stream replenishment did not expose hidden server capacity. Against fresh
  otherwise identical one-listener servers, with 400,000 requests, eight
  workers, eight persistent connections, and eight streams, the maintained
  batch driver measured 70.362k requests/s. Replenishing each completed stream
  immediately measured 62.640k (-11.0%); refilling half of the window at once
  measured 64.634k (-8.1%). The eager variants also raised median response
  latency from 0.565 to 0.865--0.745 ms. aioquic coalesces each fixed request
  batch before transmitting it; eager refill traded the batch barrier for more
  client packet/oracle overhead. Both variants were reverted.

## Correctness qualification

Commands and final results:

```sh
./scripts/test.sh
./scripts/prove.sh
./scripts/docs.sh
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

- Full repository behavioral suite: pass after the final source changes,
  including all 43 QUIC checks and 56 behavioral checks. The new standalone
  batch smoke test validates two streams in one packet and verifies that an
  aggregate connection-credit failure leaves all flow state uncommitted. The
  SPARK campaign passed, and GNATdoc generated `docs/api/index.html`.
- H2: Go, Node, and nghttpd peers passed in native and lightweight models;
  fault campaign and bounded soak passed; h2spec 146/146 passed. The full H2
  qualification was repeated after the final H3 changes as a cross-protocol
  guard. The HPACK and Huffman differential suites passed 500 and 1,000 cases
  respectively.
- H3: aioquic and quic-go passed in both Ada client and Ada server roles.
- h3spec 0.1.13: 49/49 examples passed.
- Bounded H3 stress: hostile UDP and 64 malformed cases passed; churn passed
  at 16, 32, 64, and 128 connections; server load passed at 128-way
  concurrency; the Ada client passed 1,024/1,024 requests.

## Remaining bottlenecks

- The short-response path is now close to H2 locally, but a response whose
  encoded HEADERS plus DATA cannot share the 1,100-byte aggregate falls back to
  individual packets. The validated 1,024-byte case measured 28.409k requests/s.
  General packet segmentation/coalescing across larger responses is the next
  material protocol-path opportunity; it must preserve congestion, recovery,
  final-size, and retransmission accounting.
- The post-batching profile is led by bounded record copies and packet I/O once
  waits are excluded. Transactional flow state and the prepared response each
  have fixed-size copies. Controlled no-copy/direct-slot variants were neutral
  or slower, so further work needs a different representation with evidence,
  not removal of transaction semantics.
- Flyology now exposes portable `SO_REUSEPORT`, but this server still uses one
  UDP listener with multiple Flyology loops. Naively giving each loop a reused
  QUIC socket would allow the kernel to route later packets for one connection
  to a different owner. Listener sharding therefore needs a connection-ID-aware
  dispatch design and its own interop tests; the benchmark does not justify
  weakening connection ownership.
- Investigate delayed retirement of old H3 connection generations and long-run
  throughput decay with a lifecycle-focused diagnostic build. The final
  eight-connection topology avoids making that pressure part of the throughput
  number but does not erase the earlier observation.
- Isolate client and server on separate machines before interpreting remaining
  CPU headroom. In co-located runs the Python oracle consumed several cores;
  the `asyncio.timeout` change proved that oracle overhead can materially cap
  the apparent server result.
- The post-wake-source H2 profile is led by TLS/socket calls,
  scheduler/task-local lookup, byte comparison, and remaining bounded header
  construction. One loop reached a 44.8k median and 16 loops a 147.4k median
  with four connections x 16 streams. At the same total concurrency, both
  fewer and additional connections regress, locating the next scaling work in
  per-connection serialization versus TLS/socket/scheduler overhead rather
  than another indiscriminate concurrency increase.
- Repeat on a quiescent, thermally controlled machine and on Linux before
  making cross-platform claims.
