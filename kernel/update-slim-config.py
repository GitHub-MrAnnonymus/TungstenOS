#!/usr/bin/env python3
"""Regenerate kernel/config.slim: disable the kernel options that build modules
TungstenOS blocks with `install <module> /bin/false` (or /bin/true), the
filesystems listed in EXTRA_DISABLE, and the server/datacenter hardware in
HARDWARE_RULES.

Usage: kernel/update-slim-config.py <patched-kernel-tree>
The tree must already contain a .config produced from config.base + config.fragment.
"""
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
BLOCKLISTS = [
    "root_files/usr/lib/modprobe.d/secureblue.conf",
    "root_files/usr/lib/modprobe.d/secureblue-framebuffer.conf",
    "root_files/etc/modprobe.d/blacklist.conf",
]
# Modules blocked only in some images, or blocked from autoloading but loaded on demand.
KEEP_MODULES = {"bluetooth", "btusb", "btintel", "i915", "xe", "nouveau",
                "thunderbolt", "thunderbolt_net", "thunderbolt_stream"}
# Filesystems not worth building even though they are not in the blocklists.
EXTRA_DISABLE = ["OMFS_FS", "VBOXSF_FS", "NTFS_FS"]

# obj-$(CONFIG_X), obj-${CONFIG_X} and obj-$(subst y,$(CONFIG_A),$(CONFIG_X)): the
# last CONFIG_ symbol in the expression is the one that builds the object.
# Server and datacenter hardware, matched by the Kconfig file that defines the option.
DC_ETHERNET = ("mellanox", "chelsio", "qlogic", "sfc", "netronome", "cavium", "huawei",
               "pensando", "cisco", "amazon", "google", "microsoft", "emulex", "fungible",
               "marvell/octeon", "brocade", "neterion", "mscc", "wangxun", "meta",
               "intel/ice", "intel/idpf")
SCSI_KEEP = {"SCSI", "SCSI_MOD", "SCSI_COMMON", "SCSI_DMA", "SCSI_CONSTANTS", "SCSI_LOGGING",
             "SCSI_PROC_FS", "SCSI_SCAN_ASYNC", "SCSI_NETLINK", "SCSI_LOWLEVEL",
             "BLK_DEV_SD", "BLK_DEV_BSG", "CHR_DEV_SG", "BLK_DEV_SR",
             "SCSI_ISCSI_ATTRS", "ISCSI_TCP",                       # software iSCSI client
             "SCSI_VIRTIO", "HYPERV_STORAGE", "VMWARE_PVSCSI", "XEN_SCSI_FRONTEND"}  # VM guests
HARDWARE_RULES = {
    "server SCSI/RAID/FC/iSCSI controllers":
        lambda s, p: p.startswith(("drivers/scsi/", "drivers/target/")) and s not in SCSI_KEEP,
    "server power-supply/voltage monitors":
        lambda s, p: p.startswith("drivers/hwmon/pmbus/"),
    "datacenter Ethernet":
        lambda s, p: any(p.startswith(f"drivers/net/ethernet/{v}/") for v in DC_ETHERNET)
                     or s in ("BNX2", "BNX2X", "BNXT", "CNIC"),
    "parallel-ATA controllers":
        lambda s, p: s.startswith("PATA_"),
    "staging and niche buses":
        lambda s, p: p.startswith(("drivers/staging/", "drivers/greybus/", "drivers/most/",
                                   "drivers/vme/", "drivers/counter/")),
}

OBJ_RE = re.compile(r"^obj-(\S*?CONFIG_[A-Za-z0-9_]+\S*?)\s*[+:]?=\s*(.*)$")
SYM_RE = re.compile(r"CONFIG_[A-Za-z0-9_]+")


def norm(name):
    return name.replace("-", "_")


def blocked_modules():
    mods = set()
    for rel in BLOCKLISTS:
        for line in open(os.path.join(REPO, rel)):
            line = line.split("#", 1)[0].split()
            if len(line) >= 3 and line[0] == "install" and line[2] in ("/bin/false", "/bin/true"):
                mods.add(norm(line[1]))
            elif len(line) == 2 and line[0] == "blacklist" and rel.endswith("framebuffer.conf"):
                mods.add(norm(line[1]))
    return mods - {norm(m) for m in KEEP_MODULES}


