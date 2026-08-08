#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if ! command -v gnatdoc >/dev/null 2>&1; then
  installed_gnatdoc=${ALIRE_INSTALL_PREFIX:-"$HOME/.alire"}/bin/gnatdoc
  if [ ! -x "$installed_gnatdoc" ]; then
    printf '%s\n' \
      "gnatdoc not found; install it with: alr install gnatdoc_bin" >&2
    exit 1
  fi
  PATH=$(dirname "$installed_gnatdoc"):$PATH
  export PATH
fi

cd "$crate_root"
FLYOLOGY_QUIC_DOCUMENTATION=true
export FLYOLOGY_QUIC_DOCUMENTATION
alr build --stop-after=generation
alr exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  -P flyology_quic.gpr \
  -O docs/api

test -f docs/api/index.html
