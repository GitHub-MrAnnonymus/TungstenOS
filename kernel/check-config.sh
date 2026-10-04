#!/usr/bin/env bash
# Builds a patched tree from the pristine tarball, regenerates config.slim and
# checks that every option in config.fragment and config.slim survives
# olddefconfig, as the PKGBUILD does. Uses the LLVM toolchain when available.
set -euo pipefail
cd "$(dirname -- "$0")"
KDIR="$PWD"

pkgver=$(sed -n 's/^pkgver=//p' PKGBUILD)
sha=$(sed -n "s/^sha256sums=('\([0-9a-f]*\)'.*/\1/p" PKGBUILD)
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tungstenos"
TARBALL="$CACHE/linux-$pkgver.tar.xz"
mkdir -p "$CACHE"
[ -f "$TARBALL" ] || curl -fsSL -o "$TARBALL" "https://cdn.kernel.org/pub/linux/kernel/v${pkgver%%.*}.x/linux-$pkgver.tar.xz"
echo "$sha  $TARBALL" | sha256sum -c --quiet

command -v clang >/dev/null && command -v ld.lld >/dev/null && export LLVM=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
tar -xf "$TARBALL" -C "$WORK"
TREE="$WORK/linux-$pkgver"
while read -r p; do
  [[ -z $p || $p = \#* ]] && continue
  patch -d "$TREE" -Np1 -s --no-backup-if-mismatch < "patches/$p"
done < patches/series

cp config.base "$TREE/.config"
(cd "$TREE" && scripts/kconfig/merge_config.sh -m .config "$KDIR/config.fragment" >/dev/null && make -s olddefconfig)
python3 update-slim-config.py "$TREE"

cd "$TREE"
cp "$KDIR/config.base" .config
scripts/kconfig/merge_config.sh -m .config "$KDIR/config.fragment" "$KDIR/config.slim" >/dev/null
make -s olddefconfig
bad=0
while read -r line; do
  if [[ $line =~ ^(CONFIG_[A-Za-z0-9_]+)=(.*)$ ]]; then
    sym=${BASH_REMATCH[1]}; want=${BASH_REMATCH[2]}
  elif [[ $line =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
    sym=${BASH_REMATCH[1]}; want=n
  else
    continue
  fi
  got=$(scripts/config -s "${sym#CONFIG_}")
  [[ $got = undef ]] && got=n
  want=${want//\"/}; got=${got//\"/}
  if [[ "$got" != "$want" ]]; then
    echo "config: $sym wanted '$want', got '$got'" >&2
    bad=1
  fi
done < <(cat "$KDIR/config.fragment" "$KDIR/config.slim")
[ "$bad" -eq 0 ] && echo "OK: config for linux-$pkgver (LLVM=${LLVM:-0}), $(grep -c '=m$' .config) modules"
exit "$bad"
