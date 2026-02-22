# CLAUDE.md — DIY Sonos Architecture Notes

## Overview

DIY Sonos converts Raspberry Pis into a synchronized multi-room audio system. A Pi 5 acts as the server (Spotify Connect receiver + audio broadcaster) and Pi Zero 2 Ws act as clients (synchronized playback via USB DACs).

## Tech Stack

| Component | Technology | Why |
|-----------|-----------|-----|
| Spotify Connect | librespot (via raspotify apt repo) | Pre-built arm binary, OAuth support, active maintenance |
| Synchronized audio | Snapcast (snapserver + snapclient) | Purpose-built for multi-room sync; .deb packages for arm64/armhf |
| Config parsing | Python3 + PyYAML | Always available on Pi OS; no sed escaping issues |
| Template rendering | Python regex substitution | Simple `{{VAR}}` → env var, no extra dependencies |
| Audio pipe | Linux named FIFO | Zero-copy IPC between librespot and snapserver |

## Key File Index

| File | Purpose |
|------|---------|
| `setup.sh` | Entry point; validates args, loads config, delegates |
| `config.yml` | User-editable configuration |
| `scripts/common.sh` | Shared functions (config parsing, pkg install, systemd, ALSA) |
| `scripts/setup-server.sh` | Server install logic |
| `scripts/setup-client.sh` | Client install logic |
| `templates/snapserver.conf.tmpl` | snapserver config template |
| `templates/librespot.service.tmpl` | librespot systemd unit template |
| `templates/snapserver.service.tmpl` | snapserver systemd unit template |
| `templates/snapclient.service.tmpl` | snapclient systemd unit template |

## Port Reference

| Port | Service | Direction |
|------|---------|-----------|
| 1704 | snapserver audio stream | Pi 5 → Pi Zero clients (TCP) |
| 1780 | snapserver HTTP control API | LAN → Pi 5 |
| 5353 | mDNS (avahi) | Pi 5 → LAN (Spotify discovery) |

## Config Variable Naming

`parse_config()` in `common.sh` flattens YAML with `__` separators and uppercases:

```
spotify.device_name  →  SPOTIFY__DEVICE_NAME
snapserver.fifo_path →  SNAPSERVER__FIFO_PATH
server_ip            →  SERVER_IP
```

Templates use `{{SPOTIFY__DEVICE_NAME}}` syntax. The Python renderer substitutes from `os.environ`.

## Idempotency Guarantees

- `pkg_install`: checks `dpkg -s` before installing
- `install_deb`: checks installed version matches filename version before downloading
- `ensure_fifo`: only creates if absent
- `ensure_dir`: `mkdir -p` is idempotent
- `download_file`: skips if file exists
- `render_template`: always overwrites (config may have changed)
- `systemd_enable_restart`: restarts if running, starts if stopped

## Edge Cases and Solutions

| Issue | Solution |
|-------|---------|
| FIFO disappears on reboot (tmpfs) | `/etc/tmpfiles.d/snapfifo.conf` recreates it via `systemd-tmpfiles` |
| Kernel blocks FIFO writes in `/tmp` | `fs.protected_fifos=0` via `/etc/sysctl.d/99-snapfifo.conf` |
| librespot/snapserver startup race | `Before=snapserver.service` in librespot unit; `mode=read` in pipe source blocks snapserver until librespot opens write end |
| USB DAC card number changes on reboot | User can hardcode `hw:N,0` in config; `auto` is a best-effort fallback |
| arm64 vs armhf Pi Zero 2 W | `detect_arch` maps `uname -m` → Debian arch; snapcast provides both |
| Snapcast deb filename includes OS codename | `detect_os_codename` sets `$OS_CODENAME` for correct deb URL |
| raspotify installs its own service | Masked with `systemctl mask raspotify.service`; we use our own librespot unit |
| Snapclient deb may pull in snapserver | Masked with `systemctl mask snapserver.service` on client machines |

## Pi Zero 2 W Considerations

- **Architecture:** Pi Zero 2 W is aarch64 (arm64) when running 64-bit Pi OS, armhf on 32-bit.
- **CPU:** Quad-core Cortex-A53 @ 1 GHz. FLAC decoding is fine; avoid running other heavy services.
- **RAM:** 512 MB. snapclient is lightweight; keep buffer_ms reasonable (1000–2000 ms).
- **Wi-Fi:** single-band 2.4 GHz only. Ensure good signal to avoid dropouts.
- **Audio:** no built-in audio jack that works well. USB DAC dongles are required.

## Snapcast Version

Snapcast version is centralized in `scripts/common.sh` as `SNAPCAST_VER_DEFAULT`. Both `setup-server.sh` and `setup-client.sh` call `require_snapcast_version()` to read it and fail fast if it is empty. To upgrade, change `SNAPCAST_VER_DEFAULT` once and re-run setup. The `install_deb` function will detect the version mismatch and reinstall.

## First-Run OAuth (librespot)

librespot requires Spotify OAuth authentication on first run. The auth URL appears in journald:

```bash
sudo journalctl -u librespot -f
```

Credentials are cached in `spotify.cache_dir` (default `/var/cache/librespot`). Once cached, re-authentication is not needed unless the cache is deleted.
