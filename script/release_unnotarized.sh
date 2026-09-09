#!/usr/bin/env bash
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

set -euo pipefail
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export LC_ALL=C

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UNNOTARIZED_LIBRARY_MODE="${TRANSMISSION_REMOTE_MAC_UNNOTARIZED_RELEASE_CONTRACT_LIBRARY:-0}"

if [[ "$UNNOTARIZED_LIBRARY_MODE" != 1 && "$#" != 0 ]]; then
  echo "usage: BUILD_NUMBER=<number> $0" >&2
  echo "Builds the tag matching VERSION as a self-signed, non-notarized GitHub release." >&2
  exit 2
fi
if [[ "$UNNOTARIZED_LIBRARY_MODE" == 1 && -z "${BUILD_NUMBER:-}" ]]; then
  BUILD_NUMBER=1
fi

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
if [[ "$UNNOTARIZED_LIBRARY_MODE" == 1 ]]; then
  load_app_metadata "$ROOT_DIR" development
else
  load_app_metadata "$ROOT_DIR" release
fi

RELEASE_COMPLETE=0
PUBLISHED_ARTIFACT=0
PUBLISHED_SOURCE=0
PUBLISHED_CHECKSUMS=0
PUBLISHED_MANIFEST=0

create_unnotarized_work_dir() {
  /usr/bin/python3 - "$ROOT_DIR" <<'PY'
import os
import secrets
import stat
import sys

root_path = sys.argv[1]


def open_directory(parent_descriptor, name, *, create):
    if create:
        try:
            os.mkdir(name, 0o755, dir_fd=parent_descriptor)
        except FileExistsError:
            pass
    return os.open(
        name,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=parent_descriptor,
    )


def validate_release_parent(descriptor, label):
    state = os.fstat(descriptor)
    if state.st_uid != os.geteuid() or stat.S_IMODE(state.st_mode) & 0o022:
        raise SystemExit(f"{label} must be owned by this user and not group/world writable")


canonical_root = os.path.realpath(root_path)
root_descriptor = os.open(canonical_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
try:
    dist_descriptor = open_directory(root_descriptor, "dist", create=True)
    try:
        validate_release_parent(dist_descriptor, "dist release parent")
        release_descriptor = open_directory(dist_descriptor, "github-release", create=True)
        try:
            validate_release_parent(release_descriptor, "GitHub release parent")
            for _ in range(128):
                name = f"work.{os.getpid()}.{secrets.token_hex(12)}"
                try:
                    os.mkdir(name, 0o700, dir_fd=release_descriptor)
                except FileExistsError:
                    continue
                state = os.stat(name, dir_fd=release_descriptor, follow_symlinks=False)
                if not stat.S_ISDIR(state.st_mode) or stat.S_IMODE(state.st_mode) != 0o700:
                    raise SystemExit("unique release work directory has unsafe permissions")
                path = os.path.join(canonical_root, "dist", "github-release", name)
                print(f"{path}|{state.st_dev}|{state.st_ino}")
                break
            else:
                raise SystemExit("could not allocate a unique release work directory")
        finally:
            os.close(release_descriptor)
    finally:
        os.close(dist_descriptor)
finally:
    os.close(root_descriptor)
PY
}

remove_unnotarized_work_dir() {
  local owned_work_dir="$1"
  local expected_device="$2"
  local expected_inode="$3"

  /usr/bin/python3 - \
    "$ROOT_DIR" "$owned_work_dir" "$expected_device" "$expected_inode" <<'PY'
import os
import re
import stat
import sys

root_path, owned_path, expected_device_text, expected_inode_text = sys.argv[1:]
expected_device = int(expected_device_text)
expected_inode = int(expected_inode_text)
canonical_root = os.path.realpath(root_path)
expected_parent = os.path.join(canonical_root, "dist", "github-release")
canonical_parent = os.path.dirname(owned_path)
name = os.path.basename(owned_path)
if canonical_parent != expected_parent or not re.fullmatch(r"work\.[0-9]+\.[0-9a-f]{24}", name):
    raise SystemExit(f"refusing to remove unsafe release work directory: {owned_path}")


def open_directory(parent_descriptor, entry):
    return os.open(
        entry,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=parent_descriptor,
    )


def validate_release_parent(descriptor, label):
    state = os.fstat(descriptor)
    if state.st_uid != os.geteuid() or stat.S_IMODE(state.st_mode) & 0o022:
        raise SystemExit(f"{label} must be owned by this user and not group/world writable")


def remove_directory_tree(parent_descriptor, entry, expected_identity=None):
    descriptor = open_directory(parent_descriptor, entry)
    try:
        opened = os.fstat(descriptor)
        if expected_identity is not None and (opened.st_dev, opened.st_ino) != expected_identity:
            raise SystemExit("release work directory no longer names the directory owned by this run")
        for child in os.listdir(descriptor):
            state = os.stat(child, dir_fd=descriptor, follow_symlinks=False)
            if stat.S_ISDIR(state.st_mode):
                remove_directory_tree(descriptor, child)
            else:
                os.unlink(child, dir_fd=descriptor)
    finally:
        os.close(descriptor)
    path_state = os.stat(entry, dir_fd=parent_descriptor, follow_symlinks=False)
    if expected_identity is not None and (path_state.st_dev, path_state.st_ino) != expected_identity:
        raise SystemExit("release work directory changed identity before removal")
    os.rmdir(entry, dir_fd=parent_descriptor)


root_descriptor = os.open(canonical_root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
try:
    dist_descriptor = open_directory(root_descriptor, "dist")
    try:
        validate_release_parent(dist_descriptor, "dist release parent")
        release_descriptor = open_directory(dist_descriptor, "github-release")
        try:
            validate_release_parent(release_descriptor, "GitHub release parent")
            remove_directory_tree(
                release_descriptor,
                name,
                expected_identity=(expected_device, expected_inode),
            )
        finally:
            os.close(release_descriptor)
    finally:
        os.close(dist_descriptor)
finally:
    os.close(root_descriptor)
PY
}

cleanup_unnotarized_release_state() {
  local status="${1:-1}"

  trap - EXIT INT TERM
  if [[ "$RELEASE_COMPLETE" != 1 ]]; then
    remove_owned_release_output \
      "$PUBLISHED_ARTIFACT" "$ARTIFACT" "$STAGED_ARTIFACT" "${STAGED_ARTIFACT_SNAPSHOT:-}"
    remove_owned_release_output \
      "$PUBLISHED_SOURCE" "$SOURCE_ARTIFACT" "$STAGED_SOURCE" "${STAGED_SOURCE_SNAPSHOT:-}"
    remove_owned_release_output \
      "$PUBLISHED_CHECKSUMS" "$CHECKSUM_FILE" "$STAGED_CHECKSUMS" \
      "${STAGED_CHECKSUMS_SNAPSHOT:-}"
    remove_owned_release_output \
      "$PUBLISHED_MANIFEST" "$MANIFEST" "$STAGED_MANIFEST" "${STAGED_MANIFEST_SNAPSHOT:-}"
  fi
  remove_unnotarized_work_dir "$WORK_DIR" "$WORK_DIR_DEVICE" "$WORK_DIR_INODE" || \
    echo "Refusing to remove release work directory not owned by this run: $WORK_DIR" >&2
  exit "$status"
}

install_unnotarized_release_traps() {
  trap 'cleanup_unnotarized_release_state "$?"' EXIT
  trap 'cleanup_unnotarized_release_state 130' INT
  trap 'cleanup_unnotarized_release_state 143' TERM
}

assert_unnotarized_output_paths_available() {
  local output

  for output in "$ARTIFACT" "$SOURCE_ARTIFACT" "$CHECKSUM_FILE" "$MANIFEST"; do
    [[ ! -e "$output" && ! -L "$output" ]] || \
      fail "Refusing to overwrite existing release output: $output"
  done
}

assert_arm64_architecture() {
  local executable="$1"
  local architecture

  architecture="$(/usr/bin/lipo -archs "$executable")"
  [[ "$architecture" == "arm64" ]] || \
    fail "Release executable architecture must be exactly arm64, found: $architecture"
}

validate_release_xattr_names() {
  local path="$1"
  local attributes="$2"
  local allowed_attribute="com.apple.provenance"

  [[ -z "$attributes" || "$attributes" == "$allowed_attribute" ]] || \
    fail "Release input contains unexpected extended attributes: $path ($attributes)"
}

verify_release_xattrs() {
  local path="$1"
  local item
  local attributes
  local paths_file

  [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" && ! -L "$WORK_DIR" ]] || \
    fail "Release work directory is unavailable for extended-attribute verification."
  paths_file="$(/usr/bin/mktemp "$WORK_DIR/xattr-paths.XXXXXX")" || \
    fail "Could not allocate extended-attribute enumeration evidence."
  if ! /usr/bin/find "$path" -print0 >"$paths_file"; then
    /bin/rm -f "$paths_file"
    fail "Unable to enumerate release input for extended-attribute verification: $path"
  fi

  while IFS= read -r -d '' item; do
    attributes="$(/usr/bin/xattr "$item" 2>/dev/null)" || \
      fail "Unable to inspect extended attributes for: $item"
    validate_release_xattr_names "$item" "$attributes"
  done <"$paths_file"
  /bin/rm -f "$paths_file"
}

sanitize_and_verify_generated_file_xattrs() {
  local path="$1"

  [[ -f "$path" && ! -L "$path" ]] || \
    fail "Generated release artifact is not a regular non-symlink file: $path"
  /usr/bin/xattr -c "$path" || \
    fail "Could not strip removable attributes from generated release artifact: $path"
  verify_release_xattrs "$path"
}

validate_release_certificate_file() {
  local certificate="$1"
  local certificate_pem="$2"
  local expected_common_name="$3"
  local subject
  local issuer
  local certificate_text
  local extended_key_usage
  local key_usage

  /usr/bin/openssl x509 -inform DER -in "$certificate" -out "$certificate_pem"
  /usr/bin/python3 - "$certificate_pem" "$expected_common_name" <<'PY'
import ssl
import sys
import time

certificate_path, expected_common_name = sys.argv[1:]
certificate = ssl._ssl._test_decode_cert(certificate_path)
pairs = [
    (key, value)
    for relative_distinguished_name in certificate.get("subject", ())
    for key, value in relative_distinguished_name
]
if pairs != [("commonName", expected_common_name)]:
    raise SystemExit(
        "tracked release certificate subject must contain only "
        f"commonName={expected_common_name}"
    )
if certificate.get("subjectAltName"):
    raise SystemExit("tracked release certificate must not contain subjectAltName")
now = time.time()
not_before = ssl.cert_time_to_seconds(certificate["notBefore"])
not_after = ssl.cert_time_to_seconds(certificate["notAfter"])
if now < not_before:
    raise SystemExit("tracked release certificate is not yet valid")
if now >= not_after:
    raise SystemExit("tracked release certificate is expired")
minimum_remaining_seconds = 730 * 24 * 60 * 60
if not_after - now < minimum_remaining_seconds:
    raise SystemExit("tracked release certificate must remain valid for at least 730 days")
PY
  subject="$(/usr/bin/openssl x509 -in "$certificate_pem" -noout -subject -nameopt RFC2253)"
  issuer="$(/usr/bin/openssl x509 -in "$certificate_pem" -noout -issuer -nameopt RFC2253)"
  [[ "${subject#subject=}" == "${issuer#issuer=}" ]] || \
    fail "Tracked release certificate must be self-signed."
  certificate_text="$(/usr/bin/openssl x509 -in "$certificate_pem" -noout -text)"
  /usr/bin/python3 - "$certificate_text" <<'PY'
import sys

certificate_text = sys.argv[1]
lines = certificate_text.splitlines()
marker_index = next(
    (index for index, line in enumerate(lines) if line.strip() == "X509v3 extensions:"),
    None,
)
if marker_index is None:
    raise SystemExit("tracked release certificate has no X509v3 extension block")
marker = lines[marker_index]
marker_indent = len(marker) - len(marker.lstrip())
extension_names = []
extension_values = {}
current_extension = None
for line in lines[marker_index + 1:]:
    if line.strip() and len(line) - len(line.lstrip()) <= marker_indent:
        break
    indentation = len(line) - len(line.lstrip())
    if indentation == marker_indent + 4:
        header = line.strip()
        if header.endswith(": critical"):
            name = header[:-len(": critical")]
        elif header.endswith(":"):
            name = header[:-1]
        else:
            raise SystemExit(f"could not parse certificate extension header: {header}")
        extension_names.append(name)
        extension_values[name] = []
        current_extension = name
    elif current_extension is not None and line.strip():
        extension_values[current_extension].append(line.strip())

allowed_extensions = {
    "X509v3 Authority Key Identifier",
    "X509v3 Basic Constraints",
    "X509v3 Extended Key Usage",
    "X509v3 Key Usage",
    "X509v3 Subject Key Identifier",
}
unknown_extensions = sorted(set(extension_names) - allowed_extensions)
if unknown_extensions:
    raise SystemExit(
        "tracked release certificate contains unsupported extensions: "
        + ", ".join(unknown_extensions)
    )
if len(extension_names) != len(set(extension_names)):
    raise SystemExit("tracked release certificate contains duplicate extensions")
required_extensions = {
    "X509v3 Basic Constraints",
    "X509v3 Extended Key Usage",
    "X509v3 Key Usage",
}
missing_extensions = sorted(required_extensions - set(extension_names))
if missing_extensions:
    raise SystemExit(
        "tracked release certificate is missing required extensions: "
        + ", ".join(missing_extensions)
    )
basic_constraints = " ".join(extension_values["X509v3 Basic Constraints"])
if "CA:TRUE" not in basic_constraints:
    raise SystemExit("tracked release certificate Basic Constraints must require CA:TRUE")
PY
  [[ "$certificate_text" != *"X509v3 Subject Alternative Name:"* ]] || \
    fail "Tracked release certificate must not contain a subject-alternative-name extension."
  extended_key_usage="$(
    printf '%s\n' "$certificate_text" | \
      /usr/bin/awk '/X509v3 Extended Key Usage:/{getline; print; exit}'
  )"
  [[ "$extended_key_usage" == *"Code Signing"* ]] || \
    fail "Tracked release certificate must declare the code-signing extended key usage."
  key_usage="$(
    printf '%s\n' "$certificate_text" | \
      /usr/bin/awk '/X509v3 Key Usage:/{getline; print; exit}'
  )"
  [[ "$key_usage" == *"Digital Signature"* ]] || \
    fail "Tracked release certificate must permit digital signatures."
  /usr/bin/security verify-cert \
    -c "$certificate" -r "$certificate" -p basic -N -L -l -q || \
    fail "Tracked release certificate did not verify against its own self-signed root."
}

validate_tracked_release_certificate() {
  local certificate_pem="$WORK_DIR/release-signing-certificate.pem"
  local tagged_blob
  local working_blob

  [[ -f "$RELEASE_CERTIFICATE" && ! -L "$RELEASE_CERTIFICATE" ]] || \
    fail "Tracked release certificate is missing or is not a regular file: $RELEASE_CERTIFICATE"
  freeze_regular_file \
    RELEASE_CERTIFICATE_SNAPSHOT "$RELEASE_CERTIFICATE" "tracked release certificate"
  /usr/bin/git -C "$ROOT_DIR" ls-files --error-unmatch "$RELEASE_CERTIFICATE_RELATIVE" \
    >/dev/null 2>&1 || fail "Release certificate must be tracked by Git."
  tagged_blob="$(/usr/bin/git -C "$ROOT_DIR" rev-parse "$RELEASE_TAG:$RELEASE_CERTIFICATE_RELATIVE")"
  working_blob="$(/usr/bin/git -C "$ROOT_DIR" hash-object "$RELEASE_CERTIFICATE")"
  [[ "$working_blob" == "$tagged_blob" ]] || \
    fail "Release certificate does not match the certificate in $RELEASE_TAG."
  validate_release_certificate_file \
    "$RELEASE_CERTIFICATE" "$certificate_pem" "$UNNOTARIZED_CODESIGN_IDENTITY"

  PINNED_CERT_SHA1="$(/usr/bin/shasum -a 1 "$RELEASE_CERTIFICATE" | /usr/bin/awk '{print toupper($1)}')"
  PINNED_CERT_SHA256="$(snapshot_sha256 "$RELEASE_CERTIFICATE_SNAPSHOT")"
  verify_regular_file_snapshot \
    "$RELEASE_CERTIFICATE" "$RELEASE_CERTIFICATE_SNAPSHOT" exact \
    "Tracked release certificate"
}

verify_unnotarized_signature() {
  local bundle="$1"
  local certificate_dir="$2"
  local signature_details
  local designated_requirement

  /usr/bin/codesign --verify --deep --strict --verbose=2 "$bundle"
  signature_details="$(/usr/bin/codesign -dvvv "$bundle" 2>&1)"
  [[ "$signature_details" == *"Identifier=$APP_BUNDLE_ID"* ]] || \
    fail "Unnotarized app code identifier is not exactly $APP_BUNDLE_ID."
  [[ "$signature_details" == *"Authority=$UNNOTARIZED_CODESIGN_IDENTITY"* ]] || \
    fail "Release app is not signed by the pinned project-owned identity."
  [[ "$signature_details" != *"Signature=adhoc"* ]] || \
    fail "Release app unexpectedly uses a plain ad-hoc signature."
  [[ "$signature_details" == *"TeamIdentifier=not set"* ]] || \
    fail "Unnotarized release unexpectedly contains an Apple Team ID."
  [[ "$signature_details" == *"runtime"* ]] || \
    fail "Unnotarized release signature is missing the hardened runtime flag."

  extract_signed_leaf_fingerprints "$bundle" "$certificate_dir"
  [[ "$SIGNED_LEAF_SHA1" == "$PINNED_CERT_SHA1" ]] || \
    fail "Release app leaf certificate does not match the tracked certificate SHA-1."
  [[ "$SIGNED_LEAF_SHA256" == "$PINNED_CERT_SHA256" ]] || \
    fail "Release app leaf certificate does not match the tracked certificate SHA-256."
  [[ ! -e "$certificate_dir/codesign1" && ! -L "$certificate_dir/codesign1" ]] || \
    fail "Release signature must contain one self-signed certificate, not a chain."

  designated_requirement="$(/usr/bin/codesign -d -r- "$bundle" 2>&1)"
  validate_designated_requirement "$designated_requirement"
  RELEASE_SIGNING_LEAF_SHA256="$SIGNED_LEAF_SHA256"
  /bin/rm -rf "$certificate_dir"
}

validate_designated_requirement() {
  local designated_requirement="$1"
  local normalized_requirement
  local normalized_sha1

  [[ "$designated_requirement" == *"identifier \"$APP_BUNDLE_ID\""* ]] || \
    fail "Release designated requirement does not contain the exact bundle identifier."
  [[ "$designated_requirement" != *"cdhash"* ]] || \
    fail "Release designated requirement is cdhash-only and would change between builds."

  normalized_requirement="$(printf '%s' "$designated_requirement" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  normalized_sha1="$(printf '%s' "$PINNED_CERT_SHA1" | /usr/bin/tr '[:upper:]' '[:lower:]')"
  [[ "$normalized_requirement" == *"anchor = h\"$normalized_sha1\""* \
     || "$normalized_requirement" == *"certificate root = h\"$normalized_sha1\""* ]] || \
    fail "Release designated requirement is not anchored to the exact tracked certificate."
}

verify_bundle_metadata() {
  local bundle="$1"
  local info_plist="$bundle/Contents/Info.plist"

  /usr/bin/plutil -lint "$info_plist" >/dev/null
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "$APP_BUNDLE_ID" ]] || \
    fail "App bundle identifier is incorrect."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")" == "$APP_VERSION" ]] || \
    fail "App semantic version is incorrect."
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")" == "$APP_BUILD_NUMBER" ]] || \
    fail "App build number is incorrect."
  [[ -x "$bundle/Contents/MacOS/$APP_EXECUTABLE_NAME" ]] || \
    fail "App executable is missing or is not executable."
  assert_arm64_architecture "$bundle/Contents/MacOS/$APP_EXECUTABLE_NAME"
  verify_unnotarized_signature "$bundle" "$WORK_DIR/signature-verification"
}

