#!/usr/bin/env python3
"""Run real Windows handoff/archive modules in a harmless, isolated Rust harness.

Requires Windows, Python brotli, and the Rust dependencies from Cargo.lock.
Does not elevate, install, or write to Windows/Program Files. Set CARGO_TARGET_DIR
to reuse an existing cache. Actual UAC and administrator ACL acceptance is separate.
"""
import importlib.util
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def main():
    if os.name != "nt":
        raise SystemExit("This verification requires Windows.")
    root = Path(__file__).resolve().parents[1]
    cargo = shutil.which("cargo") or str(Path.home() / ".cargo/bin/cargo.exe")
    spec = importlib.util.spec_from_file_location("portable_generator", root / "libs/portable/generate.py")
    generator = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(generator)
    with tempfile.TemporaryDirectory(prefix="labdesk-secure-update-") as temporary:
        work = Path(temporary)
        inputs = work / "payload"
        (inputs / "data").mkdir(parents=True)
        (inputs / "labdesk.exe").write_bytes(b"harmless executable fixture\r\n")
        (inputs / "data/liblabdesk.dll").write_bytes(b"harmless DLL fixture\0")
        previous_directory = Path.cwd()
        try:
            table = generator.generate_md5_table(str(inputs), 1)
        finally:
            os.chdir(previous_directory)
        generator.write_package_metadata(table, str(work), ".\\labdesk.exe")

        manifest = '''[package]
name = "labdesk-windows-update-trust-tests"
version = "0.0.0"
edition = "2021"
[dependencies]
anyhow = "=1.0.98"
base64 = "=0.22.1"
sha2 = "=0.10.8"
log = "=0.4.22"
uuid = { version = "=1.16.0", features = ["v4"] }
brotli = "=3.5.0"
md5 = "=0.7.0"
winapi = { version = "=0.3.9", features = ["winbase", "winuser"] }
windows = { version = "=0.61.1", features = ["Win32_Foundation", "Win32_System_Com", "Win32_System_SystemInformation", "Win32_System_Threading", "Win32_UI_Shell", "Win32_UI_WindowsAndMessaging", "Win32_Storage_FileSystem", "Win32_System_Memory", "Win32_System_Variant", "Win32_System_Ole", "Win32_System_Com_StructuredStorage", "Win32_System_Registry", "Win32_Security"] }
[workspace]
'''
        (work / "Cargo.toml").write_text(manifest, encoding="utf-8")
        (work / "src").mkdir()
        windows_source = (root / "src/platform/windows.rs").read_text(encoding="utf-8")
        validator = re.search(r"fn validate_install_app_name\(.*?\n}\n", windows_source, re.S)
        if validator is None:
            raise RuntimeError("Cannot locate the actual installer name validator")
        paths = {name: (root / path).as_posix() for name, path in {
            "shell": "src/platform/windows/installer_shell.rs",
            "handoff": "src/platform/windows/installer_handoff.rs",
            "update": "src/platform/windows/secure_update.rs",
            "reader": "libs/portable/src/bin_reader.rs",
            "protected": "libs/portable/src/protected_update.rs",
        }.items()}
        source = '''#![allow(dead_code)]
extern crate self as hbb_common;
pub use anyhow::{self, bail};
pub use base64;
pub use log;
pub use sha2;
pub type ResultType<T> = anyhow::Result<T>;
pub fn get_app_name() -> String { "LabDesk".to_owned() }
mod windows_staging {
    use super::ResultType;
    use hbb_common::bail;
    fn is_elevated(_: Option<u32>) -> ResultType<bool> { bail!("UAC is forbidden in this fixture harness") }
    fn wide_string(value: &str) -> Vec<u16> { value.encode_utf16().chain(Some(0)).collect() }
'''
        source += validator.group(0)
        for module, key in [("installer_shell", "shell"), ("installer_handoff", "handoff"), ("secure_update", "update")]:
            source += f'#[path = "{paths[key]}"] mod {module};\n'
        source += "}\n"
        source += f'#[path = "{paths["reader"]}"] mod bin_reader;\n'
        source += f'#[path = "{paths["protected"]}"] mod protected_update;\n'
        portable_source = (root / "libs/portable/src/main.rs").read_text(encoding="utf-8")
        execute = re.search(r"fn execute\(.*?\n}\n", portable_source, re.S)
        if execute is None:
            raise RuntimeError("Cannot locate the actual portable execute function")
        source += '''mod portable_execution {
use std::{path::{Path, PathBuf}, process::{Command, Stdio}};
const APPNAME_RUNTIME_ENV_KEY: &str = "LABDESK_APPNAME";
const SET_FOREGROUND_WINDOW_ENV_KEY: &str = "SET_FOREGROUND_WINDOW";
// Only platform/UI scaffolding: actual execute/spawn/wait/error code is included below.
fn use_null_stdio() -> bool { true }
'''
        source += execute.group(0)
        source += '''#[cfg(test)] mod tests {
use super::*;
#[test]
fn portable_wrapper_waits_for_native_child_and_preserves_its_code() {
    let directory = std::env::temp_dir().join(format!("labdesk-wrapper-wait-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir(&directory).unwrap();
    let executable = directory.join("native.exe");
    let temporary = directory.with_extension("temp");
    std::fs::create_dir(&temporary).unwrap();
    std::fs::copy(std::env::current_exe().unwrap(), &executable).unwrap();
    std::env::set_var("LABDESK_PORTABLE_EXEC_TEST_DIR", &directory);
    for expected in [0, 7, 3010] {
        std::env::set_var("LABDESK_PORTABLE_EXEC_TEST_CODE", expected.to_string());
        let code = execute(executable.clone(), vec!["--exact".into(),
            "portable_execution::tests::native_execution_child".into(), "--nocapture".into()], false, Some(&temporary)).unwrap();
        assert_eq!(code, expected);
        assert_eq!(std::fs::read_to_string(directory.join("completed")).unwrap(), expected.to_string());
        assert!(temporary.join("transient-handoff.bat").exists());
        assert!(!directory.join("transient-handoff.bat").exists());
    }
    std::env::remove_var("LABDESK_PORTABLE_EXEC_TEST_DIR");
    std::env::remove_var("LABDESK_PORTABLE_EXEC_TEST_CODE");
    std::fs::remove_dir_all(directory).unwrap();
    std::fs::remove_dir_all(temporary).unwrap();
}
#[test]
fn native_execution_child() {
    if let Some(directory) = std::env::var_os("LABDESK_PORTABLE_EXEC_TEST_DIR") {
        let directory = PathBuf::from(directory);
        assert_eq!(std::env::current_dir().unwrap(), directory);
        assert_eq!(std::env::temp_dir(), directory.with_extension("temp"));
        assert_eq!(PathBuf::from(std::env::var_os("TEMP").unwrap()), directory.with_extension("temp"));
        assert_eq!(PathBuf::from(std::env::var_os("TMP").unwrap()), directory.with_extension("temp"));
        std::fs::write(std::env::temp_dir().join("transient-handoff.bat"), b"harmless handoff fixture").unwrap();
        std::thread::sleep(std::time::Duration::from_millis(50));
        let code = std::env::var("LABDESK_PORTABLE_EXEC_TEST_CODE").unwrap();
        std::fs::write(directory.join("completed"), &code).unwrap();
        std::process::exit(code.parse().unwrap());
    }
}
}}
'''
        (work / "src/lib.rs").write_text(source, encoding="utf-8")
        environment = dict(os.environ, LABDESK_PORTABLE_FIXTURE=str(work))
        environment.setdefault("CARGO_TARGET_DIR", str(root / "target/windows-update-trust-tests"))
        subprocess.run([cargo, "test", "--lib", "--offline", "--manifest-path", str(work / "Cargo.toml"),
                        "-j", "1", "--", "--include-ignored", "--test-threads=1"], env=environment, check=True)


if __name__ == "__main__":
    main()
