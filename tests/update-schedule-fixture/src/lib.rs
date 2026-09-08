//! Compiles the actual scheduler with inert transport/platform boundaries.
#![allow(dead_code)]
extern crate self as hbb_common;
pub use anyhow::{self, bail};
pub use tokio;
pub use toml;
pub type ResultType<T> = anyhow::Result<T>;
pub const VERSION: &str = "1.0.0";

use std::{collections::{HashMap, VecDeque}, path::PathBuf, sync::{atomic::{AtomicBool, AtomicUsize, Ordering}, Mutex}};
lazy_static::lazy_static! {
    static ref OPTIONS: Mutex<HashMap<String, String>> = Mutex::new(HashMap::new());
    static ref REPLIES: Mutex<VecDeque<(&'static str, &'static str, u16, String)>> = Mutex::new(VecDeque::new());
    static ref REQUESTS: Mutex<Vec<(String, String, String)>> = Mutex::new(Vec::new());
    static ref ROOT: PathBuf = std::env::temp_dir().join(format!("labdesk-update-schedule-fixture-{}", std::process::id()));
    static ref TEST_LOCK: Mutex<()> = Mutex::new(());
}
static INSTALLS: AtomicUsize = AtomicUsize::new(0);
static IDLE: AtomicBool = AtomicBool::new(true);
static LOSE_IDLE_ON_INSTALL_ACK: AtomicBool = AtomicBool::new(false);
static MANAGED: AtomicBool = AtomicBool::new(true);

pub mod config {
    use super::*;
    pub mod keys { pub const OPTION_ALLOW_AUTO_UPDATE: &str = "allow-auto-update"; }
    pub struct Config;
    impl Config {
        pub fn get_option(key: &str) -> String { OPTIONS.lock().unwrap().get(key).cloned().unwrap_or_default() }
        pub fn set_option(key: String, value: String) { OPTIONS.lock().unwrap().insert(key, value); }
    }
    pub fn option2bool(_: &str, value: &str) -> bool { value == "Y" }
    pub fn store_path<T: serde::Serialize>(path: PathBuf, value: T) -> ResultType<()> {
        std::fs::create_dir_all(path.parent().unwrap())?;
        std::fs::write(path, toml::to_string(&value)?)?;
        Ok(())
    }
}
pub mod common {
    use super::*;
    lazy_static::lazy_static! { pub static ref SOFTWARE_UPDATE_URL: Mutex<String> = Mutex::new(String::new()); }
}
pub mod platform {
    pub fn is_installed() -> bool { true }
    pub fn is_root() -> bool { true }
    pub fn installed_package_kind() -> Option<&'static str> { Some("deb") }
}
pub mod labdesk {
    pub mod identity {
        use super::super::*;
        pub struct AgentIdentity;
        impl AgentIdentity {
            pub fn path() -> PathBuf { ROOT.join("agent-identity.toml") }
            pub fn load_existing() -> ResultType<Option<Self>> { Ok(MANAGED.load(Ordering::SeqCst).then_some(Self)) }
            pub fn machine_id(&self) -> &str { "fixture-machine" }
        }
    }
    pub mod collector {
        use super::super::*;
        pub async fn request_signed(_: &super::identity::AgentIdentity, method: &str, path: &str, body: &str) -> ResultType<(u16, String)> {
            REQUESTS.lock().unwrap().push((method.into(), path.into(), body.into()));
            let (expected_method, expected_path, status, response) = REPLIES.lock().unwrap().pop_front().expect("unexpected transport request");
            assert_eq!((method, path), (expected_method, expected_path));
            if path == "/agent/updates/status" && serde_json::from_str::<serde_json::Value>(body).ok()
                .is_some_and(|v| v["commandState"] == "installing") && LOSE_IDLE_ON_INSTALL_ACK.swap(false, Ordering::SeqCst) {
                IDLE.store(false, Ordering::SeqCst);
            }
            Ok((status, response))
        }
    }
}

#[path = "../../../src/update_schedule.rs"]
mod schedule;
fn do_check_software_update() -> ResultType<()> {
    *common::SOFTWARE_UPDATE_URL.lock().unwrap() = "https://lab-desk.net/releases/tag/2.0.0".into();
    Ok(())
}
fn has_no_active_conns() -> bool { IDLE.load(Ordering::SeqCst) }
fn has_no_active_conns_ipc() -> bool { has_no_active_conns() }
fn check_update(_: bool) -> ResultType<()> {
    schedule::before_download()?;
    schedule::before_handoff("2.0.0")?;
    INSTALLS.fetch_add(1, Ordering::SeqCst);
    Ok(())
}
fn check_update_as_root() -> ResultType<bool> { check_update(true)?; Ok(true) }
fn check_update_as_root_linux() -> ResultType<bool> { check_update_as_root() }

#[cfg(test)]
mod transport_tests {
    use super::*;

