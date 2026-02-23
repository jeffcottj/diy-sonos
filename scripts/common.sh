#!/usr/bin/env bash
# common.sh — shared functions for DIY Sonos setup scripts
# Sourced by setup.sh; do not execute directly.

# Shared package versions
SNAPCAST_VER_DEFAULT="0.31.0"

# ---------------------------------------------------------------------------
# Config parsing
# ---------------------------------------------------------------------------

# parse_config <yaml_file>
# Flattens nested YAML into exported shell variables.
# Nested keys are joined with double underscore:
#   spotify.device_name -> SPOTIFY__DEVICE_NAME
parse_config() {
    local yaml_file="$1"
    local output
    output=$(python3 - "$yaml_file" <<'PYEOF'
import sys, yaml

def flatten(obj, prefix=""):
    items = {}
    if isinstance(obj, dict):
        for k, v in obj.items():
            key = (prefix + "__" + str(k)) if prefix else str(k)
            items.update(flatten(v, key))
    else:
        items[prefix] = obj
    return items

with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)

for k, v in flatten(data).items():
    shell_name = k.upper().replace("-", "_")
    if v is None:
        v = ""
    elif isinstance(v, bool):
        v = "true" if v else "false"
    # Emit export statements
    print(f"export {shell_name}={repr(str(v))}")
PYEOF
)
    eval "$output"
}


# parse_config_files <base_yaml> [generated_yaml]
# Precedence (lowest -> highest):
#   1) base_yaml (usually config.yml)
#   2) generated_yaml (usually .diy-sonos.generated.yml), if present
parse_config_files() {
    local base_yaml="$1"
    local generated_yaml="${2:-}"

    parse_config "$base_yaml"

    if [[ -n "$generated_yaml" && -f "$generated_yaml" ]]; then
        echo "Using generated config override: $generated_yaml"
        parse_config "$generated_yaml"
    fi
}

# apply_cli_config_overrides <server_ip> <device_name> <audio_device> <output_volume>
# Highest precedence configuration layer.
apply_cli_config_overrides() {
    local server_ip="$1"
    local device_name="$2"
    local audio_device="$3"
    local output_volume="$4"

    if [[ -n "$server_ip" ]]; then
        export SERVER_IP="$server_ip"
    fi

    if [[ -n "$device_name" ]]; then
        export SPOTIFY__DEVICE_NAME="$device_name"
    fi

    if [[ -n "$audio_device" ]]; then
        export SNAPCLIENT__AUDIO_DEVICE="$audio_device"
    fi

    if [[ -n "$output_volume" ]]; then
        export SNAPCLIENT__OUTPUT_VOLUME="$output_volume"
    fi
}

