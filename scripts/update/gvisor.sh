#!/usr/bin/env bash
# Moves gvisor to the newest upstream release. Exit 10 (review) on change.
# Release tags are on the Bazel tree (master); the package builds the "go" branch, which
# merges each master commit for go build. Takes the first go-branch commit that contains
# the tag's commit.
set -euo pipefail
cd "$(dirname -- "$0")/../../packages/gvisor"
repo=https://github.com/google/gvisor.git
tag=$(git ls-remote --tags --refs "$repo" 'release-*' | sed 's|.*refs/tags/||' | sort -V | tail -1)
ver=${tag#release-}; cur=$(sed -n 's/^pkgver=//p' PKGBUILD)
[ "$ver" != "$cur" ] || { echo "gvisor up to date ($ver)"; exit 0; }
rel=$(git ls-remote "$repo" "refs/tags/$tag^{}" | cut -f1)
[ ${#rel} -eq 40 ] || { echo "cannot resolve $tag" >&2; exit 1; }
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
# Commits only (no trees or files); releases are weekly, so a month of history is enough.
git clone -q --bare --filter=tree:0 --single-branch -b go --shallow-since='30 days ago' "$repo" "$tmp/g"
commit=
for c in $(git -C "$tmp/g" rev-list --first-parent --reverse go); do
  if git -C "$tmp/g" merge-base --is-ancestor "$rel" "$c" 2>/dev/null; then commit=$c; break; fi
done
[ -n "$commit" ] || { echo "no go-branch commit contains $tag yet" >&2; exit 1; }
sed -i -e "s/^pkgver=.*/pkgver=$ver/" -e "s/^pkgrel=.*/pkgrel=1/" \
       -e "s/^_commit=[0-9a-f]*.*/_commit=$commit  # go branch, contains tag $tag/" PKGBUILD
echo "gvisor $cur -> $ver"
echo "gvisor $cur -> $ver: https://github.com/google/gvisor/compare/release-$cur...$tag" >> "${REPORT:-/dev/stderr}"
exit 10
