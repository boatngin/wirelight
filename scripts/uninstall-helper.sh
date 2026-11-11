#!/bin/bash
# Stop and remove wgbar-helper. Refuses while tunnels are still up.
set -euo pipefail

LABEL="com.thanaboat.wgbar.helper"
CTL=/usr/local/bin/wgbarctl

if [[ -x $CTL ]] && $CTL ping >/dev/null 2>&1; then
    active=$($CTL status | grep -c '"interface"' || true)
    if [[ "$active" != "0" ]]; then
        echo "There are $active active tunnel(s). Bring them down first:" >&2
        $CTL status | grep '"name"' >&2
        echo "  e.g. wgbarctl down <name>" >&2
        exit 1
    fi
fi

echo "==> Unloading LaunchDaemon (sudo)"
sudo launchctl bootout system/$LABEL 2>/dev/null || true

echo "==> Removing files"
sudo rm -f /Library/LaunchDaemons/$LABEL.plist
sudo rm -f /Library/PrivilegedHelperTools/wgbar-helper
sudo rm -f /usr/local/bin/wgbarctl
sudo rm -f /var/run/wgbar.sock
sudo rm -f /var/log/wgbar-helper.log
sudo rm -rf "/Library/Application Support/WGBar"
# Only our own leftovers in the shared wireguard run dir
sudo find /var/run/wireguard -maxdepth 1 \( -name '*.name' -o -name '*.setconf' \) -delete 2>/dev/null || true
sudo rmdir /var/run/wireguard 2>/dev/null || true

echo "==> Done"
