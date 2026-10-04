#!/usr/bin/env bash
# Moves greetd-dms-greeter to the newest upstream release. Exit 10 (review) on change.
set -euo pipefail
cd "$(dirname -- "$0")/../../packages/greetd-dms-greeter"
auth=(); [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
tag=$(curl -fsSL "${auth[@]}" https://api.github.com/repos/AvengeMedia/dank-greeter/releases/latest | jq -r .tag_name)
ver=${tag#v}; cur=$(sed -n 's/^pkgver=//p' PKGBUILD)
[ "$ver" != "$cur" ] || { echo "dms-greeter up to date ($ver)"; exit 0; }
commit=$(git ls-remote https://github.com/AvengeMedia/dank-greeter.git "refs/tags/$tag^{}" "refs/tags/$tag" | awk 'NR==1 || /\^\{\}/ {c=$1} END {print c}')
[ ${#commit} -eq 40 ] || { echo "cannot resolve $tag" >&2; exit 1; }
sed -i -e "s/^pkgver=.*/pkgver=$ver/" -e "s/^pkgrel=.*/pkgrel=1/" \
       -e "s/^_commit=[0-9a-f]*\(.*\)/_commit=$commit  # tag $tag/" PKGBUILD
echo "dms-greeter $cur -> $ver"
echo "dms-greeter $cur -> $ver: https://github.com/AvengeMedia/dank-greeter/compare/v$cur...$tag" >> "${REPORT:-/dev/stderr}"
exit 10
