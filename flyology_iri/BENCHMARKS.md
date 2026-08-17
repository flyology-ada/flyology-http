# Benchmarks

Two harnesses. The URL corpus benchmark below times validation and
construction against Ada URL over a pinned third-party corpus. The resolution
benchmark further down times the paths that read components back out of an
already parsed reference, which the corpus benchmark does not reach.

# URL corpus benchmark

The benchmark uses the exact corpus loaded by Ada v4's `benchdata` target:
`ada-url/url-dataset/out.txt`. The harness omits its empty lines, leaving
100,025 URL strings in the pinned corpus.

Pinned inputs:

- Ada URL 4.0.0: `32dabc8d39a919633f31f692c358012b2105fd61`
- URL dataset: `ef7065196980ab7956bacc60b4bda663939f659c`

Prepare and run those inputs from the `flyology_iri` directory:

```sh
./scripts/prepare-benchmark.sh
./scripts/benchmark.sh
```

The preparation script creates
`../build/flyology-iri-benchmark/ada-url/url-dataset/out.txt`, preserving the
path expected by Ada's benchmark while keeping third-party benchmark data in
the repository's ignored build directory. These inputs are script-managed
rather than Git submodules because neither checkout is needed to build, test,
or use the crate. `FLYOLOGY_IRI_BENCHMARK_ROOT` can select another managed
directory. `ADA_URL_ROOT` and `ADA_URL_DATASET` remain available for existing
checkouts, but `benchmark.sh` verifies that both are at the revisions above.

The local harness times whole-corpus loops with a monotonic clock. `can_parse`
constructs nothing. `parse_href` builds the compact representation and consumes
the stored serialization length, matching Ada's `url_aggregator` benchmark
shape. Both binaries use `-O3` release optimization and process identical
strings in the same order.

`scripts/benchmark.sh` selects `FLYOLOGY_IRI_BUILD_MODE=release`, which adds
`-gnatp` to one body, `flyology_iri.adb`. That is what the numbers below cost:
with its checks left on, the same corpus measures 26 ns `can_parse` and 165 ns
`parse_href`. The WHATWG serialization and IDNA bodies and the harness itself
keep every runtime check in both modes, because suppressing theirs moved
neither median. `proof/proof-status.md` records the obligation that suppression
leaves undischarged.

Both implementations accept exactly 99,999 of 100,025 inputs. Flyology's URL
parser also matches all 919 href, failure, and component expectations in Ada
4.0.0's pinned WPT parsing data.

Measurements from 2026-08-06 on an Apple M3 Max, macOS 26.5.2, GNAT 16.1.0,
and Apple clang 21.0.0 follow. Each row is the median of five independent runs;
each run parses the complete corpus ten times.

| Implementation | Operation | Accepted | Median ns/URL | Five runs |
| --- | --- | ---: | ---: | --- |
| `flyology_iri` | `can_parse` | 99,999 | 20 | 20, 19, 20, 20, 20 |
| Ada URL 4.0.0 | `can_parse` | 99,999 | 19 | 19, 19, 19, 21, 19 |
| `flyology_iri` | `parse_href` | 99,999 | 103 | 102, 104, 103, 103, 107 |
| Ada URL 4.0.0 | `parse_href` | 99,999 | 104 | 105, 103, 104, 102, 104 |

These are local development-machine observations, not portable performance
claims. At this workload and resolution, validation is within one nanosecond of
Ada's median and construction is within one nanosecond while slightly faster at
the median.

# Resolution and component benchmark

