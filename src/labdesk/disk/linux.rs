// Linux: getting the bytes the parsers in `ata` and `nvme` read.
//
// Same division as `windows.rs`: nothing here interprets a reading. The
// privileged calls hand back the same 512-byte buffers the Windows path
// produces, byte for byte, so one parser serves both operating systems.
//
// Privilege, stated rather than assumed:
//
//   * The free tier, `/sys/block` and `/sys/class/nvme`, is world readable.
//     It carries identity, capacity, rotational and sometimes an NVMe
//     temperature. It carries no failure evidence at all, which is why
//     [`super::verdict::Source::Sysfs`] on its own can only ever produce
//     `Unreadable`.
//   * `NVME_IOCTL_ADMIN_CMD` needs CAP_SYS_ADMIN.
//   * `SG_IO` with an ATA PASS-THROUGH(16) command needs CAP_SYS_RAWIO.
//
// The daemon has both because `res/rustdesk.service` runs it as `User=root`.
// In `--server`, running as the logged-in user, both privileged calls fail on
// every machine and the collector is left with the free tier.
//
// USB bridges and hardware RAID controllers usually refuse pass-through
// outright. That is `Verdict::Unreadable` with `health_source` of `none`, never
// `ok`: an enclosure that would not answer is not a healthy disk.

use super::BUF_LEN;
use hbb_common::{bail, libc, ResultType};
use std::fs;
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};

/// `_IOWR('N', 0x41, struct nvme_passthru_cmd)`, the NVMe admin passthrough.
///
/// Computed rather than written down, so the size field cannot drift away from
/// the struct actually sent. `tests::ioctl_numbers` pins the result against the
/// documented `0xC0484E41`.
pub const NVME_IOCTL_ADMIN_CMD: u32 = iowr(b'N', 0x41, std::mem::size_of::<NvmePassthruCmd>());

/// `SG_IO`, from `<scsi/sg.h>`. Not an `_IOWR`: the SCSI generic interface
/// numbered its ioctls by hand.
pub const SG_IO: u32 = 0x2285;

/// NVMe admin opcode 02h, Get Log Page.
const NVME_ADMIN_GET_LOG_PAGE: u8 = 0x02;
/// Log page identifier 02h, SMART / Health Information.
const NVME_LOG_HEALTH_INFO: u8 = 0x02;
/// The whole controller rather than one namespace: health is a controller
/// property, and a namespace-scoped request returns per-namespace counters that
/// most drives do not implement.
const NVME_NSID_ALL: u32 = 0xFFFF_FFFF;

/// ATA PASS-THROUGH(16), from SAT.
const ATA_PASSTHROUGH_16: u8 = 0x85;
/// The ATA SMART command.
const ATA_CMD_SMART: u8 = 0xB0;
/// SMART READ DATA, the 512-byte attribute table.
pub const ATA_SMART_READ_ATTRIBUTES: u8 = 0xD0;
/// SMART READ THRESHOLDS, the 512-byte threshold table.
pub const ATA_SMART_READ_THRESHOLDS: u8 = 0xD1;

/// `SG_DXFER_FROM_DEV`. Negative, and that is not a typo: the SCSI generic
/// header numbers its directions from -1 downwards.
const SG_DXFER_FROM_DEV: i32 = -3;
/// `'S'`, the only value `sg_io_hdr::interface_id` accepts.
const SG_INTERFACE_ID_ORIG: i32 = b'S' as i32;
/// Milliseconds. A SMART read is a register transfer, not a media access; a
/// drive that has not answered in ten seconds is not going to.
const SG_TIMEOUT_MS: u32 = 10_000;
/// Sense buffer length. The reply is discarded here because nothing in this
/// module decodes sense data, but the kernel requires somewhere to put it.
const SG_SENSE_LEN: usize = 32;

