import base64
import hashlib
import tempfile
import unittest
from pathlib import Path
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.exceptions import InvalidSignature
import release_verify


class ReleaseVerificationTests(unittest.TestCase):
    def test_only_complete_authentic_unchanged_release_is_accepted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary); assets=root/'assets'; assets.mkdir()
            key=Ed25519PrivateKey.generate(); pin=root/'public-key'
            pin.write_bytes(base64.b64encode(key.public_key().public_bytes_raw()))
            package=assets/'LabDesk-1.4.0.msi'; package.write_bytes(b'installer')
            manifest=f'{hashlib.sha256(package.read_bytes()).hexdigest()}  {package.name}\n'.encode()
            (assets/'SHA256SUMS').write_bytes(manifest)
            (assets/'SHA256SUMS.sig').write_bytes(key.sign(manifest))
            self.assertEqual(release_verify.verify_directory(pin,assets),[package.name])
            package.write_bytes(b'tampered installer')
            with self.assertRaisesRegex(ValueError,'digest'):release_verify.verify_directory(pin,assets)
            package.write_bytes(b'installer')
            (assets/'SHA256SUMS').write_bytes(manifest+b'\n')
            with self.assertRaises(InvalidSignature):release_verify.verify_directory(pin,assets)
            (assets/'SHA256SUMS').write_bytes(manifest)
            (assets/'unsigned.exe').write_bytes(b'unapproved')
            with self.assertRaisesRegex(ValueError,'inventory'):release_verify.verify_directory(pin,assets)
            (assets/'unsigned.exe').unlink()
            unsafe=manifest.replace(package.name.encode(),b'../outside.msi')
            (assets/'SHA256SUMS').write_bytes(unsafe);(assets/'SHA256SUMS.sig').write_bytes(key.sign(unsafe))
            with self.assertRaisesRegex(ValueError,'filename'):release_verify.verify_directory(pin,assets)


if __name__=='__main__':unittest.main()
