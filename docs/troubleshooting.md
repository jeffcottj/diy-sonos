# Troubleshooting

This guide is for the **DIY Sonos desktop app** (Tauri + Rust). The bash toolchain (`setup.sh`, `deploy.sh`, etc.) no longer exists. All orchestration — rendering configs, pushing file contents over the same SSH connection (base64-staged, no SFTP involved), running remote commands over SSH — is done by the app. Remote privileged actions remain ordinary shell commands (`apt-get`, `systemctl`, `amixer`, `journalctl`) that the app orchestrates; it doesn’t replace them.

Device-side facts (services, FIFO, ports) are unchanged; only how you invoke them has moved from scripts to the app.

## Quick way: the app

A quick heads-up on what's real in the app today and what isn't (all of it's getting there):

- **Doctor view** — not built yet. The health-check logic lives in `doctor.rs` as tested helpers, but no button runs it against your boxes. The SSH commands below are the real deal for now.
- **Deploy preview + log** — this part works. Fresh devices get **Set up** on their Devices row, and Settings saves open a **Review & apply** panel: dry-run diffs per box, then a live log while it runs.
- **Connect Spotify auto-flow** — also still manual (see the OAuth section for steps that work today).

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

If a service is not active/enabled/installed, push a fix from the app with Settings → Save → **Review & apply** (re-renders `*.service` units if-changed, `daemon-reload`, enable + restart only if configs changed). Once a Doctor view exists, its remediation will point at Review & apply.

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

The server should be listening on `0.0.0.0:1704` and `0.0.0.0:1780`. If not:

```bash
sudo ss -ltnp | grep -E ':(1704|1780)\b'
sudo systemctl status snapserver --no-pager -l
```

Client → server stream is TCP 1704; control is 1780. Verify no firewall blocks them. If the units look wrong, Settings → Save → **Review & apply** re-renders them.

## FIFO

Default path `/run/diy-sonos/snapfifo`. It should be a pipe (`[[ -p … ]]`).

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

If FIFO missing, a Settings save + **Review & apply** recreates it (the preview will show it planned).

## Audio device mismatch (clients)

Doctor warns if resolved audio device is `default`. On modern Pi OS, `default` is PipeWire-backed and won’t work in a system service.

Resolution is the same logic as `detect_alsa_usb_device` in the old `common.sh` (first `USB-Audio` driver card → `plughw:<name>,0`; else first non-HDMI card; else `default` with loud warning):

```bash
cat /proc/asound/cards
aplay -l
aplay -L | head -n 80
```

Pick a valid device (e.g., `plughw:Device,0` or `hw:1,0`) and set it by hand for now (no picker in the UI yet — edit `~/.config/dev.jeffcottj.diy-sonos/config.yml`, `snapclient.audio_device` globally or per-client `audio_device`, then Settings → Save → **Review & apply** to push it). The app also sets ALSA volume via `amixer` + `alsactl store` and installs `/etc/systemd/system/diy-sonos-alsa-volume.service` + `/usr/local/bin/diy-sonos-apply-volume` for boot restore.

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

1. The in-app auto-flow isn't wired up yet, so here's the manual version that works today:

```bash
sudo systemctl restart librespot.service
journalctl -u librespot --no-pager -n 400 | grep -Eo 'https://accounts\.spotify\.com/[^ ]+' | tail -n 1
# on your laptop, in another terminal:
ssh -L 4000:127.0.0.1:4000 <user>@<server_ip>
# then open the URL from the journal in your browser
```

The endgame is the app doing all of that itself (restart → poll the journal → auto-tunnel → open the browser → watch the credential cache). Almost there, not yet.

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

Via the app: a device row’s setup/deploy log, or the Settings **Review & apply** preview → copy the output.

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

FIFO consumer missing (snapserver not running). Check `snapserver.service` active, `librespot.service` uses `--backend pipe --device /run/diy-sonos/snapfifo`, `/etc/snapserver.conf` has `source = pipe:///run/diy-sonos/snapfifo?...`. Push a fix via Settings → Save → **Review & apply**.

### B) Client active but silent

Usually ALSA device mismatch — `snapclient.service` `--soundcard` is `default` or wrong. Check `aplay -l`, fix `audio_device` (config file for now, see above), and apply.

### C) One client works with speaker-test but not Spotify

Local audio OK, stream path broken: check server FIFO `lsof`, snapserver logs for connect/disconnect, client snapclient logs for decode errors. Re-apply settings to server and client.

### Ports

| Port | Purpose |
|------|---------|
| 1704 | Snapcast audio stream (server → clients, TCP) |
| 1780 | Snapcast HTTP control API (WebSocket JSON-RPC) |
| 4000 | librespot OAuth callback (`spotify.oauth_callback_port`) |
| 5353 | mDNS via avahi (Spotify discovery) |

All references to `./setup.sh doctor`, `./deploy.sh`, `./first-run.sh`, and `config.yml` in the repo root now map to GUI flows: deploy = Settings → Save → **Review & apply** (or **Set up** on a fresh device row, both with live logs), config = the Settings UI plus `config.yml` directly for the bits with no UI yet (stored at `app_config_dir()/config.yml`). A Doctor view is still on the to-do list.
