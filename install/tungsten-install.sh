#!/usr/bin/env bash
# Installs TungstenOS onto a whole disk from a live Arch ISO.
# Usage: tungsten-install.sh [options] <disk|image-file> <release-dir>
# An image file (for a VM) is created as a sparse 48G file; firmware variables are left alone.
# Without options it asks; the installer TUI (tungsten-installer) answers through options:
#   --yes                    do not ask for confirmation before erasing the disk
#   --extensions=a,b|none    system extensions to install (default: ask)
#   --passphrase-file=FILE   recovery passphrase for the root partition (default: ask)
#   --no-enroll              do not offer Secure Boot key enrollment
#   --no-summary             do not print the next steps
set -euo pipefail

YES=0 EXT_ARG= PASS_FILE= ENROLL=1 SUMMARY=1
while [[ ${1:-} == --* ]]; do
  case $1 in
    --yes) YES=1 ;;
    --extensions=*) EXT_ARG=${1#*=} ;;
    --passphrase-file=*) PASS_FILE=${1#*=} ;;
    --no-enroll) ENROLL=0 ;;
    --no-summary) SUMMARY=0 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
DISK=${1:?target disk, e.g. /dev/nvme0n1, or a VM image file}
REL=$(realpath "${2:?directory with the release files}")
[ "$EUID" -eq 0 ] || { echo "Run as root" >&2; exit 1; }
VM=0; [ -b "$DISK" ] || VM=1
for t in systemd-repart mkfs.vfat mkfs.ext4 losetup; do
  command -v "$t" >/dev/null || { echo "$t not found: pacman -S --needed dosfstools e2fsprogs util-linux" >&2; exit 1; }
done

