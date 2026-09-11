# Multispot

Turn small Linux devices into a Sonos-like synchronized multi-room audio system. A server device runs Spotify Connect and streams audio; client devices play back in perfect sync via USB DACs. Now with a cross-platform desktop app (Windows/macOS/Linux) that replaces the old bash toolchain.

Tested hardware: Raspberry Pi 5 (server) and Raspberry Pi Zero 2 W units (clients).

> **Renamed from DIY Sonos:** the app identifier changed to `dev.jeffcottj.multispot`,
> so an existing install keeps its config under the old
> `~/.config/dev.jeffcottj.diy-sonos` directory. Either move it
> (`mv ~/.config/dev.jeffcottj.diy-sonos ~/.config/dev.jeffcottj.multispot`,
> same for `~/.local/share/...`) or re-run device setup. On-device paths
> (`/run/diy-sonos`, `/var/lib/diy-sonos`, …) are intentionally unchanged,
> so deployed Pis keep working without a re-deploy.

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

Latest release: **GitHub Releases** — `https://github.com/jeffcottj/multispot/releases/latest`

| OS | Installer | Notes |
|----|-----------|-------|
| Windows 10/11 | `Multispot_x.y.z_x64-setup.exe` (NSIS) | WebView2 is downloaded via bootstrapper if missing |
| macOS (Intel + Apple Silicon) | `Multispot_x.y.z_universal.dmg` | Drag to Applications. Universal binary (aarch64 + x86_64) |
| Linux | `Multispot_x.y.z_amd64.AppImage` or `multispot_x.y.z_amd64.deb` | AppImage is portable; deb installs via `sudo dpkg -i` |

The app is **unsigned** (public GitHub Releases, no Apple Developer ID / EV cert), and updates are manual for now — download the new installer from Releases (there is no in-app updater). The OS will warn on first launch:

- **macOS Gatekeeper**: Finder → Right-click `Multispot.app` → **Open** → **Open** in the dialog. Subsequent launches work normally. Or: System Settings → Privacy & Security → **Open Anyway**.
- **Windows SmartScreen**: “Windows protected your PC” → **More info** → **Run anyway**.


## Getting started

Open the app (Devices tab):

1. **Add server & clients** — Enter the IP for each Pi manually, or click **Scan network** to sweep your subnet for SSH (may take about a minute); click a result to prefill.
   - First connect asks for SSH username + password. The app generates its own ed25519 keypair (`app_data_dir()/id_ed25519`, 0600) and installs the public key into `~/.ssh/authorized_keys` on the device (like `ssh-copy-id`). The first host key is shown as `SHA256:…`; confirm to trust (TOFU, stored in `app_data_dir()/known_hosts`). A later mismatch is a hard error.
   - Sudo runs as `sudo -S -p ''` with the password fed over stdin per command; password is held in memory only during the operation, never written to disk. Passwordless-sudo devices work transparently.

2. **Configure roles** — Each connected device shows live status plus its configured role (`server` / `client`). Unconfigured devices get a **Configure** button prompting for role and details (combo toggle for servers, display name for clients).

3. **Audio** — In Settings, pick the `basic` (flac, buffer 1000 ms, latency 0) or `advanced` (pcm, buffer 800 ms, latency -20) preset to fill the fields, or edit codec / buffer / latency directly — that flips the profile to `Custom`. Saved exactly as shown.

