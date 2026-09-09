#!/usr/bin/env bash
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

XCRUN_BIN="/usr/bin/xcrun"
SWIFT_BIN="$("$XCRUN_BIN" --find swift)"
XCODEBUILD_BIN="$("$XCRUN_BIN" --find xcodebuild)"

# shellcheck source=lib/app_bundle.sh
source "$ROOT_DIR/script/lib/app_bundle.sh"
# shellcheck source=lib/release_contract.sh
source "$ROOT_DIR/script/lib/release_contract.sh"
load_app_metadata "$ROOT_DIR" release

RELEASE_TAG="v$APP_VERSION"
RELEASE_ROOT="$ROOT_DIR/dist/release"
WORK_DIR="$RELEASE_ROOT/work"
APP_BUNDLE="$WORK_DIR/$APP_EXECUTABLE_NAME.app"
SUBMISSION_ARCHIVE="$WORK_DIR/$APP_EXECUTABLE_NAME-notarization.zip"
NOTARY_RESULT_JSON="$WORK_DIR/notary-result.json"
VALIDATION_DIR="$WORK_DIR/final-validation"
ARTIFACT_BASENAME="$APP_EXECUTABLE_NAME-$APP_VERSION+$APP_BUILD_NUMBER-macOS"
SOURCE_BASENAME="$APP_EXECUTABLE_NAME-$APP_VERSION+$APP_BUILD_NUMBER-source"
ARTIFACT="$RELEASE_ROOT/$ARTIFACT_BASENAME.zip"
SOURCE_ARTIFACT="$RELEASE_ROOT/$SOURCE_BASENAME.tar.gz"
CHECKSUM_FILE="$RELEASE_ROOT/$ARTIFACT_BASENAME.sha256"
MANIFEST="$RELEASE_ROOT/$ARTIFACT_BASENAME.manifest.json"
PERFORMANCE_ATTESTATION="$RELEASE_ROOT/$ARTIFACT_BASENAME.performance-attestation.json"
PERFORMANCE_ATTESTER_SCRATCH="$WORK_DIR/performance-attester-scratch"
SWIFT_BUILD_DIR="$WORK_DIR/swift-build"
PERFORMANCE_ATTESTER_TIMEOUT_SECONDS="${PERFORMANCE_ATTESTER_TIMEOUT_SECONDS:-1800}"
ARTIFACT_DESCRIPTOR_TOKEN="__TRANSMISSION_REMOTE_MAC_ARTIFACT_DESCRIPTOR__"
STAGED_ARTIFACT="$WORK_DIR/$(basename "$ARTIFACT")"
STAGED_SOURCE_ARTIFACT="$WORK_DIR/$(basename "$SOURCE_ARTIFACT")"
STAGED_CHECKSUM_FILE="$WORK_DIR/$(basename "$CHECKSUM_FILE")"
STAGED_MANIFEST="$WORK_DIR/$(basename "$MANIFEST")"
STAGED_PERFORMANCE_ATTESTATION="$WORK_DIR/$(basename "$PERFORMANCE_ATTESTATION")"
RELEASE_COMPLETE=0
PUBLISHED_ARTIFACT=0
PUBLISHED_SOURCE_ARTIFACT=0
PUBLISHED_CHECKSUM=0
PUBLISHED_MANIFEST=0
PUBLISHED_PERFORMANCE_ATTESTATION=0
STAGED_ARTIFACT_SNAPSHOT=""
STAGED_SOURCE_ARTIFACT_SNAPSHOT=""
STAGED_CHECKSUM_FILE_SNAPSHOT=""
STAGED_MANIFEST_SNAPSHOT=""
STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT=""
PERFORMANCE_ATTESTER_SNAPSHOT=""

DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-$(/usr/bin/git -C "$ROOT_DIR" config --local --get transmissionRemoteMac.releaseCodesignIdentity || true)}"
RELEASE_TEAM_ID="${RELEASE_TEAM_ID:-$(/usr/bin/git -C "$ROOT_DIR" config --local --get transmissionRemoteMac.releaseTeamIdentifier || true)}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-$(/usr/bin/git -C "$ROOT_DIR" config --local --get transmissionRemoteMac.notarytoolProfile || true)}"
PERFORMANCE_ATTESTER="${PERFORMANCE_ATTESTER:-$(/usr/bin/git -C "$ROOT_DIR" config --local --get transmissionRemoteMac.performanceAttester || true)}"

manage_release_work_dir() {
  local action="$1"

  case "$WORK_DIR" in
    "$ROOT_DIR"/dist/release/work) ;;
    *) return 1 ;;
  esac
  /usr/bin/python3 - "$ROOT_DIR" "$action" <<'PY'
import os
import stat
import sys

root_path, action = sys.argv[1:]
if action not in {"create", "remove"}:
    raise SystemExit("invalid release work-directory action")


def open_directory(parent_descriptor, name, *, create):
    if create:
        try:
            os.mkdir(name, 0o755, dir_fd=parent_descriptor)
        except FileExistsError:
            pass
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
    return os.open(name, flags, dir_fd=parent_descriptor)


def remove_directory_tree(parent_descriptor, name):
    try:
        descriptor = open_directory(parent_descriptor, name, create=False)
    except FileNotFoundError:
        return
    try:
        for entry in os.listdir(descriptor):
            state = os.stat(entry, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISDIR(state.st_mode):
                remove_directory_tree(descriptor, entry)
            else:
                os.unlink(entry, dir_fd=descriptor)
    finally:
        os.close(descriptor)
    os.rmdir(name, dir_fd=parent_descriptor)


root_descriptor = os.open(
    os.path.realpath(root_path),
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
)
try:
    dist_descriptor = open_directory(root_descriptor, "dist", create=True)
    try:
        release_descriptor = open_directory(dist_descriptor, "release", create=True)
        try:
            remove_directory_tree(release_descriptor, "work")
            if action == "create":
                os.mkdir("work", 0o755, dir_fd=release_descriptor)
        finally:
            os.close(release_descriptor)
    finally:
        os.close(dist_descriptor)
finally:
    os.close(root_descriptor)
PY
}

