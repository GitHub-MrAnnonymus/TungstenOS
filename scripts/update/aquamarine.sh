#!/usr/bin/env bash
# Keeps packages/aquamarine (Arch's aquamarine plus TungstenOS's changes) in step with the
# version in Arch's [extra]. Commits directly (exit 0) when our patch still applies and
# Arch's dependency lists are the ones we carry; otherwise a pull request (exit 10).
set -euo pipefail
cd "$(dirname -- "$0")/../../packages/aquamarine"
rel=$(curl -fsSL 'https://archlinux.org/packages/search/json/?name=aquamarine&repo=Extra' |
  jq -r '.results[] | select(.arch == "x86_64") | "\(.pkgver)-\(.pkgrel)"' | head -n1)
[[ $rel =~ ^[0-9.]+-[0-9.]+$ ]] || { echo "aquamarine not found in [extra]" >&2; exit 1; }
ver=${rel%-*}
cur=$(sed -n 's/^pkgver=//p' PKGBUILD)
if [ "$cur" = "$ver" ]; then echo "aquamarine up to date ($ver)"; exit 0; fi

up=$(curl -fsSL "https://gitlab.archlinux.org/archlinux/packaging/packages/aquamarine/-/raw/$rel/PKGBUILD")
sha=$(awk '/^sha256sums=\(/,/\)/' <<<"$up" | grep -oE '[0-9a-f]{64}' | head -n1)
[ ${#sha} -eq 64 ] || { echo "could not parse Arch's aquamarine PKGBUILD" >&2; exit 1; }

# Our patch against the new source.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl -fsSL -o "$work/src.tar.gz" "https://github.com/hyprwm/aquamarine/archive/v$ver/aquamarine-$ver.tar.gz"
echo "$sha  $work/src.tar.gz" | sha256sum -c --quiet -
tar -xzf "$work/src.tar.gz" -C "$work"
applies=yes
patch -d "$work/aquamarine-$ver" -p1 --dry-run -s < 0001-keep-crtc-on-exit.patch >/dev/null || applies=no

# Arch's dependency lists against ours (a new library would otherwise be missing).
arrays() { bash -c 'eval "$1"; printf "%s\n" "${depends[@]}" "--" "${makedepends[@]}"' _ "$1" | sed 's/ *#.*//' | sort; }
same_deps=yes
[ "$(arrays "$up")" = "$(arrays "$(cat PKGBUILD)")" ] || same_deps=no

sed -i -e "s/^pkgver=.*/pkgver=$ver/" -e "s/^pkgrel=.*/pkgrel=1.1/" \
       -e "0,/^sha256sums=('[0-9a-f]*'/s//sha256sums=('$sha'/" PKGBUILD
{
  echo "aquamarine $cur -> $ver (Arch $rel)"
  [ $applies = yes ] || echo "- 0001-keep-crtc-on-exit.patch no longer applies: rebase it (or drop it if upstream keeps outputs on at exit)"
  [ $same_deps = yes ] || echo "- Arch changed depends or makedepends: copy them into packages/aquamarine/PKGBUILD"
} | tee -a "${REPORT:-/dev/stderr}"
[ $applies = yes ] && [ $same_deps = yes ] && exit 0
exit 10
