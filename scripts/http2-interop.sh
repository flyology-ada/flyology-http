#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
environment="$http_root/build/http2-tester"
python="$environment/bin/python"
certificate="$http_root/tests/fixtures/tls/server-cert.pem"
private_key="$http_root/tests/fixtures/tls/server-key.pem"
command=${1:-all}
server_pid=
proxy_pid=
work_dir=

cleanup () {
  if [ -n "$proxy_pid" ]; then
    kill "$proxy_pid" 2>/dev/null || :
    wait "$proxy_pid" 2>/dev/null || :
  fi
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || :
    wait "$server_pid" 2>/dev/null || :
  fi
  if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
    rm -rf "$work_dir"
  fi
}
trap cleanup EXIT HUP INT TERM

require_tools () {
  if [ ! -x "$python" ]; then
    printf '%s\n' \
      "HTTP/2 tester is unavailable; run: ./scripts/http2-test.sh prepare" >&2
    exit 2
  fi
  if [ ! -d "$http_root/build/rts/adalib" ]; then
    printf '%s\n' \
      "prepared test runtime is unavailable; run: ./scripts/test.sh" >&2
    exit 2
  fi
  for tool in go node; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      printf '%s\n' "$tool is required for HTTP/2 interoperability" >&2
      exit 2
    fi
  done
}

find_nghttpd () {
  if [ -n "${HTTP2_NGHTTPD:-}" ] && [ -x "$HTTP2_NGHTTPD" ]; then
    nghttpd=$HTTP2_NGHTTPD
  elif command -v nghttpd >/dev/null 2>&1; then
    nghttpd=$(command -v nghttpd)
  elif [ -x /opt/homebrew/opt/nghttp2/bin/nghttpd ]; then
    nghttpd=/opt/homebrew/opt/nghttp2/bin/nghttpd
  elif [ -x /usr/local/opt/nghttp2/bin/nghttpd ]; then
    nghttpd=/usr/local/opt/nghttp2/bin/nghttpd
  else
    printf '%s\n' \
      "nghttpd is required; install nghttp2-server or Homebrew nghttp2" >&2
    exit 2
  fi
}

build_clients () {
  alr=$("$http_root/scripts/find-alr.sh")
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$http_root/build/rts" --subdirs=http2-qualification -p \
    -P "$http_root/tests/http_tests.gpr" http2_interop_client.adb
  go build -o "$work_dir/http2-go-peer" \
    "$http_root/tests/interop/http2_go_peer.go"
  node --check "$http_root/tests/interop/http2_node_peer.js"
  PYTHONDONTWRITEBYTECODE=1 "$python" -c \
    'compile(open(__import__("sys").argv[1], encoding="utf-8").read(), __import__("sys").argv[1], "exec")' \
    "$http_root/tests/http2_fault_proxy.py"
}

wait_for_port_file () {
  port_file=$1
  ready=false
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [ -s "$port_file" ]; then
      ready=true
      break
    fi
    sleep 0.1
  done
  if [ "$ready" != true ]; then
    printf '%s\n' "HTTP/2 interoperability peer did not become ready" >&2
    exit 1
  fi
}

wait_for_tcp () {
  port=$1
  ready=false
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if "$python" -c \
      'import socket,sys; channel=socket.create_connection(("127.0.0.1",int(sys.argv[1])),.2); channel.close()' \
      "$port" 2>/dev/null
    then
      ready=true
      break
    fi
    sleep 0.1
  done
  if [ "$ready" != true ]; then
    printf '%s\n' "HTTP/2 interoperability peer did not accept TCP" >&2
    exit 1
  fi
}

run_client () {
  peer=$1
  port=$2
  model=$3
  quick=${4:-false}
  FLYOLOGY_HTTP2_INTEROP_ORIGIN="https://localhost:$port" \
  FLYOLOGY_HTTP2_INTEROP_CA="$certificate" \
  FLYOLOGY_HTTP2_INTEROP_PEER="$peer" \
  FLYOLOGY_HTTP2_INTEROP_MODEL="$model" \
  FLYOLOGY_HTTP2_INTEROP_QUICK="$quick" \
    "$http_root/tests/bin/http2-qualification/http2_interop_client"
}

stop_server () {
  kill "$server_pid" 2>/dev/null || :
  wait "$server_pid" 2>/dev/null || :
  server_pid=
}

run_go () {
  port_file="$work_dir/go.port"
  "$work_dir/http2-go-peer" \
    --certificate "$certificate" --private-key "$private_key" \
    --port-file "$port_file" >"$work_dir/go.log" 2>&1 &
  server_pid=$!
  wait_for_port_file "$port_file"
  port=$(tr -d '\r\n' <"$port_file")
  for model in native lightweight; do
    run_client go "$port" "$model"
    printf '%s\n' "HTTP/2 interop: PASS go/$model"
  done
  stop_server
}

