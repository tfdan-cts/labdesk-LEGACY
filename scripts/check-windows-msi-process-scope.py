"""Exercise the real MSI shutdown action against two disposable executable copies."""
import ctypes
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

package = Path(sys.argv[1]).resolve(strict=True)
msi = ctypes.WinDLL("msi")
msi.MsiOpenPackageW.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_uint)]
msi.MsiSetPropertyW.argtypes = [ctypes.c_uint, ctypes.c_wchar_p, ctypes.c_wchar_p]
msi.MsiDoActionW.argtypes = [ctypes.c_uint, ctypes.c_wchar_p]
name = "LabDeskScopeProbe.exe"
with tempfile.TemporaryDirectory(prefix="labdesk-msi-scope-") as temporary:
    folders = [Path(temporary) / "installed", Path(temporary) / "portable"]
    children = []
    try:
        for folder in folders:
            folder.mkdir()
            shutil.copy2(Path("C:/Windows/System32/ping.exe"), folder / name)
            children.append(subprocess.Popen(
                [str(folder / name), "-t", "127.0.0.1"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            ))
        assert all(child.poll() is None for child in children)
        handle = ctypes.c_uint()
        result = msi.MsiOpenPackageW(str(package), ctypes.byref(handle))
        assert result == 0, result
        try:
            assert msi.MsiSetPropertyW(handle.value, "TerminateProcesses", name) == 0
            assert msi.MsiSetPropertyW(handle.value, "INSTALLFOLDER_INNER", str(folders[0]) + "\\") == 0
            result = msi.MsiDoActionW(handle.value, "TerminateProcesses")
            assert result == 0, result
        finally:
            msi.MsiCloseHandle(handle.value)
        time.sleep(0.3)
        receipt = {
            "actionExit": result,
            "installedStopped": children[0].poll() is not None,
            "portablePreserved": children[1].poll() is None,
        }
        print(json.dumps(receipt))
        assert receipt["installedStopped"] and receipt["portablePreserved"]
    finally:
        for child in children:
            if child.poll() is None:
                child.terminate()
            child.wait(timeout=5)
