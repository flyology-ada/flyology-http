#!/bin/sh
# Build and run every reproduction program in this harness and print one
# line per program: name, exit status, meaning.  Exit status of this script
# is 0 when every program behaved as recorded (bug programs reproduce, the
# smoke program passes), 1 otherwise.
#   ./run-all.sh [timeout_seconds] [name_prefix]
set -u
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
limit=${1:-120}
prefix=${2:-repro_}
cd "$script_dir" || exit 2
overall=0
for file in src/"$prefix"*.adb; do
  name=$(basename "$file" .adb)
  case "$name" in *_support|*_smoke) continue ;; esac
  ./run.sh "$name" "$limit" >"obj/run-$name.log" 2>&1
  status=$?
  case "$status" in
    0)   meaning="PASS (bug NOT reproduced)"; overall=1 ;;
    1)   meaning="BUG REPRODUCED" ;;
    124) meaning="TIMEOUT (hang)" ;;
    2)   meaning="BUILD FAILED"; overall=1 ;;
    *)   meaning="CRASH/other"; overall=1 ;;
  esac
  printf '%-28s %3d  %s\n' "$name" "$status" "$meaning"
done
exit "$overall"
