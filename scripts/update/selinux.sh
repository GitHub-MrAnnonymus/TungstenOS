#!/usr/bin/env bash
# Pins packages/build-selinux.sh to the newest archlinuxhardened/selinux commit
# signed by the maintainer. Exit 0 always (verified updates are safe to commit).
set -euo pipefail
cd "$(dirname -- "$0")/../.."
F=packages/build-selinux.sh
cur=$(sed -n 's/^SELINUX_COMMIT=//p' "$F")
fpr=$(sed -n 's/^MAINTAINER_FPR=//p' "$F")
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
git clone -q --filter=blob:none --no-checkout https://github.com/archlinuxhardened/selinux.git "$W/repo"
mkdir -m 700 "$W/gnupg"
GNUPGHOME="$W/gnupg" gpg --batch --quiet --import packages/archlinuxhardened.asc 2>/dev/null
git -C "$W/repo" merge-base --is-ancestor "$cur" origin/master || { echo "pinned commit not on master" >&2; exit 1; }
new=""
for c in $(git -C "$W/repo" rev-list --first-parent "$cur..origin/master"); do
  if GNUPGHOME="$W/gnupg" git -C "$W/repo" verify-commit --raw "$c" 2>&1 | grep -qE "^\[GNUPG:\] VALIDSIG .* $fpr\$"; then
    new=$c; break
  fi
done
if [ -z "$new" ]; then echo "selinux packages up to date (${cur:0:10})"; exit 0; fi
sed -i "s/^SELINUX_COMMIT=.*/SELINUX_COMMIT=$new/" "$F"
echo "selinux packages ${cur:0:10} -> ${new:0:10}"
echo "archlinuxhardened/selinux ${cur:0:10} -> ${new:0:10} (signed by $fpr):" >> "${REPORT:-/dev/stderr}"
git -C "$W/repo" log --first-parent --format='  %h %s' "$cur..$new" >> "${REPORT:-/dev/stderr}"
