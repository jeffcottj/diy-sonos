#!/usr/bin/env python3
"""Unified laptop-side YAML parser for diy-sonos config.yml (stdlib only).

Replaces three inline parsers (deploy.sh, first-run.sh x2, configure.sh).
CLI: python3 parse-network-config.py <config.yml>
Output: KEY=VALUE lines as per spec.
"""
import re
import sys


def parse_file(path):
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    default_ssh_user = "pi"
    server_ssh_user = ""
    server_ip = ""
    spotify_device_name = "DIY Sonos"
    oauth_callback_port = "4000"
    spotify_cache_dir = "/var/cache/librespot"
    snapclient_output_volume = "90"
    client_entries = []

    in_clients = False
    in_spotify = False
    in_server = False
    in_snapclient = False

    for raw in lines:
        # Strip inline # comments (known limitation: # inside quotes stripped)
        stripped = raw.split("#", 1)[0].rstrip()
        if not stripped.strip():
            continue

        # Detect section transitions: line matching ^[a-z] starts new top-level section
        if re.match(r"^[a-z]", stripped):
            in_clients = stripped.startswith("clients:")
            in_spotify = stripped.startswith("spotify:")
            in_server = stripped.startswith("server:")
            in_snapclient = stripped.startswith("snapclient:")
            # Section header lines themselves are not key-values; continue to check other patterns
            # but allow server_ip etc on same line? No, section lines are headers only.
            # For clients: we need to keep in_clients true, then next lines handle entries.
            # For server: keep in_server true.
            # We still need to check for top-level keys on this line? The line is section header, not key.
            # So we can continue to next checks but they won't match section headers.
            pass

        # Helper to unquote captured value
        def unquote(v):
            v = v.strip()
            if len(v) >= 2 and ((v[0] == '"' and v[-1] == '"') or (v[0] == "'" and v[-1] == "'")):
                return v[1:-1]
            # Also handle case where regex already stripped quotes but value may still have trailing quote
            # The regex patterns already handle optional quotes, so this is fallback.
            return v

        # Top-level ssh_user (no indent)
        m = re.match(r'^ssh_user:\s*"?([^"#\s]+)"?', stripped)
        if m:
            # This only matches when at column 0 (no leading spaces)
            default_ssh_user = unquote(m.group(1))
            continue  # avoid double-counting as server ssh_user

        # Top-level server_ip
        m = re.match(r'^server_ip:\s*"?([^"#\s]+)"?', stripped)
        if m:
            server_ip = unquote(m.group(1))

        # Legacy server: ip: (indented ip under server: block) — first-run parity
        # Only when in_server (or not in_clients) and line is indented ip:
        if in_server:
            m = re.match(r'^\s*ip:\s*"?([^"#\s]+)"?', stripped)
            if m:
                server_ip = unquote(m.group(1))

        # Indented ssh_user under server: block -> SERVER_SSH_USER
        # Match any indented ssh_user that is not part of clients block
        if not in_clients and re.match(r'^\s+ssh_user:\s*"?([^"#\s]+)"?', stripped):
            # Need to ensure it's not the top-level (already handled) and is indented
            # This captures server: ssh_user and also handles deploy's `  ssh_user:` logic
            m = re.match(r'^\s+ssh_user:\s*"?([^"#\s]+)"?', stripped)
            if m:
                # Only set if we are in server block or if not in_clients but before clients
                # To avoid capturing client ssh_user, ensure not in_clients (already)
                # And if in_server or if stripped starts with two spaces (deploy's heuristic)
                if in_server or stripped.startswith("  ssh_user:"):
                    server_ssh_user = unquote(m.group(1))

        # spotify device_name only inside spotify section
        if in_spotify:
            m = re.match(r'^\s*device_name:\s*"?([^"#]+?)"?\s*$', stripped)
            if m:
                val = m.group(1).strip()
                # Remove trailing quote if regex left it
                val = unquote(val) if (val.startswith('"') or val.startswith("'")) else val.strip().strip('"').strip("'")
                # The above unquote handles quoted values; but we should also strip surrounding quotes cleanly
                # Simpler: strip whitespace and surrounding quotes
                val = val.strip()
                if len(val) >= 2 and ((val[0] == '"' and val[-1] == '"') or (val[0] == "'" and val[-1] == "'")):
                    val = val[1:-1]
                else:
                    # If regex captured without quotes but value had quotes, they were captured; remove any surrounding quotes
                    val = val.strip('"').strip("'")
                spotify_device_name = val.strip()

        # oauth_callback_port and cache_dir at any indent
        m = re.match(r'^\s*oauth_callback_port:\s*"?([^"#\s]+)"?', stripped)
        if m:
            oauth_callback_port = unquote(m.group(1))
        m = re.match(r'^\s*cache_dir:\s*"?([^"#\s]+)"?', stripped)
        if m:
            spotify_cache_dir = unquote(m.group(1))
        # Also handle quoted cache_dir with spaces? cache_dir is path without spaces, so fine.

        # snapclient global output_volume (outside clients block)
        if in_snapclient and not in_clients:
            m = re.match(r'^\s+output_volume:\s*"?([^"#\s]+)"?', stripped)
            if m:
                snapclient_output_volume = unquote(m.group(1))

        # clients entries
        if in_clients:
            m = re.match(r'^\s*-\s*ip:\s*"?([0-9.]+)"?', stripped)
            if m:
                client_entries.append([unquote(m.group(1)), default_ssh_user, ""])
                continue
            m = re.match(r'^\s+ssh_user:\s*"?([^"#\s]+)"?', stripped)
            if m and client_entries:
                client_entries[-1][1] = unquote(m.group(1))
                continue
            m = re.match(r'^\s+output_volume:\s*"?([^"#\s]+)"?', stripped)
            if m and client_entries:
                client_entries[-1][2] = unquote(m.group(1))

    # Fallbacks
    if not server_ssh_user:
        server_ssh_user = default_ssh_user

    return {
        "DEFAULT_SSH_USER": default_ssh_user,
        "SSH_USER": default_ssh_user,
        "SERVER_IP": server_ip,
        "SERVER_SSH_USER": server_ssh_user,
        "SPOTIFY_DEVICE_NAME": spotify_device_name,
        "OAUTH_CALLBACK_PORT": oauth_callback_port,
        "SPOTIFY_CACHE_DIR": spotify_cache_dir,
        "SNAPCLIENT_OUTPUT_VOLUME": snapclient_output_volume,
        "CLIENTS": client_entries,
    }


