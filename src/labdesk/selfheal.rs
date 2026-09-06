//! Network self-healing, run inside the privileged service.
//!
//! The service is the only part of LabDesk that keeps running with nobody
//! logged in, so it is the only place a machine can heal its own network from.
//! Nothing here needs the console open, an account, or enrolment: a machine
//! that has lost the internet cannot reach any of those anyway. It is off
//! until an operator turns it on, because disabling adapters and rebooting are
//! not things to do to a machine on a guess.
//!
//! The shape is a ladder. A probe that proves the machine can reach the
//! internet, not merely that a cable is plugged in, runs on a cadence. A run
//! of failures cycles the network adapters off and on. If that does not bring
//! the internet back after a grace window, it cycles again, up to a cap. If
//! the cap is spent and the machine is still offline, it reboots, at most a
//! small number of times a day so a dead NIC cannot boot-loop the machine. The
//! decision at each tick is a pure function of the last state and the latest
//! probe, so it is tested without a network, an adapter or a reboot.

use hbb_common::{
    config::{load_path, Config, Config2},
    log,
};
use std::path::Path;
use std::sync::Mutex;
use std::time::Duration;

/// The option that turns self-healing on. Absent or anything but `Y` is off,
/// so the feature never acts on a machine unless it was asked to.
pub const OPTION_ENABLE: &str = "labdesk-selfheal";
/// Seconds between probes while the machine looks healthy.
pub const OPTION_PROBE_SECONDS: &str = "labdesk-selfheal-probe-seconds";
/// Consecutive failed probes before the first adapter cycle.
pub const OPTION_FAIL_THRESHOLD: &str = "labdesk-selfheal-fail-threshold";
/// Reboots allowed in one calendar day before the ladder holds off.
pub const OPTION_MAX_RESTARTS: &str = "labdesk-selfheal-max-restarts-per-day";

const DEFAULT_PROBE_SECONDS: u64 = 30;
const DEFAULT_FAIL_THRESHOLD: u32 = 4;
const DEFAULT_MAX_RESTARTS: u32 = 2;
/// Adapter cycles between coming online, before the ladder escalates to a
/// reboot. Two cycles with a grace window each is about a minute of trying the
/// cheap fix before the expensive one.
const MAX_CYCLES: u32 = 2;
/// Probes to let a cycle or a boot take effect before judging it failed. At the
/// default cadence this is one probe interval.
const GRACE_PROBES: u32 = 1;

/// The tuning the ladder reads. Held to sane ranges so a bad option cannot make
/// the machine probe in a tight loop or reboot without limit.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HealConfig {
    pub probe: Duration,
    pub fail_threshold: u32,
    pub max_restarts_per_day: u32,
}

impl HealConfig {
    /// Reads the options, clamps them, and falls back to the defaults for
    /// anything unset or unparseable.
    pub fn from_options() -> Self {
        let num = |k: &str, default: u64| -> u64 {
            Config::get_option(k).parse::<u64>().ok().unwrap_or(default)
        };
        HealConfig {
            probe: Duration::from_secs(
                num(OPTION_PROBE_SECONDS, DEFAULT_PROBE_SECONDS).clamp(10, 3600),
            ),
            fail_threshold: (num(OPTION_FAIL_THRESHOLD, DEFAULT_FAIL_THRESHOLD as u64)
                .clamp(1, 100)) as u32,
            max_restarts_per_day: (num(OPTION_MAX_RESTARTS, DEFAULT_MAX_RESTARTS as u64)
                .clamp(0, 24)) as u32,
        }
    }
}

impl Default for HealConfig {
    fn default() -> Self {
        HealConfig {
            probe: Duration::from_secs(DEFAULT_PROBE_SECONDS),
            fail_threshold: DEFAULT_FAIL_THRESHOLD,
            max_restarts_per_day: DEFAULT_MAX_RESTARTS,
        }
    }
}

/// What a probe found. Online means the machine reached the public internet,
/// not that an interface is up.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Connectivity {
    Online,
    Offline,
}

