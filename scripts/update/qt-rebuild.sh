#!/usr/bin/env bash
# Packages built against Qt's private API (Quickshell, qtengine) only work with the Qt
# minor release they were built with; Qt refuses to load such a platform theme, and
# Quickshell can crash. When Arch moves to a new Qt minor release, record it in _qtver
# and bump pkgrel, so the package workflow rebuilds them.
set -euo pipefail
cd "$(dirname -- "$0")/../.."
qt=$(pacman -Si qt6-base | awk '/^Version/ {print $3}')
minor=$(cut -d. -f1,2 <<<"$qt")
[[ $minor =~ ^[0-9]+\.[0-9]+$ ]] || { echo "unexpected qt6-base version: $qt" >&2; exit 1; }
for p in packages/quickshell/PKGBUILD packages/qtengine/PKGBUILD; do
  [ "$(sed -n 's/^_qtver=//p' "$p")" = "$minor" ] && continue
  rel=$(sed -n 's/^pkgrel=//p' "$p")
  if [[ $rel == *.* ]]; then new=${rel%.*}.$(( ${rel##*.} + 1 )); else new=$(( rel + 1 )); fi
  sed -i -e "s/^_qtver=.*/_qtver=$minor/" -e "s/^pkgrel=.*/pkgrel=$new/" "$p"
  echo "$(basename "$(dirname "$p")"): rebuild for Qt $minor (pkgrel $new)"
done