/// A block device as `/sys/block` describes it. Identity and capacity only:
/// nothing in here is health.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SysfsDisk {
    /// The kernel name, for example `sda` or `nvme0n1`.
    pub name: String,
    /// `/dev/<name>`, the node the privileged calls open.
    pub dev_path: String,
    pub rotational: Option<bool>,
    pub size_bytes: Option<u64>,
    pub model: Option<String>,
    pub vendor: Option<String>,
    pub serial: Option<String>,
    /// `device/rev` for a SCSI or ATA disk, `firmware_rev` on the controller
    /// for an NVMe namespace. Read on homebox 2026-09-05 as `CV11` and
    /// `P7MU002`, both of which had been arriving at the server as null.
    pub firmware: Option<String>,
}

/// Every block device in `/sys/block` that could carry a health reading.
///
/// Virtual devices are skipped by name: a loop file, a ramdisk, a device-mapper
/// target and an md array have no drive behind them to ask, and enumerating
/// them would put rows in the `disk` table that can never move off
/// `unreadable`.
pub fn list_block_devices() -> Vec<SysfsDisk> {
    let Ok(entries) = fs::read_dir("/sys/block") else {
        return Vec::new();
    };
    let mut disks: Vec<SysfsDisk> = entries
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            is_health_candidate(&name).then(|| read_sysfs_disk(&entry.path(), name))
        })
        .collect();
    disks.sort_by(|a, b| a.name.cmp(&b.name));
    disks
}

fn read_sysfs_disk(dir: &Path, name: String) -> SysfsDisk {
    let read = |rel: &str| fs::read_to_string(dir.join(rel)).ok();
    // An NVMe namespace keeps its identity on the controller, not the block
    // device, so the serial is read from `/sys/class/nvme/<controller>` when
    // the block device does not carry one.
    let nvme_class = nvme_controller(&name).map(|c| PathBuf::from("/sys/class/nvme").join(c));
    let from_class = |rel: &str| {
        nvme_class
            .as_ref()
            .and_then(|dir| fs::read_to_string(dir.join(rel)).ok())
    };
    SysfsDisk {
        dev_path: format!("/dev/{}", name),
        rotational: read("queue/rotational").as_deref().and_then(parse_rotational),
        size_bytes: read("size").as_deref().and_then(parse_size_bytes),
        model: text(read("device/model").or_else(|| from_class("model"))),
        vendor: text(read("device/vendor")),
        serial: text(read("device/serial").or_else(|| from_class("serial"))),
        firmware: text(read("device/rev").or_else(|| from_class("firmware_rev"))),
        name,
    }
}

/// The NVMe composite temperature, in whole degrees Celsius, without any
/// privilege.
///
/// Depends on `CONFIG_NVME_HWMON`, so the directory is probed rather than
/// assumed: a kernel built without it simply has no `hwmon*` and this returns
/// `None`. The hwmon device is registered on the controller itself, so it is
/// `/sys/class/nvme/nvme0/hwmon1` (kernel 7.0 on homebox, 2026-09-05, where
/// `device/hwmon*` does not exist); the `device` directory is still searched
/// second for the kernels that put it there.
pub fn nvme_temp_c(block_name: &str) -> Option<i32> {
    let controller = PathBuf::from("/sys/class/nvme").join(nvme_controller(block_name)?);
    [controller.clone(), controller.join("device")]
        .into_iter()
        .filter_map(|dir| fs::read_dir(dir).ok())
        .flatten()
        .flatten()
        .filter(|entry| entry.file_name().to_string_lossy().starts_with("hwmon"))
        .find_map(|entry| {
            let text = fs::read_to_string(entry.path().join("temp1_input")).ok()?;
            parse_milli_celsius(&text)
        })
}

