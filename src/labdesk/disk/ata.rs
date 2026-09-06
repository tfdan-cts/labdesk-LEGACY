// ATA/SATA SMART, the two 512 byte structures a drive returns.
//
// Windows delivers them through SMART_RCV_DRIVE_DATA with bFeaturesReg set to
// READ_ATTRIBUTES (0xD0) or READ_THRESHOLDS (0xD1); Linux delivers the identical
// bytes through SG_IO with an ATA PASS-THROUGH (16) CDB. One parser serves both,
// which is why this file knows about neither.
//
// Layout of both structures (ATA-8 ACS, SMART data structures):
//
//   offset 0..2     data structure revision number, vendor specific
//   offset 2..362   30 entries of 12 bytes
//   offset 362..511 trailer: offline collection status, self test status,
//                   polling times, capabilities, vendor area
//   offset 511      checksum: the 512 bytes sum to zero, modulo 256
//
// An attribute entry (READ_ATTRIBUTES):
//   +0     attribute id, 0 means the slot is unused
//   +1..3  status flags, u16 little endian
//   +3     current normalised value, higher is healthier
//   +4     worst normalised value ever recorded
//   +5..11 raw value, 48 bits little endian, meaning is vendor specific
//   +11    reserved / vendor specific
//
// A threshold entry (READ_THRESHOLDS):
//   +0     attribute id, 0 means the slot is unused
//   +1     threshold: the attribute has failed when current <= threshold
//   +2..12 reserved
//
// A threshold of 0 means the attribute can never fail, per the spec. Treating 0
// as a real threshold would fail every drive whose normalised value reads 0.

use std::collections::HashMap;

use super::{DiskParseError, BUF_LEN};

// Attribute ids this fleet cares about. The comment is the name smartmontools
// prints, kept so a reader can match these against a real drive's output.
pub const ATTR_RAW_READ_ERROR_RATE: u8 = 1; // 0x01
pub const ATTR_REALLOCATED_SECTORS: u8 = 5; // 0x05 Reallocated_Sector_Ct
pub const ATTR_POWER_ON_HOURS: u8 = 9; // 0x09 Power_On_Hours
pub const ATTR_POWER_CYCLES: u8 = 12; // 0x0C Power_Cycle_Count
pub const ATTR_UNUSED_RESERVED_BLOCKS: u8 = 169; // 0xA9 SSD life family
pub const ATTR_WEAR_LEVELING_COUNT: u8 = 173; // 0xAD SSD life family
pub const ATTR_REPORTED_UNCORRECTABLE: u8 = 187; // 0xBB Reported_Uncorrect
pub const ATTR_AIRFLOW_TEMPERATURE: u8 = 190; // 0xBE Airflow_Temperature_Cel
pub const ATTR_TEMPERATURE: u8 = 194; // 0xC2 Temperature_Celsius
pub const ATTR_REALLOCATED_EVENTS: u8 = 196; // 0xC4 Reallocated_Event_Count
pub const ATTR_PENDING_SECTORS: u8 = 197; // 0xC5 Current_Pending_Sector
pub const ATTR_OFFLINE_UNCORRECTABLE: u8 = 198; // 0xC6 Offline_Uncorrectable
pub const ATTR_UDMA_CRC_ERRORS: u8 = 199; // 0xC7 UDMA_CRC_Error_Count
pub const ATTR_SSD_LIFE_LEFT: u8 = 231; // 0xE7 SSD_Life_Left

/// The cylinder register pair a drive returns for SMART RETURN STATUS (0xDA)
/// when no threshold has been exceeded: 0x4F low, 0xC2 high. These are the same
/// values the Windows headers name SMART_CYL_LOW and SMART_CYL_HI.
pub const SMART_STATUS_OK: (u8, u8) = (0x4F, 0xC2);

/// The cylinder register pair for "a threshold has been exceeded", per ATA-8:
/// 0xF4 low, 0x2C high. Not present in the Windows headers; it comes from the
/// ATA command set, which is why it is written out here rather than imported.
pub const SMART_STATUS_FAILING: (u8, u8) = (0xF4, 0x2C);

