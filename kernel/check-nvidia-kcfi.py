#!/usr/bin/env python3
"""Fail the build when NVIDIA's code would trip kCFI at runtime.

1. NVOC dispatch slots: every function assigned to one slot (pThis->__fooBar__ = &impl)
   is called through the same pointer type, so all of them must carry the same kCFI
   hash in nvidia.ko. A different hash is a guaranteed CFI panic on the GPUs that use it.
2. Bindata accessors (g_bindata_*.c) are defined in translation units that never see
   their declarations in the NVOC headers; their prototypes must match textually.

usage: check-nvidia-kcfi.py <NVIDIA-kernel-module-source dir> <nvidia.ko>
"""
import collections, glob, os, re, subprocess, sys

src, ko = sys.argv[1], sys.argv[2]
gen = os.path.join(src, 'src/nvidia/generated')
bad = 0

# kCFI preamble hashes (with -fsanitize-kcfi-arity the register varies, the hash does not)
dis = subprocess.run(['llvm-objdump', '-d', '--no-show-raw-insn', ko],
                     check=True, capture_output=True, text=True).stdout
hashes, cur = {}, None
for line in dis.splitlines():
    m = re.match(r'^[0-9a-f]+ <__cfi_(.+)>:$', line)
    if m:
        cur = m.group(1); continue
    if cur:
        m = re.search(r'movl\s+\$0x([0-9a-f]+),\s*%(?:e[a-z]{2}|r\d+d)\b', line)
        if m:
            hashes[cur] = int(m.group(1), 16)
        cur = None

slots = collections.defaultdict(set)
for f in glob.glob(os.path.join(gen, 'g_*_nvoc.c')):
    for m in re.finditer(r'->(__\w+__)\s*=\s*&(\w+);', open(f, errors='ignore').read()):
        slots[(os.path.basename(f), m.group(1))].add(m.group(2))
for (f, slot), fns in sorted(slots.items()):
    hs = {fn: hashes[fn] for fn in fns if fn in hashes}
    if len(set(hs.values())) > 1:
        bad += 1
        print(f'kCFI: {f} {slot}: ' + ', '.join(f'{fn}={h:#010x}' for fn, h in sorted(hs.items())))

norm = lambda a: re.sub(r'\s+', '', re.sub(r'\bp\w+\b', '', a))
decl = {}
for f in glob.glob(os.path.join(gen, 'g_*_nvoc.h')):
    for m in re.finditer(r'^const BINDATA_ARCHIVE \*\s*(\w+)\(([^)]*)\);', open(f, errors='ignore').read(), re.M):
        decl[m.group(1)] = m.group(2)
for f in glob.glob(os.path.join(gen, 'g_bindata_*.c')):
    for m in re.finditer(r'^const BINDATA_ARCHIVE \*\s*(\w+)\(([^)]*)\)\s*$', open(f, errors='ignore').read(), re.M):
        n, args = m.group(1), m.group(2)
        if n in decl and norm(args) != norm(decl[n]):
            bad += 1
            print(f'kCFI: {os.path.basename(f)}: {n}({args}) declared as ({decl[n]})')

print(f'checked {len(slots)} NVOC dispatch slots and {len(decl)} bindata declarations: {bad} mismatches')
sys.exit(1 if bad else 0)
