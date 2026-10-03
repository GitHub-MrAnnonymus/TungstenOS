#!/bin/bash
# Strips all setuid/setgid bits (as secureblue does); runs in the image chroot.
set -euo pipefail

# Needed by the NVIDIA userspace driver.
keep=(/usr/bin/nvidia-modprobe)

find /usr -xdev -type f -perm /6000 -print0 | while IFS= read -r -d '' f; do
  for k in "${keep[@]}"; do [ "$f" = "$k" ] && continue 2; done
  echo "removing setuid/setgid: $f"
  chmod ug-s "$f"
done

rm -f /usr/bin/{sudo,sudoedit,su,pkexec,chsh,chfn}

setcap_if() { [ -f "$2" ] && setcap "$1" "$2" && echo "caps $1 on $2"; }
# User FUSE mounts (document portal)
setcap_if cap_sys_admin=ep /usr/bin/fusermount3
# Password checks for non-homed accounts
setcap_if cap_dac_read_search,cap_audit_write=ep /usr/bin/unix_chkpwd

left=$(find /usr -xdev -type f -perm /6000)
for k in "${keep[@]}"; do left=$(grep -vx "$k" <<<"$left" || :); done
if [ -n "$left" ]; then echo "setuid/setgid files remain: $left" >&2; exit 1; fi
