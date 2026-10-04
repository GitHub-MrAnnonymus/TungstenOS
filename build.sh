#!/usr/bin/env bash
# Builds one image variant: SELinux-labeled EROFS /usr, dm-verity tree, signed UKI.
# Env: VARIANT, OS_BUILD_TAG, UPDATE_URL, TUNGSTEN_REPO,
#      SB_DIR (db.key, db.pem, tpm2-pcr-private-key.pem)
set -euo pipefail
: "${VARIANT:?}" "${OS_BUILD_TAG:?}" "${UPDATE_URL:?}" "${TUNGSTEN_REPO:?}" "${SB_DIR:?}"

SRC="$(cd "$(dirname -- "$0")" && pwd)"
VDIR="$SRC/variants/$VARIANT"
[ -d "$VDIR" ] || { echo "unknown variant $VARIANT" >&2; exit 1; }
IMAGE_ID="tungsten-$VARIANT"
WORKDIR=/tungsten/rootfs
OUT=/tungsten/out
POLICY=refpolicy-arch

read -ra COMPONENTS <<<"$(sed 's/#.*//' "$VDIR/components" | xargs)"
LAYERS=()
for c in "${COMPONENTS[@]}"; do LAYERS+=("$SRC/components/$c"); done
LAYERS+=("$VDIR")
# Word list from <file> across all components and the variant.
layer_list() { local l; for l in "${LAYERS[@]}"; do [ -f "$l/$1" ] && sed 's/#.*//' "$l/$1"; done | xargs; }

if [ "$EUID" -ne 0 ]; then echo "Be root!"; exit 1; fi

umount -R "$WORKDIR" 2>/dev/null || :
rm -rf "$WORKDIR" "$OUT" && mkdir -p "$WORKDIR" "$OUT"

