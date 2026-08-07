#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")

"$http_root/flyology_quic/scripts/prove.sh"

cd "$http_root/proof"
"$alr" build --stop-after=generation
"$alr" gnatprove \
  -P "$http_root/flyology_http.gpr" \
  --mode=all \
  --level=1 \
  -j0 \
  --output=oneline \
  --output-header \
  --checks-as-errors=on \
  --report=all \
  -f \
  -u \
  flyology-rate_limit_policy.adb \
  flyology-http_chunk_encoding.adb \
  flyology-websocket_policy.adb \
  flyology-websocket_client_policy.adb \
  flyology-http-decoded_path_policy.adb \
  flyology-http-expect_policy.adb \
  flyology-http-client_policy.adb \
  flyology-http-http_2_policy.adb \
  flyology-http-http_3_control_policy.adb \
  flyology-http-http_3_frame_policy.adb \
  flyology-http-http_3_header_policy.adb \
  flyology-http-http_3_message_policy.adb \
  flyology-http-http_3_settings_policy.adb \
  flyology-http-http_3_stream_policy.adb \
  flyology-http-qpack_field_section_policy.adb \
  flyology-http-qpack_integer_policy.adb \
  flyology-http-qpack_static_table.adb \
  flyology-http-route_parameter_policy.adb \
  flyology-websocket_deflate_policy.adb

printf '%s\n' "Flyology HTTP SPARK proof suite passed"
