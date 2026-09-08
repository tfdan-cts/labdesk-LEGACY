//! Bind an authenticated release digest into the protected installer handoff.
use super::{
    installer_handoff::run_cmds_exit_code,
    installer_shell::{get_system_executable, path_for_cmd_environment},
    ResultType,
};
use hbb_common::bail;
use std::path::Path;

const COPY_FAILED: u32 = 0x5253_0010;
const HASH_FAILED: u32 = 0x5253_0011;
const HASH_MISMATCH: u32 = 0x5253_0012;
const WORKING_DIRECTORY_FAILED: u32 = 0x5253_0013;

pub(super) fn run(file: &str, digest: &str, quiet: bool) -> ResultType<u32> {
    let extension = Path::new(file).extension().and_then(|value| value.to_str());
    let commands = match extension {
        Some("exe") => verified_exe_commands(file, digest, "--update")?,
        Some("msi") => {
            let stage = stage_commands(file, digest, "msi")?;
            let msiexec = get_system_executable("msiexec.exe")?;
            let msiexec = path_for_cmd_environment(&msiexec)?;
            let quiet = if quiet { " /qn LAUNCH_TRAY_APP=N" } else { "" };
            format!("{stage}\r\n\"{msiexec}\" /i \"%LABDESK_OUTPUT_DIR%\\payload.msi\"{quiet} REBOOT=ReallySuppress /norestart\r\nexit /b %errorlevel%")
        }
        _ => bail!("Unsupported update file format: {file}"),
    };
    let result = run_cmds_exit_code(commands, false)?;
    match result {
        COPY_FAILED => bail!("Failed to copy the update into the protected installation directory"),
        HASH_FAILED => bail!("Failed to hash the protected update copy"),
        HASH_MISMATCH => {
            bail!("The protected update does not match the authenticated release digest")
        }
        WORKING_DIRECTORY_FAILED => bail!("Failed to enter the protected update directory"),
        _ => Ok(result),
    }
}

fn verified_exe_commands(file: &str, digest: &str, arguments: &str) -> ResultType<String> {
    let stage = stage_commands(file, digest, "exe")?;
    // START /WAIT also waits for GUI subsystem launchers. The signed portable
    // launcher must in turn wait for its protected native child before exiting.
    Ok(format!("{stage}\r\nstart \"\" /wait \"%LABDESK_OUTPUT_DIR%\\payload.exe\" {arguments}\r\nexit /b %errorlevel%"))
}

fn stage_commands(file: &str, digest: &str, extension: &str) -> ResultType<String> {
    if digest.len() != 64 || !digest.bytes().all(|value| value.is_ascii_hexdigit()) {
        bail!("The authenticated release digest is not a SHA-256 hex digest");
    }
    let path = Path::new(file);
    if !path.is_absolute() {
        bail!("The update payload path must be absolute");
    }
    let source = path_for_cmd_environment(path)?;
    let certutil = get_system_executable("certutil.exe")?;
    let certutil = path_for_cmd_environment(&certutil)?;
    let findstr = get_system_executable("findstr.exe")?;
    let findstr = path_for_cmd_environment(&findstr)?;
    let pattern = digest
        .as_bytes()
        .chunks_exact(2)
        .map(|pair| std::str::from_utf8(pair).unwrap())
        .collect::<Vec<_>>()
        .join(" *");
    // The existing elevated receiver verifies this entire script against the
    // hash bound into the UAC invocation. That authenticates the expected digest;
    // the receiver then hashes and consumes its own protected payload copy.
    Ok(format!(
        "copy /B /Y \"{source}\" \"%LABDESK_OUTPUT_DIR%\\payload.{extension}\" > nul || exit /b {COPY_FAILED}\r\n\
         \"{certutil}\" -hashfile \"%LABDESK_OUTPUT_DIR%\\payload.{extension}\" SHA256 > \"%LABDESK_OUTPUT_DIR%\\payload.sha256\" || exit /b {HASH_FAILED}\r\n\
         \"{findstr}\" /R /I /X /C:\"{pattern}\" \"%LABDESK_OUTPUT_DIR%\\payload.sha256\" > nul || exit /b {HASH_MISMATCH}\r\n\
         cd /D \"%LABDESK_OUTPUT_DIR%\" || exit /b {WORKING_DIRECTORY_FAILED}\r\n\
         set \"TEMP=%LABDESK_OUTPUT_DIR%\"\r\nset \"TMP=%LABDESK_OUTPUT_DIR%\""
    ))
}

