//! Machine-local maintenance windows around the existing signed installer.

use chrono::{Datelike, Timelike};
use hbb_common::{bail, config::{self, Config}, ResultType};
use serde_derive::{Deserialize, Serialize};
use std::{path::PathBuf, sync::{atomic::{AtomicBool, Ordering}, Mutex}};
use crate::labdesk::{collector::request_signed, identity::AgentIdentity};

const PERSONAL_OPTION: &str = "labdesk-update-policy";
const POLL_PATH: &str = "/agent/updates";
const STATUS_PATH: &str = "/agent/updates/status";
static CHECK_REQUESTED: AtomicBool = AtomicBool::new(false);
static STATE_IO: Mutex<()> = Mutex::new(());
static POLICY_WRITE: Mutex<()> = Mutex::new(());
lazy_static::lazy_static! {
    static ref ATTEMPT: Mutex<Option<Attempt>> = Mutex::new(None);
}

#[derive(Clone, Debug, Default, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Policy {
    pub revision: u64,
    pub automatic: bool,
    pub weekly: Option<Weekly>,
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Weekly {
    pub days: Vec<u32>,
    pub start_minute: u32,
    pub window_minutes: u32,
}

impl Weekly {
    fn contains(&self, day: u32, minute: u32) -> bool {
        self.days.iter().any(|start_day| {
            let elapsed = (day * 1440 + minute + 7 * 1440 - (start_day * 1440 + self.start_minute)) % (7 * 1440);
            elapsed < self.window_minutes
        })
    }
}

impl Policy {
    fn validate(&self) -> ResultType<()> {
        if self.automatic && self.weekly.is_none() { bail!("Automatic installation needs a weekly window"); }
        if let Some(w) = &self.weekly {
            if w.days.is_empty() || w.days.len() > 7 || w.start_minute >= 1440
                || !(15..=1440).contains(&w.window_minutes)
                || w.days.iter().enumerate().any(|(i, day)| *day > 6 || w.days[..i].contains(day)) {
                bail!("Invalid machine-local update window");
            }
        }
        Ok(())
    }

