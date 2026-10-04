#!/usr/bin/env bash
# Syncs erofs-utils-selinux with Arch's erofs-utils version and checksum.
set -euo pipefail
cd "$(dirname -- "$0")/../../packages/erofs-utils-selinux"
up=$(curl -fsSL https://gitlab.archlinux.org/archlinux/packaging/packages/erofs-utils/-/raw/main/PKGBUILD)
ver=$(sed -n 's/^pkgver=//p' <<<"$up")
sha=$(awk '/^sha512sums=\(/,/\)/' <<<"$up" | grep -oE '[0-9a-f]{128}' | head -n1)
[[ $ver && ${#sha} -eq 128 ]] || { echo "could not parse erofs-utils PKGBUILD" >&2; exit 1; }
cur=$(sed -n 's/^pkgver=//p' PKGBUILD)
if [ "$cur" = "$ver" ]; then echo "erofs-utils up to date ($ver)"; exit 0; fi
sed -i -e "s/^pkgver=.*/pkgver=$ver/" -e "s/^pkgrel=.*/pkgrel=1/" \
       -e "s/^sha512sums=('[0-9a-f]*'/sha512sums=('$sha'/" PKGBUILD
echo "erofs-utils $cur -> $ver"
echo "erofs-utils $cur -> $ver (checksum from Arch's PKGBUILD)" >> "${REPORT:-/dev/stderr}"
