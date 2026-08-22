# Composable operations HTTP benchmark

This report records the local HTTP/1.1 server baseline and candidate campaign
for the Flyology composable-operations consumer validation. Results describe
this host and workload only. They are not portable capacity claims.

## Environment and method

- Host: Apple arm64, macOS 26.5.2 (Darwin 25.5.0), 16 logical CPUs.
- Tools: GNAT 16.1.0, Alire 2.1.1, and oha 1.7.0.
- HTTP baseline: `fc54793` from `flyology-http` `main`.
- Flyology baseline: indexed `0.1.0` at
  `8e0461080e0f110b3bf70dbff283af9ca5e53a2c`.
- Profile: release.
- Client load: 100,000 measured requests at concurrency 128 for each case.
- Warm-up: 10,000 requests at concurrency 128 before each case.
- Server capacity: 128 handlers.
- Lightweight runtime: 16 event-loop pthreads, verified by
  `http_benchmark_runtime_probe`.
- Native runtime: 128 handler pthreads on 16 logical CPUs.
- Trials: three per lane, alternating lightweight/native lane order.
- Cooldown: 20 seconds between lanes.
- Upload payload: 32,768 bytes.

The maintained command shape was:

```sh
./showcases/run_http_benchmark.sh \
  100000 128 128 18080 16 3 10000 release 20 128
```

The indexed Flyology source contains Alire index metadata in its fetched
`alire.toml`. Alire 2.1.1 rejects the `[origin]` table when the benchmark
runner invokes that dependency's runtime preparation as a nested workspace.
The baseline therefore used a fresh temporary GitHub checkout of the exact
indexed commit, not another task's checkout:

```sh
git clone --no-checkout https://github.com/flyology-ada/flyology.git \
  /tmp/flyology-http-baseline.XXXXXX/flyology
git -C /tmp/flyology-http-baseline.XXXXXX/flyology \
  checkout 8e0461080e0f110b3bf70dbff283af9ca5e53a2c
env FLYOLOGY_DEFAULT=lightweight FLYOLOGY_LOOP_POOL_SIZE=16 \
  FLYOLOGY_RTS_DIR="$PWD/build/rts" \
  /tmp/flyology-http-baseline.XXXXXX/flyology/scripts/prepare-rts.sh
```

The release benchmark programs were linked in the isolated
`baseline-c128-l16` GPR subdirectory to prevent earlier one-loop ALI files from
entering the binary. The probe reported 16 before measurement. The runner's
build and probe lines were then skipped, while its server lifecycle, warm-ups,
workloads, alternating trial order, oha commands, and cooldowns ran unchanged.

The runner does not sample process CPU time or resident memory. The relevant
resource controls retained here are logical CPU count, event-loop count,
handler pthread count, handler capacity, request concurrency, and upload size.

## Unmodified qualification baseline

`./scripts/test.sh` built the root `flyology_http` crate and passed the
`flyology_iri` tests. It then failed before the HTTP behavioral programs while
linking the nested `flyology_quic` suite. That nested Alire workspace selected
Flyology `0.1.1-dev` while the root selected `0.1.0`; the resulting library
mix reported unresolved `Flyology.IO`, socket, and buffer symbols. This is a
pre-existing project-boundary failure, recorded separately from candidate
results.

## Baseline throughput

Each cell lists the three requests/second samples in execution order. Median,
minimum, and maximum are rounded to the nearest request/second.

| Lane | Workload | Samples (requests/s) | Median | Min | Max |
| --- | --- | --- | ---: | ---: | ---: |
| Lightweight | Routed GET | 85,178.84 / 92,630.91 / 94,270.48 | 92,631 | 85,179 | 94,270 |
| Lightweight | Middleware | 64,000.41 / 78,753.83 / 73,921.23 | 73,921 | 64,000 | 78,754 |
| Lightweight | Buffered POST | 76,908.87 / 77,708.83 / 86,662.76 | 77,709 | 76,909 | 86,663 |
| Lightweight | Streamed upload | 32,978.66 / 36,177.21 / 32,796.13 | 32,979 | 32,796 | 36,177 |
| Lightweight | Admission | 89,607.88 / 93,655.38 / 90,836.23 | 90,836 | 89,608 | 93,655 |
| Native | Routed GET | 61,625.88 / 58,684.52 / 63,278.30 | 61,626 | 58,685 | 63,278 |
| Native | Middleware | 51,528.39 / 51,475.97 / 51,456.72 | 51,476 | 51,457 | 51,528 |
| Native | Buffered POST | 48,890.34 / 57,600.64 / 62,034.34 | 57,601 | 48,890 | 62,034 |
| Native | Streamed upload | 25,560.93 / 31,185.01 / 31,379.72 | 31,185 | 25,561 | 31,380 |
| Native | Admission | 59,558.56 / 62,418.58 / 67,796.42 | 62,419 | 59,559 | 67,796 |

