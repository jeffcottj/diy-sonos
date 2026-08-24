//! Legacy cleanup — mirrors `scripts/cleanup-legacy.sh:7-90`.

pub fn quarantine_alt_units_glob() -> &'static str {
    "/etc/systemd/system/*.service"
}

pub fn legacy_units() -> &'static [&'static str] {
    &["raspotify.service"]
}

pub fn conflicting_units_for_role(role: &str) -> Vec<&'static str> {
    match role {
        "server" => vec!["snapclient.service"],
        "client" => vec!["snapserver.service"],
        _ => vec![],
    }
}

pub fn mask_command(unit: &str) -> String {
    format!("systemctl mask {} 2>/dev/null || true", unit)
}

pub fn stop_command(unit: &str) -> String {
    format!("systemctl stop {} 2>/dev/null || true", unit)
}

/// Builds the sequence of shell commands for legacy cleanup for a given role.
/// These are executed via `exec_sudo` over SSH.
pub fn cleanup_commands(role: &str, is_combo: bool) -> Vec<String> {
    let mut cmds = Vec::new();
    // Report legacy units (for logging)
    for unit in legacy_units() {
        cmds.push(format!("systemctl list-unit-files | grep -q {} && echo 'legacy:{} exists' || echo 'legacy:{} not found'", unit, unit, unit));
    }
    // Role conflict policy
    let mut conflicts = conflicting_units_for_role(role);
    if is_combo && role == "client" {
        // Combo keeps snapserver running
        conflicts.retain(|u| *u != "snapserver.service");
    }
    for unit in conflicts {
        cmds.push(mask_command(unit));
        cmds.push(stop_command(unit));
    }
    // Quarantine alt units (find + mv to /var/lib/diy-sonos/quarantine)
    cmds.push(
        "mkdir -p /var/lib/diy-sonos/quarantine && find /etc/systemd/system -maxdepth 1 -type f -name '*.service' | while read unit; do case \"$unit\" in *librespot*|*snapserver*|*snapclient*|*raspotify*) ;; *) echo \"quarantine:$unit\"; mv \"$unit\" \"/var/lib/diy-sonos/quarantine/\" || true;; esac; done".to_string(),
    );
    // Handle legacy local binaries
    cmds.push(
        "if [ -f /usr/local/bin/snapserver ] || [ -f /usr/local/bin/snapclient ]; then echo 'legacy binary in /usr/local/bin'; rm -f /usr/local/bin/snapserver /usr/local/bin/snapclient || true; fi".to_string(),
    );
    cmds
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn server_masks_snapclient() {
        let cmds = cleanup_commands("server", false);
        assert!(cmds.iter().any(|c| c.contains("snapclient.service")));
        assert!(!cmds
            .iter()
            .any(|c| c.contains("mask snapserver.service") && c.contains("server")));
    }

    #[test]
    fn client_masks_snapserver_unless_combo() {
        let cmds = cleanup_commands("client", false);
        assert!(cmds.iter().any(|c| c.contains("snapserver.service")));
        let combo = cleanup_commands("client", true);
        assert!(!combo.iter().any(|c| c.contains("mask snapserver.service")));
    }

    #[test]
    fn legacy_units_list() {
        assert_eq!(legacy_units(), &["raspotify.service"]);
    }
}
