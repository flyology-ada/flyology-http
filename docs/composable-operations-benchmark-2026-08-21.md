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

Candidate measurements will be added after the composable HTTP operations and
synchronous wrappers pass the required regressions.