    fn reset() {
        // This exact task-owned file is the only state the fixture changes.
        let path = ROOT.join("update-schedule.toml");
        if path.exists() { std::fs::remove_file(path).unwrap(); }
        OPTIONS.lock().unwrap().clear();
        REPLIES.lock().unwrap().clear();
        REQUESTS.lock().unwrap().clear();
        INSTALLS.store(0, Ordering::SeqCst);
        IDLE.store(true, Ordering::SeqCst);
        LOSE_IDLE_ON_INSTALL_ACK.store(false, Ordering::SeqCst);
        MANAGED.store(true, Ordering::SeqCst);
    }
    fn response(with_command: bool) -> String {
        let now = chrono::Utc::now().timestamp();
        serde_json::json!({"policy":{"revision":1,"automatic":false,"weekly":null},"commands":if with_command {
            vec![serde_json::json!({"id":"command-1","action":"install","startsAt":now - 10,"endsAt":now + 3600})]
        } else { vec![] }}).to_string()
    }
    fn enqueue(method: &'static str, path: &'static str, status: u16, response: String) {
        REPLIES.lock().unwrap().push_back((method, path, status, response));
    }
    fn prepare(command: &str) {
        enqueue("GET", "/agent/updates", 200, command.into());
        enqueue("POST", "/agent/updates/command-1/claim", 200, "{}".into());
        enqueue("POST", "/agent/updates/status", 200, "{}".into());
        enqueue("POST", "/agent/updates/status", 200, "{}".into());
        enqueue("GET", "/agent/updates", 200, command.into());
    }

    #[test]
    fn actual_scheduler_requires_claim_and_final_authorization_and_never_replays_handoff() {
        let _lock = TEST_LOCK.lock().unwrap(); reset();
        let command = response(true);
        prepare(&command);
        enqueue("GET", "/agent/updates", 200, command);
        enqueue("POST", "/agent/updates/status", 200, "{}".into());
        schedule::tick().unwrap();
        assert_eq!(INSTALLS.load(Ordering::SeqCst), 1);
        assert!(REPLIES.lock().unwrap().is_empty());
        let reports: Vec<serde_json::Value> = REQUESTS.lock().unwrap().iter()
            .filter(|(_, path, _)| path == "/agent/updates/status")
            .map(|(_, _, body)| serde_json::from_str(body).unwrap()).collect();
        assert_eq!(reports.iter().map(|r| r["sequence"].as_u64().unwrap()).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert_eq!(reports.last().unwrap()["commandState"], "installing");
        assert_eq!(reports.last().unwrap()["availableVersion"], "2.0.0");
        // The same process code reloads protected state exactly as a restart does.
        schedule::tick().unwrap();
        assert_eq!(INSTALLS.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn revocation_after_download_prevents_install_and_preserves_consumed_id() {
        let _lock = TEST_LOCK.lock().unwrap(); reset();
        let command = response(true);
        prepare(&command);
        enqueue("GET", "/agent/updates", 200, response(false));
        enqueue("POST", "/agent/updates/status", 410, "{}".into());
        assert!(schedule::tick().is_err());
        assert_eq!(INSTALLS.load(Ordering::SeqCst), 0);
        let state = std::fs::read_to_string(ROOT.join("update-schedule.toml")).unwrap();
        assert!(state.contains("command-1"));
        assert!(state.contains("failed"));
    }

    #[test]
    fn final_server_refusal_prevents_install() {
        let _lock = TEST_LOCK.lock().unwrap(); reset();
        let command = response(true);
        prepare(&command);
        enqueue("GET", "/agent/updates", 200, command);
        enqueue("POST", "/agent/updates/status", 409, "{}".into());
        enqueue("POST", "/agent/updates/status", 200, "{}".into());
        schedule::tick().unwrap();
        assert_eq!(INSTALLS.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn session_start_after_install_authorization_prevents_handoff() {
        let _lock = TEST_LOCK.lock().unwrap(); reset();
        let command = response(true);
        prepare(&command);
        enqueue("GET", "/agent/updates", 200, command);
        enqueue("POST", "/agent/updates/status", 200, "{}".into());
        enqueue("POST", "/agent/updates/status", 200, "{}".into());
        LOSE_IDLE_ON_INSTALL_ACK.store(true, Ordering::SeqCst);
        schedule::tick().unwrap();
        assert_eq!(INSTALLS.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn explicit_local_install_does_not_enable_recurring_updates_and_managed_override_is_denied() {
        let _lock = TEST_LOCK.lock().unwrap(); reset();
        assert!(schedule::queue_local("install").is_err());
        MANAGED.store(false, Ordering::SeqCst);
        schedule::queue_local("install").unwrap();
        let status: serde_json::Value = serde_json::from_str(&schedule::read_status().unwrap()).unwrap();
        assert_eq!(status["managed"], false);
        assert_eq!(status["queuedLocalCommand"]["action"], "install");
        let policy: serde_json::Value = serde_json::from_str(&schedule::read_policy().unwrap()).unwrap();
        assert_eq!(policy["automatic"], false);
        schedule::tick().unwrap();
        assert_eq!(INSTALLS.load(Ordering::SeqCst), 1);
        assert!(REQUESTS.lock().unwrap().is_empty());
    }
}
