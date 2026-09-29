#!/bin/sh
# Autobahn WebSocket conformance. The run refuses a dirty worktree (its
# provenance guard), so it runs from a pristine detached worktree at the same
# commit. Results are written back into the review worktree's baseline logs.
set -u
WS=/Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/ws-conformance-963c47
L=/Users/yrashk/Projects/flyology-ada/flyology-http/.claude/worktrees/exciting-lumiere-963c47/review/baselines

run () {
  name=$1; shift
  start=$(date +%s)
  printf '%s START %s\n' "$(date -u +%FT%TZ)" "$name" >> "$L/SUMMARY.txt"
  ( cd "$WS" && "$@" ) > "$L/$name.log" 2>&1
  rc=$?
  end=$(date +%s)
  printf '%-34s rc=%-3d secs=%-6d disk_free=%s\n' \
    "$name" "$rc" "$((end - start))" "$(df -h "$WS" | tail -1 | awk '{print $4}')" \
    >> "$L/SUMMARY.txt"
}

run 20-autobahn-core-native       ./scripts/websocket-conformance.sh core native
run 21-autobahn-core-lightweight  ./scripts/websocket-conformance.sh core lightweight
run 22-autobahn-limits-native     ./scripts/websocket-conformance.sh limits native
run 23-autobahn-compression-native ./scripts/websocket-conformance.sh compression native

printf '%s AUTOBAHN DONE\n' "$(date -u +%FT%TZ)" >> "$L/SUMMARY.txt"
