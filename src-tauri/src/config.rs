use serde::{Deserialize, Serialize};
use std::path::PathBuf;
#[allow(dead_code)]
pub const SNAPCAST_VERSION: &str = "0.31.0";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SpotifyConfig {
    #[serde(default = "default_device_name")]
    pub device_name: String,
    #[serde(default = "default_bitrate")]
    pub bitrate: u16,
    #[serde(default = "default_true")]
    pub normalise: bool,
    #[serde(default = "default_initial_volume")]
    pub initial_volume: u8,
    #[serde(default = "default_cache_dir")]
    pub cache_dir: String,
    #[serde(default = "default_oauth_port")]
    pub oauth_callback_port: u16,
    #[serde(default = "default_device_type")]
    pub device_type: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SnapserverConfig {
    #[serde(default = "default_fifo_path")]
    pub fifo_path: String,
    #[serde(default = "default_sampleformat")]
    pub sampleformat: String,
    #[serde(default = "default_codec")]
    pub codec: String,
    #[serde(default = "default_buffer_ms")]
    pub buffer_ms: u32,
    #[serde(default = "default_port")]
    pub port: u16,
    #[serde(default = "default_control_port")]
    pub control_port: u16,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SnapclientConfig {
    #[serde(default = "default_audio_device")]
    pub audio_device: String,
    #[serde(default = "default_output_volume")]
    pub output_volume: u8,
    #[serde(default = "default_latency_ms")]
    pub latency_ms: i16,
    #[serde(default = "default_instance")]
    pub instance: u8,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ClientEntry {
    pub ip: String,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default = "default_ssh_user")]
    pub ssh_user: String,
    #[serde(default = "default_output_volume")]
    pub output_volume: u8,
    #[serde(default)]
    pub latency_ms: i16,
    #[serde(default = "default_audio_device")]
    pub audio_device: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AppConfig {
    #[serde(default = "default_ssh_user")]
    pub ssh_user: String,
    #[serde(default)]
    pub server_ip: String,
    #[serde(default)]
    pub server_combo: bool,
    #[serde(default)]
    pub clients: Vec<ClientEntry>,
    #[serde(default = "default_profile")]
    pub profile: String,
    #[serde(default)]
    pub spotify: SpotifyConfig,
    #[serde(default)]
    pub snapserver: SnapserverConfig,
    #[serde(default)]
    pub snapclient: SnapclientConfig,
}

fn default_device_name() -> String {
    "DIY Sonos".to_string()
}
fn default_bitrate() -> u16 {
    320
}
fn default_true() -> bool {
    true
}
fn default_initial_volume() -> u8 {
    90
}
fn default_cache_dir() -> String {
    "/var/cache/librespot".to_string()
}
fn default_oauth_port() -> u16 {
    4000
}
fn default_device_type() -> String {
    "speaker".to_string()
}
fn default_fifo_path() -> String {
    "/run/diy-sonos/snapfifo".to_string()
}
fn default_sampleformat() -> String {
    "44100:16:2".to_string()
}
fn default_codec() -> String {
    "flac".to_string()
}
fn default_buffer_ms() -> u32 {
    1000
}
fn default_port() -> u16 {
    1704
}
fn default_control_port() -> u16 {
    1780
}
fn default_audio_device() -> String {
    "auto".to_string()
}
fn default_output_volume() -> u8 {
    90
}
fn default_latency_ms() -> i16 {
    0
}
fn default_instance() -> u8 {
    1
}
fn default_ssh_user() -> String {
    "pi".to_string()
}
fn default_profile() -> String {
    "basic".to_string()
}

impl Default for SpotifyConfig {
    fn default() -> Self {
        Self {
            device_name: default_device_name(),
            bitrate: default_bitrate(),
            normalise: true,
            initial_volume: default_initial_volume(),
            cache_dir: default_cache_dir(),
            oauth_callback_port: default_oauth_port(),
            device_type: default_device_type(),
        }
    }
}

impl Default for SnapserverConfig {
    fn default() -> Self {
        Self {
            fifo_path: default_fifo_path(),
            sampleformat: default_sampleformat(),
            codec: default_codec(),
            buffer_ms: default_buffer_ms(),
            port: default_port(),
            control_port: default_control_port(),
        }
    }
}

impl Default for SnapclientConfig {
    fn default() -> Self {
        Self {
            audio_device: default_audio_device(),
            output_volume: default_output_volume(),
            latency_ms: default_latency_ms(),
            instance: default_instance(),
        }
    }
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            ssh_user: default_ssh_user(),
            server_ip: String::new(),
            server_combo: false,
            clients: Vec::new(),
            profile: default_profile(),
            spotify: SpotifyConfig::default(),
            snapserver: SnapserverConfig::default(),
            snapclient: SnapclientConfig::default(),
        }
    }
}

