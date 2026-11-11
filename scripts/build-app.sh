#!/bin/bash
# Archive Wirelight.app (Release) and zip it into build/.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
VERSION="$(git describe --tags --always 2>/dev/null || echo dev)"
ARCHIVE="build/Wirelight.xcarchive"
OUT="build/Wirelight-$VERSION.zip"

echo "==> Generating Xcode project"
(cd App && xcodegen generate)

echo "==> Archiving"
rm -rf "$ARCHIVE"
xcodebuild -project App/Wirelight.xcodeproj -scheme Wirelight -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath build/DerivedData archive | grep -E "error|ARCHIVE" || true

APP="$ARCHIVE/Products/Applications/Wirelight.app"
[[ -d "$APP" ]] || { echo "archive failed" >&2; exit 1; }
codesign --verify --deep "$APP"

echo "==> Zipping"
rm -f "$OUT"
ditto -c -k --keepParent "$APP" "$OUT"
echo "==> $OUT"
