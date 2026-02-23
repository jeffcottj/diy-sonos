#!/usr/bin/env bash
# setup-client.sh — install and configure snapclient on a client device
# Sourced by setup.sh after common.sh is loaded and config is parsed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/scripts/cleanup-legacy.sh"

first_real_mixer_card_from_aplay() {
    if ! command -v aplay >/dev/null 2>&1; then
        return 0
    fi

    aplay -l 2>/dev/null | awk '
        /^card[[:space:]]+/ {
            if (match($0, /^card[[:space:]]+([^:]+):/, m)) {
                print m[1]
                exit
            }
        }
    '
}

resolve_mixer_card_for_playback_device() {
    local playback_device="${1:-}"
    local parsed_card=""

    case "$playback_device" in
        plughw:*|hw:*)
            parsed_card="${playback_device#*:}"
            parsed_card="${parsed_card%%,*}"
            ;;
    esac

    if [[ -n "$parsed_card" ]]; then
        printf '%s\n' "$parsed_card"
        return 0
    fi

    first_real_mixer_card_from_aplay
}

set_client_output_volume_max() {
    local target_volume="$1"
    if ! command -v amixer >/dev/null 2>&1; then
        echo "amixer not found; skipping ALSA mixer volume tuning"
        return 0
    fi

    local card mixer
    card="$(resolve_mixer_card_for_playback_device "$RESOLVED_AUDIO_DEVICE" || true)"

    if [[ -z "$card" ]]; then
        echo "Warning: could not derive ALSA mixer card for playback device '$RESOLVED_AUDIO_DEVICE'; skipping volume tuning" >&2
        return 0
    fi

    mixer="$(amixer -c "$card" scontrols 2>/dev/null | awk -F"'" 'NR==1{print $2}' || true)"

    if [[ -n "$mixer" ]]; then
        if amixer -c "$card" sset "$mixer" "${target_volume}%" unmute >/dev/null 2>&1; then
            echo "Set ALSA mixer '$mixer' to ${target_volume}% (playback='$RESOLVED_AUDIO_DEVICE', card='$card')"
            return 0
        fi
    fi

    local fallback_control
    for fallback_control in Master PCM Speaker; do
        if amixer -c "$card" sset "$fallback_control" "${target_volume}%" unmute >/dev/null 2>&1; then
            echo "Set ALSA mixer '$fallback_control' to ${target_volume}% (playback='$RESOLVED_AUDIO_DEVICE', card='$card')"
            return 0
        fi
    done

    echo "Warning: no usable ALSA mixer control found (playback='$RESOLVED_AUDIO_DEVICE', card='$card'); tune with alsamixer manually" >&2
}

enable_alsa_restore_units() {
    local unit
    local found=0

    for unit in alsa-restore.service alsa-state.service; do
        if ! systemctl list-unit-files --type=service --all | awk '{print $1}' | grep -qx "$unit"; then
            echo "ALSA restore unit not present on this distro: $unit (skipping)"
            continue
        fi

        found=1
        systemctl unmask "$unit" 2>/dev/null || true
        systemctl enable "$unit" >/dev/null 2>&1 || true
        systemctl is-active --quiet "$unit" || systemctl start "$unit" >/dev/null 2>&1 || true
        echo "Ensured ALSA restore unit: $unit"
    done

    if [[ $found -eq 0 ]]; then
        echo "Warning: neither alsa-restore.service nor alsa-state.service is installed; ALSA mixer restore at boot is unavailable" >&2
    fi
}


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

# The snapclient deb may pull in snapserver as a dependency.
# On client-only devices, mask/stop it.
# On server+client (combo) devices, keep snapserver running.
if [[ "${DIY_SONOS_COMBO_ROLE:-0}" -eq 1 ]]; then
    echo "Combo role detected — leaving snapserver.service unmasked on this host"
    systemctl unmask snapserver.service 2>/dev/null || true
else
    systemctl mask snapserver.service 2>/dev/null || true
    systemctl stop snapserver.service 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# 4. Resolve audio output device
# ---------------------------------------------------------------------------
echo ""
echo "--- Resolving audio device ---"

resolve_audio_device "$(cfg snapclient audio_device)"
echo "Audio device: $RESOLVED_AUDIO_DEVICE"
echo "Mixer card:   $(resolve_mixer_card_for_playback_device "$RESOLVED_AUDIO_DEVICE" || echo '<unresolved>')"

set_client_output_volume_max "$(cfg snapclient output_volume 100)"

if command -v alsactl >/dev/null 2>&1; then
    if alsactl store >/dev/null 2>&1; then
        echo "Persisted ALSA mixer state via: alsactl store"
    elif alsactl -f /var/lib/alsa/asound.state store >/dev/null 2>&1; then
        echo "Persisted ALSA mixer state via: alsactl -f /var/lib/alsa/asound.state store"
    else
        echo "Warning: failed to persist ALSA mixer state with alsactl; mixer levels may reset on reboot" >&2
    fi
else
    echo "Warning: alsactl not found; cannot persist ALSA mixer state" >&2
fi

enable_alsa_restore_units

# Validate that the resolved audio device is usable in a system service
if [[ "$RESOLVED_AUDIO_DEVICE" == "default" ]]; then
    echo "" >&2
    echo "WARNING: audio device resolved to 'default'." >&2
    echo "  snapclient.service will fail to open this device on Pi OS (PipeWire context)." >&2
    echo "  Set snapclient.audio_device in config.yml to a specific device, e.g.:" >&2
    echo "    snapclient:" >&2
    echo "      audio_device: \"plughw:Device,0\"" >&2
    echo "" >&2
    echo "  Available audio hardware:" >&2
    aplay -l 2>/dev/null | grep '^card' | sed 's/^/    /' >&2
    echo "" >&2
fi

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
    systemctl unmask snapclient 2>/dev/null || true
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
