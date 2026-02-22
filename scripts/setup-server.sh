#!/usr/bin/env bash
# setup-server.sh — install and configure snapserver + librespot on server device
# Sourced by setup.sh after common.sh is loaded and config is parsed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/scripts/cleanup-legacy.sh"

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
apt_update_if_stale
pkg_install wget curl ca-certificates alsa-utils avahi-daemon

echo ""
echo "--- Ensuring avahi-daemon is enabled and running ---"
systemctl enable avahi-daemon.service
if systemctl is-active --quiet avahi-daemon.service; then
    systemctl restart avahi-daemon.service
    echo "Restarted: avahi-daemon.service"
else
    systemctl start avahi-daemon.service
    echo "Started: avahi-daemon.service"
fi

if systemctl is-active --quiet avahi-daemon.service; then
    echo "avahi-daemon.service is active"
else
    echo "Error: avahi-daemon.service is not active after setup." >&2
    echo "Remediation: run 'sudo systemctl status avahi-daemon --no-pager' and 'sudo journalctl -u avahi-daemon -n 50 --no-pager' to inspect the failure, then fix the host mDNS/Avahi issue and rerun 'sudo ./setup.sh server'." >&2
    exit 1
fi

# Cleanup/mask legacy units and binaries before installing fresh units.
cleanup_legacy_for_role server

# ---------------------------------------------------------------------------
# 3. Install librespot via raspotify apt repo
# ---------------------------------------------------------------------------
echo ""
echo "--- Installing librespot (via raspotify repo) ---"

RASPOTIFY_GPG="/usr/share/keyrings/raspotify_pub.gpg"
RASPOTIFY_LIST="/etc/apt/sources.list.d/raspotify.list"

if [[ ! -f "$RASPOTIFY_GPG" ]]; then
    local tmp_key
    tmp_key="$(mktemp)"
    if ! curl -fsSL --connect-timeout 30 "https://dtcooper.github.io/raspotify/key.asc" \
            -o "$tmp_key"; then
        rm -f "$tmp_key"
        echo "Error: failed to download raspotify GPG key" >&2
        exit 1
    fi
    gpg --dearmor -o "$RASPOTIFY_GPG" < "$tmp_key"
    rm -f "$tmp_key"
    echo "Added raspotify GPG key"
fi

if [[ ! -f "$RASPOTIFY_LIST" ]]; then
    echo "deb [signed-by=$RASPOTIFY_GPG] https://dtcooper.github.io/raspotify raspotify main" \
        > "$RASPOTIFY_LIST"
    echo "Added raspotify apt source"
fi

apt-get update -qq

RASPOTIFY_TARGET_VERSION="$(apt-cache policy raspotify | awk '/Candidate:/ {print $2}')"
if [[ -z "$RASPOTIFY_TARGET_VERSION" || "$RASPOTIFY_TARGET_VERSION" == "(none)" ]]; then
    echo "Error: unable to determine raspotify candidate version" >&2
    exit 1
fi

RASPOTIFY_INSTALLED_VERSION="$(dpkg-query -W -f='${Version}' raspotify 2>/dev/null || true)"
if [[ -z "$RASPOTIFY_INSTALLED_VERSION" ]]; then
    RASPOTIFY_INSTALLED_VERSION="(not installed)"
fi

echo "raspotify installed version: $RASPOTIFY_INSTALLED_VERSION"
echo "raspotify target version:    $RASPOTIFY_TARGET_VERSION"

if [[ "$RASPOTIFY_INSTALLED_VERSION" == "(not installed)" ]]; then
    echo "Installing raspotify $RASPOTIFY_TARGET_VERSION"
    apt-get install -y raspotify
elif [[ "$RASPOTIFY_INSTALLED_VERSION" != "$RASPOTIFY_TARGET_VERSION" ]]; then
    echo "Upgrading raspotify to $RASPOTIFY_TARGET_VERSION"
    apt-get install -y --only-upgrade raspotify
else
    echo "raspotify already at target version"
fi

# Keep raspotify masked — we manage librespot with our own unit
systemctl mask raspotify.service 2>/dev/null || true
systemctl stop raspotify.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# 4. Install snapserver
# ---------------------------------------------------------------------------
echo ""
echo "--- Installing snapserver ---"

