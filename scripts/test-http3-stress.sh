#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")
port=${FLYOLOGY_HTTP3_STRESS_PORT:-4438}
oracle_port=${FLYOLOGY_HTTP3_CLIENT_STRESS_PORT:-4439}
oracle_venv="$http_root/build/oracle/aioquic"
oracle_python=${FLYOLOGY_HTTP3_ORACLE_PYTHON:-$oracle_venv/bin/python}

mkdir -p "$http_root/build/oracle"
if [ ! -x "$oracle_python" ]; then
  python3 -m venv "$oracle_venv"
fi
if ! "$oracle_python" -c 'import aioquic' >/dev/null 2>&1; then
  "$oracle_venv/bin/pip" install -r "$http_root/tests/oracle/requirements.txt"
fi

cd "$http_root"
"$alr" exec -- gprbuild -p -P tests/http_tests.gpr \
  http3_h3spec_server.adb http3_client_stress_probe.adb

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
"$http_root/tests/bin/http3_h3spec_server" "$port" >"$server_log" 2>&1 &
server_pid=$!
await_ready "$server_pid" "$server_log" 'Ada HTTP/3 h3spec server listening'
"$oracle_python" "$http_root/tests/oracle/aioquic_h3_stress.py" --port "$port"
kill "$server_pid" 2>/dev/null || :
wait "$server_pid" 2>/dev/null || :
server_pid=

oracle_log="$http_root/build/oracle/aioquic-h3-stress-server.log"
"$oracle_python" "$http_root/tests/oracle/aioquic_h3_server.py" \
  --port "$oracle_port" >"$oracle_log" 2>&1 &
server_pid=$!
await_ready "$server_pid" "$oracle_log" 'aioquic HTTP/3 oracle listening'
"$http_root/tests/bin/http3_client_stress_probe" 8 100 "$oracle_port"

printf '%s\n' 'HTTP/3 stress: PASS hostile input, server churn, and client concurrency'
