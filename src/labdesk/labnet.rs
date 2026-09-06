// The labnet work the console cannot do for itself, served over IPC by the process that
// holds the agent identity (src/labdesk/identity.rs).
//
// Who serves it. On Windows `--server` runs as LocalSystem and serves the main IPC
// channel (`ipc::start("")`, src/server.rs). On Linux and macOS `--server` is the desktop
// user, so the root `--service` serves these on `POSTFIX_SERVICE` (src/platform/linux.rs,
// src/platform/macos.rs), whose allowlist admits exactly `Data::Labnet` beside
// `Data::SyncConfig` (src/ipc.rs). `IPC_POSTFIX` names the channel per platform and
// `serve` refuses in any process that is not the privileged one, so the desktop user's
// own `--server` on Linux never answers and never mints a key into that user's profile.
//
// Who can ask. The peers those channels already admit: on Windows any process in the
// server's own session running this executable (`authorize_windows_main_ipc_connection`,
// src/ipc/auth.rs); on Linux and macOS any process of the active desktop uid, or root,
// running this executable (`authorize_service_scoped_ipc_connection`). So a local
// unprivileged user signed in at the console can now make the daemon do three things,
// each bounded to this machine's own labnet identity:
//
// - sign a machine-plane request as this machine, which every `/agent/*` call the console
//   makes needs; the secret key itself never leaves the daemon;
// - enrol this machine with an org-minted token they hold, which is the consent step the
//   design puts on the machine, and which the server refuses for a machine another
//   organization already owns (docs/plans/2026-09-04-003-rmm-architecture.md, 3.2);
// - install, start, connect, disconnect and read the bundled netbird daemon. The
//   management URL is held to LabDesk's own control plane, so the most a setup key of their
//   choosing can do is join this machine to a labnet on that plane, which is what the
//   consent prompt exists to let them do.
//
// Nothing here reads or writes another machine's anything, and nothing runs a command the
// caller names: the netbird argument lists are fixed in `netbird_args`.

use serde_derive::{Deserialize, Serialize};
#[cfg(not(any(target_os = "android", target_os = "ios")))]
use std::path::{Path, PathBuf};

#[derive(Serialize, Deserialize, Clone)]
#[serde(tag = "t", content = "c")]
pub enum LabnetRequest {
    /// `main_agent_sign` for a process that cannot read the key: answers the
    /// `{"machine","ts","sig"}` JSON the machine plane's three headers are read from.
    Sign {
        method: String,
        path: String,
        body: String,
    },
    /// `main_agent_enrol` for a process that cannot read the key: answers the machine id.
    Enrol { token: String },
    /// Drive the bundled netbird daemon. `action` is one of `install`, `start`, `up`,
    /// `down`, `status`; `setup_key` is read by `up` only; `management_url` by `install`
    /// and `up`. Answers the daemon's stdout.
    Daemon {
        action: String,
        setup_key: String,
        management_url: String,
    },
}

// A token and a setup key are one-off credentials; neither reaches a log line through
// `{:?}`, which the IPC layer uses when it rejects a frame.
impl std::fmt::Debug for LabnetRequest {
    fn fmt(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
        match self {
            Self::Sign { method, path, .. } => formatter
                .debug_struct("Sign")
                .field("method", method)
                .field("path", path)
                .finish_non_exhaustive(),
            Self::Enrol { .. } => formatter.debug_struct("Enrol").finish_non_exhaustive(),
            Self::Daemon { action, management_url, .. } => formatter
                .debug_struct("Daemon")
                .field("action", action)
                .field("management_url", management_url)
                .finish_non_exhaustive(),
        }
    }
}

impl LabnetRequest {
    /// How long the asking side waits for the answer. A signature is local work; an
    /// enrolment is one HTTPS round trip; `netbird up` registers with the control plane
    /// and waits for the connection, which NetBird itself gives about a minute.
    pub fn ipc_timeout_ms(&self) -> u64 {
        match self {
            Self::Sign { .. } => 3_000,
            Self::Enrol { .. } => 30_000,
            Self::Daemon { .. } => 120_000,
        }
    }
}