/// The NVMe SMART / Health Information log page, identifier 02h, exactly as
/// [`super::nvme::parse_nvme_health`] wants it. Needs CAP_SYS_ADMIN.
///
/// `block_name` is a namespace such as `nvme0n1`; the command goes to the
/// controller node `/dev/nvme0`, because the namespace node does not accept the
/// admin passthrough.
pub fn nvme_health_page(block_name: &str) -> ResultType<[u8; BUF_LEN]> {
    let Some(controller) = nvme_controller(block_name) else {
        bail!("{} is not an NVMe namespace", block_name);
    };
    let path = format!("/dev/{}", controller);
    let file = fs::File::open(&path)?;
    let mut page = [0u8; BUF_LEN];
    let mut cmd = NvmePassthruCmd {
        opcode: NVME_ADMIN_GET_LOG_PAGE,
        nsid: NVME_NSID_ALL,
        addr: page.as_mut_ptr() as u64,
        data_len: BUF_LEN as u32,
        cdw10: nvme_get_log_cdw10(NVME_LOG_HEALTH_INFO, BUF_LEN as u32),
        ..Default::default()
    };
    let rc = unsafe {
        libc::ioctl(
            file.as_raw_fd(),
            NVME_IOCTL_ADMIN_CMD as libc::Ioctl,
            &mut cmd as *mut NvmePassthruCmd as *mut libc::c_void,
        )
    };
    if rc != 0 {
        bail!(
            "{}: NVME_IOCTL_ADMIN_CMD returned {} ({})",
            path,
            rc,
            std::io::Error::last_os_error()
        );
    }
    Ok(page)
}

/// A 512-byte ATA SMART table over `SG_IO`, for
/// [`super::ata::parse_ata_attributes`] or
/// [`super::ata::parse_ata_thresholds`]. Needs CAP_SYS_RAWIO.
///
/// `feature` is [`ATA_SMART_READ_ATTRIBUTES`] or
/// [`ATA_SMART_READ_THRESHOLDS`].
pub fn ata_smart_table(dev_path: &str, feature: u8) -> ResultType<[u8; BUF_LEN]> {
    let file = fs::File::open(dev_path)?;
    let mut buf = [0u8; BUF_LEN];
    let mut cdb = ata_passthrough_cdb(feature);
    let mut sense = [0u8; SG_SENSE_LEN];
    let mut hdr = SgIoHdr {
        interface_id: SG_INTERFACE_ID_ORIG,
        dxfer_direction: SG_DXFER_FROM_DEV,
        cmd_len: cdb.len() as u8,
        mx_sb_len: sense.len() as u8,
        dxfer_len: buf.len() as u32,
        dxferp: buf.as_mut_ptr() as *mut libc::c_void,
        cmdp: cdb.as_mut_ptr(),
        sbp: sense.as_mut_ptr(),
        timeout: SG_TIMEOUT_MS,
        ..Default::default()
    };
    let rc = unsafe {
        libc::ioctl(
            file.as_raw_fd(),
            SG_IO as libc::Ioctl,
            &mut hdr as *mut SgIoHdr as *mut libc::c_void,
        )
    };
    if rc != 0 {
        bail!(
            "{}: SG_IO returned {} ({})",
            dev_path,
            rc,
            std::io::Error::last_os_error()
        );
    }
    // The ioctl succeeding only means the kernel delivered the command. A USB
    // bridge that swallowed it answers here, with a nonzero status and a buffer
    // that is still the zeroes it was handed, and that parses cleanly into an
    // empty attribute table.
    if hdr.status != 0 || hdr.host_status != 0 || hdr.driver_status != 0 {
        bail!(
            "{}: ATA pass-through refused, status {} host {} driver {}",
            dev_path,
            hdr.status,
            hdr.host_status,
            hdr.driver_status
        );
    }
    if hdr.resid != 0 {
        bail!(
            "{}: ATA pass-through returned {} bytes short of {}",
            dev_path,
            hdr.resid,
            BUF_LEN
        );
    }
    Ok(buf)
}

/// `struct nvme_passthru_cmd` from `<linux/nvme_ioctl.h>`. 72 bytes on 64-bit,
/// which is the size baked into [`NVME_IOCTL_ADMIN_CMD`].
#[repr(C)]
#[derive(Default)]
pub struct NvmePassthruCmd {
    pub opcode: u8,
    pub flags: u8,
    pub rsvd1: u16,
    pub nsid: u32,
    pub cdw2: u32,
    pub cdw3: u32,
    pub metadata: u64,
    pub addr: u64,
    pub metadata_len: u32,
    pub data_len: u32,
    pub cdw10: u32,
    pub cdw11: u32,
    pub cdw12: u32,
    pub cdw13: u32,
    pub cdw14: u32,
    pub cdw15: u32,
    pub timeout_ms: u32,
    /// Written by the kernel: the command's completion dword 0.
    pub result: u32,
}

