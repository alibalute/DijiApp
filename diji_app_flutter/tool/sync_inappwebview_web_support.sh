#!/bin/sh
# Copies web_support.js from the resolved flutter_inappwebview_web package into web/.
# Run from repo root: bash tool/sync_inappwebview_web_support.sh
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${PUB_CACHE:-$HOME/.pub-cache}"
SRC="$(find "$CACHE" -path '*flutter_inappwebview_web*/lib/assets/web/web_support.js' 2>/dev/null | head -1)"
if [ -z "$SRC" ] || [ ! -f "$SRC" ]; then
  echo "Could not find web_support.js in pub-cache. Run: cd \"$(dirname "$0")/..\" && flutter pub get"
  exit 1
fi
cp -f "$SRC" "$ROOT/web/inappwebview_web_support.js"
echo "OK: $ROOT/web/inappwebview_web_support.js ($(wc -c < "$ROOT/web/inappwebview_web_support.js") bytes)"