# cfg <section> <key> [default]
# cfg <key> [default]
# Read a config variable by section and key (mirrors YAML nesting),
# or read a top-level key directly.
# e.g. cfg spotify device_name
#      cfg server_ip
cfg() {
    local section="${1^^}"
    local key="${2-}"
    local default="${3-}"
    local var_name
    local nested_var

    if [[ -n "$key" ]]; then
        key="${key^^}"
        nested_var="${section}__${key}"
    fi

    if [[ $# -ge 3 ]]; then
        var_name="$nested_var"
    elif [[ $# -eq 2 ]]; then
        if [[ -n "${!nested_var+x}" ]]; then
            var_name="$nested_var"
            default=""
        else
            var_name="$section"
            default="${2-}"
        fi
    else
        var_name="$section"
    fi

    echo "${!var_name:-$default}"
}

# require_snapcast_version
# Prints the configured Snapcast version (single source of truth) and
# exits with an error if it is empty.
require_snapcast_version() {
    local snapcast_ver="${SNAPCAST_VER_DEFAULT:-}"
    if [[ -z "$snapcast_ver" ]]; then
        echo "Error: SNAPCAST_VER_DEFAULT is empty in scripts/common.sh. Set it before running setup." >&2
        exit 1
    fi
    echo "$snapcast_ver"
}

# ---------------------------------------------------------------------------
# Config validation helpers
# ---------------------------------------------------------------------------

validate_server_ip() {
    local value="$1"

    if [[ -z "$value" ]]; then
        echo "server_ip must not be empty"
        return 1
    fi

    if [[ ! "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        echo "server_ip '$value' must be a valid IPv4 address (example: 192.168.1.100)"
        return 1
    fi

    local IFS='.'
    local octets=($value)
    local octet
    for octet in "${octets[@]}"; do
        if ((octet < 0 || octet > 255)); then
            echo "server_ip '$value' has out-of-range octet '$octet' (must be 0-255)"
            return 1
        fi
    done
}

validate_spotify_bitrate() {
    local value="$1"
    case "$value" in
        96|160|320) return 0 ;;
        *)
            echo "spotify.bitrate '$value' is invalid; supported values: 96, 160, 320"
            return 1
            ;;
    esac
}

validate_snapserver_codec() {
    local value="${1,,}"
    case "$value" in
        flac|pcm) return 0 ;;
        *)
            echo "snapserver.codec '$1' is invalid; supported values: flac, pcm"
            return 1
            ;;
    esac
}

validate_snapclient_audio_device() {
    local value="$1"
    if [[ "$value" =~ ^(auto|default)$ ]]; then
        return 0
    fi

    if [[ "$value" =~ ^(hw|plughw):[0-9]+,[0-9]+$ ]]; then
        return 0
    fi

    echo "snapclient.audio_device '$value' must be 'auto', 'default', or an ALSA device like 'hw:1,0'"
    return 1
}

validate_snapclient_output_volume() {
    local value="$1"

    if [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "snapclient.output_volume '$value' must be an integer between 0 and 100"
        return 1
    fi

    if ((value < 0 || value > 100)); then
        echo "snapclient.output_volume '$value' must be between 0 and 100"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# OS / arch detection
# ---------------------------------------------------------------------------

# Sets: OS_ID (e.g. "raspbian", "debian"), OS_CODENAME (e.g. "bookworm")
detect_os_codename() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-debian}"
        OS_CODENAME="${VERSION_CODENAME:-bookworm}"
    else
        OS_ID="debian"
        OS_CODENAME="bookworm"
    fi
    export OS_ID OS_CODENAME
    echo "Detected OS: $OS_ID ($OS_CODENAME)"
}

# Sets: ARCH_UNAME (e.g. "aarch64"), ARCH_DEB (e.g. "arm64")
detect_arch() {
    ARCH_UNAME="$(uname -m)"
    case "$ARCH_UNAME" in
        aarch64)        ARCH_DEB="arm64" ;;
        armv7l|armv6l)  ARCH_DEB="armhf" ;;
        x86_64)         ARCH_DEB="amd64" ;;
        *)
            echo "Warning: unknown architecture '$ARCH_UNAME', defaulting to arm64" >&2
            ARCH_DEB="arm64"
            ;;
    esac
    export ARCH_UNAME ARCH_DEB
    echo "Detected architecture: $ARCH_UNAME ($ARCH_DEB)"
}

# ---------------------------------------------------------------------------
# Package management
# ---------------------------------------------------------------------------

# apt_update_if_stale
# Runs apt-get update only if the package lists are more than 1 hour old.
apt_update_if_stale() {
    local stamp="/var/lib/apt/periodic/update-success-stamp"
    if [[ -f "$stamp" ]]; then
        local age=$(( $(date +%s) - $(stat -c %Y "$stamp") ))
        if [[ $age -lt 3600 ]]; then
            echo "Package lists are fresh (${age}s old); skipping apt-get update"
            return 0
        fi
    fi
    apt-get update -qq
}