/// `sg_io_hdr_t` from `<scsi/sg.h>`. 88 bytes on 64-bit.
///
/// Written out by hand because `libc` does not carry it. `_pad` is the four
/// bytes the C compiler inserts before the next pointer; `repr(C)` would add
/// them anyway, and naming the field keeps the offsets in
/// `tests::sg_header_fields_sit_where_the_kernel_reads_them` readable against
/// the header.
#[repr(C)]
pub struct SgIoHdr {
    pub interface_id: i32,
    pub dxfer_direction: i32,
    pub cmd_len: u8,
    pub mx_sb_len: u8,
    pub iovec_count: u16,
    pub dxfer_len: u32,
    pub dxferp: *mut libc::c_void,
    pub cmdp: *mut u8,
    pub sbp: *mut u8,
    pub timeout: u32,
    pub flags: u32,
    pub pack_id: i32,
    pub _pad: u32,
    pub usr_ptr: *mut libc::c_void,
    pub status: u8,
    pub masked_status: u8,
    pub msg_status: u8,
    pub sb_len_wr: u8,
    pub host_status: u16,
    pub driver_status: u16,
    /// Bytes the device did not transfer. Nonzero means a short read.
    pub resid: i32,
    pub duration: u32,
    pub info: u32,
}

impl Default for SgIoHdr {
    fn default() -> Self {
        // Every field is a scalar or a raw pointer, so an all-zero header is a
        // valid one: it is what a C caller gets from memset.
        unsafe { std::mem::zeroed() }
    }
}

/// `_IOWR(type, nr, size)` as `<asm-generic/ioctl.h>` defines it on every
/// architecture this agent targets: direction in bits 30 and 31, size in 16 to
/// 29, type in 8 to 15, number in 0 to 7. Direction 3 is read and write.
const fn iowr(ty: u8, nr: u8, size: usize) -> u32 {
    (3 << 30) | ((size as u32) << 16) | ((ty as u32) << 8) | nr as u32
}

/// Command dword 10 for Get Log Page: the identifier in the low byte, and the
/// transfer length in bits 16 to 27 as a **zero-based** count of dwords.
///
/// The minus one is the whole point. Without it the controller is asked for one
/// dword more than the buffer holds and answers with an error, or on a lenient
/// drive with four bytes past the end.
fn nvme_get_log_cdw10(log_id: u8, len_bytes: u32) -> u32 {
    let numd = (len_bytes / 4) - 1;
    (numd << 16) | log_id as u32
}

/// The 16-byte ATA PASS-THROUGH(16) command block for a SMART data read.
///
/// Byte 1 is `protocol << 1`, protocol 4 being PIO Data-In. Byte 2 packs
/// `t_length = 2` in bits 1 and 0 (the sector count register holds the length),
/// `byte_block = 1` in bit 2 (that length is in blocks) and `t_dir = 1` in bit 3
/// (from the device), giving 0x0E. The SMART signature 0x4F / 0xC2 goes in the
/// LBA mid and high registers; a drive that gets anything else there refuses
/// the command.
///
/// Bit 5 of that byte is CK_COND, and it is deliberately clear. Setting it
/// makes the SAT layer complete every command with CHECK CONDITION and an ATA
/// Status Return Descriptor, success included, so `hdr.status` comes back 0x02
/// on a perfectly good read and [`ata_smart_table`] would throw away the 512
/// bytes the drive just handed it. Nothing here decodes the returned registers,
/// so there is nothing to ask for.
///
/// The plan writes this byte as 0x2E at
/// `docs/plans/2026-09-04-003-rmm-architecture.md:753`, which sets CK_COND.
/// That is the one place this file diverges from the plan's wire format.
fn ata_passthrough_cdb(feature: u8) -> [u8; 16] {
    [
        ATA_PASSTHROUGH_16,
        4 << 1,  // protocol: PIO Data-In, extend bit clear
        0x0E,    // t_length=2, byte_block=1, t_dir=1 (from device), ck_cond=0
        0,       // features, high byte of the 16-bit register
        feature, // features, low byte
        0,       // sector count, high
        1,       // sector count, low: one 512-byte block
        0,       // LBA low, high
        0,       // LBA low
        0,       // LBA mid, high
        0x4F,    // LBA mid: SMART signature, low
        0,       // LBA high, high
        0xC2,    // LBA high: SMART signature, high
        0,       // device
        ATA_CMD_SMART,
        0, // control
    ]
}

