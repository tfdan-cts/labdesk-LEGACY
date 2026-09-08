import base64
import tempfile
import unittest
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

import release_sign


class ReleaseSigningTests(unittest.TestCase):
    def test_protected_key_signs_exact_manifest_and_tampering_fails(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key_dir, pin = root / 'private', root / 'public-key'
            release_sign.initialize(key_dir, pin)
            asset = root / 'LabDesk-1.4.0-alpha.4.msi'
            asset.write_bytes(b'installer fixture')
            output = root / 'signed'
            release_sign.sign_assets(key_dir, pin, output, [asset])
            manifest = (output / 'SHA256SUMS').read_bytes()
            signature = (output / 'SHA256SUMS.sig').read_bytes()
            public = Ed25519PublicKey.from_public_bytes(base64.b64decode(pin.read_text()))
            self.assertEqual(len(signature), 64)
            public.verify(signature, manifest)
            self.assertIn(asset.name.encode(), manifest)
            with self.assertRaises(InvalidSignature):
                public.verify(signature, manifest + b'\n')
            protected = (key_dir / 'release-key.dpapi').read_bytes()
            self.assertGreater(len(protected), 32)
            with self.assertRaises(OSError):
                release_sign.unprotect(b'invalid DPAPI ciphertext')

    def test_key_and_pin_cannot_be_silently_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key_dir, pin = root / 'private', root / 'public-key'
            release_sign.initialize(key_dir, pin)
            before = (key_dir / 'release-key.dpapi').read_bytes()
            with self.assertRaises(FileExistsError):
                release_sign.initialize(key_dir, pin)
            self.assertEqual(before, (key_dir / 'release-key.dpapi').read_bytes())
            pin.write_text(base64.b64encode(bytes(32)).decode())
            asset = root / 'installer.msi'
            asset.write_bytes(b'fixture')
            with self.assertRaises(ValueError):
                release_sign.sign_assets(key_dir, pin, root / 'signed', [asset])
            self.assertFalse((root / 'signed').exists())

    def test_ambiguous_asset_names_are_rejected_before_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            key_dir, pin = root / 'private', root / 'public-key'
            release_sign.initialize(key_dir, pin)
            first, second = root / 'one', root / 'two'
            first.mkdir(); second.mkdir()
            for folder in [first, second]:
                (folder / 'installer.msi').write_bytes(b'fixture')
            with self.assertRaises(ValueError):
                release_sign.sign_assets(key_dir, pin, root / 'signed',
                                         [first / 'installer.msi', second / 'installer.msi'])
            self.assertFalse((root / 'signed').exists())


if __name__ == '__main__':
    unittest.main()
