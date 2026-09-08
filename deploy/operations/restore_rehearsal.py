"""Exercise an offline fixture restore. This never invokes OCI, D1, or a service.

The reduced SQLite/JSON fixture is a recovery contract, not the NetBird store
schema or a D1 backup. All CLI writes stay inside a unique TemporaryDirectory.
"""

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
import stat
import tempfile
import time


FORMAT = "labdesk-recovery-fixture-v1"
FILES = (
    "broker.sqlite", "netbird.json", "config.json", "certificate.pem",
    "GeoLite2-City_fixture.mmdb", "geonames_fixture.db",
)


class RecoveryError(ValueError):
    """A fixed diagnostic code; never include restored identities or secrets."""


def digest(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def read_regular(path, maximum=16 * 1024 * 1024):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
            or not 0 < info.st_size <= maximum):
        raise RecoveryError("unsafe_bundle_file")
    with path.open("rb") as stream:
        content = stream.read(maximum + 1)
    if len(content) > maximum:
        raise RecoveryError("unsafe_bundle_file")
    return content


def create_fixture(destination):
    """Create only synthetic state in a new directory, refusing existing paths."""
    destination.mkdir(exist_ok=False)
    checkpoint = "fixture-coordinated-checkpoint"
    certificate = b"FIXTURE ONLY: not a certificate or private key\n"
    (destination / "certificate.pem").write_bytes(certificate)
    (destination / "GeoLite2-City_fixture.mmdb").write_bytes(b"FIXTURE ONLY: not a MaxMind database\n")
    write_json(destination / "config.json", {
        "fixture": True, "management_url": "https://nb.fixture.invalid",
        "disableGeoliteUpdate": True, "certificate_sha256": digest(certificate),
    })
    write_json(destination / "netbird.json", {
        "fixture": True, "checkpoint": checkpoint,
        "peers": [
            {"id": f"peer-{n}", "public_key": f"fixture-public-key-{n}",
             "group_id": f"group-{n}", "overlay_ip": f"100.80.0.{n}"}
            for n in (1, 2)
        ],
        "policies": [],
    })
    with closing(sqlite3.connect(destination / "broker.sqlite")) as db, db:
        db.executescript("""
            CREATE TABLE recovery_meta (checkpoint TEXT NOT NULL);
            CREATE TABLE machine (
                id TEXT PRIMARY KEY, org_id TEXT NOT NULL,
                device_id TEXT NOT NULL, device_uuid TEXT NOT NULL);
            CREATE TABLE overlay_device (
                device_id TEXT PRIMARY KEY, device_uuid TEXT NOT NULL,
                org_id TEXT NOT NULL, machine_id TEXT NOT NULL REFERENCES machine(id),
                group_id TEXT NOT NULL, overlay_ip TEXT NOT NULL,
                public_key TEXT NOT NULL, peer_id TEXT NOT NULL, revoked_at INTEGER);
            CREATE TABLE overlay_session (
                id TEXT PRIMARY KEY, controller_device_id TEXT NOT NULL,
                target_device_id TEXT NOT NULL, policy_id TEXT NOT NULL, ended_at INTEGER);
        """)
        db.execute("INSERT INTO recovery_meta VALUES (?)", (checkpoint,))
        for n in (1, 2):
            db.execute("INSERT INTO machine VALUES (?, ?, ?, ?)",
                       (f"machine-{n}", "org-fixture", f"device-{n}", f"uuid-{n}"))
            db.execute("INSERT INTO overlay_device VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)",
                       (f"device-{n}", f"uuid-{n}", "org-fixture", f"machine-{n}",
                        f"group-{n}", f"100.80.0.{n}", f"fixture-public-key-{n}", f"peer-{n}"))
    with closing(sqlite3.connect(destination / "geonames_fixture.db")) as db, db:
        db.execute("CREATE TABLE fixture_geonames (name TEXT NOT NULL)")
        db.execute("INSERT INTO fixture_geonames VALUES ('fixture-city')")
    write_json(destination / "manifest.json", {
        "format": FORMAT, "checkpoint": checkpoint,
        "sha256": {name: digest((destination / name).read_bytes()) for name in FILES},
    })


