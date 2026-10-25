#!/usr/bin/env bash
# Runs inside the archlinux container of install/dev/build.sh. Prepares it as the CI build
# job does (.github/workflows/build.yml), creates the development keys on the first run,
# builds with build.sh and copies the result to /state/builds/<version>.
set -euo pipefail
K=/state/keys
OWNER=$HOST_UID:$HOST_GID
# The keys and builds belong to the user; pkgcache stays pacman's.
trap 'chown "$OWNER" /state; chown -R "$OWNER" /state/keys /state/builds 2>/dev/null || :' EXIT

# --- Container, as in CI ---
printf 'Server = %s/$repo/os/$arch\n' https://fastly.mirror.pkgbuild.com https://geo.mirror.pkgbuild.com \
  https://mirror.rackspace.com/archlinux https://mirrors.kernel.org/archlinux > /etc/pacman.d/mirrorlist
pacman-key --init
pacman -Sy --noconfirm --needed archlinux-keyring
pacman-key --add /src/keys/tungsten.pgp
KEY=$(gpg --show-keys --with-colons /src/keys/tungsten.pgp | awk -F: '/^fpr/ {print $10; exit}')
pacman-key --lsign-key "$KEY"
TUNGSTEN_REPO=https://github.com/GitHub-MrAnnonymus/TungstenOS/releases/download/packages
awk -v repo="$TUNGSTEN_REPO" '/^\[core\]/ && !d { print "[tungsten]\nServer = " repo "\n"; d=1 } { print }' \
  /etc/pacman.conf > /tmp/p.conf
mv /tmp/p.conf /etc/pacman.conf
pacman -Syu --noconfirm base arch-install-scripts erofs-utils-selinux sbsigntools systemd-ukify \
  openssl cryptsetup libcap jq efitools

# --- Development keys (first run) ---
# The same hierarchy as keys/make-secureboot-keys.sh and keys/make-pcr-key.sh, with the
# enrollment files for systemd-boot (install/dev/vm.sh puts them on the VM's ESP).
if [ ! -f "$K/db.key" ]; then
  mkdir -p "$K" && chmod 700 "$K"
  W=$(mktemp -d)
  GUID=$(uuidgen --random)
  echo "$GUID" > "$K/GUID"
  for k in PK KEK db; do
    openssl req -new -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
      -subj "/CN=TungstenOS development $k/" -keyout "$K/$k.key" -out "$K/$k.crt"
    cert-to-efi-sig-list -g "$GUID" "$K/$k.crt" "$W/$k.esl"
  done
  sign-efi-sig-list -g "$GUID" -k "$K/PK.key"  -c "$K/PK.crt"  PK  "$W/PK.esl"  "$K/PK.auth"
  sign-efi-sig-list -g "$GUID" -k "$K/PK.key"  -c "$K/PK.crt"  KEK "$W/KEK.esl" "$K/KEK.auth"
  sign-efi-sig-list -g "$GUID" -k "$K/KEK.key" -c "$K/KEK.crt" db  "$W/db.esl"  "$K/db.auth"
  cp "$K/db.crt" "$K/db.pem"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$K/tpm2-pcr-private-key.pem"
  openssl pkey -in "$K/tpm2-pcr-private-key.pem" -pubout -out "$K/tpm2-pcr-public-key.pem"
  chmod 600 "$K"/*.key "$K"/tpm2-pcr-private-key.pem
  rm -rf "$W"
fi

# --- Build ---
TAG=$(date -u +'%Y%m%d%H%M')
OS_BUILD_TAG=$TAG UPDATE_URL=https://tungsten.invalid/ TUNGSTEN_REPO=$TUNGSTEN_REPO SB_DIR=$K \
  bash /src/build.sh
B=/state/builds/$TAG
mkdir -p "$B"
cp /tungsten/out/* "$B/"
(cd "$B" && sha256sum -- * > SHA256SUMS)
ln -sfn "$TAG" /state/builds/latest
