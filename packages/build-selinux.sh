#!/usr/bin/env bash
# Builds archlinuxhardened's SELinux packages into $1 (default: ./out).
# Run as a non-root user with sudo for pacman; multilib must be enabled.
set -euo pipefail

# Must be a maintainer-signed merge commit (their binary repo is unsigned).
SELINUX_COMMIT=30b3051b203f9c48d9740b0488329dbf00cc1d39
MAINTAINER_FPR=E25E254C8EE4D303554BF5AFEC701A1DA494C5EB
HERE="$(dirname -- "$(realpath "$0")")"

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
    extra=()
    # systemd's tests fail under container seccomp filters
    [ "$pkg" = systemd-selinux ] && extra+=(--nocheck)
    [ "$pkg" = setools ] && export MAKEFLAGS=-j1
    if [ "$pkg" = selinux-refpolicy-arch ]; then
      printf '\nprepare() { cd "${srcdir}/${_reponame}" && bash %q; }\n' \
        "$HERE/refpolicy-user-exec-content.sh" >> PKGBUILD
    fi
    makepkg -s -C -f --noconfirm "${extra[@]}"
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
