#!/usr/bin/env bash
# Builds the image: SELinux-labeled EROFS /usr, dm-verity tree, signed UKI, and one
# signed system extension (sysext) per directory in components/.
# Env: OS_BUILD_TAG, UPDATE_URL, TUNGSTEN_REPO,
#      SB_DIR (db.key, db.pem, tpm2-pcr-private-key.pem)
set -euo pipefail
: "${OS_BUILD_TAG:?}" "${UPDATE_URL:?}" "${TUNGSTEN_REPO:?}" "${SB_DIR:?}"

SRC="$(cd "$(dirname -- "$0")" && pwd)"
IMAGE_ID=tungsten
WORKDIR=/tungsten/rootfs
EXTDIR=/tungsten/ext
OUT=/tungsten/out
POLICY=refpolicy-arch
EXTENSIONS=()
for d in "$SRC"/components/*/; do EXTENSIONS+=("$(basename "$d")"); done
# Word list from a file, without comments.
words() { [ -f "$1" ] && sed 's/#.*//' "$1" | xargs || :; }

if [ "$EUID" -ne 0 ]; then echo "Be root!"; exit 1; fi

for m in "$EXTDIR"/*/merged "$EXTDIR"/*/rw; do umount -R "$m" 2>/dev/null || :; done
umount -R "$WORKDIR" 2>/dev/null || :
rm -rf "$WORKDIR" "$EXTDIR" "$OUT" && mkdir -p "$WORKDIR" "$EXTDIR" "$OUT"

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

  tpm2-tss tpm2-tools hardened_malloc no_rlimit_as usbguard usbguard-notifier

  # Network
  networkmanager iptables firewalld firewall-config dnscrypt-proxy ntpd-rs bluez bluez-utils

  # Desktop
  plymouth greetd greetd-dms-greeter flatpak
  hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk dms-shell quickshell
  matugen polkit alacritty zsh nautilus nwg-look adw-gtk-theme kdeconnect papirus-icon-theme
  ttf-jetbrains-mono noto-fonts noto-fonts-emoji
  pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber pavucontrol qt6-multimedia-ffmpeg
  gnome-keyring wl-clipboard grim slurp libnotify xdg-utils udiskie
  power-profiles-daemon trivalent qemu-desktop libvirt virt-manager bazaar

  # Tools
  less git jq fastfetch tmux helix rsync unzip zip arch-repro-status
)
# Retried: a mirror dropping connections aborts the whole transaction.
for try in 1 2 3; do
  pacstrap -C "$PACMAN_CONF" -c -P "$WORKDIR" "${PACKAGES[@]}" && break
  [ "$try" -lt 3 ] || exit 1
  echo "pacstrap failed, retrying ($try)" >&2; sleep 120
done

# The SELinux module is compiled on the host; the image has no make/m4.
pacman -S --needed --noconfirm --config "$PACMAN_CONF" make m4 checkpolicy semodule-utils selinux-refpolicy-arch
SEBUILD=$(mktemp -d)
cp "$SRC"/selinux/tungsten.{te,fc,if} "$SEBUILD"/
make -C "$SEBUILD" -f /usr/share/selinux/"$POLICY"/include/Makefile tungsten.pp

arch-chroot "$WORKDIR" /bin/bash -c 'mkdir -p /usr/share/tungstenos && arch-repro-status > /usr/share/tungstenos/arch-repro-status-report.txt 2>&1 || :'

# Quickshell must be the [tungsten] build: Arch's crashes under hardened_malloc (use-after-free,
# quickshell issue #947). Fail if a newer Arch release replaced it.
pacman --config "$PACMAN_CONF" --root "$WORKDIR" -Sl tungsten | grep -c '^tungsten quickshell .*\[installed' >/dev/null \
  || { echo "quickshell is not the patched [tungsten] build; update packages/quickshell" >&2; exit 1; }

# --- Configuration ---
cp -r "$SRC"/root_files/. "$WORKDIR"/
# Staged outside /tmp: arch-chroot mounts an empty tmpfs there.
STAGE=/root/tungsten-build
install -Dm644 "$SEBUILD"/tungsten.pp "$WORKDIR$STAGE"/tungsten.pp
install -Dm755 "$SRC"/scripts/remove-suid.sh "$WORKDIR$STAGE"/remove-suid.sh

sed -i "s|@UPDATE_URL@|${UPDATE_URL}|; s|@IMAGE_ID@|${IMAGE_ID}|g" "$WORKDIR"/usr/lib/sysupdate.d/*.transfer
sed -i -e 's/^NAME=.*/NAME="TungstenOS"/' -e 's/^PRETTY_NAME=.*/PRETTY_NAME="TungstenOS"/' "$WORKDIR"/usr/lib/os-release
cat >> "$WORKDIR"/usr/lib/os-release <<EOF
IMAGE_ID=${IMAGE_ID}
IMAGE_VERSION=${OS_BUILD_TAG}
SYSEXT_LEVEL=${OS_BUILD_TAG}
EOF

