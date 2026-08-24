use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CheckStatus {
    Pass,
    Fail,
    Warn,
    Info,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckResult {
    pub status: CheckStatus,
    pub message: String,
    pub explanation: Option<String>,
    pub remediation: Option<String>,
}

impl CheckResult {
    pub fn pass(msg: impl Into<String>) -> Self {
        Self {
            status: CheckStatus::Pass,
            message: msg.into(),
            explanation: None,
            remediation: None,
        }
    }
    pub fn fail(
        msg: impl Into<String>,
        explanation: impl Into<String>,
        remediation: impl Into<String>,
    ) -> Self {
        Self {
            status: CheckStatus::Fail,
            message: msg.into(),
            explanation: Some(explanation.into()),
            remediation: Some(remediation.into()),
        }
    }
    pub fn warn(
        msg: impl Into<String>,
        explanation: impl Into<String>,
        remediation: impl Into<String>,
    ) -> Self {
        Self {
            status: CheckStatus::Warn,
            message: msg.into(),
            explanation: Some(explanation.into()),
            remediation: Some(remediation.into()),
        }
    }
}

/// Pure checks ported from `common.sh:731-905` doctor helpers.
/// Each check takes pre-fetched command outputs (so tests can inject fixtures without SSH).
pub fn check_service_installed(service: &str, list_units_output: &str) -> CheckResult {
    let needle = format!("{}.service", service);
    if list_units_output
        .lines()
        .any(|l| l.split_whitespace().next() == Some(&needle))
    {
        CheckResult::pass(format!("{}.service is installed", service))
    } else {
        CheckResult::fail(
            format!("{}.service is not installed.", service),
            "This service does not exist on the system yet, so audio components that depend on it cannot start.",
            if service == "snapclient" {
                "Redeploy this device (client role)"
            } else {
                "Redeploy this device (server role)"
            },
        )
    }
}

pub fn check_service_enabled(service: &str, enabled_state: &str) -> CheckResult {
    if enabled_state == "enabled" {
        CheckResult::pass(format!("{}.service is enabled.", service))
    } else {
        CheckResult::fail(
            format!("{}.service is not enabled (state: {}).", service, enabled_state),
            "Disabled services do not automatically start after reboot, which can leave playback offline.",
            format!("sudo systemctl enable {}", service),
        )
    }
}

pub fn check_service_active(service: &str, active_state: &str) -> CheckResult {
    if active_state == "active" {
        CheckResult::pass(format!("{}.service is active.", service))
    } else {
        CheckResult::fail(
            format!("{}.service is not active (state: {}).", service, active_state),
            "The process is currently stopped or crashed, so this audio role is not functioning right now.",
            format!("sudo systemctl restart {}", service),
        )
    }
}

pub fn check_listener(port: u16, process_hint: &str, ss_output: &str) -> CheckResult {
    let needle = format!(":{}", port);
    if ss_output.lines().any(|l| l.contains(&needle)) {
        CheckResult::pass(format!(
            "TCP port {} is listening ({}).",
            port, process_hint
        ))
    } else {
        CheckResult::fail(
            format!("TCP port {} is not listening ({}).", port, process_hint),
            format!("Nothing is accepting connections on this required port, so clients/controllers cannot talk to {}.", process_hint),
            "Redeploy this device".to_string(),
        )
    }
}

pub fn check_fifo(fifo_path: &str, is_pipe: bool) -> CheckResult {
    if is_pipe {
        CheckResult::pass(format!("FIFO exists: {}", fifo_path))
    } else {
        CheckResult::fail(
            format!("FIFO missing or not a named pipe: {}", fifo_path),
            "The audio handoff pipe between librespot and snapserver is missing, so server audio cannot flow.",
            "Redeploy this device".to_string(),
        )
    }
}

pub fn check_audio_device(resolved: &str) -> CheckResult {
    if resolved != "default" {
        CheckResult::pass(format!("Audio device resolved: {}", resolved))
    } else {
        CheckResult::warn(
            "Resolved audio device is 'default' (no suitable hardware)".to_string(),
            "Without a dedicated ALSA device, snapclient will not work in a system service context (PipeWire).",
            "Set snapclient.audio_device explicitly and redeploy",
        )
    }
}

pub fn recent_errors_summary(unit: &str, journal_output: &str) -> Vec<CheckResult> {
    if journal_output.trim().is_empty() {
        return vec![CheckResult::pass(format!(
            "No recent errors for {}.service",
            unit
        ))];
    }
    // If journal contains lines, surface as info with truncated output
    vec![CheckResult {
        status: CheckStatus::Info,
        message: format!("Recent errors for {}.service (last 15 lines):", unit),
        explanation: Some(
            journal_output
                .lines()
                .take(5)
                .collect::<Vec<_>>()
                .join("\n"),
        ),
        remediation: Some(format!(
            "sudo journalctl -u {}.service -p err -n 15 --no-pager",
            unit
        )),
    }]
}

/// Aggregate doctor for a server device.
pub fn doctor_server(
    list_units: &str,
    service_states: &[(String, String, String)], // (service, enabled, active)
    ss_output: &str,
    fifo_path: &str,
    fifo_is_pipe: bool,
) -> Vec<CheckResult> {
    let mut results = Vec::new();
    // librespot, snapserver, avahi-daemon
    for (service, enabled, active) in service_states {
        results.push(check_service_installed(service, list_units));
        results.push(check_service_enabled(service, enabled));
        results.push(check_service_active(service, active));
    }
    results.push(check_listener(1704, "snapserver", ss_output));
    results.push(check_listener(1780, "snapserver", ss_output));
    results.push(check_fifo(fifo_path, fifo_is_pipe));
    results
}

/// Aggregate doctor for a client device.
pub fn doctor_client(
    list_units: &str,
    service_states: &[(String, String, String)],
    resolved_device: &str,
) -> Vec<CheckResult> {
    let mut results = Vec::new();
    for (service, enabled, active) in service_states {
        results.push(check_service_installed(service, list_units));
        results.push(check_service_enabled(service, enabled));
        results.push(check_service_active(service, active));
    }
    results.push(check_audio_device(resolved_device));
    results
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_installed_detects() {
        let list = "librespot.service\nsnapserver.service\navahi-daemon.service\n";
        assert_eq!(
            check_service_installed("librespot", list).status,
            CheckStatus::Pass
        );
        assert_eq!(
            check_service_installed("snapclient", list).status,
            CheckStatus::Fail
        );
    }

    #[test]
    fn enabled_active_checks() {
        assert_eq!(
            check_service_enabled("snapserver", "enabled").status,
            CheckStatus::Pass
        );
        assert_eq!(
            check_service_enabled("snapserver", "disabled").status,
            CheckStatus::Fail
        );
        assert_eq!(
            check_service_active("snapserver", "active").status,
            CheckStatus::Pass
        );
        assert_eq!(
            check_service_active("snapserver", "inactive").status,
            CheckStatus::Fail
        );
    }

    #[test]
    fn listener_check() {
        let ss = "LISTEN 0 128 0.0.0.0:1704 0.0.0.0:* users:((\"snapserver\",pid=123,fd=3))\nLISTEN 0 128 0.0.0.0:1780 0.0.0.0:* users:((\"snapserver\",pid=123,fd=4))";
        assert_eq!(
            check_listener(1704, "snapserver", ss).status,
            CheckStatus::Pass
        );
        assert_eq!(
            check_listener(1780, "snapserver", ss).status,
            CheckStatus::Pass
        );
        assert_eq!(
            check_listener(9999, "snapserver", ss).status,
            CheckStatus::Fail
        );
    }

    #[test]
    fn fifo_check() {
        assert_eq!(
            check_fifo("/run/diy-sonos/snapfifo", true).status,
            CheckStatus::Pass
        );
        assert_eq!(
            check_fifo("/run/diy-sonos/snapfifo", false).status,
            CheckStatus::Fail
        );
    }

    #[test]
    fn audio_device_warn_on_default() {
        assert_eq!(
            check_audio_device("plughw:Device,0").status,
            CheckStatus::Pass
        );
        assert_eq!(check_audio_device("default").status, CheckStatus::Warn);
    }

    #[test]
    fn doctor_server_aggregates() {
        let list = "librespot.service\nsnapserver.service\navahi-daemon.service\n";
        let states = vec![
            (
                "librespot".to_string(),
                "enabled".to_string(),
                "active".to_string(),
            ),
            (
                "snapserver".to_string(),
                "enabled".to_string(),
                "active".to_string(),
            ),
        ];
        let ss = "0.0.0.0:1704\n0.0.0.0:1780";
        let res = doctor_server(list, &states, ss, "/run/diy-sonos/snapfifo", true);
        assert!(res.iter().any(|r| r.status == CheckStatus::Pass));
    }

    #[test]
    fn remediation_strings_are_app_actions() {
        let r = check_service_installed("librespot", "");
        assert!(r.remediation.unwrap().contains("Redeploy"));
        let l = check_listener(1704, "snapserver", "");
        assert!(l.remediation.unwrap().contains("Redeploy"));
    }
}
