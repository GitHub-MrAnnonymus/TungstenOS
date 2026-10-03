#!/usr/bin/env bash
# Enrolls the TungstenOS Secure Boot keys, optionally with Microsoft's certificates.
# Requires root and the firmware in Setup Mode.
set -euo pipefail
cd "$(dirname -- "$0")/../keys"
[ "$EUID" -eq 0 ] || { echo "Run as root" >&2; exit 1; }

EFIVARS=/sys/firmware/efi/efivars
GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
[ -d "$EFIVARS" ] || { echo "Not booted in UEFI mode" >&2; exit 1; }
setup_mode=$(od -An -t u1 -j4 -N1 "$EFIVARS/SetupMode-$GLOBAL" | tr -d ' ')
if [ "$setup_mode" != 1 ]; then
  echo "Firmware is not in Setup Mode. In firmware setup, clear the Secure Boot keys" >&2
  echo "(\"Reset to Setup Mode\"), then run this again." >&2
  exit 1
fi
[ -f secureboot/PK.auth ] || { echo "keys/secureboot/ missing: run keys/make-secureboot-keys.sh first" >&2; exit 1; }
(cd microsoft && sha256sum -c --quiet SHA256SUMS)
command -v efi-updatevar >/dev/null || pacman -Sy --noconfirm --needed efitools

# --- Trust selection ---
echo
echo "Which keys should this machine trust?"
echo "  1) TungstenOS only        Only TungstenOS boots. Firmware will refuse option ROMs"
echo "                            (GPU/NVMe/NIC firmware drivers) and every other OS."
echo "  2) TungstenOS + Microsoft  Also trust Microsoft's certificates (choose which next)."
read -r -p "Choice [1/2]: " choice

declare -a names files selected
if [ "$choice" = 2 ]; then
  # default | label | file (Microsoft's MicrosoftAndThirdParty template).
  # UEFI CA 2011 also signed pre-2023 shims; the 2023 third-party CA is opt-in.
  entries=(
    "1|KEK  Microsoft KEK 2K CA 2023       lets Microsoft ship db/dbx updates|secureboot/microsoft/KEK-kek-2k-ca-2023.auth"
    "1|db   Windows UEFI CA 2023           Windows boot media (2023+)|secureboot/microsoft/db-windows-uefi-ca-2023.auth"
    "1|db   Option ROM UEFI CA 2023        GPU/NVMe/NIC option ROMs (2023+)|secureboot/microsoft/db-option-rom-uefi-ca-2023.auth"
    "1|db   Microsoft UEFI CA 2011         option ROMs signed before 2023 (also pre-2023 shims)|secureboot/microsoft/db-uefi-ca-2011.auth"
    "0|db   Microsoft UEFI CA 2023         third-party bootloaders, e.g. shim/other distros (2023+)|secureboot/microsoft/db-uefi-ca-2023.auth"
  )
  for e in "${entries[@]}"; do
    rest=${e#*|}
    selected+=("${e%%|*}"); names+=("${rest%%|*}"); files+=("${rest##*|}")
  done
  while :; do
    echo
    for i in "${!names[@]}"; do
      mark=" "; [ "${selected[$i]}" = 1 ] && mark="x"
      printf '  [%s] %d) %s\n' "$mark" $((i+1)) "${names[$i]}"
    done
    read -r -p "Number to toggle, Enter to continue: " t
    [ -z "$t" ] && break
    if [[ $t =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le ${#names[@]} ]; then
      i=$((t-1)); selected[$i]=$((1 - selected[$i]))
    fi
  done
elif [ "$choice" != 1 ]; then
  echo "Invalid choice" >&2; exit 1
fi

ms_kek=0; ms_db=0
for i in "${!files[@]}"; do
  [ "${selected[$i]}" = 1 ] || continue
  case "${files[$i]}" in */KEK-*) ms_kek=1 ;; */db-*) ms_db=1 ;; esac
done

# --- Option ROM check ---
# Warn if this boot loaded option ROMs that the selection would no longer trust.
oproms=0
if command -v tpm2_eventlog >/dev/null && [ -r /sys/kernel/security/tpm0/binary_bios_measurements ]; then
  oproms=$(tpm2_eventlog /sys/kernel/security/tpm0/binary_bios_measurements 2>/dev/null \
           | grep -c 'EV_EFI_BOOT_SERVICES_DRIVER' || true)
fi
oprom_ok=0
for i in "${!files[@]}"; do
  [ "${selected[$i]}" = 1 ] && case "${files[$i]}" in *option-rom*|*uefi-ca-2011*) oprom_ok=1 ;; esac
done
if [ "$oproms" -gt 0 ] && [ "$oprom_ok" = 0 ]; then
  echo
  echo "WARNING: this machine loaded $oproms option ROM(s) during this boot (GPU, NVMe or NIC"
  echo "firmware drivers). Without 'Option ROM UEFI CA 2023' or 'Microsoft UEFI CA 2011' in db,"
  echo "the firmware will refuse them: you may lose display or the boot disk until you clear"
  echo "the keys again (often only possible with a CMOS reset)."
  read -r -p "Type 'I understand' to continue: " ok
  [ "$ok" = "I understand" ] || exit 1
fi

# --- Enroll ---
# KEK first, PK last (enrolling PK leaves Setup Mode).
for v in KEK db dbx PK; do
  chattr -i "$EFIVARS"/$v-* 2>/dev/null || :
done
enroll()  { echo "  $2 <- $1"; efi-updatevar -f "$1" "$2"; }
append()  { echo "  $2 += $1"; efi-updatevar -a -f "$1" "$2"; }

echo
enroll secureboot/KEK.auth KEK
for i in "${!files[@]}"; do [ "${selected[$i]}" = 1 ] && [[ ${files[$i]} == */KEK-* ]] && append "${files[$i]}" KEK; done
enroll secureboot/db.auth db
for i in "${!files[@]}"; do [ "${selected[$i]}" = 1 ] && [[ ${files[$i]} == */db-* ]] && append "${files[$i]}" db; done
if [ "$ms_db" = 1 ]; then
  # Microsoft revocations, signed by Microsoft KEK 2023.
  append microsoft/dbx_x64.efiauth2 dbx
  [ "$ms_kek" = 1 ] || echo "  note: without Microsoft KEK 2023, Microsoft dbx updates can't be applied later"
fi
enroll secureboot/PK.auth PK

echo
echo "Enrolled. Enable Secure Boot in firmware setup if it isn't already."
echo "PCR 7 changed: if the system was TPM-enrolled, re-run 'run0 tungsten-tpm-enroll' after booting."
