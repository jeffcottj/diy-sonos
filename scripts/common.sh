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
    while IFS= read -r -d '' var_name && IFS= read -r -d '' var_value; do
        export "$var_name=$var_value"
    done < <(python3 - "$yaml_file" <<'PYEOF'
import sys, yaml, re

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

if data is None:
    data = {}

for k, v in flatten(data).items():
    shell_name = k.upper().replace("-", "_")
    if not re.match(r'^[A-Z0-9_]+$', shell_name):
        print(f"Warning: skipping invalid variable name: {shell_name}", file=sys.stderr)
        continue
    if v is None:
        v = ""
    elif isinstance(v, bool):
        v = "true" if v else "false"
    sys.stdout.buffer.write((shell_name + "\0" + str(v) + "\0").encode())
PYEOF
)
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
    local -a octets
    read -ra octets <<< "$value"
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

# prompt_output_volume <prompt_text> <default_val>
# Prompts for a volume 0-100 with validation loop; echoes valid value.
prompt_output_volume() {
    local prompt_text="$1"
    local default_val="$2"
    local value
    while true; do
        if [[ -n "$default_val" ]]; then
            read -r -p "$prompt_text [$default_val]: " value
            value="${value:-$default_val}"
        else
            read -r -p "$prompt_text: " value
        fi
        if validate_snapclient_output_volume "$value"; then
            echo "$value"
            return 0
        fi
    done
}

