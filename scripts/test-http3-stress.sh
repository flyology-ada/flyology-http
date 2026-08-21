#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")
port=${FLYOLOGY_HTTP3_STRESS_PORT:-4438}
oracle_port=${FLYOLOGY_HTTP3_CLIENT_STRESS_PORT:-4439}
peak_concurrency=${FLYOLOGY_HTTP3_STRESS_PEAK_CONCURRENCY:-256}
client_workers=${FLYOLOGY_HTTP3_CLIENT_STRESS_WORKERS:-256}
client_requests=${FLYOLOGY_HTTP3_CLIENT_STRESS_REQUESTS:-4}
loop_pool_size=${FLYOLOGY_HTTP3_STRESS_LOOP_POOL_SIZE:-16}
stress_rts="$http_root/build/http3-stress-rts"
oracle_venv="$http_root/build/oracle/aioquic"
oracle_python=${FLYOLOGY_HTTP3_ORACLE_PYTHON:-$oracle_venv/bin/python}
flyology_root=

require_positive () {
  name=$1
  value=$2
  case "$value" in
    ''|*[!0-9]*)
      printf '%s\n' "$name must be a positive integer" >&2
      exit 2
      ;;
  esac
  if [ "$value" -lt 1 ]; then
    printf '%s\n' "$name must be a positive integer" >&2
    exit 2
  fi
}

require_positive FLYOLOGY_HTTP3_STRESS_PEAK_CONCURRENCY "$peak_concurrency"
require_positive FLYOLOGY_HTTP3_CLIENT_STRESS_WORKERS "$client_workers"
require_positive FLYOLOGY_HTTP3_CLIENT_STRESS_REQUESTS "$client_requests"
require_positive FLYOLOGY_HTTP3_STRESS_LOOP_POOL_SIZE "$loop_pool_size"
if [ "$peak_concurrency" -gt 256 ] || [ "$client_workers" -gt 256 ]; then
  printf '%s\n' 'HTTP/3 stress concurrency cannot exceed 256' >&2
  exit 2
fi
if [ "$loop_pool_size" -gt 128 ]; then
  printf '%s\n' 'HTTP/3 stress loop pool cannot exceed 128' >&2
  exit 2
fi

prepare_stress_rts () {
  flyology_root=$("$http_root/scripts/resolve-flyology-root.sh")

  "$alr" exec -- env \
    FLYOLOGY_RTS_DIR="$stress_rts" \
    FLYOLOGY_DEFAULT=lightweight \
    FLYOLOGY_LOOP_POOL_SIZE="$loop_pool_size" \
    "$flyology_root/scripts/prepare-rts.sh" >/dev/null

  if [ ! -f "$stress_rts/.flyology-rts-root" ] \
    || ! grep -q 'Flyology prepared RTS version' \
      "$stress_rts/.flyology-rts-root" \
    || ! grep -q 'Lightweight : constant Boolean := True;' \
      "$stress_rts/adainclude/s-fldeex.ads"
  then
    printf '%s\n' \
      'HTTP/3 stress RTS is not a prepared Flyology lightweight RTS' >&2
    exit 2
  fi
}

mkdir -p "$http_root/build/oracle"
if [ ! -x "$oracle_python" ]; then
  python3 -m venv "$oracle_venv"
fi
if ! "$oracle_python" -c 'import aioquic' >/dev/null 2>&1; then
  "$oracle_venv/bin/pip" install -r "$http_root/tests/oracle/requirements.txt"
fi

cd "$http_root"
prepare_stress_rts
"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$stress_rts" --subdirs=http3-stress -p \
  -P tests/http_tests.gpr \
  http3_stress_runtime_probe.adb http3_h3spec_server.adb \
  http3_client_stress_probe.adb
"$http_root/tests/bin/http3-stress/http3_stress_runtime_probe" \
  "$loop_pool_size"

server_pid=
cleanup () {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || :
    wait "$server_pid" 2>/dev/null || :
  fi
}
trap cleanup EXIT HUP INT TERM

await_ready () {
  process=$1
  log_file=$2
  marker=$3
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    if grep -q "$marker" "$log_file"; then
      return 0
    fi
    if ! kill -0 "$process" 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  sed -n '1,200p' "$log_file" >&2
  return 1
}

server_log="$http_root/build/oracle/ada-h3-stress.log"
"$http_root/tests/bin/http3-stress/http3_h3spec_server" \
  "$port" "$peak_concurrency" "$loop_pool_size" 2.0 \
  >"$server_log" 2>&1 &
server_pid=$!
await_ready "$server_pid" "$server_log" 'Ada HTTP/3 h3spec server listening'
"$oracle_python" "$http_root/tests/oracle/aioquic_h3_stress.py" \
  --port "$port" --peak-concurrency "$peak_concurrency"
kill "$server_pid" 2>/dev/null || :
wait "$server_pid" 2>/dev/null || :
server_pid=

oracle_log="$http_root/build/oracle/aioquic-h3-stress-server.log"
"$oracle_python" "$http_root/tests/oracle/aioquic_h3_server.py" \
  --port "$oracle_port" >"$oracle_log" 2>&1 &
server_pid=$!
await_ready "$server_pid" "$oracle_log" 'aioquic HTTP/3 oracle listening'
"$http_root/tests/bin/http3-stress/http3_client_stress_probe" \
  "$client_workers" "$client_requests" "$oracle_port" "$loop_pool_size"

printf '%s\n' 'HTTP/3 stress: PASS hostile input, server churn, and client concurrency'
