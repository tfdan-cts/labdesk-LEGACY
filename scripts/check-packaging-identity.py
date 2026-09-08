#!/usr/bin/env python3
"""Check product names at the build/package boundary without building or installing."""
from pathlib import Path
import ast
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def check_source():
    failures = []
    expected = {
        "build.py": ["Package: labdesk", "DRM_PACKAGE_NAME = 'labdesk-unattended-wayland'", "tmpdeb/usr/share/labdesk", "liblabdesk.dll"],
        "res/labdesk.service": ["Description=LabDesk", "ExecStart=/usr/bin/labdesk --service"],
        "res/DEBIAN/postinst": ["/usr/bin/labdesk", "systemctl enable labdesk"],
        "res/DEBIAN/preinst": ["--legacy-package", "legacy_owned_package"],
        "res/labdesk-helper": ["--legacy-package", "dpkg-deb --control"],
        "install.sh": ["pattern=\"labdesk-", "dpkg-deb --control", "--legacy-package"],
        "flatpak/labdesk.json": ['"id": "net.lab_desk.LabDesk"', '"command": "labdesk"'],
        "res/polkit/net.lab-desk.LabDesk.policy": ["/usr/share/labdesk/labdesk-helper"],
    }
    for relative, needles in expected.items():
        path = ROOT / relative
        contents = path.read_text(encoding="utf-8") if path.is_file() else ""
        failures.extend(f"{relative}: missing {needle!r}" for needle in needles if needle not in contents)
    for relative in ("res/rpm.spec", "res/rpm-suse.spec", "res/rpm-flutter.spec", "res/rpm-flutter-suse.spec"):
        if not re.search(r"^Name:\s+labdesk$", (ROOT / relative).read_text(), re.M):
            failures.append(f"{relative}: wrong package name")
    service = ROOT / "res/labdesk.service"
    if service.is_file() and "pkill" in service.read_text():
        failures.append("service must stop its own cgroup, not match unrelated process command lines")
    for relative in ("build.py", "res/msi/preprocess.py"):
        ast.parse((ROOT / relative).read_text(encoding="utf-8"), filename=relative)
    flatpak = ROOT / "flatpak/labdesk.json"
    if flatpak.is_file():
        json.loads(flatpak.read_text())
    for path in (ROOT / "res/msi/Package").rglob("*.wxs"):
        ET.parse(path)
    if failures:
        raise AssertionError("\n".join(failures))
    print("Packaging identity source checks passed")


def check_payload(directory):
    root = Path(directory).resolve(strict=True)
    assert root.is_dir() and any(path.is_file() for path in root.rglob("*")), "payload must contain files"
    failures = [str(path.relative_to(root)) for path in root.rglob("*")
                if "rustdesk" in str(path.relative_to(root)).lower()]
    if failures:
        raise AssertionError("Legacy names in unpacked payload:\n" + "\n".join(failures))
    print(f"Packaging payload filenames passed: {root}")


def check_generated_metadata():
    source = (ROOT / "build.py").read_text()
    generate = next(node for node in ast.parse(source).body if isinstance(node, ast.FunctionDef) and node.name == "generate_control_file")
    with tempfile.TemporaryDirectory(prefix="labdesk-metadata-check-") as temporary:
        fixture = Path(temporary)
        (fixture / "res/DEBIAN").mkdir(parents=True)
        (fixture / "flutter").mkdir()
        environment = {"system2": lambda command: None, "get_deb_arch": lambda: "amd64", "get_deb_extra_depends": lambda: ""}
        exec(compile(ast.Module(body=[generate], type_ignores=[]), "build.py", "exec"), environment)
        previous = Path.cwd()
        try:
            os.chdir(fixture / "flutter")
            environment["generate_control_file"]("9.8.7")
        finally:
            os.chdir(previous)
        fields = dict(line.split(": ", 1) for line in (fixture / "res/DEBIAN/control").read_text().splitlines() if ": " in line)
        assert fields["Package"] == "labdesk" and fields["Version"] == "9.8.7" and fields["Architecture"] == "amd64", fields
        assert fields["Homepage"] == "https://lab-desk.net", fields
        assert "Conflicts" not in fields and "Replaces" not in fields, fields

        source = (ROOT / "res/msi/preprocess.py").read_text()
        generate = next(node for node in ast.parse(source).body if isinstance(node, ast.FunctionDef) and node.name == "replace_component_guids_in_wxs")
        (fixture / "Package").mkdir()
        component = fixture / "Package/Component.wxs"
        original = '<Component Id="App.exe" Guid="620F0F69-4C17-4320-A619-495E329712A4" />\n'
        component.write_text(original)
        args = type("Args", (), {"argv": [str(fixture / "preprocess.py")]})
        environment = {"Path": Path, "re": re, "uuid": uuid, "sys": args, "app_name": "LabDesk"}
        exec(compile(ast.Module(body=[generate], type_ignores=[]), "preprocess.py", "exec"), environment)
        environment["replace_component_guids_in_wxs"]()
        first = component.read_text()
        environment["replace_component_guids_in_wxs"]()
        assert component.read_text() == first and first != original
    print("Generated DEB metadata and repeatable MSI component identities passed")


