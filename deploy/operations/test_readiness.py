import importlib.util
import json
import os
from pathlib import Path
import tempfile
import socket
import struct
import threading
import unittest
from unittest.mock import patch
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class ReadinessTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('readiness', Path(__file__).with_name('readiness.py'))
        self.readiness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.readiness)

    @unittest.skipIf(os.name == 'nt', 'Unix modes require Linux; Windows uses ACLs')
    def test_private_token_and_systemd_credential_permissions(self):
        with tempfile.TemporaryDirectory(prefix='labnet-token-test-') as root:
            path = Path(root) / 'token'
            path.write_text('fixture-only')
            path.chmod(0o600)
            self.assertEqual(self.readiness.read_token(path), 'fixture-only')
            with patch.dict(os.environ, {'CREDENTIALS_DIRECTORY': root}):
                path.chmod(0o440)
                self.assertEqual(self.readiness.read_token(path), 'fixture-only')
                linked_file = Path(root) / 'linked-token'
                linked_file.symlink_to(path)
                with self.assertRaises(ValueError):
                    self.readiness.read_token(linked_file)
                alias = Path(root) / 'directory-alias'
                alias.symlink_to(root, target_is_directory=True)
                with self.assertRaises(ValueError):
                    self.readiness.read_token(alias / 'token')
                sibling = Path(root) / 'credentials-sibling'
                sibling.mkdir()
                sibling_token = sibling / 'token'
                sibling_token.write_text('fixture-only')
                sibling_token.chmod(0o440)
                with self.assertRaises(ValueError):
                    self.readiness.read_token(sibling_token)
                for mode in (0o444, 0o640, 0o660):
                    path.chmod(mode)
                    with self.assertRaises(ValueError):
                        self.readiness.read_token(path)
            path.chmod(0o440)
            with patch.dict(os.environ, {'CREDENTIALS_DIRECTORY': str(Path(root) / 'elsewhere')}):
                with self.assertRaises(ValueError):
                    self.readiness.read_token(path)

    def test_real_loopback_http_failure_and_recovery(self):
        class Handler(BaseHTTPRequestHandler):
            status = 200
            body = b'{"ok":true}'

            def do_GET(self):
                self.send_response(self.status)
                self.end_headers()
                self.wfile.write(self.body)

            def log_message(self, *args):
                pass

        with HTTPServer(('127.0.0.1', 0), Handler) as server:
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                for status, body, passes in ((200, b'{"ok":true}', True),
                                             (503, b'failure-with-secret', False),
                                             (302, b'', False),
                                             (200, b'{"ok":false}', False),
                                             (200, b'not-json', False),
                                             (200, b'{"ok":true}', True)):
                    Handler.status, Handler.body = status, body
                    conn = self.readiness.http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=1)
                    if passes:
                        self.readiness.check_http(conn, '/health', 200, 'healthy')
                    else:
                        with self.assertRaises(ValueError) as raised:
                            self.readiness.check_http(conn, '/health', 200, 'healthy')
                        self.assertNotIn('secret', str(raised.exception))
            finally:
                server.shutdown()
                worker.join()

    def test_stun_protocol_checks_with_real_udp_socket(self):
        for wrong_transaction in (False, True):
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server:
                server.bind(('127.0.0.1', 0))
                server.settimeout(2)
                def answer():
                    request, sender = server.recvfrom(1024)
                    transaction = b'wrong-id-1234' if wrong_transaction else request[8:20]
                    attr = struct.pack('!HHBBHI', 0x0020, 8, 0, 1, 1234 ^ 0x2112, 0x7f000001 ^ 0x2112a442)
                    server.sendto(struct.pack('!HHI', 0x0101, len(attr), 0x2112a442) + transaction + attr, sender)
                worker = threading.Thread(target=answer, daemon=True)
                worker.start()
                try:
                    if wrong_transaction:
                        with self.assertRaises(ValueError):
                            self.readiness.check_stun('127.0.0.1', server.getsockname()[1], 1)
                    else:
                        self.readiness.check_stun('127.0.0.1', server.getsockname()[1], 1)
                finally:
                    worker.join()

    def test_cli_config_is_validated_before_network_or_secret_read(self):
        script = Path(__file__).with_name('readiness.py')
        config = json.loads(script.with_name('readiness.example.json').read_text())
        with tempfile.TemporaryDirectory(prefix='labnet-config-test-') as root:
            path = Path(root) / 'config.json'
            path.write_text(json.dumps(config))
            run = subprocess.run([sys.executable, str(script), '--config', str(path), '--check-config'], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertTrue(json.loads(run.stdout)['config_valid'])
            for key, value in [('broker_host', 'user:secret@example.com'), ('timeout_seconds', 0),
                               ('tls_min_days', -1), ('mode', 'anything'), ('unexpected', True)]:
                broken = dict(config, **{key: value})
                path.write_text(json.dumps(broken))
                run = subprocess.run([sys.executable, str(script), '--config', str(path), '--check-config'], capture_output=True, text=True)
                self.assertEqual(run.returncode, 2, run.stdout + run.stderr)
                self.assertNotIn('secret', run.stdout + run.stderr)

    def test_backup_missing_stale_or_failed_cannot_pass(self):
        spec = importlib.util.spec_from_file_location('readiness', Path(__file__).with_name('readiness.py'))
        readiness = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(readiness)
        with tempfile.TemporaryDirectory(prefix='labnet-readiness-test-') as root:
            path = Path(root) / 'backup.json'
            with self.assertRaises((OSError, ValueError)):
                readiness.check_backup(path, 'volume-fixture', 100, 10, now=1000)
            evidence = {'observed_at': 1000, 'boot_volume_id': 'volume-fixture', 'backups': [
                {'id': 'backup-fixture', 'state': 'AVAILABLE', 'created_at': 950, 'expires_at': None}]}
            path.write_text(json.dumps(evidence))
            readiness.check_backup(path, 'volume-fixture', 100, 10, now=1000)
            for change in ('stale', 'wrong-volume', 'failed', 'too-old', 'expired', 'future', 'invalid-id'):
                altered = json.loads(json.dumps(evidence))
                if change == 'stale':
                    altered['observed_at'] = 980
                elif change == 'wrong-volume':
                    altered['boot_volume_id'] = 'unrelated-volume'
                elif change == 'failed':
                    altered['backups'].append({'id': 'failure', 'state': 'FAULTY', 'created_at': 999, 'expires_at': None})
                elif change == 'too-old':
                    altered['backups'][0]['created_at'] = 800
                elif change == 'expired':
                    altered['backups'][0]['expires_at'] = 999
                elif change == 'future':
                    altered['observed_at'] = 2000
                else:
                    altered['backups'][0]['id'] = True
                path.write_text(json.dumps(altered))
                with self.subTest(change=change), self.assertRaises(ValueError):
                    readiness.check_backup(path, 'volume-fixture', 100, 10, now=1000)


if __name__ == '__main__':
    unittest.main()
