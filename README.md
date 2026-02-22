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

### 2. Edit config.yml

```bash
nano config.yml
```

Set `server_ip` to the Pi 5's IP address. Adjust `spotify.device_name` if desired.

### 3. Set up the server (Pi 5)

```bash
sudo ./setup.sh server
```

### 4. Authenticate with Spotify (first run only)

See [First-Run Spotify Authentication](#first-run-spotify-authentication) below.

### 5. Set up each client (Pi Zero 2 W)

```bash
sudo ./setup.sh client
```

Open Spotify, select your device, and music plays on all speakers in sync.

---

## First-Run Spotify Authentication

librespot uses OAuth on first run. Check the logs for the auth URL:

```bash
sudo journalctl -u librespot -f
```

Look for a line like:
```
Please authenticate at: https://accounts.spotify.com/authorize?...
```

**If you have a browser on the Pi:** open the URL directly.

**If headless (SSH only):** use SSH port-forwarding from your laptop:

```bash
# On your laptop:
ssh -L 4000:localhost:4000 pi@<pi5-ip>
```

Then open `http://localhost:4000` in your browser and complete the OAuth flow. Credentials are cached in `cache_dir` (default `/var/cache/librespot`) and won't be needed again unless you wipe the cache.

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
