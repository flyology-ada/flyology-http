#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$crate_root"
FLYOLOGY_QUIC_DOCUMENTATION=true
export FLYOLOGY_QUIC_DOCUMENTATION
alr build
alr exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  -P flyology_quic.gpr \
  -O docs/api

test -f docs/api/index.html
