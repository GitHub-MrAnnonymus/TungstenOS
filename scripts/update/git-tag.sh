#!/usr/bin/env bash
# Moves packages/<package> to the newest v<version> tag of its git repository and pins the
# tag's commit. Exit 10 (review) on change.
# Usage: git-tag.sh <package> <repository URL>
set -euo pipefail
pkg=$1 repo=$2
cd "$(dirname -- "$0")/../../packages/$pkg"
tag=$(git ls-remote --tags --refs "$repo" 'v*' | sed 's|.*refs/tags/||' | grep -E '^v[0-9.]+$' | sort -V | tail -1)
ver=${tag#v}; cur=$(sed -n 's/^pkgver=//p' PKGBUILD)
[ "$ver" != "$cur" ] || { echo "$pkg up to date ($ver)"; exit 0; }
commit=$(git ls-remote "$repo" "refs/tags/$tag^{}" "refs/tags/$tag" | awk 'NR==1 || /\^\{\}/ {c=$1} END {print c}')
[ ${#commit} -eq 40 ] || { echo "cannot resolve $tag" >&2; exit 1; }
sed -i -e "s/^pkgver=.*/pkgver=$ver/" -e "s/^pkgrel=.*/pkgrel=1/" \
       -e "s/^_commit=[0-9a-f]*\(.*\)/_commit=$commit  # tag $tag/" PKGBUILD
echo "$pkg $cur -> $ver"
echo "$pkg $cur -> $ver: ${repo%.git}/compare/v$cur...$tag" >> "${REPORT:-/dev/stderr}"
exit 10
