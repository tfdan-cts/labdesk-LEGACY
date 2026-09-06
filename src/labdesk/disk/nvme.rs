// NVMe SMART / Health Information log page, log identifier 02h, 512 bytes.
//
// Windows returns it from IOCTL_STORAGE_QUERY_PROPERTY with
// StorageDeviceProtocolSpecificProperty; Linux returns it from
// NVME_IOCTL_ADMIN_CMD with opcode 02h (Get Log Page) on the controller node.
// Both hand back the same 512 bytes, so one parser serves both.
//
// Offsets below were read out of the vendored Windows header rather than
// recalled: windows-0.61.1/src/Windows/Win32/Storage/Nvme/mod.rs:2632,
// `struct NVME_HEALTH_INFO_LOG`. They agree with the NVMe base specification.
//
//   0        Critical Warning, one bit per condition
//   1..3     Composite Temperature, u16 little endian, in Kelvin
//   3        Available Spare, percent
//   4        Available Spare Threshold, percent
//   5        Percentage Used, percent of rated endurance consumed
//   6        Endurance Group Critical Warning Summary (NVMe 1.4+), reserved
//            in the Windows header, not read here
//   7..32    reserved
//   32..48   Data Units Read, u128 little endian, units of 1000 * 512 bytes
//   48..64   Data Units Written, same units
//   64..80   Host Read Commands, u128
//   80..96   Host Write Commands, u128
//   96..112  Controller Busy Time, u128 minutes
//   112..128 Power Cycles, u128
//   128..144 Power On Hours, u128
//   144..160 Unsafe Shutdowns, u128
//   160..176 Media and Data Integrity Errors, u128
//   176..192 Number of Error Information Log Entries, u128
//   192..196 Warning Composite Temperature Time, u32 minutes
//   196..200 Critical Composite Temperature Time, u32 minutes
//   200..216 Temperature Sensor 1..8, u16 Kelvin each, 0 means not implemented
//   216..512 reserved

use super::{DiskParseError, BUF_LEN};

// Critical Warning bits. Any one of them set is a failing drive.
/// Bit 0: available spare has fallen below the threshold.
pub const CW_SPARE_BELOW_THRESHOLD: u8 = 1 << 0;
/// Bit 1: temperature is above an over-temperature or below an
/// under-temperature threshold.
pub const CW_TEMPERATURE: u8 = 1 << 1;
/// Bit 2: NVM subsystem reliability is degraded.
pub const CW_RELIABILITY_DEGRADED: u8 = 1 << 2;
/// Bit 3: the media has been placed in read only mode.
pub const CW_READ_ONLY: u8 = 1 << 3;
/// Bit 4: the volatile memory backup device has failed.
pub const CW_VOLATILE_BACKUP_FAILED: u8 = 1 << 4;
/// Bit 5: the persistent memory region is unreliable (NVMe 1.4 and later).
pub const CW_PMR_UNRELIABLE: u8 = 1 << 5;

const OFF_CRITICAL_WARNING: usize = 0;
const OFF_TEMPERATURE: usize = 1;
const OFF_AVAIL_SPARE: usize = 3;
const OFF_SPARE_THRESHOLD: usize = 4;
const OFF_PERCENT_USED: usize = 5;
const OFF_DATA_UNITS_READ: usize = 32;
const OFF_DATA_UNITS_WRITTEN: usize = 48;
const OFF_POWER_CYCLES: usize = 112;
const OFF_POWER_ON_HOURS: usize = 128;
const OFF_UNSAFE_SHUTDOWNS: usize = 144;
const OFF_MEDIA_ERRORS: usize = 160;
const OFF_ERROR_LOG_ENTRIES: usize = 176;

/// The health log, decoded.
///
/// The spec's counters are 128 bit. The five narrowed to u64 here saturate
/// rather than wrap: 2^64 power on hours is not a reading any drive will
/// produce, but a corrupt buffer can contain it and a wrapped counter would read
/// as a plausible small number. Four of the five are `disk_sample` columns;
/// `error_log_entries` has no column and is carried for the vendor blob on
/// `disk_event`. The two data unit counters keep their full width, because they
/// are the ones large enough to be worth keeping exact.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct NvmeHealth {
    pub critical_warning: u8,
    /// Composite temperature in degrees Celsius, or None when the controller
    /// reports 0 Kelvin, which means "no composite temperature". Kelvin is
    /// converted by subtracting 273, the same rounding smartmontools uses.
    pub temp_c: Option<i32>,
    pub avail_spare: u8,
    pub spare_threshold: u8,
    pub percent_used: u8,
    pub data_units_read: u128,
    pub data_units_written: u128,
    pub power_cycles: u64,
    pub power_on_hours: u64,
    pub unsafe_shutdowns: u64,
    pub media_errors: u64,
    pub error_log_entries: u64,
    /// Data written in gigabytes, decimal. A data unit is 1000 * 512 bytes, so
    /// this is units * 512 / 1_000_000, computed in u128 before it narrows.
    pub data_written_gb: u64,
}

