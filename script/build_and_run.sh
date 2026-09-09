#!/usr/bin/env bash
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

MODE="${1:-run}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--install-only|install-only)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install-only]" >&2
    exit 2
    ;;
esac

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

XCRUN_BIN="/usr/bin/xcrun"
SWIFT_BIN="$("$XCRUN_BIN" --find swift)"
LLDB_BIN="$("$XCRUN_BIN" --find lldb)"

# shellcheck source=lib/app_bundle.sh
source "$ROOT_DIR/script/lib/app_bundle.sh"
load_app_metadata "$ROOT_DIR"

DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_EXECUTABLE_NAME.app"
APPLICATIONS_BUNDLE="/Applications/$APP_EXECUTABLE_NAME.app"
APPLICATIONS_EXECUTABLE="$APPLICATIONS_BUNDLE/Contents/MacOS/$APP_EXECUTABLE_NAME"
APPLICATIONS_STAGING_BUNDLE="/Applications/.$APP_EXECUTABLE_NAME.installing.$$"
APPLICATIONS_BACKUP_BUNDLE="/Applications/.$APP_EXECUTABLE_NAME.backup.$$"
INSTALL_SWAP_STARTED=0
INSTALL_COMMITTED=0

cleanup_build_state() {
  local exit_status="$?"

  /bin/rm -rf "$SIGNATURE_WORK_DIR" "$APPLICATIONS_STAGING_BUNDLE"
  if [[ "$INSTALL_SWAP_STARTED" == 1 && "$INSTALL_COMMITTED" != 1 ]]; then
    /bin/rm -rf "$APPLICATIONS_BUNDLE"
    if [[ -e "$APPLICATIONS_BACKUP_BUNDLE" || -L "$APPLICATIONS_BACKUP_BUNDLE" ]]; then
      /bin/mv "$APPLICATIONS_BACKUP_BUNDLE" "$APPLICATIONS_BUNDLE" || true
    fi
  fi
  /bin/rm -rf "$APPLICATIONS_BACKUP_BUNDLE"
  exit "$exit_status"
}

