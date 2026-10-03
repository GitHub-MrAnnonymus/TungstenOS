#!/usr/bin/env bash
# Syncs _nvver and its checksum with Arch's nvidia-utils.
set -euo pipefail
cd "$(dirname -- "$0")"
URL=https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-utils/-/raw/main/PKGBUILD
upstream=$(curl -fsSL "$URL")
ver=$(sed -n 's/^pkgver=//p' <<<"$upstream")
sha=$(awk '/^sha512sums=\(/,/\)/' <<<"$upstream" | grep -oE "[0-9a-f]{128}" | tail -n1)
[[ $ver && ${#sha} -eq 128 ]] || { echo "could not parse nvidia-utils PKGBUILD" >&2; exit 1; }
cur=$(sed -n 's/^_nvver=//p' PKGBUILD)
if [[ $cur == "$ver" ]]; then echo "nvidia already at $ver"; exit 0; fi
sed -i "s/^_nvver=.*/_nvver=$ver/; s/^_nvsha512=.*/_nvsha512='$sha'/" PKGBUILD
sed -i "s/^pkgrel=\([0-9]*\)/echo pkgrel=\$((\1+1))/e" PKGBUILD
echo "nvidia $cur -> $ver"
