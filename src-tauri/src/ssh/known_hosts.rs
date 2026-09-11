use anyhow::{anyhow, Context};
use std::collections::HashMap;
use std::path::Path;

#[derive(Debug, Clone)]
pub struct HostKeyEntry {
    pub host: String,
    pub fingerprint: String,
}

fn load_known_hosts(path: &Path) -> Result<HashMap<String, String>, anyhow::Error> {
    if !path.exists() {
        return Ok(HashMap::new());
    }
    let content = std::fs::read_to_string(path).context("read known_hosts")?;
    let mut map = HashMap::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mut parts = line.split_whitespace();
        if let (Some(host), Some(fp)) = (parts.next(), parts.next()) {
            map.insert(host.to_string(), fp.to_string());
        }
    }
    Ok(map)
}

/// Check host key against TOFU store.
/// - If no entry: return Ok(false) meaning untrusted; caller should prompt user and call `trust_host_key`.
/// - If entry matches: Ok(true)
/// - If entry exists but fingerprint differs: Err(hard error - possible MITM)
pub fn check_host_key(
    known_hosts_path: &Path,
    host: &str,
    fingerprint: &str,
) -> Result<bool, anyhow::Error> {
    let map = load_known_hosts(known_hosts_path)?;
    if let Some(stored) = map.get(host) {
        if stored == fingerprint {
            Ok(true)
        } else {
            Err(anyhow!(
                "host key mismatch for {}: expected {} got {}",
                host,
                stored,
                fingerprint
            ))
        }
    } else {
        Ok(false)
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct KnownDevice {
    pub host: String,
    pub port: u16,
    pub fingerprint: String,
}

/// Split a store key (`host:port`, or a bare host from older versions)
/// into host + port, defaulting to 22.
pub fn split_host_key(store_key: &str) -> (String, u16) {
    match store_key.rsplit_once(':') {
        Some((host, port)) => match port.parse::<u16>() {
            Ok(port) => (host.to_string(), port),
            Err(_) => (store_key.to_string(), 22),
        },
        None => (store_key.to_string(), 22),
    }
}

/// Forget a trusted device (and any bare-host leftover for the same host).
pub fn forget_device(
    known_hosts_path: &Path,
    host: &str,
    port: u16,
) -> Result<bool, anyhow::Error> {
    let mut map = load_known_hosts(known_hosts_path)?;
    let mut removed = false;
    if map.remove(&format!("{}:{}", host, port)).is_some() {
        removed = true;
    }
    if map.remove(host).is_some() {
        removed = true;
    }
    if removed {
        write_known_hosts(known_hosts_path, &map)?;
    }
    Ok(removed)
}

/// List every trusted (connected) device in the TOFU store, sorted by host.
pub fn list_known_devices(known_hosts_path: &Path) -> Result<Vec<KnownDevice>, anyhow::Error> {
    let _ = purge_stale_entries(known_hosts_path);
    let map = load_known_hosts(known_hosts_path)?;
    let mut devices: Vec<KnownDevice> = map
        .into_iter()
        .map(|(store_key, fingerprint)| {
            let (host, port) = split_host_key(&store_key);
            KnownDevice {
                host,
                port,
                fingerprint,
            }
        })
        .collect();
    devices.sort_by(|a, b| a.host.cmp(&b.host).then(a.port.cmp(&b.port)));
    Ok(devices)
}

fn write_known_hosts(path: &Path, map: &HashMap<String, String>) -> Result<(), anyhow::Error> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).context("create known_hosts dir")?;
    }
    let mut entries: Vec<(&String, &String)> = map.iter().collect();
    entries.sort_by(|a, b| a.0.cmp(b.0));
    let mut content = String::new();
    for (h, fp) in entries {
        content.push_str(&format!("{} {}\n", h, fp));
    }
    std::fs::write(path, content).context("write known_hosts")?;
    Ok(())
}

fn is_stub_fingerprint(fp: &str) -> bool {
    fp.starts_with("SHA256:dummy")
}

