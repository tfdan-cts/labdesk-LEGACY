import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
import preprocess


class InstallerIdentityTests(unittest.TestCase):
    def test_component_identity_survives_new_build_location_and_contents(self):
        identities = []
        with tempfile.TemporaryDirectory() as directory:
            for build in ("first", "second"):
                root = Path(directory) / build
                (root / "netbird").mkdir(parents=True)
                (root / "netbird/netbird.exe").write_bytes(build.encode())
                (root / "netbird/wintun.dll").write_bytes(build.encode())
                lines = []
                self.assertTrue(preprocess.insert_components_between_tags(lines, -1, "LabDesk", root))
                document = ET.fromstring("<Components>" + "".join(lines) + "</Components>")
                identities.append({
                    Path(component.find("File").get("Source")).relative_to(root).as_posix(): component.get("Guid")
                    for component in document
                })
        self.assertEqual(identities[0], identities[1])


if __name__ == "__main__":
    unittest.main()
