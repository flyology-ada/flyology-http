#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
corpus=${1:-${ADA_URL_DATASET:-}}
ada_root=${ADA_URL_ROOT:-}
rounds=${BENCHMARK_ROUNDS:-5}
cxx=${CXX:-c++}

if [ -z "$corpus" ] || [ ! -f "$corpus" ]; then
  printf '%s\n' \
    "pass ada-url/url-dataset/out.txt or set ADA_URL_DATASET" >&2
  exit 2
fi
if [ -z "$ada_root" ] || [ ! -f "$ada_root/include/ada.h" ]; then
  printf '%s\n' "set ADA_URL_ROOT to an ada-url/ada checkout" >&2
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

printf '# ada_url_revision=%s\n' "$(git -C "$ada_root" rev-parse HEAD)"
printf '# corpus_revision=%s\n' \
  "$(git -C "$(dirname "$corpus")" rev-parse HEAD 2>/dev/null || printf unknown)"
printf '%s\n' "implementation,operation,corpus_urls,accepted,ns_per_url"
"$crate_root/benchmarks/bin/flyology_iri_benchmark" "$corpus" "$rounds"
"$crate_root/benchmarks/bin/ada_url_benchmark" "$corpus" "$rounds"
