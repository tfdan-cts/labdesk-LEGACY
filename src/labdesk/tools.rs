// The compiled tool catalog and the job runner.
//
// `tools.json` is compiled into the binary and is the whole of what a job may
// run. A job names a catalog entry and parameters; the entry names an argv per
// platform; the agent checks the parameters against the entry and runs the
// argv with `std::process::Command`, never through a shell. There is no
// server-held key because there is no server-authored command: the server can
// only ask for something this file already contains, and the same file sits in
// the Worker (`src/worker/tools.json` there), so what it refuses and what this
// refuses is the same list.
//
// Everything that decides whether a job runs is a pure function here, tested
// on a CI runner without a daemon: the catalog parse, the parameter check, the
// argv substitution, the once-only ledger, the output bound. What is left in
// `execute` is the plumbing those are wired into.

use super::identity::AgentIdentity;
use hbb_common::{bail, log, sodiumoxide::crypto::hash::sha256, ResultType};
use serde_derive::Deserialize;
use std::collections::{BTreeMap, VecDeque};
use std::io::Read;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The catalog, byte identical to the Worker's copy.
pub const CATALOG_JSON: &str = include_str!("tools.json");
/// Output is stdout then stderr, cut here; the hash is over the cut bytes.
pub const OUTPUT_LIMIT: usize = 16 * 1024;
/// Executed job ids remembered across restarts, oldest dropped first.
pub const LEDGER_SIZE: usize = 256;
/// Results per batch, so results never displace samples in the body bound.
pub const RESULTS_PER_BATCH: usize = 4;
/// The flush wait after an answer carrying `collectNow`.
pub const COLLECT_NOW_SECONDS: u64 = 10;
/// Beside the identity file: written by the daemon, readable by nobody else.
const LEDGER_FILE: &str = "agent-jobs.json";
const PLATFORMS: [&str; 3] = ["windows", "linux", "macos"];

#[derive(Deserialize)]
struct RawCatalog {
    version: u32,
    tools: Vec<RawTool>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawTool {
    id: String,
    label: String,
    run_as: String,
    timeout_s: u64,
    params: BTreeMap<String, RawParam>,
    platforms: BTreeMap<String, RawPlatform>,
}

#[derive(Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
enum RawParam {
    Pattern { pattern: String },
    Enum { values: Vec<String> },
    Int { min: i64, max: i64 },
}

#[derive(Deserialize)]
struct RawPlatform {
    steps: Vec<Vec<String>>,
}

/// The two values `machine_job.run_as` takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunAs {
    System,
    ActiveUser,
}

impl RunAs {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "system" => Some(Self::System),
            "active_user" => Some(Self::ActiveUser),
            _ => None,
        }
    }

    pub fn as_str(&self) -> &'static str {
        match self {
            Self::System => "system",
            Self::ActiveUser => "active_user",
        }
    }
}

/// A parameter's check. Three shapes and no fourth.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Param {
    Pattern(CharClass),
    Enum(Vec<String>),
    Int { min: i64, max: i64 },
}

/// The one regex shape the catalog uses, `^[class]{min,max}$`, parsed rather
/// than handed to a regex crate the binary does not carry. Anything else in a
/// `pattern` is a catalog error `Catalog::parse` refuses, so a catalog author
/// learns at test time and not from a job that could not be validated.
#[derive(Debug, Clone, PartialEq, Eq)]
struct CharClass {
    ranges: Vec<(char, char)>,
    min: usize,
    max: usize,
}

impl CharClass {
    fn parse(pattern: &str) -> Option<Self> {
        let body = pattern.strip_prefix("^[")?.strip_suffix("$")?;
        let close = body.find(']')?;
        let (class, rest) = body.split_at(close);
        let quant = rest.strip_prefix("]{")?.strip_suffix('}')?;
        let (min, max) = quant.split_once(',')?;
        let (min, max) = (min.parse::<usize>().ok()?, max.parse::<usize>().ok()?);
        if class.is_empty() || min == 0 || max < min {
            return None;
        }
        let chars: Vec<char> = class.chars().collect();
        let mut ranges = Vec::new();
        let mut i = 0;
        while i < chars.len() {
            let lo = if chars[i] == '\\' {
                i += 1;
                *chars.get(i)?
            } else {
                chars[i]
            };
            // `a-z` is a range; a `-` that is first, last, or escaped is itself.
            if i + 2 < chars.len() && chars[i + 1] == '-' {
                let hi = chars[i + 2];
                if hi < lo {
                    return None;
                }
                ranges.push((lo, hi));
                i += 3;
            } else {
                ranges.push((lo, lo));
                i += 1;
            }
        }
        Some(Self { ranges, min, max })
    }

    fn accepts(&self, value: &str) -> bool {
        let len = value.chars().count();
        len >= self.min
            && len <= self.max
            && value
                .chars()
                .all(|c| self.ranges.iter().any(|(lo, hi)| *lo <= c && c <= *hi))
    }
}

/// One catalog entry, checked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tool {
    pub id: String,
    pub label: String,
    pub run_as: RunAs,
    pub timeout_s: u64,
    params: BTreeMap<String, Param>,
    platforms: BTreeMap<String, Vec<Vec<String>>>,
}

impl Tool {
    pub fn platforms(&self) -> impl Iterator<Item = &str> {
        self.platforms.keys().map(String::as_str)
    }

    pub fn param_names(&self) -> impl Iterator<Item = &str> {
        self.params.keys().map(String::as_str)
    }
}

/// The parsed catalog. Empty when the compiled file does not parse, which
/// refuses every job as `unknown_tool` rather than running anything on a
/// catalog that failed its own checks.
#[derive(Debug, Default)]
pub struct Catalog {
    tools: Vec<Tool>,
}

lazy_static::lazy_static! {
    pub static ref CATALOG: Catalog = Catalog::parse(CATALOG_JSON).unwrap_or_else(|err| {
        log::error!("[tools] The compiled catalog is invalid, refusing every job: {}", err);
        Catalog::default()
    });
}

