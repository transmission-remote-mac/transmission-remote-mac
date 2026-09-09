#!/usr/bin/env bash
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

fail() {
  echo "$*" >&2
  exit 1
}

require_executable() {
  [[ -x "$1" ]] || fail "Required release tool is unavailable: $1"
}

regular_file_snapshot() {
  /usr/bin/python3 - "$1" <<'PY'
import hashlib
import os
import stat
import sys

path = sys.argv[1]
flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
try:
    descriptor = os.open(path, flags)
except OSError as error:
    raise SystemExit(f"could not open regular file without following symlinks: {path}: {error}")

try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode):
        raise SystemExit(f"release evidence is not a regular file: {path}")
    if before.st_nlink != 1:
        raise SystemExit(f"release evidence must have exactly one hard link: {path}")

    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)

    after = os.fstat(descriptor)
finally:
    os.close(descriptor)

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
    raise SystemExit(f"release evidence mutated while it was being hashed: {path}")

try:
    path_state = os.stat(path, follow_symlinks=False)
except OSError as error:
    raise SystemExit(f"release evidence path changed after hashing: {path}: {error}")
if not stat.S_ISREG(path_state.st_mode) or metadata(path_state) != metadata(after):
    raise SystemExit(f"release evidence path no longer names the hashed regular file: {path}")

print(
    "|".join(
        str(value)
        for value in (
            digest.hexdigest(),
            after.st_dev,
            after.st_ino,
            after.st_mode,
            after.st_nlink,
            after.st_size,
            after.st_mtime_ns,
            after.st_ctime_ns,
        )
    )
)
PY
}

verify_release_evidence_set() {
  /usr/bin/python3 - "$@" <<'PY'
import hashlib
import os
import re
import stat
import sys

arguments = sys.argv[1:]
if not arguments or len(arguments) % 4 != 0:
    raise SystemExit("release evidence set requires path, snapshot, comparison, and label groups")

snapshot_pattern = re.compile(r"^[0-9a-f]{64}(?:\|[0-9]+){7}$")


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


entries = []
try:
    for offset in range(0, len(arguments), 4):
        path, expected_text, comparison, label = arguments[offset:offset + 4]
        if not snapshot_pattern.fullmatch(expected_text):
            raise SystemExit(f"{label} has an invalid frozen snapshot")
        if comparison not in ("exact", "moved"):
            raise SystemExit(f"{label} has an invalid snapshot comparison")

        flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
        try:
            descriptor = os.open(path, flags)
        except OSError as error:
            raise SystemExit(f"could not open {label} without following symlinks: {error}")
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            os.close(descriptor)
            raise SystemExit(f"{label} is not a regular file")
        if opened.st_nlink != 1:
            os.close(descriptor)
            raise SystemExit(f"{label} must have exactly one hard link")
        entries.append({
            "path": path,
            "expected": expected_text.split("|"),
            "comparison": comparison,
            "label": label,
            "descriptor": descriptor,
            "opened": opened,
        })

    # Keep every descriptor open until every digest and every final path identity
    # has been checked. A mutation after an earlier digest therefore changes its
    # retained descriptor metadata and fails the final all-files pass.
    for entry in entries:
        digest = hashlib.sha256()
        while True:
            chunk = os.read(entry["descriptor"], 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
        entry["digest"] = digest.hexdigest()

    for entry in entries:
        final_state = os.fstat(entry["descriptor"])
        if metadata(entry["opened"]) != metadata(final_state):
            raise SystemExit(f'{entry["label"]} mutated during final release verification')
        try:
            path_state = os.stat(entry["path"], follow_symlinks=False)
        except OSError as error:
            raise SystemExit(f'{entry["label"]} path changed during final verification: {error}')
        if not stat.S_ISREG(path_state.st_mode) or metadata(path_state) != metadata(final_state):
            raise SystemExit(f'{entry["label"]} path no longer names its verified regular file')

        actual = [entry["digest"], *(str(value) for value in metadata(final_state))]
        expected = entry["expected"]
        if entry["comparison"] == "exact":
            matches = actual == expected
        else:
            # Publication changes ctime only. The digest, device, inode, mode,
            # singleton link count, size, and mtime remain frozen.
            matches = actual[:7] == expected[:7]
        if not matches:
            raise SystemExit(f'{entry["label"]} does not match its paired frozen snapshot')

    # Final metadata/path sweep across every still-open descriptor. This closes
    # the window where an earlier entry could change during later comparisons.
    for entry in entries:
        closing_state = os.fstat(entry["descriptor"])
        if metadata(entry["opened"]) != metadata(closing_state):
            raise SystemExit(f'{entry["label"]} mutated during the final evidence sweep')
        try:
            closing_path_state = os.stat(entry["path"], follow_symlinks=False)
        except OSError as error:
            raise SystemExit(f'{entry["label"]} path changed during the final evidence sweep: {error}')
        if (
            not stat.S_ISREG(closing_path_state.st_mode)
            or metadata(closing_path_state) != metadata(closing_state)
        ):
            raise SystemExit(f'{entry["label"]} path failed the final evidence sweep')
finally:
    for entry in entries:
        try:
            os.close(entry["descriptor"])
        except OSError:
            pass
PY
}

snapshot_sha256() {
  local snapshot="$1"
  /usr/bin/printf '%s\n' "${snapshot%%|*}"
}

freeze_regular_file() {
  local snapshot_variable="$1"
  local path="$2"
  local label="$3"
  local snapshot

  if ! snapshot="$(regular_file_snapshot "$path")"; then
    fail "Could not freeze $label as regular release evidence: $path"
  fi
  printf -v "$snapshot_variable" '%s' "$snapshot"
}

verify_regular_file_snapshot() {
  local path="$1"
  local expected_snapshot="$2"
  local comparison="$3"
  local label="$4"
  local actual_snapshot

  if ! actual_snapshot="$(regular_file_snapshot "$path")"; then
    fail "$label is no longer valid regular release evidence: $path"
  fi

  /usr/bin/python3 - "$expected_snapshot" "$actual_snapshot" "$comparison" <<'PY' || \
    fail "$label changed after its release identity was frozen: $path"
import re
import sys

expected_text, actual_text, comparison = sys.argv[1:]
pattern = re.compile(r"^[0-9a-f]{64}(?:\|[0-9]+){7}$")
if not pattern.fullmatch(expected_text) or not pattern.fullmatch(actual_text):
    raise SystemExit("invalid regular-file snapshot")

expected = expected_text.split("|")
actual = actual_text.split("|")
if comparison == "exact":
    matches = actual == expected
elif comparison == "moved":
    # Rename can update ctime. Content, device, inode, mode, link count, size,
    # and mtime must still identify the exact staged inode and bytes.
    matches = actual[:7] == expected[:7]
else:
    raise SystemExit("invalid regular-file snapshot comparison")
if not matches:
    raise SystemExit("regular-file snapshot mismatch")
PY
}

sha256_file() {
  local snapshot

  if ! snapshot="$(regular_file_snapshot "$1")"; then
    fail "Could not hash regular file without following symlinks: $1"
  fi
  snapshot_sha256 "$snapshot"
}

remove_owned_release_output() {
  local ownership_state="$1"
  local final="$2"
  local staged="$3"
  local staged_snapshot="${4:-}"

  case "$ownership_state" in
    0) return ;;
    1|armed)
      # While armed, publication may be on either side of the staged-link
      # removal. Prefer the still-present staged inode; once that name is gone,
      # fall back to the exact frozen singleton snapshot used by state 1.
      /usr/bin/python3 - \
        "$ownership_state" "$final" "$staged" "$staged_snapshot" <<'PY' || true
