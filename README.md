# TungstenOS

TungstenOS is an image-based, verified-boot desktop operating system built from Arch Linux packages. Following the [hermetic `/usr`](https://0pointer.net/blog/fitting-everything-together.html) model, the operating system is a read-only, dm-verity-protected `/usr` image updated atomically with A/B swaps and automatic rollback, while `/etc`, `/var` and `/home` live on a TPM-bound encrypted root partition that can be factory-reset. The desktop is Hyprland with DankMaterialShell, and the default browser is [Trivalent](https://github.com/secureblue/Trivalent).

> **Status:** experimental. The build has not yet produced a released image. SELinux is enforcing; desktop rules are added to `selinux/tungsten.te` as denials are found.

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
| Mandatory access control | SELinux (refpolicy) in enforcing mode, with all logins confined as `user_u` and `run0` in the admin domain |
| User namespaces | Enabled, but creation is permitted only to SELinux domains that need it (browser sandbox, bubblewrap) |
| Privileges | No setuid or setgid binaries; administration through `run0` and polkit with a separate administrator account that cannot log in at the login screen |
| Password guessing | 3 failed attempts lock an account for 10 minutes (`pam_faillock`), every failure waits 3 seconds, and systemd-homed allows at most 10 password checks per 5 minutes per account, also across reboots |
| Kernel | Linux stable with selected [linux-hardened](https://github.com/anthraxx/linux-hardened) patches, built with Clang (kCFI), reduced attack surface and lockdown in confidentiality mode |
| Disk encryption | LUKS2 bound to the TPM through a signed PCR 11 policy valid only in the initrd, plus a systemd-pcrlock policy for firmware, Secure Boot and bootloader (optional PIN); the TPM rate-limits PIN guesses and its lockout cannot be reset; each home is a separate systemd-homed LUKS image |
| Memory allocator | GrapheneOS [hardened_malloc](https://github.com/GrapheneOS/hardened_malloc), preloaded into every process (`/etc/ld.so.preload`), with [no_rlimit_as](https://github.com/HastD/no_rlimit_as) so address-space limits cannot break it; also preloaded into Flatpak apps |
| Peripherals | USBGuard blocks unknown USB devices; IOMMU enforced; Thunderbolt and about 760 unused or risky kernel modules blocked |
| Flatpak | Flathub limited to verified publishers (switchable); apps and runtimes updated daily |
| Performance | CachyOS-style settings without a security cost (writeback, cache pressure, transparent huge pages on request, I/O schedulers, write limits for removable disks, audio power saving on battery only); `ntsync` for Wine and Proton; sched_ext schedulers (`scx-scheds`) to try by hand, those that do not need to read kernel memory (scx_bpfland, scx_flash, scx_cosmos) |
| Crash data | Crashes are logged with a backtrace; core dumps (process memory) are not stored |
| Startup entries | Tungsten Guard reports changes to the places where something can start with every login (user units, autostart, shell start files, Hyprland exec lines, shell plugins, Flatpak overrides, launcher entries), with a diff; root keeps the baseline, so accepting a change asks for the administrator (`run0 tungsten-persist accept`) |
| Logs | The system journal can be sealed (Forward Secure Sealing, `run0 tungsten-log-seal setup`): changes to earlier entries show when it is checked with the verification key, which stays off the machine |
| Network | firewalld with inbound traffic dropped by default, encrypted DNS (dnscrypt-proxy, which also blocks IPv6 (AAAA) lookups), authenticated time (NTS) |

## Image and extensions

Each release contains one image for x86_64 systems with AMD or Intel graphics, plus optional [system extensions](https://www.freedesktop.org/software/systemd/man/latest/systemd-sysext.html) that are merged into `/usr` at boot:

| Extension | Adds |
|---|---|
| `nvidia` | Open NVIDIA kernel modules (signed during the kernel build), `nvidia-utils` and hybrid-graphics device links |
| `asus` | asusctl and rog-control-center for ASUS laptops |
| `virt` | Virtual machines: QEMU, libvirt (`qemu:///system`) and virt-manager |

Each extension is a dm-verity image signed with the db key. It is built in the same run as `/usr` and merges only into that exact version (`SYSEXT_LEVEL`); `systemd-sysext` refuses unsigned images, and the IPE policy in the UKI pins each extension's root hash for kernel modules and firmware. Extensions are defined in `components/<name>/`: `packages`, `units` to enable, and `root_files/usr`. Files the packages add to `/etc` are shipped as factory defaults and copied to `/etc` at boot where missing; users and groups they declare are created after the merge.

Installed extensions are sysupdate features and are updated with `/usr`. To add or remove one later, as the normal user (polkit asks for the administrator password; as root through `run0`, the call is refused):

```sh
updatectl enable --now nvidia    # downloads it for the running version
updatectl disable --now nvidia
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

There is no swap on disk. Swap is zram, compressed memory (zstd, capacity equal to the RAM, at most 16 GiB, taking about a quarter to a third of the RAM when full; `/etc/systemd/zram-generator.conf`), so swapped-out memory never reaches storage. systemd-oomd stops a user's services when memory pressure stays high, before the system stalls. Hibernation is not supported.

The root partition is defined in `/usr/lib/repart.d`. If it is missing, for example after a factory reset (`run0 /usr/lib/systemd/systemd-factory-reset request`, then reboot), the initramfs recreates it with new keys and the system sets itself up again from `/usr`.

## Configuration

`/etc` is an overlay: the image's defaults (`/usr/share/factory/etc`, verified with `/usr`) are the lower layer, and local changes are stored on the root partition above them. Files that have not been changed follow image updates; changed files keep the local version.

```sh
tungsten-etc status              # list files that differ from the defaults
tungsten-etc diff /etc/<file>    # show the change for one file
run0 tungsten-etc reset <file>   # restore the default at the next boot (--all for everything)
```

Settings made with graphical tools, such as firewall-config, NetworkManager connections and USBGuard rules, are stored the same way.

USBGuard allows the devices present at first boot and blocks any new device until it is allowed (`run0 usbguard allow-device -p <id>`). The first-boot wizard shows that list (built-in parts marked), lets you remove devices that should not be allowed, such as a USB stick left plugged in, and allows the devices you plug in during that step. Members of the `usbguard` group receive notifications. The stricter linux-hardened mode, which blocks all new USB devices at the kernel level, remains available through `mydenyusb.service` and `usb-allow.service`.

Tungsten Guard (a shield in the bar) can lock the empty external USB ports at the controller, on demand or whenever the screen locks: a device plugged into a locked port is not enumerated, so nothing of it reaches the kernel. On laptops the ports are also locked from early boot (in the initrd, before the disk passphrase) until the first login; `/etc/tungsten/usb-lock-at-boot` (`yes` or `no`) overrides that, e.g. on a desktop where the keyboard is plugged in later. A reboot resets the ports: they are open during the firmware and the first seconds of the kernel. Devices behind a connected hub, and a system that is already compromised, are beyond it too: the firmware's own USB setting with a BIOS password is stronger.

Tailscale is installed but off (`run0 systemctl enable --now tailscaled`, then `run0 tailscale up`). tailscaled runs in its own SELinux domain and a systemd sandbox, without client logs to Tailscale; Tailscale SSH (remote root shells, bypassing the administrator password) and MagicDNS rewriting `/etc/resolv.conf` are not possible, so DNS stays with dnscrypt-proxy. Its firewall rules go through nftables directly (it starts no programs), and its state file with the node's keys is sealed with the TPM, so a copy of the disk does not carry the node's identity; if the TPM is cleared, remove `/var/lib/tailscale/tailscaled.state` and log in again (or set `TS_ENCRYPT_STATE=false` in `/etc/default/tailscaled`).

Programs you build yourself cannot run from the home or `/tmp` (both `noexec`), so development happens in containers: rootless Podman with [gVisor](https://gvisor.dev) as the only runtime, which gives each container its own application kernel instead of the host's. `visorbox enter` starts one for the current directory (an Arch Linux environment by default, `~/.config/visorbox/`). gVisor runs on the CPU's virtualization (KVM), so containers need VT-x/AMD-V (in a VM, nested virtualization). Containers may only mount directories under `~/Projects`, which has its own SELinux type; the rest of the home stays out of their reach. Files moved into it with `mv` keep their old type until `restorecon -R ~/Projects`.

Steam (Flatpak) keeps its client and games in `/var/lib/tungsten-steam/<uid>`, the only place besides Flatpak's own where Flatpak apps may run code. Further drives for games are mounted below `/var/lib/tungsten-games`, executable and labeled for game code, at every boot:

```sh
run0 tungsten-game-drive add /dev/sdb1 bulk   # prints the folder to add in Steam > Settings > Storage
tungsten-game-drive list
run0 tungsten-game-drive remove bulk          # files on the drive stay
```

ext4, btrfs, xfs and f2fs drives get a `SteamLibrary` folder owned by the user; NTFS, exFAT and FAT drives belong to the user as a whole.

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
| `install/` | Installer ISO with the live system, disk installer and Secure Boot enrollment |
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

### Development builds

For testing in a VM before a change reaches `master`, `install/dev/build.sh` builds the image locally with throwaway development keys (Secure Boot PK, KEK, db and PCR key, created on the first run in `~/.local/share/tungstenos-dev`, outside the repository). It runs `build.sh` with `sudo podman` in the same privileged `archlinux` container as CI, with the packages of the `[tungsten]` repository. Development images have no update URL, and the release keys are never involved.

`install/dev/vm.sh` runs the newest development build in a VM (through `install/run-vm.sh --release`). The first run creates the VM image and puts the development keys on its ESP; systemd-boot enrolls them in the VM's Setup Mode firmware and restarts it with Secure Boot on. Later runs install each new build into the inactive A/B slot, as an update would.

```sh
sudo pacman -S --needed podman mtools
install/dev/build.sh
install/dev/vm.sh
```

## Installation

### Installer ISO

`install/build-iso.sh` builds an ISO on an Arch Linux host (packages `archiso`, `libisoburn`, `systemd-ukify`, `erofs-utils`): it downloads and verifies the latest release and puts its files on the ISO under `/tungsten`. The boot menu offers:

- **TungstenOS live** (default): the release itself, built by `install/build-live-uki.sh` from the release's kernel, initramfs and systemd-stub. `/usr` is the release's dm-verity image on the boot medium, the root file system is a new ext4 in compressed memory (zram), and system extensions are added for the detected hardware, as the installer would preselect them. The live system never unlocks, mounts or partitions the computer's disks, does not touch the ESP and does not update itself; everything is lost at shutdown. The first-boot wizard runs as after an installation. A kernel panic is stored in an EFI variable and saved to `/var/lib/systemd/pstore` on the next boot.
- **TungstenOS live, kernel messages**: the same with the kernel log and boot status on screen instead of the splash.
- **TungstenOS installer**: archiso's `releng` profile with the installer, which starts on the first console: a terminal UI that asks for the disk, extensions, recovery passphrase and Secure Boot keys, shows a summary, and only then writes the disk.

The ISO boots with Secure Boot off or with the firmware in Setup Mode; the live system's UKI is not signed. The IPE policy loads only if the TungstenOS db certificate is enrolled in the firmware. The kernel has no CD-ROM driver, so the live system starts from a USB stick (`dd` the ISO; Ventoy is not supported) or a disk, not from an optical drive. In virt-manager, use a Q35 machine with UEFI (`OVMF_CODE.secboot.4m.fd` with the empty `OVMF_VARS.4m.fd` template, so the firmware starts in Setup Mode), an emulated TPM 2.0, and the ISO as a USB or VirtIO disk.

On the first boot of the installed system, a wizard on the console asks for the time zone, the computer name, the administrator and the everyday account, how the disk unlocks, and which USB devices may be used.

### Manual installation

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
2. Create two accounts when prompted: an administrator and your everyday account, with different passwords. The administrator is in `wheel`; its password authorizes `run0` and polkit prompts, and it cannot log in at the login screen (only on a console). Someone who learns the everyday password still cannot become root.
3. Bind the root partition to the TPM. The first-boot wizard asks how the disk should unlock: the TPM (optionally with a boot PIN) or the recovery passphrase at every boot, in which case it removes the initial TPM key, which any TungstenOS boot can use. To bind later, log in with the everyday account and run the command below (`run0` asks for the administrator's password). Either way it shows a pcrlock recovery PIN once; store it with the passphrase. After a factory reset the disk has a new key held only by the TPM: the first-boot wizard then also asks for a new recovery passphrase.
   ```sh
   run0 tungsten-tpm-enroll
   ```

## Updates

`systemd-sysupdate` downloads new releases, verifies `SHA256SUMS.gpg` against the key built into the image, and writes the new `/usr` and verity images to the inactive slot, and the matching versions of enabled extensions to `/var/lib/extensions.d`. The new UKI is installed with boot counting: a boot counts as successful once the login screen is up and still running 20 seconds later, and if that fails three times, systemd-boot returns to the previous version. After each update the pcrlock policy is extended to cover the new UKI, so the root partition keeps unlocking from the TPM. Both A/B UKIs stay in the policy, so the automatic rollback unlocks too, until the new version has proven itself: once a desktop session has run for a minute on two of its boots, older UKIs leave the policy (`tungsten-boot-confirm.service`). The previous version then stays in the boot menu but asks for the recovery key.

Applications are installed with Flatpak, system-wide only:

```sh
flatpak install flathub <application>
```

Per-user (`--user`) Flatpak installations cannot run, because the root partition and home directories do not allow execution.

Flathub is limited to apps whose publisher Flathub has verified. `tungsten-unverified-flatpaks enable` lifts that for the whole system (it asks for an administrator password), and `disable` restores it; the choice survives image updates.

On some laptops (seen on Tiger Lake) the built-in screen blinks whenever the GPU's display audio powers up: during the boot splash and when the login screen and each session start. `run0 tungsten-display-audio off` turns HDMI/DP audio off for that machine (from the next boot; laptop speakers, headphones, USB and Bluetooth audio keep working), `on` brings it back.

New builds are published as pre-releases first, the experimental channel; once a build is verified, the "Promote image to stable" workflow marks it as the latest release, which machines update from by default. `run0 tungsten-channel experimental` switches a machine to every new build (a test machine), `run0 tungsten-channel stable` back; updates never go to an older version, so a machine leaving experimental keeps its version until stable has a newer one.

A factory reset also removes installed extensions; enable them again with `updatectl enable --now <name>`.

An update can also change the desktop defaults in `/etc/skel` (the Hyprland configuration, Dux Shell plugins), which new accounts get. For existing accounts, Tungsten Guard lists the changed files with their diffs and applies each one only after approval (`/usr/lib/tungsten/skel-sync`): files the user never edited are replaced, edits are merged where they do not overlap with the update's, and a replaced file is backed up to `~/.local/state/tungsten/skel/backup`. Settings the shell manages itself (`settings.json`, generated colors, monitor layout) are left alone.

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

### Secure Boot revocations

TungstenOS revokes its own signed boot binaries with dbx updates signed by the KEK, as Microsoft does for the binaries it signs. When systemd-boot or systemd-stub has a Secure Boot bypass (systemd's GitHub security advisories), release a fixed build, then revoke the affected builds on the offline machine:

```sh
# The systemd-boot and UKIs of the affected releases, from their GitHub release assets
keys/sign-efi-update.sh /path/to/offline/storage systemd-boot-cve-2027-1234 dbx-hash *.efi
# After a key rotation: trust the new db certificate first, revoke the old one later
keys/sign-efi-update.sh /path/to/offline/storage new-db-key db-cert new-db.crt
keys/sign-efi-update.sh /path/to/offline/storage old-db-key dbx-cert old-db.crt
```

Commit `keys/secureboot/updates/`. Each system applies the updates of its image at boot (`tungsten-secureboot-update.service`), refreshes its pcrlock policy for the new PCR 7, and holds an update back while it would revoke systemd-boot, a UKI or an add-on on its ESP; Tungsten Guard shows held-back updates. Microsoft's own dbx updates reach machines that trust Microsoft's keys through fwupd. To test in the VM, sign with the development KEK: `SB_PUB=~/.local/share/tungstenos-dev/keys keys/sign-efi-update.sh ~/.local/share/tungstenos-dev/keys <name> ...`.

### SELinux policy

The system is enforcing and cannot be switched to permissive at runtime (`secure_mode_policyload`). Collect denials from normal use:

```sh
run0 ausearch -m avc -ts boot | audit2allow -R
```

Add reviewed rules to `selinux/tungsten.te` and repeat until no denials remain.

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