impl Catalog {
    /// Parse and check a catalog. Every rule in section 1 of the phase 1
    /// contracts is a `bail!` here, and the test over the compiled file is
    /// what keeps `tools.json` inside them.
    pub fn parse(json: &str) -> ResultType<Self> {
        let raw: RawCatalog = serde_json::from_str(json)?;
        if raw.version != 1 {
            bail!("catalog version {} is not 1", raw.version);
        }
        let mut tools: Vec<Tool> = Vec::with_capacity(raw.tools.len());
        for t in raw.tools {
            if !valid_name(&t.id, 2) {
                bail!("tool id {:?} does not match ^[a-z][a-z0-9_]{{1,63}}$", t.id);
            }
            if tools.iter().any(|seen| seen.id == t.id) {
                bail!("tool id {:?} appears twice", t.id);
            }
            let Some(run_as) = RunAs::parse(&t.run_as) else {
                bail!("{}: runAs {:?} is not system or active_user", t.id, t.run_as);
            };
            if !(1..=3600).contains(&t.timeout_s) {
                bail!("{}: timeoutS {} is not 1 to 3600", t.id, t.timeout_s);
            }
            let mut params = BTreeMap::new();
            for (name, spec) in t.params {
                if !valid_name(&name, 1) {
                    bail!("{}: parameter name {:?} is not allowed", t.id, name);
                }
                let param = match spec {
                    RawParam::Pattern { pattern } => match CharClass::parse(&pattern) {
                        Some(class) => Param::Pattern(class),
                        None => bail!(
                            "{}: parameter {:?} pattern {:?} is not ^[class]{{min,max}}$",
                            t.id,
                            name,
                            pattern
                        ),
                    },
                    RawParam::Enum { values } => {
                        if values.is_empty() {
                            bail!("{}: parameter {:?} enum has no values", t.id, name);
                        }
                        Param::Enum(values)
                    }
                    RawParam::Int { min, max } => {
                        if max < min {
                            bail!("{}: parameter {:?} int range is empty", t.id, name);
                        }
                        Param::Int { min, max }
                    }
                };
                params.insert(name, param);
            }
            // An `active_user` entry is launched on Windows and macOS through a
            // command line that carries the tool id and nothing else, so it
            // cannot carry a parameter (see `execute`).
            if run_as == RunAs::ActiveUser && !params.is_empty() {
                bail!("{}: an active_user tool takes no parameters", t.id);
            }
            if t.platforms.is_empty() {
                bail!("{}: names no platform", t.id);
            }
            let mut platforms = BTreeMap::new();
            for (platform, entry) in t.platforms {
                if !PLATFORMS.contains(&platform.as_str()) {
                    bail!("{}: platform {:?} is not windows, linux or macos", t.id, platform);
                }
                if entry.steps.is_empty() {
                    bail!("{}: {} has no steps", t.id, platform);
                }
                for argv in &entry.steps {
                    if argv.is_empty() || argv[0].is_empty() {
                        bail!("{}: {} has a step with no program", t.id, platform);
                    }
                    for arg in argv {
                        match template_token(arg) {
                            // A token inside a longer argument would be a place
                            // where a value is spliced into text, which is the
                            // shape every injection takes. Whole argument or not
                            // a token at all.
                            Token::Partial => bail!(
                                "{}: {} argument {:?} carries a template token inside text",
                                t.id,
                                platform,
                                arg
                            ),
                            Token::Whole(name) => {
                                if !params.contains_key(name) {
                                    bail!(
                                        "{}: {} names parameter {:?} the entry does not list",
                                        t.id,
                                        platform,
                                        name
                                    );
                                }
                            }
                            Token::None => {}
                        }
                    }
                }
                platforms.insert(platform, entry.steps);
            }
            tools.push(Tool {
                id: t.id,
                label: t.label,
                run_as,
                timeout_s: t.timeout_s,
                params,
                platforms,
            });
        }
        Ok(Self { tools })
    }

    pub fn get(&self, id: &str) -> Option<&Tool> {
        self.tools.iter().find(|t| t.id == id)
    }

    pub fn tools(&self) -> &[Tool] {
        &self.tools
    }
}

/// `^[a-z][a-z0-9_]{1,63}$` for a tool id (`min_len` 2), and the same
/// alphabet from one character for a parameter name.
fn valid_name(id: &str, min_len: usize) -> bool {
    let bytes = id.as_bytes();
    (min_len..=64).contains(&bytes.len())
        && bytes[0].is_ascii_lowercase()
        && bytes[1..]
            .iter()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || *b == b'_')
}

enum Token<'a> {
    None,
    Whole(&'a str),
    Partial,
}

/// Whether an argument is exactly `{name}`, contains braces somewhere inside
/// text, or is plain.
fn template_token(arg: &str) -> Token<'_> {
    if let Some(name) = arg.strip_prefix('{').and_then(|s| s.strip_suffix('}')) {
        if !name.contains(['{', '}']) {
            return Token::Whole(name);
        }
    }
    if arg.contains(['{', '}']) {
        return Token::Partial;
    }
    Token::None
}

/// This build's platform, as the catalog names it.
pub fn platform() -> &'static str {
    if cfg!(target_os = "windows") {
        "windows"
    } else if cfg!(target_os = "macos") {
        "macos"
    } else {
        "linux"
    }
}

/// One job as the `/agent/batch` answer carries it.
#[derive(Debug, Clone, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub id: String,
    pub tool_id: String,
    #[serde(default)]
    pub params: serde_json::Map<String, serde_json::Value>,
    pub run_as: String,
    pub timeout_s: u64,
    pub expires_at: i64,
}

