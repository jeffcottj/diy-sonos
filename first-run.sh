#!/usr/bin/env bash
# first-run.sh — guided first-time setup wrapper for DIY Sonos
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"

_fmt() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
green()  { _fmt "32" "$*"; }
red()    { _fmt "31" "$*"; }
yellow() { _fmt "33" "$*"; }
bold()   { _fmt "1" "$*"; }

require_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "  %-14s %s\n" "$cmd" "$(green ok)"
    else
        printf "  %-14s %s\n" "$cmd" "$(red MISSING)"
        return 1
    fi
}

parse_config_hosts() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "config.yml not found. Run ./configure.sh first." >&2
        exit 1
    fi

    local parsed
    parsed="$(python3 - "$CONFIG_FILE" <<'PYEOF'
import re
import sys

server_ip = ""
default_ssh_user = "pi"
server_ssh_user = ""
client_entries = []
in_clients = False

for line in open(sys.argv[1], encoding="utf-8"):
    stripped = line.split("#", 1)[0].rstrip()

    if re.match(r"^[a-z]", stripped):
        in_clients = stripped.startswith("clients:")

    m = re.match(r'^server_ip:\s*"?([^"#\s]+)"?', stripped)
    if m:
        server_ip = m.group(1)

    m = re.match(r'^\s*ip:\s*"?([^"#\s]+)"?', stripped)
    if m and not in_clients and stripped.startswith('ip:'):
        server_ip = m.group(1)

    m = re.match(r'^ssh_user:\s*"?([^"#\s]+)"?', stripped)
    if m:
        default_ssh_user = m.group(1)

    if stripped.startswith('server:'):
        in_clients = False

    if stripped.startswith('  ssh_user:') and not in_clients:
        m = re.match(r'^\s*ssh_user:\s*"?([^"#\s]+)"?', stripped)
        if m:
            server_ssh_user = m.group(1)

    if in_clients:
        m = re.match(r'^\s+-\s+ip:\s*"?([0-9.]+)"?', stripped)
        if m:
            client_entries.append([m.group(1), default_ssh_user])
            continue
        m = re.match(r'^\s+ssh_user:\s*"?([^"#\s]+)"?', stripped)
        if m and client_entries:
            client_entries[-1][1] = m.group(1)

print(f"DEFAULT_SSH_USER={default_ssh_user}")
print(f"SERVER_SSH_USER={server_ssh_user or default_ssh_user}")
print(f"SERVER_IP={server_ip}")
for ip, user in client_entries:
    print(f"CLIENT={ip}|{user}")
PYEOF
)"

    SSH_USER="pi"
    SERVER_SSH_USER="pi"
    SERVER_IP=""
    CLIENT_IPS=()
    declare -gA CLIENT_SSH_USERS=()

    while IFS='=' read -r key val; do
        case "$key" in
            DEFAULT_SSH_USER) SSH_USER="$val" ;;
            SERVER_SSH_USER) SERVER_SSH_USER="$val" ;;
            SERVER_IP) SERVER_IP="$val" ;;
            CLIENT)
                local ip="${val%%|*}"
                local user="${val#*|}"
                CLIENT_IPS+=("$ip")
                CLIENT_SSH_USERS["$ip"]="$user"
                ;;
        esac
    done <<< "$parsed"

    if [[ -z "$SERVER_IP" || ${#CLIENT_IPS[@]} -eq 0 ]]; then
        echo "config.yml is missing server/client IPs. Re-run ./configure.sh." >&2
        exit 1
    fi
}

run_connectivity_check() {
    parse_config_hosts

    echo "$(bold '4) Connectivity check')"
    echo "  Testing SSH connectivity for configured hosts..."

    local failed=0
    local host ssh_user
    for host in "$SERVER_IP" "${CLIENT_IPS[@]}"; do
        if [[ "$host" == "$SERVER_IP" ]]; then
            ssh_user="$SERVER_SSH_USER"
        else
            ssh_user="${CLIENT_SSH_USERS[$host]:-$SSH_USER}"
        fi
        printf "  %-16s" "$host"
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "${ssh_user}@${host}" true 2>/dev/null; then
            echo "$(green ok)"
        else
            echo "$(yellow warning) (user: ${ssh_user})"
            failed=1
        fi
    done

    if [[ $failed -eq 1 ]]; then
        echo ""
        echo "$(yellow 'Some hosts were unreachable via key-based SSH.')"
        echo "Run ./configure.sh --copy-keys again or verify device networking, then retry."
        exit 1
    fi
    echo ""
}

parse_spotify_auth_settings() {
    local parsed
    parsed="$(python3 - "$CONFIG_FILE" <<'PYEOF'
import re
import sys

callback_port = "4000"
cache_dir = "/var/cache/librespot"

for line in open(sys.argv[1], encoding="utf-8"):
    stripped = line.split("#", 1)[0].strip()

    m = re.match(r'^oauth_callback_port:\s*"?([^"#\s]+)"?', stripped)
    if m:
        callback_port = m.group(1)

    m = re.match(r'^cache_dir:\s*"?([^"#\s]+)"?', stripped)
    if m:
        cache_dir = m.group(1)

print(f"OAUTH_CALLBACK_PORT={callback_port}")
print(f"SPOTIFY_CACHE_DIR={cache_dir}")
PYEOF
)"

    OAUTH_CALLBACK_PORT="4000"
    SPOTIFY_CACHE_DIR="/var/cache/librespot"

    while IFS='=' read -r key val; do
        case "$key" in
            OAUTH_CALLBACK_PORT) OAUTH_CALLBACK_PORT="$val" ;;
            SPOTIFY_CACHE_DIR) SPOTIFY_CACHE_DIR="$val" ;;
        esac
    done <<< "$parsed"
}