shopt -s nullglob
usrs=("$REL"/tungsten_*_*.usr.raw)
[ ${#usrs[@]} -eq 1 ] || { echo "expected exactly one tungsten_*.usr.raw in $REL" >&2; exit 1; }
USR=${usrs[0]}
name=$(basename "$USR" .usr.raw)            # <image-id>_<ver>_<uuid>
IMAGE_ID=${name%%_*}
VER=${name#"${IMAGE_ID}"_}; VER=${VER%%_*}
USR_UUID=${name##*_}
VERITY=$(echo "$REL/${IMAGE_ID}_${VER}"_*.usr-verity.raw)
VERITY_UUID=$(basename "$VERITY" .usr-verity.raw); VERITY_UUID=${VERITY_UUID##*_}
UKI="$REL/${IMAGE_ID}_${VER}.efi"
BOOT="$REL/${IMAGE_ID}_${VER}.systemd-bootx64.efi"
for f in "$VERITY" "$UKI" "$BOOT"; do [ -f "$f" ] || { echo "missing $f" >&2; exit 1; }; done
(cd "$REL" && sha256sum --check --ignore-missing SHA256SUMS)

if [ "$YES" = 0 ]; then
  echo "This ERASES $DISK and installs $IMAGE_ID $VER."
  read -r -p "Type the disk path again to continue: " confirm
  [ "$confirm" = "$DISK" ] || exit 1
fi

# System extensions; the default answer follows the detected hardware.
detect_nvidia() { grep -qsx 0x10de /sys/bus/pci/devices/*/vendor; }
detect_asus()   { grep -qsi asus /sys/class/dmi/id/sys_vendor; }
EXTS=()
if [ -n "$EXT_ARG" ]; then
  [ "$EXT_ARG" = none ] || IFS=, read -ra EXTS <<<"$EXT_ARG"
  for e in "${EXTS[@]}"; do
    [ -f "$REL/${e}_${VER}.raw" ] || { echo "no extension $e in $REL" >&2; exit 1; }
  done
fi
for e in nvidia asus; do
  [ -z "$EXT_ARG" ] || break
  [ -f "$REL/${e}_${VER}.raw" ] || continue
  if "detect_$e"; then
    read -r -p "Install the $e extension? (detected) [Y/n] " a; [ "${a,,}" = n ] || EXTS+=("$e")
  else
    read -r -p "Install the $e extension? (not detected) [y/N] " a; [ "${a,,}" = y ] && EXTS+=("$e")
  fi
done

DEFS=$(mktemp -d)
keyfile=$DEFS/key
trap 'shred -u "$keyfile" 2>/dev/null || :; rm -rf "$DEFS"' EXIT
cat > "$DEFS/00-esp.conf" <<EOF
[Partition]
Type=esp
Format=vfat
SizeMinBytes=2G
SizeMaxBytes=2G
EOF
cat > "$DEFS/10-usr-a.conf" <<EOF
[Partition]
Type=usr
Label=${IMAGE_ID}_${VER}
UUID=${USR_UUID}
CopyBlocks=${USR}
SizeMinBytes=8G
SizeMaxBytes=8G
ReadOnly=yes
EOF
cat > "$DEFS/11-usr-verity-a.conf" <<EOF
[Partition]
Type=usr-verity
Label=${IMAGE_ID}_${VER}
UUID=${VERITY_UUID}
CopyBlocks=${VERITY}
SizeMinBytes=512M
SizeMaxBytes=512M
ReadOnly=yes
EOF
cat > "$DEFS/20-usr-b.conf" <<EOF
[Partition]
Type=usr
Label=_empty
SizeMinBytes=8G
SizeMaxBytes=8G
EOF
cat > "$DEFS/21-usr-verity-b.conf" <<EOF
[Partition]
Type=usr-verity
Label=_empty
SizeMinBytes=512M
SizeMaxBytes=512M
EOF
# Writable root: /etc changes, /var, /home. Populated from /usr on first boot.
cat > "$DEFS/30-root.conf" <<EOF
[Partition]
Type=root
Label=root
Format=ext4
Encrypt=key-file
FactoryReset=yes
EOF
# Extensions go to the root partition, enabled as sysupdate features so they are updated.
STAGE=$DEFS/rootfs
[ ${#EXTS[@]} -eq 0 ] || echo "CopyFiles=$STAGE:/" >> "$DEFS/30-root.conf"
for e in "${EXTS[@]}"; do
  mkdir -p "$STAGE"/var/lib/extensions "$STAGE"/var/lib/extensions.d \
           "$STAGE"/var/lib/tungsten/etc/upper/sysupdate.d/"$e".feature.d
  ln -s "/var/lib/extensions.d/${e}_${VER}.raw" "$STAGE/var/lib/extensions/$e.raw"
  printf '[Feature]\nEnabled=true\n' > "$STAGE/var/lib/tungsten/etc/upper/sysupdate.d/$e.feature.d/10-enable.conf"
  echo "CopyFiles=$REL/${e}_${VER}.raw:/var/lib/extensions.d/${e}_${VER}.raw" >> "$DEFS/30-root.conf"
done

# Remains enrolled as the recovery key. Offline mode builds the partitions without
# mounting anything on this system.
# A disk is partitioned, encrypted and filled in place. An image file (VM) is built
# offline, without touching this system's devices: systemd-repart then creates each
# partition as a file in $TMPDIR (default /var/tmp) and encrypts it there, which needs
# as much free space as the root partition (sparse until encrypted). That is fine on a
# workstation, but not on a live ISO, whose /var/tmp is a small RAM overlay.
OFFLINE=no
[ "$VM" = 1 ] && OFFLINE=yes

if [ -n "$PASS_FILE" ]; then
  (umask 077; cat "$PASS_FILE" > "$keyfile")
else
  read -r -s -p "Recovery passphrase for the root partition: " pass; echo
  (umask 077; printf '%s' "$pass" > "$keyfile")
fi
[ "$VM" = 1 ] && truncate -s 48G "$DISK"
systemd-repart --dry-run=no --empty=force --definitions="$DEFS" \
  --key-file="$keyfile" --offline="$OFFLINE" "$DISK"
shred -u "$keyfile"
DEV=$DISK
[ "$VM" = 1 ] && { DEV=$(losetup --show -fP "$DISK"); udevadm settle; }

# The first UKI gets boot counting, as sysupdate does.
ESP=$(mktemp -d)
mount "$(lsblk -lnpo NAME,PARTTYPENAME "$DEV" | awk '/EFI System/ {print $1; exit}')" "$ESP"
install -Dm644 "$BOOT" "$ESP/EFI/systemd/systemd-bootx64.efi"
install -Dm644 "$BOOT" "$ESP/EFI/BOOT/BOOTX64.EFI"
install -Dm444 "$UKI" "$ESP/EFI/Linux/${IMAGE_ID}_${VER}+3-0.efi"
mkdir -p "$ESP/loader"
printf 'timeout 3\neditor no\n' > "$ESP/loader/loader.conf"
# VM images: a login on the serial port, which install/run-vm.sh connects to the host
# terminal (copy and paste work there). Unsigned add-ons load only without Secure Boot.
if [ "$VM" = 1 ]; then
  if command -v ukify >/dev/null; then
    mkdir -p "$ESP/loader/addons"
    ukify build --cmdline='console=ttyS0,115200 console=tty0 plymouth.ignore-serial-consoles systemd.wants=serial-getty@ttyS0.service' \
      --output="$ESP/loader/addons/vm-serial-console.addon.efi" >/dev/null
  else
    echo "ukify not found (package systemd-ukify): no serial console login in the terminal." >&2
  fi
fi
umount "$ESP"; rmdir "$ESP"
if [ "$VM" = 1 ]; then
  losetup -d "$DEV"
  echo "Installed $IMAGE_ID $VER (extensions: ${EXTS[*]:-none}) to $DISK. The VM firmware boots it from EFI/BOOT/BOOTX64.EFI."
  exit 0
fi
efibootmgr --create --disk "$DISK" --part 1 --label TungstenOS --loader '\EFI\systemd\systemd-bootx64.efi'

# Secure Boot enrollment requires Setup Mode.
SB_ENROLLED=0
if [ "$ENROLL" = 1 ] && [ "$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')" = 1 ]; then
  read -r -p "Firmware is in Setup Mode. Enroll TungstenOS Secure Boot keys now? [Y/n] " a
  if [ "${a,,}" != n ]; then "$(dirname -- "$0")/enroll-secureboot.sh" && SB_ENROLLED=1; fi
fi

[ "$SUMMARY" = 1 ] || exit 0
cat <<EOF
Installed $IMAGE_ID $VER with extensions: ${EXTS[*]:-none}.
1. Secure Boot: $( [ "$SB_ENROLLED" = 1 ] && echo "keys enrolled; enable Secure Boot in firmware setup if needed." || echo "put the firmware in Setup Mode, boot the live ISO again and run install/enroll-secureboot.sh." )
2. Boot and enter the recovery passphrase. The first boot then creates two
   accounts: an administrator (its password authorizes run0 and polkit; it cannot
   log in at the login screen) and your everyday account.
3. Log in with the everyday account and bind the root partition to the TPM with
   a systemd-pcrlock policy (run0 asks for the administrator's password):
     run0 tungsten-tpm-enroll
   It asks whether to require a PIN, and shows a pcrlock recovery PIN once;
   store that with the passphrase.
EOF