/// The `jobs` member of a batch answer, and whether it asked for `collectNow`.
///
/// An entry that does not parse is skipped with a warning rather than failing
/// the rest: the server marked every one of them dispatched, and the ones that
/// are well formed still have to run.
pub fn jobs_in(text: &str) -> (Vec<Job>, bool) {
    let Ok(answer) = serde_json::from_str::<serde_json::Value>(text) else {
        return (Vec::new(), false);
    };
    let jobs = answer["jobs"]
        .as_array()
        .map(|entries| {
            entries
                .iter()
                .map(|entry| {
                    // `machine_job.params` is a JSON text column; an answer
                    // that hands it over unparsed is read the same as one
                    // that parsed it.
                    let mut entry = entry.clone();
                    if let Some(text) = entry["params"].as_str() {
                        if let Ok(parsed) = serde_json::from_str::<serde_json::Value>(text) {
                            entry["params"] = parsed;
                        }
                    }
                    entry
                })
                .filter_map(|entry| match serde_json::from_value::<Job>(entry) {
                    Ok(job) => Some(job),
                    Err(err) => {
                        log::warn!("[tools] Skipping a job the answer mis-shaped: {}", err);
                        None
                    }
                })
                .collect()
        })
        .unwrap_or_default();
    (jobs, answer["collectNow"] == serde_json::Value::Bool(true))
}

/// What one job came to, as `jobResults` carries it back.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JobResult {
    pub id: String,
    pub started_at: i64,
    pub finished_at: i64,
    /// `None` with `refused` set when the job did not run.
    pub exit_code: Option<i32>,
    pub output: String,
    pub refused: Option<&'static str>,
}

impl JobResult {
    fn refused(id: &str, why: &'static str, now: i64) -> Self {
        Self {
            id: id.to_owned(),
            started_at: now,
            finished_at: now,
            exit_code: None,
            output: String::new(),
            refused: Some(why),
        }
    }

    /// The wire member. `outputSha256` is over exactly the bytes in `output`,
    /// which are already cut to `OUTPUT_LIMIT`.
    pub fn to_json(&self) -> serde_json::Value {
        serde_json::json!({
            "id": self.id,
            "startedAt": self.started_at,
            "finishedAt": self.finished_at,
            "exitCode": self.exit_code,
            "output": self.output,
            "outputSha256": hex::encode(sha256::hash(self.output.as_bytes()).0),
            "refused": self.refused,
        })
    }
}

/// The argv list for a job, or why it is refused. Pure.
///
/// Every parameter the entry lists must be present and pass its check; a
/// parameter the entry does not list refuses the job; a value is substituted
/// only where the whole argument is its token, and is never split, quoted or
/// looked inside.
///
/// `active_user` is the seat0 user for the one entry that names one: section
/// 1 of the phase 1 contracts has `power_logoff` on Linux take the user from
/// `get_active_username()` and never from a parameter, and the catalog entry
/// is `["loginctl", "terminate-user"]` with the agent appending the name.
/// Empty or absent is `no_active_user`.
pub fn argv_for(
    tool: &Tool,
    params: &serde_json::Map<String, serde_json::Value>,
    platform: &str,
    active_user: Option<&str>,
) -> Result<Vec<Vec<String>>, &'static str> {
    let Some(steps) = tool.platforms.get(platform) else {
        return Err("wrong_platform");
    };
    if params.keys().any(|k| !tool.params.contains_key(k)) {
        return Err("bad_params");
    }
    let mut values: BTreeMap<&str, String> = BTreeMap::new();
    for (name, spec) in &tool.params {
        let Some(value) = params.get(name) else {
            return Err("bad_params");
        };
        let Some(text) = check_param(spec, value) else {
            return Err("bad_params");
        };
        values.insert(name, text);
    }
    let mut out = Vec::with_capacity(steps.len());
    for argv in steps {
        let mut built = Vec::with_capacity(argv.len());
        for arg in argv {
            match template_token(arg) {
                // `Catalog::parse` proved every token names a listed
                // parameter, and every listed parameter was just filled in.
                Token::Whole(name) => match values.get(name) {
                    Some(value) => built.push(value.clone()),
                    None => return Err("bad_params"),
                },
                Token::None => built.push(arg.clone()),
                Token::Partial => return Err("bad_params"),
            }
        }
        if tool.id == LOGOFF_TOOL && platform == "linux" {
            match active_user {
                Some(user) if !user.is_empty() => built.push(user.to_owned()),
                _ => return Err("no_active_user"),
            }
        }
        out.push(built);
    }
    Ok(out)
}

/// The entry whose Linux argv the agent completes with the seat0 user.
const LOGOFF_TOOL: &str = "power_logoff";

/// The argument a parameter value becomes, or `None` when it fails its check.
///
/// Whatever its type, a value that begins with `-` is refused: every step
/// hands the value to a program that parses options, and the contract's
/// character class admits `--force` as a unit name. This is a check on top of
/// the pattern (phase 1 contracts, section 11), and the job result names it
/// `bad_params` like any other.
fn check_param(spec: &Param, value: &serde_json::Value) -> Option<String> {
    let text = match spec {
        Param::Pattern(class) => {
            let s = value.as_str()?;
            class.accepts(s).then(|| s.to_owned())
        }
        Param::Enum(values) => {
            let s = value.as_str()?;
            values.iter().any(|v| v == s).then(|| s.to_owned())
        }
        Param::Int { min, max } => {
            let n = value.as_i64()?;
            (*min <= n && n <= *max).then(|| n.to_string())
        }
    }?;
    (!text.starts_with('-')).then_some(text)
}

/// The ids this machine has executed, so a job the server re-sends after a
/// daemon restart is refused `already_ran` rather than run twice.
///
/// Bounded at `LEDGER_SIZE`, oldest out, and written before the job starts:
/// a job that crashes the daemon half way is one that ran, not one to retry.
#[derive(Debug)]
pub struct Ledger {
    path: PathBuf,
    ids: VecDeque<String>,
}

impl Ledger {
    /// Beside the identity file, in the daemon's own directory.
    pub fn open() -> Self {
        Self::load(AgentIdentity::path().with_file_name(LEDGER_FILE))
    }