/// What the ladder decides to do this tick.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// Do nothing; wait for the next probe.
    Wait,
    /// Disable and re-enable the machine's network adapters.
    CycleAdapters,
    /// Reboot the machine.
    Restart,
    /// The ladder is exhausted for today; keep probing but take no action, so a
    /// hardware fault does not turn into an endless reboot.
    HoldOff,
}

/// What the ladder carries between ticks. Constructed with [`HealState::new`]
/// and advanced only by [`HealState::advance`].
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct HealState {
    consecutive_offline: u32,
    cycles_since_online: u32,
    restarts_today: u32,
    /// Probes still owed to the last cycle or boot before it is judged.
    grace_left: u32,
}

impl HealState {
    pub fn new() -> Self {
        HealState::default()
    }

    /// Called when the calendar day rolls over, so the reboot budget is per
    /// day rather than for the life of the process.
    pub fn reset_daily(&mut self) {
        self.restarts_today = 0;
    }

    pub fn restarts_today(&self) -> u32 {
        self.restarts_today
    }

    /// The pure ladder: the next state and the step to take, given the latest
    /// probe and the tuning. No I/O, so the whole escalation is testable.
    pub fn advance(&self, probe: Connectivity, cfg: &HealConfig) -> (HealState, Step) {
        let mut next = *self;

        if probe == Connectivity::Online {
            // Back online: forget the run of failures and the cycles it took,
            // but never the day's reboot count.
            next.consecutive_offline = 0;
            next.cycles_since_online = 0;
            next.grace_left = 0;
            return (next, Step::Wait);
        }

        // Still offline. A cycle or a boot was just performed and is owed time
        // to take effect before it is judged, or a machine that reboots slowly
        // would be rebooted again the instant it came back.
        if next.grace_left > 0 {
            next.grace_left -= 1;
            return (next, Step::Wait);
        }

        next.consecutive_offline += 1;
        if next.consecutive_offline < cfg.fail_threshold {
            return (next, Step::Wait);
        }

        // The threshold is reached. Cheapest fix first: cycle the adapters,
        // then give the cycle a grace window before counting failures again.
        if next.cycles_since_online < MAX_CYCLES {
            next.cycles_since_online += 1;
            next.consecutive_offline = 0;
            next.grace_left = GRACE_PROBES;
            return (next, Step::CycleAdapters);
        }

        // Cycling did not help. Reboot, within the day's budget.
        if next.restarts_today < cfg.max_restarts_per_day {
            next.restarts_today += 1;
            next.cycles_since_online = 0;
            next.consecutive_offline = 0;
            next.grace_left = GRACE_PROBES;
            return (next, Step::Restart);
        }

        // The budget is spent. Keep watching, but do nothing drastic: a NIC
        // that is physically dead must not reboot the machine forever.
        (next, Step::HoldOff)
    }
}

/// What the console renders beside the switch: the last probe and the step
/// the ladder last took, `step` being `None` while the switch is off.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Reachability {
    pub internet: Option<Connectivity>,
    /// Unix seconds of the probe `internet` came from; 0 before the first.
    pub at: i64,
    pub step: Option<Step>,
}

impl Reachability {
    /// The `net.reachability` attribute, section 6 of the phase 1 contracts.
    pub fn to_value(&self) -> String {
        serde_json::json!({
            "internet": match self.internet {
                Some(Connectivity::Online) => "online",
                Some(Connectivity::Offline) => "offline",
                None => "unprobed",
            },
            "at": self.at,
            "probe": "tcp443",
            "selfheal": match self.step {
                None => "off",
                Some(Step::Wait) => "watching",
                Some(Step::CycleAdapters) => "cycling",
                Some(Step::Restart) => "restarting",
                Some(Step::HoldOff) => "holdoff",
            },
        })
        .to_string()
    }
}

lazy_static::lazy_static! {
    static ref STATUS: Mutex<Reachability> = Mutex::new(Reachability::default());
}

/// The running value, for the collector to report. Not the file: what the
/// daemon is actually doing.
pub fn status() -> Reachability {
    *STATUS.lock().unwrap()
}

