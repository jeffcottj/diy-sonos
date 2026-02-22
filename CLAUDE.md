# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

Turns small Linux devices into a synchronized multi-room audio system. A server device runs Spotify Connect (librespot) and streams audio via Snapcast; client devices play back in sync through USB DACs.

```
Spotify App → librespot (server) → /tmp/snapfifo (FIFO) → snapserver → snapclient(s) → ALSA → USB DAC
```

Tested hardware: Raspberry Pi 5 (server), Raspberry Pi Zero 2 W (clients).

## Validating Changes

There is no test suite. Use these to verify correctness:

```bash
# Syntax-check all shell scripts
bash -n setup.sh install.sh configure.sh deploy.sh first-run.sh
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

# Advisory preflight (no install writes, always exits 0)
./setup.sh preflight server --advisory
./setup.sh preflight client --advisory
```

## Laptop-Side Scripts

Three scripts run on the **admin laptop**, not the Pi:

| Script | Purpose |
|--------|---------|
| `first-run.sh` | One-command entry point: dep check → configure → copy-keys → connectivity check → deploy |
| `configure.sh` | Interactive wizard; writes `config.yml`; `--copy-keys` sets up SSH keys; `--diagnose-ssh` troubleshoots |
| `deploy.sh` | SSH pre-flight → rsync → `sudo ./setup.sh server` → OAuth instructions → `sudo ./setup.sh client` × N → summary |

`deploy.sh` parses `config.yml` via **inline Python regex** (no `pyyaml` needed on the laptop). It excludes `.diy-sonos.generated.yml` from rsync intentionally so on-device generated config is never clobbered.

## setup.sh — Command Modes

`setup.sh` is the sole on-device entry point and dispatches to sub-modes:

| Mode | Usage | What it does |
|------|-------|--------------|
| `init` | `./setup.sh init [--preset basic\|advanced] [--role server\|client] [--server-ip IP] [--device-name NAME] [--audio-device DEV] [--client-ips IP,...]` | Interactive wizard; writes `.diy-sonos.generated.yml` |
| `preflight` | `./setup.sh preflight server\|client [--advisory]` | Validates binaries, network, OS/arch, config values — no writes. `--advisory` always exits 0. |
| `server` | `sudo ./setup.sh server` | Full server install (runs preflight first) |
| `client` | `sudo ./setup.sh client` | Full client install (runs preflight first) |
| `upgrade` | `sudo ./setup.sh upgrade [--role server\|client]` | Idempotent reinstall; detects role from installed services if not specified |
| `doctor` | `sudo ./setup.sh doctor server\|client` | Runtime health checks: services, ports, FIFO, audio device, recent errors |
| `version` | `./setup.sh version` | Prints `.diy-sonos-version` metadata |

All install modes accept `--backup-snapshots` (auto-timestamped dir) or `--backup-dir DIR` to snapshot config/unit files before overwriting, with printed restore commands.

## Config System

### Three-layer precedence (highest wins)

1. **CLI flags** — `--server-ip`, `--device-name`, `--audio-device` (applied by `apply_cli_config_overrides()`)
2. **`.diy-sonos.generated.yml`** — written by `./setup.sh init`; not committed to git
3. **`config.yml`** — repo defaults; the file users hand-edit

`parse_config_files()` in `common.sh` merges layers in order. Both files are flattened with `__` separators and uppercased:

```
spotify.device_name  →  $SPOTIFY__DEVICE_NAME
snapserver.fifo_path →  $SNAPSERVER__FIFO_PATH
server_ip            →  $SERVER_IP
```

`spotify.normalise` is a YAML bool — `parse_config()` explicitly converts Python `True`/`False` to `"true"`/`"false"` strings before export; `setup-server.sh` then converts to the actual librespot flag (`--enable-volume-normalisation` or empty string).

### Accessing config in scripts

```bash
cfg spotify device_name        # nested key → $SPOTIFY__DEVICE_NAME
cfg server_ip                  # top-level key → $SERVER_IP
cfg snapclient audio_device auto  # with fallback default
```

### Laptop-only fields (not used by setup scripts or templates)

`ssh_user` and `clients[].ip` are parsed by `configure.sh`/`deploy.sh` directly via Python regex. When flattened by `parse_config()`, `clients` becomes a single stringified Python list (lists are not recursed into by the flatten function). This is harmless — neither field is referenced by `setup-server.sh`, `setup-client.sh`, or any template.

`profile_preset` (`basic` or `advanced`) is written to `config.yml` by `configure.sh` and is currently informational only — it describes the tuning profile chosen at wizard time.

### Templates

Files in `templates/` use `{{VAR}}` syntax. `render_template src dst` substitutes from `os.environ` via Python regex. Adding a new config key requires: (1) add to `config.yml`, (2) reference as `{{SECTION__KEY}}` in template or `cfg section key` in scripts, (3) update config table in README.md.

## Script Architecture

`setup.sh` sources `scripts/common.sh` (all shared functions), calls `parse_config_files`, then **sources** `scripts/setup-server.sh` or `scripts/setup-client.sh`. The setup scripts are sourced, not executed — they inherit all exports and functions from the parent shell.

`scripts/librespot-auth-helper.sh` is installed to `/usr/local/bin/librespot-auth-helper` during server setup. It has two sub-commands:
- `start-auth [port] [cache_dir]` — checks for cached credentials, extracts OAuth URL from the librespot journal, detects SSH session and prints a tunnel command if remote
- `verify-auth-cache [cache_dir]` — machine-parseable: outputs `AUTH_CACHE_STATUS=cached|pending` and exits 0/1

`scripts/bootstrap-clients.sh` is a power-user tool for per-client latency overrides; it reads `clients.yml` (different shape/purpose from `config.yml clients` list) and is not part of the standard `deploy.sh` flow.

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
| OAuth callback requires tunnel when remote | `librespot-auth-helper start-auth` detects `$SSH_CONNECTION` and prints a laptop-side tunnel command |

## Ports

| Port | Purpose |
|------|---------|
| 1704 | Snapcast audio stream (server → clients, TCP) |
| 1780 | Snapcast HTTP control API |
| 4000 | librespot OAuth callback (configurable via `spotify.oauth_callback_port`) |
| 5353 | mDNS via avahi (Spotify device discovery) |
