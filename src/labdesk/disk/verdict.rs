// One drive, one verdict, and the sentence that explains it.
//
// The verdict is computed on the agent so the reason travels with the reading,
// and the server re-derives it from the stored counters so the console never
// takes an agent's word for "ok".
//
// The rule that matters more than any threshold in here: a call that was
// refused, unsupported or answered with an unreadable buffer is `Unreadable`.
// It is never `Ok`. A USB bridge that will not pass SMART through has not told
// us the disk is healthy, it has told us nothing, and a green tick in that case
// is a lie the operator cannot see through.

use std::cmp::Ordering;
use std::collections::HashMap;

use super::ata::{
    AtaAttr, ATTR_OFFLINE_UNCORRECTABLE, ATTR_PENDING_SECTORS, ATTR_REALLOCATED_EVENTS,
    ATTR_REALLOCATED_SECTORS, ATTR_REPORTED_UNCORRECTABLE,
};
use super::nvme::NvmeHealth;

/// Which call produced the reading. Stored as `disk.health_source` so the
/// console can say what was asked, not only what was answered.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Source {
    /// Windows IOCTL_STORAGE_PREDICT_FAILURE. Works on every bus, including the
    /// USB bridges and RAID members that refuse everything else.
    IoctlPredict,
    /// The NVMe SMART / Health Information log page, identifier 02h.
    NvmeLogPage,
    /// The ATA SMART attribute table.
    AtaSmart,
    /// Linux /sys only: identity, size and sometimes temperature. Carries no
    /// failure evidence, so on its own it can only ever produce `Unreadable`.
    Sysfs,
    /// Nothing answered.
    None,
}

impl Source {
    /// The string stored in `disk.health_source`.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::IoctlPredict => "ioctl_predict",
            Self::NvmeLogPage => "nvme_logpage",
            Self::AtaSmart => "ata_smart",
            Self::Sysfs => "sysfs",
            Self::None => "none",
        }
    }
}

/// The four states `disk_sample.verdict` and `disk_event.verdict` hold.
///
/// `Ord` is written out below rather than derived, because the derived ordering
/// follows declaration order and would rank `Unreadable` above `Failing`. A
/// fleet view folding a machine's disks with `max()` would then surface "we
/// could not ask" and push the drive that is actually dying down the list.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Ok,
    Warn,
    Failing,
    /// We could not ask. Distinct from `Ok` on purpose, and the console renders
    /// it as its own state rather than as a healthy drive.
    Unreadable,
}

impl Verdict {
    /// The string stored in the database.
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Ok => "ok",
            Self::Warn => "warn",
            Self::Failing => "failing",
            Self::Unreadable => "unreadable",
        }
    }

    /// How bad this is, worst highest, so `machine_state.worst_disk` can be an
    /// `iter().max()` and land on the right drive.
    ///
    /// `Unreadable` sits above `Ok` because a disk nobody could ask about is not
    /// a healthy disk and must not be hidden among them, and below `Warn`
    /// because it carries no evidence of damage, only the absence of evidence.
    pub fn severity(&self) -> u8 {
        match self {
            Self::Ok => 0,
            Self::Unreadable => 1,
            Self::Warn => 2,
            Self::Failing => 3,
        }
    }
}

impl Ord for Verdict {
    fn cmp(&self, other: &Self) -> Ordering {
        self.severity().cmp(&other.severity())
    }
}