/// The IPC channel the privileged process answers labnet requests on, see the top of
/// this file.
#[cfg(windows)]
pub const IPC_POSTFIX: &str = "";
#[cfg(not(any(windows, target_os = "android", target_os = "ios")))]
pub const IPC_POSTFIX: &str = crate::POSTFIX_SERVICE;

#[cfg(not(any(target_os = "android", target_os = "ios")))]
const SERVICE_NAME: &str = "labdesk-netbird";
/// The only control plane the daemon may be pointed at (docs/LABNET-SERVER.md).
#[cfg(not(any(target_os = "android", target_os = "ios")))]
const MANAGEMENT_HOST: &str = "nb.lab-desk.net";

/// Serve one request in the privileged process, or say why not. Blocking: it signs,
/// makes an HTTPS request or waits on a netbird process, so the IPC handler runs it off
/// its runtime thread.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn serve(request: LabnetRequest) -> Result<String, String> {
    // Only the privileged process holds the key. The desktop user's `--server` on Linux
    // runs the same IPC handler, and an enrolment answered there would generate a key in
    // that user's profile which the server has never seen.
    if !crate::platform::is_root() {
        return Err("Not the privileged LabDesk process".to_owned());
    }
    match request {
        LabnetRequest::Sign { method, path, body } => sign_here(&method, &path, body.as_bytes()),
        LabnetRequest::Enrol { token } => {
            super::identity::enrol(&token, &hbb_common::config::Config::get_id())
                .map_err(|err| err.to_string())
        }
        LabnetRequest::Daemon {
            action,
            setup_key,
            management_url,
        } => daemon(&action, &setup_key, &management_url),
    }
}

/// What the FFI does: serve locally in a process that may, and otherwise ask the one
/// that does over IPC.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn serve_here_or_over_ipc(request: LabnetRequest) -> Result<String, String> {
    if crate::platform::is_root() {
        return serve(request);
    }
    crate::ipc::labnet(request).map_err(|err| err.to_string())
}

/// Sign with the identity this process can read. Nothing is minted on the way past: the
/// identity is only loaded when its file already exists, because a key generated here
/// would land in the calling account's own profile and would not be the key the server
/// holds.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn sign_here(method: &str, path: &str, body: &[u8]) -> Result<String, String> {
    use super::identity::AgentIdentity;
    if !AgentIdentity::path().exists() {
        return Err("No agent identity in this process".to_owned());
    }
    let identity = AgentIdentity::load_or_create().map_err(|err| err.to_string())?;
    if identity.machine_id().is_empty() {
        return Err("This machine is not enrolled".to_owned());
    }
    signature_json(
        identity.machine_id(),
        method,
        path,
        (hbb_common::get_time() / 1000).to_string(),
        body,
        |msg| identity.sign(msg),
    )
}

/// The three headers as JSON `{"machine","ts","sig"}`: the machine id the server looks
/// the key up by, the timestamp it bounds replay with, and the detached Ed25519
/// signature over `uplink_signed_msg` (src/labdesk/identity.rs), which is what
/// `agentAuth` rebuilds and verifies (src/worker/agent-auth.ts in labdesk-site).
///
/// The timestamp is minted by the caller rather than taken from the request, so the
/// timestamp signed and the timestamp sent cannot drift apart. The body is signed as
/// bytes, so the sender must send exactly the string it passed and nothing re-encoded.
pub fn signature_json(
    machine_id: &str,
    method: &str,
    path: &str,
    ts: String,
    body: &[u8],
    sign: impl FnOnce(&[u8]) -> hbb_common::ResultType<String>,
) -> Result<String, String> {
    let sig = sign(&super::identity::uplink_signed_msg(method, path, &ts, body))
        .map_err(|err| format!("Failed to sign an agent request: {}", err))?;
    Ok(serde_json::json!({ "machine": machine_id, "ts": ts, "sig": sig }).to_string())
}

/// Path of the bundled `netbird` executable: beside this executable, the way the
/// installer lays it out (`build.py` stages `netbird-dist` into `/usr/share/rustdesk/netbird`;
/// the Windows package puts it under `netbird\` in the install directory).
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn netbird_binary() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|err| err.to_string())?;
    let dir = exe.parent().ok_or("This executable has no directory")?;
    Ok(bundled_netbird(dir))
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn bundled_netbird(exe_dir: &Path) -> PathBuf {
    exe_dir
        .join("netbird")
        .join(if cfg!(windows) { "netbird.exe" } else { "netbird" })
}

