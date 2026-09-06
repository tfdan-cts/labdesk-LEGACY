// Connect tickets, the target's half.
//
// A ticket is minted by the Worker when a console opens a session, delivered
// to the target machine in the `tickets` member of the `/agent/tickets` answer
// (also `/agent/batch` for compatibility),
// and handed by this daemon to the `--server` process that answers logins,
// over the main IPC channel `""` (0600 on Linux and macOS; on Windows the same
// LocalSystem `--server`). `--server` keeps a claim-once map keyed by the
// controller's peer id (`src/server/connection.rs`, beside
// `PENDING_SWITCH_SIDES_UUID`), and a login from that peer presenting
// `sha256(H || salt)` claims it exactly once. Only spent IDs and their expiry
// persist in the privileged machine ledger before authentication succeeds. The inbox can therefore
// redeliver after a login-process restart without authorizing a replay.
//
// `H` is `sha256Hex(secret)` in the Worker's terms (`src/worker/crypto.ts`,
// SHA-256 over the UTF-8 bytes of the string). The delivery carries `H` itself
// when the row already holds it, and the plaintext only when the Worker chose
// to send that instead; `secret_hash` takes either, so the two lanes cannot
// disagree about which one arrived.

use hbb_common::{bail, log, sodiumoxide::crypto::hash::sha256, ResultType};
use serde_derive::Deserialize;
use std::{collections::BTreeMap, io::Write, path::PathBuf};

/// The privileged process loads this once, then writes only on a matching claim.
/// No ticket secret is persisted. Unreadable/corrupt storage is an error, never
/// an empty ledger, because redelivery must not revive a spent credential.
pub struct SpentTickets {
    path: PathBuf,
    spent: BTreeMap<String, i64>,
}

#[cfg(not(any(target_os = "android", target_os = "ios")))]
lazy_static::lazy_static! {
    static ref MACHINE_SPENT_TICKETS: std::sync::Mutex<ResultType<SpentTickets>> =
        std::sync::Mutex::new(SpentTickets::load(
            super::identity::AgentIdentity::path().with_file_name("labdesk-spent-tickets.json")
        ));
}

/// Only the machine service may persist claims, even when the desktop user changes.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn spend_here(id: &str, expires_at: i64) -> ResultType<bool> {
    if !crate::platform::is_root() {
        bail!("Not the privileged LabDesk process");
    }
    let now = hbb_common::get_time() / 1000;
    if expires_at > now + 86400 {
        bail!("ticket expiry exceeds the machine retention limit");
    }
    let mut ledger = MACHINE_SPENT_TICKETS.lock().map_err(|_| hbb_common::anyhow::anyhow!("spent-ticket lock unavailable"))?;
    match ledger.as_mut() {
        Ok(ledger) => ledger.spend(id, expires_at, now),
        Err(err) => bail!("spent-ticket storage unavailable: {}", err),
    }
}

/// Login validation is synchronous and may be inside Tokio. Run the bounded
/// service request on a separate thread rather than nesting another runtime.
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn spend_on_machine(id: &str, expires_at: i64) -> ResultType<bool> {
    // Even an elevated caller uses the designated service: separate process
    // caches of the same file would not serialize one-time spends.
    let request = super::labnet::LabnetRequest::SpendTicket { id: id.to_owned(), expires_at };
    let answer = std::thread::Builder::new().name("labdesk-ticket-spend".into())
        .spawn(move || crate::ipc::labnet(request))?
        .join().map_err(|_| hbb_common::anyhow::anyhow!("ticket spend request failed"))??;
    match answer.as_str() {
        "true" => Ok(true),
        "false" => Ok(false),
        _ => bail!("invalid ticket spend answer"),
    }
}

#[cfg(any(target_os = "android", target_os = "ios"))]
pub fn spend_on_machine(_: &str, _: i64) -> ResultType<bool> {
    bail!("machine ticket authentication requires the desktop service");
}

impl SpentTickets {
    pub fn load(path: PathBuf) -> ResultType<Self> {
        let spent: BTreeMap<String, i64> = match std::fs::read(&path) {
            Ok(bytes) => serde_json::from_slice(&bytes)?,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
            Err(err) => return Err(err.into()),
        };
        if spent.keys().any(|id| !is_ticket_id(id)) {
            bail!("invalid spent-ticket ledger");
        }
        Ok(Self { path, spent })
    }

    /// True only after the one-time spend is durably stored. A failed write
    /// also leaves the ID spent in memory, so retries remain fail-closed.
    pub fn spend(&mut self, id: &str, expires_at: i64, now: i64) -> ResultType<bool> {
        if !is_ticket_id(id) || expires_at <= now {
            return Ok(false);
        }
        self.spent.retain(|_, expires| *expires > now);
        if self.spent.contains_key(id) {
            return Ok(false);
        }
        self.spent.insert(id.to_owned(), expires_at);
        let parent = self
            .path
            .parent()
            .ok_or_else(|| std::io::Error::other("missing ledger directory"))?;
        std::fs::create_dir_all(parent)?;
        let tmp = self.path.with_extension("tmp");
        // A previous interrupted write never granted authentication. Remove
        // its temporary file before exclusive creation (also avoids symlinks).
        match std::fs::remove_file(&tmp) {
            Ok(()) => (),
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => (),
            Err(err) => return Err(err.into()),
        }
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&tmp)?;
        file.write_all(&serde_json::to_vec(&self.spent)?)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp, &self.path)?;
        #[cfg(unix)]
        std::fs::File::open(parent)?.sync_all()?;
        Ok(true)
    }
}