validate_expected_bundle_members() {
  local bundle="$1"

  /usr/bin/python3 - "$bundle" "$APP_EXECUTABLE_NAME" <<'PY'
import os
import stat
import sys

bundle, executable_name = sys.argv[1:]
expected = {
    "Contents/Info.plist",
    f"Contents/MacOS/{executable_name}",
    "Contents/Resources/AppIcon.icns",
    "Contents/Resources/CREDITS.md",
    "Contents/Resources/LICENSE",
    "Contents/Resources/PRIVACY.md",
    "Contents/_CodeSignature/CodeResources",
}
expected_directories = {
    "Contents",
    "Contents/MacOS",
    "Contents/Resources",
    "Contents/_CodeSignature",
}
actual = set()
actual_directories = set()
for root, directories, files in os.walk(bundle, followlinks=False):
    for name in directories + files:
        path = os.path.join(root, name)
        if stat.S_ISLNK(os.lstat(path).st_mode):
            raise SystemExit(f"release app contains an unexpected symlink: {path}")
    for name in files:
        actual.add(os.path.relpath(os.path.join(root, name), bundle))
    for name in directories:
        actual_directories.add(os.path.relpath(os.path.join(root, name), bundle))
if actual != expected:
    missing = sorted(expected - actual)
    unexpected = sorted(actual - expected)
    raise SystemExit(f"release app member mismatch; missing={missing}, unexpected={unexpected}")
if actual_directories != expected_directories:
    missing = sorted(expected_directories - actual_directories)
    unexpected = sorted(actual_directories - expected_directories)
    raise SystemExit(
        f"release app directory mismatch; missing={missing}, unexpected={unexpected}"
    )
PY
}

