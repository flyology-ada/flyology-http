#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
environment="$http_root/build/http2-tester"
python="$environment/bin/python"
command=${1:-all}
h2specd_version=2.6.0
h2specd_sha256=c438130c70c6cec2c20276726a454a9249b64ba48ca89ce37f39aa721867b4f0
h2specd_root="$http_root/build/h2specd-$h2specd_version"
h2specd="$h2specd_root/h2specd"

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

build_showcase_client () {
  alr=$("$http_root/scripts/find-alr.sh")
  "$http_root/showcases/prepare-alire.sh" >/dev/null
  (
    cd "$http_root/showcases"
    "$alr" exec -- env -u GPR_CONFIG gprbuild \
      --RTS="$http_root/build/rts" \
      -P showcases.gpr http_client_cli.adb
  )
}

run_codecs () {
  require_tester
  build_test flyology-http-http_2_hpack-differential http2-differential
  PYTHONDONTWRITEBYTECODE=1 "$python" \
    "$http_root/tests/http2_hpack_differential.py" \
    "$http_root/tests/bin/http2-differential/flyology-http-http_2_hpack-differential"
  build_test flyology-http-header_huffman_policy-differential huffman-differential
  PYTHONDONTWRITEBYTECODE=1 "$python" \
    "$http_root/tests/header_huffman_differential.py" \
    "$http_root/tests/bin/huffman-differential/flyology-http-header_huffman_policy-differential"
}

run_client () {
  require_tester
  build_test http2_client_integration http2-integration
  scenarios=${FLYOLOGY_HTTP2_CLIENT_SCENARIOS:-"basic prior scoped scoped-tls scoped-parent scoped-cancel scoped-abandon scoped-source-early-final scoped-source-contract scoped-sink-contract scoped-stream-isolation fallback require-failure multiplex continuation peer-capacity stream-order flow upload early-final early-final-body head-empty-data reset-race zero-read bad-preface informational-end flood shutdown-race goaway refused refused-post"}
  models=${FLYOLOGY_HTTP2_CLIENT_MODELS:-"native lightweight"}
  for model in $models; do
    for scenario in $scenarios; do
      run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http2.XXXXXX")
      port_file="$run_dir/port"
      log_file="$run_dir/events.jsonl"
      cleartext=
      scheme=https
      if [ "$scenario" = prior ] || [ "$scenario" = scoped ] \
        || [ "$scenario" = early-final ] \
        || [ "$scenario" = early-final-body ] \
        || [ "$scenario" = scoped-source-early-final ] \
        || [ "$scenario" = scoped-source-contract ] \
        || [ "$scenario" = scoped-sink-contract ] \
        || [ "$scenario" = scoped-stream-isolation ]
      then
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
        scoped-source-contract) expected_requests=0 ;;
        multiplex|continuation|peer-capacity|stream-order|reset-race|goaway|refused|scoped-sink-contract|scoped-stream-isolation) expected_requests=2 ;;
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
      if [ "$scenario" = early-final ] \
        || [ "$scenario" = early-final-body ] \
        || [ "$scenario" = scoped-source-early-final ] \
        || [ "$scenario" = scoped-cancel ] \
        || [ "$scenario" = scoped-stream-isolation ]
      then
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

run_server_case () {
  server_transport=$1
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http2-server.XXXXXX")
  port_file="$run_dir/port"
  server_log="$run_dir/server.log"
  tls_option=
  if [ "$server_transport" = tls ]; then
    tls_option=--tls
  fi
  "$http_root/tests/bin/http2-server/http2_conformance_server" \
    "$port_file" "$server_transport" \
    "$http_root/tests/fixtures/tls/server-cert.pem" \
    "$http_root/tests/fixtures/tls/server-key.pem" \
    >"$server_log" 2>&1 &
  server_pid=$!
  ready=false
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if [ -s "$port_file" ]; then
      ready=true
      break
    fi
    sleep 0.1
  done
  if [ "$ready" != true ]; then
    kill "$server_pid" 2>/dev/null || :
    wait "$server_pid" 2>/dev/null || :
    sed -n '1,160p' "$server_log" >&2
    rm -rf "$run_dir"
    printf '%s\n' "HTTP/2 server did not become ready" >&2
    exit 1
  fi
  port=$(tr -d '\r\n' <"$port_file")
  if ! PYTHONDONTWRITEBYTECODE=1 "$python" \
    "$http_root/tests/http2_server_peer.py" \
    --port "$port" --certificate \
    "$http_root/tests/fixtures/tls/server-cert.pem" $tls_option
  then
    kill "$server_pid" 2>/dev/null || :
    wait "$server_pid" 2>/dev/null || :
    sed -n '1,160p' "$server_log" >&2
    rm -rf "$run_dir"
    exit 1
  fi
  wait "$server_pid"
  rm -rf "$run_dir"
  printf '%s\n' "HTTP/2 server: PASS $server_transport"
}

