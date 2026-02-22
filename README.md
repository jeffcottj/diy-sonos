# DIY Sonos

Turn Raspberry Pis into a Sonos-like synchronized multi-room audio system. A Pi 5 runs Spotify Connect and streams audio; Pi Zero 2 Ws play back in perfect sync via USB DACs.

## Audio Flow

```
Spotify App
    │ (mDNS / Spotify Connect)
    ▼
librespot  (Pi 5)
    │  raw PCM S16 44100:16:2 written to named pipe
    ▼
/tmp/snapfifo  (FIFO)
    │
    ▼
snapserver  (Pi 5 — encodes FLAC, streams over TCP 1704)
    │
    ├──────────────────────────┐
    ▼                          ▼
snapclient (Pi Zero 2 W)  snapclient (Pi Zero 2 W)  ...
    │                          │
  ALSA → USB DAC          ALSA → USB DAC
    │                          │
 Speaker                    Speaker
```

## Hardware Requirements

| Device | Role | Notes |
|--------|------|-------|
| Raspberry Pi 5 | Server | Runs librespot + snapserver |
| Raspberry Pi Zero 2 W (×N) | Clients | One per room |
| USB audio DAC dongle (×N) | Audio output | One per Pi Zero |
| USB speakers / 3.5mm speakers | Output | Per room |

All Pis must be on the same local network.

## Quick Start

### 1. Clone the repo on each Pi

```bash
git clone https://github.com/yourusername/diy-sonos.git
cd diy-sonos
```

### 2. Run the guided setup config wizard (recommended)

```bash
./setup.sh init
```

The wizard asks for role (`server`/`client`), server IP, Spotify device name, and audio options, then writes `.diy-sonos.generated.yml`.

You can also script this step non-interactively:

```bash
./setup.sh init --role client --server-ip 192.168.1.100 --device-name "Kitchen" --audio-device hw:1,0
```

Config precedence is:
1. CLI flags (`--server-ip`, `--device-name`, `--audio-device`)
2. `.diy-sonos.generated.yml`
3. `config.yml` (repo defaults)

### 3. Set up the server (Pi 5)

```bash
sudo ./setup.sh server
```

### 3.5 Run fast preflight checks (optional but recommended)

```bash
./setup.sh preflight server
./setup.sh preflight client
```

Preflight validates required binaries (`apt-get`, `systemctl`), network reachability, supported OS/arch, and key config values before install. `setup.sh server|client` runs this automatically and aborts early if checks fail.


### 3.6 Run runtime health checks (doctor)

```bash
sudo ./setup.sh doctor server
sudo ./setup.sh doctor client
```

Doctor reports service states, key ports/listeners, FIFO presence on server, resolved audio device on client, and recent error excerpts from systemd journals. Failed checks include recommended remediation commands.


### 4. Authenticate with Spotify (first run only)

