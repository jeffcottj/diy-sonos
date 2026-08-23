#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Source common.sh for function definitions (safe)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/scripts/common.sh"

FAILED=0

ok() {
    echo "ok $1"
}

fail() {
    echo "FAIL $1 - $2"
    FAILED=1
}

# ---------------------------------------------------------------------------
# parse_config safety
# ---------------------------------------------------------------------------
test_parse_config_safety() {
    local name="parse_config safety"
    local fixture="$TMP_ROOT/parse_safety.yml"
    cat > "$fixture" <<'YAML'
spotify:
  device_name: 'name$(touch /tmp/pwned)'
  normalise: false
empty_key:
snapclient:
  audio_device: "hw:1,0"
server_ip: "10.0.0.1"
YAML

    rm -f /tmp/pwned
    # Ensure empty
    unset SPOTIFY__DEVICE_NAME SPOTIFY__NORMALISE EMPTY_KEY SNAPCLIENT__AUDIO_DEVICE SERVER_IP 2>/dev/null || true

    parse_config "$fixture"

    if [[ "${SPOTIFY__DEVICE_NAME:-}" != 'name$(touch /tmp/pwned)' ]]; then
        fail "$name" "SPOTIFY__DEVICE_NAME expected literal, got '${SPOTIFY__DEVICE_NAME:-<unset>}'"
        return
    fi
    if [[ -f /tmp/pwned ]]; then
        fail "$name" "marker file /tmp/pwned was created (injection)"
        rm -f /tmp/pwned
        return
    fi
    if [[ "${SPOTIFY__NORMALISE:-}" != "false" ]]; then
        fail "$name" "SPOTIFY__NORMALISE expected 'false', got '${SPOTIFY__NORMALISE:-<unset>}'"
        return
    fi
    # empty_key: should export as EMPTY_KEY="" (empty string) but variable exists
    if [[ ! -v EMPTY_KEY ]]; then
        fail "$name" "EMPTY_KEY not set"
        return
    fi
    if [[ -n "${EMPTY_KEY:-x}" && "${EMPTY_KEY}" != "" ]]; then
        # Actually EMPTY_KEY should be ""
        if [[ "${EMPTY_KEY}" != "" ]]; then
            fail "$name" "EMPTY_KEY expected empty string, got '$EMPTY_KEY'"
            return
        fi
    fi
    # Check that EMPTY_KEY is indeed empty
    if [[ "${EMPTY_KEY}" != "" ]]; then
        fail "$name" "EMPTY_KEY not empty"
        return
    fi
    if [[ "${SNAPCLIENT__AUDIO_DEVICE:-}" != "hw:1,0" ]]; then
        fail "$name" "SNAPCLIENT__AUDIO_DEVICE expected 'hw:1,0', got '${SNAPCLIENT__AUDIO_DEVICE:-<unset>}'"
        return
    fi
    rm -f /tmp/pwned
    ok "$name"
}

# ---------------------------------------------------------------------------
# parse_config_files precedence
# ---------------------------------------------------------------------------
test_parse_config_files_precedence() {
    local name="parse_config_files precedence"
    local base="$TMP_ROOT/base.yml"
    local gen="$TMP_ROOT/generated.yml"
    cat > "$base" <<'YAML'
spotify:
  device_name: "BaseDevice"
  bitrate: 160
server_ip: "10.0.0.1"
YAML
    cat > "$gen" <<'YAML'
spotify:
  device_name: "GeneratedDevice"
YAML
    # Clear before
    unset SPOTIFY__DEVICE_NAME SPOTIFY__BITRATE SERVER_IP 2>/dev/null || true
    parse_config_files "$base" "$gen"
    if [[ "${SPOTIFY__DEVICE_NAME:-}" != "GeneratedDevice" ]]; then
        fail "$name" "expected GeneratedDevice, got '${SPOTIFY__DEVICE_NAME:-<unset>}'"
        return
    fi
    if [[ "${SPOTIFY__BITRATE:-}" != "160" ]]; then
        fail "$name" "SPOTIFY__BITRATE expected 160 from base, got '${SPOTIFY__BITRATE:-<unset>}'"
        return
    fi
    ok "$name"
}

