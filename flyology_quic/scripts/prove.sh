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
  --checks-as-errors=on \
  --report=all \
  -f \
  -u \
  flyology-quic-connection_state_policy.adb \
  flyology-quic-crypto_frame_policy.adb \
  flyology-quic-crypto_reassembly_policy.adb \
  flyology-quic-handshake_packet_policy.adb \
  flyology-quic-initial_frame_policy.adb \
  flyology-quic-initial_packet_policy.adb \
  flyology-quic-long_header_policy.adb \
  flyology-quic-one_rtt_packet_policy.adb \
  flyology-quic-packet_number_policy.adb \
  flyology-quic-protection_policy.adb \
  flyology-quic-stream_frame_policy.adb \
  flyology-quic-tls_authentication_policy.adb \
  flyology-quic-tls_extension_policy.adb \
  flyology-quic-tls_handshake_policy.adb \
  flyology-quic-tls_signature_policy.adb \
  flyology-quic-transport_parameter_policy.adb \
  flyology-quic-varint_policy.adb

printf '%s\n' "Flyology QUIC SPARK proof suite passed"