`can_parse` constructs nothing and `parse_href` consumes only the stored
serialization length, so neither reaches a component getter. The paths that
read components back out of a parsed reference are timed separately, by
`flyology_iri_resolve_benchmark`, which is built on
[`flyology_bench`](https://flyology.org/guide/benchmarking/). It carries its
own inputs, so unlike `benchmark.sh` it needs neither the Ada URL checkout nor
the pinned corpus:

```sh
./scripts/resolve-benchmark.sh
```

Six workloads. `components_short`, `components_long`, and `components_huge`
each read all eight components of a parsed reference, cycling four references
whose serialized lengths average 44, 235, and 2,009 bytes; the three sizes are
what make a getter whose cost follows the reference distinguishable from one
whose cost follows the component. `resolve_short_base` and `resolve_long_base`
resolve the RFC 3986 section 5.4 relative references, plus the shapes a
document with a base-URI directive carries, against an 18-byte and a 233-byte
base. `resolve_long_base_string` repeats the last of those through the
serialization-returning form.

Batches fold a value derived from each result into an accumulator that
`Measure_Result_Batched` hands to a barrier after the ending timestamp, and
each iteration advances to a different input. The fold reads one byte of each
component as well as its length. That guard is precautionary: disassembling the
harness shows all eight getter calls emitted either way, because the library is
a separate project whose bodies `-gnatn2` does not inline into the harness, so
`-O3` has no opportunity to satisfy a length-only consumer without producing
the bytes.

`scripts/resolve-benchmark.sh` selects `FLYOLOGY_IRI_BUILD_MODE=release`, the
mode the corpus medians above also measure, and passes it to the binary.
The build mode is part of the baseline compatibility fingerprint, because
release suppresses runtime checks in `flyology_iri.adb` and that body is most
of what these workloads execute.

Two builds of one library cannot share a process, so a before/after pair joins
through `Flyology_Bench.Baselines` rather than a paired `Compare`. Its
fingerprint refuses a comparison across operating system, architecture,
compiler, or build mode, and deliberately does not include the library
revision, which is the difference being measured.

## Metric axes

The run requests `Process_Resource_Metrics`, the portable Darwin/Linux set.
`Linux_Hardware_Metrics` would give a lower-noise instruction count, but its
axes come from perf and report `Unsupported_Platform` on Darwin. The metrics
CSV records the collection status of every requested axis rather than leaving
it assumed; `--metrics-csv=PATH` sends it to a file.

`Process_RSS_Change` measures retained resident growth per operation and reads
zero for these workloads both before and after any change to transient copying,
because the allocator reuses memory freed within the same batch. It is the
wrong instrument for a change to short-lived copies, and a flat reading on it
is not evidence that nothing moved. `Wall_Time` is the axis that responds, with
`Thread_CPU_Time` alongside it to show that a wall-time difference is not a
scheduling artifact.

## Component-copy measurement

Measurements from 2026-08-17 on an Apple M3 Max, macOS 26.5.2, GNAT 16.1.0,
release build mode. Every one of the thirteen requested axes reported
`collected` in every run. The host was not idle: an unrelated compiler
bootstrap held the load average near 25 throughout, so the rounds were
interleaved before/after/before/after and the repeated pre-change round serves
as a drift control.

Medians in ns/op, and the `Baselines` verdict against the first pre-change
round:

| Workload | Before | After | Change | 95% speedup CI |
| --- | ---: | ---: | ---: | --- |
| `components_short` | 127.6 | 74.2 | −41.9% | 1.712 .. 1.731 |
| `components_long` | 124.6 | 82.2 | −33.5% | 1.491 .. 1.518 |
| `components_huge` | 320.2 | 115.8 | −63.8% | 2.749 .. 2.782 |
| `resolve_short_base` | 608.8 | 475.8 | −22.2% | 1.276 .. 1.297 |
| `resolve_long_base` | 980.8 | 823.2 | −15.5% | 1.154 .. 1.210 |

Replacing the assembly's `Unbounded_String` with a plain buffer, below, takes
the two resolution rows further, to 331.0 and 550.4 ns.

The drift control repeated the pre-change build after the post-change one and
landed within 3% of its own first round on every workload, against effects of
15% to 64%. `Thread_CPU_Time` stayed within 1.2% of wall time in every run, so
the wall-time differences are not descheduling.
`Process_RSS_Change` and both page-fault axes read zero on both sides.

`components_huge` is the reading that identifies the cause. Before the change
its median is 2.6 times `components_long`'s at 8.6 times the reference length;
after it, 1.4 times. What remains scales with the components rather than with
the reference.

These are local development-machine observations on a loaded host, not portable
performance claims.

## What the compiler actually emits

Timings alone cannot say which copy disappeared, so the release objects were
disassembled on both sides. Before, `flyology_iri__scheme` called
`ada__strings__unbounded__to_string` unconditionally and *ahead of the
zero-span test*, then took a second `ss_allocate` and `memcpy` for the
component itself: two copies per getter, one of them the length of the whole
reference, paid even when the component was absent. After, the same symbol is a
tail call to `ada__strings__unbounded__slice` on the present path, and the
absent path allocates the eight bytes of a null string's bounds and returns
without copying anything.

That also explains the shape of the numbers. At 44 and 235 bytes the win is
mostly one fewer call and one fewer secondary-stack allocation per getter,
which is why `components_short` improves as much as `components_long` despite
copying a fifth as many bytes. At 2,009 bytes the discarded copy dominates and
the improvement grows to 63.8%.

## The two Resolve forms

`Resolve` has a serialization-returning form that validates with `Diagnose`
instead of building a second `Reference`. Both forms are in one process, so
these are paired `Compare`s rather than baseline joins, and their answers do
not depend on host load the way an independent run does.

The validation step alone, over the assembled resolution results: `Diagnose`
213.9 ns/op against `Parse`'s 276.9 ns/op, 22.8% less, 95% CI [1.288, 1.303],
winning 100 of 100 sample pairs.

End to end against a 233-byte base:

| Form | Median | Change | 95% CI | Pairs won |
| --- | ---: | ---: | --- | ---: |
| `Resolve` returning `Reference` | 536.2 | reference | -- | -- |
| `Resolve` returning `String` | 461.2 | −13.87% | 1.156 .. 1.166 | 100/100 |

Order effect −0.48%. Process and thread CPU time both fall 14.0%, and
`Process_RSS_Change` and the page-fault axes read zero on both sides.

The saving is larger than the validation difference implies, because the
serialization form also skips constructing and finalizing the result
`Reference` — a controlled `Unbounded_String` plus eight spans — not only the
parse that fills it.

The two forms assemble through one private helper rather than one calling the
other. Composing them the obvious way, with the `Reference` form parsing the
`String` form's result, would make it validate twice and cost it about 214 ns
it does not pay today. Its median tracks the standalone `resolve_long_base`
row above, which is what confirms that.

## Where the assembly's cost was

The assembly writes into a plain `String` sized from the two parsed references,
not into a growing `Unbounded_String`. That is worth more than the returned
copy it also avoids, and it reaches both public forms:

| Form | `Unbounded` assembly | Buffer assembly | Change |
| --- | ---: | ---: | ---: |
| `Resolve` returning `Reference` | 823.2 | 550.4 | −33% |
| `Resolve` returning `String` | 743.4 | 466.5 | −37% |

Most of that is not the result copy. The old shape reallocated on nearly every
append, and its segment removal ran a whole `To_String` and
`Set_Unbounded_String` for each `/../` it collapsed.

A `procedure` form writing into a caller-supplied buffer was prototyped against
this and measured 4.7% below the serialization form, winning 69 of 100 pairs.
That difference is the returned copy alone, which is all the wider API buys
once the assembly no longer allocates. It was not adopted.
