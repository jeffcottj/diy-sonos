# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

Turns Raspberry Pis into a synchronized multi-room audio system. A Pi 5 runs Spotify Connect (librespot) and streams audio via Snapcast; Pi Zero 2 Ws play back in sync through USB DACs.

```
Spotify App → librespot (Pi 5) → /tmp/snapfifo (FIFO) → snapserver → snapclient(s) → ALSA → USB DAC
```

## Validating Changes

There is no test suite. Use these to verify correctness:

```bash
# Syntax-check all shell scripts
bash -n setup.sh install.sh
bash -n scripts/common.sh scripts/setup-server.sh scripts/setup-client.sh
bash -n scripts/bootstrap-clients.sh scripts/librespot-auth-helper.sh

# Verify config parsing produces expected env vars
python3 - config.yml <<'EOF'
import sys, yaml
def flatten(obj, prefix=""):
    items = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = (prefix + "__" + str(k)) if prefix else str(k)
            items.update(flatten(v, key))
    else:
        items[prefix] = obj
    return items
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
for k, v in flatten(data).items():
    print(k.upper().replace("-", "_"), "=", repr(str(v)))
EOF
```

## setup.sh — Command Modes

`setup.sh` is the sole entry point and dispatches to sub-modes:

| Mode | Usage | What it does |
|------|-------|--------------|
| `init` | `./setup.sh init [--role server\|client] [--server-ip IP] [--device-name NAME] [--audio-device DEV]` | Interactive wizard; writes `.diy-sonos.generated.yml` |
| `preflight` | `./setup.sh preflight server\|client` | Validates binaries, network, OS/arch, config values — no writes |
| `server` | `sudo ./setup.sh server` | Full server install (runs preflight first) |
| `client` | `sudo ./setup.sh client` | Full client install (runs preflight first) |
| `upgrade` | `sudo ./setup.sh upgrade [--role server\|client]` | Idempotent reinstall; detects role from installed services if not specified |
| `doctor` | `sudo ./setup.sh doctor server\|client` | Runtime health checks: services, ports, FIFO, audio device, recent errors |
| `version` | `./setup.sh version` | Prints `.diy-sonos-version` metadata |

## Config System

### Three-layer precedence (highest wins)

1. **CLI flags** — `--server-ip`, `--device-name`, `--audio-device` (applied by `apply_cli_config_overrides()`)
2. **`.diy-sonos.generated.yml`** — written by `./setup.sh init`; not committed to git
3. **`config.yml`** — repo defaults; the only file users should hand-edit

`parse_config_files()` in `common.sh` merges layers in order. Both files are flattened with `__` separators and uppercased:

```
spotify.device_name  →  $SPOTIFY__DEVICE_NAME
snapserver.fifo_path →  $SNAPSERVER__FIFO_PATH
server_ip            →  $SERVER_IP
```

### Accessing config in scripts

```bash
cfg spotify device_name        # nested key → $SPOTIFY__DEVICE_NAME
cfg server_ip                  # top-level key → $SERVER_IP
cfg snapclient audio_device auto  # with fallback default
```

### Templates

Files in `templates/` use `{{VAR}}` syntax. `render_template src dst` substitutes from `os.environ` via Python regex. Adding a new config key requires: (1) add to `config.yml`, (2) reference as `{{SECTION__KEY}}` in template or `cfg section key` in scripts, (3) update config table in README.md.

## Script Architecture

`setup.sh` sources `scripts/common.sh` (all shared functions), calls `parse_config_files`, then sources `scripts/setup-server.sh` or `scripts/setup-client.sh`. **The setup scripts are sourced, not executed** — they inherit all exports and functions from the parent shell.

`scripts/bootstrap-clients.sh` runs from an admin laptop, tars and pushes the repo to each Pi via SSH, runs `./setup.sh init --role client` with per-client overrides, applies latency from `clients.yml`, then runs `sudo ./setup.sh client`. Host list comes from `--hosts CSV` or `--hosts-file`; per-client config overrides come from `clients.yml`.

## Snapcast Version

Centralized in `scripts/common.sh` as `SNAPCAST_VER_DEFAULT`. Both setup scripts call `require_snapcast_version()` — update one variable to upgrade both. `install_deb()` detects the version mismatch from the deb filename and reinstalls automatically.

## Key Edge Cases

| Issue | Solution |
|-------|---------|
| FIFO disappears on reboot | `/etc/tmpfiles.d/snapfifo.conf` recreates it at boot |
| Kernel blocks FIFO writes in `/tmp` | `fs.protected_fifos=0` in `/etc/sysctl.d/99-snapfifo.conf` |
| librespot/snapserver startup race | `Before=snapserver.service` in librespot unit; `mode=read` in pipe source blocks until write end opens |
| raspotify installs its own service | Masked after install; we manage librespot with our own unit |
| snapclient deb may pull in snapserver | snapserver masked on client machines |
| Snapcast deb URL includes OS codename | `detect_os_codename()` sets `$OS_CODENAME` from `/etc/os-release` |
| `spotify.normalise` is bool in YAML | `parse_config()` explicitly handles Python `bool` → `"true"`/`"false"` string before export; setup-server.sh converts to the actual librespot flag |

## Ports

| Port | Purpose |
|------|---------|
| 1704 | Snapcast audio stream (Pi 5 → clients, TCP) |
| 1780 | Snapcast HTTP control API |
| 4000 | librespot OAuth callback (configurable via `spotify.oauth_callback_port`) |
| 5353 | mDNS via avahi (Spotify device discovery) |
