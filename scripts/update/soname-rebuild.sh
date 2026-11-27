#!/usr/bin/env bash
# Packages in [tungsten] are linked against libraries from Arch. When Arch moves one of those
# to a new soname (hyprgraphics 0.7: libhyprgraphics.so=6), the published package depends on
# a library no repository provides any more, and the image cannot be installed. For every
# such package, bump pkgrel, so the package workflow rebuilds it against the new library.
# Reads the published repository database (tungsten.db) and checks each libfoo.so=N
# dependency against what Arch's core and extra databases and [tungsten] itself provide.
set -euo pipefail
cd "$(dirname -- "$0")/../.."
REPO=${TUNGSTEN_REPO:-https://github.com/$GITHUB_REPOSITORY/releases/download/packages}
MIRROR=${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL --proto '=https' "$REPO/tungsten.db" -o "$work/db"
mkdir "$work/x" && bsdtar -xf "$work/db" -C "$work/x"

# Every soname that is provided: by Arch (core, extra) and by [tungsten] itself.
declare -A provided=()
for r in core extra; do
  curl -fsSL --proto '=https' "$MIRROR/$r/os/x86_64/$r.db" -o "$work/$r.db"
  mkdir "$work/$r" && bsdtar -xf "$work/$r.db" -C "$work/$r"
done
while read -r p; do provided[$p]=1; done < <(
  awk '/^%PROVIDES%/{f=1;next} /^%/{f=0} f&&NF&&/\.so=/' "$work"/core/*/desc "$work"/extra/*/desc "$work"/x/*/desc)
[ ${#provided[@]} -gt 1000 ] || { echo "too few sonames in the Arch databases (${#provided[@]})" >&2; exit 1; }

bump() {   # bump <PKGBUILD>
  local p=$1 rel new
  rel=$(sed -n 's/^pkgrel=//p' "$p")
  if [[ $rel == *.* ]]; then new=${rel%.*}.$(( ${rel##*.} + 1 )); else new=$(( rel + 1 )); fi
  sed -i "s/^pkgrel=.*/pkgrel=$new/" "$p"
  echo "$new"
}

declare -A done_=()
for desc in "$work"/x/*/desc; do
  name=$(awk '/^%NAME%/{getline; print; exit}' "$desc")
  base=$(awk '/^%BASE%/{getline; print; exit}' "$desc")
  missing=()
  while read -r dep; do
    [[ $dep == *.so=* ]] || continue
    [ -n "${provided[$dep]:-}" ] || missing+=("$dep")
  done < <(awk '/^%DEPENDS%/{f=1;next} /^%/{f=0} f&&NF' "$desc")
  [ ${#missing[@]} -gt 0 ] || continue
  # The PKGBUILD that builds it: its own directory, or the one naming it as pkgbase/pkgname.
  pb=$(grep -lE "^(pkgbase|pkgname)=\(?['\"]?(${base:-$name})['\" )]?" packages/*/PKGBUILD kernel/PKGBUILD 2>/dev/null | head -1)
  if [ -z "$pb" ]; then
    echo "$name: needs ${missing[*]} (no longer in Arch), but no PKGBUILD here builds it" >&2
    exit 1
  fi
  [ -n "${done_[$pb]:-}" ] && continue
  done_[$pb]=1
  new=$(bump "$pb")
  echo "$name: rebuild, Arch no longer provides ${missing[*]} (pkgrel $new)"
done
