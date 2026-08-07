#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$crate_root/tests"
alr build

for test in \
  flyology-quic-application_connection-smoke \
  flyology-quic-application_frame_policy-smoke \
  flyology-quic-connection_state_policy-smoke \
  flyology-quic-crypto_frame_policy-smoke \
  flyology-quic-crypto_openssl-smoke \
  flyology-quic-crypto_reassembly_policy-smoke \
  flyology-quic-handshake_connection-smoke \
  flyology-quic-handshake_packet_policy-smoke \
  flyology-quic-handshake_sender-smoke \
  flyology-quic-initial_frame_policy-smoke \
  flyology-quic-initial_connection-smoke \
  flyology-quic-initial_receiver-smoke \
  flyology-quic-initial_sender-smoke \
  flyology-quic-initial_packet_policy-smoke \
  flyology-quic-long_header_policy-smoke \
  flyology-quic-one_rtt_packet_policy-smoke \
  flyology-quic-one_rtt_sender-smoke \
  flyology-quic-packet_number_policy-smoke \
  flyology-quic-protection_policy-smoke \
  flyology-quic-stream_frame_policy-smoke \
  flyology-quic-stream_reassembly_policy-smoke \
  flyology-quic-tls_authentication_policy-smoke \
  flyology-quic-tls_extension_policy-smoke \
  flyology-quic-tls_handshake_policy-smoke \
  flyology-quic-tls_key_schedule-smoke \
  flyology-quic-tls_session-smoke \
  flyology-quic-tls_signature_policy-smoke \
  flyology-quic-tls_transport_smoke \
  flyology-quic-transport_parameter_policy-smoke \
  flyology-quic-varint_policy-smoke
do
  printf '%s\n' "flyology_quic test: BEGIN $test"
  "$crate_root/tests/bin/$test"
  printf '%s\n' "flyology_quic test: PASS $test"
done
