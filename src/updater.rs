use crate::{common::do_check_software_update, hbbs_http::create_http_client_with_url_strict};
use hbb_common::{bail, config, log, sodiumoxide::crypto::sign, ResultType};
use std::{
    io::{Read, Write},
    path::{Component, Path, PathBuf},
    sync::{
        atomic::{AtomicUsize, Ordering},
        mpsc::{channel, Receiver, Sender},
        Mutex,
    },
    time::{Duration, Instant},
};

#[cfg(target_os = "macos")]
use std::os::{
    fd::AsRawFd,
    unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
};

#[cfg(target_os = "linux")]
use std::os::unix::fs::{MetadataExt, PermissionsExt};

#[cfg(target_os = "macos")]
struct MacUpdateLock {
    _file: std::fs::File,
}

#[cfg(target_os = "macos")]
fn acquire_mac_update_lock() -> ResultType<MacUpdateLock> {
    let path = std::path::PathBuf::from("/var/run/labdesk-update.lock");
    let handle = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .custom_flags(hbb_common::libc::O_NOFOLLOW | hbb_common::libc::O_CLOEXEC)
        .open(&path)?;
    let metadata = handle.metadata()?;
    if !metadata.file_type().is_file() || metadata.uid() != 0 {
        bail!("[root-update] update lock is not a root-owned regular file");
    }
    handle.set_permissions(std::fs::Permissions::from_mode(0o600))?;

    // Keep the descriptor open through update preparation and detached-script
    // launch. O_CLOEXEC means this lock does not cover the detached bundle
    // swap; flock is released when this guard is dropped or the process exits.
    let lock_result = unsafe {
        hbb_common::libc::flock(
            handle.as_raw_fd(),
            hbb_common::libc::LOCK_EX | hbb_common::libc::LOCK_NB,
        )
    };
    if lock_result != 0 {
        let err = std::io::Error::last_os_error();
        if err.kind() == std::io::ErrorKind::WouldBlock {
            bail!("[root-update] another update is already running");
        }
        return Err(err.into());
    }
    Ok(MacUpdateLock { _file: handle })
}

enum UpdateMsg {
    CheckUpdate,
    Exit,
}

lazy_static::lazy_static! {
    static ref TX_MSG : Mutex<Sender<UpdateMsg>> = Mutex::new(start_auto_update_check());
}

static CONTROLLING_SESSION_COUNT: AtomicUsize = AtomicUsize::new(0);

/// Initial wait after startup before the first update check (30 seconds).
pub const INITIAL_CHECK_DELAY: Duration = Duration::from_secs(30);

/// One full day — default interval between update checks.
pub const DUR_ONE_DAY: Duration = Duration::from_secs(60 * 60 * 24);

/// Minimum interval between consecutive update checks (10 minutes).
pub const MIN_INTERVAL: Duration = Duration::from_secs(60 * 10);

/// Retry interval when an update check fails or a session is active (30 minutes).
pub const RETRY_INTERVAL: Duration = Duration::from_secs(60 * 30);

pub fn update_controlling_session_count(count: usize) {
    CONTROLLING_SESSION_COUNT.store(count, Ordering::SeqCst);
}

#[allow(dead_code)]
pub fn start_auto_update() {
    let _sender = TX_MSG.lock().unwrap();
}

#[allow(dead_code)]
pub fn manually_check_update() -> ResultType<()> {
    let sender = TX_MSG.lock().unwrap();
    sender.send(UpdateMsg::CheckUpdate)?;
    Ok(())
}

#[allow(dead_code)]
pub fn stop_auto_update() {
    let sender = TX_MSG.lock().unwrap();
    sender.send(UpdateMsg::Exit).unwrap_or_default();
}

#[inline]
/// Returns true when there are no active incoming or outgoing connections.
/// Used to avoid updating while a remote session is in progress.
pub fn has_no_active_conns() -> bool {
    let conns = crate::Connection::alive_conns();
    conns.is_empty() && has_no_controlling_conns()
}

#[cfg(any(not(target_os = "windows"), feature = "flutter"))]
fn has_no_controlling_conns() -> bool {
    CONTROLLING_SESSION_COUNT.load(Ordering::SeqCst) == 0
}

#[cfg(not(any(not(target_os = "windows"), feature = "flutter")))]
fn has_no_controlling_conns() -> bool {
    let app_exe = format!("{}.exe", crate::get_app_name().to_lowercase());
    for arg in [
        "--connect",
        "--play",
        "--file-transfer",
        "--view-camera",
        "--port-forward",
        "--rdp",
    ] {
        if !crate::platform::get_pids_of_process_with_first_arg(&app_exe, arg).is_empty() {
            return false;
        }
    }
    true
}

fn start_auto_update_check() -> Sender<UpdateMsg> {
    let (tx, rx) = channel();
    std::thread::spawn(move || start_auto_update_check_(rx));
    return tx;
}

fn start_auto_update_check_(rx_msg: Receiver<UpdateMsg>) {
    std::thread::sleep(INITIAL_CHECK_DELAY);
    if let Err(e) = check_update(false) {
        log::error!("Error checking for updates: {}", e);
    }

    let mut last_check_time = Instant::now();
    let mut check_interval = DUR_ONE_DAY;
    loop {
        let recv_res = rx_msg.recv_timeout(check_interval);
        match &recv_res {
            Ok(UpdateMsg::CheckUpdate) | Err(_) => {
                if last_check_time.elapsed() < MIN_INTERVAL {
                    // log::debug!("Update check skipped due to minimum interval.");
                    continue;
                }
                // Don't check update if there are alive connections.
                if !has_no_active_conns() {
                    check_interval = RETRY_INTERVAL;
                    continue;
                }
                if let Err(e) = check_update(matches!(recv_res, Ok(UpdateMsg::CheckUpdate))) {
                    log::error!("Error checking for updates: {}", e);
                    check_interval = RETRY_INTERVAL;
                } else {
                    last_check_time = Instant::now();
                    check_interval = DUR_ONE_DAY;
                }
            }
            Ok(UpdateMsg::Exit) => break,
        }
    }
}

fn check_update(manually: bool) -> ResultType<()> {
    // On macOS, auto-update is handled by check_update_as_root() in the service process.
    // The shared check_update() path is only used for manual update checks from the GUI.
    #[cfg(target_os = "macos")]
    if !manually {
        return Ok(());
    }
    #[cfg(target_os = "windows")]
    let update_msi = crate::platform::is_msi_installed()? && !crate::is_custom_client();
    if !(manually || config::Config::get_bool_option(config::keys::OPTION_ALLOW_AUTO_UPDATE)) {
        return Ok(());
    }
    // A failed check is returned, not swallowed: the caller then retries in
    // RETRY_INTERVAL rather than treating an offline moment as a day's answer.
    do_check_software_update()
        .map_err(|e| hbb_common::anyhow::anyhow!("Checking lab-desk.net for a new version: {}", e))?;

    let update_url = crate::common::SOFTWARE_UPDATE_URL.lock().unwrap().clone();
    if update_url.is_empty() {
        log::debug!("No update available.");
    } else {
        let download_url = update_url.replace("tag", "download");
        let version = download_url.split('/').last().unwrap_or_default();
        #[cfg(target_os = "windows")]
        let download_url = if cfg!(feature = "flutter") {
            let Some(arch) = crate::platform::windows::release_arch_suffix() else {
                bail!(
                    "Unsupported Windows release architecture: {}",
                    std::env::consts::ARCH
                );
            };
            format!(
                "{}/labdesk-{}-{}.{}",
                download_url,
                version,
                arch,
                if update_msi { "msi" } else { "exe" }
            )
        } else {
            format!("{}/labdesk-{}-x86-sciter.exe", download_url, version)
        };
        log::info!("[update] lab-desk.net offers {} over {}", &version, crate::VERSION);
        // What the asset has to hash to, learned before a byte of it is
        // fetched. There is no unverified path from here: an update whose
        // digest cannot be read is an update that does not happen.
        let expected_sha256 = get_published_sha256(&download_url)?;
        log::info!(
            "[update] the release publishes sha256 {} for {}",
            expected_sha256,
            download_url
        );
        let client = create_http_client_with_url_strict(&download_url)?;
        let Some(file_name) = get_download_file_from_url(&download_url)
            .and_then(|p| p.file_name().map(|n| n.to_owned()))
        else {
            bail!("Failed to get the file path from the URL: {}", download_url);
        };
        // This runs as SYSTEM, so the temp directory is C:\Windows\Temp, where
        // every local user may create files and owns what they create. A
        // predictable file name there let a user pre-create the installer's
        // path, keep the file, and rewrite it between the hash and the elevated
        // launch. The download now lands in a directory whose name cannot be
        // guessed, created by this process and refused if it already exists,
        // in a file that must not exist yet either. Nothing is ever reused.
        let dir = std::env::temp_dir().join(format!(
            "{}-{}",
            UPDATE_DIR_PREFIX,
            uuid::Uuid::new_v4()
        ));
        std::fs::create_dir(&dir)?;
        let file_path = dir.join(file_name);
        let response = client.get(&download_url).send()?;
        if !response.status().is_success() {
            std::fs::remove_dir_all(&dir).ok();
            bail!(
                "Failed to download the new version file: {}",
                response.status()
            );
        }
        // Streamed and bounded rather than buffered whole in the service.
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&file_path)?;
        let mut body = response.take(UPDATE_MAX_BYTES);
        if let Err(e) = std::io::copy(&mut body, &mut file) {
            std::fs::remove_dir_all(&dir).ok();
            return Err(e.into());
        }
        drop(file);
        // We have checked if the `conns` is empty before, but we need to check again.
        // No need to care about the downloaded file here, because it's rare case that the `conns` are empty
        // before the download, but not empty after the download.
        if has_no_active_conns() {
            // The trusted elevated receiver hashes its own protected copy
            // against the digest authenticated above before executing it.
            #[cfg(target_os = "windows")]
            crate::platform::install_verified_update(
                file_path
                    .to_str()
                    .ok_or_else(|| hbb_common::anyhow::anyhow!("Invalid update file path"))?,
                &expected_sha256,
                true,
            )?;
            // Nothing installs on the other desktop platforms from here, but a
            // download that does not match still has to fail the check loudly
            // and be deleted rather than left in the temp directory.
            #[cfg(not(target_os = "windows"))]
            verify_downloaded_file(&file_path, &expected_sha256)?;
        }
    }
    Ok(())
}