fn publish(status: Reachability) {
    *STATUS.lock().unwrap() = status;
}

/// Whether the switch is on, read from the daemon's own config FILE and not
/// from this process's memory.
///
/// `CONFIG2` is a `lazy_static` loaded once per process
/// (`libs/hbb_common/src/config.rs`, `Config2::load`). On Linux and macOS the
/// `--server` process syncs its copy to this daemon over `_service`, so
/// `Config::get_option` follows a flip from the console there; on Windows
/// `--server` and `--service` are two LocalSystem processes reading the same
/// file, nothing syncs them, and a flip never reached a running daemon. This
/// is the verified gap section 7 of the phase 1 contracts records, closed by
/// parsing the file on every tick.
pub fn enabled() -> bool {
    enabled_in(&Config2::file())
}

fn enabled_in(file: &Path) -> bool {
    load_path::<Config2>(file.to_path_buf())
        .options
        .get(OPTION_ENABLE)
        .map(|v| v == "Y")
        .unwrap_or(false)
}

/// Proves the machine can reach the public internet by opening a TCP
/// connection to well-known anycast resolvers on 443. A link that is up but
/// has no route to the internet, a captive portal, or a dead upstream all fail
/// this, which is the point: it measures the internet, not the cable. Any one
/// success is enough, so a single blocked address does not read as an outage.
pub(crate) fn probe_internet() -> Connectivity {
    use std::net::{SocketAddr, TcpStream};
    const TARGETS: [&str; 3] = ["1.1.1.1:443", "8.8.8.8:443", "9.9.9.9:443"];
    const TIMEOUT: Duration = Duration::from_secs(4);
    for t in TARGETS {
        if let Ok(addr) = t.parse::<SocketAddr>() {
            if TcpStream::connect_timeout(&addr, TIMEOUT).is_ok() {
                return Connectivity::Online;
            }
        }
    }
    Connectivity::Offline
}

/// Cycles every network adapter off and then on. Best effort: a machine with
/// several adapters heals the one that came back, and an error on one adapter
/// does not stop the others.
#[cfg(target_os = "windows")]
fn cycle_adapters() {
    // `netsh` is present on every supported Windows and needs no module. The
    // interface list is parsed for admin-enabled dedicated (physical) adapters;
    // loopback and disabled ones are left alone.
    let names = windows_adapter_names();
    if names.is_empty() {
        log::warn!("[selfheal] no adapter to cycle");
        return;
    }
    for name in &names {
        set_adapter(name, false);
    }
    std::thread::sleep(Duration::from_secs(3));
    for name in &names {
        set_adapter(name, true);
    }
    log::info!("[selfheal] cycled adapters: {:?}", names);
}

#[cfg(target_os = "windows")]
fn windows_adapter_names() -> Vec<String> {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let out = match std::process::Command::new("netsh")
        .args(["interface", "show", "interface"])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    {
        Ok(out) => out,
        Err(e) => {
            log::warn!("[selfheal] netsh show failed: {}", e);
            return Vec::new();
        }
    };
    let text = String::from_utf8_lossy(&out.stdout);
    let mut names = Vec::new();
    for line in text.lines() {
        // Columns: Admin State, State, Type, Interface Name. The name is the
        // rest of the line after the three leading fields, so split on
        // whitespace three times and keep the remainder verbatim.
        let cols: Vec<&str> = line.split_whitespace().collect();
        if cols.len() < 4 {
            continue;
        }
        if !cols[0].eq_ignore_ascii_case("Enabled") {
            continue;
        }
        if !cols[2].eq_ignore_ascii_case("Dedicated") {
            continue;
        }
        // Rejoin the name, which may contain spaces.
        let idx = line
            .match_indices(cols[2])
            .next()
            .map(|(i, _)| i + cols[2].len())
            .unwrap_or(0);
        let name = line[idx..].trim().to_string();
        if !name.is_empty() {
            names.push(name);
        }
    }
    names
}