# ---------------------------------------------------------------------------
# validate_* matrix
# ---------------------------------------------------------------------------
test_validate_functions() {
    local name="validate_server_ip"
    # pass
    if ! validate_server_ip "192.168.1.100"; then
        fail "$name" "192.168.1.100 should pass"
    else
        ok "$name pass 192.168.1.100"
    fi
    if validate_server_ip "999.1.1.1" 2>/dev/null; then
        fail "$name" "999.1.1.1 should fail"
    else
        ok "$name fail 999.1.1.1"
    fi
    if validate_server_ip "abc" 2>/dev/null; then
        fail "$name" "abc should fail"
    else
        ok "$name fail abc"
    fi
    if validate_server_ip "" 2>/dev/null; then
        fail "$name" "empty should fail"
    else
        ok "$name fail empty"
    fi

    name="validate_spotify_bitrate"
    for v in 96 160 320; do
        if ! validate_spotify_bitrate "$v"; then
            fail "$name" "$v should pass"
        else
            ok "$name pass $v"
        fi
    done
    if validate_spotify_bitrate "128" 2>/dev/null; then
        fail "$name" "128 should fail"
    else
        ok "$name fail 128"
    fi

    name="validate_snapserver_codec"
    for v in flac FLAC pcm; do
        if ! validate_snapserver_codec "$v"; then
            fail "$name" "$v should pass"
        else
            ok "$name pass $v"
        fi
    done
    if validate_snapserver_codec "ogg" 2>/dev/null; then
        fail "$name" "ogg should fail"
    else
        ok "$name fail ogg"
    fi

    name="validate_snapclient_audio_device"
    for v in auto default "hw:1,0" "plughw:2,0"; do
        if ! validate_snapclient_audio_device "$v"; then
            fail "$name" "$v should pass"
        else
            ok "$name pass $v"
        fi
    done
    if validate_snapclient_audio_device "foo" 2>/dev/null; then
        fail "$name" "foo should fail"
    else
        ok "$name fail foo"
    fi

    name="validate_snapclient_output_volume"
    for v in 0 50 100; do
        if ! validate_snapclient_output_volume "$v"; then
            fail "$name" "$v should pass"
        else
            ok "$name pass $v"
        fi
    done
    for v in -1 101 abc; do
        if validate_snapclient_output_volume "$v" 2>/dev/null; then
            fail "$name" "$v should fail"
        else
            ok "$name fail $v"
        fi
    done
}

# ---------------------------------------------------------------------------
# fifo_requires_protected_sysctl
# ---------------------------------------------------------------------------
test_fifo_requires() {
    local name="fifo_requires_protected_sysctl"
    if ! fifo_requires_protected_sysctl "/tmp/snapfifo"; then
        fail "$name" "/tmp/snapfifo should be true"
    else
        ok "$name /tmp/snapfifo true"
    fi
    if ! fifo_requires_protected_sysctl "/var/tmp/x"; then
        fail "$name" "/var/tmp/x should be true"
    else
        ok "$name /var/tmp/x true"
    fi
    if fifo_requires_protected_sysctl "/run/diy-sonos/snapfifo"; then
        fail "$name" "/run/diy-sonos/snapfifo should be false"
    else
        ok "$name /run/diy-sonos/snapfifo false"
    fi
}

# ---------------------------------------------------------------------------
# render_template_if_changed
# ---------------------------------------------------------------------------
test_render_template_if_changed() {
    local name="render_template_if_changed"
    local tmpl="$TMP_ROOT/tmpl.txt"
    local out="$TMP_ROOT/out.txt"
    cat > "$tmpl" <<'TMPL'
Hello {{TEST_VAR}}
Value {{ANOTHER_VAR}}
TMPL
    export TEST_VAR="world"
    export ANOTHER_VAR="123"
    # First call: should write and return 0
    if ! render_template_if_changed "$tmpl" "$out"; then
        fail "$name" "first call should return 0 (written)"
        return
    fi
    if [[ ! -f "$out" ]]; then
        fail "$name" "out file not created"
        return
    fi
    if ! grep -q "Hello world" "$out"; then
        fail "$name" "out content incorrect: $(cat "$out")"
        return
    fi
    ok "$name first write"

    # Second call with same content: should return 1 and leave mtime unchanged
    local mtime_before
    mtime_before="$(stat -c %Y "$out" 2>/dev/null || stat -f %m "$out" 2>/dev/null || echo 0)"
    sleep 1
    if render_template_if_changed "$tmpl" "$out"; then
        fail "$name" "second call should return 1 (unchanged)"
        return
    fi
    local mtime_after
    mtime_after="$(stat -c %Y "$out" 2>/dev/null || stat -f %m "$out" 2>/dev/null || echo 0)"
    if [[ "$mtime_before" != "$mtime_after" ]]; then
        fail "$name" "mtime changed on unchanged render (before $mtime_before after $mtime_after)"
        return
    fi
    if ! grep -q "Hello world" "$out"; then
        fail "$name" "content changed after unchanged render"
        return
    fi
    ok "$name unchanged"

    # Unset one var -> should fail nonzero, no partial file, original content preserved
    unset ANOTHER_VAR
    local out_content_before
    out_content_before="$(cat "$out")"
    if render_template_if_changed "$tmpl" "$out" 2>/dev/null; then
        fail "$name" "render with missing var should fail"
        export ANOTHER_VAR="123"
        return
    fi
    # Check no partial file: tmp file should be cleaned, out should still have old content or not truncated
    if [[ ! -f "$out" ]]; then
        fail "$name" "out file missing after failed render"
        export ANOTHER_VAR="123"
        return
    fi
    local out_content_after
    out_content_after="$(cat "$out")"
    if [[ "$out_content_before" != "$out_content_after" ]]; then
        fail "$name" "out content changed after failed render"
        export ANOTHER_VAR="123"
        return
    fi
    # Also check no .render.* temp left
    if ls "$TMP_ROOT"/.render.* 2>/dev/null | grep -q .; then
        fail "$name" "temp render file not cleaned"
        export ANOTHER_VAR="123"
        return
    fi
    ok "$name missing var fails cleanly"
    export ANOTHER_VAR="123"

    # Also test when out does not exist and var missing -> should fail and not create file
    local out2="$TMP_ROOT/out2.txt"
    rm -f "$out2"
    unset TEST_VAR
    if render_template_if_changed "$tmpl" "$out2" 2>/dev/null; then
        fail "$name" "render to new file with missing var should fail"
        export TEST_VAR="world"
        return
    fi
    if [[ -f "$out2" ]]; then
        fail "$name" "out2 should not exist after failed render"
        export TEST_VAR="world"
        return
    fi
    ok "$name missing var no file created"
    export TEST_VAR="world"
}

