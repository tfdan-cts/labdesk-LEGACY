"""Offline recovery contract tests; every writable path belongs to a temporary directory."""

import hashlib
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

import restore_rehearsal as recovery


class RecoveryTests(unittest.TestCase):
    def resign(self, source):
        """Model intact backup bytes that nevertheless contain inconsistent state."""
        path = source / "manifest.json"
        manifest = json.loads(path.read_text(encoding="utf-8"))
        manifest["sha256"] = {
            name: hashlib.sha256((source / name).read_bytes()).hexdigest()
            for name in recovery.FILES
        }
        path.write_text(json.dumps(manifest), encoding="utf-8")

    def test_fixture_restores_bytes_and_identity_without_claiming_cloud_recovery(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            before = {p.name: p.read_bytes() for p in source.iterdir()}
            result = recovery.rehearse(source)
            self.assertEqual(result["status"], "fixture_pass")
            self.assertEqual(result["checks"]["sqlite_integrity"], "pass")
            self.assertEqual(result["checks"]["identity_consistency"], "pass")
            self.assertEqual(result["restored_files"], 6)
            self.assertEqual(result["device_count"], 2)
            self.assertFalse(result["production_restore_proven"])
            self.assertFalse(result["service_start_proven"])
            self.assertIsNone(result["rpo_seconds"])
            self.assertIsNone(result["rto_seconds"])
            self.assertEqual(before, {p.name: p.read_bytes() for p in source.iterdir()})

    def test_refuses_unexpected_files_and_linked_input(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            (source / "untracked-key").write_bytes(b"fixture-only")
            with self.assertRaisesRegex(recovery.RecoveryError, "unexpected_bundle_files"):
                recovery.rehearse(source)
            (source / "untracked-key").unlink()
            certificate = source / "certificate.pem"
            original = Path(temporary) / "outside-certificate"
            certificate.rename(original)
            os.link(original, certificate)
            with self.assertRaisesRegex(recovery.RecoveryError, "unsafe_bundle_file"):
                recovery.rehearse(source)

    def test_same_group_for_both_devices_fails_even_when_stores_agree(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            with closing(sqlite3.connect(source / "broker.sqlite")) as db, db:
                db.execute("UPDATE overlay_device SET group_id = 'group-1'")
            path = source / "netbird.json"
            inventory = json.loads(path.read_text(encoding="utf-8"))
            inventory["peers"][1]["group_id"] = "group-1"
            path.write_text(json.dumps(inventory), encoding="utf-8")
            self.resign(source)
            with self.assertRaisesRegex(recovery.RecoveryError, "duplicate_device_identity"):
                recovery.rehearse(source)

    def test_checksum_damage_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            (source / "certificate.pem").write_bytes(b"damaged fixture")
            with self.assertRaisesRegex(recovery.RecoveryError, "checksum_mismatch"):
                recovery.rehearse(source)

    def test_sqlite_corruption_is_rejected_even_when_checksum_matches(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            (source / "broker.sqlite").write_bytes(b"not a SQLite database")
            self.resign(source)
            with self.assertRaises(sqlite3.DatabaseError):
                recovery.rehearse(source)

    def test_mismatched_identity_is_rejected_even_when_checksum_matches(self):
        for column, value in (("public_key", "wrong-public-key"), ("device_uuid", "wrong-uuid"),
                              ("org_id", "wrong-org"), ("peer_id", "wrong-peer"),
                              ("overlay_ip", "100.80.0.90"), ("group_id", "wrong-group")):
            with self.subTest(column=column), tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
                source = Path(temporary) / "backup"
                recovery.create_fixture(source)
                with closing(sqlite3.connect(source / "broker.sqlite")) as db, db:
                    # Column comes only from the fixed test cases, never external input.
                    db.execute(f"UPDATE overlay_device SET {column} = ? WHERE device_id = 'device-1'", (value,))
                self.resign(source)
                with self.assertRaises(recovery.RecoveryError):
                    recovery.rehearse(source)

    def test_orphan_machine_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            with closing(sqlite3.connect(source / "broker.sqlite")) as db, db:
                db.execute("UPDATE overlay_device SET machine_id = 'absent-machine'")
            self.resign(source)
            with self.assertRaisesRegex(recovery.RecoveryError, "sqlite_foreign_key_failed"):
                recovery.rehearse(source)

    def test_restored_open_session_must_be_reconciled(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            with closing(sqlite3.connect(source / "broker.sqlite")) as db, db:
                db.execute("INSERT INTO overlay_session VALUES ('session-1', 'device-1', 'device-2', 'policy-1', NULL)")
            self.resign(source)
            with self.assertRaisesRegex(recovery.RecoveryError, "sessions_require_reconciliation"):
                recovery.rehearse(source)

    def test_unowned_policy_and_mixed_checkpoint_are_rejected(self):
        for field, value, reason in (("policies", [{"id": "orphan-policy"}], "policies_require_reconciliation"),
                                     ("checkpoint", "different-checkpoint", "checkpoint_mismatch")):
            with self.subTest(field=field), tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
                source = Path(temporary) / "backup"
                recovery.create_fixture(source)
                path = source / "netbird.json"
                inventory = json.loads(path.read_text(encoding="utf-8"))
                inventory[field] = value
                path.write_text(json.dumps(inventory), encoding="utf-8")
                self.resign(source)
                with self.assertRaisesRegex(recovery.RecoveryError, reason):
                    recovery.rehearse(source)

    def test_manifest_cannot_supply_extraction_paths(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            path = source / "manifest.json"
            manifest = json.loads(path.read_text(encoding="utf-8"))
            manifest["sha256"]["../outside"] = "0" * 64
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with self.assertRaisesRegex(recovery.RecoveryError, "fixture_manifest_invalid"):
                recovery.rehearse(source)

    def test_symlinked_file_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-test-") as temporary:
            source = Path(temporary) / "backup"
            recovery.create_fixture(source)
            path = source / "certificate.pem"
            original = Path(temporary) / "outside-certificate"
            path.rename(original)
            try:
                path.symlink_to(original)
            except OSError:
                self.skipTest("Host does not permit creating symlinks; hardlink rejection still exercised")
            with self.assertRaisesRegex(recovery.RecoveryError, "unsafe_bundle_file"):
                recovery.rehearse(source)


if __name__ == "__main__":
    unittest.main()
