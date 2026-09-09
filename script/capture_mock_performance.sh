#!/usr/bin/env bash
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CAPTURE_MODE="${MODE:-smoke}"
case "${1:-}" in
    "")
        ;;
    --release)
        printf '%s\n' '--release is unsupported: this harness measures an isolated DEBUG copy and cannot approve the final Developer ID/notarized Release artifact' >&2
        exit 2
        ;;
    --mock-debug-acceptance)
        CAPTURE_MODE="mock-debug-acceptance"
        ;;
    --smoke)
        CAPTURE_MODE="smoke"
        ;;
    *)
        printf 'usage: %s [--mock-debug-acceptance|--smoke]\n' "$0" >&2
        exit 2
        ;;
esac
if [[ "$CAPTURE_MODE" == "release" ]]; then
    printf '%s\n' 'MODE=release is unsupported: this harness measures an isolated DEBUG copy and cannot approve the final Developer ID/notarized Release artifact' >&2
    exit 2
fi
[[ "$CAPTURE_MODE" == "mock-debug-acceptance" || "$CAPTURE_MODE" == "smoke" ]] \
    || { printf 'MODE must be mock-debug-acceptance or smoke\n' >&2; exit 2; }
if [[ "$CAPTURE_MODE" != "smoke" \
    && "${TRANSMISSION_REMOTE_MAC_CONFIRM_LONG_ACCEPTANCE:-}" != "1" ]]; then
    printf '%s\n' \
        'long acceptance is release-candidate-only and takes about 45 to 50 minutes; rerun with TRANSMISSION_REMOTE_MAC_CONFIRM_LONG_ACCEPTANCE=1 after explicit approval' >&2
    exit 2
fi

APP_BUNDLE="${APP_BUNDLE:-/Applications/TransmissionRemoteMac.app}"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/TransmissionRemoteMac"
APP_BUNDLE_ID="net.pokwer.TransmissionRemoteMac"
MOCK_HOST="127.0.0.1"
SANDBOX_REMOTE_HOST="localhost"
MOCK_PORT="${MOCK_PORT:-19091}"
MOCK_RESPONSE_DELAY_MS=6000
FOREGROUND_INTERVAL_SECONDS=5
PERFORMANCE_ISOLATION_COMPILED_MARKER="TRM_PERFORMANCE_PASSWORD_STORE_ISOLATION_V1"
PERFORMANCE_ISOLATION_REQUEST_MARKER=".transmission-remote-mac-performance-isolation"
PERFORMANCE_ISOLATION_ACTIVATION_PROOF=".transmission-remote-mac-performance-password-store-active"
PERFORMANCE_DETAIL_SELECTION_PROOF=".transmission-remote-mac-performance-detail-selection"
PERFORMANCE_WAKE_TRACE=".transmission-remote-mac-performance-polling-wakes"
PERFORMANCE_POLLING_VISIBILITY_PROOF=".transmission-remote-mac-performance-polling-visibility"
PERFORMANCE_APPLICATION_STATE_PROOF=".transmission-remote-mac-performance-application-state"
PERFORMANCE_INSTRUMENTATION_TRACE=".transmission-remote-mac-performance-instrumentation"
PERFORMANCE_INSTRUMENTATION_ENVIRONMENT_KEY="TRANSMISSION_REMOTE_MAC_PERFORMANCE_INSTRUMENTATION"
PERFORMANCE_DETAIL_TARGET_ENVIRONMENT_KEY="TRANSMISSION_REMOTE_MAC_PERFORMANCE_DETAIL_TORRENT_ID"
PERFORMANCE_APPLICATION_STATE_ENVIRONMENT_KEY="TRANSMISSION_REMOTE_MAC_PERFORMANCE_APPLICATION_STATE_PROOF"
PERFORMANCE_DETAIL_TARGET_ID=1
PERFORMANCE_POLLING_VISIBILITY_MARKER="TRM_PERFORMANCE_POLLING_VISIBILITY_V1"
PERFORMANCE_APPLICATION_STATE_MARKER="TRM_PERFORMANCE_APPLICATION_STATE_V1"
PERFORMANCE_WAKE_TRACE_STARTUP_WAIT_SECONDS=120
SAMPLE_INTERVAL_SECONDS=1
RELEASE_SAMPLE_SECONDS=600
RELEASE_HIDDEN_SAMPLE_SECONDS=600
RELEASE_VOLUME_WINDOW_SECONDS=60
RELEASE_SCALE_SAMPLE_SECONDS=60
RELEASE_WARMUP_SECONDS=30
RELEASE_FILES_WARMUP_SECONDS=30
RELEASE_FILES_SAMPLE_SECONDS=60
RELEASE_VISIBILITY_SETTLE_SECONDS=5
RELEASE_CONNECTED_AVERAGE_CPU_MAX=1.0
RELEASE_CONNECTED_P95_CPU_MAX=2.0
RELEASE_HIDDEN_AVERAGE_CPU_MAX=0.2
RELEASE_BACKGROUND_P95_CPU_MAX=2.0
RELEASE_DISCONNECTED_AVERAGE_CPU_MAX=0.2
RELEASE_DISCONNECTED_P95_CPU_MAX=0.2
RELEASE_ACTIVE_VISIBLE_RPC_MAX_PER_MINUTE=14
RELEASE_FILES_RPC_MAX_PER_MINUTE=26
RELEASE_IDLE_VISIBLE_RPC_MAX_PER_MINUTE=5
RELEASE_IDLE_VISIBLE_LIST_MAX_PER_MINUTE=4
RELEASE_ACTIVE_LIST_MIN_PER_MINUTE=3
RELEASE_ACTIVE_LIST_MAX_PER_MINUTE=12
RELEASE_HIDDEN_LIST_MAX_PER_MINUTE=4
RELEASE_HIDDEN_HEALTH_MAX_PER_MINUTE=1
RELEASE_SUSPENDED_RPC_MAX=0
RELEASE_FOREGROUND_WAKE_MAX_PER_SECOND=2
RELEASE_HIDDEN_WAKE_MAX_PER_SECOND=0.1
RELEASE_THOUSAND_FOOTPRINT_MAX_BYTES=$((150 * 1024 * 1024))
RELEASE_FILES_FOOTPRINT_MAX_BYTES=$((250 * 1024 * 1024))
RELEASE_MAIN_THREAD_P95_MAX_NANOSECONDS=50000000
RELEASE_MAIN_THREAD_MAX_NANOSECONDS=100000000
RELEASE_UI_TIMING_MAX_NANOSECONDS=100000000
RELEASE_FILES_TIMING_MAX_NANOSECONDS=100000000
SMOKE_SAMPLE_SECONDS="${SMOKE_SAMPLE_SECONDS:-15}"
SMOKE_WARMUP_SECONDS="${SMOKE_WARMUP_SECONDS:-30}"
SMOKE_CONNECTED_AVERAGE_CPU_MAX="${SMOKE_CONNECTED_AVERAGE_CPU_MAX:-15.0}"
SMOKE_DISCONNECTED_AVERAGE_CPU_MAX="${SMOKE_DISCONNECTED_AVERAGE_CPU_MAX:-10.0}"
SMOKE_CONNECTED_P95_CPU_MAX="${SMOKE_CONNECTED_P95_CPU_MAX:-25.0}"
SMOKE_DISCONNECTED_P95_CPU_MAX="${SMOKE_DISCONNECTED_P95_CPU_MAX:-20.0}"
SMOKE_CONNECTED_LIST_REQUEST_MIN="${SMOKE_CONNECTED_LIST_REQUEST_MIN:-1}"
SMOKE_DISCONNECTED_REQUEST_MAX="${SMOKE_DISCONNECTED_REQUEST_MAX:-0}"
MAX_IN_FLIGHT_REQUESTS=1

TMP_ROOT=""
APP_PID=""
APP_ISOLATION_TOKEN=""
APP_POLLING_VISIBILITY_PROOF=""
APP_APPLICATION_STATE_PROOF=""
APP_INSTRUMENTATION_TRACE=""
MOCK_PID=""
ORIGINAL_HOME="$HOME"
REAL_PROFILE_FILE="$ORIGINAL_HOME/Library/Application Support/TransmissionRemoteMac/ConnectionProfiles.json"
REAL_DEFAULTS_FILE="$ORIGINAL_HOME/Library/Preferences/$APP_BUNDLE_ID.plist"
REAL_PROFILE_BEFORE=""
REAL_DEFAULTS_BEFORE=""
REAL_FINGERPRINTS_CAPTURED=0
GATE_FAILURES=()
PERFORMANCE_DEFAULTS_SUITES=()
EVIDENCE_MODE="${CAPTURE_MODE//-/_}"
ACCEPTANCE_RESULT_KEY="$EVIDENCE_MODE"
FOREGROUND_PROCESS_STATE_EVIDENCE="active_unhidden"
FOREGROUND_EVIDENCE="native_activation"
STALE_GENERATION_GATE_EVIDENCE="stale_generation_publications_exactly_0"

fail() {
    printf 'VAL-005 performance capture failed: %s\n' "$*" >&2
    exit 1
}

terminate_child_process() {
    local pid="$1"
    local label="$2"
    local attempt

    [[ -n "$pid" ]] || return 0
    if /bin/kill -0 "$pid" 2>/dev/null; then
        /bin/kill -TERM "$pid" 2>/dev/null || true
        for (( attempt = 0; attempt < 50; attempt++ )); do
            /bin/kill -0 "$pid" 2>/dev/null || break
            /bin/sleep 0.1
        done
        if /bin/kill -0 "$pid" 2>/dev/null; then
            /bin/kill -KILL "$pid" 2>/dev/null || true
        fi
    fi
    wait "$pid" 2>/dev/null || true
    if /bin/kill -0 "$pid" 2>/dev/null; then
        printf 'VAL-005 could not terminate %s process %s\n' "$label" "$pid" >&2
        return 1
    fi
}

cleanup_processes() {
    local failed=0

    terminate_child_process "$APP_PID" app || failed=1
    APP_PID=""
    APP_ISOLATION_TOKEN=""
    APP_POLLING_VISIBILITY_PROOF=""
    APP_APPLICATION_STATE_PROOF=""
    APP_INSTRUMENTATION_TRACE=""

    terminate_child_process "$MOCK_PID" mock || failed=1
    MOCK_PID=""
    return "$failed"
}

cleanup() {
    local original_exit_code=$?
    trap - EXIT INT TERM
    local cleanup_failed=0
    cleanup_processes || cleanup_failed=1
    local defaults_suite
    for defaults_suite in "${PERFORMANCE_DEFAULTS_SUITES[@]}"; do
        /usr/bin/defaults delete "$defaults_suite" >/dev/null 2>&1 || true
    done
    if (( REAL_FINGERPRINTS_CAPTURED == 1 )); then
        local profile_after defaults_after
        if ! profile_after="$(fingerprint_file "$REAL_PROFILE_FILE")"; then
            printf 'VAL-005 cleanup could not fingerprint the real profile file\n' >&2
            cleanup_failed=1
        elif [[ "$profile_after" != "$REAL_PROFILE_BEFORE" ]]; then
            printf 'VAL-005 cleanup detected a changed real profile fingerprint\n' >&2
            cleanup_failed=1
        fi
        if ! defaults_after="$(fingerprint_file "$REAL_DEFAULTS_FILE")"; then
            printf 'VAL-005 cleanup could not fingerprint the real defaults file\n' >&2
            cleanup_failed=1
        elif [[ "$defaults_after" != "$REAL_DEFAULTS_BEFORE" ]]; then
            printf 'VAL-005 cleanup detected a changed real defaults fingerprint\n' >&2
            cleanup_failed=1
        fi
    fi
    if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" ]]; then
        /bin/rm -rf "$TMP_ROOT"
    fi
    if (( cleanup_failed == 1 )); then
        exit 1
    fi
    exit "$original_exit_code"
}

trap 'exit 130' INT TERM
trap cleanup EXIT

require_command() {
    [[ -x "$1" ]] || fail "required executable is unavailable: $1"
}

require_positive_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || fail "$name must be a positive integer"
}

require_nonnegative_integer() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$name must be a non-negative integer"
}

require_nonnegative_decimal() {
    local name="$1"
    local value="$2"
    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || fail "$name must be a non-negative number"
}

console_lock_state() {
    /usr/sbin/ioreg -n Root -d 1 -a \
        | /usr/bin/python3 -c '
import plistlib
import sys

try:
    payload = sys.stdin.buffer.read()
    registry = plistlib.loads(payload)
except Exception:
    raise SystemExit(2)
if isinstance(registry, dict):
    entries = [registry]
elif isinstance(registry, list):
    entries = registry
else:
    raise SystemExit(3)
roots = [
    entry
    for entry in entries
    if isinstance(entry, dict) and "IOConsoleLocked" in entry
]
if len(roots) != 1:
    raise SystemExit(4)
root = roots[0]
locked = root["IOConsoleLocked"]
if type(locked) is not bool:
    raise SystemExit(5)
print("locked" if locked else "unlocked")
'
}

assert_console_unlocked() {
    local label="$1"
    local lock_state
    if ! lock_state="$(console_lock_state)"; then
        fail "$label could not obtain a valid IOConsoleLocked boolean from the Root IORegistry plist"
    fi
    [[ "$lock_state" == "unlocked" ]] \
        || fail "$label requires the local macOS console to remain unlocked"
}

sleep_unlocked_warmup() {
    local duration_seconds="$1"
    local label="$2"
    local elapsed=0
    local warmup_started
    [[ "$duration_seconds" =~ ^[1-9][0-9]*$ ]] \
        || fail "$label warmup duration must be a positive integer"
    assert_console_unlocked "$label warmup initial state"
    warmup_started="$(monotonic_seconds)"
    while (( elapsed < duration_seconds )); do
        assert_console_unlocked "$label warmup sample $((elapsed + 1))"
        elapsed=$(( elapsed + SAMPLE_INTERVAL_SECONDS ))
        (( elapsed > duration_seconds )) && elapsed="$duration_seconds"
        sleep_until_elapsed "$warmup_started" "$elapsed"
        assert_console_unlocked "$label warmup sample $elapsed completion"
    done
    assert_console_unlocked "$label warmup final state"
}

fingerprint_file() {
    local path="$1"
    if [[ ! -e "$path" ]]; then
        printf 'absent'
        return
    fi
    [[ -f "$path" ]] || return 2
    /usr/bin/stat -f '%z:%m:' "$path"
    /usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{print $1}'
}

assert_decimal_at_most() {
    local label="$1"
    local actual="$2"
    local maximum="$3"
    /usr/bin/awk -v actual="$actual" -v maximum="$maximum" 'BEGIN { exit !(actual <= maximum) }' \
        || fail "$label $actual exceeded threshold $maximum"
}

assert_integer_between() {
    local label="$1"
    local actual="$2"
    local minimum="$3"
    local maximum="$4"
    (( actual >= minimum && actual <= maximum )) \
        || fail "$label $actual was outside threshold $minimum..$maximum"
}

record_decimal_below() {
    local label="$1"
    local actual="$2"
    local maximum="$3"
    if ! /usr/bin/awk -v actual="$actual" -v maximum="$maximum" 'BEGIN { exit !(actual < maximum) }'; then
        GATE_FAILURES+=("$label $actual did not remain below $maximum")
    fi
}

record_decimal_at_most() {
    local label="$1"
    local actual="$2"
    local maximum="$3"
    if ! /usr/bin/awk -v actual="$actual" -v maximum="$maximum" 'BEGIN { exit !(actual <= maximum) }'; then
        GATE_FAILURES+=("$label $actual exceeded $maximum")
    fi
}

record_integer_at_most() {
    local label="$1"
    local actual="$2"
    local maximum="$3"
    if (( actual > maximum )); then
        GATE_FAILURES+=("$label $actual exceeded $maximum")
    fi
}

record_integer_below() {
    local label="$1"
    local actual="$2"
    local maximum="$3"
    if (( actual >= maximum )); then
        GATE_FAILURES+=("$label $actual did not remain below $maximum")
    fi
}

record_integer_at_least() {
    local label="$1"
    local actual="$2"
    local minimum="$3"
    if (( actual < minimum )); then
        GATE_FAILURES+=("$label $actual was below $minimum")
    fi
}

record_decimal_at_least() {
    local label="$1"
    local actual="$2"
    local minimum="$3"
    if ! /usr/bin/awk -v actual="$actual" -v minimum="$minimum" 'BEGIN { exit !(actual >= minimum) }'; then
        GATE_FAILURES+=("$label $actual was below $minimum")
    fi
}