run_node () {
  port_file="$work_dir/node.port"
  node "$http_root/tests/interop/http2_node_peer.js" \
    --certificate "$certificate" --private-key "$private_key" \
    --port-file "$port_file" >"$work_dir/node.log" 2>&1 &
  server_pid=$!
  wait_for_port_file "$port_file"
  port=$(tr -d '\r\n' <"$port_file")
  for model in native lightweight; do
    run_client node "$port" "$model"
    printf '%s\n' "HTTP/2 interop: PASS node/$model"
  done
  stop_server
}

prepare_nghttpd_files () {
  htdocs="$work_dir/nghttpd-files"
  mkdir -p "$htdocs"
  PYTHONDONTWRITEBYTECODE=1 "$python" -c \
    'from pathlib import Path; import sys; root=Path(sys.argv[1]); root.joinpath("small").write_bytes(b"flyology-http2-interop"); root.joinpath("first").write_bytes(b"first"); root.joinpath("second").write_bytes(b"second"); root.joinpath("echo").write_bytes(b""); root.joinpath("large").write_bytes(bytes(ord("a")+i%26 for i in range(256*1024)))' \
    "$htdocs"
}

run_nghttpd () {
  find_nghttpd
  prepare_nghttpd_files
  port=$("$python" -c \
    'import socket; channel=socket.socket(); channel.bind(("127.0.0.1",0)); print(channel.getsockname()[1]); channel.close()')
  "$nghttpd" --echo-upload --address=127.0.0.1 \
    --htdocs="$htdocs" "$port" "$private_key" "$certificate" \
    >"$work_dir/nghttpd.log" 2>&1 &
  server_pid=$!
  wait_for_tcp "$port"
  for model in native lightweight; do
    run_client "" "$port" "$model"
    printf '%s\n' "HTTP/2 interop: PASS nghttpd/$model"
  done
  stop_server
}

start_go_for_faults () {
  port_file="$work_dir/fault-go.port"
  "$work_dir/http2-go-peer" \
    --certificate "$certificate" --private-key "$private_key" \
    --port-file "$port_file" >"$work_dir/fault-go.log" 2>&1 &
  server_pid=$!
  wait_for_port_file "$port_file"
  upstream_port=$(tr -d '\r\n' <"$port_file")
}

run_fault () {
  name=$1
  chunk_size=$2
  delay_ms=$3
  reset_bytes=$4
  quick=$5
  expect_success=$6
  port_file="$work_dir/proxy-$name.port"
  log_file="$work_dir/proxy-$name.jsonl"
  client_log="$work_dir/client-$name.log"
  "$python" "$http_root/tests/http2_fault_proxy.py" \
    --upstream-port "$upstream_port" --port-file "$port_file" \
    --log-file "$log_file" --chunk-size "$chunk_size" \
    --delay-ms "$delay_ms" --reset-after-server-bytes "$reset_bytes" &
  proxy_pid=$!
  wait_for_port_file "$port_file"
  port=$(tr -d '\r\n' <"$port_file")
  if FLYOLOGY_HTTP2_INTEROP_ORIGIN="https://localhost:$port" \
    FLYOLOGY_HTTP2_INTEROP_CA="$certificate" \
    FLYOLOGY_HTTP2_INTEROP_PEER=go \
    FLYOLOGY_HTTP2_INTEROP_MODEL=native \
    FLYOLOGY_HTTP2_INTEROP_QUICK="$quick" \
    FLYOLOGY_HTTP2_INTEROP_NO_WARM=true \
      "$http_root/scripts/run-with-timeout.sh" 60 \
      "$http_root/tests/bin/http2-qualification/http2_interop_client" \
      >"$client_log" 2>&1
  then
    result=success
  else
    result=failure
  fi
  wait "$proxy_pid" 2>/dev/null || :
  proxy_pid=
  if [ "$result" != "$expect_success" ]; then
    printf '%s\n' "HTTP/2 fault campaign $name: unexpected $result" >&2
    sed -n '1,120p' "$client_log" >&2
    sed -n '1,120p' "$log_file" >&2
    exit 1
  fi
  if [ "$reset_bytes" -gt 0 ]; then
    grep -q '"event": "reset"' "$log_file"
  else
    sed -n '1,120p' "$client_log"
  fi
  printf '%s\n' "HTTP/2 fault campaign: PASS $name ($result)"
}

run_interop () {
  run_go
  run_node
  run_nghttpd
}

run_faults () {
  start_go_for_faults
  run_fault one-byte 1 0 0 true success
  run_fault delayed-slices 257 1 0 false success
  run_fault mid-response-reset 4096 0 32768 false failure
  stop_server
}

require_tools
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http2-interop.XXXXXX")
build_clients

case "$command" in
  interop) run_interop ;;
  faults) run_faults ;;
  all)
    run_interop
    run_faults
    ;;
  *)
    printf '%s\n' "usage: $0 {interop|faults|all}" >&2
    exit 2
    ;;
esac
