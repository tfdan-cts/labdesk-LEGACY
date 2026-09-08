// The per-adapter network view: the `net.adapters` attribute.
//
// The sampler's sysinfo fork (`labdesk-org/sysinfo`, branch `rlim_max`)
// offers a name, a MAC and the two byte counters per interface and nothing
// else, so link state and addresses come from the operating system here:
// `getifaddrs` on Linux and macOS through the `libc` that `hbb_common`
// re-exports, `operstate` from sysfs on Linux, `GetAdaptersAddresses` on
// Windows.
//
// The walk is the only unsafe code; `collect` is the pure fold over what it
// found and is what the tests drive.
//
// Which gate proves which arm. `.github/workflows/ci.yml` is the workflow that
// RUNS the tests and it builds Linux only (one uncommented matrix row), so it
// compiles nothing behind `#[cfg(target_os = "windows")]`; what it can assert
// about the Windows arm it asserts through `windows_kind`, which is free of
// `cfg` and carries the whole classification. The Windows arm is COMPILED by
// `.github/workflows/flutter-ci.yml` on every pull request, whose
// `flutter-build.yml` matrix carries `x86_64-pc-windows-msvc`,
// `i686-pc-windows-msvc` and `aarch64-pc-windows-msvc`; that workflow builds
// and does not test, so the call's behaviour is proven by running it on a
// Windows machine.

use hbb_common::sysinfo::Networks;
use std::collections::BTreeMap;

/// `machine_attr.value` is at most 4 KiB.
pub const VALUE_LIMIT: usize = 4096;
/// The netbird interface `src/labdesk/labnet.rs::netbird_args` names.
const OVERLAY_INTERFACE: &str = "labdesk0";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Address {
    pub addr: String,
    pub prefix: u8,
    pub family: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Adapter {
    pub name: String,
    pub up: bool,
    pub mac: String,
    pub addresses: Vec<Address>,
    pub rx_bytes: u64,
    pub tx_bytes: u64,
    pub kind: &'static str,
}

/// One `getifaddrs` entry, reduced to what the fold needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RawEntry {
    pub name: String,
    pub loopback: bool,
    /// Link state as the platform reports it for this entry.
    pub up: bool,
    pub physical: bool,
    pub address: Option<Address>,
}

/// Fold the entries (one per address, several per interface) into one
/// adapter per interface, loopback dropped, sorted by name, with the counters
/// and MAC from the sampler's `Networks`.
pub fn collect(entries: Vec<RawEntry>, counters: &BTreeMap<String, (String, u64, u64)>) -> Vec<Adapter> {
    let mut by_name: BTreeMap<String, Adapter> = BTreeMap::new();
    for entry in entries {
        if entry.loopback {
            continue;
        }
        let (mac, rx, tx) = counters
            .get(&entry.name)
            .cloned()
            .unwrap_or_else(|| (String::new(), 0, 0));
        let kind = if entry.name == OVERLAY_INTERFACE {
            "overlay"
        } else if entry.physical {
            "physical"
        } else {
            "other"
        };
        let adapter = by_name.entry(entry.name.clone()).or_insert_with(|| Adapter {
            name: entry.name.clone(),
            up: entry.up,
            mac,
            addresses: Vec::new(),
            rx_bytes: rx,
            tx_bytes: tx,
            kind,
        });
        if let Some(address) = entry.address {
            if !adapter.addresses.contains(&address) {
                adapter.addresses.push(address);
            }
        }
    }
    by_name.into_values().collect()
}

/// The attribute value: compact JSON, at most `VALUE_LIMIT` bytes. Over the
/// bound, adapters are dropped from the end of the (name-sorted) list until it
/// fits, so a machine with hundreds of veth interfaces still reports its first
/// ones rather than nothing.
pub fn to_value(adapters: &[Adapter]) -> String {
    let json = |list: &[Adapter]| {
        serde_json::Value::Array(
            list.iter()
                .map(|a| {
                    serde_json::json!({
                        "name": a.name,
                        "up": a.up,
                        "mac": a.mac,
                        "addresses": a.addresses.iter().map(|x| serde_json::json!({
                            "addr": x.addr, "prefix": x.prefix, "family": x.family,
                        })).collect::<Vec<_>>(),
                        "rxBytes": a.rx_bytes,
                        "txBytes": a.tx_bytes,
                        "kind": a.kind,
                    })
                })
                .collect(),
        )
        .to_string()
    };
    let mut keep = adapters.len();
    loop {
        let text = json(&adapters[..keep]);
        if text.len() <= VALUE_LIMIT || keep == 0 {
            return text;
        }
        keep -= 1;
    }
}

