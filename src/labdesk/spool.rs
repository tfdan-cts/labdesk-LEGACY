// The agent's on-disk telemetry spool.
//
// One JSON line per sample, oldest first. The collector appends here every
// `sampleSeconds` whether or not the network is reachable, and removes lines from the
// front only after the server has acknowledged them. A machine that spends a week off
// the network therefore comes back carrying its most recent samples in a file that never
// grew past `MAX_LINES` -- rather than an unbounded log filling the disk of the machine
// we were hired to keep healthy.
//
// Everything that decides *what* to keep, *what* the next batch carries and *when* to try
// again is a pure function over slices and integers, which is what these tests cover. The
// file handling on top is deliberately the thin part.

use hbb_common::{bail, sodiumoxide::crypto::hash::sha256, ResultType};
use std::io::Write;
use std::path::PathBuf;

/// The hard cap, in lines. At the default 60 s sample cadence this is a little over 2.8
/// days of history and roughly a quarter of a megabyte on disk. Reaching it drops the
/// oldest lines: an operator looking at a machine that has just come back wants the hours
/// before it returned, not the hours before it vanished.
pub const MAX_LINES: usize = 4096;

/// The most samples one uplink carries, per the batching design.
pub const MAX_BATCH_LINES: usize = 64;

/// The byte budget for the sample lines inside one uplink.
///
/// The wire format bounds the whole request body at 64 KiB. This is the budget for the
/// packed samples alone; the remainder is headroom for the `machine`, `inventory`,
/// `volumes` and `disks` members the same body carries.
pub const MAX_BATCH_BYTES: usize = 60 * 1024;

/// The bound on the whole request body, section 4.4, enforced server side too
/// (`src/worker/routes/agent-ingest.ts`, which answers 413 above it).
///
/// The agent has to know it as well as the server does. A body the server refuses for
/// its size is not a batch this machine can ever get rid of: the spool is truncated
/// only on 2xx, so the same oversized body would be rebuilt and refused on every flush
/// forever. `collector::batch_body` drops the optional members rather than let that
/// happen.
pub const MAX_BODY_BYTES: usize = 64 * 1024;

/// The ceiling the failure backoff doubles up to: one hour.
pub const MAX_BACKOFF_SECONDS: u64 = 3600;

/// Which lines of a spool the next uplink accounts for.
///
/// `dropped` are the oldest lines that must leave the spool without ever being sent. A
/// single line longer than the whole body budget can never fit in any batch, and leaving
/// it at the front would wedge every later sample behind it forever. That is the one place
/// the newest data is preferred over the oldest, which is the direction the design asks
/// for. `sent` counts the lines immediately after those that the batch does carry.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Window {
    pub dropped: usize,
    pub sent: usize,
}

impl Window {
    /// How many lines leave the front of the spool once this batch is acknowledged.
    #[inline]
    pub fn consumed(&self) -> usize {
        self.dropped + self.sent
    }
}

/// Choose the window the next uplink carries from `lines`, oldest first.
pub fn batch_window(lines: &[String], max_lines: usize, max_bytes: usize) -> Window {
    let mut dropped = 0;
    while dropped < lines.len() && lines[dropped].len() > max_bytes {
        dropped += 1;
    }
    let mut sent = 0;
    let mut bytes = 0usize;
    for line in &lines[dropped..] {
        if sent >= max_lines {
            break;
        }
        // One separator per line after the first: the samples go out as a JSON array.
        let cost = line.len() + usize::from(sent > 0);
        if bytes + cost > max_bytes {
            break;
        }
        bytes += cost;
        sent += 1;
    }
    Window { dropped, sent }
}

/// What the server's answer means for the spool.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ack {
    /// 2xx. The server holds the batch; drop exactly what went out and reset the backoff.
    Accepted,
    /// The server said, in words, that this machine is revoked. Stop collecting and
    /// delete the spool: an org that has revoked a machine has said it wants nothing more
    /// from it, and the history sitting on that disk is inventory about a customer who is
    /// no longer a customer.
    Revoked,
    /// Everything else, 401 and an unexplained 403 included. Keep every line and back off.
    ///
    /// 401 means the signature was refused, and the ordinary cause is a clock that has
    /// drifted outside the 120 s window rather than a key that is wrong. Deleting history
    /// over a skewed clock would be unrecoverable, so a rejected signature costs a delay
    /// and nothing else.
    Retry,
}

/// The word the server's revocation carries. `src/worker/agent-auth.ts` answers a revoked
/// machine `{"error":"This machine has been revoked."}`, and this matches on the word
/// rather than on that whole sentence so that reworded copy costs a fleet nothing.
const REVOKED: &str = "revoked";