impl PartialOrd for Verdict {
    fn partial_cmp(&self, other: &Self) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

/// Decide a drive's health from whatever the platform layer managed to read.
///
/// `predict_failure` carries both of the drive's own yes/no answers, because
/// they mean the same thing: Windows IOCTL_STORAGE_PREDICT_FAILURE, and the
/// ATA SMART RETURN STATUS cylinder registers decoded by
/// [`super::ata::smart_status_failing`]. `None` means neither was asked or
/// neither answered, which is not the same as `Some(false)`.
///
/// `ata_checksum` is [`super::ata::checksum_ok`] over the buffer `ata` was
/// parsed from, ANDed with the same over the threshold buffer when one was
/// read. `None` means the caller did not compute it. `Some(false)` discards the
/// attribute table as evidence: a table that does not checksum was not read.
/// The bytes still parse, into attribute ids nobody asked about, and if that
/// junk is allowed to answer then the single most likely corruption on the
/// Windows path renders as a healthy drive.
///
/// Two rules from the plan are deliberately absent, because they need history
/// and this function sees one sample: "CRC rising between samples" and
/// "temperature at or above 60 C for two consecutive hours". Both are derived
/// server side from `disk_sample`, where the previous readings live.
///
/// Returns the verdict and a human readable reason, which is stored on
/// `disk_event.reason` and shown in the console.
pub fn verdict(
    src: Source,
    nvme: Option<&NvmeHealth>,
    ata: &[AtaAttr],
    thresholds: &HashMap<u8, u8>,
    predict_failure: Option<bool>,
    ata_checksum: Option<bool>,
) -> (Verdict, String) {
    // A shifted buffer parses cleanly into nonsense, so the checksum is the only
    // thing standing between it and a green tick. Drop the table rather than
    // reason over it; the drive's own prediction and an NVMe log page come from
    // other calls and still count.
    let bad_checksum = !ata.is_empty() && ata_checksum == Some(false);
    let ata: &[AtaAttr] = if bad_checksum { &[] } else { ata };

    // No evidence, whatever the source claims. Sysfs identity and a capacity
    // are not health, and neither is an empty attribute table.
    if nvme.is_none() && ata.is_empty() && predict_failure.is_none() {
        let why = if bad_checksum {
            format!(
                "the SMART attribute table does not checksum, so its bytes carry no reading (source {})",
                src.as_str()
            )
        } else {
            format!("no health data returned (source {})", src.as_str())
        };
        return (Verdict::Unreadable, why);
    }

    let raw = |id: u8| ata.iter().find(|a| a.id == id).map(|a| a.raw48());

    let mut failing: Vec<String> = Vec::new();

    if predict_failure == Some(true) {
        failing.push("the drive predicts its own failure".to_string());
    }
    if let Some(n) = nvme {
        for w in n.critical_warnings() {
            failing.push(format!("NVMe critical warning: {}", w));
        }
        if n.avail_spare < n.spare_threshold {
            failing.push(format!(
                "available spare {}% is below the drive's threshold of {}%",
                n.avail_spare, n.spare_threshold
            ));
        }
    }
    // A pre-failure attribute has failed when it has a nonzero count AND its
    // normalised value has reached the threshold the drive itself published.
    // A threshold of 0 means the attribute cannot fail, per ATA-8, so it is
    // skipped rather than treated as "current <= 0".
    for (id, name) in [
        (ATTR_REALLOCATED_SECTORS, "reallocated sectors"),
        (ATTR_PENDING_SECTORS, "pending sectors"),
        (ATTR_OFFLINE_UNCORRECTABLE, "offline uncorrectable sectors"),
    ] {
        let Some(attr) = ata.iter().find(|a| a.id == id) else {
            continue;
        };
        let count = attr.raw48();
        let Some(&thr) = thresholds.get(&id) else {
            continue;
        };
        if count > 0 && thr > 0 && attr.current <= thr {
            failing.push(format!(
                "{} {} with normalised value {} at or below the threshold of {}",
                count, name, attr.current, thr
            ));
        }
    }
    if !failing.is_empty() {
        return (Verdict::Failing, failing.join("; "));
    }

    let mut warn: Vec<String> = Vec::new();
    for (id, name) in [
        (ATTR_REALLOCATED_SECTORS, "reallocated sectors"),
        (ATTR_REALLOCATED_EVENTS, "reallocation events"),
        (ATTR_PENDING_SECTORS, "pending sectors"),
        (ATTR_OFFLINE_UNCORRECTABLE, "offline uncorrectable sectors"),
        (ATTR_REPORTED_UNCORRECTABLE, "reported uncorrectable errors"),
    ] {
        match raw(id) {
            Some(n) if n > 0 => warn.push(format!("{} {}", n, name)),
            _ => {}
        }
    }
    if let Some(n) = nvme {
        // The NVMe counterpart of ATA's uncorrectable sector counts: data the
        // controller could not recover. A drive accumulating these is not
        // healthy, and waiting for a critical warning bit to set is later than
        // the operator needed to know.
        if n.media_errors > 0 {
            warn.push(format!(
                "{} media and data integrity errors",
                n.media_errors
            ));
        }
        if n.percent_used >= 90 {
            warn.push(format!("{}% of rated write endurance used", n.percent_used));
        }
    }
    if !warn.is_empty() {
        return (Verdict::Warn, warn.join("; "));
    }

    (
        Verdict::Ok,
        format!("no failure indicators (source {})", src.as_str()),
    )
}

#[cfg(test)]
mod tests {
    use super::super::ata::{checksum_ok, parse_ata_attributes, parse_ata_thresholds};
    use super::super::nvme::parse_nvme_health;
    use super::super::DiskParseError;
    use super::*;

