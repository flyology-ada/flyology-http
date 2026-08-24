#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
environment="$http_root/build/http2-tester"
python="$environment/bin/python"
certificate="$http_root/tests/fixtures/tls/server-cert.pem"
private_key="$http_root/tests/fixtures/tls/server-key.pem"
requests=${FLYOLOGY_HTTP2_SOAK_REQUESTS:-250}
seconds=${FLYOLOGY_HTTP2_SOAK_SECONDS:-0.0}
epochs=${FLYOLOGY_HTTP2_SOAK_EPOCHS:-3}
concurrency=${FLYOLOGY_HTTP2_SOAK_CONCURRENCY:-4}
capacity=${FLYOLOGY_HTTP2_SOAK_CAPACITY:-1}
models=${FLYOLOGY_HTTP2_SOAK_MODELS:-"native lightweight"}
seeds=${FLYOLOGY_HTTP2_SOAK_SEEDS:-"1"}

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

alr=$("$http_root/scripts/find-alr.sh")
"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$http_root/build/rts" --subdirs=http2-soak -p \
  -P "$http_root/tests/http_tests.gpr" http2_client_soak.adb

for model in $models; do
  case "$model" in native|lightweight) ;; *)
    printf '%s\n' "invalid HTTP/2 soak model: $model" >&2
    exit 2
  esac
  for seed in $seeds; do
    run_dir=$(mktemp -d "${TMPDIR:-/tmp}/flyology-http2-soak.XXXXXX")
    port_file="$run_dir/port"
    log_file="$run_dir/events.jsonl"
    "$python" "$http_root/tests/http2_peer.py" soak \
      --certificate "$certificate" --private-key "$private_key" \
      --port-file "$port_file" --log-file "$log_file" &
    peer_pid=$!
    ready=false
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
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
      printf '%s\n' "HTTP/2 soak peer did not become ready" >&2
      exit 1
    fi
    port=$(tr -d '\r\n' <"$port_file")
    if ! FLYOLOGY_HTTP2_SOAK_ORIGIN="https://localhost:$port" \
      FLYOLOGY_HTTP2_SOAK_CA="$certificate" \
      FLYOLOGY_HTTP2_SOAK_REQUESTS="$requests" \
      FLYOLOGY_HTTP2_SOAK_SECONDS="$seconds" \
      FLYOLOGY_HTTP2_SOAK_EPOCHS="$epochs" \
      FLYOLOGY_HTTP2_SOAK_CONCURRENCY="$concurrency" \
      FLYOLOGY_HTTP2_SOAK_CAPACITY="$capacity" \
      FLYOLOGY_HTTP2_SOAK_MODEL="$model" \
      FLYOLOGY_HTTP2_SOAK_SEED="$seed" \
        "$http_root/tests/bin/http2-soak/http2_client_soak"
    then
      kill "$peer_pid" 2>/dev/null || :
      wait "$peer_pid" 2>/dev/null || :
      printf '%s\n' "HTTP/2 soak peer log (first events):" >&2
      sed -n '1,40p' "$log_file" >&2
      printf '%s\n' "HTTP/2 soak peer log (final events):" >&2
      tail -160 "$log_file" >&2
      PYTHONDONTWRITEBYTECODE=1 "$python" -c \
        'import json,sys; events=[json.loads(x) for x in open(sys.argv[1])]; print("peer summary: connections=%d requests=%d request_ends=%d responses=%d resets=%d timeouts=%d" % (sum(e["event"]=="connected" for e in events), sum(e["event"]=="request" for e in events), sum(e["event"]=="request-end" for e in events), sum(e["event"] in ("response", "cancel-response") for e in events), sum(e["event"]=="client-reset" for e in events), sum(e["event"]=="receive-timeout" for e in events)), file=sys.stderr)' \
        "$log_file"
      rm -rf "$run_dir"
      exit 1
    fi
    kill "$peer_pid" 2>/dev/null || :
    wait "$peer_pid" 2>/dev/null || :
    if [ "$seconds" = 0 ] || [ "$seconds" = 0.0 ]; then
      expected=$((1 + epochs * requests * concurrency))
    else
      expected=0
    fi
    PYTHONDONTWRITEBYTECODE=1 "$python" -c \
      'import json,sys; events=[json.loads(x) for x in open(sys.argv[1])]; requests=sum(e["event"]=="request" for e in events); assert sum(e["event"]=="connected" for e in events)==1+int(sys.argv[4]); assert requests>=1+int(sys.argv[3])*int(sys.argv[4]); assert int(sys.argv[2])==0 or requests==int(sys.argv[2]); assert any(e["event"]=="client-reset" for e in events)' \
      "$log_file" "$expected" "$concurrency" "$epochs"
    rm -rf "$run_dir"
    printf '%s\n' \
      "HTTP/2 soak: PASS $model seed=$seed requests=$requests seconds=$seconds epochs=$epochs concurrency=$concurrency capacity=$capacity"
  done
done
