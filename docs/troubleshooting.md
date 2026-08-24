# Troubleshooting

This guide is for the **DIY Sonos desktop app** (Tauri + Rust). The bash toolchain (`setup.sh`, `deploy.sh`, etc.) no longer exists. All orchestration — rendering configs, uploading via SFTP, running remote commands over SSH — is done by the app. Remote privileged actions remain ordinary shell commands (`apt-get`, `systemctl`, `amixer`, `journalctl`) that the app orchestrates; it doesn’t replace them.

Device-side facts (services, FIFO, ports) are unchanged; only how you invoke them has moved from scripts to the app.

## Quick way: the app

- **Device detail → Doctor** — runs per-device health checks and returns `CheckResult { status: pass|fail|warn|info, message, explanation, remediation }`. Failures are “must-fix”, warns are optional. Remediation now says “Redeploy this device” instead of shell commands.
- **Device detail → Deploy log** — live `deploy-log {deviceId, step, level, line}` + `deploy-status {deviceId, phase, done}` per device.
- **Connect Spotify** panel — handles the OAuth tunnel automatically (no manual `ssh -L`).

If you prefer manual SSH, `ssh <user>@<host>` and use the commands below; they’re the same ones the app runs via `sudo -S -p ''`.

## Services

| Device | Expected units |
|--------|---------------|
| Server | `librespot.service` (After=librespot, Wants=librespot), `snapserver.service`, `avahi-daemon.service` |
| Client | `snapclient.service`, `diy-sonos-alsa-volume.service` (+ `alsa-restore.service` or `alsa-state.service`) |

Check via SSH:

```bash
systemctl status librespot snapserver avahi-daemon --no-pager -l
systemctl status snapclient --no-pager -l
systemctl is-enabled librespot snapserver snapclient avahi-daemon
systemctl is-active librespot snapserver snapclient avahi-daemon
sudo journalctl -u librespot -u snapserver -u snapclient -p err -n 15 --no-pager
```

If a service is not active/enabled/installed, use **Redeploy this device** in the app (re-renders `*.service` units if-changed, `daemon-reload`, enable + restart only if configs changed). The doctor’s remediation will say “Redeploy”.

## Network / DNS failures

Preflight or deploy fails with DNS errors, or GitHub download fails.

- App preflight does `SSH → cat /etc/os-release` + `uname -m` and checks package lists freshness (`/var/lib/apt/periodic/update-success-stamp` < 1h else `apt-get update`).
- Manual check:

```bash
resolvectl status
# if broken:
sudo resolvectl dns eth0 1.1.1.1 8.8.8.8
nc -vz github.com 443
```

## Snapserver connectivity

Doctor checks listeners via `ss -ltnp` for `0.0.0.0:1704` and `0.0.0.0:1780`. If fail:

```bash
sudo ss -ltnp | grep -E ':(1704|1780)\b'
sudo systemctl status snapserver --no-pager -l
```

Client → server stream is TCP 1704; control is 1780. Verify no firewall blocks them. Redeploy server.

## FIFO

Default path `/run/diy-sonos/snapfifo`. Doctor checks `[[ -p /run/diy-sonos/snapfifo ]]`.

- FIFO is created via `mkfifo`, persisted via `/etc/tmpfiles.d/snapfifo.conf`:

```
d /run/diy-sonos 0755 root root - -
p /run/diy-sonos/snapfifo 0660 root audio - -
```

run `systemd-tmpfiles --create` immediately.

- If `snapserver.fifo_path` is overridden under `/tmp` or `/var/tmp`, the app writes `fs.protected_fifos=0` via `/etc/sysctl.d/99-snapfifo.conf` else removes it and restores `=1`.

Manual checks:

```bash
ls -l /run/diy-sonos/snapfifo
file /run/diy-sonos/snapfifo   # should be FIFO
sudo lsof /run/diy-sonos/snapfifo || true  # shows writer/reader during playback
cat /etc/tmpfiles.d/snapfifo.conf
cat /etc/sysctl.d/99-snapfifo.conf 2>/dev/null || echo "no sysctl override"
```

If FIFO missing, redeploy server.

## Audio device mismatch (clients)

Doctor warns if resolved audio device is `default`. On modern Pi OS, `default` is PipeWire-backed and won’t work in a system service.

Resolution is the same logic as `detect_alsa_usb_device` in the old `common.sh` (first `USB-Audio` driver card → `plughw:<name>,0`; else first non-HDMI card; else `default` with loud warning):

```bash
cat /proc/asound/cards
aplay -l
aplay -L | head -n 80
```

