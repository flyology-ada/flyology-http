#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")
oracle_port=${FLYOLOGY_HTTP3_ORACLE_PORT:-4433}
oracle_python=${FLYOLOGY_HTTP3_ORACLE_PYTHON:-}

if [ -z "$oracle_python" ]; then
  oracle_venv="$http_root/build/oracle/aioquic"
  if [ ! -x "$oracle_venv/bin/python" ]; then
    python3 -m venv "$oracle_venv"
  fi
  oracle_python="$oracle_venv/bin/python"
  if ! "$oracle_python" -c 'import aioquic' >/dev/null 2>&1; then
    "$oracle_venv/bin/pip" install \
      -r "$http_root/tests/oracle/requirements.txt"
  fi
fi

cd "$http_root"
"$alr" exec -- gprbuild -p -P tests/http_tests.gpr \
  http3_interop_client.adb

mkdir -p "$http_root/build/oracle"
oracle_log="$http_root/build/oracle/aioquic-h3.log"
"$oracle_python" "$http_root/tests/oracle/aioquic_h3_server.py" \
  --port "$oracle_port" >"$oracle_log" 2>&1 &
oracle_pid=$!
cleanup () {
  kill "$oracle_pid" 2>/dev/null || :
  wait "$oracle_pid" 2>/dev/null || :
}
trap cleanup EXIT HUP INT TERM

ready=false
attempt=0
while [ "$attempt" -lt 50 ]; do
  if grep -q 'aioquic HTTP/3 oracle listening' "$oracle_log"; then
    ready=true
    break
  fi
  if ! kill -0 "$oracle_pid" 2>/dev/null; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
if [ "$ready" != true ]; then
  sed -n '1,200p' "$oracle_log" >&2
  exit 1
fi

"$http_root/tests/bin/http3_interop_client" \
  "$oracle_port"
