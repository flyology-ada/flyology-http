#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
repository_root=$(CDPATH= cd -- "$crate_root/.." && pwd)
benchmark_root=${FLYOLOGY_IRI_BENCHMARK_ROOT:-$repository_root/build/flyology-iri-benchmark}
ada_root=${ADA_URL_ROOT:-$benchmark_root/ada-url}
corpus=${1:-${ADA_URL_DATASET:-$ada_root/url-dataset/out.txt}}
rounds=${BENCHMARK_ROUNDS:-5}
cxx=${CXX:-c++}
ada_revision=32dabc8d39a919633f31f692c358012b2105fd61
dataset_revision=ef7065196980ab7956bacc60b4bda663939f659c

if [ ! -f "$corpus" ] || [ ! -f "$ada_root/include/ada.h" ]; then
  printf '%s\n' \
    "benchmark inputs are missing; run $crate_root/scripts/prepare-benchmark.sh" >&2
  exit 2
fi

actual_ada_revision=$(git -C "$ada_root" rev-parse HEAD 2>/dev/null || true)
if [ "$actual_ada_revision" != "$ada_revision" ]; then
  printf '%s\n' \
    "Ada URL is at ${actual_ada_revision:-unknown}; expected $ada_revision" >&2
  exit 2
fi
dataset_root=$(dirname -- "$corpus")
actual_dataset_revision=$(git -C "$dataset_root" rev-parse HEAD 2>/dev/null || true)
if [ "$actual_dataset_revision" != "$dataset_revision" ]; then
  printf '%s\n' \
    "URL dataset is at ${actual_dataset_revision:-unknown}; expected $dataset_revision" >&2
  exit 2
fi

cd "$crate_root/benchmarks"
FLYOLOGY_IRI_BUILD_MODE=release
export FLYOLOGY_IRI_BUILD_MODE
alr build

singleheader=$ada_root/singleheader
if [ ! -f "$singleheader/ada.cpp" ]; then
  (cd "$ada_root" && python3 singleheader/amalgamate.py)
fi

"$cxx" -std=c++20 -O3 -DNDEBUG \
  -I"$singleheader" \
  "$crate_root/benchmarks/ada_url_benchmark.cpp" \
  "$singleheader/ada.cpp" \
  -o "$crate_root/benchmarks/bin/ada_url_benchmark"

printf '# ada_url_revision=%s\n' "$actual_ada_revision"
printf '# corpus_revision=%s\n' "$actual_dataset_revision"
printf '%s\n' "implementation,operation,corpus_urls,accepted,ns_per_url"
"$crate_root/benchmarks/bin/flyology_iri_benchmark" "$corpus" "$rounds"
"$crate_root/benchmarks/bin/ada_url_benchmark" "$corpus" "$rounds"
