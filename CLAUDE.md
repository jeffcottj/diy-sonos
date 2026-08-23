# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Does

Turns small Linux devices into a synchronized multi-room audio system. A server device runs Spotify Connect (librespot) and streams audio via Snapcast; client devices play back in sync through USB DACs.

```
Spotify App → librespot (server) → /run/diy-sonos/snapfifo (FIFO) → snapserver → snapclient(s) → ALSA → USB DAC
```

Tested hardware: Raspberry Pi 5 (server), Raspberry Pi Zero 2 W (clients).

## Validating Changes

Use these to verify correctness:

```bash
# Syntax-check all shell scripts
bash -n setup.sh install.sh configure.sh deploy.sh first-run.sh
bash -n scripts/common.sh scripts/setup-server.sh scripts/setup-client.sh
bash -n scripts/bootstrap-clients.sh scripts/librespot-auth-helper.sh
bash -n scripts/lib/ssh.sh tests/run-tests.sh

# Lint (error severity, CI gate)
shellcheck --severity=error --exclude=SC1091 setup.sh install.sh configure.sh deploy.sh first-run.sh scripts/*.sh scripts/lib/ssh.sh tests/run-tests.sh

# Verify config parsing produces expected env vars (device-side, via common.sh)
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

# Laptop parser smoke test
python3 scripts/parse-network-config.py config.yml

# Unit tests (no hardware needed)
bash tests/run-tests.sh

# CI workflow (GitHub Actions, ubuntu-latest)
# .github/workflows/ci.yml runs: bash -n, shellcheck, pyyaml load, tests/run-tests.sh

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

Laptop config parsing is via **`scripts/parse-network-config.py`** (stdlib only, no `pyyaml` needed). It handles `ssh_user`, `server_ip` (including legacy `server:` block), `clients:` entries, `spotify.device_name`, `oauth_callback_port`, `cache_dir`, and emits `KEY=VALUE` lines consumed by bash loops. `deploy.sh`/`first-run.sh`/`configure.sh` all source this parser; they exclude `.diy-sonos.generated.yml` from rsync intentionally so on-device generated config is never clobbered.

SSH helpers (`_fmt`, `green`, `red`, `yellow`, `bold`, `cyan`, `ensure_local_ssh_key`, `classify_ssh_error`, `print_ssh_fix_hint`, `ensure_host_key_trusted`, `validate_ipv4`) live in **`scripts/lib/ssh.sh`** — caller must set `SSH_KEY_PATH` and `KNOWN_HOSTS_FILE` before sourcing. `first-run.sh` no longer uses `StrictHostKeyChecking=no`; it trusts keys via `ensure_host_key_trusted` then uses `BatchMode=yes`.

`scripts/bootstrap-clients.sh` is intentionally **not** migrated to the shared SSH lib (different SSH option set, BatchMode-only); do not touch its SSH handling.

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
| `version` | `./setup.sh version` | Prints `.diy-sonos-version` or `git describe --tags --always` |

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

`parse_config()` in `common.sh` now uses **NUL-delimited `export "$var_name=$var_value"`** (no `eval`); Python emits `name\0value\0` via `sys.stdout.buffer.write`. It validates names against `^[A-Z0-9_]+$` and converts YAML `bool` → `"true"`/`"false"` and `None` → `""`.

`spotify.normalise` is a YAML bool — `parse_config()` explicitly converts Python `True`/`False` to `"true"`/`"false"` strings before export; `setup-server.sh` then converts to the actual librespot flag (`--enable-volume-normalisation` or empty string).

### Accessing config in scripts

```bash
cfg spotify device_name        # nested key → $SPOTIFY__DEVICE_NAME
cfg server_ip                  # top-level key → $SERVER_IP
cfg snapclient audio_device auto  # with fallback default
```

### Laptop-only fields (not used by setup scripts or templates)

`ssh_user` and `clients[].ip` are parsed by `scripts/parse-network-config.py` (shared by `configure.sh`/`deploy.sh`/`first-run.sh`). When flattened by `parse_config()`, `clients` becomes a single stringified Python list (lists are not recursed into by the flatten function). This is harmless — neither field is referenced by `setup-server.sh`, `setup-client.sh`, or any template.

`profile_preset` (`basic` or `advanced`) is written to `config.yml` by `configure.sh` and selects the tuning profile:

| Key | basic | advanced |
|-----|-------|----------|
| `spotify.bitrate` | 320 | 320 |
| `spotify.normalise` | true | true |
| `spotify.initial_volume` | 90 | 90 |
| `snapserver.codec` | flac | pcm |
| `snapserver.buffer_ms` | 1000 | 800 |
| `snapclient.latency_ms` | 0 | -20 |
| `snapclient.output_volume` | 90 | 90 |

`setup.sh init` preset values already match `basic`.

### Templates

Files in `templates/` use `{{VAR}}` syntax. `render_template_if_changed src dst` substitutes from `os.environ` via Python regex, writes atomically next to the target (`$(dirname "$out")/.render.XXXXXX`), and skips the write (returns 1) if content is identical. Adding a new config key requires: (1) add to `config.yml`, (2) reference as `{{SECTION__KEY}}` in template or `cfg section key` in scripts, (3) update config table in README.md.

`render_template` (unconditional) was removed; use `render_template_if_changed` only.

## Script Architecture

`setup.sh` sources `scripts/common.sh` (all shared functions), calls `parse_config_files`, then **sources** `scripts/setup-server.sh` or `scripts/setup-client.sh`. The setup scripts are sourced, not executed — they inherit all exports and functions from the parent shell.

`scripts/common.sh` provides `parse_config` (NUL-delimited, no eval), `install_deb` (mktemp + stamp at `/var/lib/diy-sonos/installed-debs/<pkg>` for arch/codename-safe skip), `fifo_requires_protected_sysctl`, `render_template_if_changed`, and validation helpers (`validate_server_ip`, `validate_spotify_bitrate`, `validate_snapserver_codec`, `validate_snapclient_audio_device`, `validate_snapclient_output_volume`).

`scripts/lib/ssh.sh` provides colour and SSH helpers for laptop scripts; `scripts/parse-network-config.py` is the single laptop parser.

`scripts/librespot-auth-helper.sh` is installed to `/usr/local/bin/librespot-auth-helper` during server setup. It has two sub-commands:
- `start-auth [port] [cache_dir]` — checks for cached credentials, extracts OAuth URL from the librespot journal, detects SSH session and prints a tunnel command if remote
- `verify-auth-cache [cache_dir]` — machine-parseable: outputs `AUTH_CACHE_STATUS=cached|pending` and exits 0/1

`scripts/bootstrap-clients.sh` is a power-user tool for per-client latency overrides; it reads `clients.example.yml` (copy to `clients.yml` first: `cp clients.example.yml clients.yml` and edit) — different shape/purpose from `config.yml clients` list — and is not part of the standard `deploy.sh` flow.

## Snapcast Version

Centralized in `scripts/common.sh` as `SNAPCAST_VER_DEFAULT`. Both setup scripts call `require_snapcast_version()` — update one variable to upgrade both. `install_deb()` detects the version mismatch from the deb filename and uses the stamp file to decide skip vs reinstall; after successful install it writes the filename to `/var/lib/diy-sonos/installed-debs/<pkg>`.

## Key Edge Cases

| Issue | Solution |
|-------|---------|
| FIFO disappears on reboot | `/etc/tmpfiles.d/snapfifo.conf` recreates it at boot (`d /run/diy-sonos 0755` + `p /run/diy-sonos/snapfifo 0660`); `systemd-tmpfiles --create` runs immediately and `ensure_fifo` covers non-tmpfiles systems. Migration removes old `/tmp` FIFO if path changed. |
| Kernel blocks FIFO writes in `/tmp` | Default `/run/diy-sonos/snapfifo` needs no sysctl. Only a user-overridden `fifo_path` under `/tmp` or `/var/tmp` triggers `fs.protected_fifos=0` via `/etc/sysctl.d/99-snapfifo.conf` (checked by `fifo_requires_protected_sysctl`); otherwise the file is removed and `fs.protected_fifos=1` is restored. |
| librespot/snapserver startup race | `After=librespot.service` + `Wants=librespot.service` (not `Requires`) in `snapserver.service`; `mode=read` in pipe source blocks until write end opens; `Wants` avoids cascade stop and allows `stop librespot` without stopping snapserver. |
| raspotify installs its own service | Masked after install; we manage librespot with our own unit; GPG key is pinned to `2CC9B80F5AE2B7ACEFF2BA3209146F2F7953A455` and `gnupg` is an explicit dep. |
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
