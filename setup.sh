#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    echo "Usage: sudo $0 server|client" >&2
    exit 1
}

# Validate arguments
[[ $# -eq 1 ]] || usage
MODE="$1"
[[ "$MODE" == "server" || "$MODE" == "client" ]] || usage

# Must run as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: this script must be run as root (use sudo)" >&2
    exit 1
fi

# Config file must exist
CONFIG="$SCRIPT_DIR/config.yml"
if [[ ! -f "$CONFIG" ]]; then
    echo "Error: config.yml not found at $CONFIG" >&2
    exit 1
fi

# Ensure python3-yaml is available for config parsing
if ! python3 -c "import yaml" 2>/dev/null; then
    echo "Installing python3-yaml..."
    apt-get install -y python3-yaml
fi

# Load shared functions
source "$SCRIPT_DIR/scripts/common.sh"

# Parse config into environment variables
parse_config "$CONFIG"

# Delegate to the appropriate setup script
case "$MODE" in
    server)
        source "$SCRIPT_DIR/scripts/setup-server.sh"
        ;;
    client)
        source "$SCRIPT_DIR/scripts/setup-client.sh"
        ;;
esac
