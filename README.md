# DIY Sonos

Turn small Linux devices into a Sonos-like synchronized multi-room audio system. A server device runs Spotify Connect and streams audio; client devices play back in perfect sync via USB DACs.

Tested hardware: Raspberry Pi 5 (server) and Raspberry Pi Zero 2 W units (clients).

## Audio Flow

```
Spotify App
    │ (mDNS / Spotify Connect)
    ▼
librespot  (server device)
    │  raw PCM S16 44100:16:2 written to named pipe
    ▼
/tmp/snapfifo  (FIFO)
    │
    ▼
snapserver  (server device — encodes FLAC, streams over TCP 1704)
    │
    ├──────────────────────────┐
    ▼                          ▼
snapclient (client device)  snapclient (client device)  ...
    │                          │
  ALSA → USB DAC          ALSA → USB DAC
    │                          │
 Speaker                    Speaker
```

## Hardware Requirements

| Device | Role | Notes |
|--------|------|-------|
| Linux-capable device (e.g., Raspberry Pi 5) | Server | Runs librespot + snapserver |
| Linux-capable device (×N, e.g., Raspberry Pi Zero 2 W) | Clients | One per room |
| USB audio DAC dongle (×N) | Audio output | One per client device |
| USB speakers / 3.5mm speakers | Output | Per room |

All devices must be on the same local network.

## Prerequisites

- All devices must have SSH key authentication set up so `deploy.sh` can connect without a password prompt.
- You must know the IP address for each device you want to configure.

---

## Quick Start

Need help diagnosing setup or runtime issues? See [Troubleshooting](docs/troubleshooting.md).

### Primary path: one-command guided setup

After install/clone, run:

```bash
./first-run.sh
```

This guided script walks you through the complete first-time flow:
1. Local dependency check (`ssh`, `ssh-copy-id`, `python3`, `rsync`)
2. Interactive config collection (`./configure.sh`)
3. SSH key setup (`./configure.sh --copy-keys`)
4. Connectivity check (key-based SSH to all configured hosts)
5. Deployment (`./deploy.sh`)
6. Final Spotify “what to do next” summary

### Manual path (step-by-step)

### Fastest path (recommended for first install)

Use the beginner preset to generate `.diy-sonos.generated.yml` with only the essentials:

- server IP
- one or more client IPs
- optional speaker name

All advanced audio values are auto-filled (bitrate, codec, buffer, audio auto-detect).

```bash
./setup.sh init --preset basic
```

Non-interactive example:

```bash
./setup.sh init --preset basic --server-ip 192.168.1.100 --client-ips 192.168.1.121,192.168.1.122 --device-name "Living Room"
```

### 1. Install from release (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/jeffcottj/diy-sonos/main/install.sh | bash -s -- --install-dir "$HOME/diy-sonos"
```

This installer resolves the latest tagged release, downloads the tarball, preserves existing local config files (`config.yml`, `.diy-sonos.generated.yml`, `clients.yml`) during upgrades, writes release metadata to `.diy-sonos-version`, and then offers to run the guided setup wizard.
Re-running `install.sh` is safe: the release payload is replaced, then preserved local config files are restored automatically.

To pin a specific release tag or re-install safely:

```bash
./install.sh --tag v0.1.0
```

To keep persistent snapshots of existing `config.yml` files before reinstalling:

```bash
./install.sh --tag v0.1.0 --backup-dir "$HOME/diy-sonos-install-backups"
```

### If this command fails

Use one of these fallback paths:

1. Clone and run init:

```bash
git clone https://github.com/jeffcottj/diy-sonos.git
cd diy-sonos
./setup.sh init
```

2. Download a release tarball manually and run init:

```bash
TAG="v0.1.0"
curl -fL "https://github.com/jeffcottj/diy-sonos/archive/refs/tags/${TAG}.tar.gz" -o diy-sonos.tar.gz
mkdir -p diy-sonos && tar -xzf diy-sonos.tar.gz --strip-components=1 -C diy-sonos
cd diy-sonos
./setup.sh init
```

### 2. Configure from your laptop

Run the interactive wizard on your laptop to collect IPs and write `config.yml`:

```bash
./configure.sh
```

```
DIY Sonos — Setup Wizard