# pkg_install <pkg...>
# Installs packages only if not already installed (idempotent).
pkg_install() {
    local to_install=()
    for pkg in "$@"; do
        if ! dpkg -s "$pkg" &>/dev/null; then
            to_install+=("$pkg")
        fi
    done
    if [[ ${#to_install[@]} -gt 0 ]]; then
        echo "Installing packages: ${to_install[*]}"
        apt-get install -y "${to_install[@]}"
    else
        echo "Packages already installed: $*"
    fi
}

# install_deb <url>
# Downloads a .deb and installs it, skipping if the same version is already installed.
install_deb() {
    local url="$1"
    local filename
    filename="$(basename "$url")"
    local tmp="/tmp/$filename"

    # Extract package name from filename (strip _version_arch.deb)
    local pkg_name
    pkg_name="$(echo "$filename" | cut -d_ -f1)"

    # Extract version from filename (second field)
    local pkg_ver
    pkg_ver="$(echo "$filename" | cut -d_ -f2)"

    local installed_ver=""
    if dpkg -s "$pkg_name" &>/dev/null; then
        installed_ver="$(dpkg -s "$pkg_name" | awk '/^Version:/ {print $2}')"
    fi

    echo "install_deb: pkg_name=$pkg_name installed_ver=${installed_ver:-<not-installed>} pkg_ver=$pkg_ver"
    if [[ -n "$installed_ver" ]]; then
        if [[ "$installed_ver" == "$pkg_ver" ]]; then
            echo "install_deb: decision=skip (installed version matches repo package exactly)"
            return 0
        fi
        echo "install_deb: decision=install (installed version differs from repo package)"
    else
        echo "install_deb: decision=install (package not currently installed)"
    fi

    echo "Downloading $filename..."
    download_file "$url" "$tmp"
    echo "Installing $filename..."
    dpkg -i "$tmp"
    apt-get install -f -y   # fix any dependency issues
    rm -f "$tmp"
}

# ---------------------------------------------------------------------------
# File / FIFO helpers
# ---------------------------------------------------------------------------

# ensure_fifo <path>
# Creates a named pipe (FIFO) if it doesn't already exist.
ensure_fifo() {
    local path="$1"
    if [[ -p "$path" ]]; then
        echo "FIFO already exists: $path"
    elif [[ -e "$path" ]]; then
        echo "Warning: $path exists but is not a FIFO; removing and recreating" >&2
        rm -f "$path"
        mkfifo "$path"
        echo "Created FIFO: $path"
    else
        mkfifo "$path"
        echo "Created FIFO: $path"
    fi
}

# ensure_dir <path> [owner]
# Creates directory (and parents) with optional chown.
ensure_dir() {
    local path="$1"
    local owner="${2:-}"
    mkdir -p "$path"
    if [[ -n "$owner" ]]; then
        chown "$owner" "$path"
    fi
}

# download_file <url> <dest>
# Downloads a file to dest, skipping if dest already exists.
# Removes partial file on failure.
download_file() {
    local url="$1"
    local dest="$2"
    if [[ -f "$dest" ]]; then
        echo "File already downloaded: $dest"
        return 0
    fi
    if ! wget -q --show-progress --timeout=60 -O "$dest" "$url"; then
        rm -f "$dest"
        echo "Error: failed to download $url" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# ALSA / audio device detection
# ---------------------------------------------------------------------------

# detect_alsa_usb_device
# Finds the first USB audio card and sets DETECTED_AUDIO_DEVICE.
# Uses plughw:CARD_NAME,0 (stable across reboots; enables format conversion).
# Method 1: /proc/asound/cards — looks for "USB-Audio" driver identifier (reliable
#   regardless of card display name).
# Method 2: aplay -l string match — secondary, catches unusual driver names.
# Falls back to first non-HDMI card, then "default" (warns loudly; "default" is
# PipeWire-backed on modern Pi OS and will not work in a system service context).
detect_alsa_usb_device() {
    local card_name="" fallback_name=""

    # Method 1: /proc/asound/cards — look for USB-Audio driver identifier
    if [[ -f /proc/asound/cards ]]; then
        while IFS= read -r line; do
            if [[ "$line" =~ ^[[:space:]]*[0-9]+[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*([^-]+) ]]; then
                local cur_name="${BASH_REMATCH[1]}"
                local cur_driver="${BASH_REMATCH[2]}"
                cur_name="${cur_name%"${cur_name##*[![:space:]]}"}"
                cur_driver="${cur_driver%"${cur_driver##*[![:space:]]}"}"
                if [[ "$cur_driver" == "USB-Audio" ]]; then
                    card_name="$cur_name"
                    break
                elif [[ -z "$fallback_name" && "${cur_name,,}" != *hdmi* ]]; then
                    fallback_name="$cur_name"
                fi
            fi
        done < /proc/asound/cards
    fi

    # Method 2: aplay -l string match (secondary, catches unusual driver names)
    if [[ -z "$card_name" ]]; then
        local aplay_num
        aplay_num=$(aplay -l 2>/dev/null | awk '
            /^card [0-9]+:/ { card=$2; sub(/:$/,"",card) }
            /USB/ { if (card!="") { print card; exit } }
        ')
        if [[ -n "$aplay_num" ]]; then
            card_name=$(aplay -l 2>/dev/null | awk -v n="$aplay_num" '
                $0 ~ "^card "n":" {
                    line=$0
                    sub(/^card [0-9]+: /, "", line)
                    sub(/ .*/, "", line)
                    print line
                    exit
                }
            ')
            [[ -z "$card_name" ]] && card_name="$aplay_num"
        fi
    fi

    if [[ -n "$card_name" ]]; then
        DETECTED_AUDIO_DEVICE="plughw:${card_name},0"
        echo "Detected USB audio device: $DETECTED_AUDIO_DEVICE"
    elif [[ -n "$fallback_name" ]]; then
        DETECTED_AUDIO_DEVICE="plughw:${fallback_name},0"
        echo "No USB audio device found; using first non-HDMI card: $DETECTED_AUDIO_DEVICE" >&2
    else
        DETECTED_AUDIO_DEVICE="default"
        echo "Warning: no suitable audio hardware found; falling back to 'default'" >&2
        echo "  'default' will NOT work for snapclient.service on modern Pi OS (PipeWire)." >&2
        echo "  Set snapclient.audio_device explicitly in config.yml and redeploy." >&2
    fi
    export DETECTED_AUDIO_DEVICE
}

# resolve_audio_device <cfg_value>
# If cfg_value is "auto", auto-detect; otherwise use the configured value.
# Sets and exports RESOLVED_AUDIO_DEVICE.
resolve_audio_device() {
    local cfg_value="$1"
    if [[ "$cfg_value" == "auto" ]]; then
        detect_alsa_usb_device
        RESOLVED_AUDIO_DEVICE="$DETECTED_AUDIO_DEVICE"
    else
        RESOLVED_AUDIO_DEVICE="$cfg_value"
        echo "Using configured audio device: $RESOLVED_AUDIO_DEVICE"
    fi
    export RESOLVED_AUDIO_DEVICE
}


# ---------------------------------------------------------------------------
# Optional backup snapshots
# ---------------------------------------------------------------------------

# snapshot_file <target_path>
# If BACKUP_SNAPSHOT_DIR is set and target exists, copy it into the snapshot tree
# and print a restore command.
snapshot_file() {
    local target="$1"

    if [[ -z "${BACKUP_SNAPSHOT_DIR:-}" ]]; then
        return 0
    fi

    if [[ ! -e "$target" ]]; then
        return 0
    fi

    local dest="$BACKUP_SNAPSHOT_DIR${target}"
    mkdir -p "$(dirname "$dest")"
    cp -a "$target" "$dest"

    echo "Backup snapshot: $target -> $dest"
    echo "  Restore: sudo cp -a '$dest' '$target'"
}

# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------

# render_template <tmpl_file> <output_file>
# Substitutes {{VAR}} placeholders with the current value of $VAR from the environment.
# Writes atomically via a temp file so a failed write never leaves a truncated file.
render_template() {
    local tmpl="$1"
    local out="$2"
    python3 - "$tmpl" "$out" <<'PYEOF'
import sys, os, re, tempfile

tmpl_path, out_path = sys.argv[1], sys.argv[2]

with open(tmpl_path) as f:
    content = f.read()

def replace(m):
    var = m.group(1)
    val = os.environ.get(var)
    if val is None:
        raise KeyError(f"Template variable not found in environment: {var}")
    return val

content = re.sub(r'\{\{([A-Z0-9_]+)\}\}', replace, content)

tmp_fd, tmp_path = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(out_path)))
try:
    with os.fdopen(tmp_fd, 'w') as f:
        f.write(content)
    os.replace(tmp_path, out_path)
except:
    try: os.unlink(tmp_path)
    except: pass
    raise

print(f"Rendered: {tmpl_path} -> {out_path}")
PYEOF
}

# render_template_if_changed <tmpl_file> <output_file>
# Like render_template but skips the write if the rendered content is identical
# to the existing file. Returns 0 if the file was written (new or changed),
# 1 if unchanged (no write, no side effects).
render_template_if_changed() {
    local tmpl="$1"
    local out="$2"
    local tmp
    tmp="$(mktemp)"
    python3 - "$tmpl" "$tmp" <<'PYEOF'
import sys, os, re

tmpl_path, out_path = sys.argv[1], sys.argv[2]

with open(tmpl_path) as f:
    content = f.read()

def replace(m):
    var = m.group(1)
    val = os.environ.get(var)
    if val is None:
        raise KeyError(f"Template variable not found in environment: {var}")
    return val

content = re.sub(r'\{\{([A-Z0-9_]+)\}\}', replace, content)

with open(out_path, 'w') as f:
    f.write(content)
PYEOF
    if [[ -f "$out" ]] && diff -q "$out" "$tmp" > /dev/null 2>&1; then
        rm -f "$tmp"
        echo "Unchanged: $out"
        return 1
    fi
    mv "$tmp" "$out"
    echo "Rendered: $tmpl -> $out"
    return 0
}

# ---------------------------------------------------------------------------
# systemd helpers
# ---------------------------------------------------------------------------

# systemd_enable_restart <service>
# Reloads daemon, enables and starts (or restarts) a systemd service.
systemd_enable_restart() {
    local svc="$1"
    systemctl daemon-reload
    systemctl unmask "$svc" 2>/dev/null || true
    systemctl enable "$svc"
    if systemctl is-active --quiet "$svc"; then
        systemctl restart "$svc"
        echo "Restarted: $svc"
    else
        systemctl start "$svc"
        echo "Started: $svc"
    fi
}

# ---------------------------------------------------------------------------
# Doctor / health-check helpers
# ---------------------------------------------------------------------------

doctor_mark() {
    local status="$1"
    case "$status" in
        pass) printf '[PASS]' ;;
        fail) printf '[FAIL]' ;;
        warn) printf '[WARN]' ;;
        *)    printf '[INFO]' ;;
    esac
}

doctor_severity() {
    local status="$1"
    case "$status" in
        fail) printf 'must-fix' ;;
        warn) printf 'optional' ;;
        *)    printf 'info' ;;
    esac
}