# ---------------------------------------------------------------------------
# templates render clean
# ---------------------------------------------------------------------------
test_templates_render_clean() {
    local name="templates render clean"
    local tmpl_dir="$SCRIPT_DIR/templates"
    # Set all required vars
    export SPOTIFY__DEVICE_NAME="TestDevice"
    export SPOTIFY__DEVICE_TYPE="speaker"
    export SPOTIFY__BITRATE="320"
    export SPOTIFY__INITIAL_VOLUME="90"
    export SPOTIFY__NORMALISE_FLAG="--enable-volume-normalisation"
    export SPOTIFY__CACHE_DIR="/var/cache/librespot"
    export SPOTIFY__OAUTH_CALLBACK_PORT="4000"
    export SNAPSERVER__FIFO_PATH="/run/diy-sonos/snapfifo"
    export SNAPSERVER__SAMPLEFORMAT="44100:16:2"
    export SNAPSERVER__CODEC="flac"
    export SNAPSERVER__BUFFER_MS="1000"
    export SNAPSERVER__CONTROL_PORT="1780"
    export SNAPSERVER__PORT="1704"
    export SERVER_IP="192.168.1.100"
    export RESOLVED_AUDIO_DEVICE="plughw:Device,0"
    export SNAPCLIENT__LATENCY_MS="0"
    export SNAPCLIENT__INSTANCE="1"

    for tmpl in "$tmpl_dir"/*.tmpl; do
        local out="$TMP_ROOT/$(basename "$tmpl").out"
        if ! render_template_if_changed "$tmpl" "$out"; then
            # If unchanged, still check that file exists and has no {{
            if [[ ! -f "$out" ]]; then
                fail "$name" "template $(basename "$tmpl") not rendered (no output)"
                continue
            fi
        fi
        if grep -q "{{" "$out"; then
            fail "$name" "template $(basename "$tmpl") still contains {{: $(grep "{{" "$out")"
        else
            ok "$name $(basename "$tmpl") clean"
        fi
    done
}

# ---------------------------------------------------------------------------
# parse-network-config.py
# ---------------------------------------------------------------------------
test_parse_network_config_py() {
    local name="parse-network-config.py"
    local fixture="$TMP_ROOT/fixture.yml"
    cat > "$fixture" <<'YAML'
ssh_user: "customuser"
server_ip: "10.0.0.1"
clients:
  - ip: "10.0.0.2"
  - ip: "10.0.0.3"
    ssh_user: "clientuser"
spotify:
  device_name: "Test Device"
  cache_dir: "/tmp/cache"
  oauth_callback_port: 5000
server:
  ip: "10.0.0.1"
  ssh_user: "serveruser"
YAML
    local output
    output="$(python3 "$SCRIPT_DIR/scripts/parse-network-config.py" "$fixture")"
    local expected
    expected="$(cat <<'EXP'
DEFAULT_SSH_USER=customuser
SSH_USER=customuser
SERVER_IP=10.0.0.1
SERVER_SSH_USER=serveruser
SPOTIFY_DEVICE_NAME=Test Device
OAUTH_CALLBACK_PORT=5000
SPOTIFY_CACHE_DIR=/tmp/cache
CLIENT=10.0.0.2|customuser
CLIENT=10.0.0.3|clientuser
EXP
)"
    if [[ "$output" != "$expected" ]]; then
        echo "--- expected ---"
        echo "$expected"
        echo "--- actual ---"
        echo "$output"
        fail "$name" "output mismatch"
        return
    fi
    ok "$name fixture"

    # Missing file should exit 1
    if python3 "$SCRIPT_DIR/scripts/parse-network-config.py" "$TMP_ROOT/missing.yml" 2>/dev/null; then
        fail "$name" "missing file should exit nonzero"
    else
        ok "$name missing file exits 1"
    fi
}

# Run all tests
test_parse_config_safety
test_parse_config_files_precedence
test_validate_functions
test_fifo_requires
test_render_template_if_changed
test_templates_render_clean
test_parse_network_config_py

if [[ $FAILED -ne 0 ]]; then
    echo "Some tests failed"
    exit 1
fi
echo "All tests passed"