impl NvmeHealth {
    /// The critical warning bits that are set, named. Empty means none are.
    pub fn critical_warnings(&self) -> Vec<&'static str> {
        let mut v = Vec::new();
        let cw = self.critical_warning;
        if cw & CW_SPARE_BELOW_THRESHOLD != 0 {
            v.push("available spare below threshold");
        }
        if cw & CW_TEMPERATURE != 0 {
            v.push("temperature threshold exceeded");
        }
        if cw & CW_RELIABILITY_DEGRADED != 0 {
            v.push("reliability degraded");
        }
        if cw & CW_READ_ONLY != 0 {
            v.push("media is read only");
        }
        if cw & CW_VOLATILE_BACKUP_FAILED != 0 {
            v.push("volatile memory backup failed");
        }
        if cw & CW_PMR_UNRELIABLE != 0 {
            v.push("persistent memory region unreliable");
        }
        v
    }
}

fn u128_le(buf: &[u8], off: usize) -> u128 {
    let mut b = [0u8; 16];
    b.copy_from_slice(&buf[off..off + 16]);
    u128::from_le_bytes(b)
}

fn narrow(v: u128) -> u64 {
    if v > u64::MAX as u128 {
        u64::MAX
    } else {
        v as u64
    }
}

/// Parse a 512 byte SMART / Health Information log page.
///
/// An all-zero buffer is `Empty`. That is what an ioctl which failed without
/// saying so leaves behind, and reading it as a real log page would report a
/// drive with 0 percent spare capacity, which is either a lie or a fatal
/// alarm, and never the truth.
pub fn parse_nvme_health(buf: &[u8]) -> Result<NvmeHealth, DiskParseError> {
    if buf.len() < BUF_LEN {
        return Err(DiskParseError::TooShort {
            got: buf.len(),
            need: BUF_LEN,
        });
    }
    let page = &buf[..BUF_LEN];
    if page.iter().all(|&b| b == 0) {
        return Err(DiskParseError::Empty);
    }

    let kelvin = u16::from_le_bytes([page[OFF_TEMPERATURE], page[OFF_TEMPERATURE + 1]]);
    let temp_c = match kelvin {
        0 => None,
        k => {
            let c = i32::from(k) - 273;
            // Outside this window the field does not hold a temperature.
            if (-60..=200).contains(&c) {
                Some(c)
            } else {
                None
            }
        }
    };

    let data_units_written = u128_le(page, OFF_DATA_UNITS_WRITTEN);
    Ok(NvmeHealth {
        critical_warning: page[OFF_CRITICAL_WARNING],
        temp_c,
        avail_spare: page[OFF_AVAIL_SPARE],
        spare_threshold: page[OFF_SPARE_THRESHOLD],
        percent_used: page[OFF_PERCENT_USED],
        data_units_read: u128_le(page, OFF_DATA_UNITS_READ),
        data_units_written,
        power_cycles: narrow(u128_le(page, OFF_POWER_CYCLES)),
        power_on_hours: narrow(u128_le(page, OFF_POWER_ON_HOURS)),
        unsafe_shutdowns: narrow(u128_le(page, OFF_UNSAFE_SHUTDOWNS)),
        media_errors: narrow(u128_le(page, OFF_MEDIA_ERRORS)),
        error_log_entries: narrow(u128_le(page, OFF_ERROR_LOG_ENTRIES)),
        data_written_gb: narrow(data_units_written.saturating_mul(512) / 1_000_000),
    })
}

/// How the committed NVMe fixtures are built. Every value is documented in
/// `fixtures/README.md`.
#[cfg(test)]
pub(crate) mod fixture {
    /// The log page in the units the spec uses, before it is laid out in bytes.
    pub struct Log {
        pub critical_warning: u8,
        pub temp_k: u16,
        pub avail_spare: u8,
        pub spare_threshold: u8,
        pub percent_used: u8,
        pub units_read: u128,
        pub units_written: u128,
        pub host_reads: u128,
        pub host_writes: u128,
        pub busy_minutes: u128,
        pub power_cycles: u128,
        pub power_on_hours: u128,
        pub unsafe_shutdowns: u128,
        pub media_errors: u128,
        pub error_entries: u128,
        pub warn_temp_minutes: u32,
        pub crit_temp_minutes: u32,
        pub sensors: [u16; 8],
    }

