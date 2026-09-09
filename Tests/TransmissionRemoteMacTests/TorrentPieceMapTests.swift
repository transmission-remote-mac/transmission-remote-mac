// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentPieceMapTests: XCTestCase {
    func testDecodesMSBFirstAndIgnoresUnusedBitsInPartialLastByte() throws {
        let pieceMap = try TorrentPieceMap(
            base64Encoded: Data([0b1010_0000, 0b1100_0011]).base64EncodedString(),
            pieceCount: 10
        )

        XCTAssertEqual(pieceMap.pieceCount, 10)
        XCTAssertEqual(pieceMap.packedByteCount, 2)
        XCTAssertEqual(pieceMap.completedPieceCount, 4)
        XCTAssertEqual((0..<10).compactMap { pieceMap.isComplete(pieceAt: $0) }, [
            true, false, true, false, false, false, false, false, true, true,
        ])
        XCTAssertNil(pieceMap.isComplete(pieceAt: -1))
        XCTAssertNil(pieceMap.isComplete(pieceAt: 10))
    }

    func testRejectsMalformedBase64AndPieceCountMismatches() {
        XCTAssertEqual(
            TorrentPieceMapState(base64Encoded: "%%%", pieceCount: 8),
            .invalid(.malformedBase64)
        )
        XCTAssertEqual(
            TorrentPieceMapState(
                base64Encoded: Data([0]).base64EncodedString(),
                pieceCount: 9
            ),
            .invalid(.byteCountMismatch(expected: 2, actual: 1))
        )
        XCTAssertEqual(
            TorrentPieceMapState(base64Encoded: "", pieceCount: -1),
            .invalid(.negativePieceCount(-1))
        )
    }

    func testUnknownAndZeroPieceCountsProduceInspectableStates() {
        XCTAssertEqual(
            TorrentPieceMapState(base64Encoded: nil, pieceCount: 8),
            .unavailable
        )
        XCTAssertEqual(
            TorrentPieceMapState(base64Encoded: "", pieceCount: nil),
            .unavailable
        )

        let state = TorrentPieceMapState(base64Encoded: "", pieceCount: 0)
        guard case .available(let pieceMap) = state else {
            return XCTFail("Expected an available empty piece map")
        }
        XCTAssertEqual(pieceMap.pieceCount, 0)
        XCTAssertEqual(pieceMap.completedPieceCount, 0)
        XCTAssertEqual(
            TorrentPieceMapProjection(pieceMap: pieceMap, maximumCellCount: 100).cells,
            []
        )
    }

    func testProjectionBoundsItsCellsAndAggregatesCompleteMissingAndMixedRanges() throws {
        let groupedMap = try TorrentPieceMap(
            base64Encoded: Data([0b1100_0011]).base64EncodedString(),
            pieceCount: 8
        )
        XCTAssertEqual(
            TorrentPieceMapProjection(pieceMap: groupedMap, maximumCellCount: 4).cells,
            [.complete, .missing, .missing, .complete]
        )

        let unevenMap = try TorrentPieceMap(
            base64Encoded: Data([0b1001_1000]).base64EncodedString(),
            pieceCount: 5
        )
        let projection = TorrentPieceMapProjection(
            pieceMap: unevenMap,
            maximumCellCount: 3
        )
        XCTAssertEqual(projection.cells, [.partial, .partial, .complete])
        XCTAssertEqual(projection.cells.count, 3)
        XCTAssertEqual(projection.pieceCount, 5)
        XCTAssertEqual(projection.completedPieceCount, 3)
    }

    func testLargeProjectionKeepsPackedStorageAndBoundedCellCount() throws {
        let pieceCount = 1_000_003
        let expectedByteCount = pieceCount / 8 + 1
        let pieceMap = try TorrentPieceMap(
            base64Encoded: Data(repeating: 0b1010_1010, count: expectedByteCount)
                .base64EncodedString(),
            pieceCount: pieceCount
        )

        let projection = TorrentPieceMapProjection(
            pieceMap: pieceMap,
            maximumCellCount: 10_000
        )

        XCTAssertEqual(pieceMap.packedByteCount, expectedByteCount)
        XCTAssertEqual(projection.pieceCount, pieceCount)
        XCTAssertEqual(TorrentPieceMapProjection.renderingCellCeiling, 4_000)
        XCTAssertEqual(projection.cells.count, 4_000)
    }

    @MainActor
    func testProjectionCacheReusesSeparatelyDecodedEqualBitfieldsAtTheFixedCeiling() throws {
        let encodedPieces = Data(repeating: UInt8.max, count: 625).base64EncodedString()
        let pieceMap = try TorrentPieceMap(
            base64Encoded: encodedPieces,
            pieceCount: 5_000
        )
        let equalPieceMap = try TorrentPieceMap(
            base64Encoded: encodedPieces,
            pieceCount: 5_000
        )
        let cache = TorrentPieceMapProjectionCache()

        let first = cache.projection(for: pieceMap, proposedCellCount: 10_000)
        let second = cache.projection(for: equalPieceMap, proposedCellCount: Int.max)

        XCTAssertEqual(equalPieceMap, pieceMap)
        XCTAssertEqual(first.cells.count, 4_000)
        XCTAssertEqual(second, first)
        XCTAssertEqual(cache.projectionBuildCount, 1)

        _ = cache.projection(for: pieceMap, proposedCellCount: 3_999)
        XCTAssertEqual(cache.projectionBuildCount, 2)
    }

    func testRPCBoundaryDecodesObjectAndTablePieceRowsIntoTypedState() throws {
        let encodedPieces = Data([0b1010_0000]).base64EncodedString()
        let objectResponse = try TorrentGetResponse(validating: [
            "torrents": .array([.object([
                "id": .int(1),
                "pieceCount": .int(4),
                "pieces": .string(encodedPieces),
            ])]),
        ])
        let tableResponse = try TorrentGetResponse(validating: [
            "fields": .array([.string("id"), .string("pieceCount"), .string("pieces")]),
            "data": .array([.array([.int(1), .int(4), .string(encodedPieces)])]),
        ])

        for torrent in [objectResponse.torrents[0], tableResponse.torrents[0]] {
            guard case .available(let pieceMap) = torrent.pieceMapState else {
                return XCTFail("Expected a decoded piece map")
            }
            XCTAssertEqual(pieceMap.completedPieceCount, 2)
            XCTAssertEqual(
                (0..<4).compactMap { pieceMap.isComplete(pieceAt: $0) },
                [true, false, true, false]
            )
        }
    }

    func testReplacingOverviewUpdatesTheSelectedTorrentPieceMap() {
        let first = TorrentDetail(torrent: TorrentGetTorrent(json: [
            "id": .int(1),
            "pieceCount": .int(4),
            "pieces": .string(Data([0b1000_0000]).base64EncodedString()),
        ]))
        let refreshed = TorrentDetail(torrent: TorrentGetTorrent(json: [
            "id": .int(1),
            "pieceCount": .int(4),
            "pieces": .string(Data([0b1111_0000]).base64EncodedString()),
        ]))

        let result = first.replacing(.overview, with: refreshed)
        guard case .available(let pieceMap) = result.generalInfo?.pieceMapState else {
            return XCTFail("Expected the refreshed overview piece map")
        }
        XCTAssertEqual(pieceMap.completedPieceCount, 4)
    }
}