run_server () {
  require_tester
  build_test http2_conformance_server http2-server
  run_server_case plain
  run_server_case tls
}

run_h2spec () {
  if ! command -v docker >/dev/null 2>&1; then
    printf '%s\n' "Docker is required for the pinned h2spec run" >&2
    exit 2
  fi
  if [ ! -d "$http_root/build/rts/adalib" ]; then
    printf '%s\n' \
      "prepared test runtime is unavailable; run: ./scripts/test.sh" >&2
    exit 2
  fi

  build_test http2_conformance_server http2-server
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-h2spec.XXXXXX")
  port_file="$run_dir/port"
  server_log="$run_dir/server.log"
  server_pid=

  cleanup_h2spec () {
    if [ -n "$server_pid" ]; then
      kill "$server_pid" 2>/dev/null || :
      wait "$server_pid" 2>/dev/null || :
    fi
    rm -rf "$run_dir"
  }
  trap cleanup_h2spec EXIT HUP INT TERM

  "$http_root/tests/bin/http2-server/http2_conformance_server" \
    "$port_file" plain \
    "$http_root/tests/fixtures/tls/server-cert.pem" \
    "$http_root/tests/fixtures/tls/server-key.pem" 0 \
    >"$server_log" 2>&1 &
  server_pid=$!
  ready=false
  for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if [ -s "$port_file" ]; then
      ready=true
      break
    fi
    if ! kill -0 "$server_pid" 2>/dev/null; then
      break
    fi
    sleep 0.1
  done
  if [ "$ready" != true ]; then
    sed -n '1,160p' "$server_log" >&2
    printf '%s\n' "HTTP/2 h2spec server did not become ready" >&2
    exit 1
  fi

  port=$(tr -d '\r\n' <"$port_file")
  h2spec_image=${FLYOLOGY_HTTP2_H2SPEC_IMAGE:-summerwind/h2spec:2.6.0}
  if [ "$(uname -s)" = Linux ]; then
    docker run --rm --platform linux/amd64 --network host \
      "$h2spec_image" -h 127.0.0.1 -p "$port" -o 5
  else
    docker run --rm --platform linux/amd64 \
      --add-host host.docker.internal:host-gateway \
      "$h2spec_image" -h host.docker.internal -p "$port" -o 5
  fi

  cleanup_h2spec
  trap - EXIT HUP INT TERM
  printf '%s\n' "HTTP/2 server h2spec: PASS"
}

prepare_h2specd () {
  if [ -x "$h2specd" ]; then
    return
  fi
  if ! command -v curl >/dev/null 2>&1 \
    || ! command -v go >/dev/null 2>&1
  then
    printf '%s\n' \
      "curl and Go are required to build the pinned h2specd client oracle" >&2
    exit 2
  fi

  archive="$h2specd_root/h2spec-$h2specd_version.tar.gz"
  source_dir="$h2specd_root/source"
  mkdir -p "$h2specd_root"
  curl -fsSL \
    "https://github.com/summerwind/h2spec/archive/refs/tags/v$h2specd_version.tar.gz" \
    -o "$archive.tmp"
  actual_sha256=$(shasum -a 256 "$archive.tmp" | awk '{print $1}')
  if [ "$actual_sha256" != "$h2specd_sha256" ]; then
    rm -f "$archive.tmp"
    printf '%s\n' "h2specd source checksum mismatch" >&2
    exit 1
  fi
  mv "$archive.tmp" "$archive"
  rm -rf "$source_dir"
  mkdir -p "$source_dir"
  tar -xzf "$archive" -C "$source_dir" --strip-components=1
  (
    cd "$source_dir"
    go build -trimpath \
      -ldflags "-X main.VERSION=$h2specd_version -X main.COMMIT=70ac2294010887f48b18e2d64f5cccd48421fad1" \
      -o "$h2specd" ./cmd/h2specd
  )
}

find_h2specd_port_block () {
  python3 -c '
import random, socket
candidates = list(range(20_000, 49_000, 64))
random.Random().shuffle(candidates)
for base in candidates:
    sockets = []
    try:
        for port in range(base, base + 64):
            item = socket.socket()
            item.bind(("127.0.0.1", port))
            sockets.append(item)
    except OSError:
        pass
    else:
        print(base)
        break
    finally:
        for item in sockets:
            item.close()
else:
    raise SystemExit("no free 64-port block for h2specd")'
}

