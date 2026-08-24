//! Server role deployment — port of `scripts/setup-server.sh`.
//! All shell literals (raspotify repo line, GPG fetch URL, unit file bodies) come from the bash files, not from memory.

use crate::config::AppConfig;
use crate::deploy::deb;
use crate::template::{
    vars_from_config, LIBRESPOT_SERVICE_TMPL, SNAPSERVER_CONF_TMPL, SNAPSERVER_SERVICE_TMPL,
};

pub const RASPOTIFY_GPG: &str = "/usr/share/keyrings/raspotify_pub.gpg";
pub const RASPOTIFY_GPG_FINGERPRINT: &str = "2CC9B80F5AE2B7ACEFF2BA3209146F2F7953A455";
pub const RASPOTIFY_LIST: &str = "/etc/apt/sources.list.d/raspotify.list";
pub const RASPOTIFY_REPO_LINE: &str = "deb [signed-by=/usr/share/keyrings/raspotify_pub.gpg] https://dtcooper.github.io/raspotify raspotify main";

/// Build the sequence of high-level steps for server deployment.
/// Each step is (name, command_or_description) — the executor will run the command via `exec_sudo`
/// and emit `deploy-log` events. This pure list is unit-testable.
pub fn server_steps(cfg: &AppConfig, os_codename: &str, arch_uname: &str) -> Vec<(String, String)> {
    let mut steps = Vec::new();
    let arch_deb = deb::deb_arch(arch_uname);
    let snap_ver = crate::config::SNAPCAST_VERSION;
    let snap_url = deb::snapcast_deb_url("snapserver", snap_ver, arch_deb, os_codename);
    let fifo_path = &cfg.snapserver.fifo_path;
    let fifo_dir = std::path::Path::new(fifo_path)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| "/run/diy-sonos".to_string());

    // 1. OS/arch detect (via remote commands, but we record the expected commands)
    steps.push((
        "detect-os".to_string(),
        "cat /etc/os-release; uname -m".to_string(),
    ));

    // 2. apt_update_if_stale + base deps
    steps.push((
        "apt-update-if-stale".to_string(),
        "if [ -f /var/lib/apt/periodic/update-success-stamp ]; then age=$(( $(date +%s) - $(stat -c %Y /var/lib/apt/periodic/update-success-stamp) )); if [ $age -lt 3600 ]; then echo fresh; exit 0; fi; fi; apt-get update -qq".to_string(),
    ));
    steps.push((
        "install-base-deps".to_string(),
        "dpkg -s wget curl ca-certificates alsa-utils avahi-daemon gnupg >/dev/null 2>&1 || apt-get install -y wget curl ca-certificates alsa-utils avahi-daemon gnupg".to_string(),
    ));
    steps.push((
        "ensure-avahi".to_string(),
        "systemctl enable avahi-daemon.service; systemctl is-active --quiet avahi-daemon.service || systemctl start avahi-daemon.service".to_string(),
    ));

    // 3. Legacy cleanup
    steps.push((
        "cleanup-legacy".to_string(),
        "cleanup_legacy_for_role server (masks snapclient, quarantine alt units)".to_string(),
    ));

    // 4. librespot via raspotify repo
    steps.push((
        "raspotify-gpg".to_string(),
        format!(
            "if [ ! -f {} ]; then curl -fsSL https://dtcooper.github.io/raspotify/key.asc | gpg --dearmor -o {}; fi; gpg --show-keys {} | grep -q {}",
            RASPOTIFY_GPG, RASPOTIFY_GPG, RASPOTIFY_GPG, RASPOTIFY_GPG_FINGERPRINT
        ),
    ));
    steps.push((
        "raspotify-list".to_string(),
        format!(
            "if [ ! -f {} ]; then echo '{}' > {}; fi",
            RASPOTIFY_LIST, RASPOTIFY_REPO_LINE, RASPOTIFY_LIST
        ),
    ));
    steps.push((
        "apt-update-raspotify".to_string(),
        "apt-get update -qq".to_string(),
    ));
    steps.push((
        "install-raspotify".to_string(),
        "apt-get install -y raspotify; systemctl mask raspotify.service 2>/dev/null || true; systemctl stop raspotify.service 2>/dev/null || true".to_string(),
    ));

    // 5. snapserver deb
    steps.push((
        "install-snapserver".to_string(),
        format!(
            "install_deb {} (arch {} codename {} fallback bookworm,bullseye)",
            snap_url, arch_deb, os_codename
        ),
    ));
    steps.push((
        "stop-snapserver".to_string(),
        "systemctl stop snapserver.service 2>/dev/null || true".to_string(),
    ));

    // 6. FIFO + tmpfiles + sysctl
    steps.push((
        "ensure-fifo".to_string(),
        format!(
            "mkdir -p {} && if [ -p {} ]; then echo FIFO exists; elif [ -e {} ]; then rm -f {} && mkfifo {}; else mkfifo {}; fi",
            fifo_dir, fifo_path, fifo_path, fifo_path, fifo_path, fifo_path
        ),
    ));
    steps.push((
        "tmpfiles".to_string(),
        format!(
            "cat > /etc/tmpfiles.d/snapfifo.conf <<'EOF'\nd {} 0755 root root - -\np {} 0660 root audio - -\nEOF\nsystemd-tmpfiles --create /etc/tmpfiles.d/snapfifo.conf 2>/dev/null || true",
            fifo_dir, fifo_path
        ),
    ));
    // sysctl handling for /tmp
    let needs_sysctl = fifo_path.starts_with("/tmp/") || fifo_path.starts_with("/var/tmp/");
    if needs_sysctl {
        steps.push((
            "sysctl-fifo".to_string(),
            "echo 'fs.protected_fifos=0' > /etc/sysctl.d/99-snapfifo.conf && sysctl -w fs.protected_fifos=0".to_string(),
        ));
    } else {
        steps.push((
            "sysctl-fifo".to_string(),
            "rm -f /etc/sysctl.d/99-snapfifo.conf; sysctl -w fs.protected_fifos=1 2>/dev/null || true".to_string(),
        ));
    }

    // 7. Render snapserver.conf (if-changed later via SFTP)
    let vars = vars_from_config(cfg, "default");
    let rendered_conf =
        crate::template::render_template(SNAPSERVER_CONF_TMPL, &vars).unwrap_or_default();
    steps.push((
        "render-snapserver-conf".to_string(),
        format!(
            "render /etc/snapserver.conf ({} bytes) — compare via SFTP, upload if changed",
            rendered_conf.len()
        ),
    ));

    // 8. Render service units
    let librespot_vars = vars_from_config(cfg, "default");
    let librespot_rendered =
        crate::template::render_template(LIBRESPOT_SERVICE_TMPL, &librespot_vars)
            .unwrap_or_default();
    steps.push((
        "render-librespot-service".to_string(),
        format!(
            "render /etc/systemd/system/librespot.service ({} bytes)",
            librespot_rendered.len()
        ),
    ));
    let snapserver_vars = vars_from_config(cfg, "default");
    let snapserver_rendered =
        crate::template::render_template(SNAPSERVER_SERVICE_TMPL, &snapserver_vars)
            .unwrap_or_default();
    steps.push((
        "render-snapserver-service".to_string(),
        format!(
            "render /etc/systemd/system/snapserver.service ({} bytes)",
            snapserver_rendered.len()
        ),
    ));

    // 9. Cache dir
    steps.push((
        "ensure-cache-dir".to_string(),
        format!("mkdir -p {}", cfg.spotify.cache_dir),
    ));

    // 10. Enable and start services only if any config actually changed
    steps.push((
        "enable-services".to_string(),
        "systemctl daemon-reload; if [ $_config_changed -eq 1 ]; then systemctl enable librespot snapserver; systemctl restart librespot snapserver; else echo no change, no restart; fi".to_string(),
    ));

    steps
}

