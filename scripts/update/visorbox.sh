#!/usr/bin/env bash
# Moves visorbox to the newest upstream release tag. Exit 10 (review) on change; the
# package build checks the tag's SSH signature against packages/visorbox/allowed_signers.
set -euo pipefail
cd "$(dirname -- "$0")/../../packages/visorbox"
repo=https://codeberg.org/HastD/visorbox.git
tag=$(git ls-remote --tags --refs "$repo" 'v*' | sed 's|.*refs/tags/||' | sort -V | tail -1)
ver=${tag#v}; cur=$(sed -n 's/^pkgver=//p' PKGBUILD)
[ "$ver" != "$cur" ] || { echo "visorbox up to date ($ver)"; exit 0; }
commit=$(git ls-remote "$repo" "refs/tags/$tag^{}" "refs/tags/$tag" | awk 'NR==1 || /\^\{\}/ {c=$1} END {print c}')
[ ${#commit} -eq 40 ] || { echo "cannot resolve $tag" >&2; exit 1; }
sed -i -e "s/^pkgver=.*/pkgver=$ver/" -e "s/^pkgrel=.*/pkgrel=1/" \
       -e "s/^_commit=[0-9a-f]*\(.*\)/_commit=$commit  # tag $tag/" PKGBUILD
echo "visorbox $cur -> $ver"
echo "visorbox $cur -> $ver: https://codeberg.org/HastD/visorbox/compare/v$cur...$tag" >> "${REPORT:-/dev/stderr}"
exit 10
