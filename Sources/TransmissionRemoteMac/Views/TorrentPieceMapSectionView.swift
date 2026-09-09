// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI

struct TorrentPieceMapSectionView: View, Equatable {
    var state: TorrentPieceMapState
    @StateObject private var projectionCache = TorrentPieceMapProjectionCache()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.state == rhs.state
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Piece completion", systemImage: "square.grid.3x3.fill")
                .font(.subheadline.weight(.bold))

            Group {
                switch state {
                case .available(let pieceMap) where pieceMap.pieceCount > 0:
                    GeometryReader { geometry in
                        TorrentPieceMapCanvas(
                            projection: projectionCache.projection(
                                for: pieceMap,
                                proposedCellCount: max(1, Int(geometry.size.width.rounded(.down)))
                            )
                        )
                        .equatable()
                    }
                case .complete:
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.accentColor)
                        .accessibilityLabel("Piece completion")
                        .accessibilityValue(completionDescription)
                default:
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.secondary.opacity(0.16))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 18)

            HStack(spacing: 14) {
                Text(completionDescription)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(completionDescription)
                if hasPieceMap {
                    Spacer(minLength: 8)
                    TorrentPieceMapLegendItem(title: "Complete", color: .accentColor)
                    TorrentPieceMapLegendItem(title: "Mixed", color: .accentColor.opacity(0.45))
                    TorrentPieceMapLegendItem(title: "Missing", color: .secondary.opacity(0.16))
                }
            }
            .frame(minHeight: 14, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.25))
        }
    }

    private var hasPieceMap: Bool {
        switch state {
        case .available(let map): map.pieceCount > 0
        case .complete: true
        case .unavailable, .invalid: false
        }
    }

    private var completionDescription: String {
        switch state {
        case .unavailable:
            "Piece details are not available."
        case .invalid(let error):
            error.displayDescription
        case .complete(let count):
            "\(count.formatted()) of \(count.formatted()) pieces complete"
        case .available(let map) where map.pieceCount == 0:
            "This torrent has no pieces to display."
        case .available(let map):
            "\(map.completedPieceCount.formatted()) of \(map.pieceCount.formatted()) pieces complete"
        }
    }
}

private struct TorrentPieceMapCanvas: View, Equatable {
    var projection: TorrentPieceMapProjection

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            guard !projection.cells.isEmpty, size.width > 0, size.height > 0 else { return }
            let cellWidth = size.width / CGFloat(projection.cells.count)

            for (index, cell) in projection.cells.enumerated() {
                let minimumX = floor(CGFloat(index) * cellWidth)
                let maximumX = ceil(CGFloat(index + 1) * cellWidth)
                let color: Color = switch cell {
                case .complete: .accentColor
                case .partial: .accentColor.opacity(0.45)
                case .missing: .secondary.opacity(0.16)
                }
                context.fill(
                    Path(CGRect(
                        x: minimumX,
                        y: 0,
                        width: max(1, maximumX - minimumX),
                        height: size.height
                    )),
                    with: .color(color)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.3))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Piece completion")
        .accessibilityValue(
            "\(projection.completedPieceCount) of \(projection.pieceCount) pieces complete"
        )
    }
}

private struct TorrentPieceMapLegendItem: View {
    var title: String
    var color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
