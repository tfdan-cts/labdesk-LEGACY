// The always-on telemetry collector.
//
// This runs in the `--service` daemon and nowhere else. That placement is the whole point:
// on Linux `--server` is launched through `run_as_user` as the desktop user
// (src/platform/linux.rs:713-717) while `res/labdesk.service` runs `--service` as root,
// and on macOS `_service.plist` is installed under /Library/LaunchDaemons against
// `_server.plist` under /Library/LaunchAgents (src/platform/macos.rs:190-195, :339-343).
// On Windows `sc create ... binpath= "{exe} --service"` carries no `obj=`, so the service
// is LocalSystem. Only `--service` is root/SYSTEM on all three, and a collector in the
// user process could neither read disk health nor keep running while nobody is logged in.
//
// The loop itself is deliberately small. It samples on a tick, writes one line per sample
// to the spool, and flushes the spool on a slower tick. Every decision worth getting wrong
// -- the hard cap, what a batch carries, what a status code means for the history on disk,
// how long to wait after a failure -- lives in `super::spool` as a pure function with
// tests. What is left here is the plumbing those functions are wired into.

use super::disk::{self, DiskHealth};
use super::identity::{uplink_signed_msg, AgentIdentity};
use super::selfheal::{self, Reachability};
use super::spool::{
    ack_for, backoff_seconds, batch_window, flush_jitter_seconds, Ack, Spool, MAX_BATCH_BYTES,
    MAX_BATCH_LINES, MAX_BODY_BYTES,
};
use super::tools::{self, JobResult};
use super::{netview, ticket};
use hbb_common::{
    bail,
    config::Config,
    log,
    sysinfo::{Disks, Networks, System},
    tokio::time::{sleep, Instant},
    ResultType,
};
use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const SPOOL_FILE: &str = "agent-spool.jsonl";
const BATCH_PATH: &str = "/agent/batch";
/// The catalog's word for this machine's kind, and a wire contract: the server
/// stores it on the `machine` row and every tool entry is keyed by it, so a
/// machine that never says which one it is can never be given a job
/// (labdesk-site/src/worker/tool-catalog.ts, `PLATFORMS`).
#[cfg(target_os = "windows")]
const PLATFORM: &str = "windows";
#[cfg(target_os = "macos")]
const PLATFORM: &str = "macos";
#[cfg(target_os = "linux")]
const PLATFORM: &str = "linux";
#[cfg(not(any(target_os = "windows", target_os = "macos", target_os = "linux")))]
const PLATFORM: &str = "";
/// How often an un-enrolled daemon looks again. `labdesk --enrol` runs in a separate
/// process and writes the machine id into the identity file, so the only way this one
/// learns about it is to re-read the file.
// Local identity reads only. Newly enrolled machines must start their inbox
// inside the console's 30-second session preparation deadline.
const ENROLMENT_POLL: Duration = Duration::from_secs(5);
const UPLINK_TIMEOUT: Duration = Duration::from_secs(20);
/// The slow cadence, section 4.2: disk health once an hour.
///
/// Not server controlled, unlike the two metric cadences. A SMART sweep is the only thing
/// this daemon does that touches a device, and a knob the server could turn down to a
/// second would let a compromised console hammer every drive in a fleet.
const DISK_INTERVAL: Duration = Duration::from_secs(3600);
/// And section 4.2's parenthesis: once, 60 s after start, rather than at the top of the
/// first hour. A machine that has just been enrolled reports its drives while the
/// administrator who enrolled it is still looking at the console.
const DISK_FIRST: Duration = Duration::from_secs(60);
/// Ticket delivery and claim reporting are independent of telemetry's 300 s cadence.
/// ponytail: 17,280 idle requests/device/day; a push channel replaces polling if fleet scale requires it.
const TICKET_POLL: Duration = Duration::from_secs(5);

/// Start the collector on its own thread with its own runtime.
///
/// `Builder::new().spawn` rather than `thread::spawn`: the latter panics when a thread
/// cannot be created, and that panic would unwind out of `start_os_service` and take the
/// whole service down. Losing telemetry must never cost the machine its remote access.
pub fn start() {
    if let Err(err) = std::thread::Builder::new()
        .name("labdesk-collector".to_owned())
        .spawn(|| {
            let runtime = match hbb_common::tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(err) => {
                    log::error!("[collector] Failed to build the runtime: {}", err);
                    return;
                }
            };
            runtime.block_on(run());
        })
    {
        log::warn!("[collector] Failed to spawn the collector thread: {}", err);
    }
}

