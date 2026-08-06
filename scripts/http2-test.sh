#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
environment="$http_root/build/http2-tester"
python="$environment/bin/python"
command=${1:-all}

require_tester () {
  if [ ! -x "$python" ]; then
    printf '%s\n' \
      "HTTP/2 tester is unavailable; run: ./scripts/http2-test.sh prepare" >&2
    exit 2
  fi
}

build_test () {
  main=$1
  subdir=$2
  alr=$("$http_root/scripts/find-alr.sh")
  "$alr" exec -- env -u GPR_CONFIG gprbuild \
    --RTS="$http_root/build/rts" \
    --subdirs="$subdir" -p \
    -P "$http_root/tests/http_tests.gpr" "$main.adb"
}

run_codecs () {
  require_tester
  build_test flyology-http-http_2_hpack-differential http2-differential
  PYTHONDONTWRITEBYTECODE=1 "$python" \
    "$http_root/tests/http2_hpack_differential.py" \
    "$http_root/tests/bin/http2-differential/flyology-http-http_2_hpack-differential"
}

run_client () {
  require_tester
  build_test http2_client_integration http2-integration
  for model in native lightweight; do
    for scenario in basic prior fallback require-failure multiplex continuation peer-capacity flow upload early-final reset-race zero-read bad-preface informational-end flood shutdown-race goaway refused refused-post; do
      run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http2.XXXXXX")
      port_file="$run_dir/port"
      log_file="$run_dir/events.jsonl"
      cleartext=
      scheme=https
      if [ "$scenario" = prior ]; then
        cleartext=--cleartext
        scheme=http
      fi
      "$python" "$http_root/tests/http2_peer.py" "$scenario" \
        --certificate "$http_root/tests/fixtures/tls/server-cert.pem" \
        --private-key "$http_root/tests/fixtures/tls/server-key.pem" \
        --port-file "$port_file" --log-file "$log_file" $cleartext &
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
        printf '%s\n' "HTTP/2 peer did not become ready" >&2
        exit 1
      fi
      port=$(tr -d '\r\n' <"$port_file")
      if ! FLYOLOGY_HTTP2_TEST_ORIGIN="$scheme://localhost:$port" \
        FLYOLOGY_HTTP2_TEST_SCENARIO="$scenario" \
        FLYOLOGY_HTTP2_TEST_MODEL="$model" \
        FLYOLOGY_HTTP2_TEST_CA="$http_root/tests/fixtures/tls/server-cert.pem" \
        "$http_root/tests/bin/http2-integration/http2_client_integration"
      then
        kill "$peer_pid" 2>/dev/null || :
        wait "$peer_pid" 2>/dev/null || :
        printf '%s\n' "HTTP/2 peer log ($model/$scenario):" >&2
        sed -n '1,120p' "$log_file" >&2
        exit 1
      fi
      wait "$peer_pid"
      case "$scenario" in
        multiplex|continuation|peer-capacity|reset-race|goaway|refused) expected_requests=2 ;;
        require-failure|bad-preface) expected_requests=0 ;;
        *) expected_requests=1 ;;
      esac
      PYTHONDONTWRITEBYTECODE=1 "$python" -c \
        'import json,sys; events=[json.loads(x) for x in open(sys.argv[1])]; connected=[e for e in events if e["event"]=="connected"]; assert connected; assert sys.argv[3] in ("fallback","require-failure") or connected[0]["alpn"] in ("h2","h2c"); assert sum(e["event"]=="request" for e in events)==int(sys.argv[2])' \
        "$log_file" "$expected_requests" "$scenario"
      if [ "$scenario" = reset-race ]; then
        PYTHONDONTWRITEBYTECODE=1 "$python" -c \
          'import json,sys; events=[json.loads(x) for x in open(sys.argv[1])]; assert sum(e["event"]=="connected" for e in events)==1; assert any(e["event"]=="late-data" for e in events)' \
          "$log_file"
      fi
      if [ "$scenario" = early-final ]; then
        PYTHONDONTWRITEBYTECODE=1 "$python" -c \
          'import json,sys; events=[json.loads(x) for x in open(sys.argv[1])]; assert any(e["event"]=="client-reset" for e in events)' \
          "$log_file"
      fi
      if [ "$scenario" = upload ]; then
        PYTHONDONTWRITEBYTECODE=1 "$python" -c \
          'import json,sys; events=[json.loads(x) for x in open(sys.argv[1])]; assert any(e["event"]=="request-body" and e["bytes"]==256*1024 for e in events)' \
          "$log_file"
      fi
      rm -rf "$run_dir"
      printf '%s\n' "HTTP/2 client: PASS $model/$scenario"
    done
  done
}

case "$command" in
  prepare)
    python3 -m venv "$environment"
    "$environment/bin/pip" install \
      -r "$http_root/tests/requirements-http2.txt"
    ;;
  codecs)
    if [ ! -d "$http_root/build/rts/adalib" ]; then
      printf '%s\n' \
        "prepared test runtime is unavailable; run: ./scripts/test.sh" >&2
      exit 2
    fi
    run_codecs
    ;;
  client)
    run_client
    ;;
  all)
    run_codecs
    run_client
    ;;
  *)
    printf '%s\n' "usage: $0 {prepare|codecs|client|all}" >&2
    exit 2
    ;;
esac
