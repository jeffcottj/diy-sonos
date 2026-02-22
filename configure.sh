#!/usr/bin/env bash
# configure.sh — laptop-side wizard for DIY Sonos
# Collects server/client IPs and writes config.yml.
# Run with --copy-keys to set up SSH key auth on all target devices.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
_fmt() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
green()  { _fmt "32" "$*"; }
yellow() { _fmt "33" "$*"; }
bold()   { _fmt "1"  "$*"; }

# ---------------------------------------------------------------------------
# IP validation
# ---------------------------------------------------------------------------
validate_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    local -a octets=($ip)
    local octet
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Read existing config.yml values (bash-only, no pyyaml needed)
# ---------------------------------------------------------------------------
read_existing_config() {
    EXISTING_DEVICE_NAME=""
    EXISTING_SERVER_IP=""
    EXISTING_SSH_USER=""
    EXISTING_CLIENT_IPS=()

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return
    fi

    local in_clients=0
    while IFS= read -r line; do
        # Strip inline comments
        local stripped="${line%%#*}"

        # Top-level keys
        if [[ "$stripped" =~ ^ssh_user:[[:space:]]*\"?([^\"[:space:]]+)\"? ]]; then
            EXISTING_SSH_USER="${BASH_REMATCH[1]}"
        elif [[ "$stripped" =~ ^server_ip:[[:space:]]*\"?([^\"[:space:]]+)\"? ]]; then
            EXISTING_SERVER_IP="${BASH_REMATCH[1]}"
        fi

        # Spotify device_name (indented)
        if [[ "$stripped" =~ ^[[:space:]]+device_name:[[:space:]]*\"([^\"]+)\" ]]; then
            EXISTING_DEVICE_NAME="${BASH_REMATCH[1]}"
        elif [[ "$stripped" =~ ^[[:space:]]+device_name:[[:space:]]*([^[:space:]]+) ]]; then
            EXISTING_DEVICE_NAME="${BASH_REMATCH[1]}"
        fi

        # clients list
        if [[ "$stripped" =~ ^clients: ]]; then
            in_clients=1
            continue
        fi
        if (( in_clients )); then
            if [[ "$stripped" =~ ^[[:alpha:]] && ! "$stripped" =~ ^clients: ]]; then
                in_clients=0
            elif [[ "$stripped" =~ ^[[:space:]]*-[[:space:]]*ip:[[:space:]]*\"?([0-9.]+)\"? ]]; then
                EXISTING_CLIENT_IPS+=("${BASH_REMATCH[1]}")
            fi
        fi
    done < "$CONFIG_FILE"
}

# ---------------------------------------------------------------------------
# Prompt helper: show default in brackets, accept blank to keep default
# ---------------------------------------------------------------------------
prompt_with_default() {
    local prompt_text="$1"
    local default_val="$2"
    local result
    if [[ -n "$default_val" ]]; then
        read -r -p "$prompt_text [$default_val]: " result
        echo "${result:-$default_val}"
    else
        read -r -p "$prompt_text: " result
        echo "$result"
    fi
}

# ---------------------------------------------------------------------------
# write_config_yml
# ---------------------------------------------------------------------------
write_config_yml() {
    local device_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    shift 3
    local client_ips=("$@")

    # Build clients YAML block
    local clients_yaml=""
    for ip in "${client_ips[@]}"; do
        clients_yaml+="  - ip: \"${ip}\""$'\n'
    done

    cat > "$CONFIG_FILE" <<YAML
# ── Network ──────────────────────────────────────────────────────────────
ssh_user: "${ssh_user}"           # SSH username used by deploy.sh
server_ip: "${server_ip}"         # IP of the server device

clients:                          # Speaker client IPs; used by deploy.sh
${clients_yaml}
# ── Spotify ───────────────────────────────────────────────────────────────
spotify:
  device_name: "${device_name}"   # Name shown in Spotify app
  bitrate: 320                    # 96 | 160 | 320 kbps
  normalise: true                 # Volume normalisation
  initial_volume: 75              # 0-100
  cache_dir: "/var/cache/librespot"  # OAuth credential cache
  oauth_callback_port: 4000       # Local callback port used during OAuth
  device_type: "speaker"          # Icon shown in Spotify app

# ── Advanced ──────────────────────────────────────────────────────────────
snapserver:
  fifo_path: "/tmp/snapfifo"
  sampleformat: "44100:16:2"      # Must match librespot output
  codec: "flac"                   # flac | pcm
  buffer_ms: 1000                 # End-to-end latency target
  port: 1704
  control_port: 1780

snapclient:
  audio_device: "auto"            # "auto" = detect first USB audio card; or "hw:1,0" etc.
  latency_ms: 0                   # Per-client latency trim
  instance: 1
YAML
}

# ---------------------------------------------------------------------------
# --copy-keys mode
# ---------------------------------------------------------------------------
run_copy_keys() {
    read_existing_config

    local ssh_user="${EXISTING_SSH_USER:-pi}"
    local server_ip="${EXISTING_SERVER_IP:-}"
    local client_ips=("${EXISTING_CLIENT_IPS[@]+"${EXISTING_CLIENT_IPS[@]}"}")

    if [[ -z "$server_ip" && ${#client_ips[@]} -eq 0 ]]; then
        echo "No IPs found in config.yml. Run ./configure.sh first." >&2
        exit 1
    fi

    local all_ips=()
    [[ -n "$server_ip" ]] && all_ips+=("$server_ip")
    all_ips+=("${client_ips[@]+"${client_ips[@]}"}")

    echo "$(bold "Setting up SSH keys for all devices...")"
    echo "SSH user: $ssh_user"
    echo ""

    local ok=0 fail=0
    for ip in "${all_ips[@]}"; do
        printf "  ssh-copy-id %s@%s ... " "$ssh_user" "$ip"
        if ssh-copy-id -o StrictHostKeyChecking=no -o ConnectTimeout=10 "${ssh_user}@${ip}" 2>/dev/null; then
            echo "$(green "ok")"
            (( ok++ )) || true
        else
            echo "$(yellow "warning: failed (key may already be present or host unreachable)")"
            (( fail++ )) || true
        fi
    done

    echo ""
    echo "Done. $ok succeeded, $fail warning(s)."
    if (( fail > 0 )); then
        echo "Warnings are non-fatal — the key may already be in authorized_keys."
    fi
}

# ---------------------------------------------------------------------------
# Main wizard
# ---------------------------------------------------------------------------
run_wizard() {
    read_existing_config

    echo ""
    echo "$(bold "DIY Sonos — Setup Wizard")"
    echo ""

    # Device name
    local device_name
    device_name="$(prompt_with_default "Speaker system name (shown in Spotify)" "${EXISTING_DEVICE_NAME:-DIY Sonos}")"

    # Server IP
    local server_ip=""
    while true; do
        server_ip="$(prompt_with_default "Server device IP" "${EXISTING_SERVER_IP:-}")"
        if validate_ipv4 "$server_ip"; then
            break
        fi
        echo "  Invalid IP address. Please enter a valid IPv4 address (e.g. 192.168.1.100)."
    done

    # SSH user
    local ssh_user
    ssh_user="$(prompt_with_default "SSH username on each device" "${EXISTING_SSH_USER:-pi}")"

    # Client IPs
    echo ""
    echo "Enter client device IPs one at a time. Press Enter with no input when done."
    if [[ ${#EXISTING_CLIENT_IPS[@]} -gt 0 ]]; then
        echo "(Existing clients: ${EXISTING_CLIENT_IPS[*]})"
        echo "Leave blank and press Enter to keep existing list, or enter IPs to replace it."
    fi

    local client_ips=()
    local first_entry=1
    while true; do
        local ip
        read -r -p "  Client IP: " ip
        if [[ -z "$ip" ]]; then
            if [[ ${#client_ips[@]} -eq 0 && ${#EXISTING_CLIENT_IPS[@]} -gt 0 && $first_entry -eq 1 ]]; then
                # Keep existing list
                client_ips=("${EXISTING_CLIENT_IPS[@]}")
                break
            elif [[ ${#client_ips[@]} -eq 0 ]]; then
                echo "  At least one client IP is required."
                continue
            else
                break
            fi
        fi
        first_entry=0
        if validate_ipv4 "$ip"; then
            client_ips+=("$ip")
        else
            echo "  Invalid IP address. Please enter a valid IPv4 address."
        fi
    done

    # Summary
    echo ""
    echo "Configuration summary:"
    echo "  System name : $device_name"
    echo "  Server IP   : $server_ip"
    echo "  SSH user    : $ssh_user"
    echo "  Clients     : ${client_ips[*]}"
    echo ""

    local confirm
    read -r -p "Write config.yml? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted — config.yml not written."
        exit 0
    fi

    write_config_yml "$device_name" "$server_ip" "$ssh_user" "${client_ips[@]}"

    echo ""
    echo "$(green "✓") config.yml written."
    echo ""
    echo "Next steps:"
    echo "  1. Set up SSH keys:  ./configure.sh --copy-keys"
    echo "  2. Deploy:           ./deploy.sh"
    echo ""
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    --copy-keys)
        run_copy_keys
        ;;
    --help|-h)
        cat <<USAGE
Usage:
  ./configure.sh              Interactive wizard — writes config.yml
  ./configure.sh --copy-keys  Copy SSH keys to all target devices in config.yml
  ./configure.sh --help       Show this help
USAGE
        ;;
    "")
        run_wizard
        ;;
    *)
        echo "Unknown argument: $1" >&2
        echo "Run ./configure.sh --help for usage." >&2
        exit 1
        ;;
esac