async fn run() {
    let mut identity = match wait_for_enrolment().await {
        Some(identity) => identity,
        None => return,
    };
    start_ticket_inbox();
    let spool = Spool::new(Config::path(SPOOL_FILE));
    let mut sampler = Sampler::new();
    let mut sample_seconds = identity.sample_seconds();

    // The offset is why five hundred agents installed from one image do not all arrive in
    // the same second. It delays the first flush only; every later one follows the cadence.
    let jitter = flush_jitter_seconds(identity.machine_id(), identity.flush_seconds());
    let mut next_sample = Instant::now() + Duration::from_secs(sample_seconds);
    let mut next_flush = Instant::now() + Duration::from_secs(jitter);
    let mut next_disks = Instant::now() + DISK_FIRST;
    // The last disk sweep that no server has acknowledged yet. Held rather than spooled
    // because it is a snapshot of the drives as they are now, not a history: a machine off
    // the network for a day owes the server its current disks, not yesterday's twenty four
    // readings. Cleared only on 2xx, for the same reason the spool is.
    //
    // `None` is "no sweep has finished since the last one was taken away". An EMPTY sweep
    // is not that: it is the reading that says this machine was asked and no drive
    // answered, which is what every macOS machine reports, what a Linux agent that lost
    // its privilege reports, and what a machine whose drives were pulled reports. The
    // ingest stores it as `unreadable`, so it clears a verdict that would otherwise stand
    // forever behind a drive nobody can see any more.
    let mut disks: Option<Vec<DiskHealth>> = None;
    // Results of jobs the server handed this machine, waiting for a batch to
    // ride on. Filled by the job thread (`run_jobs`), drained here only once
    // a batch that carried them is accepted.
    let results: Arc<Mutex<Vec<JobResult>>> = Default::default();
    // The two network attributes and what the server last acknowledged.
    let mut attrs = Attrs::default();
    // The collector's own probe, used only while self-healing is off.
    let mut own_probe = Reachability::default();
    let mut failures = 0u32;
    log::info!(
        "[collector] Started: sampling every {}s, flushing every {}s offset by {}s",
        sample_seconds,
        identity.flush_seconds(),
        jitter
    );

    loop {
        let deadline = next_sample.min(next_flush).min(next_disks);
        let now = Instant::now();
        if deadline > now {
            sleep(deadline - now).await;
        }

        let now = Instant::now();
        if now >= next_sample {
            next_sample = now + Duration::from_secs(sample_seconds);
            if let Err(err) = spool.append(&sampler.sample()) {
                log::warn!("[collector] Failed to spool a sample: {}", err);
            }
        }

        if now >= next_disks {
            next_disks = now + DISK_INTERVAL;
            // Blocking, on this daemon's own thread, and the only thing it can delay is
            // this loop's next sample. The newest sweep always replaces the one waiting,
            // empty included: "no drive answered this hour" is a reading about this
            // machine now, and holding the last hour that did answer would report a drive
            // that has since been pulled, lost its privilege or stopped responding.
            let read = disk::gather();
            log::info!("[collector] Read health for {} disk(s)", read.len());
            disks = Some(read);
            // Section 6 of the phase 1 contracts: while self-healing is off the
            // collector probes on this cadence so the verdict exists on every
            // machine; while it is on, the healer's tick is the source.
            if selfheal::status().step.is_none() {
                own_probe = Reachability {
                    internet: Some(selfheal::probe_internet()),
                    at: hbb_common::get_time() / 1000,
                    step: None,
                };
            }
        }

        if now >= next_flush {
            let reach = match selfheal::status() {
                on if on.step.is_some() => on,
                _ => own_probe,
            };
            let pending = attrs.pending(
                hbb_common::get_time() / 1000,
                netview::adapters(&sampler.networks).as_deref(),
                reach,
            );
            let mut collect_now = false;
            match flush(
                &mut identity,
                &spool,
                &sampler,
                sample_seconds,
                disks.as_deref(),
                &results,
                &pending,
            )
            .await
            {
                // Only an accepted batch carried the disks away with it. `Ok(None)` is
                // "nothing was owed", which means no request was made at all.
                Ok(Some(Flushed { ack: Ack::Accepted, text, included })) => {
                    failures = 0;
                    disks = None;
                    results.lock().unwrap().drain(..included.results);
                    if included.attrs {
                        attrs.sent(&pending, reach, hbb_common::get_time() / 1000);
                    }
                    let (jobs, now_please) = tools::jobs_in(&text);
                    if !jobs.is_empty() {
                        log::info!("[collector] The server handed this machine {} job(s)", jobs.len());
                        run_jobs(jobs, results.clone());
                    }
                    collect_now = now_please;
                    for t in ticket::tickets_in(&text) {
                        match ticket::deliver(&t).await {
                            Ok(()) => {
                                log::info!("[collector] Delivered connect ticket {}", t.id);
                                acknowledge_ticket_ready(&identity, &t.id).await;
                            }
                            Err(err) => {
                                log::warn!("[collector] Ticket {} not delivered: {}", t.id, err)
                            }
                        }
                    }
                }
                Ok(None) => failures = 0,
                Ok(Some(Flushed { ack: Ack::Revoked, .. })) => {
                    // The org has revoked this machine. Stop collecting and take the
                    // history with us: what is on that disk is inventory about a customer
                    // who has said they are no longer a customer.
                    log::info!("[collector] This machine is revoked; deleting the spool");
                    if let Err(err) = spool.clear() {
                        log::warn!("[collector] Failed to delete the spool: {}", err);
                    }
                    return;
                }
                Ok(Some(Flushed { ack: Ack::Retry, .. })) => failures = failures.saturating_add(1),
                Err(err) => {
                    log::warn!("[collector] Uplink failed: {}", err);
                    failures = failures.saturating_add(1);
                }
            }
            // Both cadences are server controlled and an accepted batch may have just
            // moved them. Reading them back here rather than caching them at start is
            // what lets a fleet already in the field be slowed down without every machine
            // having to be re-enrolled.
            let adopted = identity.sample_seconds();
            if adopted != sample_seconds {
                log::info!(
                    "[collector] The sample cadence moved from {}s to {}s",
                    sample_seconds,
                    adopted
                );
                sample_seconds = adopted;
                next_sample = Instant::now() + Duration::from_secs(sample_seconds);
            }
            let wait = backoff_seconds(identity.flush_seconds(), failures);
            next_flush = Instant::now() + Duration::from_secs(wait);
            // An answer carrying an urgent job asks for the result sooner than
            // the cadence (section 2 of the phase 1 contracts).
            //
            // A SAMPLE TOO, not only a flush. `flush` sends nothing whatever when the
            // spool holds no line (`window.sent == 0` returns `Ok(None)` before the body
            // is built), and ten seconds after a flush has just emptied it, it never
            // does. Measured on homebox-devserver 2026-09-05: an urgent flush_dns exited
            // 0 at 16:27:13 and its result reached the server on the ordinary 300 s tick,
            // so the urgency bought nothing. Sampling first gives the flush a line to
            // carry the result on.
            if collect_now {
                next_sample = Instant::now();
                next_flush = Instant::now() + Duration::from_secs(tools::COLLECT_NOW_SECONDS);
            }
        }
    }
}

/// A SMART read and a telemetry timeout must never hold up session credentials.
fn start_ticket_inbox() {
    if let Err(err) = std::thread::Builder::new()
        .name("labdesk-tickets".to_owned())
        .spawn(|| {
            match hbb_common::tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime.block_on(run_ticket_inbox()),
                Err(err) => log::error!("[ticket] Failed to build the runtime: {}", err),
            }
        })
    {
        log::warn!("[ticket] Failed to spawn the inbox thread: {}", err);
    }
}

async fn run_ticket_inbox() {
    let mut failures = 0u32;
    let mut claims = BTreeMap::new();
    let mut machine_id = String::new();
    loop {
        let identity = match AgentIdentity::load_existing() {
            Ok(Some(identity)) if !identity.machine_id().is_empty() => identity,
            _ => {
                sleep(ENROLMENT_POLL).await;
                continue;
            }
        };
        if machine_id != identity.machine_id() {
            machine_id = identity.machine_id().to_owned();
            claims.clear();
        }
        // A backlog of failed claim reports must not consume the new session's
        // preparation deadline. Canceled reports remain in `claims` for retry.
        hbb_common::tokio::time::timeout(
            TICKET_POLL,
            report_claimed_tickets(&identity, &mut claims),
        )
        .await
        .ok();
        match request_signed(&identity, "GET", "/agent/tickets", "").await {
            Ok((status, text)) if (200..300).contains(&status) => {
                failures = 0;
                for t in ticket::tickets_in(&text) {
                    if t.expires_at <= hbb_common::get_time() / 1000 || claims.contains_key(&t.id) {
                        continue;
                    }
                    if ticket::deliver(&t).await.is_ok() {
                        acknowledge_ticket_ready(&identity, &t.id).await;
                    }
                }
            }
            Ok((status, _)) => {
                log::debug!("[ticket] Inbox refused: HTTP {}", status);
                failures = failures.saturating_add(1);
            }
            Err(err) => {
                log::debug!("[ticket] Inbox unavailable: {}", err);
                failures = failures.saturating_add(1);
            }
        }
        // Recovery must fit the controller's 30-second preparation deadline.
        let wait = backoff_seconds(TICKET_POLL.as_secs(), failures).min(10);
        sleep(Duration::from_secs(wait)).await;
    }
}

async fn acknowledge_ticket_ready(identity: &AgentIdentity, id: &str) {
    let path = format!("/agent/ticket/{}/ready", id);
    // Only called after --server has acknowledged insertion. A failed HTTP
    // acknowledgment is retried when the next inbox poll redelivers the ticket.
    if !matches!(post_signed(identity, &path, "{}").await, Ok((200..=299, _))) {
        log::debug!("[ticket] Installation acknowledgment will be retried");
    }
}

/// IPC drains claims once. Keep them until HTTP confirms them, including across
/// temporary network failures; the server's terminal statuses also settle a retry.
async fn report_claimed_tickets(identity: &AgentIdentity, pending: &mut BTreeMap<String, i64>) {
    let now = hbb_common::get_time() / 1000;
    pending.retain(|_, until| *until > now);
    if let Ok(ids) = ticket::claimed().await {
        for id in ids {
            pending.entry(id).or_insert(now + 600);
        }
    }
    for id in pending.keys().cloned().collect::<Vec<_>>() {
        let path = format!("/agent/ticket/{}/claimed", id);
        match post_signed(identity, &path, "{}").await {
            Ok((status, _))
                if (200..300).contains(&status) || [404, 409, 410].contains(&status) =>
            {
                pending.remove(&id);
            }
            _ => log::debug!("[ticket] Claim report will be retried"),
        }
    }
}

lazy_static::lazy_static! {
    /// One job thread at a time, so two answers arriving back to back cannot
    /// race each other on the ledger.
    static ref JOB_LOCK: Mutex<()> = Mutex::new(());
}

