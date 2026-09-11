//! Structured deploy plans: pure plan builders over live preflight facts,
//! plus a dry-run previewer and a real executor.
//!
//! This replaces stringly-typed step lists for execution. Shell literals
//! below are ported from `scripts/setup-server.sh`, `setup-client.sh`,
//! `scripts/common.sh` (`systemd_enable_restart`, `install_deb`) and
//! `scripts/cleanup-legacy.sh` — see `server.rs` / `client.rs` / `legacy.rs`
//! for the literate ports and `git log` for the originals.

use crate::config::AppConfig;
use crate::deploy::{audio, deb};
use crate::ssh::{self, Remote};
use crate::template::{
    vars_from_config, LIBRESPOT_SERVICE_TMPL, SNAPCLIENT_SERVICE_TMPL, SNAPSERVER_CONF_TMPL,
    SNAPSERVER_SERVICE_TMPL,
};

/// One executable deploy operation.
#[derive(Debug, Clone)]
pub enum Op {
    /// Run a shell command under sudo. Already idempotent (`|| true` etc.)
    /// or intentionally state-asserting; nonzero exit fails the deploy.
    Exec { cmd: String },
    /// Render-then-write a file only when content differs.
    WriteFile {
        path: String,
        content: String,
        mode: String,
    },
    /// Log-only note (skip reasons, warnings). Never fails.
    Info { line: String },
    /// `daemon-reload` always; unmask+enable+restart services only when any
    /// WriteFile earlier in the plan changed something. Ports
    /// `systemd_enable_restart` (unmask first: recovery for masked units).
    RestartChanged { services: Vec<String> },
}

#[derive(Debug, Clone)]
pub struct PlanStep {
    pub name: String,
    pub op: Op,
}

/// Pure combo-safety decision: deploying a lone Server role onto a host
/// that actively runs snapclient (or lone Client where snapserver runs)
/// without combo set would mask+stop the live counterpart. Returns an
/// explanatory error when the combination is unsafe.
pub fn combo_guard_error(
    on_server: bool,
    combo: bool,
    has_server_role: bool,
    has_client_role: bool,
    snapclient_active: bool,
    snapserver_active: bool,
) -> Option<String> {
    if on_server && !combo && has_server_role && snapclient_active {
        return Some(
            "refusing: this server also runs snapclient, but combo mode is off — deploying the Server role would mask and stop its audio client. Mark it as combo first (Devices tab → Edit → tick combo)."
                .to_string(),
        );
    }
    if on_server && !combo && has_client_role && snapserver_active {
        return Some(
            "refusing: snapserver is live on this host, but combo mode is off — deploying the Client role would mask and stop the server. Mark it as combo first (Devices tab → Edit → tick combo)."
                .to_string(),
        );
    }
    None
}

/// Live facts gathered in preflight; plans are pure functions of these.
#[derive(Debug, Clone, Default)]
pub struct Facts {
    pub os_codename: String,
    pub arch_uname: String,
    pub cards: String,
    pub aplay: String,
    pub snapserver_ver: Option<String>,
    pub snapserver_stamp: Option<String>,
    pub snapclient_ver: Option<String>,
    pub snapclient_stamp: Option<String>,
}