/// Where an unattended download lands: a directory under the temp directory
/// named with this prefix and a fresh UUID, one per update, removed by
/// `try_remove_temp_update_files` once it is an hour old.
pub const UPDATE_DIR_PREFIX: &str = "labdesk-update";

/// More than any installer this project ships; a response longer than this is
/// cut off and fails the hash rather than filling the disk.
const UPDATE_MAX_BYTES: u64 = 512 * 1024 * 1024;

/// Updates come from `https://lab-desk.net/releases/download/<version>/<file>`, which the
/// site streams from the release its administrator made public.
pub fn get_update_download_file_from_url(url: &str) -> Option<PathBuf> {
    let parsed = url::Url::parse(url).ok()?;
    let labdesk_host = crate::common::LABDESK_SITE.trim_start_matches("https://");
    // Check the raw prefix before Url normalizes default ports.
    if !url.starts_with(&format!("https://{}/", labdesk_host))
        || parsed.scheme() != "https"
        || parsed.host_str() != Some(labdesk_host)
        || !parsed.username().is_empty()
        || parsed.password().is_some()
        || parsed.port().is_some()
        || parsed.query().is_some()
        || parsed.fragment().is_some()
    {
        return None;
    }

    let mut segments = parsed.path_segments()?;
    let releases = segments.next()?;
    let download = segments.next()?;
    let tag = segments.next()?;
    let filename = segments.next()?;

    if releases != "releases"
        || download != "download"
        || tag.is_empty()
        || segments.next().is_some()
        || !is_plain_update_filename(filename)
    {
        return None;
    }

    Some(std::env::temp_dir().join(filename))
}

fn is_plain_update_filename(filename: &str) -> bool {
    if filename.is_empty()
        || filename.contains('/')
        || filename.contains('\\')
        || filename.contains(':')
    {
        return false;
    }

    let mut components = Path::new(filename).components();
    matches!(
        components.next(),
        Some(Component::Normal(name)) if name.to_str() == Some(filename)
    ) && components.next().is_none()
}

/// The temp path an update from `url` is downloaded to. This says nothing at
/// all about the file's contents: a path coming back from here is not a
/// vouched-for installer, and every local user can write that directory. Any
/// caller about to hand the file to an elevated or root installer must call
/// [verify_update_file] with the same URL first.
pub fn get_download_file_from_url(url: &str) -> Option<PathBuf> {
    get_update_download_file_from_url(url)
}

/// Where the site serves a release asset, and where it publishes that asset's
/// SHA-256. The digest is produced by the release pipeline and uploaded to the
/// release as `SHA256SUMS`; the site reads it from there and serves one line
/// of it per asset.
const RELEASE_DOWNLOAD_PATH: &str = "/releases/download/";
const RELEASE_CHECKSUM_PATH: &str = "/releases/checksums/";

/// The URL that publishes the SHA-256 of the asset at `download_url`.
/// None for anything that is not a LabDesk release asset, including upstream
/// GitHub, which publishes no digest. Refusing to install what cannot be
/// verified is the point, so there is deliberately no fallback here.
pub fn get_update_checksum_url(download_url: &str) -> Option<String> {
    // Only a URL the release allowlist already accepted may be asked about.
    get_update_download_file_from_url(download_url)?;
    let prefix = format!("{}{}", crate::common::LABDESK_SITE, RELEASE_DOWNLOAD_PATH);
    let rest = download_url.strip_prefix(&prefix)?;
    Some(format!(
        "{}{}{}",
        crate::common::LABDESK_SITE,
        RELEASE_CHECKSUM_PATH,
        rest
    ))
}

/// A SHA-256 as the site publishes it: 64 hex characters and nothing else.
fn is_sha256_hex(digest: &str) -> bool {
    digest.len() == 64 && digest.bytes().all(|b| b.is_ascii_hexdigit())
}

/// The release manifest and its detached signature, both produced by
/// `.github/workflows/release-checksums.yml` and uploaded to the release as
/// assets, so the site serves them from the same place as the asset they
/// describe.
const RELEASE_MANIFEST_ASSET: &str = "SHA256SUMS";
const RELEASE_SIGNATURE_ASSET: &str = "SHA256SUMS.sig";

/// A manifest is one line of about 90 bytes per release asset. This bound is
/// far above any real release and keeps a hostile or broken endpoint from being
/// read into memory without limit.
const RELEASE_MANIFEST_MAX_BYTES: u64 = 64 * 1024;

/// The Ed25519 public key that release manifests are signed with, base64 of the
/// raw 32 bytes.
///
/// The privileged Linux helper uses the key compiled into the installed native
/// verifier. Missing or malformed trust configuration disables updates; it never disables
/// signature verification. The owner-controlled ceremony is in docs/SIGNING.md.
const RELEASE_SIGNING_PUBLIC_KEY_B64: &str = include_str!("../res/release-signing-public-key");

/// The pinned release key, or None when secure updates are not configured.
fn release_signing_public_key() -> Option<sign::PublicKey> {
    parse_release_signing_key(RELEASE_SIGNING_PUBLIC_KEY_B64)
}

/// Reject malformed configuration without crashing the application.
fn parse_release_signing_key(base64: &str) -> Option<sign::PublicKey> {
    sign::PublicKey::from_slice(&crate::decode64(base64.trim()).ok()?)
}

/// The version and asset filename a release download URL names, for URLs the
/// release allowlist accepts and only those. The manifest is therefore only
/// ever fetched from the release the asset itself came from.
fn release_asset_parts(download_url: &str) -> Option<(&str, &str)> {
    get_update_download_file_from_url(download_url)?;
    let prefix = format!("{}{}", crate::common::LABDESK_SITE, RELEASE_DOWNLOAD_PATH);
    let (version, asset) = download_url.strip_prefix(&prefix)?.split_once('/')?;
    if !version
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || b".+-".contains(&byte))
        || !asset.starts_with(&format!(
            "labdesk-{}-",
            version.strip_prefix('v').unwrap_or(version)
        ))
    {
        return None;
    }
    Some((version, asset))
}

/// Where the site serves `asset` of release `version` from.
fn release_asset_url(version: &str, asset: &str) -> String {
    format!(
        "{}{}{}/{}",
        crate::common::LABDESK_SITE,
        RELEASE_DOWNLOAD_PATH,
        version,
        asset
    )
}