See [First-Run Spotify Authentication](#first-run-spotify-authentication) below.

### 5. Set up each client (Pi Zero 2 W)

```bash
sudo ./setup.sh client
```

### 6. Bootstrap many clients remotely (optional)

Use the orchestrator script from your admin machine to copy this repo to each Pi and run `sudo ./setup.sh client` remotely:

```bash
./scripts/bootstrap-clients.sh --hosts 192.168.1.121,192.168.1.122 --inventory clients.yml
```

You can also pass a newline-delimited host file:

```bash
./scripts/bootstrap-clients.sh --hosts-file hosts.txt --inventory clients.yml
```

The script reads per-client overrides from `clients.yml`:
- `name` → Spotify device name
- `latency` → `snapclient.latency_ms`
- `audio_device` → `snapclient.audio_device`

Host selection comes from `--hosts` / `--hosts-file`; `clients.yml` supplies optional overrides by matching `clients[].host`.

Open Spotify, select your device, and music plays on all speakers in sync.

### Advanced: manual YAML editing

If you prefer to hand-edit config, update `config.yml` and/or `.diy-sonos.generated.yml` directly.

Snapcast package upgrades are controlled in one place: `scripts/common.sh` → `SNAPCAST_VER_DEFAULT`. Update that value, then re-run setup on server and clients.

---

## First-Run Spotify Authentication

librespot uses OAuth on first run. After `sudo ./setup.sh server`, use the helper command:

```bash
sudo librespot-auth-helper 4000 /var/cache/librespot
```

This command deterministically reports:
- `cached credentials found` when OAuth credentials already exist in `cache_dir`
- `auth still pending` when OAuth is not complete yet

It also prints the latest Spotify OAuth URL extracted from:

```bash
sudo journalctl -u librespot --no-pager -n 400
```

For live logs, you can still run:

```bash
sudo journalctl -u librespot -f
```

For headless SSH setups, `setup.sh server` now prints a ready-to-copy tunnel one-liner using the detected host IP and configured callback port (default `4000`), for example:

```bash
ssh -L 4000:localhost:4000 pi@192.168.1.100
```

Then open `http://localhost:4000` in your browser and complete the OAuth flow.

---

## Configuration Reference

Edit `config.yml` to customize behaviour. Re-run `sudo ./setup.sh server|client` after changes.

| Key | Default | Description |
|-----|---------|-------------|
| `server_ip` | `192.168.1.100` | IP of the Pi 5; used by clients to connect |
| `spotify.device_name` | `DIY Sonos` | Name shown in the Spotify device list |
| `spotify.bitrate` | `320` | Spotify stream bitrate: 96, 160, or 320 kbps |
| `spotify.normalise` | `true` | Enables librespot volume normalisation (`--enable-volume-normalisation` is included only when `true`) |
| `spotify.initial_volume` | `75` | Initial volume (0–100) |
| `spotify.cache_dir` | `/var/cache/librespot` | OAuth credential and metadata cache |
| `spotify.oauth_callback_port` | `4000` | Local OAuth callback port used by librespot and SSH tunnel helper |
| `spotify.device_type` | `speaker` | Icon shown in Spotify: `speaker`, `avr`, `tv`, etc. |
| `snapserver.fifo_path` | `/tmp/snapfifo` | Named pipe between librespot and snapserver |
| `snapserver.sampleformat` | `44100:16:2` | Audio sample format (must match librespot) |
| `snapserver.codec` | `flac` | Streaming codec: `flac` or `pcm` |
| `snapserver.buffer_ms` | `1000` | End-to-end latency buffer in milliseconds |
| `snapserver.port` | `1704` | TCP port for audio streaming |
| `snapserver.control_port` | `1780` | HTTP control API port |
| `snapclient.audio_device` | `auto` | ALSA device: `auto` or explicit like `hw:1,0` |
| `snapclient.latency_ms` | `0` | Per-client latency trim in milliseconds |
| `snapclient.instance` | `1` | Instance number (increment for multiple clients on same host) |

---

## Audio Device Configuration

### Auto-detection

When `snapclient.audio_device` is `auto`, the setup script scans `aplay -l` for the first USB audio card and uses `hw:N,0`. This works for most USB DAC dongles.

### Manual override

If the auto-detected device is wrong, or the card number changes on reboot, hardcode it:

```yaml
snapclient:
  audio_device: "hw:1,0"   # replace with your card number
```

Find your card number:
```bash
aplay -l
# Look for your USB DAC in the output, note the card number
```

---

## Troubleshooting

### No sound on a client

```bash
# Run built-in diagnostics first
sudo ./setup.sh doctor client

# Check snapclient is running
sudo systemctl status snapclient

# Check it can reach the server
sudo journalctl -u snapclient -f

# Test the audio device directly
aplay -l                              # list devices
speaker-test -t wav -c 2 -D hw:1,0   # replace hw:1,0 with your device
```

### Device not found in Spotify

```bash
# Check librespot is running and authenticated
sudo systemctl status librespot
sudo journalctl -u librespot -f

# Ensure avahi-daemon is running (for mDNS discovery)
sudo systemctl status avahi-daemon
```

### Audio dropouts / poor sync

- Increase `snapserver.buffer_ms` (e.g. 2000) in `config.yml` and re-run server setup.
- Ensure all Pis have a strong Wi-Fi signal.
- Check CPU load on Pi Zero clients: `top` — Pi Zero 2 W can handle FLAC decoding but should not be doing other heavy work.
- Try `codec: pcm` in `config.yml` if FLAC decoding causes issues on Pi Zero.

### FIFO errors / librespot can't write to pipe

```bash
# Check FIFO exists
ls -la /tmp/snapfifo

# Check sysctl setting
sysctl fs.protected_fifos   # should be 0

# Recreate FIFO if missing
sudo mkfifo /tmp/snapfifo
sudo systemctl restart librespot snapserver
```

### USB DAC card number changed after reboot

Set `snapclient.audio_device` to an explicit `hw:N,0` value and re-run client setup. Card numbers are assigned by the kernel at boot and can shift when devices are added/removed.

---

## Re-running Setup

All setup scripts are idempotent — safe to re-run after changing `config.yml`:

```bash
sudo ./setup.sh server   # re-renders configs and restarts services
sudo ./setup.sh client   # re-renders client service and restarts
```

Packages are only installed if not already present. Services are restarted only after configuration is updated.

`scripts/bootstrap-clients.sh` is also designed for idempotent reruns: it re-syncs the repo, regenerates `.diy-sonos.generated.yml`, reapplies latency overrides from inventory, and re-runs `sudo ./setup.sh client` on each target host.

---

## Secure SSH Prerequisites for Remote Bootstrap

Before using `scripts/bootstrap-clients.sh`, ensure:

- SSH key-based authentication is configured for each client (`ssh-copy-id` or equivalent).
- Host keys are verified and present in `~/.ssh/known_hosts` (do a manual SSH once per host).
- The remote user can run `sudo ./setup.sh client` non-interactively when automating. Use `--sudo-passless-check` to fail fast if passwordless sudo is unavailable.
- You trust the management machine running the script, since it handles your SSH key and can execute privileged commands remotely.

The script uses OpenSSH BatchMode (`-o BatchMode=yes`) so it will fail instead of prompting for passwords.
