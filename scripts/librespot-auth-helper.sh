#!/usr/bin/env bash
# librespot-auth-helper.sh — Spotify OAuth guidance and auth cache verification for librespot

set -euo pipefail

COMMAND="${1:-start-auth}"
CALLBACK_PORT_DEFAULT="${SPOTIFY_OAUTH_CALLBACK_PORT:-4000}"
CACHE_DIR_DEFAULT="${SPOTIFY_CACHE_DIR:-/var/cache/librespot}"

usage() {
    cat <<USAGE
Usage:
  librespot-auth-helper start-auth [callback_port] [cache_dir]
  librespot-auth-helper verify-auth-cache [cache_dir]

Commands:
  start-auth         Print clear OAuth next steps with SUCCESS/FAILURE messaging.
  verify-auth-cache  Machine-parseable cache status for scripts/automation.
USAGE
}

latest_oauth_url() {
    journalctl -u librespot --no-pager -n 400 2>/dev/null \
        | grep -Eo 'https://accounts\.spotify\.com/[^ ]+' \
        | tail -n 1
}

has_cached_credentials() {
    local cache_dir="$1"
    compgen -G "${cache_dir%/}/*credentials*" > /dev/null \
        || compgen -G "${cache_dir%/}/*.json" > /dev/null
}

detect_host_ip() {
    hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./) {print $i; exit}}'
}

verify_auth_cache() {
    local cache_dir="$1"

    if has_cached_credentials "$cache_dir"; then
        echo "AUTH_CACHE_STATUS=cached"
        echo "AUTH_CACHE_DIR=$cache_dir"
        return 0
    fi

    echo "AUTH_CACHE_STATUS=pending"
    echo "AUTH_CACHE_DIR=$cache_dir"
    return 1
}

start_auth() {
    local callback_port="$1"
    local cache_dir="$2"
    local oauth_url host_ip ssh_user

    echo "Librespot OAuth helper"
    echo "----------------------"
    echo "Callback port: $callback_port"
    echo "Cache dir: $cache_dir"
    echo ""

    if has_cached_credentials "$cache_dir"; then
        echo "SUCCESS: Spotify credentials already cached."
        echo "Next action: open Spotify and play to this device."
        return 0
    fi

    oauth_url="$(latest_oauth_url || true)"
    host_ip="$(detect_host_ip || true)"
    ssh_user="${SUDO_USER:-${USER:-$(id -un 2>/dev/null || echo pi)}}"

    if [[ -z "$oauth_url" ]]; then
        echo "FAILURE: OAuth URL not found in recent librespot logs."
        echo "Try again in a few seconds:"
        echo "  sudo librespot-auth-helper start-auth ${callback_port} ${cache_dir}"
        echo ""
        echo "Debug command:"
        echo "  sudo journalctl -u librespot -f"
        return 2
    fi

    echo "OAuth URL:"
    echo "  $oauth_url"
    echo ""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        local laptop_cmd
        if [[ -n "$host_ip" ]]; then
            laptop_cmd="ssh -L ${callback_port}:localhost:${callback_port} ${ssh_user}@${host_ip}"
        else
            laptop_cmd="ssh -L ${callback_port}:localhost:${callback_port} ${ssh_user}@<server-ip>"
        fi

        echo "Detected SSH session: browser likely runs on your laptop."
        echo "Copy/paste on your laptop:"
        echo "  $laptop_cmd"
        echo "Then open on your laptop:"
        echo "  $oauth_url"
        echo ""
        echo "On-device browser alternative (if this server has a GUI):"
        echo "  xdg-open '$oauth_url'"
    else
        echo "On-device browser flow (no SSH tunnel required):"
        echo "  xdg-open '$oauth_url'"
        if [[ -n "$host_ip" ]]; then
            echo ""
            echo "Laptop tunnel alternative:"
            echo "  ssh -L ${callback_port}:localhost:${callback_port} ${ssh_user}@${host_ip}"
            echo "  # Then open: $oauth_url"
        fi
    fi

    echo ""
    echo "FAILURE: Spotify auth cache is still pending until OAuth is completed."
    echo "Verify status after login:"
    echo "  sudo librespot-auth-helper verify-auth-cache ${cache_dir}"
    return 1
}

case "$COMMAND" in
    start-auth)
        callback_port="${2:-$CALLBACK_PORT_DEFAULT}"
        cache_dir="${3:-$CACHE_DIR_DEFAULT}"
        start_auth "$callback_port" "$cache_dir"
        ;;
    verify-auth-cache)
        cache_dir="${2:-$CACHE_DIR_DEFAULT}"
        verify_auth_cache "$cache_dir"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        usage >&2
        exit 64
        ;;
esac
