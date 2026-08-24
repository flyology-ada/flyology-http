#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
environment="$http_root/build/http-client-differential"
python="$environment/bin/python"
command=${1:-run}

prepare () {
  python3 -m venv "$environment"
  "$environment/bin/pip" install \
    -r "$http_root/tests/requirements-client-differential.txt"
}

build_driver () {
  alr=$("$http_root/scripts/find-alr.sh")
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$http_root/build/rts" --subdirs=http-client-differential -p \
    -P "$http_root/tests/http_tests.gpr" \
    http_client_differential_client.adb
}

run_fixture () {
  protocol=$1
  fixture=$2
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http-differential.XXXXXX")
  port_file="$run_dir/port"
  log_file="$run_dir/requests.jsonl"
  peer_pid=
  cleanup_fixture () {
    if [ -n "$peer_pid" ]; then
      kill "$peer_pid" 2>/dev/null || :
      wait "$peer_pid" 2>/dev/null || :
    fi
    rm -rf "$run_dir"
  }
  trap cleanup_fixture EXIT HUP INT TERM
  "$python" "$http_root/tests/http_client_differential_peer.py" \
    "$fixture" --protocol "$protocol" --count 5 \
    --port-file "$port_file" --log-file "$log_file" &
  peer_pid=$!
  ready=false
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$port_file" ]; then
      ready=true
      break
    fi
    sleep 0.1
  done
  if [ "$ready" != true ]; then
    kill "$peer_pid" 2>/dev/null || :
    wait "$peer_pid" 2>/dev/null || :
    rm -rf "$run_dir"
    printf '%s\n' "HTTP client differential peer did not start" >&2
    exit 1
  fi
  port=$(tr -d '\r\n' <"$port_file")
  url="http://127.0.0.1:$port/"

  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    sync native "$protocol" "$url" >"$run_dir/ada-sync"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped native "$protocol" "$url" >"$run_dir/ada-scoped-native"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped lightweight "$protocol" "$url" >"$run_dir/ada-scoped-lightweight"
  "$python" "$http_root/tests/http_client_pycurl.py" easy "$protocol" "$url" \
    >"$run_dir/pycurl-easy"
  "$python" "$http_root/tests/http_client_pycurl.py" multi "$protocol" "$url" \
    >"$run_dir/pycurl-multi"
  wait "$peer_pid"
  peer_pid=

  "$python" -c '
import pathlib, sys
root = pathlib.Path(sys.argv[1])
names = ("ada-sync", "ada-scoped-native", "ada-scoped-lightweight", "pycurl-easy", "pycurl-multi")
def normalized(name):
    lines = root.joinpath(name).read_text().splitlines()
    return sorted(line for line in lines if line.startswith(("status=", "protocol=", "body_hex=", "header=", "trailer=")))
observed = {name: normalized(name) for name in names}
golden = observed[names[0]]
for name in names[1:]:
    assert observed[name] == golden, (name, golden, observed[name])
requests = [line for line in root.joinpath("requests.jsonl").read_text().splitlines() if line]
assert len(requests) == len(names), requests
' "$run_dir"
  rm -rf "$run_dir"
  trap - EXIT HUP INT TERM
  printf '%s\n' "HTTP client PycURL differential: PASS $protocol/$fixture"
}

