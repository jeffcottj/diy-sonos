#!/usr/bin/env bash
# cleanup-legacy.sh — legacy unit and binary cleanup helpers for setup roles.
# Sourced by setup-server.sh and setup-client.sh after common.sh.

set -euo pipefail

cleanup_legacy_for_role() {
    local role="${1:-}"
    if [[ "$role" != "server" && "$role" != "client" ]]; then
        echo "Error: cleanup_legacy_for_role requires role=server|client" >&2
        return 1
    fi

    echo ""
    echo "--- Legacy service/binary cleanup (${role}) ---"

    local canonical_units=(librespot.service snapserver.service snapclient.service)
    local legacy_units=(raspotify.service)
    local distro_units=(snapclient.service snapserver.service)

    mapfile -t alt_units < <(find /etc/systemd/system -maxdepth 1 -type f -name '*.service' 2>/dev/null | \
        while read -r unit; do
            local base
            base="$(basename "$unit")"
            if [[ "$base" == "librespot.service" || "$base" == "snapserver.service" || "$base" == "snapclient.service" || "$base" == "raspotify.service" ]]; then
                continue
            fi
            if grep -Eq '^ExecStart=.*(/usr/(local/)?bin/(librespot|snapserver|snapclient)|\<(librespot|snapserver|snapclient)\>)' "$unit"; then
                echo "$base"
            fi
        done | sort -u)

    echo "Detected known legacy units:"
    for unit in "${legacy_units[@]}"; do
        _report_unit_presence "$unit"
    done

    echo "Detected distro-provided snapcast units:"
    for unit in "${distro_units[@]}"; do
        local source_path=""
        source_path="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
        if [[ "$source_path" == /lib/systemd/system/* || "$source_path" == /usr/lib/systemd/system/* ]]; then
            echo "  - $unit (distro unit: $source_path)"
        elif [[ -n "$source_path" ]]; then
            echo "  - $unit (effective source: $source_path)"
        else
            echo "  - $unit (not installed)"
        fi
    done

    if [[ ${#alt_units[@]} -gt 0 ]]; then
        echo "Detected alternate/custom legacy units:"
        local unit
        for unit in "${alt_units[@]}"; do
            _report_unit_presence "$unit"
        done
    else
        echo "Detected alternate/custom legacy units: none"
    fi

    local conflicting_units=()
    if [[ "$role" == "server" ]]; then
        if [[ "${DIY_SONOS_COMBO_ROLE:-0}" -eq 1 ]]; then
            conflicting_units=(raspotify.service)
        else
            conflicting_units=(snapclient.service raspotify.service)
        fi
    else
        if [[ "${DIY_SONOS_COMBO_ROLE:-0}" -eq 1 ]]; then
            conflicting_units=(raspotify.service)
        else
            conflicting_units=(librespot.service snapserver.service raspotify.service)
        fi
    fi

    echo "Applying role conflict policy (${role})..."
    local unit
    for unit in "${conflicting_units[@]}"; do
        if systemctl list-unit-files --type=service --all | awk '{print $1}' | grep -qx "$unit"; then
            echo "  - stop/disable/mask $unit"
            systemctl stop "$unit" 2>/dev/null || true
            systemctl disable "$unit" 2>/dev/null || true
            systemctl mask "$unit" 2>/dev/null || true
        fi
    done

    _quarantine_legacy_units "${alt_units[@]}"
    _handle_legacy_local_binaries
    _print_effective_binary_and_unit_summary
}

_report_unit_presence() {
    local unit="$1"
    local source_path=""
    source_path="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
    if [[ -n "$source_path" ]]; then
        echo "  - $unit ($source_path)"
    elif [[ -f "/etc/systemd/system/$unit" ]]; then
        echo "  - $unit (/etc/systemd/system/$unit)"
    else
        echo "  - $unit (not installed)"
    fi
}

_quarantine_legacy_units() {
    if [[ $# -eq 0 ]]; then
        return 0
    fi

    local quarantine_root="/etc/systemd/system/diy-sonos-legacy-disabled"
    local stamp
    stamp="$(date +%Y%m%d-%H%M%S)"
    local quarantine_dir="${quarantine_root}/${stamp}"

    local moved_any=0
    local unit
    for unit in "$@"; do
        [[ -n "$unit" ]] || continue

        local unit_path="/etc/systemd/system/$unit"
        if [[ ! -f "$unit_path" ]]; then
            continue
        fi

        snapshot_file "$unit_path"
        mkdir -p "$quarantine_dir"

        echo "  - quarantining obsolete unit $unit_path -> $quarantine_dir/"
        systemctl stop "$unit" 2>/dev/null || true
        systemctl disable "$unit" 2>/dev/null || true
        systemctl mask "$unit" 2>/dev/null || true
        mv "$unit_path" "$quarantine_dir/"
        moved_any=1
    done

    if [[ $moved_any -eq 1 ]]; then
        systemctl daemon-reload
        echo "Quarantined obsolete units under: $quarantine_dir"
    fi
}

_handle_legacy_local_binaries() {
    echo "Checking for conflicting /usr/local/bin legacy binaries..."
    local name
    for name in librespot snapclient snapserver; do
        local local_bin="/usr/local/bin/${name}"
        local distro_bin="/usr/bin/${name}"

        if [[ ! -e "$local_bin" ]]; then
            continue
        fi

        if [[ ! -x "$distro_bin" ]]; then
            echo "  - WARNING: found $local_bin, but $distro_bin is missing; leaving local binary in place"
            continue
        fi

        if dpkg -S "$local_bin" >/dev/null 2>&1; then
            echo "  - $local_bin is package-managed; leaving in place"
            continue
        fi

        snapshot_file "$local_bin"
        rm -f "$local_bin"
        echo "  - Removed unmanaged conflicting binary: $local_bin (using $distro_bin)"
    done
}

_print_effective_binary_and_unit_summary() {
    echo ""
    echo "Effective binary + unit source summary:"

    local svc
    for svc in librespot snapclient snapserver; do
        local unit="${svc}.service"
        local unit_source
        unit_source="$(systemctl show -p FragmentPath --value "$unit" 2>/dev/null || true)"
        if [[ -z "$unit_source" ]]; then
            unit_source="(not installed)"
        fi

        local binary="(unknown)"
        if [[ -f "$unit_source" ]]; then
            binary="$(awk -F= '/^ExecStart=/{print $2; exit}' "$unit_source" | awk '{print $1}')"
            [[ -n "$binary" ]] || binary="(unknown)"
        fi

        local resolved_binary="$binary"
        if [[ "$binary" == /* && -e "$binary" ]]; then
            resolved_binary="$(readlink -f "$binary")"
        fi

        echo "  - $svc"
        echo "      unit source: $unit_source"
        echo "      exec binary: $binary"
        echo "      resolved to: $resolved_binary"
    done
}
