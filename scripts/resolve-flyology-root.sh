#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")

valid_root () {
  [ -n "${1:-}" ] && [ -x "$1/scripts/prepare-rts.sh" ]
}

if valid_root "${FLYOLOGY_ROOT:-}"; then
  printf '%s\n' "$FLYOLOGY_ROOT"
  exit 0
fi

if [ -x "$http_root/../scripts/prepare-rts.sh" ]; then
  CDPATH= cd -- "$http_root/.." && pwd
  exit 0
fi

resolve_from_alire () {
  "$alr" exec -- sh -c 'printf "%s\n" "${FLYOLOGY_ROOT:-}"'
}

flyology_root=$(resolve_from_alire 2>/dev/null || :)
if ! valid_root "$flyology_root"; then
  (
    cd "$http_root"
    "$alr" build --stop-after=generation >&2
  )
  flyology_root=$(resolve_from_alire)
fi

if ! valid_root "$flyology_root"; then
  printf '%s\n' \
    "Flyology's source cannot prepare a custom runtime after Alire dependency bootstrap" \
    >&2
  exit 2
fi

printf '%s\n' "$flyology_root"
