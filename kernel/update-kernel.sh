#!/usr/bin/env bash
# Moves linux-tungsten to the newest signed linux-hardened release.
# Exit 0: up to date, or updated and every check passed (safe to commit).
# Exit 10: updated, but needs review (reasons appended to $REPORT).
# Any other exit: failure; discard the working tree changes.
set -euo pipefail
cd "$(dirname -- "$0")"
REPORT=${REPORT:-/dev/stderr}
note() { echo "- $*" >> "$REPORT"; review=1; }
review=0

cur_tag=$(sed -n '1s/^# linux-hardened \(v[^ ]*\) .*/\1/p' patches/series)
latest=$(git ls-remote --tags --refs https://github.com/anthraxx/linux-hardened \
  | sed -n 's#.*refs/tags/##p' | grep -E '^v[0-9]+\.[0-9]+(\.[0-9]+)?-hardened[0-9]+$' | sort -V | tail -n1)
[ -n "$cur_tag" ] && [ -n "$latest" ] || { echo "cannot determine kernel versions" >&2; exit 1; }
if [ "$(printf '%s\n%s\n' "$cur_tag" "$latest" | sort -V | tail -n1)" = "$cur_tag" ]; then
  echo "kernel up to date ($cur_tag)"; exit 0
fi
kver=${latest#v}; kver=${kver%-hardened*}; hrev=${latest##*-}
old_ver=$(sed -n 's/^pkgver=//p' PKGBUILD)
echo "kernel $cur_tag -> $latest"
echo "Kernel: linux-hardened $cur_tag -> $latest" >> "$REPORT"

slugs() { sed -E 's/^(#?)\s*[0-9]{4}-/\1/' patches/series | grep -E '\.patch$' | sort; }
before=$(slugs)
rc=0; ./update-hardened-patches.sh "$kver" "$hrev" >/dev/null || rc=$?
case $rc in
  0) ;;
  3) note "an overridden patch changed upstream; rebase it in kernel/patch-overrides/" ;;
  *) exit "$rc" ;;
esac
after=$(slugs)
if [ "$before" != "$after" ]; then
  note "linux-hardened patch set changed:"
  diff <(echo "$before") <(echo "$after") | sed -n 's/^[<>]/   &/p' >> "$REPORT" || :
fi
[ "${old_ver%.*}" = "${kver%.*}" ] || note "new kernel series ${old_ver%.*} -> ${kver%.*}: refresh config.base from Arch's linux-hardened"

# Verify the tarball against kernel.org's signing keys before pinning its checksum.
CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/tungstenos"; mkdir -p "$CACHE"
TARBALL="$CACHE/linux-$kver.tar.xz"
base="https://cdn.kernel.org/pub/linux/kernel/v${kver%%.*}.x/linux-$kver"
curl -fsSL -o "$TARBALL" "$base.tar.xz"
curl -fsSL -o "$TARBALL.sign" "$base.tar.sign"
G=$(mktemp -d); trap 'rm -rf "$G"' EXIT
GNUPGHOME="$G" gpg --batch --quiet --import keys/torvalds.asc keys/gregkh.asc 2>/dev/null
xz -cd "$TARBALL" | GNUPGHOME="$G" gpg --batch --status-fd 1 --verify "$TARBALL.sign" - 2>/dev/null \
  | grep -qE '^\[GNUPG:\] VALIDSIG (ABAF11C65A2970B130ABE3C479BE3E4300411886|647F28654894E3BD457199BE38DBBDC86092693E) ' \
  || { echo "linux-$kver tarball signature invalid" >&2; exit 1; }
sha=$(sha256sum "$TARBALL" | cut -d' ' -f1)
sed -i -e "s/^pkgver=.*/pkgver=$kver/" -e "s/^pkgrel=.*/pkgrel=1/" \
       -e "0,/^sha256sums=('[0-9a-f]*'/s//sha256sums=('$sha'/" PKGBUILD

./check-patches.sh >/dev/null 2>>"$REPORT" || note "patches do not apply cleanly to linux-$kver"
if [ "$review" -eq 0 ]; then
  cp config.slim "$G/slim.old"
  ./check-config.sh > /dev/null 2>>"$REPORT" || note "kernel config check failed"
  cmp -s config.slim "$G/slim.old" || note "config.slim changed (new or renamed kernel options)"
fi

exit $(( review ? 10 : 0 ))