/// Passes only a manifest whose detached signature verifies against the pinned
/// release key.
///
/// This is the check a published digest cannot make on its own. The digest and
/// the asset travel through the same site and out of the same release, so a
/// hash catches a tampered transfer, a poisoned cache and a swapped local file,
/// but whoever controls the site controls both halves and can serve a matching
/// pair. The signing key never reaches the site, so a signature the site cannot
/// produce is what stops that.
///
/// What it does NOT stop is whoever can make the release pipeline sign for
/// them: the private key is a secret in this same repository, so repository
/// write plus a workflow dispatch signs whatever is on the release. An older
/// signed release remains authentic; callers must also enforce newer versions.
/// `docs/SIGNING.md`, "What this does not close", is the honest list.
fn verify_manifest_signature(
    manifest: &[u8],
    signature: &[u8],
    public_key: &sign::PublicKey,
) -> ResultType<()> {
    let Ok(signature) = sign::Signature::from_bytes(signature) else {
        bail!(
            "The release manifest signature is not {} bytes",
            sign::SIGNATUREBYTES
        );
    };
    if !sign::verify_detached(&signature, manifest, public_key) {
        bail!("The release manifest signature was not made by the pinned release key");
    }
    Ok(())
}

/// The digest a signed manifest records for `asset`. The manifest is
/// `sha256sum` output: one `<64 hex>  <name>` line per asset, the name prefixed
/// with `*` when the release pipeline hashed in binary mode.
///
/// Two lines for one name is refused rather than resolved: a manifest that says
/// two things about one asset is not a manifest to install from.
fn digest_from_manifest(manifest: &str, asset: &str) -> ResultType<String> {
    if !is_plain_update_filename(asset) {
        bail!("Invalid release asset name");
    }
    let mut found = None;
    for line in manifest.lines() {
        let Some((digest, rest)) = line.split_once(' ') else {
            continue;
        };
        let Some(name) = rest.strip_prefix(' ').or_else(|| rest.strip_prefix('*')) else {
            continue;
        };
        if name != asset {
            continue;
        }
        if !is_sha256_hex(digest) {
            bail!(
                "The release manifest records an invalid digest for {}",
                asset
            );
        }
        if found.is_some() {
            bail!("The release manifest records {} more than once", asset);
        }
        found = Some(digest.to_lowercase());
    }
    match found {
        Some(digest) => Ok(digest),
        None => bail!("The release manifest publishes no digest for {}", asset),
    }
}

/// Authenticate exact manifest bytes before reading the requested asset's digest.
pub fn verify_release_manifest(
    manifest: &[u8],
    signature: &[u8],
    public_key: &sign::PublicKey,
    asset: &str,
) -> ResultType<String> {
    if manifest.is_empty() || manifest.len() as u64 > RELEASE_MANIFEST_MAX_BYTES {
        bail!("The release manifest is empty or too large");
    }
    if hbb_common::sodiumoxide::init().is_err() {
        bail!("Unable to initialize release signature verification");
    }
    verify_manifest_signature(manifest, signature, public_key)?;
    digest_from_manifest(std::str::from_utf8(manifest)?, asset)
}

/// Verify downloaded metadata with this installed build's immutable trust key.
/// Used by the privileged Linux helper without initializing the desktop app.
pub fn verify_release_manifest_files(
    manifest_path: &Path,
    signature_path: &Path,
    asset: &str,
) -> ResultType<String> {
    let public_key = release_signing_public_key().ok_or_else(|| {
        hbb_common::anyhow::anyhow!("Secure updates are unavailable: this build has no valid release signing key. Obtain a signed release from the LabDesk administrator.")
    })?;
    let mut manifest = Vec::new();
    std::fs::File::open(manifest_path)?
        .take(RELEASE_MANIFEST_MAX_BYTES + 1)
        .read_to_end(&mut manifest)?;
    let mut signature = Vec::new();
    std::fs::File::open(signature_path)?
        .take(sign::SIGNATUREBYTES as u64 + 1)
        .read_to_end(&mut signature)?;
    verify_release_manifest(&manifest, &signature, &public_key, asset)
}

/// Recognize the privileged helper's verification-only command before startup.
/// No caller-supplied key, network request, configuration, or installation.
pub fn release_verifier_command(args: &[std::ffi::OsString]) -> Option<i32> {
    if args.first().map(|arg| arg.as_os_str())
        != Some(std::ffi::OsStr::new("--verify-release-manifest"))
    {
        return None;
    }
    if args.len() != 4 {
        eprintln!("Usage: labdesk --verify-release-manifest <manifest> <signature> <asset>");
        return Some(64);
    }
    let Some(asset) = args[3].to_str() else {
        eprintln!("Invalid release asset name");
        return Some(65);
    };
    match verify_release_manifest_files(Path::new(&args[1]), Path::new(&args[2]), asset) {
        Ok(digest) => {
            println!("{}", digest);
            Some(0)
        }
        Err(error) => {
            eprintln!("Release verification failed: {}", error);
            Some(65)
        }
    }
}

/// The bytes the site publishes at `url`, up to `max`. One byte over the bound
/// is an error rather than a truncation, so a body that is not what it claims
/// to be cannot be quietly cut down into something that parses.
fn fetch_release_bytes(url: &str, max: u64) -> ResultType<Vec<u8>> {
    let client = create_http_client_with_url_strict(url)?;
    let response = client.get(url).send()?;
    if !response.status().is_success() {
        bail!("{} returned {}", url, response.status());
    }
    let mut body = Vec::new();
    response.take(max + 1).read_to_end(&mut body)?;
    if body.len() as u64 > max {
        bail!("{} returned more than {} bytes", url, max);
    }
    Ok(body)
}

/// The SHA-256 for the asset at `download_url`, reading whatever it needs
/// through `fetch`. Every failure is fatal to the update by design.
///
/// There is deliberately no unsigned fallback, including on unconfigured builds:
/// a manifest the site will not serve, or one whose signature does not verify,
/// stops the update. A fallback there would hand any site that can answer 404
/// the power to switch enforcement off for the whole fleet, which is the one
/// failure this package exists to prevent.
fn published_sha256(
    download_url: &str,
    pinned_key: Option<sign::PublicKey>,
    fetch: &dyn Fn(&str, u64) -> ResultType<Vec<u8>>,
) -> ResultType<String> {
    let Some(public_key) = pinned_key else {
        bail!("Secure updates are unavailable: this build has no valid release signing key. Obtain a signed release from the LabDesk administrator.");
    };
    let Some((version, asset)) = release_asset_parts(download_url) else {
        bail!(
            "No signed release manifest for the update URL, refusing to install: {}",
            download_url
        );
    };
    let manifest = fetch(
        &release_asset_url(version, RELEASE_MANIFEST_ASSET),
        RELEASE_MANIFEST_MAX_BYTES,
    )?;
    let signature = fetch(
        &release_asset_url(version, RELEASE_SIGNATURE_ASSET),
        sign::SIGNATUREBYTES as u64,
    )?;
    // Over the raw bytes, before a single field is parsed out of them, so
    // nothing downstream ever reads a manifest nobody vouched for.
    verify_release_manifest(&manifest, &signature, &public_key, asset)
}

/// The SHA-256 the release publishes for the asset at `download_url`, over the
/// real network.
pub fn get_published_sha256(download_url: &str) -> ResultType<String> {
    published_sha256(
        download_url,
        release_signing_public_key(),
        &fetch_release_bytes,
    )
}

/// The SHA-256 of a file on disk, as lowercase hex. Read in blocks so an
/// installer of any size is hashed in constant memory.
fn file_sha256(path: &Path) -> ResultType<String> {
    use sha2::{Digest, Sha256};
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let read = file.read(&mut buf)?;
        if read == 0 {
            break;
        }
        hasher.update(&buf[..read]);
    }
    Ok(hex::encode(hasher.finalize()))
}

/// Passes only a file whose SHA-256 is the published one. Anything else is
/// deleted, so no later run can mistake it for a download that was vouched for.
pub fn verify_downloaded_file(file_path: &Path, expected_sha256: &str) -> ResultType<()> {
    let actual = match file_sha256(file_path) {
        Ok(actual) => actual,
        Err(e) => {
            std::fs::remove_file(file_path).ok();
            return Err(e);
        }
    };
    if actual != expected_sha256 {
        std::fs::remove_file(file_path).ok();
        bail!(
            "The downloaded update does not match the published SHA-256: expected {}, got {}",
            expected_sha256,
            actual
        );
    }
    Ok(())
}

/// The whole check in one call: fetch the digest the site publishes for
/// `download_url`, then hash the file that was downloaded from it, deleting
/// the file and failing if the two do not agree.
///
/// This exists for callers that download an update themselves and want the
/// whole check in one call, without an elevated install waiting on the other
/// side of it. The Flutter UI's "extract-update-dmg" handler is the one such
/// caller: it opens the downloaded disk image to show the user what is in it,
/// before anything has been asked or elevated.
///
/// A caller that IS about to install must not use this. It fetches the digest
/// with [get_published_sha256] and hands that digest to
/// `crate::platform::update_to`. On Windows the trusted elevated receiver checks
/// its own protected copy against that authenticated digest before executing it;
/// the Linux helper independently authenticates the manifest and its private copy.
/// Checking a caller-writable file here alone cannot authorize a later install.
#[allow(dead_code)]
pub fn verify_update_file(download_url: &str, file_path: &Path) -> ResultType<()> {
    let expected_sha256 = get_published_sha256(download_url)?;
    verify_downloaded_file(file_path, &expected_sha256)
}

