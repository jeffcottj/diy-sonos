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

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SweptDevice {
    pub ip: String,
    pub port: u16,
    pub banner: Option<String>,
    pub likely_pi: bool,
}

fn banner_likely_pi(banner: &str) -> bool {
    let lower = banner.to_ascii_lowercase();
    lower.contains("raspbian") || lower.contains("raspberry")
}

/// Parse `a.b.c.d/prefix` into candidate host addresses. Refuses subnets
/// larger than 1024 addresses so a typo like /16 can't stall the UI.
pub fn parse_subnet(subnet: &str) -> Result<Vec<std::net::IpAddr>, anyhow::Error> {
    let (base, prefix) = subnet
        .split_once('/')
        .ok_or_else(|| anyhow::anyhow!("expected CIDR like 192.168.68.0/24, got '{}'", subnet))?;
    let base: std::net::Ipv4Addr = base
        .trim()
        .parse()
        .map_err(|_| anyhow::anyhow!("invalid IPv4 network '{}'", base))?;
    let prefix: u32 = prefix
        .trim()
        .parse()
        .map_err(|_| anyhow::anyhow!("invalid prefix in '{}'", subnet))?;
    if !(16..=32).contains(&prefix) {
        return Err(anyhow::anyhow!(
            "prefix must be /16..=/32 (and <=1024 hosts)"
        ));
    }
    let count: u32 = 1u32
        .checked_shl(32 - prefix)
        .ok_or_else(|| anyhow::anyhow!("bad prefix"))?;
    if count > 1024 {
        return Err(anyhow::anyhow!(
            "subnet too large ({} hosts); max 1024, e.g. /22",
            count
        ));
    }
    let network = u32::from(base) & (!0u32 << (32 - prefix));
    Ok((0..count)
        .map(|i| std::net::IpAddr::V4(std::net::Ipv4Addr::from(network + i)))
        .collect())
}

async fn probe_ssh(ip: std::net::IpAddr, port: u16) -> Option<SweptDevice> {
    use tokio::io::AsyncBufReadExt;
    let addr = std::net::SocketAddr::new(ip, port);
    let stream = tokio::time::timeout(Duration::from_secs(1), tokio::net::TcpStream::connect(addr))
        .await
        .ok()?
        .ok()?;
    let mut reader = tokio::io::BufReader::new(stream);
    let mut line = String::new();
    let banner = tokio::time::timeout(Duration::from_secs(2), reader.read_line(&mut line))
        .await
        .ok()
        .and_then(|r| r.ok())
        .filter(|_| !line.trim().is_empty())
        .map(|_| line.trim().to_string());
    Some(SweptDevice {
        ip: ip.to_string(),
        port,
        likely_pi: banner.as_deref().map(banner_likely_pi).unwrap_or(false),
        banner,
    })
}

/// Probe TCP 22 across a subnet (e.g. `192.168.68.0/24`) and report hosts
/// accepting SSH, with server banner when readable. Batched so a /24
/// typically finishes in seconds; worst case about a minute.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkScan {
    pub subnet: String,
    pub devices: Vec<SweptDevice>,
}

/// Infer the local /24 via a route lookup: "connecting" a UDP socket sends
/// no packets, it just reveals which source address the default route uses.
pub fn local_subnet() -> Result<String, anyhow::Error> {
    let sock = std::net::UdpSocket::bind("0.0.0.0:0")?;
    sock.connect("8.8.8.8:80")?;
    match sock.local_addr()?.ip() {
        std::net::IpAddr::V4(v4) => {
            let o = v4.octets();
            Ok(format!("{}.{}.{}.0/24", o[0], o[1], o[2]))
        }
        ip => Err(anyhow::anyhow!("no IPv4 default route (got {})", ip)),
    }
}

/// Scan the local subnet: infer the machine's own /24 and sweep TCP 22.
pub async fn scan_network() -> Result<NetworkScan, anyhow::Error> {
    let subnet = local_subnet()?;
    let devices = scan_subnet(&subnet).await?;
    Ok(NetworkScan { subnet, devices })
}

pub async fn scan_subnet(subnet: &str) -> Result<Vec<SweptDevice>, anyhow::Error> {
    let targets = parse_subnet(subnet)?;
    let mut found = Vec::new();
    for chunk in targets.chunks(64) {
        let mut set = tokio::task::JoinSet::new();
        for ip in chunk {
            let ip = *ip;
            set.spawn(async move { probe_ssh(ip, 22).await });
        }
        while let Some(res) = set.join_next().await {
            if let Ok(Some(device)) = res {
                found.push(device);
            }
        }
    }
    found.sort_by(|a, b| a.ip.cmp(&b.ip));
    Ok(found)
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

    #[test]
    fn parse_subnet_24_gives_256_hosts() {
        let hosts = super::parse_subnet("192.168.68.0/24").unwrap();
        assert_eq!(hosts.len(), 256);
        assert_eq!(hosts.first().unwrap().to_string(), "192.168.68.0");
        assert_eq!(hosts.last().unwrap().to_string(), "192.168.68.255");
    }

    #[test]
    fn local_subnet_is_a_scannable_24() {
        let subnet = super::local_subnet().unwrap();
        let hosts = super::parse_subnet(&subnet).unwrap();
        assert_eq!(hosts.len(), 256);
    }

    #[test]
    fn parse_subnet_rejects_garbage_and_huge() {
        assert!(super::parse_subnet("not-a-subnet").is_err());
        assert!(super::parse_subnet("192.168.1.1").is_err());
        assert!(super::parse_subnet("10.0.0.0/16").is_err());
        assert!(super::parse_subnet("192.168.68.0/33").is_err());
        assert!(super::parse_subnet("192.168.68.104/32").is_ok());
    }
}