/// The NVMe controller a block device belongs to: `nvme0n1` is namespace 1 on
/// `nvme0`. Returns `None` for anything that is not an NVMe namespace.
fn nvme_controller(block_name: &str) -> Option<String> {
    let rest = block_name.strip_prefix("nvme")?;
    let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
    // `nvme0` on its own is the controller node, not a namespace, and never
    // appears in /sys/block. Requiring something after the digits keeps this
    // honest about what it was handed.
    if digits.is_empty() || digits.len() == rest.len() {
        return None;
    }
    Some(format!("nvme{}", digits))
}

/// `queue/rotational`: 1 for a spinning disk, 0 for solid state.
fn parse_rotational(text: &str) -> Option<bool> {
    match text.trim() {
        "1" => Some(true),
        "0" => Some(false),
        _ => None,
    }
}

/// `/sys/block/<name>/size`, which is always in 512-byte sectors whatever the
/// drive's own logical block size is. Multiplying by the logical block size
/// instead is the classic way to report a 4Kn drive as eight times too large.
fn parse_size_bytes(text: &str) -> Option<u64> {
    text.trim().parse::<u64>().ok()?.checked_mul(512)
}

/// `hwmon` reports temperatures in millidegrees.
fn parse_milli_celsius(text: &str) -> Option<i32> {
    Some(text.trim().parse::<i32>().ok()? / 1000)
}

/// Trim a sysfs string and treat an empty one as absent, because sysfs answers
/// a field the driver did not fill with a bare newline rather than nothing.
fn text(raw: Option<String>) -> Option<String> {
    let value = raw?.trim().to_string();
    (!value.is_empty()).then_some(value)
}

