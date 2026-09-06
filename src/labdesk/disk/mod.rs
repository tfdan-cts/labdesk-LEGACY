// Disk health: the pure layer, and the one entry point the collector calls.
//
// ata.rs, nvme.rs and verdict.rs are total functions over bytes. No I/O, no
// platform calls, no allocation beyond the returned collections. The platform
// layer (windows.rs / linux.rs / macos.rs) issues the DeviceIoControl / ioctl and
// hands the raw output buffer here; nothing in those three knows how the buffer
// was obtained. That is what lets these parsers be tested on a diskless,
// unprivileged CI runner from committed byte fixtures.
//
// This file also carries `gather()`, the collector's only door into the module.
// It is the one place that is NOT pure: three small `#[cfg]` bodies that walk
// their platform's drives and hand each answer to `Probe::finish`, which is pure
// and is where the rule below is actually decided.
//
// The one rule the whole module exists to enforce: a buffer we could not read is
// `Verdict::Unreadable`, never `Verdict::Ok`. "The disk is fine" and "we could not
// ask" are different sentences and the console renders them differently.

pub mod ata;
pub mod nvme;
pub mod verdict;

// The platform layer: the only code in this module that touches a device. Each
// one issues its operating system's ioctls and hands the raw output buffers to
// the parsers above. Compiled one at a time, so a bad Windows constant is
// invisible to a Linux build and vice versa; see the notes at the top of each
// file for the privilege every call needs.
#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(target_os = "windows")]
pub mod windows;

pub use ata::{checksum_ok, parse_ata_attributes, parse_ata_thresholds, AtaAttr, AtaSummary};
pub use nvme::{parse_nvme_health, NvmeHealth};
pub use verdict::{verdict, Source, Verdict};

use hbb_common::sodiumoxide::crypto::hash::sha256;
use std::collections::HashMap;

/// One drive's health, as the platform layer managed to read it.
///
/// The field list is `disk` and `disk_sample` side by side, so the uplink
/// carries nothing this database has no column for and invents no column name.
/// Every counter is an `Option` because every one of them comes from a call that
/// may have been refused: `None` travels as JSON null and is stored as SQL NULL,
/// where a zero would be a measurement of a drive nobody could ask.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiskHealth {
    pub serial_hash: String,
    pub device_index: u32,
    pub device_path: Option<String>,
    pub model: Option<String>,
    pub firmware: Option<String>,
    pub bus: Option<String>,
    pub size_bytes: Option<u64>,
    pub rotational: Option<bool>,
    pub verdict: Verdict,
    pub source: Source,
    pub predict_failure: Option<bool>,
    pub temp_c: Option<i32>,
    pub power_on_hours: Option<u64>,
    pub power_cycles: Option<u64>,
    pub reallocated: Option<u64>,
    pub pending: Option<u64>,
    pub uncorrectable: Option<u64>,
    pub crc_errors: Option<u64>,
    pub percent_used: Option<u8>,
    pub spare_pct: Option<u8>,
    pub spare_threshold_pct: Option<u8>,
    pub critical_warning: Option<u8>,
    pub unsafe_shutdowns: Option<u64>,
    pub media_errors: Option<u64>,
    pub data_written_gb: Option<u64>,
}

/// What one drive answered, before it is folded into a verdict.
///
/// The platform layer fills in whichever calls succeeded and leaves the rest;
/// [`Probe::finish`] is the pure fold all three platforms converge on, so the
/// rule that a refused call is never a healthy drive is decided in one place a
/// diskless CI runner can test.
pub struct Probe {
    pub serial_hash: String,
    pub device_index: u32,
    pub device_path: Option<String>,
    pub model: Option<String>,
    pub firmware: Option<String>,
    pub bus: Option<String>,
    pub size_bytes: Option<u64>,
    pub rotational: Option<bool>,
    /// The source to record when NOTHING answered. `Source::Sysfs` on Linux,
    /// where identity and capacity are readable without privilege and are still
    /// not health; `Source::None` everywhere else.
    pub fallback: Source,
    /// A temperature read from somewhere other than a health structure, used
    /// only when neither the NVMe log page nor the ATA table supplied one. Linux
    /// hwmon answers this without any privilege, so an unprivileged agent still
    /// reports a temperature beside its `Unreadable` verdict.
    pub temp_c: Option<i32>,
    pub nvme: Option<NvmeHealth>,
    pub ata: Vec<AtaAttr>,
    pub thresholds: HashMap<u8, u8>,
    pub predict_failure: Option<bool>,
    pub ata_checksum: Option<bool>,
}