validate_zip_members() {
  /usr/bin/python3 - "$STAGED_ARTIFACT" "$APP_EXECUTABLE_NAME.app" <<'PY'
import pathlib
import stat
import sys
import unicodedata
import zipfile

archive_path, expected_root = sys.argv[1:]
seen = set()
with zipfile.ZipFile(archive_path) as archive:
    for member in archive.infolist():
        raw_name = member.filename
        is_directory = raw_name.endswith("/")
        name = raw_name[:-1] if is_directory else raw_name
        if not name or "\\" in name:
            raise SystemExit(f"unsafe ZIP member: {member.filename}")
        components = name.split("/")
        if any(component in ("", ".", "..") for component in components):
            raise SystemExit(f"non-canonical ZIP member: {member.filename}")
        path = pathlib.PurePosixPath(name)
        if path.is_absolute() or str(path) != name:
            raise SystemExit(f"non-canonical ZIP member: {member.filename}")
        if path.parts[0] != expected_root:
            raise SystemExit(f"unexpected ZIP root member: {member.filename}")
        canonical_name = unicodedata.normalize("NFC", name).casefold()
        if canonical_name in seen:
            raise SystemExit(f"canonical duplicate ZIP member: {member.filename}")
        seen.add(canonical_name)
        mode = member.external_attr >> 16
        if is_directory:
            if not stat.S_ISDIR(mode):
                raise SystemExit(f"ZIP directory member has an invalid mode: {member.filename}")
        elif not stat.S_ISREG(mode):
            raise SystemExit(f"ZIP contains a non-regular special member: {member.filename}")
PY
}