doctor_report() {
    local status="$1"
    local message="$2"
    local explanation="${3:-}"
    local remediation="${4:-}"

    printf '  %s [%s] %s\n' "$(doctor_mark "$status")" "$(doctor_severity "$status")" "$message"
    if [[ -n "$explanation" ]]; then
        printf '         Why this matters: %s\n' "$explanation"
    fi
    if [[ -n "$remediation" ]]; then
        printf '         Suggested command: %s\n' "$remediation"
    fi
}

doctor_check_systemd_service() {
    local service_name="$1"
    local remediation="${2:-sudo systemctl restart ${service_name}}"
    local install_cmd="sudo ./setup.sh server"

    case "$service_name" in
        snapclient) install_cmd="sudo ./setup.sh client" ;;
    esac

    if ! systemctl list-unit-files --type=service --all | awk '{print $1}' | grep -qx "${service_name}.service"; then
        doctor_report fail "${service_name}.service is not installed." "This service does not exist on the system yet, so audio components that depend on it cannot start." "$install_cmd"
        return 1
    fi

    local enabled_state
    enabled_state="$(systemctl is-enabled "$service_name" 2>/dev/null || true)"
    local active_state
    active_state="$(systemctl is-active "$service_name" 2>/dev/null || true)"

    local failed=0
    if [[ "$enabled_state" == "enabled" ]]; then
        doctor_report pass "${service_name}.service is enabled."
    else
        doctor_report fail "${service_name}.service is not enabled (state: ${enabled_state:-unknown})." "Disabled services do not automatically start after reboot, which can leave playback offline." "sudo systemctl enable ${service_name}"
        failed=1
    fi

    if [[ "$active_state" == "active" ]]; then
        doctor_report pass "${service_name}.service is active."
    else
        doctor_report fail "${service_name}.service is not active (state: ${active_state:-unknown})." "The process is currently stopped or crashed, so this audio role is not functioning right now." "$remediation"
        failed=1
    fi

    return $failed
}