# dnscrypt-proxy: set each key, failing if it isn't present exactly once.
DNSCRYPT="$WORKDIR"/etc/dnscrypt-proxy/dnscrypt-proxy.toml
set_toml() {
  local n; n=$(grep -cE "^#? *$1 *=" "$DNSCRYPT")
  [ "$n" -eq 1 ] || { echo "dnscrypt-proxy.toml: '$1' found $n times" >&2; exit 1; }
  sed -i -E "s|^#? *$1 *=.*|$1 = $2|" "$DNSCRYPT"
}
set_toml server_names "['cloudflare', 'google']"
set_toml require_dnssec true
set_toml timeout 1000
set_toml blocked_query_response "'refused'"
set_toml dnscrypt_ephemeral_keys true
set_toml block_ipv6 true
set_toml skip_incompatible true

# The only keyring systemd-sysupdate trusts.
install -Dm644 "$SRC"/keys/tungsten.pgp "$WORKDIR"/usr/lib/systemd/import-pubring.pgp
# Verifies the dm-verity signatures of system extensions.
install -Dm644 "$SB_DIR"/db.pem "$WORKDIR"/usr/lib/verity.d/tungsten.crt
# Verifies the signed PCR 11 policy in each UKI (default path for systemd-cryptenroll).
install -Dm644 "$SRC"/keys/tpm2-pcr-public-key.pem "$WORKDIR"/etc/systemd/tpm2-pcr-public-key.pem

arch-chroot "$WORKDIR" /bin/bash -s "$POLICY" <<'CHROOT'
set -euo pipefail
POLICY=$1

ln -sf /usr/share/zoneinfo/UTC /etc/localtime
locale-gen

systemctl enable \
  greetd NetworkManager firewalld usbguard tungsten-usbguard-init dnscrypt-proxy ntpd-rs \
  systemd-homed systemd-homed-firstboot auditd power-profiles-daemon da-lockout-clear-tpm \
  libvirtd.socket tungsten-relabel \
  systemd-sysupdate.timer systemd-boot-update tungsten-boot-check \
  systemd-pcrlock-firmware-code systemd-pcrlock-firmware-config \
  systemd-pcrlock-secureboot-policy systemd-pcrlock-secureboot-authority \
  tungsten-pcrlock-predict systemd-pcrlock-make-policy systemd-sysext
systemctl disable systemd-timesyncd.service
# Locale, keymap and timezone come from the image, and root stays locked: never ask.
systemctl mask systemd-firstboot.service

# SELinux: permissive until the desktop policy is complete.
sed -i 's/^SELINUX=.*/SELINUX=permissive/; s/^SELINUXTYPE=.*/SELINUXTYPE='"$POLICY"'/' /etc/selinux/config
semodule -n -s "$POLICY" -X 300 -i /root/tungsten-build/tungsten.pp
# Confined logins (staff_t) cannot create user namespaces themselves.
semanage login -N -S "$POLICY" -m -s staff_u __default__
# /etc defaults in the image carry the labels of their /etc paths.
semanage fcontext -N -S "$POLICY" -a -e /etc /usr/share/factory/etc
# Local /etc changes live in the overlay's upper directory on the root partition.
semanage fcontext -N -S "$POLICY" -a -e /etc /var/lib/tungsten/etc/upper

bash /root/tungsten-build/remove-suid.sh

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
chmod 600 /etc/usbguard/IPCAccessControl.d/:usbguard

cat >> /etc/fstab <<'FSTAB'
tmpfs             /tmp              tmpfs  defaults,noexec,nosuid,nodev,mode=1777,size=4G                     0  0
# The only writable location mounted exec (the root partition is noexec).
/var/lib/flatpak  /var/lib/flatpak  none   bind,exec,nosuid,nodev,x-mount.mkdir                               0  0
FSTAB

mkdir -p /etc/flatpak/remotes.d
curl -fsSL --proto '=https' https://dl.flathub.org/repo/flathub.flatpakrepo -o /etc/flatpak/remotes.d/flathub.flatpakrepo

passwd -l root
rm -rf /etc/machine-id /root/tungsten-build
CHROOT

