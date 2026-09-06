// The agent's own machine credential.
//
// Deliberately not `Config::get_key_pair()`. The whole `Config` is answered to the
// unprivileged user process over IPC (`Data::SyncConfig`, src/ipc.rs) and is written into
// that user's profile, so nothing kept inside it can serve as a machine credential. This
// keypair is generated inside the privileged daemon, stored in a file `Config` does not
// know about, and never crosses IPC.

use hbb_common::{
    bail,
    config::{self, Config},
    log,
    sodiumoxide::crypto::{hash::sha256, sign},
    ResultType,
};
use serde_derive::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

const IDENTITY_FILE: &str = "agent-identity.toml";
// Used until the server says otherwise; both cadences are server controlled so a fleet
// already in the field can be slowed down.
const DEFAULT_SAMPLE_SECONDS: u64 = 60;
/// The range a pushed cadence is held to, whatever the server says.
const MIN_SAMPLE_SECONDS: u64 = 15;
const MAX_SAMPLE_SECONDS: u64 = 3600;
const MIN_FLUSH_SECONDS: u64 = 60;
const MAX_FLUSH_SECONDS: u64 = 86400;
const DEFAULT_FLUSH_SECONDS: u64 = 300;

#[derive(Default, Serialize, Deserialize)]
pub struct AgentIdentity {
    #[serde(default)]
    sk: String, // base64, 64 bytes
    #[serde(default)]
    pk: String, // base64, 32 bytes
    #[serde(default)]
    machine_id: String,
    #[serde(default)]
    sample_seconds: u64,
    #[serde(default)]
    flush_seconds: u64,
    // Where this instance came from, so a later write cannot land anywhere else.
    #[serde(skip)]
    path: PathBuf,
}

// The secret key must not reach a log line, whatever a caller does with `{:?}`.
impl std::fmt::Debug for AgentIdentity {
    fn fmt(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
        formatter
            .debug_struct("AgentIdentity")
            .field("pk", &self.pk)
            .field("machine_id", &self.machine_id)
            .field("sample_seconds", &self.sample_seconds)
            .field("flush_seconds", &self.flush_seconds)
            .finish_non_exhaustive()
    }
}