/// Queries all active connections (remote, file-transfer, port-forward, camera, terminal)
/// from every logged-in user's --server process via IPC.
/// The root service cannot read connection state directly since connections
/// live in user --server processes. Handles fast user switching by querying
/// all GUI users, including the login-window server at UID 0. Falls back to
/// false (assumes sessions active) on any IPC error to avoid updating during
/// an unknown session state.
#[cfg(target_os = "macos")]
pub fn has_no_active_conns_ipc() -> bool {
    let rt = match hbb_common::tokio::runtime::Runtime::new() {
        Ok(rt) => rt,
        Err(_) => return false,
    };
    rt.block_on(async {
        // Use the same GUI-domain-filtered UID set as the update script.
        // Shell-only SSH/TTY users are excluded, while an empty GUI set maps
        // to UID 0 so the LoginWindow server is queried rather than assumed idle.
        let uids = crate::platform::get_logged_in_uids();
        // Check each user's server — fail closed if any has active connections
        for uid in uids {
            if let Ok(mut conn) = crate::ipc::connect_for_uid(1000, uid, "").await {
                if conn.send(&crate::ipc::Data::HasNoActiveConns(None)).await.is_ok() {
                    match conn.next_timeout(1000).await {
                        Ok(Some(crate::ipc::Data::HasNoActiveConns(Some(true)))) => {
                            // Explicit no active connections — safe to continue
                        }
                        Ok(Some(crate::ipc::Data::HasNoActiveConns(Some(false)))) => {
                            return false; // Explicit active connections
                        }
                        _ => {
                            return false; // Timeout/error/unexpected — fail closed
                        }
                    }
                } else {
                    return false; // Send failed — fail closed
                }
            } else {
                return false; // Connection failed — fail closed
            }
        }
        true // All users explicitly confirmed no active connections
    })
}

#[cfg(target_os = "macos")]
fn wait_for_failed_update_retry() {
    const FAILURE_MARKER: &str = "/var/root/.labdeskupdate_failed";
    let marker = std::path::Path::new(FAILURE_MARKER);
    if !marker.exists() {
        return;
    }

    // The updater script records failure immediately before launchd restarts
    // the old daemon. Preserve the retry deadline across that restart instead
    // of consuming the marker and retrying the same broken release in 30 sec.
    let remaining = std::fs::metadata(marker)
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| {
            std::time::SystemTime::now()
                .duration_since(modified)
                .ok()
        })
        .map(|elapsed| RETRY_INTERVAL.saturating_sub(elapsed))
        .unwrap_or(RETRY_INTERVAL);
    if !remaining.is_zero() {
        log::info!(
            "[root-update] Previous update failed; retrying in {} seconds.",
            remaining.as_secs()
        );
        std::thread::sleep(remaining);
    }
    match std::fs::remove_file(marker) {
        Ok(()) => log::info!("[root-update] Previous update retry interval elapsed."),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
        Err(err) => log::warn!("[root-update] Failed to clear failure marker: {}", err),
    }
}

/// Starts the background silent auto-update scheduler for macOS.
/// Called from `start_os_service()` which runs as root via LaunchDaemon.
#[cfg(target_os = "macos")]
pub fn start_auto_update_macos() {
    let spawn_result = std::thread::Builder::new()
        .name("labdesk-auto-update".to_owned())
        .spawn(|| {
            log::info!("[root-update] Auto-update scheduler thread started.");
            std::thread::sleep(INITIAL_CHECK_DELAY);
            wait_for_failed_update_retry();
            let mut interval = DUR_ONE_DAY;
            loop {
                log::info!("[root-update] Running scheduled update check...");
                let no_active_conns = has_no_active_conns_ipc();
                if !no_active_conns {
                    log::info!("[root-update] Active session in progress, retrying in 10 min.");
                    interval = MIN_INTERVAL;
                } else {
                    match check_update_as_root() {
                        Ok(update_started) => {
                            if update_started {
                                // The replacement script is detached and may fail
                                // after this process returns. Always retry at the
                                // failure interval until the new daemon replaces us.
                                interval = RETRY_INTERVAL;
                            } else {
                                interval = DUR_ONE_DAY;
                            }
                        }
                        Err(e) => {
                            log::error!("[root-update] Update check failed: {}", e);
                            interval = RETRY_INTERVAL;
                        }
                    }
                }
                std::thread::sleep(interval);
            }
        });
    if let Err(err) = spawn_result {
        log::error!("[root-update] Failed to start scheduler thread: {}", err);
    }
}

#[cfg(target_os = "macos")]
pub fn check_update_as_root() -> ResultType<bool> {
    let _update_lock = acquire_mac_update_lock()?;
    // Allow-auto-update setting
    if !config::Config::get_bool_option(config::keys::OPTION_ALLOW_AUTO_UPDATE) {
        log::info!("[root-update] Auto update is disabled, skipping.");
        return Ok(false);
    }
    // LabDesk is a custom client upstream and checks lab-desk.net for itself.
    if crate::is_custom_client() && !crate::common::is_labdesk() {
        log::info!("[root-update] Custom client detected, skipping stock update.");
        return Ok(false);
    }
    // Clean up only old temp dirs from previous failed updates. The detached
    // installer keeps using its update directory after this process exits and
    // releases the advisory lock, so a newly-started daemon must not remove a
    // directory that still belongs to the active transaction.
    if let Ok(entries) = std::fs::read_dir("/tmp") {
        for entry in entries.flatten() {
            let name = entry.file_name();
            let name_str = name.to_string_lossy();
            if name_str.starts_with(".labdeskupdate-root-")
                || name_str.starts_with(".labdeskdownload-")
            {
                let path = entry.path();
                let Ok(metadata) = std::fs::symlink_metadata(&path) else {
                    continue;
                };
                let mode = metadata.mode() & 0o7777;
                let is_stale = metadata
                    .modified()
                    .ok()
                    .and_then(|modified| std::time::SystemTime::now().duration_since(modified).ok())
                    .is_some_and(|age| age >= RETRY_INTERVAL);
                if metadata.file_type().is_dir() && metadata.uid() == 0 && mode == 0o700 && is_stale
                {
                    if let Err(err) = std::fs::remove_dir_all(&path) {
                        log::warn!(
                            "[root-update] Failed to remove stale temp dir {}: {}",
                            path.display(),
                            err
                        );
                    }
                }
            }
        }
    }
    if let Err(e) = do_check_software_update() {
        bail!("[root-update] Failed to check for software update: {}", e);
    }
    let update_url = crate::common::SOFTWARE_UPDATE_URL.lock().unwrap().clone();
    if update_url.is_empty() {
        log::info!("[root-update] No update available.");
        return Ok(false);
    }
    let download_url = update_url.replace("tag", "download");
    let version = download_url.split('/').last().unwrap_or_default().to_string();
    let arch = if std::env::consts::ARCH == "aarch64" { "aarch64" } else { "x86_64" };
    let dmg_url = format!("{}/labdesk-{}-{}.dmg", download_url, version, arch);
    log::info!("[root-update] New version: {}, downloading from {}", version, dmg_url);
    // Validate URL against GitHub release allowlist before downloading as root
    let Some(file_path_validated) = get_update_download_file_from_url(&dmg_url) else {
        bail!("[root-update] URL failed allowlist check: {}", dmg_url);
    };
    drop(file_path_validated);
    // What the disk image has to hash to, learned before it is fetched. A root
    // installer is never pointed at bytes nobody vouched for.
    let expected_sha256 = get_published_sha256(&dmg_url)?;
    let client = create_http_client_with_url_strict(&dmg_url)?;
    // Use mktemp so a local user cannot pre-create a predictable path and
    // permanently deny updates for a reused service PID.
    let private_tmp_output = std::process::Command::new("/usr/bin/mktemp")
        .args(["-d", "/tmp/.labdeskdownload-XXXXXX"])
        .output()?;
    if !private_tmp_output.status.success() {
        bail!(
            "[root-update] Failed to create private download directory: {}",
            String::from_utf8_lossy(&private_tmp_output.stderr).trim()
        );
    }
    let private_tmp = String::from_utf8(private_tmp_output.stdout)
        .map_err(|err| hbb_common::anyhow::anyhow!("[root-update] mktemp output error: {}", err))?
        .trim()
        .to_owned();
    if private_tmp.is_empty() {
        bail!("[root-update] mktemp returned an empty download directory");
    }
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&private_tmp, std::fs::Permissions::from_mode(0o700))?;
    }
    let filename = dmg_url.split('/').last().unwrap_or("labdesk.dmg");
    let file_path = std::path::PathBuf::from(format!("{}/{}", private_tmp, filename));
    let tmp_path = file_path.to_string_lossy().to_string();
    // Download
    let mut response = client.get(&dmg_url).send()?;
    if !response.status().is_success() {
        let _ = std::fs::remove_dir_all(&private_tmp);
        bail!("[root-update] Failed to download: {}", response.status());
    }
    // Create file exclusively (O_EXCL) and stream response directly into it
    {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&file_path)
            .map_err(|e| { let _ = std::fs::remove_dir_all(&private_tmp); e })?;
        std::io::copy(&mut response, &mut file)
            .map_err(|e| { let _ = std::fs::remove_dir_all(&private_tmp); e })?;
    }
    log::info!("[root-update] Downloaded to {}", tmp_path);
    // Recheck active sessions before installing — download can take minutes
    if !has_no_active_conns_ipc() {
        if let Err(e) = std::fs::remove_dir_all(&private_tmp) {
            log::warn!("[root-update] Failed to remove temp dir {}: {}", private_tmp, e);
        }
        bail!("[root-update] Active session started during download, deferring update.");
    }
    // The installer runs as root, so it runs on verified bytes or it does not
    // run. Checked here, immediately before the disk image is handed over.
    if let Err(e) = verify_downloaded_file(&file_path, &expected_sha256) {
        if let Err(err) = std::fs::remove_dir_all(&private_tmp) {
            log::warn!(
                "[root-update] Failed to remove temp dir {}: {}",
                private_tmp,
                err
            );
        }
        return Err(e);
    }
    // Install silently as root
    let result = crate::platform::update_from_dmg_as_root(&tmp_path, &version);
    // Clean up download directory
    if let Err(e) = std::fs::remove_dir_all(&private_tmp) {
        log::warn!("[root-update] Failed to remove temp dir {}: {}", private_tmp, e);
    }
    result.map(|_| true)
}