/// One ticket as the batch answer carries it.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Ticket {
    pub id: String,
    pub secret: String,
    pub controller_peer_id: String,
    pub expires_at: i64,
}

/// The `tickets` member of a batch answer. Absent is empty; an entry that
/// does not parse is skipped, because the rest are still owed to `--server`.
pub fn tickets_in(text: &str) -> Vec<Ticket> {
    let Ok(answer) = serde_json::from_str::<serde_json::Value>(text) else {
        return Vec::new();
    };
    answer["tickets"]
        .as_array()
        .map(|entries| {
            entries
                .iter()
                .filter_map(
                    |entry| match serde_json::from_value::<Ticket>(entry.clone()) {
                        Ok(ticket) if is_ticket_id(&ticket.id) => Some(ticket),
                        Ok(_) => None,
                        Err(err) => {
                            log::warn!("[ticket] Skipping a ticket the answer mis-shaped: {}", err);
                            None
                        }
                    },
                )
                .collect()
        })
        .unwrap_or_default()
}

/// `H`: the delivered value when it already is a SHA-256 hex digest, else
/// the digest of the delivered string's bytes.
pub fn secret_hash(delivered: &str) -> String {
    if delivered.len() == 64 && delivered.bytes().all(|b| b.is_ascii_hexdigit()) {
        return delivered.to_ascii_lowercase();
    }
    hex::encode(sha256::hash(delivered.as_bytes()).0)
}

/// Ask the `--server` that answers logins on this machine one question and
/// read its answer.
///
/// Linux and macOS: the daemon is root and `--server` runs as the seat0 user,
/// whose main channel is under that user's runtime directory, so the connect
/// names the uid. Windows: one named pipe, served by the LocalSystem
/// `--server`.
async fn ask(data: crate::ipc::Data) -> ResultType<crate::ipc::Data> {
    #[cfg(any(target_os = "linux", target_os = "macos"))]
    let mut conn = {
        let uid = crate::platform::get_active_userid();
        let Ok(uid) = uid.trim().parse::<u32>() else {
            bail!("no active user whose --server answers logins");
        };
        crate::ipc::connect_for_uid(1000, uid, "").await?
    };
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    let mut conn = crate::ipc::connect(1000, "").await?;
    conn.send(&data).await?;
    match conn.next_timeout(1000).await? {
        Some(answer) => Ok(answer),
        None => bail!("no answer from --server"),
    }
}

/// Hand one ticket to the `--server` that answers logins on this machine.
pub async fn deliver(ticket: &Ticket) -> ResultType<()> {
    let data = crate::ipc::Data::ConnectTicket {
        id: ticket.id.clone(),
        controller_peer_id: ticket.controller_peer_id.clone(),
        secret_hash: secret_hash(&ticket.secret),
        expires_at: ticket.expires_at,
    };
    // `--server` answers `Empty` once the map holds the ticket, so a delivery
    // that was refused or dropped is an error here rather than a silent gap.
    match ask(data).await? {
        crate::ipc::Data::Empty => Ok(()),
        _ => bail!("no answer from --server for ticket {}", ticket.id),
    }
}

/// The tickets `--server` has claimed since the last ask, for the daemon to
/// report with `POST /agent/ticket/:id/claimed` (section 3 of the phase 1
/// contracts). Each id is reported once: `--server` marks it as it hands it
/// over.
pub async fn claimed() -> ResultType<Vec<String>> {
    match ask(crate::ipc::Data::ClaimedTickets(Vec::new())).await? {
        crate::ipc::Data::ClaimedTickets(ids) => {
            Ok(ids.into_iter().filter(|id| is_ticket_id(id)).collect())
        }
        _ => bail!("no claimed-ticket answer from --server"),
    }
}

