#!/usr/bin/env bash
# setup-client.sh — install and configure snapclient on a client device
# Sourced by setup.sh after common.sh is loaded and config is parsed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/scripts/cleanup-legacy.sh"

echo ""
echo "=========================================="
echo " DIY Sonos — Client Setup"
echo "=========================================="
echo ""

# ---------------------------------------------------------------------------
# 1. OS / arch detection
# ---------------------------------------------------------------------------
detect_os_codename
detect_arch

# ---------------------------------------------------------------------------
# 2. Base dependencies
# ---------------------------------------------------------------------------
echo ""
echo "--- Installing base dependencies ---"
apt_update_if_stale
pkg_install wget curl ca-certificates alsa-utils

# Cleanup/mask legacy units and binaries before installing fresh units.
cleanup_legacy_for_role client

# ---------------------------------------------------------------------------
# 3. Install snapclient
# ---------------------------------------------------------------------------
echo ""
echo "--- Installing snapclient ---"

SNAPCAST_VER="$(require_snapcast_version)"
SNAP_DEB_URL="https://github.com/badaix/snapcast/releases/download/v${SNAPCAST_VER}/snapclient_${SNAPCAST_VER}-1_${ARCH_DEB}_${OS_CODENAME}.deb"
install_deb "$SNAP_DEB_URL"

# The snapclient deb may pull in snapserver as a dependency — mask it so it
# doesn't start on client machines.
systemctl mask snapserver.service 2>/dev/null || true
systemctl stop snapserver.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Resolve audio output device
# ---------------------------------------------------------------------------
echo ""
echo "--- Resolving audio device ---"

resolve_audio_device "$(cfg snapclient audio_device)"
echo "Audio device: $RESOLVED_AUDIO_DEVICE"

# ---------------------------------------------------------------------------
# 5. Render systemd service unit
# ---------------------------------------------------------------------------
echo ""
echo "--- Rendering systemd service unit ---"

_config_changed=0

snapshot_file /etc/systemd/system/snapclient.service
render_template_if_changed \
    "$SCRIPT_DIR/templates/snapclient.service.tmpl" \
    "/etc/systemd/system/snapclient.service" && _config_changed=1 || true

# ---------------------------------------------------------------------------
# 6. Enable and start service
# ---------------------------------------------------------------------------
echo ""
echo "--- Enabling snapclient ---"

if [[ $_config_changed -eq 1 ]]; then
    systemd_enable_restart snapclient
else
    echo "Config unchanged — skipping service restart"
    systemctl enable snapclient 2>/dev/null || true
    systemctl is-active --quiet snapclient || systemctl start snapclient
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " Client setup complete!"
echo "=========================================="
echo ""
echo "  Play music in Spotify → all speakers should sync automatically."
echo ""
echo "  Service status:"
echo "     sudo systemctl status snapclient"
echo "     sudo journalctl -u snapclient -f"
echo ""
echo "  Audio device in use: $RESOLVED_AUDIO_DEVICE"
echo "  Server:              $(cfg server_ip) (override in config.yml if wrong)"
echo ""
echo "  To test audio output directly:"
echo "     speaker-test -t wav -c 2 -D $RESOLVED_AUDIO_DEVICE"
echo ""
