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
#[path = "route_selection.rs"]
mod route_selection;
#[path = "local_lan.rs"]
mod local_lan;

/// Called only by the elevated uninstall helper, before removing the service.
/// Stop the writer first so its refresh thread cannot reinstall removed filters.
#[cfg(windows)]
pub fn cleanup_local_lan_for_uninstall() -> Result<(), String> {
    local_lan::platform::uninstall(&crate::get_app_name())
}
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
    /// Commit a one-time ticket spend in the machine's privileged ledger.
    ConnectPolicyRequired,
    /// Fixed local update operations; neither a signing oracle nor a file path.
    UpdateStatus,
    UpdatePolicyRead,
    UpdatePolicyWrite { value: String },
    UpdateAction { action: String },
    SpendTicket { id: String, expires_at: i64, permissions: Option<super::ticket::ConnectPermissions> },
    /// Recheck a previously claimed managed session; no arbitrary path or body.
    AuthorizeTicket { id: String },
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
            Self::ConnectPolicyRequired => formatter.write_str("ConnectPolicyRequired"),
            Self::UpdateStatus => formatter.write_str("UpdateStatus"),
            Self::UpdatePolicyRead => formatter.write_str("UpdatePolicyRead"),
            Self::UpdatePolicyWrite { .. } => formatter.write_str("UpdatePolicyWrite"),
            Self::UpdateAction { action } => formatter.debug_struct("UpdateAction").field("action", action).finish(),
            Self::SpendTicket { id, .. } => formatter.debug_struct("SpendTicket").field("id", id).finish_non_exhaustive(),
            Self::AuthorizeTicket { id } => formatter.debug_struct("AuthorizeTicket").field("id", id).finish_non_exhaustive(),
            Self::Daemon {
                action,
                management_url,
                ..
            } => formatter
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
            Self::ConnectPolicyRequired | Self::SpendTicket { .. } | Self::AuthorizeTicket { .. } => 5_000,
            Self::UpdateStatus | Self::UpdatePolicyRead | Self::UpdatePolicyWrite { .. } | Self::UpdateAction { .. } => 5_000,
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
#[cfg(not(any(target_os = "android", target_os = "ios")))]
static ROUTING_OPERATION: std::sync::Mutex<()> = std::sync::Mutex::new(());

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
        LabnetRequest::Sign { method, path, body } => sign_console_request(&method, &path, body.as_bytes(), sign_here),
        LabnetRequest::ConnectPolicyRequired => super::ticket::policy_required_here().map(|v| v.to_string()).map_err(|e| e.to_string()),
        LabnetRequest::UpdateStatus => crate::updater::update_status(),
        LabnetRequest::UpdatePolicyRead => crate::updater::update_policy(),
        LabnetRequest::UpdatePolicyWrite { value } => crate::updater::set_update_policy(&value),
        LabnetRequest::UpdateAction { action } => crate::updater::request_local_update(&action),
        LabnetRequest::SpendTicket { id, expires_at, permissions } => super::ticket::spend_here(&id, expires_at, permissions.as_ref())
            .map(|spent| spent.to_string()).map_err(|err| err.to_string()),
        LabnetRequest::AuthorizeTicket { id } => super::ticket::authority_here(&id, false, None)
            .map(|authorized| authorized.to_string()).map_err(|err| err.to_string()),
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

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn sign_console_request(method: &str, path: &str, body: &[u8], signer: impl FnOnce(&str, &str, &[u8]) -> Result<String, String>) -> Result<String, String> {
    // The UI can express local network consent, but cannot impersonate the
    // privileged telemetry, job runner or ticket collector with the machine key.
    let consent_id = |prefix: &str, suffix: &str| {
        path.strip_prefix(prefix).and_then(|rest| rest.strip_suffix(suffix))
            .map(|id| !id.is_empty() && id.len() <= 128
                && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
            .unwrap_or(false)
    };
    let allowed = matches!((method, path),
        ("POST" | "DELETE", "/agent/overlay/enrol")
        | ("POST", "/agent/overlay/self")
        | ("GET", "/agent/overlay/inbox" | "/agent/overlay/routing"))
        || (method == "POST" && (consent_id("/agent/overlay/invites/", "/decide")
            || consent_id("/agent/overlay/labnets/", "/leave")));
    if !allowed || body.len() > 16 * 1024 {
        return Err("This operation is not available to the console".to_owned());
    }
    signer(method, path, body)
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
    let identity = AgentIdentity::load_existing()
        .map_err(|err| err.to_string())?
        .ok_or_else(|| "This machine is not enrolled".to_owned())?;
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
/// installer lays it out (`build.py` stages `netbird-dist` into `/usr/share/labdesk/netbird`;
/// the Windows package puts it under `netbird\` in the install directory).
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn netbird_binary() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|err| err.to_string())?;
    let dir = exe.parent().ok_or("This executable has no directory")?;
    Ok(bundled_netbird(dir))
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn bundled_netbird(exe_dir: &Path) -> PathBuf {
    exe_dir.join("netbird").join(if cfg!(windows) {
        "netbird.exe"
    } else {
        "netbird"
    })
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
    let Ok(url) = url::Url::parse(url) else {
        return false;
    };
    url.scheme() == "https"
        && url.host_str() == Some(MANAGEMENT_HOST)
        && url.port_or_known_default() == Some(443)
        && url.username().is_empty()
        && url.password().is_none()
        && url.path() == "/"
        && url.query().is_none()
        && url.fragment().is_none()
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
            // Login carries the settings used by `up`; disabling updates also
            // rejects that login. Explicit false repairs earlier installations.
            s("--disable-update-settings=false"),
            s("--config"),
            state_dir.join("default.json").display().to_string(),
            s("--log-file"),
            state_dir.join("client.log").display().to_string(),
            s("--service-env"),
            format!("NB_STATE_DIR={}", state_dir.display()),
        ],
        "start" => vec![s("service"), s("start"), s("--service"), s(SERVICE_NAME)],
        "service-status" => vec![s("service"), s("status"), s("--service"), s(SERVICE_NAME)],
        "up" => vec![
            s("up"),
            s("--setup-key-file"),
            key_file.display().to_string(),
            s("--management-url"),
            s(management_url),
            s("--admin-url"),
            s("https://lab-desk.net"),
            s("--hostname"),
            s(hostname),
            s("--interface-name"),
            s("labdesk0"),
            s("--wireguard-port"),
            s("51821"),
            s("--disable-auto-connect=false"),
        ],
        "down" => vec![s("down")],
        "status" => vec![s("status"), s("--json")],
        "routes-list" => vec![s("networks"), s("list")],
        "exit-isolation-state" => vec![s("networks"), s("exit-isolation")],
        "exit-isolation-on" => vec![s("up"), s("--block-lan-access=true")],
        "exit-isolation-off" => vec![s("up"), s("--block-lan-access=false")],
        _ => return None,
    };
    args.push(s("--daemon-addr"));
    args.push(s(daemon_addr));
    Some(args)
}

