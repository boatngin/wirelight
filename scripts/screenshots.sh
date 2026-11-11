#!/bin/bash
# Renders README/website screenshots from the app's demo mode (sample data only).
# Requires a Debug build at build/DerivedData (see README › Development).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
APP="$REPO/build/DerivedData/Build/Products/Debug/Wirelight.app/Contents/MacOS/Wirelight"
OUT="$REPO/build/shots"
rm -rf "$OUT" && mkdir -p "$OUT"
pkill -x Wirelight 2>/dev/null || true
WIRELIGHT_DEMO=1 WIRELIGHT_SCREENSHOT_DIR="$OUT" "$APP"
echo "Raw screenshots written to $OUT (crop them before copying to docs/assets/screenshots)"
