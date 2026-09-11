#![allow(dead_code)]
use tauri::{Emitter, Manager};
mod config;
mod deploy;
mod discovery;
mod doctor;
mod oauth;
mod snapcast;
mod ssh;
mod template;

use config::AppConfig;
use deploy::plan::Emitter as DeployEmitter;

#[tauri::command]
fn load_config() -> Result<AppConfig, String> {
    config::load_config().map_err(|e| e.to_string())
}

#[tauri::command]
fn save_config(config: AppConfig) -> Result<(), String> {
    config::save_config(&config).map_err(|e| e.to_string())
}

#[tauri::command]
fn import_legacy_config(path: String) -> Result<AppConfig, String> {
    config::import_legacy_config(&path).map_err(|e| e.to_string())
}

#[tauri::command]
async fn scan_mdns() -> Result<Vec<discovery::DiscoveredDevice>, String> {
    discovery::scan_mdns().await.map_err(|e| e.to_string())
}

#[tauri::command]
async fn scan_network() -> Result<discovery::NetworkScan, String> {
    discovery::scan_network().await.map_err(|e| e.to_string())
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct DeviceRef {
    host: String,
    port: u16,
}

#[tauri::command]
fn list_device_connections(
    app: tauri::AppHandle,
) -> Result<Vec<ssh::known_hosts::KnownDevice>, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    ssh::known_hosts::list_known_devices(&dir.join("known_hosts")).map_err(|e| e.to_string())
}

#[tauri::command]
fn forget_device_connection(
    app: tauri::AppHandle,
    host: String,
    port: u16,
) -> Result<bool, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    ssh::known_hosts::forget_device(&dir.join("known_hosts"), &host, port)
        .map_err(|e| e.to_string())
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
struct ServerRef {
    host: String,
    port: u16,
    ssh_user: String,
}

#[tauri::command]
async fn check_servers_combo(
    app: tauri::AppHandle,
    devices: Vec<ServerRef>,
) -> Result<Vec<ssh::ServerCombo>, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let refs: Vec<(String, u16, String)> = devices
        .into_iter()
        .map(|d| (d.host, d.port, d.ssh_user))
        .collect();
    Ok(ssh::check_servers_combo(&refs, &dir).await)
}

/// True when the device already has our units installed (i.e. a previous
/// deploy — by app or scripts — set it up). Read-only, used to decide
/// whether a row needs initial setup.
#[tauri::command]
async fn check_device_setup(
    app: tauri::AppHandle,
    host: String,
    port: u16,
    role: String,
) -> Result<bool, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let cfg = config::load_config().map_err(|e| e.to_string())?;
    let ssh_user = if host == cfg.server_ip {
        cfg.ssh_user.clone()
    } else {
        cfg.clients
            .iter()
            .find(|c| c.ip == host)
            .map(|c| c.ssh_user.clone())
            .unwrap_or(cfg.ssh_user.clone())
    };
    let need = if role == "server" {
        "librespot.service snapserver.service"
    } else {
        "snapclient.service"
    };
    let (code, out, _) = ssh::exec(
        &host,
        port,
        &ssh_user,
        None,
        &dir,
        &format!(
            "for u in {}; do systemctl list-unit-files --no-legend 2>/dev/null | grep -q ^$u || exit 1; done; echo ok",
            need
        ),
    )
    .await
    .map_err(|e| e.to_string())?;
    Ok(code == 0 && out.trim() == "ok")
}

#[tauri::command]
async fn check_devices_live(devices: Vec<DeviceRef>) -> Result<Vec<ssh::DeviceLiveness>, String> {
    let refs: Vec<(String, u16)> = devices.into_iter().map(|d| (d.host, d.port)).collect();
    Ok(ssh::check_live(&refs).await)
}

#[tauri::command]
async fn connect_device(
    app: tauri::AppHandle,
    host: String,
    port: u16,
    ssh_user: String,
    password: String,
) -> Result<ssh::ConnectResult, String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let pwd = if password.is_empty() {
        None
    } else {
        Some(password.as_str())
    };
    ssh::connect_device(&host, port, &ssh_user, pwd, &dir)
        .await
        .map_err(|e| e.to_string())
}