/// Whether an answer is the SERVER saying revoked, rather than merely a 403.
///
/// A 403 is not proof of anything on its own. Cloudflare Access, a corporate proxy, a
/// captive portal, a WAF rule and a misrouted request all answer 403, and none of them
/// is this org revoking this machine. Taking the status code as proof means one middlebox
/// deletes the queued telemetry of every agent behind it, which is not recoverable: the
/// samples only ever existed on those disks.
///
/// So the destructive branch needs the server's own words. A JSON object with an `error`
/// naming revocation is something only the Worker sends; an edge answers HTML, and a proxy
/// that does answer JSON says "Forbidden". When in doubt this returns false, and the
/// uplink is retried instead: the cost of being wrong that way is one wasted flush.
fn says_revoked(body: &str) -> bool {
    let Ok(response) = serde_json::from_str::<serde_json::Value>(body) else {
        return false;
    };
    response["error"]
        .as_str()
        .map_or(false, |error| error.to_ascii_lowercase().contains(REVOKED))
}

/// Map an HTTP status and the body that came with it onto what the spool does about it.
pub fn ack_for(status: u16, body: &str) -> Ack {
    match status {
        200..=299 => Ack::Accepted,
        403 if says_revoked(body) => Ack::Revoked,
        _ => Ack::Retry,
    }
}

/// Seconds to wait before the next flush attempt, having failed `consecutive_failures`
/// times in a row. Zero failures is the plain cadence; each failure doubles it, up to
/// `MAX_BACKOFF_SECONDS`.
pub fn backoff_seconds(flush_seconds: u64, consecutive_failures: u32) -> u64 {
    let base = flush_seconds.max(1);
    // 1 << 12 already carries any plausible cadence past the ceiling; the clamp keeps the
    // shift itself defined however long a machine has been unable to reach the server.
    let doublings = consecutive_failures.min(12);
    base.saturating_mul(1u64 << doublings)
        .min(MAX_BACKOFF_SECONDS.max(base))
}

/// A fixed per-machine offset, in `0..flush_seconds`, applied once before the first flush.
///
/// Five hundred agents installed from one image and started by one deployment otherwise
/// share a phase and arrive together every five minutes. The offset is derived from the
/// machine id rather than drawn at random so that it survives a restart -- a machine that
/// re-rolled its offset on every service start would drift back into the crowd.
pub fn flush_jitter_seconds(machine_id: &str, flush_seconds: u64) -> u64 {
    if flush_seconds == 0 {
        return 0;
    }
    let digest = sha256::hash(machine_id.as_bytes());
    let mut head = [0u8; 8];
    head.copy_from_slice(&digest.0[..8]);
    u64::from_be_bytes(head) % flush_seconds
}

/// The spool file itself.
pub struct Spool {
    path: PathBuf,
    max_lines: usize,
}

impl Spool {
    /// A spool at `path` holding at most `MAX_LINES` lines.
    pub fn new(path: PathBuf) -> Self {
        Self::with_cap(path, MAX_LINES)
    }

    /// A spool with an explicit cap. A cap of zero would mean "keep nothing", which is not
    /// a spool, so one line is the floor.
    pub fn with_cap(path: PathBuf, max_lines: usize) -> Self {
        Self {
            path,
            max_lines: max_lines.max(1),
        }
    }

    /// Append one sample and enforce the cap.
    pub fn append(&self, line: &str) -> ResultType<()> {
        // A line carrying a newline would be read back as two records, silently corrupting
        // every batch after it. Callers pass single-line JSON; this refuses anything else
        // rather than writing damage to disk.
        if line.contains('\n') || line.contains('\r') {
            bail!("A spool line may not contain a line break");
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.path)?;
        writeln!(file, "{}", line)?;
        drop(file);
        let lines = self.read()?;
        if lines.len() > self.max_lines {
            self.rewrite(&lines[lines.len() - self.max_lines..])?;
        }
        Ok(())
    }

