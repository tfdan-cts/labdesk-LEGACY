use std::{net::{IpAddr, SocketAddr}, sync::atomic::{AtomicBool, Ordering}};
use hbb_common::{allow_err, config::{self, keys::*, option2bool, Config}, log, sleep, tokio};
use crate::server::{check_zombie, new as new_server, ConnectionMeta, ServerPtr};

static RESTART_REQUESTED: AtomicBool = AtomicBool::new(false);

/// Hosts LabDesk sessions over the network interface managed by Labnet.
pub struct NetworkService;

impl NetworkService {
    pub fn restart() {
        RESTART_REQUESTED.store(true, Ordering::SeqCst);
    }

    pub async fn start_all() {
        #[cfg(target_os = "windows")]
        if crate::platform::is_installed() && crate::is_server() {
            crate::updater::start_auto_update();
        }
        if config::is_outgoing_only() {
            std::future::pending::<()>().await;
        }
        check_zombie();
        let server = new_server();
        let host = server.clone();
        tokio::spawn(async move { direct_server(host).await; });
        #[cfg(target_os = "android")]
        let discoverable = true;
        #[cfg(not(any(target_os = "android", target_os = "ios")))]
        let discoverable = crate::platform::is_installed();
        if discoverable {
            std::thread::spawn(|| { allow_err!(crate::lan::start_listening()); });
        }
        #[cfg(target_os = "linux")]
        if crate::is_server() {
            crate::platform::linux_desktop_manager::start_xdesktop();
        }
        scrap::codec::test_av1();
        loop {
            if RESTART_REQUESTED.swap(false, Ordering::SeqCst)
                || option2bool("stop-service", &Config::get_option("stop-service"))
            {
                server.write().unwrap().close_connections();
            }
            sleep(1.).await;
        }
    }
}

fn get_direct_port() -> i32 {
    let mut port = Config::get_option("direct-access-port")
        .parse::<i32>()
        .unwrap_or(0);
    if port <= 0 {
        port = 21118;
    }
    port
}

/// labnet: how many times a literal bind is retried, one attempt a second, so
/// about a minute, before retries slow to every fifteen seconds. The interface
/// can return or a competing process can release the port without an option
/// change; only the first failure is logged.
const DIRECT_BIND_RETRIES: u32 = 60;

/// labnet: the direct listener serves this machine's overlay address alone, so
/// the option is taken only as a literal IPv4 address out of 100.64.0.0/10, the
/// range NetBird allocates overlay addresses from and the only range the console
/// ever writes here. A name would be resolved at bind time, and any other
/// address, including the IPv6 forms of one and mapped IPv4 above all, would
/// open the listener wider than the overlay while the console still reads on,
/// which is the thing binding to one address is there to prevent.
fn direct_bind_ip(bind: &str) -> Option<IpAddr> {
    let IpAddr::V4(ip) = bind.parse::<IpAddr>().ok()? else {
        return None;
    };
    let octets = ip.octets();
    if octets[0] != 100 || !(64..=127).contains(&octets[1]) {
        return None;
    }
    Some(IpAddr::V4(ip))
}

#[cfg(test)]
mod direct_bind_tests {
    use super::direct_bind_ip;

    #[test]
    fn direct_listener_refuses_missing_and_non_overlay_bind_addresses() {
        super::tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            for bind in ["", "0.0.0.0", "127.0.0.1", "10.0.105.10", "::", "::ffff:100.72.0.4", "example.com"] {
                assert!(super::listen_labnet(bind, 0).await.is_err(), "must not expose a session listener for {bind:?}");
            }
        });
    }

    #[test]
    fn only_a_literal_overlay_address_is_bound() {
        assert_eq!(
            direct_bind_ip("100.72.0.4").map(|ip| ip.to_string()),
            Some("100.72.0.4".to_owned())
        );
        assert_eq!(
            direct_bind_ip("100.64.0.3").map(|ip| ip.to_string()),
            Some("100.64.0.3".to_owned())
        );
        assert_eq!(
            direct_bind_ip("100.127.255.255").map(|ip| ip.to_string()),
            Some("100.127.255.255".to_owned())
        );
        assert_eq!(direct_bind_ip(""), None);
        assert_eq!(direct_bind_ip("this-machine.example.com"), None);
        assert_eq!(direct_bind_ip("100.72.0.4/16"), None);
        assert_eq!(direct_bind_ip("100.72.0.4:21118"), None);
        assert_eq!(direct_bind_ip("0.0.0.0"), None);
        assert_eq!(direct_bind_ip("127.0.0.1"), None);
        assert_eq!(direct_bind_ip("239.0.0.1"), None);
        assert_eq!(direct_bind_ip("192.168.1.20"), None);
        assert_eq!(direct_bind_ip("100.63.255.255"), None);
        assert_eq!(direct_bind_ip("100.128.0.1"), None);
        assert_eq!(direct_bind_ip("::"), None);
        assert_eq!(direct_bind_ip("fd00::4"), None);
        assert_eq!(direct_bind_ip("::ffff:0.0.0.0"), None);
        assert_eq!(direct_bind_ip("::ffff:100.72.0.4"), None);
        assert_eq!(direct_bind_ip("[::ffff:100.72.0.4]"), None);
        assert_eq!(direct_bind_ip("::ffff:6448:4"), None);
    }
}