impl Probe {
    /// A drive we have identified and not yet asked.
    pub fn new(serial_hash: String, device_index: u32, fallback: Source) -> Self {
        Self {
            serial_hash,
            device_index,
            device_path: None,
            model: None,
            firmware: None,
            bus: None,
            size_bytes: None,
            rotational: None,
            fallback,
            temp_c: None,
            nvme: None,
            ata: Vec::new(),
            thresholds: HashMap::new(),
            predict_failure: None,
            ata_checksum: None,
        }
    }

    /// Fold what answered into one reading.
    ///
    /// The source is derived from what is actually held rather than set by each
    /// call site, because it is what the console renders beside the verdict: a
    /// drive recorded as `ata_smart` whose attribute table never arrived would
    /// tell an operator we asked a question we did not ask.
    pub fn finish(self) -> DiskHealth {
        let source = if self.nvme.is_some() {
            Source::NvmeLogPage
        } else if !self.ata.is_empty() {
            Source::AtaSmart
        } else if self.predict_failure.is_some() {
            Source::IoctlPredict
        } else {
            self.fallback
        };
        let (verdict, _reason) = verdict(
            source,
            self.nvme.as_ref(),
            &self.ata,
            &self.thresholds,
            self.predict_failure,
            self.ata_checksum,
        );
        // The reason sentence is dropped here rather than carried. `disk_event`
        // holds the only column for it and is written on change, which needs the
        // previous verdict; the package that owns that change detection can add
        // the member, and section 4.4 ignores unknown members, so it will not
        // need a client release first.
        let ata = ata::summarize(&self.ata);
        let nvme = self.nvme.as_ref();
        DiskHealth {
            serial_hash: self.serial_hash,
            device_index: self.device_index,
            device_path: self.device_path,
            model: self.model,
            firmware: self.firmware,
            bus: self.bus,
            size_bytes: self.size_bytes,
            rotational: self.rotational,
            verdict,
            source,
            predict_failure: self.predict_failure,
            temp_c: nvme.and_then(|n| n.temp_c).or(ata.temp_c).or(self.temp_c),
            power_on_hours: nvme.map(|n| n.power_on_hours).or(ata.power_on_hours),
            power_cycles: nvme.map(|n| n.power_cycles).or(ata.power_cycles),
            reallocated: ata.reallocated,
            pending: ata.pending,
            uncorrectable: ata.uncorrectable,
            crc_errors: ata.crc_errors,
            percent_used: nvme.map(|n| n.percent_used).or(ata.life_used_pct),
            spare_pct: nvme.map(|n| n.avail_spare),
            spare_threshold_pct: nvme.map(|n| n.spare_threshold),
            critical_warning: nvme.map(|n| n.critical_warning),
            unsafe_shutdowns: nvme.map(|n| n.unsafe_shutdowns),
            media_errors: nvme.map(|n| n.media_errors),
            data_written_gb: nvme.map(|n| n.data_written_gb),
        }
    }
}

/// `disk.serial_hash`: sha256 of the drive's serial when it gave one, else of
/// `model|size|device_index`.
///
/// Never the raw serial, because this column identifies a drive and is not an
/// inventory of a customer's hardware serial numbers. And never absent: the
/// unique index over it is `(machine_id, serial_hash)`, and under SQLite every
/// NULL is distinct from every other, so a USB bridge that refuses identity
/// would otherwise add a fresh `disk` row on every uplink.
pub fn serial_hash(
    serial: Option<&str>,
    model: Option<&str>,
    size_bytes: Option<u64>,
    device_index: u32,
) -> String {
    let key = match serial.map(str::trim).filter(|serial| !serial.is_empty()) {
        Some(serial) => serial.to_owned(),
        None => format!(
            "{}|{}|{}",
            model.unwrap_or_default(),
            size_bytes.map(|n| n.to_string()).unwrap_or_default(),
            device_index
        ),
    };
    hex::encode(sha256::hash(key.as_bytes()).0)
}

/// The most drives one sweep reports, and the bound the server enforces too
/// (`MAX_DISKS` in src/worker/routes/agent-ingest.ts).
///
/// It is not a guess about density. `MAX_PHYSICAL_DRIVES` in windows.rs is the
/// same 32 and is the whole of that platform's enumeration, so on Windows this
/// can never bite. It exists for Linux, where it can: `list_block_devices`
/// walks the whole of `/sys/block` and `is_health_candidate` excludes only
/// loop, ram, zram, dm-, md and sr, so a multipath SAN host, a ZFS host with
/// zvols or a Ceph client lists far more than 32 entries. Without this cap such
/// a machine would build an uplink the server refuses whole -- metrics
/// included, spool never truncated, machine permanently stale.
pub const MAX_DISKS: usize = 32;

