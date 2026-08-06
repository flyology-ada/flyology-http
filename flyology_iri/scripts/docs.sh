#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if ! command -v gnatdoc >/dev/null 2>&1; then
  installed_gnatdoc=${ALIRE_INSTALL_PREFIX:-"$HOME/.alire"}/bin/gnatdoc
  if [ ! -x "$installed_gnatdoc" ]; then
    printf '%s\n' "gnatdoc not found; install gnatdoc_bin with Alire" >&2
    exit 1
  fi
  PATH=$(dirname "$installed_gnatdoc"):$PATH
  export PATH
fi
cd "$crate_root"
alr build
alr exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  --generate=public \
  -P flyology_iri.gpr \
  -O docs/api
test -f docs/api/index.html
