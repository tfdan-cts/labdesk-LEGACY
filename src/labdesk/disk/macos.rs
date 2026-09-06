// macOS: there are no bytes to fetch, and this file says so out loud.
//
// This module is deliberately almost empty. It exists so the collector compiles
// and behaves the same shape on all three operating systems, and so that the
// gap is a named, tested constant rather than a `#[cfg]` branch someone later
// mistakes for an oversight.
//
// What was looked for and not found:
//
//   * No public user-space API returns the NVMe SMART / Health Information log
//     page or the ATA SMART attribute table. smartmontools reaches them through
//     `IONVMeSMARTUserClient` and `IOAHCISMARTUserClient`, which are private
//     IOKit user clients, not API, and Apple has changed them between releases.
//   * `smartctl` is not installed on a stock macOS, and shelling out to a
//     bundled copy from the privileged daemon is exactly the escalation surface
//     the Windows and Linux paths were written to avoid.
//   * Apple-silicon internal storage does not expose the standard NVMe log page
//     through anything that could be verified.
//
// So v1 reports macOS disks as `Verdict::Unreadable` with a `health_source` of
// `none`. The console renders that as its own state and never as a green tick,
// which is the whole reason the pure layer keeps "the disk is fine" and "we
// could not ask" apart.
//
// This is an unmet requirement, not a solved one. A macOS-heavy fleet does not
// have hard drive health, and it will not until a vendor path exists that can
// be verified rather than guessed at. Anything added here later must produce
// the same 512-byte buffers `ata.rs` and `nvme.rs` already parse; do not add a
// third parser.

use super::verdict::{Source, Verdict};

/// The reason stored on `disk_event.reason`, so an operator reading the console
/// learns why the drive is unreadable instead of assuming the agent is broken.
pub const NO_HEALTH_SOURCE: &str =
    "macOS exposes no public interface for SMART or the NVMe health log page, so this drive's \
     health could not be read";

/// What the collector records for every disk on macOS.
///
/// Not a placeholder returning `Ok`: the pair below is the honest answer, and
/// `tests::macos_never_reports_a_healthy_disk` is here so it stays that way if
/// somebody later wires identity or capacity into this module and is tempted to
/// call that a reading.
pub fn health() -> (Verdict, Source, &'static str) {
    (Verdict::Unreadable, Source::None, NO_HEALTH_SOURCE)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The one rule this file exists to hold. `Unreadable` is not a degraded
    /// `Ok`; a fleet dashboard folding disks with `max()` must surface a macOS
    /// drive as unknown, and `Ok` here would hide it among the healthy ones.
    #[test]
    fn macos_never_reports_a_healthy_disk() {
        let (verdict, source, reason) = health();
        assert_eq!(verdict, Verdict::Unreadable);
        assert_eq!(verdict.as_str(), "unreadable");
        assert_eq!(source, Source::None);
        assert_eq!(source.as_str(), "none");
        assert!(!reason.is_empty());
        // Worse than Ok, better than Warn: an absence of evidence, not evidence
        // of damage.
        assert!(Verdict::Unreadable > Verdict::Ok);
        assert!(Verdict::Unreadable < Verdict::Warn);
    }
}
