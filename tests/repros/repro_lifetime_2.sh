#!/bin/sh
# Reproduction for LIFETIME-2 (shell reproduction; no Ada build needed).
#
#   ./tests/repros/repro_lifetime_2.sh
#
# Asserts the CORRECT behaviour of the "no helper task in client units" gate at
# scripts/test.sh:74-84.  The gate text is EXTRACTED VERBATIM from the tracked
# script (sed -n '74,84p'), never retyped, so this cannot drift from the file it
# tests.  Exit 0 = gate behaves correctly; exit 1 = BUG REPRODUCED.
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
http_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)

checks=0
failures=0
ok ()   { checks=$((checks + 1)); printf '  ok   %s\n' "$1"; }
bad ()  { checks=$((checks + 1)); failures=$((failures + 1)); printf '  FAIL %s\n' "$1"; }
note () { printf '  note %s\n' "$1"; }

work=$(mktemp -d "${TMPDIR:-/tmp}/repro_lifetime_2.XXXXXX") || exit 2
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/empty_path"

# The gate, lifted verbatim out of the tracked script.
{
  printf '%s\n' '#!/bin/sh' 'set -eu' 'http_root="$1"'
  sed -n '74,84p' "$http_root/scripts/test.sh"
  printf '%s\n' 'exit 0'
} > "$work/gate.sh"
chmod +x "$work/gate.sh"
note "gate extracted from scripts/test.sh:74-84"

# A sandbox whose src/ holds copies of exactly the files the gate globs.
build_sandbox () {   # $1 = sandbox dir, $2 = text to append to the client body
  root=$1
  rm -rf "$root"
  mkdir -p "$root/src"
  cp "$http_root"/src/flyology-http-client*.ad[bs] \
     "$http_root"/src/flyology-http-http_2_client_connection.ad[bs] \
     "$http_root"/src/flyology-http-http_3_client_connection.ad[bs] \
     "$root/src/" 2>/dev/null
  if [ -n "$2" ]; then
    printf '%s\n' "$2" >> "$root/src/flyology-http-client-state_lifetime.adb"
  fi
}

run_gate () {        # $1 = sandbox dir; echoes the gate's exit status
  ( "$work/gate.sh" "$1" >/dev/null 2>&1; echo $? )
}

run_gate_without_rg () {
  ( PATH="$work/empty_path"; export PATH; \
    "$work/gate.sh" "$1" >/dev/null 2>&1; echo $? )
}

# ---------------------------------------------------------------------------
# Control: the gate must actually work on the form it was written for.
# ---------------------------------------------------------------------------
build_sandbox "$work/control" '   task Probe;'
status=$(run_gate "$work/control")
if [ "$status" -eq 1 ]; then
  ok "control: lowercase 'task Probe;' is rejected (exit 1)"
else
  bad "control: lowercase 'task Probe;' should be rejected, gate exited $status"
  note "the extraction is wrong; the rest of this run proves nothing"
fi

# Control: a clean tree passes.
build_sandbox "$work/clean" ''
status=$(run_gate "$work/clean")
if [ "$status" -eq 0 ]; then
  ok "control: unmodified sources pass (exit 0) -- the invariant holds at HEAD"
else
  bad "control: unmodified sources should pass, gate exited $status"
fi

# ---------------------------------------------------------------------------
# Evasion 1: fails open when rg is absent (set -e does not fire on an if
# condition, so exit 127 takes the false branch).
# ---------------------------------------------------------------------------
status=$(run_gate_without_rg "$work/control")
if [ "$status" -ne 0 ]; then
  ok "no rg on PATH: gate still rejects the violating tree (exit $status)"
else
  bad "no rg on PATH: gate PASSED a tree containing 'task Probe;' (exit 0)"
  note "rg exits 127 inside the if condition; set -e does not fire there"
fi

# ---------------------------------------------------------------------------
# Evasion 2: Ada reserved words are case-insensitive (RM 2.9(1)); the pattern
# is not.
# ---------------------------------------------------------------------------
build_sandbox "$work/case" '   Task Probe;'
status=$(run_gate "$work/case")
if [ "$status" -eq 1 ]; then
  ok "capitalised 'Task Probe;' is rejected"
else
  bad "capitalised 'Task Probe;' was NOT rejected (exit $status)"
fi

build_sandbox "$work/case2" '   TASK TYPE Probe;'
status=$(run_gate "$work/case2")
if [ "$status" -eq 1 ]; then
  ok "upper-case 'TASK TYPE Probe;' is rejected"
else
  bad "upper-case 'TASK TYPE Probe;' was NOT rejected (exit $status)"
fi

# ---------------------------------------------------------------------------
# Evasion 3: a line break after the keyword is legal Ada; the pattern is
# line-oriented and requires whitespace after 'task' on the same line.
# ---------------------------------------------------------------------------
build_sandbox "$work/break" '   task
   Probe;'
status=$(run_gate "$work/break")
if [ "$status" -eq 1 ]; then
  ok "'task' + newline + name is rejected"
else
  bad "'task' + newline + name was NOT rejected (exit $status)"
fi

# ---------------------------------------------------------------------------
# Evasion 4: a task reached through a generic instantiation carries no 'task'
# keyword at all.
# ---------------------------------------------------------------------------
build_sandbox "$work/generic" '   package Helpers is new Flyology.Task_Scopes (Worker_Body);'
status=$(run_gate "$work/generic")
if [ "$status" -eq 1 ]; then
  ok "Task_Scopes instantiation in a client unit is rejected"
else
  bad "Task_Scopes instantiation in a client unit was NOT rejected (exit $status)"
fi

# ---------------------------------------------------------------------------
# Evasion 5: a unit the client withs but the three globs do not cover.
# ---------------------------------------------------------------------------
build_sandbox "$work/sibling" ''
for f in flyology-http-http_1_internals.adb flyology-http-websocket_client.adb \
         flyology-http-http_3.adb
do
  if [ -f "$http_root/src/$f" ]; then
    cp "$http_root/src/$f" "$work/sibling/src/$f"
    printf '%s\n' '   task Probe;' >> "$work/sibling/src/$f"
  fi
done
status=$(run_gate "$work/sibling")
if [ "$status" -eq 1 ]; then
  ok "task in a withed sibling unit is rejected"
else
  bad "task in withed sibling units (http_1_internals, websocket_client, http_3) was NOT rejected (exit $status)"
  note "the three globs do not cover them"
fi

printf 'checks: %d  failures: %d\n' "$checks" "$failures"
if [ "$failures" -eq 0 ]; then
  printf '%s\n' PASS
  exit 0
fi
printf '%s\n' 'BUG REPRODUCED'
exit 1
