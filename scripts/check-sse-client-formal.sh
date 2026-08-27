#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
: "${FLYOLOGY_TLA_JAVA:?evaluate 'flyology-tla toolchain env' first}"
: "${FLYOLOGY_TLA_TLC_JAR:?evaluate 'flyology-tla toolchain env' first}"
: "${FLYOLOGY_TLAPM:?evaluate 'flyology-tla toolchain env' first}"

tla_cli=${FLYOLOGY_TLA_CLI:-}
if [ -z "$tla_cli" ]; then
  tla_cli=$(command -v flyology-tla || :)
fi
if [ -z "$tla_cli" ] || [ ! -x "$tla_cli" ]; then
  printf '%s\n' \
    'set FLYOLOGY_TLA_CLI to the installed flyology-tla executable' >&2
  exit 1
fi

alr=$($http_root/scripts/find-alr.sh)
model_root=$http_root/formal/sse_client/model
ada_root=$http_root/formal/sse_client/ada
trace=$http_root/formal/sse_client/traces/sse-client.trace.json
temporary_base=${TMPDIR:-/tmp}
temporary_base=${temporary_base%/}
temporary_root=$(mktemp -d "$temporary_base/flyology-http-sse-formal.XXXXXX")
trap 'rm -rf "$temporary_root"' EXIT HUP INT TERM

run_tlc () {
  configuration=$1
  module=$2
  state_dir=$3
  shift 3
  "$FLYOLOGY_TLA_JAVA" -Xmx1g -XX:+UseParallelGC \
    -cp "$FLYOLOGY_TLA_TLC_JAR" tlc2.TLC \
    -workers 1 -coverage 1 -noGenerateSpecTE \
    -metadir "$state_dir" -config "$configuration" "$@" "$module"
}

cd "$model_root"
run_tlc SSEClient.cfg SSEClient "$temporary_root/main-states" \
  >"$temporary_root/main.log" 2>&1
grep -q 'No error has been found.' "$temporary_root/main.log"
grep -Eq '[1-9][0-9]* distinct states found' "$temporary_root/main.log"
grep -Eq '^<ReconnectWaitElapsed .*: [1-9]' "$temporary_root/main.log"
grep -Eq '^<DispatchEvent .*: [1-9]' "$temporary_root/main.log"

set +e
run_tlc SSEClientNegative.cfg SSEClient "$temporary_root/negative-states" \
  >"$temporary_root/negative.log" 2>&1
negative_status=$?
set -e
test "$negative_status" -eq 12
grep -q 'Invariant ReconnectCarriesLatestId is violated.' \
  "$temporary_root/negative.log"

set +e
run_tlc SSEClientTrace.cfg SSEClientTrace "$temporary_root/trace-states" \
  -dumpTrace json "$temporary_root/raw.json" \
  >"$temporary_root/trace.log" 2>&1
trace_status=$?
set -e
test "$trace_status" -eq 12
grep -q 'Invariant WitnessPending is violated.' "$temporary_root/trace.log"
grep -q '13 distinct states found' "$temporary_root/trace.log"

"$tla_cli" trace normalize \
  "$temporary_root/raw.json" "$temporary_root/sse-client.trace.json" \
  "$model_root/SSEClientTrace.tla" \
  --config "$model_root/SSEClientTrace.cfg" \
  --toolchain tla2tools-1.8.0+9787e65 20 32
"$tla_cli" trace validate "$temporary_root/sse-client.trace.json" 20 32
cmp "$trace" "$temporary_root/sse-client.trace.json"

"$tla_cli" ada generate "$model_root/SSEClientTrace.tla" \
  --config "$model_root/SSEClientTrace.cfg" \
  --package SSE_Client_Model \
  --output "$temporary_root/generated" \
  --type-invariant TypeOK \
  --input-type HarnessInputType \
  --outcome-type HarnessOutcomeType
for generated_file in \
  sse_client_model.ads sse_client_model.adb sse_client_model.inference.json
do
  cmp "$ada_root/generated/$generated_file" \
    "$temporary_root/generated/$generated_file"
done

cd "$ada_root"
"$alr" -n build
./bin/sse-client-conformance "$trace" >"$temporary_root/replay.log"
grep -Fxq 'conformant: 12 modeled steps' "$temporary_root/replay.log"
set +e
./bin/sse-client-conformance --buggy "$trace" \
  >"$temporary_root/buggy.log" 2>&1
buggy_status=$?
set -e
test "$buggy_status" -ne 0
grep -Fxq \
  'diverged at step 6: state:SSEClientTrace!ReconnectWaitElapsed' \
  "$temporary_root/buggy.log"

proof_path=$PATH
if [ -n "${FLYOLOGY_TLAPM_PATH_PREFIX:-}" ]; then
  proof_path=$FLYOLOGY_TLAPM_PATH_PREFIX:$proof_path
fi
cd "$model_root"
PATH=$proof_path "$FLYOLOGY_TLAPM" \
  --cache-dir "$temporary_root/tlapm-cache" --cleanfp --nofp \
  --strict --method smt SSEClientProof.tla \
  >"$temporary_root/tlapm.log" 2>&1
grep -q 'All 4 obligations proved.' "$temporary_root/tlapm.log"

printf '%s\n' \
  'SSE client TLC, TLAPS, generated Ada replay, and negative probes passed'