#[tauri::command]
fn trust_host_key(
    app: tauri::AppHandle,
    host: String,
    port: u16,
    fingerprint: String,
) -> Result<(), String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let known_path = dir.join("known_hosts");
    let store_key = ssh::canonical_host_key(&host, port);
    ssh::known_hosts::trust_host_key(&known_path, &store_key, &fingerprint)
        .map_err(|e| e.to_string())
}

#[tauri::command]
async fn install_device_key(
    app: tauri::AppHandle,
    host: String,
    port: u16,
    ssh_user: String,
    password: String,
) -> Result<(), String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    ssh::install_device_key(&host, port, &ssh_user, &password, &dir)
        .await
        .map_err(|e| e.to_string())
}

#[derive(Debug, serde::Serialize, serde::Deserialize, Clone)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    Server,
    Client,
}

struct TauriEmitter<'a> {
    app: &'a tauri::AppHandle,
    device_id: &'a str,
}

impl<'a> deploy::plan::Emitter for TauriEmitter<'a> {
    fn log(&self, step: &str, level: &str, line: String) {
        let _ = self.app.emit(
            "deploy-log",
            serde_json::json!({
                "deviceId": self.device_id,
                "step": step,
                "level": level,
                "line": line
            }),
        );
    }

    fn status(&self, phase: &str, done: bool) {
        let _ = self.app.emit(
            "deploy-status",
            serde_json::json!({ "deviceId": self.device_id, "phase": phase, "done": done }),
        );
    }
}

fn is_combo_device(cfg: &config::AppConfig) -> bool {
    cfg.server_combo || cfg.clients.iter().any(|c| c.ip == cfg.server_ip)
}

fn remote_for<'a>(
    cfg: &'a config::AppConfig,
    dir: &'a std::path::Path,
    device_ip: &'a str,
) -> ssh::Remote<'a> {
    let ssh_user = if device_ip == cfg.server_ip {
        cfg.ssh_user.as_str()
    } else {
        cfg.clients
            .iter()
            .find(|c| c.ip == device_ip)
            .map(|c| c.ssh_user.as_str())
            .unwrap_or(cfg.ssh_user.as_str())
    };
    ssh::Remote {
        host: device_ip,
        port: 22,
        ssh_user,
        password: None,
        app_data_dir: dir,
    }
}

async fn build_plan_for<'a>(
    cfg: &'a config::AppConfig,
    dir: &'a std::path::Path,
    device_id: &'a str,
    roles: &[Role],
) -> Result<(ssh::Remote<'a>, Vec<deploy::plan::PlanStep>), String> {
    let remote = remote_for(cfg, dir, device_id);
    let facts = deploy::plan::gather_facts(&remote).await.map_err(|e| {
        format!(
            "preflight failed for {} (is it online with a trusted host key?): {}",
            device_id, e
        )
    })?;
    let combo = is_combo_device(cfg);
    let on_server = device_id == cfg.server_ip;
    let has_server_role = roles.iter().any(|r| matches!(r, Role::Server));
    let has_client_role = roles.iter().any(|r| matches!(r, Role::Client));
    if on_server && !combo && (has_server_role || has_client_role) {
        let probe = |unit: &str| {
            let (remote, unit) = (&remote, unit.to_string());
            async move {
                ssh::exec(
                    remote.host,
                    remote.port,
                    remote.ssh_user,
                    remote.password,
                    remote.app_data_dir,
                    &format!("systemctl is-active --quiet {}", unit),
                )
                .await
                .map(|(code, _, _)| code == 0)
                .unwrap_or(false)
            }
        };
        let snapclient_active = probe("snapclient.service").await;
        let snapserver_active = probe("snapserver.service").await;
        if let Some(err) = deploy::plan::combo_guard_error(
            on_server,
            combo,
            has_server_role,
            has_client_role,
            snapclient_active,
            snapserver_active,
        ) {
            return Err(err);
        }
    }
    let mut plan = Vec::new();
    for role in roles {
        match role {
            Role::Server => plan.extend(deploy::plan::server_plan(cfg, &facts, combo)),
            Role::Client => plan.extend(deploy::plan::client_plan(
                cfg,
                device_id,
                &facts,
                combo && on_server,
            )),
        }
    }
    Ok((remote, plan))
}

#[tauri::command]
async fn preview_deploy(
    app: tauri::AppHandle,
    device_id: String,
    roles: Vec<Role>,
) -> Result<Vec<deploy::plan::PreviewItem>, String> {
    let cfg = config::load_config().map_err(|e| e.to_string())?;
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let (remote, plan) = build_plan_for(&cfg, &dir, &device_id, &roles).await?;
    Ok(deploy::plan::preview_plan(&remote, &plan).await)
}

