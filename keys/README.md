# keys/

- `make-secureboot-keys.sh` creates the Secure Boot hierarchy (see the main README).
- `microsoft/` holds Microsoft's certificates and dbx, vendored from a pinned commit.

## Release signing key

`tungsten.pgp` (not in the repo until you add it) is the **binary** public key
that signs the `[tungsten]` pacman repo and every release's `SHA256SUMS`.
It is baked into the images as `/usr/lib/systemd/import-pubring.pgp`, the only
keyring `systemd-sysupdate` trusts.

Create it once, offline:

```sh
export GNUPGHOME=$(mktemp -d)
gpg --batch --passphrase '' --quick-gen-key 'TungstenOS release signing' ed25519 sign never
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr/ {print $10; exit}')
gpg --export "$FPR" > keys/tungsten.pgp                    # commit this
gpg --export-secret-keys --armor "$FPR" | base64 -w0       # GitHub secret TUNGSTEN_GPG_KEY
```

Keep an offline backup of the secret key. Rotating it requires shipping the new
public key in an image signed with the old one first.
