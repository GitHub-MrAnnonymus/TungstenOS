#!/usr/bin/env bash
# Boots a TungstenOS VM image in QEMU with UEFI (OVMF, Secure Boot capable) and a software TPM.
# Firmware variables and TPM state persist next to the image in <image>.vm/.
# The terminal becomes the VM's serial port (ttyS0) with a login prompt (images from
# tungsten-install.sh): log in there to copy and paste. Ctrl+A C toggles the QEMU monitor,
# Ctrl+A X quits.
#
# Before booting, the latest GitHub release is installed into the image's inactive A/B
# slot, as systemd-sysupdate would do it: the signed SHA256SUMS is checked against
# keys/tungsten.pgp, the usr and verity images go to the older (or empty) partition pair
# with sysupdate's labels and UUIDs, the UKI goes to the ESP with fresh boot counting, and
# UKIs without a matching usr partition are removed. The usr partitions and the ESP are
# not encrypted, so no passphrase is needed; system extensions live on the encrypted root
# partition and are left alone (the VM updates them itself). Mounting the ESP uses sudo.
#
# If the image does not exist yet, the latest release is downloaded and installed into it
# with tungsten-install.sh (sudo).
#
# --release DIR uses a local build instead of the latest GitHub release (install/dev/vm.sh),
# checked against the SHA256SUMS in DIR, which carries no signature.
#
# Usage: install/run-vm.sh [--no-update] [--release DIR] <image-file>
# Needs: qemu-desktop edk2-ovmf swtpm, and for updates curl gpg jq util-linux
set -euo pipefail
UPDATE=1 LOCAL=
while [[ ${1:-} == --* ]]; do
  case $1 in
    --no-update) UPDATE=0 ;;
    --release) LOCAL=$(realpath "${2:?directory with a local build}"); shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
  shift
done
IMG=$(realpath -m "${1:?VM image file}")
HERE=$(dirname -- "$(realpath "$0")")
USR_TYPE=8484680C-9521-48C6-9C11-B0720656F69E
VERITY_TYPE=77FF5F63-E7B6-4633-ACF4-1565B864C0E6
. "$HERE/release.sh"

# The release to install: the latest on GitHub (downloaded into $CACHE), or the local build.
get_release() {
  if [ -n "$LOCAL" ]; then
    CACHE=$LOCAL
    release_names
    (cd "$CACHE" && sha256sum --check --ignore-missing --quiet SHA256SUMS) \
      || { echo "checksum mismatch in $CACHE" >&2; exit 1; }
  else
    fetch_release
  fi
}

# Prints "<number> <start sector> <size in sectors> <label>" for partitions of a GPT type.
partitions() {
  sfdisk -J "$IMG" | jq -r --arg img "$IMG" --arg t "$1" \
    '.partitiontable.partitions[] | select(.type == $t)
     | "\(.node | ltrimstr($img)) \(.start) \(.size) \(.name)"'
}

# Writes a file into a partition of the image (by offset; the image file is ours).
write_partition() {
  local file=$1 num=$2 start=$3 size=$4
  [ "$(stat -c %s "$file")" -le $((size * 512)) ] || { echo "$file does not fit partition $num" >&2; exit 1; }
  dd if="$file" of="$IMG" bs=4M seek=$((start * 512)) oflag=seek_bytes conv=notrunc,fsync status=progress
}