/// NetBird otherwise imports /etc/netbird/config.json on first start, even
/// with a different NB_STATE_DIR. Seed only a new owned profile; NetBird fills
/// its missing keys and defaults. Keep it offline until the explicit up call.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn seed_owned_profile(dir: &Path) -> Result<(), String> {
    use std::io::Write;
    let mut directories = std::fs::DirBuilder::new();
    directories.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directories.mode(0o700);
    }
    directories.create(dir).map_err(|err| err.to_string())?;
    let path = dir.join("default.json");
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = match options.open(&path) {
        Ok(file) => file,
        Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => return Ok(()),
        Err(err) => return Err(err.to_string()),
    };
    let seed = serde_json::json!({
        // The daemon's gRPC dialer requires host:port. An already seeded URL
        // bypasses NetBird's default-port normalization when Login repeats it.
        "ManagementURL": { "Scheme": "https", "Host": format!("{}:443", MANAGEMENT_HOST) },
        "AdminURL": { "Scheme": "https", "Host": "lab-desk.net" },
        "DisableAutoConnect": true,
        "WgIface": "labdesk0",
        "WgPort": 51821,
    });
    let written = file.write_all(seed.to_string().as_bytes())
        .and_then(|_| file.sync_all());
    drop(file);
    if let Err(err) = written {
        std::fs::remove_file(&path).ok();
        return Err(err.to_string());
    }
    #[cfg(windows)]
    crate::platform::set_path_permission_for_portable_service_shmem_file(&path)
        .map_err(|err| err.to_string())?;
    Ok(())
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