/// An id fit to be pasted into the path of `POST /agent/ticket/:id/claimed`.
/// The ids come back across a process boundary -- on Linux and macOS from a
/// process running as the logged-in user -- so what reaches a URL is checked
/// here rather than trusted.
pub fn is_ticket_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 64
        && id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ledger_path() -> PathBuf {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let n = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir()
            .join(format!("labdesk-spent-{}-{stamp}-{n}", std::process::id()))
            .join("spent.json")
    }

    #[test]
    fn spent_ticket_survives_restart_and_live_entries_are_never_evicted() {
        let path = ledger_path();
        let mut ledger = SpentTickets::load(path.clone()).unwrap();
        assert!(ledger.spend("ticket-1", 200, 100).unwrap());
        assert!(!ledger.spend("ticket-1", 200, 100).unwrap());
        assert!(ledger.spend("ticket-2", 300, 100).unwrap());
        let mut restarted = SpentTickets::load(path.clone()).unwrap();
        assert!(!restarted.spend("ticket-1", 200, 100).unwrap());
        assert!(!restarted.spend("ticket-2", 300, 100).unwrap());
        // Claim checks use the loaded cache; no disk read is needed for replay.
        std::fs::remove_file(&path).unwrap();
        assert!(!restarted.spend("ticket-1", 200, 100).unwrap());
        std::fs::remove_dir(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn concurrent_desktop_claims_share_one_machine_spend() {
        let path = ledger_path();
        let ledger = std::sync::Arc::new(std::sync::Mutex::new(SpentTickets::load(path.clone()).unwrap()));
        let claims: Vec<_> = (0..2).map(|_| {
            let ledger = ledger.clone();
            std::thread::spawn(move || ledger.lock().unwrap().spend("same-machine-ticket", 200, 100).unwrap())
        }).collect();
        assert_eq!(claims.into_iter().map(|claim| claim.join().unwrap()).filter(|spent| *spent).count(), 1);
        let mut restarted = SpentTickets::load(path.clone()).unwrap();
        assert!(!restarted.spend("same-machine-ticket", 200, 100).unwrap());
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_dir(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn spent_ticket_prunes_expired_entries_and_rejects_invalid_or_expired_claims() {
        let path = ledger_path();
        let mut ledger = SpentTickets::load(path.clone()).unwrap();
        assert!(!ledger.spend("../bad", 300, 100).unwrap());
        assert!(!ledger.spend("expired", 100, 100).unwrap());
        assert!(ledger.spend("old", 150, 100).unwrap());
        assert!(ledger.spend("live", 300, 150).unwrap());
        let saved: BTreeMap<String, i64> =
            serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(saved, BTreeMap::from([("live".to_owned(), 300)]));
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_dir(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn corrupt_or_unreadable_spent_ticket_storage_fails_closed() {
        let path = ledger_path();
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, b"{broken").unwrap();
        assert!(SpentTickets::load(path.clone()).is_err());
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(SpentTickets::load(path.clone()).is_err());
        std::fs::remove_dir(&path).unwrap();
        std::fs::remove_dir(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn failed_spend_write_never_grants_a_claim() {
        let path = ledger_path();
        let mut ledger = SpentTickets::load(path.clone()).unwrap();
        // A directory at the file's destination makes the final rename fail.
        std::fs::create_dir_all(&path).unwrap();
        assert!(ledger.spend("ticket", 200, 100).is_err());
        assert!(!ledger.spend("ticket", 200, 100).unwrap());
        assert!(SpentTickets::load(path.clone()).is_err());
        std::fs::remove_file(path.with_extension("tmp")).unwrap();
        std::fs::remove_dir(&path).unwrap();
        std::fs::remove_dir(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn the_tickets_member_is_read_by_name() {
        let tickets = tickets_in(
            r#"{"ok":true,"jobs":[],"tickets":[
                {"id":"t1","secret":"c2VjcmV0","controllerPeerId":"1935956186","expiresAt":1788480243},
                {"id":"bad"}
            ]}"#,
        );
        assert_eq!(
            tickets,
            vec![Ticket {
                id: "t1".into(),
                secret: "c2VjcmV0".into(),
                controller_peer_id: "1935956186".into(),
                expires_at: 1788480243,
            }]
        );
        assert!(tickets_in(r#"{"ok":true}"#).is_empty());
        assert!(tickets_in("nope").is_empty());
    }

    /// Nothing but an id the Worker could have minted reaches a URL path.
    #[test]
    fn a_ticket_id_that_could_reshape_a_url_is_dropped() {
        assert!(is_ticket_id("2f1c9b7a-0d4e-4b1a-9f00-7c3d5e6f8a91"));
        assert!(is_ticket_id("t1"));
        assert!(!is_ticket_id(""));
        assert!(!is_ticket_id("../../agent/batch"));
        assert!(!is_ticket_id("t1/claimed?x=1"));
        assert!(!is_ticket_id("t 1"));
        assert!(!is_ticket_id(&"t".repeat(65)));
        assert!(tickets_in(r#"{"tickets":[{"id":"../../batch","secret":"a","controllerPeerId":"12","expiresAt":1}]}"#).is_empty());
    }

    /// The Worker's `sha256Hex` is SHA-256 over the UTF-8 bytes of the
    /// string, hex encoded. The same input must give the same `H` here, and a
    /// value that already is an `H` must pass through untouched.
    #[test]
    fn the_secret_hash_matches_the_workers_sha256hex() {
        assert_eq!(
            secret_hash("secret"),
            "2bb80d537b1da3e38bd30361aa855686bde0eacd7162fef6a25fe97bf527a25b"
        );
        let h = "2BB80D537B1DA3E38BD30361AA855686BDE0EACD7162FEF6A25FE97BF527A25B";
        assert_eq!(secret_hash(h), h.to_ascii_lowercase());
        // Sixty four characters that are not all hex are a secret, not a hash.
        let not_hex = "zz".repeat(32);
        assert_ne!(secret_hash(&not_hex), not_hex);
        assert_eq!(secret_hash(&not_hex).len(), 64);
    }
}
