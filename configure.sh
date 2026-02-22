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
red()    { _fmt "31" "$*"; }

SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
KNOWN_HOSTS_FILE="$HOME/.ssh/known_hosts"

ensure_local_ssh_key() {
    if [[ -f "$SSH_KEY_PATH" ]]; then
        return 0
    fi

    echo "$(yellow "Local SSH key not found at $SSH_KEY_PATH")"
    read -r -p "Generate a new ed25519 key now? [Y/n]: " generate_choice
    generate_choice="${generate_choice:-Y}"

    if [[ "$generate_choice" =~ ^[Yy]$ ]]; then
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" >/dev/null
        echo "$(green "Generated SSH key: $SSH_KEY_PATH")"
        return 0
    fi

    echo "Please generate a key first: ssh-keygen -t ed25519 -f $SSH_KEY_PATH"
    return 1
}

classify_ssh_error() {
    local stderr_text="$1"

    if [[ "$stderr_text" == *"Permission denied"* ]]; then
        echo "auth_failed"
    elif [[ "$stderr_text" == *"No route to host"* ]] || [[ "$stderr_text" == *"Connection timed out"* ]] || [[ "$stderr_text" == *"Connection refused"* ]] || [[ "$stderr_text" == *"Could not resolve hostname"* ]]; then
        echo "host_unreachable"
    elif [[ "$stderr_text" == *"Host key verification failed"* ]] || [[ "$stderr_text" == *"REMOTE HOST IDENTIFICATION HAS CHANGED"* ]]; then
        echo "host_key_issue"
    else
        echo "unknown"
    fi
}

print_ssh_fix_hint() {
    local host="$1"
    local ssh_user="$2"
    local reason="$3"

    case "$reason" in
        auth_failed)
            echo "    Fix: verify credentials and push key manually:"
            echo "         ssh-copy-id ${ssh_user}@${host}"
            ;;
        host_unreachable)
            echo "    Fix: verify host is online and SSH is enabled:"
            echo "         ping -c 1 ${host}"
            echo "         ssh ${ssh_user}@${host}"
            ;;
        host_key_issue)
            echo "    Fix: remove stale host key and retry:"
            echo "         ssh-keygen -R ${host}"
            echo "         ssh-keyscan -H ${host} >> ~/.ssh/known_hosts"
            ;;
        *)
            echo "    Fix: run verbose SSH check: ssh -vv ${ssh_user}@${host}"
            ;;
    esac
}