def check_migration():
    bash = "C:/Program Files/Git/bin/bash.exe" if os.name == "nt" else shutil.which("bash")
    assert bash, "bash is required for migration checks"
    source = (ROOT / "res/DEBIAN/preinst").read_text()
    with tempfile.TemporaryDirectory(prefix="labdesk-package-check-") as temporary:
        fixture = Path(temporary)
        prefix = fixture.as_posix()
        files = {
            "usr/share/rustdesk/labdesk-helper": 'SITE="https://lab-desk.net"\n',
            "usr/share/rustdesk/files/systemd/rustdesk.service": "Description=LabDesk\n",
            "usr/share/applications/rustdesk.desktop": "Name=LabDesk\n",
        }
        for name, contents in files.items():
            path = fixture / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        # Only the fixture copy substitutes filesystem paths and external
        # package-manager commands. Production gets no test-root bypass.
        stub = '''dpkg-query() {
    if [ "$1" = -W ]; then
        [ "$3" != "${TEST_PACKAGE:-rustdesk}" ] || printf '%s' "${TEST_STATUS:-installed}"
    elif [ "$1" = -S ]; then
        printf '%s: %s' "${TEST_OWNER:-${TEST_PACKAGE:-rustdesk}}" "$2"
    else
        exit 92
    fi
}
stat() { printf '%s' "${TEST_UID:-0}"; }
systemctl() { echo unexpected-service-mutation >&2; exit 93; }
'''
        script = fixture / "preinst"
        script.write_text(stub + source.replace("/usr/share/", prefix + "/usr/share/"), newline="\n")
        cases = [
            ({}, "rustdesk\n"),
            ({"TEST_PACKAGE": "rustdesk-unattended-wayland"}, "rustdesk-unattended-wayland\n"),
            ({"TEST_STATUS": "not-installed"}, ""),
            ({"TEST_OWNER": "another-package"}, ""),
            ({"TEST_UID": "1000"}, ""),
        ]
        for settings, expected in cases:
            result = subprocess.run([bash, str(script), "--legacy-package"], env={**os.environ, **settings}, capture_output=True, text=True)
            assert result.returncode == 0 and result.stdout == expected and not result.stderr, (settings, result)
        unit = fixture / "usr/share/rustdesk/files/systemd/rustdesk.service"
        unit.write_text("Description=Independent upstream product\n")
        result = subprocess.run([bash, str(script), "--legacy-package"], capture_output=True, text=True)
        assert result.returncode == 0 and not result.stdout and not result.stderr, result
        unit.write_text("Description=LabDesk\n")
        result = subprocess.run([bash, str(script), "install"], capture_output=True, text=True)
        assert result.returncode == 1 and "verified migration" in result.stderr and "unexpected-service-mutation" not in result.stderr, result
        helper = fixture / "usr/share/rustdesk/labdesk-helper"
        helper.write_text('SITE="https://another-product.example"\n')
        result = subprocess.run([bash, str(script), "--legacy-package"], capture_output=True, text=True)
        assert result.returncode == 0 and not result.stdout and not result.stderr, result
        (fixture / "usr/share/rustdesk/labdesk-helper").unlink()
        result = subprocess.run([bash, str(script), "--legacy-package"], capture_output=True, text=True)
        assert result.returncode == 0 and not result.stdout and not result.stderr, result
    print("Nine migration fixtures passed; no installed software was touched")

    installer = (ROOT / "install.sh").read_text()
    for manager in ("rpm", "arch"):
        name = f"legacy_{manager}_package"
        start = installer.index(name + "() {")
        end = installer.index("\n}\n", start) + 3
        function = installer[start:end]
        if manager == "rpm":
            for spec in (ROOT / "res").glob("rpm*.spec"):
                assert function in spec.read_text().replace("%%{", "%{"), spec
            assert function in (ROOT / "res/labdesk-helper").read_text()
        else:
            assert function in (ROOT / "res/pacman_install").read_text()
        with tempfile.TemporaryDirectory(prefix="labdesk-manager-check-") as temporary:
            fixture = Path(temporary)
            unit = fixture / "usr/share/rustdesk/files/rustdesk.service"
            unit.parent.mkdir(parents=True)
            unit.write_text("Description=LabDesk\n")
            stub = '''rpm() {
    if [ "$1" = -qf ]; then printf '%s' "${TEST_OWNER:-rustdesk}";
    elif [ "$1" = -q ]; then printf '%s' "${TEST_SUMMARY:-LabDesk remote administration client}";
    else exit 92; fi
}
pacman() {
    if [ "$2" = --owns ]; then printf '%s' "${TEST_OWNER:-rustdesk}";
    elif [ "$2" = --info ]; then printf 'Description : %s\\n' "${TEST_SUMMARY:-LabDesk remote administration client}";
    else exit 92; fi
}
'''
            script = fixture / "check"
            script.write_text(stub + function.replace("/usr/share/", fixture.as_posix() + "/usr/share/") + name + "\n", newline="\n")
            for settings, expected in (({}, "rustdesk\n"), ({"TEST_OWNER": "another-product"}, ""), ({"TEST_SUMMARY": "Another product"}, "")):
                result = subprocess.run([bash, str(script)], env={**os.environ, **settings}, capture_output=True, text=True)
                assert result.returncode == 0 and result.stdout == expected and not result.stderr, (manager, settings, result)
            unit.write_text("Description=Independent upstream product\n")
            result = subprocess.run([bash, str(script)], capture_output=True, text=True)
            assert result.returncode == 0 and not result.stdout and not result.stderr, result
            if manager == "arch":
                unit.write_text("Description=LabDesk\n")
                hooks = (ROOT / "res/pacman_install").read_text()
                commands = '''cp() { echo copy; }
systemctl() { echo "service:$*"; }
update-desktop-database() { echo desktop; }
'''
                for hook in ("post_install", "post_upgrade"):
                    script.write_text(stub + commands + hooks.replace("/usr/share/", fixture.as_posix() + "/usr/share/") + hook + "\n", newline="\n")
                    result = subprocess.run([bash, str(script)], capture_output=True, text=True)
                    assert result.returncode == 1 and not result.stdout and "remains inactive" in result.stderr, (hook, result)
                    result = subprocess.run([bash, str(script)], env={**os.environ, "TEST_OWNER": "independent-product"}, capture_output=True, text=True)
                    assert result.returncode == 0 and "service:start labdesk" in result.stdout and not result.stderr, (hook, result)
    print("Eight RPM/Arch ownership fixtures passed; shared preflight copies match")
    print("Four Arch post-install/upgrade fixtures passed; unresolved migration never activates the new service")