update_image() {
  if ! get_release; then
    echo "Could not check for updates; booting the installed image." >&2
    return 0
  fi
  if partitions "$USR_TYPE" | awk '{print $4}' | grep -qx "tungsten_$ver"; then
    echo "VM image is up to date ($ver)."
    return 0
  fi
  echo "Installing TungstenOS $ver into the VM image."
  [ -n "$LOCAL" ] || download "$usr" "$verity" "$uki"

  # Target: the empty usr partition, otherwise the one with the older version.
  local num='' start size old vnum='' vstart vsize label target
  # "_empty" sorts before "tungsten_<version>", and older versions before newer ones.
  target=$(partitions "$USR_TYPE" | sort -k4,4 | head -1)
  read -r num start size old <<<"$target"
  [ -n "$num" ] || { echo "no usr partition in $IMG" >&2; exit 1; }
  target=$(partitions "$VERITY_TYPE" | awk -v l="$old" '$4 == l' | head -1)
  read -r vnum vstart vsize label <<<"$target"
  [ -n "$vnum" ] || { echo "no verity partition labeled $old" >&2; exit 1; }

  echo "Writing usr to partition $num (was $old)"
  write_partition "$CACHE/$usr" "$num" "$start" "$size"
  write_partition "$CACHE/$verity" "$vnum" "$vstart" "$vsize"
  local uuid=${usr%.usr.raw}; uuid=${uuid##*_}
  local vuuid=${verity%.usr-verity.raw}; vuuid=${vuuid##*_}
  sfdisk -q --part-label "$IMG" "$num" "tungsten_$ver"
  sfdisk -q --part-uuid "$IMG" "$num" "$uuid"
  sfdisk -q --part-label "$IMG" "$vnum" "tungsten_$ver"
  sfdisk -q --part-uuid "$IMG" "$vnum" "$vuuid"

  # The ESP: the new UKI with boot counting; UKIs whose usr partition is gone are removed.
  local keep
  keep=$(partitions "$USR_TYPE" | awk '$4 ~ /^tungsten_/ {sub(/^tungsten_/, "", $4); print $4}' | tr '\n' ' ')
  echo "Updating the ESP (sudo)"
  sudo bash -euo pipefail -s "$IMG" "$CACHE/$uki" "$ver" "$keep" <<'EOF'
img=$1 uki=$2 ver=$3 keep=" $4"
loop=$(losetup -fP --show "$img")
mnt=$(mktemp -d)
trap 'umount "$mnt" 2>/dev/null; rmdir "$mnt"; losetup -d "$loop"' EXIT
udevadm settle
mount "${loop}p1" "$mnt"
for f in "$mnt"/EFI/Linux/tungsten_*.efi; do
  [ -e "$f" ] || continue
  v=$(basename "$f"); v=${v#tungsten_}; v=${v%%[+.]*}
  case $keep in *" $v "*) ;; *) echo "  removing $(basename "$f")"; rm -f "$f" ;; esac
done
install -Dm444 "$uki" "$mnt/EFI/Linux/tungsten_${ver}+3-0.efi"
echo "  installed tungsten_${ver}+3-0.efi"
EOF
  echo "Installed $ver. The TPM policy does not cover it yet: unlock with the passphrase,"
  echo "then run0 tungsten-tpm-enroll in the VM if you want TPM unlock."
}

if [ ! -e "$IMG" ]; then
  # No image yet: install the latest release with the regular installer.
  get_release || { echo "Cannot reach GitHub to download a release" >&2; exit 1; }
  [ -n "$LOCAL" ] || download "$usr" "$verity" "$uki" "$boot"
  echo "Creating $IMG with TungstenOS $ver (sudo)"
  sudo "$HERE/tungsten-install.sh" "$IMG" "$CACHE"
  sudo chown "$(id -u):$(id -g)" "$IMG"
elif [ "$UPDATE" = 1 ]; then
  if pgrep -f "file=$IMG," >/dev/null; then
    echo "The VM is already running; not updating its image." >&2
  else
    update_image
  fi
fi

OVMF=/usr/share/edk2/x64
STATE="${IMG%.*}.vm"
mkdir -p "$STATE/tpm"
[ -f "$STATE/OVMF_VARS.fd" ] || cp "$OVMF/OVMF_VARS.4m.fd" "$STATE/OVMF_VARS.fd"

swtpm socket --tpm2 --tpmstate dir="$STATE/tpm" \
  --ctrl type=unixio,path="$STATE/tpm.sock" --daemon --terminate
for _ in $(seq 50); do [ -S "$STATE/tpm.sock" ] && break; sleep 0.1; done

exec qemu-system-x86_64 \
  -machine q35,smm=on -accel kvm -cpu host -smp 4 -m 6G \
  -global driver=cfi.pflash01,property=secure,value=on \
  -drive if=pflash,format=raw,unit=0,readonly=on,file="$OVMF/OVMF_CODE.secboot.4m.fd" \
  -drive if=pflash,format=raw,unit=1,file="$STATE/OVMF_VARS.fd" \
  -chardev socket,id=chrtpm,path="$STATE/tpm.sock" \
  -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis,tpmdev=tpm0 \
  -drive file="$IMG",format=raw,if=virtio,cache=none \
  -device virtio-vga-gl -display gtk,gl=on \
  -device virtio-keyboard-pci -device virtio-tablet-pci \
  -nic user,model=virtio-net-pci \
  -serial mon:stdio
