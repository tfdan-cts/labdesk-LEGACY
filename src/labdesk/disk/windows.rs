// Windows: getting the bytes the parsers in `ata` and `nvme` read.
//
// Nothing here interprets a reading. Every function either hands back a raw
// buffer of the length the device owed us, or an error saying which call was
// refused and why. That division is what lets the parsers be tested on a
// diskless CI runner and lets this file be reviewed as plumbing.
//
// Privilege, measured rather than assumed. On this workstation the interactive
// user is denied `MSStorageDriver_FailurePredictStatus` and
// `MSFT_StorageReliabilityCounter`; only `MSFT_PhysicalDisk` answers, and it
// carries neither temperature nor wear. That is why the collector runs inside
// the privileged service and why nothing here has a fallback that works from a
// user session. Concretely:
//
//   * `CreateFileW` on `\\.\PhysicalDriveN` with GENERIC_READ | GENERIC_WRITE
//     needs Administrator or SYSTEM. This is the handle the SMART calls need,
//     because `SMART_RCV_DRIVE_DATA` is defined with FILE_READ_ACCESS |
//     FILE_WRITE_ACCESS and a zero-access handle fails it outright.
//   * `CreateFileW` with `dwDesiredAccess = 0` succeeds for an unprivileged
//     caller and is enough for `IOCTL_STORAGE_QUERY_PROPERTY`,
//     `IOCTL_STORAGE_GET_DEVICE_NUMBER` and `IOCTL_STORAGE_PREDICT_FAILURE`.
//     [`Drive::open`] falls back to it and records the degradation on
//     [`Drive::writable`], so a fleet running unprivileged still reports the
//     drive's own failure prediction instead of reporting nothing.
//
// Every call is may-fail, record why, continue. A drive that answered three of
// five questions is worth more than a collector that gave up on the first
// refusal, and `StorageDeviceProtocolSpecificProperty` in particular is served
// by the storage port driver rather than the class driver: several vendor
// stacks answer ERROR_INVALID_FUNCTION to it on hardware that is perfectly
// healthy.
//
// Constants and struct layouts were read out of
// windows-0.61.1/src/Windows/Win32/System/Ioctl/mod.rs, not recalled. The
// layout assumptions this file makes are asserted in `tests::layout` so a crate
// bump that moves a field fails the build rather than silently shifting the
// bytes handed to a parser.

use super::BUF_LEN;
use hbb_common::{bail, ResultType};
use std::ffi::OsStr;
use std::os::windows::ffi::OsStrExt;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{CloseHandle, GENERIC_READ, GENERIC_WRITE, HANDLE};
use windows::Win32::Storage::FileSystem::{
    CreateFileW, FILE_FLAGS_AND_ATTRIBUTES, FILE_SHARE_READ, FILE_SHARE_WRITE, OPEN_EXISTING,
    STORAGE_BUS_TYPE,
};
use windows::Win32::Storage::Nvme::NVME_LOG_PAGE_HEALTH_INFO;
use windows::Win32::System::Ioctl::{
    PropertyStandardQuery, ProtocolTypeNvme, StorageDeviceProperty, CAP_SMART_CMD,
    StorageDeviceProtocolSpecificProperty, GETVERSIONINPARAMS, IDEREGS,
    IOCTL_STORAGE_GET_DEVICE_NUMBER, IOCTL_STORAGE_PREDICT_FAILURE, IOCTL_STORAGE_QUERY_PROPERTY,
    NVMeDataTypeLogPage, READ_ATTRIBUTES, READ_ATTRIBUTE_BUFFER_SIZE, READ_THRESHOLDS,
    READ_THRESHOLD_BUFFER_SIZE, RETURN_SMART_STATUS, SENDCMDINPARAMS, SENDCMDOUTPARAMS, SMART_CMD,
    SMART_CYL_HI, SMART_CYL_LOW, SMART_GET_VERSION, SMART_NO_ERROR, SMART_RCV_DRIVE_DATA,
    SMART_SEND_DRIVE_COMMAND, STORAGE_DEVICE_NUMBER, STORAGE_PREDICT_FAILURE,
    STORAGE_PROPERTY_QUERY, STORAGE_PROTOCOL_DATA_DESCRIPTOR, STORAGE_PROTOCOL_SPECIFIC_DATA,
};
use windows::Win32::System::IO::DeviceIoControl;

/// How many `\\.\PhysicalDriveN` indices [`physical_drives`] probes.
///
/// A policy, not a measured limit: Windows numbers physical drives from 0 with
/// no documented ceiling, and the numbering is sparse once removable media come
/// and go. Scanning is the only enumeration that finds a disk carrying no
/// mounted volume, and 32 covers every machine this fleet targets. Raise it if
/// a chassis ever exceeds it; do not replace it with a guess about density.
pub const MAX_PHYSICAL_DRIVES: u32 = 32;

/// Byte offset of `STORAGE_PROPERTY_QUERY::AdditionalParameters`, where the
/// protocol-specific request is written. Two 4-byte fields precede it.
/// `tests::layout` pins the assumption.
const QUERY_ADDITIONAL_PARAMETERS: usize = 8;

/// Byte offset of `STORAGE_PROTOCOL_DATA_DESCRIPTOR::ProtocolSpecificData` in
/// the returned buffer: `Version` and `Size` precede it.
const DESCRIPTOR_PROTOCOL_DATA: usize = 8;

/// Byte offset of `STORAGE_PROTOCOL_SPECIFIC_DATA::ProtocolDataOffset` within
/// that struct: five 4-byte fields precede it.
const PROTOCOL_DATA_OFFSET_FIELD: usize = 16;
/// Byte offset of `STORAGE_PROTOCOL_SPECIFIC_DATA::ProtocolDataLength`.
const PROTOCOL_DATA_LENGTH_FIELD: usize = 20;

/// Byte offset of `SENDCMDOUTPARAMS::DriverStatus::bDriverError` in the output
/// buffer: `cBufferSize` precedes it. The whole struct is `packed(1)`.
const DRIVER_ERROR_FIELD: usize = 4;

/// Byte offset of `STORAGE_PREDICT_FAILURE::PredictFailure`: it is the first
/// field, and 512 bytes of vendor data follow it.
const PREDICT_FAILURE_FIELD: usize = 0;
/// Byte offset of `STORAGE_DEVICE_NUMBER::DeviceNumber`: `DeviceType` precedes
/// it, and reading that instead returns the storage class rather than the disk.
const DEVICE_NUMBER_FIELD: usize = 4;
/// Byte offset of `GETVERSIONINPARAMS::fCapabilities`: four single bytes
/// precede it and `dwReserved[4]` follows.
const CAPABILITIES_FIELD: usize = 4;

