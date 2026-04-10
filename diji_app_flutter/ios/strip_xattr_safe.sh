#!/bin/sh
# Safe xattr strip for iOS codesign ("resource fork" errors).
# Do NOT run: xattr -cr .   (hits Pods, permission denied, and is unnecessary.)
set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GEN="$SCRIPT_DIR/Flutter/Generated.xcconfig"
FR=""
if [ -f "$GEN" ]; then
  FR=$(grep '^FLUTTER_ROOT=' "$GEN" | cut -d= -f2-)
fi
export COPYFILE_DISABLE=1
if [ -d "$ROOT/build/ios" ]; then
  xattr -cr "$ROOT/build/ios" 2>/dev/null || true
fi
if [ -n "$FR" ] && [ -d "$FR/bin/cache/artifacts/engine" ]; then
  xattr -cr "$FR/bin/cache/artifacts/engine" 2>/dev/null || true
fi
echo "strip_xattr_safe: ok (build/ios + engine only). FLUTTER_ROOT=$FR"
