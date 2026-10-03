#!/usr/bin/env python3
"""Pin the newest Trivalent x86_64 RPM in PKGBUILD.

Trust chain: pinned secureblue key -> signed repomd.xml -> primary metadata hash -> RPM hash.
"""
import hashlib
import os
import re
import subprocess
import sys
import tempfile
import urllib.request
import xml.etree.ElementTree as ET

REPO = "https://repo.secureblue.dev"
FINGERPRINT = "26B4463ED8F313BC7E3FBDF9D9223AF0F47B3E41"
HERE = os.path.dirname(os.path.abspath(__file__))
NS = {"repo": "http://linux.duke.edu/metadata/repo", "common": "http://linux.duke.edu/metadata/common"}


def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "tungstenos-trivalent-update/1"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def verify_repomd(tmp):
    key = os.path.join(HERE, "secureblue.asc")
    out = subprocess.run(["gpg", "--show-keys", "--with-colons", key], check=True, capture_output=True, text=True).stdout
    fprs = [l.split(":")[9] for l in out.splitlines() if l.startswith("fpr:")]
    if not fprs or fprs[0] != FINGERPRINT:
        sys.exit(f"secureblue.asc primary key fingerprint {fprs[:1]} != pinned {FINGERPRINT}")
    keyring = os.path.join(tmp, "secureblue.gpg")
    subprocess.run(["gpg", "--dearmor", "-o", keyring, key], check=True)

    repomd = fetch(f"{REPO}/repodata/repomd.xml")
    sig = fetch(f"{REPO}/repodata/repomd.xml.asc")
    with open(os.path.join(tmp, "repomd.xml"), "wb") as f:
        f.write(repomd)
    with open(os.path.join(tmp, "repomd.xml.asc"), "wb") as f:
        f.write(sig)
    subprocess.run(["gpgv", "--keyring", keyring, os.path.join(tmp, "repomd.xml.asc"), os.path.join(tmp, "repomd.xml")], check=True)
    return repomd


def primary_xml(repomd):
    root = ET.fromstring(repomd)
    data = root.find("repo:data[@type='primary']", NS)
    href = data.find("repo:location", NS).get("href")
    want = data.find("repo:checksum", NS).text
    blob = fetch(f"{REPO}/{href}")
    if hashlib.sha256(blob).hexdigest() != want:
        sys.exit("primary metadata checksum mismatch")
    return subprocess.run(["zstd", "-dq", "-c"], input=blob, check=True, capture_output=True).stdout


def verkey(pkg):
    v = pkg.find("common:version", NS)
    return [int(x) for x in re.findall(r"\d+", v.get("ver"))], int(v.get("rel"))


def main():
    with tempfile.TemporaryDirectory() as tmp:
        primary = ET.fromstring(primary_xml(verify_repomd(tmp)))

    pkgs = [p for p in primary.findall("common:package", NS)
            if p.find("common:name", NS).text == "trivalent" and p.find("common:arch", NS).text == "x86_64"]
    newest = max(pkgs, key=verkey)
    ver = newest.find("common:version", NS)
    pkgver, rel = ver.get("ver"), ver.get("rel")
    sha = newest.find("common:checksum", NS).text
    href = newest.find("common:location", NS).get("href")
    if href != f"Packages/trivalent-{pkgver}-{rel}.x86_64.rpm":
        sys.exit(f"unexpected RPM location {href}")

    path = os.path.join(HERE, "PKGBUILD")
    s = open(path).read()
    old = re.search(r"^pkgver=(.*)$", s, re.M).group(1), re.search(r"^_rpmrel=(.*)$", s, re.M).group(1)
    if old == (pkgver, rel):
        print(f"trivalent already at {pkgver}-{rel}")
        return
    s = re.sub(r"^pkgver=.*$", f"pkgver={pkgver}", s, flags=re.M)
    s = re.sub(r"^_rpmrel=.*$", f"_rpmrel={rel}", s, flags=re.M)
    s = re.sub(r"^pkgrel=.*$", "pkgrel=1", s, flags=re.M)
    s = re.sub(r"^sha256sums=\('[0-9a-f]+'", f"sha256sums=('{sha}'", s, flags=re.M)
    open(path, "w").write(s)
    print(f"trivalent {old[0]}-{old[1]} -> {pkgver}-{rel}")


if __name__ == "__main__":
    main()
