#!/usr/bin/env bash
# Builds the TungstenOS ISO from the latest release, on an Arch Linux host. Boot entries:
#   TungstenOS live       (default) the release itself, with /usr from this medium and the
#                         root file system in memory (build-live-uki.sh); disks stay untouched
#   ... kernel messages   the same with the kernel log on screen instead of the splash
#   TungstenOS installer  archiso's releng profile (the official Arch ISO) plus gum,
#                         efitools and the installer, which starts on tty1
# The release files are added to the finished ISO under /tungsten (outside the compressed
# Arch system); the live system runs from them and the installer copies them from there.
# The ISO boots with Secure Boot off (or the firmware in Setup Mode, to enroll the keys).
# The kernel has no CD-ROM driver: the live system starts from a USB stick or disk only.
#
# --dev builds it from the newest development build (install/dev/build.sh) instead, with
# the development Secure Boot keys for enrollment (public files only), for VMs: choose
# "TungstenOS only" there, as the Microsoft enrollment files are signed by the release keys.
#
# Usage: install/build-iso.sh [--dev] [output-dir]      (default: current directory)
# Needs: archiso xorriso curl gpg, sudo for mkarchiso, and for the live system
#        systemd-ukify binutils erofs-utils libarchive
set -euo pipefail
DEV=
if [ "${1:-}" = --dev ]; then
  DEV=$(realpath -m "${TUNGSTEN_DEV:-$HOME/.local/share/tungstenos-dev}"); shift
  [ -f "$DEV/builds/latest/SHA256SUMS" ] || { echo "No development build in $DEV/builds: run install/dev/build.sh" >&2; exit 1; }
  CACHE=$(realpath "$DEV/builds/latest")
fi
OUT=$(realpath "${1:-.}")
HERE=$(dirname -- "$(realpath "$0")")
REPO=$HERE/..
. "$HERE/release.sh"

for t in mkarchiso xorriso gpgv; do
  command -v "$t" >/dev/null || { echo "$t not found: pacman -S --needed archiso libisoburn gnupg" >&2; exit 1; }
done
RELENG=/usr/share/archiso/configs/releng
[ -d "$RELENG" ] || { echo "$RELENG missing (package archiso)" >&2; exit 1; }

if [ -n "$DEV" ]; then
  release_names
  (cd "$CACHE" && sha256sum --check --quiet SHA256SUMS) || { echo "checksum mismatch in $CACHE" >&2; exit 1; }
else
  fetch_release || { echo "Cannot reach GitHub to download the latest release" >&2; exit 1; }
fi
read -ra ext_files <<<"$(echo $exts)"
echo "Release $ver${DEV:+ (development build)} (extensions: ${ext_files[*]:-none})"
[ -n "$DEV" ] || download "$usr" "$verity" "$uki" "$boot" "${ext_files[@]}"

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

# The live system, the default entry. mkarchiso copies boot/vmlinuz-* from the Arch system
# into the EFI system partition (where systemd-boot can read it) and removes it from /boot.
LIVE=vmlinuz-tungsten-live.efi
mkdir -p "$P/airootfs/boot"
CACHE=$CACHE ver=$ver usr=$usr verity=$verity uki=$uki \
  "$HERE/build-live-uki.sh" "$P/airootfs/boot/$LIVE" "TUNGSTEN_${ver}"
# With Secure Boot off, systemd-stub takes the command line from the boot entry.
debug=$(objcopy -O binary --only-section=.cmdline "$P/airootfs/boot/$LIVE" /dev/stdout | tr -d '\0' \
  | sed -E 's/ (quiet|splash)\b//g; s/\bloglevel=0\b/loglevel=7/; s/$/ plymouth.enable=0/')
E=$P/efiboot/loader/entries
cat > "$E/00-tungsten-live.conf" <<EOF
title    TungstenOS live
sort-key 00
efi      /%INSTALL_DIR%/boot/%ARCH%/$LIVE
EOF
cat > "$E/00-tungsten-live-debug.conf" <<EOF
title    TungstenOS live, kernel messages
sort-key 00-debug
efi      /%INSTALL_DIR%/boot/%ARCH%/$LIVE
options  $debug
EOF
sed -i 's/^title .*/title    TungstenOS installer (Arch Linux live)/' "$E/01-archiso-linux.conf"
sed -i 's/^title .*/title    TungstenOS installer (Arch Linux live) with speech/' "$E/02-archiso-speech-linux.conf"
sed -i 's/^default .*/default 00-tungsten-live.conf/' "$P/efiboot/loader/loader.conf"

# The installer and the public Secure Boot keys it enrolls (enroll-secureboot.sh finds
# them in ../keys).
D=/usr/local/share/tungsten
mkdir -p "$P/airootfs$D/install" "$P/airootfs$D/keys" "$P/airootfs/usr/local/bin"
cp "$HERE"/tungsten-installer "$HERE"/tungsten-install.sh "$HERE"/enroll-secureboot.sh "$P/airootfs$D/install/"
if [ -n "$DEV" ]; then
  mkdir -p "$P/airootfs$D/keys/secureboot"
  cp "$DEV"/keys/{PK,KEK,db}.{auth,crt} "$DEV"/keys/GUID "$P/airootfs$D/keys/secureboot/"
  cp -r "$REPO"/keys/microsoft "$P/airootfs$D/keys/"
else
  cp -r "$REPO"/keys/secureboot "$REPO"/keys/microsoft "$P/airootfs$D/keys/"
fi
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
iso=$OUT/tungsten-installer${DEV:+-dev}-$ver.iso
maps=()
for f in SHA256SUMS SHA256SUMS.gpg "$usr" "$verity" "$uki" "$boot" "${ext_files[@]}"; do
  [ -e "$CACHE/$f" ] || continue   # development builds have no SHA256SUMS.gpg
  maps+=(-map "$CACHE/$f" "/tungsten/$f")
done
rm -f "$iso"
xorriso -indev "$base" -outdev "$iso" "${maps[@]}" -boot_image any replay
sudo chown "$(id -u):$(id -g)" "$iso" 2>/dev/null || :
echo
echo "Built $iso ($(du -h "$iso" | cut -f1))."
echo "virt-manager: attach it as a USB or VirtIO disk (the kernel has no CD-ROM driver) to a UEFI VM"
echo "(Q35, OVMF, TPM 2.0) and boot from it."
echo "USB stick: sudo dd if=$iso of=/dev/sdX bs=4M status=progress oflag=sync"