# --- Packages ---
# [tungsten] goes first so its packages win over same-named providers.
PACMAN_CONF=/tmp/pacman-tungsten.conf
awk -v repo="$TUNGSTEN_REPO" '
  /^\[/ { skip = ($0 == "[tungsten]") }   # drop a [tungsten] section the host may already have
  skip { next }
  /^\[core\]/ && !done { print "[tungsten]\nSigLevel = Required DatabaseRequired\nServer = " repo "\n"; done=1 }
  { print }' /etc/pacman.conf > "$PACMAN_CONF"

PACKAGES=(
  # Base system (SELinux-enabled builds)
  base systemd-selinux systemd-libs-selinux systemd-sysvcompat-selinux
  pam-selinux pambase-selinux coreutils-selinux findutils-selinux
  util-linux-selinux util-linux-libs-selinux shadow-selinux iproute2-selinux
  psmisc-selinux dbus-broker-selinux

  # SELinux
  libselinux libsepol libsemanage policycoreutils semodule-utils checkpolicy
  secilc selinux-python setools selinux-refpolicy-arch audit

  # Kernel, firmware, graphics
  linux-tungsten linux-firmware sof-firmware amd-ucode intel-ucode mkinitcpio
  mesa vulkan-radeon vulkan-intel intel-media-driver

  tpm2-tss tpm2-tools hardened_malloc usbguard usbguard-notifier

  # Network
  networkmanager iptables firewalld firewall-config dnscrypt-proxy ntpd-rs bluez bluez-utils

  # Desktop
  plymouth greetd greetd-dms-greeter flatpak
  hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk dms-shell quickshell
  matugen polkit kitty alacritty nautilus kdeconnect papirus-icon-theme
  ttf-jetbrains-mono noto-fonts noto-fonts-emoji
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol qt6-multimedia-ffmpeg
  gnome-keyring wl-clipboard grim slurp libnotify xdg-utils udiskie
  power-profiles-daemon trivalent qemu-full libvirt virt-manager bazaar

  # Tools
  less git jq fastfetch tmux helix rsync unzip zip arch-repro-status
)
read -ra EXTRA_PACKAGES <<<"$(layer_list packages)"
pacstrap -C "$PACMAN_CONF" -c -P "$WORKDIR" "${PACKAGES[@]}" "${EXTRA_PACKAGES[@]}"

# The SELinux module is compiled on the host; the image has no make/m4.
pacman -S --needed --noconfirm --config "$PACMAN_CONF" make m4 checkpolicy semodule-utils selinux-refpolicy-arch
SEBUILD=$(mktemp -d)
cp "$SRC"/selinux/tungsten.{te,fc,if} "$SEBUILD"/
make -C "$SEBUILD" -f /usr/share/selinux/"$POLICY"/include/Makefile tungsten.pp

arch-chroot "$WORKDIR" /bin/bash -c 'mkdir -p /usr/share/tungstenos && arch-repro-status > /usr/share/tungstenos/arch-repro-status-report.txt 2>&1 || :'

# --- Configuration ---
cp -r "$SRC"/root_files/. "$WORKDIR"/
for l in "${LAYERS[@]}"; do [ -d "$l/root_files" ] && cp -r "$l"/root_files/. "$WORKDIR"/; done
cp "$SEBUILD"/tungsten.pp "$WORKDIR"/tmp/tungsten.pp
cp "$SRC"/scripts/remove-suid.sh "$WORKDIR"/tmp/remove-suid.sh

sed -i "s|@UPDATE_URL@|${UPDATE_URL}|; s|@IMAGE_ID@|${IMAGE_ID}|g" "$WORKDIR"/usr/lib/sysupdate.d/*.transfer
cat >> "$WORKDIR"/usr/lib/os-release <<EOF
IMAGE_ID=${IMAGE_ID}
IMAGE_VERSION=${OS_BUILD_TAG}
EOF

# The only keyring systemd-sysupdate trusts.
install -Dm644 "$SRC"/keys/tungsten.pgp "$WORKDIR"/usr/lib/systemd/import-pubring.pgp
# Verifies the signed PCR 11 policy in each UKI (default path for systemd-cryptenroll).
install -Dm644 "$SRC"/keys/tpm2-pcr-public-key.pem "$WORKDIR"/etc/systemd/tpm2-pcr-public-key.pem

arch-chroot "$WORKDIR" /bin/bash -s "$POLICY" $(layer_list units) <<'CHROOT'
set -euo pipefail
POLICY=$1; shift

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
locale-gen

systemctl enable \
  greetd NetworkManager firewalld usbguard tungsten-usbguard-init dnscrypt-proxy ntpd-rs \
  systemd-homed systemd-homed-firstboot auditd power-profiles-daemon da-lockout-clear-tpm \
  libvirtd.socket tungsten-relabel \
  systemd-sysupdate.timer systemd-boot-update systemd-boot-check-no-failures \
  systemd-pcrlock-firmware-code systemd-pcrlock-firmware-config \
  systemd-pcrlock-secureboot-policy systemd-pcrlock-secureboot-authority \
  tungsten-pcrlock-predict systemd-pcrlock-make-policy \
  "$@"
systemctl disable systemd-timesyncd.service

# SELinux: permissive until the desktop policy is complete.
sed -i 's/^SELINUX=.*/SELINUX=permissive/; s/^SELINUXTYPE=.*/SELINUXTYPE='"$POLICY"'/' /etc/selinux/config
semodule -n -s "$POLICY" -X 300 -i /tmp/tungsten.pp
# Confined logins (staff_t) cannot create user namespaces themselves.
semanage login -N -S "$POLICY" -m -s staff_u __default__
# /etc defaults in the image carry the labels of their /etc paths.
semanage fcontext -N -S "$POLICY" -a -e /etc /usr/share/factory/etc

bash /tmp/remove-suid.sh

# Firewall: drop unsolicited inbound traffic.
sed -i 's/^DefaultZone=.*/DefaultZone=drop/' /etc/firewalld/firewalld.conf

# USBGuard: block unknown devices; rules for devices present at first boot are
# generated by tungsten-usbguard-init.service.
conf=/etc/usbguard/usbguard-daemon.conf
sed -i -e 's/^ImplicitPolicyTarget=.*/ImplicitPolicyTarget=block/' \
       -e 's/^PresentDevicePolicy=.*/PresentDevicePolicy=apply-policy/' \
       -e 's/^InsertedDevicePolicy=.*/InsertedDevicePolicy=apply-policy/' \
       -e 's/^IPCAllowedGroups=.*/IPCAllowedGroups=wheel usbguard/' "$conf"
: > /etc/usbguard/rules.conf
printf 'Devices=listen\nPolicy=list\nExceptions=listen\n' > /etc/usbguard/IPCAccessControl.d/:usbguard

cat >> /etc/fstab <<'FSTAB'
proc              /proc             proc   rw,nosuid,nodev,noexec,gid=26,hidepid=invisible                    0  0
tmpfs             /tmp              tmpfs  defaults,noexec,nosuid,nodev,mode=1777,size=4G                     0  0
# The only writable location mounted exec (the root partition is noexec).
/var/lib/flatpak  /var/lib/flatpak  none   bind,exec,nosuid,nodev,x-mount.mkdir                               0  0
FSTAB
patch /etc/dnscrypt-proxy/dnscrypt-proxy.toml /etc/patch_dnscryptproxy_toml.patch
rm /etc/patch_dnscryptproxy_toml.patch

mkdir -p /etc/flatpak/remotes.d
curl -fsSL --proto '=https' https://dl.flathub.org/repo/flathub.flatpakrepo -o /etc/flatpak/remotes.d/flathub.flatpakrepo

passwd -l root
rm -f /etc/machine-id /tmp/tungsten.pp /tmp/remove-suid.sh
CHROOT

# --- Hermetic /usr: everything outside /usr is recreated from /usr on boot ---
FACTORY="$WORKDIR"/usr/share/factory
TMPFILES="$WORKDIR"/usr/lib/tmpfiles.d/tungsten-factory.conf
rm -rf "$FACTORY" && mkdir -p "$FACTORY/var/lib"
# /etc defaults: the lower layer of the /etc overlay.
cp -a "$WORKDIR"/etc "$FACTORY"/etc
{
  echo "# Generated by build.sh: recreates the image's skeleton outside /usr."
  for p in "$WORKDIR"/*; do
    n=$(basename "$p")
    case "$n" in usr|etc|var|proc|sys|dev|run|tmp) continue ;; esac
    if [ -L "$p" ]; then echo "L /$n - - - - $(readlink "$p")"
    elif [ -d "$p" ]; then echo "d /$n $(stat -c %a "$p") - - -"; fi
  done
  echo "d /efi 0755 - - -"
  for p in "$WORKDIR"/var/lib/*; do
    n=$(basename "$p")
    [ "$n" = pacman ] && continue
    cp -a "$p" "$FACTORY/var/lib/$n"
    echo "C /var/lib/$n - - - - /usr/share/factory/var/lib/$n"
  done
} > "$TMPFILES"

# --- Bootloader (installed to the ESP by systemd-boot-update.service) ---
sbsign --key "$SB_DIR"/db.key --cert "$SB_DIR"/db.pem \
  --output "$WORKDIR"/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
  "$WORKDIR"/usr/lib/systemd/boot/efi/systemd-bootx64.efi
cp "$WORKDIR"/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed "$OUT/${IMAGE_ID}_${OS_BUILD_TAG}.systemd-bootx64.efi"

# --- /usr image and verity ---
FC="$WORKDIR/etc/selinux/$POLICY/contexts/files/file_contexts"
USR_IMG=/tmp/usr.erofs
VERITY_IMG=/tmp/usr.verity
mkfs.erofs -L "${OS_BUILD_TAG}" --mount-point=/usr --file-contexts="$FC" \
  -zlz4hc,12 -C65536 -Efragments,ztailpacking "$USR_IMG" "$WORKDIR/usr"

VERITY_HASH=$(veritysetup format "$USR_IMG" "$VERITY_IMG" | awk '/Root hash:/ {print $3}')
[ "${#VERITY_HASH}" -eq 64 ] || { echo "Failed to extract verity root hash"; exit 1; }
# Partition UUIDs derive from the root hash (Discoverable Partitions Spec).
hex_to_uuid() { echo "${1:0:8}-${1:8:4}-${1:12:4}-${1:16:4}-${1:20:12}"; }
UUID_USR=$(hex_to_uuid "${VERITY_HASH:0:32}")
UUID_VERITY=$(hex_to_uuid "${VERITY_HASH:32:32}")
mv "$USR_IMG"    "$OUT/${IMAGE_ID}_${OS_BUILD_TAG}_${UUID_USR}.usr.raw"
mv "$VERITY_IMG" "$OUT/${IMAGE_ID}_${OS_BUILD_TAG}_${UUID_VERITY}.usr-verity.raw"
echo "usr hash: $VERITY_HASH"

# --- IPE policy (initramfs only, as it embeds the verity hash) ---
mkdir -p "$WORKDIR"/etc/ipe_setup
cat > "$WORKDIR"/etc/ipe_setup/hardened.policy <<EOF
policy_name=hardened policy_version=0.0.0

DEFAULT action=DENY
# Execution is governed by SELinux and noexec mounts (Flatpak needs /var/lib/flatpak).
DEFAULT op=EXECUTE action=ALLOW

op=KMODULE  dmverity_roothash=sha256:$VERITY_HASH action=ALLOW
op=KMODULE  boot_verified=TRUE action=ALLOW
op=FIRMWARE dmverity_roothash=sha256:$VERITY_HASH action=ALLOW
op=FIRMWARE boot_verified=TRUE action=ALLOW
EOF
openssl smime -sign -in "$WORKDIR"/etc/ipe_setup/hardened.policy \
  -signer "$SB_DIR"/db.pem -inkey "$SB_DIR"/db.key \
  -noattr -nodetach -nosmimecap -outform der \
  -out "$WORKDIR"/etc/ipe_setup/hardened.policy.p7b
arch-chroot "$WORKDIR" mkinitcpio -p linux-tungsten

# --- UKI ---
BOOT="$WORKDIR"/boot
CMDLINE=(
  # Boot: verified /usr, encrypted writable root
  usrhash="$VERITY_HASH" systemd.verity_usr_options=panic-on-corruption
  root=/dev/mapper/root rootfstype=ext4 rootflags=nosuid,nodev,noexec rw
  rd.emergency=halt rd.shell=0 systemd.ssh_auto=no
  # LSMs and lockdown
  lsm=landlock,lockdown,yama,integrity,selinux,bpf,ipe ipe.enforce=1
  lockdown=confidentiality module.sig_enforce=1 bdev_allow_write_mounted=0
  proc_mem.force_override=ptrace
  # Memory
  slab_nomerge slab_debug=FZ init_on_alloc=1 init_on_free=1 page_alloc.shuffle=1
  randomize_kstack_offset=on hash_pointers=always vsyscall=none vdso32=0
  oops=panic debugfs=off zswap.enabled=0
  # Entropy
  random.trust_cpu=off random.trust_bootloader=off extra_latent_entropy
  # DMA
  iommu=force iommu.strict=1 iommu.passthrough=0 amd_iommu=force_isolation intel_iommu=on
  efi=disable_early_pci_dma modprobe.blacklist=thunderbolt mem_encrypt=on
  # CPU mitigations
  pti=on spectre_v2=on spec_store_bypass_disable=on l1d_flush=on l1tf=full,force
  gather_data_sampling=force tsx=off kvm.nx_huge_pages=force kvm.mitigate_smt_rsb=1
  # KVM
  kvm_amd.sev=1 kvm_amd.sev_es=1 kvm_amd.sev_snp=1 kvm-amd.nested=0 kvm-intel.nested=0
  # Misc
  preempt=full ipv6.disable=1 amd_pstate=active
  pcie_aspm.policy=powersupersave acpi.ec_no_wakeup=1 quiet loglevel=0 splash
)
read -ra EXTRA_CMDLINE <<<"$(layer_list cmdline)"
CMDLINE+=("${EXTRA_CMDLINE[@]}")
cat "$BOOT"/*-ucode.img > /tmp/ucode.img
ukify build \
  --output /tmp/uki.efi \
  --cmdline "${CMDLINE[*]}" \
  --os-release "@$WORKDIR/usr/lib/os-release" \
  --microcode /tmp/ucode.img \
  --linux "$BOOT/vmlinuz-linux-tungsten" \
  --initrd "$BOOT/initramfs-linux-tungsten.img" \
  --pcr-private-key "$SB_DIR"/tpm2-pcr-private-key.pem \
  --pcr-public-key "$SRC"/keys/tpm2-pcr-public-key.pem \
  --sign-initrd-pcrs
sbsign --key "$SB_DIR"/db.key --cert "$SB_DIR"/db.pem \
  --output "$OUT/${IMAGE_ID}_${OS_BUILD_TAG}.efi" /tmp/uki.efi

rm -rf /tmp/ucode.img /tmp/uki.efi "$PACMAN_CONF" "$SEBUILD"
ls -lh "$OUT"
