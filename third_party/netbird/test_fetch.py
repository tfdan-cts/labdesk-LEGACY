import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fetch import fetch


class PinnedArchiveTests(unittest.TestCase):
    def test_private_archive_cache_still_requires_exact_manifest_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            name = 'netbird_fixture_windows_amd64.tar.gz'
            content = b'patched archive fixture'
            (Path(directory) / name).write_bytes(content)
            entries = {name: (hashlib.sha256(content).hexdigest(), 'local:' + name)}
            with patch.dict(os.environ, {'LABDESK_NETBIRD_ARCHIVE_DIR': directory}):
                self.assertEqual(fetch(name, entries), content)
                (Path(directory) / name).write_bytes(b'tampered')
                with self.assertRaises(SystemExit):
                    fetch(name, entries)

    def test_missing_private_archive_does_not_fall_back_to_an_upstream_binary(self):
        with tempfile.TemporaryDirectory() as directory:
            name = 'netbird_fixture_windows_amd64.tar.gz'
            with patch.dict(os.environ, {'LABDESK_NETBIRD_ARCHIVE_DIR': directory}):
                with self.assertRaises(SystemExit):
                    fetch(name, {name: ('0' * 64, 'local:' + name)})


if __name__ == '__main__':
    unittest.main()