/// Whether every LabDesk session on this machine is idle, asked over IPC.
///
/// The root service holds no connection state on Linux: `res/labdesk.service`
/// runs this process as root while `--server`, where connections live, is
/// launched as the desktop user. So the desktop user's `--server` is asked, and
/// a question that is not answered is read as a session in progress. Installing
/// through a live session would drop it, because the package's `preinst` stops
/// the service.
#[cfg(target_os = "linux")]
fn has_no_active_conns_ipc() -> bool {
    let uid = crate::platform::get_active_userid();
    if uid.is_empty() {
        // No seat0 session, so no `--server` was ever started and no connection
        // can be held by one.
        return true;
    }
    let Ok(uid) = uid.parse::<u32>() else {
        return false;
    };
    let Ok(rt) = hbb_common::tokio::runtime::Runtime::new() else {
        return false;
    };
    rt.block_on(async {
        let Ok(mut conn) = crate::ipc::connect_for_uid(1000, uid, "").await else {
            return false;
        };
        if conn
            .send(&crate::ipc::Data::HasNoActiveConns(None))
            .await
            .is_err()
        {
            return false;
        }
        matches!(
            conn.next_timeout(1000).await,
            Ok(Some(crate::ipc::Data::HasNoActiveConns(Some(true))))
        )
    })
}

/// Removes the download directories earlier checks left behind.
/// `try_remove_temp_update_files` does this on Windows and has no Linux arm, so
/// without this every unattended update would leave its package in the temp
/// directory for good. Only root-owned directories carrying this process's own
/// prefix, and only once they are older than a retry interval, so a download in
/// flight is never taken out from under an install.
#[cfg(target_os = "linux")]
fn remove_stale_update_dirs() {
    let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) else {
        return;
    };
    for entry in entries.flatten() {
        if !entry
            .file_name()
            .to_string_lossy()
            .starts_with(UPDATE_DIR_PREFIX)
        {
            continue;
        }
        let path = entry.path();
        let Ok(metadata) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        let stale = metadata
            .modified()
            .ok()
            .and_then(|modified| std::time::SystemTime::now().duration_since(modified).ok())
            .is_some_and(|age| age >= RETRY_INTERVAL);
        if metadata.file_type().is_dir() && metadata.uid() == 0 && stale {
            if let Err(err) = std::fs::remove_dir_all(&path) {
                log::warn!(
                    "[root-update] Failed to remove the stale download directory {}: {}",
                    path.display(),
                    err
                );
            }
        }
    }
}

/// The name the release gives this platform's package, which is the name
/// lab-desk.net serves it and its digest under.
///
/// Getting this wrong is not a visible failure: the site answers 404, the check
/// ends in an error line, and the machine simply never updates. The names come
/// from `.github/workflows/flutter-build.yml`, which renames each deb to carry
/// the architecture, and from `res/rpm-flutter.spec`, whose `Release: 0` is the
/// `-0.` in the rpm name.
#[cfg(target_os = "linux")]
fn linux_asset_name(kind: &str, version: &str, arch: &str) -> String {
    match kind {
        "deb" => format!("labdesk-{}-{}.deb", version, arch),
        _ => format!("labdesk-{}-0.{}.rpm", version, arch),
    }
}

/// Starts the unattended update loop on Linux, from `start_os_service()`.
///
/// Until this existed the updater had a `windows` arm and a `macos` arm and
/// nothing else, so a Linux machine could learn that a new version was offered
/// and had no way to install it: Linux received no update at all. The loop runs
/// in the root service for the same reason the telemetry collector does, that
/// `--server` is the desktop user's process and cannot install a package.
#[cfg(target_os = "linux")]
pub fn start_auto_update_linux() {
    let spawned = std::thread::Builder::new()
        .name("labdesk-auto-update".to_owned())
        .spawn(|| {
            log::info!("[root-update] The unattended update loop has started.");
            std::thread::sleep(INITIAL_CHECK_DELAY);
            loop {
                let interval = if !has_no_active_conns_ipc() {
                    log::info!("[root-update] A session is in progress, retrying in 10 minutes.");
                    MIN_INTERVAL
                } else {
                    match check_update_as_root_linux() {
                        // The install runs in a transient systemd unit that
                        // outlives this process, so there is nothing more to do
                        // here: either it replaces this service or the retry
                        // interval brings us back.
                        Ok(true) => RETRY_INTERVAL,
                        Ok(false) => DUR_ONE_DAY,
                        Err(err) => {
                            log::error!("[root-update] The update check failed: {}", err);
                            RETRY_INTERVAL
                        }
                    }
                };
                std::thread::sleep(interval);
            }
        });
    if let Err(err) = spawned {
        log::error!("[root-update] Failed to start the update loop: {}", err);
    }
}

