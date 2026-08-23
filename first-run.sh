#!/usr/bin/env bash
# first-run.sh — guided first-time setup wrapper for DIY Sonos
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"

# shellcheck disable=SC2034
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
# shellcheck disable=SC2034
KNOWN_HOSTS_FILE="$HOME/.ssh/known_hosts"

source "$SCRIPT_DIR/scripts/lib/ssh.sh"

require_cmd() {
    local cmd="$1"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf "  %-14s %s\n" "$cmd" "$(green ok)"
    else
        printf "  %-14s %s\n" "$cmd" "$(red MISSING)"
        return 1
    fi
}

parse_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "config.yml not found. Run ./configure.sh first." >&2
        exit 1
    fi

    local parsed
    parsed="$(python3 "$SCRIPT_DIR/scripts/parse-network-config.py" "$CONFIG_FILE")"

    SSH_USER="pi"
    SERVER_SSH_USER="pi"
    SERVER_IP=""
    OAUTH_CALLBACK_PORT="4000"
    SPOTIFY_CACHE_DIR="/var/cache/librespot"
    CLIENT_IPS=()
    declare -gA CLIENT_SSH_USERS=()

    while IFS='=' read -r key val; do
        case "$key" in
            DEFAULT_SSH_USER) SSH_USER="$val" ;;
            SERVER_SSH_USER) SERVER_SSH_USER="$val" ;;
            SERVER_IP) SERVER_IP="$val" ;;
            SPOTIFY_DEVICE_NAME) : ;; # not needed in first-run but parsed
            OAUTH_CALLBACK_PORT) OAUTH_CALLBACK_PORT="$val" ;;
            SPOTIFY_CACHE_DIR) SPOTIFY_CACHE_DIR="$val" ;;
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

# Backward-compat wrappers (original names)
parse_config_hosts() { parse_config; }
parse_spotify_auth_settings() { parse_config; }

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
        if ! ensure_host_key_trusted "$host"; then
            echo "$(yellow warning) (host key not trusted)"
            failed=1
            continue
        fi
        if ssh -o BatchMode=yes -o ConnectTimeout=10 "${ssh_user}@${host}" true 2>/dev/null; then
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
if ensure_host_key_trusted "$SERVER_IP" && ssh -o BatchMode=yes -o ConnectTimeout=10 "${SERVER_SSH_USER}@${SERVER_IP}" \
    "sudo librespot-auth-helper verify-auth-cache ${SPOTIFY_CACHE_DIR}" >/dev/null 2>&1; then
    _auth_ok=1
fi

_librespot_active=0
if ensure_host_key_trusted "$SERVER_IP" && ssh -o BatchMode=yes -o ConnectTimeout=10 "${SERVER_SSH_USER}@${SERVER_IP}" \
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
