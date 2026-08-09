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
The final row is the last clean 16-loop post-change run after qualification.
Latency values are milliseconds. All requests succeeded.

| Configuration | Requests/s | p50 | p95 | p99 | Concurrency and reuse |
| --- | ---: | ---: | ---: | ---: | --- |
| H1, 1 loop, baseline | 34,784 | 0.431 | 0.540 | 0.737 | 16 connections, keep-alive |
| H2, 1 loop, baseline | 19,783 | 3.17 | 4.09 | 4.54 | 4 connections x 16 streams |
| H3, 1 Python worker, baseline | 13,768 | 10.320 | 18.111 | 19.454 | 16 connections x 16 streams |
| H3, 1 server loop saturated, baseline | 25,725 | 36.64 | — | — | 4 workers, 64 connections x 16 streams |
| H3, 1 server loop, ACK candidate | 26,827 | 35.25 | — | — | same; +4.3% rate, -3.8% p50 |
| H3, 1 loop, pre-QPACK median | 27,310 | 32.8 | — | — | 4 workers, 64 connections x 16 streams |
| H3, 1 loop, QPACK median | **30,097** | 29.6 | — | — | same; +10.2% rate, about -10% p50 |
| H1, 16 loops, baseline median | 98,299 | 0.459 | 1.700 | 3.285 | 64 connections |
| H2, 16 loops, baseline median | 32,035 | 1.946 | 2.552 | 2.795 | 4 connections x 16 streams |
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

1. **Packet output and descriptor/source-address work dominate the H3
   server.** In the active 16-loop server sample the leading stacks included
   `sendmsg` (56,142 samples), `kevent` (7,759), `memmove` (4,822), `fcntl`
   (3,052), `memset` (1,684), `setsockopt` (1,364), scheduler current-fiber
   work (850), `recvmsg` (715), and `getsockname` (681). QPACK field-name work
   was only 533 samples and crypto was sparse. Routing and response construction
   did not dominate. Flyology's native `flyology_socket_send_datagram` calls
   `getsockname` for every source-selected datagram and emits one `sendmsg` per
   call. Caching verified local endpoint data and packet batching are plausible
   upstream work. This crate was not changed to work around Flyology core.

2. **QPACK response encoding repeatedly constructed static-table names.** At
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

3. **ACK processing copied large retransmission tables per packet.** The
   application-space packet transaction copied a roughly 72 KiB
   retransmittable table plus packet-frame table before applying ACK events.
   The accepted change stages only the bounded packet-event resolution log,
   applies it after all fallible frame processing succeeds, then commits the
   smaller sent/recovery candidates. Controlled one-loop median rate improved
   25,725 to 26,827 requests/s (+4.3%); 16-loop results were neutral within
   noise, so no multi-loop gain is attributed to this change.

4. **The Ada H3 client allocated a large event object twice per request.** A
   pooled connection now retains one event object and frees it with the
   transport. In a 640,000-request, 64-connection optimized Ada-client run,
   rate improved from 31,543 to 35,284 requests/s (+11.9%) and mean latency
   from 1.990 to 1.790 ms (-10.1%). Pool diagnostics were 64 created, 639,936
   reused, 64 idle, zero closed. Before, `madvise` appeared 2,944 times and the
   body reader's allocation path was hot; afterward `madvise` disappeared from
   the leading sample and `memset` samples fell from 5,577 to 2,276. Sample
   totals differed, so counts support the allocation mechanism rather than an
   exact percentage claim.

5. **Eager per-connection request header slots inflated server memory.** Eight
   bounded slots embedded full header blocks even when unused. Header blocks
   are now allocated on first slot use, retained for the connection, and freed
   during cleanup. At 64 H3 connections peak physical memory fell from 309.9
   to 250.1 MB (about 19%); at 128 connections RSS fell from about 632 to 495
   MB (about 22%). Throughput remained in the 50k+ band. This is a capacity
   improvement, not a claimed request-rate win.

6. **Single-process aioquic is an oracle bottleneck.** One worker stayed near
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
  fault campaign and bounded soak passed; h2spec 146/146 passed.
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
- Repeat on a quiescent, thermally controlled machine and on Linux before
  making cross-platform claims.
