#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
workflow=${1:-$http_root/.github/workflows/ci.yml}
formal_check=${2:-$http_root/scripts/check-sse-client-formal.sh}
trace=${3:-$http_root/formal/sse_client/traces/sse-client.trace.json}
formal_manifest=${4:-$http_root/formal/sse_client/ada/alire.toml}

checkout_block=$(sed -n \
  '/name: Check out the pinned Flyology TLA harness/,/name: Run SSE reconnect formal gate/p' \
  "$workflow")

printf '%s\n' "$checkout_block" | grep -Fq 'repository: flyology-ada/tla' || {
  printf '%s\n' 'formal CI does not check out flyology-ada/tla' >&2
  exit 1
}
printf '%s\n' "$checkout_block" | grep -Fq 'path: build/flyology-tla' || {
  printf '%s\n' 'formal CI flyology_tla checkout uses an unexpected path' >&2
  exit 1
}
tla_revision=$(printf '%s\n' "$checkout_block" |
  sed -n 's/^[[:space:]]*ref: \([0-9a-f][0-9a-f]*\)$/\1/p')
printf '%s\n' "$tla_revision" | grep -Eq '^[0-9a-f]{40}$' || {
    printf '%s\n' 'formal CI flyology_tla ref is not a full commit ID' >&2
    exit 1
  }
printf '%s\n' "$checkout_block" | grep -Fq 'persist-credentials: false' || {
  printf '%s\n' 'formal CI flyology_tla checkout retains credentials' >&2
  exit 1
}

if grep -Fq 'flyology_tla=0.1.0-dev' "$workflow"; then
  printf '%s\n' \
    'formal CI resolves flyology_tla through the mutable development index' >&2
  exit 1
fi

formal_block=$(sed -n \
  '/name: Run SSE reconnect formal gate/,/name: Prove QUIC and HTTP policy units/p' \
  "$workflow")
printf '%s\n' "$formal_block" |
  grep -Fq '(cd build/flyology-tla && alr -n install --prefix="$tla_prefix")' || {
    printf '%s\n' \
      'formal CI does not install the checked-out flyology_tla revision' >&2
    exit 1
  }

grep -Fq \
  'flyology_tla = { url = "git+https://github.com/flyology-ada/tla.git", commit = "'"$tla_revision"'" }' \
  "$formal_manifest" || {
    printf '%s\n' \
      'formal Ada dependency does not match the CI flyology_tla source pin' >&2
    exit 1
  }

toolchain_id=$(sed -n \
  's/.*--toolchain \(tla2tools-[^ ]*\) .*/\1/p' "$formal_check")
test -n "$toolchain_id" || {
  printf '%s\n' 'formal check does not record a TLA+ toolchain identity' >&2
  exit 1
}
grep -Fq '"toolchain":"'"$toolchain_id"'"' "$trace" || {
  printf '%s\n' 'checked SSE trace does not match the formal toolchain identity' >&2
  exit 1
}

printf '%s\n' 'formal CI toolchain source and trace provenance pins passed'
