# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

Turns small Linux devices into a synchronized multi-room audio system. A server device runs Spotify Connect (librespot) and streams audio via Snapcast; client devices play back in sync through USB DACs.

```
Spotify App → librespot (server) → /run/diy-sonos/snapfifo (FIFO) → snapserver → snapclient(s) → ALSA → USB DAC
```

Tested hardware: Raspberry Pi 5 (server), Raspberry Pi Zero 2 W (clients).

The project is now a **Tauri 2 + Rust backend + React/TypeScript frontend** desktop app (Windows/macOS/Linux) that replaces the entire bash toolchain. All orchestration — rendering configs locally, uploading via SFTP, running remote commands over SSH — is done natively in Rust. No bash scripts, no rsync of the repo, no device-side agent binary.

## Validating Changes

Use these to verify correctness (repo root):

```bash
# Backend
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings
cargo test --manifest-path src-tauri/Cargo.toml

# Frontend
npm run build   # tsc && vite build

# Full desktop dev
npm run tauri dev
npm run tauri build            # installers per tauri.conf.json (all)
npm run tauri build -- --no-bundle  # CI check without bundling

# CI (GitHub Actions)
# .github/workflows/ci.yml runs: cargo fmt/clippy/test + npm build + tauri build --no-bundle on ubuntu/windows/macos
# .github/workflows/release.yml runs on tag v* via tauri-apps/tauri-action
```

## Architecture

Repo layout:

```
/
  src/                  # React 18 + Vite + TS frontend
  src-tauri/
    src/
      config.rs         # AppConfig model, load/save, import, validation
      templates/        # *.tmpl assets, embedded via include_str!
      template.rs       # {{VAR}} renderer with render-if-changed semantics at upload time
      ssh/              # russh client: sessions, auth, exec+sudo, SFTP, port-forward, TOFU host keys
      discovery.rs      # mdns-sd scanner for _ssh._tcp.local
      deploy/           # ported setup logic: server.rs, client.rs, legacy.rs, deb.rs, audio.rs
      doctor.rs         # ported health checks
      oauth.rs          # journal poll + SSH local port-forward + browser open
      snapcast.rs       # contingency JSON-RPC client (if frontend WebSocket rejected)
  docs/troubleshooting.md
  README.md, LICENSE, CLAUDE.md
```

Crates: `tauri` 2, `tauri-plugin-updater`, `tauri-plugin-opener`, `tauri-plugin-dialog`; `russh` + `russh-sftp`; `mdns-sd`; `tokio`, `serde`, `serde_yaml`, `thiserror`/`anyhow`. Frontend: React 18, TypeScript, Vite, Tailwind 4, `zustand`; no component library. `npm` package manager. Do NOT use `snapcast-control` crate — hand-rolled thin JSON-RPC client (~8 methods).

Snapcast control: frontend opens `new WebSocket("ws://<server_ip>:1780/jsonrpc")` directly, sends `Server.GetStatus`, and keeps state live from notifications (`Client.OnConnect/OnDisconnect/OnVolumeChanged/...`, `Group.OnMute/OnStreamChanged`, `Server.OnUpdate`). Methods: `Server.GetStatus`, `Server.DeleteClient`, `Client.SetVolume`, `Client.SetLatency`, `Client.SetName`, `Group.SetMute`, `Group.SetClients`, `Group.SetName`. Clients matched by `client.host.ip` against app device IPs. If cross-origin WebSocket is rejected, Rust fallback in `snapcast.rs` (tokio-tungstenite) bridges via Tauri events.

Tauri commands (backend API surface):

- `load_config() -> AppConfig`, `save_config(AppConfig) -> ()`
- `import_legacy_config(path: string) -> AppConfig`
- `scan_mdns() -> Vec<DiscoveredDevice>` — browse `_ssh._tcp.local` for ~5 s; flag hostnames matching `/raspberrypi|raspi|pi|dietpi|ubuntu/i` as likely Pi
- `connect_device(host, port, ssh_user, password) -> ConnectResult` (Ok | HostKeyUntrusted), `trust_host_key(host, fingerprint) -> ()` (TOFU, stored at `app_data_dir()/known_hosts`)
- `install_device_key(host, port, ssh_user, password) -> ()` — generate/ensure ed25519 keypair at `app_data_dir()/id_ed25519` (0600), append to remote `~/.ssh/authorized_keys`
- `deploy_device(device_id, roles: Vec<Role>) -> ()` — streams `deploy-log` / `deploy-status` events
- `doctor_device(device_id) -> Vec<CheckResult>` — `{status: pass|fail|warn|info, message, explanation, remediation}`
- `start_oauth(device_id) -> ()` — emits `oauth-url {url}` event, opens browser, polls until credentials cached

Progress events: `deploy-log {deviceId, step, level, line}` and `deploy-status {deviceId, phase, done}`.

Config storage: `tauri::Manager::app_config_dir()` + `config.yml` (`dev.jeffcottj.diy-sonos`), via `serde_yaml`. App-owned SSH keypair at `app_data_dir()/id_ed25519` (0600, ed25519).

Config schema (same keys as old `config.yml` for legacy import, plus additions):

```yaml
ssh_user: "pi"
server_ip: "192.168.1.100"
server_combo: false            # also run client on server
clients:
  - ip: "192.168.1.121"
    name: "Kitchen"            # also set via Client.SetName
    ssh_user: "pi"
    output_volume: 90
    latency_ms: 0
    audio_device: "auto"
profile: basic                 # basic | advanced
spotify:    { device_name, bitrate, normalise, initial_volume, cache_dir, oauth_callback_port, device_type }
snapserver: { fifo_path, sampleformat, codec, buffer_ms, port, control_port }
snapclient: { audio_device, output_volume, latency_ms, instance }
```