safe_clean_work_dir() {
  manage_release_work_dir create || \
    fail "Refusing to clean unsafe release work directory: $WORK_DIR"
}

clean_release_state() {
  case "$WORK_DIR" in
    "$ROOT_DIR"/dist/release/work) ;;
    *) return ;;
  esac
  if [[ "$RELEASE_COMPLETE" != 1 ]]; then
    remove_owned_release_output \
      "$PUBLISHED_ARTIFACT" "$ARTIFACT" "$STAGED_ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT"
    remove_owned_release_output \
      "$PUBLISHED_SOURCE_ARTIFACT" "$SOURCE_ARTIFACT" "$STAGED_SOURCE_ARTIFACT" \
      "$STAGED_SOURCE_ARTIFACT_SNAPSHOT"
    remove_owned_release_output \
      "$PUBLISHED_CHECKSUM" "$CHECKSUM_FILE" "$STAGED_CHECKSUM_FILE" \
      "$STAGED_CHECKSUM_FILE_SNAPSHOT"
    remove_owned_release_output \
      "$PUBLISHED_MANIFEST" "$MANIFEST" "$STAGED_MANIFEST" "$STAGED_MANIFEST_SNAPSHOT"
    remove_owned_release_output \
      "$PUBLISHED_PERFORMANCE_ATTESTATION" \
      "$PERFORMANCE_ATTESTATION" \
      "$STAGED_PERFORMANCE_ATTESTATION" \
      "$STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT"
  fi
  if ! manage_release_work_dir remove; then
    echo "Refusing to remove unsafe release work directory: $WORK_DIR" >&2
  fi
}

assert_output_paths_available() {
  local output

  for output in \
    "$ARTIFACT" \
    "$SOURCE_ARTIFACT" \
    "$CHECKSUM_FILE" \
    "$MANIFEST" \
    "$PERFORMANCE_ATTESTATION"; do
    [[ ! -e "$output" && ! -L "$output" ]] || \
      fail "Refusing to overwrite existing release output: $output"
  done
}

verify_distribution_signature() {
  local bundle="$1"
  local certificate_dir="$2"
  local signature_details

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
  signature_details="$(/usr/bin/codesign -dvvv "$bundle" 2>&1)"
  [[ "$signature_details" == *"Authority=$DEVELOPER_ID_APPLICATION"* ]] || \
    fail "Distribution app is not signed by the configured Developer ID Application identity."
  [[ "$signature_details" == *"TeamIdentifier=$RELEASE_TEAM_ID"* ]] || \
    fail "Distribution app does not use expected Team ID: $RELEASE_TEAM_ID"
  [[ "$signature_details" == *"Identifier=$APP_BUNDLE_ID"* ]] || \
    fail "Distribution app does not use expected bundle identifier: $APP_BUNDLE_ID"
  [[ "$signature_details" == *"runtime"* ]] || \
    fail "Distribution app signature is missing the hardened runtime flag."
  [[ "$signature_details" == *"Timestamp="* ]] || \
    fail "Distribution app signature is missing a secure timestamp."

  extract_signed_leaf_fingerprints "$bundle" "$certificate_dir"
  [[ "$SIGNED_LEAF_SHA1" == "$RELEASE_CERT_SHA1" ]] || \
    fail "Distribution app leaf certificate does not match the configured Developer ID certificate."
  RELEASE_SIGNING_LEAF_SHA256="$SIGNED_LEAF_SHA256"
  export RELEASE_SIGNING_LEAF_SHA256
  /bin/rm -rf "$certificate_dir"
}

verify_packaged_file_hash() {
  local packaged_file="$1"
  local expected_hash="$2"

  [[ "$(sha256_file "$packaged_file")" == "$expected_hash" ]] || \
    fail "Packaged release input hash does not match: $packaged_file"
}

