#!/usr/bin/env bash
# Syncs _nvver and its checksum with Arch's nvidia-utils in [extra], which the image
# installs (the kernel package pins nvidia-utils to its version). Not the packaging repo's
# main branch: a version lands there already when it enters [extra-testing].
set -euo pipefail
cd "$(dirname -- "$0")"
rel=$(curl -fsSL 'https://archlinux.org/packages/search/json/?name=nvidia-utils&repo=Extra' |
  jq -r '.results[] | select(.arch == "x86_64") | "\(.pkgver)-\(.pkgrel)"' | head -n1)
[[ $rel =~ ^[0-9.]+-[0-9.]+$ ]] || { echo "nvidia-utils not found in [extra]" >&2; exit 1; }
URL=https://gitlab.archlinux.org/archlinux/packaging/packages/nvidia-utils/-/raw/$rel/PKGBUILD
upstream=$(curl -fsSL "$URL")
ver=$(sed -n 's/^pkgver=//p' <<<"$upstream")
sha=$(awk '/^sha512sums=\(/,/\)/' <<<"$upstream" | grep -oE "[0-9a-f]{128}" | tail -n1)
[[ $ver && ${#sha} -eq 128 ]] || { echo "could not parse nvidia-utils PKGBUILD" >&2; exit 1; }
cur=$(sed -n 's/^_nvver=//p' PKGBUILD)
if [[ $cur == "$ver" ]]; then echo "nvidia already at $ver"; exit 0; fi
sed -i "s/^_nvver=.*/_nvver=$ver/; s/^_nvsha512=.*/_nvsha512='$sha'/" PKGBUILD
sed -i "s/^pkgrel=\([0-9]*\)/echo pkgrel=\$((\1+1))/e" PKGBUILD
echo "nvidia $cur -> $ver"
