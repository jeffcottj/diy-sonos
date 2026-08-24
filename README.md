# DIY Sonos

Turn small Linux devices into a Sonos-like synchronized multi-room audio system. A server device runs Spotify Connect and streams audio; client devices play back in perfect sync via USB DACs. Now with a cross-platform desktop app (Windows/macOS/Linux) that replaces the old bash toolchain.

Tested hardware: Raspberry Pi 5 (server) and Raspberry Pi Zero 2 W units (clients).

## Audio Flow

```
Spotify App
    │ (mDNS / Spotify Connect)
    ▼
librespot  (server device)
    │  raw PCM S16 44100:16:2 written to named pipe
    ▼
/run/diy-sonos/snapfifo  (FIFO)
    │
    ▼
snapserver  (server device — encodes FLAC, streams over TCP 1704)
    │
    ├──────────────────────────┐
    ▼                          ▼
snapclient (client)        snapclient (client)  ...
    │                          │
  ALSA → USB DAC          ALSA → USB DAC
```

## Download & Install

Latest release: **GitHub Releases** — `https://github.com/jeffcottj/diy-sonos/releases/latest`

| OS | Installer | Notes |
|----|-----------|-------|
| Windows 10/11 | `DIY_Sonos_x.y.z_x64-setup.exe` (NSIS) | WebView2 is downloaded via bootstrapper if missing |
| macOS (Intel + Apple Silicon) | `DIY_Sonos_x.y.z_universal.dmg` | Drag to Applications. Universal binary (aarch64 + x86_64) |
| Linux | `DIY_Sonos_x.y.z_amd64.AppImage` or `diy-sonos_x.y.z_amd64.deb` | AppImage is portable; deb installs via `sudo dpkg -i` |

The app is **unsigned** (public GitHub Releases, no Apple Developer ID / EV cert). Tauri updater uses its own minisign keys (`latest.json` is signed; the app verifies updates independently). The OS will warn on first launch:

- **macOS Gatekeeper**: Finder → Right-click `DIY Sonos.app` → **Open** → **Open** in the dialog. Subsequent launches work normally. Or: System Settings → Privacy & Security → **Open Anyway**.
- **Windows SmartScreen**: “Windows protected your PC” → **More info** → **Run anyway**.

Updates: the app checks `https://github.com/jeffcottj/diy-sonos/releases/latest/download/latest.json` via `tauri-plugin-updater`. When an update is available you’ll see a prompt; it installs on restart.

## First-run wizard

Open the app:

1. **Add server & clients** — Enter the IP for each Pi manually, or click **Scan network** to browse `_ssh._tcp.local` via mDNS (5 s). Hosts matching `raspberrypi|raspi|pi|dietpi|ubuntu` get a “likely Pi” badge; click a result to prefill.
   - First connect asks for SSH username + password. The app generates its own ed25519 keypair (`app_data_dir()/id_ed25519`, 0600) and installs the public key into `~/.ssh/authorized_keys` on the device (like `ssh-copy-id`). The first host key is shown as `SHA256:…`; confirm to trust (TOFU, stored in `app_data_dir()/known_hosts`). A later mismatch is a hard error.
   - Sudo runs as `sudo -S -p ''` with the password fed over stdin per command; password is held in memory only during the operation, never written to disk. Passwordless-sudo devices work transparently.

2. **Audio profile** — Choose `basic` (flac, buffer 1000 ms, latency 0) or `advanced` (pcm, buffer 800 ms, latency -20). This sets `snapserver.codec`, `snapserver.buffer_ms`, and `snapclient.latency_ms`. You can change it later in Settings.

3. **Deploy** — One-click deploy. The app:
   - Preflights SSH to all devices (fail fast)
   - Deploys the server role (or combo server+client) → surfaces **Connect Spotify** → deploys each client in sequence → shows pass/fail summary
   - Streams live logs per device (`deploy-log {deviceId, step, level, line}`) and step checklist (`deploy-status {deviceId, phase, done}`)

4. **Connect Spotify** — If credentials are already cached (`/var/cache/librespot/*credentials*` or `*.json`), the step is skipped. Otherwise the app:
   - Restarts `librespot.service` on the server
   - Polls `journalctl -u librespot --no-pager -n 400` for the last `https://accounts\.spotify\.com/[^ ]+` URL
   - Starts a local port-forward (`127.0.0.1:4000` on the laptop → `127.0.0.1:4000` on the device via russh `direct-tcpip`) and opens the URL in your default browser
   - Emits `oauth-url {url}` events until credentials appear, then stops the forward

5. **Play** — Open Spotify on any device and select **“DIY Sonos”**. The dashboard shows stream idle/playing state (audio pipe provides no track metadata — don’t hunt for it).

## Using the app