/// Run the jobs an answer carried, on a thread of their own so a job that
/// takes its whole timeout does not stop the sampler.
fn run_jobs(jobs: Vec<tools::Job>, results: Arc<Mutex<Vec<JobResult>>>) {
    let spawned = std::thread::Builder::new()
        .name("labdesk-jobs".to_owned())
        .spawn(move || {
            let _one_at_a_time = JOB_LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let mut ledger = tools::Ledger::open();
            for job in jobs {
                let now = hbb_common::get_time() / 1000;
                let result = tools::execute(&job, &mut ledger, now);
                match result.refused {
                    Some(why) => log::info!("[collector] Job {} refused: {}", job.id, why),
                    None => log::info!(
                        "[collector] Job {} ({}) exited {:?}",
                        job.id,
                        job.tool_id,
                        result.exit_code
                    ),
                }
                results.lock().unwrap().push(result);
            }
        });
    if let Err(err) = spawned {
        log::warn!("[collector] Failed to spawn the job thread: {}", err);
    }
}

/// The `attrs` member: what this machine last had acknowledged, and the rule
/// for what goes into the next batch.
///
/// `net.adapters` goes when anything but its byte counters changed, and once
/// an hour otherwise so the counters are refreshed; `net.reachability` goes on
/// every change of verdict or ladder step and once an hour otherwise. Both
/// rules keep the per-uplink attribute write, the single largest uncosted
/// writer in the architecture's arithmetic (section 4.5), to about one row an
/// hour per machine.
#[derive(Default)]
struct Attrs {
    adapters_shape: Option<String>,
    adapters_at: i64,
    reach: Option<(Option<selfheal::Connectivity>, Option<selfheal::Step>)>,
    reach_at: i64,
}

const ATTR_REFRESH: i64 = 3600;

impl Attrs {
    fn pending(
        &self,
        now: i64,
        adapters: Option<&[netview::Adapter]>,
        reach: Reachability,
    ) -> BTreeMap<String, String> {
        let mut out = BTreeMap::new();
        if let Some(adapters) = adapters {
            let value = netview::to_value(adapters);
            let shape = netview::shape_of_value(&value);
            if self.adapters_shape.as_deref() != Some(shape.as_str())
                || now - self.adapters_at >= ATTR_REFRESH
            {
                out.insert("net.adapters".to_owned(), value);
            }
        }
        if self.reach != Some((reach.internet, reach.step)) || now - self.reach_at >= ATTR_REFRESH {
            out.insert("net.reachability".to_owned(), reach.to_value());
        }
        out
    }

    /// The server took `sent`; remember what it now holds.
    fn sent(&mut self, sent: &BTreeMap<String, String>, reach: Reachability, now: i64) {
        if let Some(value) = sent.get("net.adapters") {
            // The shape of what was sent, recomputed from the value so the
            // comparison in `pending` is against the same derivation.
            self.adapters_shape = Some(netview::shape_of_value(value));
            self.adapters_at = now;
        }
        if sent.contains_key("net.reachability") {
            self.reach = Some((reach.internet, reach.step));
            self.reach_at = now;
        }
    }
}

/// What one flush came to, beyond the acknowledgement: the answer text the
/// jobs and tickets are read out of, and which optional members the body
/// actually carried so the caller clears exactly those.
struct Flushed {
    ack: Ack,
    text: String,
    included: Included,
}

/// Which optional members `batch_body_with` fitted into the bound.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
struct Included {
    disks: bool,
    results: usize,
    attrs: bool,
}

/// Load the agent identity, waiting for an administrator to run `--enrol` if need be.
///
/// Returns `None` only when the identity file itself cannot be used, which is a state a
/// retry loop cannot fix and which `AgentIdentity` deliberately refuses to paper over by
/// generating a second key.
async fn wait_for_enrolment() -> Option<AgentIdentity> {
    loop {
        match AgentIdentity::load_or_create() {
            Ok(identity) if !identity.machine_id().is_empty() => return Some(identity),
            Ok(_) => {}
            Err(err) => {
                log::error!("[collector] No usable agent identity: {}", err);
                return None;
            }
        }
        sleep(ENROLMENT_POLL).await;
    }
}

/// One flush attempt. `Ok(None)` means nothing was owed to the server, which is not a
/// failure and must not push the backoff out.
async fn flush(
    identity: &mut AgentIdentity,
    spool: &Spool,
    sampler: &Sampler,
    sample_seconds: u64,
    disks: Option<&[DiskHealth]>,
    results: &Arc<Mutex<Vec<JobResult>>>,
    attrs: &BTreeMap<String, String>,
) -> ResultType<Option<Flushed>> {
    let lines = spool.read()?;
    let window = batch_window(&lines, MAX_BATCH_LINES, MAX_BATCH_BYTES);
    if window.dropped > 0 {
        log::warn!(
            "[collector] Dropping {} spool line(s) too large to ever send",
            window.dropped
        );
    }
    if window.sent == 0 {
        spool.drop_front(window.dropped)?;
        return Ok(None);
    }

    let sent = &lines[window.dropped..window.consumed()];
    // At most four results a batch, oldest first, so results never displace
    // samples; the rest wait for the next one.
    let owed: Vec<JobResult> = results
        .lock()
        .unwrap()
        .iter()
        .take(tools::RESULTS_PER_BATCH)
        .cloned()
        .collect();
    let (body, included) =
        match batch_body_with(sampler.machine(), sent, sample_seconds, disks, &owed, attrs) {
            Ok(body) => body,
        Err(err) => {
            // Nothing in this window can be turned into a batch. Drop it for the same
            // reason an oversized line is dropped: left at the front it would wedge every
            // later sample behind it forever.
            log::warn!(
                "[collector] Discarding {} unusable spool line(s): {}",
                window.sent,
                err
            );
            spool.drop_front(window.consumed())?;
            return Ok(None);
        }
    };
    let (status, text) = post_signed(identity, BATCH_PATH, &body).await?;
    // The body as well as the status: a 403 alone is not proof this machine was revoked,
    // and `ack_for` will not destroy a spool without the server's own words.
    let ack = ack_for(status, &text);
    match ack {
        Ack::Accepted => {
            // Only now. Everything before this point leaves the spool exactly as it was,
            // which is what lets a machine survive a week of failed sends.
            spool.drop_front(window.consumed())?;
            adopt_cadences(identity, &text);
        }
        Ack::Revoked | Ack::Retry => {
            log::warn!("[collector] The server refused the batch: {} {}", status, text);
        }
    }
    Ok(Some(Flushed {
        ack,
        text,
        included,
    }))
}

/// The cadences the server named, as `(sampleSeconds, flushSeconds)`.
///
/// Zero means "not named". Both members are optional in the response and a member the
/// server leaves out must leave the agent on the cadence it already had rather than
/// snapping it back to a default, which is why absence and zero are the same answer here.
fn asked_cadences(text: &str) -> (u64, u64) {
    let Ok(response) = serde_json::from_str::<serde_json::Value>(text) else {
        return (0, 0);
    };
    (
        response["sampleSeconds"].as_u64().unwrap_or(0),
        response["flushSeconds"].as_u64().unwrap_or(0),
    )
}

/// Which cadences to persist, given what the server `asked` for and the `current` pair.
///
/// `None` means nothing moved and the identity file must not be rewritten: a five minute
/// flush must not rewrite a credential file 288 times a day.
fn adopted_cadences(asked: (u64, u64), current: (u64, u64)) -> Option<(u64, u64)> {
    let wanted = (
        if asked.0 == 0 { current.0 } else { asked.0 },
        if asked.1 == 0 { current.1 } else { asked.1 },
    );
    (wanted != current).then_some(wanted)
}

