#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")

if [ "${FLYOLOGY_HTTP_HOOK_ELISION_IN_ALIRE:-0}" != 1 ]; then
  "$alr" build >/dev/null
  FLYOLOGY_HTTP_HOOK_ELISION_IN_ALIRE=1
  export FLYOLOGY_HTTP_HOOK_ELISION_IN_ALIRE
  exec "$alr" exec -- "$0"
fi

temp_root=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http-hook-elision.XXXXXX")

cleanup () {
  rm -rf -- "$temp_root"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

undefined_symbols () {
  nm -u "$1" | awk '
    {
      found = 0
      for (i = 1; i <= NF; i++) {
        if ($i == "U") {
          print $(i + 1)
          found = 1
        }
      }
      if (!found && NF == 1 && $1 !~ /:$/) print $1
    }
  '
}

check_project_selection () {
  state=$1
  if [ "$state" = enabled ]; then
    value=true
    opposite=disabled
  else
    value=false
    opposite=enabled
  fi

  inspection=$(gprinspect \
    -P "$project_root/flyology_http.gpr" \
    --attributes --display=textual --views=flyology_http \
    -XFLYOLOGY_CONNECTION_TEST_HOOKS="$value")
  expected="/src/test_hooks/connection/$state"
  unexpected="/src/test_hooks/connection/$opposite"
  if ! printf '%s\n' "$inspection" | grep -F "$expected" >/dev/null; then
    printf '%s\n' "connection hooks omit $expected" >&2
    exit 1
  fi
  if printf '%s\n' "$inspection" | grep -F "$unexpected" >/dev/null; then
    printf '%s\n' "connection hooks include $unexpected" >&2
    exit 1
  fi
}

check_archive () {
  state=$1
  mode=$2
  shift 2
  if [ "$state" = enabled ]; then
    value=true
  else
    value=false
  fi
  subdir="hook-elision-$state-$mode"
  build_log="$temp_root/$state-$mode.log"

  if ! env -u GPR_CONFIG gprbuild \
    -P "$project_root/flyology_http.gpr" \
    --subdirs="$subdir" -f -p -q -j0 \
    -XFLYOLOGY_CONNECTION_TEST_HOOKS="$value" \
    -XFLYOLOGY_HTTP_LIBRARY_TYPE=static \
    -cargs:Ada "$@" >"$build_log" 2>&1
  then
    cat "$build_log" >&2
    exit 1
  fi

  archive="$project_root/lib/$subdir/libFlyology_HTTP.a"
  if [ ! -f "$archive" ]; then
    printf '%s\n' "hook-elision build did not produce $archive" >&2
    exit 1
  fi
  symbols=$(undefined_symbols "$archive")
  if printf '%s\n' "$symbols" | grep -F \
    flyology_http_disabled_hook_must_be_elided >/dev/null
  then
    printf '%s\n' \
      "disabled connection-hook sentinel survived in $state $mode" >&2
    exit 1
  fi

  real_symbols='flyology_test_connection_barrier_arrive
flyology_test_connection_barrier_released
flyology_http_test_connection_receive_limit
flyology_http_test_connection_receive_observed'
  for symbol in $real_symbols; do
    if [ "$state" = enabled ]; then
      if ! printf '%s\n' "$symbols" | grep -F "$symbol" >/dev/null; then
        printf '%s\n' \
          "enabled connection hook $symbol disappeared in $mode" >&2
        exit 1
      fi
    elif printf '%s\n' "$symbols" | grep -F "$symbol" >/dev/null; then
      printf '%s\n' \
        "production connection hook $symbol survived in $mode" >&2
      exit 1
    fi
  done
}

if git -C "$project_root" grep -n -- '-gnateD' -- '*.gpr' >/dev/null; then
  printf '%s\n' "global Ada preprocessor switches reappeared" >&2
  exit 1
fi
if git -C "$project_root" grep -n -E \
  '^#(if|else|end if)' -- '*.adb' '*.ads' >/dev/null
then
  printf '%s\n' "Ada preprocessing directives reappeared" >&2
  exit 1
fi

printf '%s\n' 'HTTP test-hook elision: both project selections'
check_project_selection disabled
check_project_selection enabled

printf '%s\n' 'HTTP test-hook elision: strict -O0 archives'
check_archive disabled O0-strict \
  -O0 -fno-inline -fno-inline-functions -fno-tree-dce -fno-dce
check_archive enabled O0-strict \
  -O0 -fno-inline -fno-inline-functions -fno-tree-dce -fno-dce

printf '%s\n' 'HTTP test-hook elision: every supported optimization mode'
for mode in O0 Og O1 O2 O3 Os Oz Ofast; do
  check_archive disabled "$mode" "-$mode"
  check_archive enabled "$mode" "-$mode"
done

printf '%s\n' 'HTTP test-hook elision: PASS'