    /// A ledger that does not exist yet is empty, which is every machine
    /// before its first job. One that does not parse is empty too, and says so.
    pub fn load(path: PathBuf) -> Self {
        let ids = match std::fs::read_to_string(&path) {
            Ok(text) => match serde_json::from_str::<Vec<String>>(&text) {
                Ok(ids) => ids.into_iter().collect(),
                Err(err) => {
                    log::warn!("[tools] Ignoring an unreadable job ledger: {}", err);
                    VecDeque::new()
                }
            },
            Err(_) => VecDeque::new(),
        };
        Self { path, ids }
    }

    pub fn contains(&self, id: &str) -> bool {
        self.ids.iter().any(|seen| seen == id)
    }

    /// Remember `id`, written beside the file and renamed so a power cut
    /// leaves the old ledger or the new one and never half of either.
    pub fn record(&mut self, id: &str) -> ResultType<()> {
        self.ids.push_back(id.to_owned());
        while self.ids.len() > LEDGER_SIZE {
            self.ids.pop_front();
        }
        let tmp = self.path.with_extension("tmp");
        std::fs::write(&tmp, serde_json::to_string(&self.ids)?)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}

/// stdout then stderr, cut to `OUTPUT_LIMIT` bytes on a character boundary.
fn bounded_output(stdout: &[u8], stderr: &[u8]) -> String {
    let mut bytes = Vec::with_capacity(stdout.len() + stderr.len());
    bytes.extend_from_slice(stdout);
    bytes.extend_from_slice(stderr);
    bytes.truncate(OUTPUT_LIMIT);
    let mut text = String::from_utf8_lossy(&bytes).into_owned();
    while text.len() > OUTPUT_LIMIT {
        text.pop();
    }
    text
}

/// Run each argv in order with `Command::new(argv[0]).args(&argv[1..])`,
/// stopping at the first non-zero exit. One clock for the whole list.
///
/// Returns the last exit code and the output so far; `refused` is `timeout`
/// when the clock ran out, and the child that was running is killed.
pub fn run_steps(
    steps: &[Vec<String>],
    timeout: Duration,
) -> (Option<i32>, String, Option<&'static str>) {
    let deadline = Instant::now() + timeout;
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    let mut code = 0;
    for argv in steps {
        let mut command = std::process::Command::new(&argv[0]);
        command
            .args(&argv[1..])
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            command.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
        }
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(err) => {
                let line = format!("{}: {}\n", argv[0], err);
                stderr.extend_from_slice(line.as_bytes());
                return (Some(127), bounded_output(&stdout, &stderr), None);
            }
        };
        // Both pipes drained on their own threads: a child that fills one
        // while this thread waits on the other would block forever.
        let out_reader = drain(child.stdout.take());
        let err_reader = drain(child.stderr.take());
        let status = loop {
            match child.try_wait() {
                Ok(Some(status)) => break Some(status),
                Ok(None) if Instant::now() < deadline => {
                    std::thread::sleep(Duration::from_millis(50));
                }
                Ok(None) => {
                    let _ = child.kill();
                    let _ = child.wait();
                    break None;
                }
                Err(_) => break None,
            }
        };
        stdout.extend(out_reader.join().unwrap_or_default());
        stderr.extend(err_reader.join().unwrap_or_default());
        let Some(status) = status else {
            return (None, bounded_output(&stdout, &stderr), Some("timeout"));
        };
        // A process ended by a signal has no code; -1 says so without
        // passing for a clean exit.
        code = status.code().unwrap_or(-1);
        if code != 0 {
            break;
        }
    }
    (Some(code), bounded_output(&stdout, &stderr), None)
}

fn drain<R: Read + Send + 'static>(pipe: Option<R>) -> std::thread::JoinHandle<Vec<u8>> {
    std::thread::spawn(move || {
        let mut bytes = Vec::new();
        if let Some(mut pipe) = pipe {
            let _ = pipe.read_to_end(&mut bytes);
        }
        bytes
    })
}

/// Decide and run one job. The order is the contract's: `already_ran`, then
/// `expired` by this machine's clock, then `unknown_tool`, `wrong_platform`,
/// `bad_params`; only then is the id written to the ledger and the argv run.
pub fn execute(job: &Job, ledger: &mut Ledger, now: i64) -> JobResult {
    if ledger.contains(&job.id) {
        return JobResult::refused(&job.id, "already_ran", now);
    }
    if job.expires_at <= now {
        return JobResult::refused(&job.id, "expired", now);
    }
    let Some(tool) = CATALOG.get(&job.tool_id) else {
        return JobResult::refused(&job.id, "unknown_tool", now);
    };
    // The catalog decides who a tool runs as; the row's copy is checked
    // against it rather than trusted.
    if RunAs::parse(&job.run_as) != Some(tool.run_as) {
        return JobResult::refused(&job.id, "bad_params", now);
    }
    let active_user = crate::platform::get_active_username();
    let steps = match argv_for(tool, &job.params, platform(), Some(&active_user)) {
        Ok(steps) => steps,
        Err(why) => return JobResult::refused(&job.id, why, now),
    };
    if let Err(err) = ledger.record(&job.id) {
        // Without the ledger a restart could run this job again. Refusing it
        // is the safe answer; the operator can request it again.
        log::error!("[tools] Cannot write the job ledger, refusing {}: {}", job.id, err);
        return JobResult::refused(&job.id, "already_ran", now);
    }
    let timeout = Duration::from_secs(tool.timeout_s.min(job.timeout_s.max(1)));
    log::info!("[tools] Running {} ({}) as {}", job.id, tool.id, tool.run_as.as_str());
    let started_at = now;
    let (exit_code, output, refused) = match tool.run_as {
        RunAs::System => run_steps(&steps, timeout),
        RunAs::ActiveUser => run_as_active_user(tool, &steps, &active_user, timeout),
    };
    JobResult {
        id: job.id.clone(),
        started_at,
        finished_at: hbb_common::get_time() / 1000,
        exit_code,
        output,
        refused,
    }
}