const ENTRY_COUNT: usize = 30;
const ENTRY_SIZE: usize = 12;
const TABLE_OFFSET: usize = 2;

/// One SMART attribute, exactly as the drive reported it. Nothing is normalised
/// or reinterpreted here: `raw` stays six bytes because what those bytes mean
/// depends on the attribute and on the vendor.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AtaAttr {
    pub id: u8,
    pub flags: u16,
    pub current: u8,
    pub worst: u8,
    pub raw: [u8; 6],
}

impl AtaAttr {
    /// The raw field as one 48 bit little endian integer. This is the only
    /// reading that is always correct, because the width of the meaningful part
    /// is vendor specific but the byte order never is.
    pub fn raw48(&self) -> u64 {
        let r = &self.raw;
        u64::from(r[0])
            | u64::from(r[1]) << 8
            | u64::from(r[2]) << 16
            | u64::from(r[3]) << 24
            | u64::from(r[4]) << 32
            | u64::from(r[5]) << 40
    }

    /// Bit 0 of the flags: a pre-failure attribute, meaning the drive claims a
    /// value at or below the threshold is an imminent failure rather than a
    /// worn out consumable.
    pub fn prefail(&self) -> bool {
        self.flags & 0x0001 != 0
    }

    /// Bit 1 of the flags: the attribute is updated during normal operation
    /// rather than only during an offline self test.
    pub fn online(&self) -> bool {
        self.flags & 0x0002 != 0
    }

    /// Current temperature in degrees Celsius, for a temperature attribute
    /// (id 194 or 190). Returns None for any other attribute and for a raw
    /// value outside a plausible range.
    ///
    /// The raw field is 48 bits, but vendors do not agree on how much of it the
    /// temperature occupies:
    ///
    ///   * byte 0 only, bytes 1..6 zero            - most common
    ///   * three 16 bit words: current, min, max   - Western Digital, HGST
    ///   * three 16 bit words: current, max, min   - some Seagate
    ///   * three bytes: current, min, max          - some Samsung and Toshiba
    ///
    /// Byte 0 is the current reading in every one of those layouts, because a
    /// Celsius temperature never exceeds 255 and so never needs a second byte.
    /// What differs is what the remaining bytes mean, which is exactly why this
    /// refuses to widen the read: on a drive that packs the lifetime minimum
    /// into byte 1, reading the field as a u16 turns 34 C into 7202 C.
    ///
    /// The plausible range is 1..=150. A drive reporting 0 is reporting "no
    /// sensor", and anything above 150 is a raw field that does not hold a
    /// temperature at all. Both yield None, so a nonsense reading is absent
    /// rather than wrong.
    pub fn temp_c(&self) -> Option<i32> {
        if self.id != ATTR_TEMPERATURE && self.id != ATTR_AIRFLOW_TEMPERATURE {
            return None;
        }
        let t = i32::from(self.raw[0]);
        if (1..=150).contains(&t) {
            Some(t)
        } else {
            None
        }
    }
}

/// Parse a 512 byte SMART READ_ATTRIBUTES buffer into the attributes the drive
/// actually populated. Slots with an id of 0 are unused and are skipped.
///
/// A buffer with no populated slot is `Empty`, not an empty Vec: a drive that
/// answered with thirty blank rows told us nothing, and the difference between
/// nothing and nothing-is-wrong is the whole point of this module.
pub fn parse_ata_attributes(buf: &[u8]) -> Result<Vec<AtaAttr>, DiskParseError> {
    if buf.len() < BUF_LEN {
        return Err(DiskParseError::TooShort {
            got: buf.len(),
            need: BUF_LEN,
        });
    }
    let mut out = Vec::new();
    for i in 0..ENTRY_COUNT {
        let o = TABLE_OFFSET + i * ENTRY_SIZE;
        let id = buf[o];
        if id == 0 {
            continue;
        }
        let mut raw = [0u8; 6];
        raw.copy_from_slice(&buf[o + 5..o + 11]);
        out.push(AtaAttr {
            id,
            flags: u16::from_le_bytes([buf[o + 1], buf[o + 2]]),
            current: buf[o + 3],
            worst: buf[o + 4],
            raw,
        });
    }
    if out.is_empty() {
        return Err(DiskParseError::Empty);
    }
    Ok(out)
}

