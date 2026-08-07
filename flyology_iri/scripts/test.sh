#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

# The WPT URL corpus lives in the third-party ada-url/ada repository, so
# ADA_URL_ROOT stays optional and a developer without that checkout still
# gets the unit suite. CI pins the corpus and sets FLYOLOGY_IRI_REQUIRE_WPT,
# which turns a missing corpus into a build failure: a conformance gate that
# skips itself when its environment is unset is indistinguishable from a
# green run, which is how this suite went unrun in CI.
if [ -z "${ADA_URL_ROOT:-}" ] && [ -n "${FLYOLOGY_IRI_REQUIRE_WPT:-}" ]; then
  printf '%s\n' \
    "flyology_iri: FLYOLOGY_IRI_REQUIRE_WPT is set but ADA_URL_ROOT is not" >&2
  exit 2
fi

cd "$crate_root/tests"
alr build
"$crate_root/tests/bin/flyology_iri_tests"

if [ -n "${ADA_URL_ROOT:-}" ]; then
  python3 "$crate_root/tests/wpt_conformance.py" \
    "$crate_root/tests/bin/flyology_iri_url_cli" "$ADA_URL_ROOT"
else
  printf '%s\n' \
    "flyology_iri: WPT URL conformance skipped; set ADA_URL_ROOT to run it"
fi