impl AgentIdentity {
    /// Where the credential lives.
    ///
    /// Deliberately not derived from the calling process's own profile. `--enrol` runs as
    /// an elevated administrator while the daemon that later signs runs as LocalSystem
    /// (`sc create {app} binpath= "{exe} --service"` carries no `obj=`,
    /// src/platform/windows.rs:3814), and those are two different roaming profiles.
    /// Registering `agent_pk` A from one and then signing with `agent_pk` B from the other
    /// would reject every uplink forever, and `machine_agent_pk_uidx` is globally unique so
    /// the machine could not be enrolled again without a fresh owner-minted token.
    ///
    /// This is the daemon's own config directory: `Config::path()` resolves LocalSystem's
    /// roaming AppData and `patch()` rewrites it to `ServiceProfiles\LocalService`
    /// (libs/hbb_common/src/config.rs:463-473). Administrators can write there and
    /// interactive users cannot read it.
    #[cfg(windows)]
    pub fn path() -> PathBuf {
        let system_root =
            std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned());
        PathBuf::from(system_root)
            .join("ServiceProfiles\\LocalService\\AppData\\Roaming")
            .join(crate::get_app_name())
            .join("config")
            .join(IDENTITY_FILE)
    }

    /// Where the credential lives. The daemon is root (`res/rustdesk.service` sets
    /// `User=root`) and so is the `sudo` that runs `--enrol`, so both resolve the same
    /// directory; that is the same scope every existing root CLI command already assumes
    /// (src/core_main.rs:210-215).
    #[cfg(not(windows))]
    pub fn path() -> PathBuf {
        Config::path(IDENTITY_FILE)
    }

    /// Load the agent identity, generating and persisting one only when no file exists.
    ///
    /// Only the privileged daemon and the equally privileged `--enrol` may call this: the
    /// file is created under whichever account is running, and the whole point of the key
    /// is that no other account holds it.
    pub fn load_or_create() -> ResultType<Self> {
        Self::load_or_create_at(&Self::path())
    }

    fn load_or_create_at(path: &Path) -> ResultType<Self> {
        if let Some(identity) = Self::load_from(path)? {
            return Ok(identity);
        }
        let (pk, sk) = sign::gen_keypair();
        // A machine id belongs to the key the server was given, so a freshly generated key
        // starts with no machine id and must be enrolled.
        let identity = Self {
            sk: crate::encode64(&sk.0[..]),
            pk: crate::encode64(&pk.0[..]),
            path: path.to_path_buf(),
            ..Default::default()
        };
        identity.store_to(path)?;
        log::info!("Generated agent identity at {}", path.display());
        Ok(identity)
    }

    /// `Ok(None)` means the file is absent and a key may be generated. Every other failure
    /// is an error rather than a fresh key: the server holds the public half, so silently
    /// replacing an identity file that merely failed to read would de-enrol the machine and
    /// destroy the only copy of the credential.
    fn load_from(path: &Path) -> ResultType<Option<Self>> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(err) => bail!("Failed to read '{}': {}", path.display(), err),
        };
        let mut identity: Self = hbb_common::toml::from_str(&text)?;
        if identity.secret_key().is_none() {
            bail!("'{}' holds no usable agent secret key", path.display());
        }
        identity.path = path.to_path_buf();
        Ok(Some(identity))
    }

    /// The base64 public key, as submitted at enrolment and looked up on every uplink.
    #[inline]
    pub fn public_key(&self) -> &str {
        &self.pk
    }

    /// The machine id the server assigned, empty until enrolment succeeds.
    #[inline]
    pub fn machine_id(&self) -> &str {
        &self.machine_id
    }

    /// How often the collector samples, in seconds. Server controlled.
    #[inline]
    pub fn sample_seconds(&self) -> u64 {
        if self.sample_seconds == 0 {
            DEFAULT_SAMPLE_SECONDS
        } else {
            // Server controlled, but not without limit: one sample a second
            // would rewrite the spool file every second on the machine this
            // product exists to keep healthy.
            self.sample_seconds.clamp(MIN_SAMPLE_SECONDS, MAX_SAMPLE_SECONDS)
        }
    }

    /// How often the collector flushes its spool, in seconds. Server controlled: this is
    /// the only way to slow a fleet that is already in the field.
    #[inline]
    pub fn flush_seconds(&self) -> u64 {
        if self.flush_seconds == 0 {
            DEFAULT_FLUSH_SECONDS
        } else {
            self.flush_seconds.clamp(MIN_FLUSH_SECONDS, MAX_FLUSH_SECONDS)
        }
    }

    /// Pin what the server assigned at enrolment. A zero cadence means "unspecified" and
    /// leaves the reader on its default.
    pub fn set_enrolment(
        &mut self,
        machine_id: &str,
        sample_seconds: u64,
        flush_seconds: u64,
    ) -> ResultType<()> {
        self.machine_id = machine_id.to_owned();
        self.sample_seconds = sample_seconds;
        self.flush_seconds = flush_seconds;
        self.store()
    }

    /// Adopt the flush cadence the server echoes in every batch response. A no-op when it
    /// has not moved, so a five-minute flush does not rewrite the file 288 times a day.
    pub fn set_flush_seconds(&mut self, flush_seconds: u64) -> ResultType<()> {
        if flush_seconds == 0 || flush_seconds == self.flush_seconds {
            return Ok(());
        }
        self.flush_seconds = flush_seconds;
        self.store()
    }

    /// Sign `msg` with the agent secret key, returning the base64 detached signature.
    pub fn sign(&self, msg: &[u8]) -> ResultType<String> {
        let Some(sk) = self.secret_key() else {
            bail!("No agent identity secret key");
        };
        Ok(crate::encode64(sign::sign_detached(msg, &sk).to_bytes()))
    }

    fn secret_key(&self) -> Option<sign::SecretKey> {
        sign::SecretKey::from_slice(&crate::decode64(&self.sk).ok()?)
    }

    fn store(&self) -> ResultType<()> {
        self.store_to(&self.path)
    }

    fn store_to(&self, path: &Path) -> ResultType<()> {
        // `store_path` writes the file 0600 on unix, see libs/hbb_common/src/config.rs.
        config::store_path(path.to_path_buf(), self)?;
        #[cfg(windows)]
        {
            // Windows has no mode bits. The directory is the LocalService profile, which
            // interactive users cannot read; this narrows the file itself to SYSTEM plus
            // Administrators plus the writing account. A failure is fatal rather than a
            // warning: a machine credential must not be left on disk under an ACL we did
            // not set.
            if let Err(err) =
                crate::platform::set_path_permission_for_portable_service_shmem_file(path)
            {
                std::fs::remove_file(path).ok();
                bail!("Failed to restrict '{}': {}", path.display(), err);
            }
        }
        Ok(())
    }
}

