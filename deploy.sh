#!/usr/bin/env bash
# deploy.sh — laptop-side orchestrator for DIY Sonos
# Rsyncs this repo to all target devices, runs setup, surfaces OAuth URL, prints summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"
# shellcheck disable=SC2088
REMOTE_DIR="~/diy-sonos"

SSH_OPTS=(-o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o BatchMode=yes)
# shellcheck disable=SC2034
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
# shellcheck disable=SC2034
KNOWN_HOSTS_FILE="$HOME/.ssh/known_hosts"

source "$SCRIPT_DIR/scripts/lib/ssh.sh"

# ---------------------------------------------------------------------------
# Parse config.yml via inline Python (no pyyaml needed on laptop)
# ---------------------------------------------------------------------------
parse_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "config.yml not found. Run ./configure.sh first." >&2
        exit 1
    fi

    local parsed
    parsed="$(python3 "$SCRIPT_DIR/scripts/parse-network-config.py" "$CONFIG_FILE")"

    SERVER_IP=""
    SSH_USER="pi"
    SERVER_SSH_USER="pi"
    SPOTIFY_DEVICE_NAME="DIY Sonos"
    CLIENT_IPS=()
    declare -gA CLIENT_SSH_USERS=()

    while IFS='=' read -r key val; do
        case "$key" in
            SERVER_IP)  SERVER_IP="$val" ;;
            SSH_USER)   SSH_USER="$val" ;;
            SERVER_SSH_USER) SERVER_SSH_USER="$val" ;;
            SPOTIFY_DEVICE_NAME) SPOTIFY_DEVICE_NAME="$val" ;;
            CLIENT)
                local ip="${val%%|*}"
                local user="${val#*|}"
                CLIENT_IPS+=("$ip")
                CLIENT_SSH_USERS["$ip"]="$user"
                ;;
        esac
    done <<< "$parsed"

    if [[ -z "$SERVER_IP" ]]; then
        echo "server_ip is missing or empty in config.yml. Run ./configure.sh first." >&2
        exit 1
    fi

    if [[ ${#CLIENT_IPS[@]} -eq 0 ]]; then
        echo "No clients found in config.yml. Run ./configure.sh first." >&2
        exit 1
    fi
}

server_diagnostics() {
    local remote_cmd
    remote_cmd=$(cat <<'EOF'
set -e
cd ~/diy-sonos

echo ""
echo "━━ Server runtime diagnostics ━━"

echo "  Spotify auth cache status:"
sudo librespot-auth-helper verify-auth-cache /var/cache/librespot || true
echo ""

echo "  Service state snapshot:"
sudo systemctl --no-pager --full status librespot snapserver avahi-daemon 2>/dev/null || true
echo ""

echo "  Doctor check (server):"
if sudo ./setup.sh doctor server; then
  echo "  ✓ Doctor passed"
else
  echo "  ✗ Doctor reported failures"
fi
EOF
)

    ssh "${SSH_OPTS[@]}" "$(ssh_user_for_host "$SERVER_IP")@${SERVER_IP}" "$remote_cmd"
}

ssh_user_for_host() {
    local host="$1"
    if [[ "$host" == "$SERVER_IP" ]]; then
        echo "$SERVER_SSH_USER"
        return
    fi
    echo "${CLIENT_SSH_USERS[$host]:-$SSH_USER}"
}

# ---------------------------------------------------------------------------
# Pre-flight: verify SSH connectivity for all hosts
# ---------------------------------------------------------------------------
run_preflight() {
    echo "$(bold "Pre-flight: checking SSH connectivity...")"
    local all_hosts=("$SERVER_IP" "${CLIENT_IPS[@]}")
    local failed_hosts=()

    ensure_local_ssh_key || true

    for host in "${all_hosts[@]}"; do
        local ssh_user
        ssh_user="$(ssh_user_for_host "$host")"
        printf "  %-20s" "$host"

        if ! ensure_host_key_trusted "$host"; then
            failed_hosts+=("$host")
            continue
        fi

        local err_file
        err_file="$(mktemp)"
        if ssh "${SSH_OPTS[@]}" "${ssh_user}@${host}" true 2>"$err_file"; then
            echo "$(green "ok")"
        else
            echo "$(red "FAILED")"
            local err_text reason
            err_text="$(<"$err_file")"
            reason="$(classify_ssh_error "$err_text")"
            echo "    Reason: $reason"
            print_ssh_fix_hint "$host" "$ssh_user" "$reason"
            failed_hosts+=("$host")
        fi
        rm -f "$err_file"
    done

    if [[ ${#failed_hosts[@]} -gt 0 ]]; then
        echo ""
        echo "$(red "SSH connectivity failed for:") ${failed_hosts[*]}"
        echo "Run ./configure.sh --diagnose-ssh for full per-host diagnostics."
        exit 1
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# rsync (with tar-over-SSH fallback)
# ---------------------------------------------------------------------------
sync_repo() {
    local host="$1"
    echo "  Syncing repository..."
    if command -v rsync &>/dev/null; then
        local ssh_user
        ssh_user="$(ssh_user_for_host "$host")"
        rsync -az -e "ssh ${SSH_OPTS[*]}" \
            --exclude='.git' \
            --exclude='.diy-sonos.generated.yml' \
            "$SCRIPT_DIR/" \
            "${ssh_user}@${host}:${REMOTE_DIR}/"
    else
        # tar-over-SSH fallback
        local ssh_user
        ssh_user="$(ssh_user_for_host "$host")"
        tar --exclude='.git' --exclude='.diy-sonos.generated.yml' \
            -czf - -C "$SCRIPT_DIR" . | \
            ssh "${SSH_OPTS[@]}" "${ssh_user}@${host}" \
                "mkdir -p ${REMOTE_DIR} && tar -xzf - -C ${REMOTE_DIR}"
    fi
}

# ---------------------------------------------------------------------------
# Deploy server
# ---------------------------------------------------------------------------
deploy_server() {
    echo "$(bold "━━ Deploying server: $SERVER_IP ━━")"

    sync_repo "$SERVER_IP"

    echo "  Running sudo ./setup.sh server (output streamed)..."
    ssh "${SSH_OPTS[@]}" "$(ssh_user_for_host "$SERVER_IP")@${SERVER_IP}" \
        "cd ${REMOTE_DIR} && sudo ./setup.sh server"

    echo "  Verifying librespot health on server..."
    ssh "${SSH_OPTS[@]}" "$(ssh_user_for_host "$SERVER_IP")@${SERVER_IP}" \
        "set -euo pipefail; \
         if ! systemctl is-active --quiet librespot; then \
             echo 'librespot is not active yet; waiting briefly before rechecking...'; \
             sleep 3; \
         fi; \
         if ! systemctl is-active --quiet librespot; then \
             echo 'Error: librespot is not active after deploy.' >&2; \
             systemctl status librespot --no-pager -l >&2 || true; \
             journalctl -u librespot -n 80 --no-pager >&2 || true; \
             exit 1; \
         fi"

    server_diagnostics

    echo ""
}

# ---------------------------------------------------------------------------
# OAuth URL — poll journalctl for the Spotify auth URL
# ---------------------------------------------------------------------------
surface_oauth_url() {
    local callback_port cache_dir

    callback_port="$(ssh "${SSH_OPTS[@]}" "$(ssh_user_for_host "$SERVER_IP")@${SERVER_IP}" \
        "cd ${REMOTE_DIR} && python3 -c \"\
import re\
try:\
    txt = open('config.yml').read()\
    m = re.search(r'oauth_callback_port:\\s*\"?([^\"#\\n]+)', txt)\
    print(m.group(1).strip() if m else '4000')\
except:\
    print('4000')\
\"" 2>/dev/null || echo "4000")"

    # Try to read cache_dir from remote config; default to /var/cache/librespot
    cache_dir="$(ssh "${SSH_OPTS[@]}" "$(ssh_user_for_host "$SERVER_IP")@${SERVER_IP}" \
        "cd ${REMOTE_DIR} && python3 -c \"\
import re\
try:\
    txt = open('config.yml').read()\
    m = re.search(r'cache_dir:\\s*\"?([^\"#\\n]+)', txt)\
    print(m.group(1).strip() if m else '/var/cache/librespot')\
except:\
    print('/var/cache/librespot')\
\"" 2>/dev/null || echo "/var/cache/librespot")"

    echo "$(bold "━━ Spotify Authentication ━━")"
    echo ""
    echo "  Next action (run on server):"
    echo "    sudo librespot-auth-helper start-auth ${callback_port} ${cache_dir}"
    echo ""
    echo "  Verify in scripts/automation:"
    echo "    sudo librespot-auth-helper verify-auth-cache ${cache_dir}"
    echo ""
}


# ---------------------------------------------------------------------------
# Deploy clients
# ---------------------------------------------------------------------------
deploy_clients() {
    echo "$(bold "━━ Deploying clients ━━")"

    declare -g -A CLIENT_STATUS
    for host in "${CLIENT_IPS[@]}"; do
           echo "$(bold "  → $host")"
        if sync_repo "$host" && \
           ssh "${SSH_OPTS[@]}" "$(ssh_user_for_host "$host")@${host}" \
               "cd ${REMOTE_DIR} && sudo ./setup.sh client"; then
            CLIENT_STATUS["$host"]="ok"
            echo "  $(green "✓") $host done"
        else
            CLIENT_STATUS["$host"]="FAILED"
            echo "  $(red "✗") $host FAILED"
            echo "  Collecting quick diagnostics from $host..."
            ssh "${SSH_OPTS[@]}" "$(ssh_user_for_host "$host")@${host}" \
                "set -o pipefail; \
                 echo '    --- snapclient unit state ---'; \
                 systemctl status snapclient --no-pager -l || true; \
                 echo; \
                 echo '    --- recent snapclient logs ---'; \
                 journalctl -u snapclient -n 60 --no-pager || true; \
                 echo; \
                 echo '    --- ALSA devices ---'; \
                 aplay -l || true; \
                 echo; \
                 echo '    --- ALSA controls for resolved device hint ---'; \
                 amixer scontrols || true" || true
        fi
        echo ""
    done
}

# ---------------------------------------------------------------------------
# Summary table
# ---------------------------------------------------------------------------
print_summary() {
    echo "$(bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")"
    echo "$(bold "Deployment Summary")"
    echo "$(bold "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")"
    printf "  %-25s %s\n" "Host" "Status"
    printf "  %-25s %s\n" "─────────────────────────" "──────"
    printf "  %-25s %s\n" "$SERVER_IP (server)" "$(green "ok")"
    local any_failed=0
    for host in "${CLIENT_IPS[@]}"; do
        local status="${CLIENT_STATUS[$host]:-FAILED}"
        if [[ "$status" == "ok" ]]; then
            printf "  %-25s %s\n" "$host (client)" "$(green "ok")"
        else
            printf "  %-25s %s\n" "$host (client)" "$(red "FAILED")"
            any_failed=1
        fi
    done
    echo ""
    if [[ $any_failed -eq 0 ]]; then
        echo "$(green "All devices deployed successfully.")"
        echo "Open Spotify and select \"$(bold "$SPOTIFY_DEVICE_NAME")\" to start playing."
    else
        echo "$(red "Some deployments failed.") Check output above for details."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
parse_config
run_preflight
deploy_server
surface_oauth_url
deploy_clients
print_summary