/// One unattended check, running as root. Returns whether an install was handed
/// to the helper.
///
/// The asset names are the ones `.github/workflows/flutter-build.yml` uploads
/// and lab-desk.net therefore serves. Which of them is asked for is decided by
/// the package manager that owns the running binary, so an AppImage or a copy
/// that was never installed from a package is left alone rather than handed a
/// package it cannot install.
#[cfg(target_os = "linux")]
pub fn check_update_as_root_linux() -> ResultType<bool> {
    if !config::Config::get_bool_option(config::keys::OPTION_ALLOW_AUTO_UPDATE) {
        log::info!("[root-update] Auto update is off, skipping.");
        return Ok(false);
    }
    // LabDesk is a custom client upstream and checks lab-desk.net for itself.
    if crate::is_custom_client() && !crate::common::is_labdesk() {
        log::info!("[root-update] Custom client detected, skipping the stock update.");
        return Ok(false);
    }
    let Some(kind) = crate::platform::installed_package_kind() else {
        log::info!(
            "[root-update] This copy was not installed from a package, so nothing here can upgrade it in place."
        );
        return Ok(false);
    };
    remove_stale_update_dirs();

    do_check_software_update().map_err(|e| {
        hbb_common::anyhow::anyhow!("Checking lab-desk.net for a new version: {}", e)
    })?;
    let update_url = crate::common::SOFTWARE_UPDATE_URL.lock().unwrap().clone();
    if update_url.is_empty() {
        log::debug!("[root-update] No update available.");
        return Ok(false);
    }
    let download_url = update_url.replace("tag", "download");
    let version = download_url.split('/').last().unwrap_or_default().to_owned();
    let arch = if std::env::consts::ARCH == "aarch64" {
        "aarch64"
    } else {
        "x86_64"
    };
    let asset = linux_asset_name(kind, &version, arch);
    let asset_url = format!("{}/{}", download_url, asset);
    // The allowlist first, so nothing below ever talks to a host this updater
    // does not accept.
    if get_update_download_file_from_url(&asset_url).is_none() {
        bail!(
            "[root-update] The update URL failed the release allowlist check: {}",
            asset_url
        );
    }
    // What the asset has to hash to, learned before a byte of it is fetched.
    let expected_sha256 = get_published_sha256(&asset_url)?;
    log::info!(
        "[root-update] lab-desk.net offers {} over {}; the release publishes sha256 {} for {}",
        version,
        crate::VERSION,
        expected_sha256,
        asset
    );

    // A directory whose name cannot be guessed, created by this process, refused
    // if it already exists, and readable only by root. The temp directory is
    // world-writable and this download is about to be installed as root.
    let dir = std::env::temp_dir().join(format!("{}-{}", UPDATE_DIR_PREFIX, uuid::Uuid::new_v4()));
    std::fs::create_dir(&dir)?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    let file_path = dir.join(&asset);
    let client = create_http_client_with_url_strict(&asset_url)?;
    let response = client.get(&asset_url).send()?;
    if !response.status().is_success() {
        std::fs::remove_dir_all(&dir).ok();
        bail!(
            "[root-update] Failed to download the new version: {}",
            response.status()
        );
    }
    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&file_path)?;
    // Streamed and bounded rather than buffered whole in the service.
    let mut body = response.take(UPDATE_MAX_BYTES);
    if let Err(e) = std::io::copy(&mut body, &mut file) {
        std::fs::remove_dir_all(&dir).ok();
        return Err(e.into());
    }
    drop(file);

    // The download can take minutes, so the session question is asked again
    // right before the install rather than only before it.
    if !has_no_active_conns_ipc() {
        std::fs::remove_dir_all(&dir).ok();
        bail!("[root-update] A session started during the download, deferring the update.");
    }
    if let Err(e) = verify_downloaded_file(&file_path, &expected_sha256) {
        std::fs::remove_dir_all(&dir).ok();
        return Err(e);
    }
    let Some(path) = file_path.to_str() else {
        std::fs::remove_dir_all(&dir).ok();
        bail!("[root-update] The download path is not valid UTF-8");
    };
    log::info!("[root-update] Handing {} to the update helper.", path);
    crate::platform::install_update_as_root(path)?;
    Ok(true)
}

#[cfg(all(test, target_os = "linux"))]
mod linux_tests {
    use super::{get_update_checksum_url, get_update_download_file_from_url, linux_asset_name};

    /// The Linux update arm builds an asset URL out of the version the site
    /// offers, and everything downstream of it -- the allowlist, the published
    /// digest, the download -- is reached through that one string. A name the
    /// release does not carry is answered with a 404 and reads as "no update",
    /// so this is checked here rather than in the field.
    #[test]
    fn the_linux_asset_url_is_one_the_release_allowlist_accepts() {
        for (kind, expected) in [
            ("deb", "labdesk-1.2.5-x86_64.deb"),
            ("rpm", "labdesk-1.2.5-0.x86_64.rpm"),
        ] {
            let asset = linux_asset_name(kind, "1.2.5", "x86_64");
            assert_eq!(asset, expected);
            let url = format!("https://lab-desk.net/releases/download/1.2.5/{}", asset);
            assert_eq!(
                get_update_download_file_from_url(&url)
                    .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned())),
                Some(expected.to_owned()),
                "the release allowlist refused {}",
                url
            );
            assert_eq!(
                get_update_checksum_url(&url),
                Some(format!(
                    "https://lab-desk.net/releases/checksums/1.2.5/{}",
                    asset
                ))
            );
        }
        assert_eq!(
            linux_asset_name("deb", "1.2.5", "aarch64"),
            "labdesk-1.2.5-aarch64.deb"
        );
    }
}

#[cfg(test)]
mod tests {
    use super::{
        digest_from_manifest, file_sha256, get_download_file_from_url, get_update_checksum_url,
        is_sha256_hex, parse_release_signing_key, published_sha256, release_asset_parts,
        release_asset_url, release_signing_public_key, sign, verify_downloaded_file,
        verify_manifest_signature, verify_release_manifest, ResultType, RELEASE_MANIFEST_ASSET,
        RELEASE_SIGNATURE_ASSET, RELEASE_SIGNING_PUBLIC_KEY_B64,
    };

    #[test]
    fn an_unconfigured_release_key_refuses_updates_without_fetching_unsigned_data() {
        let fetched = std::cell::Cell::new(false);
        let result = published_sha256(
            "https://lab-desk.net/releases/download/1.2.2/labdesk-1.2.2-x86_64.exe",
            None,
            &|_, _| {
                fetched.set(true);
                Ok(b"460de39d0bfc73247f2f143b4a83d255a00a53620a116fca20af1f7963b7a2c5  labdesk-1.2.2-x86_64.exe\n".to_vec())
            },
        );
        assert!(
            result.is_err(),
            "an unsigned manifest must not authorize installation"
        );
        assert!(
            !fetched.get(),
            "an absent trust anchor must fail before network access"
        );
    }

    #[test]
    fn release_verification_authenticates_metadata_before_authorizing_an_artifact() {
        let (key, secret) = sign::gen_keypair();
        let asset = "labdesk-1.2.2-x86_64.exe";
        let manifest = format!("{}  {}\n", "a".repeat(64), asset);
        let signature = sign::sign_detached(manifest.as_bytes(), &secret).to_bytes();
        assert_eq!(
            verify_release_manifest(manifest.as_bytes(), &signature, &key, asset).unwrap(),
            "a".repeat(64),
        );
        let (untrusted_key, _) = sign::gen_keypair();
        assert!(
            verify_release_manifest(manifest.as_bytes(), &signature, &untrusted_key, asset)
                .is_err()
        );
        assert!(verify_release_manifest(
            manifest.replace('a', "b").as_bytes(),
            &signature,
            &key,
            asset
        )
        .is_err());
        for invalid in [Vec::new(), signature[..63].to_vec(), vec![0; 65]] {
            assert!(verify_release_manifest(manifest.as_bytes(), &invalid, &key, asset).is_err());
        }
        for invalid in [String::new(), manifest.repeat(2), "x".repeat(65537)] {
            let signed = sign::sign_detached(invalid.as_bytes(), &secret).to_bytes();
            assert!(verify_release_manifest(invalid.as_bytes(), &signed, &key, asset).is_err());
        }
        assert!(
            verify_release_manifest(manifest.as_bytes(), &signature, &key, "other.exe").is_err()
        );
    }

    #[test]
    fn a_release_cannot_borrow_a_signed_asset_from_a_different_version() {
        assert!(release_asset_parts(
            "https://lab-desk.net/releases/download/9.9.9/labdesk-1.2.2-x86_64.exe"
        )
        .is_none());
        assert!(release_asset_parts(
            "https://lab-desk.net/releases/download/1.2.2/labdesk-1.2.20-x86_64.exe"
        )
        .is_none());
        assert!(release_asset_parts(
            "https://lab-desk.net/releases/download/v1.2.2/labdesk-1.2.2-x86_64.exe"
        )
        .is_some());
    }

    #[test]
    fn verification_command_rejects_bad_arguments_and_an_unconfigured_build() {
        use std::ffi::OsString;
        assert_eq!(super::release_verifier_command(&[]), None);
        assert_eq!(
            super::release_verifier_command(&[OsString::from("--version")]),
            None
        );
        assert_eq!(
            super::release_verifier_command(&[OsString::from("--verify-release-manifest")]),
            Some(64)
        );
        if release_signing_public_key().is_none() {
            assert_eq!(
                super::release_verifier_command(&[
                    OsString::from("--verify-release-manifest"),
                    OsString::from("missing-manifest"),
                    OsString::from("missing-signature"),
                    OsString::from("labdesk-1.2.2-x86_64.exe"),
                ]),
                Some(65)
            );
        }
    }

    #[test]
    fn update_download_file_rejects_third_party_release_urls() {
        assert!(get_download_file_from_url(
            "https://github.com/example/upstream/releases/download/1.4.0/labdesk-1.4.0-x86_64.dmg",
        )
        .is_none());
    }

