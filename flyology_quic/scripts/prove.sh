#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$crate_root/proof"
alr build --stop-after=generation
alr gnatprove \
  -P "$crate_root/flyology_quic.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --report=all \
  -f \
  -u \
  flyology-quic-long_header_policy.adb \
  flyology-quic-packet_number_policy.adb \
  flyology-quic-protection_policy.adb \
  flyology-quic-varint_policy.adb

printf '%s\n' "Flyology QUIC SPARK proof suite passed"
