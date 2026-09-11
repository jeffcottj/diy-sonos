# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

Turns small Linux devices into a synchronized multi-room audio system. A server device runs Spotify Connect (librespot) and streams audio via Snapcast; client devices play back in sync through USB DACs.

```
Spotify App → librespot (server) → /run/diy-sonos/snapfifo (FIFO) → snapserver → snapclient(s) → ALSA → USB DAC
```

Tested hardware: Raspberry Pi 5 (server), Raspberry Pi Zero 2 W (clients).

The project is now a **Tauri 2 + Rust backend + React/TypeScript frontend** desktop app (Windows/macOS/Linux) that replaces the entire bash toolchain. All orchestration — rendering configs locally, pushing file bytes over the same SSH connection (base64-staged into place, no SFTP), running remote commands over SSH — is done natively in Rust. No bash scripts, no rsync of the repo, no device-side agent binary.

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
      ssh/              # russh client: TOFU host keys, password/key auth, exec+sudo, read/write-if-changed file ops
      discovery.rs      # subnet sweep (TCP 22 + banner, local-/24 inference) + mdns-sd `_ssh._tcp.local` browse
      deploy/           # plan.rs engine (preflight facts → pure plan → preview/execute) + ported logic: server.rs, client.rs, legacy.rs, deb.rs, audio.rs
      doctor.rs         # pure health-check helpers (tested); no UI wired to them yet
      oauth.rs          # credential-cached check + URL regex helpers; full tunnel flow not wired yet
      snapcast.rs       # contingency JSON-RPC client (if frontend WebSocket rejected)
  docs/troubleshooting.md
  README.md, LICENSE, CLAUDE.md