All 3,000,000 measured baseline responses were status 200. No timeout or
non-success response entered the table.

## Baseline latency

The table reports the median of the three trial values in milliseconds.
Average is oha's mean response time; p50, p90, and p99 are distribution
percentiles.

| Lane | Workload | Average (ms) | p50 (ms) | p90 (ms) | p99 (ms) |
| --- | --- | ---: | ---: | ---: | ---: |
| Lightweight | Routed GET | 1.4 | 0.5 | 3.4 | 14.9 |
| Lightweight | Middleware | 1.7 | 0.5 | 4.4 | 17.1 |
| Lightweight | Buffered POST | 1.6 | 0.5 | 3.8 | 15.8 |
| Lightweight | Streamed upload | 3.9 | 2.4 | 7.6 | 27.4 |
| Lightweight | Admission | 1.4 | 0.6 | 3.3 | 10.4 |
| Native | Routed GET | 2.1 | 0.2 | 3.6 | 36.8 |
| Native | Middleware | 2.5 | 0.3 | 2.8 | 57.2 |
| Native | Buffered POST | 2.2 | 0.3 | 2.6 | 41.2 |
| Native | Streamed upload | 4.1 | 0.4 | 4.6 | 99.2 |
| Native | Admission | 2.0 | 0.2 | 2.1 | 40.4 |

The three-sample ranges show material run-to-run noise, especially for native
buffered and upload throughput. The post-change campaign must use this exact
protocol and should treat a shift outside these adjacent ranges as a signal to
diagnose, not as proof by itself.

## Candidate results

The candidate production sources were committed as `8e1b04a`. The release
binary used the same production tree; the only later change before that commit
was a test-only update that composed the TLS upgrade and HTTP request-head
operations through one completion set. Flyology was pinned at
`1810fc60ba41bd9029a7d1c96c0e326af1ad415a` from
`codex/composable-operations`.

Alire commands used the configured settings directory through an `ALR`
wrapper equivalent to:

```sh
exec /usr/local/bin/alr -s "$HOME/.config/alire" "$@"
```

The candidate qualification commands were:

```sh
env ALR=/tmp/codex-flyology-http-alr ./scripts/test.sh
env ALR=/tmp/codex-flyology-http-alr ./scripts/docs.sh
env ALR=/tmp/codex-flyology-http-alr \
  ./showcases/run_http_benchmark.sh \
  100000 128 128 18080 16 3 10000 release 20 128
```

The authoritative suite passed all 61 HTTP behavioral programs, the three
connection-hook programs, the Flyology QUIC suite, and the `flyology_iri`
tests. This includes the native and lightweight operation regressions, plain
and upgraded-TLS paths, retained failures, cancellation, abandoned-scope
cleanup, counted waits, gates, timers, partial I/O, multiple operations, and
synchronous parity. The GNATdoc pipeline generated the searchable HTTP, QUIC,
and IRI API references without an error.

### Candidate throughput

Each cell lists the three requests/second samples in execution order. Median,
minimum, and maximum are rounded to the nearest request/second.

