#!/usr/bin/env bash
# Creates a Secure Boot database update signed with the TungstenOS KEK. Run offline, where
# the KEK private key is (keys/make-secureboot-keys.sh). Every TungstenOS system applies
# committed updates at boot (tungsten-secureboot-update.service), unless something it boots
# from would be revoked.
#
#   keys/sign-efi-update.sh <private-dir> <name> dbx-hash <file.efi>...
#       Revoke specific binaries we signed (systemd-boot, UKIs, add-ons), by their
#       Authenticode SHA-256, e.g. every build before a systemd-boot security fix.
#   keys/sign-efi-update.sh <private-dir> <name> dbx-cert <cert.crt|.pem|.der>
#       Revoke everything a certificate signed (an old db key after a key rotation).
#   keys/sign-efi-update.sh <private-dir> <name> db-cert <cert.crt|.pem|.der>
#       Trust a new db certificate (the new key of a rotation; enroll it before the old
#       one is revoked).
#
# Output: keys/secureboot/updates/NNNN-<name>/{update.auth,update.json}. Commit both.
# Updates are appends (EFI_VARIABLE_APPEND_WRITE): they add entries, never remove any, and
# applying one twice changes nothing.
set -euo pipefail
cd "$(dirname -- "$0")"

PRIV=${1:?private directory with KEK.key}; NAME=${2:?update name}; KIND=${3:?dbx-hash, dbx-cert or db-cert}
shift 3
[ -f "$PRIV/KEK.key" ] || { echo "$PRIV/KEK.key not found" >&2; exit 1; }
[[ $NAME =~ ^[a-z0-9][a-z0-9-]*$ ]] || { echo "name: lowercase letters, digits and -" >&2; exit 1; }
for t in openssl cert-to-efi-sig-list hash-to-efi-sig-list sign-efi-sig-list jq; do
  command -v "$t" >/dev/null || { echo "missing $t (pacman -S efitools openssl jq)" >&2; exit 1; }
done
GUID=$(cat secureboot/GUID)
UPDATES=secureboot/updates
mkdir -p "$UPDATES"
n=$(find "$UPDATES" -mindepth 1 -maxdepth 1 -type d | wc -l)
OUT=$UPDATES/$(printf '%04d' $((n + 1)))-$NAME
[ ! -e "$OUT" ] || { echo "$OUT exists" >&2; exit 1; }
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

entries='[]'
case $KIND in
  dbx-hash)
    var=dbx
    [ $# -gt 0 ] || { echo "dbx-hash needs at least one EFI binary" >&2; exit 1; }
    # Prints "HASH IS <hex>" per binary: the Authenticode digest the firmware checks.
    mapfile -t hashes < <(hash-to-efi-sig-list "$@" "$WORK/update.esl" | sed -n 's/^HASH IS //p')
    [ ${#hashes[@]} -eq $# ] || { echo "expected $# hashes, got ${#hashes[@]}" >&2; exit 1; }
    files=("$@")
    for i in "${!hashes[@]}"; do
      entries=$(jq -c --arg h "${hashes[$i]}" --arg f "$(basename "${files[$i]}")" \
        '. + [{type: "sha256", hash: $h, file: $f}]' <<<"$entries")
    done
    ;;
  dbx-cert|db-cert)
    var=${KIND%%-*}
    [ $# -eq 1 ] || { echo "$KIND takes one certificate" >&2; exit 1; }
    if openssl x509 -in "$1" -noout 2>/dev/null; then
      openssl x509 -in "$1" -out "$WORK/cert.pem"
    else
      openssl x509 -inform der -in "$1" -out "$WORK/cert.pem"
    fi
    fp=$(openssl x509 -in "$WORK/cert.pem" -noout -fingerprint -sha256 | sed 's/.*=//; s/://g' | tr 'A-F' 'a-f')
    subject=$(openssl x509 -in "$WORK/cert.pem" -noout -subject -nameopt RFC2253 | sed 's/^subject=//')
    cert-to-efi-sig-list -g "$GUID" "$WORK/cert.pem" "$WORK/update.esl"
    entries=$(jq -cn --arg fp "$fp" --arg s "$subject" '[{type: "x509", sha256: $fp, subject: $s}]')
    mkdir -p "$OUT" && cp "$WORK/cert.pem" "$OUT/cert.pem"
    ;;
  *) echo "unknown kind $KIND" >&2; exit 2 ;;
esac

mkdir -p "$OUT"
# Timestamped, append: firmware accepts appends regardless of the previous timestamp.
sign-efi-sig-list -a -t "$(date -u '+%Y-%m-%d %H:%M:%S')" -g "$GUID" \
  -k "$PRIV/KEK.key" -c secureboot/KEK.crt "$var" "$WORK/update.esl" "$OUT/update.auth"
jq -n --arg name "$NAME" --arg var "$var" --arg kind "$KIND" --argjson entries "$entries" \
   --arg created "$(date -u -Iseconds)" \
   '{name: $name, var: $var, kind: $kind, created: $created, entries: $entries}' > "$OUT/update.json"
echo "Created $OUT ($var, ${KIND}, $(jq length <<<"$entries") entries). Commit it."