def module_symbols(tree):
    """Map module name -> set of CONFIG symbols that build it as a top-level object."""
    result = {}
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in (".git", "Documentation", "tools", "scripts")]
        for f in files:
            if f not in ("Makefile", "Kbuild"):
                continue
            text = open(os.path.join(root, f), errors="replace").read().replace("\\\n", " ")
            for line in text.splitlines():
                m = OBJ_RE.match(line.strip())
                if not m:
                    continue
                sym = SYM_RE.findall(m.group(1))[-1]
                for obj in m.group(2).split():
                    if obj.endswith(".o"):
                        result.setdefault(norm(os.path.basename(obj)[:-2]), set()).add(sym)
    return result


def kconfig_locations(tree):
    """Map option name -> path of the Kconfig file that defines it."""
    loc = {}
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in (".git", "Documentation", "tools", "scripts")]
        for f in files:
            if f.startswith("Kconfig"):
                path = os.path.relpath(os.path.join(root, f), tree)
                text = open(os.path.join(root, f), errors="replace").read()
                for m in re.finditer(r"^\s*(?:menu)?config\s+([A-Za-z0-9_]+)", text, re.M):
                    loc.setdefault(m.group(1), path)
    return loc


def config_value(tree, sym):
    out = subprocess.run(["scripts/config", "--file", ".config", "-s", sym[len("CONFIG_"):]],
                         cwd=tree, capture_output=True, text=True).stdout.strip()
    return "n" if out in ("undef", "") else out


def main():
    tree = sys.argv[1]
    mods = blocked_modules()
    table = module_symbols(tree)

    wanted, unmapped = {}, []
    for mod in sorted(mods):
        syms = table.get(mod)
        if not syms:
            unmapped.append(mod)
            continue
        for s in syms:
            if config_value(tree, s) in ("y", "m"):
                wanted.setdefault(s, set()).add(mod)
    for s in EXTRA_DISABLE:
        if config_value(tree, "CONFIG_" + s) in ("y", "m"):
            wanted.setdefault("CONFIG_" + s, set()).add("(filesystem)")

    enabled = {l.split("=")[0][len("CONFIG_"):] for l in open(os.path.join(tree, ".config"))
               if l.startswith("CONFIG_") and l.rstrip().endswith(("=y", "=m"))}
    loc = kconfig_locations(tree)
    for label, rule in HARDWARE_RULES.items():
        for s in sorted(enabled):
            if rule(s, loc.get(s, "")):
                wanted.setdefault("CONFIG_" + s, set()).add(label)

    # Drop options that olddefconfig turns back on (selected by something we keep).
    base = open(os.path.join(tree, ".config")).read()
    candidates = sorted(wanted)
    while True:
        frag = "".join(f"# {s} is not set\n" for s in candidates)
        open(os.path.join(tree, ".slim.tmp"), "w").write(frag)
        open(os.path.join(tree, ".config"), "w").write(base)
        subprocess.run(["scripts/kconfig/merge_config.sh", "-m", ".config", ".slim.tmp"],
                       cwd=tree, check=True, capture_output=True)
        subprocess.run(["make", "olddefconfig"], cwd=tree, check=True, capture_output=True,
                       env={**os.environ, "LLVM": os.environ.get("LLVM", "")})
        stuck = [s for s in candidates if config_value(tree, s) != "n"]
        if not stuck:
            break
        candidates = [s for s in candidates if s not in stuck]
    final = open(os.path.join(tree, ".config")).read()
    open(os.path.join(tree, ".config"), "w").write(base)
    os.remove(os.path.join(tree, ".slim.tmp"))

    with open(os.path.join(HERE, "config.slim"), "w") as out:
        out.write("# Generated by update-slim-config.py from the modprobe blocklists. Do not edit.\n")
        for s in candidates:
            out.write(f"# {s} is not set\n")

    dropped = sorted(set(wanted) - set(candidates))
    count = lambda t: sum(1 for l in t.splitlines() if l.endswith("=m"))
    print(f"blocked modules: {len(mods)}, unmapped (not built or renamed): {len(unmapped)}")
    print(f"options disabled: {len(candidates)}; kept because selected elsewhere: {len(dropped)}")
    if dropped:
        print("  " + " ".join(dropped))
    print(f"modules built: {count(base)} -> {count(final)}")


if __name__ == "__main__":
    main()