/// Adopt the cadences an accepted batch echoed back.
///
/// The identity is re-read from disk rather than written back from the copy this daemon
/// loaded at start. `--enrol` is a separate process (identity.rs:88-97) and may have
/// re-enrolled this machine since, while `store` writes sk, pk, machine_id and both
/// cadences together (identity.rs:204-226) -- so writing a start-of-day snapshot back
/// would put a stale machine id over a freshly enrolled one. `machine_agent_pk_uidx` is
/// globally unique, so that is not recoverable from the agent side.
///
/// Nothing here returns an error. The server has already taken the batch and the spool
/// has already been truncated; charging the agent a doubling backoff because a file could
/// not be rewritten would make a transient disk fault look like an unreachable server.
fn adopt_cadences(identity: &mut AgentIdentity, text: &str) {
    let asked = asked_cadences(text);
    if asked == (0, 0) {
        return;
    }
    let mut fresh = match AgentIdentity::load_or_create() {
        Ok(fresh) if !fresh.machine_id().is_empty() => fresh,
        // An identity with no machine id means the file went away underneath us and a
        // fresh key was generated. Keep signing with the credential the server actually
        // holds rather than adopting one it has never seen.
        Ok(_) => {
            log::warn!("[collector] The identity file holds no enrolment; keeping the loaded one");
            return;
        }
        Err(err) => {
            log::warn!("[collector] Failed to re-read the agent identity: {}", err);
            return;
        }
    };
    // Measured against the file, not against the copy this daemon started with, so a
    // cadence that a re-enrolment has just written is not immediately undone.
    if let Some((sample_seconds, flush_seconds)) =
        adopted_cadences(asked, (fresh.sample_seconds(), fresh.flush_seconds()))
    {
        log::info!(
            "[collector] Adopting the server cadences: sample {}s, flush {}s",
            sample_seconds,
            flush_seconds
        );
        // `set_enrolment` is the only setter carrying both cadences. It writes the machine
        // id it is handed, which is the one just read off that same file.
        let machine_id = fresh.machine_id().to_owned();
        if let Err(err) = fresh.set_enrolment(&machine_id, sample_seconds, flush_seconds) {
            log::warn!("[collector] Failed to persist the server cadences: {}", err);
        }
    }
    *identity = fresh;
}

/// Build the request body from spool lines of the form
/// `[at, cpuPct, memPct, fsWorstPct, netRx, netTx]`.
///
/// The leading timestamp is the spool's own, not the wire's: the batch carries `from` and
/// `to` once and the samples themselves are the five readings, packed positionally.
/// `disks` is `None` when no sweep has finished since the last one the server took, and
/// `Some` when one has -- INCLUDING when it found nothing. The two are different members
/// on the wire and the ingest treats them differently: no member leaves
/// `machine_state.worst_disk` exactly as it was, an empty member sets it to `unreadable`.
fn batch_body(
    machine: serde_json::Value,
    lines: &[String],
    step: u64,
    disks: Option<&[DiskHealth]>,
) -> ResultType<String> {
    Ok(batch_body_with(machine, lines, step, disks, &[], &BTreeMap::new())?.0)
}

/// `batch_body` with the two members phase 1 added, `jobResults` and `attrs`,
/// and the order things give way in when the body is over the bound: the
/// disks first (a snapshot taken again in an hour), then the attrs (sent
/// again next flush), then results from the newest down (they wait). The
/// samples never give way.
fn batch_body_with(
    machine: serde_json::Value,
    lines: &[String],
    step: u64,
    disks: Option<&[DiskHealth]>,
    results: &[JobResult],
    attrs: &BTreeMap<String, String>,
) -> ResultType<(String, Included)> {
    // `Option` rather than a zero sentinel: the batch window is what the server
    // de-duplicates on, so a machine whose clock reads the epoch must report the epoch
    // rather than silently take the timestamp of a later sample.
    let mut from = None;
    let mut to = 0u64;
    let mut samples = Vec::with_capacity(lines.len());
    for line in lines {
        // A line that will not parse is skipped rather than allowed to fail the whole
        // batch: it still leaves the spool with the rest, so one bad line cannot wedge
        // every sample behind it.
        let Ok(serde_json::Value::Array(values)) = serde_json::from_str(line) else {
            log::warn!("[collector] Skipping an unreadable spool line");
            continue;
        };
        let Some(at) = values.first().and_then(|at| at.as_u64()) else {
            continue;
        };
        from.get_or_insert(at);
        to = at;
        samples.push(serde_json::Value::Array(values[1..].to_vec()));
    }
    if samples.is_empty() {
        bail!("No readable samples in the batch");
    }
    let batch = serde_json::json!({ "from": from, "to": to, "step": step, "samples": samples });
    let build = |with: Included| {
        let mut body = serde_json::json!({ "machine": machine, "batch": batch });
        if with.disks {
            if let Some(disks) = disks {
                body["disks"] = disks.iter().map(disk_member).collect::<Vec<_>>().into();
            }
        }
        if with.results > 0 {
            body["jobResults"] = results[..with.results]
                .iter()
                .map(JobResult::to_json)
                .collect::<Vec<_>>()
                .into();
        }
        if with.attrs && !attrs.is_empty() {
            body["attrs"] = serde_json::json!(attrs);
        }
        body.to_string()
    };
    let full = Included {
        disks: disks.is_some(),
        results: results.len(),
        attrs: !attrs.is_empty(),
    };
    let text = build(full);
    if text.len() <= MAX_BODY_BYTES {
        return Ok((text, full));
    }
    // The samples are the ones that cannot wait: they are the only copy, they leave the
    // spool once this is accepted, and a body the server refuses for its size would be
    // rebuilt and refused on every flush from now on. The disks are a snapshot that is
    // taken again in an hour, so they are what gets dropped first. The member is dropped
    // WHOLE rather than emptied: an empty member is the claim that this machine was
    // asked and no drive answered, and a body that was merely too long has not made
    // that claim.
    log::warn!(
        "[collector] A {} byte body is over the {} byte bound; dropping the optional members",
        text.len(),
        MAX_BODY_BYTES
    );
    let mut with = Included { disks: false, ..full };
    loop {
        let text = build(with);
        if text.len() <= MAX_BODY_BYTES {
            return Ok((text, with));
        }
        if with.attrs {
            with.attrs = false;
        } else if with.results > 0 {
            with.results -= 1;
        } else {
            // Samples alone. The window is bounded at MAX_BATCH_BYTES, well
            // under the body bound, so this is the floor and it fits.
            return Ok((text, with));
        }
    }
}

/// One drive, as section 4.4's `disks` member carries it.
///
/// The field names are the `disk` and `disk_sample` columns in camel case and nothing
/// else, so the ingest stores this without inventing a name for anything. Every counter
/// the drive did not answer is `null` in place rather than absent or zero: `null` is
/// stored as SQL NULL and rendered `--`, while a zero would be a measurement of a drive
/// nobody could ask, which is the one thing this whole module exists to prevent.
pub(crate) fn disk_member(disk: &DiskHealth) -> serde_json::Value {
    serde_json::json!({
        "serialHash": disk.serial_hash,
        "deviceIndex": disk.device_index,
        "devicePath": disk.device_path,
        "model": disk.model,
        "firmware": disk.firmware,
        "bus": disk.bus,
        "sizeBytes": disk.size_bytes,
        "rotational": disk.rotational,
        "verdict": disk.verdict.as_str(),
        "healthSource": disk.source.as_str(),
        "predictFailure": disk.predict_failure,
        "tempC": disk.temp_c,
        "powerOnHours": disk.power_on_hours,
        "powerCycles": disk.power_cycles,
        "reallocated": disk.reallocated,
        "pending": disk.pending,
        "uncorrectable": disk.uncorrectable,
        "crcErrors": disk.crc_errors,
        "percentUsed": disk.percent_used,
        "sparePct": disk.spare_pct,
        "spareThresholdPct": disk.spare_threshold_pct,
        "criticalWarning": disk.critical_warning,
        "unsafeShutdowns": disk.unsafe_shutdowns,
        "mediaErrors": disk.media_errors,
        "dataWrittenGb": disk.data_written_gb,
    })
}

/// POST a signed body to an `/agent/*` path.
///
/// The three headers are the uplink contract from the architecture: the machine id the
/// server looks the key up by, the timestamp it bounds replay with, and the detached
/// Ed25519 signature over the method, path, timestamp and body hash.
async fn post_signed(
    identity: &AgentIdentity,
    path: &str,
    body: &str,
) -> ResultType<(u16, String)> {
    request_signed(identity, "POST", path, body).await
}