/// Byte offsets of the two cylinder registers inside an `IDEREGS`. Three
/// single-byte registers precede the low one.
const IDEREGS_CYL_LOW: usize = 3;
const IDEREGS_CYL_HIGH: usize = 4;

/// `IDEREGS::bDriveHeadReg` for the master device. The drive select bit is
/// folded in by [`smart_in_buf`].
const DRIVE_HEAD_MASTER: u8 = 0xA0;

/// Offsets into `STORAGE_DEVICE_DESCRIPTOR` that [`Identity`] reads. The
/// descriptor is variable length: the fixed header carries byte offsets into
/// the same buffer, and an offset of 0 means the drive did not answer.
///
/// `RemovableMedia` is at 10, not 8. `DeviceType` and `DeviceTypeModifier` sit
/// at 8 and 9 ahead of it, and reading `DeviceType` gives the storage class:
/// 0 for SCSI direct access, which is every hard disk and every USB stick, so
/// the flag would read false on exactly the media it exists to mark.
const SDD_REMOVABLE_MEDIA: usize = 10;
const SDD_VENDOR_ID_OFFSET: usize = 12;
const SDD_PRODUCT_ID_OFFSET: usize = 16;
const SDD_PRODUCT_REVISION_OFFSET: usize = 20;
const SDD_SERIAL_NUMBER_OFFSET: usize = 24;
const SDD_BUS_TYPE: usize = 28;
/// Enough for the fixed header plus the strings every drive appends after it.
const SDD_BUF_LEN: usize = 1024;

/// An open handle to `\\.\PhysicalDriveN`.
///
/// Closing is the `Drop`, so a probe that bails halfway through does not leak a
/// handle to a physical disk.
pub struct Drive {
    handle: HANDLE,
    index: u32,
    writable: bool,
}

/// What the drive says it is. No health here, only identity, so the collector
/// can key a `disk` row before any SMART call succeeds or fails.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Identity {
    pub vendor: String,
    pub product: String,
    pub revision: String,
    pub serial: String,
    /// One of the strings `disk.bus` stores: nvme, sata, sas, usb, raid,
    /// unknown.
    pub bus: &'static str,
    pub removable: bool,
}

impl Drop for Drive {
    fn drop(&mut self) {
        // Nothing useful to do with a failure here, and the process is not
        // exiting: log nothing, drop the handle.
        let _ = unsafe { CloseHandle(self.handle) };
    }
}

impl Drive {
    /// Open `\\.\PhysicalDriveN`, read/write first so the SMART path is
    /// available, falling back to a zero-access handle when that is denied.
    ///
    /// The fallback is not a nicety. `SMART_RCV_DRIVE_DATA` is defined with
    /// FILE_READ_ACCESS | FILE_WRITE_ACCESS, so an unprivileged caller loses
    /// the ATA attribute table entirely, but `IOCTL_STORAGE_PREDICT_FAILURE`
    /// still answers on a zero-access handle and is the drive's own verdict.
    pub fn open(index: u32) -> ResultType<Self> {
        let path: Vec<u16> = OsStr::new(&format!("\\\\.\\PhysicalDrive{}", index))
            .encode_wide()
            .chain(std::iter::once(0))
            .collect();
        let open = |access: u32| unsafe {
            CreateFileW(
                PCWSTR::from_raw(path.as_ptr()),
                access,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                None,
                OPEN_EXISTING,
                FILE_FLAGS_AND_ATTRIBUTES(0),
                None,
            )
        };
        match open(GENERIC_READ.0 | GENERIC_WRITE.0) {
            Ok(handle) => Ok(Self {
                handle,
                index,
                writable: true,
            }),
            Err(rw_err) => match open(0) {
                Ok(handle) => Ok(Self {
                    handle,
                    index,
                    writable: false,
                }),
                Err(ro_err) => bail!(
                    "PhysicalDrive{}: read/write open failed ({}) and zero-access open failed ({})",
                    index,
                    rw_err,
                    ro_err
                ),
            },
        }
    }

    /// The `\\.\PhysicalDriveN` index this handle was opened on.
    pub fn index(&self) -> u32 {
        self.index
    }

    /// False when only the zero-access fallback succeeded, which means every
    /// SMART call on this drive will be refused. Store it so a fleet-wide
    /// absence of ATA data reads as "the agent is not privileged" rather than
    /// "the drives do not support SMART".
    pub fn writable(&self) -> bool {
        self.writable
    }

    fn ioctl(&self, code: u32, input: &[u8], output: &mut [u8]) -> ResultType<u32> {
        let mut returned: u32 = 0;
        let in_ptr = if input.is_empty() {
            None
        } else {
            Some(input.as_ptr() as *const core::ffi::c_void)
        };
        unsafe {
            DeviceIoControl(
                self.handle,
                code,
                in_ptr,
                input.len() as u32,
                Some(output.as_mut_ptr() as *mut core::ffi::c_void),
                output.len() as u32,
                Some(&mut returned),
                None,
            )
        }?;
        Ok(returned)
    }

    /// `IOCTL_STORAGE_QUERY_PROPERTY` / `StorageDeviceProperty`. Works on the
    /// zero-access handle.
    pub fn identity(&self) -> ResultType<Identity> {
        // The full `STORAGE_PROPERTY_QUERY`, padding included: the documented
        // minimum input length is its `sizeof`, not the offset of the field
        // this query stops at.
        let mut query = vec![0u8; std::mem::size_of::<STORAGE_PROPERTY_QUERY>()];
        query[0..4].copy_from_slice(&(StorageDeviceProperty.0 as u32).to_le_bytes());
        query[4..8].copy_from_slice(&(PropertyStandardQuery.0 as u32).to_le_bytes());
        let mut out = vec![0u8; SDD_BUF_LEN];
        let returned = self.ioctl(IOCTL_STORAGE_QUERY_PROPERTY, &query, &mut out)? as usize;
        out.truncate(returned.min(SDD_BUF_LEN));
        parse_device_descriptor(&out)
    }

    /// `IOCTL_STORAGE_GET_DEVICE_NUMBER`, the disk number the volume layer uses.
    /// The same call on a `\\.\C:` handle is how a volume is mapped back to its
    /// physical disk; that mapping belongs to the collector, not here.
    pub fn device_number(&self) -> ResultType<u32> {
        let mut out = [0u8; std::mem::size_of::<STORAGE_DEVICE_NUMBER>()];
        let returned = self.ioctl(IOCTL_STORAGE_GET_DEVICE_NUMBER, &[], &mut out)? as usize;
        reply_u32(
            &out,
            returned,
            DEVICE_NUMBER_FIELD,
            "STORAGE_DEVICE_NUMBER::DeviceNumber",
        )
    }

