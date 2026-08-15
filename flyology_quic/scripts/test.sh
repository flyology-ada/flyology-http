#!/bin/sh
set -eu

crate_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
http_root=$(CDPATH= cd -- "$crate_root/.." && pwd)

if [ -n "${FLYOLOGY_QUIC_TEST_RTS:-}" ]; then
  test_rts=$FLYOLOGY_QUIC_TEST_RTS
elif [ -d "$http_root/build/rts/adainclude" ]; then
  test_rts="$http_root/build/rts"
elif [ -n "${FLYOLOGY_ROOT:-}" ] \
  && [ -d "$FLYOLOGY_ROOT/build/rts/adainclude" ]
then
  test_rts="$FLYOLOGY_ROOT/build/rts"
else
  printf '%s\n' \
    "Flyology QUIC tests require FLYOLOGY_QUIC_TEST_RTS; refusing the default RTS" \
    >&2
  exit 2
fi

runtime_marker="$test_rts/adainclude/s-fldeex.ads"
if [ ! -f "$runtime_marker" ] \
  || ! grep -q 'package System.Flyology.Default_Execution is' "$runtime_marker"
then
  printf '%s\n' \
    "Flyology QUIC tests require a Flyology custom RTS; refusing $test_rts" \
    >&2
  exit 2
fi

run_gprbuild () {
  if [ "$(uname -s)" = Darwin ]; then
    compiler_sysroot=$(alr exec -- gcc -print-sysroot)
    if [ -z "$compiler_sysroot" ] || [ ! -d "$compiler_sysroot" ]; then
      current_sysroot=$(xcrun --sdk macosx --show-sdk-path)
      alr exec -- env -u GPR_CONFIG gprbuild "$@" \
        -largs "-Wl,-syslibroot,$current_sysroot" -nodefaultrpaths
      return
    fi
    alr exec -- env -u GPR_CONFIG gprbuild "$@" \
      -largs -nodefaultrpaths
    return
  fi
  alr exec -- env -u GPR_CONFIG gprbuild "$@"
}

cd "$crate_root/tests"
alr build --stop-after=generation
run_gprbuild --RTS="$test_rts" -f -p -j0 -P flyology_quic_tests.gpr

for test in \
  flyology-quic-ack_frame_policy-smoke \
  flyology-quic-ack_range_policy-smoke \
  flyology-quic-application_connection-smoke \
  flyology-quic-application_space-batch_smoke \
  flyology-quic-application_space-smoke \
  flyology-quic-application_frame_policy-smoke \
  flyology-quic-connection_state_policy-smoke \
  flyology-quic-connection_driver-smoke \
  flyology-quic-crypto_frame_policy-smoke \
  flyology-quic-crypto_openssl-smoke \
  flyology-quic-crypto_reassembly_policy-smoke \
  flyology-quic-flow_control_policy-smoke \
  flyology-quic-handshake_connection-smoke \
  flyology-quic-handshake_packet_policy-smoke \
  flyology-quic-handshake_sender-smoke \
  flyology-quic-handshake_space-smoke \
  flyology-quic-initial_frame_policy-smoke \
  flyology-quic-initial_connection-smoke \
  flyology-quic-initial_receiver-smoke \
  flyology-quic-initial_sender-smoke \
  flyology-quic-initial_space-smoke \
  flyology-quic-initial_packet_policy-smoke \
  flyology-quic-long_header_policy-smoke \
  flyology-quic-one_rtt_packet_policy-smoke \
  flyology-quic-one_rtt_sender-smoke \
  flyology-quic-packet_number_policy-smoke \
  flyology-quic-protection_policy-smoke \
  flyology-quic-receive_flow_control_policy-smoke \
  flyology-quic-recovery_policy-smoke \
  flyology-quic-sent_packet_policy-smoke \
  flyology-quic-stream_frame_policy-smoke \
  flyology-quic-stream_id_policy-smoke \
  flyology-quic-stream_reassembly_policy-smoke \
  flyology-quic-stream_table_policy-smoke \
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
