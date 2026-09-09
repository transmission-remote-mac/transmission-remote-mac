// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// Read widths from the public SwiftUI customization Codable payload. Native
/// column identifiers are transient UUIDs, so the bridge uses catalog titles.
enum TableColumnWidthSnapshot {
    static func widths(in data: Data) -> [String: CGFloat] {
        guard let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return [:] }
        var result: [String: CGFloat] = [:]
        var columnID: String?
        for entry in snapshot.perColumnState {
            if let identifier = entry.base?.explicit.value {
                columnID = identifier
            } else {
                if let columnID, let width = entry.currentWidth, width.isFinite, width > 0 {
                    result[columnID] = width
                }
                columnID = nil
            }
        }
        return result
    }

    private struct Snapshot: Decodable {
        let perColumnState: [Entry]
    }

    private struct Entry: Decodable {
        let base: Base?
        let currentWidth: CGFloat?
    }

    private struct Base: Decodable {
        let explicit: Identifier
    }

    private struct Identifier: Decodable {
        let value: String
        private enum CodingKeys: String, CodingKey {
            case value = "_0"
        }
    }
}