/// Where the daemon keeps its keys and profile, apart from any NetBird the user
/// installed for themselves.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn state_dir() -> PathBuf {
    if cfg!(windows) {
        PathBuf::from(std::env::var("ProgramData").unwrap_or_else(|_| "C:\\ProgramData".to_owned()))
            .join("LabDesk")
            .join("netbird")
    } else {
        PathBuf::from("/var/lib/labdesk/netbird")
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn daemon_addr() -> &'static str {
    if cfg!(windows) {
        "npipe://labdesk-netbird"
    } else {
        "unix:///var/run/labdesk-netbird.sock"
    }
}

/// Only LabDesk's own control plane, over TLS. The console relays what the Worker told
/// it, and a local user can relay anything, so the daemon checks rather than trusts.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn management_url_is_ours(url: &str) -> bool {
    let Some(rest) = url.strip_prefix("https://") else {
        return false;
    };
    let host = rest.split(['/', ':']).next().unwrap_or_default();
    host.eq_ignore_ascii_case(MANAGEMENT_HOST)
}

/// The fixed argument list for one daemon action, or `None` for an action that does not
/// exist. Mirrors what the console ran itself before this moved into the daemon
/// (flutter/lib/labdesk/services/overlay_daemon.dart): the management address is fixed at
/// install time, `NB_*` never comes from the environment, and the setup key goes through
/// a file rather than argv, which every local user can read for as long as the process
/// runs.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn netbird_args(
    action: &str,
    management_url: &str,
    key_file: &Path,
    hostname: &str,
    state_dir: &Path,
    daemon_addr: &str,
) -> Option<Vec<String>> {
    let s = |x: &str| x.to_owned();
    let mut args = match action {
        "install" => vec![
            s("service"),
            s("install"),
            s("--service"),
            s(SERVICE_NAME),
            s("--management-url"),
            s(management_url),
            s("--disable-update-settings"),
            s("--service-env"),
            format!("NB_STATE_DIR={}", state_dir.display()),
        ],
        "start" => vec![s("service"), s("start"), s("--service"), s(SERVICE_NAME)],
        "up" => vec![
            s("up"),
            s("--setup-key-file"),
            key_file.display().to_string(),
            s("--management-url"),
            s(management_url),
            s("--hostname"),
            s(hostname),
        ],
        "down" => vec![s("down")],
        "status" => vec![s("status"), s("--json")],
        _ => return None,
    };
    args.push(s("--daemon-addr"));
    args.push(s(daemon_addr));
    Some(args)
}

/// A one-off credential on disk for as long as one netbird call runs, in the daemon's
/// own config directory (admin-only on both platforms, see `AgentIdentity::path`), and
/// gone when this is dropped, whichever way the call ended.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
struct KeyFile(PathBuf);

