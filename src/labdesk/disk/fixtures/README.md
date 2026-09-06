# Disk health byte fixtures

These are the raw buffers a platform call returns, committed so the pure parsers
in `../{ata,nvme,verdict}.rs` can be tested on a CI runner that has no disks and
no privileges.

Every byte here was **constructed programmatically**, not pasted from a hex dump.
The builders live in `ata::fixture` and `nvme::fixture` (both `#[cfg(test)]`), and
the test `fixtures_match_builders` in each of those files fails if a committed
file and its builder ever drift apart. Regenerate with:

```
LABDESK_WRITE_FIXTURES=1 cargo test -p rustdesk labdesk::disk::write_fixtures
```

The values are realistic rather than captured: none of them came off a specific
serial number, so nothing here identifies a machine, and every field below is
accounted for.

## `ata_attrs_healthy.bin` (512 bytes)

A SMART READ_ATTRIBUTES (0xD0) buffer from a healthy SATA hard disk: no
reallocations, no pending sectors, 34 C, roughly a year of power-on time.

Data structure revision `0x0010`. Eleven attribute slots populated, the remaining
nineteen left as zeros (an id of 0 means the slot is unused):

| id  | name                    | flags  | current | worst | raw           |
|-----|-------------------------|--------|---------|-------|---------------|
| 1   | Raw_Read_Error_Rate     | 0x000F | 118     | 99    | 176,512,004   |
| 5   | Reallocated_Sector_Ct   | 0x0033 | 100     | 100   | 0             |
| 9   | Power_On_Hours          | 0x0032 | 89      | 89    | 9,874         |
| 12  | Power_Cycle_Count       | 0x0032 | 100     | 100   | 412           |
| 187 | Reported_Uncorrect      | 0x0032 | 100     | 100   | 0             |
| 190 | Airflow_Temperature_Cel | 0x0022 | 66      | 51    | 34            |
| 196 | Reallocated_Event_Count | 0x0032 | 100     | 100   | 0             |
| 197 | Current_Pending_Sector  | 0x0012 | 100     | 100   | 0             |
| 198 | Offline_Uncorrectable   | 0x0010 | 100     | 100   | 0             |
| 199 | UDMA_CRC_Error_Count    | 0x003E | 200     | 200   | 0             |
| 194 | Temperature_Celsius     | 0x0022 | 34      | 49    | 0x0031001C0022 |

The two temperature attributes deliberately use different vendor encodings, so
the parser is tested against both: 190 puts 34 C in byte 0 and nothing else,
while 194 uses the three 16 bit word layout (current 34, minimum 28, maximum 49).
The raw field is 48 bits little endian in both cases.

Trailer, the fields a drive fills in after the attribute table:

| offset  | value  | meaning                                            |
|---------|--------|----------------------------------------------------|
| 362     | 0x00   | offline data collection status: never started      |
| 363     | 0x00   | self test execution status: no error, none running |
| 364..366| 675    | seconds for offline data collection                |
| 367     | 0x5B   | offline data collection capability bits            |
| 368..370| 0x0003 | SMART capability                                   |
| 370     | 0x01   | error logging capability: supported                |
| 372     | 1      | short self test, minutes                           |
| 373     | 0xFF   | extended self test does not fit a byte, see 375    |
| 374     | 2      | conveyance self test, minutes                      |
| 375..377| 465    | extended self test, minutes                        |
| 511     | -      | checksum, written so the 512 bytes sum to 0 mod 256 |

Every other byte is zero.

## `ata_attrs_failing.bin` (512 bytes)

The same drive after a head crash. Same layout and the same trailer; only the
attribute values differ:

