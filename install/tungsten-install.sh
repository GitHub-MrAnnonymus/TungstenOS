#!/usr/bin/env bash
# Installs TungstenOS onto a whole disk from a live Arch ISO.
# Usage: [IMAGE_ID=tungsten-<variant>] tungsten-install.sh <disk> <release-dir>
set -euo pipefail

DISK=${1:?target disk, e.g. /dev/nvme0n1}
REL=$(realpath "${2:?directory with the release files}")
[ "$EUID" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

shopt -s nullglob
usrs=("$REL"/"${IMAGE_ID:-tungsten-*}"_*_*.usr.raw)
[ ${#usrs[@]} -eq 1 ] || { echo "expected exactly one *.usr.raw in $REL (set IMAGE_ID to choose)" >&2; exit 1; }
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

echo "This ERASES $DISK and installs $IMAGE_ID $VER."
read -r -p "Type the disk path again to continue: " confirm
[ "$confirm" = "$DISK" ] || exit 1

DEFS=$(mktemp -d)
trap 'rm -rf "$DEFS"' EXIT
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

# Remains enrolled as the recovery key.
read -r -s -p "Recovery passphrase for the root partition: " pass; echo
keyfile=$(mktemp); printf '%s' "$pass" > "$keyfile"
systemd-repart --dry-run=no --empty=force --definitions="$DEFS" \
  --key-file="$keyfile" "$DISK"
shred -u "$keyfile"

# The first UKI gets boot counting, as sysupdate does.
ESP=$(mktemp -d)
mount "$(lsblk -lnpo NAME,PARTTYPENAME "$DISK" | awk '/EFI System/ {print $1; exit}')" "$ESP"
install -Dm644 "$BOOT" "$ESP/EFI/systemd/systemd-bootx64.efi"
install -Dm644 "$BOOT" "$ESP/EFI/BOOT/BOOTX64.EFI"
install -Dm444 "$UKI" "$ESP/EFI/Linux/${IMAGE_ID}_${VER}+3-0.efi"
mkdir -p "$ESP/loader"
printf 'timeout 3\neditor no\n' > "$ESP/loader/loader.conf"
umount "$ESP"; rmdir "$ESP"
efibootmgr --create --disk "$DISK" --part 1 --label TungstenOS --loader '\EFI\systemd\systemd-bootx64.efi'

# Secure Boot enrollment requires Setup Mode.
SB_ENROLLED=0
if [ "$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SetupMode-8be4df61-93ca-11d2-aa0d-00e098032b8c 2>/dev/null | tr -d ' ')" = 1 ]; then
  read -r -p "Firmware is in Setup Mode. Enroll TungstenOS Secure Boot keys now? [Y/n] " a
  if [ "${a,,}" != n ]; then "$(dirname -- "$0")/enroll-secureboot.sh" && SB_ENROLLED=1; fi
fi

cat <<EOF
Installed $IMAGE_ID $VER.
1. Secure Boot: $( [ "$SB_ENROLLED" = 1 ] && echo "keys enrolled; enable Secure Boot in firmware setup if needed." || echo "put the firmware in Setup Mode, boot the live ISO again and run install/enroll-secureboot.sh." )
2. Boot and enter the recovery passphrase. systemd-homed-firstboot then
   asks you to create a user: make this first one the admin (add it to wheel).
3. Bind the root partition to the TPM with a systemd-pcrlock policy:
     run0 tungsten-tpm-enroll
   It asks whether to require a PIN, and shows a pcrlock recovery PIN once;
   store that with the passphrase.
4. Create your everyday account outside wheel, like secureblue recommends:
     run0 homectl create <you> --storage=luks
EOF
