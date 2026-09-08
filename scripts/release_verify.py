"""Verify an offline-signed release inventory without access to a private key."""
import argparse
import base64
import hashlib
import re
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def verify_directory(pin, directory):
    manifest_path=directory/'SHA256SUMS'
    if manifest_path.stat().st_size>1024*1024:
        raise ValueError('Release manifest is too large')
    manifest=manifest_path.read_bytes()
    public=Ed25519PublicKey.from_public_bytes(base64.b64decode(pin.read_bytes().strip(),validate=True))
    public.verify((directory/'SHA256SUMS.sig').read_bytes(),manifest)
    names=[]
    for line in manifest.decode('ascii').splitlines():
        match=re.fullmatch(r'([a-f0-9]{64})  ([A-Za-z0-9][A-Za-z0-9._+-]*)',line)
        if not match:
            raise ValueError('Invalid release digest or filename')
        digest,name=match.groups()
        if name in names or name in {'SHA256SUMS','SHA256SUMS.sig'}:
            raise ValueError('Duplicate or reserved release filename')
        path=directory/name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Missing or unsafe release filename')
        with path.open('rb') as stream:
            if hashlib.file_digest(stream,'sha256').hexdigest()!=digest:
                raise ValueError('Release asset digest mismatch: '+name)
        names.append(name)
    actual={path.name for path in directory.iterdir() if path.name not in {'SHA256SUMS','SHA256SUMS.sig'}}
    if not names or set(names)!=actual:
        raise ValueError('Release inventory differs from the signed manifest')
    return sorted(names)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--public-key',required=True,type=Path)
    parser.add_argument('directory',type=Path)
    args=parser.parse_args()
    names=verify_directory(args.public_key,args.directory)
    print(f'Verified signature and hashes for {len(names)} release assets.')
