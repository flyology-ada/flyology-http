#!/bin/sh
set -eu

project_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
alr=$("$project_root/scripts/find-alr.sh")
website_kit="$project_root/vendor/website-kit"

if [ ! -f "$website_kit/scripts/render-gnatdoc-theme.mjs" ]; then
  printf '%s\n' \
    "website kit is unavailable; run: git submodule update --init" >&2
  exit 1
fi

if ! command -v gnatdoc >/dev/null 2>&1; then
  installed_gnatdoc=${ALIRE_INSTALL_PREFIX:-"$HOME/.alire"}/bin/gnatdoc
  if [ ! -x "$installed_gnatdoc" ]; then
    printf '%s\n' \
      "gnatdoc not found; install it with: $alr install gnatdoc_bin" >&2
    exit 1
  fi
  PATH=$(dirname "$installed_gnatdoc"):$PATH
  export PATH
fi

"$project_root/flyology_quic/scripts/docs.sh"

cd "$project_root"
FLYOLOGY_HTTP_DOCUMENTATION=true
export FLYOLOGY_HTTP_DOCUMENTATION
"$alr" build --stop-after=generation

if [ -n "${FLYOLOGY_ROOT:-}" ]; then
  flyology_root=$FLYOLOGY_ROOT
else
  flyology_root=$("$alr" exec -- sh -c 'printf "%s\n" "$FLYOLOGY_ROOT"')
fi

if [ ! -f "$flyology_root/flyology.gpr" ]; then
  printf '%s\n' "unable to locate the Flyology dependency project" >&2
  exit 1
fi

node "$website_kit/scripts/render-gnatdoc-theme.mjs" \
  "$project_root/docs/gnatdoc-theme.json" \
  "$project_root/docs/gnatdoc/html"
"$alr" exec -- gnatdoc \
  --backend=html \
  --warnings \
  --style=leading \
  -P flyology_http.gpr \
  -O docs/api

mkdir -p docs/api/fonts
cp "$website_kit/assets/fonts/geologica-latin-variable.woff2" docs/api/fonts/
cp website/assets/brand/flyology-mark-transparent.svg docs/api/flyology-mark.svg
cp "$website_kit/assets/scripts/ada-highlight.js" docs/api/ada-highlight.js
node "$website_kit/scripts/build-api-search-index.mjs" docs/api

test -f docs/api/index.html
test -f docs/api/search-index.js
