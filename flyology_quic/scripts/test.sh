#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$crate_root/tests"
alr build

for test in \
  flyology-quic-crypto_openssl-smoke \
  flyology-quic-initial_packet_policy-smoke \
  flyology-quic-long_header_policy-smoke \
  flyology-quic-packet_number_policy-smoke \
  flyology-quic-protection_policy-smoke \
  flyology-quic-varint_policy-smoke
do
  printf '%s\n' "flyology_quic test: BEGIN $test"
  "$crate_root/tests/bin/$test"
  printf '%s\n' "flyology_quic test: PASS $test"
done