/// Remove stale trust entries left by earlier app versions:
/// - fingerprints from the pre-SSH stub (`SHA256:dummy…`, never a real key),
/// - bare-host keys shadowed by a `host:port` entry (migrated to `host:22`
///   when they carry a real fingerprint).
///
/// Returns the number of entries removed or migrated.
/// Self-healing: runs automatically when listing devices.
pub fn purge_stale_entries(known_hosts_path: &Path) -> Result<usize, anyhow::Error> {
    let mut map = load_known_hosts(known_hosts_path)?;
    if map.is_empty() {
        return Ok(0);
    }
    let mut changed = 0;
    // Drop stub fingerprints outright.
    let stubs: Vec<String> = map
        .iter()
        .filter(|(_, fp)| is_stub_fingerprint(fp))
        .map(|(h, _)| h.clone())
        .collect();
    for host in stubs {
        map.remove(&host);
        changed += 1;
    }
    // Fold bare-host keys into host:22.
    let bare: Vec<(String, String)> = map
        .iter()
        .filter(|(h, _)| !h.contains(':'))
        .map(|(h, fp)| (h.clone(), fp.clone()))
        .collect();
    for (host, fp) in bare {
        let qualified = format!("{}:22", host);
        map.remove(&host);
        map.entry(qualified).or_insert(fp);
        changed += 1;
    }
    if changed > 0 {
        write_known_hosts(known_hosts_path, &map)?;
    }
    Ok(changed)
}

pub fn trust_host_key(
    known_hosts_path: &Path,
    host: &str,
    fingerprint: &str,
) -> Result<(), anyhow::Error> {
    let mut map = load_known_hosts(known_hosts_path)?;
    map.insert(host.to_string(), fingerprint.to_string());

    if let Some(parent) = known_hosts_path.parent() {
        std::fs::create_dir_all(parent).context("create known_hosts dir")?;
    }
    let mut content = String::new();
    for (h, fp) in map {
        content.push_str(&format!("{} {}\n", h, fp));
    }
    std::fs::write(known_hosts_path, content).context("write known_hosts")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn list_known_devices_parses_store() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        assert!(super::list_known_devices(&path).unwrap().is_empty());
        super::trust_host_key(&path, "192.168.68.104:22", "SHA256:aaa").unwrap();
        super::trust_host_key(&path, "bare-host", "SHA256:bbb").unwrap();
        let devices = super::list_known_devices(&path).unwrap();
        assert_eq!(devices.len(), 2);
        assert_eq!(devices[0].host, "192.168.68.104");
        assert_eq!(devices[0].port, 22);
        assert_eq!(devices[0].fingerprint, "SHA256:aaa");
        assert_eq!(devices[1].host, "bare-host");
        assert_eq!(devices[1].port, 22);
    }

    #[test]
    fn purge_removes_stub_and_migrates_bare() {
        use std::io::Write;
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        let mut f = std::fs::File::create(&path).unwrap();
        writeln!(f, "192.168.68.104 SHA256:dummy_fingerprint").unwrap();
        writeln!(f, "192.168.68.114 SHA256:realfp==").unwrap();
        writeln!(f, "192.168.68.104:22 SHA256:realfp2==").unwrap();
        drop(f);
        let changed = super::purge_stale_entries(&path).unwrap();
        assert_eq!(changed, 2);
        let devices = super::list_known_devices(&path).unwrap();
        assert_eq!(devices.len(), 2);
        assert!(devices.iter().all(|d| !d.fingerprint.contains("dummy")));
        let migrated = devices.iter().find(|d| d.host == "192.168.68.114").unwrap();
        assert_eq!(migrated.port, 22);
        assert_eq!(migrated.fingerprint, "SHA256:realfp==");
    }

    #[test]
    fn tofu_flow() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        // Initially untrusted
        assert_eq!(
            check_host_key(&path, "192.168.1.10:22", "SHA256:abc").unwrap(),
            false
        );
        // Trust it
        trust_host_key(&path, "192.168.1.10:22", "SHA256:abc").unwrap();
        assert_eq!(
            check_host_key(&path, "192.168.1.10:22", "SHA256:abc").unwrap(),
            true
        );
        // Mismatch is error
        assert!(check_host_key(&path, "192.168.1.10:22", "SHA256:different").is_err());
        // Different host is separate
        assert_eq!(
            check_host_key(&path, "192.168.1.11:22", "SHA256:abc").unwrap(),
            false
        );
    }

    #[test]
    fn known_hosts_file_format() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        trust_host_key(&path, "host1", "fp1").unwrap();
        trust_host_key(&path, "host2", "fp2").unwrap();
        let content = std::fs::read_to_string(&path).unwrap();
        assert!(content.contains("host1 fp1"));
        assert!(content.contains("host2 fp2"));
    }
}