/// Whether a `/sys/block` entry has a drive behind it worth asking.
fn is_health_candidate(name: &str) -> bool {
    const VIRTUAL: [&str; 6] = ["loop", "ram", "zram", "dm-", "md", "sr"];
    !name.is_empty() && !VIRTUAL.iter().any(|prefix| name.starts_with(prefix))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Both numbers are baked into the wire format. `NVME_IOCTL_ADMIN_CMD`
    /// carries the struct size in its own bits, so a field added to
    /// `NvmePassthruCmd` silently changes the ioctl the kernel is asked for and
    /// every NVMe read starts failing with ENOTTY.
    #[test]
    fn layout() {
        assert_eq!(std::mem::size_of::<NvmePassthruCmd>(), 72);
        assert_eq!(std::mem::size_of::<SgIoHdr>(), 88);
    }

    #[test]
    fn ioctl_numbers() {
        assert_eq!(NVME_IOCTL_ADMIN_CMD, 0xC048_4E41);
        assert_eq!(SG_IO, 0x2285);
    }

    fn raw<T>(value: &T) -> &[u8] {
        unsafe {
            std::slice::from_raw_parts(value as *const T as *const u8, std::mem::size_of::<T>())
        }
    }

    /// `size_of` alone does not catch two same-sized fields swapping places,
    /// and every field the kernel reads out of this struct is a `u32`. The
    /// offsets below are the ones in `<linux/nvme_ioctl.h>`; a command whose
    /// `data_len` landed in `metadata_len` would still be 72 bytes and would
    /// still be sent.
    #[test]
    fn nvme_command_fields_sit_where_the_kernel_reads_them() {
        let cmd = NvmePassthruCmd {
            opcode: NVME_ADMIN_GET_LOG_PAGE,
            nsid: NVME_NSID_ALL,
            addr: 0x1122_3344_5566_7788,
            data_len: BUF_LEN as u32,
            cdw10: nvme_get_log_cdw10(NVME_LOG_HEALTH_INFO, BUF_LEN as u32),
            ..Default::default()
        };
        let b = raw(&cmd);
        assert_eq!(b[0], 0x02, "opcode at 0");
        assert_eq!(&b[4..8], &0xFFFF_FFFFu32.to_le_bytes(), "nsid at 4");
        assert_eq!(&b[16..24], &0u64.to_le_bytes(), "metadata at 16, unused");
        assert_eq!(
            &b[24..32],
            &0x1122_3344_5566_7788u64.to_le_bytes(),
            "addr at 24"
        );
        assert_eq!(&b[32..36], &0u32.to_le_bytes(), "metadata_len at 32, unused");
        assert_eq!(&b[36..40], &512u32.to_le_bytes(), "data_len at 36");
        assert_eq!(&b[40..44], &0x007F_0002u32.to_le_bytes(), "cdw10 at 40");
    }

    /// Same reasoning for the SCSI generic header, and one field in particular:
    /// `resid` and `duration` are neighbouring `u32`s, so swapping them keeps
    /// the struct 88 bytes and turns "the drive returned a short read" into a
    /// millisecond count that is almost always zero.
    #[test]
    fn sg_header_fields_sit_where_the_kernel_reads_them() {
        let mut cdb = ata_passthrough_cdb(ATA_SMART_READ_ATTRIBUTES);
        let mut buf = [0u8; BUF_LEN];
        let mut sense = [0u8; SG_SENSE_LEN];
        let hdr = SgIoHdr {
            interface_id: SG_INTERFACE_ID_ORIG,
            dxfer_direction: SG_DXFER_FROM_DEV,
            cmd_len: cdb.len() as u8,
            mx_sb_len: sense.len() as u8,
            dxfer_len: buf.len() as u32,
            dxferp: buf.as_mut_ptr() as *mut libc::c_void,
            cmdp: cdb.as_mut_ptr(),
            sbp: sense.as_mut_ptr(),
            timeout: SG_TIMEOUT_MS,
            resid: -7,
            duration: 0,
            ..Default::default()
        };
        let b = raw(&hdr);
        assert_eq!(&b[0..4], &(b'S' as i32).to_le_bytes(), "interface_id at 0");
        assert_eq!(&b[4..8], &(-3i32).to_le_bytes(), "dxfer_direction at 4");
        assert_eq!(b[8], 16, "cmd_len at 8");
        assert_eq!(b[9], 32, "mx_sb_len at 9");
        assert_eq!(&b[12..16], &512u32.to_le_bytes(), "dxfer_len at 12");
        assert_eq!(
            &b[16..24],
            &(buf.as_mut_ptr() as usize as u64).to_le_bytes(),
            "dxferp at 16"
        );
        assert_eq!(
            &b[24..32],
            &(cdb.as_mut_ptr() as usize as u64).to_le_bytes(),
            "cmdp at 24"
        );
        assert_eq!(&b[40..44], &10_000u32.to_le_bytes(), "timeout at 40");
        assert_eq!(
            &b[72..76],
            &(-7i32).to_le_bytes(),
            "resid at 72, not duration's 76"
        );
        assert_eq!(&b[76..80], &0u32.to_le_bytes(), "duration at 76");
    }

    /// The zero-based dword count. Dropping the minus one produces
    /// 0x0080_0002, which is a well-formed request for the wrong length.
    #[test]
    fn get_log_page_length_is_zero_based() {
        assert_eq!(nvme_get_log_cdw10(0x02, 512), 0x007F_0002);
        assert_eq!(nvme_get_log_cdw10(0x01, 64), 0x000F_0001);
    }

    /// Byte for byte. Every one of these positions is a different ATA register,
    /// and a value in the wrong slot is a valid request for something else that
    /// the drive will answer.
    #[test]
    fn ata_cdb_matches_the_sat_command() {
        assert_eq!(
            ata_passthrough_cdb(ATA_SMART_READ_ATTRIBUTES),
            [
                0x85, 0x08, 0x0E, 0x00, 0xD0, 0x00, 0x01, 0x00, 0x00, 0x00, 0x4F, 0x00, 0xC2, 0x00,
                0xB0, 0x00
            ]
        );
        // Only the feature register moves between the two tables.
        let thresholds = ata_passthrough_cdb(ATA_SMART_READ_THRESHOLDS);
        assert_eq!(thresholds[4], 0xD1);
        assert_eq!(thresholds[10], 0x4F, "SMART signature, LBA mid");
        assert_eq!(thresholds[12], 0xC2, "SMART signature, LBA high");
        assert_eq!(thresholds[14], 0xB0, "the SMART command itself");
    }

    /// Byte 2 field by field, because the byte carries four separate meanings
    /// and only the arithmetic says which are set.
    ///
    /// CK_COND is the one that matters. With bit 5 set, the SAT layer completes
    /// every command with CHECK CONDITION and an ATA Status Return Descriptor,
    /// including the ones that worked, so `hdr.status` is 0x02 on a good read
    /// and `ata_smart_table` bails on line 232 having been handed all 512
    /// bytes. Every SATA disk in the fleet would report "ATA pass-through
    /// refused". The plan's own byte, 0x2E at
    /// `docs/plans/2026-09-04-003-rmm-architecture.md:753`, has it set.
    #[test]
    fn ata_cdb_does_not_ask_for_check_condition() {
        let byte2 = ata_passthrough_cdb(ATA_SMART_READ_ATTRIBUTES)[2];
        assert_eq!(byte2 & 0b11, 2, "t_length: the sector count holds it");
        assert_eq!(byte2 & 0b100, 0b100, "byte_block: that length is in blocks");
        assert_eq!(byte2 & 0b1000, 0b1000, "t_dir: from the device");
        assert_eq!(byte2 & 0b10_0000, 0, "ck_cond must stay clear");
        assert_eq!(byte2 & 0b1100_0000, 0, "off_line: no extra wait");
    }

    #[test]
    fn nvme_namespace_maps_to_its_controller() {
        assert_eq!(nvme_controller("nvme0n1").as_deref(), Some("nvme0"));
        assert_eq!(nvme_controller("nvme12n3").as_deref(), Some("nvme12"));
        // The controller node itself is not a namespace and has no /sys/block
        // entry; answering "nvme0" for it would send the admin command to the
        // right node for the wrong reason.
        assert_eq!(nvme_controller("nvme0"), None);
        assert_eq!(nvme_controller("sda"), None);
        assert_eq!(nvme_controller("nvme"), None);
    }

    /// Sectors are always 512 bytes here whatever the drive reports, so a 4Kn
    /// drive is not eight times its real size.
    #[test]
    fn size_is_in_512_byte_sectors() {
        assert_eq!(parse_size_bytes("1953525168\n"), Some(1_000_204_886_016));
        assert_eq!(parse_size_bytes("0"), Some(0));
        assert_eq!(parse_size_bytes(""), None);
        assert_eq!(parse_size_bytes("not a number"), None);
    }

    #[test]
    fn rotational_distinguishes_absent_from_false() {
        assert_eq!(parse_rotational("1\n"), Some(true));
        assert_eq!(parse_rotational("0\n"), Some(false));
        assert_eq!(parse_rotational(""), None);
        assert_eq!(parse_rotational("maybe"), None);
    }

    /// Millidegrees. Reporting the raw value would put 41000 C on the console.
    #[test]
    fn hwmon_temperature_is_millidegrees() {
        assert_eq!(parse_milli_celsius("41850\n"), Some(41));
        assert_eq!(parse_milli_celsius("-5000"), Some(-5));
        assert_eq!(parse_milli_celsius("n/a"), None);
    }

    /// A loop file or an md array has no drive to ask. Enumerating them would
    /// add `disk` rows that can never move off `unreadable`.
    #[test]
    fn virtual_block_devices_are_skipped() {
        assert!(is_health_candidate("sda"));
        assert!(is_health_candidate("nvme0n1"));
        assert!(is_health_candidate("vda"));
        assert!(!is_health_candidate("loop0"));
        assert!(!is_health_candidate("ram0"));
        assert!(!is_health_candidate("zram0"));
        assert!(!is_health_candidate("dm-0"));
        assert!(!is_health_candidate("md0"));
        assert!(!is_health_candidate("sr0"));
    }

    #[test]
    fn empty_sysfs_fields_are_absent() {
        assert_eq!(text(Some("  Samsung SSD 860  \n".into())).as_deref(), Some("Samsung SSD 860"));
        assert_eq!(text(Some("\n".into())), None);
        assert_eq!(text(None), None);
    }
}