    fn due(&self) -> bool {
        let local = chrono::Local::now();
        self.automatic && self.weekly.as_ref().is_some_and(|w|
            w.contains(local.weekday().num_days_from_sunday(), local.hour() * 60 + local.minute()))
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
struct Command {
    id: String,
    action: String,
    starts_at: i64,
    ends_at: i64,
}

impl Command {
    fn valid(&self) -> bool {
        !self.id.is_empty() && self.id.len() <= 128
            && self.id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            && matches!(self.action.as_str(), "check" | "install")
            && self.starts_at >= 0 && self.ends_at > self.starts_at
    }
    fn due(&self, now: i64) -> bool { self.valid() && self.starts_at <= now && now < self.ends_at }
}

#[derive(Deserialize)]
struct Response { policy: Policy, commands: Vec<Command> }

#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct State {
    sequence: u64,
    policy: Option<Policy>,
    policy_revision: u64,
    current_version: String,
    available_version: Option<String>,
    state: String,
    last_checked_at: Option<i64>,
    last_attempt_at: Option<i64>,
    command_id: Option<String>,
    command_state: Option<String>,
    error: Option<String>,
    handed_off_target_version: Option<String>,
    consumed: Vec<Command>,
}

impl State {
    fn merge_ledger(&mut self, current: Self, at: i64) {
        self.sequence = self.sequence.max(current.sequence);
        for command in current.consumed {
            if command.ends_at > at && !self.consumed.iter().any(|c| c.id == command.id) { self.consumed.push(command); }
        }
    }
    fn consume(&mut self, command: &Command, now: i64) -> ResultType<()> {
        self.consumed.retain(|c| c.ends_at > now);
        if !command.due(now) || self.consumed.iter().any(|c| c.id == command.id) || self.consumed.len() >= 4096 {
            bail!("Update command is expired or already attempted");
        }
        self.consumed.push(command.clone());
        Ok(())
    }
    fn store(&self) -> ResultType<()> {
        self.save(false).map(|_| ())
    }
    fn save(&self, advance: bool) -> ResultType<Self> {
        let _lock = STATE_IO.lock().unwrap();
        let mut stored = self.clone();
        match std::fs::read_to_string(state_path()) {
            Ok(text) => {
                let current: State = hbb_common::toml::from_str(&text)?;
                stored.merge_ledger(current, now());
            },
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {},
            Err(error) => return Err(error.into()),
        }
        if advance {
            stored.sequence = stored.sequence.checked_add(1).filter(|n| *n <= 9_007_199_254_740_991)
                .ok_or_else(|| hbb_common::anyhow::anyhow!("Update status sequence is exhausted"))?;
        }
        let destination = state_path();
        let temporary = destination.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        let result = (|| -> ResultType<()> {
            config::store_path(temporary.clone(), &stored)?;
            std::fs::OpenOptions::new().read(true).write(true).open(&temporary)?.sync_all()?;
            std::fs::rename(&temporary, &destination)?;
            #[cfg(unix)]
            std::fs::File::open(destination.parent().unwrap())?.sync_all()?;
            Ok(())
        })();
        if result.is_err() { let _ = std::fs::remove_file(&temporary); }
        result?;
        Ok(stored)
    }
    fn load() -> ResultType<Self> {
        let _lock = STATE_IO.lock().unwrap();
        match std::fs::read_to_string(state_path()) {
            Ok(text) => Ok(hbb_common::toml::from_str(&text)?),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(e) => Err(e.into()),
        }
    }
    fn public_status(&self) -> serde_json::Value {
        serde_json::json!({
            "sequence": self.sequence,
            "policyRevision": self.policy_revision, "currentVersion": report_version(&self.current_version),
            "availableVersion": self.available_version.as_deref().map(report_version), "state": self.state,
            "lastCheckedAt": self.last_checked_at, "lastAttemptAt": self.last_attempt_at,
            "commandId": self.command_id, "commandState": self.command_state,
            "error": self.error, "capabilities": capabilities(),
        })
    }
    fn report(&self, identity: Option<&AgentIdentity>) -> ResultType<()> {
        let Some(identity) = identity else { return Ok(()); };
        let stored = self.save(true)?;
        request(identity, "POST", STATUS_PATH, &stored.public_status().to_string()).map(|_| ())
    }
}

struct Attempt { policy: Policy, command: Option<Command>, state: State }

fn state_path() -> PathBuf { AgentIdentity::path().with_file_name("update-schedule.toml") }
fn now() -> i64 { chrono::Utc::now().timestamp() }
fn report_version(version: &str) -> &str { version.strip_prefix('v').unwrap_or(version) }
pub(super) fn android_release_available(metadata: &serde_json::Value, version: &str) -> bool {
    metadata["version"].as_str() == Some(version) && metadata["platforms"].as_array().is_some_and(|platforms|
        platforms.iter().any(|p| p["key"] == "android-universal" && p["kind"] == "apk" && p["asset"].as_str().is_some_and(|asset| !asset.is_empty())))
}
pub(super) fn compare_versions(a: &str, b: &str) -> Option<std::cmp::Ordering> {
    use std::cmp::Ordering;
    fn parts(value: &str) -> Option<(Vec<u64>, Option<&str>)> {
        if value.len() > 64 { return None; }
        let value = report_version(value).split('+').next()?;
        let (core, pre) = value.split_once('-').map_or((value, None), |(c, p)| (c, Some(p)));
        let core: Vec<u64> = core.split('.').map(str::parse).collect::<Result<_, _>>().ok()?;
        if core.len() != 3 || pre.is_some_and(|p| p.split('.').any(|v| v.is_empty() || !v.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-'))) { return None; }
        Some((core, pre))
    }
    let (core_a, pre_a) = parts(a)?;
    let (core_b, pre_b) = parts(b)?;
    let core_order = core_a.cmp(&core_b);
    if core_order != Ordering::Equal { return Some(core_order); }
    let (a, b) = match (pre_a, pre_b) {
        (None, None) => return Some(Ordering::Equal),
        (None, Some(_)) => return Some(Ordering::Greater),
        (Some(_), None) => return Some(Ordering::Less),
        (Some(a), Some(b)) => (a, b),
    };
    let mut a = a.split('.'); let mut b = b.split('.');
    loop {
        let (x, y) = match (a.next(), b.next()) {
            (None, None) => return Some(Ordering::Equal),
            (None, Some(_)) => return Some(Ordering::Less),
            (Some(_), None) => return Some(Ordering::Greater),
            (Some(x), Some(y)) => (x, y),
        };
        let order = match (x.bytes().all(|v| v.is_ascii_digit()), y.bytes().all(|v| v.is_ascii_digit())) {
            (true, true) => { let x = x.trim_start_matches('0'); let y = y.trim_start_matches('0'); x.len().cmp(&y.len()).then_with(|| x.cmp(y)) },
            (true, false) => Ordering::Less,
            (false, true) => Ordering::Greater,
            (false, false) => x.cmp(y),
        };
        if order != Ordering::Equal { return Some(order); }
    }
}
fn request(identity: &AgentIdentity, method: &str, path: &str, body: &str) -> ResultType<String> {
    let rt = hbb_common::tokio::runtime::Builder::new_current_thread().enable_all().build()?;
    let (status, text) = rt.block_on(request_signed(identity, method, path, body))?;
    if !(200..300).contains(&status) { bail!("Update service refused request ({})", status); }
    if text.len() > 64 * 1024 { bail!("Update response is too large"); }
    Ok(text)
}

fn identity() -> ResultType<Option<AgentIdentity>> {
    Ok(AgentIdentity::load_existing()?.filter(|i| !i.machine_id().is_empty()))
}

fn policy(identity: Option<&AgentIdentity>) -> ResultType<Response> {
    let response = if let Some(identity) = identity {
        serde_json::from_str::<Response>(&request(identity, "GET", POLL_PATH, "")?)?
    } else {
        let text = Config::get_option(PERSONAL_OPTION);
        let personal = if text.is_empty() {
            // Preserve an explicit existing choice; a missing option never opts in.
            let legacy = Config::get_option(config::keys::OPTION_ALLOW_AUTO_UPDATE);
            let enabled = !legacy.is_empty() && config::option2bool(config::keys::OPTION_ALLOW_AUTO_UPDATE, &legacy);
            let personal = Policy { revision: 0, automatic: enabled, weekly: enabled.then(|| Weekly { days: (0..7).collect(), start_minute: 0, window_minutes: 1440 }) };
            Config::set_option(PERSONAL_OPTION.into(), serde_json::to_string(&personal)?);
            if enabled { Config::set_option("labdesk-update-legacy-migrated".into(), "Y".into()); }
            personal
        } else { serde_json::from_str(&text)? };
        Response { policy: personal, commands: local_command().filter(|c| c.due(now())).into_iter().collect() }
    };
    response.policy.validate()?;
    if response.commands.len() > 1 || response.commands.iter().any(|c| !c.valid()) {
        bail!("Invalid update commands");
    }
    Ok(response)
}

fn same_authority(response: &Response, policy: &Policy, command: Option<&Command>) -> bool {
    match command {
        Some(command) => response.commands.iter().any(|current| current == command),
        None => response.policy == *policy,
    }
}

fn idle() -> bool {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    { super::has_no_active_conns_ipc() }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    { super::has_no_active_conns() }
}

fn capabilities() -> serde_json::Value {
    #[cfg(any(target_os = "windows", target_os = "macos", target_os = "linux"))]
    let installed = crate::platform::is_installed() && crate::platform::is_root();
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    let installed = false;
    #[cfg(target_os = "linux")]
    let installed = installed && crate::platform::installed_package_kind().is_some();
    serde_json::json!({"check": true, "install": installed, "scheduling": installed})
}

pub(super) fn request_check() { CHECK_REQUESTED.store(true, Ordering::SeqCst); }

/// Called only by the service updater thread, never by the telemetry runtime.
pub(super) fn tick() -> ResultType<()> {
    let identity = identity()?;
    let mut state = State::load()?;
    state.current_version = crate::VERSION.to_owned();
    if state.handed_off_target_version.as_deref().and_then(|target| compare_versions(crate::VERSION, target))
        .is_some_and(|order| order != std::cmp::Ordering::Less) {
        state.state = "completed".into();
        if state.command_id.is_some() { state.command_state = Some("completed".into()); }
        state.handed_off_target_version = None;
        state.available_version = None;
        state.last_checked_at = None;
        state.store()?;
        state.report(identity.as_ref())?;
    }
    // A claim persisted before a crash is never executed twice. Installation
    // remains pending until the running version confirms its target.
    if state.handed_off_target_version.is_some() {
        if state.last_attempt_at.is_some_and(|at| now() - at >= 1800) {
            state.handed_off_target_version = None;
            state.state = "failed".into();
            state.error = Some("Installation did not confirm the new running version within 30 minutes.".into());
            if state.command_id.is_some() { state.command_state = Some("failed".into()); }
            state.store()?;
            return state.report(identity.as_ref());
        }
        return Ok(());
    }
    if state.command_id.as_ref().is_some_and(|id| state.consumed.iter().any(|c| c.id == *id))
        && !matches!(state.command_state.as_deref(), Some("completed" | "failed" | "skipped")) {
        state.command_state = Some("failed".into());
        state.state = "failed".into();
        state.error = Some("The previous update attempt ended before an installation handoff.".into());
        state.store()?;
        state.report(identity.as_ref())?;
    }
    if state.command_id.is_some() && matches!(state.command_state.as_deref(), Some("completed" | "failed" | "skipped")) {
        // Keep a terminal acknowledgement durable until the service accepts it.
        if let Err(error) = state.report(identity.as_ref()) {
            // A canceled/expired command can no longer accept a terminal report.
            // Confirm its absence before forgetting it; network failure is not consent.
            let current = policy(identity.as_ref())?;
            if current.commands.iter().any(|c| Some(&c.id) == state.command_id.as_ref()) { return Err(error); }
        }
        state.command_id = None;
        state.command_state = None;
        state.store()?;
    }
    let response = policy(identity.as_ref());
    let authorized = response.is_ok();
    let response = response.unwrap_or(Response { policy: Policy::default(), commands: vec![] });
    if authorized {
        state.policy_revision = response.policy.revision;
        state.policy = Some(response.policy.clone());
    }
    let command = response.commands.into_iter().find(|c| c.due(now()) && !state.consumed.iter().any(|old| old.id == c.id));
    if authorized && command.is_none() {
        if identity.is_none() && local_command().is_some_and(|c| c.ends_at <= now() && state.command_id.as_ref() == Some(&c.id)) {
            state.state = "failed".into();
            state.error = Some("The one-hour local update window expired before installation could start.".into());
        }
        // Canceled/expired commands must not be attached to a later weekly run.
        state.command_id = None;
        state.command_state = None;
    }
    let forced = CHECK_REQUESTED.swap(false, Ordering::SeqCst);
    let check_due = forced || command.is_some() || state.last_checked_at.is_none_or(|at| now() - at >= 3600);
    if check_due {
        if let Some(command) = &command {
            if let Some(identity) = identity.as_ref() {
                request(identity, "POST", &format!("/agent/updates/{}/claim", command.id), "{}")?;
            }
            state.command_id = Some(command.id.clone());
            state.command_state = Some("checking".into());
        }
        state.state = "checking".into();
        // Reporting an observation must not prevent release detection while the
        // management endpoint is temporarily unavailable.
        let _ = state.report(identity.as_ref());
        match super::do_check_software_update() {
            Ok(()) => {
                state.last_checked_at = Some(now());
                let url = crate::common::SOFTWARE_UPDATE_URL.lock().unwrap().clone();
                state.available_version = if url.is_empty() { None } else { Some(url.rsplit('/').next().unwrap_or_default().chars().take(64).collect()) };
                state.error = None;
                state.state = if state.available_version.is_some() { "available" } else { "up-to-date" }.into();
            }
            Err(e) => {
                state.last_checked_at = Some(now());
                state.state = "failed".into();
                state.error = Some(e.to_string().chars().take(512).collect());
                if let Some(command) = &command {
                    state.consume(command, now())?;
                    state.command_state = Some("failed".into());
                }
                state.store()?;
                return state.report(identity.as_ref());
            }
        }
    }
    if let Some(command) = &command {
        if command.action == "check" || state.available_version.is_none() {
            state.consume(command, now())?;
            state.command_state = Some(if command.action == "check" { "completed" } else { "skipped" }.into());
            state.store()?;
            return state.report(identity.as_ref());
        }
    }
    if !authorized {
        state.store()?;
        return state.report(identity.as_ref());
    }
    let due = command.as_ref().is_some_and(|c| c.action == "install" && c.due(now()))
        || (command.is_none() && response.policy.due());
    if due && state.available_version.is_some() && (command.is_some() || state.last_attempt_at.is_none_or(|at| now() - at >= 1800)) {
        if capabilities()["install"] != true {
            state.state = "unsupported".into();
            if let Some(command) = &command {
                state.consume(command, now())?;
                state.command_state = Some("skipped".into());
            }
        } else if !idle() {
            state.state = "deferred".into();
        } else {
            if let Some(command) = &command { state.consume(command, now())?; }
            state.last_attempt_at = Some(now());
            state.state = "downloading".into();
            if command.is_some() { state.command_state = Some("downloading".into()); }
            state.store()?;
            state.report(identity.as_ref())?;
            *ATTEMPT.lock().unwrap() = Some(Attempt { policy: response.policy, command, state });
            let result = install();
            let mut attempt = ATTEMPT.lock().unwrap().take().unwrap();
            if let Err(error) = result {
                attempt.state.state = "failed".into();
                attempt.state.error = Some(error.to_string().chars().take(512).collect());
                attempt.state.handed_off_target_version = None;
                if attempt.command.is_some() { attempt.state.command_state = Some("failed".into()); }
            }
            attempt.state.store()?;
            return if attempt.state.handed_off_target_version.is_some() { Ok(()) } else { attempt.state.report(identity.as_ref()) };
        }
    }
    state.store()?;
    state.report(identity.as_ref())
}

fn install() -> ResultType<()> {
    #[cfg(target_os = "windows")]
    { super::check_update(true) }
    #[cfg(target_os = "macos")]
    { if !super::check_update_as_root()? { bail!("No install was started"); } Ok(()) }
    #[cfg(target_os = "linux")]
    { if !super::check_update_as_root_linux()? { bail!("No install was started"); } Ok(()) }
    #[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
    { bail!("Scheduled installation is unavailable on this platform") }
}

pub(super) fn install_authorized() -> bool { ATTEMPT.lock().unwrap().is_some() }

pub(super) fn read_status() -> ResultType<String> {
    let mut state = State::load()?;
    state.current_version = crate::VERSION.to_owned();
    if state.state.is_empty() { state.state = "idle".into(); }
    let mut status = state.public_status();
    let policy_error = Config::get_option("labdesk-update-policy-error");
    if !policy_error.is_empty() { status["error"] = policy_error.into(); }
    status["managed"] = identity()?.is_some().into();
    status["legacyMigrated"] = (Config::get_option("labdesk-update-legacy-migrated") == "Y").into();
    status["queuedLocalCommand"] = serde_json::to_value(local_command().filter(|c| c.due(now()) && !state.consumed.iter().any(|old| old.id == c.id)))?;
    Ok(status.to_string())
}

pub(super) fn read_policy() -> ResultType<String> {
    let policy = if identity()?.is_some() { State::load()?.policy.unwrap_or_default() } else { policy(None)?.policy };
    Ok(serde_json::to_string(&policy)?)
}

pub(super) fn write_policy(value: &str) -> ResultType<String> {
    let _lock = POLICY_WRITE.lock().unwrap();
    let result = (|| {
        if identity()?.is_some() { bail!("This machine's fleet manages its update policy"); }
        if value.len() > 4096 { bail!("Update policy is too large"); }
        let mut proposed: Policy = serde_json::from_str(value)?;
        proposed.validate()?;
        let current = policy(None)?.policy;
        if proposed.revision != current.revision { bail!("Update settings changed. Refresh before saving"); }
        proposed.revision = current.revision.checked_add(1).ok_or_else(|| hbb_common::anyhow::anyhow!("Update policy revision is exhausted"))?;
        let text = serde_json::to_string(&proposed)?;
        Config::set_option(PERSONAL_OPTION.into(), text.clone());
        Config::set_option("labdesk-update-legacy-migrated".into(), String::new());
        Ok(text)
    })();
    let error = result.as_ref().err().map(|e: &hbb_common::anyhow::Error| e.to_string().chars().take(512).collect()).unwrap_or_default();
    Config::set_option("labdesk-update-policy-error".into(), error);
    result
}

fn local_command() -> Option<Command> {
    let value = Config::get_option("labdesk-update-once");
    if value.len() > 4096 { return None; }
    serde_json::from_str::<Command>(&value).ok().filter(Command::valid)
}

pub(super) fn queue_local(action: &str) -> ResultType<()> {
    let _lock = POLICY_WRITE.lock().unwrap();
    let result = (|| {
        if identity()?.is_some() { bail!("This machine is fleet-managed. Use its fleet update controls"); }
        if !matches!(action, "check" | "install") { bail!("Choose check or install"); }
        if action == "install" && capabilities()["install"] != true { bail!("This copy does not support unattended installation"); }
        let state = State::load()?;
        if state.handed_off_target_version.is_some() || local_command().is_some_and(|c| c.due(now()) && !state.consumed.iter().any(|old| old.id == c.id)) {
            bail!("A local update is already queued or installing");
        }
        let command = Command { id: uuid::Uuid::new_v4().to_string(), action: action.into(), starts_at: now(), ends_at: now() + 3600 };
        Config::set_option("labdesk-update-once".into(), serde_json::to_string(&command)?);
        Ok(())
    })();
    let error = result.as_ref().err().map(|e: &hbb_common::anyhow::Error| e.to_string().chars().take(512).collect()).unwrap_or_default();
    Config::set_option("labdesk-update-policy-error".into(), error);
    result
}

pub(super) fn before_download() -> ResultType<()> {
    let guard = ATTEMPT.lock().unwrap();
    let attempt = guard.as_ref().ok_or_else(|| hbb_common::anyhow::anyhow!("No scheduled update authorization"))?;
    let identity = identity()?;
    let latest = policy(identity.as_ref())?;
    if !same_authority(&latest, &attempt.policy, attempt.command.as_ref())
        || !attempt.command.as_ref().map_or_else(|| latest.policy.due(), |c| c.due(now())) || !idle() {
        bail!("Update authorization, maintenance window, or idle state changed");
    }
    Ok(())
}

/// Fresh server consent is required after download, before any privileged handoff.
pub(super) fn before_handoff(version: &str) -> ResultType<()> {
    let mut guard = ATTEMPT.lock().unwrap();
    let attempt = guard.as_mut().ok_or_else(|| hbb_common::anyhow::anyhow!("No scheduled update authorization"))?;
    let identity = identity()?;
    let latest = policy(identity.as_ref())?;
    if !same_authority(&latest, &attempt.policy, attempt.command.as_ref())
        || !attempt.command.as_ref().map_or_else(|| latest.policy.due(), |c| c.due(now())) || !idle() {
        bail!("Update authorization, maintenance window, or idle state changed");
    }
    attempt.state.state = "installing".into();
    attempt.state.available_version = Some(version.to_owned());
    if attempt.command.is_some() { attempt.state.command_state = Some("installing".into()); }
    attempt.state.handed_off_target_version = Some(version.to_owned());
    attempt.state.store()?;
    attempt.state.report(identity.as_ref())?;
    if !attempt.command.as_ref().map_or_else(|| latest.policy.due(), |c| c.due(now())) || !idle() {
        bail!("Maintenance window closed or a session started before installation");
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn weekly_window_includes_overnight_but_excludes_its_end() {
        let weekly = Weekly { days: vec![6], start_minute: 23 * 60, window_minutes: 120 };
        assert!(weekly.contains(6, 23 * 60));
        assert!(weekly.contains(0, 59));
        assert!(!weekly.contains(0, 60));
        assert!(!weekly.contains(6, 22 * 60));
    }

    #[test]
    fn notifications_do_not_authorize_installation() {
        assert!(!Policy::default().due());
        assert!(!Policy { revision: 1, automatic: true, weekly: None }.due());
        let policy = Policy { revision: 1, automatic: false, weekly: Some(Weekly { days: (0..7).collect(), start_minute: 0, window_minutes: 1440 }) };
        assert!(!policy.due());
    }

    #[test]
    fn command_cannot_name_an_artifact_or_escape_claim_path() {
        let mut command = Command { id: "../other".into(), action: "install".into(), starts_at: 0, ends_at: 200 };
        assert!(!command.valid());
        command.id = "command-1".into();
        command.action = "download".into();
        assert!(!command.valid());
    }

    #[test]
    fn malformed_policy_cannot_enable_an_install() {
        for weekly in [
            Weekly { days: vec![], start_minute: 0, window_minutes: 60 },
            Weekly { days: vec![7], start_minute: 0, window_minutes: 60 },
            Weekly { days: vec![0, 0], start_minute: 0, window_minutes: 60 },
            Weekly { days: vec![0], start_minute: 1440, window_minutes: 60 },
            Weekly { days: vec![0], start_minute: 0, window_minutes: 1441 },
        ] {
            assert!(Policy { revision: 1, automatic: true, weekly: Some(weekly) }.validate().is_err());
        }
    }

    #[test]
    fn command_window_and_consumed_ids_fail_closed() {
        let command = Command { id: "command-1".into(), action: "install".into(), starts_at: 100, ends_at: 200 };
        assert!(!command.due(99));
        assert!(command.due(100));
        assert!(!command.due(200));
        let mut state = State::default();
        assert!(state.consume(&command, 150).is_ok());
        let json = serde_json::to_string(&state).unwrap();
        let mut restored: State = serde_json::from_str(&json).unwrap();
        assert!(restored.consume(&command, 151).is_err());
        assert!(hbb_common::toml::from_str::<State>("").is_err());
        assert!(serde_json::from_str::<State>("{\"sequence\":1}").is_err());
    }

    #[test]
    fn stale_state_cannot_erase_a_consumed_command_or_roll_back_sequence() {
        let command = Command { id: "command-1".into(), action: "install".into(), starts_at: 100, ends_at: 200 };
        let mut current = State::default();
        current.sequence = 7;
        current.consume(&command, 150).unwrap();
        let mut stale = State::default();
        stale.merge_ledger(current, 151);
        assert_eq!(stale.sequence, 7);
        assert!(stale.consume(&command, 151).is_err());
    }

    #[test]
    fn prerelease_ordering_detects_alpha_updates_and_ignores_build_metadata() {
        use std::cmp::Ordering::*;
        assert_eq!(compare_versions("1.4.0-alpha.7", "1.4.0-alpha.6"), Some(Greater));
        assert_eq!(compare_versions("1.4.0-alpha.9", "1.4.0-alpha.10"), Some(Less));
        assert_eq!(compare_versions("1.4.0", "1.4.0-alpha.10"), Some(Greater));
        assert_eq!(compare_versions("v1.4.0+new", "1.4.0+old"), Some(Equal));
        assert_eq!(compare_versions("garbage", "1.4.0"), None);
    }

    #[test]
    fn mobile_notice_requires_the_same_release_to_publish_an_android_asset() {
        let release = serde_json::json!({"version":"2.0.0","platforms":[{"key":"android-universal","kind":"apk","asset":"labdesk-2.0.0-universal.apk"}]});
        assert!(android_release_available(&release, "2.0.0"));
        assert!(!android_release_available(&release, "2.1.0"));
        assert!(!android_release_available(&serde_json::json!({"version":"2.0.0","platforms":[]}), "2.0.0"));
        assert!(!android_release_available(&serde_json::json!({"version":"2.0.0","platforms":[{"key":"windows-x86_64","kind":"exe","asset":"labdesk.exe"}]}), "2.0.0"));
    }

    #[test]
    fn changed_policy_or_canceled_command_cannot_authorize_handoff() {
        let policy = Policy { revision: 4, automatic: true, weekly: Some(Weekly { days: vec![1], start_minute: 0, window_minutes: 1440 }) };
        let mut response = Response { policy: policy.clone(), commands: vec![] };
        assert!(same_authority(&response, &policy, None));
        response.policy.revision = 5;
        assert!(!same_authority(&response, &policy, None));
        let command = Command { id: "once".into(), action: "install".into(), starts_at: 0, ends_at: 200 };
        assert!(!same_authority(&response, &policy, Some(&command)));
        response.commands.push(command.clone());
        assert!(same_authority(&response, &policy, Some(&command)));
    }
}
