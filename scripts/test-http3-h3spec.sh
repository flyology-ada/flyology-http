#!/bin/sh
set -eu

http_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$http_root/scripts/find-alr.sh")
port=${FLYOLOGY_H3SPEC_PORT:-4437}
h3spec=${FLYOLOGY_H3SPEC:-}
version=0.1.13
qualification_rts="$http_root/build/http3-qualification-rts"

prepare_qualification_rts () {
  flyology_root=$("$http_root/scripts/resolve-flyology-root.sh")

  "$alr" exec -- env \
    FLYOLOGY_RTS_DIR="$qualification_rts" \
    FLYOLOGY_DEFAULT=native \
    FLYOLOGY_LOOP_POOL_SIZE=1 \
    "$flyology_root/scripts/prepare-rts.sh" >/dev/null
}

if [ -z "$h3spec" ]; then
  platform=$(uname -s)-$(uname -m)
  case "$platform" in
    Linux-x86_64)
      asset=h3spec-linux-x86_64
      checksum=b5f8eddd968cb195d1e3e7698d33fa141d6b2ad56153089d89928ac0fdee28bf
      ;;
    Darwin-arm64)
      asset=h3spec-mac-arm64
      checksum=850ee3317b767db1e5e41cf3b9f034a74feabf52672744920ba41f330b710253
      ;;
    *)
      printf '%s\n' \
        "h3spec $version has no pinned Flyology asset for $platform" >&2
      exit 2
      ;;
  esac
  h3spec="$http_root/build/oracle/h3spec-$version-$asset"
  if [ ! -x "$h3spec" ]; then
    mkdir -p "$http_root/build/oracle"
    curl -fL \
      "https://github.com/kazu-yamamoto/h3spec/releases/download/v$version/$asset" \
      -o "$h3spec.download"
    actual=$(shasum -a 256 "$h3spec.download" | awk '{print $1}')
    if [ "$actual" != "$checksum" ]; then
      printf '%s\n' \
        "h3spec checksum mismatch: expected $checksum, got $actual" >&2
      exit 1
    fi
    mv "$h3spec.download" "$h3spec"
    chmod +x "$h3spec"
  fi
fi

cd "$http_root"
prepare_qualification_rts
"$alr" exec -- env -u GPR_CONFIG gprbuild \
  --RTS="$qualification_rts" -p -P tests/http_tests.gpr \
  http3_h3spec_server.adb

server_log="$http_root/build/oracle/ada-h3-h3spec.log"
report="$http_root/build/oracle/h3spec-report.log"
server_pid=
cleanup () {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || :
    wait "$server_pid" 2>/dev/null || :
  fi
}
trap cleanup EXIT HUP INT TERM

"$http_root/tests/bin/http3_h3spec_server" \
  "$port" >"$server_log" 2>&1 &
server_pid=$!
ready=false
attempt=0
while [ "$attempt" -lt 100 ]; do
  if grep -q 'Ada HTTP/3 h3spec server listening' "$server_log"; then
    ready=true
    break
  fi
  if ! kill -0 "$server_pid" 2>/dev/null; then
    break
  fi
  attempt=$((attempt + 1))
  sleep 0.1
done
if [ "$ready" != true ]; then
  sed -n '1,200p' "$server_log" >&2
  exit 1
fi

set +e
"$h3spec" 127.0.0.1 "$port" -n -t 5000 "$@" >"$report" 2>&1
status=$?
set -e
sed -n '1,400p' "$report"
if grep -q '\[✘\]' "$report"; then
  status=1
fi
if [ "$status" -ne 0 ]; then
  printf '%s\n' "h3spec $version reported failures; see $report" >&2
fi
exit "$status"