/// `b"labdesk-enrol-v1\0" || sha256_hex(token) || \0 || agent_pk || \0 || peer_id || \0 || ts`
pub fn enrol_signed_msg(token: &str, agent_pk: &str, peer_id: &str, ts: &str) -> Vec<u8> {
    let token_hash = sha256_hex(token.as_bytes());
    let mut msg = Vec::with_capacity(
        17 + token_hash.len() + 1 + agent_pk.len() + 1 + peer_id.len() + 1 + ts.len(),
    );
    msg.extend_from_slice(b"labdesk-enrol-v1\0");
    msg.extend_from_slice(token_hash.as_bytes());
    msg.push(0);
    msg.extend_from_slice(agent_pk.as_bytes());
    msg.push(0);
    msg.extend_from_slice(peer_id.as_bytes());
    msg.push(0);
    msg.extend_from_slice(ts.as_bytes());
    msg
}

/// `b"labdesk-agent-v1\0" || method || \0 || path || \0 || ts || \0 || sha256_hex(body)`
pub fn uplink_signed_msg(method: &str, path: &str, ts: &str, body: &[u8]) -> Vec<u8> {
    let body_hash = sha256_hex(body);
    let mut msg =
        Vec::with_capacity(17 + method.len() + 1 + path.len() + 1 + ts.len() + 1 + body_hash.len());
    msg.extend_from_slice(b"labdesk-agent-v1\0");
    msg.extend_from_slice(method.as_bytes());
    msg.push(0);
    msg.extend_from_slice(path.as_bytes());
    msg.push(0);
    msg.extend_from_slice(ts.as_bytes());
    msg.push(0);
    msg.extend_from_slice(body_hash.as_bytes());
    msg
}

#[inline]
fn sha256_hex(bytes: &[u8]) -> String {
    hex::encode(sha256::hash(bytes).0)
}

