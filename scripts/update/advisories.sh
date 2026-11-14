#!/usr/bin/env bash
# Opens an issue (assigned to the repository owner) for each new security advisory of
# systemd: TungstenOS builds on homed, nsresourced, journald and systemd-boot/-stub, which
# are signed for Secure Boot. Advisories for the boot chain may call for revoking earlier
# builds (keys/sign-efi-update.sh dbx-hash). Advisories older than 60 days are skipped, so
# the first run does not open issues for history; each advisory is reported once.
set -euo pipefail
REPO=${GITHUB_REPOSITORY:?}
OWNER=${GITHUB_REPOSITORY_OWNER:-}
since=$(date -u -d '-60 days' +%Y-%m-%d)
arch_systemd=$(curl -fsS "https://archlinux.org/packages/search/json/?name=systemd&repo=Core" |
  jq -r '.results[0] | .pkgver + "-" + .pkgrel' 2>/dev/null || echo unknown)

curl -fsS "https://api.github.com/repos/systemd/systemd/security-advisories?per_page=50&sort=published&direction=desc" |
jq -c --arg since "$since" '.[] | select(.published_at >= $since)' |
while read -r a; do
  id=$(jq -r .ghsa_id <<<"$a")
  if gh issue list --repo "$REPO" --state all --search "$id in:title" --json number -q '.[0].number' | grep -q .; then
    continue
  fi
  summary=$(jq -r .summary <<<"$a"); severity=$(jq -r .severity <<<"$a")
  cve=$(jq -r '.cve_id // empty' <<<"$a"); url=$(jq -r .html_url <<<"$a")
  components=$(jq -r '[.vulnerabilities[]?.package.name // empty] | unique | join(", ")' <<<"$a")
  patched=$(jq -r '[.vulnerabilities[]?.patched_versions // empty] | unique | join("; ")' <<<"$a")
  boot=""
  if grep -qiE 'systemd-(boot|stub)|sd-boot|bootctl|\bUKI\b|secure ?boot|ukify' <<<"$summary $components"; then
    boot=$'\n\n**Boot chain:** this concerns code TungstenOS signs for Secure Boot. If it allows bypassing Secure Boot, release a fixed build and revoke the affected systemd-boot and UKIs: `keys/sign-efi-update.sh <private-dir> <name> dbx-hash <files>` (README, "Secure Boot revocations").'
  fi
  body="**${severity}** · ${components:-systemd}${cve:+ · $cve}

${summary}

- Patched in: ${patched:-see the advisory}
- systemd in Arch [core] now: ${arch_systemd} (TungstenOS uses Arch Linux Hardened's -selinux build of the same version)
- Advisory: ${url}${boot}"
  title="systemd advisory ${id}: ${summary}"
  gh issue create --repo "$REPO" --title "${title:0:200}" --body "$body" ${OWNER:+--assignee "$OWNER"} >/dev/null
  echo "issue opened for $id"
done