validate_gatekeeper_rejection() {
  local bundle="$1"
  local assessment_plist="$WORK_DIR/gatekeeper-assessment.plist"
  local assessment_stderr="$WORK_DIR/gatekeeper-assessment.stderr"
  local assessment_status

  /bin/rm -f "$assessment_plist" "$assessment_stderr"
  if /usr/sbin/spctl --assess --type execute --raw "$bundle" \
    >"$assessment_plist" 2>"$assessment_stderr"; then
    assessment_status=0
  else
    assessment_status=$?
  fi
  [[ "$assessment_status" != 0 ]] || \
    fail "Gatekeeper unexpectedly accepted a self-signed, non-notarized release."
  /usr/bin/plutil -lint "$assessment_plist" >/dev/null || \
    fail "Gatekeeper did not return a valid raw assessment property list."
  /usr/bin/python3 - "$assessment_plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    assessment = plistlib.load(handle)
if assessment.get("assessment:verdict") is not False:
    raise SystemExit("Gatekeeper raw assessment verdict was not false")
PY
  GATEKEEPER_EXIT_STATUS="$assessment_status"
  GATEKEEPER_ASSESSMENT="false (spctl exit $assessment_status)"
}

validate_final_artifact() {
  local extracted_app="$VALIDATION_DIR/$APP_EXECUTABLE_NAME.app"
  local extracted_entry=""
  local extracted_count=0
  local entry

  verify_regular_file_snapshot \
    "$STAGED_ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" exact "Staged app artifact"
  verify_release_xattrs "$STAGED_ARTIFACT"
  validate_zip_members
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

  validate_expected_bundle_members "$extracted_app"
  verify_release_xattrs "$extracted_app"
  verify_bundle_metadata "$extracted_app"
  [[ "$(sha256_file "$extracted_app/Contents/Resources/LICENSE")" == "$LICENSE_SHA256" ]] || \
    fail "Packaged LICENSE does not match the tagged source."
  [[ "$(sha256_file "$extracted_app/Contents/Resources/CREDITS.md")" == "$CREDITS_SHA256" ]] || \
    fail "Packaged CREDITS.md does not match the tagged source."
  [[ "$(sha256_file "$extracted_app/Contents/Resources/PRIVACY.md")" == "$PRIVACY_SHA256" ]] || \
    fail "Packaged PRIVACY.md does not match the tagged source."
  [[ "$(sha256_file "$extracted_app/Contents/Resources/AppIcon.icns")" == "$ICON_SHA256" ]] || \
    fail "Packaged application icon does not match the tagged source."
  validate_gatekeeper_rejection "$extracted_app"
  verify_release_xattrs "$extracted_app"
  verify_regular_file_snapshot \
    "$STAGED_ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" exact "Staged app artifact"
}