/// Inspect the actual Windows registration, not service.json, which NetBird
/// writes before a reconfiguration succeeds. Reconfiguring an unchanged service
/// deletes and recreates it and can race SCM's pending deletion.
#[cfg(windows)]
fn owned_windows_service_is_configured(binary: &Path, dir: &Path) -> bool {
    use windows::{
        core::PCWSTR,
        Win32::{Foundation::{HLOCAL, LocalFree}, UI::Shell::CommandLineToArgvW},
    };
    use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
    let Ok(key) = RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(format!(r"SYSTEM\CurrentControlSet\Services\{}", SERVICE_NAME))
    else { return false; };
    let Ok(command): Result<String, _> = key.get_value("ImagePath") else { return false; };
    let Ok(environment): Result<Vec<String>, _> = key.get_value("Environment") else { return false; };
    let wide: Vec<u16> = command.encode_utf16().chain(Some(0)).collect();
    let mut count = 0;
    // Windows owns this argv allocation; release it after copying the strings.
    let args = unsafe {
        let pointer = CommandLineToArgvW(PCWSTR(wide.as_ptr()), &mut count);
        if pointer.is_null() { return false; }
        let result = std::slice::from_raw_parts(pointer, count as usize)
            .iter().map(|arg| arg.to_string()).collect::<Result<Vec<_>, _>>();
        let _ = LocalFree(Some(HLOCAL(pointer.cast())));
        match result { Ok(args) => args, Err(_) => return false }
    };
    let same_path = |a: &str, b: &Path| a.replace('/', "\\").eq_ignore_ascii_case(&b.display().to_string().replace('/', "\\"));
    if args.len() < 3 || !same_path(&args[0], binary) || args[1..3] != ["service", "run"] {
        return false;
    }
    let mut values = std::collections::HashMap::new();
    let mut remaining = args[3..].iter();
    while let Some(flag) = remaining.next() {
        let Some(value) = remaining.next() else { return false; };
        if values.insert(flag.as_str(), value.as_str()).is_some() { return false; }
    }
    if values.keys().any(|flag| !matches!(*flag, "--log-level" | "--daemon-addr" | "--management-url" | "--config" | "--log-file")) {
        return false;
    }
    values.get("--daemon-addr") == Some(&daemon_addr())
        && values.get("--management-url").is_some_and(|url| management_url_is_ours(url))
        && values.get("--config").is_some_and(|path| same_path(path, &dir.join("default.json")))
        && values.get("--log-file").is_some_and(|path| same_path(path, &dir.join("client.log")))
        && environment.len() == 1
        && environment[0].strip_prefix("NB_STATE_DIR=").is_some_and(|path| same_path(path, dir))
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn daemon(action: &str, setup_key: &str, management_url: &str) -> Result<String, String> {
    if matches!(action, "exit-isolation-on" | "exit-isolation-off") {
        return Err("Exit LAN policy changes require the checked consent operation".into());
    }
    if matches!(action, "exit-consent" | "subnet-consent") {
        if !management_url.is_empty() { return Err("Exit consent does not accept a management URL".into()); }
        #[derive(Deserialize)]
        #[serde(rename_all = "camelCase", deny_unknown_fields)]
        struct Decision { offer_id: String, accept: bool }
        let decision: Decision = serde_json::from_str(setup_key).map_err(|_| "Invalid exit consent")?;
        if decision.offer_id.len() != 36 || !route_selection::valid_exit_id(&format!("ld-{}", decision.offer_id)) { return Err("Invalid exit offer identifier".into()); }
        let _lock = ROUTING_OPERATION.lock().map_err(|_| "Routing operation unavailable")?;
        let intent = routing_http("GET", "/agent/overlay/routing", "")?;
        let subnet = action == "subnet-consent";
        let offers = intent[if subnet { "subnetOffers" } else { "offers" }].as_array().ok_or("Missing hosting offers")?;
        let offer = offers.iter().find(|offer| offer["id"].as_str() == Some(decision.offer_id.as_str())).ok_or("Exit offer no longer pending")?;
        let cidr = if subnet {
            let cidr = offer["cidr"].as_str().ok_or("Missing offered subnet")?;
            let (ip, bits) = cidr.split_once('/').ok_or("Invalid offered subnet")?;
            let ip: std::net::IpAddr = ip.parse().map_err(|_| "Invalid offered subnet address")?;
            let bits: u8 = bits.parse().map_err(|_| "Invalid offered subnet prefix")?;
            if bits == 0 || bits > if ip.is_ipv4() { 32 } else { 128 } { return Err("Invalid offered subnet prefix".into()); }
            Some(cidr)
        } else { None };
        if decision.accept {
            let allow_lan = if subnet { true } else { offer["allowExitLan"].as_bool().ok_or("Missing exit LAN policy")? };
            if allow_lan && intent["isolationRequired"].as_bool() != Some(false) { return Err("Revoke isolated exit offers and finish their cleanup before allowing LAN access".into()); }
            if !allow_lan && intent["lanAccessRequired"].as_bool() != Some(false) { return Err("Revoke LAN-enabled exit and subnet offers and finish cleanup before isolating this host".into()); }
            let state: serde_json::Value = serde_json::from_str(&daemon("exit-isolation-state", "", "")?).map_err(|e| e.to_string())?;
            if state["version"].as_u64() != Some(1) || state["supported"].as_bool() != Some(true) { return Err("The running VPN does not support safe exit hosting".into()); }
            if subnet && (state["allowExitLan"].as_bool() != Some(true) || state["active"].as_bool() != Some(false)) { return Err("Disable exit LAN isolation before approving subnet sharing".into()); }
            if !subnet { set_exit_isolation_profile(allow_lan)?; }
            routing_operation_locked(true)?;
        }
        let path = format!("/agent/overlay/{}/{}/decide", if subnet { "subnets" } else { "exits" }, decision.offer_id);
        let mut body = serde_json::json!({ "accept": decision.accept });
        if let Some(cidr) = cidr { body["cidr"] = serde_json::json!(cidr); }
        return Ok(routing_http("POST", &path, &body.to_string())?.to_string());
    }
    if matches!(action, "exit-isolation-enable" | "exit-isolation-disable") {
        let _lock = ROUTING_OPERATION.lock().map_err(|_| "Routing operation unavailable")?;
        if !setup_key.is_empty() || !management_url.is_empty() { return Err("Exit isolation takes no caller-supplied arguments".into()); }
        if action == "exit-isolation-disable" && routing_http("GET", "/agent/overlay/routing", "")?["isolationRequired"].as_bool() != Some(false) {
            return Err("Revoke isolated exit offers and finish cleanup before allowing exit users onto this LAN".into());
        }
        if action == "exit-isolation-enable" && routing_http("GET", "/agent/overlay/routing", "")?["lanAccessRequired"].as_bool() != Some(false) {
            return Err("Revoke LAN-enabled exit and subnet offers and finish cleanup before isolating this host".into());
        }
        let before: serde_json::Value = serde_json::from_str(&daemon("exit-isolation-state", "", "")?).map_err(|e| e.to_string())?;
        if before["version"].as_u64() != Some(1) || before["supported"].as_bool() != Some(true) {
            return Err("This VPN daemon cannot enforce exit-side LAN isolation".into());
        }
        set_exit_isolation_profile(action == "exit-isolation-disable")?;
        return routing_operation_locked(true);
    }
    if matches!(action, "routing-sync" | "routing-status") {
        if !setup_key.is_empty() || !management_url.is_empty() {
            return Err("Routing IPC accepts no caller-supplied route identifiers or arguments".into());
        }
        return routing_operation(action == "routing-sync");
    }
    // This is served only after the privileged-process check in `serve`. It
    // lets onboarding verify that its IPC service exists before minting a token.
    if action == "agent-status" {
        return Ok("ready".to_owned());
    }
    if matches!(action, "install" | "up") && !management_url_is_ours(management_url) {
        return Err(format!(
            "Refusing a control plane other than {}",
            MANAGEMENT_HOST
        ));
    }
    let binary = netbird_binary()?;
    #[cfg(windows)]
    if matches!(action, "start" | "up") { local_lan::platform::recover_before_start(&binary)?; }
    let mut reconfigure = false;
    // An unanswered socket can also mean an installed service is stopped. Do not
    // try to install over it; the caller starts it after ensuring installation.
    if matches!(action, "install" | "start") {
        let args = netbird_args(
            "service-status",
            "",
            Path::new(""),
            "",
            &state_dir(),
            daemon_addr(),
        )
        .ok_or("Missing service status command")?;
        if let Ok(status) = run_netbird(&binary, &args) {
            if action == "install" {
                #[cfg(windows)]
                if owned_windows_service_is_configured(&binary, &state_dir()) {
                    return Ok(status);
                }
                // Earlier installations persisted the ordinary NetBird config
                // path. Repair this owned service during explicit enable.
                reconfigure = true;
            } else if status.trim() == "NetBird service status: Running" {
                return Ok(status);
            }
        }
    }
    if action == "install" {
        seed_owned_profile(&state_dir())?;
    }
    let key_dir = super::identity::AgentIdentity::path()
        .parent()
        .map(Path::to_path_buf)
        .ok_or("The identity path has no directory")?;
    let key_file = if action == "up" {
        Some(KeyFile::write(&key_dir, setup_key)?)
    } else {
        None
    };
    let mut args = netbird_args(
        action,
        management_url,
        key_file.as_ref().map_or(Path::new(""), |k| k.0.as_path()),
        &crate::whoami_hostname(),
        &state_dir(),
        daemon_addr(),
    )
    .ok_or_else(|| format!("Unknown daemon action '{}'", action))?;
    if reconfigure {
        args[1] = "reconfigure".to_owned();
    }
    let result = run_netbird(&binary, &args);
    // Dropped here, so the key is gone before the answer is returned.
    drop(key_file);
    result
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn set_exit_isolation_profile(allow_lan: bool) -> Result<String, String> {
    let args = netbird_args(if allow_lan { "exit-isolation-off" } else { "exit-isolation-on" }, "", Path::new(""), "", &state_dir(), daemon_addr()).ok_or("Missing exit isolation command")?;
    run_netbird(&netbird_binary()?, &args)
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn routing_http(method: &str, path: &str, body: &str) -> Result<serde_json::Value, String> {
    // Called only inside the privileged routing operation. The console cannot
    // sign acknowledgements or choose their reported values.
    let signature: serde_json::Value = serde_json::from_str(&sign_here(method, path, body.as_bytes())?).map_err(|e| e.to_string())?;
    let url = format!("{}{}", crate::LABDESK_SITE, path);
    let client = crate::hbbs_http::create_http_client_with_url_strict(&url).map_err(|e| e.to_string())?;
    let method = method.parse::<reqwest::Method>().map_err(|e| e.to_string())?;
    let response = client.request(method, &url)
        .header("Content-Type", "application/json")
        .header("X-LD-Machine", signature["machine"].as_str().ok_or("Missing machine")?)
        .header("X-LD-Ts", signature["ts"].as_str().ok_or("Missing timestamp")?)
        .header("X-LD-Sig", signature["sig"].as_str().ok_or("Missing signature")?)
        .timeout(std::time::Duration::from_secs(20)).body(body.to_owned()).send().map_err(|e| e.to_string())?;
    if !response.status().is_success() { return Err(format!("Routing broker refused request: {}", response.status())); }
    let text = response.text().map_err(|e| e.to_string())?;
    if text.len() > 64 * 1024 { return Err("Routing broker response too large".into()); }
    serde_json::from_str(&text).map_err(|e| e.to_string())
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn routing_operation(sync: bool) -> Result<String, String> {
    let _lock = ROUTING_OPERATION.lock().map_err(|_| "Routing operation unavailable")?;
    routing_operation_locked(sync)
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn routing_operation_locked(sync: bool) -> Result<String, String> {
    use std::io::Write;
    let read_routes = || -> Result<Vec<route_selection::Route>, String> {
        route_selection::parse_routes(&daemon("routes-list", "", "")?)
    };
    let mut routes = read_routes()?;
    let mut result = serde_json::json!({
        "selectionSupported": true, "hostingSupported": false,
        "clientLocalLanSupported": cfg!(windows), "exitLanSupported": false,
        "subnetSharingSupported": false, "egressVerified": false,
        "status": "unknown", "appliedExitId": null,
    });
    if let Ok(text) = daemon("exit-isolation-state", "", "") {
        if let Ok(isolation) = serde_json::from_str::<serde_json::Value>(&text) {
            if isolation["version"].as_u64() == Some(1) {
                result["hostingSupported"] = isolation["supported"].clone();
                result["exitIsolationActive"] = isolation["active"].clone();
                result["allowExitLan"] = isolation["allowExitLan"].clone();
                result["exitLanSupported"] = isolation["supported"].clone();
                result["subnetSharingSupported"] = serde_json::json!(isolation["supported"].as_bool() == Some(true) && isolation["allowExitLan"].as_bool() == Some(true) && isolation["active"].as_bool() == Some(false));
            }
        }
    }
    if sync {
        let intent = routing_http("GET", "/agent/overlay/routing", "")?;
        let revision = intent["revision"].as_u64().filter(|v| *v <= 9_007_199_254_740_991).ok_or("Invalid routing revision")?;
        let desired_exit = if intent["exitId"].is_null() { None } else { Some(intent["exitId"].as_str().ok_or("Invalid exit identity")?) };
        let desired_network = if desired_exit.is_none() { None } else { intent["networkId"].as_str() };
        let allow_local_lan = intent["allowLocalLan"].as_bool().ok_or("Missing client LAN policy")?;
        let machine = super::identity::AgentIdentity::load_existing().map_err(|e| e.to_string())?.ok_or("Not enrolled")?;
        let path = super::identity::AgentIdentity::path().with_file_name("routing-revision.json");
        match std::fs::read_to_string(&path) {
            Ok(text) => {
                let saved: serde_json::Value = serde_json::from_str(&text).map_err(|_| "Routing revision ledger is unreadable; refusing stale commands")?;
                if saved["machine"].as_str() == Some(machine.machine_id()) && saved["revision"].as_u64().ok_or("Invalid saved revision")? > revision {
                    return Err("Stale routing preference refused".into());
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.to_string()),
        }
        // Persist before changing routes. A torn ledger fails closed on the next
        // request; no command can silently restore an older selection after restart.
        let mut options = std::fs::OpenOptions::new(); options.write(true).create(true).truncate(true);
        #[cfg(unix)] { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
        let mut file = options.open(&path).map_err(|e| e.to_string())?;
        let record = serde_json::json!({ "machine": machine.machine_id(), "revision": revision }).to_string();
        file.write_all(record.as_bytes()).and_then(|_| file.sync_all()).map_err(|e| e.to_string())?;
        drop(file);
        #[cfg(windows)] crate::platform::set_path_permission_for_portable_service_shmem_file(&path).map_err(|e| e.to_string())?;
        result["revision"] = revision.into();
        let apply = || -> Result<Vec<route_selection::Route>, String> {
            if intent["unavailable"].as_bool() != Some(false) || (desired_exit.is_some() && desired_network.is_none()) {
                return Err("Selected exit is unavailable; Direct was not requested".into());
            }
            let commands = route_selection::selection_commands(&routes, desired_network)?;
            let binary = netbird_binary()?;
            #[cfg(windows)]
            local_lan::platform::apply(desired_exit.is_some() && !allow_local_lan, &binary, super::netview::attached_lan_prefixes()?)?;
            #[cfg(not(windows))]
            if desired_exit.is_some() && !allow_local_lan { return Err("Client-local LAN enforcement is unavailable on this platform".into()); }
            for command in commands {
                // Global flags must precede `--`, which protects daemon-returned IDs.
                let mut args = vec!["--daemon-addr".to_owned(), daemon_addr().to_owned()];
                args.extend(command);
                run_netbird(&binary, &args)?;
            }
            let readback = read_routes()?;
            let selected: Vec<_> = readback.iter().filter(|r| r.is_exit() && r.selected).collect();
            if desired_network.map_or(!selected.is_empty(), |id| selected.len() != 1 || selected[0].id != id) {
                return Err("Daemon did not confirm the requested exit selection".into());
            }
            Ok(readback)
        };
        match apply() {
            Ok(readback) => { routes = readback; result["status"] = if desired_exit.is_some() { "selected" } else { "direct" }.into(); result["appliedExitId"] = intent["exitId"].clone(); result["localLanBlocked"] = (desired_exit.is_some() && !allow_local_lan).into(); }
            Err(error) => { result["status"] = "unavailable".into(); result["error"] = error.into(); }
        }
        routing_http("POST", "/agent/overlay/routing/ack", &result.to_string())?;
    }
    result["routes"] = serde_json::Value::Array(routes.iter().map(|route| serde_json::json!({ "id": route.id, "networks": route.networks, "selected": route.selected, "isExit": route.is_exit() })).collect());
    Ok(result.to_string())
}

/// Run the bundled netbird with none of the `NB_*` environment it would let outrank the
/// flags. Stdout on exit zero; the daemon's own words otherwise.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn run_netbird(binary: &Path, args: &[String]) -> Result<String, String> {
    use std::io::Read;
    use std::process::Stdio;
    use std::time::{Duration, Instant};
    let mut command = std::process::Command::new(binary);
    command.args(args);
    for (key, _) in std::env::vars_os() {
        if key
            .to_string_lossy()
            .to_ascii_uppercase()
            .starts_with("NB_")
        {
            command.env_remove(key);
        }
    }
    // The CLI itself loads and persists service.json and computes --config
    // defaults. --service-env alone only isolates the later daemon process.
    command.env("NB_STATE_DIR", state_dir());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = command
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|err| format!("{}: {}", binary.display(), err))?;
    let mut stdout = child.stdout.take().ok_or("No daemon stdout")?;
    let mut stderr = child.stderr.take().ok_or("No daemon stderr")?;
    let (out_tx, out_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stdout.read_to_end(&mut bytes).map(|_| bytes);
        out_tx.send(result).ok();
    });
    let (err_tx, err_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        let result = stderr.read_to_end(&mut bytes).map(|_| bytes);
        err_tx.send(result).ok();
    });
    let timeout = Duration::from_secs(if args.first().map(String::as_str) == Some("status")
        || (args.first().map(String::as_str) == Some("service")
            && args.get(1).map(String::as_str) == Some("status")) {
        10
    } else {
        90
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(50))
            }
            result => {
                child.kill().ok();
                child.wait().ok();
                break Err(match result {
                    Err(err) => format!("Waiting for labnet service: {}", err),
                    _ => format!(
                        "Labnet command timed out after {} seconds",
                        timeout.as_secs()
                    ),
                });
            }
        }
    };
    // A service helper may leave a descendant holding its pipes open after
    // exiting. Do not join a blocking reader beyond the command deadline.
    let status = status?;
    let stdout = out_rx
        .recv_timeout(timeout.saturating_sub(started.elapsed()))
        .map_err(|_| "Labnet stdout did not close before the command deadline")?
        .map_err(|err| err.to_string())?;
    let stderr = err_rx
        .recv_timeout(timeout.saturating_sub(started.elapsed()))
        .map_err(|_| "Labnet stderr did not close before the command deadline")?
        .map_err(|err| err.to_string())?;
    let stdout = String::from_utf8_lossy(&stdout).trim().to_owned();
    if status.success() {
        return Ok(stdout);
    }
    let stderr = String::from_utf8_lossy(&stderr).trim().to_owned();
    Err(if stderr.is_empty() { stdout } else { stderr })
}

