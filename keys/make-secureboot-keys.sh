#!/usr/bin/env bash
# Creates the Secure Boot hierarchy and pre-signed enrollment files. Run once, offline.
# Usage: keys/make-secureboot-keys.sh <private-dir outside the repo>
# Public output goes to keys/secureboot/; private keys and CI secrets to <private-dir>.
set -euo pipefail
cd "$(dirname -- "$0")"

PRIV=${1:?private output directory (offline storage)}
mkdir -p "$PRIV" && chmod 700 "$PRIV"
PRIV=$(realpath "$PRIV")
REPO=$(realpath ..)
case "$PRIV/" in "$REPO"/*)
  echo "Refusing to write private keys inside the repository ($REPO)." >&2
  echo "Use a directory on offline/removable storage." >&2
  rmdir "$PRIV" 2>/dev/null; exit 1 ;;
esac
PUB=secureboot
[ -e "$PUB/PK.crt" ] && { echo "$PUB/PK.crt exists; refusing to overwrite an existing hierarchy" >&2; exit 1; }
mkdir -p "$PUB/microsoft"
for t in openssl cert-to-efi-sig-list sign-efi-sig-list uuidgen; do
  command -v "$t" >/dev/null || { echo "missing $t (pacman -S efitools openssl util-linux)" >&2; exit 1; }
done
(cd microsoft && sha256sum -c --quiet SHA256SUMS)

GUID=$(uuidgen --random)
echo "$GUID" > "$PUB/GUID"
MS_GUID=77fa9abd-0359-4d32-bd60-28f4e78f784b   # Microsoft's signature owner
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# RSA-2048: the only key size UEFI firmware is required to support.
for k in PK KEK db; do
  openssl req -new -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -subj "/CN=TungstenOS $k/" -keyout "$PRIV/$k.key" -out "$PUB/$k.crt"
  chmod 600 "$PRIV/$k.key"
  cert-to-efi-sig-list -g "$GUID" "$PUB/$k.crt" "$WORK/$k.esl"
done

sign-efi-sig-list -g "$GUID" -k "$PRIV/PK.key"  -c "$PUB/PK.crt"  PK  "$WORK/PK.esl"  "$PUB/PK.auth"
sign-efi-sig-list -g "$GUID" -k "$PRIV/PK.key"  -c "$PUB/PK.crt"  KEK "$WORK/KEK.esl" "$PUB/KEK.auth"
sign-efi-sig-list -g "$GUID" -k "$PRIV/KEK.key" -c "$PUB/KEK.crt" db  "$WORK/db.esl"  "$PUB/db.auth"

for der in microsoft/KEK/*.der microsoft/db/*.der; do
  var=$(basename "$(dirname "$der")")          # KEK or db
  name=$(basename "$der" .der)
  openssl x509 -inform der -in "$der" -out "$WORK/$name.pem"
  cert-to-efi-sig-list -g "$MS_GUID" "$WORK/$name.pem" "$WORK/$name.esl"
  if [ "$var" = KEK ]; then signer=PK; else signer=KEK; fi
  sign-efi-sig-list -a -g "$GUID" -k "$PRIV/$signer.key" -c "$PUB/$signer.crt" \
    "$var" "$WORK/$name.esl" "$PUB/microsoft/$var-$name.auth"
done

base64 -w0 "$PRIV/db.key" > "$PRIV/SB_DB_KEY.base64"
base64 -w0 "$PUB/db.crt"  > "$PRIV/SB_DB_CRT.base64"
cat <<EOF
Done.
  Commit:  keys/secureboot/
  Secrets: SB_DB_KEY = $PRIV/SB_DB_KEY.base64
           SB_DB_CRT = $PRIV/SB_DB_CRT.base64
  Store $PRIV offline (PK.key and KEK.key are only needed to re-sign enrollment files).
EOF