doctor_check_listener() {
    local port="$1"
    local process_hint="$2"

    if ss -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" { found=1 } END { exit(found ? 0 : 1) }'; then
        doctor_report pass "TCP port ${port} is listening (${process_hint})."
        return 0
    fi

    doctor_report fail "TCP port ${port} is not listening (${process_hint})." "Nothing is accepting connections on this required port, so clients/controllers cannot talk to ${process_hint}." "sudo systemctl restart ${process_hint}"
    return 1
}

doctor_check_fifo() {
    local fifo_path="$1"
    if [[ -p "$fifo_path" ]]; then
        doctor_report pass "FIFO exists: ${fifo_path}"
        return 0
    fi
    doctor_report fail "FIFO missing or not a named pipe: ${fifo_path}" "The audio handoff pipe between librespot and snapserver is missing, so server audio cannot flow." "sudo rm -f '${fifo_path}' && sudo mkfifo '${fifo_path}'"
    return 1
}

doctor_show_recent_errors() {
    local unit="$1"
    local lines="${2:-15}"

    echo "  Recent errors (${unit}.service):"
    if ! journalctl -u "${unit}.service" -p err -n "$lines" --no-pager 2>/dev/null | sed 's/^/    /'; then
        doctor_report warn "Unable to read journal for ${unit}.service" "Logs were not readable in this session, so recent error clues are unavailable." "sudo journalctl -u ${unit}.service -p err -n ${lines} --no-pager"
    fi
}