/// Gather preflight facts over SSH (read-only).
pub async fn gather_facts(remote: &Remote<'_>) -> Result<Facts, anyhow::Error> {
    let (code, out, err) = ssh::exec(
        remote.host,
        remote.port,
        remote.ssh_user,
        remote.password,
        remote.app_data_dir,
        "cat /etc/os-release; echo ---FACT---; uname -m",
    )
    .await?;
    if code != 0 {
        return Err(anyhow::anyhow!("detect-os failed: {}", err));
    }
    let mut os_codename = String::new();
    let mut arch_uname = String::new();
    for line in out.lines() {
        if let Some(v) = line.strip_prefix("VERSION_CODENAME=") {
            os_codename = v.to_string();
        }
        if line == "---FACT---" {
            arch_uname.clear();
            continue;
        }
        if !os_codename.is_empty()
            && arch_uname.is_empty()
            && !line.contains('=')
            && !line.starts_with("---")
        {
            // last resort handled below; prefer explicit split
        }
    }
    // arch is the segment after the separator
    if let Some(idx) = out.find("---FACT---") {
        arch_uname = out[idx + "---FACT---".len()..]
            .lines()
            .collect::<Vec<_>>()
            .join("")
            .trim()
            .to_string();
    }
    if os_codename.is_empty() || arch_uname.is_empty() {
        return Err(anyhow::anyhow!("could not parse os/arch from: {}", out));
    }

    let (code, out, _) = ssh::exec(
        remote.host,
        remote.port,
        remote.ssh_user,
        remote.password,
        remote.app_data_dir,
        "dpkg -s snapserver 2>/dev/null | awk '/^Version:/ {print $2}'; echo ---FACT---; cat /var/lib/diy-sonos/installed-debs/snapserver 2>/dev/null || true; echo ---FACT---; dpkg -s snapclient 2>/dev/null | awk '/^Version:/ {print $2}'; echo ---FACT---; cat /var/lib/diy-sonos/installed-debs/snapclient 2>/dev/null || true",
    )
    .await?;
    let _ = code;
    let parts: Vec<&str> = out.split("---FACT---").collect();
    let opt = |s: &str| {
        let s = s.trim();
        if s.is_empty() {
            None
        } else {
            Some(s.to_string())
        }
    };
    let (snapserver_ver, snapserver_stamp, snapclient_ver, snapclient_stamp) =
        match parts.as_slice() {
            [a, b, c, d] => (opt(a), opt(b), opt(c), opt(d)),
            _ => (None, None, None, None),
        };

    let (_, cards_out, _) = ssh::exec(
        remote.host,
        remote.port,
        remote.ssh_user,
        remote.password,
        remote.app_data_dir,
        "cat /proc/asound/cards 2>/dev/null; echo ---FACT---; aplay -l 2>/dev/null || true",
    )
    .await?;
    let (cards, aplay) = match cards_out.split_once("---FACT---") {
        Some((c, a)) => (c.to_string(), a.to_string()),
        None => (cards_out, String::new()),
    };

    Ok(Facts {
        os_codename,
        arch_uname,
        cards,
        aplay,
        snapserver_ver,
        snapserver_stamp,
        snapclient_ver,
        snapclient_stamp,
    })
}

fn target_ver(filename: &str) -> &str {
    filename.split('_').nth(1).unwrap_or("")
}

/// Deb install steps for one package: skip/stamp/install per `deb_action`.
fn deb_steps(
    pkg: &str,
    facts_ver: Option<&str>,
    facts_stamp: Option<&str>,
    os_codename: &str,
    arch: &str,
) -> Vec<PlanStep> {
    let filename = format!(
        "{}_{}-1_{}_{}.deb",
        pkg,
        crate::config::SNAPCAST_VERSION,
        arch,
        os_codename
    );
    // Full fallback chain across codenames (trixie has no builds; bookworm works).
    let urls: Vec<String> = deb::codename_fallback_chain(os_codename)
        .iter()
        .map(|c| deb::snapcast_deb_url(pkg, crate::config::SNAPCAST_VERSION, arch, c))
        .collect();
    match deb::deb_action(facts_ver, facts_stamp, target_ver(&filename), &filename) {
        deb::DebAction::Skip => vec![PlanStep {
            name: format!("install-{}", pkg),
            op: Op::Info {
                line: format!("{} already at target {}", pkg, target_ver(&filename)),
            },
        }],
        deb::DebAction::UpdateStamp => vec![PlanStep {
            name: format!("install-{}", pkg),
            op: Op::WriteFile {
                path: deb::stamp_path(pkg),
                content: format!("{}\n", filename),
                mode: "644".to_string(),
            },
        }],
        deb::DebAction::Install => {
            let tries = urls
                .iter()
                .map(|u| {
                    let f = u.rsplit('/').next().unwrap_or("pkg.deb");
                    format!("if curl -fsSL -o /tmp/{f} '{u}'; then if dpkg -i /tmp/{f}; then echo '{f}' > {stamp}; rm -f /tmp/{f}; ok=1; fi; fi", f = f, u = u, stamp = deb::stamp_path(pkg))
                })
                .collect::<Vec<_>>()
                .join(" ");
            vec![PlanStep {
                name: format!("install-{}", pkg),
                op: Op::Exec {
                    cmd: format!(
                        "tmp_ok=0; {tries}; dpkg -s {pkg} >/dev/null 2>&1 || {{ echo 'FAILED to install {pkg}'; exit 1; }}",
                        tries = tries,
                        pkg = pkg
                    ),
                },
            }]
        }
    }
}

