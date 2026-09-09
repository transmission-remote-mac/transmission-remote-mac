// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine

@MainActor
final class TorrentPieceMapProjectionCache: ObservableObject {
    private var cachedPieceMap: TorrentPieceMap?
    private var cachedCellCount = 0
    private var cachedProjection: TorrentPieceMapProjection?

    private(set) var projectionBuildCount = 0

    func projection(
        for pieceMap: TorrentPieceMap,
        proposedCellCount: Int
    ) -> TorrentPieceMapProjection {
        let cellCount = TorrentPieceMapProjection.boundedCellCount(
            pieceCount: pieceMap.pieceCount,
            proposedCellCount: proposedCellCount
        )
        if cachedPieceMap == pieceMap,
           cachedCellCount == cellCount,
           let cachedProjection {
            return cachedProjection
        }

        let projection = TorrentPieceMapProjection(
            pieceMap: pieceMap,
            maximumCellCount: cellCount
        )
        cachedPieceMap = pieceMap
        cachedCellCount = cellCount
        cachedProjection = projection
        projectionBuildCount += 1
        return projection
    }
}