/// Bound a sweep at `MAX_DISKS`, worst first.
///
/// The surplus is dropped from the healthy end, so the drive an operator needs
/// to see is the one that survives the cut. `sort_by_key` is stable, so drives
/// of equal verdict keep the order their platform enumerated them in and a
/// machine under the cap is not reordered at all.
fn cap(mut disks: Vec<DiskHealth>) -> Vec<DiskHealth> {
    if disks.len() <= MAX_DISKS {
        return disks;
    }
    disks.sort_by_key(|disk| std::cmp::Reverse(disk.verdict.severity()));
    disks.truncate(MAX_DISKS);
    disks
}

/// Read every drive this machine can be asked about, at most [`MAX_DISKS`] of
/// them.
///
/// Blocking, and called from the collector's own thread on its slow cadence: a
/// SMART sweep is a handful of register transfers per drive, and the only thing
/// it can delay is that collector's next sample.
///
/// A drive that answered nothing is still returned, as `Verdict::Unreadable`.
/// Dropping it would be the same lie as a green tick, only quieter: the console
/// would show a machine with fewer drives than it has rather than a drive nobody
/// could measure.
///
/// An EMPTY result is a reading too, and the collector sends it as one: it says
/// this machine was asked and no drive answered, which the ingest stores as
/// `unreadable` rather than leaving last week's verdict standing.
pub fn gather() -> Vec<DiskHealth> {
    cap(sweep())
}

#[cfg(target_os = "windows")]
fn sweep() -> Vec<DiskHealth> {
    windows::physical_drives()
        .into_iter()
        .filter_map(|index| windows::Drive::open(index).ok())
        .map(|drive| probe_windows(&drive).finish())
        .collect()
}

#[cfg(target_os = "windows")]
fn probe_windows(drive: &windows::Drive) -> Probe {
    let index = drive.index();
    let identity = drive.identity().ok();
    let model = identity.as_ref().and_then(|id| {
        let model = format!("{} {}", id.vendor, id.product);
        let model = model.trim().to_owned();
        (!model.is_empty()).then_some(model)
    });
    let serial = identity.as_ref().map(|id| id.serial.clone());
    let mut probe = Probe::new(
        serial_hash(serial.as_deref(), model.as_deref(), None, index),
        index,
        Source::None,
    );
    probe.device_path = Some(format!("\\\\.\\PhysicalDrive{}", index));
    probe.model = model;
    probe.firmware = identity
        .as_ref()
        .map(|id| id.revision.clone())
        .filter(|revision| !revision.is_empty());
    probe.bus = identity.as_ref().map(|id| id.bus.to_owned());
    // Asked first because it is the one call a USB bridge or a RAID member
    // answers, and it comes back on the zero-access handle that opens when the
    // read/write open is denied.
    probe.predict_failure = drive.predict_failure().ok();
    if probe.bus.as_deref() == Some("nvme") {
        probe.nvme = drive
            .nvme_health_page()
            .ok()
            .and_then(|buf| nvme::parse_nvme_health(&buf).ok());
    }
    // Gated on the driver having claimed the SMART capability: sending
    // SMART_RCV_DRIVE_DATA to one that never did is how the ATA path produces
    // confusing failures on NVMe and RAID stacks.
    if drive.smart_supported().unwrap_or(false) {
        if let Ok(buf) = drive.ata_attributes() {
            if let Ok(attrs) = ata::parse_ata_attributes(&buf) {
                probe.ata = attrs;
                let mut checksum = ata::checksum_ok(&buf);
                if let Ok(buf) = drive.ata_thresholds() {
                    checksum = checksum && ata::checksum_ok(&buf);
                    if let Ok(thresholds) = ata::parse_ata_thresholds(&buf) {
                        probe.thresholds = thresholds;
                    }
                }
                probe.ata_checksum = Some(checksum);
            }
        }
        // RETURN_SMART_STATUS is the drive's own threshold-exceeded answer and
        // means the same thing as IOCTL_STORAGE_PREDICT_FAILURE, so it fills the
        // same slot when the prediction was refused.
        if probe.predict_failure.is_none() {
            probe.predict_failure = drive
                .ata_smart_status()
                .ok()
                .and_then(|(low, high)| ata::smart_status_failing(low, high));
        }
    }
    probe
}

#[cfg(target_os = "linux")]
fn sweep() -> Vec<DiskHealth> {
    linux::list_block_devices()
        .iter()
        .enumerate()
        .map(|(index, sysfs)| probe_linux(sysfs, index as u32).finish())
        .collect()
}