    /// `IOCTL_STORAGE_PREDICT_FAILURE`: the drive's own yes/no, on every bus
    /// including USB bridges and RAID members, from the zero-access handle.
    ///
    /// This is the same datum WMI exposes as
    /// `MSStorageDriver_FailurePredictStatus`, without the namespace ACL that
    /// denies it to an interactive user, which is why it is the call to make
    /// first and the one to trust when everything else is refused.
    pub fn predict_failure(&self) -> ResultType<bool> {
        // STORAGE_PREDICT_FAILURE: PredictFailure u32, then VendorSpecific[512].
        let mut out = [0u8; std::mem::size_of::<STORAGE_PREDICT_FAILURE>()];
        let returned = self.ioctl(IOCTL_STORAGE_PREDICT_FAILURE, &[], &mut out)? as usize;
        Ok(reply_u32(
            &out,
            returned,
            PREDICT_FAILURE_FIELD,
            "STORAGE_PREDICT_FAILURE::PredictFailure",
        )? != 0)
    }

    /// The NVMe SMART / Health Information log page, identifier 02h, exactly as
    /// [`super::nvme::parse_nvme_health`] wants it.
    ///
    /// Fails with ERROR_INVALID_FUNCTION on vendor stacks whose port driver does
    /// not implement `StorageDeviceProtocolSpecificProperty`. That is a normal
    /// answer, not a bug: record it and fall through to the prediction.
    pub fn nvme_health_page(&self) -> ResultType<[u8; BUF_LEN]> {
        let query = protocol_query_buf();
        let mut out = vec![0u8; query.len()];
        let returned = self.ioctl(IOCTL_STORAGE_QUERY_PROPERTY, &query, &mut out)? as usize;
        out.truncate(returned.min(query.len()));
        protocol_payload(&out)
    }

    /// True when the driver answers `SMART_GET_VERSION` with the SMART command
    /// capability bit. Gate the two calls below on it: sending
    /// `SMART_RCV_DRIVE_DATA` to a driver that never claimed the capability is
    /// how the ATA path produces confusing failures on NVMe and RAID stacks.
    pub fn smart_supported(&self) -> ResultType<bool> {
        // GETVERSIONINPARAMS: bVersion, bRevision, bReserved, bIDEDeviceMap,
        // fCapabilities u32, dwReserved[4].
        let mut out = [0u8; std::mem::size_of::<GETVERSIONINPARAMS>()];
        let returned = self.ioctl(SMART_GET_VERSION, &[], &mut out)? as usize;
        let caps = reply_u32(
            &out,
            returned,
            CAPABILITIES_FIELD,
            "GETVERSIONINPARAMS::fCapabilities",
        )?;
        Ok(caps & CAP_SMART_CMD != 0)
    }

    /// The 512-byte ATA SMART attribute table, for
    /// [`super::ata::parse_ata_attributes`]. Needs the read/write handle.
    pub fn ata_attributes(&self) -> ResultType<[u8; BUF_LEN]> {
        self.smart_read(READ_ATTRIBUTES as u8, READ_ATTRIBUTE_BUFFER_SIZE)
    }

    /// The 512-byte ATA SMART threshold table, for
    /// [`super::ata::parse_ata_thresholds`]. Needs the read/write handle.
    pub fn ata_thresholds(&self) -> ResultType<[u8; BUF_LEN]> {
        self.smart_read(READ_THRESHOLDS as u8, READ_THRESHOLD_BUFFER_SIZE)
    }

    fn smart_read(&self, feature: u8, buffer_size: u32) -> ResultType<[u8; BUF_LEN]> {
        if !self.writable {
            bail!(
                "PhysicalDrive{}: SMART feature {:#04x} needs a read/write handle and only the \
                 zero-access fallback opened",
                self.index,
                feature
            );
        }
        let input = smart_in_buf(feature, self.index, buffer_size);
        let mut out = vec![0u8; smart_out_len(buffer_size as usize)];
        let returned = self.ioctl(SMART_RCV_DRIVE_DATA, &input, &mut out)? as usize;
        out.truncate(returned.min(out.len()));
        let payload = smart_out_payload(&out, BUF_LEN)?;
        let mut buf = [0u8; BUF_LEN];
        buf.copy_from_slice(payload);
        Ok(buf)
    }

    /// `RETURN_SMART_STATUS`: the drive's threshold-exceeded answer, returned in
    /// the cylinder registers, ready for
    /// [`super::ata::smart_status_failing`]. Needs the read/write handle.
    ///
    /// This one goes out on `SMART_SEND_DRIVE_COMMAND` with a zero-length data
    /// buffer, and the reply is an `IDEREGS` in the output payload rather than a
    /// 512-byte table.
    pub fn ata_smart_status(&self) -> ResultType<(u8, u8)> {
        if !self.writable {
            bail!(
                "PhysicalDrive{}: RETURN_SMART_STATUS needs a read/write handle and only the \
                 zero-access fallback opened",
                self.index
            );
        }
        let input = smart_in_buf(RETURN_SMART_STATUS as u8, self.index, 0);
        let regs = std::mem::size_of::<IDEREGS>();
        let mut out = vec![0u8; smart_out_len(regs)];
        let returned = self.ioctl(SMART_SEND_DRIVE_COMMAND, &input, &mut out)? as usize;
        out.truncate(returned.min(out.len()));
        smart_status_regs(smart_out_payload(&out, regs)?)
    }
}

/// A `u32` field at `at` in a driver's reply, refused unless the driver said it
/// wrote that far.
///
/// `DeviceIoControl` reports success and a byte count, and the count is the
/// only evidence the buffer holds anything. A call that succeeded without
/// filling it leaves the caller's zeroes behind, which is how "the driver
/// answered nothing" becomes `PredictFailure == 0`, a `Some(false)` and, by
/// `verdict::verdict`, a green tick. That is the one rule `disk/mod.rs` exists
/// to enforce, so the length is checked before the bytes are read.
fn reply_u32(out: &[u8], returned: usize, at: usize, what: &str) -> ResultType<u32> {
    let need = at + 4;
    if returned < need || out.len() < need {
        bail!(
            "{}: the driver returned {} bytes, need {}",
            what,
            returned,
            need
        );
    }
    Ok(u32::from_le_bytes([
        out[at],
        out[at + 1],
        out[at + 2],
        out[at + 3],
    ]))
}