# Programs that will not start because a library is missing or too old (repository skew).
arch-chroot "$WORKDIR" /bin/bash -c '
  for f in /usr/bin/*; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    out=$(ldd -r "$f" 2>&1) || continue
    grep -q "not found" <<<"$out" && continue   # optional dependency not installed
    bad=$(grep "undefined symbol" <<<"$out" | head -3)
    [ -n "$bad" ] && printf "::warning::%s will not start (library version skew):\n%s\n" "$f" "$bad"
  done; :'

# --- Drop files nothing in the image can use (there is no compiler) ---
rm -rf "$WORKDIR"/usr/include "$WORKDIR"/usr/src/debug \
       "$WORKDIR"/usr/share/{doc,gtk-doc,info,devhelp,gir-1.0,vala} \
       "$WORKDIR"/usr/lib/{cmake,pkgconfig} "$WORKDIR"/usr/share/pkgconfig
find "$WORKDIR"/usr/lib -name '*.a' -type f -delete
echo "Largest directories in /usr:"
du -x --max-depth=3 "$WORKDIR"/usr 2>/dev/null | sort -rn | sed -n '2,21p' | numfmt --field=1 --from-unit=1024 --to=iec | sed "s#$WORKDIR##"

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

# --- System extensions ---
# Each is built on an overlay above the finished base tree, so it contains exactly the
# files its packages add or change. Only /usr is kept.
FC="$WORKDIR/etc/selinux/$POLICY/contexts/files/file_contexts"
declare -A EXT_HASH
build_extension() {
  local name=$1 comp=$SRC/components/$1 E=$EXTDIR/$1 pkgs units u t
  mkdir -p "$E"/rw "$E"/merged "$E"/tree "$E"/repart.d
  # The container's own overlayfs cannot hold an upper directory; use memory.
  mount -t tmpfs -o size=12G tmpfs "$E"/rw
  mkdir -p "$E"/rw/upper "$E"/rw/work
  mount -t overlay overlay -o "lowerdir=$WORKDIR,upperdir=$E/rw/upper,workdir=$E/rw/work" "$E"/merged
  read -ra pkgs <<<"$(words "$comp"/packages)"
  pacstrap -C "$PACMAN_CONF" -c "$E"/merged "${pkgs[@]}" || { sleep 30; pacstrap -C "$PACMAN_CONF" -c "$E"/merged "${pkgs[@]}"; }
  [ -d "$comp"/root_files ] && cp -r "$comp"/root_files/. "$E"/merged/
  # Enable units through .wants symlinks under /usr, as /etc is not part of an extension.
  read -ra units <<<"$(words "$comp"/units)"
  for u in "${units[@]}"; do
    [[ $u == *.* ]] || u=$u.service
    [ -f "$E"/merged/usr/lib/systemd/system/"$u" ] || { echo "$name: unit $u not found" >&2; exit 1; }
    for t in $(sed -n 's/^\(WantedBy\|RequiredBy\)=//p' "$E"/merged/usr/lib/systemd/system/"$u"); do
      mkdir -p "$E"/merged/usr/lib/systemd/system/"$t".wants
      ln -sf ../"$u" "$E"/merged/usr/lib/systemd/system/"$t".wants/"$u"
    done
  done
  umount "$E"/merged

  # Copy without xattrs: overlayfs metadata must not reach the image.
  cp -dR --preserve=mode,ownership,timestamps,links "$E"/rw/upper/usr "$E"/tree/usr
  find "$E"/tree/usr -type c -delete
  local dropped; dropped=$(find "$E"/rw/upper/etc -mindepth 1 -maxdepth 1 ! -name ld.so.cache ! -name pacman.d -printf '/etc/%P ' 2>/dev/null || :)
  [ -z "$dropped" ] || echo "::warning::$name: changes outside /usr are not part of the extension: $dropped"
  rm -rf "$E"/tree/usr/include "$E"/tree/usr/src "$E"/tree/usr/share/{doc,gtk-doc,info,man} \
         "$E"/tree/usr/lib/{cmake,pkgconfig}
  find "$E"/tree/usr -type f -perm /6000 ! -path '*/usr/bin/nvidia-modprobe' -exec chmod ug-s {} +
  [ -d "$E"/tree/usr/lib/tmpfiles.d ] && \
    sed -i -E '/^[zZ][[:space:]]+\/usr\S*[[:space:]]+[0-7]?[2467][0-7]{3}[[:space:]]/d' "$E"/tree/usr/lib/tmpfiles.d/*.conf
  mkdir -p "$E"/tree/usr/lib/extension-release.d
  printf 'ID=arch\nSYSEXT_LEVEL=%s\nSYSEXT_SCOPE=system\n' "$OS_BUILD_TAG" \
    > "$E"/tree/usr/lib/extension-release.d/extension-release."$name"
  umount "$E"/rw

  mkfs.erofs -L "$name" --mount-point=/usr --file-contexts="$FC" \
    -zzstd,level=15 -C262144 -Efragments,ztailpacking "$E"/usr.erofs "$E"/tree/usr
  printf '[Partition]\nType=usr\nCopyBlocks=%s\nVerity=data\nVerityMatchKey=usr\n' "$E"/usr.erofs > "$E"/repart.d/10-usr.conf
  printf '[Partition]\nType=usr-verity\nVerity=hash\nVerityMatchKey=usr\nMinimize=best\n' > "$E"/repart.d/20-usr-verity.conf
  printf '[Partition]\nType=usr-verity-sig\nVerity=signature\nVerityMatchKey=usr\n' > "$E"/repart.d/30-usr-verity-sig.conf
  EXT_HASH[$name]=$(systemd-repart --empty=create --size=auto --dry-run=no \
      --definitions="$E"/repart.d --private-key="$SB_DIR"/db.key --certificate="$SB_DIR"/db.pem \
      --json=short "$OUT/${name}_${OS_BUILD_TAG}.raw" | jq -r '[.[] | .roothash // empty | select(. != "")][0]')
  [[ ${EXT_HASH[$name]} =~ ^[0-9a-f]{64}$ ]] || { echo "$name: no verity root hash" >&2; exit 1; }
  echo "$name extension hash: ${EXT_HASH[$name]}"
}
for e in "${EXTENSIONS[@]}"; do build_extension "$e"; done

# --- Bootloader (installed to the ESP by systemd-boot-update.service) ---
sbsign --key "$SB_DIR"/db.key --cert "$SB_DIR"/db.pem \
  --output "$WORKDIR"/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed \
  "$WORKDIR"/usr/lib/systemd/boot/efi/systemd-bootx64.efi
cp "$WORKDIR"/usr/lib/systemd/boot/efi/systemd-bootx64.efi.signed "$OUT/${IMAGE_ID}_${OS_BUILD_TAG}.systemd-bootx64.efi"

# --- /usr image and verity ---
USR_IMG=/tmp/usr.erofs
VERITY_IMG=/tmp/usr.verity
mkfs.erofs -L "${OS_BUILD_TAG}" --mount-point=/usr --file-contexts="$FC" \
  -zzstd,level=15 -C262144 -Efragments,ztailpacking "$USR_IMG" "$WORKDIR/usr"

VERITY_HASH=$(veritysetup format "$USR_IMG" "$VERITY_IMG" | awk '/Root hash:/ {print $3}')
[ "${#VERITY_HASH}" -eq 64 ] || { echo "Failed to extract verity root hash"; exit 1; }
# Partition UUIDs derive from the root hash (Discoverable Partitions Spec).
hex_to_uuid() { echo "${1:0:8}-${1:8:4}-${1:12:4}-${1:16:4}-${1:20:12}"; }
UUID_USR=$(hex_to_uuid "${VERITY_HASH:0:32}")
UUID_VERITY=$(hex_to_uuid "${VERITY_HASH:32:32}")
mv "$USR_IMG"    "$OUT/${IMAGE_ID}_${OS_BUILD_TAG}_${UUID_USR}.usr.raw"
mv "$VERITY_IMG" "$OUT/${IMAGE_ID}_${OS_BUILD_TAG}_${UUID_VERITY}.usr-verity.raw"
echo "usr hash: $VERITY_HASH"
# GitHub rejects release assets of 2 GiB or more; fail here rather than at upload.
for f in "$OUT"/*; do
  [ "$(stat -c %s "$f")" -lt 2147483648 ] || { echo "$(basename "$f") is $(du -h "$f" | cut -f1), over GitHub's 2 GiB asset limit" >&2; exit 1; }
done
ls -lh "$OUT"

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
for e in "${EXTENSIONS[@]}"; do
  printf 'op=KMODULE  dmverity_roothash=sha256:%s action=ALLOW\nop=FIRMWARE dmverity_roothash=sha256:%s action=ALLOW\n' \
    "${EXT_HASH[$e]}" "${EXT_HASH[$e]}" >> "$WORKDIR"/etc/ipe_setup/hardened.policy
done
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
  mount.usrfstype=erofs mount.usrflags=ro
  root=/dev/mapper/root rootfstype=ext4 rootflags=nosuid,nodev,noexec rw
  rd.emergency=halt rd.shell=0 systemd.ssh_auto=no audit_backlog_limit=8192
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
  preempt=full loglevel=0 quiet splash
  # Splash on the firmware framebuffer: the initramfs has no GPU drivers (no kms hook)
  plymouth.use-simpledrm
)
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

rm -rf /tmp/ucode.img /tmp/uki.efi "$PACMAN_CONF" "$SEBUILD" "$EXTDIR"
ls -lh "$OUT"
