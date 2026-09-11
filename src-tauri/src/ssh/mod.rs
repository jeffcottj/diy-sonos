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

/// Wrap a command for privileged execution. Password (if any) is fed over
/// stdin via `sudo -S`; `-p ''` keeps the prompt silent for log parsing.
pub fn sudo_wrap(command: &str) -> String {
    format!("sudo -S -p '' -- {}", command)
}

/// Connect with the app keypair (publickey auth). Used once password auth has
/// installed the key, or when `password` is None.
fn load_app_keypair(
    app_data_dir: &Path,
) -> Result<std::sync::Arc<russh::keys::key::KeyPair>, anyhow::Error> {
    ensure_app_keypair(app_data_dir)?;
    let pem = std::fs::read_to_string(app_data_dir.join("id_ed25519"))
        .map_err(|e| anyhow!("read app private key: {}", e))?;
    let keypair = russh::keys::decode_secret_key(pem.as_str(), None)
        .map_err(|e| anyhow!("decode app private key: {}", e))?;
    Ok(std::sync::Arc::new(keypair))
}

/// Open an authenticated session. The server host key is verified against the
/// TOFU store first (hard error on mismatch or untrusted); auth is password
/// when provided, otherwise the app keypair.
async fn connect_session(
    host: &str,
    port: u16,
    ssh_user: &str,
    password: Option<&str>,
    app_data_dir: &Path,
) -> Result<russh::client::Handle<FetchHostKeyHandler>, anyhow::Error> {
    let known_path = app_data_dir.join("known_hosts");
    let store_key = canonical_host_key(host, port);
    let presented = fetch_server_fingerprint(host, port).await?;
    match check_host_key(&known_path, &store_key, &presented) {
        Ok(true) => {}
        Ok(false) => {
            return Err(anyhow!(
                "host key for {} is not trusted yet; connect and trust it first",
                store_key
            ))
        }
        Err(e) => return Err(anyhow!("host key mismatch for {}: {}", host, e)),
    }

    let config = Arc::new(russh::client::Config::default());
    let handler = FetchHostKeyHandler {
        fingerprint: Arc::new(Mutex::new(None)),
    };
    let addr = format!("{}:{}", host, port);
    let connect = russh::client::connect(config, addr.as_str(), handler);
    let mut session = tokio::time::timeout(std::time::Duration::from_secs(8), connect)
        .await
        .map_err(|_| anyhow!("SSH connect to {}:{} timed out", host, port))?
        .map_err(|e| anyhow!("SSH connect to {}:{} failed: {}", host, port, e))?;

    if let Some(password) = password {
        let authed = session
            .authenticate_password(ssh_user, password)
            .await
            .map_err(|e| anyhow!("SSH password auth to {} failed: {}", host, e))?;
        if !authed {
            return Err(anyhow!(
                "SSH password auth rejected for {}@{}",
                ssh_user,
                host
            ));
        }
    } else {
        let keypair = load_app_keypair(app_data_dir)?;
        let authed = session
            .authenticate_publickey(ssh_user, keypair)
            .await
            .map_err(|e| anyhow!("SSH key auth to {} failed: {}", host, e))?;
        if !authed {
            return Err(anyhow!("SSH key auth rejected for {}@{}", ssh_user, host));
        }
    }
    Ok(session)
}

async fn run_remote_command(
    session: &russh::client::Handle<FetchHostKeyHandler>,
    remote_cmd: &str,
    sudo_password: Option<&str>,
) -> Result<(i32, String, String), anyhow::Error> {
    let mut channel = session
        .channel_open_session()
        .await
        .map_err(|e| anyhow!("open SSH channel failed: {}", e))?;
    channel
        .exec(true, remote_cmd)
        .await
        .map_err(|e| anyhow!("SSH exec failed: {}", e))?;
    if let Some(password) = sudo_password {
        let prompt_input = format!("{}\n", password);
        channel
            .data(prompt_input.as_bytes())
            .await
            .map_err(|e| anyhow!("send sudo password failed: {}", e))?;
        channel
            .eof()
            .await
            .map_err(|e| anyhow!("close channel stdin failed: {}", e))?;
    }
    let mut stdout: Vec<u8> = Vec::new();
    let mut stderr: Vec<u8> = Vec::new();
    let mut code: Option<u32> = None;
    loop {
        match tokio::time::timeout(std::time::Duration::from_secs(300), channel.wait())
            .await
            .map_err(|_| anyhow!("remote command timed out: {}", remote_cmd))?
        {
            Some(russh::ChannelMsg::Data { data }) => stdout.extend_from_slice(&data),
            Some(russh::ChannelMsg::ExtendedData { data, .. }) => stderr.extend_from_slice(&data),
            Some(russh::ChannelMsg::ExitStatus { exit_status }) => code = Some(exit_status),
            Some(russh::ChannelMsg::ExitSignal { .. }) => break,
            None => break,
            _ => {}
        }
    }
    let _ = channel.close().await;
    Ok((
        code.unwrap_or(1) as i32,
        String::from_utf8_lossy(&stdout).into_owned(),
        String::from_utf8_lossy(&stderr).into_owned(),
    ))
}