/// Server-role plan. `is_combo` keeps snapclient unmasked (combo device).
pub fn server_plan(cfg: &AppConfig, facts: &Facts, is_combo: bool) -> Vec<PlanStep> {
    let mut steps = Vec::new();
    let arch = deb::deb_arch(&facts.arch_uname);
    let fifo_path = &cfg.snapserver.fifo_path;
    let fifo_dir = std::path::Path::new(fifo_path)
        .parent()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or_else(|| "/run/diy-sonos".to_string());

    steps.push(PlanStep {
        name: "apt-update-if-stale".to_string(),
        op: Op::Exec {
            cmd: "if [ -f /var/lib/apt/periodic/update-success-stamp ]; then age=$(( $(date +%s) - $(stat -c %Y /var/lib/apt/periodic/update-success-stamp) )); if [ $age -lt 3600 ]; then echo fresh; exit 0; fi; fi; apt-get update -qq".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "install-base-deps".to_string(),
        op: Op::Exec {
            cmd: "dpkg -s wget curl ca-certificates alsa-utils avahi-daemon gnupg >/dev/null 2>&1 || apt-get install -y wget curl ca-certificates alsa-utils avahi-daemon gnupg".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "ensure-avahi".to_string(),
        op: Op::Exec {
            cmd: "systemctl enable avahi-daemon.service; systemctl is-active --quiet avahi-daemon.service || systemctl start avahi-daemon.service".to_string(),
        },
    });
    let mut cleanup = crate::deploy::legacy::cleanup_commands("server", false);
    if is_combo {
        cleanup.retain(|c| !c.contains("snapclient.service"));
    }
    for (i, cmd) in cleanup.into_iter().enumerate() {
        steps.push(PlanStep {
            name: format!("cleanup-legacy-{}", i),
            op: Op::Exec { cmd },
        });
    }
    steps.push(PlanStep {
        name: "raspotify-gpg".to_string(),
        op: Op::Exec {
            cmd: format!("if [ ! -f {} ]; then curl -fsSL https://dtcooper.github.io/raspotify/key.asc | gpg --dearmor -o {}; fi; gpg --show-keys {} | grep -q {}", crate::deploy::server::RASPOTIFY_GPG, crate::deploy::server::RASPOTIFY_GPG, crate::deploy::server::RASPOTIFY_GPG, crate::deploy::server::RASPOTIFY_GPG_FINGERPRINT),
        },
    });
    steps.push(PlanStep {
        name: "raspotify-list".to_string(),
        op: Op::WriteFile {
            path: crate::deploy::server::RASPOTIFY_LIST.to_string(),
            content: crate::deploy::server::raspotify_list_content(),
            mode: "644".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "apt-update-raspotify".to_string(),
        op: Op::Exec {
            cmd: "apt-get update -qq".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "install-raspotify".to_string(),
        op: Op::Exec {
            cmd: "apt-get install -y raspotify; systemctl mask raspotify.service 2>/dev/null || true; systemctl stop raspotify.service 2>/dev/null || true".to_string(),
        },
    });
    steps.extend(deb_steps(
        "snapserver",
        facts.snapserver_ver.as_deref(),
        facts.snapserver_stamp.as_deref(),
        &facts.os_codename,
        arch,
    ));
    steps.push(PlanStep {
        name: "stop-snapserver".to_string(),
        op: Op::Exec {
            cmd: "systemctl stop snapserver.service 2>/dev/null || true".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "ensure-fifo".to_string(),
        op: Op::Exec {
            cmd: format!("mkdir -p {} && if [ -p {} ]; then echo FIFO exists; elif [ -e {} ]; then rm -f {} && mkfifo {}; else mkfifo {}; fi", fifo_dir, fifo_path, fifo_path, fifo_path, fifo_path, fifo_path),
        },
    });
    steps.push(PlanStep {
        name: "tmpfiles".to_string(),
        op: Op::WriteFile {
            path: "/etc/tmpfiles.d/snapfifo.conf".to_string(),
            content: format!(
                "d {} 0755 root root - -\np {} 0660 root audio - -\n",
                fifo_dir, fifo_path
            ),
            mode: "644".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "tmpfiles-create".to_string(),
        op: Op::Exec {
            cmd: "systemd-tmpfiles --create /etc/tmpfiles.d/snapfifo.conf 2>/dev/null || true"
                .to_string(),
        },
    });
    if fifo_path.starts_with("/tmp/") || fifo_path.starts_with("/var/tmp/") {
        steps.push(PlanStep {
            name: "sysctl-fifo".to_string(),
            op: Op::WriteFile {
                path: "/etc/sysctl.d/99-snapfifo.conf".to_string(),
                content: "fs.protected_fifos=0\n".to_string(),
                mode: "644".to_string(),
            },
        });
        steps.push(PlanStep {
            name: "sysctl-apply".to_string(),
            op: Op::Exec {
                cmd: "sysctl -w fs.protected_fifos=0".to_string(),
            },
        });
    } else {
        steps.push(PlanStep {
            name: "sysctl-fifo".to_string(),
            op: Op::Exec {
                cmd: "rm -f /etc/sysctl.d/99-snapfifo.conf; sysctl -w fs.protected_fifos=1 2>/dev/null || true".to_string(),
            },
        });
    }
    let vars = vars_from_config(cfg, "default");
    let render = |tmpl: &str| crate::template::render_template(tmpl, &vars).unwrap_or_default();
    steps.push(PlanStep {
        name: "snapserver-conf".to_string(),
        op: Op::WriteFile {
            path: "/etc/snapserver.conf".to_string(),
            content: render(SNAPSERVER_CONF_TMPL),
            mode: "644".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "librespot-service".to_string(),
        op: Op::WriteFile {
            path: "/etc/systemd/system/librespot.service".to_string(),
            content: render(LIBRESPOT_SERVICE_TMPL),
            mode: "644".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "snapserver-service".to_string(),
        op: Op::WriteFile {
            path: "/etc/systemd/system/snapserver.service".to_string(),
            content: render(SNAPSERVER_SERVICE_TMPL),
            mode: "644".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "ensure-cache-dir".to_string(),
        op: Op::Exec {
            cmd: format!("mkdir -p {}", cfg.spotify.cache_dir),
        },
    });
    steps.push(PlanStep {
        name: "enable-services".to_string(),
        op: Op::RestartChanged {
            services: vec!["librespot".to_string(), "snapserver".to_string()],
        },
    });
    steps
}

/// Client-role plan. Audio auto-detection runs over preflight facts.
pub fn client_plan(
    cfg: &AppConfig,
    device_ip: &str,
    facts: &Facts,
    is_combo: bool,
) -> Vec<PlanStep> {
    let mut steps = Vec::new();
    let arch = deb::deb_arch(&facts.arch_uname);
    let detected = audio::detect_device(&facts.cards, Some(&facts.aplay));
    let resolved = crate::deploy::client::resolved_audio_device(cfg, &detected);
    let vol = crate::deploy::client::effective_volume(cfg, device_ip);

    steps.push(PlanStep {
        name: "apt-update-if-stale".to_string(),
        op: Op::Exec {
            cmd: "if [ -f /var/lib/apt/periodic/update-success-stamp ]; then age=$(( $(date +%s) - $(stat -c %Y /var/lib/apt/periodic/update-success-stamp) )); if [ $age -lt 3600 ]; then echo fresh; exit 0; fi; fi; apt-get update -qq".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "install-base-deps".to_string(),
        op: Op::Exec {
            cmd: "dpkg -s wget curl ca-certificates alsa-utils >/dev/null 2>&1 || apt-get install -y wget curl ca-certificates alsa-utils".to_string(),
        },
    });
    for (i, cmd) in crate::deploy::legacy::cleanup_commands("client", is_combo)
        .into_iter()
        .enumerate()
    {
        steps.push(PlanStep {
            name: format!("cleanup-legacy-{}", i),
            op: Op::Exec { cmd },
        });
    }
    steps.extend(deb_steps(
        "snapclient",
        facts.snapclient_ver.as_deref(),
        facts.snapclient_stamp.as_deref(),
        &facts.os_codename,
        arch,
    ));
    if !is_combo {
        steps.push(PlanStep {
            name: "mask-snapserver".to_string(),
            op: Op::Exec {
                cmd: "systemctl mask snapserver.service 2>/dev/null || true; systemctl stop snapserver.service 2>/dev/null || true".to_string(),
            },
        });
    }
    if resolved == "default" {
        steps.push(PlanStep {
            name: "warn-default-audio".to_string(),
            op: Op::Info {
                line: "Warning: no suitable audio hardware detected; 'default' will NOT work for snapclient.service on modern Pi OS".to_string(),
            },
        });
    }
    steps.push(PlanStep {
        name: "set-volume".to_string(),
        op: Op::Exec {
            cmd: format!(
                "amixer set Master {}% || amixer set PCM {}% || true; alsactl store || true",
                vol, vol
            ),
        },
    });
    steps.push(PlanStep {
        name: "alsa-volume-script".to_string(),
        op: Op::WriteFile {
            path: "/usr/local/bin/diy-sonos-apply-volume".to_string(),
            content: format!("#!/usr/bin/env bash\namixer set Master {}% || true\n", vol),
            mode: "755".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "alsa-volume-service".to_string(),
        op: Op::WriteFile {
            path: "/etc/systemd/system/diy-sonos-alsa-volume.service".to_string(),
            content: "[Unit]\nDescription=DIY Sonos ALSA volume restore\nAfter=sound.target\n[Service]\nType=oneshot\nExecStart=/usr/local/bin/diy-sonos-apply-volume\n[Install]\nWantedBy=multi-user.target\n".to_string(),
            mode: "644".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "enable-alsa-restore".to_string(),
        op: Op::Exec {
            cmd: "systemctl enable diy-sonos-alsa-volume.service 2>/dev/null || true; systemctl enable alsa-restore.service 2>/dev/null || systemctl enable alsa-state.service 2>/dev/null || true".to_string(),
        },
    });
    let vars = vars_from_config(cfg, &resolved);
    let rendered =
        crate::template::render_template(SNAPCLIENT_SERVICE_TMPL, &vars).unwrap_or_default();
    steps.push(PlanStep {
        name: "snapclient-service".to_string(),
        op: Op::WriteFile {
            path: "/etc/systemd/system/snapclient.service".to_string(),
            content: rendered,
            mode: "644".to_string(),
        },
    });
    steps.push(PlanStep {
        name: "enable-snapclient".to_string(),
        op: Op::RestartChanged {
            services: vec!["snapclient".to_string()],
        },
    });
    steps
}

/// Simple line diff for previews: `  ctx`, `- old`, `+ new`.
pub fn diff_lines(old: &str, new: &str) -> Vec<String> {
    let a: Vec<&str> = old.lines().collect();
    let b: Vec<&str> = new.lines().collect();
    // LCS table (configs are small).
    let (n, m) = (a.len(), b.len());
    let mut dp = vec![vec![0usize; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            dp[i][j] = if a[i] == b[j] {
                dp[i + 1][j + 1] + 1
            } else {
                dp[i + 1][j].max(dp[i][j + 1])
            };
        }
    }
    let mut out = Vec::new();
    let (mut i, mut j) = (0, 0);
    while i < n && j < m {
        if a[i] == b[j] {
            i += 1;
            j += 1;
        } else if dp[i + 1][j] >= dp[i][j + 1] {
            out.push(format!("- {}", a[i]));
            i += 1;
        } else {
            out.push(format!("+ {}", b[j]));
            j += 1;
        }
    }
    while i < n {
        out.push(format!("- {}", a[i]));
        i += 1;
    }
    while j < m {
        out.push(format!("+ {}", b[j]));
        j += 1;
    }
    out
}

/// Dry-run preview of one step. Read-only against the device.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct PreviewItem {
    pub name: String,
    pub kind: String,
    pub detail: String,
    pub diff: Vec<String>,
    pub changes: bool,
}

/// Preview a plan without mutating anything (file steps read remote state).
pub async fn preview_plan(remote: &Remote<'_>, plan: &[PlanStep]) -> Vec<PreviewItem> {
    let mut items = Vec::new();
    let mut would_change = false;
    for step in plan {
        match &step.op {
            Op::Exec { cmd } => items.push(PreviewItem {
                name: step.name.clone(),
                kind: "run".to_string(),
                detail: cmd.clone(),
                diff: vec![],
                changes: false,
            }),
            Op::Info { line } => items.push(PreviewItem {
                name: step.name.clone(),
                kind: "info".to_string(),
                detail: line.clone(),
                diff: vec![],
                changes: false,
            }),
            Op::WriteFile { path, content, .. } => {
                let current = ssh::read_privileged_file(remote, path)
                    .await
                    .unwrap_or(None);
                match current {
                    None => {
                        would_change = true;
                        items.push(PreviewItem {
                            name: step.name.clone(),
                            kind: "write-new".to_string(),
                            detail: format!("{} (new file)", path),
                            diff: content.lines().map(|l| format!("+ {}", l)).collect(),
                            changes: true,
                        });
                    }
                    Some(existing) if existing != *content => {
                        would_change = true;
                        items.push(PreviewItem {
                            name: step.name.clone(),
                            kind: "update".to_string(),
                            detail: format!("{} (content differs)", path),
                            diff: diff_lines(&existing, content),
                            changes: true,
                        });
                    }
                    _ => items.push(PreviewItem {
                        name: step.name.clone(),
                        kind: "unchanged".to_string(),
                        detail: format!("{} (already correct)", path),
                        diff: vec![],
                        changes: false,
                    }),
                }
            }
            Op::RestartChanged { services } => items.push(PreviewItem {
                name: step.name.clone(),
                kind: "restart".to_string(),
                detail: if would_change {
                    format!(
                        "daemon-reload + restart {} (files changed)",
                        services.join(", ")
                    )
                } else {
                    format!(
                        "daemon-reload only; {} untouched (no changes)",
                        services.join(", ")
                    )
                },
                diff: vec![],
                changes: would_change,
            }),
        }
    }
    items
}

/// Sink for live deploy events; lib.rs bridges to Tauri events, tests collect.
pub trait Emitter: Send + Sync {
    fn log(&self, step: &str, level: &str, line: String);
    fn status(&self, phase: &str, done: bool);
}

/// Execute a plan for real. Fails fast on the first failing Exec/Write.
pub async fn execute_plan(
    remote: &Remote<'_>,
    plan: &[PlanStep],
    emit: &dyn Emitter,
) -> Result<DeploySummary, anyhow::Error> {
    let mut summary = DeploySummary::default();
    for step in plan {
        emit.status(&step.name, false);
        match &step.op {
            Op::Exec { cmd } => {
                let (code, out, err) = ssh::exec_sudo(
                    remote.host,
                    remote.port,
                    remote.ssh_user,
                    remote.password,
                    remote.app_data_dir,
                    cmd,
                )
                .await?;
                for line in out.lines().chain(err.lines()) {
                    if !line.trim().is_empty() {
                        emit.log(&step.name, "info", line.to_string());
                    }
                }
                if code != 0 {
                    emit.log(&step.name, "error", format!("exit code {}", code));
                    return Err(anyhow::anyhow!(
                        "step '{}' failed (exit {})",
                        step.name,
                        code
                    ));
                }
                summary.steps_ok += 1;
            }
            Op::Info { line } => {
                emit.log(&step.name, "info", line.clone());
                summary.steps_ok += 1;
            }
            Op::WriteFile {
                path,
                content,
                mode,
            } => {
                let changed =
                    ssh::write_privileged_file_if_changed(remote, content, path, mode).await?;
                if changed {
                    summary.changed_files.push(path.clone());
                    summary.files_changed = true;
                    emit.log(&step.name, "info", format!("updated {}", path));
                } else {
                    emit.log(&step.name, "info", format!("unchanged {}", path));
                }
                summary.steps_ok += 1;
            }
            Op::RestartChanged { services } => {
                let (code, out, err) = ssh::exec_sudo(
                    remote.host,
                    remote.port,
                    remote.ssh_user,
                    remote.password,
                    remote.app_data_dir,
                    "systemctl daemon-reload",
                )
                .await?;
                if code != 0 {
                    return Err(anyhow::anyhow!("daemon-reload failed: {}", err.trim()));
                }
                let _ = out;
                if summary.files_changed {
                    for svc in services {
                        let (code, out, err) = ssh::exec_sudo(
                            remote.host,
                            remote.port,
                            remote.ssh_user,
                            remote.password,
                            remote.app_data_dir,
                            &format!("systemctl unmask {} 2>/dev/null || true; systemctl enable {}; if systemctl is-active --quiet {}; then systemctl restart {}; echo Restarted: {}; else systemctl start {}; echo Started: {}; fi", svc, svc, svc, svc, svc, svc, svc),
                        )
                        .await?;
                        for line in out.lines().chain(err.lines()) {
                            if !line.trim().is_empty() {
                                emit.log(&step.name, "info", line.to_string());
                            }
                        }
                        if code != 0 {
                            return Err(anyhow::anyhow!("restart {} failed (exit {})", svc, code));
                        }
                        summary.restarts.push(svc.clone());
                    }
                } else {
                    emit.log(
                        &step.name,
                        "info",
                        "no file changes — no restarts".to_string(),
                    );
                }
                summary.steps_ok += 1;
            }
        }
        emit.status(&step.name, true);
    }
    Ok(summary)
}

#[derive(Debug, Default, serde::Serialize)]
pub struct DeploySummary {
    pub steps_ok: u32,
    pub files_changed: bool,
    pub changed_files: Vec<String>,
    pub restarts: Vec<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_facts() -> Facts {
        Facts {
            os_codename: "bookworm".to_string(),
            arch_uname: "aarch64".to_string(),
            cards: " 0 [A]: USB-Audio - USB".to_string(),
            aplay: String::new(),
            ..Default::default()
        }
    }

    #[test]
    fn server_plan_skips_installed_deb() {
        let mut cfg = AppConfig::default();
        cfg.server_ip = "192.168.68.104".to_string();
        let mut facts = test_facts();
        facts.snapserver_ver = Some("0.31.0-1".to_string());
        facts.snapserver_stamp = Some("snapserver_0.31.0-1_arm64_bookworm.deb".to_string());
        let plan = server_plan(&cfg, &facts, false);
        let install = plan
            .iter()
            .find(|s| s.name == "install-snapserver")
            .unwrap();
        assert!(
            matches!(install.op, Op::Info { .. }),
            "installed deb must be Info-skip"
        );
    }

    #[test]
    fn server_plan_installs_missing_deb_with_fallback_urls() {
        let cfg = AppConfig::default();
        let plan = server_plan(&cfg, &test_facts(), false);
        let install = plan
            .iter()
            .find(|s| s.name == "install-snapserver")
            .unwrap();
        match &install.op {
            Op::Exec { cmd } => {
                assert!(cmd.contains("curl -fsSL"));
                assert!(cmd.contains("dpkg -i"));
                assert!(cmd.contains("bookworm"));
            }
            other => panic!("expected Exec, got {:?}", other),
        }
    }

    #[test]
    fn combo_server_keeps_snapclient() {
        let cfg = AppConfig::default();
        let plan = server_plan(&cfg, &test_facts(), true);
        let joined = plan
            .iter()
            .map(|s| format!("{:?}", s.op))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            !joined.contains("mask snapclient"),
            "combo must not mask snapclient"
        );
        let plain = server_plan(&cfg, &test_facts(), false);
        let joined = plain
            .iter()
            .map(|s| format!("{:?}", s.op))
            .collect::<Vec<_>>()
            .join("\n");
        assert!(
            joined.contains("mask snapclient"),
            "plain server masks snapclient"
        );
    }

    #[test]
    fn restart_step_always_present_lastish() {
        let cfg = AppConfig::default();
        let plan = server_plan(&cfg, &test_facts(), false);
        let last = plan.last().unwrap();
        assert_eq!(last.name, "enable-services");
        assert!(matches!(last.op, Op::RestartChanged { .. }));
        let cplan = client_plan(&cfg, "192.168.68.114", &test_facts(), false);
        assert!(matches!(
            cplan.last().unwrap().op,
            Op::RestartChanged { .. }
        ));
    }

    #[test]
    fn combo_guard_blocks_masking_live_counterpart() {
        // Server-only deploy onto combo host without combo flag: blocked.
        assert!(super::combo_guard_error(true, false, true, false, true, false).is_some());
        // Client-only deploy onto server host without combo flag: blocked.
        assert!(super::combo_guard_error(true, false, false, true, false, true).is_some());
        // Combo set: allowed.
        assert!(super::combo_guard_error(true, true, true, true, true, true).is_none());
        // Counterpart not running: allowed.
        assert!(super::combo_guard_error(true, false, true, false, false, false).is_none());
        // Pure client box: unaffected.
        assert!(super::combo_guard_error(false, false, false, true, false, true).is_none());
    }

    #[test]
    fn diff_lines_marks_changes() {
        let d = diff_lines("a\nb\nc\n", "a\nx\nc\n");
        assert!(d.iter().any(|l| l == "- b"));
        assert!(d.iter().any(|l| l == "+ x"));
        assert!(diff_lines("same\n", "same\n").is_empty());
    }

    /// Live read-only validation against the real fleet. Ignored by default;
    /// run with `MULTISPOT_LIVE_TEST=1 cargo test live_preview -- --nocapture`.
    /// Asserts preflight + plan + preview work; preview never mutates.
    #[tokio::test]
    async fn live_preview_against_fleet() {
        if std::env::var("MULTISPOT_LIVE_TEST").is_err() {
            return;
        }
        let server = std::env::var("MULTISPOT_TEST_SERVER").unwrap_or("192.168.68.104".to_string());
        let home = std::env::var("HOME").expect("HOME");
        let dir =
            std::path::PathBuf::from(format!("{}/.local/share/dev.jeffcottj.multispot", home));
        let cfg = crate::config::load_config().expect("load app config");
        let remote = crate::ssh::Remote {
            host: server.as_str(),
            port: 22,
            ssh_user: cfg.ssh_user.as_str(),
            password: None,
            app_data_dir: &dir,
        };
        let facts = gather_facts(&remote).await.expect("preflight facts");
        assert!(!facts.os_codename.is_empty(), "codename parsed");
        assert!(!facts.arch_uname.is_empty(), "arch parsed");
        println!("facts: {} {}", facts.os_codename, facts.arch_uname);
        let plan = server_plan(&cfg, &facts, false);
        assert!(!plan.is_empty());
        let preview = preview_plan(&remote, &plan).await;
        let changed = preview.iter().filter(|i| i.changes).count();
        println!(
            "server preview: {} steps, {} would change",
            preview.len(),
            changed
        );
        for item in &preview {
            println!(
                "  {:28} [{}] {}",
                item.name,
                item.kind,
                item.detail.lines().next().unwrap_or("")
            );
            for line in item.diff.iter().take(10) {
                println!("      {}", line);
            }
        }
        // Preview is pure reads: run twice, identical outcome.
        let preview2 = preview_plan(&remote, &plan).await;
        assert_eq!(preview.len(), preview2.len());

        // Client role against the speaker Pi: audio must resolve off `default`.
        let client = std::env::var("MULTISPOT_TEST_CLIENT").unwrap_or("192.168.68.114".to_string());
        let remote_c = crate::ssh::Remote {
            host: client.as_str(),
            port: 22,
            ssh_user: cfg.ssh_user.as_str(),
            password: None,
            app_data_dir: &dir,
        };
        let facts_c = gather_facts(&remote_c).await.expect("client preflight");
        let cplan = client_plan(&cfg, &client, &facts_c, false);
        let cpreview = preview_plan(&remote_c, &cplan).await;
        let cchanged = cpreview.iter().filter(|i| i.changes).count();
        println!(
            "client preview: {} steps, {} would change",
            cpreview.len(),
            cchanged
        );
        assert!(
            !cpreview.iter().any(|i| i.name == "warn-default-audio"),
            "USB DAC must resolve, expected no default-audio warning"
        );
    }

    #[test]
    fn client_plan_warns_on_default_audio() {
        let mut cfg = AppConfig::default();
        cfg.snapclient.audio_device = "auto".to_string();
        let mut facts = test_facts();
        facts.cards = " 0 [vc4hdmi]: vc4-hdmi - vc4-hdmi".to_string();
        let plan = client_plan(&cfg, "192.168.68.114", &facts, false);
        assert!(plan.iter().any(|s| s.name == "warn-default-audio"));
    }
}