#[cfg(target_os = "windows")]
fn set_adapter(name: &str, enable: bool) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let admin = if enable { "admin=enabled" } else { "admin=disabled" };
    let res = std::process::Command::new("netsh")
        .args(["interface", "set", "interface"])
        .arg(format!("name={}", name))
        .arg(admin)
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    if let Err(e) = res {
        log::warn!("[selfheal] netsh set '{}' {} failed: {}", name, admin, e);
    }
}

/// Best-effort adapter cycle on Linux through `ip link`. Runs as the service
/// user, which is root for an installed copy.
#[cfg(target_os = "linux")]
fn cycle_adapters() {
    let out = std::process::Command::new("ip")
        .args(["-o", "link", "show"])
        .output();
    let text = match out {
        Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
        Err(e) => {
            log::warn!("[selfheal] ip link show failed: {}", e);
            return;
        }
    };
    let mut names = Vec::new();
    for line in text.lines() {
        // "2: eth0: <BROADCAST,...>" -- the name is the second colon field.
        if let Some(rest) = line.split_once(": ") {
            let name = rest.1.split(&[':', '@'][..]).next().unwrap_or("").trim();
            if !name.is_empty() && name != "lo" {
                names.push(name.to_string());
            }
        }
    }
    for name in &names {
        let _ = std::process::Command::new("ip")
            .args(["link", "set", name, "down"])
            .status();
    }
    std::thread::sleep(Duration::from_secs(3));
    for name in &names {
        let _ = std::process::Command::new("ip")
            .args(["link", "set", name, "up"])
            .status();
    }
    log::info!("[selfheal] cycled adapters: {:?}", names);
}

#[cfg(target_os = "macos")]
fn cycle_adapters() {
    // No self-healing action layer on macOS yet; the ladder still probes and
    // logs, so the gap is visible rather than silent.
    log::info!("[selfheal] adapter cycling is not implemented on macOS");
}

/// Reboots the machine after a short, announced delay so a person at the
/// console is not surprised.
#[cfg(target_os = "windows")]
fn restart_machine() {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let _ = std::process::Command::new("shutdown")
        .args([
            "/r",
            "/t",
            "60",
            "/c",
            "LabDesk self-healing: restarting to restore network connectivity",
        ])
        .creation_flags(CREATE_NO_WINDOW)
        .status();
    log::warn!("[selfheal] reboot scheduled in 60s to restore connectivity");
}

#[cfg(target_os = "linux")]
fn restart_machine() {
    let _ = std::process::Command::new("shutdown")
        .args(["-r", "+1", "LabDesk self-healing: restoring network connectivity"])
        .status();
    log::warn!("[selfheal] reboot scheduled to restore connectivity");
}

#[cfg(target_os = "macos")]
fn restart_machine() {
    log::warn!("[selfheal] reboot to restore connectivity is not implemented on macOS");
}

/// Today as a day number, for resetting the reboot budget when the date rolls.
fn today() -> i64 {
    hbb_common::get_time() / 1000 / 86_400
}

/// Starts the self-healing thread. Called from the service start hook next to
/// the collector. The thread is spawned whether or not the switch is on: it
/// idles on `enabled()` while the option is off, so a daemon started with the
/// switch off still honours a later flip.
pub fn start() {
    if let Err(err) = std::thread::Builder::new()
        .name("labdesk-selfheal".to_owned())
        .spawn(run)
    {
        log::warn!("[selfheal] failed to spawn: {}", err);
    }
}

/// How often the idle thread looks at the file while the switch is off.
const OFF_POLL: Duration = Duration::from_secs(30);