process_ids_for_executable() {
  local expected_executable="$1"
  local pid
  local process_executable

  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    process_executable="$(/bin/ps -p "$pid" -o comm= 2>/dev/null | /usr/bin/awk '{$1=$1; print}')"
    if [[ "$process_executable" == "$expected_executable" ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(/usr/bin/pgrep -x "$APP_EXECUTABLE_NAME" 2>/dev/null || true)
}

terminate_executable() {
  local expected_executable="$1"
  local pids
  local pid
  local attempt

  pids="$(process_ids_for_executable "$expected_executable")"
  [[ -n "$pids" ]] || return 0
  for pid in $pids; do
    /bin/kill -TERM "$pid" 2>/dev/null || true
  done
  for (( attempt = 0; attempt < 50; attempt++ )); do
    [[ -z "$(process_ids_for_executable "$expected_executable")" ]] && return
    /bin/sleep 0.1
  done
  pids="$(process_ids_for_executable "$expected_executable")"
  for pid in $pids; do
    /bin/kill -KILL "$pid" 2>/dev/null || true
  done
  for (( attempt = 0; attempt < 20; attempt++ )); do
    [[ -z "$(process_ids_for_executable "$expected_executable")" ]] && return
    /bin/sleep 0.1
  done
  echo "Unable to stop app process at: $expected_executable" >&2
  exit 1
}

verify_exact_app_process() {
  local pids
  local count
  local attempt

  for (( attempt = 0; attempt < 50; attempt++ )); do
    pids="$(process_ids_for_executable "$APPLICATIONS_EXECUTABLE")"
    count="$(printf '%s\n' "$pids" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')"
    if [[ "$count" == 1 ]]; then
      return
    fi
    if (( count > 1 )); then
      echo "More than one installed app process is running: $pids" >&2
      exit 1
    fi
    /bin/sleep 0.1
  done
  echo "Installed app did not launch from the expected executable: $APPLICATIONS_EXECUTABLE" >&2
  exit 1
}

cd "$ROOT_DIR"

CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$(git config --local --get transmissionRemoteMac.codesignIdentity || true)}"
EXPECTED_TEAM_ID="${EXPECTED_TEAM_ID:-$(git config --local --get transmissionRemoteMac.teamIdentifier || true)}"

if [[ -z "$CODESIGN_IDENTITY" || -z "$EXPECTED_TEAM_ID" ]]; then
  echo "Configure a stable Apple Development signing identity before building:" >&2
  echo "  git config --local transmissionRemoteMac.codesignIdentity 'Apple Development: Your Name (TEAMID)'" >&2
  echo "  git config --local transmissionRemoteMac.teamIdentifier TEAMID" >&2
  echo "CODESIGN_IDENTITY and EXPECTED_TEAM_ID environment variables are also supported." >&2
  exit 2
fi

if [[ "$CODESIGN_IDENTITY" != "Apple Development:"* ]]; then
  echo "Development builds require an Apple Development identity, not: $CODESIGN_IDENTITY" >&2
  exit 2
fi

DEVELOPMENT_CERT_SHA1="$(resolve_codesigning_identity_sha1 "$CODESIGN_IDENTITY")"
SIGNATURE_WORK_DIR="$DIST_DIR/.signature-verification"
trap cleanup_build_state EXIT

terminate_executable "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE_NAME"

"$SWIFT_BIN" build
BUILD_BINARY="$("$SWIFT_BIN" build --show-bin-path)/$APP_EXECUTABLE_NAME"

verify_development_signature() {
  local bundle="$1"
  local signature_details

  /usr/bin/codesign --verify --strict --verbose=2 "$bundle"
  signature_details="$(/usr/bin/codesign -dvvv "$bundle" 2>&1)"
  if [[ "$signature_details" != *"Authority=$CODESIGN_IDENTITY"* ]]; then
    echo "Signed app does not use the approved Apple Development identity: $CODESIGN_IDENTITY" >&2
    exit 1
  fi
  if [[ "$signature_details" != *"TeamIdentifier=$EXPECTED_TEAM_ID"* ]]; then
    echo "Signed app does not use expected development Team ID: $EXPECTED_TEAM_ID" >&2
    exit 1
  fi
  if [[ "$signature_details" != *"Identifier=$APP_BUNDLE_ID"* ]]; then
    echo "Signed app does not use expected bundle identifier: $APP_BUNDLE_ID" >&2
    exit 1
  fi

  extract_signed_leaf_fingerprints "$bundle" "$SIGNATURE_WORK_DIR"
  if [[ "$SIGNED_LEAF_SHA1" != "$DEVELOPMENT_CERT_SHA1" ]]; then
    echo "Signed app leaf certificate does not match the configured Apple Development certificate." >&2
    exit 1
  fi
  /bin/rm -rf "$SIGNATURE_WORK_DIR"
}

/bin/rm -rf "$APP_BUNDLE"
assemble_app_bundle "$ROOT_DIR" "$BUILD_BINARY" "$APP_BUNDLE"
sanitize_and_verify_unsigned_bundle_xattrs "$APP_BUNDLE"

/usr/bin/codesign --force \
  --sign "$DEVELOPMENT_CERT_SHA1" \
  --identifier "$APP_BUNDLE_ID" \
  --options runtime \
  --timestamp=none \
  "$APP_BUNDLE"
verify_development_signature "$APP_BUNDLE"

/bin/rm -rf "$APPLICATIONS_STAGING_BUNDLE" "$APPLICATIONS_BACKUP_BUNDLE"
/bin/cp -RX "$APP_BUNDLE" "$APPLICATIONS_STAGING_BUNDLE"
verify_development_signature "$APPLICATIONS_STAGING_BUNDLE"

terminate_executable "$APPLICATIONS_EXECUTABLE"
if [[ -e "$APPLICATIONS_BUNDLE" || -L "$APPLICATIONS_BUNDLE" ]]; then
  /bin/mv "$APPLICATIONS_BUNDLE" "$APPLICATIONS_BACKUP_BUNDLE"
fi
INSTALL_SWAP_STARTED=1
/bin/mv "$APPLICATIONS_STAGING_BUNDLE" "$APPLICATIONS_BUNDLE"
verify_development_signature "$APPLICATIONS_BUNDLE"
INSTALL_COMMITTED=1
/bin/rm -rf "$APPLICATIONS_BACKUP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APPLICATIONS_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    "$LLDB_BIN" -- "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE_NAME"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$APP_BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_exact_app_process
    /bin/sleep 1
    verify_exact_app_process
    ;;
  --install-only|install-only)
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install-only]" >&2
    exit 2
    ;;
esac
