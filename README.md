# TungstenOS

TungstenOS is an image-based, verified-boot desktop operating system built from Arch Linux packages. Following the [hermetic `/usr`](https://0pointer.net/blog/fitting-everything-together.html) model, the operating system is a read-only, dm-verity-protected `/usr` image updated atomically with A/B swaps and automatic rollback, while `/etc`, `/var` and `/home` live on a TPM-bound encrypted root partition that can be factory-reset. The desktop is Hyprland with DankMaterialShell, and the default browser is [Trivalent](https://github.com/secureblue/Trivalent).

> **Status:** experimental. The build has not yet produced a released image, and the SELinux policy runs in permissive mode until the desktop policy is complete.

## Contents

- [Security model](#security-model)
- [Images](#images)
- [Disk layout](#disk-layout)
- [Configuration](#configuration)
- [Building](#building)
- [Installation](#installation)
- [Updates](#updates)
- [Maintenance](#maintenance)
- [Supply chain](#supply-chain)
- [Acknowledgements](#acknowledgements)

## Security model

| Area | Implementation |
|---|---|
| Boot integrity | UEFI Secure Boot with an owner-controlled key hierarchy, signed systemd-boot and Unified Kernel Images (UKIs) |
| Operating system | Read-only EROFS `/usr` image verified by dm-verity; the verity root hash is embedded in the signed UKI |
| Code integrity | IPE restricts kernel modules and firmware to the verified image; module signatures are enforced |
| Execution control | The writable root partition is mounted `noexec`, and SELinux denies confined users execution from their home and `/tmp`; the only writable executable location is system-wide Flatpak |
| Mandatory access control | SELinux (refpolicy) with all logins confined as `staff_u` |
| User namespaces | Enabled, but creation is permitted only to SELinux domains that need it (browser sandbox, bubblewrap) |
| Privileges | No setuid or setgid binaries; administration through `run0` and polkit |
| Kernel | Linux stable with selected [linux-hardened](https://github.com/anthraxx/linux-hardened) patches, built with Clang (kCFI/FineIBT), reduced attack surface and lockdown in confidentiality mode |
| Disk encryption | LUKS2 bound to the TPM through a systemd-pcrlock policy (optional PIN); each home is a separate systemd-homed LUKS image |
| Memory allocator | GrapheneOS [hardened_malloc](https://github.com/GrapheneOS/hardened_malloc), preloaded system-wide |
| Peripherals | USBGuard blocks unknown USB devices; IOMMU enforced; Thunderbolt and about 760 unused or risky kernel modules blocked |
| Network | firewalld with inbound traffic dropped by default, IPv6 disabled, encrypted DNS (dnscrypt-proxy), authenticated time (NTS) |

## Images

Each release contains four images. They share the kernel, SELinux policy and userspace.

| Image | Adds |
|---|---|
| `tungsten-generic` | Base image for x86_64 systems with AMD or Intel graphics |
| `tungsten-generic-asus` | asusctl and rog-control-center for ASUS laptops |
| `tungsten-nvidia` | Open NVIDIA kernel modules (signed during the kernel build), `nvidia-utils` and hybrid-graphics setup |
| `tungsten-nvidia-asus` | Both of the above |

Images are composed from `components/` (`nvidia`, `asus`); each `variants/<name>/components` file selects them, and a variant may add its own files.

## Disk layout

| # | Partition | Contents | Protection |
|---|---|---|---|
| 1 | ESP | systemd-boot, UKIs, pcrlock policy credential | Contents signed for Secure Boot |
| 2, 4 | `/usr` A, B | Operating system (EROFS) | dm-verity |
| 3, 5 | `/usr` verity A, B | dm-verity hash trees | — |
| 6 | Root | `/etc` changes, `/var`, `/home`, Flatpak | LUKS2: TPM2 + pcrlock (optional PIN), recovery key; mounted `noexec` |

Home directories are additionally systemd-homed LUKS images unlocked with each user's password, so they stay locked while their user is logged out. `/tmp` is memory-backed.

The root partition is defined in `/usr/lib/repart.d`. If it is missing, for example after a factory reset (`systemd-factory-reset request`, then reboot), the initramfs recreates it with new keys and the system sets itself up again from `/usr`.

## Configuration

`/etc` is an overlay: the image's defaults (`/usr/share/factory/etc`, verified with `/usr`) are the lower layer, and local changes are stored on the root partition above them. Files that have not been changed follow image updates; changed files keep the local version.

```sh
tungsten-etc status              # list files that differ from the defaults
tungsten-etc diff /etc/<file>    # show the change for one file
run0 tungsten-etc reset <file>   # restore the default at the next boot (--all for everything)
```

Settings made with graphical tools, such as firewall-config, NetworkManager connections and USBGuard rules, are stored the same way.

USBGuard allows the devices present at first boot and blocks any new device until it is allowed (`run0 usbguard allow-device <id>`). Members of the `usbguard` group receive notifications. The stricter linux-hardened mode, which blocks all new USB devices at the kernel level, remains available through `mydenyusb.service` and `usb-allow.service`.

## Building

Builds run on GitHub Actions.

### Repository layout

| Path | Purpose |
|---|---|
| `build.sh` | Builds one image variant |
| `components/` | Optional image components: packages, units, kernel parameters and files |
| `variants/` | Image definitions: the components each image uses, plus image-specific files |
| `root_files/` | Files copied into every image; `etc/skel` holds the default user configuration |
| `kernel/` | `linux-tungsten` package: PKGBUILD, config fragment and vendored linux-hardened patches |
| `packages/` | SELinux userspace builder and PKGBUILDs for Trivalent, hardened_malloc, dms-greeter, usbguard-notifier and erofs-utils |
| `selinux/` | Local SELinux policy module |
| `keys/` | Public signing keys, Secure Boot key tooling and vendored Microsoft certificates |
| `install/` | Disk installer and Secure Boot enrollment |
| `scripts/` | Build helpers and vendoring scripts |

### One-time setup

1. **Enable the commit hook**, which rejects private key material:
   ```sh
   git config core.hooksPath .githooks
   ```
2. **Create the release signing key** as described in [`keys/README.md`](keys/README.md). Commit `keys/tungsten.pgp` and add the secret key as the `TUNGSTEN_GPG_KEY` repository secret.
3. **Create the Secure Boot hierarchy** on an offline machine with `efitools` installed:
   ```sh
   keys/make-secureboot-keys.sh /path/to/offline/storage
   ```
   Commit `keys/secureboot/`. Add the generated `SB_DB_KEY.base64` and `SB_DB_CRT.base64` values as the `SB_DB_KEY` and `SB_DB_CRT` secrets. The PK and KEK private keys never leave the offline machine.
4. **Allow workflows to publish releases:** Settings → Actions → General → Workflow permissions → *Read and write*.

### Workflows

| Workflow | Output | Trigger |
|---|---|---|
| Build packages | Signed `[tungsten]` pacman repository on the `packages` release | Changes under `kernel/` or `packages/`, daily upstream checks (Trivalent, NVIDIA), manual |
| Build OS image | All images and a signed `SHA256SUMS` as the latest release | Every two days, configuration changes, after a package build, manual |

Run *Build packages* with **all** selected before the first image build. Only package groups whose inputs changed are rebuilt; the kernel build uses a compiler cache that is saved even when a build times out.

## Installation

Download one image's files together with `SHA256SUMS` and `SHA256SUMS.gpg` from a release, verify them, and run the installer from an Arch Linux live ISO:

```sh
gpgv --keyring keys/tungsten.pgp SHA256SUMS.gpg SHA256SUMS
IMAGE_ID=tungsten-generic install/tungsten-install.sh /dev/nvme0n1 ./release
```

The installer erases the disk, creates the partition layout above, writes the first image, installs the bootloader and asks for a recovery passphrase for the root partition.

### Secure Boot enrollment

If the firmware is in Setup Mode, the installer offers to enroll keys; `install/enroll-secureboot.sh` can also be run on its own. It offers two choices:

- **TungstenOS only.** Only TungstenOS boots; option ROMs and other operating systems are rejected.
- **TungstenOS and Microsoft.** Certificates from Microsoft's `MicrosoftAndThirdParty` template can be selected individually. Preselected: Microsoft KEK 2K CA 2023, Windows UEFI CA 2023, Option ROM UEFI CA 2023 and UEFI CA 2011 (required by option ROMs signed before 2023). The third-party Microsoft UEFI CA 2023 is opt-in. Microsoft's revocation list (dbx) is applied whenever a Microsoft db certificate is enrolled.

Before writing, the script checks the TPM event log and warns if the selection would block option ROMs that the system loaded during the current boot.

### First boot

1. Unlock the root partition with the recovery passphrase.
2. Create the first user when prompted. Add this account to `wheel`; it is the administrator.
3. Bind the root partition to the TPM. This shows a pcrlock recovery PIN once; store it with the passphrase. After a factory reset, the same command also creates a recovery key.
   ```sh
   run0 tungsten-tpm-enroll
   ```
4. Create a separate everyday account outside `wheel`:
   ```sh
   run0 homectl create <name> --storage=luks
   ```

## Updates

`systemd-sysupdate` downloads new releases, verifies `SHA256SUMS.gpg` against the key built into the image, and writes the new `/usr` and verity images to the inactive slot. The new UKI is installed with boot counting: if it fails to boot three times, systemd-boot returns to the previous one. After each update the pcrlock policy is extended to cover the new UKI, so the root partition keeps unlocking from the TPM.

Applications are installed with Flatpak, system-wide only:

```sh
flatpak install flathub <application>
```

Per-user (`--user`) Flatpak installations cannot run, because the root partition and home directories do not allow execution.

## Maintenance

### Kernel

```sh
cd kernel
./update-hardened-patches.sh <version> hardened1   # export linux-hardened as individual patches
$EDITOR patches/series                              # comment out patches to skip
./check-patches.sh                                  # apply the series to a pristine tarball
```

Update `pkgver` and the tarball checksum in `kernel/PKGBUILD`. Patches that conflict once their neighbours are disabled are kept as rebased copies in `kernel/patch-overrides/`. `config.fragment` lists every deviation from Arch's linux-hardened configuration, and the build fails if any of them is not honoured. The NVIDIA module version follows Arch's `nvidia-utils` automatically.

### SELinux policy

The system boots in permissive mode. To complete the policy, collect denials from normal use:

```sh
run0 ausearch -m avc -ts boot | audit2allow -R
```

Add reviewed rules to `selinux/tungsten.te` and repeat until no denials remain. Then set `SELINUX=enforcing` in `build.sh` and disable `CONFIG_SECURITY_SELINUX_DEVELOP` in `kernel/config.fragment`.

### Vendored components

| Component | Update procedure |
|---|---|
| archlinuxhardened SELinux packages | Set `SELINUX_COMMIT` in `packages/build-selinux.sh` to a maintainer-signed merge commit; the reference policy is patched by `packages/refpolicy-user-exec-content.sh` |
| secureblue module blocklists | Set `COMMIT` in `scripts/update-secureblue-modprobe.sh` and run it |
| Trivalent | Automatic (`packages/trivalent/update.py`) |
| hardened_malloc | Set `_commit` in `packages/hardened_malloc/PKGBUILD` |
| Microsoft certificates | Replace files in `keys/microsoft/` and regenerate `SHA256SUMS` |

## Supply chain

Packages not available from Arch Linux are built from source in CI and published in a repository signed with the TungstenOS key.

| Source | Verification |
|---|---|
| Linux kernel | kernel.org tarball signatures |
| linux-hardened patches | Vendored in the repository and reviewed per patch |
| archlinuxhardened/selinux | Pinned commit verified against the maintainer's key (`E25E254C8EE4D303554BF5AFEC701A1DA494C5EB`); upstream tarballs verified with the keys in that signed tree. The project's prebuilt repository is unsigned and not used. |
| Trivalent | secureblue's signed repository metadata, then metadata and RPM checksums |
| NVIDIA open modules | Checksum from Arch's `nvidia-utils` package |
| dms-greeter, hardened_malloc | Pinned commits |
| usbguard-notifier | Upstream release signature (key vendored in `packages/usbguard-notifier/`) |
| Microsoft certificates and dbx | Pinned commit of [microsoft/secureboot_objects](https://github.com/microsoft/secureboot_objects), checksummed |

## Acknowledgements

- [archlinux-desktop-verity](https://github.com/lucasbeiler/archlinux-desktop-verity) by Lucas Beiler, the project TungstenOS is derived from
- [secureblue](https://github.com/secureblue/secureblue): Trivalent, the kernel configuration reductions, module blocklists, sysctl settings and setuid removal approach
- [linux-hardened](https://github.com/anthraxx/linux-hardened) and Arch Linux's `linux-hardened` package
- [archlinuxhardened/selinux](https://github.com/archlinuxhardened/selinux)
- [GrapheneOS hardened_malloc](https://github.com/GrapheneOS/hardened_malloc)
- [DankMaterialShell](https://github.com/AvengeMedia/DankMaterialShell)