Speaker system name (shown in Spotify) [DIY Sonos]: Living Room
Server device IP: 192.168.1.100
SSH username on each device [pi]:

Enter client device IPs one at a time. Press Enter with no input when done.
  Client IP: 192.168.1.121
  Client IP: 192.168.1.122
  Client IP:

Configuration summary:
  System name : Living Room
  Server IP   : 192.168.1.100
  SSH user    : pi
  Clients     : 192.168.1.121 192.168.1.122
Write config.yml? [Y/n]:

✓ config.yml written.
```

Then set up SSH keys (one-time):

```bash
./configure.sh --copy-keys
```

### 3. Deploy everything from your laptop

```bash
./deploy.sh
```

`deploy.sh` will:
1. Verify SSH connectivity to all devices (fails fast before touching anything)
2. Rsync this repo to the server device and run `sudo ./setup.sh server`
3. Surface the Spotify OAuth URL (or print fallback instructions if not found)
4. Rsync to each client device and run `sudo ./setup.sh client`
5. Print a pass/fail summary table

### 4. Open Spotify

Select your speaker system from the Spotify device list. Music plays on all speakers in sync.

---

### Upgrade an existing install

Use upgrade mode to re-run idempotent package/service setup for the configured role while preserving your existing config files:

```bash
sudo ./setup.sh upgrade
```

You can override role detection explicitly:

```bash
sudo ./setup.sh upgrade --role server
sudo ./setup.sh upgrade --role client
```


### Run fast preflight checks (optional but recommended)

```bash
./setup.sh preflight server
./setup.sh preflight client
```

Preflight validates required binaries (`apt-get`, `systemctl`), network reachability, supported OS/arch, and key config values before install. `setup.sh server|client` runs this automatically and aborts early if checks fail.


### Run runtime health checks (doctor)

```bash
sudo ./setup.sh doctor server
sudo ./setup.sh doctor client
```

Doctor reports service states, key ports/listeners, FIFO presence on server, resolved audio device on client, and recent error excerpts from systemd journals. Failed checks include recommended remediation commands.

### Retry safety and recovery

Safe-to-rerun commands:

```bash
./deploy.sh
sudo ./setup.sh upgrade
sudo ./setup.sh doctor server
sudo ./setup.sh doctor client
```

- `deploy.sh`: re-syncs repository contents and re-runs setup on each host. It is designed for retries after transient network/auth failures.
- `setup.sh upgrade`: detects role and re-applies package + config setup idempotently.
- `setup.sh doctor`: read-only health checks, no configuration writes.

Recovering partially configured hosts:

1. Run doctor to identify what failed:
   ```bash
   sudo ./setup.sh doctor server
   sudo ./setup.sh doctor client
   ```
2. Re-run install for the role:
   ```bash
   sudo ./setup.sh upgrade --role server
   sudo ./setup.sh upgrade --role client
   ```
3. If this was a multi-host deployment, re-run from your laptop:
   ```bash
   ./deploy.sh
   ```

Optional backup snapshots before major writes:

```bash
sudo ./setup.sh server --backup-snapshots
sudo ./setup.sh client --backup-snapshots
sudo ./setup.sh upgrade --backup-dir /var/backups/diy-sonos/manual-$(date +%Y%m%d-%H%M%S)
./setup.sh init --backup-snapshots
```

When enabled, setup snapshots existing config/unit files before overwrite (e.g. `/etc/snapserver.conf`, `/etc/systemd/system/*.service`, and `.diy-sonos.generated.yml`) and prints exact restore commands.

Restoring a previous file from snapshot:

```bash
sudo cp -a /var/backups/diy-sonos/<snapshot>/etc/systemd/system/snapclient.service /etc/systemd/system/snapclient.service
sudo systemctl daemon-reload
sudo systemctl restart snapclient
```

---

### Advanced: on-device setup (alternative to deploy.sh)

If you prefer to SSH into each device individually:

```bash
# On the server device
sudo ./setup.sh server

# On each client device
sudo ./setup.sh client
```

For a single host acting as both server and player, set `profile.role: "server+client"` and run both modes on that host (`sudo ./setup.sh server` then `sudo ./setup.sh client`).

The guided init wizard (also runs on-device):

```bash
./setup.sh init
```

Non-interactive:

```bash
./setup.sh init --role client --server-ip 192.168.1.100 --device-name "Kitchen" --audio-device hw:1,0
```

Config precedence is:
1. CLI flags (`--server-ip`, `--device-name`, `--audio-device`)
2. `.diy-sonos.generated.yml`
3. `config.yml` (repo defaults)

### Advanced: bootstrap many clients remotely

For power users who need per-client latency overrides via an inventory file:

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
- `output_volume` → `snapclient.output_volume`

Host selection comes from `--hosts` / `--hosts-file`; `clients.yml` supplies optional overrides by matching `clients[].host`.

### Advanced: manual YAML editing

If you prefer to hand-edit config, update `config.yml` and/or `.diy-sonos.generated.yml` directly.

Snapcast package upgrades are controlled in one place: `scripts/common.sh` → `SNAPCAST_VER_DEFAULT`. Update that value, then re-run setup on server and clients.

---

## Contributor / Developer Path (clone from source)

If you are developing or contributing, clone from source instead of using the release installer:

```bash
git clone https://github.com/jeffcottj/diy-sonos.git
cd diy-sonos
```

Then run the same guided workflow (`./setup.sh init`, `sudo ./setup.sh server|client`).

---

## Spotify Authentication

On first run, run one command on the server:

```bash
sudo librespot-auth-helper start-auth 4000 /var/cache/librespot
```

The helper prints explicit terminal outcomes:
- `SUCCESS: ...` when credentials are already cached
- `FAILURE: ...` when auth is still pending or the OAuth URL is not yet available

It automatically detects whether you are connected over SSH and prints step-by-step instructions for:
- laptop browser flow (explicit `ssh -N -L ...` tunnel command that must stay open)
- on-device browser flow (`xdg-open`)

It also prints callback listener status (`READY` / `NOT READY`) so you can quickly tell whether librespot is actually listening on the OAuth callback port.

`deploy.sh` always prints this same `start-auth` command as the clear next action after server install.

### Machine-parseable auth-cache verification

For automation/CI scripts, use:

```bash
sudo librespot-auth-helper verify-auth-cache /var/cache/librespot
```

Output is deterministic key/value lines:
- `AUTH_CACHE_STATUS=cached` (exit code `0`)
- `AUTH_CACHE_STATUS=pending` (exit code `1`)

You can still inspect service logs directly:

```bash
sudo journalctl -u librespot -f
```

---

## Configuration Reference

Edit `config.yml` to customize behaviour. Re-run `sudo ./setup.sh server|client` after changes.

| Key | Default | Description |
|-----|---------|-------------|
| `ssh_user` | `pi` | SSH username used by `deploy.sh` and `configure.sh --copy-keys` |
| `server_ip` | `192.168.1.100` | IP of the server device; used by clients to connect and by `deploy.sh` |
| `clients[].ip` | _(none)_ | IP of each client device; used by `deploy.sh` |
| `spotify.device_name` | `DIY Sonos` | Name shown in the Spotify device list |
| `spotify.bitrate` | `320` | Spotify stream bitrate: 96, 160, or 320 kbps |
| `spotify.normalise` | `true` | Enables librespot volume normalisation (`--enable-volume-normalisation` is included only when `true`) |
| `spotify.initial_volume` | `90` | Initial volume (0–100) |
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
| `snapclient.output_volume` | `90` | Client hardware mixer output volume percent (0–100), applied via `amixer` during client setup |
| `snapclient.latency_ms` | `0` | Per-client latency trim in milliseconds |
| `snapclient.instance` | `1` | Instance number (increment for multiple clients on same host) |

`spotify.initial_volume` controls librespot's software stream volume at playback start on the server. `snapclient.output_volume` controls each client's local ALSA hardware mixer ceiling during setup. Use both: set a safe hardware baseline per client with `snapclient.output_volume`, then tune listening level behavior with `spotify.initial_volume`.

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
- Ensure all devices have a strong Wi-Fi signal.
- Check CPU load on client devices: `top` — lower-power clients can handle FLAC decoding but should not be doing other heavy work.
- Try `codec: pcm` in `config.yml` if FLAC decoding causes issues on lower-power clients.

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
sudo ./setup.sh server    # re-renders configs and restarts services
sudo ./setup.sh client    # re-renders client service and restarts
sudo ./setup.sh upgrade   # detects role and re-runs install safely
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