/// The cylinder pair out of the `IDEREGS` a `RETURN_SMART_STATUS` reply
/// carries, in the order [`super::ata::smart_status_failing`] takes them.
///
/// Split out of [`Drive::ata_smart_status`] because that call needs a live
/// handle and nothing could otherwise test the decode. The order is load
/// bearing: 0xF4 / 0x2C is the drive reporting a threshold exceeded, and
/// swapped it becomes 0x2C / 0xF4, which matches neither signature. The drive's
/// own "I am dying" would then be dropped as `None` instead of reported.
fn smart_status_regs(payload: &[u8]) -> ResultType<(u8, u8)> {
    let regs = std::mem::size_of::<IDEREGS>();
    if payload.len() < regs {
        bail!(
            "RETURN_SMART_STATUS returned {} bytes, IDEREGS is {}",
            payload.len(),
            regs
        );
    }
    // IDEREGS is eight single bytes: features, sector count, sector number,
    // cylinder low, cylinder high, drive/head, command, reserved.
    Ok((payload[IDEREGS_CYL_LOW], payload[IDEREGS_CYL_HIGH]))
}

/// Every `\\.\PhysicalDriveN` index that opens, in order.
///
/// The numbering is sparse, so this does not stop at the first gap. A drive that
/// refuses both access levels is skipped rather than reported: it is not a disk
/// this agent can say anything about.
pub fn physical_drives() -> Vec<u32> {
    (0..MAX_PHYSICAL_DRIVES)
        .filter(|index| Drive::open(*index).is_ok())
        .collect()
}

/// The `SENDCMDINPARAMS` input buffer, as bytes.
///
/// The input length is `size_of::<SENDCMDINPARAMS>() - 1`, because the struct
/// ends in a one-byte `bBuffer` placeholder that is not part of an input
/// request. Passing a bare `size_of` is the classic failure on this call and
/// makes the driver reject the request.
fn smart_in_buf(feature: u8, drive: u32, buffer_size: u32) -> Vec<u8> {
    let params = SENDCMDINPARAMS {
        cBufferSize: buffer_size,
        irDriveRegs: IDEREGS {
            bFeaturesReg: feature,
            // One sector, addressed by the SMART signature in the cylinder
            // registers. Both are 1 for every SMART data transfer.
            bSectorCountReg: 1,
            bSectorNumberReg: 1,
            bCylLowReg: SMART_CYL_LOW as u8,
            bCylHighReg: SMART_CYL_HI as u8,
            // Bit 4 selects master or slave on the controller the drive sits
            // on, which is the low bit of the physical drive number.
            bDriveHeadReg: DRIVE_HEAD_MASTER | (((drive & 1) as u8) << 4),
            bCommandReg: SMART_CMD as u8,
            bReserved: 0,
        },
        bDriveNumber: drive as u8,
        bReserved: [0; 3],
        dwReserved: [0; 4],
        bBuffer: [0; 1],
    };
    let len = std::mem::size_of::<SENDCMDINPARAMS>() - 1;
    // SENDCMDINPARAMS is packed(1) and Copy, so its bytes are exactly the wire
    // layout with no padding to leak.
    let bytes =
        unsafe { std::slice::from_raw_parts(&params as *const SENDCMDINPARAMS as *const u8, len) };
    bytes.to_vec()
}

/// The output buffer length for a SMART receive of `payload` bytes: the
/// `SENDCMDOUTPARAMS` header, less its one-byte `bBuffer` placeholder, plus the
/// payload itself.
fn smart_out_len(payload: usize) -> usize {
    std::mem::size_of::<SENDCMDOUTPARAMS>() - 1 + payload
}

/// The payload out of a `SENDCMDOUTPARAMS`, once the driver has said it
/// succeeded.
///
/// `bDriverError` is checked before the bytes are trusted. A driver that
/// refused the command still returns a buffer, and that buffer is whatever the
/// caller zeroed it to, which parses cleanly into an empty attribute table.
/// Treating it as data is how "we could not ask" turns into a green tick.
fn smart_out_payload(out: &[u8], want: usize) -> ResultType<&[u8]> {
    let header = std::mem::size_of::<SENDCMDOUTPARAMS>() - 1;
    if out.len() < header + want {
        bail!(
            "SMART output buffer is {} bytes, need {}",
            out.len(),
            header + want
        );
    }
    let err = out[DRIVER_ERROR_FIELD];
    if err as u32 != SMART_NO_ERROR {
        bail!("SMART driver error {}", err);
    }
    Ok(&out[header..header + want])
}

/// The `IOCTL_STORAGE_QUERY_PROPERTY` request for the NVMe health log page.
///
/// One buffer serves as both input and output, which is what the field layout
/// expects: `ProtocolDataOffset` is measured from the start of the
/// `STORAGE_PROTOCOL_SPECIFIC_DATA` struct, so the log page lands immediately
/// after it and the driver writes it back into the same place.
fn protocol_query_buf() -> Vec<u8> {
    let specific = std::mem::size_of::<STORAGE_PROTOCOL_SPECIFIC_DATA>();
    let mut buf = vec![0u8; QUERY_ADDITIONAL_PARAMETERS + specific + BUF_LEN];
    buf[0..4].copy_from_slice(&(StorageDeviceProtocolSpecificProperty.0 as u32).to_le_bytes());
    buf[4..8].copy_from_slice(&(PropertyStandardQuery.0 as u32).to_le_bytes());
    let p = QUERY_ADDITIONAL_PARAMETERS;
    let put = |buf: &mut [u8], field: usize, value: u32| {
        buf[p + field..p + field + 4].copy_from_slice(&value.to_le_bytes());
    };
    put(&mut buf, 0, ProtocolTypeNvme.0 as u32); // ProtocolType
    put(&mut buf, 4, NVMeDataTypeLogPage.0 as u32); // DataType
    put(&mut buf, 8, NVME_LOG_PAGE_HEALTH_INFO.0 as u32); // ProtocolDataRequestValue
    put(&mut buf, 12, 0); // ProtocolDataRequestSubValue
    put(&mut buf, PROTOCOL_DATA_OFFSET_FIELD, specific as u32);
    put(&mut buf, PROTOCOL_DATA_LENGTH_FIELD, BUF_LEN as u32);
    buf
}