/// Linux: the two `active_user` entries are `loginctl` commands aimed at the
/// seat0 user's sessions, and only root may aim `loginctl` at another user's
/// session (polkit's `org.freedesktop.login1.*` actions), so they run here in
/// the daemon with `{active_user}` already filled in. This is a correction to
/// section 1 of the phase 1 contracts, which named `run_as_user` for Linux;
/// through `sudo -u <user>` both commands are refused by polkit.
#[cfg(target_os = "linux")]
fn run_as_active_user(
    _tool: &Tool,
    steps: &[Vec<String>],
    active_user: &str,
    timeout: Duration,
) -> (Option<i32>, String, Option<&'static str>) {
    if active_user.is_empty() {
        return (None, String::new(), Some("no_active_user"));
    }
    run_steps(steps, timeout)
}

/// Windows and macOS: launched in the logged-in user's session through the
/// arm `crate::platform::run_as_user` already uses for `--server`, as
/// `labdesk --labdesk-tool <id>`, which is `run_here` below. The command line
/// carries the id and nothing else, which is why an `active_user` entry may
/// not take parameters.
#[cfg(not(target_os = "linux"))]
fn run_as_active_user(
    tool: &Tool,
    _steps: &[Vec<String>],
    active_user: &str,
    timeout: Duration,
) -> (Option<i32>, String, Option<&'static str>) {
    if active_user.is_empty() {
        return (None, String::new(), Some("no_active_user"));
    }
    match crate::platform::run_as_user(vec!["--labdesk-tool", &tool.id]) {
        Err(err) => (Some(127), format!("{}\n", err), None),
        // macOS hands back the `launchctl asuser` child, whose exit status is
        // the tool's.
        Ok(Some(mut child)) => {
            let deadline = Instant::now() + timeout;
            loop {
                match child.try_wait() {
                    Ok(Some(status)) => {
                        return (Some(status.code().unwrap_or(-1)), String::new(), None)
                    }
                    Ok(None) if Instant::now() < deadline => {
                        std::thread::sleep(Duration::from_millis(50))
                    }
                    Ok(None) => {
                        let _ = child.kill();
                        return (None, String::new(), Some("timeout"));
                    }
                    Err(err) => return (Some(-1), format!("{}\n", err), None),
                }
            }
        }
        // Windows launches through `LaunchProcessWin` and hands back no
        // handle, so the exit status is not observed. The output says so
        // rather than leaving a 0 to read as a clean exit it never saw.
        Ok(None) => (
            Some(0),
            format!(
                "launched {} in the console session of {}; the exit status is not observed on Windows\n",
                tool.id, active_user
            ),
            None,
        ),
    }
}

