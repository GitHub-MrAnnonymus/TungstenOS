#!/usr/bin/env bash
# Runs every updater. Verified routine updates (exit 0) are committed to the current
# branch and pushed; updates that need review (exit 10) go to auto/<name> branches
# with a pull request. Writes the package groups to rebuild to $GITHUB_OUTPUT.
set -euo pipefail
cd "$(dirname -- "$0")/../.."
BRANCH=$(git rev-parse --abbrev-ref HEAD)
START=$(git rev-parse HEAD)
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
failed=()

push_branch() { [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$BRANCH")" ] || git push -q origin "$BRANCH"; }

open_pr() {
  local name=$1 title=$2 body=$3 b=auto/$1
  push_branch
  git stash push -q -u
  git checkout -q -B "$b"
  git stash pop -q
  git add -A
  git commit -q -m "$title" -m "$body"
  local mine theirs=""
  mine=$(git diff HEAD~1 HEAD | git patch-id --stable | cut -d' ' -f1)
  if git fetch -q origin "$b" 2>/dev/null; then
    theirs=$(git diff "origin/$BRANCH...FETCH_HEAD" | git patch-id --stable | cut -d' ' -f1)
  fi
  if [ "$mine" = "$theirs" ] && gh pr view "$b" --json state -q .state 2>/dev/null | grep -qx OPEN; then
    echo "  pull request for $b is already up to date"
  else
    git push -q -f origin "$b"
    if gh pr view "$b" --json state -q .state 2>/dev/null | grep -qx OPEN; then
      gh pr edit "$b" --title "$title" --body "$body" >/dev/null
    else
      gh pr create --base "$BRANCH" --head "$b" --title "$title" --body "$body" >/dev/null
    fi
    echo "  pull request: $b"
  fi
  git checkout -q "$BRANCH"
}

run() {
  local name=$1 out rc=0 report
  shift
  report=$(mktemp)
  out=$(REPORT=$report GNUPGHOME=$(mktemp -d) "$@") || rc=$?
  echo "$name: ${out:-no output} (exit $rc)"
  if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    [ "$rc" -eq 0 ] || [ "$rc" -eq 10 ] || failed+=("$name")
    return 0
  fi
  local body; body=$( [ -s "$report" ] && cat "$report" || echo "$out" )
  case $rc in
    0)  git add -A; git commit -q -m "Update $name" -m "$body" ;;
    10) open_pr "$name" "Update $name" "$body" ;;
    *)  failed+=("$name"); git checkout -q -- .; git clean -fdq ;;
  esac
}

run trivalent       python3 packages/trivalent/update.py
run nvidia          kernel/sync-nvidia.sh
run erofs-utils     scripts/update/erofs-utils.sh
run selinux         scripts/update/selinux.sh
run kernel          kernel/update-kernel.sh
run secureblue      scripts/update/secureblue.sh
run hardened_malloc scripts/update/hardened-malloc.sh
run dms-greeter     scripts/update/greeter.sh
run qt-rebuild      scripts/update/qt-rebuild.sh
push_branch

changed=$(git diff --name-only "$START" HEAD)
groups=()
grep -qE '^kernel/(PKGBUILD|config\.(base|fragment|slim)|patches/|patch-overrides/)' <<<"$changed" && groups+=(kernel)
grep -qE '^packages/(build-selinux\.sh|refpolicy-user-exec-content\.sh|archlinuxhardened\.asc|erofs-utils-selinux/)' <<<"$changed" && groups+=(selinux)
grep -qE '^packages/(trivalent|hardened_malloc|greetd-dms-greeter|usbguard-notifier|quickshell|no_rlimit_as|qtengine)/' <<<"$changed" && groups+=(misc)
echo "groups=${groups[*]}" >> "${GITHUB_OUTPUT:-/dev/stdout}"

if [ ${#failed[@]} -gt 0 ]; then
  echo "updaters failed: ${failed[*]}" >&2
  exit 1
fi
