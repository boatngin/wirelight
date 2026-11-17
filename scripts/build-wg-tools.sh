#!/bin/bash
# Builds universal wg and wireguard-go from pinned upstream sources.
#   scripts/build-wg-tools.sh <out-dir>
# Needs: git, a C compiler (Xcode CLT) and Go. Tags are checked against the pinned
# commits so a moved tag can't slip other code into the package.
set -euo pipefail

WG_TOOLS_TAG=v1.0.20260223
WG_TOOLS_COMMIT=49ce333da02056ae7b22ee2aeb6afe8aaed79b19
WG_GO_TAG=0.0.20250522
WG_GO_COMMIT=f333402bd9cbe0f3eeb02507bd14e23d7d639280

OUT="$(mkdir -p "${1:?usage: $0 <out-dir>}" && cd "$1" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

fetch() { # url tag commit dir
    git -c advice.detachedHead=false clone -q --depth 1 --branch "$2" "$1" "$WORK/$4"
    local got; got="$(git -C "$WORK/$4" rev-parse HEAD)"
    [[ "$got" == "$3" ]] || { echo "$4: tag $2 is $got, expected $3" >&2; exit 1; }
}

fetch https://git.zx2c4.com/wireguard-tools "$WG_TOOLS_TAG" "$WG_TOOLS_COMMIT" tools
fetch https://git.zx2c4.com/wireguard-go "$WG_GO_TAG" "$WG_GO_COMMIT" go

echo "==> wg $WG_TOOLS_TAG"
for arch in arm64 x86_64; do
    make -s -C "$WORK/tools/src" clean >/dev/null
    make -s -C "$WORK/tools/src" CC="cc -arch $arch -mmacosx-version-min=13.0" wg >/dev/null
    cp "$WORK/tools/src/wg" "$WORK/wg-$arch"
done
lipo -create "$WORK/wg-arm64" "$WORK/wg-x86_64" -output "$OUT/wg"

echo "==> wireguard-go $WG_GO_TAG"
for arch in arm64 amd64; do
    (cd "$WORK/go" && CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags="-s -w" -o "$WORK/wggo-$arch" .)
done
lipo -create "$WORK/wggo-arm64" "$WORK/wggo-amd64" -output "$OUT/wireguard-go"

for t in wg wireguard-go; do
    codesign --force -s "${APP_SIGN_IDENTITY:--}" -i "io.github.boatngin.wirelight.$t" "$OUT/$t"
done
printf 'wireguard-tools %s %s\nwireguard-go %s %s\n' "$WG_TOOLS_TAG" "$WG_TOOLS_COMMIT" "$WG_GO_TAG" "$WG_GO_COMMIT" > "$OUT/VERSIONS"
echo "==> $OUT: $(lipo -archs "$OUT/wg") / $(lipo -archs "$OUT/wireguard-go")"
