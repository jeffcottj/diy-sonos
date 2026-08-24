//! Client role deployment — port of `scripts/setup-client.sh`.

use crate::config::AppConfig;
use crate::deploy::deb;
use crate::template::{vars_from_config, SNAPCLIENT_SERVICE_TMPL};

/// Resolve effective audio device string for client deployment.
/// If cfg snapclient.audio_device == "auto", caller should have fetched `/proc/asound/cards` + `aplay -l` over SSH
/// and run `crate::deploy::audio::detect_device`. This function just selects the string to use in the template.
pub fn resolved_audio_device(cfg: &AppConfig, detected: &str) -> String {
    if cfg.snapclient.audio_device == "auto" {
        detected.to_string()
    } else {
        cfg.snapclient.audio_device.clone()
    }
}

/// Effective output volume for this client device IP, per `get_effective_snapclient_output_volume`.
pub fn effective_volume(cfg: &AppConfig, device_ip: &str) -> u8 {
    crate::config::effective_output_volume_for_ip(cfg, device_ip)
}

pub fn client_steps(
    cfg: &AppConfig,
    os_codename: &str,
    arch_uname: &str,
    device_ip: &str,
    detected_audio_device: &str,
) -> Vec<(String, String)> {
    let mut steps = Vec::new();
    let arch_deb = deb::deb_arch(arch_uname);
    let snap_url = deb::snapcast_deb_url(
        "snapclient",
        crate::config::SNAPCAST_VERSION,
        arch_deb,
        os_codename,
    );
    let resolved = resolved_audio_device(cfg, detected_audio_device);
    let vol = effective_volume(cfg, device_ip);

    steps.push((
        "detect-os".to_string(),
        "cat /etc/os-release; uname -m".to_string(),
    ));
    steps.push((
        "apt-update-if-stale".to_string(),
        "apt_update_if_stale (skip if <1h)".to_string(),
    ));
    steps.push((
        "install-base-deps".to_string(),
        "dpkg -s wget curl ca-certificates alsa-utils >/dev/null 2>&1 || apt-get install -y wget curl ca-certificates alsa-utils".to_string(),
    ));
    steps.push((
        "cleanup-legacy".to_string(),
        "cleanup_legacy_for_role client".to_string(),
    ));
    steps.push((
        "install-snapclient".to_string(),
        format!(
            "install_deb {} (arch {} codename {})",
            snap_url, arch_deb, os_codename
        ),
    ));
    // Combo handling: snapclient deb may pull in snapserver, mask on client-only
    let is_combo = cfg.server_combo && cfg.server_ip == device_ip;
    if is_combo {
        steps.push((
            "combo-keep-snapserver".to_string(),
            "DIY_SONOS_COMBO_ROLE=1 keep snapserver".to_string(),
        ));
    } else {
        steps.push((
            "mask-snapserver".to_string(),
            "systemctl mask snapserver.service 2>/dev/null || true; systemctl stop snapserver.service 2>/dev/null || true".to_string(),
        ));
    }
    steps.push((
        "resolve-audio".to_string(),
        format!(
            "resolve_audio_device {} -> {}",
            cfg.snapclient.audio_device, resolved
        ),
    ));
    if resolved == "default" {
        steps.push((
            "warn-default-audio".to_string(),
            "Warning: no suitable audio hardware, fallback to 'default' will NOT work for snapclient.service on modern Pi OS".to_string(),
        ));
    }
    steps.push((
        "set-volume".to_string(),
        format!(
            "amixer set Master {}% || amixer set PCM {}% || true; alsactl store || true (effective {}% global {}% )",
            vol,
            vol,
            vol,
            cfg.snapclient.output_volume
        ),
    ));
    // Boot-time volume restore service
    steps.push((
        "alsa-restore-service".to_string(),
        format!(
            "cat > /usr/local/bin/diy-sonos-apply-volume <<'EOSVC'\n#!/usr/bin/env bash\namixer set Master {}% || true\nEOSVC\nchmod +x /usr/local/bin/diy-sonos-apply-volume\ncat > /etc/systemd/system/diy-sonos-alsa-volume.service <<'EOSVC'\n[Unit]\nDescription=DIY Sonos ALSA volume restore\nAfter=sound.target\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/diy-sonos-apply-volume\n[Install]\nWantedBy=multi-user.target\nEOSVC\nsystemctl daemon-reload; systemctl enable diy-sonos-alsa-volume.service",
            vol
        ),
    ));
    steps.push((
        "enable-alsa-restore".to_string(),
        "systemctl enable alsa-restore.service 2>/dev/null || systemctl enable alsa-state.service 2>/dev/null || true".to_string(),
    ));
    // Render snapclient.service with resolved device, server_ip, latency, instance, volume via template vars
    let vars = vars_from_config(cfg, &resolved);
    let rendered =
        crate::template::render_template(SNAPCLIENT_SERVICE_TMPL, &vars).unwrap_or_default();
    steps.push((
        "render-snapclient-service".to_string(),
        format!("render /etc/systemd/system/snapclient.service ({} bytes) server {} device {} latency {} instance {}", rendered.len(), cfg.server_ip, resolved, cfg.snapclient.latency_ms, cfg.snapclient.instance),
    ));
    steps.push((
        "enable-snapclient".to_string(),
        "systemctl daemon-reload; if [ $_config_changed -eq 1 ]; then systemctl enable snapclient; systemctl restart snapclient || systemctl start snapclient; fi".to_string(),
    ));

    steps
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AppConfig;

    #[test]
    fn resolves_auto_vs_explicit() {
        let mut cfg = AppConfig::default();
        cfg.snapclient.audio_device = "auto".to_string();
        assert_eq!(
            resolved_audio_device(&cfg, "plughw:Device,0"),
            "plughw:Device,0"
        );
        cfg.snapclient.audio_device = "hw:1,0".to_string();
        assert_eq!(resolved_audio_device(&cfg, "plughw:Device,0"), "hw:1,0");
    }

    #[test]
    fn effective_volume_prefers_per_client() {
        let mut cfg = AppConfig::default();
        cfg.server_ip = "192.168.1.100".to_string();
        cfg.snapclient.output_volume = 90;
        cfg.clients.push(crate::config::ClientEntry {
            ip: "192.168.1.121".to_string(),
            name: None,
            ssh_user: "pi".to_string(),
            output_volume: 70,
            latency_ms: 0,
            audio_device: "auto".to_string(),
        });
        assert_eq!(effective_volume(&cfg, "192.168.1.121"), 70);
        assert_eq!(effective_volume(&cfg, "192.168.1.122"), 90);
    }

    #[test]
    fn client_steps_contain_critical_commands() {
        let cfg = AppConfig::default();
        let steps = client_steps(
            &cfg,
            "bookworm",
            "aarch64",
            "192.168.1.121",
            "plughw:Device,0",
        );
        let all = steps
            .iter()
            .map(|(_, c)| c.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(all.contains("snapclient"), "must contain snapclient deb");
        assert!(
            all.contains("diy-sonos-alsa-volume"),
            "must create alsa volume service"
        );
        assert!(
            all.contains("snapclient.service"),
            "must render snapclient service"
        );
        assert!(all.contains("amixer"), "must set ALSA volume");
    }

    #[test]
    fn client_masks_snapserver_unless_combo() {
        let mut cfg = AppConfig::default();
        cfg.server_ip = "192.168.1.100".to_string();
        cfg.server_combo = false;
        let steps = client_steps(&cfg, "bookworm", "aarch64", "192.168.1.121", "default");
        let all = steps
            .iter()
            .map(|(_, c)| c.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(all.contains("mask snapserver.service"));
        // Combo when device_ip == server_ip
        cfg.server_combo = true;
        let steps_combo = client_steps(&cfg, "bookworm", "aarch64", "192.168.1.100", "default");
        let all_combo = steps_combo
            .iter()
            .map(|(_, c)| c.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(all_combo.contains("keep snapserver"));
        assert!(!all_combo.contains("mask snapserver.service"));
    }
}