validate_strict_json_file() {
  local path="$1"

  /usr/bin/python3 - "$path" <<'PY'
import json
import sys


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key}")
        result[key] = value
    return result


def reject_nonstandard_constant(value):
    raise ValueError(f"non-standard JSON constant: {value}")


try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        document = json.load(
            handle,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_nonstandard_constant,
        )
except (OSError, UnicodeError, ValueError) as error:
    raise SystemExit(f"invalid strict JSON: {error}")
if not isinstance(document, dict):
    raise SystemExit("strict JSON document must contain a top-level object")
PY
}

write_manifest() {
  /usr/bin/python3 - \
    "$STAGED_MANIFEST" \
    "$(basename "$ARTIFACT")" \
    "$ARTIFACT_SHA256" \
    "$(basename "$SOURCE_ARTIFACT")" \
    "$SOURCE_SHA256" \
    "$(basename "$CHECKSUM_FILE")" \
    "$(basename "$MANIFEST")" \
    "$APP_VERSION" \
    "$APP_BUILD_NUMBER" \
    "$APP_BUNDLE_ID" \
    "$APP_MINIMUM_SYSTEM_VERSION" \
    "$RELEASE_TAG" \
    "$RELEASE_COMMIT" \
    "$RELEASE_CERTIFICATE_RELATIVE" \
    "$PINNED_CERT_SHA1" \
    "$PINNED_CERT_SHA256" \
    "$GATEKEEPER_EXIT_STATUS" \
    "$SWIFT_VERSION" \
    "$XCODE_VERSION" \
    "$MACOS_VERSION" \
    "$MACOS_BUILD" <<'PY'
import json
import sys

(
    output,
    artifact,
    artifact_sha256,
    source_artifact,
    source_sha256,
    checksums,
    manifest_file,
    version,
    build,
    bundle_identifier,
    minimum_os,
    release_tag,
    commit,
    certificate_file,
    certificate_sha1,
    certificate_sha256,
    gatekeeper_exit_status,
    swift_version,
    xcode_version,
    macos_version,
    macos_build,
) = sys.argv[1:]

manifest = {
    "architecture": "arm64",
    "artifact": {"file": artifact, "sha256": artifact_sha256},
    "build": build,
    "bundleIdentifier": bundle_identifier,
    "checksums": {
        "algorithm": "SHA-256",
        "covers": [artifact, source_artifact, manifest_file],
        "file": checksums,
    },
    "commit": commit,
    "buildEnvironment": {
        "macOSBuild": macos_build,
        "macOSVersion": macos_version,
        "swift": swift_version,
        "xcode": xcode_version,
    },
    "gatekeeper": {
        "assessmentType": "execute",
        "manualUserApprovalRequired": True,
        "rawVerdict": False,
        "spctlExitStatus": int(gatekeeper_exit_status),
    },
    "minimumOS": minimum_os,
    "notarization": {"status": "not-submitted"},
    "performance": {"exactArtifactStatus": "not-attested"},
    "releaseTag": release_tag,
    "reproducibility": {"status": "not-claimed"},
    "schemaVersion": 1,
    "signing": {
        "appleTrust": False,
        "certificateAuthority": "self-signed",
        "certificateFile": certificate_file,
        "certificateSha1": certificate_sha1,
        "certificateSha256": certificate_sha256,
        "commonName": "Transmission Remote Mac Release",
        "designatedRequirement": "certificate-anchored",
        "hardenedRuntime": True,
        "keychainACLContinuity": "unverified",
        "leafSha256": certificate_sha256,
        "teamIdentifier": None,
        "type": "project-self-signed",
    },
    "sourceArtifact": {"file": source_artifact, "sha256": source_sha256},
    "version": version,
}

with open(output, "x", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
  validate_strict_json_file "$STAGED_MANIFEST"
}

verify_staged_release_evidence() {
  verify_release_evidence_set \
    "$STAGED_ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" exact "Staged app artifact" \
    "$STAGED_SOURCE" "$STAGED_SOURCE_SNAPSHOT" exact "Staged source archive" \
    "$STAGED_MANIFEST" "$STAGED_MANIFEST_SNAPSHOT" exact "Staged release manifest" \
    "$STAGED_CHECKSUMS" "$STAGED_CHECKSUMS_SNAPSHOT" exact "Staged checksum file" \
    "$RELEASE_CERTIFICATE" "$RELEASE_CERTIFICATE_SNAPSHOT" exact \
    "Tracked release certificate" \
    || fail "Staged release evidence changed during final all-files verification."
}

verify_published_release_evidence() {
  verify_release_evidence_set \
    "$ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" moved "Published app artifact" \
    "$SOURCE_ARTIFACT" "$STAGED_SOURCE_SNAPSHOT" moved "Published source archive" \
    "$MANIFEST" "$STAGED_MANIFEST_SNAPSHOT" moved "Published release manifest" \
    "$CHECKSUM_FILE" "$STAGED_CHECKSUMS_SNAPSHOT" moved "Published checksum file" \
    "$RELEASE_CERTIFICATE" "$RELEASE_CERTIFICATE_SNAPSHOT" exact \
    "Tracked release certificate" \
    || fail "Published release evidence changed during final all-files verification."
}

if [[ "$UNNOTARIZED_LIBRARY_MODE" == 1 ]]; then
  [[ "${BASH_SOURCE[0]}" != "$0" ]] || \
    fail "Unnotarized release contract library mode may only be used while sourcing the script."
  return 0
fi

for tool in /usr/bin/awk /usr/bin/codesign /usr/bin/ditto /usr/bin/find /usr/bin/git \
  /usr/bin/head /usr/bin/lipo /usr/bin/mktemp /usr/bin/openssl /usr/bin/paste /usr/bin/plutil \
  /usr/bin/python3 /usr/bin/security /usr/bin/shasum /usr/bin/sw_vers /usr/bin/tr \
  /usr/bin/uname /usr/bin/xattr /usr/bin/xcrun \
  /usr/libexec/PlistBuddy /usr/sbin/spctl; do
  require_executable "$tool"
done
[[ "$(/usr/bin/uname -m)" == "arm64" ]] || \
  fail "Unnotarized GitHub releases must be built on an arm64 host."

UNNOTARIZED_CODESIGN_IDENTITY="Transmission Remote Mac Release"
RELEASE_CERTIFICATE_RELATIVE="Resources/ReleaseSigningCertificate.cer"
RELEASE_CERTIFICATE="$ROOT_DIR/$RELEASE_CERTIFICATE_RELATIVE"
RELEASE_TAG="v$APP_VERSION"
RELEASE_ROOT="$ROOT_DIR/dist/github-release"
ARTIFACT_BASENAME="$APP_EXECUTABLE_NAME-$APP_VERSION+$APP_BUILD_NUMBER-macOS-arm64-self-signed"
SOURCE_BASENAME="$APP_EXECUTABLE_NAME-$APP_VERSION+$APP_BUILD_NUMBER-source"
ARTIFACT="$RELEASE_ROOT/$ARTIFACT_BASENAME.zip"
SOURCE_ARTIFACT="$RELEASE_ROOT/$SOURCE_BASENAME.tar.gz"
CHECKSUM_FILE="$RELEASE_ROOT/$APP_EXECUTABLE_NAME-$APP_VERSION+$APP_BUILD_NUMBER-SHA256SUMS.txt"
MANIFEST="$RELEASE_ROOT/$ARTIFACT_BASENAME.manifest.json"

assert_release_checkout
RELEASE_COMMIT="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
assert_unnotarized_output_paths_available
WORK_DIR_RECORD="$(create_unnotarized_work_dir)" || \
  fail "Could not create a unique release work directory safely."
WORK_DIR="${WORK_DIR_RECORD%%|*}"
WORK_DIR_METADATA="${WORK_DIR_RECORD#*|}"
WORK_DIR_DEVICE="${WORK_DIR_METADATA%%|*}"
WORK_DIR_INODE="${WORK_DIR_METADATA#*|}"
APP_BUNDLE="$WORK_DIR/$APP_EXECUTABLE_NAME.app"
VALIDATION_DIR="$WORK_DIR/final-validation"
SWIFT_BUILD_DIR="$WORK_DIR/swift-build"
STAGED_ARTIFACT="$WORK_DIR/$(basename "$ARTIFACT")"
STAGED_SOURCE="$WORK_DIR/$(basename "$SOURCE_ARTIFACT")"
STAGED_CHECKSUMS="$WORK_DIR/$(basename "$CHECKSUM_FILE")"
STAGED_MANIFEST="$WORK_DIR/$(basename "$MANIFEST")"
install_unnotarized_release_traps

validate_tracked_release_certificate
RELEASE_CERT_SHA1="$(resolve_codesigning_identity_sha1 "$UNNOTARIZED_CODESIGN_IDENTITY")" || \
  fail "Install exactly one valid code-signing identity named: $UNNOTARIZED_CODESIGN_IDENTITY"
[[ "$RELEASE_CERT_SHA1" == "$PINNED_CERT_SHA1" ]] || \
  fail "Keychain signing identity does not match the tracked release certificate."
verify_regular_file_snapshot \
  "$RELEASE_CERTIFICATE" "$RELEASE_CERTIFICATE_SNAPSHOT" exact \
  "Tracked release certificate"
SWIFT_VERSION="$("$SWIFT_BIN" --version | /usr/bin/head -n 1)"
XCODE_VERSION="$("$XCODEBUILD_BIN" -version | /usr/bin/paste -sd ' ' -)"
MACOS_VERSION="$(/usr/bin/sw_vers -productVersion)"
MACOS_BUILD="$(/usr/bin/sw_vers -buildVersion)"

LICENSE_SHA256="$(sha256_file "$ROOT_DIR/LICENSE")"
CREDITS_SHA256="$(sha256_file "$ROOT_DIR/CREDITS.md")"
PRIVACY_SHA256="$(sha256_file "$ROOT_DIR/PRIVACY.md")"
ICON_SHA256="$(sha256_file "$APP_ICON_PATH")"

/usr/bin/git -C "$ROOT_DIR" archive \
  --format=tar.gz \
  --prefix="$SOURCE_BASENAME/" \
  --output="$STAGED_SOURCE" \
  "$RELEASE_TAG"
sanitize_and_verify_generated_file_xattrs "$STAGED_SOURCE"
freeze_regular_file STAGED_SOURCE_SNAPSHOT "$STAGED_SOURCE" "staged source archive"

cd "$ROOT_DIR"
"$SWIFT_BIN" build -c release --scratch-path "$SWIFT_BUILD_DIR"
BUILD_BINARY="$(
  "$SWIFT_BIN" build -c release --scratch-path "$SWIFT_BUILD_DIR" --show-bin-path
)/$APP_EXECUTABLE_NAME"
assert_arm64_architecture "$BUILD_BINARY"
assert_release_checkout
assemble_app_bundle "$ROOT_DIR" "$BUILD_BINARY" "$APP_BUNDLE"
sanitize_and_verify_unsigned_bundle_xattrs "$APP_BUNDLE"

