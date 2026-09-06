#!/usr/bin/env python3
"""Fetch the NetBird client LabDesk bundles, pinned by manifest.txt.

    fetch.py windows x86_64 <outdir>   -> <outdir>/netbird.exe, <outdir>/wintun.dll
    fetch.py linux   x86_64 <outdir>   -> <outdir>/netbird

Every archive is checked against the SHA-256 in manifest.txt before anything
is extracted; a mismatch is a build failure, never a warning.
"""
import hashlib
import io
import os
import sys
import tarfile
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ARCH = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}


def manifest():
    out = {}
    with open(os.path.join(HERE, "manifest.txt"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            digest, name, url = line.split()
            out[name] = (digest, url)
    return out


def fetch(name, entries):
    digest, url = entries[name]
    print(f"fetching {name}")
    data = urllib.request.urlopen(url, timeout=120).read()
    got = hashlib.sha256(data).hexdigest()
    if got != digest:
        sys.exit(f"{name}: sha256 {got} does not match the pinned {digest}")
    print(f"{name}: sha256 verified")
    return data


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("windows", "linux"):
        sys.exit(__doc__)
    platform, arch, outdir = sys.argv[1], ARCH[sys.argv[2]], sys.argv[3]
    entries = manifest()
    os.makedirs(outdir, exist_ok=True)
    tar_name = [n for n in entries if n.startswith("netbird_") and n.endswith(f"_{platform}_{arch}.tar.gz")][0]
    with tarfile.open(fileobj=io.BytesIO(fetch(tar_name, entries)), mode="r:gz") as tar:
        exe = "netbird.exe" if platform == "windows" else "netbird"
        member = tar.getmember(exe)
        with tar.extractfile(member) as src, open(os.path.join(outdir, exe), "wb") as dst:
            dst.write(src.read())
        if platform == "linux":
            os.chmod(os.path.join(outdir, exe), 0o755)
    if platform == "windows":
        zip_name = [n for n in entries if n.startswith("wintun-")][0]
        with zipfile.ZipFile(io.BytesIO(fetch(zip_name, entries))) as z:
            with open(os.path.join(outdir, "wintun.dll"), "wb") as dst:
                dst.write(z.read(f"wintun/bin/{arch}/wintun.dll"))
    print("bundled:", sorted(os.listdir(outdir)))


if __name__ == "__main__":
    main()
