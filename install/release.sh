# Sourced by run-vm.sh, build-iso.sh and build-live-uki.sh: fetches the latest GitHub
# release, checked against the signed SHA256SUMS (keys/tungsten.pgp). Needs: curl gpg
# Sets: ver usr verity uki boot exts (release file names) and CACHE (download directory).
HERE=${HERE:-$(dirname -- "$(realpath "${BASH_SOURCE[0]}")")}
KEYRING=$HERE/../keys/tungsten.pgp
URL=https://github.com/GitHub-MrAnnonymus/TungstenOS/releases/latest/download
# build-iso.sh --dev passes the directory of a local build.
CACHE=${CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/tungstenos/release}

# Fetches and verifies the latest release's SHA256SUMS and sets the file names.
# Returns 1 if GitHub cannot be reached.
fetch_release() {
  mkdir -p "$CACHE"
  curl -fsSL -o "$CACHE/SHA256SUMS.new" "$URL/SHA256SUMS" || return 1
  curl -fsSL -o "$CACHE/SHA256SUMS.gpg.new" "$URL/SHA256SUMS.gpg" || return 1
  gpgv --keyring "$KEYRING" "$CACHE/SHA256SUMS.gpg.new" "$CACHE/SHA256SUMS.new" 2>/dev/null \
    || { echo "SHA256SUMS of the latest release has no valid signature from keys/tungsten.pgp" >&2; exit 1; }
  mv "$CACHE/SHA256SUMS.new" "$CACHE/SHA256SUMS"
  mv "$CACHE/SHA256SUMS.gpg.new" "$CACHE/SHA256SUMS.gpg"
  release_names
}

# Sets the file names from $CACHE/SHA256SUMS (also for a local build: install/dev/build.sh).
release_names() {
  local names
  names=$(awk '{sub(/^\*/, "", $2); print $2}' "$CACHE/SHA256SUMS")
  usr=$(grep -E '^tungsten_[0-9]+_[0-9a-f-]+\.usr\.raw$' <<<"$names")
  ver=${usr#tungsten_}; ver=${ver%%_*}
  verity=$(grep -E "^tungsten_${ver}_[0-9a-f-]+\.usr-verity\.raw\$" <<<"$names")
  uki=tungsten_$ver.efi
  boot=tungsten_$ver.systemd-bootx64.efi
  exts=$(grep -E "^[a-z0-9-]+_${ver}\.raw\$" <<<"$names" | grep -v '^tungsten_' || :)
}

# Downloads release files into the cache (once) and checks them against SHA256SUMS.
# Files of other releases are removed from the cache.
download() {
  find "$CACHE" -maxdepth 1 -name '*_*' ! -name "*_${ver}[._]*" ! -name 'SHA256SUMS*' -delete
  local f
  for f in "$@"; do
    if [ ! -f "$CACHE/$f" ]; then
      curl -fL --progress-bar -o "$CACHE/$f.part" "$URL/$f"
      mv "$CACHE/$f.part" "$CACHE/$f"
    fi
    (cd "$CACHE" && grep -E " \*?${f//./\\.}\$" SHA256SUMS | sha256sum -c --quiet) \
      || { rm -f "$CACHE/$f"; echo "checksum mismatch for $f, download removed" >&2; exit 1; }
  done
}