validate_final_artifact() {
  local extracted_app="$VALIDATION_DIR/$APP_EXECUTABLE_NAME.app"
  local extracted_entry=""
  local extracted_count=0
  local entry

  /bin/rm -rf "$VALIDATION_DIR"
  /bin/mkdir -p "$VALIDATION_DIR"
  /usr/bin/ditto -x -k "$STAGED_ARTIFACT" "$VALIDATION_DIR"

  shopt -s nullglob dotglob
  for entry in "$VALIDATION_DIR"/*; do
    extracted_entry="$entry"
    extracted_count=$((extracted_count + 1))
  done
  shopt -u nullglob dotglob
  [[ "$extracted_count" == 1 && "$extracted_entry" == "$extracted_app" ]] || \
    fail "Final ZIP must extract exactly one expected app bundle."

  /usr/bin/plutil -lint "$extracted_app/Contents/Info.plist" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$extracted_app/Contents/Info.plist")" == "$APP_BUNDLE_ID" ]] || \
    fail "Extracted app bundle identifier is incorrect."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$extracted_app/Contents/Info.plist")" == "$APP_VERSION" ]] || \
    fail "Extracted app semantic version is incorrect."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$extracted_app/Contents/Info.plist")" == "$APP_BUILD_NUMBER" ]] || \
    fail "Extracted app build number is incorrect."

  verify_packaged_file_hash "$extracted_app/Contents/Resources/LICENSE" "$LICENSE_SHA256"
  verify_packaged_file_hash "$extracted_app/Contents/Resources/CREDITS.md" "$CREDITS_SHA256"
  verify_packaged_file_hash "$extracted_app/Contents/Resources/PRIVACY.md" "$PRIVACY_SHA256"
  verify_packaged_file_hash "$extracted_app/Contents/Resources/AppIcon.icns" "$ICON_SHA256"
  verify_distribution_signature "$extracted_app" "$WORK_DIR/extracted-signature-verification"
  "$XCRUN_BIN" stapler validate "$extracted_app"
  /usr/sbin/spctl --assess --type execute --verbose=4 "$extracted_app"
}

resolve_performance_attester() {
  [[ -n "$PERFORMANCE_ATTESTER" ]] || fail \
    "Configure transmissionRemoteMac.performanceAttester or PERFORMANCE_ATTESTER. Release publication requires performance proof for the exact final artifact."
  [[ "$PERFORMANCE_ATTESTER" == /* ]] || fail \
    "PERFORMANCE_ATTESTER must be an absolute executable path."
  if [[ "$PERFORMANCE_ATTESTER" == *$'\n'* || "$PERFORMANCE_ATTESTER" == *$'\r'* || "$PERFORMANCE_ATTESTER" == *$'\t'* ]]; then
    fail "PERFORMANCE_ATTESTER contains forbidden control characters."
  fi
  [[ ! -L "$PERFORMANCE_ATTESTER" ]] || fail \
    "Configured performance attester must not be a symlink: $PERFORMANCE_ATTESTER"

  PERFORMANCE_ATTESTER_CANONICAL="$(/usr/bin/python3 -c \
    'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$PERFORMANCE_ATTESTER")"
  [[ "$PERFORMANCE_ATTESTER_CANONICAL" == /* ]] || fail \
    "Could not resolve PERFORMANCE_ATTESTER to an absolute path."
  regular_file_snapshot "$PERFORMANCE_ATTESTER_CANONICAL" >/dev/null || fail \
    "Configured performance attester is not a regular non-symlink file: $PERFORMANCE_ATTESTER_CANONICAL"
  [[ -x "$PERFORMANCE_ATTESTER_CANONICAL" ]] || fail \
    "Configured performance attester is not an executable regular file: $PERFORMANCE_ATTESTER_CANONICAL"
  [[ "$PERFORMANCE_ATTESTER_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || fail \
    "PERFORMANCE_ATTESTER_TIMEOUT_SECONDS must be a positive integer."
  (( PERFORMANCE_ATTESTER_TIMEOUT_SECONDS >= 1 && PERFORMANCE_ATTESTER_TIMEOUT_SECONDS <= 7200 )) || fail \
    "PERFORMANCE_ATTESTER_TIMEOUT_SECONDS must be between 1 and 7200 seconds."
}

run_isolated_performance_attester() {
  local attester_path="$1"
  local attester_snapshot="$2"
  local artifact_path="$3"
  local artifact_snapshot="$4"
  local scratch_path="$5"
  local output_path="$6"
  local timeout_seconds="$7"
  shift 7

  /usr/bin/python3 - \
    "$attester_path" \
    "$attester_snapshot" \
    "$artifact_path" \
    "$artifact_snapshot" \
    "$scratch_path" \
    "$output_path" \
    "$timeout_seconds" \
    "$ARTIFACT_DESCRIPTOR_TOKEN" \
    "$@" <<'PY'
import ctypes
import hashlib
import os
import re
import resource
import select
import signal
import stat
import sys
import time

(
    attester_path,
    attester_snapshot,
    artifact_path,
    artifact_snapshot,
    scratch_path,
    output_path,
    timeout_text,
    artifact_token,
    *attester_arguments,
) = sys.argv[1:]

snapshot_pattern = re.compile(r"^[0-9a-f]{64}(?:\|[0-9]+){7}$")
if not snapshot_pattern.fullmatch(attester_snapshot):
    raise SystemExit("performance attester snapshot is invalid")
if not snapshot_pattern.fullmatch(artifact_snapshot):
    raise SystemExit("staged artifact snapshot is invalid")
try:
    timeout_seconds = int(timeout_text)
except ValueError:
    raise SystemExit("performance attester timeout is invalid")
if timeout_seconds < 1 or timeout_seconds > 7200:
    raise SystemExit("performance attester timeout is outside the supported range")
if attester_arguments.count(artifact_token) != 1:
    raise SystemExit("performance attester invocation must contain exactly one artifact descriptor token")
if os.path.lexists(scratch_path):
    raise SystemExit("performance attester scratch path already exists")
if os.path.lexists(output_path):
    raise SystemExit("performance attestation output already exists")
os.mkdir(scratch_path, 0o700)
scratch_state = os.lstat(scratch_path)
if not stat.S_ISDIR(scratch_state.st_mode) or stat.S_IMODE(scratch_state.st_mode) != 0o700:
    raise SystemExit("performance attester scratch directory is not private")
canonical_scratch_path = os.path.realpath(scratch_path)
canonical_scratch_state = os.stat(canonical_scratch_path, follow_symlinks=False)
if (
    not stat.S_ISDIR(canonical_scratch_state.st_mode)
    or canonical_scratch_state.st_dev != scratch_state.st_dev
    or canonical_scratch_state.st_ino != scratch_state.st_ino
):
    raise SystemExit("canonical performance attester scratch path changed identity")
execution_directory = os.path.join(
    os.path.dirname(canonical_scratch_path),
    ".performance-attester-executable",
)
execution_path = os.path.join(execution_directory, "performance-attester")
if os.path.lexists(execution_directory):
    raise SystemExit("performance attester executable snapshot directory already exists")


def metadata(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def open_frozen_file(path, expected_snapshot, executable):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SystemExit(f"could not open frozen release input without following symlinks: {path}: {error}")
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise SystemExit(f"frozen release input is not a regular file: {path}")
        if before.st_nlink != 1:
            raise SystemExit(f"frozen release input must have exactly one hard link: {path}")
        if executable and before.st_mode & 0o111 == 0:
            raise SystemExit(f"performance attester is not executable: {path}")

        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        if metadata(before) != metadata(after):
            raise SystemExit(f"frozen release input mutated while it was opened: {path}")
        actual_snapshot = "|".join(
            str(value)
            for value in (digest.hexdigest(), *metadata(after))
        )
        if actual_snapshot != expected_snapshot:
            raise SystemExit(f"frozen release input does not match its paired snapshot: {path}")
        path_state = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(path_state.st_mode) or metadata(path_state) != metadata(after):
            raise SystemExit(f"frozen release input path changed before execution: {path}")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor, after
    except BaseException:
        os.close(descriptor)
        raise


def create_executable_snapshot(source_descriptor, expected_snapshot):
    expected_digest = expected_snapshot.split("|", 1)[0]
    os.mkdir(execution_directory, 0o700)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    destination = os.open(execution_path, flags, 0o700)
    copied_digest = hashlib.sha256()
    try:
        os.lseek(source_descriptor, 0, os.SEEK_SET)
        while True:
            chunk = os.read(source_descriptor, 1024 * 1024)
            if not chunk:
                break
            copied_digest.update(chunk)
            view = memoryview(chunk)
            while view:
                written = os.write(destination, view)
                view = view[written:]
        os.fchmod(destination, 0o500)
        os.fsync(destination)
    finally:
        os.close(destination)
        os.lseek(source_descriptor, 0, os.SEEK_SET)
    if copied_digest.hexdigest() != expected_digest:
        raise SystemExit("private performance attester snapshot does not match the verified descriptor bytes")
    os.chmod(execution_directory, 0o500)

    guard, state = open_frozen_file_for_execution(execution_path, expected_digest)
    return guard, state


def open_frozen_file_for_execution(path, expected_digest):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
    descriptor = os.open(path, flags)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise SystemExit("private performance attester snapshot is not a singleton regular file")
        if stat.S_IMODE(before.st_mode) != 0o500:
            raise SystemExit("private performance attester snapshot permissions changed")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        after = os.fstat(descriptor)
        if metadata(before) != metadata(after) or digest.hexdigest() != expected_digest:
            raise SystemExit("private performance attester snapshot failed exact-content verification")
        path_state = os.stat(path, follow_symlinks=False)
        if not stat.S_ISREG(path_state.st_mode) or metadata(path_state) != metadata(after):
            raise SystemExit("private performance attester snapshot path changed")
        os.lseek(descriptor, 0, os.SEEK_SET)
        return descriptor, after
    except BaseException:
        os.close(descriptor)
        raise


def verify_execution_snapshot_unchanged(descriptor, expected_state, expected_digest):
    os.lseek(descriptor, 0, os.SEEK_SET)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    final_state = os.fstat(descriptor)
    if metadata(final_state) != metadata(expected_state) or digest.hexdigest() != expected_digest:
        raise RuntimeError("private performance attester snapshot mutated during execution")
    path_state = os.stat(execution_path, follow_symlinks=False)
    if not stat.S_ISREG(path_state.st_mode) or metadata(path_state) != metadata(final_state):
        raise RuntimeError("private performance attester snapshot path changed during execution")


attester_descriptor, _ = open_frozen_file(attester_path, attester_snapshot, True)
artifact_descriptor, _ = open_frozen_file(artifact_path, artifact_snapshot, False)
execution_guard_descriptor, execution_guard_state = create_executable_snapshot(
    attester_descriptor,
    attester_snapshot,
)
stdout_read = stdout_write = ready_read = ready_write = null_descriptor = None
child_pid = None
child_status = None
group_ready = False


def group_exists():
    if child_pid is None or not group_ready:
        return False
    try:
        os.killpg(child_pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def reap_child_nonblocking():
    global child_status
    if child_pid is None or child_status is not None:
        return
    waited_pid, status_value = os.waitpid(child_pid, os.WNOHANG)
    if waited_pid == child_pid:
        child_status = status_value


def contain_process_group():
    global child_status
    if child_pid is None:
        return
    if not group_ready:
        try:
            os.kill(child_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if child_status is None:
            try:
                _, child_status = os.waitpid(child_pid, 0)
            except ChildProcessError:
                pass
        return
    if group_ready and group_exists():
        try:
            os.killpg(child_pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        deadline = time.monotonic() + 0.5
        while group_exists() and time.monotonic() < deadline:
            reap_child_nonblocking()
            time.sleep(0.02)
        if group_exists():
            try:
                os.killpg(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + 2.0
    while group_exists() and time.monotonic() < deadline:
        reap_child_nonblocking()
        time.sleep(0.02)
    if group_exists():
        raise RuntimeError("performance attester process group could not be contained")
    if child_status is None:
        try:
            _, child_status = os.waitpid(child_pid, 0)
        except ChildProcessError:
            pass


captured = bytearray()
completed = False
try:
    stdout_read, stdout_write = os.pipe()
    ready_read, ready_write = os.pipe()
    null_descriptor = os.open("/dev/null", os.O_RDONLY | os.O_CLOEXEC)

    sandbox_library = ctypes.CDLL("/usr/lib/libsandbox.1.dylib")
    sandbox_init = sandbox_library.sandbox_init
    sandbox_init.argtypes = [ctypes.c_char_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_char_p)]
    sandbox_init.restype = ctypes.c_int
    sandbox_free_error = sandbox_library.sandbox_free_error
    sandbox_free_error.argtypes = [ctypes.c_char_p]
    sandbox_free_error.restype = None

    escaped_scratch = canonical_scratch_path.replace("\\", "\\\\").replace('"', '\\"')
    sandbox_profile = (
        '(version 1)\n'
        '(allow default)\n'
        '(deny file-write*\n'
        '  (require-all\n'
        '    (require-not (subpath "' + escaped_scratch + '"))\n'
        '    (require-not (literal "/dev/null"))))\n'
    )
    child_environment = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": canonical_scratch_path,
        "TMPDIR": canonical_scratch_path + "/",
        "CFFIXED_USER_HOME": canonical_scratch_path,
        "TRANSMISSION_REMOTE_MAC_RELEASE_ATTESTER_SCRATCH": canonical_scratch_path,
    }
    for key in ("LANG", "LC_ALL", "LC_CTYPE"):
        if key in os.environ:
            child_environment[key] = os.environ[key]

    child_pid = os.fork()
    if child_pid == 0:
        try:
            os.setsid()
            os.write(ready_write, b"R")
            os.dup2(null_descriptor, 0)
            os.dup2(stdout_write, 1)
            os.dup2(artifact_descriptor, 21, inheritable=True)
            os.chdir(canonical_scratch_path)

            maximum_descriptor = min(resource.getrlimit(resource.RLIMIT_NOFILE)[0], 65536)
            os.closerange(3, 21)
            os.closerange(22, int(maximum_descriptor))

            sandbox_error = ctypes.c_char_p()
            if sandbox_init(sandbox_profile.encode("utf-8"), 0, ctypes.byref(sandbox_error)) != 0:
                message = sandbox_error.value.decode("utf-8", "replace") if sandbox_error.value else "unknown error"
                if sandbox_error.value:
                    sandbox_free_error(sandbox_error)
                raise RuntimeError(f"could not apply performance attester sandbox: {message}")

            descriptor_arguments = [
                "/dev/fd/21" if value == artifact_token else value
                for value in attester_arguments
            ]
            os.execve(
                execution_path,
                [execution_path, *descriptor_arguments],
                child_environment,
            )
        except BaseException as error:
            try:
                os.write(2, f"performance attester launch failed: {error}\n".encode("utf-8", "replace"))
            finally:
                os._exit(126)

    os.close(stdout_write)
    stdout_write = None
    os.close(ready_write)
    ready_write = None
    os.close(attester_descriptor)
    attester_descriptor = None
    os.close(artifact_descriptor)
    artifact_descriptor = None
    os.close(null_descriptor)
    null_descriptor = None

    ready, _, _ = select.select([ready_read], [], [], min(5, timeout_seconds))
    if not ready or os.read(ready_read, 1) != b"R":
        raise RuntimeError("performance attester did not enter its isolated process group")
    group_ready = True
    os.close(ready_read)
    ready_read = None
    os.set_blocking(stdout_read, False)

    deadline = time.monotonic() + timeout_seconds
    stdout_eof = False
    while child_status is None or not stdout_eof:
        reap_child_nonblocking()
        if child_status is not None and os.waitstatus_to_exitcode(child_status) != 0:
            raise RuntimeError(
                f"performance attester exited with status {os.waitstatus_to_exitcode(child_status)}"
            )
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise RuntimeError("performance attester timed out")
        readable, _, _ = select.select([stdout_read], [], [], min(0.1, remaining))
        if readable:
            chunk = os.read(stdout_read, 65537)
            if chunk:
                captured.extend(chunk)
                if len(captured) > 65536:
                    raise RuntimeError("performance attester stdout exceeds 64 KiB")
            else:
                stdout_eof = True

    contain_process_group()
    if child_status is None or os.waitstatus_to_exitcode(child_status) != 0:
        raise RuntimeError("performance attester did not exit successfully")
    if not captured:
        raise RuntimeError("performance attester returned empty evidence")
    verify_execution_snapshot_unchanged(
        execution_guard_descriptor,
        execution_guard_state,
        attester_snapshot.split("|", 1)[0],
    )

    output_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    output_descriptor = os.open(output_path, output_flags, 0o600)
    try:
        view = memoryview(captured)
        while view:
            written = os.write(output_descriptor, view)
            view = view[written:]
        os.fsync(output_descriptor)
    finally:
        os.close(output_descriptor)
    completed = True
except BaseException as error:
    try:
        contain_process_group()
    except BaseException as containment_error:
        raise SystemExit(f"{error}; {containment_error}")
    raise SystemExit(str(error))
finally:
    for descriptor in (
        attester_descriptor,
        artifact_descriptor,
        execution_guard_descriptor,
        stdout_read,
        stdout_write,
        ready_read,
        ready_write,
        null_descriptor,
    ):
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    if not completed:
        try:
            os.unlink(output_path)
        except FileNotFoundError:
            pass
    try:
        os.chmod(execution_directory, 0o700)
        os.unlink(execution_path)
        os.rmdir(execution_directory)
    except FileNotFoundError:
        pass
PY
}

validate_performance_attestation() {
  local attestation="$1"
  /usr/bin/python3 - \
    "$attestation" \
    "$(basename "$ARTIFACT")" \
    "$ARTIFACT_SHA256" \
    "$APP_BUNDLE_ID" \
    "$APP_VERSION" \
    "$APP_BUILD_NUMBER" \
    "$RELEASE_SIGNING_LEAF_SHA256" \
    "$RELEASE_TEAM_ID" \
    "$NOTARY_STATUS" \
    "$NOTARY_SUBMISSION_ID" \
    "$PERFORMANCE_ATTESTER_SHA256" \
    "$STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT" <<'PY'
import hashlib
import json
import os
import re
import stat
import sys

(
    path_text,
    artifact_name,
    artifact_sha256,
    bundle_identifier,
    version,
    build,
    leaf_sha256,
    team_identifier,
    notary_status,
    submission_id,
    attester_sha256,
    expected_snapshot,
) = sys.argv[1:]

flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
try:
    attestation_descriptor = os.open(path_text, flags)
except OSError as error:
    raise SystemExit(f"could not open performance attestation without following symlinks: {error}")
try:
    before = os.fstat(attestation_descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit("performance attestation is not a regular file")
    raw = os.read(attestation_descriptor, 65537)
    if os.read(attestation_descriptor, 1):
        raise SystemExit("performance attestation exceeds 64 KiB")
    after = os.fstat(attestation_descriptor)
finally:
    os.close(attestation_descriptor)

metadata = lambda value: (
    value.st_dev,
    value.st_ino,
    value.st_mode,
    value.st_nlink,
    value.st_size,
    value.st_mtime_ns,
    value.st_ctime_ns,
)
if metadata(before) != metadata(after):
    raise SystemExit("performance attestation mutated while it was being validated")
actual_snapshot = "|".join(
    str(value)
    for value in (
        hashlib.sha256(raw).hexdigest(),
        after.st_dev,
        after.st_ino,
        after.st_mode,
        after.st_nlink,
        after.st_size,
        after.st_mtime_ns,
        after.st_ctime_ns,
    )
)
if actual_snapshot != expected_snapshot:
    raise SystemExit("performance attestation does not match its frozen release identity")
try:
    path_state = os.stat(path_text, follow_symlinks=False)
except OSError as error:
    raise SystemExit(f"performance attestation path changed during validation: {error}")
if not stat.S_ISREG(path_state.st_mode) or metadata(path_state) != metadata(after):
    raise SystemExit("performance attestation path no longer names the validated regular file")

if not raw or len(raw) > 65536:
    raise SystemExit("performance attestation must be between 1 byte and 64 KiB")
try:
    text = raw.decode("utf-8")
    payload = json.loads(text)
except (UnicodeDecodeError, json.JSONDecodeError) as error:
    raise SystemExit(f"performance attestation is not UTF-8 JSON: {error}")

expected = {
    "attester": {
        "sha256": attester_sha256,
    },
    "artifact": {
        "build": build,
        "bundleIdentifier": bundle_identifier,
        "fileName": artifact_name,
        "sha256": artifact_sha256,
        "version": version,
    },
    "notarization": {
        "status": notary_status,
        "submissionId": submission_id,
    },
    "result": "passed",
    "schemaVersion": 1,
    "signing": {
        "leafSha256": leaf_sha256,
        "teamIdentifier": team_identifier,
    },
}
if payload != expected:
    raise SystemExit("performance attestation fields do not exactly match the staged release evidence")
if type(payload["schemaVersion"]) is not int:
    raise SystemExit("performance attestation schemaVersion must be an integer")
if not re.fullmatch(r"[0-9a-f]{64}", artifact_sha256):
    raise SystemExit("staged artifact SHA-256 is not canonical lowercase hexadecimal")
if not re.fullmatch(r"[0-9a-f]{64}", leaf_sha256):
    raise SystemExit("signing leaf SHA-256 is not canonical lowercase hexadecimal")
if not re.fullmatch(r"[0-9a-f]{64}", attester_sha256):
    raise SystemExit("performance attester SHA-256 is not canonical lowercase hexadecimal")
canonical = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True) + "\n"
if text != canonical:
    raise SystemExit("performance attestation JSON is not canonical sorted compact JSON")
PY
}

run_performance_attester() {
  freeze_regular_file \
    PERFORMANCE_ATTESTER_SNAPSHOT \
    "$PERFORMANCE_ATTESTER_CANONICAL" \
    "performance attester executable"
  PERFORMANCE_ATTESTER_SHA256="$(snapshot_sha256 "$PERFORMANCE_ATTESTER_SNAPSHOT")"
  if ! run_isolated_performance_attester \
    "$PERFORMANCE_ATTESTER_CANONICAL" \
    "$PERFORMANCE_ATTESTER_SNAPSHOT" \
    "$STAGED_ARTIFACT" \
    "$STAGED_ARTIFACT_SNAPSHOT" \
    "$PERFORMANCE_ATTESTER_SCRATCH" \
    "$STAGED_PERFORMANCE_ATTESTATION" \
    "$PERFORMANCE_ATTESTER_TIMEOUT_SECONDS" \
    --attester-sha256 "$PERFORMANCE_ATTESTER_SHA256" \
    --artifact "$ARTIFACT_DESCRIPTOR_TOKEN" \
    --artifact-file-name "$(basename "$ARTIFACT")" \
    --artifact-sha256 "$ARTIFACT_SHA256" \
    --bundle-identifier "$APP_BUNDLE_ID" \
    --version "$APP_VERSION" \
    --build "$APP_BUILD_NUMBER" \
    --signing-leaf-sha256 "$RELEASE_SIGNING_LEAF_SHA256" \
    --team-identifier "$RELEASE_TEAM_ID" \
    --notarization-status "$NOTARY_STATUS" \
    --notarization-submission-id "$NOTARY_SUBMISSION_ID"; then
    fail "Performance attester rejected the staged notarized release artifact."
  fi

  freeze_regular_file \
    STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT \
    "$STAGED_PERFORMANCE_ATTESTATION" \
    "staged performance attestation"
  PERFORMANCE_ATTESTATION_SHA256="$(snapshot_sha256 "$STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT")"
  validate_performance_attestation "$STAGED_PERFORMANCE_ATTESTATION" \
    || fail "Performance attester returned invalid or mismatched canonical evidence."
  verify_regular_file_snapshot \
    "$STAGED_PERFORMANCE_ATTESTATION" "$STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT" exact \
    "Staged performance attestation"
  verify_regular_file_snapshot \
    "$STAGED_ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" exact \
    "Staged app artifact"
  verify_regular_file_snapshot \
    "$PERFORMANCE_ATTESTER_CANONICAL" "$PERFORMANCE_ATTESTER_SNAPSHOT" exact \
    "Performance attester executable"
  PERFORMANCE_ATTESTATION_RESULT="passed"
}

verify_staged_release_evidence_hashes() {
  verify_regular_file_snapshot \
    "$STAGED_SOURCE_ARTIFACT" "$STAGED_SOURCE_ARTIFACT_SNAPSHOT" exact \
    "Staged source archive"
  verify_regular_file_snapshot \
    "$STAGED_ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" exact \
    "Staged app artifact"
  verify_regular_file_snapshot \
    "$STAGED_PERFORMANCE_ATTESTATION" "$STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT" exact \
    "Staged performance attestation"
  verify_regular_file_snapshot \
    "$PERFORMANCE_ATTESTER_CANONICAL" "$PERFORMANCE_ATTESTER_SNAPSHOT" exact \
    "Performance attester executable"

  if [[ -n "$STAGED_CHECKSUM_FILE_SNAPSHOT" ]]; then
    verify_regular_file_snapshot \
      "$STAGED_CHECKSUM_FILE" "$STAGED_CHECKSUM_FILE_SNAPSHOT" exact \
      "Staged checksum file"
  fi
  if [[ -n "$STAGED_MANIFEST_SNAPSHOT" ]]; then
    verify_regular_file_snapshot \
      "$STAGED_MANIFEST" "$STAGED_MANIFEST_SNAPSHOT" exact \
      "Staged release manifest"
  fi
}

verify_published_release_evidence() {
  verify_release_evidence_set \
    "$ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" moved "Published app artifact" \
    "$SOURCE_ARTIFACT" "$STAGED_SOURCE_ARTIFACT_SNAPSHOT" moved "Published source archive" \
    "$CHECKSUM_FILE" "$STAGED_CHECKSUM_FILE_SNAPSHOT" moved "Published checksum file" \
    "$MANIFEST" "$STAGED_MANIFEST_SNAPSHOT" moved "Published release manifest" \
    "$PERFORMANCE_ATTESTATION" "$STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT" moved "Published performance attestation" \
    "$PERFORMANCE_ATTESTER_CANONICAL" "$PERFORMANCE_ATTESTER_SNAPSHOT" exact "Performance attester executable" \
    || fail "Published release evidence changed during final all-files verification."
}

write_canonical_manifest() {
  assert_json_safe "artifact name" "$(basename "$ARTIFACT")"
  assert_json_safe "source artifact name" "$(basename "$SOURCE_ARTIFACT")"
  assert_json_safe "Swift version" "$SWIFT_VERSION"
  assert_json_safe "Xcode version" "$XCODE_VERSION"
  assert_json_safe "performance attestation name" "$(basename "$PERFORMANCE_ATTESTATION")"

  /bin/cat >"$STAGED_MANIFEST" <<JSON
{
  "artifact": "$(basename "$ARTIFACT")",
  "artifactSha256": "$ARTIFACT_SHA256",
  "build": "$APP_BUILD_NUMBER",
  "bundleIdentifier": "$APP_BUNDLE_ID",
  "commit": "$RELEASE_COMMIT",
  "inputs": {
    "creditsSha256": "$CREDITS_SHA256",
    "iconSha256": "$ICON_SHA256",
    "licenseSha256": "$LICENSE_SHA256",
    "privacySha256": "$PRIVACY_SHA256"
  },
  "minimumOS": "$APP_MINIMUM_SYSTEM_VERSION",
  "notarization": {
    "status": "$NOTARY_STATUS",
    "submissionId": "$NOTARY_SUBMISSION_ID"
  },
  "performance": {
    "attestation": "$(basename "$PERFORMANCE_ATTESTATION")",
    "attestationSha256": "$PERFORMANCE_ATTESTATION_SHA256",
    "attesterSha256": "$PERFORMANCE_ATTESTER_SHA256",
    "result": "$PERFORMANCE_ATTESTATION_RESULT",
    "schemaVersion": 1
  },
  "releaseTag": "$RELEASE_TAG",
  "sdk": {
    "version": "$SDK_VERSION"
  },
  "signing": {
    "leafSha256": "$RELEASE_SIGNING_LEAF_SHA256",
    "teamIdentifier": "$RELEASE_TEAM_ID",
    "type": "Developer ID Application"
  },
  "sourceArtifact": "$(basename "$SOURCE_ARTIFACT")",
  "sourceSha256": "$SOURCE_SHA256",
  "swift": "$SWIFT_VERSION",
  "version": "$APP_VERSION",
  "xcode": "$XCODE_VERSION"
}
JSON
  /usr/bin/plutil -lint "$STAGED_MANIFEST" >/dev/null
}

assert_json_safe() {
  local label="$1"
  local value="$2"

  if [[ "$value" == *\"* || "$value" == *\\* || "$value" == *$'\n'* || "$value" == *$'\r'* || "$value" == *$'\t'* ]]; then
    fail "$label cannot be represented safely in the canonical release manifest."
  fi
}

if [[ "${TRANSMISSION_REMOTE_MAC_RELEASE_CONTRACT_LIBRARY:-0}" == 1 ]]; then
  [[ "${BASH_SOURCE[0]}" != "$0" ]] || fail \
    "Release contract library mode may only be used while sourcing release.sh."
  return 0
fi

for tool in /usr/bin/git /usr/bin/codesign /usr/bin/security /usr/bin/xattr /usr/bin/ditto \
  /usr/bin/plutil /usr/bin/find /usr/bin/cmp /usr/bin/mktemp \
  /usr/bin/python3 /usr/libexec/PlistBuddy /usr/sbin/spctl \
  "$XCRUN_BIN" "$SWIFT_BIN" "$XCODEBUILD_BIN"; do
  require_executable "$tool"
done

safe_clean_work_dir
trap clean_release_state EXIT

[[ -n "$DEVELOPER_ID_APPLICATION" ]] || fail \
  "Configure transmissionRemoteMac.releaseCodesignIdentity or DEVELOPER_ID_APPLICATION."
[[ "$DEVELOPER_ID_APPLICATION" == "Developer ID Application:"* ]] || fail \
  "Distribution requires a Developer ID Application identity. Apple Development and ad-hoc signing are forbidden."
[[ -n "$RELEASE_TEAM_ID" ]] || fail \
  "Configure transmissionRemoteMac.releaseTeamIdentifier or RELEASE_TEAM_ID."
[[ "$RELEASE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "RELEASE_TEAM_ID must be a 10-character Team ID."
[[ -n "$NOTARYTOOL_PROFILE" ]] || fail \
  "Configure transmissionRemoteMac.notarytoolProfile or NOTARYTOOL_PROFILE."
[[ -f "$APP_ICON_PATH" ]] || fail \
  "Release icon is missing: Resources/AppIcon.icns. Distribution will not borrow legacy artwork."
resolve_performance_attester

assert_release_checkout
RELEASE_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
assert_output_paths_available
RELEASE_CERT_SHA1="$(resolve_codesigning_identity_sha1 "$DEVELOPER_ID_APPLICATION")"

SWIFT_VERSION="$("$SWIFT_BIN" --version | /usr/bin/head -n 1)"
XCODE_VERSION="$("$XCODEBUILD_BIN" -version | /usr/bin/paste -sd ' ' -)"
SDK_VERSION="$("$XCRUN_BIN" --sdk macosx --show-sdk-version)"
LICENSE_SHA256="$(sha256_file "$ROOT_DIR/LICENSE")"
CREDITS_SHA256="$(sha256_file "$ROOT_DIR/CREDITS.md")"
PRIVACY_SHA256="$(sha256_file "$ROOT_DIR/PRIVACY.md")"
ICON_SHA256="$(sha256_file "$APP_ICON_PATH")"

assert_release_checkout
/usr/bin/git -C "$ROOT_DIR" archive \
  --format=tar.gz \
  --prefix="$SOURCE_BASENAME/" \
  --output="$STAGED_SOURCE_ARTIFACT" \
  "$RELEASE_TAG"
freeze_regular_file \
  STAGED_SOURCE_ARTIFACT_SNAPSHOT \
  "$STAGED_SOURCE_ARTIFACT" \
  "staged source archive"
SOURCE_SHA256="$(snapshot_sha256 "$STAGED_SOURCE_ARTIFACT_SNAPSHOT")"

cd "$ROOT_DIR"
"$SWIFT_BIN" build -c release --scratch-path "$SWIFT_BUILD_DIR"
BUILD_BINARY="$(
  "$SWIFT_BIN" build -c release --scratch-path "$SWIFT_BUILD_DIR" --show-bin-path
)/$APP_EXECUTABLE_NAME"
assert_release_checkout
assemble_app_bundle "$ROOT_DIR" "$BUILD_BINARY" "$APP_BUNDLE"
sanitize_and_verify_unsigned_bundle_xattrs "$APP_BUNDLE"

/usr/bin/codesign --force \
  --sign "$RELEASE_CERT_SHA1" \
  --identifier "$APP_BUNDLE_ID" \
  --options runtime \
  --timestamp \
  "$APP_BUNDLE"
verify_distribution_signature "$APP_BUNDLE" "$WORK_DIR/signature-verification"

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$SUBMISSION_ARCHIVE"
"$XCRUN_BIN" notarytool submit "$SUBMISSION_ARCHIVE" \
  --keychain-profile "$NOTARYTOOL_PROFILE" \
  --wait \
  --output-format json >"$NOTARY_RESULT_JSON"
NOTARY_STATUS="$(/usr/bin/plutil -extract status raw -o - "$NOTARY_RESULT_JSON")"
NOTARY_SUBMISSION_ID="$(/usr/bin/plutil -extract id raw -o - "$NOTARY_RESULT_JSON")"
[[ "$NOTARY_STATUS" == "Accepted" ]] || fail "Notarization was not accepted: $NOTARY_STATUS"
[[ "$NOTARY_SUBMISSION_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || \
  fail "Notarization returned an invalid submission ID."

"$XCRUN_BIN" stapler staple "$APP_BUNDLE"
"$XCRUN_BIN" stapler validate "$APP_BUNDLE"
verify_distribution_signature "$APP_BUNDLE" "$WORK_DIR/stapled-signature-verification"
/usr/sbin/spctl --assess --type execute --verbose=4 "$APP_BUNDLE"
assert_release_checkout

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$STAGED_ARTIFACT"
freeze_regular_file \
  STAGED_ARTIFACT_SNAPSHOT \
  "$STAGED_ARTIFACT" \
  "staged app artifact"
ARTIFACT_SHA256="$(snapshot_sha256 "$STAGED_ARTIFACT_SNAPSHOT")"
validate_final_artifact
verify_regular_file_snapshot \
  "$STAGED_ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" exact \
  "Staged app artifact"
run_performance_attester
assert_release_checkout
verify_staged_release_evidence_hashes
/usr/bin/printf '%s  %s\n%s  %s\n%s  %s\n' \
  "$ARTIFACT_SHA256" "$(basename "$ARTIFACT")" \
  "$SOURCE_SHA256" "$(basename "$SOURCE_ARTIFACT")" \
  "$PERFORMANCE_ATTESTATION_SHA256" "$(basename "$PERFORMANCE_ATTESTATION")" \
  >"$STAGED_CHECKSUM_FILE"
freeze_regular_file \
  STAGED_CHECKSUM_FILE_SNAPSHOT \
  "$STAGED_CHECKSUM_FILE" \
  "staged checksum file"
verify_staged_release_evidence_hashes
write_canonical_manifest
freeze_regular_file \
  STAGED_MANIFEST_SNAPSHOT \
  "$STAGED_MANIFEST" \
  "staged release manifest"
assert_release_checkout
assert_output_paths_available
verify_staged_release_evidence_hashes

publish_release_output \
  "$STAGED_ARTIFACT" "$ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" PUBLISHED_ARTIFACT
publish_release_output \
  "$STAGED_SOURCE_ARTIFACT" "$SOURCE_ARTIFACT" \
  "$STAGED_SOURCE_ARTIFACT_SNAPSHOT" PUBLISHED_SOURCE_ARTIFACT
publish_release_output \
  "$STAGED_CHECKSUM_FILE" "$CHECKSUM_FILE" \
  "$STAGED_CHECKSUM_FILE_SNAPSHOT" PUBLISHED_CHECKSUM
publish_release_output \
  "$STAGED_MANIFEST" "$MANIFEST" "$STAGED_MANIFEST_SNAPSHOT" PUBLISHED_MANIFEST
publish_release_output \
  "$STAGED_PERFORMANCE_ATTESTATION" \
  "$PERFORMANCE_ATTESTATION" \
  "$STAGED_PERFORMANCE_ATTESTATION_SNAPSHOT" \
  PUBLISHED_PERFORMANCE_ATTESTATION

verify_published_release_evidence
RELEASE_COMPLETE=1
/usr/bin/printf 'Release ready:\n  %s\n  %s\n  %s\n  %s\n  %s\n' \
  "$ARTIFACT" \
  "$SOURCE_ARTIFACT" \
  "$CHECKSUM_FILE" \
  "$MANIFEST" \
  "$PERFORMANCE_ATTESTATION"
