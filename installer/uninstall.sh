#!/bin/bash
# Removes everything the Wirelight installer added. Run with sudo.
set -euo pipefail
LABEL="com.thanaboat.wgbar.helper"

if [[ $EUID -ne 0 ]]; then echo "Run with sudo: sudo $0" >&2; exit 1; fi

if [[ -x /usr/local/bin/wgbarctl ]] && /usr/local/bin/wgbarctl ping >/dev/null 2>&1; then
    if /usr/local/bin/wgbarctl status | grep -q '"interface"'; then
        echo "A tunnel is still connected. Disconnect it in Wirelight first." >&2
        exit 1
    fi
fi

pkill -x Wirelight 2>/dev/null || true
launchctl bootout system/"$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" /Library/PrivilegedHelperTools/wgbar-helper
rm -f /usr/local/bin/wgbarctl /var/run/wgbar.sock /var/log/wgbar-helper.log
rm -rf "/Library/Application Support/WGBar" /Applications/Wirelight.app
for f in /etc/resolver/*; do
    [[ -f "$f" ]] && head -1 "$f" | grep -q '^# managed by wgbar:' && rm -f "$f"
done
rm -rf /usr/local/share/wirelight
pkgutil --forget com.thanaboat.wgbar.pkg >/dev/null 2>&1 || true
echo "Wirelight removed. Keychain items (service com.thanaboat.wgbar) are left in your login keychain."