run_lost_fixture () {
  protocol=$1
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http-lost-response.XXXXXX")
  port_file="$run_dir/port"
  log_file="$run_dir/requests.jsonl"
  peer_pid=
  cleanup_lost_fixture () {
    if [ -n "$peer_pid" ]; then
      kill "$peer_pid" 2>/dev/null || :
      wait "$peer_pid" 2>/dev/null || :
    fi
    rm -rf "$run_dir"
  }
  trap cleanup_lost_fixture EXIT HUP INT TERM
  "$python" "$http_root/tests/http_client_differential_peer.py" \
    lost-final-response --protocol "$protocol" --count 3 --linger 0.75 \
    --port-file "$port_file" --log-file "$log_file" &
  peer_pid=$!
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$port_file" ]; then
      break
    fi
    sleep 0.1
  done
  if [ ! -s "$port_file" ]; then
    printf '%s\n' "HTTP lost-response peer did not start" >&2
    exit 1
  fi
  port=$(tr -d '\r\n' <"$port_file")
  url="http://127.0.0.1:$port/"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    sync-lost native "$protocol" "$url" >"$run_dir/ada-sync"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped-lost native "$protocol" "$url" >"$run_dir/ada-scoped-native"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped-lost lightweight "$protocol" "$url" \
    >"$run_dir/ada-scoped-lightweight"
  wait "$peer_pid"
  peer_pid=
  "$python" -c '
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
records = [json.loads(line) for line in root.joinpath("requests.jsonl").read_text().splitlines() if line]
assert len(records) == 3, records
for record in records:
    assert record["request"] == "PUT /immutable-commit HTTP/" + sys.argv[2], record
    assert record["if_none_match"] == "*", record
    assert bytes.fromhex(record["body_hex"]) == b"immutable-commit-bytes", record
assert root.joinpath("ada-sync").read_text().splitlines() == ["outcome=failed"]
for name in ("ada-scoped-native", "ada-scoped-lightweight"):
    lines = root.joinpath(name).read_text().splitlines()
    assert "admission=POSSIBLY_ADMITTED" in lines, (name, lines)
    assert "body_length=0" in lines, (name, lines)
' "$run_dir" "$(if [ "$protocol" = h1 ]; then printf 1.1; else printf 2; fi)"
  rm -rf "$run_dir"
  trap - EXIT HUP INT TERM
  printf '%s\n' "HTTP client lost-final-response oracle: PASS $protocol"
}

run_h3_fixture () {
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http-differential-h3.XXXXXX")
  peer_log="$run_dir/peer.log"
  peer_pid=
  cleanup_h3_fixture () {
    if [ -n "$peer_pid" ]; then
      kill "$peer_pid" 2>/dev/null || :
      wait "$peer_pid" 2>/dev/null || :
    fi
    rm -rf "$run_dir"
  }
  trap cleanup_h3_fixture EXIT HUP INT TERM
  "$python" "$http_root/tests/oracle/aioquic_h3_server.py" \
    --port 0 --corpus >"$peer_log" 2>&1 &
  peer_pid=$!
  port=
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if grep -q 'aioquic HTTP/3 oracle listening' "$peer_log"; then
      port=$(sed -n \
        's/^aioquic HTTP\/3 oracle listening on 127\.0\.0\.1:\([0-9][0-9]*\) .*/\1/p' \
        "$peer_log" | tail -n 1)
      break
    fi
    if ! kill -0 "$peer_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [ -z "$port" ]; then
    sed -n '1,200p' "$peer_log" >&2
    exit 1
  fi
  url="https://127.0.0.1:$port/"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    sync native h3 "$url" >"$run_dir/ada-sync"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped native h3 "$url" >"$run_dir/ada-scoped-native"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped lightweight h3 "$url" >"$run_dir/ada-scoped-lightweight"
  "$python" -c '
import pathlib, sys
root = pathlib.Path(sys.argv[1])
names = ("ada-sync", "ada-scoped-native", "ada-scoped-lightweight")
def normalized(name):
    lines = root.joinpath(name).read_text().splitlines()
    return sorted(line for line in lines if line.startswith(("status=", "protocol=", "body_hex=", "header=", "trailer=")))
observed = {name: normalized(name) for name in names}
golden = observed[names[0]]
for name in names[1:]:
    assert observed[name] == golden, (name, golden, observed[name])
assert golden == sorted((
    "status=200",
    "protocol=h3",
    "body_hex=636f727075732d66697865642d626f6479",
    "header=x-corpus-value:alpha",
    "header=x-corpus-value:beta",
)), golden
' "$run_dir"
  cleanup_h3_fixture
  peer_pid=
  trap - EXIT HUP INT TERM
  printf '%s\n' "HTTP client aioquic differential: PASS h3/fixed-200"
}