    const ATA_HEALTHY: &[u8] = include_bytes!("fixtures/ata_attrs_healthy.bin");
    const ATA_FAILING: &[u8] = include_bytes!("fixtures/ata_attrs_failing.bin");
    const ATA_THRESHOLDS: &[u8] = include_bytes!("fixtures/ata_thresholds.bin");
    const NVME_HEALTHY: &[u8] = include_bytes!("fixtures/nvme_health_ok.bin");
    const NVME_FAILING: &[u8] = include_bytes!("fixtures/nvme_health_failing.bin");
    const SHORT: &[u8] = include_bytes!("fixtures/malformed_short.bin");
    const ZEROS: &[u8] = include_bytes!("fixtures/malformed_zeros.bin");

    fn no_thresholds() -> HashMap<u8, u8> {
        HashMap::new()
    }

    #[test]
    fn healthy_ata_disk_is_ok() {
        let attrs = parse_ata_attributes(ATA_HEALTHY).unwrap();
        let thr = parse_ata_thresholds(ATA_THRESHOLDS).unwrap();
        let (v, why) = verdict(Source::AtaSmart, None, &attrs, &thr, Some(false), Some(true));
        assert_eq!(v, Verdict::Ok, "{}", why);
        assert_eq!(v.as_str(), "ok");
    }

    #[test]
    fn failing_ata_disk_is_failing_and_says_why() {
        let attrs = parse_ata_attributes(ATA_FAILING).unwrap();
        let thr = parse_ata_thresholds(ATA_THRESHOLDS).unwrap();
        let (v, why) = verdict(Source::AtaSmart, None, &attrs, &thr, None, Some(true));
        assert_eq!(v, Verdict::Failing);
        assert!(why.contains("1296 reallocated sectors"), "reason was: {}", why);
        assert!(why.contains("threshold of 36"), "reason was: {}", why);
    }

    /// ATA-8: a pre-failure attribute has failed when its normalised value is at
    /// or below the published threshold. Exactly at it is the moment the rule
    /// fires, and an off-by-one there quietly downgrades a failing disk to a
    /// warning.
    #[test]
    fn current_exactly_at_the_threshold_is_a_failure() {
        let attrs = |current: u8| {
            vec![AtaAttr {
                id: ATTR_REALLOCATED_SECTORS,
                flags: 0x0033,
                current,
                worst: current,
                raw: [1, 0, 0, 0, 0, 0],
            }]
        };
        let thr: HashMap<u8, u8> = [(ATTR_REALLOCATED_SECTORS, 36)].into_iter().collect();
        let v = |c: u8| verdict(Source::AtaSmart, None, &attrs(c), &thr, None, None).0;
        assert_eq!(v(37), Verdict::Warn, "one above the threshold has not failed yet");
        assert_eq!(v(36), Verdict::Failing, "at the threshold is a failure");
        assert_eq!(v(35), Verdict::Failing);
    }

