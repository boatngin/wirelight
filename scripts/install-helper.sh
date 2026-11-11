#!/bin/bash
# Build and (re)install wgbar-helper as a LaunchDaemon. Safe to run repeatedly.
set -euo pipefail

LABEL="com.thanaboat.wgbar.helper"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

if [[ $EUID -eq 0 ]]; then
    echo "Run as your normal user (the script calls sudo itself)." >&2
    exit 1
fi

if [[ ! -x /opt/homebrew/bin/wireguard-go && ! -x /usr/local/bin/wireguard-go ]]; then
    echo "wireguard-go not found. Run: brew install wireguard-tools wireguard-go" >&2
    exit 1
fi

echo "==> Building release"
swift build -c release

echo "==> Installing (sudo)"
sudo install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
sudo install -m 755 -o root -g wheel .build/release/wgbar-helper /Library/PrivilegedHelperTools/
sudo install -m 644 -o root -g wheel scripts/$LABEL.plist /Library/LaunchDaemons/
sudo install -d -m 755 /usr/local/bin
sudo install -m 755 -o root -g wheel .build/release/wgbarctl /usr/local/bin/

echo "==> (Re)loading LaunchDaemon"
sudo launchctl bootout system/$LABEL 2>/dev/null || true
# bootout is asynchronous; wait until the job is gone before bootstrapping again
for _ in {1..20}; do
    sudo launchctl print system/$LABEL >/dev/null 2>&1 || break
    sleep 0.25
done
sudo launchctl bootstrap system /Library/LaunchDaemons/$LABEL.plist

sleep 1
if /usr/local/bin/wgbarctl ping >/dev/null 2>&1; then
    echo "==> OK: helper is running (wgbarctl ping works)"
else
    echo "==> Helper installed but not answering yet. Check: sudo tail /var/log/wgbar-helper.log" >&2
    exit 1
fi