/// `labdesk --labdesk-tool <id>`: run one `active_user` entry in this
/// process's own session and exit with its status. Anyone may run it, and it
/// runs as whoever ran it, which is no more than they could do at a prompt.
pub fn run_here(tool_id: &str) -> i32 {
    let Some(tool) = CATALOG.get(tool_id) else {
        println!("unknown tool");
        return 2;
    };
    if tool.run_as != RunAs::ActiveUser {
        println!("not an active_user tool");
        return 2;
    }
    let steps = match argv_for(tool, &serde_json::Map::new(), platform(), None) {
        Ok(steps) => steps,
        Err(why) => {
            println!("{}", why);
            return 2;
        }
    };
    let (code, output, refused) = run_steps(&steps, Duration::from_secs(tool.timeout_s));
    print!("{}", output);
    if let Some(why) = refused {
        println!("{}", why);
        return 2;
    }
    code.unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params(pairs: &[(&str, serde_json::Value)]) -> serde_json::Map<String, serde_json::Value> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_owned(), v.clone()))
            .collect()
    }

    fn catalog() -> Catalog {
        Catalog::parse(CATALOG_JSON).expect("the compiled catalog parses")
    }

    /// The compiled file, entry by entry against the contract's table, so a
    /// hand edit to `tools.json` that drifts from the Worker's copy fails here
    /// before `cmp` fails in the critic's hands.
    #[test]
    fn the_compiled_catalog_is_the_contract_table() {
        let c = catalog();
        let ids: Vec<&str> = c.tools().iter().map(|t| t.id.as_str()).collect();
        assert_eq!(
            ids,
            [
                "service_start",
                "service_stop",
                "service_restart",
                "process_kill",
                "power_restart",
                "power_shutdown",
                "power_logoff",
                "power_lock",
                "flush_dns",
            ]
        );
        for t in c.tools() {
            let timeout = if t.id.starts_with("service_") { 60 } else { 30 };
            assert_eq!(t.timeout_s, timeout, "{}", t.id);
            assert_eq!(t.platforms().collect::<Vec<_>>(), ["linux", "macos", "windows"], "{}", t.id);
            let expected = if t.id.starts_with("power_lo") { RunAs::ActiveUser } else { RunAs::System };
            assert_eq!(t.run_as, expected, "{}", t.id);
        }
        assert_eq!(c.get("process_kill").unwrap().label, "End a process");
        assert_eq!(c.get("service_restart").unwrap().param_names().collect::<Vec<_>>(), ["unit"]);
        assert_eq!(c.get("process_kill").unwrap().param_names().collect::<Vec<_>>(), ["pid"]);
        assert_eq!(c.get("flush_dns").unwrap().param_names().count(), 0);
        // Byte for byte what the daemon will run, on the entries with more
        // than one step and on the one with an agent-filled token.
        assert_eq!(
            argv_for(c.get("service_restart").unwrap(), &params(&[("unit", "spooler".into())]), "windows", None).unwrap(),
            [vec!["sc.exe", "stop", "spooler"], vec!["sc.exe", "start", "spooler"]]
        );
        assert_eq!(
            argv_for(c.get("flush_dns").unwrap(), &params(&[]), "macos", None).unwrap(),
            [vec!["dscacheutil", "-flushcache"], vec!["killall", "-HUP", "mDNSResponder"]]
        );
        assert_eq!(
            argv_for(c.get("power_logoff").unwrap(), &params(&[]), "linux", Some("dan")).unwrap(),
            [vec!["loginctl", "terminate-user", "dan"]]
        );
        assert_eq!(
            argv_for(c.get("power_logoff").unwrap(), &params(&[]), "linux", Some("")),
            Err("no_active_user")
        );
        assert_eq!(
            argv_for(c.get("power_logoff").unwrap(), &params(&[]), "linux", None),
            Err("no_active_user")
        );
    }

    /// THE RULE THE CATALOG EXISTS FOR: a parameter is a whole argument or it
    /// is refused, so no value ever becomes part of a command a shell or a
    /// program could read as more than one thing.
    #[test]
    fn a_parameter_that_carries_an_injection_shape_is_refused() {
        let c = catalog();
        let restart = c.get("service_restart").unwrap();
        for bad in [
            "spooler; rm -rf /",
            "spooler && shutdown",
            "spooler|cat",
            "$(id)",
            "`id`",
            "spooler\n/bin/sh",
            "sp ooler",
            "../../etc/passwd",
            "C:\\Windows\\x",
            "spooler\"",
            "",
            "-",
            "--force",
            "-x",
        ] {
            let p = params(&[("unit", bad.into())]);
            assert_eq!(argv_for(restart, &p, "linux", None), Err("bad_params"), "{:?}", bad);
        }
        // A unit name that is 129 characters is refused; 128 is accepted.
        assert!(argv_for(restart, &params(&[("unit", "a".repeat(128).into())]), "linux", None).is_ok());
        assert_eq!(
            argv_for(restart, &params(&[("unit", "a".repeat(129).into())]), "linux", None),
            Err("bad_params")
        );
        // The whole `_safeTarget` class less the two path characters.
        assert!(argv_for(restart, &params(&[("unit", "ssh.service@2:x+y_-Z".into())]), "linux", None).is_ok());
        // A number where a string is wanted, and a string where a number is.
        assert_eq!(argv_for(restart, &params(&[("unit", 7.into())]), "linux", None), Err("bad_params"));
        let kill = c.get("process_kill").unwrap();
        assert_eq!(argv_for(kill, &params(&[("pid", "12".into())]), "linux", None), Err("bad_params"));
        assert_eq!(argv_for(kill, &params(&[("pid", 0.into())]), "linux", None), Err("bad_params"));
        assert_eq!(argv_for(kill, &params(&[("pid", 4194305.into())]), "linux", None), Err("bad_params"));
        assert_eq!(argv_for(kill, &params(&[("pid", (-9).into())]), "linux", None), Err("bad_params"));
        assert_eq!(argv_for(kill, &params(&[("pid", 1.5.into())]), "linux", None), Err("bad_params"));
        assert_eq!(
            argv_for(kill, &params(&[("pid", 4194304.into())]), "windows", None).unwrap(),
            [vec!["taskkill.exe", "/PID", "4194304", "/F"]]
        );
        // A missing parameter, and an extra one, are both refused.
        assert_eq!(argv_for(restart, &params(&[]), "linux", None), Err("bad_params"));
        assert_eq!(
            argv_for(restart, &params(&[("unit", "spooler".into()), ("extra", "x".into())]), "linux", None),
            Err("bad_params")
        );
        // The user the agent appends on Linux is never a parameter.
        assert_eq!(
            argv_for(c.get("power_logoff").unwrap(), &params(&[("user", "root".into())]), "linux", Some("dan")),
            Err("bad_params")
        );
        // And is appended nowhere else: the lock entry and the other platforms
        // carry exactly their catalog argv.
        assert_eq!(
            argv_for(c.get("power_lock").unwrap(), &params(&[]), "linux", Some("dan")).unwrap(),
            [vec!["loginctl", "lock-sessions"]]
        );
        assert_eq!(
            argv_for(c.get("power_logoff").unwrap(), &params(&[]), "windows", Some("dan")).unwrap(),
            [vec!["shutdown.exe", "/l"]]
        );
        // A platform the entry does not name.
        assert_eq!(argv_for(restart, &params(&[("unit", "spooler".into())]), "freebsd", None), Err("wrong_platform"));
    }

    /// Every step is an argv and every argv is a vector: nothing here is ever
    /// joined into a command line.
    #[test]
    fn argv_is_always_a_vec_and_never_a_line() {
        let c = catalog();
        for t in c.tools() {
            for platform in t.platforms() {
                let p = match t.id.as_str() {
                    "process_kill" => params(&[("pid", 42.into())]),
                    id if id.starts_with("service_") => params(&[("unit", "x".into())]),
                    _ => params(&[]),
                };
                let steps = argv_for(t, &p, platform, Some("dan")).unwrap();
                assert!(!steps.is_empty());
                for argv in steps {
                    assert!(!argv.is_empty());
                    assert!(!argv[0].contains(' '), "{}: {:?}", t.id, argv);
                    // No shell anywhere in the catalog.
                    for shell in ["sh", "bash", "cmd", "cmd.exe", "powershell", "powershell.exe", "pwsh"] {
                        assert_ne!(argv[0], shell, "{}", t.id);
                    }
                    assert!(!argv.iter().any(|a| a == "-c" || a == "/c" || a == "-Command"), "{}: {:?}", t.id, argv);
                    assert!(!argv.iter().any(|a| a.contains('{')), "{}: an unfilled token in {:?}", t.id, argv);
                }
            }
        }
    }

    #[test]
    fn a_catalog_outside_the_rules_does_not_parse() {
        let base = |id: &str, run_as: &str, timeout: u64, params: &str, platforms: &str| {
            format!(
                r#"{{"version":1,"tools":[{{"id":"{id}","label":"x","runAs":"{run_as}","timeoutS":{timeout},"params":{params},"platforms":{platforms}}}]}}"#
            )
        };
        let lin = r#"{"linux":{"steps":[["true"]]}}"#;
        assert!(Catalog::parse(&base("ok_tool", "system", 60, "{}", lin)).is_ok());
        for (why, json) in [
            ("version", base("ok_tool", "system", 60, "{}", lin).replace("\"version\":1", "\"version\":2")),
            ("id case", base("OkTool", "system", 60, "{}", lin)),
            ("id short", base("a", "system", 60, "{}", lin)),
            ("id long", base(&"a".repeat(65), "system", 60, "{}", lin)),
            ("run_as", base("ok_tool", "root", 60, "{}", lin)),
            ("timeout 0", base("ok_tool", "system", 0, "{}", lin)),
            ("timeout 3601", base("ok_tool", "system", 3601, "{}", lin)),
            ("no platform", base("ok_tool", "system", 60, "{}", "{}")),
            ("bad platform", base("ok_tool", "system", 60, "{}", r#"{"freebsd":{"steps":[["true"]]}}"#)),
            ("no steps", base("ok_tool", "system", 60, "{}", r#"{"linux":{"steps":[]}}"#)),
            ("empty argv", base("ok_tool", "system", 60, "{}", r#"{"linux":{"steps":[[]]}}"#)),
            ("token inside text", base("ok_tool", "system", 60, r#"{"unit":{"type":"pattern","pattern":"^[a-z]{1,8}$"}}"#, r#"{"linux":{"steps":[["systemctl","restart","{unit}.service"]]}}"#)),
            ("unlisted param", base("ok_tool", "system", 60, "{}", r#"{"linux":{"steps":[["systemctl","restart","{unit}"]]}}"#)),
            ("active_user tool with a param", base("ok_tool", "active_user", 60, r#"{"unit":{"type":"pattern","pattern":"^[a-z]{1,8}$"}}"#, lin)),
            ("pattern not anchored", base("ok_tool", "system", 60, r#"{"unit":{"type":"pattern","pattern":"[a-z]{1,8}"}}"#, lin)),
            ("pattern with alternation", base("ok_tool", "system", 60, r#"{"unit":{"type":"pattern","pattern":"^(a|b){1,8}$"}}"#, lin)),
            ("pattern zero length", base("ok_tool", "system", 60, r#"{"unit":{"type":"pattern","pattern":"^[a-z]{0,8}$"}}"#, lin)),
            ("fourth type", base("ok_tool", "system", 60, r#"{"unit":{"type":"regex","pattern":"^[a-z]{1,8}$"}}"#, lin)),
            ("empty enum", base("ok_tool", "system", 60, r#"{"mode":{"type":"enum","values":[]}}"#, lin)),
            ("empty int range", base("ok_tool", "system", 60, r#"{"n":{"type":"int","min":5,"max":4}}"#, lin)),
            ("duplicate id", r#"{"version":1,"tools":[{"id":"ok_tool","label":"x","runAs":"system","timeoutS":60,"params":{},"platforms":{"linux":{"steps":[["true"]]}}},{"id":"ok_tool","label":"y","runAs":"system","timeoutS":60,"params":{},"platforms":{"linux":{"steps":[["true"]]}}}]}"#.to_owned()),
        ] {
            assert!(Catalog::parse(&json).is_err(), "{} should be refused", why);
        }
    }

    #[test]
    fn the_pattern_subset_reads_the_contract_class() {
        let class = CharClass::parse("^[A-Za-z0-9._@:+-]{1,128}$").unwrap();
        assert_eq!(class.min, 1);
        assert_eq!(class.max, 128);
        assert!(class.accepts("spooler"));
        assert!(class.accepts("ssh.service"));
        assert!(class.accepts("a-b"));
        assert!(!class.accepts("a/b"));
        assert!(!class.accepts("a\\b"));
        assert!(!class.accepts("a b"));
        assert!(!class.accepts(""));
        // Length is counted in characters, and a non-ASCII character is not
        // in the class whatever its byte length.
        assert!(!class.accepts("spo\u{f6}ler"));
        let escaped = CharClass::parse("^[a\\-z]{1,2}$").unwrap();
        assert!(escaped.accepts("-"));
        assert!(!escaped.accepts("b"));
        let enum_and_int = Catalog::parse(
            r#"{"version":1,"tools":[{"id":"t_e","label":"x","runAs":"system","timeoutS":5,"params":{"mode":{"type":"enum","values":["fast","slow","-v"]},"n":{"type":"int","min":-2,"max":2}},"platforms":{"linux":{"steps":[["echo","{mode}","{n}"]]}}}]}"#,
        )
        .unwrap();
        let t = enum_and_int.get("t_e").unwrap();
        assert_eq!(
            argv_for(t, &params(&[("mode", "fast".into()), ("n", 2.into())]), "linux", None).unwrap(),
            [vec!["echo", "fast", "2"]]
        );
        assert_eq!(argv_for(t, &params(&[("mode", "medium".into()), ("n", 0.into())]), "linux", None), Err("bad_params"));
        assert_eq!(argv_for(t, &params(&[("mode", "fast".into()), ("n", 3.into())]), "linux", None), Err("bad_params"));
        // A value that would reach a program as an option is refused whatever
        // its type, even when the catalog's own enum or range admits it.
        assert_eq!(argv_for(t, &params(&[("mode", "-v".into()), ("n", 0.into())]), "linux", None), Err("bad_params"));
        assert_eq!(argv_for(t, &params(&[("mode", "fast".into()), ("n", (-2).into())]), "linux", None), Err("bad_params"));
    }

    #[test]
    fn the_batch_answer_is_read_by_name_and_unknown_members_are_ignored() {
        let (jobs, now) = jobs_in(
            r#"{"ok":true,"sampleSeconds":60,"flushSeconds":300,"jobs":[
                {"id":"2f1c","toolId":"service_restart","params":{"unit":"spooler"},"runAs":"system","timeoutS":60,"expiresAt":1788483600},
                {"id":"broken"},
                {"id":"3a","toolId":"flush_dns","runAs":"system","timeoutS":60,"expiresAt":1788483600},
                {"id":"4b","toolId":"process_kill","params":"{\"pid\":42}","runAs":"system","timeoutS":30,"expiresAt":1788483600}
            ],"tickets":[],"collectNow":true,"later":{"x":1}}"#,
        );
        assert_eq!(jobs.len(), 3, "the mis-shaped entry is skipped, the rest run");
        assert_eq!(jobs[0].id, "2f1c");
        assert_eq!(jobs[0].tool_id, "service_restart");
        assert_eq!(jobs[0].params, params(&[("unit", "spooler".into())]));
        assert_eq!(jobs[0].expires_at, 1788483600);
        assert_eq!(jobs[1].params, params(&[]), "params absent is params empty");
        assert_eq!(jobs[2].params, params(&[("pid", 42.into())]), "the column's JSON text is read too");
        assert!(now);
        // The answer the server sends today: no member at all.
        assert_eq!(jobs_in(r#"{"ok":true,"sampleSeconds":60,"flushSeconds":300}"#), (Vec::new(), false));
        assert_eq!(jobs_in("not json"), (Vec::new(), false));
        assert_eq!(jobs_in(r#"{"jobs":[],"collectNow":"true"}"#).1, false, "only the boolean true");
    }

    #[test]
    fn the_result_carries_the_hash_of_the_cut_output() {
        let r = JobResult {
            id: "j".into(),
            started_at: 1,
            finished_at: 2,
            exit_code: Some(0),
            output: "hello\n".into(),
            refused: None,
        };
        let v = r.to_json();
        assert_eq!(v["id"], "j");
        assert_eq!(v["exitCode"], 0);
        assert_eq!(v["refused"], serde_json::Value::Null);
        assert_eq!(
            v["outputSha256"],
            "5891b5b522d5df086d0ff0b110fbd9d21bb4fc7163af34d08286a2e846f6be03"
        );
        let refused = JobResult::refused("k", "expired", 5).to_json();
        assert_eq!(refused["exitCode"], serde_json::Value::Null);
        assert_eq!(refused["refused"], "expired");
        assert_eq!(refused["startedAt"], 5);
        assert_eq!(refused["finishedAt"], 5);

        // The bound: exactly OUTPUT_LIMIT bytes survive, on a character
        // boundary, stdout first.
        let long = bounded_output(&vec![b'a'; OUTPUT_LIMIT - 1], &"\u{e9}\u{e9}".as_bytes().to_vec());
        assert_eq!(long.len(), OUTPUT_LIMIT - 1, "a character that does not fit is dropped whole");
        assert!(long.ends_with('a'));
        let exact = bounded_output(&vec![b'a'; OUTPUT_LIMIT], b"tail");
        assert_eq!(exact.len(), OUTPUT_LIMIT);
        assert!(!exact.contains("tail"));
        assert_eq!(bounded_output(b"out", b"err"), "outerr");
    }

    #[test]
    fn the_ledger_refuses_a_second_run_and_survives_a_reload() {
        let dir = std::env::temp_dir().join(format!("labdesk-ledger-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("agent-jobs.json");
        let mut ledger = Ledger::load(path.clone());
        assert!(!ledger.contains("a"));
        ledger.record("a").unwrap();
        assert!(ledger.contains("a"));
        // A fresh handle on the same file, which is what a daemon restart is.
        let reloaded = Ledger::load(path.clone());
        assert!(reloaded.contains("a"));
        assert!(!reloaded.contains("b"));
        // Bounded: the 257th id pushes the first one out.
        let mut ledger = reloaded;
        for n in 0..LEDGER_SIZE {
            ledger.record(&format!("id-{}", n)).unwrap();
        }
        assert!(!ledger.contains("a"));
        assert!(ledger.contains("id-0"));
        assert!(ledger.contains(&format!("id-{}", LEDGER_SIZE - 1)));
        let reloaded = Ledger::load(path.clone());
        assert_eq!(reloaded.ids.len(), LEDGER_SIZE);
        // An unreadable ledger is an empty one, not a panic.
        std::fs::write(&path, "not json").unwrap();
        assert!(!Ledger::load(path.clone()).contains("id-0"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn steps_run_in_order_stop_at_the_first_failure_and_time_out() {
        let steps = |list: &[&[&str]]| -> Vec<Vec<String>> {
            list.iter().map(|argv| argv.iter().map(|s| s.to_string()).collect()).collect()
        };
        let (code, out, refused) = run_steps(&steps(&[&["echo", "one"], &["echo", "two"]]), Duration::from_secs(10));
        assert_eq!((code, refused), (Some(0), None));
        assert_eq!(out, "one\ntwo\n");

        let (code, out, refused) = run_steps(&steps(&[&["echo", "one"], &["false"], &["echo", "three"]]), Duration::from_secs(10));
        assert_eq!((code, refused), (Some(1), None));
        assert_eq!(out, "one\n", "the step after the failure never ran");

        let (code, out, refused) = run_steps(&steps(&[&["sleep", "30"]]), Duration::from_millis(300));
        assert_eq!((code, refused), (None, Some("timeout")));
        assert_eq!(out, "");

        let (code, out, refused) = run_steps(&steps(&[&["/nonexistent/program"]]), Duration::from_secs(1));
        assert_eq!((code, refused), (Some(127), None));
        assert!(out.starts_with("/nonexistent/program: "));

        // An argument is passed as one argument whatever it contains.
        let (code, out, _) = run_steps(&steps(&[&["printf", "%s|", "a b", "$(id)", ";ls"]]), Duration::from_secs(5));
        assert_eq!(code, Some(0));
        assert_eq!(out, "a b|$(id)|;ls|");
    }
}