# Tracked files that may keep the legacy product name: legal notices, history, and the
# migration code that recognises packages installed before the rename.
IDENTITY_ALLOWED_FILES = {
    "LICENCE", "CHANGELOG.md", "docs/THIRD-PARTY.md", "scripts/check-packaging-identity.py",
    "install.sh", "res/labdesk-helper", "res/DEBIAN/preinst", "res/pacman_install",
    ".github/workflows/third-party-window-injection.yml",
}
IDENTITY_ALLOWED_PREFIXES = ("docs/plans/", "res/vcpkg/", "res/rpm")
# Dependency provenance (pinned forks, upstream issue links) and the AGPL attribution line.
IDENTITY_ALLOWED_LINE = re.compile(
    r"github\.com/(rustdesk|rustdesk-org|fufesou)/|rustdesk\.com/docs/|doc\.rustdesk\.com|reddit\.com/r/rustdesk"
    r"|uses: rustdesk-org/|ubuntu18\.04-rustdesk|Based on RustDesk", re.I)


def check_source_identity():
    listed = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True, check=True).stdout.decode().split("\0")
    failures = []
    for relative in filter(None, listed):
        if "rustdesk" in relative.lower():
            failures.append(f"{relative}: legacy name in path")
        if relative in IDENTITY_ALLOWED_FILES or relative.startswith(IDENTITY_ALLOWED_PREFIXES) or relative.endswith(".lock"):
            continue
        path = ROOT / relative
        if not path.is_file():
            continue
        data = path.read_bytes()
        text = data.decode("utf-16") if data[:2] in (b"\xff\xfe", b"\xfe\xff") else data.decode("utf-8", errors="replace")
        for number, line in enumerate(text.splitlines(), 1):
            if "rustdesk" in line.lower() and not IDENTITY_ALLOWED_LINE.search(line):
                failures.append(f"{relative}:{number}: {line.strip()[:120]}")
    if failures:
        raise AssertionError("Legacy product identity in tracked sources:\n" + "\n".join(failures))
    print(f"Source identity passed: {len(listed) - 1} tracked files")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--payload":
        check_payload(sys.argv[2])
    elif len(sys.argv) == 2 and sys.argv[1] == "--source-identity":
        check_source_identity()
    elif len(sys.argv) == 1:
        check_source()
        check_generated_metadata()
        check_migration()
    else:
        sys.exit("usage: check-packaging-identity.py [--payload DIRECTORY | --source-identity]")