SNAPCAST_VER="$(require_snapcast_version)"
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
snapshot_file /etc/tmpfiles.d/snapfifo.conf
cat > /etc/tmpfiles.d/snapfifo.conf <<EOF
p ${FIFO_PATH} 0660 root audio - -
EOF
echo "Wrote /etc/tmpfiles.d/snapfifo.conf"

# ---------------------------------------------------------------------------
# 6. sysctl: allow FIFO writes from non-owner in /tmp
# ---------------------------------------------------------------------------
echo ""
echo "--- Configuring sysctl for FIFO access ---"

snapshot_file /etc/sysctl.d/99-snapfifo.conf
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

_config_changed=0

snapshot_file /etc/snapserver.conf
render_template_if_changed \
    "$SCRIPT_DIR/templates/snapserver.conf.tmpl" \
    "/etc/snapserver.conf" && _config_changed=1 || true

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

snapshot_file /etc/systemd/system/librespot.service
render_template_if_changed \
    "$SCRIPT_DIR/templates/librespot.service.tmpl" \
    "/etc/systemd/system/librespot.service" && _config_changed=1 || true

snapshot_file /etc/systemd/system/snapserver.service
render_template_if_changed \
    "$SCRIPT_DIR/templates/snapserver.service.tmpl" \
    "/etc/systemd/system/snapserver.service" && _config_changed=1 || true

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

check_librespot_health() {
    if systemctl is-active --quiet librespot; then
        return 0
    fi

    echo "librespot is not active yet; waiting briefly before rechecking..."
    sleep 3

    if systemctl is-active --quiet librespot; then
        return 0
    fi

    echo "Error: librespot is not active after setup." >&2
    systemctl status librespot --no-pager -l >&2 || true
    journalctl -u librespot -n 80 --no-pager >&2 || true
    return 1
}

if [[ $_config_changed -eq 1 ]]; then
    systemd_enable_restart librespot
    check_librespot_health
    systemd_enable_restart snapserver
else
    echo "Config unchanged — skipping service restarts"
    systemctl unmask librespot snapserver 2>/dev/null || true
    systemctl enable librespot snapserver 2>/dev/null || true
    systemctl is-active --quiet librespot || systemctl start librespot
    check_librespot_health
    systemctl is-active --quiet snapserver || systemctl start snapserver
fi

# ---------------------------------------------------------------------------
# 11. Install auth helper command
# ---------------------------------------------------------------------------
install -m 0755 "$SCRIPT_DIR/scripts/librespot-auth-helper.sh" /usr/local/bin/librespot-auth-helper

# Determine best effort host IP for SSH tunnel instructions
HOST_IP="$(hostname -I 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i !~ /^127\./) {print $i; exit}}')"
if [[ -z "$HOST_IP" ]]; then
    HOST_IP="$(cfg server_ip)"
fi

CALLBACK_PORT="$(cfg spotify oauth_callback_port 4000)"
SSH_USER="${SUDO_USER:-$USER}"
SSH_TUNNEL_CMD="ssh -L ${CALLBACK_PORT}:localhost:${CALLBACK_PORT} ${SSH_USER}@${HOST_IP}"

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
echo "     Run: sudo librespot-auth-helper start-auth ${CALLBACK_PORT} $(cfg spotify cache_dir)"
echo "     (Prints explicit SUCCESS/FAILURE and copy-paste tunnel/browser commands.)"
echo "     Or follow logs live: sudo journalctl -u librespot -f"
echo ""
echo "     If you're connected over SSH, run this on your laptop:"
echo "       ${SSH_TUNNEL_CMD}"
echo "     Then open: http://localhost:${CALLBACK_PORT}"
echo ""
echo "  2. Open Spotify on any device and look for:"
echo "     '$(cfg spotify device_name)' in the device list."
echo ""
echo "  3. Run setup on each client device:"
echo "     sudo ./setup.sh client"
echo ""
echo "  4. Deterministic auth status check:"
echo "     sudo librespot-auth-helper verify-auth-cache $(cfg spotify cache_dir)"
echo ""
echo "  Service status:"
echo "     sudo systemctl status librespot snapserver"
echo "     sudo journalctl -u librespot -f"
echo ""
