# TungstenOS

TungstenOS is an image-based, verified-boot desktop operating system built from Arch Linux packages. Following the [hermetic `/usr`](https://0pointer.net/blog/fitting-everything-together.html) model, the operating system is a read-only, dm-verity-protected `/usr` image updated atomically with A/B swaps and automatic rollback, while `/etc`, `/var` and `/home` live on a TPM-bound encrypted root partition that can be factory-reset. The desktop is Hyprland with DankMaterialShell, and the default browser is [Trivalent](https://github.com/secureblue/Trivalent).

> **Status:** experimental. The build has not yet produced a released image, and the SELinux policy runs in permissive mode until the desktop policy is complete.

## Contents

- [Security model](#security-model)
- [Image and extensions](#image-and-extensions)
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
| Code integrity | IPE restricts kernel modules and firmware to the verified image and its extensions; module signatures are enforced |
| Execution control | The writable root partition, homes, `/tmp` and `/dev/shm` are mounted `noexec`, and SELinux denies confined users execution from their home and `/tmp`; the only writable executable location is system-wide Flatpak |
| Mandatory access control | SELinux (refpolicy) with all logins confined as `staff_u`; permissive until the desktop policy is complete |
| User namespaces | Enabled, but creation is permitted only to SELinux domains that need it (browser sandbox, bubblewrap) |
| Privileges | No setuid or setgid binaries; administration through `run0` and polkit |
| Kernel | Linux stable with selected [linux-hardened](https://github.com/anthraxx/linux-hardened) patches, built with Clang (kCFI/FineIBT), reduced attack surface and lockdown in confidentiality mode |
| Disk encryption | LUKS2 bound to the TPM through a signed PCR 11 policy valid only in the initrd, plus a systemd-pcrlock policy for firmware, Secure Boot and bootloader (optional PIN); the TPM rate-limits PIN guesses and its lockout cannot be reset; each home is a separate systemd-homed LUKS image |
| Memory allocator | GrapheneOS [hardened_malloc](https://github.com/GrapheneOS/hardened_malloc), preloaded into every process (`/etc/ld.so.preload`), with [no_rlimit_as](https://github.com/HastD/no_rlimit_as) so address-space limits cannot break it; also preloaded into Flatpak apps |
| Peripherals | USBGuard blocks unknown USB devices; IOMMU enforced; Thunderbolt and about 760 unused or risky kernel modules blocked |
| Flatpak | Flathub limited to verified publishers; apps and runtimes updated daily |
| Crash data | Crashes are logged with a backtrace; core dumps (process memory) are not stored |
| Network | firewalld with inbound traffic dropped by default, encrypted DNS (dnscrypt-proxy, which also blocks IPv6 (AAAA) lookups), authenticated time (NTS) |

## Image and extensions

Each release contains one image for x86_64 systems with AMD or Intel graphics, plus optional [system extensions](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html) that are merged into `/usr` at boot:

| Extension | Adds |
|---|---|
| `nvidia` | Open NVIDIA kernel modules (signed during the kernel build), `nvidia-utils` and hybrid-graphics device links |
| `asus` | asusctl and rog-control-center for ASUS laptops |

Each extension is a dm-verity image signed with the db key. It is built in the same run as `/usr` and merges only into that exact version (`SYSEXT_LEVEL`); `systemd-sysext` refuses unsigned images, and the IPE policy in the UKI pins each extension's root hash for kernel modules and firmware. Extensions are defined in `components/<name>/`: `packages`, `units` to enable, and `root_files/usr`.

Installed extensions are sysupdate features and are updated with `/usr`. To add or remove one later:

```sh
run0 updatectl enable --now nvidia    # downloads it for the running version
run0 updatectl disable --now nvidia
```

The change takes effect at the next boot.

## Disk layout

| # | Partition | Contents | Protection |
|---|---|---|---|
| 1 | ESP | systemd-boot, UKIs, pcrlock policy credential | Contents signed for Secure Boot |
| 2, 4 | `/usr` A, B | Operating system (EROFS) | dm-verity |
| 3, 5 | `/usr` verity A, B | dm-verity hash trees | — |
| 6 | Root | `/etc` changes, `/var`, `/home`, Flatpak, system extensions | LUKS2: TPM2 + pcrlock (optional PIN), recovery key; mounted `noexec` |

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

## Troubleshooting

`tungsten-debug` writes a report to your home directory: failed units, errors from this boot, crashes, SELinux denials, local `/etc` changes, USBGuard, boot entries, updates and TPM keyslots. It asks for authentication once for the root-only parts.

`tungsten-audit` checks that the security settings are in effect (Secure Boot, dm-verity, IPE, lockdown, SELinux, `noexec` mounts, hardened_malloc, Flatpak hardening, services, TPM binding and PIN lockout) and prints PASS, WARN or FAIL for each. Its exit status is the number of failed checks.

## Building

Builds run on GitHub Actions.

### Repository layout

| Path | Purpose |
|---|---|
| `build.sh` | Builds the image and its system extensions |
| `components/` | System extensions: packages, units and files under `/usr` |
| `root_files/` | Files copied into every image; `etc/skel` holds the default user configuration |
| `kernel/` | `linux-tungsten` package: PKGBUILD, config fragment and vendored linux-hardened patches |
| `packages/` | SELinux userspace builder and PKGBUILDs for Trivalent, hardened_malloc, dms-greeter, usbguard-notifier, erofs-utils, no_rlimit_as and a patched Quickshell |
| `selinux/` | Local SELinux policy module |
| `keys/` | Public signing keys, Secure Boot key tooling and vendored Microsoft certificates |
| `install/` | Disk installer and Secure Boot enrollment |
| `scripts/` | Build helpers and vendoring scripts |

### One-time setup

1. **Enable the commit hook**, which rejects private key material:
   ```sh
   git config core.hooksPath .githooks
   ```
2. **Create the `release` environment:** Settings → Environments → *New environment* `release` → *Deployment branches and tags* → *Selected branches and tags* → add `master`. All signing secrets below are environment secrets of `release`, so only workflows running on `master` can read them; do not add them as repository secrets.
3. **Create the release signing key** as described in [`keys/README.md`](keys/README.md). Commit `keys/tungsten.pgp` and add the secret key as the `TUNGSTEN_GPG_KEY` secret.
4. **Create the Secure Boot hierarchy** on an offline machine with `efitools` installed:
   ```sh
   keys/make-secureboot-keys.sh /path/to/offline/storage
   ```
   Commit `keys/secureboot/`. Add the generated `SB_DB_KEY.base64` and `SB_DB_CRT.base64` values as the `SB_DB_KEY` and `SB_DB_CRT` secrets. The PK and KEK private keys never leave the offline machine.
5. **Create the PCR signing key**, which signs each UKI's expected PCR 11 values:
   ```sh
   keys/make-pcr-key.sh /path/to/offline/storage
   ```
   Commit `keys/tpm2-pcr-public-key.pem` and add `TPM2_PCR_KEY.base64` as the `TPM2_PCR_KEY` secret.
6. **Allow workflows to publish releases and open pull requests:** Settings → Actions → General → Workflow permissions → *Read and write*, and *Allow GitHub Actions to create and approve pull requests*.
7. **Back up the private keys** offline, encrypted (for example with `age -p`), in at least two places, and test restoring them once.

### Workflows

| Workflow | Output | Trigger |
|---|---|---|
| Update | Verified version bumps: commits for routine updates, pull requests for the rest | Daily, manual |
| Build packages | Signed `[tungsten]` pacman repository on the `packages` release | Changes to package inputs, started by *Update*, manual |
| Build OS image | The image, its extensions and a signed `SHA256SUMS` as the latest release | Every two days, configuration changes, after a package build, manual |

Run *Build packages* with **all** selected before the first image build. Only package groups whose inputs changed are rebuilt; the kernel build uses a compiler cache that is saved even when a build times out.

## Installation

Download a release's files, verify them, and run the installer from an Arch Linux live ISO:

```sh
gpgv --keyring keys/tungsten.pgp SHA256SUMS.gpg SHA256SUMS
install/tungsten-install.sh /dev/nvme0n1 ./release
```

The installer erases the disk, creates the partition layout above, writes the first image, installs the bootloader, offers each extension (preselected when the hardware is detected) and asks for a recovery passphrase for the root partition. Given a file instead of a disk, it creates a VM image; `install/run-vm.sh` boots it with UEFI and a software TPM.

### Secure Boot enrollment

If the firmware is in Setup Mode, the installer offers to enroll keys; `install/enroll-secureboot.sh` can also be run on its own. It offers two choices:

- **TungstenOS only.** Only TungstenOS boots; option ROMs and other operating systems are rejected.
- **TungstenOS and Microsoft.** Certificates from Microsoft's `MicrosoftAndThirdParty` template can be selected individually. Preselected: Microsoft KEK 2K CA 2023, Windows UEFI CA 2023, Option ROM UEFI CA 2023 and UEFI CA 2011 (required by option ROMs signed before 2023). The third-party Microsoft UEFI CA 2023 is opt-in. Microsoft's revocation list (dbx) is applied whenever a Microsoft db certificate is enrolled.

Before writing, the script checks the TPM event log and warns if the selection would block option ROMs that the system loaded during the current boot.

### First boot

1. Unlock the root partition with the recovery passphrase.
2. Create the first user when prompted. This account is added to `wheel` and is the administrator.
3. Bind the root partition to the TPM. This shows a pcrlock recovery PIN once; store it with the passphrase. After a factory reset, the same command also creates a recovery key.
   ```sh
   run0 tungsten-tpm-enroll
   ```
4. Create a separate everyday account outside `wheel`:
   ```sh
   run0 homectl create <name> --storage=luks --noexec=yes
   ```

## Updates

`systemd-sysupdate` downloads new releases, verifies `SHA256SUMS.gpg` against the key built into the image, and writes the new `/usr` and verity images to the inactive slot, and the matching versions of enabled extensions to `/var/lib/extensions.d`. The new UKI is installed with boot counting: a boot counts as successful once the login screen is up and still running 20 seconds later, and if that fails three times, systemd-boot returns to the previous version. After each update the pcrlock policy is extended to cover the new UKI, so the root partition keeps unlocking from the TPM.

Applications are installed with Flatpak, system-wide only:

```sh
flatpak install flathub <application>
```

Per-user (`--user`) Flatpak installations cannot run, because the root partition and home directories do not allow execution.

A factory reset also removes installed extensions; enable them again with `updatectl enable --now`.

## Automation

The *Update* workflow runs daily. Each component's updater verifies the new upstream release before changing the pinned version; if verification fails, nothing changes.

| Component | Verification | Applied |
|---|---|---|
| Trivalent | secureblue's signed repository metadata | committed automatically |
| NVIDIA modules, erofs-utils | checksums from Arch Linux's packaging | committed automatically |
| archlinuxhardened SELinux packages | commit signed by the maintainer's key | committed automatically |
| Kernel point release | linux-hardened tag signature, kernel.org tarball signature, unchanged patch set, patches apply without fuzz, config check passes | committed automatically, otherwise pull request |
| New kernel series, changed patch set or stale override | as above | pull request |
| secureblue module blocklist | GitHub-verified commit signature | pull request when blocked modules change |
| hardened_malloc, dms-greeter | upstream does not sign; review the linked changes | pull request |
| GitHub Actions | pinned by commit hash | Dependabot pull request, monthly |

Automatic updates start the package build, which starts the image build when it succeeds. Images are published only if every build succeeds, and installed systems fall back to the previous version if a new one fails to boot.

Requires *Settings → Actions → General → Allow GitHub Actions to create and approve pull requests*.

## Maintenance

### Kernel

Point releases are applied by the *Update* workflow. For a new series or a pull request that needs work:

```sh
cd kernel
./update-hardened-patches.sh <version> hardened1   # export linux-hardened as individual patches (tag signature verified)
$EDITOR patches/series                              # comment out patches to skip
./check-patches.sh                                  # apply the series to a pristine tarball
./check-config.sh                                   # regenerate config.slim and check the config
```

Update `pkgver` and the tarball checksum in `kernel/PKGBUILD`. Patches that conflict once their neighbours are disabled are kept as rebased copies in `kernel/patch-overrides/`. `config.fragment` lists every deviation from Arch's linux-hardened configuration, and the build fails if any of them is not honoured. `config.slim` disables the options that build modules blocked in modprobe; regenerate it with `kernel/update-slim-config.py <patched-tree>` whenever the blocklists change. The NVIDIA module version follows Arch's `nvidia-utils` automatically.

### SELinux policy

The system boots in permissive mode. To complete the policy, collect denials from normal use:

```sh
run0 ausearch -m avc -ts boot | audit2allow -R
```

Add reviewed rules to `selinux/tungsten.te` and repeat until no denials remain. Then set `SELINUX=enforcing` in `build.sh` and disable `CONFIG_SECURITY_SELINUX_DEVELOP` in `kernel/config.fragment`.

### Manual updates

Everything else is handled by the *Update* workflow. These remain manual because they change rarely:

| Component | Procedure |
|---|---|
| Microsoft certificates and dbx | Replace files in `keys/microsoft/` from a reviewed commit of microsoft/secureboot_objects and regenerate `SHA256SUMS` |
| usbguard-notifier | Bump `pkgver` and the checksum in `packages/usbguard-notifier/PKGBUILD` (the release signature is verified at build time) |
| Signing keys in `kernel/keys/` and `packages/*.asc` | Refresh when a key's expiry is extended (linux-hardened key: end of 2027, archlinuxhardened signing subkey: May 2027) |

## Supply chain

Packages not available from Arch Linux are built from source in CI and published in a repository signed with the TungstenOS key.

| Source | Verification |
|---|---|
| Linux kernel | kernel.org tarball signatures |
| linux-hardened patches | Vendored in the repository and reviewed per patch |
| archlinuxhardened/selinux | Pinned commit verified against the maintainer's key (`E25E254C8EE4D303554BF5AFEC701A1DA494C5EB`); upstream tarballs verified with the keys in that signed tree. The project's prebuilt repository is unsigned and not used. GNU sources (coreutils, findutils, gnulib) are fetched from GitHub mirrors because of Savannah outages; their signed release tags are still verified. |
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
