#!/usr/bin/env bash
# librespot-auth-helper.sh — inspect librespot OAuth status and auth URL

set -euo pipefail

CALLBACK_PORT="${1:-${SPOTIFY_OAUTH_CALLBACK_PORT:-4000}}"
CACHE_DIR="${2:-${SPOTIFY_CACHE_DIR:-/var/cache/librespot}}"

latest_oauth_url() {
    journalctl -u librespot --no-pager -n 400 2>/dev/null \
        | grep -Eo 'https://accounts\.spotify\.com/[^ ]+' \
        | tail -n 1
}

url="$(latest_oauth_url || true)"

echo "Librespot OAuth helper"
echo "----------------------"

if [[ -n "$url" ]]; then
    echo "Latest OAuth URL:"
    echo "  $url"
else
    echo "Latest OAuth URL:"
    echo "  (none found yet in recent librespot logs)"
fi

echo ""
echo "Auth status check:"
if compgen -G "${CACHE_DIR%/}/*credentials*" > /dev/null || compgen -G "${CACHE_DIR%/}/*.json" > /dev/null; then
    echo "  cached credentials found"
else
    echo "  auth still pending"
fi

echo ""
echo "To follow logs live:"
echo "  sudo journalctl -u librespot -f"
echo ""
echo "Callback port: $CALLBACK_PORT"
