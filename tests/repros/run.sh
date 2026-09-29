#!/bin/sh
# Build and run one reproduction program.
#   ./run.sh repro_name [timeout_seconds]
# Exit status: 0 = expected (correct) behaviour observed; 1 = bug reproduced;
# 124 = timed out (treated as a hang); 2 = build failure; other = crash.
#
# The build mirrors scripts/test.sh: it re-executes itself under `alr exec`,
# unsets GPR_CONFIG, applies the macOS sysroot workaround, builds against the
# version-matched runtime under build/rts that scripts/test.sh prepared, and
# sets FLYOLOGY_TLS_TEST_HOOKS.  Run ./scripts/test.sh at least once first so
# build/rts exists.
set -u

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
http_root=$(CDPATH= cd -- "$script_dir/../.." && pwd)
. "$http_root/scripts/alire-test-context.sh"
alr=$("$http_root/scripts/find-alr.sh")
test_rts="$http_root/build/rts"

# `alr exec` reports its own exit status, not the child's, so the inner run
# records the real status in a file and the outer run reads it back. Without
# this every outcome would surface as 1 and run-all.sh's table would be wrong.
if [ -z "${FLYOLOGY_HTTP_TEST_IN_ALIRE:-}" ]; then
  outer_name=${1:?repro program name}
  mkdir -p "$script_dir/obj"
  status_file="$script_dir/obj/status-$outer_name"
  rm -f "$status_file"
  cd "$http_root" || exit 2
  "$alr" exec -- \
    env FLYOLOGY_HTTP_TEST_IN_ALIRE=1 \
    FLYOLOGY_REPRO_STATUS_FILE="$status_file" \
    "$script_dir/run.sh" "$@"
  alr_status=$?
  if [ -f "$status_file" ]; then
    read -r inner_status < "$status_file"
    exit "$inner_status"
  fi
  exit "$alr_status"
fi

name=${1:?repro program name}
limit=${2:-60}

record_status () {
  if [ -n "${FLYOLOGY_REPRO_STATUS_FILE:-}" ]; then
    printf '%s\n' "$1" > "$FLYOLOGY_REPRO_STATUS_FILE"
  fi
}

if [ ! -d "$test_rts" ]; then
  printf '%s\n' "missing runtime $test_rts; run ./scripts/test.sh once" >&2
  record_status 2
  exit 2
fi

FLYOLOGY_TLS_TEST_HOOKS=true
export FLYOLOGY_TLS_TEST_HOOKS

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$(gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      env -u GPR_CONFIG gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    env -u GPR_CONFIG gprbuild "$@" -largs -nodefaultrpaths
    return
  fi
  env -u GPR_CONFIG gprbuild "$@"
}

cd "$script_dir" || exit 2
mkdir -p obj bin

# Serialize concurrent builds sharing one object directory.  Several
# verification agents run at once and gprbuild is not safe against that.
lock="$script_dir/.build.lock"
tries=0
until mkdir "$lock" 2>/dev/null; do
  tries=$((tries + 1))
  if [ "$tries" -gt 900 ]; then
    printf '%s\n' "build lock timeout waiting for another spike" >&2
    exit 2
  fi
  sleep 1
done
trap 'rmdir "$lock" 2>/dev/null' EXIT HUP INT TERM

if ! run_gprbuild \
      --RTS="$test_rts" \
      --subdirs=repros \
      -q -p -j0 \
      -P "$script_dir/repros.gpr" \
      -XMAIN="$name" \
      > "obj/build-$name.log" 2>&1
then
  cat "obj/build-$name.log" >&2
  printf '%s\n' "BUILD FAILED: $name" >&2
  rmdir "$lock" 2>/dev/null
  trap - EXIT HUP INT TERM
  record_status 2
  exit 2
fi

rmdir "$lock" 2>/dev/null
trap - EXIT HUP INT TERM

# The spike runs from the repository root so that relative fixture paths
# under tests/ resolve the way the maintained suites resolve them.
cd "$http_root" || exit 2
# GNU timeout reports 124 on expiry, which is the harness hang convention.
if command -v timeout >/dev/null 2>&1; then
  timeout "$limit" "$script_dir/bin/repros/$name"
  status=$?
else
  "$http_root/scripts/run-with-timeout.sh" "$limit" \
    "$script_dir/bin/repros/$name"
  status=$?
  case "$status" in 137 | 143) status=124 ;; esac
fi
if [ "$status" -eq 124 ]; then
  printf '%s\n' "TIMEOUT after ${limit}s: $name (hang)"
fi
record_status "$status"
exit "$status"
