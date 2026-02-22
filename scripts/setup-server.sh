#!/usr/bin/env bash
# setup-server.sh — install and configure snapserver + librespot on Pi 5
# Sourced by setup.sh after common.sh is loaded and config is parsed.

set -euo pipefail

SNAPCAST_VER="0.31.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo ""
echo "=========================================="
echo " DIY Sonos — Server Setup"
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
apt-get update -qq
pkg_install wget curl ca-certificates alsa-utils avahi-daemon

# ---------------------------------------------------------------------------
# 3. Install librespot via raspotify apt repo
# ---------------------------------------------------------------------------
echo ""
echo "--- Installing librespot (via raspotify repo) ---"

RASPOTIFY_GPG="/usr/share/keyrings/raspotify_pub.gpg"
RASPOTIFY_LIST="/etc/apt/sources.list.d/raspotify.list"

if [[ ! -f "$RASPOTIFY_GPG" ]]; then
    curl -sL "https://dtcooper.github.io/raspotify/key.asc" \
        | gpg --dearmor -o "$RASPOTIFY_GPG"
    echo "Added raspotify GPG key"
fi

if [[ ! -f "$RASPOTIFY_LIST" ]]; then
    echo "deb [signed-by=$RASPOTIFY_GPG] https://dtcooper.github.io/raspotify raspotify main" \
        > "$RASPOTIFY_LIST"
    apt-get update -qq
    echo "Added raspotify apt source"
fi

pkg_install raspotify

# Mask raspotify's own service — we manage librespot with our own unit
systemctl mask raspotify.service 2>/dev/null || true
systemctl stop raspotify.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Install snapserver
# ---------------------------------------------------------------------------
echo ""
echo "--- Installing snapserver ---"

SNAP_DEB_URL="https://github.com/badaix/snapcast/releases/download/v${SNAPCAST_VER}/snapserver_${SNAPCAST_VER}-1_${ARCH_DEB}_${OS_CODENAME}.deb"
install_deb "$SNAP_DEB_URL"

# Stop the default snapserver service (we'll reconfigure and restart later)
systemctl stop snapserver.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Create FIFO + ensure it survives reboots
# ---------------------------------------------------------------------------
echo ""
echo "--- Creating audio FIFO ---"

FIFO_PATH="$(cfg snapserver fifo_path)"
ensure_fifo "$FIFO_PATH"

# systemd-tmpfiles.d entry so the FIFO is recreated after reboot
cat > /etc/tmpfiles.d/snapfifo.conf <<EOF
p ${FIFO_PATH} 0660 root audio - -
EOF
echo "Wrote /etc/tmpfiles.d/snapfifo.conf"

# ---------------------------------------------------------------------------
# 6. sysctl: allow FIFO writes from non-owner in /tmp
# ---------------------------------------------------------------------------
echo ""
echo "--- Configuring sysctl for FIFO access ---"

cat > /etc/sysctl.d/99-snapfifo.conf <<EOF
# Allow librespot to write to the FIFO in /tmp without being blocked
# by the kernel's protected_fifos mechanism.
fs.protected_fifos = 0
EOF
sysctl -p /etc/sysctl.d/99-snapfifo.conf
echo "Applied fs.protected_fifos=0"

# ---------------------------------------------------------------------------
# 7. Render snapserver config
# ---------------------------------------------------------------------------
echo ""
echo "--- Rendering snapserver config ---"

render_template \
    "$SCRIPT_DIR/templates/snapserver.conf.tmpl" \
    "/etc/snapserver.conf"

# ---------------------------------------------------------------------------
# 8. Render systemd service units
# ---------------------------------------------------------------------------
echo ""
echo "--- Rendering systemd service units ---"

NORMALISE="$(cfg spotify normalise true)"
if [[ "${NORMALISE,,}" == "true" ]]; then
    export SPOTIFY__NORMALISE_FLAG="--enable-volume-normalisation"
else
    export SPOTIFY__NORMALISE_FLAG=""
fi

render_template \
    "$SCRIPT_DIR/templates/librespot.service.tmpl" \
    "/etc/systemd/system/librespot.service"

render_template \
    "$SCRIPT_DIR/templates/snapserver.service.tmpl" \
    "/etc/systemd/system/snapserver.service"

# ---------------------------------------------------------------------------
# 9. Create librespot cache directory
# ---------------------------------------------------------------------------
CACHE_DIR="$(cfg spotify cache_dir)"
ensure_dir "$CACHE_DIR"
echo "Cache directory ready: $CACHE_DIR"

# ---------------------------------------------------------------------------
# 10. Enable and start services
# ---------------------------------------------------------------------------
echo ""
echo "--- Enabling services ---"

systemd_enable_restart librespot
systemd_enable_restart snapserver

# ---------------------------------------------------------------------------
# Done — print OAuth instructions
# ---------------------------------------------------------------------------
echo ""
echo "=========================================="
echo " Server setup complete!"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "  1. Authenticate with Spotify (first run only):"
echo "     sudo journalctl -u librespot -f"
echo "     Look for a URL starting with https://accounts.spotify.com/"
echo "     Open it in a browser (or use SSH port-forwarding if headless)."
echo ""
echo "  2. Open Spotify on any device and look for:"
echo "     '$(cfg spotify device_name)' in the device list."
echo ""
echo "  3. Run setup on each Pi Zero client:"
echo "     sudo ./setup.sh client"
echo ""
echo "  Service status:"
echo "     sudo systemctl status librespot snapserver"
echo "     sudo journalctl -u librespot -f"
echo ""