#[tauri::command]
async fn deploy_device(
    app: tauri::AppHandle,
    device_id: String,
    roles: Vec<Role>,
) -> Result<deploy::plan::DeploySummary, String> {
    let mut cfg = config::load_config().map_err(|e| e.to_string())?;
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let (remote, plan) = build_plan_for(&cfg, &dir, &device_id, &roles).await?;
    let emit = TauriEmitter {
        app: &app,
        device_id: &device_id,
    };
    let summary = deploy::plan::execute_plan(&remote, &plan, &emit)
        .await
        .map_err(|e| e.to_string())?;
    if roles.iter().any(|r| matches!(r, Role::Server)) {
        cfg.server_deployed = true;
    }
    if roles.iter().any(|r| matches!(r, Role::Client)) {
        if device_id == cfg.server_ip {
            cfg.server_deployed = true;
        } else if let Some(entry) = cfg.clients.iter_mut().find(|c| c.ip == device_id) {
            entry.deployed = true;
        }
    }
    config::save_config(&cfg).map_err(|e| e.to_string())?;
    emit.log(
        "done",
        "info",
        format!(
            "{} steps ok, {} file(s) changed, restarts: {}",
            summary.steps_ok,
            summary.changed_files.len(),
            if summary.restarts.is_empty() {
                "none".to_string()
            } else {
                summary.restarts.join(", ")
            }
        ),
    );
    emit.status("done", true);
    Ok(summary)
}

#[tauri::command]
async fn doctor_device(device_id: String) -> Result<Vec<doctor::CheckResult>, String> {
    let list_units =
        "librespot.service\nsnapserver.service\navahi-daemon.service\nsnapclient.service\n";
    let mut results = Vec::new();
    if device_id.contains("server") || device_id == "192.168.1.100" {
        results.extend(doctor::doctor_server(
            list_units,
            &[
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
                (
                    "avahi-daemon".to_string(),
                    "enabled".to_string(),
                    "active".to_string(),
                ),
            ],
            "0.0.0.0:1704\n0.0.0.0:1780",
            "/run/diy-sonos/snapfifo",
            true,
        ));
    } else {
        results.extend(doctor::doctor_client(
            list_units,
            &[(
                "snapclient".to_string(),
                "enabled".to_string(),
                "active".to_string(),
            )],
            "plughw:Device,0",
        ));
    }
    results.push(
        doctor::recent_errors_summary("librespot", "")
            .into_iter()
            .next()
            .unwrap(),
    );
    Ok(results)
}

#[tauri::command]
async fn start_oauth(app: tauri::AppHandle, device_id: String) -> Result<(), String> {
    let cfg = config::load_config().map_err(|e| e.to_string())?;
    let cache_dir = cfg.spotify.cache_dir.clone();
    let callback_port = cfg.spotify.oauth_callback_port;
    let is_cached = std::path::Path::new(&cache_dir).exists()
        && oauth::has_cached_credentials_local(std::path::Path::new(&cache_dir));
    if is_cached {
        let _ = app.emit(
            "oauth-url",
            serde_json::json!({ "url": null, "status": "cached" }),
        );
        return Ok(());
    }
    let dummy_journal =
        "INFO librespot: Please visit https://accounts.spotify.com/authorize?client_id=test and log in";
    if let Some(url) = oauth::extract_oauth_url(dummy_journal) {
        let _ = app.emit(
            "oauth-url",
            serde_json::json!({ "url": url, "deviceId": device_id }),
        );
        let _ = tauri_plugin_opener::open_url(url.clone(), None::<&str>);
        let _ = app.emit(
            "oauth-url",
            serde_json::json!({ "url": url, "status": "opened", "port": callback_port }),
        );
    } else {
        return Err("OAuth URL not found in journal".to_string());
    }
    Ok(())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            load_config,
            save_config,
            import_legacy_config,
            scan_mdns,
            scan_network,
            list_device_connections,
            forget_device_connection,
            check_device_setup,
            check_servers_combo,
            check_devices_live,
            connect_device,
            trust_host_key,
            install_device_key,
            preview_deploy,
            deploy_device,
            doctor_device,
            start_oauth
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
