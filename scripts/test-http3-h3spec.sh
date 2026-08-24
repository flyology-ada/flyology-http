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
    # Bounded the way the workflow bounds its package installs: a stalled
    # connection becomes a retry and then a failure, instead of hanging the
    # step until the job timeout. --max-time is counted per attempt once
    # --retry is in play, and the checksum below is what makes retrying safe,
    # because a truncated or resumed body never survives it.
    curl -fL --retry 3 --retry-delay 5 --retry-all-errors \
      --connect-timeout 20 --max-time 300 \
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
  --RTS="$qualification_rts" --subdirs=http3-qualification -p \
  -P tests/http_tests.gpr \
  http3_h3spec_server.adb

server_log="$http_root/build/oracle/ada-h3-h3spec.log"
report="$http_root/build/oracle/h3spec-report.log"
keyupdate_report="$http_root/build/oracle/h3spec-keyupdate-report.log"
server_pid=
cleanup () {
  if [ -n "$server_pid" ]; then
    kill "$server_pid" 2>/dev/null || :
    wait "$server_pid" 2>/dev/null || :
  fi
}
trap cleanup EXIT HUP INT TERM

"$http_root/tests/bin/http3-qualification/http3_h3spec_server" \
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
  exit "$status"
fi

# Exercise the same-flight Finished + forbidden KeyUpdate boundary repeatedly.
# A server must reject the already-reassembled trailing TLS message without
# depending on another Handshake packet to drive the connection state machine.
repetition=1
while [ "$repetition" -le 10 ]; do
  set +e
  "$h3spec" 127.0.0.1 "$port" -n -t 5000 \
    -m 'MUST send unexpected_message TLS alert if KeyUpdate in Handshake is received' \
    >"$keyupdate_report" 2>&1
  keyupdate_status=$?
  set -e
  if [ "$keyupdate_status" -ne 0 ] \
    || grep -q '\[✘\]' "$keyupdate_report"
  then
    sed -n '1,160p' "$keyupdate_report"
    printf '%s\n' \
      "h3spec KeyUpdate repetition $repetition failed; see $keyupdate_report" \
      >&2
    exit 1
  fi
  repetition=$((repetition + 1))
done
printf '%s\n' 'h3spec repeated same-flight KeyUpdate boundary: 10/10 passed'