/// Parse a 512 byte SMART READ_THRESHOLDS buffer into id -> threshold.
///
/// Entries with a threshold of 0 are kept: 0 is a meaningful answer, "this
/// attribute cannot fail", and dropping it would make an attribute that
/// declares itself unfailable indistinguishable from one the drive never
/// reported. The verdict layer is what knows to skip them.
pub fn parse_ata_thresholds(buf: &[u8]) -> Result<HashMap<u8, u8>, DiskParseError> {
    if buf.len() < BUF_LEN {
        return Err(DiskParseError::TooShort {
            got: buf.len(),
            need: BUF_LEN,
        });
    }
    let mut out = HashMap::new();
    for i in 0..ENTRY_COUNT {
        let o = TABLE_OFFSET + i * ENTRY_SIZE;
        let id = buf[o];
        if id == 0 {
            continue;
        }
        out.insert(id, buf[o + 1]);
    }
    if out.is_empty() {
        return Err(DiskParseError::Empty);
    }
    Ok(out)
}

/// Whether byte 511 checksums the buffer: the 512 bytes must sum to zero
/// modulo 256.
///
/// Advisory, not a parse failure. Real drives ship firmware that gets this
/// wrong and smartmontools only warns, so refusing to parse would report
/// working disks as unreadable. It is still worth recording, because a
/// mismatch is the signature of a buffer read at the wrong offset, which is the
/// classic first-build mistake on the Windows path: SENDCMDOUTPARAMS ends in a
/// one byte bBuffer, so the data starts at size_of::<SENDCMDOUTPARAMS>() - 1,
/// not at size_of.
pub fn checksum_ok(buf: &[u8]) -> bool {
    buf.len() >= BUF_LEN && buf[..BUF_LEN].iter().fold(0u8, |a, &b| a.wrapping_add(b)) == 0
}

/// Decode the cylinder registers a SMART RETURN STATUS (0xDA) command left
/// behind. None means the pair matched neither defined answer, so the drive
/// told us nothing and the caller must not invent a verdict from it.
pub fn smart_status_failing(cyl_low: u8, cyl_high: u8) -> Option<bool> {
    match (cyl_low, cyl_high) {
        SMART_STATUS_OK => Some(false),
        SMART_STATUS_FAILING => Some(true),
        _ => None,
    }
}

/// The counters worth lifting out of the attribute table.
///
/// Most are `disk_sample` columns. Two are not: `reallocated_events` and
/// `reported_uncorrectable` have no column in the schema, and are here because
/// the verdict reasons over them and the vendor blob on `disk_event` is where
/// they are kept.
///
/// Every field is an Option and absence is never zero: a drive that does not
/// report reallocated sectors has not reported zero reallocated sectors, and
/// storing 0 there would let a missing attribute render as a clean one.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct AtaSummary {
    pub temp_c: Option<i32>,
    pub power_on_hours: Option<u64>,
    pub power_cycles: Option<u64>,
    pub reallocated: Option<u64>,
    pub reallocated_events: Option<u64>,
    pub pending: Option<u64>,
    pub uncorrectable: Option<u64>,
    pub reported_uncorrectable: Option<u64>,
    pub crc_errors: Option<u64>,
    /// Percent of rated write endurance consumed, from SSD_Life_Left (0xE7)
    /// whose normalised current value is the percent remaining. That is a
    /// vendor convention rather than a spec, so it is read from 0xE7 only. The
    /// raw fields of the other two SSD life attributes (0xAD wear levelling
    /// count, 0xA9 unused reserved blocks) are left to the caller, because
    /// their units differ between vendors and guessing them would produce a
    /// number that looks authoritative and is not.
    pub life_used_pct: Option<u8>,
}