    /// Every line, oldest first. A spool that does not exist yet is empty, not an error:
    /// that is the state of every machine before its first sample.
    pub fn read(&self) -> ResultType<Vec<String>> {
        match std::fs::read_to_string(&self.path) {
            Ok(text) => Ok(text
                .lines()
                .filter(|line| !line.trim().is_empty())
                .map(str::to_owned)
                .collect()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(Vec::new()),
            Err(err) => bail!("Failed to read '{}': {}", self.path.display(), err),
        }
    }

    /// Remove the `count` oldest lines. Called only once the server has taken them, which
    /// is why nothing here is conditional on the send having been attempted.
    pub fn drop_front(&self, count: usize) -> ResultType<()> {
        if count == 0 {
            return Ok(());
        }
        let lines = self.read()?;
        if count >= lines.len() {
            return self.clear();
        }
        self.rewrite(&lines[count..])
    }

    /// Delete the spool entirely.
    pub fn clear(&self) -> ResultType<()> {
        match std::fs::remove_file(&self.path) {
            Ok(()) => Ok(()),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(err) => bail!("Failed to remove '{}': {}", self.path.display(), err),
        }
    }

    /// Replace the file with exactly `lines`.
    ///
    /// Written beside the spool and renamed, so that losing power part way through a trim
    /// leaves either the old history or the new one, never half a file where the history
    /// used to be. `rename` replaces the destination on all three platforms.
    fn rewrite(&self, lines: &[String]) -> ResultType<()> {
        let tmp = self.path.with_extension("tmp");
        let mut text = lines.join("\n");
        if !text.is_empty() {
            text.push('\n');
        }
        std::fs::write(&tmp, text)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    fn scratch_path(name: &str) -> PathBuf {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "labdesk-spool-test-{}-{}-{}.jsonl",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed),
            name
        ));
        std::fs::remove_file(&path).ok();
        path
    }

    fn scratch_spool(name: &str, max_lines: usize) -> Spool {
        Spool::with_cap(scratch_path(name), max_lines)
    }

    fn sample(at: u64) -> String {
        format!("[{},7,42,55,100,200]", at)
    }

    #[test]
    fn test_the_cap_drops_the_oldest_and_keeps_the_newest() {
        let spool = scratch_spool("cap", 4);
        for at in 1..=10 {
            spool.append(&sample(at)).unwrap();
        }
        let lines = spool.read().unwrap();
        // Not merely "four lines": the four that survive must be the last four written.
        assert_eq!(
            lines,
            vec![sample(7), sample(8), sample(9), sample(10)],
            "the cap must drop the oldest, not the newest"
        );
        spool.clear().unwrap();
    }

    #[test]
    fn test_a_long_offline_stretch_cannot_grow_the_file_without_bound() {
        let spool = scratch_spool("offline", 8);
        // Far past the cap, with nothing sent and nothing acknowledged -- the shape of a
        // machine that has been off the network for days.
        for at in 0..1_000 {
            spool.append(&sample(at)).unwrap();
        }
        let lines = spool.read().unwrap();
        assert_eq!(lines.len(), 8);
        assert_eq!(lines.first().unwrap(), &sample(992));
        assert_eq!(lines.last().unwrap(), &sample(999));
        spool.clear().unwrap();
    }

    #[test]
    fn test_lines_survive_until_a_send_is_acknowledged() {
        let spool = scratch_spool("truncate", 64);
        for at in 1..=5 {
            spool.append(&sample(at)).unwrap();
        }
        let lines = spool.read().unwrap();
        let window = batch_window(&lines, 3, MAX_BATCH_BYTES);
        assert_eq!(window, Window { dropped: 0, sent: 3 });

        // A failure, then a rejected signature: neither may cost a single sample.
        for status in [0u16, 401, 429, 500, 502] {
            assert_eq!(ack_for(status, REVOKED_BODY), Ack::Retry);
            assert_eq!(spool.read().unwrap(), lines);
        }

        // Only the acknowledgement moves the front, and it moves it by exactly what went.
        assert_eq!(ack_for(200, ""), Ack::Accepted);
        spool.drop_front(window.consumed()).unwrap();
        assert_eq!(spool.read().unwrap(), vec![sample(4), sample(5)]);
        spool.clear().unwrap();
    }

    #[test]
    fn test_the_spool_production_builds_carries_the_documented_cap() {
        // The constants by literal. These three numbers are the package's headline
        // promise -- a machine off the network for a week comes back with 2.8 days of
        // history in a quarter of a megabyte rather than an unbounded file on the disk we
        // were hired to keep healthy -- and every other test here passes its own cap, so
        // without this nothing would notice the cap being changed to eight or to a million.
        assert_eq!(MAX_LINES, 4096);
        assert_eq!(MAX_BATCH_LINES, 64);
        assert_eq!(MAX_BATCH_BYTES, 61440);
        // Section 4.4's bound on the whole body, which the server enforces as a 413. The
        // sample budget has to leave room under it for the members that ride alongside.
        assert_eq!(MAX_BODY_BYTES, 65536);
        assert!(MAX_BATCH_BYTES < MAX_BODY_BYTES);

        // And the constructor the collector actually calls really carries `MAX_LINES`,
        // exactly, rather than a cap some other test supplied. Seeded with a full spool in
        // one write so this costs one append rather than four thousand.
        let path = scratch_path("production");
        let seeded: Vec<String> = (1..=MAX_LINES as u64).map(sample).collect();
        std::fs::write(&path, format!("{}\n", seeded.join("\n"))).unwrap();
        let spool = Spool::new(path);
        spool.append(&sample(9999)).unwrap();

        let lines = spool.read().unwrap();
        assert_eq!(lines.len(), MAX_LINES, "the production cap is MAX_LINES");
        assert_eq!(
            lines.first().unwrap(),
            &sample(2),
            "one line over the cap drops exactly the oldest one"
        );
        assert_eq!(lines.last().unwrap(), &sample(9999), "and keeps the newest");
        spool.clear().unwrap();
    }

    #[test]
    fn test_a_batch_is_bounded_by_both_lines_and_bytes() {
        let lines: Vec<String> = (0..200).map(sample).collect();
        // Line-bound: 200 short lines, and exactly `MAX_BATCH_LINES` go. Asserted against
        // the literal 64 as well as the constant, since `sent == MAX_BATCH_LINES` alone
        // holds true whatever the constant is changed to.
        let window = batch_window(&lines, MAX_BATCH_LINES, MAX_BATCH_BYTES);
        assert_eq!(window.sent, 64);
        assert_eq!(window.sent, MAX_BATCH_LINES);

        // Byte-bound, on the exact boundary: each line here is 10 bytes and the separators
        // are counted, so four lines cost 4*10 + 3 = 43 and three cost 3*10 + 2 = 32.
        let ten: Vec<String> = std::iter::repeat("0123456789".to_owned()).take(9).collect();
        assert_eq!(batch_window(&ten, 64, 43).sent, 4);
        assert_eq!(batch_window(&ten, 64, 42).sent, 3);
        assert_eq!(batch_window(&ten, 64, 32).sent, 3);
        assert_eq!(batch_window(&ten, 64, 31).sent, 2);
        assert_eq!(batch_window(&ten, 64, 10).sent, 1);
        assert_eq!(batch_window(&ten, 0, 43).sent, 0);
        assert_eq!(batch_window(&[], 64, 43), Window::default());
    }

    #[test]
    fn test_an_oversized_line_is_dropped_instead_of_wedging_the_queue() {
        // A single sample larger than the whole body budget can never be sent. If it were
        // merely skipped it would sit at the front forever and every later sample would
        // starve behind it, which is the failure this asserts against.
        let huge = "x".repeat(200);
        let lines = vec![huge, sample(1), sample(2)];
        let window = batch_window(&lines, 64, 100);
        assert_eq!(window, Window { dropped: 1, sent: 2 });
        assert_eq!(window.consumed(), 3);

        // The newest is never the one sacrificed: an oversized line at the back is simply
        // not reached by this batch, and the batch before it still goes out.
        let trailing = vec![sample(1), "x".repeat(200)];
        assert_eq!(
            batch_window(&trailing, 64, 100),
            Window { dropped: 0, sent: 1 }
        );
    }

    #[test]
    fn test_the_backoff_doubles_from_the_cadence_to_one_hour_and_stops() {
        // The schedule the design names: 5 min doubling to 60 min.
        let schedule: Vec<u64> = (0..8).map(|n| backoff_seconds(300, n)).collect();
        assert_eq!(schedule, vec![300, 600, 1200, 2400, 3600, 3600, 3600, 3600]);
        assert_eq!(backoff_seconds(300, u32::MAX), MAX_BACKOFF_SECONDS);

        // Success resets, which is the caller passing zero failures again.
        assert_eq!(backoff_seconds(300, 0), 300);

        // A server that has slowed a fleet past the ceiling is not sped back up by the
        // backoff: the cadence it asked for is the floor.
        assert_eq!(backoff_seconds(7200, 0), 7200);
        assert_eq!(backoff_seconds(7200, 3), 7200);
        assert_eq!(backoff_seconds(0, 0), 1);
    }

    #[test]
    fn test_the_jitter_is_deterministic_and_inside_the_cadence() {
        // Pinned: the offset is a machine's phase in the fleet, so it must be the same
        // number after a service restart, an upgrade and a reboot. A change to the
        // derivation moves every agent at once and has to be a deliberate edit here. The
        // three values were cross-checked against .NET's SHA-256 rather than read off this
        // implementation: sha256("m-1") begins a461b472cb41a9ec, and 0xa461b472cb41a9ec
        // mod 300 is 148.
        assert_eq!(flush_jitter_seconds("m-1", 300), 148);
        assert_eq!(flush_jitter_seconds("m-1", 300), 148);
        assert_eq!(flush_jitter_seconds("m-2", 300), 71);
        assert_eq!(flush_jitter_seconds("", 300), 52);

        // Inside the cadence for every machine, so the offset delays the first flush and
        // never skips one.
        for n in 0..500 {
            let offset = flush_jitter_seconds(&format!("machine-{}", n), 300);
            assert!(offset < 300, "machine-{} offset {}", n, offset);
        }
        assert_eq!(flush_jitter_seconds("m-1", 0), 0);
        assert_eq!(flush_jitter_seconds("m-1", 1), 0);
    }

    /// The body `src/worker/agent-auth.ts` sends with its 403, verbatim.
    const REVOKED_BODY: &str = r#"{"error":"This machine has been revoked."}"#;

    #[test]
    fn test_only_the_server_saying_revoked_destroys_a_spool() {
        // The one answer that means it, and it still has to arrive with a 403.
        assert_eq!(ack_for(403, REVOKED_BODY), Ack::Revoked);
        assert_eq!(ack_for(200, REVOKED_BODY), Ack::Accepted);
        assert_eq!(ack_for(401, REVOKED_BODY), Ack::Retry);
        assert_eq!(ack_for(500, REVOKED_BODY), Ack::Retry);

        // AUDIT FINDING 8. Every one of these is a 403 that is NOT this org revoking this
        // machine, and every one of them used to delete the machine's queued telemetry.
        // A middlebox in front of a fleet would have taken the lot, and the samples only
        // ever existed on those disks.
        for body in [
            "",
            "Forbidden",
            "<!DOCTYPE html><title>403 Forbidden</title>",
            r#"{"error":"Forbidden"}"#,
            r#"{"error":"You do not have permission to access this site."}"#,
            r#"{"success":false,"errors":[{"code":1020,"message":"Access denied"}]}"#,
            // JSON, and the word is there, but not where the server puts it: a body
            // matched by a bare substring search over the response text.
            r#"{"error":"Forbidden","hint":"revoked machines are refused here"}"#,
            r#"{"message":"This machine has been revoked."}"#,
            // Not an object at all, and a null `error`.
            r#"["revoked"]"#,
            r#"{"error":null}"#,
        ] {
            assert_eq!(ack_for(403, body), Ack::Retry, "403 with body {:?}", body);
        }

        // The match is on the word, not on the punctuation around it, so the server may
        // reword its copy without stranding a fleet that can no longer be told to stop.
        assert_eq!(ack_for(403, r#"{"error":"REVOKED"}"#), Ack::Revoked);
        assert_eq!(
            ack_for(403, r#"{"error":"This machine was revoked by an administrator"}"#),
            Ack::Revoked
        );
    }

    #[test]
    fn test_a_revoked_machine_loses_its_spool_and_a_rejected_signature_does_not() {
        assert_eq!(ack_for(403, REVOKED_BODY), Ack::Revoked);
        assert_eq!(ack_for(401, REVOKED_BODY), Ack::Retry);

        let spool = scratch_spool("revoked", 64);
        spool.append(&sample(1)).unwrap();
        spool.clear().unwrap();
        assert!(spool.read().unwrap().is_empty());
        // Clearing a spool that is already gone is not an error: revocation can arrive
        // twice and the second one must not take the service down.
        spool.clear().unwrap();
    }

    #[test]
    fn test_a_line_break_is_refused_rather_than_split_into_two_records() {
        let spool = scratch_spool("linebreak", 64);
        spool.append(&sample(1)).unwrap();
        assert!(spool.append("[2,7,42,55,\n100,200]").is_err());
        assert!(spool.append("[2,7,42,55,\r100,200]").is_err());
        assert_eq!(spool.read().unwrap(), vec![sample(1)]);
        spool.clear().unwrap();
    }

    #[test]
    fn test_dropping_more_than_the_spool_holds_leaves_it_empty_not_broken() {
        let spool = scratch_spool("overdrop", 64);
        spool.append(&sample(1)).unwrap();
        spool.drop_front(9).unwrap();
        assert!(spool.read().unwrap().is_empty());
        // And it is still usable afterwards.
        spool.append(&sample(2)).unwrap();
        assert_eq!(spool.read().unwrap(), vec![sample(2)]);
        spool.drop_front(0).unwrap();
        assert_eq!(spool.read().unwrap(), vec![sample(2)]);
        spool.clear().unwrap();
    }
}
