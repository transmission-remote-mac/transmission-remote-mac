// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI

struct GlobalStatisticsView: View {
    var sessionStats: SessionStats?

    var body: some View {
        if let sessionStats {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Global daemon statistics", systemImage: "server.rack")
                            .font(.title3.weight(.semibold))

                        Text("These figures cover the entire Transmission daemon, not the selected torrent.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 145), spacing: 10)],
                        alignment: .leading,
                        spacing: 10
                    ) {
                        GlobalStatisticMetricView(
                            title: "Active torrents",
                            value: Self.count(sessionStats.activeTorrentCount),
                            systemImage: "bolt.fill"
                        )
                        GlobalStatisticMetricView(
                            title: "Paused torrents",
                            value: Self.count(sessionStats.pausedTorrentCount),
                            systemImage: "pause.fill"
                        )
                        GlobalStatisticMetricView(
                            title: "Total torrents",
                            value: Self.count(sessionStats.torrentCount),
                            systemImage: "tray.full.fill"
                        )
                        GlobalStatisticMetricView(
                            title: "Download speed",
                            value: ByteCountFormatters.speed(sessionStats.downloadSpeed),
                            systemImage: "arrow.down"
                        )
                        GlobalStatisticMetricView(
                            title: "Upload speed",
                            value: ByteCountFormatters.speed(sessionStats.uploadSpeed),
                            systemImage: "arrow.up"
                        )
                    }

                    GlobalStatisticHistoryView(
                        rows: Self.historyRows(for: sessionStats)
                    )
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            ContentUnavailableView(
                "Global Statistics Unavailable",
                systemImage: "chart.bar.xaxis",
                description: Text("Connect to a daemon that supports session statistics. These figures are daemon-wide, not torrent-specific.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private static func historyRows(for stats: SessionStats) -> [GlobalStatisticHistoryRow] {
        [
            GlobalStatisticHistoryRow(
                label: "Downloaded",
                current: ByteCountFormatters.transferSize(stats.current.downloadedBytes),
                cumulative: ByteCountFormatters.transferSize(stats.cumulative.downloadedBytes)
            ),
            GlobalStatisticHistoryRow(
                label: "Uploaded",
                current: ByteCountFormatters.transferSize(stats.current.uploadedBytes),
                cumulative: ByteCountFormatters.transferSize(stats.cumulative.uploadedBytes)
            ),
            GlobalStatisticHistoryRow(
                label: "Files added",
                current: count(stats.current.filesAdded),
                cumulative: count(stats.cumulative.filesAdded)
            ),
            GlobalStatisticHistoryRow(
                label: "Active time",
                current: elapsed(stats.current.secondsActive),
                cumulative: elapsed(stats.cumulative.secondsActive)
            ),
            GlobalStatisticHistoryRow(
                label: "Daemon sessions",
                current: count(stats.current.sessionCount),
                cumulative: count(stats.cumulative.sessionCount)
            )
        ]
    }

    private static func count(_ value: Int) -> String {
        max(0, value).formatted()
    }

    private static func elapsed(_ seconds: Int) -> String {
        seconds > 0 ? DurationFormatters.elapsed(seconds) : "0s"
    }
}

private struct GlobalStatisticMetricView: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18))
        }
    }
}

private struct GlobalStatisticHistoryView: View {
    var rows: [GlobalStatisticHistoryRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Transfer history", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.bold))

            Text("Current session resets when the daemon restarts. Cumulative totals are retained across daemon sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ViewThatFits(in: .horizontal) {
                GlobalStatisticComparisonGrid(rows: rows)
                VStack(spacing: 10) {
                    GlobalStatisticSnapshotView(
                        title: "Current session",
                        rows: rows,
                        value: \GlobalStatisticHistoryRow.current
                    )
                    GlobalStatisticSnapshotView(
                        title: "Cumulative",
                        rows: rows,
                        value: \GlobalStatisticHistoryRow.cumulative
                    )
                }
            }
        }
    }
}

private struct GlobalStatisticComparisonGrid: View {
    var rows: [GlobalStatisticHistoryRow]

    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Measure")
                    .frame(width: 150, alignment: .leading)
                Text("Current session")
                    .frame(width: 150, alignment: .trailing)
                Text("Cumulative")
                    .frame(width: 150, alignment: .trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            Divider()
                .gridCellColumns(3)

            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 150, alignment: .leading)
                    Text(row.current)
                        .frame(width: 150, alignment: .trailing)
                    Text(row.cumulative)
                        .frame(width: 150, alignment: .trailing)
                }
            }
        }
        .font(.callout.monospacedDigit())
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
        }
    }
}

private struct GlobalStatisticSnapshotView: View {
    var title: String
    var rows: [GlobalStatisticHistoryRow]
    var value: KeyPath<GlobalStatisticHistoryRow, String>

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
                ForEach(rows) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                        Text(row[keyPath: value])
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            .font(.callout)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
        }
    }
}

private struct GlobalStatisticHistoryRow: Identifiable {
    var label: String
    var current: String
    var cumulative: String

    var id: String { label }
}
