"""Sign release manifests on Windows using a CurrentUser DPAPI-protected key.

Requires cryptography. Private bytes never go into files, arguments or output.
Run --help for initialization and signing. See docs/SIGNING.md for recovery limits.
"""
import argparse
import base64
import csv
import ctypes
from ctypes import wintypes
import hashlib
import io
from pathlib import Path
import re
import subprocess
import sys

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


class Blob(ctypes.Structure):
    _fields_ = [('size', wintypes.DWORD), ('data', ctypes.POINTER(ctypes.c_ubyte))]


def dpapi(data, encrypt):
    if sys.platform != 'win32':
        raise OSError('This signer requires Windows CurrentUser DPAPI')
    buffer = (ctypes.c_ubyte * len(data)).from_buffer_copy(data)
    source, result = Blob(len(data), buffer), Blob()
    crypt32 = ctypes.WinDLL('crypt32', use_last_error=True)
    function = crypt32.CryptProtectData if encrypt else crypt32.CryptUnprotectData
    function.argtypes = [ctypes.POINTER(Blob), ctypes.c_void_p, ctypes.POINTER(Blob),
                         ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(Blob)]
    function.restype = wintypes.BOOL
    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel32.LocalFree.argtypes = [ctypes.c_void_p]
    kernel32.LocalFree.restype = ctypes.c_void_p
    try:
        # UI_FORBIDDEN; deliberately omit LOCAL_MACHINE so other users cannot decrypt.
        if not function(ctypes.byref(source), None, None, None, None, 1, ctypes.byref(result)):
            raise ctypes.WinError(ctypes.get_last_error())
        return ctypes.string_at(result.data, result.size)
    finally:
        ctypes.memset(buffer, 0, len(data))
        if result.data:
            ctypes.memset(result.data, 0, result.size)
            kernel32.LocalFree(result.data)


def unprotect(data):
    return dpapi(data, False)


def initialize(key_dir, pin):
    if key_dir.exists():
        raise FileExistsError('Existing signing directory is never replaced')
    if pin.exists() and pin.read_text().strip():
        raise ValueError('Existing public pin requires an explicit key rotation procedure')
    sid_output = subprocess.check_output(['whoami', '/user', '/fo', 'csv', '/nh'], text=True)
    sid = next(csv.reader(io.StringIO(sid_output)))[1]
    if not re.fullmatch(r'S-1-[0-9-]+', sid):
        raise ValueError('Unable to verify current Windows identity')
    key_dir.mkdir()
    # No inherited access. The new directory grants only the owner and SYSTEM.
    subprocess.run(['icacls', str(key_dir), '/inheritance:r', '/grant:r',
                    '*' + sid + ':(OI)(CI)F', '*S-1-5-18:(OI)(CI)F'],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    key = Ed25519PrivateKey.generate()
    protected = dpapi(key.private_bytes_raw(), True)
    recovered = Ed25519PrivateKey.from_private_bytes(unprotect(protected))
    if recovered.public_key().public_bytes_raw() != key.public_key().public_bytes_raw():
        raise ValueError('DPAPI round trip failed')
    with (key_dir / 'release-key.dpapi').open('xb') as output:
        output.write(protected)
    pin.write_text(base64.b64encode(key.public_key().public_bytes_raw()).decode() + '\n',
                   encoding='ascii')


def sign_assets(key_dir, pin, output_dir, assets):
    public = base64.b64decode(pin.read_text().strip(), validate=True)
    key = Ed25519PrivateKey.from_private_bytes(unprotect((key_dir / 'release-key.dpapi').read_bytes()))
    if public != key.public_key().public_bytes_raw():
        raise ValueError('Signing key does not match the application public pin')
    names = [asset.name for asset in assets]
    if (not names or len(set(names)) != len(names) or
            any(not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._+-]*', name) or
                name in {'SHA256SUMS', 'SHA256SUMS.sig'} for name in names)):
        raise ValueError('Release asset names must be unique, unambiguous filenames')
    lines = []
    for asset in sorted(assets, key=lambda item: item.name):
        with asset.open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        lines.append(f'{digest}  {asset.name}\n')
    manifest = ''.join(lines).encode('ascii')
    signature = key.sign(manifest)
    key.public_key().verify(signature, manifest)
    output_dir.mkdir()
    (output_dir / 'SHA256SUMS').write_bytes(manifest)
    (output_dir / 'SHA256SUMS.sig').write_bytes(signature)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['init', 'sign'])
    parser.add_argument('--key-dir', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, required=True)
    parser.add_argument('--out-dir', type=Path)
    parser.add_argument('assets', nargs='*', type=Path)
    args = parser.parse_args()
    if args.command == 'init':
        if args.assets or args.out_dir:
            parser.error('init takes no assets or output directory')
        initialize(args.key_dir, args.public_key)
    else:
        if not args.out_dir or not args.assets:
            parser.error('sign requires --out-dir and at least one asset')
        sign_assets(args.key_dir, args.public_key, args.out_dir, args.assets)
    print('Release signing operation verified.')


if __name__ == '__main__':
    main()