/// `value` with its byte counters zeroed: what "changed" means for the
/// attribute, since the counters move on every sample and would otherwise
/// make every flush a change. Computed from the value rather than the
/// adapters so that a list `to_value` cut at the bound compares against what
/// was actually sent.
pub fn shape_of_value(value: &str) -> String {
    let Ok(mut list) = serde_json::from_str::<serde_json::Value>(value) else {
        return value.to_owned();
    };
    if let Some(entries) = list.as_array_mut() {
        for entry in entries {
            entry["rxBytes"] = 0.into();
            entry["txBytes"] = 0.into();
        }
    }
    list.to_string()
}

/// The counters the sampler holds, keyed by interface name:
/// `(mac, rx_bytes, tx_bytes)`.
pub fn counters(networks: &Networks) -> BTreeMap<String, (String, u64, u64)> {
    networks
        .list()
        .iter()
        .map(|(name, data)| {
            (
                name.clone(),
                (
                    data.mac_address().to_string(),
                    data.total_received(),
                    data.total_transmitted(),
                ),
            )
        })
        .collect()
}

/// Every adapter, or `None` where this build cannot enumerate them.
pub fn adapters(networks: &Networks) -> Option<Vec<Adapter>> {
    let entries = walk()?;
    Some(collect(entries, &counters(networks)))
}

/// Untruncated interface prefixes for the service-owned LAN policy.
pub fn attached_lan_prefixes() -> Result<Vec<(std::net::IpAddr, u8)>, String> {
    walk().ok_or("Cannot enumerate LAN interfaces")?.into_iter()
        .filter(|entry| entry.up && !entry.loopback && entry.name != OVERLAY_INTERFACE)
        .filter_map(|entry| entry.address)
        .map(|address| address.addr.parse().map(|ip| (ip, address.prefix)).map_err(|_| "Invalid LAN interface address".into()))
        .collect()
}

pub fn prefix_v4(mask: u32) -> u8 {
    mask.count_ones() as u8
}

pub fn prefix_v6(mask: [u8; 16]) -> u8 {
    mask.iter().map(|b| b.count_ones() as u8).sum()
}

/// The `IfType` values the Windows walk classifies on, copied from
/// windows-0.61.1/src/Windows/Win32/NetworkManagement/IpHelper/mod.rs
/// (`IF_TYPE_ETHERNET_CSMACD` 6, `IF_TYPE_SOFTWARE_LOOPBACK` 24,
/// `IF_TYPE_IEEE80211` 71). The Windows walk asserts they are still the
/// crate's own values in `the_if_type_numbers_are_the_crates`.
pub const IF_TYPE_ETHERNET: u32 = 6;
pub const IF_TYPE_LOOPBACK: u32 = 24;
pub const IF_TYPE_WIFI: u32 = 71;