Defaults: `device_name "DIY Sonos"`, `bitrate 320`, `normalise true`, `initial_volume 90`, `cache_dir /var/cache/librespot`, `oauth_callback_port 4000`, `device_type "speaker"`, `fifo_path /run/diy-sonos/snapfifo`, `sampleformat "44100:16:2"`, `codec flac`, `buffer_ms 1000`, `port 1704`, `control_port 1780`, `audio_device auto`, `output_volume 90`, `latency_ms 0`, `instance 1`. Profile `advanced` maps: `codec pcm`, `buffer_ms 800`, `snapclient.latency_ms -20`. Snapcast version pin: `SNAPCAST_VERSION = "0.31.0"`.

Validation (ported from `scripts/common.sh:146-219`): `validate_server_ip` IPv4 + octet 0-255; `bitrate ∈ {96,160,320}`; `codec ∈ {flac,pcm}`; `audio_device ∈ {auto,default,hw:N,N,plughw:N,N}`; `output_volume` 0-100 int.

Templates: `src-tauri/templates/*.tmpl` copied verbatim from old `templates/` and embedded via `include_str!`. Renderer replaces `{{[A-Z0-9_]+}}` with values (missing key = hard error, same as old `render_template_if_changed`). If-changed is checked at upload time by comparing rendered content to remote file via SFTP.

Deploy engine: ported ordered step lists from `scripts/setup-server.sh`, `setup-client.sh`, `cleanup-legacy.sh`, `common.sh`. Exact shell literals (raspotify repo line, GPG fetch URL, unit file bodies) come from those bash files — read them before porting. Steps emit `deploy-log` events. FIFO handling: `d <dir> 0755 root root - -` + `p <path> 0660 root audio - -` in `/etc/tmpfiles.d/snapfifo.conf`, `systemd-tmpfiles --create`, stale old-path FIFO removal, sysctl `fs.protected_fifos` only if path under `/tmp` or `/var/tmp`.

Doctor: ported from `common.sh:731-905` + `setup.sh doctor`. Checks: service installed/enabled/active, listeners on 1704/1780, FIFO is a pipe, audio device != `default` (warn), recent errors `journalctl -u <unit> -p err -n 15`. Returns `CheckResult` structs; remediation strings are app actions (“Redeploy this device”).

OAuth: ported from `scripts/librespot-auth-helper.sh:28-56`. If `has_cached_credentials` (`<cache_dir>/*credentials*` or `*.json`), skip. Else restart `librespot.service`, poll `journalctl -u librespot --no-pager -n 400` for `https://accounts\.spotify\.com/[^ ]+`, start local port-forward (`TcpListener` on `127.0.0.1:<port>` → russh `direct_tcpip` to `127.0.0.1:<port>` on device), open URL via `tauri-plugin-opener`, emit `oauth-url {url}` until credentials appear, stop forward.

## Config System

- App config at `app_config_dir()/config.yml` (identifier `dev.jeffcottj.diy-sonos`), written via `serde_yaml`. App key at `app_data_dir()/id_ed25519`.
- Legacy import: `import_legacy_config(path)` parses an old repo `config.yml` (accepts old shape incl. `clients[].ip/ssh_user/output_volume`; ignores unknown keys). Config schema keeps same top-level keys so import is 1:1.
- Profile `advanced` mapping applied in `AppConfig::apply_profile()`.

## Frontend

- `src/App.tsx` — shell with tabs (Wizard, Devices, Dashboard, Settings), loads config via `load_config`, stores `server_ip` in zustand.
- `src/components/DeviceAddDialog.tsx` — manual IP + Scan network (mDNS list, likely-Pi badge) + first-connect flow (password → HostKeyUntrusted confirm → key install).
- `src/components/Dashboard.tsx` — WebSocket to `ws://<server_ip>:1780/jsonrpc`, live groups/clients/streams, volume/mute/latency/rename/group assignment, delete stale clients, offline badge.
- `src/components/ConnectSpotify.tsx` — starts OAuth, listens for `oauth-url` events, shows clickable URL.
- `src/components/Wizard.tsx` — first-run wizard (add server+clients → profile → deploy → OAuth → done).
- `src/components/Settings.tsx` — all config fields, profile switch, per-client `name`/`latency_ms`/`audio_device`.
- `src/store.ts` — zustand store for `serverIp` + devices.

## Key Edge Cases (unchanged device-side facts)

Same as before, but triggered by the app instead of scripts: FIFO via tmpfiles, `fs.protected_fifos` only if `fifo_path` under `/tmp`; `After=Wants=librespot.service` (not `Requires`) + `mode=read` to avoid startup race; raspotify masked after install; snapclient deb may pull snapserver (masked on client unless combo); `spotify.normalise` bool → `--enable-volume-normalisation` flag.

## Ports

| Port | Purpose |
|------|---------|
| 1704 | Snapcast audio stream (server → clients, TCP) |
| 1780 | Snapcast HTTP control API (WebSocket JSON-RPC) |
| 4000 | librespot OAuth callback (`spotify.oauth_callback_port`) |
| 5353 | mDNS via avahi (Spotify device discovery) |

All references to `setup.sh`, `deploy.sh`, `first-run.sh`, `config.yml` in repo root, and `scripts/` now map to GUI flows in the desktop app. The `src-tauri/templates/` dir is the source of truth for service units.