/// Lift the counters above out of a parsed attribute table.
///
/// Power-on hours is the LOW 24 BITS of the raw value. Measured on
/// 2026-09-05 against a Seagate ST1000VX008 (`fixtures/ata_attrs_st1000vx008.bin`):
/// the drive reports `6a b8 00 00 4e 41`, and the upper two bytes moved from
/// `0x414e` to `0x417a` between two reads seconds apart, so they are a second,
/// faster counter packed beside the hours and the full 48 bit read is 71
/// trillion. No drive has run for 2^24 hours (1,914 years), so anything above
/// the low 24 bits cannot be hours and is dropped. A vendor that counts minutes
/// rather than hours is still reported sixty times high; that habit leaves no
/// mark in the structure to detect it by.
pub fn summarize(attrs: &[AtaAttr]) -> AtaSummary {
    let find = |id: u8| attrs.iter().find(|a| a.id == id);
    let raw = |id: u8| find(id).map(|a| a.raw48());
    AtaSummary {
        temp_c: find(ATTR_TEMPERATURE)
            .and_then(|a| a.temp_c())
            .or_else(|| find(ATTR_AIRFLOW_TEMPERATURE).and_then(|a| a.temp_c())),
        power_on_hours: raw(ATTR_POWER_ON_HOURS).map(|hours| hours & 0x00FF_FFFF),
        power_cycles: raw(ATTR_POWER_CYCLES),
        reallocated: raw(ATTR_REALLOCATED_SECTORS),
        reallocated_events: raw(ATTR_REALLOCATED_EVENTS),
        pending: raw(ATTR_PENDING_SECTORS),
        uncorrectable: raw(ATTR_OFFLINE_UNCORRECTABLE),
        reported_uncorrectable: raw(ATTR_REPORTED_UNCORRECTABLE),
        crc_errors: raw(ATTR_UDMA_CRC_ERRORS),
        life_used_pct: find(ATTR_SSD_LIFE_LEFT).map(|a| 100u8.saturating_sub(a.current)),
    }
}

/// How the committed fixtures under `fixtures/` are built. Every value the
/// builders set is documented in `fixtures/README.md`; nothing here was pasted
/// from a hex dump we could not account for.
#[cfg(test)]
pub(crate) mod fixture {
    /// One attribute row, in the terms a drive reports it.
    pub struct Row {
        pub id: u8,
        pub flags: u16,
        pub current: u8,
        pub worst: u8,
        pub raw: u64,
    }

    /// Write byte 511 so the 512 bytes sum to zero modulo 256.
    fn seal(b: &mut [u8; 512]) {
        let sum = b[..511].iter().fold(0u8, |a, &x| a.wrapping_add(x));
        b[511] = (!sum).wrapping_add(1);
    }

    /// Build a READ_ATTRIBUTES buffer: revision, rows, then the trailer fields
    /// a real drive fills in after the attribute table.
    pub fn attr_table(rev: u16, rows: &[Row]) -> [u8; 512] {
        let mut b = [0u8; 512];
        b[0..2].copy_from_slice(&rev.to_le_bytes());
        for (i, r) in rows.iter().enumerate() {
            let o = 2 + i * 12;
            b[o] = r.id;
            b[o + 1..o + 3].copy_from_slice(&r.flags.to_le_bytes());
            b[o + 3] = r.current;
            b[o + 4] = r.worst;
            b[o + 5..o + 11].copy_from_slice(&r.raw.to_le_bytes()[..6]);
        }
        b[362] = 0x00; // offline data collection: never started
        b[363] = 0x00; // self test execution status: no error, none running
        b[364..366].copy_from_slice(&675u16.to_le_bytes()); // offline collection seconds
        b[367] = 0x5B; // offline data collection capability
        b[368..370].copy_from_slice(&0x0003u16.to_le_bytes()); // SMART capability
        b[370] = 0x01; // error logging capability: supported
        b[372] = 1; // short self test, minutes
        b[373] = 0xFF; // extended self test does not fit a byte, see 375..377
        b[374] = 2; // conveyance self test, minutes
        b[375..377].copy_from_slice(&465u16.to_le_bytes()); // extended self test, minutes
        seal(&mut b);
        b
    }

