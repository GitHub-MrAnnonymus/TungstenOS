#!/usr/bin/env bash
# Moves hardened_malloc to the newest commit on main. Exit 10 (review) on change.
# GrapheneOS does not sign commits, so every update is reviewed.
set -euo pipefail
cd "$(dirname -- "$0")/../../packages/hardened_malloc"
auth=(); [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
c=$(curl -fsSL "${auth[@]}" https://api.github.com/repos/GrapheneOS/hardened_malloc/commits/main)
new=$(jq -r .sha <<<"$c"); cur=$(sed -n 's/^_commit=//p' PKGBUILD)
[ "$new" != "$cur" ] || { echo "hardened_malloc up to date"; exit 0; }
sed -i -e "s/^_commit=.*/_commit=$new/" -e "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
echo "hardened_malloc ${cur:0:10} -> ${new:0:10}"
{
  echo "hardened_malloc ${cur:0:10} -> ${new:0:10} (upstream commits are unsigned; review the changes):"
  echo "  https://github.com/GrapheneOS/hardened_malloc/compare/$cur...$new"
} >> "${REPORT:-/dev/stderr}"
exit 10
