// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentOverviewSection: Identifiable, Equatable {
    var id: String { title }
    let title: String
    let systemImage: String
    let minimumColumnWidth: CGFloat
    let columns: [TorrentOverviewColumn]
    let fullSpanRows: [TorrentDetailRow]

    init(
        title: String,
        systemImage: String,
        minimumColumnWidth: CGFloat = 280,
        columns: [TorrentOverviewColumn],
        fullSpanRows: [TorrentDetailRow] = []
    ) {
        self.title = title
        self.systemImage = systemImage
        self.minimumColumnWidth = minimumColumnWidth
        self.columns = columns
        self.fullSpanRows = fullSpanRows
    }
}

struct TorrentOverviewColumn: Identifiable, Equatable {
    let id: String
    let rows: [TorrentDetailRow]

    static func balanced(
        rows: [TorrentDetailRow],
        columnCount: Int,
        idPrefix: String
    ) -> [TorrentOverviewColumn] {
        guard columnCount > 0 else { return [] }

        let baseRowCount = rows.count / columnCount
        let extraRowCount = rows.count % columnCount
        var nextRowIndex = rows.startIndex

        return (0..<columnCount).map { columnIndex in
            let rowCount = baseRowCount + (columnIndex < extraRowCount ? 1 : 0)
            let endIndex = nextRowIndex + rowCount
            defer { nextRowIndex = endIndex }
            return TorrentOverviewColumn(
                id: "\(idPrefix)-\(columnIndex)",
                rows: Array(rows[nextRowIndex..<endIndex])
            )
        }
    }
}

struct TorrentDetailRow: Identifiable, Equatable {
    var id: String { label }
    let label: String
    let value: String
    let isWarning: Bool
    let isLongText: Bool
    let help: String?
    let accessibilityValue: String?
    let linkTarget: TorrentCommentWebURL?

    init(
        _ label: String,
        _ value: String,
        isWarning: Bool = false,
        isLongText: Bool = false,
        help: String? = nil,
        accessibilityValue: String? = nil,
        linkTarget: TorrentCommentWebURL? = nil
    ) {
        self.label = label
        self.value = value
        self.isWarning = isWarning
        self.isLongText = isLongText
        self.help = help
        self.accessibilityValue = accessibilityValue
        self.linkTarget = linkTarget
    }

    var displayValue: String {
        value.isEmpty ? "—" : value
    }

    var lineLimit: Int {
        isLongText ? 2 : 3
    }

    static func date(
        _ label: String,
        _ date: Date?,
        relativeTo referenceDate: Date,
        preferences: DateDisplayPreferences,
        formatter: DateDisplayFormattingService
    ) -> TorrentDetailRow {
        guard let date else { return TorrentDetailRow(label, "—") }
        let presentation = formatter.presentation(
            for: date,
            relativeTo: referenceDate,
            preferences: preferences,
            context: .detail
        )
        return TorrentDetailRow(
            label,
            presentation.primary,
            help: presentation.alternate,
            accessibilityValue: "\(presentation.primary), alternate timestamp \(presentation.alternate)"
        )
    }
}