    /// Build a READ_THRESHOLDS buffer. Entry layout is id, threshold, then ten
    /// reserved bytes.
    pub fn threshold_table(rev: u16, rows: &[(u8, u8)]) -> [u8; 512] {
        let mut b = [0u8; 512];
        b[0..2].copy_from_slice(&rev.to_le_bytes());
        for (i, (id, thr)) in rows.iter().enumerate() {
            let o = 2 + i * 12;
            b[o] = *id;
            b[o + 1] = *thr;
        }
        seal(&mut b);
        b
    }

    /// A healthy 4 TB SATA hard disk: no reallocations, no pending sectors,
    /// 34 C, roughly a year of power-on time.
    pub fn healthy() -> [u8; 512] {
        attr_table(
            0x0010,
            &[
                Row { id: 1, flags: 0x000F, current: 118, worst: 99, raw: 176_512_004 },
                Row { id: 5, flags: 0x0033, current: 100, worst: 100, raw: 0 },
                Row { id: 9, flags: 0x0032, current: 89, worst: 89, raw: 9_874 },
                Row { id: 12, flags: 0x0032, current: 100, worst: 100, raw: 412 },
                Row { id: 187, flags: 0x0032, current: 100, worst: 100, raw: 0 },
                // Airflow temperature, byte 0 encoding: 34 C and nothing else.
                Row { id: 190, flags: 0x0022, current: 66, worst: 51, raw: 34 },
                Row { id: 196, flags: 0x0032, current: 100, worst: 100, raw: 0 },
                Row { id: 197, flags: 0x0012, current: 100, worst: 100, raw: 0 },
                Row { id: 198, flags: 0x0010, current: 100, worst: 100, raw: 0 },
                Row { id: 199, flags: 0x003E, current: 200, worst: 200, raw: 0 },
                // Temperature, three word encoding: current 34, min 28, max 49.
                Row { id: 194, flags: 0x0022, current: 34, worst: 49, raw: 0x0031_001C_0022 },
            ],
        )
    }

    /// The same drive after the head crash: 1296 reallocated sectors with the
    /// normalised value driven under its threshold of 36, plus pending and
    /// offline-uncorrectable sectors and a raised reallocation event count.
    pub fn failing() -> [u8; 512] {
        attr_table(
            0x0010,
            &[
                Row { id: 1, flags: 0x000F, current: 71, worst: 63, raw: 12_884_901_888 },
                Row { id: 5, flags: 0x0033, current: 8, worst: 8, raw: 1_296 },
                Row { id: 9, flags: 0x0032, current: 52, worst: 52, raw: 41_233 },
                Row { id: 12, flags: 0x0032, current: 100, worst: 100, raw: 1_207 },
                Row { id: 187, flags: 0x0032, current: 100, worst: 100, raw: 96 },
                Row { id: 190, flags: 0x0022, current: 59, worst: 44, raw: 41 },
                Row { id: 196, flags: 0x0032, current: 100, worst: 100, raw: 37 },
                Row { id: 197, flags: 0x0012, current: 100, worst: 100, raw: 24 },
                Row { id: 198, flags: 0x0010, current: 100, worst: 100, raw: 24 },
                Row { id: 199, flags: 0x003E, current: 200, worst: 200, raw: 3 },
                Row { id: 194, flags: 0x0022, current: 41, worst: 51, raw: 41 },
            ],
        )
    }