/usr/bin/codesign --force \
  --sign "$RELEASE_CERT_SHA1" \
  --identifier "$APP_BUNDLE_ID" \
  --requirements "=designated => anchor = H\"$PINNED_CERT_SHA1\" and identifier \"$APP_BUNDLE_ID\"" \
  --options runtime \
  --timestamp=none \
  "$APP_BUNDLE"
verify_bundle_metadata "$APP_BUNDLE"
verify_release_xattrs "$APP_BUNDLE"
verify_regular_file_snapshot \
  "$RELEASE_CERTIFICATE" "$RELEASE_CERTIFICATE_SNAPSHOT" exact \
  "Tracked release certificate"

/usr/bin/ditto -c -k --keepParent --norsrc "$APP_BUNDLE" "$STAGED_ARTIFACT"
sanitize_and_verify_generated_file_xattrs "$STAGED_ARTIFACT"
freeze_regular_file STAGED_ARTIFACT_SNAPSHOT "$STAGED_ARTIFACT" "staged app artifact"
validate_final_artifact
assert_release_checkout

ARTIFACT_SHA256="$(snapshot_sha256 "$STAGED_ARTIFACT_SNAPSHOT")"
SOURCE_SHA256="$(snapshot_sha256 "$STAGED_SOURCE_SNAPSHOT")"
write_manifest
sanitize_and_verify_generated_file_xattrs "$STAGED_MANIFEST"
freeze_regular_file STAGED_MANIFEST_SNAPSHOT "$STAGED_MANIFEST" "staged release manifest"
MANIFEST_SHA256="$(snapshot_sha256 "$STAGED_MANIFEST_SNAPSHOT")"
/usr/bin/printf '%s  %s\n%s  %s\n%s  %s\n' \
  "$ARTIFACT_SHA256" "$(basename "$ARTIFACT")" \
  "$SOURCE_SHA256" "$(basename "$SOURCE_ARTIFACT")" \
  "$MANIFEST_SHA256" "$(basename "$MANIFEST")" \
  >"$STAGED_CHECKSUMS"
