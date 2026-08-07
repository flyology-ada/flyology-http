#!/bin/sh
# Regression test for the WPT URL conformance gate wiring.
#
# The conformance harness is this crate's primary oracle, yet it is opt-in on
# ADA_URL_ROOT so that a developer without the third-party corpus can still
# run the suite. CI must therefore both supply a pinned corpus and refuse to
# run without one. This test pins the three halves of that contract: the
# developer skip, the CI hard requirement, and the workflow wiring that was
# missing when the gate silently never ran.
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_script="$crate_root/scripts/test.sh"
workflow="$crate_root/../.github/workflows/ci.yml"
failures=0

fail () {
  printf '%s\n' "flyology_iri wpt-gate-test: FAIL $1" >&2
  failures=$((failures + 1))
}

pass () {
  printf '%s\n' "flyology_iri wpt-gate-test: PASS $1"
}

# A CI run whose corpus wiring is missing must fail rather than skip.
set +e
required_output=$(env -u ADA_URL_ROOT FLYOLOGY_IRI_REQUIRE_WPT=1 \
  "$test_script" 2>&1)
required_status=$?
set -e
if [ "$required_status" -eq 0 ]; then
  fail "required gate succeeded without ADA_URL_ROOT"
elif ! printf '%s\n' "$required_output" \
  | grep -q "FLYOLOGY_IRI_REQUIRE_WPT is set but ADA_URL_ROOT is not"
then
  fail "required gate failed without naming the missing corpus"
else
  pass "missing corpus fails a required run"
fi

# The developer path is unchanged: no corpus, no gate, no failure.
set +e
skipped_output=$(env -u ADA_URL_ROOT -u FLYOLOGY_IRI_REQUIRE_WPT \
  "$test_script" 2>&1)
skipped_status=$?
set -e
if [ "$skipped_status" -ne 0 ]; then
  printf '%s\n' "$skipped_output" >&2
  fail "unset ADA_URL_ROOT did not skip the gate"
elif ! printf '%s\n' "$skipped_output" \
  | grep -q "WPT URL conformance skipped"
then
  fail "the skipped gate did not report itself"
else
  pass "an unset corpus skips the gate and reports the skip"
fi

# The workflow must pin the corpus by commit and demand the gate.
if [ ! -f "$workflow" ]; then
  printf '%s\n' \
    "flyology_iri wpt-gate-test: SKIP workflow check; $workflow is absent"
else
  if ! grep -q "repository: ada-url/ada" "$workflow"; then
    fail "the workflow does not check out ada-url/ada"
  elif ! grep -Eq "ref: [0-9a-f]{40}" "$workflow"; then
    fail "the workflow does not pin ada-url/ada by commit"
  elif ! grep -q "ADA_URL_ROOT:" "$workflow"; then
    fail "the workflow does not set ADA_URL_ROOT"
  elif ! grep -q "FLYOLOGY_IRI_REQUIRE_WPT:" "$workflow"; then
    fail "the workflow does not require the gate"
  else
    pass "the workflow pins the corpus by commit and requires the gate"
  fi
fi

if [ "$failures" -ne 0 ]; then
  printf '%s\n' "flyology_iri wpt-gate-test: $failures check(s) failed" >&2
  exit 1
fi
printf '%s\n' "flyology_iri WPT gate wiring passed"
