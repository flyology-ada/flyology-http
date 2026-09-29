#!/bin/sh
# Follow-up baselines: waits for run.sh to finish, then runs the steps the
# first pass got wrong or skipped.
#   17 the PycURL differential with its prepare step, which run.sh omitted
#   18 the SPARK proof at CI's FLYOLOGY_PROOF_LEVEL=2; run.sh used the script
#      default of 1, where two QUIC checks hit the prover time limit
set -u
W=/Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/exciting-lumiere-963c47
L=$W/review/baselines

while pgrep -f "baselines/run\.sh" >/dev/null 2>&1; do sleep 20; done

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

run 17-differential-prepare      ./scripts/http-client-differential.sh prepare
run 18-differential-run          ./scripts/http-client-differential.sh run
FLYOLOGY_PROOF_LEVEL=2 run 19-prove-level2 ./scripts/prove.sh

printf '%s FOLLOW-UP DONE\n' "$(date -u +%FT%TZ)" >> "$L/SUMMARY.txt"