#[cfg(target_os = "linux")]
fn probe_linux(sysfs: &linux::SysfsDisk, index: u32) -> Probe {
    let model = match (sysfs.vendor.as_deref(), sysfs.model.as_deref()) {
        (Some(vendor), Some(model)) => Some(format!("{} {}", vendor, model)),
        (None, model) => model.map(str::to_owned),
        (vendor, None) => vendor.map(str::to_owned),
    };
    let nvme_namespace = sysfs.name.starts_with("nvme");
    // `Sysfs`, not `None`: identity and a capacity really were read here without
    // any privilege, and they are still not health. `verdict` returns
    // `Unreadable` for this source whenever no reading joins it.
    let mut probe = Probe::new(
        serial_hash(
            sysfs.serial.as_deref(),
            model.as_deref(),
            sysfs.size_bytes,
            index,
        ),
        index,
        Source::Sysfs,
    );
    probe.device_path = Some(sysfs.dev_path.clone());
    probe.model = model;
    probe.firmware = sysfs.firmware.clone();
    probe.rotational = sysfs.rotational;
    probe.size_bytes = sysfs.size_bytes;
    let bus = if nvme_namespace { "nvme" } else { "unknown" };
    probe.bus = Some(bus.to_owned());
    if nvme_namespace {
        probe.nvme = linux::nvme_health_page(&sysfs.name)
            .ok()
            .and_then(|buf| nvme::parse_nvme_health(&buf).ok());
        // Readable from hwmon without CAP_SYS_ADMIN, so an agent whose admin
        // passthrough was refused still reports a temperature beside its
        // `Unreadable` verdict. `finish` prefers the log page when one arrived.
        probe.temp_c = linux::nvme_temp_c(&sysfs.name);
    } else if let Ok(buf) = linux::ata_smart_table(&sysfs.dev_path, linux::ATA_SMART_READ_ATTRIBUTES)
    {
        if let Ok(attrs) = ata::parse_ata_attributes(&buf) {
            probe.ata = attrs;
            // The drive answered ATA PASS-THROUGH with a SMART table, so it is
            // an ATA drive whatever the controller in front of it is. Named
            // here rather than guessed from the device name, because `unknown`
            // is what the console showed for the SATA drive on homebox while
            // its `ata_smart` reading sat beside it.
            probe.bus = Some("ata".to_owned());
            let mut checksum = ata::checksum_ok(&buf);
            if let Ok(buf) =
                linux::ata_smart_table(&sysfs.dev_path, linux::ATA_SMART_READ_THRESHOLDS)
            {
                checksum = checksum && ata::checksum_ok(&buf);
                if let Ok(thresholds) = ata::parse_ata_thresholds(&buf) {
                    probe.thresholds = thresholds;
                }
            }
            probe.ata_checksum = Some(checksum);
        }
    }
    probe
}

/// macOS enumerates no drives, and that empty sweep is itself the reading.
///
/// `macos.rs` records what was looked for and not found: no public interface
/// returns the NVMe health log page or the ATA attribute table, so there is no
/// health to read on this platform at all. `macos::health()` is what a drive
/// found here would carry -- `Unreadable`, `none`, never `Ok` -- so every row an
/// IOKit media walk could add would carry exactly that and would not change one
/// verdict. What was missing was not the rows, it was that nothing reached the
/// server: `gather` returned an empty vector, the collector dropped it, and
/// `machine_state.worst_disk` stayed NULL forever.
///
/// It does not now. The collector sends an empty sweep as an empty `disks`
/// member and the ingest stores `worst_disk = 'unreadable'` from it, so a macOS
/// machine says "asked, and no drive answered" every hour instead of saying
/// nothing. The per-drive INVENTORY is still absent and still needs an IOKit
/// media walk; one row per mounted volume would put physical drives in the
/// database that do not exist, so it is not faked here.
#[cfg(target_os = "macos")]
fn sweep() -> Vec<DiskHealth> {
    Vec::new()
}

/// Every structure this module parses is exactly 512 bytes: the ATA SMART
/// READ_ATTRIBUTES buffer (`READ_ATTRIBUTE_BUFFER_SIZE`), the ATA
/// READ_THRESHOLDS buffer (`READ_THRESHOLD_BUFFER_SIZE`) and the NVMe SMART /
/// Health Information log page (log identifier 02h).
pub const BUF_LEN: usize = 512;

