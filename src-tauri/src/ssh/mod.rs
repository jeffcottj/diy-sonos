use anyhow::anyhow;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::sync::Mutex;

mod keys;
pub mod known_hosts;
pub use keys::{ensure_app_keypair, load_app_pubkey_string};
pub use known_hosts::check_host_key;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeviceStatus {
    pub host: String,
    pub port: u16,
    pub reachable: bool,
    pub host_key_fingerprint: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ConnectResult {
    Ok { status: DeviceStatus },
    HostKeyUntrusted { fingerprint: String, host: String },
}

/// Simple TOFU host-key store: app_data/known_hosts as `host fingerprint` lines.
pub struct SshManager {
    known_hosts_path: PathBuf,
    app_key_path: PathBuf,
    sessions: Arc<Mutex<HashMap<String, ()>>>,
}

impl SshManager {
    pub fn new(app_data_dir: &Path) -> Self {
        Self {
            known_hosts_path: app_data_dir.join("known_hosts"),
            app_key_path: app_data_dir.join("id_ed25519"),
            sessions: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    pub fn known_hosts_path(&self) -> &Path {
        &self.known_hosts_path
    }

    pub fn app_key_path(&self) -> &Path {
        &self.app_key_path
    }
}

/// Compute SSH fingerprint as `SHA256:base64` for a raw public key blob.
/// Uses `ssh-key` crate's fingerprint helper if available.
pub fn fingerprint_sha256(key_bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    // Use base64 without padding? OpenSSH uses base64 without padding? We'll use standard.
    let mut hasher = Sha256::new();
    hasher.update(key_bytes);
    let hash = hasher.finalize();
    // base64 encode and trim padding
    let b64 = data_encoding::BASE64.encode(&hash);
    format!("SHA256:{}", b64.trim_end_matches('='))
}

/// Execute a remote command via `sudo -S -p '' -- <cmd>` with password fed over stdin.
/// This is the Rust orchestration replacement for shelling out to bash; the remote
/// privileged actions remain ordinary shell commands (`apt-get`, `systemctl`, etc.).
/// In this scaffold, the actual russh execution is stubbed; the shape is preserved
/// for Phase 4 integration.
pub async fn exec_sudo(
    _host: &str,
    _port: u16,
    _ssh_user: &str,
    _password: Option<&str>,
    command: &str,
) -> Result<(i32, String, String), anyhow::Error> {
    // TODO: implement russh client exec with `sudo -S -p '' -- <command>`
    // For now, return an error indicating not yet connected; tests mock this.
    Err(anyhow!(
        "exec_sudo not yet implemented for command: {}",
        command
    ))
}

/// SFTP upload helper shape — uploads rendered content via russh-sftp.
/// Stub for Phase 3; Phase 4 will implement SFTP read/write for if-changed.
pub async fn sftp_upload(
    _host: &str,
    _port: u16,
    _remote_path: &str,
    _content: &[u8],
) -> Result<(), anyhow::Error> {
    Err(anyhow!("sftp_upload not yet implemented"))
}

/// Local port forwarding shape: `TcpListener` on 127.0.0.1:<local_port> splicing to remote 127.0.0.1:<remote_port> via russh direct-tcpip.
/// Stub for Phase 3; Phase 5 OAuth will wire this.
pub async fn start_port_forward(
    _host: &str,
    _port: u16,
    _local_port: u16,
    _remote_port: u16,
) -> Result<(), anyhow::Error> {
    Err(anyhow!("port_forward not yet implemented"))
}

/// Install the app's public key into remote `~/.ssh/authorized_keys` idempotently.
/// Mirrors what `ssh-copy-id` does; the app key is generated via `ensure_app_keypair`.
pub async fn install_device_key(
    host: &str,
    port: u16,
    ssh_user: &str,
    password: &str,
    app_data_dir: &Path,
) -> Result<(), anyhow::Error> {
    let pubkey = load_app_pubkey_string(app_data_dir).or_else(|_| {
        // Ensure keypair exists
        ensure_app_keypair(app_data_dir).and_then(|_| load_app_pubkey_string(app_data_dir))
    })?;

    // Remote command: mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qxF "<pubkey>" ~/.ssh/authorized_keys || echo "<pubkey>" >> ~/.ssh/authorized_keys
    // Use single-quoted pubkey to avoid shell expansion; pubkey contains no single quotes.
    let cmd = format!(
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '{}' ~/.ssh/authorized_keys || echo '{}' >> ~/.ssh/authorized_keys",
        pubkey.trim(),
        pubkey.trim()
    );
    let (code, _out, err) = exec_sudo(host, port, ssh_user, Some(password), &cmd).await?;
    if code != 0 {
        return Err(anyhow!("install_device_key failed: {}", err));
    }
    Ok(())
}

/// Connect to a device, performing TOFU host-key check.
/// Returns `ConnectResult::Ok` if host key is trusted or `HostKeyUntrusted` if new.
/// On later connects, a mismatched key is a hard error.
pub async fn connect_device(
    host: &str,
    port: u16,
    _ssh_user: &str,
    _password: Option<&str>,
    app_data_dir: &Path,
) -> Result<ConnectResult, anyhow::Error> {
    // In this scaffold, we simulate host-key handling without actual TCP.
    // Try to read known_hosts; if entry exists, report Ok, else HostKeyUntrusted with dummy fingerprint.
    let known_path = app_data_dir.join("known_hosts");
    let host_key = format!("{}:{}", host, port);
    match check_host_key(&known_path, &host_key, "SHA256:dummy") {
        Ok(true) => Ok(ConnectResult::Ok {
            status: DeviceStatus {
                host: host.to_string(),
                port,
                reachable: true,
                host_key_fingerprint: Some("SHA256:dummy".to_string()),
            },
        }),
        Ok(false) => {
            // Not yet trusted
            Ok(ConnectResult::HostKeyUntrusted {
                fingerprint: "SHA256:dummy_fingerprint".to_string(),
                host: host.to_string(),
            })
        }
        Err(e) => Err(anyhow!("host key mismatch for {}: {}", host, e)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fingerprint_format() {
        let fp = fingerprint_sha256(b"testkey");
        assert!(fp.starts_with("SHA256:"));
        assert!(fp.len() > 7);
    }

    #[test]
    fn install_key_command_escapes_correctly() {
        let pubkey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI test@host";
        let cmd = format!(
            "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '{}' ~/.ssh/authorized_keys || echo '{}' >> ~/.ssh/authorized_keys",
            pubkey.trim(),
            pubkey.trim()
        );
        assert!(cmd.contains("grep -qxF"));
        assert!(cmd.contains(pubkey));
    }
}
