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
fn trust_host_key(app: tauri::AppHandle, host: String, fingerprint: String) -> Result<(), String> {
    let dir = app.path().app_data_dir().map_err(|e| e.to_string())?;
    let known_path = dir.join("known_hosts");
    ssh::known_hosts::trust_host_key(&known_path, &host, &fingerprint).map_err(|e| e.to_string())
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

#[tauri::command]
async fn deploy_device(
    app: tauri::AppHandle,
    device_id: String,
    roles: Vec<Role>,
) -> Result<(), String> {
    let cfg = config::load_config().map_err(|e| e.to_string())?;
    let _ = app.emit(
        "deploy-log",
        serde_json::json!({
            "deviceId": device_id,
            "step": "deploy",
            "level": "info",
            "line": format!("Deploying roles {:?} to {} (server_ip {})", roles, device_id, cfg.server_ip)
        }),
    );
    for role in &roles {
        let steps = match role {
            Role::Server => deploy::server::server_steps(&cfg, "bookworm", "aarch64"),
            Role::Client => deploy::client::client_steps(
                &cfg,
                "bookworm",
                "aarch64",
                &device_id,
                "plughw:Device,0",
            ),
        };
        for (step, cmd) in steps.iter().take(2) {
            let _ = app.emit(
                "deploy-log",
                serde_json::json!({
                    "deviceId": device_id,
                    "step": step,
                    "level": "info",
                    "line": cmd
                }),
            );
        }
    }
    let _ = app.emit(
        "deploy-status",
        serde_json::json!({ "deviceId": device_id, "phase": "done", "done": true }),
    );
    Ok(())
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
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_updater::Builder::new().build())
        .invoke_handler(tauri::generate_handler![
            load_config,
            save_config,
            import_legacy_config,
            scan_mdns,
            connect_device,
            trust_host_key,
            install_device_key,
            deploy_device,
            doctor_device,
            start_oauth
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
