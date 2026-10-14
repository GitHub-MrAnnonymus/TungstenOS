#!/usr/bin/env bash
# Builds the TungstenOS installer ISO from the latest release, on an Arch Linux host.
# Base: archiso's releng profile (the official Arch ISO) plus gum, efitools and the
# installer, which starts on tty1. The release files are added to the finished ISO under
# /tungsten (outside the compressed live system); the installer copies them from there.
# The ISO boots with Secure Boot off (or the firmware in Setup Mode, to enroll the keys).
#
# Usage: install/build-iso.sh [output-dir]      (default: current directory)
# Needs: archiso xorriso curl gpg, sudo for mkarchiso
set -euo pipefail
OUT=$(realpath "${1:-.}")
HERE=$(dirname -- "$(realpath "$0")")
REPO=$HERE/..
. "$HERE/release.sh"

for t in mkarchiso xorriso gpgv; do
  command -v "$t" >/dev/null || { echo "$t not found: pacman -S --needed archiso libisoburn gnupg" >&2; exit 1; }
done
RELENG=/usr/share/archiso/configs/releng
[ -d "$RELENG" ] || { echo "$RELENG missing (package archiso)" >&2; exit 1; }

fetch_release || { echo "Cannot reach GitHub to download the latest release" >&2; exit 1; }
read -ra ext_files <<<"$(echo $exts)"
echo "Release $ver (extensions: ${ext_files[*]:-none})"
download "$usr" "$verity" "$uki" "$boot" "${ext_files[@]}"

WORK=$(mktemp -d -p /var/tmp tungsten-iso.XXXXXX)
trap 'sudo rm -rf "$WORK"' EXIT
P=$WORK/profile
cp -r "$RELENG" "$P"

# Identity of the ISO (the boot entries find it by label).
sed -i -e "s/^iso_name=.*/iso_name=\"tungsten-installer\"/" \
       -e "s/^iso_label=.*/iso_label=\"TUNGSTEN_${ver}\"/" \
       -e "s/^iso_publisher=.*/iso_publisher=\"TungstenOS\"/" \
       -e "s/^iso_application=.*/iso_application=\"TungstenOS installer\"/" \
       -e "s/^iso_version=.*/iso_version=\"${ver}\"/" "$P/profiledef.sh"
printf '%s\n' gum efitools tpm2-tools >> "$P/packages.x86_64"

# The installer and the public Secure Boot keys it enrolls (enroll-secureboot.sh finds
# them in ../keys).
D=/usr/local/share/tungsten
mkdir -p "$P/airootfs$D/install" "$P/airootfs$D/keys" "$P/airootfs/usr/local/bin"
cp "$HERE"/tungsten-installer "$HERE"/tungsten-install.sh "$HERE"/enroll-secureboot.sh "$P/airootfs$D/install/"
cp -r "$REPO"/keys/secureboot "$REPO"/keys/microsoft "$P/airootfs$D/keys/"
ln -s "$D/install/tungsten-installer" "$P/airootfs/usr/local/bin/tungsten-installer"
sed -i "/^file_permissions=(/a\\
  [\"$D/install/tungsten-installer\"]=\"0:0:755\"\\
  [\"$D/install/tungsten-install.sh\"]=\"0:0:755\"\\
  [\"$D/install/enroll-secureboot.sh\"]=\"0:0:755\"" "$P/profiledef.sh"

# Start the installer on the first console; leaving it drops to the usual Arch ISO shell.
cat >> "$P/airootfs/root/.zlogin" <<'EOF'

# TungstenOS: the installer on tty1.
if [[ $(tty) == /dev/tty1 ]]; then
  tungsten-installer
fi
EOF

sudo mkarchiso -v -w "$WORK/work" -o "$WORK/out" "$P"
base=$(echo "$WORK"/out/*.iso)

# Add the release outside the squashfs, keeping the boot setup.
iso=$OUT/tungsten-installer-$ver.iso
maps=()
for f in SHA256SUMS SHA256SUMS.gpg "$usr" "$verity" "$uki" "$boot" "${ext_files[@]}"; do
  maps+=(-map "$CACHE/$f" "/tungsten/$f")
done
rm -f "$iso"
xorriso -indev "$base" -outdev "$iso" "${maps[@]}" -boot_image any replay
sudo chown "$(id -u):$(id -g)" "$iso" 2>/dev/null || :
echo
echo "Built $iso ($(du -h "$iso" | cut -f1))."
echo "virt-manager: attach it as a CD-ROM to a UEFI VM (Q35, OVMF, TPM 2.0) and boot from it."
echo "USB stick: sudo dd if=$iso of=/dev/sdX bs=4M status=progress oflag=sync"