run_client_h2spec () {
  if [ ! -d "$http_root/build/rts/adalib" ]; then
    printf '%s\n' \
      "prepared test runtime is unavailable; run: ./scripts/test.sh" >&2
    exit 2
  fi
  prepare_h2specd
  build_test http2_h2spec_client h2spec-client

  styles=${FLYOLOGY_HTTP2_H2SPECD_STYLES:-"sync scoped"}
  models=${FLYOLOGY_HTTP2_H2SPECD_MODELS:-"native lightweight"}
  for style in $styles; do
    for model in $models; do
      run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-h2specd.XXXXXX")
      result_log="$run_dir/result.log"
      from_port=$(find_h2specd_port_block)
      "$h2specd" -f "$from_port" -o 3 \
        -e "$http_root/tests/bin/h2spec-client/http2_h2spec_client $style $model" \
        >"$result_log" 2>&1 || :
      if ! grep -Fq '57 tests, 57 passed, 0 skipped, 0 failed' \
        "$result_log"
      then
        sed -n '1,220p' "$result_log" >&2
        rm -rf "$run_dir"
        printf '%s\n' \
          "HTTP/2 client h2specd failed: $style/$model" >&2
        exit 1
      fi
      rm -rf "$run_dir"
      printf '%s\n' "HTTP/2 client h2specd: PASS $style/$model (57/57)"
    done
  done
}

run_showcase_case () {
  showcase_scenario=$1
  showcase_option=$2
  showcase_scheme=$3
  showcase_expected=$4
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http2-cli.XXXXXX")
  port_file="$run_dir/port"
  log_file="$run_dir/events.jsonl"
  error_file="$run_dir/stderr"
  cleartext=
  if [ "$showcase_scheme" = http ]; then
    cleartext=--cleartext
  fi
  "$python" "$http_root/tests/http2_peer.py" "$showcase_scenario" \
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
    rm -rf "$run_dir"
    printf '%s\n' "HTTP/2 showcase peer did not become ready" >&2
    exit 1
  fi
  port=$(tr -d '\r\n' <"$port_file")
  if [ "$showcase_scheme" = https ]; then
    if ! showcase_output=$("$http_root/showcases/bin/http_client_cli" \
      -v "$showcase_option" \
      --ca-file "$http_root/tests/fixtures/tls/server-cert.pem" \
      "$showcase_scheme://localhost:$port/" 2>"$error_file")
    then
      kill "$peer_pid" 2>/dev/null || :
      wait "$peer_pid" 2>/dev/null || :
      sed -n '1,120p' "$error_file" >&2
      sed -n '1,120p' "$log_file" >&2
      rm -rf "$run_dir"
      exit 1
    fi
  else
    if ! showcase_output=$("$http_root/showcases/bin/http_client_cli" \
      -v "$showcase_option" \
      "$showcase_scheme://localhost:$port/" 2>"$error_file")
    then
      kill "$peer_pid" 2>/dev/null || :
      wait "$peer_pid" 2>/dev/null || :
      sed -n '1,120p' "$error_file" >&2
      sed -n '1,120p' "$log_file" >&2
      rm -rf "$run_dir"
      exit 1
    fi
  fi
  wait "$peer_pid"
  test "$showcase_output" = "$showcase_expected"
  if [ "$showcase_scenario" = fallback ]; then
    grep -q '^< HTTP/1.1 200 OK$' "$error_file"
    expected_alpn=http/1.1
  else
    grep -q '^< HTTP/2 200$' "$error_file"
    expected_alpn=$(if [ "$showcase_scheme" = http ]; then printf h2c; else printf h2; fi)
  fi
  PYTHONDONTWRITEBYTECODE=1 "$python" -c \
    'import json,sys; events=[json.loads(x) for x in open(sys.argv[1])]; connected=[e for e in events if e["event"]=="connected"]; assert len(connected)==1; assert connected[0]["alpn"]==sys.argv[2]; assert sum(e["event"]=="request" for e in events)==1' \
    "$log_file" "$expected_alpn"
  rm -rf "$run_dir"
  printf '%s\n' "HTTP/2 showcase CLI: PASS $showcase_option/$showcase_scenario"
}