| Lane | Workload | Samples (requests/s) | Median | Min | Max |
| --- | --- | --- | ---: | ---: | ---: |
| Lightweight | Routed GET | 92,752.38 / 85,670.43 / 97,650.98 | 92,752 | 85,670 | 97,651 |
| Lightweight | Middleware | 71,304.32 / 78,777.34 / 67,044.85 | 71,304 | 67,045 | 78,777 |
| Lightweight | Buffered POST | 87,524.40 / 77,460.61 / 47,750.93 | 77,461 | 47,751 | 87,524 |
| Lightweight | Streamed upload | 31,955.60 / 38,555.01 / 19,218.97 | 31,956 | 19,219 | 38,555 |
| Lightweight | Admission | 78,674.06 / 90,143.72 / 85,575.74 | 85,576 | 78,674 | 90,144 |
| Native | Routed GET | 70,528.67 / 60,215.66 / 53,832.90 | 60,216 | 53,833 | 70,529 |
| Native | Middleware | 55,456.11 / 56,430.35 / 50,588.30 | 55,456 | 50,588 | 56,430 |
| Native | Buffered POST | 55,523.98 / 57,128.44 / 54,738.88 | 55,524 | 54,739 | 57,128 |
| Native | Streamed upload | 28,622.93 / 30,554.92 / 29,382.51 | 29,383 | 28,623 | 30,555 |
| Native | Admission | 69,520.97 / 59,040.70 / 56,819.31 | 59,041 | 56,819 | 69,521 |

All 3,000,000 measured candidate responses were status 200. No timeout or
non-success response entered the table.

### Candidate latency

The table reports the median of the three candidate trial values in
milliseconds.

| Lane | Workload | Average (ms) | p50 (ms) | p90 (ms) | p99 (ms) |
| --- | --- | ---: | ---: | ---: | ---: |
| Lightweight | Routed GET | 1.4 | 0.3 | 3.0 | 17.8 |
| Lightweight | Middleware | 1.8 | 0.8 | 3.8 | 18.0 |
| Lightweight | Buffered POST | 1.6 | 0.4 | 4.3 | 18.6 |
| Lightweight | Streamed upload | 4.0 | 1.3 | 9.5 | 41.0 |
| Lightweight | Admission | 1.5 | 0.6 | 3.6 | 12.4 |
| Native | Routed GET | 2.1 | 0.2 | 2.5 | 46.5 |
| Native | Middleware | 2.3 | 0.2 | 1.9 | 52.0 |
| Native | Buffered POST | 2.3 | 0.2 | 1.9 | 51.6 |
| Native | Streamed upload | 4.3 | 0.5 | 5.6 | 94.5 |
| Native | Admission | 2.2 | 0.2 | 1.8 | 45.5 |

### Baseline comparison

| Lane | Workload | Baseline median | Candidate median | Change |
| --- | --- | ---: | ---: | ---: |
| Lightweight | Routed GET | 92,631 | 92,752 | +0.13% |
| Lightweight | Middleware | 73,921 | 71,304 | -3.54% |
| Lightweight | Buffered POST | 77,709 | 77,461 | -0.32% |
| Lightweight | Streamed upload | 32,979 | 31,956 | -3.10% |
| Lightweight | Admission | 90,836 | 85,576 | -5.79% |
| Native | Routed GET | 61,626 | 60,216 | -2.29% |
| Native | Middleware | 51,476 | 55,456 | +7.73% |
| Native | Buffered POST | 57,601 | 55,524 | -3.61% |
| Native | Streamed upload | 31,185 | 29,383 | -5.78% |
| Native | Admission | 62,419 | 59,041 | -5.41% |

The median shifts do not show a broad regression. Eight workload medians move
by less than 6%, routed GET is unchanged, and native middleware improves by
7.7%. Most candidate medians remain inside the corresponding baseline
three-sample range. Lightweight admission is 4.5% below the baseline minimum,
native admission is 0.9% below it, and lightweight upload is 2.6% below it.
The low lightweight buffered and upload samples occurred together in trial
three while routed GET improved, which is inconsistent with a common HTTP
parser cost. Native trials also slowed over campaign order while middleware
remained above baseline. These patterns indicate host or thermal noise rather
than an operation-specific steady-state cost, but the report retains the
outliers instead of discarding them.

The benchmark exercises the preserved synchronous server path. The additive
scoped operations therefore add no per-request allocation or dispatch to this
steady-state workload. The only shared synchronous changes are bounded parser
transition helpers and unconditional initialization of the peer-closure
status. A final campaign must repeat after the Flyology PR pin advances; this
current comparison is evidence for `1810fc6`, not for the eventual PR head.