run_h3_lost_fixture () {
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http-lost-response-h3.XXXXXX")
  peer_log="$run_dir/peer.log"
  request_log="$run_dir/requests.jsonl"
  peer_pid=
  cleanup_h3_lost_fixture () {
    if [ -n "$peer_pid" ]; then
      kill "$peer_pid" 2>/dev/null || :
      wait "$peer_pid" 2>/dev/null || :
    fi
    rm -rf "$run_dir"
  }
  trap cleanup_h3_lost_fixture EXIT HUP INT TERM
  "$python" "$http_root/tests/oracle/aioquic_h3_server.py" \
    --port 0 --lost-response --log-file "$request_log" \
    >"$peer_log" 2>&1 &
  peer_pid=$!
  port=
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if grep -q 'aioquic HTTP/3 oracle listening' "$peer_log"; then
      port=$(sed -n \
        's/^aioquic HTTP\/3 oracle listening on 127\.0\.0\.1:\([0-9][0-9]*\) .*/\1/p' \
        "$peer_log" | tail -n 1)
      break
    fi
    if ! kill -0 "$peer_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [ -z "$port" ]; then
    sed -n '1,200p' "$peer_log" >&2
    exit 1
  fi
  url="https://127.0.0.1:$port/"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    sync-lost native h3 "$url" >"$run_dir/ada-sync"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped-lost native h3 "$url" >"$run_dir/ada-scoped-native"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped-lost lightweight h3 "$url" >"$run_dir/ada-scoped-lightweight"
  sleep 0.5
  "$python" -c '
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
records = [json.loads(line) for line in root.joinpath("requests.jsonl").read_text().splitlines() if line]
assert len(records) == 3, records
for record in records:
    assert record["request"] == "PUT /immutable-commit HTTP/3", record
    assert record["if_none_match"] == "*", record
    assert bytes.fromhex(record["body_hex"]) == b"immutable-commit-bytes", record
assert root.joinpath("ada-sync").read_text().splitlines() == ["outcome=failed"]
for name in ("ada-scoped-native", "ada-scoped-lightweight"):
    lines = root.joinpath(name).read_text().splitlines()
    assert "admission=POSSIBLY_ADMITTED" in lines, (name, lines)
    assert "body_length=0" in lines, (name, lines)
' "$run_dir"
  cleanup_h3_lost_fixture
  peer_pid=
  trap - EXIT HUP INT TERM
  printf '%s\n' "HTTP client lost-final-response oracle: PASS h3"
}

run_h3_malformed_fixture () {
  scenario=$1
  model=$2
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http-malformed-h3.XXXXXX")
  peer_log="$run_dir/peer.log"
  peer_pid=
  cleanup_h3_malformed_fixture () {
    if [ -n "$peer_pid" ]; then
      kill "$peer_pid" 2>/dev/null || :
      wait "$peer_pid" 2>/dev/null || :
    fi
    rm -rf "$run_dir"
  }
  trap cleanup_h3_malformed_fixture EXIT HUP INT TERM
  "$python" "$http_root/tests/oracle/aioquic_h3_server.py" \
    --port 0 --malformed-response "$scenario" >"$peer_log" 2>&1 &
  peer_pid=$!
  port=
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if grep -q 'aioquic HTTP/3 oracle listening' "$peer_log"; then
      port=$(sed -n \
        's/^aioquic HTTP\/3 oracle listening on 127\.0\.0\.1:\([0-9][0-9]*\) .*/\1/p' \
        "$peer_log" | tail -n 1)
      break
    fi
    if ! kill -0 "$peer_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [ -z "$port" ]; then
    sed -n '1,200p' "$peer_log" >&2
    exit 1
  fi
  url="https://127.0.0.1:$port/"
  "$http_root/tests/bin/http-client-differential/http_client_differential_client" \
    scoped-h3-isolation "$model" h3 "$url" >"$run_dir/ada"
  grep -qx 'outcome=isolated' "$run_dir/ada"
  cleanup_h3_malformed_fixture
  peer_pid=
  trap - EXIT HUP INT TERM
  printf '%s\n' \
    "HTTP client aioquic malformed-response: PASS h3/$scenario/$model"
}

case "$command" in
  prepare)
    prepare
    ;;
  run)
    if [ ! -x "$python" ]; then
      printf '%s\n' \
        "PycURL environment unavailable; run: ./scripts/http-client-differential.sh prepare" >&2
      exit 2
    fi
    build_driver
    printf '%s\n' "$($python -c 'import pycurl; print(pycurl.version)')"
    protocols=h1
    if "$python" -c \
      'import pycurl; raise SystemExit(0 if pycurl.version_info()[4] & pycurl.VERSION_HTTP2 else 1)'
    then
      protocols="h1 h2"
    fi
    for protocol in $protocols; do
      for fixture in fixed-200 status-204 zero-200 informational-final; do
        run_fixture "$protocol" "$fixture"
      done
      run_lost_fixture "$protocol"
    done
    run_h3_fixture
    run_h3_lost_fixture
    for scenario in \
      pseudo-after-field connection-specific-field status-101
    do
      for model in native lightweight; do
        run_h3_malformed_fixture "$scenario" "$model"
      done
    done
    ;;
  *)
    printf '%s\n' "usage: $0 {prepare|run}" >&2
    exit 2
    ;;
esac
