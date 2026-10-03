#!/usr/bin/env bash
# Applies the enabled patches to a pristine tarball without fuzz.
set -euo pipefail
cd "$(dirname -- "$0")"
KDIR="$PWD"

pkgver=$(sed -n 's/^pkgver=//p' PKGBUILD)
sha=$(sed -n "s/^sha256sums=('\([0-9a-f]*\)'.*/\1/p" PKGBUILD)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tungstenos"
TARBALL="$CACHE/linux-$pkgver.tar.xz"
mkdir -p "$CACHE"
[ -f "$TARBALL" ] || curl -fL --progress-bar -o "$TARBALL" "https://cdn.kernel.org/pub/linux/kernel/v${pkgver%%.*}.x/linux-$pkgver.tar.xz"
echo "$sha  $TARBALL" | sha256sum -c --quiet

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xf "$TARBALL" -C "$WORK"
cd "$WORK/linux-$pkgver"

n=0
while read -r p; do
  [[ -z $p || $p = \#* ]] && continue
  if ! out=$(patch -Np1 --no-backup-if-mismatch -F0 < "$KDIR/patches/$p" 2>&1); then
    echo "$out" >&2
    echo "FAILED: $p (after $n patches). It probably depends on a disabled patch;" >&2
    echo "rebase it and put the result in patch-overrides/." >&2
    exit 1
  fi
  n=$((n+1))
done < "$KDIR/patches/series"
echo "OK: all $n enabled patches apply cleanly (no fuzz) to linux-$pkgver"
