#!/usr/bin/env bash
# Creates the key that signs each UKI's expected PCR 11 values. Run once, offline.
# Usage: keys/make-pcr-key.sh <private-dir outside the repo>
# Public key goes to keys/tpm2-pcr-public-key.pem; the private key and the
# TPM2_PCR_KEY secret value to <private-dir>.
set -euo pipefail
cd "$(dirname -- "$0")"

PRIV=${1:?private output directory (offline storage)}
mkdir -p "$PRIV" && chmod 700 "$PRIV"
PRIV=$(realpath "$PRIV")
case "$PRIV/" in "$(realpath ..)"/*)
  echo "Refusing to write private keys inside the repository." >&2; exit 1 ;;
esac
PUB=tpm2-pcr-public-key.pem
[ -e "$PUB" ] && { echo "$PUB exists; refusing to overwrite" >&2; exit 1; }

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIV/tpm2-pcr-private-key.pem"
chmod 600 "$PRIV/tpm2-pcr-private-key.pem"
openssl pkey -in "$PRIV/tpm2-pcr-private-key.pem" -pubout -out "$PUB"
base64 -w0 "$PRIV/tpm2-pcr-private-key.pem" > "$PRIV/TPM2_PCR_KEY.base64"

echo "Public key:  keys/$PUB (commit it)"
echo "Secret:      add $PRIV/TPM2_PCR_KEY.base64 as the TPM2_PCR_KEY repository secret"