async fn listen_labnet(bind: &str, port: u16) -> hbb_common::ResultType<tokio::net::TcpListener> {
    match direct_bind_ip(bind) {
        Some(ip) => hbb_common::tcp::new_listener(SocketAddr::new(ip, port), cfg!(unix)).await,
        None => Err(hbb_common::anyhow::anyhow!("not an address to bind: {}", bind)),
    }
}

async fn direct_server(server: ServerPtr) {
    let mut listener = None;
    let mut port = 0;
    // Serve the verified Labnet address only; missing addresses fail closed.
    let mut bind = String::new();
    // labnet: binds that have failed since the port or the address last changed.
    let mut failures = 0;
    loop {
        let disabled = !option2bool(
            OPTION_DIRECT_SERVER,
            &Config::get_option(OPTION_DIRECT_SERVER),
        ) || option2bool("stop-service", &Config::get_option("stop-service"))
            || Config::get_option("labdesk-labnet-enabled") == "N";
        if disabled {
            failures = 0;
        }
        if !disabled && listener.is_none() {
            let next_port = get_direct_port();
            let next_bind = Config::get_option("labdesk-direct-bind");
            if next_port != port || next_bind != bind {
                failures = 0;
            }
            port = next_port;
            bind = next_bind;
            // The reuse flag is what listen_any sets on this platform: reuseport
            // and reuseaddr on unix, nothing on windows, where reuseaddr would
            // let any other local process bind the same address and take the
            // connections meant for this listener.
            let bind_ip = direct_bind_ip(&bind);
            let listen = listen_labnet(&bind, port as u16).await;
            match listen {
                Ok(l) => {
                    failures = 0;
                    listener = Some(l);
                    log::info!(
                        "Direct server listening on: {:?}",
                        listener.as_ref().map(|l| l.local_addr())
                    );
                }
                Err(err) => {
                    failures += 1;
                    if failures == 1 {
                        // to-do: pass to ui
                        log::error!(
                            "Failed to start direct server on port: {}, error: {}",
                            port,
                            err
                        );
                    }
                    loop {
                        sleep(if bind_ip.is_some() && failures > DIRECT_BIND_RETRIES { 15. } else { 1. }).await;
                        if bind_ip.is_some()
                            || port != get_direct_port()
                            || bind != Config::get_option("labdesk-direct-bind")
                            || Config::get_option("labdesk-labnet-enabled") == "N"
                            || !option2bool(OPTION_DIRECT_SERVER, &Config::get_option(OPTION_DIRECT_SERVER))
                            || option2bool("stop-service", &Config::get_option("stop-service"))
                        {
                            break;
                        }
                    }
                }
            }
        }
        if let Some(l) = listener.as_mut() {
            if disabled
                || port != get_direct_port()
                || bind != Config::get_option("labdesk-direct-bind")
            {
                log::info!("Exit direct access listen");
                listener = None;
                continue;
            }
            if let Ok(Ok((stream, addr))) = hbb_common::timeout(1000, l.accept()).await {
                stream.set_nodelay(true).ok();
                log::info!("direct access from {}", addr);
                let local_addr = stream
                    .local_addr()
                    .unwrap_or(Config::get_any_listen_addr(true));
                let server = server.clone();
                // Labnet sessions always authenticate the peer key exchange.
                tokio::spawn(async move {
                    allow_err!(
                        crate::server::create_tcp_connection(
                            server,
                            hbb_common::Stream::from(stream, local_addr),
                            addr,
                            true,
                            ConnectionMeta::default(), // Direct connections don't have server-side user context.
                        )
                        .await
                    );
                });
            } else {
                sleep(0.1).await;
            }
        } else {
            sleep(1.).await;
        }
    }
}