/// The log page out of a `STORAGE_PROTOCOL_DATA_DESCRIPTOR`.
///
/// The offset and length are read back from what the driver returned rather
/// than assumed to match the request: a port driver is free to answer with a
/// shorter page, and reading 512 bytes past a 64-byte answer would hand the
/// parser whatever was left in the buffer.
fn protocol_payload(out: &[u8]) -> ResultType<[u8; BUF_LEN]> {
    let head = std::mem::size_of::<STORAGE_PROTOCOL_DATA_DESCRIPTOR>();
    if out.len() < head {
        bail!(
            "protocol data descriptor is {} bytes, need {}",
            out.len(),
            head
        );
    }
    let field = |at: usize| {
        let base = DESCRIPTOR_PROTOCOL_DATA + at;
        u32::from_le_bytes([out[base], out[base + 1], out[base + 2], out[base + 3]]) as usize
    };
    let offset = field(PROTOCOL_DATA_OFFSET_FIELD);
    let length = field(PROTOCOL_DATA_LENGTH_FIELD);
    if length < BUF_LEN {
        bail!(
            "NVMe log page is {} bytes, the health page is {}",
            length,
            BUF_LEN
        );
    }
    let start = DESCRIPTOR_PROTOCOL_DATA + offset;
    let end = start
        .checked_add(BUF_LEN)
        .filter(|end| *end <= out.len())
        .ok_or_else(|| {
            hbb_common::anyhow::anyhow!(
                "NVMe log page at offset {} runs past the {}-byte reply",
                start,
                out.len()
            )
        })?;
    let mut page = [0u8; BUF_LEN];
    page.copy_from_slice(&out[start..end]);
    Ok(page)
}

/// Identity out of a `STORAGE_DEVICE_DESCRIPTOR`.
///
/// The strings are not in the header. It carries byte offsets into the same
/// buffer, and an offset of 0 is the drive saying it did not answer that field,
/// which is why every one of them can come back empty.
fn parse_device_descriptor(out: &[u8]) -> ResultType<Identity> {
    if out.len() <= SDD_BUS_TYPE + 4 {
        bail!("storage device descriptor is only {} bytes", out.len());
    }
    let at = |field: usize| {
        u32::from_le_bytes([out[field], out[field + 1], out[field + 2], out[field + 3]]) as usize
    };
    Ok(Identity {
        vendor: descriptor_str(out, at(SDD_VENDOR_ID_OFFSET)),
        product: descriptor_str(out, at(SDD_PRODUCT_ID_OFFSET)),
        revision: descriptor_str(out, at(SDD_PRODUCT_REVISION_OFFSET)),
        serial: descriptor_str(out, at(SDD_SERIAL_NUMBER_OFFSET)),
        bus: bus_name(at(SDD_BUS_TYPE) as i32),
        removable: out[SDD_REMOVABLE_MEDIA] != 0,
    })
}

/// A NUL-terminated ASCII field at `offset` in the descriptor buffer, trimmed.
/// Offset 0 means absent, and so does an offset past the end of what the driver
/// returned.
fn descriptor_str(out: &[u8], offset: usize) -> String {
    if offset == 0 || offset >= out.len() {
        return String::new();
    }
    let tail = &out[offset..];
    let end = tail.iter().position(|b| *b == 0).unwrap_or(tail.len());
    String::from_utf8_lossy(&tail[..end]).trim().to_string()
}