run_showcase_usage () {
  usage_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http2-cli-usage.XXXXXX")
  "$http_root/showcases/bin/http_client_cli" --help >"$usage_dir/help"
  grep -q -- '--http2-only' "$usage_dir/help"
  grep -q -- '--http2-prior-knowledge' "$usage_dir/help"
  grep -q -- '--unix-socket' "$usage_dir/help"
  if "$http_root/showcases/bin/http_client_cli" \
    --http1.1 --http2 https://localhost/ \
    >"$usage_dir/output" 2>"$usage_dir/error"
  then
    rm -rf "$usage_dir"
    printf '%s\n' "conflicting showcase HTTP modes were accepted" >&2
    exit 1
  fi
  grep -q 'conflicts with another HTTP version option' "$usage_dir/error"
  if "$http_root/showcases/bin/http_client_cli" \
    --http2 http://localhost/ >"$usage_dir/output" 2>"$usage_dir/error"
  then
    rm -rf "$usage_dir"
    printf '%s\n' "TLS HTTP/2 mode accepted a cleartext URL" >&2
    exit 1
  fi
  grep -q -- '--http2-prior-knowledge' "$usage_dir/error"
  if "$http_root/showcases/bin/http_client_cli" \
    --unix-socket /tmp/example.sock https://localhost/ \
    >"$usage_dir/output" 2>"$usage_dir/error"
  then
    rm -rf "$usage_dir"
    printf '%s\n' "Unix transport accepted an HTTPS URL" >&2
    exit 1
  fi
  grep -q -- '--unix-socket requires an http:// URL' "$usage_dir/error"
  if "$http_root/showcases/bin/http_client_cli" \
    --unix-socket '' http://127.0.0.1:1/ \
    >"$usage_dir/output" 2>"$usage_dir/error"
  then
    rm -rf "$usage_dir"
    printf '%s\n' "empty Unix socket path was accepted" >&2
    exit 1
  fi
  grep -q 'Unix socket pathname is empty' "$usage_dir/error"
  if grep -q 'resolved HTTP endpoints' "$usage_dir/error"; then
    rm -rf "$usage_dir"
    printf '%s\n' "empty Unix socket path selected Internet transport" >&2
    exit 1
  fi
  rm -rf "$usage_dir"
  printf '%s\n' "HTTP/2 showcase CLI: PASS option validation"
}

run_showcase () {
  require_tester
  if [ ! -d "$http_root/build/rts/adalib" ]; then
    printf '%s\n' \
      "prepared test runtime is unavailable; run: ./scripts/test.sh" >&2
    exit 2
  fi
  build_showcase_client
  run_showcase_usage
  run_showcase_case basic --http2-only https flyology-http2
  run_showcase_case fallback --http2 https fallback
  run_showcase_case prior --http2-prior-knowledge http flyology-http2
}

case "$command" in
  prepare)
    python3 -m venv "$environment"
    "$environment/bin/pip" install \
      -r "$http_root/tests/requirements-http2.txt"
    prepare_h2specd
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
  server)
    run_server
    ;;
  h2spec)
    run_h2spec
    ;;
  h2spec-client)
    run_client_h2spec
    ;;
  showcase)
    run_showcase
    ;;
  interop)
    "$http_root/scripts/http2-interop.sh" interop
    ;;
  faults)
    "$http_root/scripts/http2-interop.sh" faults
    ;;
  soak)
    "$http_root/scripts/http2-soak.sh"
    ;;
  qualification)
    run_server
    run_client
    "$http_root/scripts/http2-interop.sh" all
    "$http_root/scripts/http2-soak.sh"
    run_h2spec
    run_client_h2spec
    ;;
  nightly)
    FLYOLOGY_HTTP2_SOAK_SECONDS=${FLYOLOGY_HTTP2_SOAK_SECONDS:-1800.0}
    FLYOLOGY_HTTP2_SOAK_MODELS=${FLYOLOGY_HTTP2_SOAK_MODELS:-"native lightweight"}
    FLYOLOGY_HTTP2_SOAK_SEEDS=${FLYOLOGY_HTTP2_SOAK_SEEDS:-1}
    export FLYOLOGY_HTTP2_SOAK_SECONDS FLYOLOGY_HTTP2_SOAK_MODELS
    export FLYOLOGY_HTTP2_SOAK_SEEDS
    run_server
    run_client
    "$http_root/scripts/http2-interop.sh" all
    "$http_root/scripts/http2-soak.sh"
    run_h2spec
    run_client_h2spec
    ;;
  all)
    run_codecs
    run_client
    run_server
    run_showcase
    ;;
  *)
    printf '%s\n' \
      "usage: $0 {prepare|codecs|client|server|h2spec|h2spec-client|showcase|interop|faults|soak|qualification|nightly|all}" >&2
    exit 2
    ;;
esac
