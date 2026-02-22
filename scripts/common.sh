#!/usr/bin/env bash
# common.sh — shared functions for DIY Sonos setup scripts
# Sourced by setup.sh; do not execute directly.

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

    if dpkg -s "$pkg_name" &>/dev/null; then
        local installed_ver
        installed_ver="$(dpkg -s "$pkg_name" | grep '^Version:' | awk '{print $2}')"
        if [[ "$installed_ver" == *"$pkg_ver"* ]]; then
            echo "$pkg_name $pkg_ver already installed, skipping"
            return 0
        fi
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
download_file() {
    local url="$1"
    local dest="$2"
    if [[ -f "$dest" ]]; then
        echo "File already downloaded: $dest"
    else
        wget -q --show-progress -O "$dest" "$url"
    fi
}

# ---------------------------------------------------------------------------
# ALSA / audio device detection
# ---------------------------------------------------------------------------

# detect_alsa_usb_device
# Finds the first USB audio card from `aplay -l` and sets DETECTED_AUDIO_DEVICE.
# Falls back to "default" if none found.
detect_alsa_usb_device() {
    local card_num
    card_num=$(aplay -l 2>/dev/null | awk '
        /^card [0-9]+:/ {
            card = $2
            sub(/:$/, "", card)
        }
        /USB/ {
            if (card != "") { print card; exit }
        }
    ')

    if [[ -n "$card_num" ]]; then
        DETECTED_AUDIO_DEVICE="hw:${card_num},0"
        echo "Detected USB audio device: $DETECTED_AUDIO_DEVICE"
    else
        DETECTED_AUDIO_DEVICE="default"
        echo "No USB audio device found, using 'default'"
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
# Template rendering
# ---------------------------------------------------------------------------

# render_template <tmpl_file> <output_file>
# Substitutes {{VAR}} placeholders with the current value of $VAR from the environment.
render_template() {
    local tmpl="$1"
    local out="$2"
    python3 - "$tmpl" "$out" <<'PYEOF'
import sys, os, re

tmpl_path, out_path = sys.argv[1], sys.argv[2]

with open(tmpl_path) as f:
    content = f.read()

def replace(m):
    var = m.group(1)
    val = os.environ.get(var)
    if val is None:
        # Try with double-underscore section prefix already uppercased
        raise KeyError(f"Template variable not found in environment: {var}")
    return val

content = re.sub(r'\{\{([A-Z0-9_]+)\}\}', replace, content)

with open(out_path, 'w') as f:
    f.write(content)

print(f"Rendered: {tmpl_path} -> {out_path}")
PYEOF
}

# ---------------------------------------------------------------------------
# systemd helpers
# ---------------------------------------------------------------------------

# systemd_enable_restart <service>
# Reloads daemon, enables and starts (or restarts) a systemd service.
systemd_enable_restart() {
    local svc="$1"
    systemctl daemon-reload
    systemctl enable "$svc"
    if systemctl is-active --quiet "$svc"; then
        systemctl restart "$svc"
        echo "Restarted: $svc"
    else
        systemctl start "$svc"
        echo "Started: $svc"
    fi
}
