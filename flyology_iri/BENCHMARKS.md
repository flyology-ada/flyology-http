# URL corpus benchmark

The benchmark uses the exact corpus loaded by Ada v4's `benchdata` target:
`ada-url/url-dataset/out.txt`. The harness omits its empty lines, leaving
100,025 URL strings in the pinned corpus.

Pinned inputs:

- Ada URL 4.0.0: `32dabc8d39a919633f31f692c358012b2105fd61`
- URL dataset: `ef7065196980ab7956bacc60b4bda663939f659c`

The local harness times whole-corpus loops with a monotonic clock. `can_parse`
constructs nothing. `parse_href` builds the compact representation and consumes
the stored serialization length, matching Ada's `url_aggregator` benchmark
shape. Both binaries use `-O3` release optimization and process identical
strings in the same order.

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
