#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$crate_root/tests"
alr build
"$crate_root/tests/bin/flyology_iri_tests"

if [ -n "${ADA_URL_ROOT:-}" ]; then
  python3 "$crate_root/tests/wpt_conformance.py" \
    "$crate_root/tests/bin/flyology_iri_url_cli" "$ADA_URL_ROOT"
fi
