#!/usr/bin/env bash
# Moves the vendored secureblue module blocklists to the newest signed commit that
# changed them, and regenerates kernel/config.slim. Exit 10 (review) on change.
set -euo pipefail
cd "$(dirname -- "$0")/../.."
S=scripts/update-secureblue-modprobe.sh
cur=$(sed -n 's/^COMMIT=//p' "$S")
auth=(); [ -n "${GH_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GH_TOKEN")
api=https://api.github.com/repos/secureblue/secureblue
c=$(curl -fsSL "${auth[@]}" "$api/commits?sha=live&path=files/system/usr/lib/modprobe.d&per_page=1")
new=$(jq -r '.[0].sha' <<<"$c")
[ "$new" != "$cur" ] || { echo "secureblue blocklist up to date"; exit 0; }
[ "$(jq -r '.[0].commit.verification.verified' <<<"$c")" = true ] || { echo "secureblue commit $new is not signed" >&2; exit 1; }
body() { grep -hv '^# Vendored from secureblue @' root_files/usr/lib/modprobe.d/secureblue*.conf; }
old_body=$(body)
old=$(grep -hE '^install ' root_files/usr/lib/modprobe.d/secureblue*.conf | sort)
sed -i "s/^COMMIT=.*/COMMIT=$new/" "$S"
"$S" >/dev/null
if [ "$(body)" = "$old_body" ]; then
  git checkout -- "$S" root_files/usr/lib/modprobe.d
  echo "secureblue blocklist unchanged upstream"; exit 0
fi
added=$(comm -13 <(echo "$old") <(grep -hE '^install ' root_files/usr/lib/modprobe.d/secureblue*.conf | sort))
removed=$(comm -23 <(echo "$old") <(grep -hE '^install ' root_files/usr/lib/modprobe.d/secureblue*.conf | sort))
if [ -z "$added$removed" ]; then
  echo "secureblue blocklist ${cur:0:10} -> ${new:0:10} (comments only)"
  echo "secureblue blocklist ${cur:0:10} -> ${new:0:10}: no module changes" >> "${REPORT:-/dev/stderr}"
  exit 0
fi
kernel/check-config.sh >/dev/null 2>&1 || :
{
  echo "secureblue module blocklist ${cur:0:10} -> ${new:0:10}"
  echo "Newly blocked (also removed from the kernel build):"; echo "${added:-  none}" | sed 's/^/  /'
  echo "No longer blocked:"; echo "${removed:-  none}" | sed 's/^/  /'
} >> "${REPORT:-/dev/stderr}"
echo "secureblue blocklist ${cur:0:10} -> ${new:0:10}"
exit 10