Pick a valid device (e.g., `plughw:Device,0` or `hw:1,0`) and set it per-client in **Settings → Clients → audio_device** (or globally via `snapclient.audio_device` if `auto` should detect correctly). Then redeploy that client. The app also sets ALSA volume via `amixer` + `alsactl store` and installs `/etc/systemd/system/diy-sonos-alsa-volume.service` + `/usr/local/bin/diy-sonos-apply-volume` for boot restore.

Test locally:

```bash
speaker-test -t wav -c 2 -D plughw:1,0
amixer scontrols; amixer get Master; amixer get PCM
```

## Volume

- Per-client `output_volume` (0-100) is resolved as: per-client override for that IP if valid, else global `snapclient.output_volume`, else `90` on invalid. The app sets it via `amixer` and persists via `alsactl store` + the boot restore service.
- Spotify initial volume (`spotify.initial_volume`) is the librespot starting volume; normalise flag maps to `--enable-volume-normalisation` or empty.

## Spotify not visible / OAuth

If “DIY Sonos” doesn’t appear in Spotify:

1. In the app, open **Connect Spotify** (or `start_oauth` via command). The app restarts `librespot.service` and polls `journalctl -u librespot --no-pager -n 400` for the last `https://accounts\.spotify\.com/[^ ]+` URL, starts a local port-forward (`127.0.0.1:4000` → device `127.0.0.1:4000` via russh `direct-tcpip`), opens the URL in your browser (via `tauri-plugin-opener`), and emits `oauth-url {url}` events until credentials appear in `cache_dir` (`/var/cache/librespot/*credentials*` or `*.json` via `ls` glob). No manual `ssh -L` needed.

2. Manual check (SSH to server):

```bash
systemctl status librespot --no-pager -l
journalctl -u librespot --no-pager -n 400 | grep -Eo 'https://accounts\.spotify\.com/[^ ]+' | tail -n 1
ls -l /var/cache/librespot/*credentials* /var/cache/librespot/*.json 2>&1 | head
cat /etc/systemd/system/librespot.service | grep ExecStart
```

If `avahi-daemon` is inactive, Spotify may not discover the device:

```bash
systemctl status avahi-daemon --no-pager
sudo systemctl enable --now avahi-daemon
```

## ALSA mixer state not persisting

After reboot, volume resets:

```bash
sudo alsactl store
sudo systemctl enable --now alsa-restore.service  # or alsa-state.service
```

Even with persistence, USB card renumbering can break `hw:1,0` references; prefer stable `plughw:<name>,0` or ALSA aliases/udev naming.

## Collecting diagnostics to share

Via the app: **Device detail → Doctor** and **Deploy log** → copy output.

Via SSH (if asked):

```bash
# Server
systemctl status librespot snapserver avahi-daemon --no-pager -l
journalctl -u librespot -n 200 --no-pager
journalctl -u snapserver -n 200 --no-pager
ss -ltnp | grep -E ':(1704|1780)\b'
ls -l /run/diy-sonos/snapfifo; cat /etc/tmpfiles.d/snapfifo.conf; cat /etc/snapserver.conf
systemctl cat librespot; systemctl cat snapserver

# Each client
systemctl status snapclient --no-pager -l
journalctl -u snapclient -n 200 --no-pager
aplay -l; aplay -L | head -n 80
systemctl cat snapclient
```

Also share `~/.config/dev.jeffcottj.diy-sonos/config.yml` (the app’s config) and the timestamp when you started Spotify playback.

## Common failure signatures

### A) librespot logs `Broken pipe (os error 32)`

FIFO consumer missing (snapserver not running). Check `snapserver.service` active, `librespot.service` uses `--backend pipe --device /run/diy-sonos/snapfifo`, `/etc/snapserver.conf` has `source = pipe:///run/diy-sonos/snapfifo?...`. Redeploy server.

### B) Client active but silent

Usually ALSA device mismatch — `snapclient.service` `--soundcard` is `default` or wrong. Check `aplay -l` and redeploy with correct per-client `audio_device`.

### C) One client works with speaker-test but not Spotify

Local audio OK, stream path broken: check server FIFO `lsof`, snapserver logs for connect/disconnect, client snapclient logs for decode errors. Redeploy server and client.

### Ports

| Port | Purpose |
|------|---------|
| 1704 | Snapcast audio stream (server → clients, TCP) |
| 1780 | Snapcast HTTP control API (WebSocket JSON-RPC) |
| 4000 | librespot OAuth callback (`spotify.oauth_callback_port`) |
| 5353 | mDNS via avahi (Spotify discovery) |

All references to `./setup.sh doctor`, `./deploy.sh`, `./first-run.sh`, and `config.yml` in the repo root now map to GUI flows: doctor = app’s Doctor, deploy = app’s Deploy (with live log), config = Settings UI (stored at `app_config_dir()/config.yml`).