ensure_host_key_trusted() {
    local host="$1"

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    touch "$KNOWN_HOSTS_FILE"
    chmod 600 "$KNOWN_HOSTS_FILE"

    if ssh-keygen -F "$host" -f "$KNOWN_HOSTS_FILE" >/dev/null; then
        return 0
    fi

    local scan_out
    if ! scan_out="$(ssh-keyscan -T 5 -H "$host" 2>/dev/null)" || [[ -z "$scan_out" ]]; then
        echo "$(red "Could not fetch SSH host key for $host via ssh-keyscan")"
        return 1
    fi

    local fingerprint
    fingerprint="$(printf '%s\n' "$scan_out" | ssh-keygen -lf - 2>/dev/null | awk 'NR==1{print $2}')"

    echo "Host $host is new."
    echo "  Fingerprint: ${fingerprint:-unknown}"
    read -r -p "Trust this host key and add to known_hosts? [y/N]: " trust_choice
    if [[ ! "$trust_choice" =~ ^[Yy]$ ]]; then
        echo "Skipped host $host (untrusted host key)."
        return 1
    fi

    printf '%s\n' "$scan_out" >> "$KNOWN_HOSTS_FILE"
    echo "Added host key for $host to $KNOWN_HOSTS_FILE"
}

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
    EXISTING_SERVER_SSH_USER=""
    EXISTING_CLIENT_IPS=()
    declare -gA EXISTING_CLIENT_SSH_USERS=()

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return
    fi

    local in_clients=0
    local current_client_ip=""
    while IFS= read -r line; do
        # Strip inline comments
        local stripped="${line%%#*}"

        # Top-level keys
        if [[ "$stripped" =~ ^ssh_user:[[:space:]]*\"?([^\"[:space:]]+)\"? ]]; then
            EXISTING_SSH_USER="${BASH_REMATCH[1]}"
            if [[ -z "$EXISTING_SERVER_SSH_USER" ]]; then
                EXISTING_SERVER_SSH_USER="${BASH_REMATCH[1]}"
            fi
        elif [[ "$stripped" =~ ^server_ip:[[:space:]]*\"?([^\"[:space:]]+)\"? ]]; then
            EXISTING_SERVER_IP="${BASH_REMATCH[1]}"
        elif [[ "$stripped" =~ ^server:[[:space:]]*$ ]]; then
            in_clients=0
        elif [[ "$stripped" =~ ^[[:space:]]+ssh_user:[[:space:]]*\"?([^\"[:space:]]+)\"? ]] && [[ -z "$current_client_ip" ]]; then
            EXISTING_SERVER_SSH_USER="${BASH_REMATCH[1]}"
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
                current_client_ip=""
            elif [[ "$stripped" =~ ^[[:space:]]*-[[:space:]]*ip:[[:space:]]*\"?([0-9.]+)\"? ]]; then
                EXISTING_CLIENT_IPS+=("${BASH_REMATCH[1]}")
                current_client_ip="${BASH_REMATCH[1]}"
            elif [[ -n "$current_client_ip" ]] && [[ "$stripped" =~ ^[[:space:]]+ssh_user:[[:space:]]*\"?([^\"[:space:]]+)\"? ]]; then
                EXISTING_CLIENT_SSH_USERS["$current_client_ip"]="${BASH_REMATCH[1]}"
            fi
        fi
    done < "$CONFIG_FILE"

    if [[ -z "$EXISTING_SERVER_SSH_USER" ]]; then
        EXISTING_SERVER_SSH_USER="${EXISTING_SSH_USER:-pi}"
    fi
}

ssh_user_for_host() {
    local host_ip="$1"
    if [[ "$host_ip" == "$EXISTING_SERVER_IP" ]]; then
        echo "${EXISTING_SERVER_SSH_USER:-${EXISTING_SSH_USER:-pi}}"
        return
    fi
    echo "${EXISTING_CLIENT_SSH_USERS[$host_ip]:-${EXISTING_SSH_USER:-pi}}"
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

prompt_non_empty_with_default() {
    local prompt_text="$1"
    local default_val="$2"
    local value
    while true; do
        value="$(prompt_with_default "$prompt_text" "$default_val")"
        if [[ -n "$value" ]]; then
            echo "$value"
            return 0
        fi
        echo "  Value is required. Please enter a non-empty value."
    done
}

prompt_ipv4_with_default() {
    local prompt_text="$1"
    local default_val="$2"
    local value
    while true; do
        value="$(prompt_with_default "$prompt_text" "$default_val")"
        if validate_ipv4 "$value"; then
            echo "$value"
            return 0
        fi
        echo "  Invalid IP address. Please enter a valid IPv4 address (e.g. 192.168.1.100)."
    done
}

choose_profile_preset() {
    local default_choice="1"
    echo "Choose speaker tuning preset for this system:" >&2
    echo "  1) Basic home setup (recommended first install)" >&2
    echo "  2) Advanced tuning (higher bitrate/lower buffer)" >&2
    echo "  Enter 1 or 2, or press Enter to accept the default (1)." >&2
    while true; do
        local choice
        read -r -p "Preset number [${default_choice}]: " choice
        choice="${choice:-$default_choice}"
        case "$choice" in
            1)
                echo "basic"
                return 0
                ;;
            2)
                echo "advanced"
                return 0
                ;;
            *)
                echo "  Please enter 1 or 2."
                ;;
        esac
    done
}

collect_client_ips() {
    local -n _existing_ref=$1
    local -a collected=()
    local first_entry=1

    echo "" >&2
    echo "Add each speaker client device." >&2
    echo "Enter client device IPs one at a time. Press Enter with no input when done." >&2
    if [[ ${#_existing_ref[@]} -gt 0 ]]; then
        echo "(Existing clients: ${_existing_ref[*]})" >&2
        echo "Leave blank and press Enter to keep existing list, or enter IPs to replace it." >&2
    fi

    while true; do
        local ip
        read -r -p "  Client IP: " ip

        if [[ -z "$ip" ]]; then
            if [[ ${#collected[@]} -eq 0 && ${#_existing_ref[@]} -gt 0 && $first_entry -eq 1 ]]; then
                collected=("${_existing_ref[@]}")
                break
            elif [[ ${#collected[@]} -eq 0 ]]; then
                echo "  At least one client IP is required." >&2
                continue
            else
                break
            fi
        fi
        first_entry=0

        if ! validate_ipv4 "$ip"; then
            echo "  Invalid IP address. Please enter a valid IPv4 address." >&2
            continue
        fi

        local existing
        for existing in "${collected[@]}"; do
            if [[ "$existing" == "$ip" ]]; then
                echo "  Duplicate client IP: $ip (already added)." >&2
                continue 2
            fi
        done

        collected+=("$ip")
    done

    printf '%s\n' "${collected[@]}"
}

print_summary_conflicts() {
    local server_ip="$1"
    shift
    local client_ips=("$@")
    local has_conflict=0

    if [[ ${#client_ips[@]} -eq 0 ]]; then
        echo "  - Conflict: client IP list is empty."
        has_conflict=1
    fi

    declare -A seen=()
    local ip
    for ip in "${client_ips[@]}"; do
        if [[ -z "$ip" ]]; then
            echo "  - Conflict: empty client IP detected."
            has_conflict=1
            continue
        fi
        if [[ -n "${seen[$ip]:-}" ]]; then
            echo "  - Conflict: duplicate client IP detected: $ip"
            has_conflict=1
        fi
        seen[$ip]=1
    done

    if [[ -n "${seen[$server_ip]:-}" ]]; then
        echo "  - Note: server IP ($server_ip) is also listed as a client IP (server+client mode)."
    fi

    return $has_conflict
}

# ---------------------------------------------------------------------------
# write_config_yml
# ---------------------------------------------------------------------------
write_config_yml() {
    local device_name="$1"
    local server_ip="$2"
    local ssh_user="$3"
    local profile_preset="$4"
    shift 4
    local client_ips=("$@")

    local bitrate="160"
    local normalise="true"
    local initial_volume="70"
    local codec="flac"
    local buffer_ms="1200"
    local latency_ms="0"

    if [[ "$profile_preset" == "advanced" ]]; then
        bitrate="320"
        initial_volume="75"
        codec="pcm"
        buffer_ms="800"
        latency_ms="-20"
    fi

    # Build clients YAML block
    local clients_yaml=""
    for ip in "${client_ips[@]}"; do
        local client_user="${CLIENT_SSH_USERS[$ip]:-$ssh_user}"
        clients_yaml+="  - ip: \"${ip}\""$'\n'
        clients_yaml+="    ssh_user: \"${client_user}\""$'\n'
    done

    cat > "$CONFIG_FILE" <<YAML
# ── Network ──────────────────────────────────────────────────────────────
ssh_user: "${ssh_user}"           # SSH username used by deploy.sh
server_ip: "${server_ip}"         # IP of the server device
server:
  ip: "${server_ip}"
  ssh_user: "${ssh_user}"

clients:                          # Speaker client IPs; used by deploy.sh
${clients_yaml}
# ── Spotify ───────────────────────────────────────────────────────────────
spotify:
  device_name: "${device_name}"   # Name shown in Spotify app
  bitrate: ${bitrate}                    # 96 | 160 | 320 kbps
  normalise: ${normalise}                 # Volume normalisation
  initial_volume: ${initial_volume}              # 0-100
  cache_dir: "/var/cache/librespot"  # OAuth credential cache
  oauth_callback_port: 4000       # Local callback port used during OAuth
  device_type: "speaker"          # Icon shown in Spotify app

# ── Advanced ──────────────────────────────────────────────────────────────
profile_preset: "${profile_preset}"   # basic | advanced

snapserver:
  fifo_path: "/tmp/snapfifo"
  sampleformat: "44100:16:2"      # Must match librespot output
  codec: "${codec}"                   # flac | pcm
  buffer_ms: ${buffer_ms}                 # End-to-end latency target
  port: 1704
  control_port: 1780

snapclient:
  audio_device: "auto"            # "auto" = detect first USB audio card; or "hw:1,0" etc.
  latency_ms: ${latency_ms}                   # Per-client latency trim
  instance: 1
YAML
}

# ---------------------------------------------------------------------------
# --copy-keys mode
# ---------------------------------------------------------------------------
run_copy_keys() {
    read_existing_config

    local default_ssh_user="${EXISTING_SSH_USER:-pi}"
    local server_ip="${EXISTING_SERVER_IP:-}"
    local client_ips=("${EXISTING_CLIENT_IPS[@]+"${EXISTING_CLIENT_IPS[@]}"}")

    if [[ -z "$server_ip" && ${#client_ips[@]} -eq 0 ]]; then
        echo "No IPs found in config.yml. Run ./configure.sh first." >&2
        exit 1
    fi

    local all_ips=()
    [[ -n "$server_ip" ]] && all_ips+=("$server_ip")
    all_ips+=("${client_ips[@]+"${client_ips[@]}"}")

    ensure_local_ssh_key

    echo "$(bold "Setting up SSH keys for all devices...")"
    echo "Default SSH user: $default_ssh_user"
    echo ""

    local ok=0 fail=0
    for ip in "${all_ips[@]}"; do
        local ssh_user
        ssh_user="$(ssh_user_for_host "$ip")"
        if ! ensure_host_key_trusted "$ip"; then
            (( fail++ )) || true
            continue
        fi

        printf "  ssh-copy-id %s@%s ... " "$ssh_user" "$ip"
        local err_file
        err_file="$(mktemp)"
        if ssh-copy-id -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "${ssh_user}@${ip}" 2>"$err_file"; then
            echo "$(green "ok")"
            (( ok++ )) || true
        else
            echo "$(red "FAILED")"
            local err_text reason
            err_text="$(<"$err_file")"
            reason="$(classify_ssh_error "$err_text")"
            echo "    Reason: $reason"
            print_ssh_fix_hint "$ip" "$ssh_user" "$reason"
            (( fail++ )) || true
        fi
        rm -f "$err_file"
    done

    echo ""
    echo "Done. $ok succeeded, $fail warning(s)."
    if (( fail > 0 )); then
        echo "Warnings are non-fatal — the key may already be in authorized_keys."
    fi
}

run_diagnose_ssh() {
    read_existing_config

    local default_ssh_user="${EXISTING_SSH_USER:-pi}"
    local server_ip="${EXISTING_SERVER_IP:-}"
    local client_ips=("${EXISTING_CLIENT_IPS[@]+"${EXISTING_CLIENT_IPS[@]}"}")

    if [[ -z "$server_ip" && ${#client_ips[@]} -eq 0 ]]; then
        echo "No IPs found in config.yml. Run ./configure.sh first." >&2
        exit 1
    fi

    local all_ips=()
    [[ -n "$server_ip" ]] && all_ips+=("$server_ip")
    all_ips+=("${client_ips[@]+"${client_ips[@]}"}")

    ensure_local_ssh_key || true

    echo "$(bold "SSH diagnostics")"
    echo "Default user: $default_ssh_user"
    echo ""

    local failures=0
    for ip in "${all_ips[@]}"; do
        local ssh_user
        ssh_user="$(ssh_user_for_host "$ip")"
        echo "$(bold "Host: $ip")"
        echo "  SSH user: $ssh_user"

        if ! ensure_host_key_trusted "$ip"; then
            echo "  $(red "Host key check failed")"
            echo "  Fix: ssh-keyscan -H $ip >> ~/.ssh/known_hosts"
            (( failures++ )) || true
            echo ""
            continue
        fi

        local err_file
        err_file="$(mktemp)"
        if ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "${ssh_user}@${ip}" true 2>"$err_file"; then
            echo "  $(green "SSH ok")"
        else
            local err_text reason
            err_text="$(<"$err_file")"
            reason="$(classify_ssh_error "$err_text")"
            echo "  $(red "SSH failed") — $reason"
            print_ssh_fix_hint "$ip" "$ssh_user" "$reason"
            (( failures++ )) || true
        fi
        rm -f "$err_file"
        echo ""
    done

    if (( failures > 0 )); then
        echo "$(yellow "Diagnostics complete with $failures host(s) requiring fixes.")"
        exit 1
    fi

    echo "$(green "All hosts passed SSH diagnostics.")"
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
    device_name="$(prompt_non_empty_with_default "Speaker system name (shown in Spotify)" "${EXISTING_DEVICE_NAME:-DIY Sonos}")"

    # Profile preset
    local profile_preset
    profile_preset="$(choose_profile_preset)"

    # Server IP
    local server_ip=""
    server_ip="$(prompt_ipv4_with_default "Server device IP" "${EXISTING_SERVER_IP:-}")"

    # SSH user
    local ssh_user
    ssh_user="$(prompt_non_empty_with_default "Server SSH username (for ${server_ip})" "${EXISTING_SERVER_SSH_USER:-pi}")"

    # Client IPs
    local client_ips=()
    mapfile -t client_ips < <(collect_client_ips EXISTING_CLIENT_IPS)
    declare -gA CLIENT_SSH_USERS=()
    local client_ip
    for client_ip in "${client_ips[@]}"; do
        CLIENT_SSH_USERS["$client_ip"]="$(prompt_non_empty_with_default "SSH username for client ${client_ip}" "${EXISTING_CLIENT_SSH_USERS[$client_ip]:-$ssh_user}")"
    done

    while true; do
        echo ""
        echo "Configuration summary:"
        echo "  System name : $device_name"
        echo "  Preset      : $profile_preset"
        echo "  Server IP   : $server_ip"
        echo "  Server SSH  : $ssh_user"
        echo "  Clients     : ${client_ips[*]}"
        for client_ip in "${client_ips[@]}"; do
            echo "    - ${client_ip} (ssh user: ${CLIENT_SSH_USERS[$client_ip]})"
        done
        echo ""
        echo "Conflict checks:"
        if print_summary_conflicts "$server_ip" "${client_ips[@]}"; then
            echo "  No conflicts detected."
        else
            echo ""
            echo "Please resolve the conflicts before writing config.yml."
        fi

        echo ""
        echo "Review/edit options:"
        echo "  1) Device name"
        echo "  2) Preset"
        echo "  3) Server IP"
        echo "  4) Server SSH user"
        echo "  5) Client IPs"
        echo "  6) Client SSH users"
        echo "  7) Continue"
        local edit_choice
        read -r -p "Select option [7]: " edit_choice
        edit_choice="${edit_choice:-7}"

        case "$edit_choice" in
            1) device_name="$(prompt_non_empty_with_default "Speaker system name (shown in Spotify)" "$device_name")" ;;
            2) profile_preset="$(choose_profile_preset)" ;;
            3) server_ip="$(prompt_ipv4_with_default "Server device IP" "$server_ip")" ;;
            4) ssh_user="$(prompt_non_empty_with_default "Server SSH username (for ${server_ip})" "$ssh_user")" ;;
            5)
                mapfile -t client_ips < <(collect_client_ips client_ips)
                for client_ip in "${client_ips[@]}"; do
                    CLIENT_SSH_USERS["$client_ip"]="$(prompt_non_empty_with_default "SSH username for client ${client_ip}" "${CLIENT_SSH_USERS[$client_ip]:-$ssh_user}")"
                done
                ;;
            6)
                for client_ip in "${client_ips[@]}"; do
                    CLIENT_SSH_USERS["$client_ip"]="$(prompt_non_empty_with_default "SSH username for client ${client_ip}" "${CLIENT_SSH_USERS[$client_ip]:-$ssh_user}")"
                done
                ;;
            7)
                if print_summary_conflicts "$server_ip" "${client_ips[@]}"; then
                    break
                fi
                ;;
            *) echo "  Invalid option. Please choose 1-7." ;;
        esac

        if [[ "$edit_choice" == "7" ]] && ! print_summary_conflicts "$server_ip" "${client_ips[@]}"; then
            echo "Cannot continue until conflicts are resolved."
        fi
    done

    local confirm
    read -r -p "Write config.yml? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "Aborted — config.yml not written."
        exit 0
    fi

    write_config_yml "$device_name" "$server_ip" "$ssh_user" "$profile_preset" "${client_ips[@]}"

    echo ""
    echo "$(green "✓") config.yml written."
    echo ""
    echo "Running advisory preflight validation (no install changes)..."

    if ./setup.sh preflight server --advisory; then
        echo "  Server preflight advisory: OK"
    else
        echo "  Server preflight advisory: reported issues"
    fi

    if ./setup.sh preflight client --advisory; then
        echo "  Client preflight advisory: OK"
    else
        echo "  Client preflight advisory: reported issues"
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Review any advisory preflight warnings above."
    echo "  2. Set up SSH keys:  ./configure.sh --copy-keys"
    echo "  3. Deploy:           ./deploy.sh"
    echo ""
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-}" in
    --copy-keys)
        run_copy_keys
        ;;
    --diagnose-ssh)
        run_diagnose_ssh
        ;;
    --help|-h)
        cat <<USAGE
Usage:
  ./configure.sh              Interactive wizard — writes config.yml
  ./configure.sh --copy-keys  Copy SSH keys to all target devices in config.yml
  ./configure.sh --diagnose-ssh Diagnose SSH connectivity to all configured devices
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
