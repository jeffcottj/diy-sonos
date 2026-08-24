use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscoveredDevice {
    pub hostname: String,
    pub ip: String,
    pub port: u16,
    pub likely_pi: bool,
}

fn is_likely_pi(hostname: &str) -> bool {
    let lower = hostname.to_ascii_lowercase();
    lower.contains("raspberrypi")
        || lower.contains("raspi")
        || lower.contains("dietpi")
        || lower == "pi"
        || lower.contains("ubuntu")
        || (lower.contains("pi") && lower.len() <= 15) // heuristic: short names containing pi
}

#[cfg(test)]
fn is_likely_pi_testable(hostname: &str) -> bool {
    is_likely_pi(hostname)
}

/// Scan for mDNS SSH hosts for ~5 seconds, dedupe by IP.
pub async fn scan_mdns() -> Result<Vec<DiscoveredDevice>, anyhow::Error> {
    let mdns = mdns_sd::ServiceDaemon::new()?;
    let receiver = mdns.browse("_ssh._tcp.local.")?;

    let mut devices: HashMap<String, DiscoveredDevice> = HashMap::new();
    let timeout = Duration::from_secs(5);
    let start = std::time::Instant::now();

    while start.elapsed() < timeout {
        let remaining = timeout.saturating_sub(start.elapsed());
        match tokio::time::timeout(remaining, receiver.recv_async()).await {
            Ok(Ok(event)) => match event {
                mdns_sd::ServiceEvent::ServiceResolved(info) => {
                    let hostname = info.get_hostname().to_string();
                    // Remove trailing dot
                    let hostname = hostname.trim_end_matches('.').to_string();
                    let port = info.get_port();
                    for addr in info.get_addresses() {
                        if addr.is_ipv4() {
                            let ip = addr.to_string();
                            let entry = DiscoveredDevice {
                                hostname: hostname.clone(),
                                ip: ip.clone(),
                                port,
                                likely_pi: is_likely_pi(&hostname),
                            };
                            devices.entry(ip).or_insert(entry);
                        }
                    }
                }
                mdns_sd::ServiceEvent::ServiceRemoved(_ty, fullname) => {
                    // Could remove, but keep deduped map
                    let _ = fullname;
                }
                _ => {}
            },
            Ok(Err(_)) => break,
            Err(_) => break, // timeout
        }
    }

    // mdns is dropped here, stopping browse
    let mut result: Vec<DiscoveredDevice> = devices.into_values().collect();
    result.sort_by(|a, b| a.ip.cmp(&b.ip));
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn likely_pi_detection() {
        assert!(is_likely_pi_testable("raspberrypi.local"));
        assert!(is_likely_pi_testable("RASPBERRYPI"));
        assert!(is_likely_pi_testable("raspi-01"));
        assert!(is_likely_pi_testable("dietpi"));
        assert!(is_likely_pi_testable("ubuntu-server"));
        assert!(!is_likely_pi_testable("my-laptop"));
        assert!(!is_likely_pi_testable("desktop"));
    }

    #[test]
    fn dedupe_by_ip_logic() {
        let mut map: HashMap<String, DiscoveredDevice> = HashMap::new();
        let d1 = DiscoveredDevice {
            hostname: "pi1.local".to_string(),
            ip: "192.168.1.10".to_string(),
            port: 22,
            likely_pi: true,
        };
        let d2 = DiscoveredDevice {
            hostname: "pi1.local".to_string(),
            ip: "192.168.1.10".to_string(),
            port: 22,
            likely_pi: true,
        };
        map.insert(d1.ip.clone(), d1);
        map.entry(d2.ip.clone()).or_insert(d2);
        assert_eq!(map.len(), 1);
    }
}