    #[test]
    fn update_download_file_accepts_labdesk_site_asset_urls() {
        let file = get_download_file_from_url(
            "https://lab-desk.net/releases/download/1.2.0/labdesk-1.2.0-x86_64.exe",
        )
        .expect("valid lab-desk.net release asset URL");
        assert_eq!(
            file.file_name().and_then(|name| name.to_str()),
            Some("labdesk-1.2.0-x86_64.exe")
        );
        for url in [
            "http://lab-desk.net/releases/download/1.2.0/labdesk-1.2.0-x86_64.exe",
            "https://lab-desk.net/labdesk-1.2.0-x86_64.exe",
            "https://lab-desk.net/releases/download/1.2.0/",
            "https://lab-desk.net/releases/download/1.2.0/nested/labdesk.exe",
            "https://lab-desk.net/releases/download/1.2.0/labdesk.exe?x=1",
            "https://lab-desk.net.evil.com/releases/download/1.2.0/labdesk.exe",
            "https://evil.com/lab-desk.net/releases/download/1.2.0/labdesk.exe",
        ] {
            assert!(get_download_file_from_url(url).is_none(), "{url}");
        }
    }

    #[test]
    fn update_download_file_rejects_untrusted_or_malformed_urls() {
        for url in [
            "http://github.com/example/upstream/releases/download/1/labdesk.exe",
            "https://example.com/labdesk.exe",
            "https://github.com/other/project/releases/download/1/labdesk.exe",
            "https://github.com/example/upstream/releases/download/1/",
            "https://github.com/example/upstream/releases/download/1/nested/labdesk.exe",
            "https://github.com/example/upstream/releases/download/1/C:labdesk.exe",
            "https://user@github.com/example/upstream/releases/download/1/labdesk.exe",
            "https://github.com:443/labdesk/labdesk/releases/download/1/labdesk.exe",
            "https://github.com/example/upstream/releases/download/1/labdesk.exe?download=1",
            "https://github.com/example/upstream/releases/download/1/labdesk.exe#download",
            "not a url",
        ] {
            assert!(get_download_file_from_url(url).is_none(), "{url}");
        }
    }

    #[test]
    fn a_digest_url_exists_only_for_a_labdesk_release_asset() {
        assert_eq!(
            get_update_checksum_url(
                "https://lab-desk.net/releases/download/1.2.0/labdesk-1.2.0-x86_64.exe"
            )
            .as_deref(),
            Some("https://lab-desk.net/releases/checksums/1.2.0/labdesk-1.2.0-x86_64.exe")
        );
        for url in [
            // Upstream GitHub publishes no digest, so nothing fetched from it
            // can be verified, so nothing fetched from it may be installed.
            "https://github.com/example/upstream/releases/download/1.4.0/labdesk-1.4.0-x86_64.dmg",
            "http://lab-desk.net/releases/download/1.2.0/labdesk-1.2.0-x86_64.exe",
            "https://lab-desk.net/releases/download/1.2.0/nested/labdesk.exe",
            "https://lab-desk.net/releases/download/1.2.0/labdesk.exe?x=1",
            "https://lab-desk.net.evil.com/releases/download/1.2.0/labdesk.exe",
            "https://evil.com/lab-desk.net/releases/download/1.2.0/labdesk.exe",
            "not a url",
        ] {
            assert!(get_update_checksum_url(url).is_none(), "{url}");
        }
    }

    #[test]
    fn an_update_that_does_not_match_the_published_digest_is_refused_and_deleted() {
        // Process-unique so two test binaries on one runner cannot collide.
        let path = std::env::temp_dir().join(format!(
            "labdesk-update-verify-test-{}.bin",
            std::process::id()
        ));
        std::fs::write(&path, b"labdesk installer").expect("write the test payload");

        // A known vector, so this proves the digest is really SHA-256 and not
        // merely self-consistent.
        let digest = file_sha256(&path).expect("hash the test payload");
        assert!(is_sha256_hex(&digest));
        assert_eq!(
            digest,
            "460de39d0bfc73247f2f143b4a83d255a00a53620a116fca20af1f7963b7a2c5"
        );

        verify_downloaded_file(&path, &digest).expect("the published digest verifies");
        assert!(path.exists(), "a verified file is kept for the installer");

        let wrong = "0".repeat(64);
        assert!(
            verify_downloaded_file(&path, &wrong).is_err(),
            "a mismatched file is refused"
        );
        assert!(
            !path.exists(),
            "a file that failed verification is deleted, not left for a later run"
        );
    }

    #[test]
    fn a_configured_release_key_is_well_formed_and_an_absent_key_disables_updates() {
        assert_eq!(
            release_signing_public_key().is_some(),
            !RELEASE_SIGNING_PUBLIC_KEY_B64.trim().is_empty(),
            "RELEASE_SIGNING_PUBLIC_KEY_B64 is set but is not a 32-byte Ed25519 public key"
        );
        assert!(parse_release_signing_key("").is_none());
        assert!(parse_release_signing_key(&crate::encode64([7u8; 32])).is_some());
        // 31 and 33 bytes are not Ed25519 public keys, and neither is a string
        // that is not base64 at all.
        assert!(parse_release_signing_key(&crate::encode64([7u8; 31])).is_none());
        assert!(parse_release_signing_key(&crate::encode64([7u8; 33])).is_none());
        assert!(parse_release_signing_key("not base64!").is_none());
    }

    #[test]
    fn a_manifest_is_trusted_only_with_its_own_signature_from_the_pinned_key() {
        let (public_key, secret_key) = sign::gen_keypair();
        let (other_public_key, _) = sign::gen_keypair();
        let manifest = "460de39d0bfc73247f2f143b4a83d255a00a53620a116fca20af1f7963b7a2c5  labdesk-1.2.2-x86_64.exe\n";
        let signature = sign::sign_detached(manifest.as_bytes(), &secret_key).to_bytes();

        verify_manifest_signature(manifest.as_bytes(), &signature, &public_key)
            .expect("the signature the release made over this manifest verifies");

        // One character of one digest changed, the signature left alone: this
        // is the compromised-release case the digest alone cannot catch.
        let tampered = manifest.replace("460de39d", "460de39e");
        assert!(verify_manifest_signature(tampered.as_bytes(), &signature, &public_key).is_err());

        // The real manifest and its real signature, verified against a key that
        // did not make it.
        assert!(
            verify_manifest_signature(manifest.as_bytes(), &signature, &other_public_key).is_err()
        );

        // An absent, truncated or over-long signature is refused before any
        // verification is attempted.
        assert!(verify_manifest_signature(manifest.as_bytes(), &[], &public_key).is_err());
        assert!(
            verify_manifest_signature(manifest.as_bytes(), &signature[..63], &public_key).is_err()
        );
        let mut too_long = signature.to_vec();
        too_long.push(0);
        assert!(verify_manifest_signature(manifest.as_bytes(), &too_long, &public_key).is_err());
    }

    #[test]
    fn a_digest_is_read_out_of_a_manifest_by_asset_name() {
        let manifest = concat!(
            "0000000000000000000000000000000000000000000000000000000000000001  labdesk-1.2.2-aarch64.exe\n",
            "0000000000000000000000000000000000000000000000000000000000000002  labdesk-1.2.2-x86_64.exe\n",
            "0000000000000000000000000000000000000000000000000000000000000003 *labdesk-1.2.2-x86_64.msi\n",
        );
        // The asset's own digest, not the neighbouring line's.
        assert_eq!(
            digest_from_manifest(manifest, "labdesk-1.2.2-x86_64.exe").unwrap(),
            "0000000000000000000000000000000000000000000000000000000000000002"
        );
        // `sha256sum -b` marks the name with a leading `*`.
        assert_eq!(
            digest_from_manifest(manifest, "labdesk-1.2.2-x86_64.msi").unwrap(),
            "0000000000000000000000000000000000000000000000000000000000000003"
        );
        // No line for the asset, a name that is only a prefix of one that is
        // there, two lines for one name, and a line that is not a digest line
        // at all: every one of them stops the update.
        assert!(digest_from_manifest(manifest, "labdesk-1.2.2-x86_64.deb").is_err());
        assert!(digest_from_manifest(manifest, "labdesk-1.2.2-x86_64.ex").is_err());
        assert!(
            digest_from_manifest(&format!("{manifest}{manifest}"), "labdesk-1.2.2-x86_64.exe")
                .is_err()
        );
        assert!(
            digest_from_manifest("# labdesk-1.2.2-x86_64.exe\n", "labdesk-1.2.2-x86_64.exe")
                .is_err()
        );
    }