- **Devices** tab — Current config (`server_ip`, `ssh_user`, client list). Add/edit devices, re-run deploys, view per-device doctor results and deploy logs.
- **Dashboard** tab — Live Snapcast control. The frontend opens `new WebSocket("ws://<server_ip>:1780/jsonrpc")` directly, sends `Server.GetStatus`, and keeps state live from notifications (`Client.OnConnect/OnDisconnect/OnVolumeChanged/...`, `Group.OnMute/OnStreamChanged`, `Server.OnUpdate`). Controls:
  - Per-client: volume slider (`Client.SetVolume`), mute, latency (`Client.SetLatency`), rename (`Client.SetName` seeded from `clients[].name`)
  - Per-group: group mute (`Group.SetMute`), drag/toggle clients between groups (`Group.SetClients`), delete stale clients (`Server.DeleteClient`)
  - Badges: client online/offline (`Client.OnConnect/OnDisconnect`), stream idle/playing from `stream.status`
  - Clients are matched to app devices by `client.host.ip`
  - If Snapcast or the webview rejects the cross-origin WebSocket (Origin check), the Rust fallback in `snapcast.rs` (tokio-tungstenite) bridges via Tauri events — same store shape.

- **Settings** tab — All `config.yml` fields (profile, spotify/snapserver/snapclient sections, per-client `name`/`latency_ms`/`audio_device`). Changes that affect rendered files prompt **Apply changes** → re-run deploy for affected devices.
  - Config is stored at `app_config_dir()/config.yml` (`dev.jeffcottj.diy-sonos`) via `serde_yaml`. Comments are not preserved (the UI replaces hand-editing; see schema in Settings).
  - Device passwords are never persisted; the app key is the only credential stored.

## Device-side facts (what the app manages)

- Services: `librespot.service` + `snapserver.service` on server (`After=librespot.service`, `Wants=librespot.service`, not `Requires`); `snapclient.service` on clients (`After=network-online.target sound.target`)
- FIFO: `/run/diy-sonos/snapfifo` (default), created via `mkfifo`, persisted via `/etc/tmpfiles.d/snapfifo.conf` as `d <dir> 0755 root root - -` + `p <path> 0660 root audio - -` + `systemd-tmpfiles --create`; stale old-path FIFO removed on path change; if path is under `/tmp` or `/var/tmp`, `fs.protected_fifos=0` via `/etc/sysctl.d/99-snapfifo.conf` else removed/restored to `1`
- Snapserver config: `/etc/snapserver.conf` from `snapserver.conf.tmpl` (`sampleformat`, `codec`, `buffer`, `source = pipe:///…`)
- Ports: `1704` (audio), `1780` (HTTP control), `4000` (librespot OAuth callback, configurable via `spotify.oauth_callback_port`), `5353` (mDNS via avahi)
- Snapcast deb URL: `https://github.com/badaix/snapcast/releases/download/v{VER}/snap{server|client}_{VER}-1_{ARCH}_{CODENAME}.deb` with arch map `aarch64→arm64, armv7l|armv6l→armhf, x86_64→amd64` and codename fallback `bookworm → bullseye`
- Cache dir: `/var/cache/librespot`
- Boot-time ALSA volume restore: `/etc/systemd/system/diy-sonos-alsa-volume.service` + `/usr/local/bin/diy-sonos-apply-volume` plus `alsa-restore`/`alsa-state` units

## Troubleshooting

See `docs/troubleshooting.md` for device-side diagnostics. Quick checks via SSH or the app’s **Device detail → Doctor**:

- **Doctor** runs per-device checks: service installed/enabled/active (`librespot`, `snapserver`, `avahi-daemon` on server; `snapclient` + `alsa-restore` on client), listeners on `1704`/`1780`, FIFO is a pipe, resolved audio device ≠ `default` (warn), recent errors `journalctl -u <unit> -p err -n 15`. Results show pass/fail/warn + explanation + remediation (“Redeploy this device”).
- **Deploy log** shows per-step output; idempotent re-run on an unchanged fleet reports “unchanged” and no service restarts (check `systemctl show -p ActiveEnterTimestamp <service>`).
- **Dashboard offline badge**: client power off → offline within seconds via `Client.OnDisconnect`.

Common fixes: `Redeploy this device` from the app (re-renders configs if-changed, fixes FIFO/tmpfiles/sysctl, reinstalls debs if needed). For OAuth issues, use **Connect Spotify** again (tunnel is automatic).

## Development

Prerequisites: Rust stable (via `rustup`), Node 20, npm.

```bash
# Frontend dev (Vite)
npm install
npm run build        # tsc && vite build

# Backend checks (from src-tauri)
cargo fmt --check
cargo clippy -- -D warnings
cargo test

# Desktop dev (Tauri)
npm run tauri dev
npm run tauri build        # produces installers per tauri.conf.json bundle targets
npm run tauri build -- --no-bundle  # CI check without bundling

# One-shot verification (repo root)
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo clippy --manifest-path src-tauri/Cargo.toml -- -D warnings
cargo test --manifest-path src-tauri/Cargo.toml
npm run build
```

Distribution: `release.yml` builds on tag `v*` via `tauri-apps/tauri-action@v0` (windows-latest, macos-latest, ubuntu-22.04) and publishes installers + `latest.json` to the GitHub Release. Updater signing keys are generated once (`npm run tauri signer generate`); private key + passphrase stored as repo secrets `TAURI_SIGNING_PRIVATE_KEY` / `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`; public key embedded in `tauri.conf.json` under `plugins.updater.pubkey`.

## License

MIT — see `LICENSE`.