pub(super) fn copy_update_commands(
    source: &Path,
    destination: &Path,
    rename: &str,
    restore_service: &str,
) -> ResultType<String> {
    let source = path_for_cmd_environment(source)?;
    let destination = path_for_cmd_environment(destination)?;
    // Do not use XCOPY /C for updates: a partial copy must stop installation.
    // Capture its code before the recovery command overwrites ERRORLEVEL.
    Ok(format!(
        "XCOPY \"{source}\" \"{destination}\" /Y /E /H /I /K /R /Z\r\n\
        if errorlevel 1 goto labdesk_update_copy_failed\r\n\
        {rename}\r\nif errorlevel 1 goto labdesk_update_copy_failed\r\n\
        goto labdesk_update_copy_complete\r\n\
        :labdesk_update_copy_failed\r\nset \"LABDESK_COPY_EXIT=%errorlevel%\"\r\n\
        {restore_service}\r\nexit /b %LABDESK_COPY_EXIT%\r\n\
        :labdesk_update_copy_complete"
    ))
}

pub(super) fn required_update_commands(commands: &str, recovery: &str) -> String {
    commands
        .lines()
        .filter(|line| !line.trim().is_empty())
        .map(|command| {
            // cmd expands this block before running recovery, so the final exit
            // keeps the required command's failure even if recovery succeeds.
            format!("{command}\r\nif errorlevel 1 (\r\n{recovery}\r\nexit /b %errorlevel%\r\n)")
        })
        .collect::<Vec<_>>()
        .join("\r\n")
}

#[cfg(test)]
mod tests {
    use super::super::installer_handoff::{run_commands_in_fixture, spawn_fixture_and_exit};
    use super::*;
    use hbb_common::sha2::{Digest, Sha256};
    use std::{fs, path::PathBuf};

