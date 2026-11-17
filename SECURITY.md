# Security Policy

Wirelight installs a helper that runs as **root**, so we take security reports seriously.

## Supported versions

Only the latest release gets security fixes.

## Reporting a vulnerability

Please **don't** open a public issue. Use GitHub's private reporting instead:
[Report a vulnerability](https://github.com/boatngin/wirelight/security/advisories/new)

Include what you found, how to reproduce it, and the impact you expect. We aim to reply within 7 days and to ship a fix or mitigation within 30 days for confirmed issues. We'll credit you in the release notes unless you'd rather stay anonymous.

## Security model

- The helper (`wgbar-helper`) listens on `/var/run/wgbar.sock` (`root:staff`, mode `0660`) and only serves users in the `admin` group, checked with `getpeereid`.
- The calling process must also be Wirelight or `wgbarctl`: its code signature is checked by audit token (not PID, which can be swapped mid-request), and its executable and every folder above it must be root-owned, so no user can replace it. Source builds opt out with the root-owned flag file `/Library/Application Support/WGBar/allow-dev-callers`, which `scripts/install-helper.sh` creates.
- Requests are limited to 64 KB. Every config is validated again in the helper. Scripting hooks (`PreUp`, `PostUp`, `PreDown`, `PostDown`, `SaveConfig`, `Table`) are rejected.
- The helper runs only allow-listed binaries (`wireguard-go`, `wg`, `ifconfig`, `route`, `networksetup`, `pfctl`, `dscacheutil`, `killall`) with a fixed argument list. It never invokes a shell and never accepts file paths from clients.
- Private keys live in the user's login Keychain. They are never logged and never written to disk by the app. The helper writes a temporary `wg setconf` file (mode `0600`, in a root-only directory) and deletes it right away.

### Known limitations

- The installer ships `wireguard-go` and `wg` in `/Library/PrivilegedHelperTools/wirelight-tools`, built from pinned upstream commits (`scripts/build-wg-tools.sh`). The helper uses them only while they and their folders are root-only. If they're missing it falls back to Homebrew, which is usually writable by the logged-in user; `wgbarctl doctor` says which copy is in use and warns when it isn't root-owned.
- Updates come through Sparkle and are verified with an EdDSA signature before installing. Builds without a configured public key have no updater.
- Release builds aren't notarized yet, so macOS shows a Gatekeeper warning. Check the `.sha256` file published with each release before you install.