/// Stage bytes on the remote as a regular user via base64 (no sudo, no
/// quoting hazards). Returns the shell command; the caller runs it with
/// [`exec`]. Pure constructor, unit-tested.
pub fn stage_file_command(content_b64: &str, stage_path: &str) -> String {
    format!(
        "echo '{}' | base64 -d > '{}' && chmod 600 '{}'",
        content_b64, stage_path, stage_path
    )
}

/// Install a staged file to a privileged destination. Runs under sudo.
pub fn install_staged_command(stage_path: &str, dest_path: &str, mode: &str) -> String {
    format!(
        "cp '{}' '{}' && chmod {} '{}' && rm -f '{}'",
        stage_path, dest_path, mode, dest_path, stage_path
    )
}

/// True when the remote file is missing or differs from desired content.
pub fn needs_update(current: Option<&str>, desired: &str) -> bool {
    match current {
        None => true,
        Some(existing) => existing != desired,
    }
}

/// Connection target for remote file operations.
#[derive(Debug, Clone, Copy)]
pub struct Remote<'a> {
    pub host: &'a str,
    pub port: u16,
    pub ssh_user: &'a str,
    pub password: Option<&'a str>,
    pub app_data_dir: &'a Path,
}

/// Read a (possibly privileged) remote file. Returns None when unreadable.
pub async fn read_privileged_file(
    remote: &Remote<'_>,
    path: &str,
) -> Result<Option<String>, anyhow::Error> {
    let (code, out, _) = exec_sudo(
        remote.host,
        remote.port,
        remote.ssh_user,
        remote.password,
        remote.app_data_dir,
        &format!("cat '{}'", path),
    )
    .await?;
    if code != 0 {
        return Ok(None);
    }
    Ok(Some(out))
}

/// Write content to a privileged path only when it differs. Returns true
/// when the file was changed. Staging avoids SFTP entirely: bytes travel
/// inside the already-authenticated SSH exec channel.
pub async fn write_privileged_file_if_changed(
    remote: &Remote<'_>,
    content: &str,
    dest_path: &str,
    mode: &str,
) -> Result<bool, anyhow::Error> {
    use data_encoding::BASE64;
    let current = read_privileged_file(remote, dest_path).await?;
    if !needs_update(current.as_deref(), content) {
        return Ok(false);
    }
    let stage_path = format!("/tmp/.diy-sonos-{}", dest_path.replace('/', "_"));
    let b64 = BASE64.encode(content.as_bytes());
    let (code, _, err) = exec(
        remote.host,
        remote.port,
        remote.ssh_user,
        remote.password,
        remote.app_data_dir,
        &stage_file_command(&b64, &stage_path),
    )
    .await?;
    if code != 0 {
        return Err(anyhow!("staging {} failed: {}", dest_path, err));
    }
    let (code, _, err) = exec_sudo(
        remote.host,
        remote.port,
        remote.ssh_user,
        remote.password,
        remote.app_data_dir,
        &install_staged_command(&stage_path, dest_path, mode),
    )
    .await?;
    if code != 0 {
        return Err(anyhow!("installing {} failed: {}", dest_path, err));
    }
    Ok(true)
}

/// Execute a remote command over the app-key SSH session (no sudo).
pub async fn exec(
    host: &str,
    port: u16,
    ssh_user: &str,
    password: Option<&str>,
    app_data_dir: &Path,
    command: &str,
) -> Result<(i32, String, String), anyhow::Error> {
    let session = connect_session(host, port, ssh_user, password, app_data_dir).await?;
    let result = run_remote_command(&session, command, None).await;
    let _ = session
        .disconnect(russh::Disconnect::ByApplication, "", "")
        .await;
    result
}

