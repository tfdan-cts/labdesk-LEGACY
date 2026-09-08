//! Client-local LAN isolation. Only the privileged service calls this module.
//! Persistent WFP objects are the ownership ledger and survive service crashes.
use std::net::IpAddr;

pub fn prefixes(attached: Vec<(IpAddr, u8)>) -> Result<Vec<(IpAddr, u8)>, String> {
    let mut result = Vec::new();
    for value in [
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
        "169.254.0.0/16",
        "100.64.0.0/10",
        "fc00::/7",
        "fe80::/10",
    ] {
        let (ip, bits) = value.split_once('/').unwrap();
        result.push((ip.parse().unwrap(), bits.parse().unwrap()));
    }
    for (ip, bits) in attached {
        if bits == 0 || bits > if ip.is_ipv4() { 32 } else { 128 } {
            return Err("Invalid LAN prefix".into());
        }
        if !ip.is_loopback() && !ip.is_unspecified() {
            let network = match ip {
                IpAddr::V4(ip) => IpAddr::V4((u32::from(ip) & (u32::MAX << (32 - bits))).into()),
                IpAddr::V6(ip) => IpAddr::V6((u128::from(ip) & (u128::MAX << (128 - bits))).into()),
            };
            result.push((network, bits));
        }
    }
    result.sort();
    result.dedup();
    Ok(result)
}

#[cfg(windows)]
pub mod platform {
    use super::*;
    use std::{
        path::{Path, PathBuf},
        sync::{Mutex, Once},
        time::{Duration, Instant},
    };
    use windows::{
        core::{GUID, PCWSTR, PWSTR},
        Win32::{
            Foundation::{FWP_E_ALREADY_EXISTS, FWP_E_PROVIDER_NOT_FOUND, HANDLE},
            NetworkManagement::{
                IpHelper::ConvertInterfaceAliasToLuid, Ndis::NET_LUID_LH,
                WindowsFilteringPlatform::*,
            },
        },
    };
    const PROVIDER: GUID = GUID::from_u128(0x61ff0274_8437_4ac9_a36e_7095388210bd);
    const SUBLAYER: GUID = GUID::from_u128(0x92fdc5e9_3276_49e8_8442_f8ed193d1a40);