verify_installed_app() {
    [[ "$APP_BUNDLE" == /Applications/*.app ]] \
        || fail "APP_BUNDLE must be an installed /Applications bundle"
    [[ -d "$APP_BUNDLE" && -x "$APP_BINARY" ]] \
        || fail "installed app binary is missing: $APP_BINARY"

    local bundle_id
    bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null)"
    [[ "$bundle_id" == "$APP_BUNDLE_ID" ]] \
        || fail "unexpected installed bundle identifier: $bundle_id"
    /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" 2>/dev/null \
        || fail "installed app signature verification failed"

    local signature
    signature="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
    [[ "$signature" == *"TeamIdentifier="* && "$signature" != *"TeamIdentifier=not set"* ]] \
        || fail "installed app has no stable signing team"
    if ! /usr/bin/strings -a "$APP_BINARY" \
        | /usr/bin/grep -F "$PERFORMANCE_ISOLATION_COMPILED_MARKER" >/dev/null; then
        fail "installed app lacks the DEBUG-only password-store isolation hook; refusing to launch before any Keychain access"
    fi
    if ! /usr/bin/strings -a "$APP_BINARY" \
        | /usr/bin/grep -F "$PERFORMANCE_INSTRUMENTATION_ENVIRONMENT_KEY" >/dev/null; then
        fail "installed app lacks the DEBUG-only performance instrumentation hook"
    fi
    if ! /usr/bin/strings -a "$APP_BINARY" \
        | /usr/bin/grep -F "$PERFORMANCE_DETAIL_TARGET_ENVIRONMENT_KEY" >/dev/null; then
        fail "installed app lacks the DEBUG-only exact detail-target hook"
    fi
    if [[ "$CAPTURE_MODE" != "smoke" ]]; then
        if ! /usr/bin/strings -a "$APP_BINARY" \
            | /usr/bin/grep -F "$PERFORMANCE_APPLICATION_STATE_ENVIRONMENT_KEY" >/dev/null; then
            fail "installed app lacks the DEBUG-only application-state proof request hook"
        fi
        if ! /usr/bin/strings -a "$APP_BINARY" \
            | /usr/bin/grep -F "$PERFORMANCE_APPLICATION_STATE_MARKER" >/dev/null; then
            fail "installed app lacks the DEBUG-only application-state proof hook"
        fi
    fi
}

verify_port_is_free() {
    if /usr/sbin/lsof -nP -iTCP:"$MOCK_PORT" -sTCP:LISTEN 2>/dev/null | /usr/bin/awk 'NR == 2 { found = 1 } END { exit !found }'; then
        fail "mock port $MOCK_PORT is already in use"
    fi
}

write_profile() {
    local phase_home="$1"
    local phase="$2"
    local connect_on_launch="$3"
    local profile_id
    profile_id="$(/usr/bin/uuidgen)"
    local profile_dir="$phase_home/Library/Application Support/TransmissionRemoteMac"
    /bin/mkdir -p "$profile_dir" "$phase_home/Library/Preferences" "$phase_home/tmp"
    /usr/bin/uuidgen > "$phase_home/$PERFORMANCE_ISOLATION_REQUEST_MARKER"
    /bin/cat > "$profile_dir/ConnectionProfiles.json" <<EOF
{
  "profiles" : [
    {
      "askPasswordAtConnect" : false,
      "autoReconnect" : false,
      "connectOnLaunch" : $connect_on_launch,
      "host" : "$MOCK_HOST",
      "id" : "$profile_id",
      "name" : "VAL-005 $phase mock",
      "pathMappings" : [],
      "port" : $MOCK_PORT,
      "proxySettings" : {
        "authenticationEnabled" : false,
        "host" : "",
        "port" : 8080,
        "transport" : "direct",
        "username" : ""
      },
      "requestTimeoutSeconds" : 30,
      "rpcPath" : "/transmission/rpc",
      "scheme" : "http",
      "transferPreferences" : {
        "addDestinationHistory" : [],
        "addDestinationRules" : {
          "rules" : []
        },
        "destinationHistoryLimit" : 50,
        "downloadSpeedPresetsKBps" : [50, 100, 250, 500, 1000, 2500],
        "moveDestinationHistory" : [],
        "schemaVersion" : 2,
        "uploadSpeedPresetsKBps" : [10, 25, 50, 100, 250, 500]
      },
      "username" : ""
    }
  ],
  "selectedProfileID" : "$profile_id"
}
EOF
}

verify_foundation_isolation() {
    local phase_home="$1"
    local resolved_home
    local canonical_phase_home
    local canonical_resolved_home
    resolved_home="$(
        /usr/bin/env -i \
            HOME="$phase_home" \
            CFFIXED_USER_HOME="$phase_home" \
            CFPREFERENCES_AVOID_DAEMON=1 \
            PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
            /usr/bin/osascript -l JavaScript \
                -e 'ObjC.import("Foundation"); ObjC.unwrap($.NSHomeDirectory())'
    )"
    canonical_phase_home="$(cd "$phase_home" && /bin/pwd -P)"
    canonical_resolved_home="$(cd "$resolved_home" && /bin/pwd -P)"
    [[ "$canonical_resolved_home" == "$canonical_phase_home" ]] \
        || fail "Foundation isolation resolved $resolved_home instead of $phase_home"
}

write_network_sandbox() {
    local sandbox_file="$1"
    /bin/cat > "$sandbox_file" <<EOF
(version 1)
(allow default)
(deny network*)
(allow network-outbound (remote ip "$SANDBOX_REMOTE_HOST:$MOCK_PORT"))
EOF
}

validate_network_sandbox() {
    local sandbox_file="$1"
    local parser_output
    if ! parser_output="$(/usr/bin/sandbox-exec -f "$sandbox_file" /usr/bin/true 2>&1)"; then
        fail "Seatbelt rejected the generated network profile: $parser_output"
    fi
}

start_mock() {
    local phase_dir="$1"
    local torrent_count="${2:-1000}"
    local include_large_detail="${3:-false}"
    case "$torrent_count" in
        0|100|1000) ;;
        *) fail "unsupported internal torrent count: $torrent_count" ;;
    esac
    [[ "$include_large_detail" == "true" || "$include_large_detail" == "false" ]] \
        || fail "invalid internal large-detail mode: $include_large_detail"
    verify_port_is_free
    local -a mock_arguments=(
        --host "$MOCK_HOST"
        --port "$MOCK_PORT"
        --torrent-count "$torrent_count"
        --response-delay-ms "$MOCK_RESPONSE_DELAY_MS"
    )
    if [[ "$include_large_detail" == "true" ]]; then
        mock_arguments+=(--large-detail-torrent)
    fi
    /usr/bin/python3 "$ROOT_DIR/script/mock_transmission_rpc.py" \
        "${mock_arguments[@]}" \
        >"$phase_dir/mock.log" 2>&1 &
    MOCK_PID=$!

    local ready=0
    for _ in {1..100}; do
        if ! /bin/kill -0 "$MOCK_PID" 2>/dev/null; then
            /usr/bin/tail -n 20 "$phase_dir/mock.log" >&2 || true
            fail "mock exited before becoming ready"
        fi
        if /usr/bin/curl --noproxy '*' --fail --silent --show-error \
            "http://$MOCK_HOST:$MOCK_PORT/__mock__/state" >/dev/null 2>&1; then
            ready=1
            break
        fi
        /bin/sleep 0.05
    done
    (( ready == 1 )) || fail "mock did not become ready"
}

start_isolated_app() {
    local phase_dir="$1"
    local phase_home="$2"
    local sandbox_file="$3"
    local background_policy="$4"
    local select_detail="${5:-false}"
    local profile_file="$phase_home/Library/Application Support/TransmissionRemoteMac/ConnectionProfiles.json"
    local profile_hash_before
    profile_hash_before="$(fingerprint_file "$profile_file")"
    local request_marker="$phase_home/$PERFORMANCE_ISOLATION_REQUEST_MARKER"
    local isolation_token
    isolation_token="$(/usr/bin/awk '{$1=$1; print}' "$request_marker")"
    [[ ${#isolation_token} -ge 32 ]] || fail "performance-isolation token is invalid"
    APP_ISOLATION_TOKEN="$isolation_token"
    APP_POLLING_VISIBILITY_PROOF="$phase_home/tmp/$PERFORMANCE_POLLING_VISIBILITY_PROOF"
    APP_APPLICATION_STATE_PROOF="$phase_home/tmp/$PERFORMANCE_APPLICATION_STATE_PROOF"
    APP_INSTRUMENTATION_TRACE="$phase_home/tmp/$PERFORMANCE_INSTRUMENTATION_TRACE"
    local defaults_suite="$APP_BUNDLE_ID.performance.$isolation_token"
    PERFORMANCE_DEFAULTS_SUITES+=("$defaults_suite")
    local runner_bundle_id="$APP_BUNDLE_ID.performance.runner-$isolation_token"
    PERFORMANCE_DEFAULTS_SUITES+=("$runner_bundle_id")
    local phase_bundle="$phase_dir/TransmissionRemoteMac-$isolation_token.app"
    local phase_binary="$phase_bundle/Contents/MacOS/TransmissionRemoteMac"
    /usr/bin/ditto "$APP_BUNDLE" "$phase_bundle"
    /usr/bin/plutil -replace CFBundleIdentifier -string "$runner_bundle_id" \
        "$phase_bundle/Contents/Info.plist"
    /usr/bin/codesign --force --deep --sign - "$phase_bundle" >/dev/null \
        || fail "could not sign the isolated performance app copy"
    [[ "$(/usr/bin/defaults read "$phase_bundle/Contents/Info.plist" CFBundleIdentifier)" == "$runner_bundle_id" ]] \
        || fail "isolated performance app copy kept the production bundle identifier"
    local activation_proof="$phase_home/$PERFORMANCE_ISOLATION_ACTIVATION_PROOF"
    [[ ! -e "$activation_proof" ]] || fail "stale password-store activation proof exists"
    local wake_trace="$phase_home/tmp/$PERFORMANCE_WAKE_TRACE"
    local detail_selection_proof="$phase_home/tmp/$PERFORMANCE_DETAIL_SELECTION_PROOF"
    [[ ! -e "$APP_POLLING_VISIBILITY_PROOF" ]] \
        || fail "stale performance polling-visibility proof exists"
    [[ ! -e "$APP_APPLICATION_STATE_PROOF" ]] \
        || fail "stale performance application-state proof exists"
    [[ ! -e "$APP_INSTRUMENTATION_TRACE" ]] \
        || fail "stale performance instrumentation trace exists"
    [[ ! -e "$wake_trace" ]] || fail "stale performance wake trace exists"
    [[ ! -e "$detail_selection_proof" ]] || fail "stale performance detail-selection proof exists"
    local wake_recording=0
    local detail_selection=0
    if [[ "$CAPTURE_MODE" == "mock-debug-acceptance" ]]; then
        wake_recording=1
    fi
    if [[ "$select_detail" == "true" ]]; then
        [[ "$CAPTURE_MODE" == "mock-debug-acceptance" ]] \
            || fail "headless detail selection is mock DEBUG acceptance only"
        detail_selection=1
    elif [[ "$select_detail" != "false" ]]; then
        fail "invalid headless detail-selection mode: $select_detail"
    fi

    local -a acceptance_environment=()
    if [[ "$CAPTURE_MODE" != "smoke" ]]; then
        acceptance_environment+=(
            "$PERFORMANCE_APPLICATION_STATE_ENVIRONMENT_KEY=1"
        )
    fi
    /usr/bin/env -i \
        HOME="$phase_home" \
        CFFIXED_USER_HOME="$phase_home" \
        CFPREFERENCES_AVOID_DAEMON=1 \
        TMPDIR="$phase_home/tmp" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        LANG="en_AU.UTF-8" \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_ISOLATION=1 \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_HOME="$phase_home" \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_TOKEN="$isolation_token" \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_DEFAULTS_SUITE="$defaults_suite" \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_FOREGROUND_INTERVAL="$FOREGROUND_INTERVAL_SECONDS" \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_BACKGROUND_INTERVAL=20 \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_BACKGROUND_POLICY="$background_policy" \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_WAKE_RECORDING="$wake_recording" \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_DETAIL_SELECTION="$detail_selection" \
        "$PERFORMANCE_DETAIL_TARGET_ENVIRONMENT_KEY"="$PERFORMANCE_DETAIL_TARGET_ID" \
        TRANSMISSION_REMOTE_MAC_PERFORMANCE_VISIBILITY_PROOF=1 \
        "$PERFORMANCE_INSTRUMENTATION_ENVIRONMENT_KEY"=1 \
        "${acceptance_environment[@]}" \
        /usr/bin/sandbox-exec -f "$sandbox_file" "$phase_binary" \
        >"$phase_dir/app.log" 2>&1 &
    APP_PID=$!

    /bin/sleep 2
    if ! /bin/kill -0 "$APP_PID" 2>/dev/null; then
        /usr/bin/tail -n 40 "$phase_dir/app.log" >&2 || true
        fail "isolated app exited during startup"
    fi
    local process_name
    process_name="$(/bin/ps -p "$APP_PID" -o comm= | /usr/bin/awk '{$1=$1; print}')"
    [[ "${process_name##*/}" == "TransmissionRemoteMac" ]] \
        || fail "captured PID is not TransmissionRemoteMac: $process_name"
    if [[ "$CAPTURE_MODE" == "mock-debug-acceptance" ]]; then
        process_physical_footprint_bytes "$APP_PID" >/dev/null \
            || fail "physical-footprint preflight failed before long sampling"
    fi
    activate_isolated_app
    local expected_proof actual_proof
    expected_proof="$PERFORMANCE_ISOLATION_COMPILED_MARKER
$isolation_token"
    [[ -f "$activation_proof" ]] || fail "DEBUG password-store isolation did not produce runtime activation proof"
    actual_proof="$(/usr/bin/awk 'NF { print }' "$activation_proof")"
    [[ "$actual_proof" == "$expected_proof" ]] \
        || fail "DEBUG password-store isolation activation proof did not match this temporary home"
    [[ ! -e "$request_marker" ]] \
        || fail "DEBUG password-store isolation did not consume its one-use request marker"
    [[ "$(fingerprint_file "$profile_file")" == "$profile_hash_before" ]] \
        || fail "the isolated profile was unexpectedly rewritten"
}

isolated_process_state() {
    local pid="${1:-$APP_PID}"
    /usr/bin/osascript -l JavaScript -e "
ObjC.import('AppKit');
const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier($pid);
if (!app) throw new Error('TransmissionRemoteMac process not found');
const active = Boolean(app.active);
const hidden = Boolean(app.hidden);
(active ? 'active' : 'inactive') + ' ' + (hidden ? 'hidden' : 'unhidden');
"
}

polling_visibility_proof_state() {
    [[ -n "$APP_POLLING_VISIBILITY_PROOF" && -n "$APP_ISOLATION_TOKEN" ]] || return 1
    /usr/bin/python3 - \
        "$APP_POLLING_VISIBILITY_PROOF" \
        "$APP_ISOLATION_TOKEN" \
        "$PERFORMANCE_POLLING_VISIBILITY_MARKER" <<'PY'
import os
import stat
import sys

path, token, marker = sys.argv[1:]
descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or stat.S_IMODE(opened.st_mode) != 0o600:
        raise SystemExit(1)
    if opened.st_size <= 0 or opened.st_size > 256:
        raise SystemExit(1)
    payload = b""
    while len(payload) < opened.st_size:
        chunk = os.read(descriptor, opened.st_size - len(payload))
        if not chunk:
            break
        payload += chunk
finally:
    os.close(descriptor)
current = os.lstat(path)
if not stat.S_ISREG(current.st_mode):
    raise SystemExit(1)
if (opened.st_dev, opened.st_ino, opened.st_size) != (
    current.st_dev,
    current.st_ino,
    current.st_size,
):
    raise SystemExit(1)
try:
    text = payload.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(1)
parts = text.splitlines()
if len(parts) != 3 or parts[0] != marker or parts[1] != token:
    raise SystemExit(1)
if parts[2] not in {"foreground", "background"} or not text.endswith("\n"):
    raise SystemExit(1)
print(parts[2])
PY
}

application_state_proof() {
    [[ -n "$APP_APPLICATION_STATE_PROOF" && -n "$APP_ISOLATION_TOKEN" ]] || return 1
    /usr/bin/python3 - \
        "$APP_APPLICATION_STATE_PROOF" \
        "$APP_ISOLATION_TOKEN" \
        "$PERFORMANCE_APPLICATION_STATE_MARKER" <<'PY'
import os
import stat
import sys

path, token, marker = sys.argv[1:]
descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
try:
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or stat.S_IMODE(opened.st_mode) != 0o600:
        raise SystemExit(1)
    if opened.st_size <= 0 or opened.st_size > 256:
        raise SystemExit(1)
    payload = b""
    while len(payload) < opened.st_size:
        chunk = os.read(descriptor, opened.st_size - len(payload))
        if not chunk:
            break
        payload += chunk
finally:
    os.close(descriptor)
current = os.lstat(path)
if not stat.S_ISREG(current.st_mode):
    raise SystemExit(1)
if (opened.st_dev, opened.st_ino, opened.st_size) != (
    current.st_dev,
    current.st_ino,
    current.st_size,
):
    raise SystemExit(1)
try:
    text = payload.decode("utf-8")
except UnicodeDecodeError:
    raise SystemExit(1)
parts = text.splitlines()
if len(parts) != 4 or parts[0] != marker or parts[1] != token or not text.endswith("\n"):
    raise SystemExit(1)
activation_prefix = "activation_count="
window_prefix = "main_window_visible_nonminiaturized="
if not parts[2].startswith(activation_prefix) or not parts[3].startswith(window_prefix):
    raise SystemExit(1)
activation_count = parts[2][len(activation_prefix):]
window_state = parts[3][len(window_prefix):]
if not activation_count.isdigit() or window_state not in {"true", "false"}:
    raise SystemExit(1)
print(f"{int(activation_count)} {window_state}")
PY
}

assert_application_state_proof() {
    local expected_main_window_state="$1"
    local label="$2"
    [[ "$CAPTURE_MODE" != "smoke" ]] || return
    local proof activation_count main_window_state
    proof="$(application_state_proof)" \
        || fail "$label could not read the validated in-app application-state proof"
    read -r activation_count main_window_state <<< "$proof"
    (( activation_count >= 1 )) \
        || fail "$label did not record the native application activation"
    [[ "$main_window_state" == "$expected_main_window_state" ]] \
        || fail "$label expected main_window_visible_nonminiaturized=$expected_main_window_state but sampled $main_window_state"
}

wait_for_application_state_proof() {
    local expected_main_window_state="$1"
    local label="$2"
    [[ "$CAPTURE_MODE" != "smoke" ]] || return
    local sampled_application_state="unavailable"
    local sampled_activation_count=""
    local sampled_main_window_state=""
    for (( attempt = 0; attempt < 300; attempt++ )); do
        /bin/kill -0 "$APP_PID" 2>/dev/null \
            || fail "$label app exited before emitting its application-state proof"
        sampled_application_state="$(application_state_proof 2>/dev/null || true)"
        read -r sampled_activation_count sampled_main_window_state \
            <<< "$sampled_application_state"
        if [[ "$sampled_activation_count" =~ ^[1-9][0-9]*$ \
            && "$sampled_main_window_state" == "$expected_main_window_state" ]]; then
            return
        fi
        /bin/sleep 0.1
    done
    fail "$label expected native activation_count>=1 and main_window_visible_nonminiaturized=$expected_main_window_state but sampled ${sampled_application_state:-unavailable}"
}

wait_for_polling_visibility_proof() {
    local expected_state="$1"
    local label="$2"
    local sampled_state="unavailable"
    for (( attempt = 0; attempt < 50; attempt++ )); do
        /bin/kill -0 "$APP_PID" 2>/dev/null \
            || fail "$label app exited before emitting polling-visibility proof"
        sampled_state="$(polling_visibility_proof_state 2>/dev/null || true)"
        if [[ "$sampled_state" == "$expected_state" ]]; then
            return
        fi
        /bin/sleep 0.1
    done
    fail "$label expected AppDelegate polling visibility $expected_state but sampled ${sampled_state:-unavailable}"
}

wait_for_isolated_app_foreground() {
    local label="$1"
    local sampled_process_state="unavailable"
    local sampled_polling_visibility="unavailable"
    local sampled_application_state="unavailable"
    for (( attempt = 0; attempt < 300; attempt++ )); do
        /bin/kill -0 "$APP_PID" 2>/dev/null \
            || fail "$label app exited before reaching foreground"
        sampled_process_state="$(isolated_process_state "$APP_PID" 2>/dev/null || true)"
        sampled_polling_visibility="$(polling_visibility_proof_state 2>/dev/null || true)"
        sampled_application_state="$(application_state_proof 2>/dev/null || true)"
        if [[ "$sampled_process_state" == "active unhidden" \
            && "$sampled_polling_visibility" == "foreground" ]]; then
            if [[ "$CAPTURE_MODE" == "smoke" \
                || "$sampled_application_state" =~ ^[1-9][0-9]*\ true$ ]]; then
                return
            fi
        fi
        /bin/sleep 0.1
    done
    fail "$label expected active unhidden process state, AppDelegate polling visibility foreground, native activation_count>=1, and a visible non-miniaturized main window but sampled ${sampled_process_state:-unavailable}, ${sampled_polling_visibility:-unavailable} polling, and application state ${sampled_application_state:-unavailable}"
}

assert_isolated_app_state() {
    local pid="$1"
    local expected="$2"
    local label="$3"
    local expected_process_state expected_polling_visibility expected_main_window_state
    local process_state polling_visibility
    case "$expected" in
        foreground)
            expected_process_state="active unhidden"
            expected_polling_visibility="foreground"
            expected_main_window_state="true"
            ;;
        background)
            expected_process_state="inactive unhidden"
            expected_polling_visibility="background"
            expected_main_window_state="true"
            ;;
        hidden)
            expected_process_state="inactive hidden"
            expected_polling_visibility="background"
            expected_main_window_state="false"
            ;;
        *) fail "invalid isolated app state assertion: $expected" ;;
    esac
    process_state="$(isolated_process_state "$pid")" \
        || fail "$label could not inspect isolated app PID $pid"
    [[ "$process_state" == "$expected_process_state" ]] \
        || fail "$label expected PID $pid to remain $expected_process_state but sampled $process_state"
    polling_visibility="$(polling_visibility_proof_state)" \
        || fail "$label could not read the validated AppDelegate polling-visibility proof"
    [[ "$polling_visibility" == "$expected_polling_visibility" ]] \
        || fail "$label expected AppDelegate polling visibility $expected_polling_visibility but sampled $polling_visibility"
    assert_application_state_proof "$expected_main_window_state" "$label"
}