async fn request_signed(
    identity: &AgentIdentity,
    method: &str,
    path: &str,
    body: &str,
) -> ResultType<(u16, String)> {
    // Always lab-desk.net: the `api-server` option is the profile's hbbs API, not the
    // machine plane (see `enrol` in src/labdesk/identity.rs).
    let ts = (hbb_common::get_time() / 1000).to_string();
    let signature = identity.sign(&uplink_signed_msg(method, path, &ts, body.as_bytes()))?;
    let url = format!("{}{}", crate::LABDESK_SITE, path);
    // The strict client refuses anything but HTTPS. An uplink carries a machine's whole
    // inventory, so cleartext is not a configuration we quietly accept.
    let response = crate::hbbs_http::create_http_client_async_with_url_strict(&url)
        .await?
        .request(method.parse()?, &url)
        .header("Content-Type", "application/json")
        .header("X-LD-Machine", identity.machine_id())
        .header("X-LD-Ts", &ts)
        .header("X-LD-Sig", signature)
        .timeout(if path == BATCH_PATH {
            UPLINK_TIMEOUT
        } else {
            TICKET_POLL
        })
        .body(body.to_owned())
        .send()
        .await?;
    let status = response.status().as_u16();
    Ok((status, response.text().await?))
}

/// The 60 s cadence: everything cheap enough to read once a minute forever.
struct Sampler {
    system: System,
    networks: Networks,
    disks: Disks,
}

impl Sampler {
    fn new() -> Self {
        let mut system = System::new();
        // CPU usage is a delta between two refreshes, so the first one here is what makes
        // the first sample -- a whole cadence later -- a real reading rather than a zero.
        system.refresh_cpu();
        system.refresh_memory();
        // The disk list is deliberately left empty: `sample` enumerates it from scratch
        // every time, so there is nothing for a constructor to seed. The interface list
        // is not, because the FIRST flush can come before the first sample -- the flush
        // offset is a fraction of the flush cadence and the first sample is a whole
        // sample cadence away -- and `net.adapters` is built from these counters. An
        // unseeded list writes that attribute with no MAC address and no traffic on
        // every adapter, and `Attrs` then holds that shape for an hour.
        let mut networks = Networks::new();
        networks.refresh_list();
        Self {
            system,
            networks,
            disks: Disks::new(),
        }
    }

    /// One spool line: `[at, cpuPct, memPct, fsWorstPct, netRx, netTx]`.
    ///
    /// A figure we could not read is `null`, never zero. The console renders absence as
    /// `--`; a zero would render as a healthy reading of a machine we did not measure.
    fn sample(&mut self) -> String {
        self.system.refresh_cpu();
        self.system.refresh_memory();
        // `refresh_list`, never `refresh`. In the vendored fork `Disks::refresh` walks only
        // the disks already listed (sysinfo src/common.rs:2155-2159, whose own warning is
        // "if a disk is added or removed, this method won't take it into account") and
        // `NetworksInner::refresh` walks only the interfaces already mapped
        // (src/unix/linux/network.rs:129-135, src/windows/network.rs:154-159). A service
        // starts at boot, before BitLocker unlock and before most data volumes attach, so
        // a sampler that froze its lists there would be permanently blind to the very disk
        // that later fills, and would never count an overlay, VPN or dock interface that
        // came up afterwards.
        self.networks.refresh_list();
        self.disks.refresh_list();

        let at = hbb_common::get_time() / 1000;
        let cpu = self.system.global_cpu_info().cpu_usage().round() as u64;
        let total_memory = self.system.total_memory();
        let memory =
            (total_memory > 0).then(|| percent(self.system.used_memory(), total_memory));
        // The fullest fixed mount. Removable media is excluded: a full USB stick is not a
        // machine about to stop working.
        let fullest = self
            .disks
            .list()
            .iter()
            .filter(|disk| !disk.is_removable() && disk.total_space() > 0)
            .map(|disk| {
                percent(
                    disk.total_space().saturating_sub(disk.available_space()),
                    disk.total_space(),
                )
            })
            .max();
        // The kernel's own since-interface-up totals, summed over the interfaces present
        // right now: `total_received` returns `/sys/class/net/<if>/statistics/rx_bytes`
        // verbatim on Linux (sysinfo src/unix/linux/network.rs:181-184, :227-229) and
        // `MIB_IF_ROW2.InOctets` on Windows (src/windows/network.rs:103, :210-212).
        // Restarting this daemon therefore does NOT reset the sum; a reboot or an interface
        // flap does, and so does an interface going away, since `refresh_list` drops the
        // ones that are gone. Whoever differences this into a rate must read any decrease
        // as a reset rather than as negative traffic.
        let (received, transmitted) =
            self.networks
                .list()
                .values()
                .fold((0u64, 0u64), |acc, data| {
                    (
                        acc.0.saturating_add(data.total_received()),
                        acc.1.saturating_add(data.total_transmitted()),
                    )
                });
        pack(&Reading {
            at,
            cpu,
            memory,
            fullest,
            received,
            transmitted,
        })
    }

    /// The `machine` member every batch carries.
    ///
    /// `conns` is deliberately absent: live connection counts live in the unprivileged
    /// `--server` processes and this daemon has no IPC call that answers for all of them,
    /// so there is no honest number to put here yet. Absence renders `--`; a zero would
    /// claim we had measured an idle machine.
    fn machine(&self) -> serde_json::Value {
        serde_json::json!({
            "hostname": crate::hostname(),
            "os": self.system.long_os_version().unwrap_or_default(),
            "platform": PLATFORM,
            "arch": std::env::consts::ARCH,
            "agentVersion": crate::VERSION,
            "uptimeS": self.system.uptime(),
            "loggedInUser": crate::platform::get_active_username(),
        })
    }
}

/// Pack one reading into a spool line.
///
/// The order is the wire contract. The batch strips the leading timestamp and sends the
/// remaining five positionally as `[cpu, memPct, fsWorstPct, netRx, netTx]`, which is the
/// order the console's columns and every health rule are read out of, so a transposition
/// here would render a filesystem percentage as memory on every chart. That is why this is
/// a named function pinned by a test on the exact string rather than a `json!` line inside
/// the sampler where nothing could see it.
fn pack(reading: &Reading) -> String {
    serde_json::json!([
        reading.at,
        reading.cpu,
        reading.memory,
        reading.fullest,
        reading.received,
        reading.transmitted,
    ])
    .to_string()
}

/// One reading, before it is packed.
///
/// Named fields rather than a six-tuple, so that the only place two of these can be
/// transposed is `pack`, which a test pins position by position. Four of the six are plain
/// `u64` and would swap without a compiler complaint if the sampler handed them over
/// positionally.
struct Reading {
    /// `hbb_common::get_time()` is `i64` (libs/hbb_common/src/lib.rs:379); the spool line
    /// carries it as it comes rather than through a cast that could wrap.
    at: i64,
    cpu: u64,
    memory: Option<u64>,
    fullest: Option<u64>,
    received: u64,
    transmitted: u64,
}