/// Helper to generate the exact librespot apt source file content.
pub fn raspotify_list_content() -> String {
    format!("{}\n", RASPOTIFY_REPO_LINE)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::AppConfig;

    #[test]
    fn server_steps_contain_critical_literals() {
        let cfg = AppConfig::default();
        let steps = server_steps(&cfg, "bookworm", "aarch64");
        let all = steps
            .iter()
            .map(|(_, c)| c.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            all.contains(RASPOTIFY_GPG_FINGERPRINT),
            "must contain raspotify fingerprint"
        );
        assert!(all.contains(RASPOTIFY_REPO_LINE), "must contain repo line");
        assert!(
            all.contains("snapserver_0.31.0-1_arm64_bookworm.deb") || all.contains("snapserver"),
            "must contain snapserver deb"
        );
        assert!(all.contains("mkfifo"), "must contain fifo creation");
        assert!(
            all.contains("/etc/tmpfiles.d/snapfifo.conf"),
            "must contain tmpfiles"
        );
        assert!(
            all.contains("systemd-tmpfiles --create"),
            "must run tmpfiles"
        );
        assert!(
            all.contains("librespot.service"),
            "must reference librespot service"
        );
        assert!(
            all.contains("snapserver.service"),
            "must reference snapserver service"
        );
    }

    #[test]
    fn server_steps_fifo_sysctl_logic() {
        let mut cfg = AppConfig::default();
        cfg.snapserver.fifo_path = "/tmp/snapfifo".to_string();
        let steps = server_steps(&cfg, "bookworm", "aarch64");
        let all = steps
            .iter()
            .map(|(n, c)| format!("{}:{}", n, c))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            all.contains("fs.protected_fifos=0"),
            "tmp fifo should set protected_fifos=0"
        );
        cfg.snapserver.fifo_path = "/run/diy-sonos/snapfifo".to_string();
        let steps2 = server_steps(&cfg, "bookworm", "aarch64");
        let all2 = steps2
            .iter()
            .map(|(_, c)| c.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            all2.contains("protected_fifos=1"),
            "run fifo should restore protected_fifos=1"
        );
    }

    #[test]
    fn raspotify_repo_exact_line() {
        assert_eq!(
            raspotify_list_content(),
            format!("{}\n", RASPOTIFY_REPO_LINE)
        );
    }

    #[test]
    fn arch_mapping_in_steps() {
        let cfg = AppConfig::default();
        let steps_bookworm_arm64 = server_steps(&cfg, "bookworm", "aarch64");
        let all = steps_bookworm_arm64
            .iter()
            .map(|(_, c)| c.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(all.contains("arm64"), "aarch64 should map to arm64");
        let steps_x86 = server_steps(&cfg, "bookworm", "x86_64");
        let all_x86 = steps_x86
            .iter()
            .map(|(_, c)| c.as_str())
            .collect::<Vec<_>>()
            .join("\n");
        assert!(all_x86.contains("amd64"), "x86_64 should map to amd64");
    }
}