verify_isolated_app_foreground() {
    assert_isolated_app_state "$APP_PID" foreground "foreground verification"
}

verify_isolated_app_hidden() {
    assert_isolated_app_state "$APP_PID" hidden "hidden verification"
}

verify_isolated_app_background() {
    assert_isolated_app_state "$APP_PID" background "inactive-visible verification"
}

activate_isolated_app() {
    /usr/bin/osascript -l JavaScript -e "
ObjC.import('AppKit');
const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier($APP_PID);
if (!app) throw new Error('TransmissionRemoteMac process not found');
app.performSelector('unhide');
app.activateWithOptions(3);
for (let attempt = 0; attempt < 50; attempt++) {
    if (Boolean(app.active) && !Boolean(app.hidden)) break;
    $.NSThread.sleepForTimeInterval(0.1);
}
" >/dev/null || fail "could not activate the isolated app"
    wait_for_isolated_app_foreground "foreground activation"
}

deactivate_isolated_app() {
    /usr/bin/osascript -l JavaScript -e "
ObjC.import('AppKit');
const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier($APP_PID);
if (!app) throw new Error('TransmissionRemoteMac process not found');
const finders = $.NSRunningApplication.runningApplicationsWithBundleIdentifier('com.apple.finder');
if (finders.count < 1) throw new Error('Finder process not found');
const finder = finders.objectAtIndex(0);
finder.activateWithOptions(3);
for (let attempt = 0; attempt < 50; attempt++) {
    if (!Boolean(app.active) && !Boolean(app.hidden)) break;
    $.NSThread.sleepForTimeInterval(0.1);
}
" >/dev/null || fail "could not deactivate the isolated app without hiding it"
    wait_for_polling_visibility_proof background "inactive-visible transition"
    verify_isolated_app_background
}

disconnect_isolated_app_through_menu() {
    if ! /usr/bin/osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
    tell first application process whose unix id is $APP_PID
        tell menu bar 1
            tell menu bar item "Connection"
                tell menu "Connection"
                    click menu item "Disconnect"
                end tell
            end tell
        end tell
    end tell
end tell
APPLESCRIPT
    then
        fail "could not invoke Connection > Disconnect for the stale-generation probe"
    fi
}

hide_isolated_app() {
    /usr/bin/osascript -l JavaScript -e "
ObjC.import('AppKit');
const app = $.NSRunningApplication.runningApplicationWithProcessIdentifier($APP_PID);
if (!app) throw new Error('TransmissionRemoteMac process not found');
app.performSelector('hide');
for (let attempt = 0; attempt < 50; attempt++) {
    if (!Boolean(app.active) && Boolean(app.hidden)) break;
    $.NSThread.sleepForTimeInterval(0.1);
}
" >/dev/null || fail "could not hide the isolated app"
    wait_for_polling_visibility_proof background "hidden transition"
    wait_for_application_state_proof false "hidden transition"
    verify_isolated_app_hidden
}

process_cpu_seconds() {
    local pid="$1"
    local elapsed
    elapsed="$(/bin/ps -p "$pid" -o time= | /usr/bin/awk '{$1=$1; print}')" \
        || return 1
    [[ -n "$elapsed" ]] || return 1
    /usr/bin/python3 -c '
import sys
value = sys.argv[1]
days = 0
if "-" in value:
    day_text, value = value.split("-", 1)
    days = int(day_text)
parts = value.split(":")
if len(parts) == 3:
    hours, minutes, seconds = int(parts[0]), int(parts[1]), float(parts[2])
elif len(parts) == 2:
    hours, minutes, seconds = 0, int(parts[0]), float(parts[1])
else:
    raise SystemExit(1)
print(days * 86400 + hours * 3600 + minutes * 60 + seconds)
' "$elapsed"
}

process_rss_bytes() {
    local pid="$1"
    local rss_kib
    rss_kib="$(/bin/ps -p "$pid" -o rss= | /usr/bin/awk '{$1=$1; print}')" \
        || return 1
    [[ "$rss_kib" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "$(( rss_kib * 1024 ))"
}

process_physical_footprint_bytes() {
    local pid="$1"
    local output current peak
    output="$(/usr/bin/footprint --pid "$pid" --noCategories --format bytes 2>&1)" \
        || return 1
    current="$(printf '%s\n' "$output" | /usr/bin/awk '/^[[:space:]]*phys_footprint:/ { print $2; exit }')"
    peak="$(printf '%s\n' "$output" | /usr/bin/awk '/^[[:space:]]*phys_footprint_peak:/ { print $2; exit }')"
    [[ "$current" =~ ^[1-9][0-9]*$ && "$peak" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s %s' "$current" "$peak"
}

monotonic_seconds() {
    /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
        -e 'print clock_gettime(CLOCK_MONOTONIC), qq(\n)'
}

sleep_until_elapsed() {
    local window_started="$1"
    local elapsed_seconds="$2"
    local now sleep_seconds
    now="$(monotonic_seconds)"
    sleep_seconds="$(/usr/bin/awk \
        -v started="$window_started" \
        -v elapsed="$elapsed_seconds" \
        -v now="$now" \
        'BEGIN {
            remaining = started + elapsed - now
            if (remaining < 0) remaining = 0
            printf "%.6f", remaining
        }')"
    /bin/sleep "$sleep_seconds"
}

restore_smoke_foreground_if_needed() {
    local pid="$1"
    local expected_state="$2"
    [[ "$CAPTURE_MODE" == "smoke" && "$expected_state" == "foreground" ]] || return

    local process_state
    process_state="$(isolated_process_state "$pid")" \
        || fail "could not inspect the smoke app before restoring foreground state"
    if [[ "$process_state" != "active unhidden" ]]; then
        activate_isolated_app
    fi
}

capture_state_window() {
    local pid="$1"
    local duration_seconds="$2"
    local expected_state="$3"
    local label="$4"
    local elapsed=0
    local window_started
    assert_console_unlocked "$label initial state"
    window_started="$(monotonic_seconds)"

    while (( elapsed < duration_seconds )); do
        assert_console_unlocked "$label sample $((elapsed + 1))"
        assert_isolated_app_state "$pid" "$expected_state" "$label"
        elapsed=$(( elapsed + SAMPLE_INTERVAL_SECONDS ))
        (( elapsed > duration_seconds )) && elapsed="$duration_seconds"
        sleep_until_elapsed "$window_started" "$elapsed"
        assert_console_unlocked "$label sample $elapsed completion"
    done
    assert_console_unlocked "$label final state"
    assert_isolated_app_state "$pid" "$expected_state" "$label"
}

capture_cpu() {
    local pid="$1"
    local sample_seconds="$2"
    local expected_state="$3"
    local label="$4"
    local samples=$(( (sample_seconds + SAMPLE_INTERVAL_SECONDS - 1) / SAMPLE_INTERVAL_SECONDS ))
    (( samples > 0 )) || samples=1
    local values=""
    local peak="0"
    local peak_rss_bytes="0"
    local cpu_started wall_started previous_cpu previous_wall
    assert_console_unlocked "$label initial CPU sample"
    cpu_started="$(process_cpu_seconds "$pid")" || fail "could not read initial process CPU time"
    wall_started="$(monotonic_seconds)"
    previous_cpu="$cpu_started"
    previous_wall="$wall_started"

    for (( sample = 0; sample < samples; sample++ )); do
        assert_console_unlocked "$label CPU sample $((sample + 1))/$samples"
        /bin/kill -0 "$pid" 2>/dev/null || fail "app exited during CPU capture"
        restore_smoke_foreground_if_needed "$pid" "$expected_state"
        assert_isolated_app_state "$pid" "$expected_state" "$label CPU sample $((sample + 1))/$samples"
        local elapsed_seconds=$(( (sample + 1) * SAMPLE_INTERVAL_SECONDS ))
        (( elapsed_seconds > sample_seconds )) && elapsed_seconds="$sample_seconds"
        sleep_until_elapsed "$wall_started" "$elapsed_seconds"
        assert_console_unlocked "$label CPU sample $((sample + 1))/$samples completion"
        restore_smoke_foreground_if_needed "$pid" "$expected_state"
        assert_isolated_app_state "$pid" "$expected_state" "$label CPU sample $((sample + 1))/$samples completion"

        local current_cpu current_wall interval_cpu current_rss_bytes
        current_cpu="$(process_cpu_seconds "$pid")" || fail "could not read process CPU time sample"
        current_rss_bytes="$(process_rss_bytes "$pid")" || fail "could not read process RSS sample"
        (( current_rss_bytes > peak_rss_bytes )) && peak_rss_bytes="$current_rss_bytes"
        current_wall="$(monotonic_seconds)"
        interval_cpu="$(
            /usr/bin/awk \
                -v previous_cpu="$previous_cpu" \
                -v current_cpu="$current_cpu" \
                -v previous_wall="$previous_wall" \
                -v current_wall="$current_wall" \
                'BEGIN {
                    cpu_delta = current_cpu - previous_cpu
                    wall_delta = current_wall - previous_wall
                    if (cpu_delta < 0 || wall_delta <= 0) exit 1
                    printf "%.4f", cpu_delta * 100 / wall_delta
                }'
        )" || fail "could not calculate interval CPU sample"
        values+="$interval_cpu\n"
        if /usr/bin/awk -v current="$interval_cpu" -v previous="$peak" 'BEGIN { exit !(current > previous) }'; then
            peak="$interval_cpu"
        fi
        previous_cpu="$current_cpu"
        previous_wall="$current_wall"
    done
    assert_console_unlocked "$label final CPU sample"
    assert_isolated_app_state "$pid" "$expected_state" "$label final CPU sample"

    local cpu_finished wall_finished cpu_delta wall_delta average
    cpu_finished="$previous_cpu"
    wall_finished="$previous_wall"
    read -r cpu_delta wall_delta average <<< "$(
        /usr/bin/awk \
            -v cpu_started="$cpu_started" \
            -v cpu_finished="$cpu_finished" \
            -v wall_started="$wall_started" \
            -v wall_finished="$wall_finished" \
            'BEGIN {
                cpu_delta = cpu_finished - cpu_started
                wall_delta = wall_finished - wall_started
                if (cpu_delta < 0 || wall_delta <= 0) exit 1
                printf "%.4f %.4f %.4f", cpu_delta, wall_delta, cpu_delta * 100 / wall_delta
            }'
    )" || fail "could not calculate process CPU-time delta"
    local percentile_rank=$(( (samples * 95 + 99) / 100 ))
    local p95
    p95="$(
        printf '%b' "$values" \
            | /usr/bin/sort -n \
            | /usr/bin/awk -v rank="$percentile_rank" '
                NR == rank { percentile = $1 }
                END { if (percentile != "") printf "%.2f", percentile }
            '
    )"
    [[ -n "$p95" ]] || fail "could not calculate CPU p95"
    printf '%s %s %s %s %s %s %s' \
        "$average" "$p95" "$peak" "$samples" "$cpu_delta" "$wall_delta" "$peak_rss_bytes"
}

mock_metrics() {
    /usr/bin/curl --noproxy '*' --fail --silent --show-error \
        "http://$MOCK_HOST:$MOCK_PORT/__mock__/state" \
        | /usr/bin/python3 -c '
import json
import sys
state = json.load(sys.stdin)
counts = state["methodRequestCounts"]
selector = state["lastTorrentGetSelector"]
if selector is None:
    selector = "none"
elif isinstance(selector, list) and all(isinstance(item, int) for item in selector):
    selector = "ids:" + ",".join(str(item) for item in selector)
elif not isinstance(selector, str) or any(character.isspace() for character in selector):
    raise SystemExit("lastTorrentGetSelector was not a supported selector")
print(
    state["requestCount"],
    counts.get("torrent-get", 0),
    state["recentlyActiveTorrentGetRequestCount"],
    counts.get("session-get", 0),
    counts.get("session-stats", 0),
    state["inFlightRequests"],
    state["maxInFlightRequests"],
    state["torrentCount"],
    selector,
    state["lastTorrentGetFieldCount"],
    state["lastTorrentGetRequestBytes"],
)
'
}

validate_performance_instrumentation() {
    local phase="$1"
    local expected_row_count="$2"
    local requirement="$3"
    local summary
    if ! summary="$(/usr/bin/python3 - \
        "$APP_INSTRUMENTATION_TRACE" \
        "$phase" \
        "$expected_row_count" \
        "$requirement" \
        "$PERFORMANCE_DETAIL_TARGET_ID" \
        "$RELEASE_MAIN_THREAD_P95_MAX_NANOSECONDS" \
        "$RELEASE_MAIN_THREAD_MAX_NANOSECONDS" \
        "$RELEASE_UI_TIMING_MAX_NANOSECONDS" \
        "$RELEASE_FILES_TIMING_MAX_NANOSECONDS" <<'PY'
import json
import math
import os
import stat
import sys
import uuid

(
    path,
    phase,
    expected_row_count_text,
    requirement,
    expected_files_torrent_id_text,
    main_p95_limit_text,
    main_max_limit_text,
    ui_limit_text,
    files_limit_text,
) = sys.argv[1:]
expected_row_count = int(expected_row_count_text)
expected_files_torrent_id = int(expected_files_torrent_id_text)
main_p95_limit = int(main_p95_limit_text)
main_max_limit = int(main_max_limit_text)
ui_limit = int(ui_limit_text)
files_limit = int(files_limit_text)
if requirement not in {"list", "large-list", "files", "stale"}:
    raise SystemExit(f"{phase}: unsupported instrumentation requirement {requirement}")
if expected_files_torrent_id <= 0:
    raise SystemExit(f"{phase}: invalid Files target torrent ID")


def reject(message):
    raise SystemExit(f"{phase}: {message}")


try:
    descriptor = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
except OSError as error:
    reject(f"instrumentation trace could not be opened safely: {error}")
try:
    opened = os.fstat(descriptor)
    if not stat.S_ISREG(opened.st_mode) or stat.S_IMODE(opened.st_mode) != 0o600:
        reject("instrumentation trace is not a private regular file")
    if opened.st_size <= 0 or opened.st_size > 1_048_576:
        reject(f"instrumentation trace size is invalid: {opened.st_size}")
    payload = b""
    while len(payload) < opened.st_size:
        chunk = os.read(descriptor, opened.st_size - len(payload))
        if not chunk:
            break
        payload += chunk
finally:
    os.close(descriptor)
current = os.lstat(path)
if not stat.S_ISREG(current.st_mode):
    reject("instrumentation trace path changed type")
if (opened.st_dev, opened.st_ino, opened.st_size) != (
    current.st_dev,
    current.st_ino,
    current.st_size,
):
    reject("instrumentation trace changed while being consumed")
if len(payload) != opened.st_size or not payload.endswith(b"\n"):
    reject("instrumentation trace was truncated")
try:
    text = payload.decode("utf-8")
except UnicodeDecodeError:
    reject("instrumentation trace was not UTF-8")
lines = text.splitlines()
if not lines or len(lines) > 8_192:
    reject(f"instrumentation record count is invalid: {len(lines)}")

allowed_keys = {
    "schemaVersion",
    "event",
    "outcome",
    "profileID",
    "connectionGeneration",
    "requestSequence",
    "durationNanoseconds",
    "torrentID",
    "revision",
    "rowCount",
    "fileCount",
    "selectedCount",
    "operation",
    "pane",
    "reason",
}
required_keys = {"schemaVersion", "event", "outcome", "durationNanoseconds"}
allowed_events = {
    "torrent_list_publication",
    "main_thread_apply",
    "list_projection",
    "cached_selection",
    "files_rpc_latency",
    "files_projection",
    "files_select_all",
    "files_mutation_plan",
    "files_pane_proof",
}
allowed_outcomes = {"accepted", "rejected", "measured", "proven"}
rejection_reasons = {"stale-owner", "field-plan", "accumulator", "bootstrap"}
projection_operations = {"search", "sort", "filter"}


def nonnegative_integer(value):
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def positive_integer(value):
    return nonnegative_integer(value) and value > 0


records = []
for index, line in enumerate(lines, start=1):
    try:
        record = json.loads(line)
    except json.JSONDecodeError as error:
        reject(f"record {index} is invalid JSON: {error}")
    if (
        not isinstance(record, dict)
        or not required_keys.issubset(record)
        or not set(record).issubset(allowed_keys)
    ):
        reject(f"record {index} has an unexpected schema")
    for name in allowed_keys - required_keys:
        record.setdefault(name, None)
    if record["schemaVersion"] != 1 or isinstance(record["schemaVersion"], bool):
        reject(f"record {index} has an unsupported schema version")
    if record["event"] not in allowed_events or record["outcome"] not in allowed_outcomes:
        reject(f"record {index} has an unsupported event or outcome")
    if not nonnegative_integer(record["durationNanoseconds"]):
        reject(f"record {index} has an invalid duration")
    for name in ("rowCount", "fileCount", "selectedCount"):
        if record[name] is not None and not nonnegative_integer(record[name]):
            reject(f"record {index} has an invalid {name}")
    if record["torrentID"] is not None and not positive_integer(record["torrentID"]):
        reject(f"record {index} has an invalid torrentID")
    for name in ("operation", "pane", "reason"):
        if record[name] is not None and not isinstance(record[name], str):
            reject(f"record {index} has an invalid {name}")
    for name in ("profileID", "connectionGeneration"):
        value = record[name]
        if value is not None:
            try:
                uuid.UUID(value)
            except (ValueError, TypeError, AttributeError):
                reject(f"record {index} has an invalid {name}")
    if record["revision"] is not None:
        try:
            uuid.UUID(record["revision"])
        except (ValueError, TypeError, AttributeError):
            reject(f"record {index} has an invalid revision")
    if record["requestSequence"] is not None and not positive_integer(record["requestSequence"]):
        reject(f"record {index} has an invalid requestSequence")

    event = record["event"]
    outcome = record["outcome"]
    has_owner = (
        record["profileID"] is not None
        and record["connectionGeneration"] is not None
        and positive_integer(record["requestSequence"])
    )
    if event == "torrent_list_publication":
        if not has_owner or record["rowCount"] is None:
            reject(f"record {index} has incomplete torrent publication ownership")
        if outcome == "accepted" and record["reason"] is not None:
            reject(f"record {index} gives an accepted publication a rejection reason")
        if outcome == "rejected" and record["reason"] not in rejection_reasons:
            reject(f"record {index} has an invalid publication rejection reason")
        if outcome not in {"accepted", "rejected"}:
            reject(f"record {index} has an invalid publication outcome")
    elif event == "main_thread_apply":
        if outcome != "measured" or not has_owner or record["rowCount"] is None:
            reject(f"record {index} has an invalid main-thread measurement")
    elif event == "list_projection":
        if (
            outcome != "measured"
            or record["rowCount"] is None
            or record["operation"] not in projection_operations
        ):
            reject(f"record {index} has an invalid list projection measurement")
    elif event == "cached_selection":
        if (
            outcome != "measured"
            or record["rowCount"] is None
            or record["selectedCount"] is None
            or record["operation"] != "lookup"
        ):
            reject(f"record {index} has an invalid cached-selection measurement")
    elif event == "files_rpc_latency":
        if (
            outcome != "measured"
            or record["torrentID"] is None
            or record["revision"] is None
            or record["fileCount"] is None
        ):
            reject(f"record {index} has an invalid Files RPC-latency measurement")
    elif event == "files_projection":
        if (
            outcome != "measured"
            or record["torrentID"] is None
            or record["revision"] is None
            or record["fileCount"] is None
            or record["rowCount"] is None
        ):
            reject(f"record {index} has an invalid Files projection measurement")
    elif event == "files_select_all":
        if (
            outcome != "measured"
            or record["torrentID"] is None
            or record["revision"] is None
            or record["fileCount"] is None
            or record["selectedCount"] is None
            or record["operation"] not in {"plan", "state-commit"}
        ):
            reject(f"record {index} has an invalid Files select-all measurement")
    elif event == "files_mutation_plan":
        if (
            outcome != "measured"
            or record["torrentID"] is None
            or record["revision"] is None
            or record["fileCount"] is None
            or record["selectedCount"] is None
            or record["operation"] != "selected-file-indexes"
        ):
            reject(f"record {index} has an invalid Files mutation-plan measurement")
    elif event == "files_pane_proof":
        if (
            record["torrentID"] is None
            or record["revision"] is None
            or record["fileCount"] is None
        ):
            reject(f"record {index} has an invalid Files pane proof")
        if outcome == "rejected":
            if record["reason"] != "stale-revision":
                reject(f"record {index} has an invalid Files pane rejection")
        elif (
            outcome != "proven"
            or record["pane"] != "files"
            or record["selectedCount"] is None
            or not positive_integer(record["durationNanoseconds"])
        ):
            reject(f"record {index} has an invalid Files pane proof")
    records.append(record)


def event_records(event, outcome=None):
    return [
        record
        for record in records
        if record["event"] == event and (outcome is None or record["outcome"] == outcome)
    ]


def percentile95(values):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * 0.95) - 1)]