/// `used` as a whole percent of `total`. Callers guarantee a non-zero total; a reading
/// that has no total to be a percent of is `None`, and serialises as `null` rather than
/// as a zero the console would render as a healthy measurement.
fn percent(used: u64, total: u64) -> u64 {
    ((used as f64 / total.max(1) as f64) * 100.0).round() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    fn machine() -> serde_json::Value {
        serde_json::json!({ "hostname": "host-1" })
    }

    #[test]
    fn test_the_batch_names_the_platform_and_the_architecture() {
        // The server keys every catalog entry on `machine.platform` and writes that
        // column from nowhere else, so a batch that does not name it leaves the column
        // NULL for the life of the machine and `POST /org/jobs` answers "That machine
        // has not reported its platform yet." for every tool, forever.
        let member = Sampler::new().machine();
        assert!(["windows", "macos", "linux"].contains(&PLATFORM));
        assert_eq!(member["platform"], PLATFORM);
        assert_eq!(member["arch"], std::env::consts::ARCH);
    }

    #[test]
    fn test_the_batch_carries_the_window_and_strips_the_spool_timestamp() {
        let lines = vec![
            "[1788480000,7,42,55,100,200]".to_owned(),
            "[1788480060,9,43,55,140,260]".to_owned(),
            "[1788480120,11,44,56,180,320]".to_owned(),
        ];
        let body: serde_json::Value =
            serde_json::from_str(&batch_body(machine(), &lines, 60, None).unwrap()).unwrap();

        // Each figure by name, not merely "it parsed": `from` is the first sample's
        // timestamp and `to` the last, and neither may be a sample reading.
        assert_eq!(body["batch"]["from"], 1788480000u64);
        assert_eq!(body["batch"]["to"], 1788480120u64);
        assert_eq!(body["batch"]["step"], 60u64);
        assert_eq!(body["machine"]["hostname"], "host-1");

        // The timestamp leads the spool line and must not lead the packed sample, or every
        // chart would read a unix time as a CPU percentage.
        assert_eq!(
            body["batch"]["samples"],
            serde_json::json!([[7, 42, 55, 100, 200], [9, 43, 55, 140, 260], [11, 44, 56, 180, 320]])
        );
    }

    #[test]
    fn test_an_unreadable_line_is_skipped_and_an_unreadable_batch_is_refused() {
        let lines = vec![
            "not json at all".to_owned(),
            "[1788480060,9,43,55,140,260]".to_owned(),
            "{\"cpu\":7}".to_owned(),
        ];
        let body: serde_json::Value =
            serde_json::from_str(&batch_body(machine(), &lines, 60, None).unwrap()).unwrap();
        assert_eq!(body["batch"]["from"], 1788480060u64);
        assert_eq!(body["batch"]["to"], 1788480060u64);
        assert_eq!(
            body["batch"]["samples"],
            serde_json::json!([[9, 43, 55, 140, 260]])
        );

        // A window with nothing readable in it is an error rather than an empty batch, so
        // that the caller drops those lines instead of posting a batch of no samples.
        assert!(batch_body(machine(), &["not json at all".to_owned()], 60, None).is_err());
        assert!(batch_body(machine(), &[], 60, None).is_err());
    }

    #[test]
    fn test_a_reading_with_no_total_is_null_and_never_zero() {
        // The console renders absence as `--` and zero as a measurement. A machine whose
        // memory total could not be read is not a machine with no memory in use.
        assert_eq!(serde_json::json!(Option::<u64>::None), serde_json::Value::Null);
        assert_eq!(percent(0, 0), 0);
        assert_eq!(percent(1, 2), 50);
        assert_eq!(percent(2, 3), 67);
        assert_eq!(percent(1, 1000), 0);
    }

    #[test]
    fn test_a_sample_is_packed_in_the_one_order_the_wire_pins() {
        // Six values chosen so that no two are equal and none could pass for another: any
        // transposition at all moves a digit in this string. The wire is
        // `[cpu, memPct, fsWorstPct, netRx, netTx]` once the leading spool timestamp is
        // stripped, so a memory percentage arriving in the filesystem column would fire
        // every disk-full rule against the wrong series.
        assert_eq!(
            pack(&Reading {
                at: 1788480000,
                cpu: 7,
                memory: Some(42),
                fullest: Some(55),
                received: 100,
                transmitted: 200,
            }),
            "[1788480000,7,42,55,100,200]"
        );

        // Position by position, against a body built from that very line, so the packing
        // and the batch cannot drift apart.
        let body: serde_json::Value = serde_json::from_str(
            &batch_body(
                machine(),
                &[pack(&Reading {
                    at: 1788480000,
                    cpu: 7,
                    memory: Some(42),
                    fullest: Some(55),
                    received: 100,
                    transmitted: 200,
                })],
                60,
                None,
            )
            .unwrap(),
        )
        .unwrap();
        let sample = &body["batch"]["samples"][0];
        assert_eq!(body["batch"]["from"], 1788480000u64, "at leads the spool line");
        assert_eq!(sample[0], 7u64, "cpu is the first wire column");
        assert_eq!(sample[1], 42u64, "memPct is the second");
        assert_eq!(sample[2], 55u64, "fsWorstPct is the third");
        assert_eq!(sample[3], 100u64, "netRx is the fourth");
        assert_eq!(sample[4], 200u64, "netTx is the fifth");

        // A reading we could not take is `null` in place, never a zero and never a hole
        // that shortens the row and shifts every later column left.
        assert_eq!(
            pack(&Reading {
                at: 1788480000,
                cpu: 7,
                memory: None,
                fullest: None,
                received: 100,
                transmitted: 200,
            }),
            "[1788480000,7,null,null,100,200]"
        );
    }


    /// One drive, with every counter absent, so a test that fills a field in is the only
    /// thing that can make that field non-null.
    fn unread_disk(serial_hash: &str, verdict: disk::Verdict, source: disk::Source) -> DiskHealth {
        DiskHealth {
            serial_hash: serial_hash.to_owned(),
            device_index: 0,
            device_path: None,
            model: None,
            firmware: None,
            bus: None,
            size_bytes: None,
            rotational: None,
            verdict,
            source,
            predict_failure: None,
            temp_c: None,
            power_on_hours: None,
            power_cycles: None,
            reallocated: None,
            pending: None,
            uncorrectable: None,
            crc_errors: None,
            percent_used: None,
            spare_pct: None,
            spare_threshold_pct: None,
            critical_warning: None,
            unsafe_shutdowns: None,
            media_errors: None,
            data_written_gb: None,
        }
    }

    #[test]
    fn test_the_disks_member_carries_every_column_the_ingest_stores() {
        // A drive that answered, with a different number in every counter so that no two
        // fields can be swapped without moving a value an assertion reads.
        let answered = DiskHealth {
            serial_hash: "a".repeat(64),
            device_index: 3,
            device_path: Some("/dev/nvme0n1".to_owned()),
            model: Some("ACME NVMe 1TB".to_owned()),
            firmware: Some("FW1234".to_owned()),
            bus: Some("nvme".to_owned()),
            size_bytes: Some(1_000_204_886_016),
            rotational: Some(false),
            verdict: disk::Verdict::Warn,
            source: disk::Source::NvmeLogPage,
            predict_failure: Some(false),
            temp_c: Some(41),
            power_on_hours: Some(1234),
            power_cycles: Some(56),
            reallocated: Some(7),
            pending: Some(8),
            uncorrectable: Some(9),
            crc_errors: Some(10),
            percent_used: Some(11),
            spare_pct: Some(97),
            spare_threshold_pct: Some(10),
            critical_warning: Some(1),
            unsafe_shutdowns: Some(12),
            media_errors: Some(13),
            data_written_gb: Some(4096),
        };
        let body: serde_json::Value = serde_json::from_str(
            &batch_body(
                machine(),
                &["[1788480000,7,42,55,100,200]".to_owned()],
                60,
                Some(&[answered, unread_disk(&"b".repeat(64), disk::Verdict::Unreadable, disk::Source::None)]),
            )
            .unwrap(),
        )
        .unwrap();

        // Field by field and by name, because the ingest stores these into columns of the
        // same name and a rename on either side is a column that silently stops arriving.
        let one = &body["disks"][0];
        assert_eq!(one["serialHash"], "a".repeat(64));
        assert_eq!(one["deviceIndex"], 3u64);
        assert_eq!(one["devicePath"], "/dev/nvme0n1");
        assert_eq!(one["model"], "ACME NVMe 1TB");
        assert_eq!(one["firmware"], "FW1234");
        assert_eq!(one["bus"], "nvme");
        assert_eq!(one["sizeBytes"], 1_000_204_886_016u64);
        assert_eq!(one["rotational"], false);
        assert_eq!(one["verdict"], "warn");
        assert_eq!(one["healthSource"], "nvme_logpage");
        assert_eq!(one["predictFailure"], false);
        assert_eq!(one["tempC"], 41i64);
        assert_eq!(one["powerOnHours"], 1234u64);
        assert_eq!(one["powerCycles"], 56u64);
        assert_eq!(one["reallocated"], 7u64);
        assert_eq!(one["pending"], 8u64);
        assert_eq!(one["uncorrectable"], 9u64);
        assert_eq!(one["crcErrors"], 10u64);
        assert_eq!(one["percentUsed"], 11u64);
        assert_eq!(one["sparePct"], 97u64);
        assert_eq!(one["spareThresholdPct"], 10u64);
        assert_eq!(one["criticalWarning"], 1u64);
        assert_eq!(one["unsafeShutdowns"], 12u64);
        assert_eq!(one["mediaErrors"], 13u64);
        assert_eq!(one["dataWrittenGb"], 4096u64);

        // THE RULE THE WHOLE DISK MODULE EXISTS FOR, ON THE WIRE. A drive nobody could ask
        // travels as `unreadable` with a source of `none`, and every counter it never
        // answered is `null` IN PLACE -- not absent, not zero. A zero here would be stored
        // as a measurement and rendered as a healthy figure for a drive we did not read.
        let other = &body["disks"][1];
        assert_eq!(other["verdict"], "unreadable");
        assert_eq!(other["healthSource"], "none");
        for field in [
            "devicePath",
            "model",
            "firmware",
            "bus",
            "sizeBytes",
            "rotational",
            "predictFailure",
            "tempC",
            "powerOnHours",
            "powerCycles",
            "reallocated",
            "pending",
            "uncorrectable",
            "crcErrors",
            "percentUsed",
            "sparePct",
            "spareThresholdPct",
            "criticalWarning",
            "unsafeShutdowns",
            "mediaErrors",
            "dataWrittenGb",
        ] {
            assert_eq!(
                other[field],
                serde_json::Value::Null,
                "{} must be null, never zero and never missing",
                field
            );
        }

        // And the samples still ride the same body, unmoved.
        assert_eq!(
            body["batch"]["samples"],
            serde_json::json!([[7, 42, 55, 100, 200]])
        );
    }

    #[test]
    fn test_a_sweep_that_has_not_happened_and_one_that_found_nothing_are_different_bodies() {
        let lines = ["[1788480000,7,42,55,100,200]".to_owned()];
        // No sweep has finished since the last one the server took. The ingest leaves
        // `machine_state.worst_disk` exactly as it was, which is what stops the eleven
        // metrics-only flushes in every twelve from blanking a dying drive.
        let body: serde_json::Value =
            serde_json::from_str(&batch_body(machine(), &lines, 60, None).unwrap()).unwrap();
        assert_eq!(body["disks"], serde_json::Value::Null);
        assert!(body.as_object().unwrap().get("disks").is_none());

        // A SWEEP THAT RAN AND FOUND NOTHING IS A READING, AND IT HAS TO REACH THE SERVER.
        // Every macOS machine is in this state permanently, and so is a Linux agent that
        // lost its privilege or a machine whose drives were pulled. Without a member the
        // server would hold the last verdict it was ever told forever, and the console
        // would show a failing drive that is no longer in the chassis.
        let body: serde_json::Value =
            serde_json::from_str(&batch_body(machine(), &lines, 60, Some(&[])).unwrap()).unwrap();
        assert!(body.as_object().unwrap().get("disks").is_some());
        assert_eq!(body["disks"], serde_json::json!([]));
        // And the samples still ride the same body either way.
        assert_eq!(
            body["batch"]["samples"],
            serde_json::json!([[7, 42, 55, 100, 200]])
        );
    }

    #[test]
    fn test_a_body_over_the_bound_drops_the_disks_and_never_the_samples() {
        // A body the server refuses for its size is not a batch this machine can ever get
        // rid of: the spool is truncated only on 2xx, so the same oversized body would be
        // rebuilt and refused on every flush from now on. The disks are a snapshot taken
        // again in an hour; the samples are the only copy there is.
        //
        // Five hundred drives is a backstop rather than a shape the collector can build:
        // `disk::gather` caps every sweep at `disk::MAX_DISKS`. This is what happens if
        // that cap is ever raised past what the body budget can carry.
        let many: Vec<DiskHealth> = (0..500)
            .map(|n| unread_disk(&format!("{:064}", n), disk::Verdict::Unreadable, disk::Source::None))
            .collect();
        let lines = vec!["[1788480000,7,42,55,100,200]".to_owned()];

        let oversized = serde_json::json!({
            "machine": machine(),
            "batch": { "from": 1788480000, "to": 1788480000, "step": 60, "samples": [[7, 42, 55, 100, 200]] },
            "disks": many.iter().map(disk_member).collect::<Vec<_>>(),
        })
        .to_string();
        assert!(
            oversized.len() > MAX_BODY_BYTES,
            "the fixture has to actually exceed the bound to exercise the branch"
        );

        let body = batch_body(machine(), &lines, 60, Some(&many)).unwrap();
        assert!(body.len() <= MAX_BODY_BYTES, "{} bytes", body.len());
        let body: serde_json::Value = serde_json::from_str(&body).unwrap();
        // Absent, and NOT an empty array: an empty member says this machine was asked and
        // no drive answered, and a body that was merely too long has not said that.
        assert!(body.as_object().unwrap().get("disks").is_none());
        assert_ne!(body["disks"], serde_json::json!([]));
        assert_eq!(
            body["batch"]["samples"],
            serde_json::json!([[7, 42, 55, 100, 200]])
        );

        // THE BOUND ITSELF, not merely "much too big". A guard that is a kilobyte loose
        // builds a body the server answers 413 to, and the spool is truncated only on 2xx,
        // so that machine would rebuild and re-send the same refused body forever. One
        // drive, padded a byte at a time: the model is the only free-length field and each
        // character it grows by is one more byte of JSON.
        let padded = |pad: usize| {
            let mut disk = unread_disk(&"c".repeat(64), disk::Verdict::Unreadable, disk::Source::None);
            disk.model = Some("m".repeat(pad));
            disk
        };
        let base = batch_body(machine(), &lines, 60, Some(&[padded(0)]))
            .unwrap()
            .len();
        let pad = MAX_BODY_BYTES - base;

        let exact = batch_body(machine(), &lines, 60, Some(&[padded(pad)])).unwrap();
        assert_eq!(exact.len(), MAX_BODY_BYTES, "the fixture has to land ON the bound");
        let exact: serde_json::Value = serde_json::from_str(&exact).unwrap();
        assert_eq!(
            exact["disks"].as_array().unwrap().len(),
            1,
            "a body of exactly MAX_BODY_BYTES is inside the bound and goes as it is"
        );

        let over = batch_body(machine(), &lines, 60, Some(&[padded(pad + 1)])).unwrap();
        assert!(over.len() < MAX_BODY_BYTES, "{} bytes", over.len());
        let over: serde_json::Value = serde_json::from_str(&over).unwrap();
        assert!(
            over.as_object().unwrap().get("disks").is_none(),
            "one byte over the bound and the disks are what go"
        );

        // One drive still fits alongside a full batch of samples, so the branch above is a
        // backstop and not the ordinary path.
        let full: Vec<String> = (0..MAX_BATCH_LINES)
            .map(|n| format!("[{},7,42,55,100,200]", 1788480000u64 + n as u64))
            .collect();
        let body = batch_body(machine(), &full, 60, Some(&many[..1])).unwrap();
        assert!(body.len() <= MAX_BODY_BYTES, "{} bytes", body.len());
        let body: serde_json::Value = serde_json::from_str(&body).unwrap();
        assert_eq!(body["disks"].as_array().unwrap().len(), 1);
    }

    fn result(id: &str, output: &str) -> JobResult {
        JobResult {
            id: id.to_owned(),
            started_at: 1788480123,
            finished_at: 1788480125,
            exit_code: Some(0),
            output: output.to_owned(),
            refused: None,
        }
    }

    #[test]
    fn test_job_results_and_attrs_ride_the_batch_by_name() {
        let lines = ["[1788480000,7,42,55,100,200]".to_owned()];
        let mut attrs = BTreeMap::new();
        attrs.insert("net.reachability".to_owned(), r#"{"internet":"online"}"#.to_owned());
        let (text, included) = batch_body_with(
            machine(),
            &lines,
            60,
            None,
            &[result("2f1c", "ok\n")],
            &attrs,
        )
        .unwrap();
        assert_eq!(included, Included { disks: false, results: 1, attrs: true });
        let body: serde_json::Value = serde_json::from_str(&text).unwrap();
        // Section 2 of the phase 1 contracts, member by member.
        let r = &body["jobResults"][0];
        assert_eq!(r["id"], "2f1c");
        assert_eq!(r["startedAt"], 1788480123);
        assert_eq!(r["finishedAt"], 1788480125);
        assert_eq!(r["exitCode"], 0);
        assert_eq!(r["output"], "ok\n");
        assert_eq!(r["refused"], serde_json::Value::Null);
        assert_eq!(r["outputSha256"].as_str().unwrap().len(), 64);
        // Section 6: a string value per key, not a nested object.
        assert_eq!(body["attrs"]["net.reachability"], r#"{"internet":"online"}"#);
        assert_eq!(body["batch"]["samples"], serde_json::json!([[7, 42, 55, 100, 200]]));
        // Neither member is present when there is nothing to carry.
        let (text, included) = batch_body_with(machine(), &lines, 60, None, &[], &BTreeMap::new()).unwrap();
        assert_eq!(included, Included::default());
        let body: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert!(body.get("jobResults").is_none());
        assert!(body.get("attrs").is_none());
    }

    #[test]
    fn test_over_the_bound_the_disks_go_first_then_attrs_then_results_never_samples() {
        let lines = ["[1788480000,7,42,55,100,200]".to_owned()];
        let disks = [unread_disk(&"c".repeat(64), disk::Verdict::Unreadable, disk::Source::None)];
        let mut attrs = BTreeMap::new();
        attrs.insert("net.adapters".to_owned(), "x".repeat(4000));
        // Four results at the output bound: 64 KiB of output alone, which is
        // the whole body budget.
        let big: Vec<JobResult> = (0..4)
            .map(|n| result(&format!("r{}", n), &"o".repeat(tools::OUTPUT_LIMIT)))
            .collect();
        let (text, included) = batch_body_with(machine(), &lines, 60, Some(&disks), &big, &attrs).unwrap();
        assert!(text.len() <= MAX_BODY_BYTES, "{}", text.len());
        assert!(!included.disks, "the disks give way first");
        assert!(!included.attrs, "then the attrs");
        assert!(included.results < 4 && included.results >= 2, "then results, newest down: {}", included.results);
        let body: serde_json::Value = serde_json::from_str(&text).unwrap();
        assert_eq!(body["jobResults"].as_array().unwrap().len(), included.results);
        assert_eq!(body["jobResults"][0]["id"], "r0", "oldest first survives");
        assert_eq!(body["batch"]["samples"], serde_json::json!([[7, 42, 55, 100, 200]]));
        // Small extras fit beside the disks and nothing is dropped.
        let (_, included) = batch_body_with(machine(), &lines, 60, Some(&disks), &big[..1], &attrs).unwrap();
        assert_eq!(included, Included { disks: true, results: 1, attrs: true });
    }

    #[test]
    fn test_attrs_go_on_change_and_hourly_and_the_counters_are_not_a_change() {
        use super::super::netview::{Adapter, Address};
        let adapters = |rx: u64, up: bool| {
            vec![Adapter {
                name: "eth0".into(),
                up,
                mac: "aa".into(),
                addresses: vec![Address { addr: "10.0.0.1".into(), prefix: 24, family: "inet" }],
                rx_bytes: rx,
                tx_bytes: 0,
                kind: "physical",
            }]
        };
        let online = Reachability {
            internet: Some(selfheal::Connectivity::Online),
            at: 1_000,
            step: None,
        };
        let mut attrs = Attrs::default();
        // First flush: both go.
        let first = attrs.pending(1_000, Some(&adapters(1, true)), online);
        assert_eq!(first.keys().collect::<Vec<_>>(), ["net.adapters", "net.reachability"]);
        attrs.sent(&first, online, 1_000);
        // Five minutes on, counters moved, same verdict: nothing goes.
        let later = Reachability { at: 1_300, ..online };
        assert!(attrs.pending(1_300, Some(&adapters(50_000, true)), later).is_empty());
        // The link went down: adapters go, reachability does not.
        let down = attrs.pending(1_600, Some(&adapters(60_000, false)), later);
        assert_eq!(down.keys().collect::<Vec<_>>(), ["net.adapters"]);
        // A refused batch means nothing was sent, so it goes again next time.
        assert_eq!(attrs.pending(1_900, Some(&adapters(70_000, false)), later).len(), 1);
        attrs.sent(&down, later, 1_900);
        // The verdict changed: reachability goes.
        let offline = Reachability {
            internet: Some(selfheal::Connectivity::Offline),
            at: 2_200,
            step: None,
        };
        let changed = attrs.pending(2_200, Some(&adapters(80_000, false)), offline);
        assert_eq!(changed.keys().collect::<Vec<_>>(), ["net.reachability"]);
        attrs.sent(&changed, offline, 2_200);
        // The healer turning on is a change of `selfheal` even with the same verdict.
        let watching = Reachability { step: Some(selfheal::Step::Wait), ..offline };
        assert_eq!(attrs.pending(2_500, Some(&adapters(80_000, false)), watching).len(), 1);
        // An hour on with nothing changed: both go again, counters refreshed.
        let hour = Reachability { at: 6_000, ..offline };
        let refreshed = attrs.pending(6_000, Some(&adapters(90_000, false)), hour);
        assert_eq!(refreshed.len(), 2);
        assert!(refreshed["net.adapters"].contains("90000"));
        // Windows today: no adapter list at all, and no `net.adapters` member.
        let mut fresh = Attrs::default();
        assert_eq!(fresh.pending(1, None, online).keys().collect::<Vec<_>>(), ["net.reachability"]);
        fresh.sent(&fresh.pending(1, None, online), online, 1);
        assert!(fresh.pending(2, None, online).is_empty());
    }

    #[test]
    fn test_both_cadences_are_server_controlled_and_an_unchanged_pair_is_not_rewritten() {
        // The response shape from the wire format. Both members move the agent.
        assert_eq!(
            asked_cadences(r#"{"ok":true,"sampleSeconds":30,"flushSeconds":900}"#),
            (30, 900)
        );
        // A member the server omits is not a request to reset it, so it reads as zero and
        // leaves that cadence alone below.
        assert_eq!(asked_cadences(r#"{"ok":true,"flushSeconds":900}"#), (0, 900));
        assert_eq!(asked_cadences(r#"{"ok":true,"sampleSeconds":30}"#), (30, 0));
        assert_eq!(asked_cadences(r#"{"ok":true}"#), (0, 0));
        // A body that is not JSON, or names the cadences as something other than a number,
        // must not be read as "slow to zero".
        assert_eq!(asked_cadences("not json at all"), (0, 0));
        assert_eq!(asked_cadences(r#"{"sampleSeconds":"30"}"#), (0, 0));
        assert_eq!(asked_cadences(r#"{"sampleSeconds":-30}"#), (0, 0));

        // Each cadence is adopted on its own: a fleet slowed only in its sampling keeps the
        // flush it had, which is the whole point of the two being separate knobs.
        assert_eq!(adopted_cadences((30, 900), (60, 300)), Some((30, 900)));
        assert_eq!(adopted_cadences((30, 0), (60, 300)), Some((30, 300)));
        assert_eq!(adopted_cadences((0, 900), (60, 300)), Some((60, 900)));

        // And nothing moved means nothing is written. The identity file holds the machine
        // credential; rewriting it 288 times a day to store the number it already held is
        // 288 chances a day to lose it.
        assert_eq!(adopted_cadences((60, 300), (60, 300)), None);
        assert_eq!(adopted_cadences((0, 0), (60, 300)), None);
        assert_eq!(adopted_cadences((0, 300), (60, 300)), None);
    }
}