impl AppConfig {
    /// Apply profile tuning preset. Mirrors the preset table in CLAUDE.md.
    /// `basic` keeps defaults; `advanced` maps: codec pcm, buffer_ms 800, snapclient.latency_ms -20.
    pub fn apply_profile(&mut self) {
        match self.profile.as_str() {
            "advanced" => {
                self.snapserver.codec = "pcm".to_string();
                self.snapserver.buffer_ms = 800;
                self.snapclient.latency_ms = -20;
            }
            _ => {
                // basic: keep whatever is already set, but ensure defaults if needed
                if self.snapserver.codec.is_empty() {
                    self.snapserver.codec = default_codec();
                }
                if self.snapserver.buffer_ms == 0 {
                    self.snapserver.buffer_ms = default_buffer_ms();
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Validation helpers — ported from scripts/common.sh:146-219
// ---------------------------------------------------------------------------

pub fn validate_server_ip(value: &str) -> Result<(), String> {
    if value.is_empty() {
        return Err("server_ip must not be empty".to_string());
    }
    let parts: Vec<&str> = value.split('.').collect();
    if parts.len() != 4 {
        return Err(format!(
            "server_ip '{}' must be a valid IPv4 address (example: 192.168.1.100)",
            value
        ));
    }
    for octet in parts {
        if octet.is_empty() || octet.len() > 3 {
            return Err(format!(
                "server_ip '{}' must be a valid IPv4 address (example: 192.168.1.100)",
                value
            ));
        }
        if !octet.chars().all(|c| c.is_ascii_digit()) {
            return Err(format!(
                "server_ip '{}' must be a valid IPv4 address (example: 192.168.1.100)",
                value
            ));
        }
        match octet.parse::<u16>() {
            Ok(n) if n <= 255 => {}
            _ => {
                return Err(format!(
                    "server_ip '{}' has out-of-range octet '{}' (must be 0-255)",
                    value, octet
                ))
            }
        }
    }
    Ok(())
}

pub fn validate_spotify_bitrate(value: u16) -> Result<(), String> {
    match value {
        96 | 160 | 320 => Ok(()),
        _ => Err(format!(
            "spotify.bitrate '{}' is invalid; supported values: 96, 160, 320",
            value
        )),
    }
}

pub fn validate_snapserver_codec(value: &str) -> Result<(), String> {
    match value.to_ascii_lowercase().as_str() {
        "flac" | "pcm" => Ok(()),
        _ => Err(format!(
            "snapserver.codec '{}' is invalid; supported values: flac, pcm",
            value
        )),
    }
}

pub fn validate_snapclient_audio_device(value: &str) -> Result<(), String> {
    if value == "auto" || value == "default" {
        return Ok(());
    }
    // Must match ^(hw|plughw):[0-9]+,[0-9]+$
    if let Some((prefix, rest)) = value.split_once(':') {
        if prefix == "hw" || prefix == "plughw" {
            if let Some((a, b)) = rest.split_once(',') {
                if !a.is_empty()
                    && !b.is_empty()
                    && a.chars().all(|c| c.is_ascii_digit())
                    && b.chars().all(|c| c.is_ascii_digit())
                {
                    return Ok(());
                }
            }
        }
    }
    Err(format!(
        "snapclient.audio_device '{}' must be 'auto', 'default', or an ALSA device like 'hw:1,0'",
        value
    ))
}

pub fn validate_snapclient_output_volume(value: i32) -> Result<(), String> {
    if !(0..=100).contains(&value) {
        return Err(format!(
            "snapclient.output_volume '{}' must be between 0 and 100",
            value
        ));
    }
    Ok(())
}

pub fn validate_snapclient_output_volume_u8(value: u8) -> Result<(), String> {
    // u8 always 0..255, but limit 0..100
    if value > 100 {
        return Err(format!(
            "snapclient.output_volume '{}' must be between 0 and 100",
            value
        ));
    }
    Ok(())
}

/// Validate entire AppConfig, collecting errors. Mirrors common.sh validation used in preflight.
pub fn validate_config(cfg: &AppConfig) -> Result<(), Vec<String>> {
    let mut errors = Vec::new();
    if let Err(e) = validate_server_ip(&cfg.server_ip) {
        // server_ip may be empty before wizard; only error if set? But spec says must not be empty.
        // Keep error for validation callers; wizard may allow empty transiently.
        errors.push(e);
    }
    if let Err(e) = validate_spotify_bitrate(cfg.spotify.bitrate) {
        errors.push(e);
    }
    if let Err(e) = validate_snapserver_codec(&cfg.snapserver.codec) {
        errors.push(e);
    }
    if let Err(e) = validate_snapclient_audio_device(&cfg.snapclient.audio_device) {
        errors.push(e);
    }
    if let Err(e) = validate_snapclient_output_volume_u8(cfg.snapclient.output_volume) {
        errors.push(e);
    }
    for client in &cfg.clients {
        if let Err(e) = validate_server_ip(&client.ip) {
            errors.push(format!("clients[].ip '{}': {}", client.ip, e));
        }
        if let Err(e) = validate_snapclient_output_volume_u8(client.output_volume) {
            errors.push(format!("clients[{}].output_volume: {}", client.ip, e));
        }
        if let Err(e) = validate_snapclient_audio_device(&client.audio_device) {
            errors.push(format!("clients[{}].audio_device: {}", client.ip, e));
        }
    }
    if errors.is_empty() {
        Ok(())
    } else {
        Err(errors)
    }
}

/// Effective output volume for a given device IP.
/// Mirrors `get_effective_snapclient_output_volume` in common.sh:146-219 and `get_client_output_volume_for_ip`.
/// Priority: per-client override for that IP if valid 0-100, else global snapclient.output_volume if valid, else 90.
pub fn effective_output_volume_for_ip(cfg: &AppConfig, ip: &str) -> u8 {
    let global = cfg.snapclient.output_volume;
    let global_valid = (0..=100).contains(&global);
    let mut effective = if global_valid { global } else { 90 };

    for entry in &cfg.clients {
        if entry.ip == ip {
            if entry.output_volume <= 100 {
                effective = entry.output_volume;
            }
            break;
        }
    }
    if effective > 100 {
        90
    } else {
        effective
    }
}

fn config_path() -> Result<PathBuf, anyhow::Error> {
    if let Some(dir) = dirs_next() {
        Ok(dir.join("config.yml"))
    } else {
        Ok(PathBuf::from("config.yml"))
    }
}

fn dirs_next() -> Option<PathBuf> {
    if let Ok(xdg) = std::env::var("XDG_CONFIG_HOME") {
        if !xdg.is_empty() {
            return Some(PathBuf::from(xdg).join("dev.jeffcottj.diy-sonos"));
        }
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() {
            return Some(
                PathBuf::from(home)
                    .join(".config")
                    .join("dev.jeffcottj.diy-sonos"),
            );
        }
    }
    None
}

pub fn load_config() -> Result<AppConfig, anyhow::Error> {
    let path = config_path()?;
    if !path.exists() {
        return Ok(AppConfig::default());
    }
    let content = std::fs::read_to_string(&path)?;
    let mut cfg: AppConfig = serde_yaml::from_str(&content)?;
    // Unknown keys are ignored by serde_yaml by default (no deny_unknown_fields)
    // Apply profile mapping if needed? Keep as stored; caller may apply.
    if cfg.profile.is_empty() {
        cfg.profile = default_profile();
    }
    Ok(cfg)
}

pub fn save_config(cfg: &AppConfig) -> Result<(), anyhow::Error> {
    let path = config_path()?;
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let content = serde_yaml::to_string(cfg)?;
    std::fs::write(&path, content)?;
    Ok(())
}

/// Parse a legacy `config.yml` file path (old repo shape) into AppConfig.
/// Accepts old shape including `clients[].ip/ssh_user/output_volume` and ignores unknown keys.
/// Returns an AppConfig with defaults for missing fields.
pub fn import_legacy_config(path: &str) -> Result<AppConfig, anyhow::Error> {
    let content = std::fs::read_to_string(path)?;
    let mut cfg: AppConfig = serde_yaml::from_str(&content)?;
    // Normalize defaults for fields that may be missing in legacy file
    if cfg.snapclient.audio_device.is_empty() {
        cfg.snapclient.audio_device = default_audio_device();
    }
    if cfg.profile.is_empty() {
        cfg.profile = default_profile();
    }
    // Legacy `clients` entries may lack new fields `name`, `latency_ms`, `audio_device`.
    // Those already have defaults via serde `default` attributes; but ensure audio_device fallback.
    for client in &mut cfg.clients {
        if client.audio_device.is_empty() {
            client.audio_device = default_audio_device();
        }
        if client.ssh_user.is_empty() {
            client.ssh_user = default_ssh_user();
        }
    }
    Ok(cfg)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_spec() {
        let cfg = AppConfig::default();
        assert_eq!(cfg.spotify.device_name, "DIY Sonos");
        assert_eq!(cfg.spotify.bitrate, 320);
        assert!(cfg.spotify.normalise);
        assert_eq!(cfg.spotify.initial_volume, 90);
        assert_eq!(cfg.spotify.cache_dir, "/var/cache/librespot");
        assert_eq!(cfg.spotify.oauth_callback_port, 4000);
        assert_eq!(cfg.spotify.device_type, "speaker");
        assert_eq!(cfg.snapserver.fifo_path, "/run/diy-sonos/snapfifo");
        assert_eq!(cfg.snapserver.sampleformat, "44100:16:2");
        assert_eq!(cfg.snapserver.codec, "flac");
        assert_eq!(cfg.snapserver.buffer_ms, 1000);
        assert_eq!(cfg.snapserver.port, 1704);
        assert_eq!(cfg.snapserver.control_port, 1780);
        assert_eq!(cfg.snapclient.audio_device, "auto");
        assert_eq!(cfg.snapclient.output_volume, 90);
        assert_eq!(cfg.snapclient.latency_ms, 0);
        assert_eq!(cfg.snapclient.instance, 1);
        assert_eq!(SNAPCAST_VERSION, "0.31.0");
    }

    #[test]
    fn profile_basic_keeps_defaults() {
        let mut cfg = AppConfig::default();
        cfg.profile = "basic".to_string();
        cfg.snapserver.codec = "flac".to_string();
        cfg.snapserver.buffer_ms = 1000;
        cfg.snapclient.latency_ms = 0;
        cfg.apply_profile();
        assert_eq!(cfg.snapserver.codec, "flac");
        assert_eq!(cfg.snapserver.buffer_ms, 1000);
        assert_eq!(cfg.snapclient.latency_ms, 0);
    }

    #[test]
    fn profile_advanced_maps_values() {
        let mut cfg = AppConfig::default();
        cfg.profile = "advanced".to_string();
        cfg.apply_profile();
        assert_eq!(cfg.snapserver.codec, "pcm");
        assert_eq!(cfg.snapserver.buffer_ms, 800);
        assert_eq!(cfg.snapclient.latency_ms, -20);
        // Other defaults unchanged
        assert_eq!(cfg.spotify.bitrate, 320);
        assert_eq!(cfg.snapclient.output_volume, 90);
    }

    #[test]
    fn validate_server_ip_cases() {
        assert!(validate_server_ip("192.168.1.100").is_ok());
        assert!(validate_server_ip("0.0.0.0").is_ok());
        assert!(validate_server_ip("255.255.255.255").is_ok());
        assert!(validate_server_ip("").is_err());
        assert!(validate_server_ip("999.1.1.1").is_err());
        assert!(validate_server_ip("abc").is_err());
        assert!(validate_server_ip("192.168.1").is_err());
        assert!(validate_server_ip("192.168.1.999").is_err());
    }

    #[test]
    fn validate_bitrate_cases() {
        assert!(validate_spotify_bitrate(96).is_ok());
        assert!(validate_spotify_bitrate(160).is_ok());
        assert!(validate_spotify_bitrate(320).is_ok());
        assert!(validate_spotify_bitrate(128).is_err());
        assert!(validate_spotify_bitrate(0).is_err());
    }

    #[test]
    fn validate_codec_cases() {
        assert!(validate_snapserver_codec("flac").is_ok());
        assert!(validate_snapserver_codec("FLAC").is_ok());
        assert!(validate_snapserver_codec("pcm").is_ok());
        assert!(validate_snapserver_codec("PCM").is_ok());
        assert!(validate_snapserver_codec("ogg").is_err());
        assert!(validate_snapserver_codec("").is_err());
    }

    #[test]
    fn validate_audio_device_cases() {
        assert!(validate_snapclient_audio_device("auto").is_ok());
        assert!(validate_snapclient_audio_device("default").is_ok());
        assert!(validate_snapclient_audio_device("hw:1,0").is_ok());
        assert!(validate_snapclient_audio_device("plughw:2,0").is_ok());
        assert!(validate_snapclient_audio_device("plughw:10,1").is_ok());
        assert!(validate_snapclient_audio_device("foo").is_err());
        assert!(validate_snapclient_audio_device("hw:1").is_err());
        assert!(validate_snapclient_audio_device("hw:a,b").is_err());
    }

    #[test]
    fn validate_output_volume_cases() {
        assert!(validate_snapclient_output_volume(0).is_ok());
        assert!(validate_snapclient_output_volume(50).is_ok());
        assert!(validate_snapclient_output_volume(100).is_ok());
        assert!(validate_snapclient_output_volume(-1).is_err());
        assert!(validate_snapclient_output_volume(101).is_err());
    }

    #[test]
    fn legacy_import_accepts_old_shape() {
        let yaml = r#"
ssh_user: "pi"
server_ip: "192.168.1.10"
clients:
  - ip: "192.168.1.121"
    ssh_user: "pi"
    output_volume: 85
spotify:
  device_name: "DIY Sonos"
  bitrate: 320
"#;
        let cfg: AppConfig = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(cfg.server_ip, "192.168.1.10");
        assert_eq!(cfg.clients.len(), 1);
        assert_eq!(cfg.clients[0].ip, "192.168.1.121");
        assert_eq!(cfg.clients[0].output_volume, 85);
        // Defaults for missing new fields
        assert_eq!(cfg.snapclient.audio_device, "auto");
        assert_eq!(cfg.profile, "basic");
        // snapserver defaults preserved
        assert_eq!(cfg.snapserver.codec, "flac");
    }

    #[test]
    fn legacy_import_ignores_unknown_keys() {
        let yaml = r#"
ssh_user: "pi"
server_ip: "192.168.1.10"
unknown_top_level: "should be ignored"
spotify:
  device_name: "Test"
  unknown_nested: 123
  bitrate: 160
"#;
        let cfg: AppConfig = serde_yaml::from_str(yaml).unwrap();
        assert_eq!(cfg.spotify.device_name, "Test");
        assert_eq!(cfg.spotify.bitrate, 160);
    }

    #[test]
    fn effective_volume_resolution() {
        let mut cfg = AppConfig::default();
        cfg.snapclient.output_volume = 90;
        cfg.clients = vec![
            ClientEntry {
                ip: "192.168.1.121".to_string(),
                name: None,
                ssh_user: "pi".to_string(),
                output_volume: 70,
                latency_ms: 0,
                audio_device: "auto".to_string(),
            },
            ClientEntry {
                ip: "192.168.1.122".to_string(),
                name: None,
                ssh_user: "pi".to_string(),
                output_volume: 80,
                latency_ms: 0,
                audio_device: "auto".to_string(),
            },
        ];
        assert_eq!(effective_output_volume_for_ip(&cfg, "192.168.1.121"), 70);
        assert_eq!(effective_output_volume_for_ip(&cfg, "192.168.1.122"), 80);
        // Unknown IP falls back to global
        assert_eq!(effective_output_volume_for_ip(&cfg, "192.168.1.200"), 90);
        // Invalid global fallback to 90
        cfg.snapclient.output_volume = 200; // >100 invalid, but u8 200 >100; test fallback
        cfg.clients.clear();
        assert_eq!(effective_output_volume_for_ip(&cfg, "192.168.1.121"), 90);
    }

    #[test]
    fn import_legacy_file_roundtrip() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("legacy.yml");
        std::fs::write(
            &path,
            r#"
server_ip: "192.168.1.100"
clients:
  - ip: "192.168.1.121"
    output_volume: 90
spotify:
  device_name: "DIY Sonos"
"#,
        )
        .unwrap();
        let cfg = import_legacy_config(path.to_str().unwrap()).unwrap();
        assert_eq!(cfg.server_ip, "192.168.1.100");
        assert_eq!(cfg.clients[0].ip, "192.168.1.121");
    }
}