4. **Connect Spotify** — Still being wired up, so for now this is a manual step (the button doesn't do the tunnel dance yet). On the server:
   - `sudo systemctl restart librespot.service`
   - `journalctl -u librespot --no-pager -n 400 | grep -Eo 'https://accounts\.spotify\.com/[^ ]+' | tail -n 1`
   - Open that URL on your laptop with an SSH tunnel in place: `ssh -L 4000:127.0.0.1:4000 <user>@<server_ip>`, then complete login in the browser
   - Confirm with `ls /var/cache/librespot/*credentials* /var/cache/librespot/*.json`

   The plan is for the app to do all of that itself (restart → poll journal → auto-tunnel → open browser → watch for credentials). Not yet — your fleet's existing cached credentials keep playing fine meanwhile.

5. **Play** — Open Spotify on any device and select **“Multispot”**. The dashboard shows stream idle/playing state (audio pipe provides no track metadata — don’t hunt for it).

## Using the app

- **Devices** tab — Connected-device roster with live status and configured roles (`server` / `client`). Scan, add, configure, and forget devices; fresh boxes get a **Set up** button that previews the full install before touching anything; **Connect Spotify** lives here too.
- **Dashboard** tab — Live Snapcast control. The frontend opens `new WebSocket("ws://<server_ip>:1780/jsonrpc")` directly, sends `Server.GetStatus`, and keeps state live from notifications (`Client.OnConnect/OnDisconnect/OnVolumeChanged/...`, `Group.OnMute/OnStreamChanged`, `Server.OnUpdate`). Controls:
  - Per-client: volume slider (`Client.SetVolume`), mute, latency (`Client.SetLatency`), rename (`Client.SetName`)
  - Per-group: group mute (`Group.SetMute`), move clients between groups (`Group.SetClients`), delete stale clients (`Server.DeleteClient`, plus a one-click **Delete offline** for ghosts)
  - Badges: client online/offline (`Client.OnConnect/OnDisconnect`), stream idle/playing from `stream.status`
  - Clients are matched to app devices by `client.host.ip` (`::ffff:` IPv4-mapped prefix stripped for display)
  - If Snapcast or the webview rejects the cross-origin WebSocket (Origin check), the Rust fallback in `snapcast.rs` (tokio-tungstenite) bridges via Tauri events — same store shape.

- **Settings** tab — Audio preset + codec/buffer/latency (with an automatic `Custom` state when you stray from presets), Spotify name/bitrate. Hit **Save config** and you get a **Review & apply** panel: dry-run preview per device (files that would change, services that would restart), then **Apply to devices**. Anything deeper still lives in `config.yml` directly.
  - Config is stored at `app_config_dir()/config.yml` (`dev.jeffcottj.multispot`) via `serde_yaml`. Comments are not preserved (the UI replaces hand-editing for the common stuff).
  - Device passwords are never persisted; the app key is the only credential stored.

## Device-side facts (what the app manages)

- Services: `librespot.service` + `snapserver.service` on server (`After=librespot.service`, `Wants=librespot.service`, not `Requires`); `snapclient.service` on clients (`After=network-online.target sound.target`)
- FIFO: `/run/diy-sonos/snapfifo` (default), created via `mkfifo` (replacing a stray non-pipe file if one squats on the path), persisted via `/etc/tmpfiles.d/snapfifo.conf` as `d <dir> 0755 root root - -` + `p <path> 0660 root audio - -` + `systemd-tmpfiles --create`; if path is under `/tmp` or `/var/tmp`, `fs.protected_fifos=0` via `/etc/sysctl.d/99-snapfifo.conf` else removed/restored to `1`
- Snapserver config: `/etc/snapserver.conf` from `snapserver.conf.tmpl` (`sampleformat`, `codec`, `buffer`, `source = pipe:///…`)
- Ports: `1704` (audio), `1780` (HTTP control), `4000` (librespot OAuth callback, configurable via `spotify.oauth_callback_port`), `5353` (mDNS via avahi)
- Snapcast deb URL: `https://github.com/badaix/snapcast/releases/download/v{VER}/snap{server|client}_{VER}-1_{ARCH}_{CODENAME}.deb` with arch map `aarch64→arm64, armv7l|armv6l→armhf, x86_64→amd64` and codename fallback `bookworm → bullseye`
- Cache dir: `/var/cache/librespot`
- Boot-time ALSA volume restore: `/etc/systemd/system/diy-sonos-alsa-volume.service` + `/usr/local/bin/diy-sonos-apply-volume` plus `alsa-restore`/`alsa-state` units

## Troubleshooting

See `docs/troubleshooting.md` for device-side diagnostics. Quick checks via SSH:

- A per-device **Doctor** view doesn't exist yet — for now, the checks are the manual commands below, and the closest in-app diagnostic is a deploy **preview** (dry run showing exactly what differs on the box).
- Deploy output streams per step in the setup/apply panels; an unchanged fleet reports “unchanged” files and no service restarts (verify with `systemctl show -p ActiveEnterTimestamp <service>`).
- **Dashboard offline badge**: client power off → offline within seconds via `Client.OnDisconnect`.

Common fixes: Settings → Save → **Review & apply** (re-renders configs if-changed, fixes FIFO/tmpfiles/sysctl, reinstalls debs if needed). For OAuth issues, redo the manual Connect Spotify steps above for now.

## Development

Prerequisites: Rust stable (via `rustup`), Node 20 or newer, npm. (`cargo` lives in `~/.cargo/bin` — fish users: `fish_add_path ~/.cargo/bin`.)

```bash
# Frontend dev (Vite)
npm install
npm run build        # tsc && vite build

# Backend checks (from src-tauri)
cargo fmt --check
cargo clippy --locked -- -D warnings
cargo test --locked

# Desktop dev (Tauri)
npm run tauri dev
npm run tauri build        # produces installers per tauri.conf.json bundle targets
npm run tauri build -- --no-bundle  # CI check without bundling

# One-shot verification (repo root)
cargo fmt --manifest-path src-tauri/Cargo.toml -- --check
cargo clippy --locked --manifest-path src-tauri/Cargo.toml -- -D warnings
cargo test --locked --manifest-path src-tauri/Cargo.toml
npm run build
```

Distribution: `release.yml` builds on tag `v*` via `tauri-apps/tauri-action@v0` (windows-latest, macos-latest, ubuntu-22.04) and publishes installers to the GitHub Release. (`TAURI_SIGNING_*` repo secrets are dormant leftovers from the removed auto-updater — kept in case it returns.)

## License

MIT — see `LICENSE`.