    /// Thresholds for the two tables above. 5 fails at 36, which is what makes
    /// the failing fixture a failure rather than a warning.
    pub fn thresholds() -> [u8; 512] {
        threshold_table(
            0x0010,
            &[
                (1, 44),
                (5, 36),
                (9, 0),
                (12, 20),
                (187, 0),
                (190, 45),
                (196, 0),
                (197, 0),
                (198, 0),
                (199, 0),
                (194, 0),
            ],
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HEALTHY: &[u8] = include_bytes!("fixtures/ata_attrs_healthy.bin");
    const FAILING: &[u8] = include_bytes!("fixtures/ata_attrs_failing.bin");
    const THRESHOLDS: &[u8] = include_bytes!("fixtures/ata_thresholds.bin");
    const SHORT: &[u8] = include_bytes!("fixtures/malformed_short.bin");
    const ZEROS: &[u8] = include_bytes!("fixtures/malformed_zeros.bin");

    /// The committed bytes are what the documented builders produce. If this
    /// fails, either a fixture was edited by hand or a builder changed without
    /// the fixture being regenerated.
    #[test]
    fn fixtures_match_builders() {
        assert_eq!(HEALTHY, &fixture::healthy()[..]);
        assert_eq!(FAILING, &fixture::failing()[..]);
        assert_eq!(THRESHOLDS, &fixture::thresholds()[..]);
    }

    #[test]
    fn parses_every_populated_slot_and_no_others() {
        let attrs = parse_ata_attributes(HEALTHY).unwrap();
        let ids: Vec<u8> = attrs.iter().map(|a| a.id).collect();
        assert_eq!(ids, vec![1, 5, 9, 12, 187, 190, 196, 197, 198, 199, 194]);
    }

    #[test]
    fn reads_the_documented_fields_of_one_attribute() {
        let attrs = parse_ata_attributes(HEALTHY).unwrap();
        let poh = attrs.iter().find(|a| a.id == ATTR_POWER_ON_HOURS).unwrap();
        assert_eq!(poh.flags, 0x0032);
        assert_eq!(poh.current, 89);
        assert_eq!(poh.worst, 89);
        assert_eq!(poh.raw48(), 9_874);
        assert!(poh.online());
        assert!(!poh.prefail());
        let realloc = attrs.iter().find(|a| a.id == ATTR_REALLOCATED_SECTORS).unwrap();
        assert!(realloc.prefail(), "attribute 5 is a pre-failure attribute");
    }

    /// `current` is the live normalised value and `worst` is the lifetime low.
    /// Only `current` decides whether an attribute has failed, so reading the
    /// two bytes in the wrong order ships a parser that judges every drive on
    /// the worst it has ever been. Attribute 1 is the one whose two values
    /// differ in both fixtures, which is what makes this bite.
    #[test]
    fn current_and_worst_are_not_the_same_byte() {
        let healthy = parse_ata_attributes(HEALTHY).unwrap();
        let rate = healthy.iter().find(|a| a.id == ATTR_RAW_READ_ERROR_RATE).unwrap();
        assert_eq!((rate.current, rate.worst), (118, 99));
        let temp = healthy.iter().find(|a| a.id == ATTR_TEMPERATURE).unwrap();
        assert_eq!((temp.current, temp.worst), (34, 49));

        let failing = parse_ata_attributes(FAILING).unwrap();
        let rate = failing.iter().find(|a| a.id == ATTR_RAW_READ_ERROR_RATE).unwrap();
        assert_eq!((rate.current, rate.worst), (71, 63));
    }

    /// The raw field is 48 bits little endian: byte 5 is the most significant,
    /// and the twelfth byte of the entry is not part of it.
    #[test]
    fn raw_is_48_bits_little_endian() {
        let a = AtaAttr {
            id: 5,
            flags: 0,
            current: 100,
            worst: 100,
            raw: [0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
        };
        assert_eq!(a.raw48(), 0x0605_0403_0201);
        let max = AtaAttr { raw: [0xFF; 6], ..a };
        assert_eq!(max.raw48(), 0x0000_FFFF_FFFF_FFFF);
    }

    /// Temperature is byte 0 whatever the vendor packed into the rest. Reading
    /// the field as a u16 is the bug this guards.
    #[test]
    fn temperature_is_byte_zero_across_vendor_encodings() {
        let t = |raw: [u8; 6]| AtaAttr { id: 194, flags: 0, current: 34, worst: 49, raw }.temp_c();
        // byte 0 only
        assert_eq!(t([34, 0, 0, 0, 0, 0]), Some(34));
        // three 16 bit words: current 34, min 28, max 49
        assert_eq!(t([34, 0, 28, 0, 49, 0]), Some(34));
        // three bytes: current 34, min 28, max 49. A u16 read here gives 7202.
        assert_eq!(t([34, 28, 49, 0, 0, 0]), Some(34));
        assert_eq!(u16::from_le_bytes([34, 28]), 7202, "the reading we must not do");
    }

    #[test]
    fn implausible_temperature_is_absent_not_wrong() {
        let t = |raw: [u8; 6]| AtaAttr { id: 194, flags: 0, current: 0, worst: 0, raw }.temp_c();
        assert_eq!(t([0, 0, 0, 0, 0, 0]), None, "no sensor is not zero degrees");
        assert_eq!(t([200, 0, 0, 0, 0, 0]), None, "200 C is not a disk temperature");
        // A non temperature attribute never answers, whatever its raw holds.
        let realloc = AtaAttr { id: 5, flags: 0, current: 100, worst: 100, raw: [34, 0, 0, 0, 0, 0] };
        assert_eq!(realloc.temp_c(), None);
    }

    /// The failing fixture's attribute 1 raw needs more than 32 bits on purpose:
    /// a parser that read the field as a u32 would silently lose the top bytes.
    #[test]
    fn a_raw_wider_than_32_bits_survives() {
        let attrs = parse_ata_attributes(FAILING).unwrap();
        let rate = attrs.iter().find(|a| a.id == ATTR_RAW_READ_ERROR_RATE).unwrap();
        assert_eq!(rate.raw48(), 12_884_901_888);
    }

    /// The one table here that came off a drive: SMART READ_ATTRIBUTES from a
    /// Seagate ST1000VX008-2AY1 on homebox-devserver, 2026-09-05, read over
    /// `SG_IO` by `linux::ata_smart_table`. Provenance in `fixtures/README.md`.
    #[test]
    fn reads_a_real_seagate_table() {
        const REAL: &[u8] = include_bytes!("fixtures/ata_attrs_st1000vx008.bin");
        assert!(checksum_ok(REAL), "the drive's own checksum");
        let attrs = parse_ata_attributes(REAL).unwrap();
        assert_eq!(attrs.len(), 25);
        let poh = attrs.iter().find(|a| a.id == ATTR_POWER_ON_HOURS).unwrap();
        // 0x414e0000b86a as read: a second counter in the upper bytes beside
        // 47,210 hours in the low 24 bits. The 48 bit value is not hours.
        assert_eq!(poh.raw, [0x6a, 0xb8, 0x00, 0x00, 0x4e, 0x41]);
        assert_eq!(poh.raw48(), 0x414e_0000_b86a);
        let s = summarize(&attrs);
        assert_eq!(s.power_on_hours, Some(47_210));
        assert_eq!(s.power_cycles, Some(65));
        assert_eq!(s.reallocated, Some(0));
        assert_eq!(s.pending, Some(0));
        assert_eq!(s.uncorrectable, Some(0));
        assert_eq!(s.crc_errors, Some(0));
        assert_eq!(s.temp_c, Some(28));
        assert_eq!(s.life_used_pct, None);
    }

    #[test]
    fn summary_lifts_the_stored_counters() {
        let s = summarize(&parse_ata_attributes(HEALTHY).unwrap());
        assert_eq!(s.temp_c, Some(34));
        assert_eq!(s.power_on_hours, Some(9_874));
        assert_eq!(s.power_cycles, Some(412));
        assert_eq!(s.reallocated, Some(0));
        assert_eq!(s.pending, Some(0));
        assert_eq!(s.uncorrectable, Some(0));
        assert_eq!(s.crc_errors, Some(0));
        // This drive reports no SSD life attribute, which is not 0 percent used.
        assert_eq!(s.life_used_pct, None);

        let f = summarize(&parse_ata_attributes(FAILING).unwrap());
        assert_eq!(f.reallocated, Some(1_296));
        assert_eq!(f.reallocated_events, Some(37));
        assert_eq!(f.pending, Some(24));
        assert_eq!(f.uncorrectable, Some(24));
        assert_eq!(f.reported_uncorrectable, Some(96));
        assert_eq!(f.temp_c, Some(41));
    }

    #[test]
    fn ssd_life_left_is_percent_remaining() {
        let attrs = vec![AtaAttr {
            id: ATTR_SSD_LIFE_LEFT,
            flags: 0x0013,
            current: 91,
            worst: 91,
            raw: [0; 6],
        }];
        assert_eq!(summarize(&attrs).life_used_pct, Some(9));
    }

    #[test]
    fn thresholds_parse_including_the_unfailable_zero() {
        let t = parse_ata_thresholds(THRESHOLDS).unwrap();
        assert_eq!(t.get(&ATTR_REALLOCATED_SECTORS), Some(&36));
        assert_eq!(t.get(&ATTR_PENDING_SECTORS), Some(&0));
        assert_eq!(t.get(&ATTR_TEMPERATURE), Some(&0));
        assert_eq!(t.get(&0xE7), None);
    }

    #[test]
    fn checksum_is_advisory_but_correct() {
        assert!(checksum_ok(HEALTHY));
        assert!(checksum_ok(THRESHOLDS));
        let mut bent = fixture::healthy();
        bent[100] = bent[100].wrapping_add(1);
        assert!(!checksum_ok(&bent));
        assert!(
            parse_ata_attributes(&bent).is_ok(),
            "a bad checksum warns, it does not stop the parse"
        );
        assert!(!checksum_ok(SHORT));
    }

    #[test]
    fn smart_return_status_registers() {
        assert_eq!(smart_status_failing(0x4F, 0xC2), Some(false));
        assert_eq!(smart_status_failing(0xF4, 0x2C), Some(true));
        assert_eq!(smart_status_failing(0x00, 0x00), None, "an unset pair says nothing");
    }

    #[test]
    fn short_buffer_is_an_error_not_a_panic() {
        assert_eq!(
            parse_ata_attributes(SHORT),
            Err(DiskParseError::TooShort { got: SHORT.len(), need: 512 })
        );
        assert_eq!(
            parse_ata_thresholds(SHORT),
            Err(DiskParseError::TooShort { got: SHORT.len(), need: 512 })
        );
        assert_eq!(parse_ata_attributes(&[]), Err(DiskParseError::TooShort { got: 0, need: 512 }));
    }

    #[test]
    fn untouched_buffer_is_empty_not_healthy() {
        assert_eq!(parse_ata_attributes(ZEROS), Err(DiskParseError::Empty));
        assert_eq!(parse_ata_thresholds(ZEROS), Err(DiskParseError::Empty));
    }

    /// Nothing in this parser may panic, whatever bytes arrive.
    #[test]
    fn arbitrary_bytes_never_panic() {
        let mut b = [0u8; 512];
        for (i, x) in b.iter_mut().enumerate() {
            // A cheap deterministic spread, no rand dependency.
            *x = ((i as u32).wrapping_mul(2_654_435_761) >> 13) as u8;
        }
        let _ = parse_ata_attributes(&b);
        let _ = parse_ata_thresholds(&b);
        let _ = checksum_ok(&b);
        for len in 0..=512 {
            let _ = parse_ata_attributes(&b[..len]);
            let _ = parse_ata_thresholds(&b[..len]);
        }
    }
}
