// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum ByteCountFormatters {
    static let fileSize: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func fileSize(_ bytes: Int64) -> String {
        fileSize.string(fromByteCount: bytes)
    }

    static func preciseFileSize(_ bytes: Int64) -> String {
        bytes == 0 ? fileSize(0) : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func transferSize(_ bytes: Int64) -> String {
        bytes > 0 ? fileSize(bytes) : "—"
    }

    static func speed(_ bytesPerSecond: Int64, zeroValue: String = "—") -> String {
        bytesPerSecond > 0 ? "\(fileSize(bytesPerSecond))/s" : zeroValue
    }
}