#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl KeyFile {
    fn write(dir: &Path, setup_key: &str) -> Result<Self, String> {
        let path = dir.join(format!(
            "setup-key-{}-{}",
            std::process::id(),
            hbb_common::get_time()
        ));
        let file = Self(path);
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        {
            use std::io::Write;
            let mut handle = options.open(&file.0).map_err(|err| err.to_string())?;
            handle
                .write_all(setup_key.as_bytes())
                .and_then(|_| handle.flush())
                .map_err(|err| err.to_string())?;
        }
        #[cfg(windows)]
        crate::platform::set_path_permission_for_portable_service_shmem_file(&file.0)
            .map_err(|err| err.to_string())?;
        Ok(file)
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
impl Drop for KeyFile {
    fn drop(&mut self) {
        std::fs::remove_file(&self.0).ok();
    }
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn daemon(action: &str, setup_key: &str, management_url: &str) -> Result<String, String> {
    if matches!(action, "install" | "up") && !management_url_is_ours(management_url) {
        return Err(format!("Refusing a control plane other than {}", MANAGEMENT_HOST));
    }
    let binary = netbird_binary()?;
    let key_dir = super::identity::AgentIdentity::path()
        .parent()
        .map(Path::to_path_buf)
        .ok_or("The identity path has no directory")?;
    let key_file = if action == "up" {
        Some(KeyFile::write(&key_dir, setup_key)?)
    } else {
        None
    };
    let args = netbird_args(
        action,
        management_url,
        key_file.as_ref().map_or(Path::new(""), |k| k.0.as_path()),
        &crate::whoami_hostname(),
        &state_dir(),
        daemon_addr(),
    )
    .ok_or_else(|| format!("Unknown daemon action '{}'", action))?;
    let result = run_netbird(&binary, &args);
    // Dropped here, so the key is gone before the answer is returned.
    drop(key_file);
    result
}

/// Run the bundled netbird with none of the `NB_*` environment it would let outrank the
/// flags. Stdout on exit zero; the daemon's own words otherwise.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn run_netbird(binary: &Path, args: &[String]) -> Result<String, String> {
    let mut command = std::process::Command::new(binary);
    command.args(args);
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().to_ascii_uppercase().starts_with("NB_") {
            command.env_remove(key);
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let out = command
        .output()
        .map_err(|err| format!("{}: {}", binary.display(), err))?;
    let stdout = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    if out.status.success() {
        return Ok(stdout);
    }
    let stderr = String::from_utf8_lossy(&out.stderr).trim().to_owned();
    Err(if stderr.is_empty() { stdout } else { stderr })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_a_request_never_prints_its_credential() {
        let enrol = LabnetRequest::Enrol {
            token: "tok-secret".to_owned(),
        };
        assert!(!format!("{:?}", enrol).contains("tok-secret"));
        let up = LabnetRequest::Daemon {
            action: "up".to_owned(),
            setup_key: "key-secret".to_owned(),
            management_url: "https://nb.lab-desk.net".to_owned(),
        };
        let printed = format!("{:?}", up);
        assert!(!printed.contains("key-secret"));
        assert!(printed.contains("up"));
    }

    #[test]
    fn test_a_request_round_trips_through_the_ipc_encoding() {
        let request = LabnetRequest::Sign {
            method: "POST".to_owned(),
            path: "/agent/overlay/self".to_owned(),
            body: "{\"a\":1}".to_owned(),
        };
        let text = serde_json::to_string(&request).unwrap();
        match serde_json::from_str::<LabnetRequest>(&text).unwrap() {
            LabnetRequest::Sign { method, path, body } => {
                assert_eq!((method.as_str(), path.as_str(), body.as_str()),
                    ("POST", "/agent/overlay/self", "{\"a\":1}"));
            }
            other => panic!("{:?}", other),
        }
    }

    #[test]
    fn test_the_wait_is_longest_for_the_daemon_and_shortest_for_a_signature() {
        let sign = LabnetRequest::Sign {
            method: "GET".to_owned(),
            path: "/".to_owned(),
            body: String::new(),
        };
        let enrol = LabnetRequest::Enrol {
            token: String::new(),
        };
        let daemon = LabnetRequest::Daemon {
            action: "up".to_owned(),
            setup_key: String::new(),
            management_url: String::new(),
        };
        assert!(sign.ipc_timeout_ms() < enrol.ipc_timeout_ms());
        assert!(enrol.ipc_timeout_ms() < daemon.ipc_timeout_ms());
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_the_channel_is_the_one_the_privileged_process_serves() {
        if cfg!(windows) {
            assert_eq!(IPC_POSTFIX, "");
        } else {
            assert_eq!(IPC_POSTFIX, crate::POSTFIX_SERVICE);
        }
    }

    #[test]
    fn test_signature_json_reports_the_timestamp_it_signed() {
        let mut signed = Vec::new();
        let json = signature_json("m-1", "POST", "/agent/x", "1700000000".to_owned(), b"{}", |msg| {
            signed = msg.to_vec();
            Ok("sig".to_owned())
        })
        .unwrap();
        let answer: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(answer["machine"], "m-1");
        assert_eq!(answer["ts"], "1700000000");
        assert_eq!(answer["sig"], "sig");
        assert_eq!(
            signed,
            crate::labdesk::identity::uplink_signed_msg("POST", "/agent/x", "1700000000", b"{}")
        );
    }

    #[test]
    fn test_signature_json_is_an_error_when_the_key_will_not_sign() {
        assert!(signature_json("m-1", "POST", "/agent/x", "1".to_owned(), b"", |_| {
            hbb_common::bail!("no key")
        })
        .is_err());
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_only_our_control_plane_over_tls_is_accepted() {
        assert!(management_url_is_ours("https://nb.lab-desk.net"));
        assert!(management_url_is_ours("https://nb.lab-desk.net/"));
        assert!(management_url_is_ours("https://nb.lab-desk.net:443"));
        assert!(management_url_is_ours("https://NB.lab-desk.net"));
        assert!(!management_url_is_ours("http://nb.lab-desk.net"));
        assert!(!management_url_is_ours("https://nb.lab-desk.net.evil.example"));
        assert!(!management_url_is_ours("https://evil.example/nb.lab-desk.net"));
        assert!(!management_url_is_ours("https://api.netbird.io"));
        assert!(!management_url_is_ours(""));
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_netbird_args_are_fixed_per_action_and_unknown_actions_run_nothing() {
        let key = Path::new("/k/setup-key");
        let state = Path::new("/s");
        let args = |action: &str| {
            netbird_args(action, "https://nb.lab-desk.net", key, "host-1", state, "unix:///d.sock")
        };
        assert_eq!(
            args("install").unwrap(),
            [
                "service",
                "install",
                "--service",
                "labdesk-netbird",
                "--management-url",
                "https://nb.lab-desk.net",
                "--disable-update-settings",
                "--service-env",
                "NB_STATE_DIR=/s",
                "--daemon-addr",
                "unix:///d.sock",
            ]
        );
        assert_eq!(
            args("start").unwrap(),
            ["service", "start", "--service", "labdesk-netbird", "--daemon-addr", "unix:///d.sock"]
        );
        assert_eq!(
            args("up").unwrap(),
            [
                "up",
                "--setup-key-file",
                "/k/setup-key",
                "--management-url",
                "https://nb.lab-desk.net",
                "--hostname",
                "host-1",
                "--daemon-addr",
                "unix:///d.sock",
            ]
        );
        assert_eq!(args("down").unwrap(), ["down", "--daemon-addr", "unix:///d.sock"]);
        assert_eq!(
            args("status").unwrap(),
            ["status", "--json", "--daemon-addr", "unix:///d.sock"]
        );
        for bad in ["", "uninstall", "ssh", "up; rm", "Up"] {
            assert!(args(bad).is_none(), "{}", bad);
        }
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_the_bundled_binary_sits_beside_this_executable() {
        let path = bundled_netbird(Path::new("/usr/share/rustdesk"));
        assert_eq!(path.parent().and_then(Path::file_name).unwrap(), "netbird");
        if cfg!(windows) {
            assert_eq!(path.file_name().unwrap(), "netbird.exe");
        } else {
            assert_eq!(path, PathBuf::from("/usr/share/rustdesk/netbird/netbird"));
        }
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_the_key_file_is_gone_after_the_call_whichever_way_it_ended() {
        let dir = std::env::temp_dir();
        let path = {
            let key = KeyFile::write(&dir, "the-key").unwrap();
            assert_eq!(std::fs::read_to_string(&key.0).unwrap(), "the-key");
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                assert_eq!(
                    std::fs::metadata(&key.0).unwrap().permissions().mode() & 0o777,
                    0o600
                );
            }
            // A binary that does not exist: the failure path.
            assert!(run_netbird(&dir.join("no-such-netbird"), &["status".to_owned()]).is_err());
            key.0.clone()
        };
        assert!(!path.exists());
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_the_daemon_refuses_another_control_plane_before_touching_anything() {
        let err = daemon("up", "key", "https://api.netbird.io").unwrap_err();
        assert!(err.contains(MANAGEMENT_HOST), "{}", err);
        let err = daemon("install", "", "http://nb.lab-desk.net").unwrap_err();
        assert!(err.contains(MANAGEMENT_HOST), "{}", err);
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_sign_here_mints_nothing_when_there_is_no_identity() {
        // Whatever this process is, an absent file must stay absent: a key generated on
        // the way past would not be the key the server holds.
        let path = crate::labdesk::identity::AgentIdentity::path();
        if path.exists() {
            return;
        }
        assert!(sign_here("POST", "/agent/x", b"{}").is_err());
        assert!(!path.exists());
    }
}
