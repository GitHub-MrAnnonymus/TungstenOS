#!/usr/bin/env bash
# Builds archlinuxhardened's SELinux packages into $1 (default: ./out).
# Run as a non-root user with sudo for pacman; multilib must be enabled.
set -euo pipefail

# Must be a maintainer-signed merge commit (their binary repo is unsigned).
SELINUX_COMMIT=3cf00b6b4104e94b634ad0067d17d9b2f8a67789
MAINTAINER_FPR=E25E254C8EE4D303554BF5AFEC701A1DA494C5EB
HERE="$(dirname -- "$(realpath "$0")")"
# Perl scripts (e.g. po4a for util-linux) live here; normally added by a login shell.
export PATH="$PATH:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl"

OUT="$(realpath -m "${1:-out}")"
mkdir -p "$OUT"
SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT

git clone -q https://github.com/archlinuxhardened/selinux.git "$SRC"
git -C "$SRC" checkout -q "$SELINUX_COMMIT"

# Verify the pinned commit with the vendored maintainer key only.
VERIFY_HOME="$(mktemp -d)"
GNUPGHOME="$VERIFY_HOME" gpg --batch --quiet --import "$HERE/archlinuxhardened.asc"
if ! GNUPGHOME="$VERIFY_HOME" git -C "$SRC" verify-commit --raw "$SELINUX_COMMIT" 2>&1 \
     | grep -qE "^\[GNUPG:\] VALIDSIG .* ${MAINTAINER_FPR}\$"; then
  echo "archlinuxhardened commit $SELINUX_COMMIT is not signed by $MAINTAINER_FPR" >&2
  exit 1
fi
rm -rf "$VERIFY_HOME"
echo "archlinuxhardened $SELINUX_COMMIT: good signature from $MAINTAINER_FPR"

# Upstream source signing keys, trusted via the signed commit.
gpg --batch --quiet --import "$SRC"/_pgp_cache/*.asc
shopt -s nullglob
keys=("$SRC"/*/keys/pgp/*.asc)
[ ${#keys[@]} -gt 0 ] && gpg --batch --quiet --import "${keys[@]}"
shopt -u nullglob

# Fetch GNU sources from GitHub mirrors instead of git.savannah.gnu.org, which
# has frequent outages. makepkg still verifies the signed release tags (?signed),
# and gnulib is pinned by commit in those tags. Scoped to this process via env.
export GIT_CONFIG_COUNT=3
export GIT_CONFIG_KEY_0=url.https://github.com/coreutils/coreutils.git.insteadOf
export GIT_CONFIG_VALUE_0=https://git.savannah.gnu.org/git/coreutils.git
export GIT_CONFIG_KEY_1=url.https://github.com/coreutils/gnulib.git.insteadOf
export GIT_CONFIG_VALUE_1=https://git.savannah.gnu.org/git/gnulib.git
export GIT_CONFIG_KEY_2=url.https://github.com/sailfishos-mirror/findutils.git.insteadOf
export GIT_CONFIG_VALUE_2=https://git.savannah.gnu.org/git/findutils.git

# Build order from upstream's build_and_install_all.sh (util-linux/systemd twice).
PKGS=(
  libsepol libselinux checkpolicy secilc libsemanage policycoreutils
  semodule-utils setools selinux-python
  pambase-selinux pam-selinux coreutils-selinux findutils-selinux
  iproute2-selinux psmisc-selinux shadow-selinux
  util-linux-selinux systemd-selinux util-linux-selinux systemd-selinux
  dbus-broker-selinux selinux-refpolicy-arch
)

for pkg in "${PKGS[@]}"; do
  echo "::group::$pkg"
  (
    cd "$SRC/$pkg"
    rm -f ./*.pkg.tar.zst
    # Test suites are skipped: the same sources are tested by Arch and upstream,
    # and running them all exceeds the 6 h CI job limit.
    extra=(--nocheck)
    export MAKEFLAGS="-j$(nproc)"
    [ "$pkg" = setools ] && export MAKEFLAGS=-j1   # as upstream builds it
    if [ "$pkg" = selinux-refpolicy-arch ]; then
      printf '\nprepare() { cd "${srcdir}/${_reponame}" && bash %q; }\n' \
        "$HERE/refpolicy-user-exec-content.sh" >> PKGBUILD
    fi
    # Download and verify sources with retries, then build without re-fetching.
    for attempt in 1 2 3 4 5; do
      makepkg --verifysource --noconfirm && break
      [ "$attempt" -eq 5 ] && { echo "source download failed for $pkg" >&2; exit 1; }
      echo "source download failed, retrying in $((attempt * 2)) minutes" >&2
      sleep $((attempt * 120))
    done
    makepkg -s -C -f --holdver --noconfirm "${extra[@]}"
    # --ask=4: replace the conflicting non-SELinux package
    sudo pacman -U --noconfirm --ask=4 ./*.pkg.tar.zst
    cp ./*.pkg.tar.zst "$OUT/"
  )
  echo "::endgroup::"
done

# Needs libselinux from above.
(
  cd "$HERE/erofs-utils-selinux"
  makepkg -s -C -f --noconfirm
  mv ./*.pkg.tar.zst "$OUT/"
)
