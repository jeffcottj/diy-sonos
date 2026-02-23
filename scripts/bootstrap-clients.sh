#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  cat <<USAGE
Usage:
  $0 --hosts host1,host2 [options]
  $0 --hosts-file hosts.txt [options]

Options:
  --hosts CSV                Comma-separated hostnames/IPs to bootstrap.
  --hosts-file PATH          Newline-delimited hostnames/IPs to bootstrap.
  --inventory PATH           Inventory YAML file (default: clients.yml).
  --ssh-user USER            SSH username.
  --ssh-key PATH             SSH private key path.
  --ssh-port PORT            SSH port (default: 22).
  --remote-dir PATH          Remote deploy directory (default: ~/diy-sonos).
  --sudo-passless-check      Fail fast if sudo requires a TTY/password remotely.
  -h, --help                 Show this help.

Inventory format (simple YAML subset):
  defaults:
    server_ip: 192.168.1.100
    ssh_user: pi
    ssh_port: 22
    ssh_key: ~/.ssh/id_ed25519
    remote_dir: ~/diy-sonos
  clients:
    - host: 192.168.1.121
      name: Kitchen
      latency: 20
      audio_device: hw:1,0
      output_volume: 85

Per-client keys: host (required for inventory mapping), name, latency, audio_device, output_volume.
USAGE
}

HOSTS_CSV=""
HOSTS_FILE=""
INVENTORY_PATH="$REPO_ROOT/clients.yml"
SSH_USER=""
SSH_KEY=""
SSH_PORT="22"
REMOTE_DIR="~/diy-sonos"
CHECK_PASSWORDLESS_SUDO=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hosts)
      HOSTS_CSV="${2:-}"
      shift 2
      ;;
    --hosts-file)
      HOSTS_FILE="${2:-}"
      shift 2
      ;;
    --inventory)
      INVENTORY_PATH="${2:-}"
      shift 2
      ;;
    --ssh-user)
      SSH_USER="${2:-}"
      shift 2
      ;;
    --ssh-key)
      SSH_KEY="${2:-}"
      shift 2
      ;;
    --ssh-port)
      SSH_PORT="${2:-}"
      shift 2
      ;;
    --remote-dir)
      REMOTE_DIR="${2:-}"
      shift 2
      ;;
    --sudo-passless-check)
      CHECK_PASSWORDLESS_SUDO=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$HOSTS_CSV" && -n "$HOSTS_FILE" ]]; then
  echo "Use either --hosts or --hosts-file, not both." >&2
  exit 1
fi

if [[ -z "$HOSTS_CSV" && -z "$HOSTS_FILE" ]]; then
  echo "Missing required target list: --hosts or --hosts-file" >&2
  exit 1
fi

if [[ -n "$HOSTS_FILE" && ! -f "$HOSTS_FILE" ]]; then
  echo "Hosts file not found: $HOSTS_FILE" >&2
  exit 1
fi

readarray -t TARGET_HOSTS < <(
  if [[ -n "$HOSTS_CSV" ]]; then
    tr ',' '\n' <<<"$HOSTS_CSV"
  else
    cat "$HOSTS_FILE"
  fi | sed 's/#.*$//' | sed 's/^\s*//;s/\s*$//' | awk 'NF'
)

