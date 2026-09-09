// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentSorting {
    static var defaultSortOrder: [KeyPathComparator<TorrentSummary>] {
        [KeyPathComparator(\TorrentSummary.name, comparator: .localizedStandard)]
    }

    static func sorted(
        _ torrents: [TorrentSummary],
        using sortOrder: [KeyPathComparator<TorrentSummary>]
    ) -> [TorrentSummary] {
        let activeSortOrder = sortOrder.isEmpty ? defaultSortOrder : sortOrder
        return torrents.sorted { lhs, rhs in
            compare(lhs, rhs, using: activeSortOrder) == .orderedAscending
        }
    }

    static func areInIncreasingOrder(
        _ lhs: TorrentSummary,
        _ rhs: TorrentSummary,
        using sortOrder: [KeyPathComparator<TorrentSummary>]
    ) -> Bool {
        let activeSortOrder = sortOrder.isEmpty ? defaultSortOrder : sortOrder
        return compare(lhs, rhs, using: activeSortOrder) == .orderedAscending
    }

    private static func compare(
        _ lhs: TorrentSummary,
        _ rhs: TorrentSummary,
        using sortOrder: [KeyPathComparator<TorrentSummary>]
    ) -> ComparisonResult {
        for descriptor in sortOrder {
            let result = descriptor.compare(lhs, rhs)
            if result != .orderedSame {
                return result
            }
        }

        return KeyPathComparator(\TorrentSummary.id).compare(lhs, rhs)
    }
}
