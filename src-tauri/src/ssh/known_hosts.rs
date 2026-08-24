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
