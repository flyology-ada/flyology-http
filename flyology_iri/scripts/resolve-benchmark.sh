#!/bin/sh
set -eu

# Times the component-getter and Resolve paths with flyology_bench. Unlike
# benchmark.sh this harness carries its own inputs, so it needs neither the
# Ada URL checkout nor the pinned corpus.
#
# The build mode is passed to the binary as well as to the compiler because it
# is part of the baseline compatibility fingerprint: the release profile
# suppresses runtime checks in flyology_iri.adb, which is most of what these
# workloads execute, so a checked baseline must not be compared with a release
# run. FLYOLOGY_IRI_BUILD_MODE defaults to release here, matching the mode the
# published medians in BENCHMARKS.md measure.

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build_mode=${FLYOLOGY_IRI_BUILD_MODE:-release}

cd "$crate_root/benchmarks"
FLYOLOGY_IRI_BUILD_MODE=$build_mode
export FLYOLOGY_IRI_BUILD_MODE
alr build >&2

exec "$crate_root/benchmarks/bin/flyology_iri_resolve_benchmark" \
  "--build-mode=$build_mode" "$@"
