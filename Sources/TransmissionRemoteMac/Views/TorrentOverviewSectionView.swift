// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI

struct TorrentOverviewSectionView: View, Equatable {
    var section: TorrentOverviewSection

    private let columnSpacing: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(section.title, systemImage: section.systemImage)
                .font(.subheadline.weight(.bold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(.primary)
                .background(Color.secondary.opacity(0.10))

            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    LazyVGrid(
                        columns: section.columns.map { _ in
                            GridItem(
                                .flexible(minimum: section.minimumColumnWidth),
                                spacing: columnSpacing,
                                alignment: .top
                            )
                        },
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(section.columns) { column in
                            TorrentOverviewColumnView(column: column)
                                .equatable()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: section.minimumColumnWidth),
                                spacing: columnSpacing,
                                alignment: .top
                            )
                        ],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(section.columns) { column in
                            TorrentOverviewColumnView(column: column)
                                .equatable()
                        }
                    }
                }

                if !section.fullSpanRows.isEmpty {
                    Divider()
                    TorrentOverviewColumnView(
                        column: TorrentOverviewColumn(
                            id: "full-span",
                            rows: section.fullSpanRows
                        )
                    )
                    .equatable()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
        }
    }
}

private struct TorrentOverviewColumnView: View, Equatable {
    var column: TorrentOverviewColumn

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            ForEach(column.rows) { row in
                GridRow(alignment: .firstTextBaseline) {
                    Text(row.label)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 118, alignment: .trailing)

                    TorrentOverviewValueView(row: row)
                        .equatable()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct TorrentOverviewValueView: View, Equatable {
    var row: TorrentDetailRow

    @Environment(\.openURL) private var openURL

    static func == (lhs: TorrentOverviewValueView, rhs: TorrentOverviewValueView) -> Bool {
        lhs.row == rhs.row
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ExpandableTorrentText(
                value: row.displayValue,
                accessibilityLabel: row.label,
                lineLimit: row.lineLimit,
                accessibilityValue: row.accessibilityValue
            )

            if let linkTarget = row.linkTarget {
                Button {
                    openURL(linkTarget.url)
                } label: {
                    Label("Open Link", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityIdentifier("torrent-overview-open-comment-link")
                .help("Open comment link in your default browser")
            }
        }
            .font(.callout)
            .foregroundStyle(row.isWarning ? Color.red : Color.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.help ?? row.displayValue)
    }
}