def validate_restored(restored, checkpoint):
    """Read the restored files and fail closed on identity or policy divergence."""
    config = json.loads((restored / "config.json").read_text(encoding="utf-8"))
    inventory = json.loads((restored / "netbird.json").read_text(encoding="utf-8"))
    if (config.get("fixture") is not True or inventory.get("fixture") is not True
            or config.get("management_url") != "https://nb.fixture.invalid"
            or config.get("disableGeoliteUpdate") is not True
            or config.get("certificate_sha256") != digest((restored / "certificate.pem").read_bytes())
            or not (restored / "GeoLite2-City_fixture.mmdb").read_bytes()):
        raise RecoveryError("fixture_configuration_invalid")
    if inventory.get("checkpoint") != checkpoint:
        raise RecoveryError("checkpoint_mismatch")
    peers = inventory.get("peers", [])
    peer_by_id = {peer["id"]: peer for peer in peers}
    if len(peer_by_id) != len(peers):
        raise RecoveryError("duplicate_peer_identity")
    if inventory.get("policies") != []:
        raise RecoveryError("policies_require_reconciliation")
    for name in ("broker.sqlite", "geonames_fixture.db"):
        with closing(sqlite3.connect((restored / name).as_uri() + "?mode=ro", uri=True)) as db:
            if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise RecoveryError("sqlite_integrity_failed")
            if db.execute("PRAGMA foreign_key_check").fetchall():
                raise RecoveryError("sqlite_foreign_key_failed")
    with closing(sqlite3.connect((restored / "broker.sqlite").as_uri() + "?mode=ro", uri=True)) as db:
        if db.execute("SELECT checkpoint FROM recovery_meta").fetchall() != [(checkpoint,)]:
            raise RecoveryError("checkpoint_mismatch")
        if db.execute("SELECT COUNT(*) FROM overlay_session WHERE ended_at IS NULL").fetchone()[0]:
            raise RecoveryError("sessions_require_reconciliation")
        devices = db.execute("""
            SELECT d.peer_id, d.public_key, d.group_id, d.overlay_ip,
                   d.org_id, m.org_id, d.device_id, m.device_id,
                   d.device_uuid, m.device_uuid
            FROM overlay_device d LEFT JOIN machine m ON m.id = d.machine_id
            WHERE d.revoked_at IS NULL
        """).fetchall()
        if len({row[0] for row in devices}) != len(devices) or set(peer_by_id) != {row[0] for row in devices}:
            raise RecoveryError("peer_inventory_mismatch")
        if any(len({row[column] for row in devices}) != len(devices) for column in (1, 2, 3, 8)):
            raise RecoveryError("duplicate_device_identity")
        for peer_id, key, group, ip, org, machine_org, device_id, machine_device, uuid, machine_uuid in devices:
            peer = peer_by_id[peer_id]
            if (org != machine_org or device_id != machine_device or uuid != machine_uuid
                    or (key, group, ip) != (peer["public_key"], peer["group_id"], peer["overlay_ip"])):
                raise RecoveryError("device_identity_mismatch")
        # A non-empty fixture forces the read path to exercise actual restored rows.
        if len(devices) != 2:
            raise RecoveryError("fixture_devices_missing")
    with closing(sqlite3.connect((restored / "geonames_fixture.db").as_uri() + "?mode=ro", uri=True)) as db:
        if db.execute("SELECT name FROM fixture_geonames").fetchall() != [("fixture-city",)]:
            raise RecoveryError("fixture_geonames_query_failed")
    return len(devices)


def rehearse(source):
    """Restore a fixture into a unique temp directory. Never modify its source."""
    started = time.monotonic()
    directory = source.lstat()
    if (not stat.S_ISDIR(directory.st_mode)
            or getattr(directory, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
        raise RecoveryError("unsafe_bundle_directory")
    if {path.name for path in source.iterdir()} != set(FILES) | {"manifest.json"}:
        raise RecoveryError("unexpected_bundle_files")
    manifest = json.loads(read_regular(source / "manifest.json", 64 * 1024))
    if manifest.get("format") != FORMAT or set(manifest.get("sha256", {})) != set(FILES):
        raise RecoveryError("fixture_manifest_invalid")
    with tempfile.TemporaryDirectory(prefix="labdesk-recovery-restored-") as temporary:
        restored = Path(temporary)
        for name in FILES:
            content = read_regular(source / name)
            if digest(content) != manifest["sha256"][name]:
                raise RecoveryError("checksum_mismatch")
            (restored / name).write_bytes(content)
            if digest((restored / name).read_bytes()) != manifest["sha256"][name]:
                raise RecoveryError("restored_checksum_mismatch")
        devices = validate_restored(restored, manifest["checkpoint"])
    return {
        "status": "fixture_pass", "scope": FORMAT,
        "checks": {"checksums": "pass", "sqlite_integrity": "pass",
                   "identity_consistency": "pass", "fixture_queries": "pass"},
        "restored_files": len(FILES), "device_count": devices,
        "fixture_elapsed_seconds": round(time.monotonic() - started, 4),
        "production_restore_proven": False, "service_start_proven": False,
        "rpo_seconds": None, "rto_seconds": None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True, action="store_true",
                        help="exercise synthetic state only; no external input or destination")
    parser.parse_args()
    try:
        with tempfile.TemporaryDirectory(prefix="labdesk-recovery-fixture-") as temporary:
            source = Path(temporary) / "backup"
            create_fixture(source)
            result = rehearse(source)
    except (RecoveryError, OSError, sqlite3.Error, ValueError, KeyError, TypeError):
        print(json.dumps({"status": "fixture_fail", "production_restore_proven": False}))
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
