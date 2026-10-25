#!/usr/bin/env bash
# Runs the newest development build (install/dev/build.sh) in a VM with Secure Boot on,
# under firmware that trusts only the development keys.
#
# The first run creates the VM image with tungsten-install.sh (sudo; it asks for the
# recovery passphrase) and prepares its ESP:
#   loader/keys/auto/  the development PK, KEK and db, which systemd-boot enrolls by
#                      itself in the VM's Setup Mode firmware (secure-boot-enroll if-safe
#                      enrolls only the key set named "auto"), then restarts the VM with
#                      Secure Boot on
#   the serial console add-on, signed with the development db key (unsigned add-ons do
#   not load under Secure Boot)
# Later runs install each new build into the inactive A/B slot (run-vm.sh --release).
#
# --debug-shell on|off adds or removes an add-on, signed with the development db key, for
# debugging a boot that never reaches a login: systemd's debug shell (root, no password) on
# the serial console, the terminal, instead of the serial login, and the whole boot output
# there too (no splash, kernel log level 7, the serial port as /dev/console: the last
# console= wins, so the add-on's name sorts after vm-serial-console). Then it starts the VM.
#
# Usage: install/dev/vm.sh [--debug-shell on|off] [image-file]
#        (default image: $TUNGSTEN_DEV/vm/tungsten-dev.img)
# Needs: the run-vm.sh tools, mtools, systemd-ukify
set -euo pipefail
DEBUG=
if [ "${1:-}" = --debug-shell ]; then
  DEBUG=${2:?on or off}; shift 2
  case $DEBUG in on|off) ;; *) echo "--debug-shell takes on or off" >&2; exit 2 ;; esac
fi
HERE=$(dirname -- "$(realpath "$0")")
DEV=$(realpath -m "${TUNGSTEN_DEV:-$HOME/.local/share/tungstenos-dev}")
K=$DEV/keys
B=$DEV/builds/latest
[ -f "$B/SHA256SUMS" ] || { echo "No development build in $DEV/builds: run install/dev/build.sh" >&2; exit 1; }
IMG=$(realpath -m "${1:-$DEV/vm/tungsten-dev.img}")
ESP_TYPE=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# The ESP of the image, by its offset (mtools needs no loop device).
esp() {
  local start
  start=$(sfdisk -J "$IMG" | jq -r --arg t "$ESP_TYPE" '.partitiontable.partitions[] | select(.type == $t) | .start')
  echo "$IMG@@$((start * 512))"
}
# Builds a command line add-on signed with the development db key.
signed_addon() {
  ukify build --cmdline="$1" --signtool=systemd-sbsign \
    --secureboot-private-key="$K/db.key" --secureboot-certificate="$K/db.crt" --output="$2" >/dev/null
}

if [ ! -e "$IMG" ]; then
  for t in mcopy ukify jq; do
    command -v "$t" >/dev/null || { echo "$t not found: pacman -S --needed mtools systemd-ukify jq" >&2; exit 1; }
  done
  mkdir -p "$(dirname "$IMG")"
  sudo "$HERE/../tungsten-install.sh" --yes --extensions=none --no-summary "$IMG" "$B"
  sudo chown "$(id -u):$(id -g)" "$IMG"

  E=$(esp)
  mmd -i "$E" ::/loader/keys ::/loader/keys/auto
  mcopy -i "$E" "$K/PK.auth" "$K/KEK.auth" "$K/db.auth" ::/loader/keys/auto/
  mcopy -i "$E" ::/loader/loader.conf "$T/loader.conf"
  echo "secure-boot-enroll if-safe" >> "$T/loader.conf"
  mcopy -o -i "$E" "$T/loader.conf" ::/loader/loader.conf
  signed_addon 'console=ttyS0,115200 console=tty0 plymouth.ignore-serial-consoles systemd.wants=serial-getty@ttyS0.service' \
    "$T/vm-serial-console.addon.efi"
  mcopy -o -i "$E" "$T/vm-serial-console.addon.efi" ::/loader/addons/vm-serial-console.addon.efi

  # Fresh firmware variables (Setup Mode, for the enrollment) and TPM state.
  rm -rf "${IMG%.*}.vm"
  echo "Created $IMG. On its first start, systemd-boot enrolls the development keys and restarts."
fi
if [ -n "$DEBUG" ]; then
  if pgrep -f "file=$IMG," >/dev/null; then
    echo "The VM is running; stop it first (Ctrl+A X in its terminal)." >&2; exit 1
  fi
  E=$(esp)
  if [ "$DEBUG" = on ]; then
    signed_addon 'systemd.debug_shell=/dev/ttyS0 systemd.mask=serial-getty@ttyS0.service loglevel=7 systemd.show_status=1 plymouth.enable=0 console=tty0 console=ttyS0,115200' \
      "$T/zz-debug.addon.efi"
    mdel -i "$E" ::/loader/addons/debug-shell.addon.efi 2>/dev/null || :
    mcopy -o -i "$E" "$T/zz-debug.addon.efi" ::/loader/addons/zz-debug.addon.efi
    echo "Debug on: the boot output and a root shell (press Enter) appear in this terminal."
  else
    mdel -i "$E" ::/loader/addons/zz-debug.addon.efi ::/loader/addons/debug-shell.addon.efi 2>/dev/null || :
    echo "Debug off."
  fi
fi
rm -rf "$T"   # exec replaces this shell, so the EXIT trap would not run
exec "$HERE/../run-vm.sh" --release "$B" "$IMG"
