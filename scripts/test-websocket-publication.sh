#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

sh -n "$project_root/scripts/websocket-conformance.sh"
node --check "$project_root/scripts/websocket-run-provenance.mjs"
node --check "$project_root/scripts/publish-websocket-conformance.mjs"
node --check "$project_root/scripts/check-websocket-verdicts.mjs"
node --test "$project_root/tests/check_websocket_verdicts_test.mjs"
node --test "$project_root/tests/websocket_run_provenance_test.mjs"