    // Serialized by ROUTING_OPERATION; the mutex also makes ownership explicit.
    static SESSION: Mutex<Option<Session>> = Mutex::new(None);
    struct Session {
        handle: usize,
        sublayer: GUID,
        ids: Vec<u64>,
        prefixes: Vec<(IpAddr, u8)>,
        executable: PathBuf,
        refreshed: Instant,
        interface: u64,
    }
    impl Session {
        fn handle(&self) -> HANDLE {
            HANDLE(self.handle as *mut _)
        }
        fn close(&mut self) -> Result<(), String> {
            if self.handle != 0 {
                check(unsafe { FwpmEngineClose0(self.handle()) })?;
                self.handle = 0;
            }
            Ok(())
        }
        fn verify(&self) -> Result<(), String> {
            if self.refreshed.elapsed() > Duration::from_secs(3) {
                return Err("LAN interface snapshot is stale".into());
            }
            for id in &self.ids {
                let mut filter = std::ptr::null_mut();
                check(unsafe { FwpmFilterGetById0(self.handle(), *id, &mut filter) })?;
                if filter.is_null() {
                    return Err("Missing LAN filter readback".into());
                }
                let valid = unsafe {
                    (*filter).filterId == *id
                        && owned(&*filter)
                        && (*filter).numFilterConditions == 3
                };
                unsafe { FwpmFreeMemory0(&mut filter as *mut _ as *mut _) };
                if !valid {
                    return Err("LAN filter readback mismatch".into());
                }
            }
            Ok(())
        }
    }
    impl Drop for Session {
        fn drop(&mut self) {
            let _ = self.close();
        }
    }
    fn check(status: u32) -> Result<(), String> {
        if status == 0 {
            Ok(())
        } else {
            Err(format!("Windows LAN filtering failed ({status})"))
        }
    }
    fn create(status: u32) -> Result<(), String> {
        if status == FWP_E_ALREADY_EXISTS.0 as u32 {
            Ok(())
        } else {
            check(status)
        }
    }
    fn owned(filter: &FWPM_FILTER0) -> bool {
        !filter.providerKey.is_null()
            && unsafe { *filter.providerKey == PROVIDER }
            && filter.subLayerKey == SUBLAYER
            && filter.action.r#type == FWP_ACTION_BLOCK
            && filter.flags.contains(FWPM_FILTER_FLAG_PERSISTENT)
    }
    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(Some(0)).collect()
    }

    /// Recover persisted restriction before starting a replacement VPN binary.
    /// This works without the broker or an already connected tunnel.
    pub fn recover_before_start(executable: &Path) -> Result<(), String> {
        let mut handle = HANDLE::default();
        check(unsafe { FwpmEngineOpen0(PCWSTR::null(), 10, None, None, &mut handle) })?;
        let mut provider = std::ptr::null_mut();
        let found = unsafe { FwpmProviderGetByKey0(handle, &PROVIDER, &mut provider) };
        if !provider.is_null() { unsafe { FwpmFreeMemory0(&mut provider as *mut _ as *mut _) }; }
        if found != 0 {
            let closed = check(unsafe { FwpmEngineClose0(handle) });
            if found == FWP_E_PROVIDER_NOT_FOUND.0 as u32 { return closed; }
            return check(found);
        }
        let existing = owned_ids(handle);
        let closed = check(unsafe { FwpmEngineClose0(handle) });
        let existing = existing?;
        closed?;
        if !existing.is_empty() {
            apply(
                true,
                executable,
                crate::labdesk::netview::attached_lan_prefixes()?,
            )?;
        }
        Ok(())
    }

    pub fn uninstall(service_name: &str) -> Result<(), String> {
        use windows_service::{
            service::{ServiceAccess, ServiceState},
            service_manager::{ServiceManager, ServiceManagerAccess},
        };
        let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
            .map_err(|e| e.to_string())?;
        match manager.open_service(
            service_name,
            ServiceAccess::STOP | ServiceAccess::QUERY_STATUS,
        ) {
            Ok(service) => {
                if service
                    .query_status()
                    .map_err(|e| e.to_string())?
                    .current_state
                    != ServiceState::Stopped
                {
                    service.stop().map_err(|e| e.to_string())?;
                    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
                    while service
                        .query_status()
                        .map_err(|e| e.to_string())?
                        .current_state
                        != ServiceState::Stopped
                    {
                        if std::time::Instant::now() >= deadline {
                            return Err(
                                "Stop the LabDesk service before removing client LAN isolation"
                                    .into(),
                            );
                        }
                        std::thread::sleep(std::time::Duration::from_millis(100));
                    }
                }
            }
            Err(windows_service::Error::Winapi(error)) if error.raw_os_error() == Some(1060) => {}
            Err(error) => return Err(error.to_string()),
        }

        let mut state = SESSION.lock().map_err(|_| "LAN filtering unavailable")?;
        let session = install(Path::new(""), Vec::new())?;
        let handle = session.handle();
        check(unsafe { FwpmTransactionBegin0(handle, 0) })?;
        check(unsafe { FwpmSubLayerDeleteByKey0(handle, &SUBLAYER) })?;
        check(unsafe { FwpmProviderDeleteByKey0(handle, &PROVIDER) })?;
        check(unsafe { FwpmTransactionCommit0(handle) })?;
        *state = None;
        Ok(())
    }

    pub fn apply(
        block: bool,
        executable: &Path,
        attached: Vec<(IpAddr, u8)>,
    ) -> Result<bool, String> {
        let mut state = SESSION.lock().map_err(|_| "LAN filtering unavailable")?;
        let result = apply_locked(&mut state, block, executable, attached);
        static WATCH: Once = Once::new();
        if result == Ok(true) {
            WATCH.call_once(|| {
                std::thread::spawn(|| loop {
                    std::thread::sleep(Duration::from_secs(1));
                    if let Ok(mut state) = SESSION.lock() {
                        let Some(session) = state.as_ref() else {
                            continue;
                        };
                        let executable = session.executable.clone();
                        if let Ok(attached) = crate::labdesk::netview::attached_lan_prefixes() {
                            let _ = apply_locked(&mut state, true, &executable, attached);
                        }
                    }
                });
            });
        }
        result
    }
    fn apply_locked(
        state: &mut Option<Session>,
        block: bool,
        executable: &Path,
        attached: Vec<(IpAddr, u8)>,
    ) -> Result<bool, String> {
        if !block {
            // Enumeration of our persistent provider recovers after a service or OS restart.
            install(executable, Vec::new())?;
            *state = None;
            return Ok(false);
        }
        let wanted = prefixes(attached)?;
        if let Some(session) = state.as_mut() {
            if session.prefixes == wanted
                && session.executable == executable
                && session.interface == tunnel_interface()
            {
                session.refreshed = Instant::now();
                session.verify()?;
                return Ok(true);
            }
        }
        // The WFP transaction atomically replaces only our persistent filters.
        let session = install(executable, wanted)?;
        *state = Some(session);
        Ok(true)
    }

    fn tunnel_interface() -> u64 {
        let alias = wide("labdesk0");
        let mut luid = NET_LUID_LH::default();
        // No adapter excludes no interface. This retains a stricter restriction
        // during upgrade/startup; the watcher replaces it when the adapter appears.
        let result = unsafe { ConvertInterfaceAliasToLuid(PCWSTR(alias.as_ptr()), &mut luid) };
        if result.0 == 0 {
            unsafe { luid.Value }
        } else {
            0
        }
    }

    fn install(executable: &Path, prefixes: Vec<(IpAddr, u8)>) -> Result<Session, String> {
        let mut interface = tunnel_interface();
        let name = wide("LabDesk client LAN isolation");
        let config = FWPM_SESSION0 {
            displayData: FWPM_DISPLAY_DATA0 {
                name: PWSTR(name.as_ptr() as *mut _),
                ..Default::default()
            },
            ..Default::default()
        };
        let mut handle = HANDLE::default();
        check(unsafe { FwpmEngineOpen0(PCWSTR::null(), 10, None, Some(&config), &mut handle) })?;
        let mut session = Session {
            handle: handle.0 as usize,
            sublayer: SUBLAYER,
            ids: Vec::new(),
            prefixes,
            executable: executable.into(),
            refreshed: Instant::now(),
            interface,
        };
        check(unsafe { FwpmTransactionBegin0(handle, 0) })?;
        let mut provider_id = PROVIDER;
        let provider = FWPM_PROVIDER0 {
            providerKey: provider_id,
            flags: FWPM_PROVIDER_FLAG_PERSISTENT,
            displayData: FWPM_DISPLAY_DATA0 {
                name: PWSTR(name.as_ptr() as *mut _),
                ..Default::default()
            },
            ..Default::default()
        };
        create(unsafe { FwpmProviderAdd0(handle, &provider, None) })?;
        let sublayer = FWPM_SUBLAYER0 {
            subLayerKey: session.sublayer,
            providerKey: &mut provider_id,
            flags: FWPM_SUBLAYER_FLAG_PERSISTENT,
            displayData: FWPM_DISPLAY_DATA0 {
                name: PWSTR(name.as_ptr() as *mut _),
                ..Default::default()
            },
            weight: u16::MAX,
            ..Default::default()
        };
        create(unsafe { FwpmSubLayerAdd0(handle, &sublayer, None) })?;
        let old = owned_ids(handle)?;
        let path = wide(executable.to_str().ok_or("Invalid VPN executable path")?);
        let mut app = std::ptr::null_mut();
        if !session.prefixes.is_empty() {
            check(unsafe { FwpmGetAppIdFromFileName0(PCWSTR(path.as_ptr()), &mut app) })?;
        }
        let install_result: Result<(), String> = (|| {
            for &(address, bits) in &session.prefixes {
                let mut v4 = FWP_V4_ADDR_AND_MASK::default();
                let mut v6 = FWP_V6_ADDR_AND_MASK::default();
                let remote = match address {
                    IpAddr::V4(ip) => {
                        v4.addr = u32::from(ip);
                        v4.mask = u32::MAX << (32 - bits);
                        FWP_CONDITION_VALUE0 {
                            r#type: FWP_V4_ADDR_MASK,
                            Anonymous: FWP_CONDITION_VALUE0_0 {
                                v4AddrMask: &mut v4,
                            },
                        }
                    }
                    IpAddr::V6(ip) => {
                        v6.addr = ip.octets();
                        v6.prefixLength = bits;
                        FWP_CONDITION_VALUE0 {
                            r#type: FWP_V6_ADDR_MASK,
                            Anonymous: FWP_CONDITION_VALUE0_0 {
                                v6AddrMask: &mut v6,
                            },
                        }
                    }
                };
                let mut conditions = [
                    FWPM_FILTER_CONDITION0 {
                        fieldKey: FWPM_CONDITION_IP_REMOTE_ADDRESS,
                        matchType: FWP_MATCH_EQUAL,
                        conditionValue: remote,
                    },
                    FWPM_FILTER_CONDITION0 {
                        fieldKey: FWPM_CONDITION_IP_LOCAL_INTERFACE,
                        matchType: FWP_MATCH_NOT_EQUAL,
                        conditionValue: FWP_CONDITION_VALUE0 {
                            r#type: FWP_UINT64,
                            Anonymous: FWP_CONDITION_VALUE0_0 {
                                uint64: &mut interface,
                            },
                        },
                    },
                    FWPM_FILTER_CONDITION0 {
                        fieldKey: FWPM_CONDITION_ALE_APP_ID,
                        matchType: FWP_MATCH_NOT_EQUAL,
                        conditionValue: FWP_CONDITION_VALUE0 {
                            r#type: FWP_BYTE_BLOB_TYPE,
                            Anonymous: FWP_CONDITION_VALUE0_0 { byteBlob: app },
                        },
                    },
                ];
                for layer in if address.is_ipv4() {
                    [
                        FWPM_LAYER_ALE_AUTH_CONNECT_V4,
                        FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
                    ]
                } else {
                    [
                        FWPM_LAYER_ALE_AUTH_CONNECT_V6,
                        FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
                    ]
                } {
                    let filter = FWPM_FILTER0 {
                        providerKey: &mut provider_id,
                        flags: FWPM_FILTER_FLAG_PERSISTENT,
                        displayData: FWPM_DISPLAY_DATA0 {
                            name: PWSTR(name.as_ptr() as *mut _),
                            ..Default::default()
                        },
                        subLayerKey: session.sublayer,
                        layerKey: layer,
                        numFilterConditions: conditions.len() as u32,
                        filterCondition: conditions.as_mut_ptr(),
                        action: FWPM_ACTION0 {
                            r#type: FWP_ACTION_BLOCK,
                            ..Default::default()
                        },
                        ..Default::default()
                    };
                    let mut id = 0;
                    check(unsafe { FwpmFilterAdd0(handle, &filter, None, Some(&mut id)) })?;
                    session.ids.push(id);
                }
            }
            session.verify()?;
            for id in old {
                check(unsafe { FwpmFilterDeleteById0(handle, id) })?;
            }
            check(unsafe { FwpmTransactionCommit0(handle) })?;
            session.verify()?;
            let actual = owned_ids(handle)?;
            if actual.len() != session.ids.len()
                || actual.iter().any(|id| !session.ids.contains(id))
            {
                return Err("LAN filter set did not match readback".into());
            }
            Ok(())
        })();
        if !app.is_null() {
            unsafe { FwpmFreeMemory0(&mut app as *mut _ as *mut _) };
        }
        install_result?;
        Ok(session)
    }

    fn owned_ids(handle: HANDLE) -> Result<Vec<u64>, String> {
        let mut ids = Vec::new();
        let mut provider = PROVIDER;
        for layer in [
            FWPM_LAYER_ALE_AUTH_CONNECT_V4,
            FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V4,
            FWPM_LAYER_ALE_AUTH_CONNECT_V6,
            FWPM_LAYER_ALE_AUTH_RECV_ACCEPT_V6,
        ] {
            let template = FWPM_FILTER_ENUM_TEMPLATE0 {
                providerKey: &mut provider,
                layerKey: layer,
                actionMask: u32::MAX,
                ..Default::default()
            };
            let mut enumeration = HANDLE::default();
            check(unsafe {
                FwpmFilterCreateEnumHandle0(handle, Some(&template), &mut enumeration)
            })?;
            let result: Result<(), String> = (|| {
                loop {
                    let mut entries = std::ptr::null_mut();
                    let mut count = 0;
                    check(unsafe {
                        FwpmFilterEnum0(handle, enumeration, 256, &mut entries, &mut count)
                    })?;
                    if count != 0 && entries.is_null() {
                        return Err("Invalid LAN filter enumeration".into());
                    }
                    if count > 0 {
                        for pointer in
                            unsafe { std::slice::from_raw_parts(entries, count as usize) }
                        {
                            if !pointer.is_null() && owned(unsafe { &**pointer }) {
                                ids.push(unsafe { (**pointer).filterId });
                            }
                        }
                    }
                    if !entries.is_null() {
                        unsafe { FwpmFreeMemory0(&mut entries as *mut _ as *mut _) };
                    }
                    if count < 256 {
                        break;
                    }
                }
                Ok(())
            })();
            let closed = check(unsafe { FwpmFilterDestroyEnumHandle0(handle, enumeration) });
            result?;
            closed?;
        }
        Ok(ids)
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        #[test]
        fn cleanup_requires_exact_durable_ownership() {
            let mut provider = PROVIDER;
            let mut filter = FWPM_FILTER0 {
                providerKey: &mut provider,
                subLayerKey: SUBLAYER,
                flags: FWPM_FILTER_FLAG_PERSISTENT,
                action: FWPM_ACTION0 {
                    r#type: FWP_ACTION_BLOCK,
                    ..Default::default()
                },
                ..Default::default()
            };
            assert!(owned(&filter));
            filter.providerKey = std::ptr::null_mut();
            assert!(!owned(&filter));
            filter.providerKey = &mut provider;
            filter.subLayerKey = FWPM_SUBLAYER_UNIVERSAL;
            assert!(!owned(&filter));
            filter.subLayerKey = SUBLAYER;
            filter.flags = FWPM_FILTER_FLAGS(0);
            assert!(!owned(&filter));
            filter.flags = FWPM_FILTER_FLAG_PERSISTENT;
            filter.action.r#type = FWP_ACTION_PERMIT;
            assert!(!owned(&filter));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn covers_private_v4_v6_and_public_attached_networks() {
        let attached = ("8.4.2.3".parse().unwrap(), 24);
        let values = prefixes(vec![attached, attached]).unwrap();
        assert!(values.contains(&("10.0.0.0".parse().unwrap(), 8)));
        assert!(values.contains(&("fc00::".parse().unwrap(), 7)));
        assert_eq!(
            values
                .iter()
                .filter(|v| **v == ("8.4.2.0".parse().unwrap(), 24))
                .count(),
            1
        );
    }
    #[test]
    fn rejects_default_routes_and_invalid_prefixes() {
        for (ip, bits) in [("1.2.3.4", 0), ("1.2.3.4", 33), ("fd00::1", 129)] {
            assert!(prefixes(vec![(ip.parse().unwrap(), bits)]).is_err());
        }
    }
}
