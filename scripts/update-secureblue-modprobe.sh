#!/usr/bin/env bash
# Vendors secureblue's module blocklists at COMMIT into root_files/usr/lib/modprobe.d/.
set -euo pipefail
cd "$(dirname -- "$0")/.."

COMMIT=4282b5fc3f9e1b1af666489d5d14c22c8cfee1ea
BASE="https://raw.githubusercontent.com/secureblue/secureblue/$COMMIT/files/system/usr/lib/modprobe.d"
# Modules kept loadable (Bluetooth is loaded on demand by bluetooth-on.service).
KEEP=(bluetooth btusb)

OUT=root_files/usr/lib/modprobe.d
mkdir -p "$OUT"
for f in secureblue.conf secureblue-framebuffer.conf; do
  tmp=$(mktemp)
  curl -fsSL "$BASE/$f" -o "$tmp"
  {
    echo "# Vendored from secureblue @ $COMMIT by scripts/update-secureblue-modprobe.sh."
    echo "# Copyright The Secureblue Authors. SPDX-License-Identifier: Apache-2.0 (see upstream for framebuffer file)."
    echo "# Do not edit; change KEEP in that script instead."
    for m in "${KEEP[@]}"; do
      grep -qE "^install $m /bin/false\$" "$tmp" && echo "# TungstenOS: '$m' unblocked"
    done
    grep -vE "^install ($(IFS='|'; echo "${KEEP[*]}")) /bin/false\$" "$tmp"
  } > "$OUT/$f"
  rm -f "$tmp"
done
echo "blocked modules: $(grep -cE '^install ' "$OUT/secureblue.conf")"
