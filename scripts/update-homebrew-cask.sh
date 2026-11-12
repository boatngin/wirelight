#!/bin/bash
# Updates the Wirelight cask in the Homebrew tap (default boatngin/homebrew-tap)
# after a release. No-op when HOMEBREW_TAP_TOKEN is unset.
#   scripts/update-homebrew-cask.sh <version> <pkg-sha256>
set -euo pipefail

VERSION="${1:?usage: update-homebrew-cask.sh <version> <pkg-sha256>}"
SHA256="${2:?usage: update-homebrew-cask.sh <version> <pkg-sha256>}"
TAP_REPO="${HOMEBREW_TAP_REPO:-boatngin/homebrew-tap}"
TAP_BRANCH="${HOMEBREW_TAP_BRANCH:-main}"
TOKEN="${HOMEBREW_TAP_TOKEN:-}"

if [[ -z "$TOKEN" ]]; then
  echo "HOMEBREW_TAP_TOKEN not set; skipping Homebrew cask update" >&2
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
git clone --depth 1 --branch "$TAP_BRANCH" \
  "https://x-access-token:${TOKEN}@github.com/${TAP_REPO}.git" "$WORK/tap"
mkdir -p "$WORK/tap/Casks"
cat >"$WORK/tap/Casks/wirelight.rb" <<EOF
cask "wirelight" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/boatngin/wirelight/releases/download/v#{version}/Wirelight-#{version}.pkg"
  name "Wirelight"
  desc "Menu bar WireGuard VPN client for macOS"
  homepage "https://github.com/boatngin/wirelight"
  license "MIT"

  depends_on macos: ">= :ventura"
  depends_on formula: ["wireguard-tools", "wireguard-go"]

  pkg "Wirelight-#{version}.pkg"

  uninstall pkg: "com.thanaboat.wgbar.pkg",
            delete: [
              "/Library/LaunchDaemons/com.thanaboat.wgbar.helper.plist",
              "/Library/PrivilegedHelperTools/wgbar-helper",
              "/usr/local/bin/wgbarctl",
              "/usr/local/share/wirelight",
            ]

  zap trash: [
    "~/Library/Preferences/com.thanaboat.wgbar.plist",
  ]
end
EOF

cd "$WORK/tap"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git add Casks/wirelight.rb
if ! git diff --cached --quiet; then
  git commit -m "wirelight $VERSION"
  git push origin "HEAD:$TAP_BRANCH"
  echo "==> cask updated to $VERSION"
else
  echo "==> cask already at $VERSION"
fi
