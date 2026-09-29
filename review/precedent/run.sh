#!/bin/sh
# Build and run one reproduction program.
#   ./run.sh repro_name [timeout_seconds]
# Exit status: 0 = expected (correct) behavior observed; 1 = bug reproduced;
# 124 = timed out (treated as a hang); other = build failure or crash.
set -u
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
name=${1:?repro program name}
limit=${2:-60}
lock="$script_dir/.build.lock"
cd "$script_dir" || exit 2
# Serialize concurrent builds sharing one object directory.
tries=0
until mkdir "$lock" 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -gt 600 ]; then echo "lock timeout" >&2; exit 2; fi
  sleep 1
done
trap 'rmdir "$lock" 2>/dev/null' EXIT HUP INT TERM
if ! alr -n exec -- gprbuild -q -p -P repros.gpr -XMAIN="$name" >"obj/build-$name.log" 2>&1; then
  cat "obj/build-$name.log" >&2
  echo "BUILD FAILED: $name" >&2
  exit 2
fi
rmdir "$lock" 2>/dev/null
trap - EXIT HUP INT TERM
timeout "$limit" "./bin/$name"
status=$?
if [ "$status" -eq 124 ]; then echo "TIMEOUT after ${limit}s: $name (hang)"; fi
exit "$status"