/// Execute a remote command via `sudo -S -p '' -- <cmd>` with password fed over stdin.
/// This is the Rust orchestration replacement for shelling out to bash; the remote
/// privileged actions remain ordinary shell commands (`apt-get`, `systemctl`, etc.).
pub async fn exec_sudo(
    host: &str,
    port: u16,
    ssh_user: &str,
    password: Option<&str>,
    app_data_dir: &Path,
    command: &str,
) -> Result<(i32, String, String), anyhow::Error> {
    let wrapped = sudo_wrap(command);
    let session = connect_session(host, port, ssh_user, password, app_data_dir).await?;
    let result = run_remote_command(&session, &wrapped, password).await;
    let _ = session
        .disconnect(russh::Disconnect::ByApplication, "", "")
        .await;
    result
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

    // Remote command runs as the SSH user (NOT sudo): the key must land in
    // the user's own ~/.ssh/authorized_keys for subsequent key auth to work.
    // Use single-quoted pubkey to avoid shell expansion; pubkey contains no single quotes.
    let cmd = format!(
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && grep -qxF '{}' ~/.ssh/authorized_keys || echo '{}' >> ~/.ssh/authorized_keys",
        pubkey.trim(),
        pubkey.trim()
    );
    let (code, _out, err) = exec(host, port, ssh_user, Some(password), app_data_dir, &cmd).await?;
    if code != 0 {
        return Err(anyhow!("install_device_key failed: {}", err));
    }
    Ok(())
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct DeviceLiveness {
    pub host: String,
    pub port: u16,
    pub live: bool,
}

async fn probe_live(host: &str, port: u16) -> DeviceLiveness {
    let addr = format!("{}:{}", host, port);
    let live = tokio::time::timeout(
        std::time::Duration::from_millis(1500),
        tokio::net::TcpStream::connect(addr.as_str()),
    )
    .await
    .is_ok_and(|r| r.is_ok());
    DeviceLiveness {
        host: host.to_string(),
        port,
        live,
    }
}

/// Check TCP reachability for a batch of devices in parallel.
/// Read-only: connects to the SSH port and immediately closes.
pub async fn check_live(devices: &[(String, u16)]) -> Vec<DeviceLiveness> {
    let mut set = tokio::task::JoinSet::new();
    for (host, port) in devices {
        let (host, port) = (host.clone(), *port);
        set.spawn(async move { probe_live(&host, port).await });
    }
    let mut out = Vec::new();
    while let Some(res) = set.join_next().await {
        if let Ok(status) = res {
            out.push(status);
        }
    }
    out.sort_by(|a, b| a.host.cmp(&b.host).then(a.port.cmp(&b.port)));
    out
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct ServerCombo {
    pub host: String,
    pub port: u16,
    pub runs_client: bool,
}

async fn probe_server_combo(
    host: &str,
    port: u16,
    ssh_user: &str,
    app_data_dir: std::path::PathBuf,
) -> ServerCombo {
    let runs_client = exec(
        host,
        port,
        ssh_user,
        None,
        &app_data_dir,
        "systemctl is-active snapclient",
    )
    .await
    .map(|(code, out, _)| code == 0 && out.trim() == "active")
    .unwrap_or(false);
    ServerCombo {
        host: host.to_string(),
        port,
        runs_client,
    }
}

/// Detect whether server-role devices also run snapclient (combo) via key
/// auth. Auth failures quietly report false; the UI only upgrades display.
pub async fn check_servers_combo(
    devices: &[(String, u16, String)],
    app_data_dir: &std::path::Path,
) -> Vec<ServerCombo> {
    let mut set = tokio::task::JoinSet::new();
    for (host, port, ssh_user) in devices {
        let (host, port, ssh_user, dir) = (
            host.clone(),
            *port,
            ssh_user.clone(),
            app_data_dir.to_path_buf(),
        );
        set.spawn(async move { probe_server_combo(&host, port, &ssh_user, dir).await });
    }
    let mut out = Vec::new();
    while let Some(res) = set.join_next().await {
        if let Ok(status) = res {
            out.push(status);
        }
    }
    out.sort_by(|a, b| a.host.cmp(&b.host).then(a.port.cmp(&b.port)));
    out
}

/// Canonical TOFU store key. IPv4/hostnames become `host:port`; values that
/// already contain `:` (host:port or IPv6 literals) pass through unchanged.
pub fn canonical_host_key(host: &str, port: u16) -> String {
    if host.contains(':') {
        host.to_string()
    } else {
        format!("{}:{}", host, port)
    }
}

struct FetchHostKeyHandler {
    fingerprint: Arc<Mutex<Option<String>>>,
}

#[async_trait::async_trait]
impl russh::client::Handler for FetchHostKeyHandler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::key::PublicKey,
    ) -> Result<bool, Self::Error> {
        let fingerprint = format!("SHA256:{}", server_public_key.fingerprint());
        *self.fingerprint.lock().await = Some(fingerprint);
        Ok(true)
    }
}

