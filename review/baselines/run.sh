#!/bin/sh
# Serialized baseline runner. Never run two alr commands concurrently.
set -u
W=/Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/exciting-lumiere-963c47
L=$W/review/baselines
mkdir -p "$L"
: > "$L/SUMMARY.txt"

run () {
  name=$1; shift
  start=$(date +%s)
  printf '%s START %s\n' "$(date -u +%FT%TZ)" "$name" >> "$L/SUMMARY.txt"
  ( cd "$W" && "$@" ) > "$L/$name.log" 2>&1
  rc=$?
  end=$(date +%s)
  printf '%-34s rc=%-3d secs=%-6d disk_free=%s\n' \
    "$name" "$rc" "$((end - start))" "$(df -h "$W" | tail -1 | awk '{print $4}')" \
    >> "$L/SUMMARY.txt"
}

export ADA_URL_ROOT="$W/build/ada-url"
export FLYOLOGY_IRI_REQUIRE_WPT=1

run 01-alr-build                 alr build
run 02-test-sh                   ./scripts/test.sh
run 03-prove                     ./scripts/prove.sh
run 04-check-test-hook-elision   ./scripts/check-test-hook-elision.sh
run 05-iri-wpt-gate              ./flyology_iri/scripts/wpt-gate-test.sh
run 06-http2-prepare             ./scripts/http2-test.sh prepare
run 07-http2-all                 ./scripts/http2-test.sh all
run 08-http-client-differential  ./scripts/http-client-differential.sh run
run 09-http-client-conformance   ./scripts/http-client-conformance.sh
run 10-http3-interop             ./scripts/test-http3-interop.sh all
run 11-http3-h3spec              ./scripts/test-http3-h3spec.sh
run 12-http3-stress              ./scripts/test-http3-stress.sh
run 13-http2-h2spec-docker       ./scripts/http2-test.sh h2spec
run 14-autobahn-core-native      ./scripts/websocket-conformance.sh core native
run 15-autobahn-core-lightweight ./scripts/websocket-conformance.sh core lightweight
run 16-autobahn-compression      ./scripts/websocket-conformance.sh compression native

printf '%s ALL DONE\n' "$(date -u +%FT%TZ)" >> "$L/SUMMARY.txt"
