//! Strict adapter for the pinned NetBird `networks list` text format.
//! Selection is daemon readback, not a claim about egress, DNS or firewall policy.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Route {
    pub id: String,
    pub networks: Vec<String>,
    pub selected: bool,
}
impl Route {
    pub fn is_exit(&self) -> bool {
        self.networks.iter().any(|n| n == "0.0.0.0/0" || n == "::/0")
    }
}
pub fn parse_routes(text: &str) -> Result<Vec<Route>, String> {
    if text.trim() == "No networks available." { return Ok(Vec::new()); }
    let mut lines = text.lines().map(str::trim).filter(|s| !s.is_empty());
    if lines.next() != Some("Available Networks:") { return Err("Unsupported route-list response".into()); }
    let mut routes = Vec::new();
    let mut pending: Option<(String, Option<Vec<String>>, Option<bool>)> = None;
    fn finish(p: Option<(String, Option<Vec<String>>, Option<bool>)>, routes: &mut Vec<Route>) -> Result<(), String> {
        if let Some((id, networks, selected)) = p {
            if routes.iter().any(|r| r.id == id) { return Err("Duplicate route identifier".into()); }
            routes.push(Route { id, networks: networks.ok_or("Missing route network")?, selected: selected.ok_or("Missing route status")? });
        }
        Ok(())
    }
    for line in lines {
        if let Some(id) = line.strip_prefix("- ID: ") {
            finish(pending.take(), &mut routes)?;
            if id.is_empty() || id.len() > 40 || id.chars().any(char::is_control) { return Err("Invalid route identifier".into()); }
            pending = Some((id.to_owned(), None, None));
        } else {
            let p = pending.as_mut().ok_or("Route entry without an identifier")?;
            if let Some(network) = line.strip_prefix("Network: ") {
                if p.1.is_some() { return Err("Duplicate network field".into()); }
                let prefixes: Vec<String> = network.split(", ").map(str::to_owned).collect();
                if prefixes.iter().any(|prefix| !valid_prefix(prefix)) { return Err("Invalid network prefix".into()); }
                p.1 = Some(prefixes);
            } else if line.starts_with("Domains: ") {
                if p.1.is_some() { return Err("Duplicate network field".into()); }
                p.1 = Some(Vec::new());
            } else if let Some(status) = line.strip_prefix("Status: ") {
                if p.2.is_some() { return Err("Duplicate status field".into()); }
                p.2 = Some(match status { "Selected" => true, "Not Selected" => false, _ => return Err("Unknown selection status".into()) });
            } else if !line.starts_with("Resolved IPs:") && !line.starts_with('[') {
                return Err("Unsupported route-list field".into());
            }
        }
    }
    finish(pending, &mut routes)?;
    Ok(routes)
}
fn valid_prefix(prefix: &str) -> bool {
    let Some((ip, bits)) = prefix.split_once('/') else { return false; };
    let Ok(ip) = ip.parse::<std::net::IpAddr>() else { return false; };
    bits.parse::<u8>().is_ok_and(|b| b <= if ip.is_ipv4() { 32 } else { 128 })
}
pub fn valid_exit_id(id: &str) -> bool {
    id.strip_prefix("ld-").is_some_and(|id| id.len() == 36 && id.bytes().enumerate().all(|(i, b)| if matches!(i, 8 | 13 | 18 | 23) { b == b'-' } else { b.is_ascii_hexdigit() }))
}
/// Only default routes are deselected. Subnet/domain selections are untouched.
/// Every argument is an exact daemon-returned ID and follows `--`.
pub fn selection_commands(routes: &[Route], desired: Option<&str>) -> Result<Vec<Vec<String>>, String> {
    if let Some(id) = desired {
        if !valid_exit_id(id) || !routes.iter().any(|r| r.id == id && r.is_exit()) { return Err("Authorized exit is unavailable in the daemon".into()); }
    }
    let mut commands = Vec::new();
    for route in routes.iter().filter(|r| r.is_exit() && r.selected && Some(r.id.as_str()) != desired) {
        commands.push(vec!["networks".into(), "deselect".into(), "--".into(), route.id.clone()]);
    }
    if let Some(id) = desired {
        if !routes.iter().any(|r| r.id == id && r.selected) {
            commands.push(vec!["networks".into(), "select".into(), "--append".into(), "--".into(), id.into()]);
        }
    }
    Ok(commands)
}
#[cfg(test)]
mod tests {
    use super::*;
    const ID: &str = "ld-00000000-0000-0000-0000-000000000001";
    fn routes() -> Vec<Route> { vec![Route { id: "subnet".into(), networks: vec!["10.0.0.0/24".into()], selected: true }, Route { id: ID.into(), networks: vec!["0.0.0.0/0".into(), "::/0".into()], selected: true }] }
    #[test] fn direct_preserves_subnets() { assert_eq!(selection_commands(&routes(), None).unwrap(), vec![vec!["networks", "deselect", "--", ID]]); }
    #[test] fn unavailable_exit_does_not_switch_to_direct() { assert!(selection_commands(&routes(), Some("ld-00000000-0000-0000-0000-000000000002")).is_err()); }
    #[test] fn rejects_cli_arguments_and_non_exit_routes() { for id in ["all", "--append", "subnet", "ld-../../arbitrary"] { assert!(selection_commands(&routes(), Some(id)).is_err()); } }
    #[test] fn selected_exit_is_noop() { assert!(selection_commands(&routes(), Some(ID)).unwrap().is_empty()); }
    #[test] fn parser_reads_paired_v4_v6_and_domain_routes() {
        let text = format!("Available Networks:\n\n  - ID: {ID}\n    Network: 0.0.0.0/0, ::/0\n    Status: Selected\n  - ID: office\n    Domains: example.test\n    Status: Not Selected\n    Resolved IPs: -\n");
        let parsed = parse_routes(&text).unwrap(); assert_eq!(parsed.len(), 2); assert!(parsed[0].is_exit()); assert!(!parsed[1].is_exit());
    }
    #[test] fn malformed_readback_fails_closed() { for text in ["unknown", "Available Networks:\n- ID: x\nStatus: Selected", "Available Networks:\n- ID: x\nNetwork: 0.0.0.0/0\nStatus: Maybe"] { assert!(parse_routes(text).is_err()); } }
}
