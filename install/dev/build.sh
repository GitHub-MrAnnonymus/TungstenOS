#!/usr/bin/env bash
# Builds TungstenOS locally, signed with throwaway development keys, for VMs only
# (install/dev/vm.sh). The build runs build.sh in the same privileged archlinux container
# as CI (.github/workflows/build.yml), with the packages of the [tungsten] repository.
# The release keys are never involved, and the image has no update URL: it never installs
# a release, whose signatures its firmware would reject anyway.
#
# Keys and builds live in $TUNGSTEN_DEV (default ~/.local/share/tungstenos-dev):
#   keys/              Secure Boot PK, KEK, db and PCR signing key, created on the first run
#   builds/<version>/  the release files with SHA256SUMS; builds/latest is the newest
#   pkgcache/          pacman's package cache, so later builds download only what changed
#
# Usage: install/dev/build.sh
# Needs: podman, sudo (the container is privileged, as in CI: it mounts and uses loop devices)
set -euo pipefail
HERE=$(dirname -- "$(realpath "$0")")
REPO=$(realpath "$HERE/../..")
DEV=${TUNGSTEN_DEV:-$HOME/.local/share/tungstenos-dev}
command -v podman >/dev/null || { echo "podman not found: pacman -S --needed podman" >&2; exit 1; }
case "$(realpath -m "$DEV")/" in "$REPO"/*)
  echo "Refusing to keep development keys inside the repository ($REPO)." >&2; exit 1 ;;
esac
mkdir -p "$DEV/pkgcache" && chmod 700 "$DEV"
DEV=$(realpath "$DEV")

sudo podman run --rm --privileged --pull=newer \
  -v "$REPO":/src:ro -v "$DEV":/state -v "$DEV/pkgcache":/var/cache/pacman/pkg \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  docker.io/library/archlinux:latest bash /src/install/dev/build-in-container.sh
echo "Built $(readlink "$DEV/builds/latest") in $DEV/builds. Start it with install/dev/vm.sh."