/// Why a buffer carried no reading.
///
/// Both variants mean the same thing to the caller: record `Verdict::Unreadable`
/// and a `health_source` of `none` for this call. Neither is ever an excuse to
/// report zeroed counters as a healthy drive.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiskParseError {
    /// The buffer is shorter than the fixed-size structure the device owed us.
    /// A short read is the normal shape of a USB bridge or RAID controller that
    /// accepted the ioctl and then answered with less than it promised.
    TooShort { got: usize, need: usize },
    /// The buffer is the right length but carries no reading at all: an ioctl
    /// that failed quietly leaves the output buffer exactly as the caller zeroed
    /// it, and a table of zero attributes is indistinguishable from that.
    Empty,
}

impl std::fmt::Display for DiskParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::TooShort { got, need } => write!(f, "buffer too short: {} bytes, need {}", got, need),
            Self::Empty => write!(f, "buffer carries no reading"),
        }
    }
}

impl std::error::Error for DiskParseError {}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    /// A probe carrying whatever the fixtures below hand it, and nothing else.
    fn probe(fallback: Source) -> Probe {
        Probe::new("serial-hash".to_owned(), 0, fallback)
    }

    /// THE RULE THE MODULE EXISTS FOR, AT THE POINT THE COLLECTOR READS IT.
    ///
    /// Every call refused is exactly the state a USB bridge, a RAID member or an
    /// unprivileged agent produces, and it is the state the audit named: a disk
    /// that could not be read must never reach the server looking healthy.
    #[test]
    fn a_probe_that_answered_nothing_is_unreadable_and_never_ok() {
        for fallback in [Source::None, Source::Sysfs] {
            let health = probe(fallback).finish();
            assert_eq!(health.verdict, Verdict::Unreadable, "{:?}", fallback);
            assert_ne!(health.verdict, Verdict::Ok);
            // The source is the one that answered, and none did, so it is the
            // fallback rather than a call we can claim to have made.
            assert_eq!(health.source, fallback);
            // And not one counter carries a zero that would read as a measurement.
            assert_eq!(health.predict_failure, None);
            assert_eq!(health.temp_c, None);
            assert_eq!(health.power_on_hours, None);
            assert_eq!(health.power_cycles, None);
            assert_eq!(health.reallocated, None);
            assert_eq!(health.pending, None);
            assert_eq!(health.uncorrectable, None);
            assert_eq!(health.crc_errors, None);
            assert_eq!(health.percent_used, None);
            assert_eq!(health.spare_pct, None);
            assert_eq!(health.spare_threshold_pct, None);
            assert_eq!(health.critical_warning, None);
            assert_eq!(health.unsafe_shutdowns, None);
            assert_eq!(health.media_errors, None);
            assert_eq!(health.data_written_gb, None);
        }

        // The buffer a quietly failed ioctl leaves behind: 512 zeroes. It parses
        // as nothing rather than as thirty healthy attributes, so a probe fed one
        // holds an empty table and is still `Unreadable`.
        assert!(parse_ata_attributes(&[0u8; BUF_LEN]).is_err());
        let mut zeroed = probe(Source::None);
        zeroed.ata = parse_ata_attributes(&[0u8; BUF_LEN]).unwrap_or_default();
        assert_eq!(zeroed.finish().verdict, Verdict::Unreadable);
    }

    /// The source is what actually answered, never what was attempted. A drive
    /// stored as `ata_smart` whose attribute table never arrived would tell an
    /// operator we asked a question we did not ask.
    #[test]
    fn the_source_names_the_call_that_answered() {
        let mut only_predict = probe(Source::None);
        only_predict.predict_failure = Some(false);
        assert_eq!(only_predict.finish().source, Source::IoctlPredict);

        let mut only_ata = probe(Source::Sysfs);
        only_ata.ata = parse_ata_attributes(&ata::fixture::healthy()).unwrap();
        assert_eq!(only_ata.finish().source, Source::AtaSmart);

        // NVMe outranks both: it is the richest reading and the one the counters
        // below are lifted from.
        let mut nvme_too = probe(Source::None);
        nvme_too.predict_failure = Some(false);
        nvme_too.ata = parse_ata_attributes(&ata::fixture::healthy()).unwrap();
        nvme_too.nvme = Some(parse_nvme_health(&nvme::fixture::healthy()).unwrap());
        assert_eq!(nvme_too.finish().source, Source::NvmeLogPage);
    }

    /// Counter by counter against the documented fixture, so a pair of adjacent
    /// fields cannot be swapped in `finish` without a value moving.
    #[test]
    fn the_counters_are_lifted_out_of_the_reading_that_carried_them() {
        let mut healthy = probe(Source::None);
        healthy.nvme = Some(parse_nvme_health(&nvme::fixture::healthy()).unwrap());
        let health = healthy.finish();
        assert_eq!(health.verdict, Verdict::Ok);
        assert_eq!(health.source, Source::NvmeLogPage);
        assert_eq!(health.temp_c, Some(38)); // 311 K
        assert_eq!(health.power_on_hours, Some(9_874));
        assert_eq!(health.power_cycles, Some(412));
        assert_eq!(health.percent_used, Some(3));
        assert_eq!(health.spare_pct, Some(100));
        assert_eq!(health.spare_threshold_pct, Some(10));
        assert_eq!(health.critical_warning, Some(0));
        assert_eq!(health.unsafe_shutdowns, Some(37));
        assert_eq!(health.media_errors, Some(0));
        assert_eq!(health.data_written_gb, Some(12_009));
        // An NVMe log page carries none of the ATA sector counts, and the columns
        // they would fill stay absent rather than reading as four clean counts.
        assert_eq!(health.reallocated, None);
        assert_eq!(health.pending, None);
        assert_eq!(health.uncorrectable, None);
        assert_eq!(health.crc_errors, None);

        let mut ata_healthy = probe(Source::None);
        let attrs = ata::fixture::healthy();
        ata_healthy.ata = parse_ata_attributes(&attrs).unwrap();
        ata_healthy.thresholds = parse_ata_thresholds(&ata::fixture::thresholds()).unwrap();
        ata_healthy.ata_checksum = Some(checksum_ok(&attrs));
        let health = ata_healthy.finish();
        assert_eq!(health.verdict, Verdict::Ok);
        assert_eq!(health.source, Source::AtaSmart);
        assert_eq!(health.temp_c, Some(34));
        assert_eq!(health.power_on_hours, Some(9_874));
        assert_eq!(health.power_cycles, Some(412));
        assert_eq!(health.reallocated, Some(0));
        assert_eq!(health.pending, Some(0));
        assert_eq!(health.uncorrectable, Some(0));
        assert_eq!(health.crc_errors, Some(0));
        // The NVMe-only columns, from a drive that is not NVMe.
        assert_eq!(health.spare_pct, None);
        assert_eq!(health.spare_threshold_pct, None);
        assert_eq!(health.critical_warning, None);
        assert_eq!(health.data_written_gb, None);
    }

    /// A dying drive has to survive the fold, or the whole chain carries a green
    /// tick to the console. Both buses, and the ATA one needs its thresholds.
    #[test]
    fn a_failing_drive_is_still_failing_after_the_fold() {
        let mut nvme_bad = probe(Source::None);
        nvme_bad.nvme = Some(parse_nvme_health(&nvme::fixture::failing()).unwrap());
        let health = nvme_bad.finish();
        assert_eq!(health.verdict, Verdict::Failing);
        assert_eq!(health.spare_pct, Some(3));
        assert_eq!(health.spare_threshold_pct, Some(10));
        assert_eq!(health.critical_warning, Some(5)); // spare below threshold | reliability degraded
        assert_eq!(health.media_errors, Some(1_284));

        let mut ata_bad = probe(Source::None);
        let attrs = ata::fixture::failing();
        ata_bad.ata = parse_ata_attributes(&attrs).unwrap();
        ata_bad.thresholds = parse_ata_thresholds(&ata::fixture::thresholds()).unwrap();
        ata_bad.ata_checksum = Some(checksum_ok(&attrs));
        let health = ata_bad.finish();
        assert_eq!(health.verdict, Verdict::Failing);
        assert_eq!(health.reallocated, Some(1_296));
        assert_eq!(health.pending, Some(24));

        // And the drive's own prediction alone is enough, on a bus that answers
        // nothing else at all.
        let mut predicted = probe(Source::None);
        predicted.predict_failure = Some(true);
        assert_eq!(predicted.finish().verdict, Verdict::Failing);

        // A table that does not checksum is not evidence. It parses into
        // attribute ids nobody asked about, and letting that answer would make
        // the likeliest corruption on the Windows path render as a healthy drive.
        let mut corrupt = probe(Source::None);
        corrupt.ata = parse_ata_attributes(&ata::fixture::healthy()).unwrap();
        corrupt.thresholds = parse_ata_thresholds(&ata::fixture::thresholds()).unwrap();
        corrupt.ata_checksum = Some(false);
        assert_eq!(corrupt.finish().verdict, Verdict::Unreadable);
    }

    /// THE TWO FALLBACKS A RICHER READING HIDES.
    ///
    /// Both are silent data loss on real hardware if they are dropped, and both
    /// are invisible to every other test here because every other fixture
    /// carries a health structure that supplies the field itself.
    #[test]
    fn a_temperature_and_a_wear_figure_survive_without_a_health_structure() {
        // Linux hwmon: no privilege, no health, and still a real temperature.
        // An agent whose admin passthrough was refused reports it beside its
        // `Unreadable` verdict rather than reporting nothing at all.
        let mut hwmon = probe(Source::Sysfs);
        hwmon.temp_c = Some(29);
        let health = hwmon.finish();
        assert_eq!(health.verdict, Verdict::Unreadable);
        assert_eq!(health.temp_c, Some(29));

        // And it is the LAST resort, not a competitor: a call that carried its
        // own temperature wins, on both buses.
        let mut with_nvme = probe(Source::Sysfs);
        with_nvme.temp_c = Some(29);
        with_nvme.nvme = Some(parse_nvme_health(&nvme::fixture::healthy()).unwrap());
        assert_eq!(with_nvme.finish().temp_c, Some(38));
        let mut with_ata = probe(Source::Sysfs);
        with_ata.temp_c = Some(29);
        with_ata.ata = parse_ata_attributes(&ata::fixture::healthy()).unwrap();
        assert_eq!(with_ata.finish().temp_c, Some(34));

        // Wear on a SATA SSD is attribute 0xE7, whose normalised current value
        // is the percent REMAINING, so 91 remaining is 9 per cent used. It is
        // the only endurance figure the module has for an ATA drive, and
        // `disk_sample.percent_used` is empty fleet-wide for every SSD that is
        // not NVMe without it.
        let table = ata::fixture::attr_table(
            0x0010,
            &[ata::fixture::Row { id: 231, flags: 0x0032, current: 91, worst: 91, raw: 0 }],
        );
        let mut ssd = probe(Source::None);
        ssd.ata = parse_ata_attributes(&table).unwrap();
        ssd.ata_checksum = Some(checksum_ok(&table));
        let health = ssd.finish();
        assert_eq!(health.source, Source::AtaSmart);
        assert_eq!(health.verdict, Verdict::Ok);
        assert_eq!(health.percent_used, Some(9));

        // And the NVMe log page's own figure wins where a drive answered both.
        let mut both = probe(Source::None);
        both.ata = parse_ata_attributes(&table).unwrap();
        both.nvme = Some(parse_nvme_health(&nvme::fixture::healthy()).unwrap());
        assert_eq!(both.finish().percent_used, Some(3));
    }

    /// One drive at `device_index`, carrying `verdict` and nothing else.
    fn drive(device_index: u32, verdict: Verdict) -> DiskHealth {
        DiskHealth {
            device_index,
            verdict,
            ..probe(Source::None).finish()
        }
    }

    /// A SWEEP WIDER THAN THE SERVER ACCEPTS MUST NOT COST THE MACHINE ITS
    /// TELEMETRY.
    ///
    /// `/sys/block` is unbounded and `is_health_candidate` excludes only six
    /// prefixes, so a multipath SAN host, a ZFS host with zvols or a Ceph client
    /// really does enumerate more than 32 drives. The ingest bounds the `disks`
    /// member at the same 32; an agent that sent 40 would have had its whole
    /// uplink refused, metrics included, on every flush from then on.
    #[test]
    fn a_sweep_wider_than_the_server_accepts_is_cut_from_the_healthy_end() {
        assert_eq!(MAX_DISKS, 32);
        // Under the cap nothing is touched at all, not even the order.
        let few: Vec<DiskHealth> = (0..3).map(|n| drive(n, Verdict::Ok)).collect();
        assert_eq!(cap(few.clone()), few);
        let exact: Vec<DiskHealth> = (0..MAX_DISKS as u32).map(|n| drive(n, Verdict::Ok)).collect();
        assert_eq!(cap(exact.clone()), exact);
        // An empty sweep stays empty: it is the reading that says no drive
        // answered, and the collector sends it as one.
        assert!(cap(Vec::new()).is_empty());

        // Forty drives with the three that matter at the very end, which is
        // where a plain truncate would drop them.
        let mut many: Vec<DiskHealth> = (0..40).map(|n| drive(n, Verdict::Ok)).collect();
        many[37].verdict = Verdict::Unreadable;
        many[38].verdict = Verdict::Warn;
        many[39].verdict = Verdict::Failing;
        let capped = cap(many);
        assert_eq!(capped.len(), MAX_DISKS);
        assert_eq!(capped[0].verdict, Verdict::Failing);
        assert_eq!(capped[0].device_index, 39);
        assert_eq!(capped[1].verdict, Verdict::Warn);
        assert_eq!(capped[1].device_index, 38);
        assert_eq!(capped[2].verdict, Verdict::Unreadable);
        assert_eq!(capped[2].device_index, 37);
        // The healthy remainder keeps the order the platform enumerated it in,
        // so a machine's drives do not shuffle between sweeps.
        assert_eq!(capped[3].device_index, 0);
        assert_eq!(capped[4].device_index, 1);
        assert_eq!(capped[MAX_DISKS - 1].device_index, 28);
    }

    /// The identity a `disk` row is keyed on. The serial is preferred and never
    /// stored raw; without one the key has to be something the same drive
    /// reproduces on the next sweep, or every uplink adds a row.
    #[test]
    fn the_serial_hash_prefers_the_serial_and_is_stable_without_one() {
        let from_serial = serial_hash(Some("S3Z1NB0K"), Some("ACME 1TB"), Some(1_000), 0);
        // A hex sha256 and not the serial itself: this column identifies a drive,
        // it is not an inventory of a customer's hardware serial numbers.
        assert_eq!(from_serial.len(), 64);
        assert!(from_serial.chars().all(|c| c.is_ascii_hexdigit()));
        assert!(!from_serial.contains("S3Z1NB0K"));
        // The model, the size and the index are ignored while a serial exists, so
        // a drive moved to another port keeps its row.
        assert_eq!(serial_hash(Some("S3Z1NB0K"), None, None, 7), from_serial);
        // Whitespace is not identity, and a blank serial is no serial at all.
        assert_eq!(serial_hash(Some("  S3Z1NB0K  "), None, None, 0), from_serial);
        assert_eq!(
            serial_hash(Some("   "), Some("ACME 1TB"), Some(1_000), 0),
            serial_hash(None, Some("ACME 1TB"), Some(1_000), 0)
        );

        // Without a serial the key is model|size|index, which the same drive
        // reproduces every hour and two different drives do not share.
        let fallback = serial_hash(None, Some("ACME 1TB"), Some(1_000), 0);
        assert_eq!(serial_hash(None, Some("ACME 1TB"), Some(1_000), 0), fallback);
        assert_ne!(serial_hash(None, Some("ACME 1TB"), Some(1_000), 1), fallback);
        assert_ne!(serial_hash(None, Some("ACME 2TB"), Some(1_000), 0), fallback);
        assert_ne!(serial_hash(None, Some("ACME 1TB"), Some(2_000), 0), fallback);
        assert_ne!(fallback, from_serial);
        // A drive that refused everything still gets a key rather than a NULL,
        // which under SQLite's unique index rules would be distinct from every
        // other NULL and would add a fresh `disk` row on every uplink.
        assert_eq!(serial_hash(None, None, None, 0).len(), 64);
        assert_ne!(serial_hash(None, None, None, 0), serial_hash(None, None, None, 1));
    }

    /// Regenerate the committed byte fixtures from the builders in `ata::fixture`
    /// and `nvme::fixture`, which document every field they set:
    ///
    ///   LABDESK_WRITE_FIXTURES=1 cargo test -p rustdesk labdesk::disk::write_fixtures
    ///
    /// It is inert without that variable, so a normal test run never writes to
    /// the source tree. `fixtures_match_builders` in ata.rs and nvme.rs is what
    /// proves the committed bytes and the builders have not drifted apart.
    #[test]
    fn write_fixtures() {
        if std::env::var_os("LABDESK_WRITE_FIXTURES").is_none() {
            return;
        }
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("src/labdesk/disk/fixtures");
        fs::create_dir_all(&dir).unwrap();
        let ata_healthy = super::ata::fixture::healthy();
        let ata_failing = super::ata::fixture::failing();
        let ata_thresholds = super::ata::fixture::thresholds();
        let nvme_ok = super::nvme::fixture::healthy();
        let nvme_failing = super::nvme::fixture::failing();
        // An untouched output buffer: what a quietly failed ioctl leaves.
        let zeros = [0u8; super::BUF_LEN];
        let files: [(&str, &[u8]); 6] = [
            ("ata_attrs_healthy.bin", &ata_healthy),
            ("ata_attrs_failing.bin", &ata_failing),
            ("ata_thresholds.bin", &ata_thresholds),
            ("nvme_health_ok.bin", &nvme_ok),
            ("nvme_health_failing.bin", &nvme_failing),
            ("malformed_zeros.bin", &zeros),
        ];
        for (name, bytes) in files {
            fs::write(dir.join(name), bytes).unwrap();
        }
        // A short read: the first 100 bytes of a real attribute table, which is
        // the shape a USB bridge returns when it accepts the command and then
        // answers with less than it promised.
        fs::write(dir.join("malformed_short.bin"), &ata_healthy[..100]).unwrap();
    }
}
