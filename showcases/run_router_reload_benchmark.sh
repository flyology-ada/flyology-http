#!/bin/sh
# Runs the router reload benchmark across a sweep of reload rates.
#
# Wall-clock varies more between processes than between inner repetitions,
# because code layout changes per link and the scheduler places tasks
# differently. Each rate is therefore measured as several independent
# process runs and reported by its best result, which is the most stable
# statistic for ranking two builds of the same benchmark.
set -eu

#  The test suite builds Flyology with the TLS test hooks; a showcase link
#  needs them off, and a stale setting silently measures the wrong build.
unset FLYOLOGY_TLS_TEST_HOOKS || :

showcase_root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$showcase_root/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

workers=${WORKERS:-4}
seconds=${SECONDS_PER_RUN:-2}
trials=${TRIALS:-5}
rates=${RATES:-"0 10 100 1000 5000"}
label=${LABEL:-run}

cd "$project_root"
"$alr" build --release >/dev/null
"$showcase_root/prepare-alire.sh" release >/dev/null
#  The runtime is prepared by the test suite, which is the canonical
#  bootstrap for it. Reuse that instead of preparing a second one, so both
#  builds under comparison link the same runtime.
if [ ! -d "$project_root/build/rts/adalib" ]; then
  printf '%s\n' "runtime not prepared; run ./scripts/test.sh once first" >&2
  exit 1
fi

cd "$showcase_root"
FLYOLOGY_SHOWCASE_PROFILE=release "$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$project_root/build/rts" \
  -f \
  -P showcases.gpr \
  http_router_reload_benchmark.adb >/dev/null

printf '%s\n' "label=$label workers=$workers seconds=$seconds trials=$trials"
printf '%s\n' "reloads_per_second best median worst spread_percent failures"

for rate in $rates; do
  samples=$(mktemp)
  failures=0
  i=0
  while [ "$i" -lt "$trials" ]; do
    i=$((i + 1))
    out=$("$showcase_root/bin/http_router_reload_benchmark" \
      --workers "$workers" \
      --seconds "$seconds" \
      --reloads-per-second "$rate")
    value=$(printf '%s\n' "$out" | sed -n 's/.*dispatches_per_second= *//p')
    printf '%s\n' "${value%%.*}" >>"$samples"
    run_failures=$(printf '%s\n' "$out" \
      | sed -n 's/.*failures= *\([0-9]*\).*/\1/p')
    failures=$((failures + run_failures))
  done
  sorted=$(sort -n "$samples")
  worst=$(printf '%s\n' "$sorted" | head -1)
  best=$(printf '%s\n' "$sorted" | tail -1)
  median=$(printf '%s\n' "$sorted" | sed -n "$(((trials + 1) / 2))p")
  spread=$(( (best - worst) * 100 / worst ))
  rm -f "$samples"
  printf '%s %s %s %s %s %s\n' \
    "$rate" "$best" "$median" "$worst" "$spread" "$failures"
done
