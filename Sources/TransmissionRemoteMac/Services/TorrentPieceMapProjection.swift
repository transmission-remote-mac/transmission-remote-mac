// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

struct TorrentPieceMapProjection: Hashable, Sendable {
    static let renderingCellCeiling = 4_000

    enum Cell: Hashable, Sendable {
        case missing
        case partial
        case complete
    }

    let pieceCount: Int
    let completedPieceCount: Int
    let cells: [Cell]

    /// Partitions the packed bitfield into bounded display cells. The ranges
    /// cover each packed byte at most a constant number of times, so projection
    /// work is O(packed bytes + cells), never O(one model allocation per piece).
    init(pieceMap: TorrentPieceMap, maximumCellCount: Int) {
        pieceCount = pieceMap.pieceCount

        let cellCount = Self.boundedCellCount(
            pieceCount: pieceCount,
            proposedCellCount: maximumCellCount
        )
        guard cellCount > 0 else {
            completedPieceCount = pieceMap.completedPieceCount
            cells = []
            return
        }

        var projectedCells: [Cell] = []
        projectedCells.reserveCapacity(cellCount)
        var projectedCompletedPieceCount = 0
        for cellIndex in 0..<cellCount {
            let range = Self.pieceRange(
                for: cellIndex,
                pieceCount: pieceCount,
                cellCount: cellCount
            )
            let completedInCell = pieceMap.completedPieceCount(in: range) ?? 0
            projectedCompletedPieceCount += completedInCell

            if completedInCell == 0 {
                projectedCells.append(.missing)
            } else if completedInCell == range.count {
                projectedCells.append(.complete)
            } else {
                projectedCells.append(.partial)
            }
        }
        completedPieceCount = projectedCompletedPieceCount
        cells = projectedCells
    }

    static func boundedCellCount(pieceCount: Int, proposedCellCount: Int) -> Int {
        guard pieceCount > 0, proposedCellCount > 0 else { return 0 }
        return min(pieceCount, min(proposedCellCount, renderingCellCeiling))
    }

    private static func pieceRange(
        for cellIndex: Int,
        pieceCount: Int,
        cellCount: Int
    ) -> Range<Int> {
        let piecesPerCell = pieceCount / cellCount
        let cellsWithExtraPiece = pieceCount % cellCount
        let start = cellIndex * piecesPerCell + min(cellIndex, cellsWithExtraPiece)
        let count = piecesPerCell + (cellIndex < cellsWithExtraPiece ? 1 : 0)
        return start..<(start + count)
    }
}