accepted = event_records("torrent_list_publication", "accepted")
if not any(record["rowCount"] == expected_row_count for record in accepted):
    reject(f"no accepted full publication proved {expected_row_count} rows")
main_records = event_records("main_thread_apply", "measured")
if not main_records:
    reject("main-thread apply timing is missing")
main_durations = [record["durationNanoseconds"] for record in main_records]
main_p95 = percentile95(main_durations)
main_max = max(main_durations)
if main_p95 >= main_p95_limit:
    reject(f"main-thread apply p95 {main_p95}ns did not remain below {main_p95_limit}ns")
if main_max >= main_max_limit:
    reject(f"main-thread apply maximum {main_max}ns did not remain below {main_max_limit}ns")

ui_max = 0
if requirement == "large-list":
    projections = event_records("list_projection", "measured")
    for operation in projection_operations:
        matches = [
            record for record in projections
            if record["operation"] == operation and record["rowCount"] >= 1_000
        ]
        if not matches:
            reject(f"1,000-row {operation} timing is missing")
        duration = max(record["durationNanoseconds"] for record in matches)
        ui_max = max(ui_max, duration)
        if duration >= ui_limit:
            reject(f"1,000-row {operation} timing {duration}ns did not remain below {ui_limit}ns")
    cached = [
        record for record in event_records("cached_selection", "measured")
        if record["rowCount"] >= 1_000 and record["selectedCount"] == 10
    ]
    if not cached:
        reject("1,000-row cached selection timing is missing")
    cached_max = max(record["durationNanoseconds"] for record in cached)
    ui_max = max(ui_max, cached_max)
    if cached_max >= ui_limit:
        reject(f"cached selection timing {cached_max}ns did not remain below {ui_limit}ns")

files_rpc = files_projection = files_select_plan = files_state_commit = 0
files_mutation_plan = files_state_acknowledgement = 0
if requirement == "files":
    proof_records = [
        record for record in event_records("files_pane_proof", "proven")
        if record["torrentID"] == expected_files_torrent_id
        and record["fileCount"] >= 10_000
        and record["selectedCount"] >= 10_000
    ]
    if not proof_records:
        reject(f"10,000-file pane proof for torrent {expected_files_torrent_id} is missing")
    proof_revision = proof_records[-1]["revision"]

    def files_records(event, operation=None):
        return [
            record for record in event_records(event, "measured")
            if record["torrentID"] == expected_files_torrent_id
            and record["revision"] == proof_revision
            and record["fileCount"] >= 10_000
            and (operation is None or record["operation"] == operation)
        ]

    rpc_records = files_records("files_rpc_latency")
    projection_records = files_records("files_projection")
    select_plan_records = files_records("files_select_all", "plan")
    state_commit_records = files_records("files_select_all", "state-commit")
    mutation_plan_records = files_records("files_mutation_plan", "selected-file-indexes")
    if not rpc_records:
        reject("10,000-file RPC-latency proof is missing for the proven Files revision")
    if not projection_records:
        reject("10,000-file view projection timing is missing for the proven Files revision")
    if not select_plan_records:
        reject("10,000-file select-all planning timing is missing for the proven Files revision")
    if not state_commit_records:
        reject("10,000-file select-all state commit is missing for the proven Files revision")
    if not mutation_plan_records:
        reject("10,000-file regular-file mutation planning is missing for the proven Files revision")
    if not all(record["rowCount"] >= 10_000 for record in projection_records):
        reject("10,000-file view projection did not materialize the full visible tree")
    if not all(record["selectedCount"] >= 10_000 for record in select_plan_records):
        reject("10,000-file select-all plan did not cover every file")
    if not all(record["selectedCount"] >= 10_000 for record in state_commit_records):
        reject("10,000-file select-all state commit did not cover every file")
    if not all(record["selectedCount"] >= 10_000 for record in mutation_plan_records):
        reject("10,000-file mutation plan did not cover every regular file")

    files_rpc = max(record["durationNanoseconds"] for record in rpc_records)
    files_projection = max(record["durationNanoseconds"] for record in projection_records)
    files_select_plan = max(record["durationNanoseconds"] for record in select_plan_records)
    files_state_commit = max(record["durationNanoseconds"] for record in state_commit_records)
    files_mutation_plan = max(record["durationNanoseconds"] for record in mutation_plan_records)
    files_state_acknowledgement = max(
        record["durationNanoseconds"] for record in proof_records
        if record["revision"] == proof_revision
    )
    for label, duration in (
        ("projection", files_projection),
        ("select-all planning", files_select_plan),
        ("select-all state commit", files_state_commit),
        ("regular-file mutation planning", files_mutation_plan),
        ("state acknowledgement", files_state_acknowledgement),
    ):
        if duration >= files_limit:
            reject(f"10,000-file {label} timing {duration}ns did not remain below {files_limit}ns")

stale_rejections = 0
if requirement == "stale":
    indexed_records = list(enumerate(records))
    stale = [
        (index, record)
        for index, record in indexed_records
        if record["event"] == "torrent_list_publication"
        and record["outcome"] == "rejected"
        and record["reason"] == "stale-owner"
    ]
    if not stale:
        reject("no genuine stale-owner publication rejection was recorded")
    for rejected_index, rejected in stale:
        if any(
            later["event"] == "torrent_list_publication"
            and later["outcome"] == "accepted"
            and later["profileID"] == rejected["profileID"]
            and later["connectionGeneration"] == rejected["connectionGeneration"]
            for later in records[rejected_index + 1:]
        ):
            reject("an old connection generation published after stale-owner rejection")
    stale_rejections = len(stale)

print(
    f"instrumentation_phase={phase} schema_version=1 records={len(records)} "
    f"accepted_publications={len(accepted)} main_thread_samples={len(main_records)} "
    f"main_thread_p95_nanoseconds={main_p95} main_thread_max_nanoseconds={main_max} "
    f"ui_max_nanoseconds={ui_max} files_rpc_latency_nanoseconds={files_rpc} "
    f"files_projection_nanoseconds={files_projection} "
    f"files_select_plan_nanoseconds={files_select_plan} "
    f"files_state_commit_nanoseconds={files_state_commit} "
    f"files_mutation_plan_nanoseconds={files_mutation_plan} "
    f"files_state_acknowledgement_nanoseconds={files_state_acknowledgement} "
    f"stale_owner_rejections={stale_rejections} proof=passed"
)
PY
    )"; then
        fail "performance instrumentation proof failed for $phase"
    fi
    printf '%s\n' "$summary"
}

finish_instrumented_phase() {
    local phase="$1"
    local expected_row_count="$2"
    local requirement="$3"
    terminate_child_process "$APP_PID" app \
        || fail "could not stop the isolated app before validating $phase instrumentation"
    APP_PID=""
    validate_performance_instrumentation "$phase" "$expected_row_count" "$requirement"
}

wait_for_mock_idle() {
    local label="$1"
    local state in_flight
    local -a metrics
    for _ in {1..1200}; do
        /bin/kill -0 "$APP_PID" 2>/dev/null \
            || fail "app exited while waiting for $label RPCs to drain"
        state="$(mock_metrics)"
        read -r -a metrics <<< "$state"
        in_flight="${metrics[5]}"
        if [[ "$in_flight" == "0" ]]; then
            return
        fi
        /bin/sleep 0.1
    done
    fail "$label RPCs did not drain within 120 seconds"
}

wait_for_next_torrent_request_in_flight() {
    local baseline_torrent_get_count="$1"
    local state torrent_get_count in_flight
    local -a metrics
    for _ in {1..1200}; do
        /bin/kill -0 "$APP_PID" 2>/dev/null \
            || fail "app exited while waiting for the stale-generation list request"
        state="$(mock_metrics)"
        read -r -a metrics <<< "$state"
        torrent_get_count="${metrics[1]}"
        in_flight="${metrics[5]}"
        if (( torrent_get_count > baseline_torrent_get_count )) && [[ "$in_flight" == "1" ]]; then
            return
        fi
        /bin/sleep 0.1
    done
    fail "no delayed torrent-get became observable for the stale-generation probe"
}

configure_connected_delta() {
    local torrent_count="${1:-1000}"
    local changed_json
    case "$torrent_count" in
        0) changed_json='[]' ;;
        100|1000) changed_json='[1,2]' ;;
        *) fail "unsupported internal torrent count for delta control: $torrent_count" ;;
    esac
    /usr/bin/curl --noproxy '*' --fail --silent --show-error \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"mode\":\"replace\",\"changed\":$changed_json,\"removed\":[]}" \
        "http://$MOCK_HOST:$MOCK_PORT/__mock__/delta" \
        | /usr/bin/python3 -c '
import json
import sys
state = json.load(sys.stdin)
expected_count = int(sys.argv[1])
expected_ids = [] if expected_count == 0 else [1, 2]
expected = (
    state["deltaControlled"]
    and state["recentlyActiveIds"] == expected_ids
    and state["torrentCount"] == expected_count
)
raise SystemExit(0 if expected else 1)
' "$torrent_count" \
        || fail "mock delta control did not enter the expected isolated state"
}

configure_idle_delta() {
    /usr/bin/curl --noproxy '*' --fail --silent --show-error \
        -X POST \
        -H 'Content-Type: application/json' \
        -d '{"mode":"replace","changed":[],"removed":[],"allTorrentsState":"stopped"}' \
        "http://$MOCK_HOST:$MOCK_PORT/__mock__/delta" \
        | /usr/bin/python3 -c '
import json
import sys
state = json.load(sys.stdin)
expected = (
    state["deltaControlled"]
    and len(state["recentlyActiveIds"]) == state["torrentCount"]
    and state["recentlyRemovedIds"] == []
    and state["allTorrentsStopped"]
    and state["stoppedTorrentCount"] == state["torrentCount"]
    and state["torrentDownloadRate"] == 0
    and state["torrentUploadRate"] == 0
    and state["activeVerificationCount"] == 0
)
if not expected:
    raise SystemExit(1)
print(state["methodRequestCounts"].get("torrent-get", 0))
' \
        || fail "mock delta control did not enter the expected idle state"
}

clear_idle_delta_delivery() {
    /usr/bin/curl --noproxy '*' --fail --silent --show-error \
        -X POST \
        -H 'Content-Type: application/json' \
        -d '{"mode":"replace","changed":[],"removed":[]}' \
        "http://$MOCK_HOST:$MOCK_PORT/__mock__/delta" \
        | /usr/bin/python3 -c '
import json
import sys
state = json.load(sys.stdin)
expected = (
    state["deltaControlled"]
    and state["recentlyActiveIds"] == []
    and state["recentlyRemovedIds"] == []
    and state["allTorrentsStopped"]
    and state["stoppedTorrentCount"] == state["torrentCount"]
    and state["torrentDownloadRate"] == 0
    and state["torrentUploadRate"] == 0
    and state["activeVerificationCount"] == 0
)
raise SystemExit(0 if expected else 1)
' \
        || fail "mock idle transition could not clear its delivered delta"
}

accepted_torrent_publication_count() {
    local expected_row_count="$1"
    [[ -f "$APP_INSTRUMENTATION_TRACE" && ! -L "$APP_INSTRUMENTATION_TRACE" ]] \
        || fail "performance instrumentation trace is missing during idle transition"
    /usr/bin/python3 - "$APP_INSTRUMENTATION_TRACE" "$expected_row_count" <<'PY'
import json
import sys

count = 0
with open(sys.argv[1], encoding="utf-8") as trace:
    for line in trace:
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            record.get("event") == "torrent_list_publication"
            and record.get("outcome") == "accepted"
            and record.get("rowCount") == int(sys.argv[2])
        ):
            count += 1
print(count)
PY
}

wait_for_idle_torrent_publication() {
    local baseline_publication_count="$1"
    local baseline_torrent_get_count="$2"
    local publication_count state torrent_get_count in_flight
    local -a metrics
    for _ in {1..1200}; do
        /bin/kill -0 "$APP_PID" 2>/dev/null \
            || fail "app exited while waiting for the all-stopped idle publication"
        state="$(mock_metrics)"
        read -r -a metrics <<< "$state"
        torrent_get_count="${metrics[1]}"
        in_flight="${metrics[5]}"
        publication_count="$(accepted_torrent_publication_count 1000)"
        if (( torrent_get_count > baseline_torrent_get_count )) \
            && [[ "$in_flight" == "0" ]] \
            && (( publication_count > baseline_publication_count )); then
            /bin/sleep 1
            return
        fi
        /bin/sleep 0.1
    done
    fail "all-stopped idle state was not accepted before the transition deadline"
}

requests_per_minute() {
    local request_count="$1"
    local seconds="$2"
    /usr/bin/awk -v requests="$request_count" -v seconds="$seconds" \
        'BEGIN { printf "%.2f", requests * 60 / seconds }'
}

performance_wake_count() {
    local phase_home="$1"
    local trace_file="$phase_home/tmp/$PERFORMANCE_WAKE_TRACE"
    [[ -f "$trace_file" && ! -L "$trace_file" ]] \
        || fail "performance wake trace is missing or not a regular file: $trace_file"
    /usr/bin/awk '
        NF != 1 || $1 !~ /^[123]$/ { invalid = 1 }
        END {
            if (invalid || NR == 0) exit 1
            print NR + 0
        }
    ' "$trace_file" || fail "performance wake trace was malformed"
}

wait_for_first_performance_wake() {
    local phase_home="$1"
    local trace_file="$phase_home/tmp/$PERFORMANCE_WAKE_TRACE"
    local waited=0
    while (( waited < PERFORMANCE_WAKE_TRACE_STARTUP_WAIT_SECONDS )); do
        /bin/kill -0 "$APP_PID" 2>/dev/null \
            || fail "app exited while waiting for the first performance wake"
        if [[ -e "$trace_file" || -L "$trace_file" ]]; then
            [[ -f "$trace_file" && ! -L "$trace_file" ]] \
                || fail "performance wake trace startup path is not a regular file: $trace_file"
            if [[ -s "$trace_file" ]]; then
                return
            fi
        fi
        /bin/sleep 1
        waited=$(( waited + 1 ))
    done
    fail "performance wake recorder did not record its first wake within ${PERFORMANCE_WAKE_TRACE_STARTUP_WAIT_SECONDS}s"
}

wait_for_detail_selection() {
    local phase_home="$1"
    local expected_pane="${2:-overview}"
    local expected_torrent_id="${3:-$PERFORMANCE_DETAIL_TARGET_ID}"
    [[ "$expected_pane" == "overview" || "$expected_pane" == "files" ]] \
        || fail "invalid expected performance detail pane: $expected_pane"
    [[ "$expected_torrent_id" =~ ^[1-9][0-9]*$ ]] \
        || fail "invalid expected performance detail torrent ID: $expected_torrent_id"
    local proof_file="$phase_home/tmp/$PERFORMANCE_DETAIL_SELECTION_PROOF"
    local proof="" proof_mode=""
    for _ in {1..1200}; do
        /bin/kill -0 "$APP_PID" 2>/dev/null \
            || fail "app exited while waiting for isolated detail selection"
        if [[ -e "$proof_file" || -L "$proof_file" ]]; then
            [[ -f "$proof_file" && ! -L "$proof_file" ]] \
                || fail "isolated detail-selection proof was not a regular file"
            proof_mode="$(/usr/bin/stat -f '%Lp' "$proof_file")" \
                || fail "could not inspect isolated detail-selection proof permissions"
            [[ "$proof_mode" == "600" ]] \
                || fail "isolated detail-selection proof permissions were $proof_mode instead of 600"
            proof="$(/usr/bin/awk 'NF { print }' "$proof_file")"
            if [[ "$proof" == "$expected_torrent_id $expected_pane" ]]; then
                printf '%s' "$proof"
                return
            fi
            fail "isolated detail-selection proof was malformed: $proof"
        fi
        /bin/sleep 0.1
    done
    fail "isolated detail selection did not activate after the first torrent snapshot"
}

