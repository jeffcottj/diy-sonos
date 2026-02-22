#!/usr/bin/env bash
# deploy.sh — laptop-side orchestrator for DIY Sonos
# Rsyncs this repo to all Pis, runs setup, surfaces OAuth URL, prints summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"
REMOTE_DIR="~/diy-sonos"

SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
_fmt() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
green()  { _fmt "32" "$*"; }
red()    { _fmt "31" "$*"; }
yellow() { _fmt "33" "$*"; }
bold()   { _fmt "1"  "$*"; }
cyan()   { _fmt "36" "$*"; }

# ---------------------------------------------------------------------------
# Parse config.yml via inline Python (no pyyaml needed on laptop)
# ---------------------------------------------------------------------------
parse_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "config.yml not found. Run ./configure.sh first." >&2
        exit 1
    fi

    local parsed
    parsed="$(python3 - "$CONFIG_FILE" <<'PYEOF'
import sys, re

with open(sys.argv[1], encoding="utf-8") as f:
    lines = f.readlines()

server_ip = ""
ssh_user = "pi"
client_ips = []

in_clients = False
in_spotify = False

for line in lines:
    stripped = line.split("#")[0].rstrip()

    # Detect section transitions
    if re.match(r"^[a-z]", stripped):
        in_clients = stripped.startswith("clients:")
        in_spotify = stripped.startswith("spotify:")

    m = re.match(r'^server_ip:\s*"?([^"#\s]+)"?', stripped)
    if m:
        server_ip = m.group(1)

    m = re.match(r'^ssh_user:\s*"?([^"#\s]+)"?', stripped)
    if m:
        ssh_user = m.group(1)

    if in_clients:
        m = re.match(r'^\s+-\s+ip:\s*"?([0-9.]+)"?', stripped)
        if m:
            client_ips.append(m.group(1))

print(f"SERVER_IP={server_ip}")
print(f"SSH_USER={ssh_user}")
for ip in client_ips:
    print(f"CLIENT_IP={ip}")
PYEOF
)"

    SERVER_IP=""
    SSH_USER="pi"
    CLIENT_IPS=()

    while IFS='=' read -r key val; do
        case "$key" in
            SERVER_IP)  SERVER_IP="$val" ;;
            SSH_USER)   SSH_USER="$val" ;;
            CLIENT_IP)  CLIENT_IPS+=("$val") ;;
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

# ---------------------------------------------------------------------------
# Pre-flight: verify SSH connectivity for all hosts
# ---------------------------------------------------------------------------
run_preflight() {
    echo "$(bold "Pre-flight: checking SSH connectivity...")"
    local all_hosts=("$SERVER_IP" "${CLIENT_IPS[@]}")
    local failed_hosts=()

    for host in "${all_hosts[@]}"; do
        printf "  %-20s" "$host"
        if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" true 2>/dev/null; then
            echo "$(green "ok")"
        else
            echo "$(red "FAILED")"
            failed_hosts+=("$host")
        fi
    done

    if [[ ${#failed_hosts[@]} -gt 0 ]]; then
        echo ""
        echo "$(red "SSH connectivity failed for:") ${failed_hosts[*]}"
        echo "Ensure SSH keys are set up: ./configure.sh --copy-keys"
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
        rsync -az \
            --exclude='.git' \
            --exclude='.diy-sonos.generated.yml' \
            "$SCRIPT_DIR/" \
            "${SSH_USER}@${host}:${REMOTE_DIR}/"
    else
        # tar-over-SSH fallback
        tar --exclude='.git' --exclude='.diy-sonos.generated.yml' \
            -czf - -C "$SCRIPT_DIR" . | \
            ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
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
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
        "cd ${REMOTE_DIR} && sudo ./setup.sh server"

    echo ""
}

# ---------------------------------------------------------------------------
# OAuth URL — poll journalctl for the Spotify auth URL
# ---------------------------------------------------------------------------
surface_oauth_url() {
    local cache_dir
    # Try to read cache_dir from remote config; default to /var/cache/librespot
    cache_dir="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
        "cd ${REMOTE_DIR} && python3 -c \"
import re
try:
    txt = open('config.yml').read()
    m = re.search(r'cache_dir:\s*\\\"?([^\\\"\\'#\\n]+)', txt)
    print(m.group(1).strip() if m else '/var/cache/librespot')
except: print('/var/cache/librespot')
\"" 2>/dev/null || echo "/var/cache/librespot")"

    echo "$(bold "━━ Spotify Authentication ━━")"

    # Check if credentials already cached
    local cached
    cached="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
        "ls '${cache_dir}' 2>/dev/null | grep -c 'credentials' || true")"

    if [[ "$cached" -gt 0 ]]; then
        echo "  $(green "✓") Spotify credentials already cached — no action needed."
        echo ""
        return
    fi

    echo "  Polling for Spotify OAuth URL (up to 30s)..."
    local oauth_url=""
    local attempts=0
    while [[ $attempts -lt 10 ]]; do
        oauth_url="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SERVER_IP}" \
            "sudo journalctl -u librespot -n 100 --no-pager 2>/dev/null | grep -o 'https://accounts.spotify.com[^ ]*' | tail -1 || true")"
        if [[ -n "$oauth_url" ]]; then
            break
        fi
        sleep 3
        (( attempts++ )) || true
    done

    echo ""
    if [[ -n "$oauth_url" ]]; then
        echo "  $(bold "$(cyan "Open this URL in your browser to authenticate with Spotify:")")"
        echo ""
        echo "    $oauth_url"
        echo ""
    else
        echo "  $(yellow "OAuth URL not found in librespot logs.")"
        echo "  To authenticate manually, SSH into the server and run:"
        echo ""
        echo "    ssh ${SSH_USER}@${SERVER_IP}"
        echo "    sudo librespot-auth-helper 4000 /var/cache/librespot"
        echo ""
        echo "  Or set up an SSH tunnel:"
        echo "    ssh -L 4000:localhost:4000 ${SSH_USER}@${SERVER_IP}"
        echo "  Then open http://localhost:4000 in your browser."
        echo ""
    fi

    read -r -p "  Press Enter once authenticated (or to skip and continue)..."
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
           ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
               "cd ${REMOTE_DIR} && sudo ./setup.sh client"; then
            CLIENT_STATUS["$host"]="ok"
            echo "  $(green "✓") $host done"
        else
            CLIENT_STATUS["$host"]="FAILED"
            echo "  $(red "✗") $host FAILED"
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
        echo "Open Spotify and select \"$(bold "$SERVER_IP")\" to start playing."
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