    pub fn page(l: &Log) -> [u8; 512] {
        let mut b = [0u8; 512];
        b[0] = l.critical_warning;
        b[1..3].copy_from_slice(&l.temp_k.to_le_bytes());
        b[3] = l.avail_spare;
        b[4] = l.spare_threshold;
        b[5] = l.percent_used;
        // 6..32 reserved, left zero.
        let mut put = |off: usize, v: u128| b[off..off + 16].copy_from_slice(&v.to_le_bytes());
        put(32, l.units_read);
        put(48, l.units_written);
        put(64, l.host_reads);
        put(80, l.host_writes);
        put(96, l.busy_minutes);
        put(112, l.power_cycles);
        put(128, l.power_on_hours);
        put(144, l.unsafe_shutdowns);
        put(160, l.media_errors);
        put(176, l.error_entries);
        b[192..196].copy_from_slice(&l.warn_temp_minutes.to_le_bytes());
        b[196..200].copy_from_slice(&l.crit_temp_minutes.to_le_bytes());
        for (i, s) in l.sensors.iter().enumerate() {
            let o = 200 + i * 2;
            b[o..o + 2].copy_from_slice(&s.to_le_bytes());
        }
        b
    }

    /// A healthy 1 TB consumer NVMe SSD: no warnings, 38 C, full spare
    /// capacity, 3 percent of endurance used, about 12 TB written.
    pub fn healthy() -> [u8; 512] {
        page(&Log {
            critical_warning: 0x00,
            temp_k: 311,
            avail_spare: 100,
            spare_threshold: 10,
            percent_used: 3,
            units_read: 45_678_901,
            units_written: 23_456_789,
            host_reads: 987_654_321,
            host_writes: 456_789_012,
            busy_minutes: 5_432,
            power_cycles: 412,
            power_on_hours: 9_874,
            unsafe_shutdowns: 37,
            media_errors: 0,
            error_entries: 12,
            warn_temp_minutes: 0,
            crit_temp_minutes: 0,
            sensors: [311, 318, 0, 0, 0, 0, 0, 0],
        })
    }