sanitize_and_verify_generated_file_xattrs "$STAGED_CHECKSUMS"
freeze_regular_file STAGED_CHECKSUMS_SNAPSHOT "$STAGED_CHECKSUMS" "staged checksum file"

assert_unnotarized_output_paths_available
assert_release_checkout
verify_staged_release_evidence
publish_release_output \
  "$STAGED_ARTIFACT" "$ARTIFACT" "$STAGED_ARTIFACT_SNAPSHOT" PUBLISHED_ARTIFACT
publish_release_output \
  "$STAGED_SOURCE" "$SOURCE_ARTIFACT" "$STAGED_SOURCE_SNAPSHOT" PUBLISHED_SOURCE
publish_release_output \
  "$STAGED_MANIFEST" "$MANIFEST" "$STAGED_MANIFEST_SNAPSHOT" PUBLISHED_MANIFEST
publish_release_output \
  "$STAGED_CHECKSUMS" "$CHECKSUM_FILE" "$STAGED_CHECKSUMS_SNAPSHOT" PUBLISHED_CHECKSUMS

verify_published_release_evidence
(
  cd "$RELEASE_ROOT"
  /usr/bin/shasum -a 256 -c "$(basename "$CHECKSUM_FILE")"
)
validate_strict_json_file "$MANIFEST"
verify_release_xattrs "$ARTIFACT"
verify_release_xattrs "$SOURCE_ARTIFACT"
verify_release_xattrs "$MANIFEST"
verify_release_xattrs "$CHECKSUM_FILE"
verify_published_release_evidence
RELEASE_COMPLETE=1

/usr/bin/printf '%s\n' \
  "GitHub release artifacts are ready:" \
  "  $ARTIFACT" \
  "  $SOURCE_ARTIFACT" \
  "  $CHECKSUM_FILE" \
  "  $MANIFEST" \
  "" \
  "Architecture: arm64" \
  "Signing: pinned project-owned self-signed certificate ($UNNOTARIZED_CODESIGN_IDENTITY)" \
  "Signing leaf SHA-256: $RELEASE_SIGNING_LEAF_SHA256" \
  "Notarization: not submitted" \
  "Gatekeeper: rejected as expected ($GATEKEEPER_ASSESSMENT)" \
  "Keychain ACL continuity: unverified until clean-install and upgrade acceptance is complete" \
  "Users must explicitly approve the downloaded app through macOS Privacy & Security."
