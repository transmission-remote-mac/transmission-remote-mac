# Transmission Remote Mac
# SPDX-FileCopyrightText: 2026 aidpok
# SPDX-License-Identifier: GPL-2.0-only
# See CREDITS.md for upstream attribution.

import unittest
from pathlib import Path

from check_source_hygiene import source_problems


class SourceHygieneTests(unittest.TestCase):
    header = (
        "// Transmission Remote Mac\n"
        "// SPDX-FileCopyrightText: 2026 Example Contributor\n"
        "// SPDX-License-Identifier: GPL-2.0-only\n"
    )

    def test_accepts_contributor_notice_and_existing_long_declarations(self):
        source = self.header + "func " + "longName" * 30 + "() {}\n"
        self.assertEqual(source_problems(Path("Example.swift"), source.encode()), [])

    def test_requires_notices_near_start(self):
        self.assertEqual(len(source_problems(Path("Example.swift"), b"import Foundation\n")), 3)

    def test_detects_whitespace_without_rewriting(self):
        source = (self.header + "\tlet value = 1 \r\n}").encode()
        problems = source_problems(Path("Example.swift"), source)
        self.assertEqual(len(problems), 4)

    def test_rejects_invalid_encoding(self):
        self.assertEqual(len(source_problems(Path("Example.swift"), b"\xff")), 1)

    def test_package_directive_stays_first(self):
        self.assertEqual(len(source_problems(Path("Package.swift"), self.header.encode())), 1)
        self.assertEqual(source_problems(Path("Package.swift"), ("// swift-tools-version: 5.9\n" + self.header).encode()), [])

    def test_script_header_follows_shebang(self):
        source = "#!/usr/bin/env python3\n" + self.header.replace("//", "#")
        self.assertEqual(source_problems(Path("example.py"), source.encode()), [])


if __name__ == "__main__":
    unittest.main()
