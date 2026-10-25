#!/usr/bin/env bash
# Builds the UKI of the TungstenOS live system from the latest release: the release's kernel,
# initramfs, microcode and systemd-stub, plus a small initramfs (install/live/) that runs
# /usr from the release files on the boot medium (found by its file system label, as
# build-iso.sh adds them under /tungsten) and the root file system in memory.
#
# The command line is the release's with these changes:
#   root=/dev/zram0, discard      a new ext4 in compressed memory, as after a factory reset
#   systemd.verity_usr_data/hash  /usr from loop devices of the release files
#   luks=no systemd.gpt_auto=0    never unlock or mount partitions of the computer's disks
#                                 (luks=: in the initrd and the booted system, which
#                                 reads /etc/crypttab too)
#   systemd.mask=                 no root partition creation, updates or pcrlock predictions
#   efi_pstore.pstore_disable=0   a kernel panic is kept in an EFI variable; the next boot
#                                 saves it to /var/lib/systemd/pstore
# The UKI is not signed (no Secure Boot keys here): it boots with Secure Boot off or with the
# firmware in Setup Mode, like the rest of the ISO.
#
# Usage: install/build-live-uki.sh <output.efi> [medium label]   (default: TUNGSTEN_<version>)
# Needs: systemd-ukify binutils erofs-utils libarchive, curl gpg
set -euo pipefail
OUTPUT=$(realpath -m "${1:?output UKI}")
HERE=$(dirname -- "$(realpath "$0")")
. "$HERE/release.sh"

for t in ukify objcopy dump.erofs bsdtar; do
  command -v "$t" >/dev/null || { echo "$t not found: pacman -S --needed systemd-ukify binutils erofs-utils libarchive" >&2; exit 1; }
done
# build-iso.sh passes the release it has downloaded (ver usr verity uki).
if [ -z "${ver:-}" ]; then
  fetch_release || { echo "Cannot reach GitHub to download the latest release" >&2; exit 1; }
  download "$usr" "$verity" "$uki"
fi
LABEL=${2:-TUNGSTEN_$ver}

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
for s in linux initrd ucode osrel cmdline; do
  objcopy -O binary --only-section=".$s" "$CACHE/$uki" "$T/$s"
done
# The image's own stub, so the live system boots exactly as the installed one.
dump.erofs --cat --path=/lib/systemd/boot/efi/linuxx64.efi.stub "$CACHE/$usr" > "$T/stub.efi"

# The live initramfs, unpacked over the release's.
R=$T/root
install -Dm644 "$HERE/live/tungsten-live.service" "$R/etc/systemd/system/tungsten-live.service"
mkdir -p "$R/etc/systemd/system/initrd-root-device.target.wants"
ln -s ../tungsten-live.service "$R/etc/systemd/system/initrd-root-device.target.wants/"
install -Dm755 "$HERE/live/setup" "$R/usr/lib/tungsten/live-setup"
install -Dm644 "$HERE/live/60-tungsten-live.rules" "$R/usr/lib/udev/rules.d/60-tungsten-live.rules"
printf 'LABEL=%s\nVERSION=%s\nUSR=%s\nVERITY=%s\n' "$LABEL" "$ver" "$usr" "$verity" > "$R/etc/tungsten-live.conf"
chmod 644 "$R/etc/tungsten-live.conf"
(cd "$R" && bsdtar --format newc --uid 0 --gid 0 -cf "$T/live.cpio" etc usr)

cmdline=$(tr -d '\0' < "$T/cmdline")
grep -qw 'root=/dev/mapper/root' <<<"$cmdline" && grep -qw 'rootflags=[^ ]*' <<<"$cmdline" \
  || { echo "Unexpected command line in $uki: $cmdline" >&2; exit 1; }
cmdline=$(sed -e 's|root=/dev/mapper/root|root=/dev/zram0|' -e 's|rootflags=\([^ ]*\)|rootflags=\1,discard|' <<<"$cmdline")
cmdline+=" systemd.verity_usr_data=/dev/disk/tungsten-live/usr"
cmdline+=" systemd.verity_usr_hash=/dev/disk/tungsten-live/usr-verity"
cmdline+=" luks=no systemd.gpt_auto=0"
cmdline+=" systemd.mask=systemd-repart.service systemd.mask=systemd-sysupdate.timer"
cmdline+=" systemd.mask=tungsten-pcrlock-predict.service"
cmdline+=" efi_pstore.pstore_disable=0"

ukify build --stub "$T/stub.efi" --linux "$T/linux" --initrd "$T/initrd" --initrd "$T/live.cpio" \
  --microcode "$T/ucode" --os-release "@$T/osrel" --cmdline "$cmdline" --output "$OUTPUT"
echo "Built $OUTPUT (TungstenOS $ver live, medium label $LABEL)."