doctor_check_librespot_service() {
    doctor_check_systemd_service "librespot" "sudo systemctl restart librespot"
}

doctor_check_snapserver_service() {
    doctor_check_systemd_service "snapserver" "sudo systemctl restart snapserver"
}

doctor_check_avahi_service() {
    doctor_check_systemd_service "avahi-daemon" "sudo systemctl restart avahi-daemon"
}

doctor_check_snapclient_service() {
    doctor_check_systemd_service "snapclient" "sudo systemctl restart snapclient"
}

doctor_check_alsa_restore_service() {
    local unit
    local present_units=()
    local enabled_any=0
    local active_any=0

    for unit in alsa-restore.service alsa-state.service; do
        if systemctl list-unit-files --type=service --all | awk '{print $1}' | grep -qx "$unit"; then
            present_units+=("$unit")
        fi
    done

    if [[ ${#present_units[@]} -eq 0 ]]; then
        doctor_report warn "No ALSA restore units found (alsa-restore.service / alsa-state.service)." \
            "Without one of these units, saved ALSA mixer levels are not automatically restored after boot." \
            "sudo apt-get install -y alsa-utils"
        return 0
    fi

    for unit in "${present_units[@]}"; do
        local enabled_state active_state
        enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
        active_state="$(systemctl is-active "$unit" 2>/dev/null || true)"

        if [[ "$enabled_state" == "enabled" ]]; then
            doctor_report pass "${unit} is enabled."
            enabled_any=1
        else
            doctor_report warn "${unit} is not enabled (state: ${enabled_state:-unknown})." \
                "After reboot, ALSA mixer state may not be restored automatically." \
                "sudo systemctl enable ${unit}"
        fi

        if [[ "$active_state" == "active" ]]; then
            doctor_report pass "${unit} is active."
            active_any=1
        else
            doctor_report warn "${unit} is not active (state: ${active_state:-unknown})." \
                "If inactive while boot has completed, saved mixer state may not have been applied." \
                "sudo systemctl start ${unit}"
        fi
    done

    if [[ $enabled_any -eq 0 ]]; then
        doctor_report warn "No installed ALSA restore unit is enabled." \
            "Mixer levels can reset to driver defaults after reboot." \
            "sudo systemctl enable ${present_units[0]}"
    fi

    if [[ $active_any -eq 0 ]]; then
        doctor_report warn "No installed ALSA restore unit is currently active." \
            "ALSA mixer state restore may not be running on this system." \
            "sudo systemctl start ${present_units[0]}"
    fi
}