import hashlib
import os
import re
import stat
import sys

ownership_state, final_path, staged_path, expected_text = sys.argv[1:]


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


try:
    final_state = os.stat(final_path, follow_symlinks=False)
except OSError:
    raise SystemExit(0)

if ownership_state == "armed":
    try:
        staged_state = os.stat(staged_path, follow_symlinks=False)
    except FileNotFoundError:
        staged_state = None
    except OSError:
        raise SystemExit(0)
    if staged_state is not None:
        if (
            stat.S_ISREG(final_state.st_mode)
            and stat.S_ISREG(staged_state.st_mode)
            and final_state.st_dev == staged_state.st_dev
            and final_state.st_ino == staged_state.st_ino
        ):
            os.unlink(final_path)
        raise SystemExit(0)

snapshot_pattern = re.compile(r"^[0-9a-f]{64}(?:\|[0-9]+){7}$")
if not snapshot_pattern.fullmatch(expected_text):
    raise SystemExit(0)
expected = expected_text.split("|")

flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK
try:
    descriptor = os.open(final_path, flags)
except OSError:
    raise SystemExit(0)
try:
    before = os.fstat(descriptor)
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
        raise SystemExit(0)
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
    after = os.fstat(descriptor)
    if metadata(before) != metadata(after):
        raise SystemExit(0)
    path_state = os.stat(final_path, follow_symlinks=False)
    if not stat.S_ISREG(path_state.st_mode) or metadata(path_state) != metadata(after):
        raise SystemExit(0)
    actual = [digest.hexdigest(), *(str(value) for value in metadata(after))]
    if actual[:7] == expected[:7]:
        os.unlink(final_path)
finally:
    os.close(descriptor)
PY
      ;;
  esac
}

assert_release_checkout() {
  local current_commit
  local tagged_commit

  [[ "$(/usr/bin/git -C "$ROOT_DIR" rev-parse --is-shallow-repository)" == "false" ]] || \
    fail "Release checkout must not be shallow."
  current_commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse HEAD)"
  tagged_commit="$(/usr/bin/git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$RELEASE_TAG^{commit}" 2>/dev/null || true)"
  [[ -n "$tagged_commit" ]] || fail "Release tag does not exist: $RELEASE_TAG"
  [[ "$tagged_commit" == "$current_commit" ]] || fail "Release tag $RELEASE_TAG must point at HEAD."
  [[ -z "$(/usr/bin/git -C "$ROOT_DIR" status --porcelain)" ]] || fail "Release checkout must be clean."
  if [[ -n "${RELEASE_COMMIT:-}" && "$current_commit" != "$RELEASE_COMMIT" ]]; then
    fail "Release checkout HEAD changed during release assembly."
  fi
}

publish_release_output() {
  local staged="$1"
  local final="$2"
  local staged_snapshot="$3"
  local published_flag="$4"

  [[ ! -e "$final" && ! -L "$final" ]] || \
    fail "Refusing to overwrite release output created during assembly: $final"
  verify_regular_file_snapshot "$staged" "$staged_snapshot" exact "Staged publication input"

  # The successful absent-path assertion above is the namespace ownership
  # point. Arm cleanup before ln so an interrupt cannot strand our new link.
  printf -v "$published_flag" '%s' armed
  # Hard-link then unlink gives this same-filesystem publication an atomic,
  # no-overwrite destination while preserving the exact staged inode.
  /bin/ln "$staged" "$final"
  /bin/rm -f "$staged"
  printf -v "$published_flag" '%s' 1
  [[ ! -e "$staged" && ! -L "$staged" ]] || fail \
    "Staged release output remained after publication: $staged"
  verify_regular_file_snapshot "$final" "$staged_snapshot" moved "Published release output"
}