echo ""
echo "$(bold 'DIY Sonos — Quick Start Wizard')"
echo ""

echo "$(bold '1) Local dependency check')"
missing=0
for cmd in ssh ssh-copy-id python3 rsync; do
    require_cmd "$cmd" || missing=1
done
if [[ $missing -eq 1 ]]; then
    echo ""
    echo "$(red 'Missing required dependencies. Install the missing command(s) and re-run ./first-run.sh.')"
    exit 1
fi
echo ""

echo "$(bold '2) Interactive configuration')"
bash "$SCRIPT_DIR/configure.sh"
echo ""

echo "$(bold '3) SSH key setup')"
bash "$SCRIPT_DIR/configure.sh" --copy-keys
echo ""

run_connectivity_check

echo "$(bold '5) Deploying DIY Sonos')"
bash "$SCRIPT_DIR/deploy.sh"
echo ""

parse_spotify_auth_settings

echo "$(bold '6) Spotify authentication check')"
echo "  Verifying server auth cache status..."

_auth_ok=0
if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SERVER_SSH_USER}@${SERVER_IP}" \
    "sudo librespot-auth-helper verify-auth-cache ${SPOTIFY_CACHE_DIR}" >/dev/null 2>&1; then
    _auth_ok=1
fi

_librespot_active=0
if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${SERVER_SSH_USER}@${SERVER_IP}" \
    "systemctl is-active --quiet librespot" 2>/dev/null; then
    _librespot_active=1
fi

if [[ $_auth_ok -eq 1 && $_librespot_active -eq 1 ]]; then
    echo "  $(green 'Spotify auth cache detected.')"
    echo "  Open Spotify and select your configured speaker device to start playback."
    echo ""
    echo "$(green 'Done: deployment complete and Spotify-ready.')"
elif [[ $_auth_ok -eq 1 && $_librespot_active -eq 0 ]]; then
    echo "  $(yellow 'Auth cache OK but librespot is not running on the server.')"
    echo "  Re-run deployment to recover: ./deploy.sh"
    echo ""
    echo "$(yellow 'Done: deployment complete (librespot needs restart).')"
else
    echo "  $(yellow 'Spotify auth cache is still pending.')"
    echo "  Deployment is complete, but Spotify playback is blocked until auth finishes."
    echo ""
    echo "  Run these commands on the server:"
    echo "    sudo librespot-auth-helper start-auth ${OAUTH_CALLBACK_PORT} ${SPOTIFY_CACHE_DIR}"
    echo "    sudo librespot-auth-helper verify-auth-cache ${SPOTIFY_CACHE_DIR}"
    echo ""
    echo "$(yellow 'Done: deployment complete (not Spotify-ready yet).')"
fi