async fn fetch_server_fingerprint(host: &str, port: u16) -> Result<String, anyhow::Error> {
    let config = Arc::new(russh::client::Config::default());
    let fingerprint = Arc::new(Mutex::new(None));
    let handler = FetchHostKeyHandler {
        fingerprint: fingerprint.clone(),
    };
    let addr = format!("{}:{}", host, port);
    let connect = russh::client::connect(config, addr.as_str(), handler);
    let session = tokio::time::timeout(std::time::Duration::from_secs(8), connect)
        .await
        .map_err(|_| anyhow!("SSH connect to {}:{} timed out", host, port))?
        .map_err(|e| anyhow!("SSH connect to {}:{} failed: {}", host, port, e))?;
    let _ = session
        .disconnect(russh::Disconnect::ByApplication, "", "")
        .await;
    let stored = { fingerprint.lock().await.clone() };
    stored.ok_or_else(|| anyhow!("server {}:{} did not present a host key", host, port))
}

/// Connect to a device, performing TOFU host-key check.
/// Fetches the real server host key over SSH (no auth), then compares it
/// against the TOFU store. Returns `ConnectResult::Ok` if trusted,
/// `HostKeyUntrusted` with the real fingerprint if new.
/// On later connects, a mismatched key is a hard error.
pub async fn connect_device(
    host: &str,
    port: u16,
    _ssh_user: &str,
    _password: Option<&str>,
    app_data_dir: &Path,
) -> Result<ConnectResult, anyhow::Error> {
    let known_path = app_data_dir.join("known_hosts");
    let store_key = canonical_host_key(host, port);
    let real_fingerprint = fetch_server_fingerprint(host, port).await?;
    match check_host_key(&known_path, &store_key, &real_fingerprint) {
        Ok(true) => Ok(ConnectResult::Ok {
            status: DeviceStatus {
                host: host.to_string(),
                port,
                reachable: true,
                host_key_fingerprint: Some(real_fingerprint),
            },
        }),
        Ok(false) => Ok(ConnectResult::HostKeyUntrusted {
            fingerprint: real_fingerprint,
            host: host.to_string(),
        }),
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

    #[tokio::test]
    async fn check_live_sees_open_and_closed_ports() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let open = listener.local_addr().unwrap().port();
        let closed = if open == 9 { 10 } else { 9 };
        let out = super::check_live(&[
            ("127.0.0.1".to_string(), open),
            ("127.0.0.1".to_string(), closed),
        ])
        .await;
        assert_eq!(out.len(), 2);
        assert!(out.iter().any(|d| d.port == open && d.live));
        assert!(out.iter().any(|d| d.port == closed && !d.live));
    }

    #[test]
    fn canonical_host_key_formats() {
        assert_eq!(
            canonical_host_key("192.168.68.104", 22),
            "192.168.68.104:22"
        );
        assert_eq!(
            canonical_host_key("192.168.68.104:22", 22),
            "192.168.68.104:22"
        );
    }

    #[test]
    fn stage_and_install_commands_quote_paths() {
        let stage = super::stage_file_command("aGVsbG8=", "/tmp/.diy-sonos-x");
        assert!(stage.contains("base64 -d"));
        assert!(stage.contains("/tmp/.diy-sonos-x"));
        let install =
            super::install_staged_command("/tmp/.diy-sonos-x", "/etc/snapserver.conf", "644");
        assert!(install.contains("cp '/tmp/.diy-sonos-x' '/etc/snapserver.conf'"));
        assert!(install.contains("chmod 644"));
    }

    #[test]
    fn needs_update_detects_missing_and_diff() {
        assert!(super::needs_update(None, "a"));
        assert!(super::needs_update(Some("a"), "b"));
        assert!(!super::needs_update(Some("a"), "a"));
    }

    #[test]
    fn sudo_wrap_prefixes_sudo_stdin() {
        let wrapped = sudo_wrap("apt-get update");
        assert_eq!(wrapped, "sudo -S -p '' -- apt-get update");
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