    /// The one byte shift the Windows path makes when it reads the payload from
    /// size_of::<SENDCMDOUTPARAMS>() instead of size_of - 1. The bytes still
    /// parse, into attributes nobody asked about, and the checksum is the only
    /// signal that says so.
    #[test]
    fn a_shifted_buffer_is_unreadable_not_ok() {
        let mut shifted = [0u8; 512];
        shifted[..511].copy_from_slice(&ATA_HEALTHY[1..512]);
        assert!(!checksum_ok(&shifted), "the shift is what the checksum catches");
        let attrs = parse_ata_attributes(&shifted).unwrap();
        let thr = parse_ata_thresholds(ATA_THRESHOLDS).unwrap();

        let (v, why) = verdict(Source::AtaSmart, None, &attrs, &thr, None, Some(false));
        assert_eq!(v, Verdict::Unreadable, "reason was: {}", why);
        assert!(why.contains("does not checksum"), "reason was: {}", why);

        // What the checksum buys, stated as a test: told the table is sound, the
        // very same junk renders as a healthy drive.
        assert_eq!(
            verdict(Source::AtaSmart, None, &attrs, &thr, None, Some(true)).0,
            Verdict::Ok
        );
    }

    /// The same damaged drive with no threshold table is a warning, not a
    /// failure: without the drive's own threshold there is no evidence the
    /// normalised value has crossed anything.
    #[test]
    fn damage_without_a_threshold_table_is_a_warning() {
        let attrs = parse_ata_attributes(ATA_FAILING).unwrap();
        let (v, why) = verdict(Source::AtaSmart, None, &attrs, &no_thresholds(), None, Some(true));
        assert_eq!(v, Verdict::Warn);
        assert!(why.contains("1296 reallocated sectors"), "reason was: {}", why);
        assert!(why.contains("24 pending sectors"), "reason was: {}", why);
    }

    /// A threshold of 0 means the attribute cannot fail. Reading it as
    /// "current <= 0" would fail every drive that ever reports a 0.
    #[test]
    fn a_zero_threshold_cannot_fail_a_drive() {
        let attrs = vec![AtaAttr {
            id: ATTR_PENDING_SECTORS,
            flags: 0x0012,
            current: 0,
            worst: 0,
            raw: [8, 0, 0, 0, 0, 0],
        }];
        let thr: HashMap<u8, u8> = [(ATTR_PENDING_SECTORS, 0)].into_iter().collect();
        assert_eq!(verdict(Source::AtaSmart, None, &attrs, &thr, None, None).0, Verdict::Warn);
    }

    #[test]
    fn the_drives_own_prediction_outranks_clean_attributes() {
        let attrs = parse_ata_attributes(ATA_HEALTHY).unwrap();
        let thr = parse_ata_thresholds(ATA_THRESHOLDS).unwrap();
        let (v, why) = verdict(Source::IoctlPredict, None, &attrs, &thr, Some(true), Some(true));
        assert_eq!(v, Verdict::Failing);
        assert!(why.contains("predicts its own failure"), "reason was: {}", why);
    }

    #[test]
    fn healthy_nvme_is_ok() {
        let h = parse_nvme_health(NVME_HEALTHY).unwrap();
        let (v, why) = verdict(Source::NvmeLogPage, Some(&h), &[], &no_thresholds(), None, None);
        assert_eq!(v, Verdict::Ok, "{}", why);
    }

    #[test]
    fn nvme_critical_warning_and_spare_are_failures() {
        let f = parse_nvme_health(NVME_FAILING).unwrap();
        let (v, why) = verdict(Source::NvmeLogPage, Some(&f), &[], &no_thresholds(), None, None);
        assert_eq!(v, Verdict::Failing);
        assert!(why.contains("available spare below threshold"), "reason was: {}", why);
        assert!(why.contains("reliability degraded"), "reason was: {}", why);
        assert!(why.contains("below the drive's threshold of 10%"), "reason was: {}", why);
    }

    #[test]
    fn nvme_wear_alone_is_a_warning() {
        let mut h = parse_nvme_health(NVME_HEALTHY).unwrap();
        h.percent_used = 94;
        let (v, why) = verdict(Source::NvmeLogPage, Some(&h), &[], &no_thresholds(), None, None);
        assert_eq!(v, Verdict::Warn);
        assert!(why.contains("94% of rated write endurance used"), "reason was: {}", why);
    }

