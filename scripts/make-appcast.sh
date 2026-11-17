#!/bin/bash
# Signs the installer with Sparkle's EdDSA key and writes build/appcast.xml for it.
#   SPARKLE_PRIVATE_KEY=<base64> scripts/make-appcast.sh <version>
# The feed lists only the latest release and is uploaded as a release asset, so
# releases/latest/download/appcast.xml always points at it.
set -euo pipefail
VERSION="${1:?version}"
SPARKLE_VERSION=2.9.6
PKG="build/Wirelight-$VERSION.pkg"
[[ -f "$PKG" ]] || { echo "missing $PKG" >&2; exit 1; }
[[ -n "${SPARKLE_PRIVATE_KEY:-}" ]] || { echo "SPARKLE_PRIVATE_KEY not set; skipping appcast" >&2; exit 0; }

TOOLS="build/sparkle-$SPARKLE_VERSION"
if [[ ! -x "$TOOLS/bin/sign_update" ]]; then
    mkdir -p "$TOOLS"
    curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
        | tar -xJ -C "$TOOLS"
fi
SIG="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$TOOLS/bin/sign_update" --ed-key-file - "$PKG")"
URL="https://github.com/boatngin/wirelight/releases/download/v$VERSION/Wirelight-$VERSION.pkg"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
    build/DerivedData-release/Build/Products/Release/Wirelight.app/Contents/Info.plist)"

cat > build/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Wirelight</title>
    <item>
      <title>Wirelight $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/boatngin/wirelight/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$URL" sparkle:installationType="package" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "==> build/appcast.xml for $VERSION"
