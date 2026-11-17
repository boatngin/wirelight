#!/bin/bash
# Builds universal wg, wireguard-go, awg and amneziawg-go from pinned upstream sources.
#   scripts/build-wg-tools.sh <out-dir>
# Needs: git, a C compiler (Xcode CLT) and Go. Tags are checked against the pinned
# commits so a moved tag can't slip other code into the package.
set -euo pipefail

WG_TOOLS_TAG=v1.0.20260223
WG_TOOLS_COMMIT=49ce333da02056ae7b22ee2aeb6afe8aaed79b19
WG_GO_TAG=0.0.20250522
WG_GO_COMMIT=f333402bd9cbe0f3eeb02507bd14e23d7d639280
AWG_TOOLS_TAG=v3.1.20260812
AWG_TOOLS_COMMIT=ee0f0a9aa34ff0a0da4b3433b9512781cfe02843
AWG_GO_TAG=v3.1.20260828
AWG_GO_COMMIT=b5928efb6ca19f0153958460c3d141f04abc5c2e

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
fetch https://github.com/amnezia-vpn/amneziawg-tools "$AWG_TOOLS_TAG" "$AWG_TOOLS_COMMIT" awgtools
fetch https://github.com/amnezia-vpn/amneziawg-go "$AWG_GO_TAG" "$AWG_GO_COMMIT" awggo

build_c() { # src-dir binary-name out-name
    for arch in arm64 x86_64; do
        make -s -C "$WORK/$1/src" clean >/dev/null
        make -s -C "$WORK/$1/src" CC="cc -arch $arch -mmacosx-version-min=13.0" "$2" >/dev/null
        cp "$WORK/$1/src/$2" "$WORK/$3-$arch"
    done
    lipo -create "$WORK/$3-arm64" "$WORK/$3-x86_64" -output "$OUT/$3"
}

build_go() { # src-dir out-name
    for arch in arm64 amd64; do
        (cd "$WORK/$1" && CGO_ENABLED=0 GOOS=darwin GOARCH=$arch go build -trimpath -ldflags="-s -w" -o "$WORK/$2-$arch" .)
    done
    lipo -create "$WORK/$2-arm64" "$WORK/$2-amd64" -output "$OUT/$2"
}

echo "==> wg $WG_TOOLS_TAG";            build_c tools wg wg
echo "==> wireguard-go $WG_GO_TAG";     build_go go wireguard-go
echo "==> awg $AWG_TOOLS_TAG";          build_c awgtools wg awg
echo "==> amneziawg-go $AWG_GO_TAG";    build_go awggo amneziawg-go

for t in wg wireguard-go awg amneziawg-go; do
    codesign --force -s "${APP_SIGN_IDENTITY:--}" -i "io.github.boatngin.wirelight.$t" "$OUT/$t"
done
printf '%s %s %s\n' wireguard-tools "$WG_TOOLS_TAG" "$WG_TOOLS_COMMIT" wireguard-go "$WG_GO_TAG" "$WG_GO_COMMIT" \
    amneziawg-tools "$AWG_TOOLS_TAG" "$AWG_TOOLS_COMMIT" amneziawg-go "$AWG_GO_TAG" "$AWG_GO_COMMIT" > "$OUT/VERSIONS"
for t in wg wireguard-go awg amneziawg-go; do echo "==> $t: $(lipo -archs "$OUT/$t")"; done
