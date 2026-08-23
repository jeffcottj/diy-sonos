#!/usr/bin/env bash
# scripts/lib/ssh.sh — shared SSH helpers for laptop-side scripts
# Caller must set SSH_KEY_PATH and KNOWN_HOSTS_FILE before sourcing.

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
    local ssh_user="$2"
    local reason="$3"

    case "$reason" in
        auth_failed)
            echo "    Fix: run ./configure.sh --copy-keys (or): ssh-copy-id ${ssh_user}@${host}"
            ;;
        host_unreachable)
            echo "    Fix: verify network + ssh service:"
            echo "         ping -c 1 ${host}"
            echo "         ssh ${ssh_user}@${host}"
            ;;
        host_key_issue)
            echo "    Fix: refresh known_hosts entry:"
            echo "         ssh-keygen -R ${host}"
            echo "         ssh-keyscan -H ${host} >> ~/.ssh/known_hosts"
            ;;
        *)
            echo "    Fix: inspect verbose SSH output: ssh -vv ${ssh_user}@${host}"
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

validate_ipv4() {
    local ip="$1"
    if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    local IFS='.'
    local -a octets
    read -ra octets <<< "$ip"
    local octet
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done
    return 0
}
