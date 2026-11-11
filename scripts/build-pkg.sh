#!/bin/bash
# Builds a universal (arm64 + x86_64) Wirelight installer package.
#   scripts/build-pkg.sh [version]
# Output: build/Wirelight-<version>.pkg and build/Wirelight.pkg
# Optional env: APP_SIGN_IDENTITY (default ad-hoc "-"), PKG_SIGN_IDENTITY
# ("Developer ID Installer: ..."; unsigned when empty).
set -euo pipefail
export COPYFILE_DISABLE=1   # no AppleDouble ._ files in the payload

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
VERSION="${1:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.0.0)}"
[[ -n "$VERSION" ]] || VERSION=0.0.0
BUILD_NO="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
OUT=build/pkg
ROOT="$OUT/root"
rm -rf "$OUT"; mkdir -p "$ROOT"

echo "==> Version $VERSION ($BUILD_NO)"

echo "==> Building helper and CLI (universal)"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "==> Building app (universal)"
(cd App && xcodegen generate >/dev/null)
xcodebuild -project App/Wirelight.xcodeproj -scheme Wirelight -configuration Release \
    -derivedDataPath build/DerivedData-release \
    ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NO" \
    CODE_SIGN_IDENTITY="${APP_SIGN_IDENTITY:--}" DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}" \
    build | grep -E "error:|BUILD" || true
APP="build/DerivedData-release/Build/Products/Release/Wirelight.app"
[[ -d "$APP" ]] || { echo "app build failed" >&2; exit 1; }

echo "==> Staging payload"
install -d "$ROOT/Applications" "$ROOT/Library/PrivilegedHelperTools" "$ROOT/Library/LaunchDaemons" \
           "$ROOT/usr/local/bin" "$ROOT/usr/local/share/wirelight"
ditto "$APP" "$ROOT/Applications/Wirelight.app"
install -m 755 "$BIN/wgbar-helper" "$ROOT/Library/PrivilegedHelperTools/"
install -m 755 "$BIN/wgbarctl" "$ROOT/usr/local/bin/"
install -m 644 scripts/com.thanaboat.wgbar.helper.plist "$ROOT/Library/LaunchDaemons/"
install -m 755 installer/uninstall.sh "$ROOT/usr/local/share/wirelight/uninstall.sh"
cp LICENSE "$ROOT/usr/local/share/wirelight/LICENSE"

xattr -cr "$ROOT"

# Keep the app in /Applications even if another copy exists elsewhere.
pkgbuild --analyze --root "$ROOT" "$OUT/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$OUT/components.plist"

echo "==> Building component package"
pkgbuild --root "$ROOT" --component-plist "$OUT/components.plist" \
    --scripts installer/scripts --identifier com.thanaboat.wgbar.pkg \
    --version "$VERSION" --install-location / "$OUT/Wirelight-component.pkg"

echo "==> Building installer"
mkdir -p "$OUT/resources"
cp installer/resources/* "$OUT/resources/"
cp LICENSE "$OUT/resources/LICENSE.txt"
sed "s/__VERSION__/$VERSION/" installer/distribution.xml > "$OUT/distribution.xml"
SIGN_ARGS=()
[[ -n "${PKG_SIGN_IDENTITY:-}" ]] && SIGN_ARGS=(--sign "$PKG_SIGN_IDENTITY")
productbuild --distribution "$OUT/distribution.xml" --resources "$OUT/resources" \
    --package-path "$OUT" ${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"} "build/Wirelight-$VERSION.pkg"
cp "build/Wirelight-$VERSION.pkg" build/Wirelight.pkg

(cd build && shasum -a 256 "Wirelight-$VERSION.pkg" > "Wirelight-$VERSION.pkg.sha256")
echo "==> build/Wirelight-$VERSION.pkg"
