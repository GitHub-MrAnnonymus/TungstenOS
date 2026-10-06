#!/usr/bin/env bash
# Boots a TungstenOS VM image in QEMU with UEFI (OVMF, Secure Boot capable) and a software TPM.
# Firmware variables and TPM state persist next to the image in <image>.vm/.
# The terminal becomes the VM's serial port (ttyS0) with a login prompt (images from
# tungsten-install.sh): log in there to copy and paste. Ctrl+A C toggles the QEMU monitor,
# Ctrl+A X quits.
# Usage: install/run-vm.sh <image-file>
# Needs: qemu-desktop edk2-ovmf swtpm
set -euo pipefail
IMG=$(realpath "${1:?VM image file}")
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
