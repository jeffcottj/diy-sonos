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

# Determine effective output volume: per-client override for this host if configured, else global
EFFECTIVE_OUTPUT_VOLUME=""
if declare -F get_effective_snapclient_output_volume >/dev/null 2>&1; then
    EFFECTIVE_OUTPUT_VOLUME="$(get_effective_snapclient_output_volume 2>/dev/null || true)"
fi
if [[ -z "$EFFECTIVE_OUTPUT_VOLUME" ]]; then
    EFFECTIVE_OUTPUT_VOLUME="$(cfg snapclient output_volume 90)"
fi
# Validate; fallback to 90 on invalid config
if ! validate_snapclient_output_volume "$EFFECTIVE_OUTPUT_VOLUME" 2>/dev/null; then
    echo "Warning: configured output_volume '$EFFECTIVE_OUTPUT_VOLUME' invalid, falling back to 90" >&2
    EFFECTIVE_OUTPUT_VOLUME="90"
fi
echo "Effective output volume: ${EFFECTIVE_OUTPUT_VOLUME}% (global=$(cfg snapclient output_volume 90)%$(if [[ "$(cfg snapclient output_volume 90)" != "$EFFECTIVE_OUTPUT_VOLUME" ]]; then echo ", per-client override active"; fi))"

set_client_output_volume_max "$EFFECTIVE_OUTPUT_VOLUME"

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

# Ensure volume survives reboot even if alsa-restore is unavailable or card renumbered:
# Create a small oneshot service that reapplies the configured volume at boot.
ALSA_VOLUME_SERVICE="/etc/systemd/system/diy-sonos-alsa-volume.service"
ALSA_VOLUME_SCRIPT="/usr/local/bin/diy-sonos-apply-volume"
snapshot_file "$ALSA_VOLUME_SERVICE"
snapshot_file "$ALSA_VOLUME_SCRIPT"
cat > "$ALSA_VOLUME_SCRIPT" <<EOSVC
#!/usr/bin/env bash
set -euo pipefail
TARGET_VOL="$EFFECTIVE_OUTPUT_VOLUME"
RESOLVED_DEVICE="$RESOLVED_AUDIO_DEVICE"
# Resolve card at boot (handles renumbering and 'auto' without repo dependency)
if [[ "\$RESOLVED_DEVICE" == "auto" ]]; then
    # Try to find first non-HDMI card via /proc/asound/cards, fallback to aplay
    if [[ -f /proc/asound/cards ]]; then
        while IFS= read -r line; do
            if [[ "\$line" =~ ^[[:space:]]*[0-9]+[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*([^-]+) ]]; then
                _cname="\${BASH_REMATCH[1]}"
                _cdriver="\${BASH_REMATCH[2]}"
                _cname="\${_cname%"\${_cname##*[![:space:]]}"}"
                _cdriver="\${_cdriver%"\${_cdriver##*[![:space:]]}"}"
                if [[ "\$_cdriver" == "USB-Audio" ]]; then
                    RESOLVED_DEVICE="plughw:\${_cname},0"
                    break
                fi
            fi
        done < /proc/asound/cards
    fi
    if [[ "\$RESOLVED_DEVICE" == "auto" ]]; then
        _first="\$(aplay -l 2>/dev/null | awk '/^card [0-9]+:/{print \$2; sub(/:$/,"",\$2); print \$2; exit}')"
        if [[ -n "\$_first" ]]; then
            RESOLVED_DEVICE="plughw:\${_first},0"
        else
            RESOLVED_DEVICE="default"
        fi
    fi
fi
CARD="\$(case "\$RESOLVED_DEVICE" in plughw:*|hw:*) echo "\${RESOLVED_DEVICE#*:}" | cut -d, -f1 ;; *) echo "0" ;; esac)"
if [[ -z "\$CARD" ]]; then CARD="0"; fi
MIXER="\$(amixer -c "\$CARD" scontrols 2>/dev/null | awk -F"'" 'NR==1{print \$2}' || true)"
if [[ -n "\$MIXER" ]]; then
    amixer -c "\$CARD" sset "\$MIXER" "\${TARGET_VOL}%" unmute >/dev/null 2>&1 || true
else
    for fb in Master PCM Speaker; do
        amixer -c "\$CARD" sset "\$fb" "\${TARGET_VOL}%" unmute >/dev/null 2>&1 && break || true
    done
fi
EOSVC
chmod +x "$ALSA_VOLUME_SCRIPT"
cat > "$ALSA_VOLUME_SERVICE" <<EOSVC
[Unit]
Description=DIY Sonos — restore ALSA volume for $RESOLVED_AUDIO_DEVICE
After=sound.target
Wants=sound.target

[Service]
Type=oneshot
ExecStart=$ALSA_VOLUME_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOSVC
systemctl daemon-reload 2>/dev/null || true
systemctl enable diy-sonos-alsa-volume.service 2>/dev/null || true
echo "Ensured boot-time volume restore service: diy-sonos-alsa-volume.service (${EFFECTIVE_OUTPUT_VOLUME}%)"

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