assert_recent_poll_evidence() {
    local label="$1"
    local torrent_get_count="$2"
    local recently_active_count="$3"
    local selector="$4"
    local field_count="$5"
    local request_bytes="$6"
    local minimum_recent_count="$7"

    (( torrent_get_count >= minimum_recent_count )) \
        || fail "$label torrent-get count $torrent_get_count was below $minimum_recent_count"
    (( recently_active_count >= minimum_recent_count )) \
        || fail "$label recently-active count $recently_active_count was below $minimum_recent_count; startup-only traffic is not steady polling"
    (( recently_active_count <= torrent_get_count )) \
        || fail "$label recently-active count exceeded torrent-get count"
    [[ "$selector" == "recently-active" || "$selector" == "recently_active" ]] \
        || fail "$label last torrent-get selector was not recently-active/recently_active: $selector"
    (( field_count > 0 && request_bytes > 0 )) \
        || fail "$label last torrent-get field/byte metrics were empty"
}

record_recent_poll_evidence() {
    local label="$1"
    local torrent_get_count="$2"
    local recently_active_count="$3"
    local selector="$4"
    local field_count="$5"
    local request_bytes="$6"

    record_integer_at_least "$label torrent-get requests" "$torrent_get_count" 1
    record_integer_at_least "$label recently-active torrent-get requests" "$recently_active_count" 1
    if (( recently_active_count > torrent_get_count )); then
        GATE_FAILURES+=("$label recently-active count $recently_active_count exceeded torrent-get count $torrent_get_count")
    fi
    if [[ "$selector" != "recently-active" && "$selector" != "recently_active" ]]; then
        GATE_FAILURES+=("$label last torrent-get selector was $selector instead of recently-active/recently_active")
    fi
    record_integer_at_least "$label last torrent-get field count" "$field_count" 1
    record_integer_at_least "$label last torrent-get request bytes" "$request_bytes" 1
}

assert_expected_method_total() {
    local label="$1"
    local total="$2"
    local torrent_get="$3"
    local session_get="$4"
    local session_stats="$5"
    local expected=$(( torrent_get + session_get + session_stats ))
    (( total == expected )) \
        || fail "$label accepted $total RPCs but known method counts totalled $expected"
}

record_expected_method_total() {
    local label="$1"
    local total="$2"
    local torrent_get="$3"
    local session_get="$4"
    local session_stats="$5"
    local expected=$(( torrent_get + session_get + session_stats ))
    if (( total != expected )); then
        GATE_FAILURES+=("$label accepted $total RPCs but known method counts totalled $expected")
    fi
}