fn run() {
    let mut state = HealState::new();
    let mut day = today();
    let mut on = false;
    loop {
        // The FILE, each tick, so a flip from the console takes effect within
        // one interval on every platform (see `enabled`).
        if !enabled() {
            if on {
                log::info!("[selfheal] turned off");
                on = false;
                state = HealState::new();
                let last = status();
                publish(Reachability { step: None, ..last });
            }
            std::thread::sleep(OFF_POLL);
            continue;
        }
        if !on {
            log::info!("[selfheal] watching connectivity");
            on = true;
        }
        let cfg = HealConfig::from_options();
        if today() != day {
            day = today();
            state.reset_daily();
        }
        let probe = probe_internet();
        let (next, step) = state.advance(probe, &cfg);
        state = next;
        publish(Reachability {
            internet: Some(probe),
            at: hbb_common::get_time() / 1000,
            step: Some(step),
        });
        match step {
            Step::Wait => {}
            Step::CycleAdapters => {
                log::warn!("[selfheal] internet unreachable; cycling adapters");
                cycle_adapters();
            }
            Step::Restart => {
                log::warn!(
                    "[selfheal] internet still unreachable after cycling; restart {} of {} today",
                    state.restarts_today(),
                    cfg.max_restarts_per_day
                );
                restart_machine();
            }
            Step::HoldOff => {
                log::error!(
                    "[selfheal] internet unreachable and the day's remedies are spent; holding off"
                );
            }
        }
        std::thread::sleep(cfg.probe);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg() -> HealConfig {
        HealConfig {
            probe: Duration::from_secs(30),
            fail_threshold: 3,
            max_restarts_per_day: 2,
        }
    }

    /// Drives the ladder with a fixed probe result for a number of ticks,
    /// collecting the steps it takes.
    fn drive(mut state: HealState, probe: Connectivity, ticks: usize, cfg: &HealConfig) -> (HealState, Vec<Step>) {
        let mut steps = Vec::new();
        for _ in 0..ticks {
            let (next, step) = state.advance(probe, cfg);
            state = next;
            steps.push(step);
        }
        (state, steps)
    }

    #[test]
    fn online_never_acts() {
        let (_s, steps) = drive(HealState::new(), Connectivity::Online, 20, &cfg());
        assert!(steps.iter().all(|s| *s == Step::Wait));
    }

    #[test]
    fn a_run_of_failures_cycles_before_it_reboots() {
        let c = cfg();
        let mut state = HealState::new();
        let mut steps = Vec::new();
        for _ in 0..40 {
            let (next, step) = state.advance(Connectivity::Offline, &c);
            state = next;
            steps.push(step);
        }
        // First a cycle appears, and no reboot appears before the first cycle.
        let first_cycle = steps.iter().position(|s| *s == Step::CycleAdapters);
        let first_restart = steps.iter().position(|s| *s == Step::Restart);
        assert!(first_cycle.is_some(), "the ladder must try a cycle first");
        assert!(first_restart.is_some(), "and then escalate to a reboot");
        assert!(first_cycle.unwrap() < first_restart.unwrap(), "cheap fix before the expensive one");
    }

    #[test]
    fn the_first_cycle_waits_for_the_threshold() {
        let c = cfg(); // fail_threshold = 3
        let mut state = HealState::new();
        // Two offline probes: below the threshold, so no action yet.
        for _ in 0..(c.fail_threshold - 1) {
            let (next, step) = state.advance(Connectivity::Offline, &c);
            state = next;
            assert_eq!(step, Step::Wait);
        }
        // The third crosses it.
        let (_next, step) = state.advance(Connectivity::Offline, &c);
        assert_eq!(step, Step::CycleAdapters);
    }

    #[test]
    fn a_cycle_gets_a_grace_probe_before_it_is_judged() {
        let c = cfg();
        let mut state = HealState::new();
        // Reach the first cycle.
        for _ in 0..c.fail_threshold {
            let (next, _step) = state.advance(Connectivity::Offline, &c);
            state = next;
        }
        // The very next offline probe is the grace probe: no action.
        let (next, step) = state.advance(Connectivity::Offline, &c);
        state = next;
        assert_eq!(step, Step::Wait, "the cycle is owed a grace window");
        // Then failures count again toward the next escalation.
        let (_n, step) = {
            let mut s = state;
            for _ in 0..(c.fail_threshold - 1) {
                let (nn, _st) = s.advance(Connectivity::Offline, &c);
                s = nn;
            }
            s.advance(Connectivity::Offline, &c)
        };
        assert_eq!(step, Step::CycleAdapters, "second cycle before a reboot");
    }

    #[test]
    fn reboots_are_capped_per_day_then_hold_off() {
        let c = cfg(); // max_restarts_per_day = 2
        let (state, steps) = drive(HealState::new(), Connectivity::Offline, 200, &c);
        let restarts = steps.iter().filter(|s| **s == Step::Restart).count();
        assert_eq!(restarts as u32, c.max_restarts_per_day, "no more reboots than the budget");
        assert_eq!(state.restarts_today(), c.max_restarts_per_day);
        assert!(steps.contains(&Step::HoldOff), "once spent, the ladder holds off");
    }

    #[test]
    fn a_new_day_restores_the_reboot_budget() {
        let c = cfg();
        let (mut state, _steps) = drive(HealState::new(), Connectivity::Offline, 200, &c);
        assert_eq!(state.restarts_today(), c.max_restarts_per_day);
        state.reset_daily();
        // After the reset, offline again eventually reaches another reboot.
        let (_s, steps) = drive(state, Connectivity::Offline, 200, &c);
        assert!(steps.contains(&Step::Restart), "the budget returns the next day");
    }

    /// The switch is read from the file, so a value written by ANOTHER handle
    /// (the console's `--server`, on Windows a different process) is seen
    /// without this process ever reloading its `CONFIG2`.
    #[test]
    fn the_gate_reads_a_value_another_handle_wrote_to_the_file() {
        let dir = std::env::temp_dir().join(format!("labdesk-selfheal-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("LabDesk2.toml");
        assert!(!enabled_in(&file), "no file is off");
        std::fs::write(&file, "[options]\nlabdesk-selfheal = \"Y\"\n").unwrap();
        assert!(enabled_in(&file));
        std::fs::write(&file, "[options]\nlabdesk-selfheal = \"N\"\n").unwrap();
        assert!(!enabled_in(&file), "anything but Y is off");
        std::fs::write(&file, "[options]\nother = \"Y\"\n").unwrap();
        assert!(!enabled_in(&file));
        std::fs::write(&file, "not toml at all [[[").unwrap();
        assert!(!enabled_in(&file), "an unreadable file is off, not a panic");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The running value the console renders, in the contract's words.
    #[test]
    fn the_reachability_value_is_the_contract_shape() {
        let v = |r: Reachability| serde_json::from_str::<serde_json::Value>(&r.to_value()).unwrap();
        let unprobed = v(Reachability::default());
        assert_eq!(unprobed["internet"], "unprobed");
        assert_eq!(unprobed["selfheal"], "off");
        assert_eq!(unprobed["probe"], "tcp443");
        assert_eq!(unprobed["at"], 0);
        let watching = v(Reachability {
            internet: Some(Connectivity::Online),
            at: 1788480300,
            step: Some(Step::Wait),
        });
        assert_eq!(watching["internet"], "online");
        assert_eq!(watching["selfheal"], "watching");
        assert_eq!(watching["at"], 1788480300);
        for (step, word) in [
            (Step::CycleAdapters, "cycling"),
            (Step::Restart, "restarting"),
            (Step::HoldOff, "holdoff"),
        ] {
            let r = v(Reachability { internet: Some(Connectivity::Offline), at: 1, step: Some(step) });
            assert_eq!(r["internet"], "offline");
            assert_eq!(r["selfheal"], word);
        }
        // The ladder itself is untouched: `advance` is pure and the tests
        // above drive it without a probe, an adapter or a reboot.
        let (_s, step) = HealState::new().advance(Connectivity::Online, &cfg());
        assert_eq!(step, Step::Wait);
    }

    #[test]
    fn coming_back_online_forgets_the_failure_run() {
        let c = cfg();
        let mut state = HealState::new();
        for _ in 0..(c.fail_threshold - 1) {
            let (next, _s) = state.advance(Connectivity::Offline, &c);
            state = next;
        }
        let (back, step) = state.advance(Connectivity::Online, &c);
        assert_eq!(step, Step::Wait);
        // A single later failure does not immediately cross the threshold,
        // proving the counter was cleared.
        let (_n, step) = back.advance(Connectivity::Offline, &c);
        assert_eq!(step, Step::Wait);
    }
}
