#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")
mode=${1:-all}
aioquic_server_port=${FLYOLOGY_HTTP3_AIOQUIC_SERVER_PORT:-4433}
ada_aioquic_port=${FLYOLOGY_HTTP3_ADA_AIOQUIC_PORT:-4434}
quic_go_server_port=${FLYOLOGY_HTTP3_QUIC_GO_SERVER_PORT:-4435}
ada_quic_go_port=${FLYOLOGY_HTTP3_ADA_QUIC_GO_PORT:-4436}
oracle_python=${FLYOLOGY_HTTP3_ORACLE_PYTHON:-}
qualification_rts="$http_root/build/http3-qualification-rts"

case "$mode" in
  aioquic|quic-go|all) ;;
  *)
    printf '%s\n' "usage: $0 {aioquic|quic-go|all}" >&2
    exit 2
    ;;
esac

mkdir -p "$http_root/build/oracle"

prepare_qualification_rts () {
  flyology_root=$("$http_root/scripts/resolve-flyology-root.sh")

  "$alr" exec -- env \
    FLYOLOGY_RTS_DIR="$qualification_rts" \
    FLYOLOGY_DEFAULT=lightweight \
    FLYOLOGY_LOOP_POOL_SIZE=1 \
    "$flyology_root/scripts/prepare-rts.sh" >/dev/null

  if [ ! -f "$qualification_rts/.flyology-rts-root" ] \
    || ! grep -q 'Flyology prepared RTS version' \
      "$qualification_rts/.flyology-rts-root" \
    || ! grep -q 'Lightweight : constant Boolean := True;' \
      "$qualification_rts/adainclude/s-fldeex.ads"
  then
    printf '%s\n' \
      'HTTP/3 qualification RTS is not a prepared Flyology lightweight RTS' >&2
    exit 2
  fi
}

prepare_aioquic () {
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
}

prepare_quic_go () {
  (
    cd "$http_root/tests/oracle/quic-go"
    go build -mod=readonly -trimpath \
      -o "$http_root/build/oracle/quic-go-h3" .
  )
}

cd "$http_root"
prepare_qualification_rts
"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$qualification_rts" -p -P tests/http_tests.gpr \
  http3_interop_client.adb http3_interop_server.adb

oracle_pid=
server_pid=
cleanup () {
  if [ -n "$oracle_pid" ]; then
    kill "$oracle_pid" 2>/dev/null || :
    wait "$oracle_pid" 2>/dev/null || :
  fi
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
  ready=false
  attempt=0
  while [ "$attempt" -lt 100 ]; do
    if grep -q "$marker" "$log_file"; then
      ready=true
      break
    fi
    if ! kill -0 "$process" 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
  done
  if [ "$ready" != true ]; then
    sed -n '1,200p' "$log_file" >&2
    return 1
  fi
}

run_aioquic () {
  prepare_aioquic
  oracle_log="$http_root/build/oracle/aioquic-h3-server.log"
  server_log="$http_root/build/oracle/ada-h3-aioquic.log"

  "$oracle_python" "$http_root/tests/oracle/aioquic_h3_server.py" \
    --port "$aioquic_server_port" >"$oracle_log" 2>&1 &
  oracle_pid=$!
  await_ready "$oracle_pid" "$oracle_log" \
    'aioquic HTTP/3 oracle listening'
  "$http_root/tests/bin/http3_interop_client" "$aioquic_server_port"
  kill "$oracle_pid" 2>/dev/null || :
  wait "$oracle_pid" 2>/dev/null || :
  oracle_pid=

  "$http_root/tests/bin/http3_interop_server" \
    "$ada_aioquic_port" >"$server_log" 2>&1 &
  server_pid=$!
  await_ready "$server_pid" "$server_log" \
    'Ada HTTP/3 routed server listening'
  if ! "$oracle_python" "$http_root/tests/oracle/aioquic_h3_client.py" \
    --port "$ada_aioquic_port"
  then
    sed -n '1,200p' "$server_log" >&2
    return 1
  fi
  if ! wait "$server_pid"; then
    sed -n '1,200p' "$server_log" >&2
    return 1
  fi
  server_pid=
  sed -n '1,200p' "$server_log"
  printf '%s\n' 'HTTP/3 qualification: PASS aioquic client and server roles'
}

run_quic_go () {
  prepare_quic_go
  oracle_log="$http_root/build/oracle/quic-go-h3-server.log"
  server_log="$http_root/build/oracle/ada-h3-quic-go.log"

  "$http_root/build/oracle/quic-go-h3" \
    --port "$quic_go_server_port" server >"$oracle_log" 2>&1 &
  oracle_pid=$!
  await_ready "$oracle_pid" "$oracle_log" \
    'quic-go HTTP/3 oracle listening'
  "$http_root/tests/bin/http3_interop_client" "$quic_go_server_port"
  kill "$oracle_pid" 2>/dev/null || :
  wait "$oracle_pid" 2>/dev/null || :
  oracle_pid=

  "$http_root/tests/bin/http3_interop_server" \
    "$ada_quic_go_port" >"$server_log" 2>&1 &
  server_pid=$!
  await_ready "$server_pid" "$server_log" \
    'Ada HTTP/3 routed server listening'
  if ! "$http_root/build/oracle/quic-go-h3" \
    --port "$ada_quic_go_port" client
  then
    sed -n '1,200p' "$server_log" >&2
    return 1
  fi
  if ! wait "$server_pid"; then
    sed -n '1,200p' "$server_log" >&2
    return 1
  fi
  server_pid=
  sed -n '1,200p' "$server_log"
  printf '%s\n' 'HTTP/3 qualification: PASS quic-go client and server roles'
}

case "$mode" in
  aioquic) run_aioquic ;;
  quic-go) run_quic_go ;;
  all)
    run_aioquic
    run_quic_go
    ;;
esac