fail_on_recorded_gate_failures() {
    local phase="$1"
    (( ${#GATE_FAILURES[@]} == 0 )) && return
    printf 'mode=%s %s=blocked phase=%s failed_gate_count=%s fail_fast=yes\n' \
        "$EVIDENCE_MODE" "$ACCEPTANCE_RESULT_KEY" "$phase" "${#GATE_FAILURES[@]}" >&2
    local failure
    for failure in "${GATE_FAILURES[@]}"; do
        printf 'gate_failure=%s\n' "$failure" >&2
    done
    exit 1
}

run_smoke_phase() {
    local phase="$1"
    local connect_on_launch="$2"
    local phase_dir="$TMP_ROOT/$phase"
    local phase_home="$phase_dir/home"
    local sandbox_file="$phase_dir/network.sb"
    /bin/mkdir -p "$phase_dir"

    write_profile "$phase_home" "$phase" "$connect_on_launch"
    verify_foundation_isolation "$phase_home"
    write_network_sandbox "$sandbox_file"
    validate_network_sandbox "$sandbox_file"
    start_mock "$phase_dir"

    local initial_state
    initial_state="$(mock_metrics)"
    local initial_requests initial_torrent_get initial_recent initial_session_get initial_session_stats
    local initial_in_flight initial_max_in_flight torrent_count initial_selector initial_field_count initial_request_bytes
    read -r initial_requests initial_torrent_get initial_recent initial_session_get initial_session_stats \
        initial_in_flight initial_max_in_flight torrent_count initial_selector initial_field_count \
        initial_request_bytes <<< "$initial_state"
    [[ "$initial_requests" == "0" && "$initial_in_flight" == "0" && "$torrent_count" == "1000" ]] \
        || fail "mock did not start from the expected isolated 1,000-row state: $initial_state"
    if [[ "$phase" == "connected" ]]; then
        configure_connected_delta
    fi

    start_isolated_app "$phase_dir" "$phase_home" "$sandbox_file" pollSlowly
    sleep_unlocked_warmup "$SMOKE_WARMUP_SECONDS" "smoke $phase"
    activate_isolated_app

    local baseline_state baseline_requests baseline_torrent_get baseline_recent
    local baseline_session_get baseline_session_stats baseline_in_flight baseline_max_in_flight
    local baseline_torrent_count baseline_selector baseline_field_count baseline_request_bytes
    baseline_state="$(mock_metrics)"
    read -r baseline_requests baseline_torrent_get baseline_recent baseline_session_get baseline_session_stats \
        baseline_in_flight baseline_max_in_flight baseline_torrent_count baseline_selector \
        baseline_field_count baseline_request_bytes <<< "$baseline_state"
    [[ "$baseline_torrent_count" == "1000" ]] \
        || fail "mock warmup changed its isolated dataset: $baseline_state"

    local cpu_result average_cpu p95_cpu peak_cpu sample_count cpu_time_seconds wall_time_seconds peak_rss_bytes
    cpu_result="$(capture_cpu \
        "$APP_PID" \
        "$SMOKE_SAMPLE_SECONDS" \
        foreground \
        "smoke $phase measurement")"
    read -r average_cpu p95_cpu peak_cpu sample_count cpu_time_seconds wall_time_seconds \
        peak_rss_bytes <<< "$cpu_result"

    local final_state final_requests final_torrent_get final_recent final_session_get final_session_stats
    local in_flight max_in_flight final_torrent_count final_selector final_field_count final_request_bytes
    final_state="$(mock_metrics)"
    read -r final_requests final_torrent_get final_recent final_session_get final_session_stats \
        in_flight max_in_flight final_torrent_count final_selector final_field_count \
        final_request_bytes <<< "$final_state"
    [[ "$final_torrent_count" == "1000" ]] \
        || fail "mock ended in an unexpected state: $final_state"

    local requests=$(( final_requests - baseline_requests ))
    local torrent_get_requests=$(( final_torrent_get - baseline_torrent_get ))
    local recently_active_requests=$(( final_recent - baseline_recent ))
    local session_get_requests=$(( final_session_get - baseline_session_get ))
    local session_stats_requests=$(( final_session_stats - baseline_session_stats ))
    assert_expected_method_total \
        "smoke $phase steady method accounting" \
        "$requests" \
        "$torrent_get_requests" \
        "$session_get_requests" \
        "$session_stats_requests"

    if [[ "$phase" == "connected" ]]; then
        local default_request_max=$(( 2 + SMOKE_SAMPLE_SECONDS / FOREGROUND_INTERVAL_SECONDS ))
        local request_max="${SMOKE_CONNECTED_REQUEST_MAX:-$default_request_max}"
        local request_min="$SMOKE_CONNECTED_LIST_REQUEST_MIN"
        require_nonnegative_integer "SMOKE_CONNECTED_REQUEST_MAX" "$request_max"
        assert_decimal_at_most "smoke connected average CPU" "$average_cpu" "$SMOKE_CONNECTED_AVERAGE_CPU_MAX"
        assert_decimal_at_most "smoke connected p95 CPU" "$p95_cpu" "$SMOKE_CONNECTED_P95_CPU_MAX"
        assert_integer_between "connected steady accepted RPC requests" "$requests" "$request_min" "$request_max"
        assert_recent_poll_evidence \
            "smoke connected steady polling" \
            "$torrent_get_requests" \
            "$recently_active_requests" \
            "$final_selector" \
            "$final_field_count" \
            "$final_request_bytes" \
            "$SMOKE_CONNECTED_LIST_REQUEST_MIN"
    else
        local request_max="$SMOKE_DISCONNECTED_REQUEST_MAX"
        local request_min=0
        assert_decimal_at_most "smoke disconnected average CPU" "$average_cpu" "$SMOKE_DISCONNECTED_AVERAGE_CPU_MAX"
        assert_decimal_at_most "smoke disconnected p95 CPU" "$p95_cpu" "$SMOKE_DISCONNECTED_P95_CPU_MAX"
        assert_integer_between "disconnected accepted RPC requests" "$requests" "$request_min" "$request_max"
    fi
    assert_integer_between "maximum concurrent RPC requests" "$max_in_flight" 0 "$MAX_IN_FLIGHT_REQUESTS"

    printf 'mode=smoke release_acceptance=no phase=%s samples=%s process_cpu_seconds=%s wall_seconds=%s average_cpu_percent=%s p95_cpu_percent=%s peak_cpu_percent=%s peak_rss_bytes=%s steady_accepted_rpc_requests=%s torrent_get_requests=%s recently_active_torrent_get_requests=%s session_get_requests=%s session_stats_requests=%s last_torrent_get_selector=%s last_torrent_get_field_count=%s last_torrent_get_request_bytes=%s max_in_flight_requests=%s response_delay_ms=%s request_threshold=%s..%s\n' \
        "$phase" "$sample_count" "$cpu_time_seconds" "$wall_time_seconds" \
        "$average_cpu" "$p95_cpu" "$peak_cpu" "$peak_rss_bytes" \
        "$requests" "$torrent_get_requests" "$recently_active_requests" \
        "$session_get_requests" "$session_stats_requests" "$final_selector" \
        "$final_field_count" "$final_request_bytes" "$max_in_flight" \
        "$MOCK_RESPONSE_DELAY_MS" "$request_min" "$request_max"

    cleanup_processes
}

prepare_mock_debug_acceptance_phase() {
    local phase_dir="$1"
    local phase_home="$2"
    local background_policy="$3"
    local select_detail="${4:-false}"
    local torrent_count="${5:-1000}"
    local include_large_detail="${6:-false}"
    local sandbox_file="$phase_dir/network.sb"
    /bin/mkdir -p "$phase_dir"

    write_profile "$phase_home" "mock-debug-acceptance" true
    verify_foundation_isolation "$phase_home"
    write_network_sandbox "$sandbox_file"
    validate_network_sandbox "$sandbox_file"
    start_mock "$phase_dir" "$torrent_count" "$include_large_detail"
    configure_connected_delta "$torrent_count"
    start_isolated_app \
        "$phase_dir" \
        "$phase_home" \
        "$sandbox_file" \
        "$background_policy" \
        "$select_detail"
}

run_mock_debug_disconnected() {
    local phase_dir="$TMP_ROOT/mock-debug-disconnected"
    local phase_home="$phase_dir/home"
    local sandbox_file="$phase_dir/network.sb"
    /bin/mkdir -p "$phase_dir"

    write_profile "$phase_home" "mock-debug-disconnected" false
    verify_foundation_isolation "$phase_home"
    write_network_sandbox "$sandbox_file"
    validate_network_sandbox "$sandbox_file"
    start_mock "$phase_dir" 0 false
    start_isolated_app \
        "$phase_dir" "$phase_home" "$sandbox_file" pollSlowly false
    sleep_unlocked_warmup "$RELEASE_WARMUP_SECONDS" "disconnected-visible"
    activate_isolated_app

    local before requests_before torrent_before recent_before session_get_before session_stats_before
    local in_flight_before max_in_flight_before rows_before selector_before field_count_before request_bytes_before
    before="$(mock_metrics)"
    read -r requests_before torrent_before recent_before session_get_before session_stats_before \
        in_flight_before max_in_flight_before rows_before selector_before field_count_before \
        request_bytes_before <<< "$before"
    [[ "$requests_before" == "0" && "$in_flight_before" == "0" && "$rows_before" == "0" ]] \
        || fail "disconnected mock did not start from an untouched zero-row state: $before"

    local cpu_result average_cpu p95_cpu peak_cpu samples cpu_seconds wall_seconds peak_rss_bytes
    cpu_result="$(capture_cpu \
        "$APP_PID" \
        "$RELEASE_SAMPLE_SECONDS" \
        foreground \
        "disconnected-visible measurement")"
    read -r average_cpu p95_cpu peak_cpu samples cpu_seconds wall_seconds \
        peak_rss_bytes <<< "$cpu_result"
    verify_isolated_app_foreground

    local after requests_after torrent_after recent_after session_get_after session_stats_after
    local in_flight_after max_in_flight_after rows_after selector_after field_count_after request_bytes_after
    after="$(mock_metrics)"
    read -r requests_after torrent_after recent_after session_get_after session_stats_after \
        in_flight_after max_in_flight_after rows_after selector_after field_count_after \
        request_bytes_after <<< "$after"
    local request_count=$(( requests_after - requests_before ))
    record_decimal_below \
        "disconnected visible average CPU" \
        "$average_cpu" \
        "$RELEASE_DISCONNECTED_AVERAGE_CPU_MAX"
    record_decimal_below \
        "disconnected visible p95 CPU" \
        "$p95_cpu" \
        "$RELEASE_DISCONNECTED_P95_CPU_MAX"
    record_integer_at_most \
        "disconnected accepted RPC requests" \
        "$request_count" \
        0
    record_integer_at_most \
        "disconnected maximum concurrent RPC requests" \
        "$max_in_flight_after" \
        0
    [[ "$rows_after" == "0" ]] \
        || fail "disconnected mock changed its isolated dataset: $after"
    printf "mode=$EVIDENCE_MODE phase=disconnected-visible process_state=$FOREGROUND_PROCESS_STATE_EVIDENCE main_window=visible_nonminiaturized foreground_evidence=$FOREGROUND_EVIDENCE dataset_torrents=0 duration_seconds=%s samples=%s process_cpu_seconds=%s wall_seconds=%s average_cpu_percent=%s p95_cpu_percent=%s peak_cpu_percent=%s peak_rss_bytes=%s accepted_rpc_requests=%s max_in_flight_requests=%s cpu_thresholds=average_below_%s,p95_below_%s rpc_threshold=exactly_0\n" \
        "$RELEASE_SAMPLE_SECONDS" "$samples" "$cpu_seconds" "$wall_seconds" \
        "$average_cpu" "$p95_cpu" "$peak_cpu" "$peak_rss_bytes" \
        "$request_count" "$max_in_flight_after" \
        "$RELEASE_DISCONNECTED_AVERAGE_CPU_MAX" "$RELEASE_DISCONNECTED_P95_CPU_MAX"
    verify_isolated_app_foreground
    cleanup_processes
}

run_mock_debug_scale_dataset() {
    local torrent_count="$1"
    [[ "$torrent_count" == "0" || "$torrent_count" == "100" ]] \
        || fail "scale phase only supports the non-primary 0 and 100 row fixtures"
    local phase_dir="$TMP_ROOT/mock-debug-scale-$torrent_count"
    local phase_home="$phase_dir/home"
    prepare_mock_debug_acceptance_phase \
        "$phase_dir" "$phase_home" pollSlowly false "$torrent_count" false
    sleep_unlocked_warmup "$RELEASE_WARMUP_SECONDS" "scale-$torrent_count connected-visible"

    wait_for_first_performance_wake "$phase_home"
    activate_isolated_app
    wait_for_mock_idle "scale-$torrent_count visible warmup"
    local wakes_before
    wakes_before="$(performance_wake_count "$phase_home")"
    local before requests_before torrent_before recent_before session_get_before session_stats_before
    local in_flight_before max_in_flight_before rows_before selector_before field_count_before request_bytes_before
    before="$(mock_metrics)"
    read -r requests_before torrent_before recent_before session_get_before session_stats_before \
        in_flight_before max_in_flight_before rows_before selector_before field_count_before \
        request_bytes_before <<< "$before"
    [[ "$rows_before" == "$torrent_count" ]] \
        || fail "scale-$torrent_count mock did not retain its isolated dataset: $before"

    local cpu_result average_cpu p95_cpu peak_cpu samples cpu_seconds wall_seconds peak_rss_bytes
    cpu_result="$(capture_cpu \
        "$APP_PID" \
        "$RELEASE_SCALE_SAMPLE_SECONDS" \
        foreground \
        "scale-$torrent_count connected-visible measurement")"
    read -r average_cpu p95_cpu peak_cpu samples cpu_seconds wall_seconds \
        peak_rss_bytes <<< "$cpu_result"
    verify_isolated_app_foreground

    local after requests_after torrent_after recent_after session_get_after session_stats_after
    local in_flight_after max_in_flight_after rows_after selector_after field_count_after request_bytes_after
    after="$(mock_metrics)"
    read -r requests_after torrent_after recent_after session_get_after session_stats_after \
        in_flight_after max_in_flight_after rows_after selector_after field_count_after \
        request_bytes_after <<< "$after"
    [[ "$rows_after" == "$torrent_count" ]] \
        || fail "scale-$torrent_count mock changed its isolated dataset: $after"

    local wakes_after wake_count
    wakes_after="$(performance_wake_count "$phase_home")"
    wake_count=$(( wakes_after - wakes_before ))
    local wake_rate
    wake_rate="$(/usr/bin/awk \
        -v wakes="$wake_count" \
        -v seconds="$RELEASE_SCALE_SAMPLE_SECONDS" \
        'BEGIN { printf "%.4f", wakes / seconds }')"
    local request_count=$(( requests_after - requests_before ))
    local torrent_count_delta=$(( torrent_after - torrent_before ))
    local recent_count=$(( recent_after - recent_before ))
    local session_get_count=$(( session_get_after - session_get_before ))
    local session_stats_count=$(( session_stats_after - session_stats_before ))
    local rpc_rate list_rate
    rpc_rate="$(requests_per_minute "$request_count" "$RELEASE_SCALE_SAMPLE_SECONDS")"
    list_rate="$(requests_per_minute "$torrent_count_delta" "$RELEASE_SCALE_SAMPLE_SECONDS")"

    record_decimal_below \
        "scale-$torrent_count connected visible average CPU" \
        "$average_cpu" \
        "$RELEASE_CONNECTED_AVERAGE_CPU_MAX"
    record_decimal_below \
        "scale-$torrent_count connected visible p95 CPU" \
        "$p95_cpu" \
        "$RELEASE_CONNECTED_P95_CPU_MAX"
    record_expected_method_total \
        "scale-$torrent_count connected visible method accounting" \
        "$request_count" \
        "$torrent_count_delta" \
        "$session_get_count" \
        "$session_stats_count"
    record_recent_poll_evidence \
        "scale-$torrent_count connected visible steady polling" \
        "$torrent_count_delta" \
        "$recent_count" \
        "$selector_after" \
        "$field_count_after" \
        "$request_bytes_after"
    record_decimal_at_least \
        "scale-$torrent_count connected visible list polls per minute" \
        "$list_rate" \
        "$RELEASE_ACTIVE_LIST_MIN_PER_MINUTE"
    record_decimal_at_most \
        "scale-$torrent_count connected visible list polls per minute" \
        "$list_rate" \
        "$RELEASE_ACTIVE_LIST_MAX_PER_MINUTE"
    record_decimal_at_most \
        "scale-$torrent_count active visible RPC requests per minute" \
        "$rpc_rate" \
        "$RELEASE_ACTIVE_VISIBLE_RPC_MAX_PER_MINUTE"
    record_integer_at_least "scale-$torrent_count scheduler wakes" "$wake_count" 1
    record_decimal_below \
        "scale-$torrent_count scheduler wakes per second" \
        "$wake_rate" \
        "$RELEASE_FOREGROUND_WAKE_MAX_PER_SECOND"
    record_integer_at_most \
        "scale-$torrent_count maximum concurrent RPC requests" \
        "$max_in_flight_after" \
        "$MAX_IN_FLIGHT_REQUESTS"
    printf "mode=$EVIDENCE_MODE phase=scale-connected-visible process_state=$FOREGROUND_PROCESS_STATE_EVIDENCE main_window=visible_nonminiaturized foreground_evidence=$FOREGROUND_EVIDENCE dataset_torrents=%s duration_seconds=%s samples=%s process_cpu_seconds=%s wall_seconds=%s average_cpu_percent=%s p95_cpu_percent=%s peak_cpu_percent=%s peak_rss_bytes=%s accepted_rpc_requests=%s rpc_requests_per_minute=%s torrent_get_requests=%s recently_active_torrent_get_requests=%s list_polls_per_minute=%s session_get_requests=%s session_stats_requests=%s scheduler_wakes=%s scheduler_wakes_per_second=%s last_torrent_get_selector=%s last_torrent_get_field_count=%s last_torrent_get_request_bytes=%s max_in_flight_requests=%s response_delay_ms=%s cpu_thresholds=average_below_%s,p95_below_%s rpc_threshold=at_most_%s_per_minute list_cadence=%s..%s_per_minute wake_threshold=below_%s_per_second\n" \
        "$torrent_count" "$RELEASE_SCALE_SAMPLE_SECONDS" "$samples" "$cpu_seconds" \
        "$wall_seconds" "$average_cpu" "$p95_cpu" "$peak_cpu" "$peak_rss_bytes" \
        "$request_count" "$rpc_rate" "$torrent_count_delta" "$recent_count" "$list_rate" \
        "$session_get_count" "$session_stats_count" "$wake_count" "$wake_rate" \
        "$selector_after" "$field_count_after" "$request_bytes_after" \
        "$max_in_flight_after" "$MOCK_RESPONSE_DELAY_MS" \
        "$RELEASE_CONNECTED_AVERAGE_CPU_MAX" "$RELEASE_CONNECTED_P95_CPU_MAX" \
        "$RELEASE_ACTIVE_VISIBLE_RPC_MAX_PER_MINUTE" \
        "$RELEASE_ACTIVE_LIST_MIN_PER_MINUTE" "$RELEASE_ACTIVE_LIST_MAX_PER_MINUTE" \
        "$RELEASE_FOREGROUND_WAKE_MAX_PER_SECOND"
    verify_isolated_app_foreground
    finish_instrumented_phase "scale-$torrent_count" "$torrent_count" list
    cleanup_processes
}

run_inactive_visible_background_window() {
    local phase_home="$1"
    deactivate_isolated_app
    sleep_unlocked_warmup \
        "$RELEASE_VISIBILITY_SETTLE_SECONDS" \
        "inactive-visible background visibility settle"
    verify_isolated_app_background
    wait_for_mock_idle "inactive-visible background transition"

    local wakes_before
    wakes_before="$(performance_wake_count "$phase_home")"
    local before requests_before torrent_before recent_before session_get_before session_stats_before
    local in_flight_before max_in_flight_before rows_before selector_before field_count_before request_bytes_before
    before="$(mock_metrics)"
    read -r requests_before torrent_before recent_before session_get_before session_stats_before \
        in_flight_before max_in_flight_before rows_before selector_before field_count_before \
        request_bytes_before <<< "$before"
    [[ "$rows_before" == "1000" ]] \
        || fail "inactive-visible background mock lost its isolated dataset: $before"

    local cpu_result average_cpu p95_cpu peak_cpu samples cpu_seconds wall_seconds peak_rss_bytes
    cpu_result="$(capture_cpu \
        "$APP_PID" \
        "$RELEASE_HIDDEN_SAMPLE_SECONDS" \
        background \
        "inactive-visible background measurement")"
    read -r average_cpu p95_cpu peak_cpu samples cpu_seconds wall_seconds \
        peak_rss_bytes <<< "$cpu_result"
    verify_isolated_app_background

    local after requests_after torrent_after recent_after session_get_after session_stats_after
    local in_flight_after max_in_flight_after rows_after selector_after field_count_after request_bytes_after
    after="$(mock_metrics)"
    read -r requests_after torrent_after recent_after session_get_after session_stats_after \
        in_flight_after max_in_flight_after rows_after selector_after field_count_after \
        request_bytes_after <<< "$after"
    local wakes_after wake_count
    wakes_after="$(performance_wake_count "$phase_home")"
    wake_count=$(( wakes_after - wakes_before ))
    local wake_rate
    wake_rate="$(/usr/bin/awk \
        -v wakes="$wake_count" \
        -v seconds="$RELEASE_HIDDEN_SAMPLE_SECONDS" \
        'BEGIN { printf "%.4f", wakes / seconds }')"
    local request_count=$(( requests_after - requests_before ))
    local torrent_count=$(( torrent_after - torrent_before ))
    local recent_count=$(( recent_after - recent_before ))
    local session_get_count=$(( session_get_after - session_get_before ))
    local session_stats_count=$(( session_stats_after - session_stats_before ))
    local health_count="$session_get_count"
    (( session_stats_count > health_count )) && health_count="$session_stats_count"
    local health_skew=$(( session_get_count - session_stats_count ))
    (( health_skew < 0 )) && health_skew=$(( -health_skew ))
    local rpc_rate list_rate health_rate
    rpc_rate="$(requests_per_minute "$request_count" "$RELEASE_HIDDEN_SAMPLE_SECONDS")"
    list_rate="$(requests_per_minute "$torrent_count" "$RELEASE_HIDDEN_SAMPLE_SECONDS")"
    health_rate="$(requests_per_minute "$health_count" "$RELEASE_HIDDEN_SAMPLE_SECONDS")"

    record_decimal_below \
        "inactive-visible background average CPU" \
        "$average_cpu" \
        "$RELEASE_HIDDEN_AVERAGE_CPU_MAX"
    record_decimal_below \
        "inactive-visible background p95 CPU" \
        "$p95_cpu" \
        "$RELEASE_BACKGROUND_P95_CPU_MAX"
    record_expected_method_total \
        "inactive-visible background method accounting" \
        "$request_count" \
        "$torrent_count" \
        "$session_get_count" \
        "$session_stats_count"
    record_recent_poll_evidence \
        "inactive-visible background steady polling" \
        "$torrent_count" \
        "$recent_count" \
        "$selector_after" \
        "$field_count_after" \
        "$request_bytes_after"
    record_decimal_at_least "inactive-visible background list polls per minute" "$list_rate" 1
    record_decimal_at_most \
        "inactive-visible background list polls per minute" \
        "$list_rate" \
        "$RELEASE_HIDDEN_LIST_MAX_PER_MINUTE"
    record_integer_at_least "inactive-visible background health probes" "$health_count" 1
    record_integer_at_most "inactive-visible background health method count skew" "$health_skew" 1
    record_decimal_at_most \
        "inactive-visible background health probes per minute" \
        "$health_rate" \
        "$RELEASE_HIDDEN_HEALTH_MAX_PER_MINUTE"
    record_integer_at_least "inactive-visible background scheduler wakes" "$wake_count" 1
    record_decimal_below \
        "inactive-visible background scheduler wakes per second" \
        "$wake_rate" \
        "$RELEASE_HIDDEN_WAKE_MAX_PER_SECOND"
    record_integer_at_most \
        "inactive-visible background maximum concurrent RPC requests" \
        "$max_in_flight_after" \
        "$MAX_IN_FLIGHT_REQUESTS"
    printf "mode=$EVIDENCE_MODE phase=background-visible process_state=inactive_unhidden main_window=visible_nonminiaturized foreground_evidence=native_background dataset_torrents=1000 duration_seconds=%s samples=%s process_cpu_seconds=%s wall_seconds=%s average_cpu_percent=%s p95_cpu_percent=%s peak_cpu_percent=%s peak_rss_bytes=%s accepted_rpc_requests=%s aggregate_rpc_requests_per_minute=%s torrent_get_requests=%s recently_active_torrent_get_requests=%s list_polls_per_minute=%s session_get_requests=%s session_stats_requests=%s health_probes_per_minute=%s scheduler_wakes=%s scheduler_wakes_per_second=%s last_torrent_get_selector=%s last_torrent_get_field_count=%s last_torrent_get_request_bytes=%s max_in_flight_requests=%s cpu_thresholds=average_below_%s,p95_below_%s rpc_thresholds=list_at_most_%s_per_minute,health_at_most_%s_per_minute wake_threshold=below_%s_per_second\n" \
        "$RELEASE_HIDDEN_SAMPLE_SECONDS" "$samples" "$cpu_seconds" "$wall_seconds" \
        "$average_cpu" "$p95_cpu" "$peak_cpu" "$peak_rss_bytes" \
        "$request_count" "$rpc_rate" "$torrent_count" "$recent_count" "$list_rate" \
        "$session_get_count" "$session_stats_count" "$health_rate" \
        "$wake_count" "$wake_rate" "$selector_after" "$field_count_after" \
        "$request_bytes_after" "$max_in_flight_after" \
        "$RELEASE_HIDDEN_AVERAGE_CPU_MAX" "$RELEASE_BACKGROUND_P95_CPU_MAX" \
        "$RELEASE_HIDDEN_LIST_MAX_PER_MINUTE" \
        "$RELEASE_HIDDEN_HEALTH_MAX_PER_MINUTE" "$RELEASE_HIDDEN_WAKE_MAX_PER_SECOND"
    [[ "$rows_after" == "1000" ]] \
        || fail "inactive-visible background mock changed its isolated dataset: $after"
}

run_mock_debug_connected_and_hidden() {
    local phase_dir="$TMP_ROOT/mock-debug-connected"
    local phase_home="$phase_dir/home"
    prepare_mock_debug_acceptance_phase \
        "$phase_dir" "$phase_home" pollSlowly false 1000 false
    sleep_unlocked_warmup "$RELEASE_WARMUP_SECONDS" "connected-visible"

    wait_for_first_performance_wake "$phase_home"
    activate_isolated_app
    wait_for_mock_idle "connected visible warmup"
    local visible_wakes_before
    visible_wakes_before="$(performance_wake_count "$phase_home")"
    local visible_before visible_requests_before visible_torrent_before visible_recent_before
    local visible_session_get_before visible_session_stats_before visible_in_flight_before
    local visible_max_in_flight_before visible_torrents_before visible_selector_before
    local visible_field_count_before visible_request_bytes_before
    visible_before="$(mock_metrics)"
    read -r visible_requests_before visible_torrent_before visible_recent_before \
        visible_session_get_before visible_session_stats_before visible_in_flight_before \
        visible_max_in_flight_before visible_torrents_before visible_selector_before \
        visible_field_count_before visible_request_bytes_before <<< "$visible_before"

    local visible_cpu_result visible_average_cpu visible_p95_cpu visible_peak_cpu visible_samples
    local visible_cpu_seconds visible_wall_seconds visible_peak_rss_bytes
    local visible_footprint_before visible_footprint_peak_before visible_footprint_result
    visible_footprint_result="$(process_physical_footprint_bytes "$APP_PID")" \
        || fail "could not read connected visible physical footprint baseline"
    read -r visible_footprint_before visible_footprint_peak_before \
        <<< "$visible_footprint_result"
    visible_cpu_result="$(capture_cpu \
        "$APP_PID" \
        "$RELEASE_SAMPLE_SECONDS" \
        foreground \
        "connected-visible measurement")"
    read -r visible_average_cpu visible_p95_cpu visible_peak_cpu visible_samples \
        visible_cpu_seconds visible_wall_seconds visible_peak_rss_bytes <<< "$visible_cpu_result"
    local visible_footprint_after visible_footprint_peak_after
    visible_footprint_result="$(process_physical_footprint_bytes "$APP_PID")" \
        || fail "could not read connected visible physical footprint result"
    read -r visible_footprint_after visible_footprint_peak_after \
        <<< "$visible_footprint_result"
    verify_isolated_app_foreground

    local visible_after visible_requests_after visible_torrent_after visible_recent_after
    local visible_session_get_after visible_session_stats_after visible_in_flight_after
    local visible_max_in_flight_after visible_torrents_after visible_selector_after
    local visible_field_count_after visible_request_bytes_after
    visible_after="$(mock_metrics)"
    read -r visible_requests_after visible_torrent_after visible_recent_after \
        visible_session_get_after visible_session_stats_after visible_in_flight_after \
        visible_max_in_flight_after visible_torrents_after visible_selector_after \
        visible_field_count_after visible_request_bytes_after <<< "$visible_after"
    local visible_wakes_after visible_wake_count visible_wake_rate
    visible_wakes_after="$(performance_wake_count "$phase_home")"
    visible_wake_count=$(( visible_wakes_after - visible_wakes_before ))
    visible_wake_rate="$(/usr/bin/awk \
        -v wakes="$visible_wake_count" \
        -v seconds="$RELEASE_SAMPLE_SECONDS" \
        'BEGIN { printf "%.4f", wakes / seconds }')"
    [[ "$visible_torrents_after" == "1000" ]] \
        || fail "visible mock DEBUG capture changed the isolated dataset: $visible_after"

    local visible_request_count=$(( visible_requests_after - visible_requests_before ))
    local visible_torrent_count=$(( visible_torrent_after - visible_torrent_before ))
    local visible_recent_count=$(( visible_recent_after - visible_recent_before ))
    local visible_session_get_count=$(( visible_session_get_after - visible_session_get_before ))
    local visible_session_stats_count=$(( visible_session_stats_after - visible_session_stats_before ))
    local visible_rpc_rate visible_list_rate
    visible_rpc_rate="$(requests_per_minute "$visible_request_count" "$RELEASE_SAMPLE_SECONDS")"
    visible_list_rate="$(requests_per_minute "$visible_torrent_count" "$RELEASE_SAMPLE_SECONDS")"

    record_decimal_below "connected visible average CPU" "$visible_average_cpu" "$RELEASE_CONNECTED_AVERAGE_CPU_MAX"
    record_decimal_below "connected visible p95 CPU" "$visible_p95_cpu" "$RELEASE_CONNECTED_P95_CPU_MAX"
    record_integer_below \
        "connected visible peak physical footprint bytes" \
        "$visible_footprint_peak_after" \
        "$RELEASE_THOUSAND_FOOTPRINT_MAX_BYTES"
    record_expected_method_total \
        "connected visible method accounting" \
        "$visible_request_count" \
        "$visible_torrent_count" \
        "$visible_session_get_count" \
        "$visible_session_stats_count"
    record_recent_poll_evidence \
        "connected visible steady polling" \
        "$visible_torrent_count" \
        "$visible_recent_count" \
        "$visible_selector_after" \
        "$visible_field_count_after" \
        "$visible_request_bytes_after"
    record_decimal_at_least \
        "connected visible list polls per minute" \
        "$visible_list_rate" \
        "$RELEASE_ACTIVE_LIST_MIN_PER_MINUTE"
    record_decimal_at_most \
        "connected visible list polls per minute" \
        "$visible_list_rate" \
        "$RELEASE_ACTIVE_LIST_MAX_PER_MINUTE"
    record_decimal_at_most \
        "active visible no-detail RPC requests per minute" \
        "$visible_rpc_rate" \
        "$RELEASE_ACTIVE_VISIBLE_RPC_MAX_PER_MINUTE"
    record_integer_at_least "connected visible scheduler wakes" "$visible_wake_count" 1
    record_decimal_below \
        "connected visible scheduler wakes per second" \
        "$visible_wake_rate" \
        "$RELEASE_FOREGROUND_WAKE_MAX_PER_SECOND"
    printf "mode=$EVIDENCE_MODE phase=connected-visible process_state=$FOREGROUND_PROCESS_STATE_EVIDENCE main_window=visible_nonminiaturized foreground_evidence=$FOREGROUND_EVIDENCE dataset_torrents=1000 duration_seconds=%s samples=%s process_cpu_seconds=%s wall_seconds=%s average_cpu_percent=%s p95_cpu_percent=%s peak_cpu_percent=%s sampled_peak_rss_bytes=%s physical_footprint_baseline_bytes=%s physical_footprint_final_bytes=%s physical_footprint_peak_bytes=%s accepted_rpc_requests=%s rpc_requests_per_minute=%s torrent_get_requests=%s recently_active_torrent_get_requests=%s list_polls_per_minute=%s session_get_requests=%s session_stats_requests=%s scheduler_wakes=%s scheduler_wakes_per_second=%s last_torrent_get_selector=%s last_torrent_get_field_count=%s last_torrent_get_request_bytes=%s max_in_flight_requests=%s response_delay_ms=%s cpu_thresholds=average_below_%s,p95_below_%s physical_footprint_threshold=below_%s_bytes rpc_threshold=at_most_%s_per_minute list_cadence=%s..%s_per_minute wake_threshold=below_%s_per_second\n" \
        "$RELEASE_SAMPLE_SECONDS" "$visible_samples" "$visible_cpu_seconds" "$visible_wall_seconds" \
        "$visible_average_cpu" "$visible_p95_cpu" \
        "$visible_peak_cpu" "$visible_peak_rss_bytes" \
        "$visible_footprint_before" "$visible_footprint_after" "$visible_footprint_peak_after" \
        "$visible_request_count" "$visible_rpc_rate" \
        "$visible_torrent_count" "$visible_recent_count" "$visible_list_rate" \
        "$visible_session_get_count" "$visible_session_stats_count" \
        "$visible_wake_count" "$visible_wake_rate" \
        "$visible_selector_after" "$visible_field_count_after" "$visible_request_bytes_after" \
        "$visible_max_in_flight_after" "$MOCK_RESPONSE_DELAY_MS" \
        "$RELEASE_CONNECTED_AVERAGE_CPU_MAX" "$RELEASE_CONNECTED_P95_CPU_MAX" \
        "$RELEASE_THOUSAND_FOOTPRINT_MAX_BYTES" \
        "$RELEASE_ACTIVE_VISIBLE_RPC_MAX_PER_MINUTE" \
        "$RELEASE_ACTIVE_LIST_MIN_PER_MINUTE" "$RELEASE_ACTIVE_LIST_MAX_PER_MINUTE" \
        "$RELEASE_FOREGROUND_WAKE_MAX_PER_SECOND"
    fail_on_recorded_gate_failures connected-visible

    wait_for_mock_idle "before idle visible transition"
    /bin/sleep 1
    local idle_transition_publications_before
    local idle_transition_torrent_requests_before
    idle_transition_publications_before="$(accepted_torrent_publication_count 1000)"
    idle_transition_torrent_requests_before="$(configure_idle_delta)"
    wait_for_idle_torrent_publication \
        "$idle_transition_publications_before" \
        "$idle_transition_torrent_requests_before"
    clear_idle_delta_delivery
    verify_isolated_app_foreground
    wait_for_mock_idle "idle visible transition"
    local idle_before idle_requests_before idle_torrent_before idle_recent_before
    local idle_session_get_before idle_session_stats_before idle_in_flight_before
    local idle_max_in_flight_before idle_torrents_before idle_selector_before
    local idle_field_count_before idle_request_bytes_before
    idle_before="$(mock_metrics)"
    read -r idle_requests_before idle_torrent_before idle_recent_before idle_session_get_before \
        idle_session_stats_before idle_in_flight_before idle_max_in_flight_before idle_torrents_before \
        idle_selector_before idle_field_count_before idle_request_bytes_before <<< "$idle_before"
    capture_state_window \
        "$APP_PID" \
        "$RELEASE_VOLUME_WINDOW_SECONDS" \
        foreground \
        "idle-visible measurement"
    local idle_after idle_requests_after idle_torrent_after idle_recent_after
    local idle_session_get_after idle_session_stats_after idle_in_flight_after idle_max_in_flight_after
    local idle_torrents_after idle_selector_after idle_field_count_after idle_request_bytes_after
    idle_after="$(mock_metrics)"
    verify_isolated_app_foreground
    read -r idle_requests_after idle_torrent_after idle_recent_after idle_session_get_after \
        idle_session_stats_after idle_in_flight_after idle_max_in_flight_after idle_torrents_after \
        idle_selector_after idle_field_count_after idle_request_bytes_after <<< "$idle_after"
    local idle_request_count=$(( idle_requests_after - idle_requests_before ))
    local idle_torrent_count=$(( idle_torrent_after - idle_torrent_before ))
    local idle_recent_count=$(( idle_recent_after - idle_recent_before ))
    local idle_session_get_count=$(( idle_session_get_after - idle_session_get_before ))
    local idle_session_stats_count=$(( idle_session_stats_after - idle_session_stats_before ))
    local idle_rpc_rate idle_list_rate
    idle_rpc_rate="$(requests_per_minute "$idle_request_count" "$RELEASE_VOLUME_WINDOW_SECONDS")"
    idle_list_rate="$(requests_per_minute "$idle_torrent_count" "$RELEASE_VOLUME_WINDOW_SECONDS")"
    record_expected_method_total \
        "idle visible method accounting" \
        "$idle_request_count" \
        "$idle_torrent_count" \
        "$idle_session_get_count" \
        "$idle_session_stats_count"
    record_recent_poll_evidence \
        "idle visible steady polling" \
        "$idle_torrent_count" \
        "$idle_recent_count" \
        "$idle_selector_after" \
        "$idle_field_count_after" \
        "$idle_request_bytes_after"
    record_decimal_at_most \
        "idle visible list polls per minute" \
        "$idle_list_rate" \
        "$RELEASE_IDLE_VISIBLE_LIST_MAX_PER_MINUTE"
    record_decimal_at_most \
        "idle visible RPC requests per minute" \
        "$idle_rpc_rate" \
        "$RELEASE_IDLE_VISIBLE_RPC_MAX_PER_MINUTE"
    printf "mode=$EVIDENCE_MODE phase=idle-visible process_state=$FOREGROUND_PROCESS_STATE_EVIDENCE main_window=visible_nonminiaturized foreground_evidence=$FOREGROUND_EVIDENCE duration_seconds=%s accepted_rpc_requests=%s rpc_requests_per_minute=%s torrent_get_requests=%s recently_active_torrent_get_requests=%s list_polls_per_minute=%s session_get_requests=%s session_stats_requests=%s last_torrent_get_selector=%s last_torrent_get_field_count=%s last_torrent_get_request_bytes=%s max_in_flight_requests=%s rpc_threshold=at_most_%s_per_minute list_cadence=observed_at_least_once_and_at_most_%s_per_minute\n" \
        "$RELEASE_VOLUME_WINDOW_SECONDS" "$idle_request_count" "$idle_rpc_rate" \
        "$idle_torrent_count" "$idle_recent_count" "$idle_list_rate" \
        "$idle_session_get_count" "$idle_session_stats_count" "$idle_selector_after" \
        "$idle_field_count_after" "$idle_request_bytes_after" "$idle_max_in_flight_after" \
        "$RELEASE_IDLE_VISIBLE_RPC_MAX_PER_MINUTE" \
        "$RELEASE_IDLE_VISIBLE_LIST_MAX_PER_MINUTE"
    fail_on_recorded_gate_failures idle-visible

    run_inactive_visible_background_window "$phase_home"
    fail_on_recorded_gate_failures background-visible
    wait_for_mock_idle "inactive-visible background phase"
    hide_isolated_app
    sleep_unlocked_warmup \
        "$RELEASE_VISIBILITY_SETTLE_SECONDS" \
        "hidden-default visibility settle"
    verify_isolated_app_hidden
    wait_for_mock_idle "hidden visibility transition"
    local hidden_wakes_before
    hidden_wakes_before="$(performance_wake_count "$phase_home")"
    local hidden_before hidden_requests_before hidden_torrent_before hidden_recent_before
    local hidden_session_get_before hidden_session_stats_before hidden_in_flight_before
    local hidden_max_in_flight_before hidden_torrents_before hidden_selector_before
    local hidden_field_count_before hidden_request_bytes_before
    hidden_before="$(mock_metrics)"
    read -r hidden_requests_before hidden_torrent_before hidden_recent_before hidden_session_get_before \
        hidden_session_stats_before hidden_in_flight_before hidden_max_in_flight_before hidden_torrents_before \
        hidden_selector_before hidden_field_count_before hidden_request_bytes_before <<< "$hidden_before"
    local hidden_cpu_result hidden_average_cpu hidden_p95_cpu hidden_peak_cpu hidden_samples
    local hidden_cpu_seconds hidden_wall_seconds hidden_peak_rss_bytes
    hidden_cpu_result="$(capture_cpu \
        "$APP_PID" \
        "$RELEASE_HIDDEN_SAMPLE_SECONDS" \
        hidden \
        "hidden-default measurement")"
    read -r hidden_average_cpu hidden_p95_cpu hidden_peak_cpu hidden_samples \
        hidden_cpu_seconds hidden_wall_seconds hidden_peak_rss_bytes <<< "$hidden_cpu_result"
    verify_isolated_app_hidden

    local hidden_after hidden_requests_after hidden_torrent_after hidden_recent_after
    local hidden_session_get_after hidden_session_stats_after hidden_in_flight_after hidden_max_in_flight_after
    local hidden_torrents_after hidden_selector_after hidden_field_count_after hidden_request_bytes_after
    hidden_after="$(mock_metrics)"
    read -r hidden_requests_after hidden_torrent_after hidden_recent_after hidden_session_get_after \
        hidden_session_stats_after hidden_in_flight_after hidden_max_in_flight_after hidden_torrents_after \
        hidden_selector_after hidden_field_count_after hidden_request_bytes_after <<< "$hidden_after"
    local hidden_wakes_after hidden_wake_count hidden_wake_rate
    hidden_wakes_after="$(performance_wake_count "$phase_home")"
    hidden_wake_count=$(( hidden_wakes_after - hidden_wakes_before ))
    hidden_wake_rate="$(/usr/bin/awk \
        -v wakes="$hidden_wake_count" \
        -v seconds="$RELEASE_HIDDEN_SAMPLE_SECONDS" \
        'BEGIN { printf "%.4f", wakes / seconds }')"
    local hidden_request_count=$(( hidden_requests_after - hidden_requests_before ))
    local hidden_torrent_count=$(( hidden_torrent_after - hidden_torrent_before ))
    local hidden_recent_count=$(( hidden_recent_after - hidden_recent_before ))
    local hidden_session_get_count=$(( hidden_session_get_after - hidden_session_get_before ))
    local hidden_session_stats_count=$(( hidden_session_stats_after - hidden_session_stats_before ))
    local hidden_health_count="$hidden_session_get_count"
    (( hidden_session_stats_count > hidden_health_count )) && hidden_health_count="$hidden_session_stats_count"
    local hidden_health_skew=$(( hidden_session_get_count - hidden_session_stats_count ))
    (( hidden_health_skew < 0 )) && hidden_health_skew=$(( -hidden_health_skew ))
    local hidden_rpc_rate hidden_list_rate hidden_health_rate
    hidden_rpc_rate="$(requests_per_minute "$hidden_request_count" "$RELEASE_HIDDEN_SAMPLE_SECONDS")"
    hidden_list_rate="$(requests_per_minute "$hidden_torrent_count" "$RELEASE_HIDDEN_SAMPLE_SECONDS")"
    hidden_health_rate="$(requests_per_minute "$hidden_health_count" "$RELEASE_HIDDEN_SAMPLE_SECONDS")"

    record_decimal_below "hidden average CPU" "$hidden_average_cpu" "$RELEASE_HIDDEN_AVERAGE_CPU_MAX"
    record_decimal_below "hidden p95 CPU" "$hidden_p95_cpu" "$RELEASE_BACKGROUND_P95_CPU_MAX"
    record_expected_method_total \
        "hidden default method accounting" \
        "$hidden_request_count" \
        "$hidden_torrent_count" \
        "$hidden_session_get_count" \
        "$hidden_session_stats_count"
    record_recent_poll_evidence \
        "hidden default steady polling" \
        "$hidden_torrent_count" \
        "$hidden_recent_count" \
        "$hidden_selector_after" \
        "$hidden_field_count_after" \
        "$hidden_request_bytes_after"
    record_decimal_at_least "hidden list polls per minute" "$hidden_list_rate" 1
    record_decimal_at_most \
        "hidden list polls per minute" \
        "$hidden_list_rate" \
        "$RELEASE_HIDDEN_LIST_MAX_PER_MINUTE"
    record_integer_at_least "hidden health probes" "$hidden_health_count" 1
    record_integer_at_most "hidden health method count skew" "$hidden_health_skew" 1
    record_decimal_at_most \
        "hidden health probes per minute" \
        "$hidden_health_rate" \
        "$RELEASE_HIDDEN_HEALTH_MAX_PER_MINUTE"
    record_integer_at_least "hidden scheduler wakes" "$hidden_wake_count" 1
    record_decimal_below \
        "hidden scheduler wakes per second" \
        "$hidden_wake_rate" \
        "$RELEASE_HIDDEN_WAKE_MAX_PER_SECOND"
    printf "mode=$EVIDENCE_MODE phase=hidden-default process_state=inactive_hidden main_window=not_visible_or_miniaturized foreground_evidence=native_hidden duration_seconds=%s samples=%s process_cpu_seconds=%s wall_seconds=%s average_cpu_percent=%s p95_cpu_percent=%s peak_cpu_percent=%s peak_rss_bytes=%s accepted_rpc_requests=%s aggregate_rpc_requests_per_minute=%s torrent_get_requests=%s recently_active_torrent_get_requests=%s list_polls_per_minute=%s session_get_requests=%s session_stats_requests=%s health_probes_per_minute=%s scheduler_wakes=%s scheduler_wakes_per_second=%s last_torrent_get_selector=%s last_torrent_get_field_count=%s last_torrent_get_request_bytes=%s max_in_flight_requests=%s cpu_thresholds=average_below_%s,p95_below_%s rpc_thresholds=list_at_most_%s_per_minute,health_at_most_%s_per_minute wake_threshold=below_%s_per_second\n" \
        "$RELEASE_HIDDEN_SAMPLE_SECONDS" "$hidden_samples" "$hidden_cpu_seconds" "$hidden_wall_seconds" \
        "$hidden_average_cpu" "$hidden_p95_cpu" \
        "$hidden_peak_cpu" "$hidden_peak_rss_bytes" "$hidden_request_count" "$hidden_rpc_rate" \
        "$hidden_torrent_count" "$hidden_recent_count" "$hidden_list_rate" \
        "$hidden_session_get_count" "$hidden_session_stats_count" "$hidden_health_rate" \
        "$hidden_wake_count" "$hidden_wake_rate" \
        "$hidden_selector_after" "$hidden_field_count_after" "$hidden_request_bytes_after" \
        "$hidden_max_in_flight_after" "$RELEASE_HIDDEN_AVERAGE_CPU_MAX" \
        "$RELEASE_BACKGROUND_P95_CPU_MAX" \
        "$RELEASE_HIDDEN_LIST_MAX_PER_MINUTE" "$RELEASE_HIDDEN_HEALTH_MAX_PER_MINUTE" \
        "$RELEASE_HIDDEN_WAKE_MAX_PER_SECOND"

    [[ "$hidden_torrents_after" == "1000" ]] \
        || fail "mock DEBUG capture ended in an unexpected state: $hidden_after"
    record_integer_at_most \
        "maximum concurrent RPC requests" \
        "$hidden_max_in_flight_after" \
        "$MAX_IN_FLIGHT_REQUESTS"
    verify_isolated_app_hidden
    finish_instrumented_phase "connected-background-hidden" 1000 large-list
    cleanup_processes
}

run_mock_debug_large_files_detail() {
    local phase_dir="$TMP_ROOT/mock-debug-large-files-detail"
    local phase_home="$phase_dir/home"
    prepare_mock_debug_acceptance_phase \
        "$phase_dir" "$phase_home" pollSlowly true 100 true

    local selection_proof selection_id
    selection_proof="$(wait_for_detail_selection \
        "$phase_home" files "$PERFORMANCE_DETAIL_TARGET_ID")"
    selection_id="${selection_proof%% *}"
    [[ "$selection_id" == "$PERFORMANCE_DETAIL_TARGET_ID" ]] \
        || fail "large-files detail selection did not target fixture torrent 1"
    sleep_unlocked_warmup "$RELEASE_FILES_WARMUP_SECONDS" "large-files detail"
    activate_isolated_app
    wait_for_mock_idle "large-files detail warmup"

    local before requests_before torrent_before recent_before session_get_before session_stats_before
    local in_flight_before max_in_flight_before torrents_before selector_before field_count_before request_bytes_before
    before="$(mock_metrics)"
    read -r requests_before torrent_before recent_before session_get_before session_stats_before \
        in_flight_before max_in_flight_before torrents_before selector_before field_count_before \
        request_bytes_before <<< "$before"
    [[ "$torrents_before" == "100" ]] \
        || fail "large-files detail mock did not retain its isolated dataset: $before"

    local cpu_result average_cpu p95_cpu peak_cpu samples cpu_seconds wall_seconds peak_rss_bytes
    local footprint_before footprint_peak_before footprint_result
    footprint_result="$(process_physical_footprint_bytes "$APP_PID")" \
        || fail "could not read large-files physical footprint baseline"
    read -r footprint_before footprint_peak_before \
        <<< "$footprint_result"
    cpu_result="$(capture_cpu \
        "$APP_PID" \
        "$RELEASE_FILES_SAMPLE_SECONDS" \
        foreground \
        "large-files detail measurement")"
    read -r average_cpu p95_cpu peak_cpu samples cpu_seconds wall_seconds \
        peak_rss_bytes <<< "$cpu_result"
    local footprint_after footprint_peak_after
    footprint_result="$(process_physical_footprint_bytes "$APP_PID")" \
        || fail "could not read large-files physical footprint result"
    read -r footprint_after footprint_peak_after \
        <<< "$footprint_result"

    local after requests_after torrent_after recent_after session_get_after session_stats_after
    local in_flight_after max_in_flight_after torrents_after selector_after field_count_after request_bytes_after
    after="$(mock_metrics)"
    verify_isolated_app_foreground
    read -r requests_after torrent_after recent_after session_get_after session_stats_after \
        in_flight_after max_in_flight_after torrents_after selector_after field_count_after \
        request_bytes_after <<< "$after"
    local request_count=$(( requests_after - requests_before ))
    local torrent_count=$(( torrent_after - torrent_before ))
    local recent_count=$(( recent_after - recent_before ))
    local detail_count=$(( torrent_count - recent_count ))
    local session_get_count=$(( session_get_after - session_get_before ))
    local session_stats_count=$(( session_stats_after - session_stats_before ))
    local rpc_rate
    rpc_rate="$(requests_per_minute "$request_count" "$RELEASE_FILES_SAMPLE_SECONDS")"

    record_expected_method_total \
        "large-files detail method accounting" \
        "$request_count" \
        "$torrent_count" \
        "$session_get_count" \
        "$session_stats_count"
    record_decimal_below \
        "large-files detail average CPU" \
        "$average_cpu" \
        "$RELEASE_CONNECTED_AVERAGE_CPU_MAX"
    record_decimal_below \
        "large-files detail p95 CPU" \
        "$p95_cpu" \
        "$RELEASE_CONNECTED_P95_CPU_MAX"
    record_integer_at_least "large-files targeted torrent-get requests" "$detail_count" 1
    record_decimal_at_most \
        "large-files detail RPC requests per minute" \
        "$rpc_rate" \
        "$RELEASE_FILES_RPC_MAX_PER_MINUTE"
    record_integer_at_most \
        "large-files detail maximum concurrent RPC requests" \
        "$max_in_flight_after" \
        "$MAX_IN_FLIGHT_REQUESTS"
    record_integer_below \
        "large-files detail peak physical footprint bytes" \
        "$footprint_peak_after" \
        "$RELEASE_FILES_FOOTPRINT_MAX_BYTES"
    printf "mode=$EVIDENCE_MODE phase=large-files-detail process_state=$FOREGROUND_PROCESS_STATE_EVIDENCE main_window=visible_nonminiaturized foreground_evidence=$FOREGROUND_EVIDENCE dataset_torrents=100 selected_torrent_id=%s selected_pane=files fixture_files=10000 duration_seconds=%s samples=%s process_cpu_seconds=%s wall_seconds=%s average_cpu_percent=%s p95_cpu_percent=%s peak_cpu_percent=%s sampled_peak_rss_bytes=%s physical_footprint_baseline_bytes=%s physical_footprint_final_bytes=%s physical_footprint_peak_bytes=%s accepted_rpc_requests=%s rpc_requests_per_minute=%s torrent_get_requests=%s recently_active_torrent_get_requests=%s targeted_detail_torrent_get_requests=%s session_get_requests=%s session_stats_requests=%s last_torrent_get_selector=%s last_torrent_get_field_count=%s last_torrent_get_request_bytes=%s max_in_flight_requests=%s cpu_thresholds=average_below_%s,p95_below_%s rpc_threshold=at_most_%s_per_minute physical_footprint_threshold=below_%s_bytes isolation_selection_proof=matched\n" \
        "$selection_id" "$RELEASE_FILES_SAMPLE_SECONDS" "$samples" \
        "$cpu_seconds" "$wall_seconds" "$average_cpu" "$p95_cpu" "$peak_cpu" \
        "$peak_rss_bytes" "$footprint_before" "$footprint_after" "$footprint_peak_after" \
        "$request_count" "$rpc_rate" \
        "$torrent_count" "$recent_count" "$detail_count" "$session_get_count" \
        "$session_stats_count" "$selector_after" "$field_count_after" \
        "$request_bytes_after" "$max_in_flight_after" \
        "$RELEASE_CONNECTED_AVERAGE_CPU_MAX" "$RELEASE_CONNECTED_P95_CPU_MAX" \
        "$RELEASE_FILES_RPC_MAX_PER_MINUTE" "$RELEASE_FILES_FOOTPRINT_MAX_BYTES"

    [[ "$torrents_after" == "100" ]] \
        || fail "large-files detail mock ended in an unexpected state: $after"
    verify_isolated_app_foreground
    finish_instrumented_phase "large-files-detail" 100 files
    cleanup_processes
}

run_mock_debug_stale_generation() {
    local phase_dir="$TMP_ROOT/mock-debug-stale-generation"
    local phase_home="$phase_dir/home"
    prepare_mock_debug_acceptance_phase \
        "$phase_dir" "$phase_home" pollSlowly false 100 false
    sleep_unlocked_warmup "$RELEASE_WARMUP_SECONDS" "stale-generation"
    activate_isolated_app
    wait_for_mock_idle "stale-generation warmup"

    local before requests_before torrent_before recent_before session_get_before session_stats_before
    local in_flight_before max_in_flight_before rows_before selector_before field_count_before request_bytes_before
    before="$(mock_metrics)"
    read -r requests_before torrent_before recent_before session_get_before session_stats_before \
        in_flight_before max_in_flight_before rows_before selector_before field_count_before \
        request_bytes_before <<< "$before"
    [[ "$rows_before" == "100" ]] \
        || fail "stale-generation mock did not retain its isolated dataset: $before"

    assert_console_unlocked "stale-generation measurement"
    wait_for_next_torrent_request_in_flight "$torrent_before"
    disconnect_isolated_app_through_menu
    wait_for_mock_idle "stale-generation disconnect"
    /bin/sleep 1
    assert_console_unlocked "stale-generation final proof"

    local after requests_after torrent_after recent_after session_get_after session_stats_after
    local in_flight_after max_in_flight_after rows_after selector_after field_count_after request_bytes_after
    after="$(mock_metrics)"
    read -r requests_after torrent_after recent_after session_get_after session_stats_after \
        in_flight_after max_in_flight_after rows_after selector_after field_count_after \
        request_bytes_after <<< "$after"
    [[ "$rows_after" == "100" ]] \
        || fail "stale-generation mock changed its isolated dataset: $after"
    record_integer_at_least \
        "stale-generation accepted torrent-get requests" \
        "$(( torrent_after - torrent_before ))" \
        1
    record_integer_at_most \
        "stale-generation maximum concurrent RPC requests" \
        "$max_in_flight_after" \
        "$MAX_IN_FLIGHT_REQUESTS"
    finish_instrumented_phase "stale-generation" 100 stale
    printf "mode=$EVIDENCE_MODE phase=stale-generation process_state=$FOREGROUND_PROCESS_STATE_EVIDENCE main_window=visible_nonminiaturized foreground_evidence=$FOREGROUND_EVIDENCE dataset_torrents=100 delayed_torrent_get_requests=%s max_in_flight_requests=%s stale_publication_threshold=exactly_0 instrumentation_rejection=required\n" \
        "$(( torrent_after - torrent_before ))" "$max_in_flight_after"
    cleanup_processes
}

run_mock_debug_suspended_background() {
    local phase_dir="$TMP_ROOT/mock-debug-suspended"
    local phase_home="$phase_dir/home"
    prepare_mock_debug_acceptance_phase "$phase_dir" "$phase_home" suspend
    sleep_unlocked_warmup "$RELEASE_WARMUP_SECONDS" "hidden-suspended"
    wait_for_mock_idle "suspended foreground warmup"
    hide_isolated_app
    sleep_unlocked_warmup \
        "$RELEASE_VISIBILITY_SETTLE_SECONDS" \
        "hidden-suspended visibility settle"
    verify_isolated_app_hidden
    wait_for_mock_idle "suspended hidden transition"

    local before requests_before torrent_before recent_before session_get_before session_stats_before
    local in_flight_before max_in_flight_before torrents_before selector_before field_count_before request_bytes_before
    before="$(mock_metrics)"
    read -r requests_before torrent_before recent_before session_get_before session_stats_before \
        in_flight_before max_in_flight_before torrents_before selector_before field_count_before \
        request_bytes_before <<< "$before"
    capture_state_window \
        "$APP_PID" \
        "$RELEASE_VOLUME_WINDOW_SECONDS" \
        hidden \
        "hidden-suspended measurement"
    local after requests_after torrent_after recent_after session_get_after session_stats_after
    local in_flight_after max_in_flight_after torrents_after selector_after field_count_after request_bytes_after
    after="$(mock_metrics)"
    verify_isolated_app_hidden
    read -r requests_after torrent_after recent_after session_get_after session_stats_after \
        in_flight_after max_in_flight_after torrents_after selector_after field_count_after \
        request_bytes_after <<< "$after"
    local request_count=$(( requests_after - requests_before ))
    local torrent_count=$(( torrent_after - torrent_before ))
    local recent_count=$(( recent_after - recent_before ))
    local session_get_count=$(( session_get_after - session_get_before ))
    local session_stats_count=$(( session_stats_after - session_stats_before ))
    record_expected_method_total \
        "suspended background method accounting" \
        "$request_count" \
        "$torrent_count" \
        "$session_get_count" \
        "$session_stats_count"
    record_integer_at_most \
        "suspended background RPC requests" \
        "$request_count" \
        "$RELEASE_SUSPENDED_RPC_MAX"
    record_integer_at_most "suspended background torrent-get requests" "$torrent_count" 0
    record_integer_at_most "suspended background recently-active requests" "$recent_count" 0
    printf "mode=$EVIDENCE_MODE phase=hidden-suspended process_state=inactive_hidden main_window=not_visible_or_miniaturized foreground_evidence=native_hidden duration_seconds=%s accepted_rpc_requests=%s torrent_get_requests=%s recently_active_torrent_get_requests=%s session_get_requests=%s session_stats_requests=%s max_in_flight_requests=%s rpc_threshold=exactly_0\n" \
        "$RELEASE_VOLUME_WINDOW_SECONDS" "$request_count" "$torrent_count" "$recent_count" \
        "$session_get_count" "$session_stats_count" "$max_in_flight_after"
    [[ "$torrents_after" == "1000" ]] \
        || fail "suspended mock ended in an unexpected state: $after"
    record_integer_at_most \
        "suspended maximum concurrent RPC requests" \
        "$max_in_flight_after" \
        "$MAX_IN_FLIGHT_REQUESTS"
    verify_isolated_app_hidden
    finish_instrumented_phase "hidden-suspended" 1000 list
    cleanup_processes
}

finish_mock_debug_acceptance_gates() {
    if (( ${#GATE_FAILURES[@]} > 0 )); then
        printf 'mode=%s %s=blocked failed_or_unmeasured_gate_count=%s\n' \
            "$EVIDENCE_MODE" "$ACCEPTANCE_RESULT_KEY" "${#GATE_FAILURES[@]}" >&2
        printf '%s\n' 'release_acceptance=blocked reason=measured_artifact_is_an_isolated_DEBUG_copy_not_the_final_Developer_ID_notarized_Release_artifact' >&2
        local failure
        for failure in "${GATE_FAILURES[@]}"; do
            printf 'gate_failure=%s\n' "$failure" >&2
        done
        return 1
    fi
    printf 'mode=%s %s=passed native_activation_count=at_least_1 main_window_proof=validated\n' \
        "$EVIDENCE_MODE" "$ACCEPTANCE_RESULT_KEY"
    printf '%s\n' 'release_acceptance=blocked reason=measured_artifact_is_an_isolated_DEBUG_copy_not_the_final_Developer_ID_notarized_Release_artifact'
}

require_positive_integer "MOCK_PORT" "$MOCK_PORT"
(( MOCK_PORT <= 65535 )) || fail "MOCK_PORT must be at most 65535"
require_positive_integer "SAMPLE_INTERVAL_SECONDS" "$SAMPLE_INTERVAL_SECONDS"
require_positive_integer "MOCK_RESPONSE_DELAY_MS" "$MOCK_RESPONSE_DELAY_MS"
[[ "$PERFORMANCE_DETAIL_TARGET_ID" == "1" ]] \
    || fail "large Files acceptance must target generated fixture torrent 1"
(( MOCK_RESPONSE_DELAY_MS > FOREGROUND_INTERVAL_SECONDS * 1000 )) \
    || fail "mock response delay must exceed the foreground poll interval to expose overlap"
require_nonnegative_integer "MAX_IN_FLIGHT_REQUESTS" "$MAX_IN_FLIGHT_REQUESTS"
require_positive_integer \
    "PERFORMANCE_WAKE_TRACE_STARTUP_WAIT_SECONDS" \
    "$PERFORMANCE_WAKE_TRACE_STARTUP_WAIT_SECONDS"
require_positive_integer "RELEASE_FILES_SAMPLE_SECONDS" "$RELEASE_FILES_SAMPLE_SECONDS"
(( RELEASE_FILES_SAMPLE_SECONDS >= 60 )) \
    || fail "RELEASE_FILES_SAMPLE_SECONDS must be at least 60"
require_positive_integer "RELEASE_FILES_WARMUP_SECONDS" "$RELEASE_FILES_WARMUP_SECONDS"
require_positive_integer "RELEASE_SCALE_SAMPLE_SECONDS" "$RELEASE_SCALE_SAMPLE_SECONDS"
(( RELEASE_SCALE_SAMPLE_SECONDS >= 60 )) \
    || fail "RELEASE_SCALE_SAMPLE_SECONDS must be at least 60"
require_nonnegative_decimal \
    "RELEASE_DISCONNECTED_AVERAGE_CPU_MAX" \
    "$RELEASE_DISCONNECTED_AVERAGE_CPU_MAX"
require_nonnegative_decimal \
    "RELEASE_DISCONNECTED_P95_CPU_MAX" \
    "$RELEASE_DISCONNECTED_P95_CPU_MAX"
require_nonnegative_decimal \
    "RELEASE_BACKGROUND_P95_CPU_MAX" \
    "$RELEASE_BACKGROUND_P95_CPU_MAX"
require_positive_integer \
    "RELEASE_THOUSAND_FOOTPRINT_MAX_BYTES" \
    "$RELEASE_THOUSAND_FOOTPRINT_MAX_BYTES"
require_positive_integer \
    "RELEASE_FILES_FOOTPRINT_MAX_BYTES" \
    "$RELEASE_FILES_FOOTPRINT_MAX_BYTES"
require_positive_integer \
    "RELEASE_MAIN_THREAD_P95_MAX_NANOSECONDS" \
    "$RELEASE_MAIN_THREAD_P95_MAX_NANOSECONDS"
require_positive_integer \
    "RELEASE_MAIN_THREAD_MAX_NANOSECONDS" \
    "$RELEASE_MAIN_THREAD_MAX_NANOSECONDS"
require_positive_integer \
    "RELEASE_UI_TIMING_MAX_NANOSECONDS" \
    "$RELEASE_UI_TIMING_MAX_NANOSECONDS"
require_positive_integer \
    "RELEASE_FILES_TIMING_MAX_NANOSECONDS" \
    "$RELEASE_FILES_TIMING_MAX_NANOSECONDS"
require_nonnegative_decimal \
    "RELEASE_FILES_RPC_MAX_PER_MINUTE" \
    "$RELEASE_FILES_RPC_MAX_PER_MINUTE"
require_nonnegative_decimal \
    "RELEASE_FOREGROUND_WAKE_MAX_PER_SECOND" \
    "$RELEASE_FOREGROUND_WAKE_MAX_PER_SECOND"
require_nonnegative_decimal \
    "RELEASE_HIDDEN_WAKE_MAX_PER_SECOND" \
    "$RELEASE_HIDDEN_WAKE_MAX_PER_SECOND"
if [[ "$CAPTURE_MODE" == "smoke" ]]; then
    require_positive_integer "SMOKE_SAMPLE_SECONDS" "$SMOKE_SAMPLE_SECONDS"
    require_positive_integer "SMOKE_WARMUP_SECONDS" "$SMOKE_WARMUP_SECONDS"
    require_positive_integer "SMOKE_CONNECTED_LIST_REQUEST_MIN" "$SMOKE_CONNECTED_LIST_REQUEST_MIN"
    require_nonnegative_integer "SMOKE_DISCONNECTED_REQUEST_MAX" "$SMOKE_DISCONNECTED_REQUEST_MAX"
    require_nonnegative_decimal "SMOKE_CONNECTED_AVERAGE_CPU_MAX" "$SMOKE_CONNECTED_AVERAGE_CPU_MAX"
    require_nonnegative_decimal "SMOKE_CONNECTED_P95_CPU_MAX" "$SMOKE_CONNECTED_P95_CPU_MAX"
    require_nonnegative_decimal "SMOKE_DISCONNECTED_AVERAGE_CPU_MAX" "$SMOKE_DISCONNECTED_AVERAGE_CPU_MAX"
    require_nonnegative_decimal "SMOKE_DISCONNECTED_P95_CPU_MAX" "$SMOKE_DISCONNECTED_P95_CPU_MAX"
fi
require_command /usr/bin/codesign
require_command /usr/bin/curl
require_command /usr/bin/footprint
require_command /usr/bin/osascript
require_command /usr/bin/perl
require_command /usr/bin/python3
require_command /usr/bin/sandbox-exec
require_command /usr/bin/plutil
require_command /usr/sbin/ioreg
require_command /usr/sbin/lsof

assert_console_unlocked "VAL-005 startup"
verify_installed_app
if /usr/bin/pgrep -x TransmissionRemoteMac >/dev/null 2>&1; then
    fail "TransmissionRemoteMac is already running; quit it so the harness cannot sample or alter the wrong process"
fi

TMP_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/transmission-remote-mac-val005.XXXXXX")"
TMP_ROOT="$(cd "$TMP_ROOT" && /bin/pwd -P)"
REAL_PROFILE_BEFORE="$(fingerprint_file "$REAL_PROFILE_FILE")" \
    || fail "could not fingerprint the real profile file before capture"
REAL_DEFAULTS_BEFORE="$(fingerprint_file "$REAL_DEFAULTS_FILE")" \
    || fail "could not fingerprint the real defaults file before capture"
REAL_FINGERPRINTS_CAPTURED=1

printf 'VAL-005 mock-only capture: mode=%s app=%s mock=http://%s:%s/transmission/rpc rows=0,100,1000 large_files=10000 response_delay_ms=%s overlap_probe=delay_exceeds_%ss_foreground_interval password_store_isolation=DEBUG_noop_runtime_proof_required\n' \
    "$CAPTURE_MODE" "$APP_BUNDLE" "$MOCK_HOST" "$MOCK_PORT" \
    "$MOCK_RESPONSE_DELAY_MS" "$FOREGROUND_INTERVAL_SECONDS"
if [[ "$CAPTURE_MODE" == "smoke" ]]; then
    printf 'mode=smoke release_acceptance=no reason=short_non_release_baseline duration_seconds=%s\n' \
        "$SMOKE_SAMPLE_SECONDS"
    run_smoke_phase disconnected false
    run_smoke_phase connected true
else
    printf 'mode=%s thresholds=disconnected_average_below_%s,disconnected_p95_below_%s,connected_and_files_average_below_%s,connected_and_files_p95_below_%s_over_%s_seconds,background_and_hidden_average_below_%s,background_and_hidden_p95_below_%s,thousand_physical_footprint_below_%s_bytes,files_physical_footprint_below_%s_bytes,main_thread_p95_below_%s_ns,main_thread_max_below_%s_ns,ui_and_files_below_%s_ns active_visible_rpc_at_most_%s_per_minute,files_detail_rpc_at_most_%s_per_minute,idle_visible_rpc_at_most_%s_per_minute,background_and_hidden_list_at_most_%s_per_minute,background_and_hidden_health_at_most_%s_per_minute,foreground_wakes_below_%s_per_second,background_and_hidden_wakes_below_%s_per_second,suspended_rpc_exactly_0,%s\n' \
        "$EVIDENCE_MODE" \
        "$RELEASE_DISCONNECTED_AVERAGE_CPU_MAX" "$RELEASE_DISCONNECTED_P95_CPU_MAX" \
        "$RELEASE_CONNECTED_AVERAGE_CPU_MAX" "$RELEASE_CONNECTED_P95_CPU_MAX" \
        "$RELEASE_SAMPLE_SECONDS" "$RELEASE_HIDDEN_AVERAGE_CPU_MAX" \
        "$RELEASE_BACKGROUND_P95_CPU_MAX" \
        "$RELEASE_THOUSAND_FOOTPRINT_MAX_BYTES" "$RELEASE_FILES_FOOTPRINT_MAX_BYTES" \
        "$RELEASE_MAIN_THREAD_P95_MAX_NANOSECONDS" "$RELEASE_MAIN_THREAD_MAX_NANOSECONDS" \
        "$RELEASE_UI_TIMING_MAX_NANOSECONDS" \
        "$RELEASE_ACTIVE_VISIBLE_RPC_MAX_PER_MINUTE" "$RELEASE_FILES_RPC_MAX_PER_MINUTE" \
        "$RELEASE_IDLE_VISIBLE_RPC_MAX_PER_MINUTE" "$RELEASE_HIDDEN_LIST_MAX_PER_MINUTE" \
        "$RELEASE_HIDDEN_HEALTH_MAX_PER_MINUTE" "$RELEASE_FOREGROUND_WAKE_MAX_PER_SECOND" \
        "$RELEASE_HIDDEN_WAKE_MAX_PER_SECOND" "$STALE_GENERATION_GATE_EVIDENCE"
    run_mock_debug_disconnected
    fail_on_recorded_gate_failures disconnected-visible
    run_mock_debug_scale_dataset 0
    fail_on_recorded_gate_failures scale-0
    run_mock_debug_scale_dataset 100
    fail_on_recorded_gate_failures scale-100
    run_mock_debug_connected_and_hidden
    fail_on_recorded_gate_failures connected-background-hidden
    run_mock_debug_large_files_detail
    fail_on_recorded_gate_failures large-files-detail
    run_mock_debug_stale_generation
    fail_on_recorded_gate_failures stale-generation
    run_mock_debug_suspended_background
    fail_on_recorded_gate_failures hidden-suspended
fi

[[ "$(fingerprint_file "$REAL_PROFILE_FILE")" == "$REAL_PROFILE_BEFORE" ]] \
    || fail "the real ConnectionProfiles.json changed during isolated capture"
[[ "$(fingerprint_file "$REAL_DEFAULTS_FILE")" == "$REAL_DEFAULTS_BEFORE" ]] \
    || fail "the real application defaults changed during isolated capture"

printf 'isolation=proven foundation_home=temp password_store=DEBUG_in_memory_noop password_store_runtime_proof=matched seatbelt_network_outbound=%s:%s mock_endpoint=%s:%s real_profile_unchanged=yes real_defaults_unchanged=yes cleanup=automatic\n' \
    "$SANDBOX_REMOTE_HOST" "$MOCK_PORT" "$MOCK_HOST" "$MOCK_PORT"

if [[ "$CAPTURE_MODE" == "mock-debug-acceptance" ]]; then
    finish_mock_debug_acceptance_gates
fi