/// `STORAGE_BUS_TYPE` as one of the strings `disk.bus` stores.
///
/// The buses that carry a SMART path are named; everything else collapses to
/// unknown, because the column exists to explain why a drive did or did not
/// answer, not to enumerate Windows' bus taxonomy.
fn bus_name(bus: i32) -> &'static str {
    use windows::Win32::Storage::FileSystem::{
        BusTypeAta, BusTypeNvme, BusTypeRAID, BusTypeSas, BusTypeSata, BusTypeSpaces, BusTypeUsb,
    };
    match STORAGE_BUS_TYPE(bus) {
        b if b == BusTypeNvme => "nvme",
        b if b == BusTypeSata || b == BusTypeAta => "sata",
        b if b == BusTypeSas => "sas",
        b if b == BusTypeUsb => "usb",
        b if b == BusTypeRAID || b == BusTypeSpaces => "raid",
        _ => "unknown",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    // Only the tests read the descriptor's own layout; the module itself walks
    // the buffer by offset because the struct is variable length.
    use windows::Win32::System::Ioctl::STORAGE_DEVICE_DESCRIPTOR;

    /// Everything this file does with raw offsets rests on these sizes. A
    /// `windows` crate bump that changes one would otherwise shift the bytes
    /// handed to a parser without any call failing.
    #[test]
    fn layout() {
        assert_eq!(std::mem::size_of::<SENDCMDINPARAMS>(), 33);
        assert_eq!(std::mem::size_of::<SENDCMDOUTPARAMS>(), 17);
        assert_eq!(std::mem::size_of::<IDEREGS>(), 8);
        assert_eq!(std::mem::size_of::<STORAGE_PROPERTY_QUERY>(), 12);
        assert_eq!(std::mem::size_of::<STORAGE_PROTOCOL_SPECIFIC_DATA>(), 40);
        assert_eq!(std::mem::size_of::<STORAGE_PROTOCOL_DATA_DESCRIPTOR>(), 48);
        assert_eq!(std::mem::size_of::<STORAGE_DEVICE_NUMBER>(), 12);
        assert_eq!(std::mem::size_of::<GETVERSIONINPARAMS>(), 24);
        assert_eq!(std::mem::size_of::<STORAGE_PREDICT_FAILURE>(), 4 + BUF_LEN);
    }

    /// Where each field actually is, taken from the crate's own structs rather
    /// than from the constants that read them.
    ///
    /// `layout` pins sizes, and a size cannot tell a field from its
    /// same-sized neighbour: `RemovableMedia` shipped for a wave reading
    /// `DeviceType` two bytes earlier and every test stayed green, because
    /// every fixture was built out of the same constant and moved with it.
    /// These offsets come from the struct, so a wrong constant and a crate bump
    /// both fail here.
    #[test]
    fn offsets_match_the_crate_structs() {
        macro_rules! offset {
            ($ty:ty, $($field:tt)+) => {{
                let value = <$ty>::default();
                let base = &value as *const $ty as usize;
                (std::ptr::addr_of!(value.$($field)+) as *const u8 as usize) - base
            }};
        }
        assert_eq!(
            offset!(STORAGE_PROPERTY_QUERY, AdditionalParameters),
            QUERY_ADDITIONAL_PARAMETERS
        );
        assert_eq!(
            offset!(STORAGE_PROTOCOL_DATA_DESCRIPTOR, ProtocolSpecificData),
            DESCRIPTOR_PROTOCOL_DATA
        );
        assert_eq!(
            offset!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolDataOffset),
            PROTOCOL_DATA_OFFSET_FIELD
        );
        assert_eq!(
            offset!(STORAGE_PROTOCOL_SPECIFIC_DATA, ProtocolDataLength),
            PROTOCOL_DATA_LENGTH_FIELD
        );
        assert_eq!(
            offset!(SENDCMDOUTPARAMS, DriverStatus.bDriverError),
            DRIVER_ERROR_FIELD
        );
        assert_eq!(
            offset!(STORAGE_PREDICT_FAILURE, PredictFailure),
            PREDICT_FAILURE_FIELD
        );
        assert_eq!(
            offset!(STORAGE_DEVICE_NUMBER, DeviceNumber),
            DEVICE_NUMBER_FIELD
        );
        assert_eq!(
            offset!(GETVERSIONINPARAMS, fCapabilities),
            CAPABILITIES_FIELD
        );
        assert_eq!(offset!(IDEREGS, bCylLowReg), IDEREGS_CYL_LOW);
        assert_eq!(offset!(IDEREGS, bCylHighReg), IDEREGS_CYL_HIGH);
        assert_eq!(
            offset!(STORAGE_DEVICE_DESCRIPTOR, RemovableMedia),
            SDD_REMOVABLE_MEDIA
        );
        assert_eq!(
            offset!(STORAGE_DEVICE_DESCRIPTOR, VendorIdOffset),
            SDD_VENDOR_ID_OFFSET
        );
        assert_eq!(
            offset!(STORAGE_DEVICE_DESCRIPTOR, ProductIdOffset),
            SDD_PRODUCT_ID_OFFSET
        );
        assert_eq!(
            offset!(STORAGE_DEVICE_DESCRIPTOR, ProductRevisionOffset),
            SDD_PRODUCT_REVISION_OFFSET
        );
        assert_eq!(
            offset!(STORAGE_DEVICE_DESCRIPTOR, SerialNumberOffset),
            SDD_SERIAL_NUMBER_OFFSET
        );
        assert_eq!(offset!(STORAGE_DEVICE_DESCRIPTOR, BusType), SDD_BUS_TYPE);
    }

    /// The identity buffer has to outlast the descriptor's fixed header by
    /// enough to hold the strings the drive appends after it: an ATA model is
    /// 40 bytes and a serial 20, and vendors pad past both. A buffer that ends
    /// inside the string area makes every field come back empty and leaves the
    /// `disk` row with no serial to key on.
    #[test]
    fn identity_buffer_holds_the_header_and_the_strings() {
        assert!(SDD_BUF_LEN >= std::mem::size_of::<STORAGE_DEVICE_DESCRIPTOR>() + 256);
    }

    /// A `DeviceIoControl` that reports success without filling the buffer
    /// hands back the caller's own zeroes, and `verdict.rs` turns a bare
    /// `Some(false)` prediction into `Verdict::Ok`. The byte count is the only
    /// thing standing between "we could not ask" and a green tick.
    #[test]
    fn a_reply_shorter_than_the_field_is_refused() {
        let full = [0xFFu8; 16];
        assert!(reply_u32(&full, 0, 0, "nothing written").is_err());
        assert!(reply_u32(&full, 3, 0, "three bytes of four").is_err());
        assert_eq!(
            reply_u32(&full, 4, 0, "exactly the field").unwrap(),
            0xFFFF_FFFF
        );
        assert!(reply_u32(&full, 4, 4, "a field the driver never reached").is_err());
        assert!(reply_u32(&full[..6], 16, 4, "a buffer shorter than the count").is_err());
    }

    /// Each of the three replies read at its own offset, from a buffer whose
    /// other fields hold values that would be wrong. Asserting only that
    /// something came back would not notice `DeviceType` standing in for
    /// `DeviceNumber`.
    #[test]
    fn reply_fields_sit_where_their_structs_put_them() {
        // STORAGE_DEVICE_NUMBER { DeviceType, DeviceNumber, PartitionNumber }.
        let mut num = [0u8; 12];
        num[0..4].copy_from_slice(&7u32.to_le_bytes()); // FILE_DEVICE_DISK
        num[4..8].copy_from_slice(&3u32.to_le_bytes());
        num[8..12].copy_from_slice(&1u32.to_le_bytes());
        assert_eq!(
            reply_u32(&num, num.len(), DEVICE_NUMBER_FIELD, "DeviceNumber").unwrap(),
            3
        );

        // GETVERSIONINPARAMS: four single bytes, then fCapabilities, then
        // dwReserved[4] of zeroes. Reading either neighbour loses the bit.
        let mut ver = [0u8; 24];
        ver[0..4].copy_from_slice(&[1, 1, 0, 1]); // version, revision, reserved, device map
        ver[4..8].copy_from_slice(&CAP_SMART_CMD.to_le_bytes()); // fCapabilities
        assert_eq!(
            reply_u32(&ver, ver.len(), CAPABILITIES_FIELD, "fCapabilities").unwrap() & CAP_SMART_CMD,
            CAP_SMART_CMD,
            "the driver claimed the SMART command capability"
        );
        ver[4..8].copy_from_slice(&0u32.to_le_bytes());
        assert_eq!(
            reply_u32(&ver, ver.len(), CAPABILITIES_FIELD, "fCapabilities").unwrap() & CAP_SMART_CMD,
            0,
            "and a driver that claimed nothing must not be read as claiming it"
        );

        // STORAGE_PREDICT_FAILURE: the flag, then 512 bytes of vendor data that
        // a healthy drive fills. Reading past the flag would fail every disk.
        let mut pf = [0xABu8; 4 + BUF_LEN];
        pf[0..4].copy_from_slice(&0u32.to_le_bytes());
        assert_eq!(
            reply_u32(&pf, pf.len(), PREDICT_FAILURE_FIELD, "PredictFailure").unwrap(),
            0
        );
        pf[0..4].copy_from_slice(&1u32.to_le_bytes());
        assert_eq!(
            reply_u32(&pf, pf.len(), PREDICT_FAILURE_FIELD, "PredictFailure").unwrap(),
            1
        );
    }

    /// The two numbers the plan calls the classic failure: a bare `size_of` on
    /// either end sends 33 in and asks for 529 back, and the driver refuses.
    #[test]
    fn smart_buffer_lengths_drop_the_placeholder_byte() {
        assert_eq!(smart_in_buf(READ_ATTRIBUTES as u8, 0, 512).len(), 32);
        assert_eq!(smart_out_len(512), 528);
        assert_eq!(smart_out_len(std::mem::size_of::<IDEREGS>()), 24);
    }

    /// Field by field, because a register in the wrong slot is a request for a
    /// different command that the drive will happily answer.
    #[test]
    fn smart_in_buf_places_every_register() {
        let buf = smart_in_buf(READ_ATTRIBUTES as u8, 0, READ_ATTRIBUTE_BUFFER_SIZE);
        assert_eq!(&buf[0..4], &512u32.to_le_bytes(), "cBufferSize");
        assert_eq!(buf[4], 0xD0, "bFeaturesReg = READ_ATTRIBUTES");
        assert_eq!(buf[5], 1, "bSectorCountReg");
        assert_eq!(buf[6], 1, "bSectorNumberReg");
        assert_eq!(buf[7], 0x4F, "bCylLowReg = SMART_CYL_LOW");
        assert_eq!(buf[8], 0xC2, "bCylHighReg = SMART_CYL_HI");
        assert_eq!(buf[9], 0xA0, "bDriveHeadReg, master");
        assert_eq!(buf[10], 0xB0, "bCommandReg = SMART_CMD");
        assert_eq!(buf[11], 0, "bReserved");
        assert_eq!(buf[12], 0, "bDriveNumber");

        let thresholds = smart_in_buf(READ_THRESHOLDS as u8, 3, READ_THRESHOLD_BUFFER_SIZE);
        assert_eq!(thresholds[4], 0xD1, "bFeaturesReg = READ_THRESHOLDS");
        assert_eq!(thresholds[9], 0xB0, "drive 3 is the slave on its controller");
        assert_eq!(thresholds[12], 3, "bDriveNumber");

        let status = smart_in_buf(RETURN_SMART_STATUS as u8, 0, 0);
        assert_eq!(&status[0..4], &0u32.to_le_bytes(), "status transfers no data");
        assert_eq!(status[4], 0xDA, "bFeaturesReg = RETURN_SMART_STATUS");
    }

    /// Built at the byte offsets `SENDCMDOUTPARAMS` has, written out rather
    /// than taken from this file's constants: a fixture built out of the same
    /// constant that reads it moves with it and notices nothing.
    fn smart_reply(driver_error: u8, payload: &[u8]) -> Vec<u8> {
        let mut out = vec![0u8; 16 + payload.len()];
        out[0..4].copy_from_slice(&(payload.len() as u32).to_le_bytes()); // cBufferSize
        out[4] = driver_error; // DriverStatus.bDriverError
        out[5] = 0; // DriverStatus.bIDEError
        out[16..].copy_from_slice(payload); // bBuffer
        out
    }

    /// The payload starts at 16, not 4 and not 17. A one-byte slip shifts the
    /// whole attribute table and every attribute id becomes its neighbour's.
    #[test]
    fn smart_out_payload_starts_after_the_header() {
        let mut page = [0u8; BUF_LEN];
        page[0] = 0x10;
        page[1] = 0x00;
        page[2] = 5; // first attribute id, at the table's first entry
        let out = smart_reply(0, &page);
        let got = smart_out_payload(&out, BUF_LEN).unwrap();
        assert_eq!(got.len(), BUF_LEN);
        assert_eq!(got[0], 0x10);
        assert_eq!(got[2], 5);
    }

    /// A refused command still fills the output buffer. Reading it as data is
    /// how a zeroed buffer becomes an empty attribute table and a healthy disk.
    #[test]
    fn smart_out_payload_refuses_a_driver_error() {
        let out = smart_reply(9, &[0u8; BUF_LEN]); // SMART_NOT_SUPPORTED
        assert!(smart_out_payload(&out, BUF_LEN).is_err());
    }

    /// The one call that carries the drive's own verdict, and the only one
    /// whose decode had no test: every register is given a different value, so
    /// a read one byte either side fails instead of coinciding. Swapped, a
    /// threshold-exceeded drive answers 0x2C / 0xF4, which matches neither
    /// signature in `ata::smart_status_failing`, and a dying disk is recorded
    /// as having said nothing.
    #[test]
    fn smart_status_reads_the_cylinder_pair_in_order() {
        let mut regs = [0u8; 8];
        regs[0] = 0xDA; // bFeaturesReg, RETURN_SMART_STATUS echoed back
        regs[1] = 0x01; // bSectorCountReg
        regs[2] = 0x01; // bSectorNumberReg
        regs[3] = 0xF4; // bCylLowReg: threshold exceeded
        regs[4] = 0x2C; // bCylHighReg
        regs[5] = 0xA0; // bDriveHeadReg
        regs[6] = 0xB0; // bCommandReg
        assert_eq!(smart_status_regs(&regs).unwrap(), (0xF4, 0x2C));
        assert_eq!(
            super::super::ata::smart_status_failing(0xF4, 0x2C),
            Some(true),
            "and the pair in that order is what the parser calls failing"
        );

        regs[3] = 0x4F; // the healthy signature, the same two registers
        regs[4] = 0xC2;
        assert_eq!(smart_status_regs(&regs).unwrap(), (0x4F, 0xC2));
        assert_eq!(
            super::super::ata::smart_status_failing(0x4F, 0xC2),
            Some(false)
        );

        // A driver that returned less than an IDEREGS wrote no registers at
        // all, and 0x00 / 0x00 is a pair the parser cannot read.
        assert!(smart_status_regs(&regs[..7]).is_err());
    }

    #[test]
    fn smart_out_payload_refuses_a_short_reply() {
        let out = smart_reply(0, &[0u8; 100]);
        assert!(smart_out_payload(&out, BUF_LEN).is_err());
    }

    /// The request the port driver reads. Every field is checked at its own
    /// offset because they are all `u32` and a swapped pair still looks like a
    /// well-formed request.
    #[test]
    fn protocol_query_asks_for_the_health_log_page() {
        let buf = protocol_query_buf();
        assert_eq!(buf.len(), 8 + 40 + BUF_LEN);
        let u32_at = |at: usize| u32::from_le_bytes(buf[at..at + 4].try_into().unwrap());
        assert_eq!(u32_at(0), 50, "StorageDeviceProtocolSpecificProperty");
        assert_eq!(u32_at(4), 0, "PropertyStandardQuery");
        assert_eq!(u32_at(8), 3, "ProtocolTypeNvme");
        assert_eq!(u32_at(12), 2, "NVMeDataTypeLogPage");
        assert_eq!(u32_at(16), 2, "log page identifier 02h, health information");
        assert_eq!(u32_at(20), 0, "ProtocolDataRequestSubValue");
        assert_eq!(u32_at(24), 40, "ProtocolDataOffset, from the struct's start");
        assert_eq!(u32_at(28), 512, "ProtocolDataLength");
    }

    /// Also written at the C struct's own offsets: `ProtocolSpecificData` at 8
    /// inside the descriptor, `ProtocolDataOffset` at 16 and
    /// `ProtocolDataLength` at 20 inside that.
    fn protocol_reply(offset: u32, length: u32, page: &[u8]) -> Vec<u8> {
        let mut out = vec![0u8; 8 + offset as usize + page.len()];
        out[8 + 16..8 + 20].copy_from_slice(&offset.to_le_bytes());
        out[8 + 20..8 + 24].copy_from_slice(&length.to_le_bytes());
        let start = 8 + offset as usize;
        out[start..start + page.len()].copy_from_slice(page);
        out
    }

    /// The offset is the driver's, not the request's. Hard-coding 48 here reads
    /// the right bytes only as long as every port driver echoes the request
    /// back, and the ones that do not would hand the parser its own zeroes.
    #[test]
    fn protocol_payload_follows_the_offset_the_driver_returned() {
        let mut page = [0u8; BUF_LEN];
        page[0] = 0x04; // critical warning: read only
        page[5] = 91; // percentage used
        let out = protocol_reply(40, 512, &page);
        let got = protocol_payload(&out).unwrap();
        assert_eq!(got[0], 0x04);
        assert_eq!(got[5], 91);

        // Same page, moved. Following the field rather than the constant is the
        // difference between reading it and reading zeroes.
        let shifted = protocol_reply(64, 512, &page);
        let got = protocol_payload(&shifted).unwrap();
        assert_eq!(got[5], 91, "the page moved and the offset field said so");
    }

    /// A port driver that answers with a shorter page must not have 512 bytes
    /// read out of it. The tail would be whatever the request buffer held.
    #[test]
    fn protocol_payload_refuses_a_short_page() {
        let out = protocol_reply(40, 64, &[0u8; BUF_LEN]);
        assert!(protocol_payload(&out).is_err());
    }

    #[test]
    fn protocol_payload_refuses_an_offset_past_the_reply() {
        let mut out = vec![0u8; 8 + 40 + BUF_LEN];
        out[8 + 16..8 + 20].copy_from_slice(&4000u32.to_le_bytes());
        out[8 + 20..8 + 24].copy_from_slice(&512u32.to_le_bytes());
        assert!(protocol_payload(&out).is_err());
    }

    /// A `STORAGE_DEVICE_DESCRIPTOR` laid out at the offsets the C struct has,
    /// written out here rather than taken from the `SDD_*` constants that read
    /// it. `DeviceType` and `RemovableMedia` are set independently and to
    /// different values, because they are two of the four single bytes between
    /// `Size` and `VendorIdOffset` and a read of the wrong one is invisible
    /// when both are zero.
    fn descriptor(device_type: u8, removable: bool, bus: i32, fields: &[(usize, &str)]) -> Vec<u8> {
        let mut out = vec![0u8; 256];
        let total = out.len() as u32;
        out[0..4].copy_from_slice(&1u32.to_le_bytes()); // Version
        out[4..8].copy_from_slice(&total.to_le_bytes()); // Size
        out[8] = device_type; // DeviceType
        out[9] = 0; // DeviceTypeModifier
        out[10] = removable as u8; // RemovableMedia
        out[11] = 1; // CommandQueueing
        out[28..32].copy_from_slice(&(bus as u32).to_le_bytes()); // BusType
        let mut cursor = 64usize;
        for (field, text) in fields {
            out[*field..*field + 4].copy_from_slice(&(cursor as u32).to_le_bytes());
            out[cursor..cursor + text.len()].copy_from_slice(text.as_bytes());
            cursor += text.len() + 1;
        }
        out
    }

    /// Each string comes from its own offset field. Asserting only that
    /// something parsed would not notice product and serial swapping places,
    /// and the serial is what keys the `disk` row.
    #[test]
    fn device_descriptor_reads_each_field_from_its_own_offset() {
        let out = descriptor(
            0x00,  // DeviceType: SCSI direct access
            false, // RemovableMedia
            17,    // BusTypeNvme
            &[
                (12, "ACME"),           // VendorIdOffset
                (16, "SSD 970"),        // ProductIdOffset
                (20, "2B2QEXM7"),       // ProductRevisionOffset
                (24, "S4EWNX0N123456"), // SerialNumberOffset
            ],
        );
        let id = parse_device_descriptor(&out).unwrap();
        assert_eq!(id.vendor, "ACME");
        assert_eq!(id.product, "SSD 970");
        assert_eq!(id.revision, "2B2QEXM7");
        assert_eq!(id.serial, "S4EWNX0N123456");
        assert_eq!(id.bus, "nvme");
        assert!(!id.removable);
    }

    /// `RemovableMedia` is at 10 and `DeviceType` at 8, and the two disagree on
    /// every case the flag exists for. Both directions are checked because
    /// reading `DeviceType` inverts the answer rather than losing it.
    #[test]
    fn removable_is_the_flag_not_the_device_type() {
        // A USB stick: SCSI direct access, removable media. `DeviceType` is 0
        // here, so reading it would call the one genuinely removable disk in
        // the fleet fixed.
        let stick = descriptor(0x00, true, 7, &[]);
        assert!(parse_device_descriptor(&stick).unwrap().removable);
        // An optical drive: DeviceType 5, and the unit itself is not removable.
        // Reading `DeviceType` would call it removable on the strength of being
        // a CD-ROM.
        let optical = descriptor(0x05, false, 3, &[]);
        assert!(!parse_device_descriptor(&optical).unwrap().removable);
    }

    /// A drive that answers no identity at all returns offset 0 for every
    /// string, which is absence and must not be read as the byte at offset 0.
    #[test]
    fn device_descriptor_treats_offset_zero_as_absent() {
        let out = descriptor(0x00, false, 7, &[]); // BusTypeUsb, nothing else answered
        let id = parse_device_descriptor(&out).unwrap();
        assert_eq!(id.serial, "");
        assert_eq!(id.product, "");
        assert_eq!(id.bus, "usb");
    }

    /// The buses that matter are the ones that explain a refusal: a USB bridge
    /// or a RAID member is expected to answer nothing, and the column is how the
    /// console says so.
    #[test]
    fn bus_names_match_the_column() {
        assert_eq!(bus_name(17), "nvme");
        assert_eq!(bus_name(11), "sata");
        assert_eq!(bus_name(3), "sata");
        assert_eq!(bus_name(10), "sas");
        assert_eq!(bus_name(7), "usb");
        assert_eq!(bus_name(8), "raid");
        assert_eq!(bus_name(16), "raid");
        assert_eq!(bus_name(0), "unknown");
        assert_eq!(bus_name(13), "unknown");
    }
}