# get_client_output_volume_for_ip <ip>
# Returns per-client output_volume for given IP from config (base + generated override), if present.
get_client_output_volume_for_ip() {
    local query_ip="$1"
    local base_yaml="${DEFAULT_CONFIG:-$SCRIPT_DIR/config.yml}"
    local gen_yaml="${GENERATED_CONFIG:-$SCRIPT_DIR/.diy-sonos.generated.yml}"
    python3 - "$query_ip" "$base_yaml" "$gen_yaml" 2>/dev/null <<'PYEOF'
import sys, os
try:
    import yaml
except ImportError:
    sys.exit(0)
query_ip = sys.argv[1]
base_yaml = sys.argv[2]
gen_yaml = sys.argv[3]

def load_yaml(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = yaml.safe_load(f)
            return data or {}
    except Exception:
        return {}

data = load_yaml(base_yaml)
if gen_yaml and os.path.exists(gen_yaml):
    gen_data = load_yaml(gen_yaml)
    if 'clients' in gen_data and gen_data['clients'] is not None:
        data['clients'] = gen_data['clients']
    if 'snapclient' in gen_data and isinstance(gen_data['snapclient'], dict) and 'output_volume' in gen_data['snapclient']:
        if 'snapclient' not in data or not isinstance(data['snapclient'], dict):
            data['snapclient'] = {}
        data['snapclient']['output_volume'] = gen_data['snapclient']['output_volume']

vol = ""
for entry in data.get('clients', []) or []:
    if isinstance(entry, dict) and str(entry.get('ip', '')).strip() == query_ip:
        v = entry.get('output_volume')
        if v is not None:
            vol = str(v).strip()
            break
if vol:
    print(vol)
PYEOF
}

# get_effective_snapclient_output_volume
# Resolves per-client output_volume for this host if configured, else global snapclient.output_volume.
# Prints effective volume (0-100) and returns 0.
get_effective_snapclient_output_volume() {
    local global_vol
    global_vol="$(cfg snapclient output_volume 90)"
    if ! validate_snapclient_output_volume "$global_vol" 2>/dev/null; then
        global_vol="90"
    fi
    local effective="$global_vol"
    local local_ips
    local_ips="$(hostname -I 2>/dev/null || true)"
    if command -v ip >/dev/null 2>&1; then
        local_ips+=" $(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | tr '\n' ' ')"
    fi
    local ip
    for ip in $local_ips; do
        [[ "$ip" == 127.* ]] && continue
        [[ -z "$ip" ]] && continue
        local per_vol
        per_vol="$(get_client_output_volume_for_ip "$ip" 2>/dev/null || true)"
        if [[ -n "$per_vol" ]] && validate_snapclient_output_volume "$per_vol" 2>/dev/null; then
            effective="$per_vol"
            break
        fi
    done
    echo "$effective"
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
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/${filename}.XXXXXX")"

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

    local stamp_file="/var/lib/diy-sonos/installed-debs/${pkg_name}"
    local stamp_content=""
    if [[ -f "$stamp_file" ]]; then
        stamp_content="$(cat "$stamp_file" 2>/dev/null || true)"
    fi

    echo "install_deb: pkg_name=$pkg_name installed_ver=${installed_ver:-<not-installed>} pkg_ver=$pkg_ver stamp=${stamp_content:-<none>}"
    if [[ -n "$installed_ver" && "$installed_ver" == "$pkg_ver" ]]; then
        # Idempotent fast-path: already at target version, even if stamp is missing/mismatched
        # (stamp mismatch happens after OS upgrade, manual install, or first-runs before stamp was introduced).
        if [[ "$stamp_content" == "$filename" ]]; then
            echo "install_deb: decision=skip (installed version and stamp match repo package exactly)"
        else
            echo "install_deb: decision=skip (installed version $installed_ver matches target $pkg_ver; updating stamp from '${stamp_content:-<none>}' to '$filename')"
        fi
        mkdir -p "$(dirname "$stamp_file")"
        echo "$filename" > "$stamp_file"
        rm -f "$tmp"
        return 0
    fi
    if [[ -n "$installed_ver" ]]; then
        echo "install_deb: decision=install (installed version $installed_ver differs from target $pkg_ver)"
    else
        echo "install_deb: decision=install (package not currently installed)"
    fi

    echo "Downloading $filename..."
    if ! download_file "$url" "$tmp"; then
        # Fallback for distro codename specific debs (e.g. snapcast has no trixie build yet;
        # bookworm debs work on trixie). Try alternative codenames before giving up.
        if [[ "$filename" == *"_${OS_CODENAME:-}.deb" ]]; then
            local fallback_codename
            for fallback_codename in bookworm bullseye; do
                [[ "$fallback_codename" == "${OS_CODENAME:-}" ]] && continue
                local fallback_filename="${filename/_${OS_CODENAME}.deb/_${fallback_codename}.deb}"
                local fallback_url="${url/_${OS_CODENAME}.deb/_${fallback_codename}.deb}"
                [[ "$fallback_filename" == "$filename" ]] && continue
                echo "Primary deb not found for $OS_CODENAME; trying fallback codename '$fallback_codename': $fallback_filename" >&2
                local fallback_tmp
                fallback_tmp="$(mktemp "${TMPDIR:-/tmp}/${fallback_filename}.XXXXXX")"
                if download_file "$fallback_url" "$fallback_tmp"; then
                    echo "Installing fallback $fallback_filename..."
                    if dpkg -i "$fallback_tmp"; then
                        apt-get install -f -y
                        rm -f "$fallback_tmp" "$tmp"
                        mkdir -p "$(dirname "$stamp_file")"
                        echo "$fallback_filename" > "$stamp_file"
                        echo "Installed fallback deb for $fallback_codename: $fallback_filename"
                        return 0
                    fi
                    rm -f "$fallback_tmp"
                else
                    rm -f "$fallback_tmp"
                    echo "Fallback $fallback_codename also not available: $fallback_url" >&2
                fi
            done
        fi
        # Final check: if version now matches (race or fallback installed), succeed
        local recheck_ver=""
        if dpkg -s "$pkg_name" &>/dev/null; then
            recheck_ver="$(dpkg -s "$pkg_name" | awk '/^Version:/ {print $2}')"
        fi
        if [[ -n "$recheck_ver" && "$recheck_ver" == "$pkg_ver" ]]; then
            echo "Warning: failed to download $filename but $pkg_name $recheck_ver is already installed; continuing" >&2
            mkdir -p "$(dirname "$stamp_file")"
            echo "$filename" > "$stamp_file"
            rm -f "$tmp"
            return 0
        fi
        rm -f "$tmp"
        return 1
    fi
    echo "Installing $filename..."
    if ! dpkg -i "$tmp"; then
        echo "Error: dpkg -i failed for $filename" >&2
        rm -f "$tmp"
        return 1
    fi
    if ! apt-get install -f -y; then
        echo "Error: apt-get install -f failed after installing $filename" >&2
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"
    mkdir -p "$(dirname "$stamp_file")"
    echo "$filename" > "$stamp_file"
}
# ---------------------------------------------------------------------------
# File / FIFO helpers
# ---------------------------------------------------------------------------

# ensure_fifo <path>
# Creates a named pipe (FIFO) if it doesn't already exist.
ensure_fifo() {
    local path="$1"
    local dir
    dir="$(dirname "$path")"
    mkdir -p "$dir"
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
# Downloads a file to dest.
# Removes partial file on failure.
download_file() {
    local url="$1"
    local dest="$2"
    if ! wget -q --show-progress --timeout=60 -O "$dest" "$url"; then
        rm -f "$dest"
        echo "Error: failed to download $url" >&2
        return 1
    fi
}

fifo_requires_protected_sysctl() {
    local p="$1"
    [[ "$p" == /tmp/* || "$p" == /var/tmp/* ]]
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

# render_template_if_changed <tmpl_file> <output_file>
# Like render_template but skips the write if the rendered content is identical
# to the existing file. Returns 0 if the file was written (new or changed),
# 1 if unchanged (no write, no side effects).
render_template_if_changed() {
    local tmpl="$1"
    local out="$2"
    local tmp
    tmp="$(mktemp "$(dirname "$out")/.render.XXXXXX")"
    if ! python3 - "$tmpl" "$tmp" <<'PYEOF'
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
    then
        rm -f "$tmp"
        return 1
    fi
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