/// Windows: an adapter's `IfType` reduced to the two flags `RawEntry` carries,
/// `(loopback, physical)`. Written without `cfg` so the Linux-only CI asserts
/// the mapping even though it never compiles the call that feeds it.
///
/// `IfType` is what an adapter presents as, not what is behind it: a Hyper-V or
/// WSL virtual switch reports `IF_TYPE_ETHERNET_CSMACD` and reads `physical`
/// here, the same way a virtio interface does on Linux, where the test is a
/// `device` link in sysfs. `kind` is a hint the console shows beside the name,
/// and the name says which it is.
pub fn windows_kind(if_type: u32) -> (bool, bool) {
    (
        if_type == IF_TYPE_LOOPBACK,
        if_type == IF_TYPE_ETHERNET || if_type == IF_TYPE_WIFI,
    )
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
fn walk() -> Option<Vec<RawEntry>> {
    use hbb_common::libc;
    use std::net::{Ipv4Addr, Ipv6Addr};
    let mut head: *mut libc::ifaddrs = std::ptr::null_mut();
    if unsafe { libc::getifaddrs(&mut head) } != 0 {
        return None;
    }
    let mut entries = Vec::new();
    let mut cursor = head;
    while !cursor.is_null() {
        let entry = unsafe { &*cursor };
        cursor = entry.ifa_next;
        if entry.ifa_name.is_null() {
            continue;
        }
        let name = unsafe { std::ffi::CStr::from_ptr(entry.ifa_name) }
            .to_string_lossy()
            .into_owned();
        let flags = entry.ifa_flags as i32;
        let address = if entry.ifa_addr.is_null() {
            None
        } else {
            let family = unsafe { (*entry.ifa_addr).sa_family } as i32;
            if family == libc::AF_INET {
                let sa = unsafe { &*(entry.ifa_addr as *const libc::sockaddr_in) };
                let mask = if entry.ifa_netmask.is_null() {
                    0
                } else {
                    unsafe { (*(entry.ifa_netmask as *const libc::sockaddr_in)).sin_addr.s_addr }
                };
                Some(Address {
                    addr: Ipv4Addr::from(u32::from_be(sa.sin_addr.s_addr)).to_string(),
                    prefix: prefix_v4(u32::from_be(mask)),
                    family: "inet",
                })
            } else if family == libc::AF_INET6 {
                let sa = unsafe { &*(entry.ifa_addr as *const libc::sockaddr_in6) };
                let mask = if entry.ifa_netmask.is_null() {
                    [0u8; 16]
                } else {
                    unsafe { (*(entry.ifa_netmask as *const libc::sockaddr_in6)).sin6_addr.s6_addr }
                };
                Some(Address {
                    addr: Ipv6Addr::from(sa.sin6_addr.s6_addr).to_string(),
                    prefix: prefix_v6(mask),
                    family: "inet6",
                })
            } else {
                None
            }
        };
        entries.push(RawEntry {
            loopback: flags & libc::IFF_LOOPBACK != 0,
            up: link_up(&name, flags),
            physical: is_physical(&name),
            name,
            address,
        });
    }
    unsafe { libc::freeifaddrs(head) };
    Some(entries)
}

/// Linux: `operstate`, the kernel's own word on the link, except where the
/// kernel has no word to give.
///
/// `IFF_UP` alone is administrative and stays set on an unplugged cable, which
/// is why `operstate` is read first. But a driver that never calls
/// `netif_carrier_*` leaves `operstate` at `unknown`
/// (Documentation/networking/operstates.rst), and every tunnel on a machine is
/// one of those: `tailscale0`, `wg0`, `tun0` and the netbird interface all read
/// `unknown` while carrying traffic. Reading that as down reported the VPN
/// adapter of homebox-devserver as down on 2026-09-05 while this session was
/// talking to the machine over it, so `unknown` falls back to the
/// administrative flag, which is the only answer those drivers offer.
#[cfg(target_os = "linux")]
fn link_up(name: &str, flags: i32) -> bool {
    use hbb_common::libc;
    match std::fs::read_to_string(format!("/sys/class/net/{}/operstate", name)) {
        Ok(state) if state.trim() == "up" => true,
        Ok(state) if state.trim() == "unknown" => flags & libc::IFF_UP != 0,
        Ok(_) => false,
        Err(_) => flags & libc::IFF_UP != 0,
    }
}

/// macOS: administratively up and with a carrier.
#[cfg(target_os = "macos")]
fn link_up(_name: &str, flags: i32) -> bool {
    use hbb_common::libc;
    flags & libc::IFF_UP != 0 && flags & libc::IFF_RUNNING != 0
}

/// Linux: an interface with a `device` link has hardware behind it.
#[cfg(target_os = "linux")]
fn is_physical(name: &str) -> bool {
    std::path::Path::new(&format!("/sys/class/net/{}/device", name)).exists()
}

/// macOS: `en*` is the hardware family; `utun*`, `bridge*`, `awdl*` are not.
#[cfg(target_os = "macos")]
fn is_physical(name: &str) -> bool {
    name.starts_with("en")
}

/// Windows: `GetAdaptersAddresses`, the one call that carries link state, the
/// addresses and their prefix lengths together, so nothing here reconstructs a
/// mask the way the `getifaddrs` arm does.
///
/// The name is the adapter's `FriendlyName` and not its `AdapterName`, because
/// `FriendlyName` is the string the sampler's `Networks` is keyed by on
/// Windows: the vendored sysinfo fork builds its map from `MIB_IF_ROW2.Alias`
/// (`src/windows/network.rs` of the checkout under
/// `~/.cargo/git/checkouts/sysinfo-7cea62a9ad7b4e33`), which is the same
/// interface alias. `AdapterName` is the adapter GUID and would key every
/// adapter away from its byte counters.
#[cfg(target_os = "windows")]
fn walk() -> Option<Vec<RawEntry>> {
    use std::net::{Ipv4Addr, Ipv6Addr};
    use windows::Win32::Foundation::ERROR_BUFFER_OVERFLOW;
    use windows::Win32::NetworkManagement::IpHelper::{
        GetAdaptersAddresses, GAA_FLAG_SKIP_ANYCAST, GAA_FLAG_SKIP_DNS_SERVER,
        GAA_FLAG_SKIP_MULTICAST, IP_ADAPTER_ADDRESSES_LH,
    };
    use windows::Win32::NetworkManagement::Ndis::IfOperStatusUp;
    use windows::Win32::Networking::WinSock::{
        AF_INET, AF_INET6, AF_UNSPEC, SOCKADDR, SOCKADDR_IN, SOCKADDR_IN6,
    };

    unsafe fn address_of(sockaddr: *const SOCKADDR, prefix: u8) -> Option<Address> {
        if sockaddr.is_null() {
            return None;
        }
        let family = (*sockaddr).sa_family;
        if family == AF_INET {
            let sa = &*(sockaddr as *const SOCKADDR_IN);
            Some(Address {
                addr: Ipv4Addr::from(u32::from_be(sa.sin_addr.S_un.S_addr)).to_string(),
                prefix,
                family: "inet",
            })
        } else if family == AF_INET6 {
            let sa = &*(sockaddr as *const SOCKADDR_IN6);
            Some(Address {
                addr: Ipv6Addr::from(sa.sin6_addr.u.Byte).to_string(),
                prefix,
                family: "inet6",
            })
        } else {
            None
        }
    }

    // Anycast, multicast and DNS server lists are three chains this view never
    // reads; the friendly name is kept because it IS the name here.
    let flags = GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
    // The call writes the length it wanted back into `size` when the buffer was
    // short. Three attempts, because an adapter can appear between the sizing
    // and the read. `Vec<u64>` and not `Vec<u8>` because what the call writes
    // is a chain of structs that must land on an 8 byte boundary.
    let mut size: u32 = 16 * 1024;
    for _ in 0..3 {
        let mut buffer: Vec<u64> = vec![0; (size as usize + 7) / 8];
        let head = buffer.as_mut_ptr() as *mut IP_ADAPTER_ADDRESSES_LH;
        let code =
            unsafe { GetAdaptersAddresses(AF_UNSPEC.0 as u32, flags, None, Some(head), &mut size) };
        if code == ERROR_BUFFER_OVERFLOW.0 {
            continue;
        }
        if code != 0 {
            return None;
        }
        let mut entries = Vec::new();
        let mut cursor = head;
        while !cursor.is_null() {
            let adapter = unsafe { &*cursor };
            cursor = adapter.Next;
            if adapter.FriendlyName.is_null() {
                continue;
            }
            let Ok(name) = (unsafe { adapter.FriendlyName.to_string() }) else {
                continue;
            };
            let (loopback, physical) = windows_kind(adapter.IfType);
            let up = adapter.OperStatus == IfOperStatusUp;
            // The adapter itself first, so one holding no address is still
            // listed, the way the AF_PACKET entry lists it on Linux.
            entries.push(RawEntry {
                name: name.clone(),
                loopback,
                up,
                physical,
                address: None,
            });
            let mut unicast = adapter.FirstUnicastAddress;
            while !unicast.is_null() {
                let one = unsafe { &*unicast };
                unicast = one.Next;
                if let Some(address) =
                    unsafe { address_of(one.Address.lpSockaddr, one.OnLinkPrefixLength) }
                {
                    entries.push(RawEntry {
                        name: name.clone(),
                        loopback,
                        up,
                        physical,
                        address: Some(address),
                    });
                }
            }
        }
        return Some(entries);
    }
    None
}

/// Everything else: no enumeration, so the collector sends no `net.adapters`
/// at all rather than an empty list that would read as "no adapters".
#[cfg(not(any(target_os = "linux", target_os = "macos", target_os = "windows")))]
fn walk() -> Option<Vec<RawEntry>> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn entry(name: &str, up: bool, physical: bool, address: Option<Address>) -> RawEntry {
        RawEntry {
            name: name.to_owned(),
            loopback: name == "lo" || name == "lo0",
            up,
            physical,
            address,
        }
    }

    fn v4(addr: &str, prefix: u8) -> Address {
        Address { addr: addr.into(), prefix, family: "inet" }
    }

    fn v6(addr: &str, prefix: u8) -> Address {
        Address { addr: addr.into(), prefix, family: "inet6" }
    }

    #[test]
    fn entries_fold_into_one_adapter_per_interface_without_loopback() {
        let mut counters = BTreeMap::new();
        counters.insert("eno2".to_owned(), ("3c:ec:ef:d9:cc:ad".to_owned(), 156_122_012u64, 9_000u64));
        counters.insert("tailscale0".to_owned(), ("".to_owned(), 5u64, 6u64));
        counters.insert("lo".to_owned(), ("00:00:00:00:00:00".to_owned(), 1u64, 1u64));
        let adapters = collect(
            vec![
                // getifaddrs yields the AF_PACKET entry first, with no address.
                entry("tailscale0", false, false, None),
                entry("lo", true, false, Some(v4("127.0.0.1", 8))),
                entry("eno2", true, true, None),
                entry("eno2", true, true, Some(v4("10.1.10.110", 24))),
                entry("eno2", true, true, Some(v6("fe80::ab85:c576:989e:198b", 64))),
                entry("eno2", true, true, Some(v4("10.1.10.110", 24))),
                entry("tailscale0", false, false, Some(v4("100.89.139.104", 32))),
                entry("labdesk0", true, false, Some(v4("100.64.0.7", 16))),
            ],
            &counters,
        );
        assert_eq!(adapters.len(), 3, "loopback is dropped");
        assert_eq!(adapters[0].name, "eno2");
        assert_eq!(adapters[0].mac, "3c:ec:ef:d9:cc:ad");
        assert_eq!(adapters[0].rx_bytes, 156_122_012);
        assert_eq!(adapters[0].tx_bytes, 9_000);
        assert_eq!(adapters[0].kind, "physical");
        assert!(adapters[0].up);
        assert_eq!(
            adapters[0].addresses,
            vec![v4("10.1.10.110", 24), v6("fe80::ab85:c576:989e:198b", 64)],
            "a repeated address is listed once"
        );
        assert_eq!(adapters[1].name, "labdesk0");
        assert_eq!(adapters[1].kind, "overlay");
        assert_eq!(adapters[2].name, "tailscale0");
        assert_eq!(adapters[2].kind, "other");
        assert!(!adapters[2].up);
        assert_eq!(adapters[2].mac, "", "an interface the sampler has no MAC for");
    }

    #[test]
    fn the_value_is_the_contract_shape_and_stays_inside_the_column() {
        let adapters = vec![Adapter {
            name: "eth0".into(),
            up: true,
            mac: "aa:bb:cc:dd:ee:ff".into(),
            addresses: vec![v4("192.168.1.20", 24), v6("fe80::1", 64)],
            rx_bytes: 123456789,
            tx_bytes: 23456789,
            kind: "physical",
        }];
        let value: serde_json::Value = serde_json::from_str(&to_value(&adapters)).unwrap();
        assert_eq!(
            value,
            serde_json::json!([{
                "name": "eth0", "up": true, "mac": "aa:bb:cc:dd:ee:ff",
                "addresses": [
                    { "addr": "192.168.1.20", "prefix": 24, "family": "inet" },
                    { "addr": "fe80::1", "prefix": 64, "family": "inet6" }
                ],
                "rxBytes": 123456789, "txBytes": 23456789, "kind": "physical"
            }])
        );
        // Hundreds of veth interfaces: the value is cut at the column bound
        // by whole adapters from the end, and the first ones survive.
        let many: Vec<Adapter> = (0..400)
            .map(|n| Adapter {
                name: format!("veth{:04}", n),
                up: true,
                mac: "aa:bb:cc:dd:ee:ff".into(),
                addresses: vec![],
                rx_bytes: 0,
                tx_bytes: 0,
                kind: "other",
            })
            .collect();
        let value = to_value(&many);
        assert!(value.len() <= VALUE_LIMIT, "{}", value.len());
        let kept: Vec<serde_json::Value> = serde_json::from_str(&value).unwrap();
        assert!(kept.len() > 20 && kept.len() < 400);
        assert_eq!(kept[0]["name"], "veth0000");
        assert_eq!(to_value(&[]), "[]");
    }

    #[test]
    fn the_shape_ignores_the_counters_and_nothing_else() {
        let a = |rx: u64, up: bool| {
            vec![Adapter {
                name: "eth0".into(),
                up,
                mac: "aa".into(),
                addresses: vec![v4("10.0.0.1", 24)],
                rx_bytes: rx,
                tx_bytes: rx * 2,
                kind: "physical",
            }]
        };
        assert_eq!(shape_of_value(&to_value(&a(1, true))), shape_of_value(&to_value(&a(999, true))));
        assert_ne!(shape_of_value(&to_value(&a(1, true))), shape_of_value(&to_value(&a(1, false))));
        assert_eq!(shape_of_value("not json"), "not json");
    }

    #[test]
    fn prefixes_are_counted_from_the_masks() {
        assert_eq!(prefix_v4(0xFFFF_FF00), 24);
        assert_eq!(prefix_v4(0xFFFF_FFFF), 32);
        assert_eq!(prefix_v4(0), 0);
        let mut m = [0u8; 16];
        m[..8].fill(0xFF);
        assert_eq!(prefix_v6(m), 64);
        assert_eq!(prefix_v6([0xFF; 16]), 128);
    }

    /// The Windows classification, asserted on every platform because CI
    /// builds Linux only and would otherwise assert none of it.
    #[test]
    fn an_if_type_says_loopback_and_hardware() {
        assert_eq!(windows_kind(IF_TYPE_LOOPBACK), (true, false));
        assert_eq!(windows_kind(IF_TYPE_ETHERNET), (false, true), "an ethernet port");
        assert_eq!(windows_kind(IF_TYPE_WIFI), (false, true), "a wifi radio");
        // 53 is IF_TYPE_PROP_VIRTUAL, what a wintun overlay adapter reports:
        // neither loopback nor hardware, so `collect` calls it overlay or
        // other by its name.
        assert_eq!(windows_kind(53), (false, false));
        assert_eq!(windows_kind(0), (false, false));
    }

    /// The numbers above are the `windows` crate's own, checked where the
    /// crate is actually compiled.
    #[cfg(target_os = "windows")]
    #[test]
    fn the_if_type_numbers_are_the_crates() {
        use windows::Win32::NetworkManagement::IpHelper::{
            IF_TYPE_ETHERNET_CSMACD, IF_TYPE_IEEE80211, IF_TYPE_SOFTWARE_LOOPBACK,
        };
        assert_eq!(IF_TYPE_ETHERNET, IF_TYPE_ETHERNET_CSMACD);
        assert_eq!(IF_TYPE_LOOPBACK, IF_TYPE_SOFTWARE_LOOPBACK);
        assert_eq!(IF_TYPE_WIFI, IF_TYPE_IEEE80211);
    }

    /// The walk itself, on the CI runner: it must not fail, must drop
    /// loopback, and must find at least the runner's own interface.
    #[cfg(any(target_os = "linux", target_os = "macos", target_os = "windows"))]
    #[test]
    fn the_walk_finds_this_machines_interfaces() {
        let entries = walk().expect("getifaddrs answers");
        assert!(entries.iter().any(|e| e.loopback), "every host has a loopback");
        let adapters = collect(entries, &BTreeMap::new());
        assert!(adapters.iter().all(|a| a.name != "lo" && a.name != "lo0"));
        assert!(!adapters.is_empty());
    }
}
