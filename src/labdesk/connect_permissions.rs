use serde_derive::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ConnectPermissions {
    pub version: u32,
    pub mode: String,
    pub capabilities: Vec<String>,
    pub revision: u64,
}

impl ConnectPermissions {
    pub fn accepts_login(&self, login: &hbb_common::message_proto::LoginRequest) -> bool {
        use hbb_common::message_proto::login_request;
        if !self.valid() { return false; }
        match login.union.as_ref() {
            Some(login_request::Union::FileTransfer(_)) => self.mode == "files",
            Some(login_request::Union::ViewCamera(_)) => self.mode == "camera",
            Some(login_request::Union::Terminal(_)) => {
                let admin = cfg!(target_os = "windows") && !login.os_login.username.trim().is_empty();
                if admin { self.mode == "terminal_admin" && self.allows("terminalAdmin") }
                else { self.mode == "terminal" }
            },
            Some(login_request::Union::PortForward(pf)) => self.mode == "tcp" || (self.mode == "rdp"
                && ((pf.host == "RDP" && pf.port == 0) || (matches!(pf.host.as_str(), "localhost" | "127.0.0.1" | "::1" | "") && pf.port == 3389))),
            None => self.mode == "desktop",
            Some(_) => false,
        }
    }

    pub fn allows(&self, capability: &str) -> bool {
        self.version == 1 && self.capabilities.iter().any(|c| c == capability)
    }

    pub fn valid(&self) -> bool {
        const CAPS: &[&str] = &["view", "control", "files", "clipboard", "audio", "camera", "terminal", "terminalAdmin", "rdp", "tunnel", "remotePrinter", "restart", "recording", "blockInput", "privacyMode", "remoteConfig"];
        self.version == 1 && self.capabilities.len() <= CAPS.len()
            && self.capabilities.iter().all(|c| CAPS.contains(&c.as_str()))
            && self.capabilities.iter().collect::<std::collections::HashSet<_>>().len() == self.capabilities.len()
            && (!self.allows("control") || self.allows("view"))
            && (!self.allows("terminalAdmin") || self.allows("terminal"))
            && match self.mode.as_str() {
                "desktop" => self.allows("view"), "files" => self.allows("files"),
                "camera" => self.allows("camera"), "terminal" => self.allows("terminal"),
                "terminal_admin" => self.allows("terminal") && self.allows("terminalAdmin"),
                "rdp" => self.allows("rdp"), "tcp" => self.allows("tunnel"), _ => false,
            }
    }
}

#[cfg(test)]
mod connect_permission_tests {
    use super::*;
    use hbb_common::message_proto::{LoginRequest, FileTransfer, PortForward, Terminal};
    fn permissions(mode: &str, caps: &[&str]) -> ConnectPermissions {
        ConnectPermissions { version: 1, mode: mode.into(), capabilities: caps.iter().map(|s| s.to_string()).collect(), revision: 1 }
    }
    #[test]
    fn connect_permissions_reject_mode_confusion_and_unknown_fields() {
        let desktop = permissions("desktop", &["view"]);
        let mut login = LoginRequest::new();
        assert!(desktop.accepts_login(&login));
        assert!(!desktop.allows("control"));
        login.set_file_transfer(FileTransfer::new());
        assert!(!desktop.accepts_login(&login));
        login.set_terminal(Terminal::new());
        assert!(!desktop.accepts_login(&login));
        assert!(!permissions("desktop", &["control"]).valid());
        assert!(!permissions("desktop", &["view", "view"]).valid());
        assert!(!permissions("desktop", &["view", "futurePower"]).valid());
        assert!(serde_json::from_str::<ConnectPermissions>(r#"{"version":1,"mode":"desktop","capabilities":["view"],"revision":1,"full":true}"#).is_err());
    }
    #[test]
    fn connect_permissions_rdp_never_becomes_arbitrary_forwarding() {
        let rdp = permissions("rdp", &["rdp"]);
        for (host, port, expected) in [("RDP", 0, true), ("127.0.0.1", 3389, true), ("localhost", 22, false), ("192.168.1.1", 3389, false), ("RDP", 22, false)] {
            let mut login = LoginRequest::new();
            let mut forward = PortForward::new(); forward.host = host.into(); forward.port = port;
            login.set_port_forward(forward);
            assert_eq!(rdp.accepts_login(&login), expected, "{}:{}", host, port);
        }
    }
    #[cfg(target_os = "windows")]
    #[test]
    fn connect_permissions_regular_terminal_cannot_select_admin_credentials() {
        let mut login = LoginRequest::new(); login.set_terminal(Terminal::new());
        login.os_login.mut_or_insert_default().username = "Administrator".into();
        assert!(!permissions("terminal", &["terminal"]).accepts_login(&login));
        assert!(permissions("terminal_admin", &["terminal", "terminalAdmin"]).accepts_login(&login));
    }
}