| id  | name                    | flags  | current | worst | raw            |
|-----|-------------------------|--------|---------|-------|----------------|
| 1   | Raw_Read_Error_Rate     | 0x000F | 71      | 63    | 12,884,901,888 |
| 5   | Reallocated_Sector_Ct   | 0x0033 | 8       | 8     | 1,296          |
| 9   | Power_On_Hours          | 0x0032 | 52      | 52    | 41,233         |
| 12  | Power_Cycle_Count       | 0x0032 | 100     | 100   | 1,207          |
| 187 | Reported_Uncorrect      | 0x0032 | 100     | 100   | 96             |
| 190 | Airflow_Temperature_Cel | 0x0022 | 59      | 44    | 41             |
| 196 | Reallocated_Event_Count | 0x0032 | 100     | 100   | 37             |
| 197 | Current_Pending_Sector  | 0x0012 | 100     | 100   | 24             |
| 198 | Offline_Uncorrectable   | 0x0010 | 100     | 100   | 24             |
| 199 | UDMA_CRC_Error_Count    | 0x003E | 200     | 200   | 3              |
| 194 | Temperature_Celsius     | 0x0022 | 41      | 51    | 41             |

Attribute 1 carries a raw of 12,884,901,888 (0x300000000) on purpose: it needs
more than 32 bits, so a parser that read the raw field as a u32 would lose it.

What makes this fixture a `failing` verdict rather than a `warn` is attribute 5:
1,296 reallocated sectors with a normalised value of 8 against the threshold of
36 published in `ata_thresholds.bin`. Without that threshold table the same
buffer is only a `warn`, which is a case the verdict tests cover.

## `ata_thresholds.bin` (512 bytes)

A SMART READ_THRESHOLDS (0xD1) buffer for the two tables above. Same
revision `0x0010`, same slot order, entry layout is id then threshold then ten
reserved bytes, and byte 511 is again the checksum.

| id  | 1  | 5  | 9 | 12 | 187 | 190 | 196 | 197 | 198 | 199 | 194 |
|-----|----|----|---|----|-----|-----|-----|-----|-----|-----|-----|
| thr | 44 | 36 | 0 | 20 | 0   | 45  | 0   | 0   | 0   | 0   | 0   |

The zeros are real answers, not gaps. A threshold of 0 means the attribute can
never fail, per ATA-8, which is why 197 and 198 cannot on their own produce a
`failing` verdict on a real drive.

## `nvme_health_ok.bin` (512 bytes)

A SMART / Health Information log page (log identifier 02h) from a healthy 1 TB
consumer NVMe SSD.

| offset  | field                          | value                     |
|---------|--------------------------------|---------------------------|
| 0       | Critical Warning               | 0x00, no bits set         |
| 1..3    | Composite Temperature          | 311 K, which is 38 C      |
| 3       | Available Spare                | 100 percent               |
| 4       | Available Spare Threshold      | 10 percent                |
| 5       | Percentage Used                | 3                         |
| 6..32   | reserved                       | zero                      |
| 32..48  | Data Units Read                | 45,678,901                |
| 48..64  | Data Units Written             | 23,456,789, so 12,009 GB  |
| 64..80  | Host Read Commands             | 987,654,321               |
| 80..96  | Host Write Commands            | 456,789,012               |
| 96..112 | Controller Busy Time           | 5,432 minutes             |
| 112..128| Power Cycles                   | 412                       |
| 128..144| Power On Hours                 | 9,874                     |
| 144..160| Unsafe Shutdowns               | 37                        |
| 160..176| Media and Data Integrity Errors| 0                         |
| 176..192| Error Information Log Entries  | 12                        |
| 192..196| Warning Composite Temp Time    | 0 minutes                 |
| 196..200| Critical Composite Temp Time   | 0 minutes                 |
| 200..216| Temperature Sensors 1..8       | 311 K, 318 K, rest 0      |
| 216..512| reserved                       | zero                      |

Every counter from offset 32 to 192 is 128 bits little endian. This log page has
no checksum.

## `nvme_health_failing.bin` (512 bytes)

The same page from a drive that is failing.

