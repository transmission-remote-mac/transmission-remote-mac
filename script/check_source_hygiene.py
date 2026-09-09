#!/usr/bin/env python3
# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

"""Check source notices and whitespace without rewriting source layout."""

from pathlib import Path
import sys


def source_problems(path, data):
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        return [f"{path}: source must be UTF-8"]
    problems = []
    if "\r" in text:
        problems.append(f"{path}: use LF line endings")
    if not text.endswith("\n"):
        problems.append(f"{path}: missing final newline")
    lines = text.splitlines()
    prefix = "//" if path.suffix == ".swift" else "#"
    header = lines[:8]
    if f"{prefix} Transmission Remote Mac" not in header:
        problems.append(f"{path}: missing project header")
    copyright_prefix = f"{prefix} SPDX-FileCopyrightText: "
    if not any(line.startswith(copyright_prefix) and line[len(copyright_prefix):].strip() for line in header):
        problems.append(f"{path}: missing copyright notice")
    if f"{prefix} SPDX-License-Identifier: GPL-2.0-only" not in header:
        problems.append(f"{path}: missing project license notice")
    if path.name == "Package.swift" and not text.startswith("// swift-tools-version:"):
        problems.append(f"{path}: swift-tools-version must be first")
    for number, line in enumerate(lines, 1):
        if line.rstrip(" \t") != line:
            problems.append(f"{path}:{number}: trailing whitespace")
        indentation = line[:len(line) - len(line.lstrip(" \t"))]
        if path.suffix in {".swift", ".py"} and "\t" in indentation:
            problems.append(f"{path}:{number}: use spaces for indentation")
    return problems


def main():
    root = Path(__file__).resolve().parent.parent
    paths = [root / "Package.swift"]
    for directory in ("Sources", "Tests", "script"):
        paths.extend(
            path for path in (root / directory).rglob("*")
            if path.is_file() and path.suffix in {".swift", ".py", ".sh"}
        )
    problems = []
    for path in sorted(paths):
        problems.extend(source_problems(path.relative_to(root), path.read_bytes()))
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print(f"Source hygiene passed for {len(paths)} files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