if [[ ${#TARGET_HOSTS[@]} -eq 0 ]]; then
  echo "No hosts to process." >&2
  exit 1
fi

if [[ ! -f "$INVENTORY_PATH" ]]; then
  echo "Inventory file not found: $INVENTORY_PATH" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

INVENTORY_JSON="$TMP_DIR/inventory.json"
python3 - "$INVENTORY_PATH" "$INVENTORY_JSON" <<'PY'
import json
import re
import sys

src, out = sys.argv[1], sys.argv[2]

with open(src, "r", encoding="utf-8") as f:
    lines = f.readlines()

clean = []
for line in lines:
    line = re.sub(r"\s+#.*$", "", line.rstrip("\n"))
    if line.strip():
        clean.append(line)

def parse_scalar(v: str):
    v = v.strip()
    if (v.startswith('"') and v.endswith('"')) or (v.startswith("'") and v.endswith("'")):
        return v[1:-1]
    if re.fullmatch(r"-?\d+", v):
        return int(v)
    return v

result = {"defaults": {}, "clients": []}
state = None
i = 0
while i < len(clean):
    line = clean[i]
    if line.startswith("defaults:"):
        state = "defaults"
        i += 1
        while i < len(clean) and clean[i].startswith("  ") and not clean[i].startswith("  - "):
            k, _, v = clean[i].strip().partition(":")
            result["defaults"][k.strip()] = parse_scalar(v)
            i += 1
        continue
    if line.startswith("clients:"):
        state = "clients"
        i += 1
        while i < len(clean):
            row = clean[i]
            if not row.startswith("  - "):
                if row.startswith("  "):
                    i += 1
                    continue
                break
            item = {}
            first = row[4:]
            if first.strip():
                k, _, v = first.partition(":")
                item[k.strip()] = parse_scalar(v)
            i += 1
            while i < len(clean) and clean[i].startswith("    "):
                k, _, v = clean[i].strip().partition(":")
                item[k.strip()] = parse_scalar(v)
                i += 1
            result["clients"].append(item)
        continue
    i += 1

json.dump(result, open(out, "w", encoding="utf-8"))
PY

lookup_client_override() {
  local host="$1"
  python3 - "$INVENTORY_JSON" "$host" <<'PY'
import json
import sys

inventory_path, host = sys.argv[1], sys.argv[2]
obj = json.load(open(inventory_path, "r", encoding="utf-8"))
found = {}
for item in obj.get("clients", []):
    if str(item.get("host", "")).strip() == host:
        found = item
        break

for key in ("name", "latency", "audio_device", "output_volume"):
    value = found.get(key, "")
    print(f"{key}={value}")
PY
}

lookup_default() {
  local key="$1"
  python3 - "$INVENTORY_JSON" "$key" <<'PY'
import json
import sys
obj = json.load(open(sys.argv[1], "r", encoding="utf-8"))
key = sys.argv[2]
print(obj.get("defaults", {}).get(key, ""))
PY
}

if [[ -z "$SSH_USER" ]]; then SSH_USER="$(lookup_default ssh_user)"; fi
if [[ -z "$SSH_KEY" ]]; then SSH_KEY="$(lookup_default ssh_key)"; fi
if [[ "$SSH_PORT" == "22" ]]; then
  inv_port="$(lookup_default ssh_port)"
  if [[ -n "$inv_port" ]]; then SSH_PORT="$inv_port"; fi
fi
if [[ "$REMOTE_DIR" == "~/diy-sonos" ]]; then
  inv_remote_dir="$(lookup_default remote_dir)"
  if [[ -n "$inv_remote_dir" ]]; then REMOTE_DIR="$inv_remote_dir"; fi
fi
DEFAULT_SERVER_IP="$(lookup_default server_ip)"

if [[ -z "$SSH_USER" ]]; then
  echo "SSH user is required (set --ssh-user or defaults.ssh_user)." >&2
  exit 1
fi

SSH_OPTS=(-o BatchMode=yes -p "$SSH_PORT")
if [[ -n "$SSH_KEY" ]]; then
  SSH_OPTS+=(-i "$SSH_KEY")
fi

for host in "${TARGET_HOSTS[@]}"; do
  echo "=== Bootstrapping $host ==="

  override_lines="$(lookup_client_override "$host")"
  client_name=""
  client_latency=""
  client_audio_device=""
  client_output_volume=""
  while IFS='=' read -r k v; do
    case "$k" in
      name) client_name="$v" ;;
      latency) client_latency="$v" ;;
      audio_device) client_audio_device="$v" ;;
      output_volume) client_output_volume="$v" ;;
    esac
  done <<<"$override_lines"

  if [[ -z "$client_name" ]]; then
    client_name="$host"
  fi

  if [[ -z "$client_audio_device" ]]; then
    client_audio_device="auto"
  fi

  if [[ -z "$DEFAULT_SERVER_IP" ]]; then
    echo "Missing defaults.server_ip in inventory file: $INVENTORY_PATH" >&2
    exit 1
  fi

  echo "[$host] Syncing repository to $REMOTE_DIR"
  tar --exclude .git -czf - -C "$REPO_ROOT" . | \
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" "mkdir -p $REMOTE_DIR && tar -xzf - -C $REMOTE_DIR"

  if [[ $CHECK_PASSWORDLESS_SUDO -eq 1 ]]; then
    echo "[$host] Checking passwordless sudo"
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" "cd $REMOTE_DIR && sudo -n true"
  fi

  echo "[$host] Generating client config"
  setup_init_cmd="cd $REMOTE_DIR && ./setup.sh init --role client --server-ip '$DEFAULT_SERVER_IP' --device-name '$client_name' --audio-device '$client_audio_device'"
  if [[ -n "$client_output_volume" ]]; then
    setup_init_cmd+=" --output-volume '$client_output_volume'"
  fi
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" \
    "$setup_init_cmd"

  if [[ -n "$client_latency" ]]; then
    echo "[$host] Applying latency override: $client_latency ms"
    ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" "cd $REMOTE_DIR && python3 - <<'PY'
from pathlib import Path
import re
p = Path('.diy-sonos.generated.yml')
text = p.read_text(encoding='utf-8')
if 'snapclient:' not in text:
    text += '\nsnapclient:\n'
if re.search(r'(?m)^  latency_ms:\s*', text):
    text = re.sub(r'(?m)^  latency_ms:\s*.*$', f'  latency_ms: {int($client_latency)}', text)
else:
    text += f'  latency_ms: {int($client_latency)}\n'
p.write_text(text, encoding='utf-8')
PY"
  fi

  echo "[$host] Running client setup"
  ssh "${SSH_OPTS[@]}" "$SSH_USER@$host" "cd $REMOTE_DIR && sudo ./setup.sh client"
  echo "=== Completed $host ==="
  echo

done

echo "All requested hosts processed successfully."
