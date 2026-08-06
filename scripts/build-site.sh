#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SITE="$ROOT/build/site"
KIT="$ROOT/vendor/website-kit"

test -f "$KIT/scripts/install-assets.mjs" || {
  echo "website-kit submodule is missing; run git submodule update --init" >&2
  exit 1
}

rm -rf "$SITE"
mkdir -p "$ROOT/build"
cp -R "$ROOT/website" "$SITE"
node "$KIT/scripts/install-assets.mjs" "$SITE"
touch "$SITE/.nojekyll"
node "$KIT/scripts/check-site.mjs" "$SITE"
