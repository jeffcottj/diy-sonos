#!/usr/bin/env bash
# deploy.sh — laptop-side orchestrator for DIY Sonos
# Rsyncs this repo to all target devices, runs setup, surfaces OAuth URL, prints summary.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.yml"
REMOTE_DIR="~/diy-sonos"

SSH_OPTS=(-o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o BatchMode=yes)
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"
KNOWN_HOSTS_FILE="$HOME/.ssh/known_hosts"

# ---------------------------------------------------------------------------
# Colour helpers
# ---------------------------------------------------------------------------
_fmt() { printf "\033[%sm%s\033[0m" "$1" "$2"; }
green()  { _fmt "32" "$*"; }
red()    { _fmt "31" "$*"; }
yellow() { _fmt "33" "$*"; }
bold()   { _fmt "1"  "$*"; }
cyan()   { _fmt "36" "$*"; }

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
    local reason="$2"

    case "$reason" in
        auth_failed)
            echo "    Fix: run ./configure.sh --copy-keys (or): ssh-copy-id ${SSH_USER}@${host}"
            ;;
        host_unreachable)
            echo "    Fix: verify network + ssh service:"
            echo "         ping -c 1 ${host}"
            echo "         ssh ${SSH_USER}@${host}"
            ;;
        host_key_issue)
            echo "    Fix: refresh known_hosts entry:"
            echo "         ssh-keygen -R ${host}"
            echo "         ssh-keyscan -H ${host} >> ~/.ssh/known_hosts"
            ;;
        *)
            echo "    Fix: inspect verbose SSH output: ssh -vv ${SSH_USER}@${host}"
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
        echo "$(red "FAILED")"
        echo "    Reason: unable to pre-seed host key (host unreachable or SSH closed)"
        echo "    Fix: ssh-keyscan -H ${host} >> ~/.ssh/known_hosts"
        return 1
    fi

    local fingerprint
    fingerprint="$(printf '%s\n' "$scan_out" | ssh-keygen -lf - 2>/dev/null | awk 'NR==1{print $2}')"

    echo ""
    echo "    New host key detected for ${host}"
    echo "      Fingerprint: ${fingerprint:-unknown}"
    read -r -p "    Confirm fingerprint and trust this host? [y/N]: " trust_choice
    if [[ ! "$trust_choice" =~ ^[Yy]$ ]]; then
        echo "$(red "FAILED")"
        echo "    Reason: host key not confirmed"
        return 1
    fi

    printf '%s\n' "$scan_out" >> "$KNOWN_HOSTS_FILE"
    return 0
}

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

    ensure_local_ssh_key || true

    for host in "${all_hosts[@]}"; do
        printf "  %-20s" "$host"

        if ! ensure_host_key_trusted "$host"; then
            failed_hosts+=("$host")
            continue
        fi

        local err_file
        err_file="$(mktemp)"
        if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" true 2>"$err_file"; then
            echo "$(green "ok")"
        else
            echo "$(red "FAILED")"
            local err_text reason
            err_text="$(<"$err_file")"
            reason="$(classify_ssh_error "$err_text")"
            echo "    Reason: $reason"
            print_ssh_fix_hint "$host" "$reason"
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