/// Run in the LabDesk server, which receives live option changes and keeps running
/// when the Flutter window closes. On Unix it asks the privileged service to sign
/// and operate NetBird; the machine credential never moves into the desktop process.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn start() {
    use hbb_common::{config::Config, log};
    use std::sync::Once;
    use std::time::Duration;
    static START: Once = Once::new();
    START.call_once(|| {
        if let Err(err) = std::thread::Builder::new()
            .name("labdesk-labnet".into())
            .spawn(|| {
                let mut reported = None;
                let mut last_error = String::new();
                loop {
                    if wants_labnet(
                        &Config::get_option("labdesk-labnet-enabled"),
                        &Config::get_option("labdesk-direct-bind"),
                    ) {
                        match reconcile(&mut reported) {
                            Ok(()) => last_error.clear(),
                            Err(err) => {
                                reported = None;
                                Config::set_option("direct-server".into(), "N".into());
                                if last_error != err {
                                    log::warn!("[labnet] {}", err);
                                    last_error = err;
                                }
                            }
                        }
                    } else {
                        if !Config::get_option("labdesk-direct-bind").is_empty() {
                            Config::set_option("direct-server".into(), "N".into());
                        }
                        reported = None;
                    }
                    std::thread::sleep(Duration::from_secs(15));
                }
            })
        {
            log::error!("[labnet] Could not start reconciliation: {}", err);
        }
    });
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn wants_labnet(enabled: &str, previous_bind: &str) -> bool {
    enabled == "Y" || (enabled.is_empty() && !previous_bind.is_empty())
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn connected_address(status: &serde_json::Value) -> Option<String> {
    if status["daemonStatus"].as_str()? != "Connected" {
        return None;
    }
    let ip = status["netbirdIp"].as_str()?.split('/').next()?;
    let address: std::net::Ipv4Addr = ip.parse().ok()?;
    let octets = address.octets();
    // This bounds a bind address, not proof of the network provider. The status
    // comes from our owned daemon; the Worker checks its actual NetBird group.
    (octets[0] == 100
        && (64..=127).contains(&octets[1])
        && !status["publicKey"].as_str()?.is_empty())
    .then(|| address.to_string())
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
fn reconcile(reported: &mut Option<String>) -> Result<(), String> {
    use hbb_common::config::Config;
    let request = |action: &str| {
        serve_here_or_over_ipc(LabnetRequest::Daemon {
            action: action.to_owned(),
            setup_key: String::new(),
            management_url: String::new(),
        })
    };
    let text = match request("status") {
        Ok(text) => text,
        Err(err) => {
            // Only restart an existing owned service. Enrollment and installation
            // still require the explicit product flow and its setup key.
            if wants_labnet(&Config::get_option("labdesk-labnet-enabled"), &Config::get_option("labdesk-direct-bind")) {
                request("start")?;
            }
            return Err(format!("Restarting the labnet service after: {}", err));
        }
    };
    let status: serde_json::Value = serde_json::from_str(&text).map_err(|err| err.to_string())?;
    let Some(ip) = connected_address(&status) else {
        *reported = None;
        Config::set_option("direct-server".into(), "N".into());
        return Err("Waiting for the owned labnet daemon to connect".to_owned());
    };
    let port = Config::get_option("direct-access-port")
        .parse::<u16>()
        .ok()
        .filter(|port| *port != 0)
        .unwrap_or((hbb_common::config::RENDEZVOUS_PORT + 2) as u16);
    let body = serde_json::json!({
        "overlayIp": ip,
        "publicKey": status["publicKey"],
        "idPk": crate::encode64(Config::get_key_pair().1),
        "directPort": port,
    })
    .to_string();
    if reported.as_deref() != Some(body.as_str()) {
        let path = "/agent/overlay/self";
        let headers = serve_here_or_over_ipc(LabnetRequest::Sign {
            method: "POST".into(),
            path: path.into(),
            body: body.clone(),
        })?;
        let headers: serde_json::Value =
            serde_json::from_str(&headers).map_err(|err| err.to_string())?;
        let url = format!("{}{}", crate::LABDESK_SITE, path);
        let response = crate::hbbs_http::create_http_client_with_url_strict(&url)
            .map_err(|err| err.to_string())?
            .post(&url)
            .header("Content-Type", "application/json")
            .header(
                "X-LD-Machine",
                headers["machine"]
                    .as_str()
                    .ok_or("Missing machine signature")?,
            )
            .header(
                "X-LD-Ts",
                headers["ts"]
                    .as_str()
                    .ok_or("Missing signature timestamp")?,
            )
            .header(
                "X-LD-Sig",
                headers["sig"].as_str().ok_or("Missing signature")?,
            )
            .timeout(std::time::Duration::from_secs(20))
            .body(body.clone())
            .send()
            .map_err(|err| err.to_string())?;
        if !response.status().is_success() {
            Config::set_option("direct-server".into(), "N".into());
            return Err(format!(
                "Labnet identity registration refused: {}",
                response.status()
            ));
        }
        *reported = Some(body);
    }
    // Remote intent remains pending while offline and is applied by the service
    // even after the Flutter window closes. Routing failure does not invent a
    // successful egress state or disable the independent Labnet connection.
    if let Err(error) = request("routing-sync") {
        hbb_common::log::debug!("[labnet] Routing reconciliation pending: {}", error);
    }
    // Disable may have arrived while the network request was running.
    if wants_labnet(
        &Config::get_option("labdesk-labnet-enabled"),
        &Config::get_option("labdesk-direct-bind"),
    ) {
        Config::set_option("labdesk-direct-bind".into(), ip);
        Config::set_option("direct-server".into(), "Y".into());
    } else {
        *reported = None;
    }
    Ok(())
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
                assert_eq!(
                    (method.as_str(), path.as_str(), body.as_str()),
                    ("POST", "/agent/overlay/self", "{\"a\":1}")
                );
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
        // Authority includes a bounded 3-second HTTPS round trip plus IPC overhead.
        assert_eq!(LabnetRequest::SpendTicket { id: "ticket".into(), expires_at: 200, permissions: None }.ipc_timeout_ms(), 5_000);
        assert_eq!(LabnetRequest::AuthorizeTicket { id: "ticket".into() }.ipc_timeout_ms(), 5_000);
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
        let json = signature_json(
            "m-1",
            "POST",
            "/agent/x",
            "1700000000".to_owned(),
            b"{}",
            |msg| {
                signed = msg.to_vec();
                Ok("sig".to_owned())
            },
        )
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
        assert!(
            signature_json("m-1", "POST", "/agent/x", "1".to_owned(), b"", |_| {
                hbb_common::bail!("no key")
            })
            .is_err()
        );
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn console_cannot_sign_privileged_agent_operations() {
        for (method, path) in [
            ("POST", "/agent/batch"), ("POST", "/agent/ticket/t1/claimed"),
            ("GET", "/agent/tickets"), ("POST", "/agent/job/j1/complete"),
            ("GET", "/agent/overlay/inbox?extra=1"), ("PATCH", "/agent/overlay/self"),
            ("POST", "/agent/overlay/invites/../decide"), ("POST", "/agent/overlay/labnets/a/b/leave"),
            ("POST", "/agent/overlay/exits/123abc/decide"), ("POST", "/agent/overlay/subnets/123abc/decide"),
            ("POST", "/agent/overlay/routing/ack"),
        ] {
            let result = sign_console_request(method, path, b"", |_, _, _| Ok("signature".into()));
            assert!(result.is_err(), "console signed {method} {path}");
        }
        assert!(sign_console_request("POST", "/agent/overlay/self", &vec![0; 16 * 1024 + 1], |_, _, _| Ok("signature".into())).is_err());
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn console_can_sign_only_its_existing_network_consent_routes() {
        for (method, path) in [
            ("POST", "/agent/overlay/enrol"), ("DELETE", "/agent/overlay/enrol"),
            ("POST", "/agent/overlay/self"), ("GET", "/agent/overlay/inbox"),
            ("POST", "/agent/overlay/invites/123abc-DEF_9/decide"),
            ("POST", "/agent/overlay/labnets/123abc-DEF_9/leave"),
        ] {
            assert_eq!(sign_console_request(method, path, b"", |m, p, _| Ok(format!("{m} {p}"))).unwrap(), format!("{method} {path}"));
        }
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_only_our_control_plane_over_tls_is_accepted() {
        assert!(management_url_is_ours("https://nb.lab-desk.net"));
        assert!(management_url_is_ours("https://nb.lab-desk.net/"));
        assert!(management_url_is_ours("https://nb.lab-desk.net:443"));
        assert!(management_url_is_ours("https://NB.lab-desk.net"));
        assert!(!management_url_is_ours("http://nb.lab-desk.net"));
        assert!(!management_url_is_ours(
            "https://nb.lab-desk.net.evil.example"
        ));
        assert!(!management_url_is_ours(
            "https://evil.example/nb.lab-desk.net"
        ));
        assert!(!management_url_is_ours("https://api.netbird.io"));
        assert!(!management_url_is_ours(""));
        for invalid in [
            "https://nb.lab-desk.net:443@evil.example",
            "https://nb.lab-desk.net:444",
            "https://nb.lab-desk.net/path",
            "https://nb.lab-desk.net/?redirect=evil",
            "https://user@nb.lab-desk.net",
        ] {
            assert!(!management_url_is_ours(invalid), "{}", invalid);
        }
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_reconcile_requires_enable_or_a_previous_enrollment_and_respects_disable() {
        assert!(!wants_labnet("", ""));
        assert!(wants_labnet("Y", ""));
        assert!(wants_labnet("", "100.70.0.1"));
        assert!(!wants_labnet("N", "100.70.0.1"));
        assert!(!wants_labnet("unexpected", "100.70.0.1"));
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_reconcile_never_binds_an_unconnected_or_invalid_daemon_address() {
        let mut status = serde_json::json!({"daemonStatus":"Connected", "netbirdIp":"100.70.0.8/16", "publicKey":"key"});
        assert_eq!(connected_address(&status).as_deref(), Some("100.70.0.8"));
        status["daemonStatus"] = "Idle".into();
        assert!(connected_address(&status).is_none());
        status["daemonStatus"] = "Connected".into();
        for ip in [
            "0.0.0.0",
            "10.1.10.110",
            "100.128.0.1",
            "100.63.0.1",
            "::",
            "garbage",
        ] {
            status["netbirdIp"] = ip.into();
            assert!(connected_address(&status).is_none(), "{}", ip);
        }
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_netbird_args_are_fixed_per_action_and_unknown_actions_run_nothing() {
        let key = Path::new("/k/setup-key");
        let state = Path::new("/s");
        let config_path = state.join("default.json").display().to_string();
        let log_path = state.join("client.log").display().to_string();
        let args = |action: &str| {
            netbird_args(
                action,
                "https://nb.lab-desk.net",
                key,
                "host-1",
                state,
                "unix:///d.sock",
            )
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
                "--disable-update-settings=false",
                "--config",
                &config_path,
                "--log-file",
                &log_path,
                "--service-env",
                "NB_STATE_DIR=/s",
                "--daemon-addr",
                "unix:///d.sock",
            ]
        );
        assert_eq!(
            args("start").unwrap(),
            [
                "service",
                "start",
                "--service",
                "labdesk-netbird",
                "--daemon-addr",
                "unix:///d.sock"
            ]
        );
        assert_eq!(
            args("up").unwrap(),
            [
                "up",
                "--setup-key-file",
                "/k/setup-key",
                "--management-url",
                "https://nb.lab-desk.net",
                "--admin-url",
                "https://lab-desk.net",
                "--hostname",
                "host-1",
                "--interface-name",
                "labdesk0",
                "--wireguard-port",
                "51821",
                "--disable-auto-connect=false",
                "--daemon-addr",
                "unix:///d.sock",
            ]
        );
        assert_eq!(
            args("down").unwrap(),
            ["down", "--daemon-addr", "unix:///d.sock"]
        );
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
    fn test_owned_profile_is_offline_until_enrolled_and_never_overwritten() {
        let dir = std::env::temp_dir().join(format!("labdesk-profile-{}-{}", std::process::id(), hbb_common::get_time()));
        seed_owned_profile(&dir).unwrap();
        let path = dir.join("default.json");
        let seed: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(seed["ManagementURL"]["Host"], "nb.lab-desk.net:443");
        assert_eq!(seed["AdminURL"]["Host"], "lab-desk.net");
        assert_eq!(seed["DisableAutoConnect"], true);
        assert_eq!(seed["WgIface"], "labdesk0");
        std::fs::write(&path, "existing owned credential").unwrap();
        seed_owned_profile(&dir).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "existing owned credential");
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_dir(&dir).unwrap();
    }

    #[cfg(not(any(target_os = "android", target_os = "ios")))]
    #[test]
    fn test_the_bundled_binary_sits_beside_this_executable() {
        let path = bundled_netbird(Path::new("/usr/share/labdesk"));
        assert_eq!(path.parent().and_then(Path::file_name).unwrap(), "netbird");
        if cfg!(windows) {
            assert_eq!(path.file_name().unwrap(), "netbird.exe");
        } else {
            assert_eq!(path, PathBuf::from("/usr/share/labdesk/netbird/netbird"));
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