| offset  | field                          | value                                          |
|---------|--------------------------------|------------------------------------------------|
| 0       | Critical Warning               | 0x05: bit 0 spare below threshold, bit 2 reliability degraded |
| 1..3    | Composite Temperature          | 347 K, which is 74 C                           |
| 3       | Available Spare                | 3 percent                                      |
| 4       | Available Spare Threshold      | 10 percent                                     |
| 5       | Percentage Used                | 100                                            |
| 32..48  | Data Units Read                | 812,345,678                                    |
| 48..64  | Data Units Written             | 400,000,000, so 204,800 GB                     |
| 64..80  | Host Read Commands             | 9,876,543,210                                  |
| 80..96  | Host Write Commands            | 8,765,432,109                                  |
| 96..112 | Controller Busy Time           | 512,345 minutes                                |
| 112..128| Power Cycles                   | 1,207                                          |
| 128..144| Power On Hours                 | 43,800                                         |
| 144..160| Unsafe Shutdowns               | 96                                             |
| 160..176| Media and Data Integrity Errors| 1,284                                          |
| 176..192| Error Information Log Entries  | 4,211                                          |
| 192..196| Warning Composite Temp Time    | 8,640 minutes                                  |
| 196..200| Critical Composite Temp Time   | 613 minutes                                    |
| 200..216| Temperature Sensors 1..8       | 347 K, 351 K, rest 0                           |

Two independent conditions make this `failing`: the critical warning bits, and
available spare below the drive's own threshold. The tests assert both appear in
the reason, so removing either rule is caught.

## `malformed_short.bin` (100 bytes)

The first 100 bytes of `ata_attrs_healthy.bin`. This is the shape of a short
read: a USB bridge or RAID controller that accepts the command and then answers
with less than the 512 bytes it promised. Both ATA parsers and the NVMe parser
must return `TooShort` for it, and the verdict must be `unreadable`.

## `malformed_zeros.bin` (512 bytes)

512 zero bytes: the output buffer exactly as the caller zeroed it, which is what
an ioctl that failed without saying so leaves behind. It is the right length and
carries no reading, so the parsers return `Empty`.

This is the fixture that matters most. Read as data it says "0 reallocated
sectors, no critical warnings", which would render as a perfectly healthy drive.
It must produce `unreadable` instead, and it must not panic.

## Captured from real hardware, 2026-09-05

Two buffers below are the exception to "constructed programmatically": they were
read off drives on homebox-devserver (Lubuntu 26.04, kernel 7.0.0-30) by a
harness that compiled this directory verbatim and ran `linux::nvme_health_page`
and `linux::ata_smart_table` as root. Neither structure carries a serial number;
the drive identity lives in `/sys` and is not here. The raw capture, with the
harness source hashes, is in the phase 1 evidence directory of that session
(`gauntlet-evidence/p1-rust-core/round-1/homebox-disk-harness.txt`).

### `nvme_health_micron3400.bin` (512 bytes)

Log page 02h from a Micron 3400 MTFDKBA512TFH (firmware P7MU002) over
`NVME_IOCTL_ADMIN_CMD`. Composite temperature 300 K (27 C), spare 100 percent
against a threshold of 5, 1 percent used, 4,500 power-on hours, 36 power cycles,
25 unsafe shutdowns, 8,367,439 data units written (4,284 GB), no media errors,
no critical warning. Asserted field by field by `nvme::tests::reads_a_real_micron_page`.

### `ata_attrs_st1000vx008.bin` (512 bytes)

SMART READ_ATTRIBUTES from a Seagate ST1000VX008-2AY1 (firmware CV11) over
`SG_IO` with the ATA PASS-THROUGH(16) CDB in `linux.rs`. Twenty five attributes,
checksum valid. The one this capture exists for is attribute 9: the drive
reports `6a b8 00 00 4e 41`, and the upper two bytes changed between two reads
seconds apart, which is why `ata::summarize` now takes the low 24 bits (47,210
hours) and not the 48 bit value (71 trillion). Asserted by
`ata::tests::reads_a_real_seagate_table`.