/// Enrol this machine: prove possession of the agent key against a single-use token an
/// org owner minted, and pin the machine id and cadences the server assigns.
///
/// `peer_id` is this machine's nine-digit id: `crate::ipc::get_id()` from the CLI, and
/// `Config::get_id()` inside the daemon, which cannot ask itself over IPC.
///
/// The machine plane is always lab-desk.net. The `api-server` option is the profile's
/// hbbs API, which on a machine whose config still carries the RustDesk name is a
/// server that has never heard of `/agent/*` (`get_api_server_`, src/common.rs).
#[cfg(not(any(target_os = "android", target_os = "ios")))]
pub fn enrol(token: &str, peer_id: &str) -> ResultType<String> {
    let mut identity = AgentIdentity::load_or_create()?;
    let ts = (hbb_common::get_time() / 1000).to_string();
    let signature = identity.sign(&enrol_signed_msg(
        token,
        identity.public_key(),
        peer_id,
        &ts,
    ))?;
    let body = serde_json::json!({
        "token": token,
        "peer_id": peer_id,
        "agent_pk": identity.public_key(),
        "id_pk": crate::encode64(Config::get_key_pair().1),
        "machine_uuid": crate::encode64(hbb_common::get_uuid()),
        "sysinfo": crate::get_sysinfo(),
        "ts": ts,
        "sig": signature,
    })
    .to_string();
    let url = format!("{}/agent/enrol", crate::LABDESK_SITE);
    let text = crate::post_request_sync(url, body, "")?;
    let response = serde_json::from_str::<serde_json::Value>(&text)?;
    let Some(machine_id) = response["machineId"].as_str() else {
        bail!("Enrolment rejected: {}", text);
    };
    identity.set_enrolment(
        machine_id,
        response["sampleSeconds"].as_u64().unwrap_or_default(),
        response["flushSeconds"].as_u64().unwrap_or_default(),
    )?;
    Ok(machine_id.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU32, Ordering};

    // The vector labdesk-site/test/fixtures/agent-sig.json holds, generated by
    // labdesk-site/test/fixtures/gen-agent-sig.mjs and asserted by
    // labdesk-site/test/ed25519.test.ts. The signature below was produced by node, so a
    // Rust change to the message layout stops it verifying here.
    const FIXTURE_TS: &str = "1788480000";
    const FIXTURE_BODY: &[u8] = br#"{"cpu":7}"#;
    const FIXTURE_MESSAGE_B64: &str = "bGFiZGVzay1hZ2VudC12MQBQT1NUAC9hZ2VudC9zdGF0ZQAxNzg4NDgwMDAwADljOWIxZWFmZDNkZmU0NzEwMzM1YzFjMmJiNDBmZDdkZGUzNTFiMWExZjlmYjJjNWVjZmNkM2Y4YzBmN2E4MGI=";
    const FIXTURE_PUBLIC_KEY_B64: &str = "abdG8ROOJSgJydAjqLgpPZ+PcyK6k2twpmSxLWea6jI=";
    const FIXTURE_SIGNATURE_B64: &str =
        "tSWGj4MjTqBDIaNa6vKXcqBqPmBpDy1xZWtPgZ4ktE7VugZlsocD8KggJP1cJrByQ7/rB9RzcCDQv/M0H9wiBA==";
    const FIXTURE_OTHER_PUBLIC_KEY_B64: &str = "HvZDz0mZSHZh0oE/K0eSfU/bvmKyTGUVvRCQHMc1Keg=";

    fn fixed_identity() -> (AgentIdentity, sign::PublicKey) {
        let (pk, sk) = sign::gen_keypair();
        let identity = AgentIdentity {
            sk: crate::encode64(&sk.0[..]),
            pk: crate::encode64(&pk.0[..]),
            ..Default::default()
        };
        (identity, pk)
    }

    fn scratch_path(name: &str) -> PathBuf {
        static COUNTER: AtomicU32 = AtomicU32::new(0);
        let path = std::env::temp_dir().join(format!(
            "labdesk-identity-test-{}-{}-{}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed),
            name
        ));
        std::fs::remove_file(&path).ok();
        path
    }

    fn signature(base64: &str) -> sign::Signature {
        sign::Signature::from_bytes(&crate::decode64(base64).unwrap()).unwrap()
    }

    fn public_key(base64: &str) -> sign::PublicKey {
        sign::PublicKey::from_slice(&crate::decode64(base64).unwrap()).unwrap()
    }

    #[test]
    fn test_enrol_signed_msg_layout() {
        let expected: Vec<u8> = [
            &b"labdesk-enrol-v1\0"[..],
            // sha256_hex("tok")
            b"1a7674eb4ee78df7e1ac439a93c3fa8e3c945784d4dec9fd8e3011738b2f1d62",
            b"\0",
            b"pk1",
            b"\0",
            b"123456789",
            b"\0",
            b"1700000000",
        ]
        .concat();
        assert_eq!(
            enrol_signed_msg("tok", "pk1", "123456789", "1700000000"),
            expected
        );
    }

    #[test]
    fn test_uplink_signed_msg_matches_the_worker_side_fixture() {
        assert_eq!(
            uplink_signed_msg("POST", "/agent/state", FIXTURE_TS, FIXTURE_BODY),
            crate::decode64(FIXTURE_MESSAGE_B64).unwrap()
        );
    }

    #[test]
    fn test_a_worker_side_signature_verifies_against_this_message_layout() {
        // Cross-language: the signature was made by node over the fixture's message. If
        // either side moves the layout, one of the two suites fails.
        let msg = uplink_signed_msg("POST", "/agent/state", FIXTURE_TS, FIXTURE_BODY);
        assert!(sign::verify_detached(
            &signature(FIXTURE_SIGNATURE_B64),
            &msg,
            &public_key(FIXTURE_PUBLIC_KEY_B64)
        ));
    }

    #[test]
    fn test_sign_round_trips_and_rejects_a_tampered_message() {
        let (identity, pk) = fixed_identity();
        let msg = enrol_signed_msg("tok", identity.public_key(), "123456789", "1700000000");
        let sig = signature(&identity.sign(&msg).unwrap());
        assert!(sign::verify_detached(&sig, &msg, &pk));

        let tampered = enrol_signed_msg("tok", identity.public_key(), "987654321", "1700000000");
        assert!(!sign::verify_detached(&sig, &tampered, &pk));
    }

    #[test]
    fn test_key_round_trips_through_the_stored_file_format() {
        let (identity, pk) = fixed_identity();
        let stored = hbb_common::toml::to_string(&identity).unwrap();
        let reloaded: AgentIdentity = hbb_common::toml::from_str(&stored).unwrap();
        assert_eq!(reloaded.public_key(), identity.public_key());

        // This is exactly what the Worker does: resolve the key from what was stored at
        // enrolment, then verify. A key that does not round trip breaks every uplink.
        let msg = uplink_signed_msg("POST", "/agent/state", FIXTURE_TS, FIXTURE_BODY);
        let sig = signature(&reloaded.sign(&msg).unwrap());
        assert!(sign::verify_detached(&sig, &msg, &pk));
        assert!(sign::verify_detached(
            &sig,
            &msg,
            &public_key(reloaded.public_key())
        ));
    }

    #[test]
    fn test_signature_does_not_verify_under_another_agents_key() {
        // The cross-machine guard: `otherPublicKeyRawB64` is the second key the Worker
        // fixture carries for exactly this negative case.
        let msg = uplink_signed_msg("POST", "/agent/state", FIXTURE_TS, FIXTURE_BODY);
        assert!(!sign::verify_detached(
            &signature(FIXTURE_SIGNATURE_B64),
            &msg,
            &public_key(FIXTURE_OTHER_PUBLIC_KEY_B64)
        ));
    }

    #[test]
    fn test_load_or_create_generates_once_and_then_never_re_keys() {
        let path = scratch_path("rekey.toml");
        let first = AgentIdentity::load_or_create_at(&path).unwrap();
        assert!(!first.public_key().is_empty());
        assert!(first.machine_id().is_empty());

        // An enrolled machine: the second load must return this key, not a new one.
        let mut enrolled = AgentIdentity::load_or_create_at(&path).unwrap();
        enrolled.set_enrolment("m-1", 30, 900).unwrap();

        let second = AgentIdentity::load_or_create_at(&path).unwrap();
        assert_eq!(second.public_key(), first.public_key());
        assert_eq!(second.sk, first.sk);
        assert_eq!(second.machine_id(), "m-1");
        assert_eq!(second.sample_seconds(), 30);
        assert_eq!(second.flush_seconds(), 900);
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_load_or_create_refuses_to_overwrite_an_unreadable_identity() {
        let path = scratch_path("corrupt.toml");
        // A truncated write, a hand edit, half a disk: anything that is not "absent".
        let corrupt = "sk = \"not closed\n";
        std::fs::write(&path, corrupt).unwrap();
        assert!(AgentIdentity::load_or_create_at(&path).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), corrupt);

        // Present, parseable, but carrying no usable key is equally not "absent".
        std::fs::write(&path, "pk = \"only-the-public-half\"\n").unwrap();
        assert!(AgentIdentity::load_or_create_at(&path).is_err());
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "pk = \"only-the-public-half\"\n"
        );
        std::fs::remove_file(&path).ok();
    }

    #[test]
    fn test_the_cadence_falls_back_only_while_the_server_has_not_spoken() {
        let path = scratch_path("cadence.toml");
        let mut identity = AgentIdentity::load_or_create_at(&path).unwrap();
        assert_eq!(identity.sample_seconds(), DEFAULT_SAMPLE_SECONDS);
        assert_eq!(identity.flush_seconds(), DEFAULT_FLUSH_SECONDS);

        identity.set_enrolment("m-2", 0, 0).unwrap();
        assert_eq!(identity.flush_seconds(), DEFAULT_FLUSH_SECONDS);

        // The escape valve: a fleet already in the field is slowed by the batch response.
        identity.set_flush_seconds(1800).unwrap();
        assert_eq!(
            AgentIdentity::load_or_create_at(&path)
                .unwrap()
                .flush_seconds(),
            1800
        );
        std::fs::remove_file(&path).ok();
    }

    #[cfg(not(windows))]
    #[test]
    fn test_the_identity_file_is_written_0600() {
        use std::os::unix::fs::PermissionsExt;
        let path = scratch_path("mode.toml");
        AgentIdentity::load_or_create_at(&path).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        std::fs::remove_file(&path).ok();
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn test_no_agent_secret_key_reaches_config() {
        // `Config` is answered to the unprivileged user process over IPC, so the agent
        // secret must never share its file, and persisting an identity must not put a byte
        // of the secret anywhere `Config` writes.
        let path = scratch_path("guard.toml");
        let identity = AgentIdentity::load_or_create_at(&path).unwrap();
        let secret = identity.sk.clone();
        assert!(std::fs::read_to_string(&path).unwrap().contains(&secret));
        assert_ne!(AgentIdentity::path(), Config::file());

        // Both renderings the key could take in that file: base64, and the decimal byte
        // array `Config` already writes for its own `key_pair`.
        let decimals = crate::decode64(&secret)
            .unwrap()
            .iter()
            .map(|byte| byte.to_string())
            .collect::<Vec<_>>()
            .join(", ");
        let mut checked = vec![hbb_common::toml::to_string(&Config::get()).unwrap()];
        for entry in std::fs::read_dir(Config::path("")).into_iter().flatten() {
            let Ok(entry) = entry else { continue };
            checked.push(std::fs::read_to_string(entry.path()).unwrap_or_default());
        }
        for text in checked {
            assert!(!text.contains(&secret));
            assert!(!text.contains(&decimals));
        }
        assert!(!format!("{:?}", identity).contains(&secret));
        std::fs::remove_file(&path).ok();
    }

    // On Windows the enrolling administrator and the signing daemon are different
    // profiles, so the credential must not live in the caller's own config directory.
    // CI compiles no Windows target (.github/workflows/ci.yml:74-86), so this assertion
    // only ever runs on a developer machine.
    #[cfg(windows)]
    #[test]
    fn test_the_identity_is_not_kept_in_the_calling_accounts_profile() {
        let path = AgentIdentity::path();
        assert!(!path.starts_with(Config::path("")), "{}", path.display());
        assert!(path.starts_with(
            std::env::var("SystemRoot").unwrap_or_else(|_| "C:\\Windows".to_owned())
        ));
    }
}