    fn fixture() -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "labdesk_payload_!&^()_{}",
            uuid::Uuid::new_v4().simple()
        ));
        fs::create_dir(&directory).unwrap();
        directory
    }

    #[test]
    fn protected_payload_rejects_source_and_script_replacement() {
        let directory = fixture();
        let source = directory.join("signed payload !&^().exe");
        fs::write(&source, b"authenticated payload").unwrap();
        let digest = format!("{:x}", Sha256::digest(b"authenticated payload"));
        let stage = stage_commands(source.to_str().unwrap(), &digest, "exe").unwrap();
        // The fixture consumer checks the exact protected copy. No installer or
        // UAC is invoked; the real outer bootstrap runs in a private test folder.
        let consumer = format!("{stage}\r\nif not exist \"%LABDESK_OUTPUT_DIR%\\payload.exe\" exit /b 78\r\nexit /b 73");
        let valid = run_commands_in_fixture(consumer.clone(), None).unwrap();
        assert_eq!(valid.status.code(), Some(73));
        fs::write(&source, b"replaced after caller verification").unwrap();
        let changed = run_commands_in_fixture(consumer.clone(), None).unwrap();
        assert_eq!(changed.status.code(), Some(HASH_MISMATCH as i32));
        let changed_script = run_commands_in_fixture(consumer, Some("exit /b 0")).unwrap();
        assert!(!changed_script.status.success());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn protected_payload_does_not_reopen_the_original_after_staging() {
        let directory = fixture();
        let source = directory.join("source.exe");
        fs::write(&source, b"original").unwrap();
        let digest = format!("{:x}", Sha256::digest(b"original"));
        let stage = stage_commands(source.to_str().unwrap(), &digest, "exe").unwrap();
        let commands = format!("{stage}\r\necho replaced>\"{}\"\r\nfc /B \"{}\" \"%LABDESK_OUTPUT_DIR%\\payload.exe\" > nul\r\nif errorlevel 2 exit /b 79\r\nif errorlevel 1 exit /b 74\r\nexit /b 0", source.display(), source.display());
        let output = run_commands_in_fixture(commands, None).unwrap();
        assert_eq!(output.status.code(), Some(74));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn protected_payload_rejects_unsafe_command_inputs() {
        let digest = "0".repeat(64);
        for path in [
            "relative.exe",
            "C:\\unsafe%TEMP%.exe",
            "C:\\unsafe\".exe",
            "C:\\unsafe\n.exe",
        ] {
            assert!(stage_commands(path, &digest, "exe").is_err());
        }
        for digest in ["", "abc", &"g".repeat(64), &format!("{}&", "0".repeat(63))] {
            assert!(stage_commands("C:\\payload.exe", digest, "exe").is_err());
        }
    }

    #[test]
    fn protected_exe_waits_and_preserves_child_failure_or_reboot_exit() {
        let directory = fixture();
        let source = directory.join("update !&^().exe");
        let marker = directory.join("executed.txt");
        fs::copy(std::env::current_exe().unwrap(), &source).unwrap();
        let digest = format!("{:x}", Sha256::digest(fs::read(&source).unwrap()));
        std::env::set_var("LABDESK_UPDATE_TEST_MARKER", &marker);
        for code in [7, 3010] {
            std::env::set_var("LABDESK_UPDATE_TEST_EXIT", code.to_string());
            let commands = verified_exe_commands(
                source.to_str().unwrap(),
                &digest,
                "--test-threads=1 harmless_update_payload_child --nocapture",
            )
            .unwrap();
            let output = run_commands_in_fixture(commands, None).unwrap();
            assert_eq!(
                output.status.code(),
                Some(code),
                "{}",
                String::from_utf8_lossy(&output.stderr)
            );
            let executed = fs::read_to_string(&marker).unwrap();
            assert!(executed.ends_with("\\payload.exe"));
            assert!(executed.contains(".bat.dir\\"));
            assert_ne!(executed, source.to_str().unwrap());
        }
        std::env::remove_var("LABDESK_UPDATE_TEST_MARKER");
        std::env::remove_var("LABDESK_UPDATE_TEST_EXIT");
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn harmless_update_payload_child() {
        if let Ok(marker) = std::env::var("LABDESK_UPDATE_TEST_MARKER") {
            fs::write(marker, std::env::current_exe().unwrap().to_str().unwrap()).unwrap();
            std::process::exit(
                std::env::var("LABDESK_UPDATE_TEST_EXIT")
                    .unwrap()
                    .parse()
                    .unwrap(),
            );
        }
    }

    #[test]
    fn protected_copy_survives_the_originating_process_exit() {
        let directory = fixture();
        fs::create_dir(directory.join("runner")).unwrap();
        fs::write(directory.join("source.exe"), b"original").unwrap();
        // Pipe handles can survive in the detached receiver, so output() waits
        // for that receiver's EOF. Wait only for the parent, keeping diagnostics.
        let parent_output = fs::File::create(directory.join("parent-output.txt")).unwrap();
        let result = std::process::Command::new(std::env::current_exe().unwrap())
            .args(["--test-threads=1", "harmless_handoff_parent", "--nocapture"])
            .env("LABDESK_HANDOFF_PARENT_FIXTURE", &directory)
            .env("TEMP", &directory)
            .env("TMP", &directory)
            .stdin(std::process::Stdio::null())
            .stdout(parent_output.try_clone().unwrap())
            .stderr(parent_output)
            .status()
            .unwrap();
        assert!(
            result.success(),
            "{}",
            fs::read_to_string(directory.join("parent-output.txt")).unwrap()
        );
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while !directory.join("ready").exists() && std::time::Instant::now() < deadline {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(
            directory.join("ready").exists(),
            "detached receiver never staged payload"
        );
        assert!(
            !directory.join("completed").exists(),
            "receiver consumed payload before the post-exit mutation"
        );
        fs::write(
            directory.join("source.exe"),
            b"replaced after original process exit",
        )
        .unwrap();
        fs::write(directory.join("continue"), b"continue").unwrap();
        while (!directory.join("completed").exists()
            || fs::read_dir(directory.join("runner"))
                .unwrap()
                .next()
                .is_some())
            && std::time::Instant::now() < deadline
        {
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        assert!(
            directory.join("completed").exists(),
            "protected copy was not consumed after origin exit"
        );
        assert_eq!(fs::read(directory.join("completed")).unwrap(), b"original");
        assert!(
            fs::read_dir(directory.join("runner"))
                .unwrap()
                .next()
                .is_none(),
            "receiver did not finish cleanup"
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn harmless_handoff_parent() {
        if let Some(directory) = std::env::var_os("LABDESK_HANDOFF_PARENT_FIXTURE") {
            let directory = PathBuf::from(directory);
            let source = directory.join("source.exe");
            let digest = format!("{:x}", Sha256::digest(b"original"));
            let stage = stage_commands(source.to_str().unwrap(), &digest, "exe").unwrap();
            let root = path_for_cmd_environment(&directory).unwrap();
            let commands = format!("{stage}\r\necho ready>\"{root}\\ready\"\r\n\
                for /L %%i in (1,1,15) do (\r\n\
                if exist \"{root}\\continue\" goto consume\r\n\
                ping -n 2 127.0.0.1 > nul\r\n)\r\nexit /b 81\r\n\
                :consume\r\ncopy /B /Y \"%LABDESK_OUTPUT_DIR%\\payload.exe\" \"{root}\\completed\" > nul || exit /b 82\r\nexit /b 0");
            spawn_fixture_and_exit(commands, &directory).unwrap();
        }
    }

    #[test]
    fn update_copy_failure_runs_recovery_and_preserves_failure() {
        let directory = fixture();
        let destination = directory.join("destination");
        let recovered = directory.join("recovered");
        fs::create_dir(&destination).unwrap();
        let recovery = format!("echo restored>\"{}\"\r\nver > nul", recovered.display());
        let commands = copy_update_commands(
            &directory.join("missing source"),
            &destination,
            "",
            &recovery,
        )
        .unwrap();
        let result = run_commands_in_fixture(format!("{commands}\r\nexit /b 0"), None).unwrap();
        assert!(
            !result.status.success(),
            "copy failure was replaced by recovery success"
        );
        assert!(recovered.exists(), "service recovery command did not run");
        let source = directory.join("source");
        fs::create_dir(&source).unwrap();
        fs::write(source.join("labdesk.exe"), b"replacement").unwrap();
        fs::remove_file(&recovered).unwrap();
        let commands = copy_update_commands(&source, &destination, "", &recovery).unwrap();
        let result = run_commands_in_fixture(format!("{commands}\r\nexit /b 0"), None).unwrap();
        assert!(
            result.status.success(),
            "{}",
            String::from_utf8_lossy(&result.stderr)
        );
        assert_eq!(
            fs::read(destination.join("labdesk.exe")).unwrap(),
            b"replacement"
        );
        assert!(!recovered.exists());
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn required_update_failure_survives_recovery_and_optional_success() {
        let cmd = get_system_executable("cmd.exe").unwrap();
        let cmd = path_for_cmd_environment(&cmd).unwrap();
        let commands = required_update_commands(&format!("\"{cmd}\" /D /C exit 7"), "ver > nul");
        let result =
            run_commands_in_fixture(format!("{commands}\r\nver > nul\r\nexit /b 0"), None).unwrap();
        assert_eq!(result.status.code(), Some(7));
    }
}