def main():
    if len(sys.argv) < 2:
        print("Usage: parse-network-config.py <config.yml>", file=sys.stderr)
        sys.exit(1)
    path = sys.argv[1]
    try:
        with open(path, encoding="utf-8"):
            pass
    except FileNotFoundError:
        print(f"config file not found: {path}", file=sys.stderr)
        sys.exit(1)
    data = parse_file(path)
    # Emit protocol
    out_lines = []
    out_lines.append(f"DEFAULT_SSH_USER={data['DEFAULT_SSH_USER']}")
    out_lines.append(f"SSH_USER={data['DEFAULT_SSH_USER']}")
    out_lines.append(f"SERVER_IP={data['SERVER_IP']}")
    out_lines.append(f"SERVER_SSH_USER={data['SERVER_SSH_USER']}")
    out_lines.append(f"SPOTIFY_DEVICE_NAME={data['SPOTIFY_DEVICE_NAME']}")
    out_lines.append(f"OAUTH_CALLBACK_PORT={data['OAUTH_CALLBACK_PORT']}")
    out_lines.append(f"SPOTIFY_CACHE_DIR={data['SPOTIFY_CACHE_DIR']}")
    out_lines.append(f"SNAPCLIENT_OUTPUT_VOLUME={data['SNAPCLIENT_OUTPUT_VOLUME']}")
    for entry in data["CLIENTS"]:
        # Backward compat: CLIENT=ip|user
        ip = entry[0]
        user = entry[1] if len(entry) > 1 else ""
        vol = entry[2] if len(entry) > 2 else ""
        out_lines.append(f"CLIENT={ip}|{user}")
        if vol:
            out_lines.append(f"CLIENT_OUTPUT_VOLUME={ip}|{vol}")
    sys.stdout.write("\n".join(out_lines) + ("\n" if out_lines else ""))


if __name__ == "__main__":
    main()