    #[test]
    fn the_manifest_is_fetched_from_the_release_the_asset_came_from() {
        let (version, asset) = release_asset_parts(
            "https://lab-desk.net/releases/download/1.2.2/labdesk-1.2.2-x86_64.exe",
        )
        .expect("a LabDesk release asset URL");
        assert_eq!(version, "1.2.2");
        assert_eq!(asset, "labdesk-1.2.2-x86_64.exe");
        assert_eq!(
            release_asset_url(version, RELEASE_MANIFEST_ASSET),
            "https://lab-desk.net/releases/download/1.2.2/SHA256SUMS"
        );
        assert_eq!(
            release_asset_url(version, RELEASE_SIGNATURE_ASSET),
            "https://lab-desk.net/releases/download/1.2.2/SHA256SUMS.sig"
        );
        // Anything the release allowlist does not accept has no manifest, so no
        // signature can be demanded of it and no update can come from it.
        for url in [
            "https://github.com/example/upstream/releases/download/1.4.0/labdesk-1.4.0-x86_64.dmg",
            "http://lab-desk.net/releases/download/1.2.2/labdesk-1.2.2-x86_64.exe",
            "https://lab-desk.net/releases/download/1.2.2/nested/labdesk.exe",
            "https://lab-desk.net.evil.com/releases/download/1.2.2/labdesk.exe",
            "not a url",
        ] {
            assert!(release_asset_parts(url).is_none(), "{url}");
        }
    }

    /// The client half of the mechanism against the CI half, with a vector
    /// openssl actually produced.
    ///
    /// These constants came out of a scratch directory, from exactly the
    /// commands `.github/workflows/release-checksums.yml` runs and
    /// `docs/SIGNING.md` writes down:
    ///
    ///   openssl genpkey -algorithm ed25519 -out throwaway.pem
    ///   openssl pkeyutl -sign -rawin -inkey throwaway.pem -in SHA256SUMS \
    ///     -out SHA256SUMS.sig
    ///   openssl pkey -in throwaway.pem -pubout -outform DER | tail -c 32 | base64 -w0
    ///
    /// The key was a throwaway made for this fixture and is not, and must never
    /// become, the release key. A public key and a signature are not secrets.
    ///
    /// Every other test here signs with sodiumoxide and verifies with
    /// sodiumoxide, which is one library agreeing with itself and says nothing
    /// about the side that really makes these files. If openssl's output stops
    /// being what `verify_detached` accepts, or the ceremony's key extraction
    /// stops yielding the raw 32 bytes, the fleet's update channel breaks, and
    /// this is the test that has to notice first.
    #[test]
    fn an_openssl_signature_made_the_way_ci_makes_it_verifies_here() {
        const MANIFEST: &str = concat!(
            "0000000000000000000000000000000000000000000000000000000000000001",
            "  labdesk-1.2.2-aarch64.exe\n",
            "0000000000000000000000000000000000000000000000000000000000000002",
            "  labdesk-1.2.2-x86_64.exe\n",
        );
        const PUBLIC_KEY_DER_B64: &str =
            "MCowBQYDK2VwAyEA24i/6YbJxz+qqWbWPlVKBGK/vF3C2U0ZPqBLfk//UEY=";
        const PUBLIC_KEY_B64: &str = "24i/6YbJxz+qqWbWPlVKBGK/vF3C2U0ZPqBLfk//UEY=";
        const SIGNATURE_B64: &str = concat!(
            "lmphXsCiZMUsXFydCeaW2G7JXHLIwTuJqt8mm3zVo/22zOycqIePHKYZsYQJm0b1",
            "mAlKcjvYvlkvpQrnYcLIBg==",
        );

        // Ceremony step 2. An Ed25519 SubjectPublicKeyInfo is a 12-byte header
        // and then the key, so the DER's last 32 bytes are exactly what the
        // pinned constant holds. Getting this wrong produces a key that parses
        // and then verifies nothing.
        let der = crate::decode64(PUBLIC_KEY_DER_B64).expect("the DER the ceremony prints");
        assert_eq!(der.len(), 44);
        assert_eq!(crate::encode64(&der[der.len() - 32..]), PUBLIC_KEY_B64);

        let public_key = parse_release_signing_key(PUBLIC_KEY_B64).expect("a pinned 32-byte key");
        let signature = crate::decode64(SIGNATURE_B64).expect("the published signature");
        assert_eq!(signature.len(), sign::SIGNATUREBYTES);

        verify_manifest_signature(MANIFEST.as_bytes(), &signature, &public_key)
            .expect("an openssl detached signature verifies under sodiumoxide");
        assert_eq!(
            digest_from_manifest(MANIFEST, "labdesk-1.2.2-x86_64.exe").unwrap(),
            "0000000000000000000000000000000000000000000000000000000000000002"
        );

        // One digit of one digest changed, the signature left as published.
        let tampered = MANIFEST.replace("00000002", "00000003");
        assert!(verify_manifest_signature(tampered.as_bytes(), &signature, &public_key).is_err());
    }

    /// The switch itself, which is the highest-value line in this file: pinning
    /// a key has to replace the unsigned digest route, not sit in front of it.
    /// Every fetch is recorded, so a fallback cannot hide behind an assertion
    /// that only inspects the answer.
    #[test]
    fn a_pinned_key_replaces_the_unsigned_digest_route_and_never_falls_back_to_it() {
        let (public_key, secret_key) = sign::gen_keypair();
        let url = "https://lab-desk.net/releases/download/1.2.2/labdesk-1.2.2-x86_64.exe";
        let manifest = concat!(
            "0000000000000000000000000000000000000000000000000000000000000002",
            "  labdesk-1.2.2-x86_64.exe\n"
        );
        let digest = "0000000000000000000000000000000000000000000000000000000000000002";
        let signature = sign::sign_detached(manifest.as_bytes(), &secret_key).to_bytes();
        let manifest_url = "https://lab-desk.net/releases/download/1.2.2/SHA256SUMS";
        let signature_url = "https://lab-desk.net/releases/download/1.2.2/SHA256SUMS.sig";

        let asked = std::cell::RefCell::new(Vec::new());
        let record = |asked_url: &str| asked.borrow_mut().push(asked_url.to_owned());
        let not_found = |asked_url: &str| -> ResultType<Vec<u8>> {
            Err(
                std::io::Error::new(std::io::ErrorKind::NotFound, format!("404 {asked_url}"))
                    .into(),
            )
        };

        // The release serves both files: the digest comes out of the manifest,
        // and only after the signature over it verified.
        let found = published_sha256(url, Some(public_key), &|asked_url: &str, _max: u64| {
            record(asked_url);
            match asked_url {
                u if u == manifest_url => Ok(manifest.as_bytes().to_vec()),
                u if u == signature_url => Ok(signature.to_vec()),
                other => not_found(other),
            }
        })
        .expect("a manifest the pinned key signed");
        assert_eq!(found, digest);
        assert_eq!(asked.take(), [manifest_url, signature_url]);

        // The site will not serve the manifest. That has to stop the update: a
        // fallback here would let anything able to answer 404 switch
        // enforcement off for the whole fleet.
        assert!(
            published_sha256(url, Some(public_key), &|asked_url: &str, _max: u64| {
                record(asked_url);
                not_found(asked_url)
            })
            .is_err()
        );
        assert_eq!(asked.take(), [manifest_url]);

        // The real manifest carrying a signature that another key made.
        let (_, other_secret_key) = sign::gen_keypair();
        let forged = sign::sign_detached(manifest.as_bytes(), &other_secret_key).to_bytes();
        assert!(
            published_sha256(url, Some(public_key), &|asked_url: &str, _max: u64| {
                record(asked_url);
                match asked_url {
                    u if u == manifest_url => Ok(manifest.as_bytes().to_vec()),
                    u if u == signature_url => Ok(forged.to_vec()),
                    other => not_found(other),
                }
            })
            .is_err()
        );
        assert_eq!(asked.take(), [manifest_url, signature_url]);

        // A URL the release allowlist does not accept has no manifest, and with
        // a key pinned that is the end of it, not a reason to try the digest.
        assert!(published_sha256(
            "https://github.com/example/upstream/releases/download/1.4.0/labdesk-1.4.0-x86_64.dmg",
            Some(public_key),
            &|asked_url: &str, _max: u64| {
                record(asked_url);
                not_found(asked_url)
            }
        )
        .is_err());
        assert!(asked.take().is_empty());
    }

    #[test]
    fn only_a_full_hex_digest_is_accepted() {
        assert!(is_sha256_hex(
            "460de39d0bfc73247f2f143b4a83d255a00a53620a116fca20af1f7963b7a2c5"
        ));
        for bad in [
            "",
            "460de39d0bfc73247f2f143b4a83d255a00a53620a116fca20af1f7963b7a2c",
            "460de39d0bfc73247f2f143b4a83d255a00a53620a116fca20af1f7963b7a2c55",
            "460de39d0bfc73247f2f143b4a83d255a00a53620a116fca20af1f7963b7a2cz",
        ] {
            assert!(!is_sha256_hex(bad), "{bad}");
        }
    }
}