```

Crates: `tauri` 2, `tauri-plugin-opener`; `russh` (no `russh-sftp` — files go over exec); `mdns-sd`; `tokio`, `serde`, `serde_yaml`, `anyhow`. Frontend: React 18, TypeScript, Vite, Tailwind 4, `zustand`; no component library. `npm` package manager. Do NOT use `snapcast-control` crate — hand-rolled thin JSON-RPC client (~8 methods).

Snapcast control: frontend opens `new WebSocket("ws://<server_ip>:1780/jsonrpc")` directly, sends `Server.GetStatus`, and keeps state live from notifications (`Client.OnConnect/OnDisconnect/OnVolumeChanged/...`, `Group.OnMute/OnStreamChanged`, `Server.OnUpdate`). Methods: `Server.GetStatus`, `Server.DeleteClient`, `Client.SetVolume`, `Client.SetLatency`, `Client.SetName`, `Group.SetMute`, `Group.SetClients`, `Group.SetName`. Clients matched by `client.host.ip` against app device IPs. If cross-origin WebSocket is rejected, Rust fallback in `snapcast.rs` (tokio-tungstenite) bridges via Tauri events.

Tauri commands (backend API surface):

- `load_config() -> AppConfig`, `save_config(AppConfig) -> ()`
- `import_legacy_config(path: string) -> AppConfig`
- `scan_mdns() -> Vec<DiscoveredDevice>` (legacy mDNS path; UI uses `scan_network` now) — browse `_ssh._tcp.local` for ~5 s; flag hostnames matching `/raspberrypi|raspi|pi|dietpi|ubuntu/i` as likely Pi
- `connect_device(host, port, ssh_user, password) -> ConnectResult` (Ok | HostKeyUntrusted with the REAL fingerprint), `trust_host_key(host, port, fingerprint) -> ()` (TOFU, canonical `host:port` keys, self-heals stub-era entries on list)
- `install_device_key(host, port, ssh_user, password) -> ()` — ed25519 keypair at `app_data_dir()/id_ed25519` (0600), installed into the remote user's own `~/.ssh/authorized_keys` (plain SSH, never sudo)
- `preview_deploy(device_id, roles) -> Vec<PreviewItem>` (read-only dry run with diffs) + `deploy_device(device_id, roles) -> DeploySummary` (combo guards refuse to mask a live counterpart; marks `deployed` flags)
- `list_device_connections()`, `check_devices_live(...)`, `check_servers_combo(...)`, `check_device_setup(host, port, role)`, `forget_device_connection(host, port)`
- `doctor_device(device_id) -> Vec<CheckResult>` — STUBBED (canned data, don't trust it)
- `start_oauth(device_id)` — STUBBED (placeholder URL); full flow not wired yet

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

Validation (ported from `scripts/common.sh:146-219`): `validate_server_ip` IPv4 + octet 0-255; `bitrate ∈ {96,160,320}`; `codec ∈ {flac,pcm}`; `audio_device ∈ {auto,default,hw:N,N,plughw:N,N}`; `output_volume` 0-100 int; `buffer_ms` 100-10000; `latency_ms` ±5000 (global + per-client). All enforced in `save_config`.

Templates: `src-tauri/templates/*.tmpl` copied verbatim from old `templates/` and embedded via `include_str!`. Renderer replaces `{{[A-Z0-9_]+}}` with values (missing key = hard error, same as old `render_template_if_changed`). If-changed is decided by reading the remote file over exec and comparing before writing (`write_privileged_file_if_changed`).

Deploy engine: ported ordered step lists from `scripts/setup-server.sh`, `setup-client.sh`, `cleanup-legacy.sh`, `common.sh`. Exact shell literals (raspotify repo line, GPG fetch URL, unit file bodies) come from those bash files — read them before porting. Steps emit `deploy-log` events. `combo_guard_error` refuses lone-role deploys that would mask a live counterpart. FIFO handling: `d <dir> 0755 root root - -` + `p <path> 0660 root audio - -` in `/etc/tmpfiles.d/snapfifo.conf`, `systemd-tmpfiles --create`, stale old-path FIFO removal, sysctl `fs.protected_fifos` only if path under `/tmp` or `/var/tmp`.

Doctor: pure check helpers ported from `common.sh:731-905` + `setup.sh doctor` (tested, but no UI or live path wired yet — `doctor_device` returns canned data). Checks: service installed/enabled/active, listeners on 1704/1780, FIFO is a pipe, audio device != `default` (warn), recent errors `journalctl -u <unit> -p err -n 15`. Returns `CheckResult` structs; remediation strings are app actions (“Redeploy this device”).

OAuth: helpers ported from `scripts/librespot-auth-helper.sh:28-56` (`has_cached_credentials`, URL regex). Full tunnel flow NOT wired. If it were, it would: if `has_cached_credentials` (`<cache_dir>/*credentials*` or `*.json`), skip. Else restart `librespot.service`, poll `journalctl -u librespot --no-pager -n 400` for `https://accounts\.spotify\.com/[^ ]+`, start local port-forward (`TcpListener` on `127.0.0.1:<port>` → russh `direct_tcpip` to `127.0.0.1:<port>` on device), open URL via `tauri-plugin-opener`, emit `oauth-url {url}` until credentials appear, stop forward.

## Config System

- App config at `app_config_dir()/config.yml` (identifier `dev.jeffcottj.diy-sonos`), written via `serde_yaml`. App key at `app_data_dir()/id_ed25519`.
- Legacy import: `import_legacy_config(path)` parses an old repo `config.yml` (accepts old shape incl. `clients[].ip/ssh_user/output_volume`; ignores unknown keys). Config schema keeps same top-level keys so import is 1:1.
- Profiles live in the Settings form (`basic`/`advanced` fill codec/buffer/latency, edits flip to `custom`); `save_config` persists exactly what's shown and validates ranges. `AppConfig::apply_profile()` still exists but nothing calls it on save paths (round-trip test proves it).

## Frontend

- `src/App.tsx` — shell with tabs (Devices, Dashboard, Settings), loads config via `load_config`, stores `server_ip` in zustand.
- `src/components/DeviceAddDialog.tsx` — manual IP + one **Scan network** button (subnet sweep, click-to-fill) + first-connect flow (password → HostKeyUntrusted confirm → key install). No role logic; it only connects.
- `src/components/Dashboard.tsx` — WebSocket to `ws://<server_ip>:1780/jsonrpc`, live groups/clients/streams, volume/mute/latency/rename/group assignment, delete stale clients, offline badge.
- `src/components/ConnectSpotify.tsx` — starts OAuth, listens for `oauth-url` events, shows clickable URL. (Backend returns a placeholder today — manual OAuth steps in README.)
- `src/components/DeviceList.tsx` — connected-device roster (trust store + liveness + configured roles) with inline Configure/Edit and Forget.
- `src/components/Settings.tsx` — Audio (preset fills fields, edits flip to auto-`Custom`, save persists exactly + validates) and Spotify name/bitrate. Save opens **Review & apply** (per-device preview → confirm → sequential deploy). Server/roster live on Devices.
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