    /// Media and data integrity errors are the NVMe analogue of ATA's
    /// uncorrectable sectors: data the controller could not recover. A drive
    /// collecting them is not a healthy drive.
    #[test]
    fn nvme_media_errors_are_a_warning() {
        let mut h = parse_nvme_health(NVME_HEALTHY).unwrap();
        assert_eq!(h.media_errors, 0, "the healthy fixture has none, so this test is the only source");
        h.media_errors = 4_211;
        let (v, why) = verdict(Source::NvmeLogPage, Some(&h), &[], &no_thresholds(), None, None);
        assert_eq!(v, Verdict::Warn, "reason was: {}", why);
        assert!(why.contains("4211 media and data integrity errors"), "reason was: {}", why);
    }

    /// The heart of the package. Nothing answered, so the answer is
    /// "unreadable", never "ok".
    #[test]
    fn nothing_answered_is_unreadable_never_ok() {
        for src in [Source::None, Source::Sysfs, Source::IoctlPredict, Source::AtaSmart] {
            let (v, why) = verdict(src, None, &[], &no_thresholds(), None, None);
            assert_eq!(v, Verdict::Unreadable, "source {} must not produce ok", src.as_str());
            assert_eq!(v.as_str(), "unreadable");
            assert!(why.contains("no health data"), "reason was: {}", why);
        }
    }

    /// A drive that answered "I am not failing" and nothing else is still a
    /// reading, and it is ok.
    #[test]
    fn a_bare_negative_prediction_is_ok() {
        let (v, _) = verdict(Source::IoctlPredict, None, &[], &no_thresholds(), Some(false), None);
        assert_eq!(v, Verdict::Ok);
    }

    /// End to end over the malformed fixtures: a short buffer and an untouched
    /// buffer both reach `Unreadable`, and neither panics on the way.
    #[test]
    fn malformed_buffers_end_as_unreadable_without_panicking() {
        for bad in [SHORT, ZEROS] {
            let attrs = parse_ata_attributes(bad);
            let nvme = parse_nvme_health(bad);
            assert!(matches!(attrs, Err(DiskParseError::TooShort { .. } | DiskParseError::Empty)));
            assert!(matches!(nvme, Err(DiskParseError::TooShort { .. } | DiskParseError::Empty)));

            // What the platform layer does with those errors: contribute
            // nothing, and never a zeroed reading.
            let attrs = attrs.unwrap_or_default();
            let nvme = nvme.ok();
            let thr = parse_ata_thresholds(bad).unwrap_or_default();
            let (v, _) = verdict(
                Source::None,
                nvme.as_ref(),
                &attrs,
                &thr,
                None,
                Some(checksum_ok(bad)),
            );
            assert_eq!(v, Verdict::Unreadable);
        }
    }

    /// A fleet view folds a machine's disks into one value with `max()`. The
    /// drive that is dying has to come out of that, not the one nobody could
    /// ask about. The derived ordering would do the opposite.
    #[test]
    fn severity_ranks_a_dying_drive_above_an_unreadable_one() {
        let mut all = [Verdict::Unreadable, Verdict::Ok, Verdict::Failing, Verdict::Warn];
        all.sort();
        assert_eq!(
            all,
            [Verdict::Ok, Verdict::Unreadable, Verdict::Warn, Verdict::Failing]
        );
        assert_eq!(
            [Verdict::Unreadable, Verdict::Failing].into_iter().max(),
            Some(Verdict::Failing)
        );
        // And an unreadable disk still outranks the healthy ones, so it cannot
        // be hidden among them.
        assert_eq!(
            [Verdict::Ok, Verdict::Unreadable, Verdict::Ok].into_iter().max(),
            Some(Verdict::Unreadable)
        );
    }

    #[test]
    fn source_strings_match_the_schema() {
        assert_eq!(
            [
                Source::IoctlPredict,
                Source::NvmeLogPage,
                Source::AtaSmart,
                Source::Sysfs,
                Source::None
            ]
            .map(|s| s.as_str()),
            ["ioctl_predict", "nvme_logpage", "ata_smart", "sysfs", "none"]
        );
        assert_eq!(
            [Verdict::Ok, Verdict::Warn, Verdict::Failing, Verdict::Unreadable].map(|v| v.as_str()),
            ["ok", "warn", "failing", "unreadable"]
        );
    }
}