    /// A worn out drive that has started to fail: spare capacity below its
    /// threshold and reliability degraded (critical warning bits 0 and 2),
    /// 74 C, endurance fully consumed, media errors accumulating.
    pub fn failing() -> [u8; 512] {
        page(&Log {
            critical_warning: super::CW_SPARE_BELOW_THRESHOLD | super::CW_RELIABILITY_DEGRADED,
            temp_k: 347,
            avail_spare: 3,
            spare_threshold: 10,
            percent_used: 100,
            units_read: 812_345_678,
            units_written: 400_000_000,
            host_reads: 9_876_543_210,
            host_writes: 8_765_432_109,
            busy_minutes: 512_345,
            power_cycles: 1_207,
            power_on_hours: 43_800,
            unsafe_shutdowns: 96,
            media_errors: 1_284,
            error_entries: 4_211,
            warn_temp_minutes: 8_640,
            crit_temp_minutes: 613,
            sensors: [347, 351, 0, 0, 0, 0, 0, 0],
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEALTHY: &[u8] = include_bytes!("fixtures/nvme_health_ok.bin");
    const FAILING: &[u8] = include_bytes!("fixtures/nvme_health_failing.bin");
    const SHORT: &[u8] = include_bytes!("fixtures/malformed_short.bin");
    const ZEROS: &[u8] = include_bytes!("fixtures/malformed_zeros.bin");

    #[test]
    fn fixtures_match_builders() {
        assert_eq!(HEALTHY, &fixture::healthy()[..]);
        assert_eq!(FAILING, &fixture::failing()[..]);
    }

    #[test]
    fn reads_every_documented_field() {
        let h = parse_nvme_health(HEALTHY).unwrap();
        assert_eq!(h.critical_warning, 0);
        assert_eq!(h.temp_c, Some(38), "311 K is 38 C");
        assert_eq!(h.avail_spare, 100);
        assert_eq!(h.spare_threshold, 10);
        assert_eq!(h.percent_used, 3);
        assert_eq!(h.data_units_read, 45_678_901);
        assert_eq!(h.data_units_written, 23_456_789);
        assert_eq!(h.power_cycles, 412);
        assert_eq!(h.power_on_hours, 9_874);
        assert_eq!(h.unsafe_shutdowns, 37);
        assert_eq!(h.media_errors, 0);
        assert_eq!(h.error_log_entries, 12);
        // 23_456_789 units * 512 000 bytes = 12_009_875_968 000 bytes.
        assert_eq!(h.data_written_gb, 12_009);
        assert!(h.critical_warnings().is_empty());
    }

    /// The one page here that came off a drive: log page 02h from a Micron
    /// 3400 MTFDKBA512TFH on homebox-devserver, 2026-09-05, read over
    /// `NVME_IOCTL_ADMIN_CMD` by `linux::nvme_health_page`. Provenance in
    /// `fixtures/README.md`.
    #[test]
    fn reads_a_real_micron_page() {
        const REAL: &[u8] = include_bytes!("fixtures/nvme_health_micron3400.bin");
        let h = parse_nvme_health(REAL).unwrap();
        assert_eq!(h.critical_warning, 0);
        assert_eq!(h.temp_c, Some(27), "300 K is 27 C");
        assert_eq!(h.avail_spare, 100);
        assert_eq!(h.spare_threshold, 5);
        assert_eq!(h.percent_used, 1);
        assert_eq!(h.data_units_read, 2_342_348);
        assert_eq!(h.data_units_written, 8_367_439);
        assert_eq!(h.power_cycles, 36);
        assert_eq!(h.power_on_hours, 4_500);
        assert_eq!(h.unsafe_shutdowns, 25);
        assert_eq!(h.media_errors, 0);
        assert_eq!(h.data_written_gb, 4_284);
        assert!(h.critical_warnings().is_empty());
    }

    #[test]
    fn reads_the_failing_page() {
        let f = parse_nvme_health(FAILING).unwrap();
        assert_eq!(f.critical_warning, 0b0000_0101);
        assert_eq!(f.temp_c, Some(74));
        assert_eq!(f.avail_spare, 3);
        assert_eq!(f.spare_threshold, 10);
        assert_eq!(f.percent_used, 100);
        assert_eq!(f.media_errors, 1_284);
        assert_eq!(
            f.critical_warnings(),
            vec!["available spare below threshold", "reliability degraded"]
        );
    }

    /// Every counter is 128 bit little endian at its own 16 byte slot. This
    /// catches a field read from the wrong offset, which a fixture whose
    /// counters were all small would not.
    #[test]
    fn counters_are_read_from_their_own_offsets() {
        let mut b = fixture::healthy();
        for (off, expect) in [(112usize, 1u128), (128, 2), (144, 3), (160, 4), (176, 5)] {
            b[off..off + 16].copy_from_slice(&expect.to_le_bytes());
        }
        let h = parse_nvme_health(&b).unwrap();
        assert_eq!(
            (h.power_cycles, h.power_on_hours, h.unsafe_shutdowns, h.media_errors, h.error_log_entries),
            (1, 2, 3, 4, 5)
        );
    }

    #[test]
    fn oversized_counters_saturate_rather_than_wrap() {
        let mut b = fixture::healthy();
        b[128..144].copy_from_slice(&u128::MAX.to_le_bytes()); // power on hours
        let h = parse_nvme_health(&b).unwrap();
        assert_eq!(h.power_on_hours, u64::MAX, "a wrapped counter would look plausible");
    }

    #[test]
    fn unreported_temperature_is_absent_not_minus_273() {
        let mut b = fixture::healthy();
        b[1..3].copy_from_slice(&0u16.to_le_bytes());
        assert_eq!(parse_nvme_health(&b).unwrap().temp_c, None);
        // A value that is not a temperature at all is also absent.
        b[1..3].copy_from_slice(&60_000u16.to_le_bytes());
        assert_eq!(parse_nvme_health(&b).unwrap().temp_c, None);
    }

    #[test]
    fn short_buffer_is_an_error_not_a_panic() {
        assert_eq!(
            parse_nvme_health(SHORT),
            Err(DiskParseError::TooShort { got: SHORT.len(), need: 512 })
        );
        assert_eq!(parse_nvme_health(&[]), Err(DiskParseError::TooShort { got: 0, need: 512 }));
    }

    #[test]
    fn untouched_buffer_is_empty_not_a_dead_drive() {
        assert_eq!(parse_nvme_health(ZEROS), Err(DiskParseError::Empty));
    }

    #[test]
    fn arbitrary_bytes_never_panic() {
        let mut b = [0u8; 512];
        for (i, x) in b.iter_mut().enumerate() {
            *x = ((i as u32).wrapping_mul(2_654_435_761) >> 11) as u8;
        }
        let _ = parse_nvme_health(&b);
        for len in 0..=512 {
            let _ = parse_nvme_health(&b[..len]);
        }
    }
}
