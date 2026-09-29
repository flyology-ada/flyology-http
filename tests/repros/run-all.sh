#!/bin/sh
# Build and run every reproduction program and print one line per program:
# name, exit status, meaning.  Exit status of this script is 0 when every
# program behaved as recorded (each finding spike reproduces, the harness
# self-tests pass), 1 otherwise.
#   ./run-all.sh [timeout_seconds] [name_filter]
#
# Three kinds of spike are covered:
#   src/repro_<id>.adb                      ordinary program
#   src/<parent>-repro_<id>.adb             child unit, for a private package
#   repro_<id>.sh                           shell reproduction
set -u
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
limit=${1:-120}
filter=${2:-}
cd "$script_dir" || exit 2
mkdir -p obj
overall=0

report () {
  name=$1
  status=$2
  case "$status" in
    0)   meaning="PASS (bug NOT reproduced)"; overall=1 ;;
    1)   meaning="BUG REPRODUCED" ;;
    124) meaning="TIMEOUT (hang)" ;;
    2)   meaning="BUILD FAILED"; overall=1 ;;
    *)   meaning="CRASH/other"; overall=1 ;;
  esac
  printf '%-58s %3d  %s\n' "$name" "$status" "$meaning"
}

# Programs that must PASS on current sources rather than reproduce a bug:
# the two harness self-tests, and the adversarial probes that establish a
# surface is sound (a probe reproducing would mean a new defect).
EXPECTED_PASS="repro_smoke seam_check repro_h1_server_6 repro_h1_server_7"

# Controls that must FAIL TO COMPILE. repro_lifetime_3b and 3c are the negative
# controls for the compile-time enforcement finding: the compiler rejecting
# them is the evidence that the rule is live where the contract does hold.
EXPECTED_BUILD_FAILURE="repro_lifetime_3b repro_lifetime_3c"

expected_build_failure () {
  for candidate in $EXPECTED_BUILD_FAILURE; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

expected_pass () {
  for candidate in $EXPECTED_PASS; do
    [ "$candidate" = "$1" ] && return 0
  done
  return 1
}

for self in repro_smoke seam_check; do
  "$script_dir/run.sh" "$self" 60 > "obj/run-$self.log" 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    printf '%-58s %3d  %s\n' "$self" 0 "PASS (harness self-test)"
  else
    printf '%-58s %3d  %s\n' "$self" "$status" \
      "HARNESS BROKEN (self-test did not pass)"
    overall=1
  fi
done

for file in src/*repro_*.adb repro_*.sh; do
  [ -e "$file" ] || continue
  case "$file" in
    *.sh) name=$(basename "$file" .sh); kind=shell ;;
    *)    name=$(basename "$file" .adb); kind=ada ;;
  esac
  case "$name" in *_support | repro_smoke | seam_check) continue ;; esac
  if [ -n "$filter" ]; then
    case "$name" in *"$filter"*) ;; *) continue ;; esac
  fi
  if [ "$kind" = shell ]; then
    sh "$script_dir/$file" > "obj/run-$name.log" 2>&1
    status=$?
  else
    "$script_dir/run.sh" "$name" "$limit" > "obj/run-$name.log" 2>&1
    status=$?
  fi
  if expected_build_failure "$name"; then
    if [ "$status" -eq 2 ]; then
      printf '%-58s %3d  %s\n' "$name" 2 "BUILD FAILED (control: the rule is live)"
    else
      printf '%-58s %3d  %s\n' "$name" "$status" \
        "CONTROL COMPILED (the compile-time rule is gone)"
      overall=1
    fi
  elif expected_pass "$name"; then
    if [ "$status" -eq 0 ]; then
      printf '%-58s %3d  %s\n' "$name" 0 "PASS (probe: surface is sound)"
    else
      printf '%-58s %3d  %s\n' "$name" "$status" \
        "PROBE FAILED (a sound surface no longer is)"
      overall=1
    fi
  elif [ "$kind" = shell ]; then
    report "$name (shell)" "$status"
  else
    report "$name" "$status"
  fi
done
exit "$overall"
