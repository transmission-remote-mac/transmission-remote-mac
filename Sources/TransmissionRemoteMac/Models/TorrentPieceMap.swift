// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentPieceMapValidationError: Error, Hashable, Sendable {
    case negativePieceCount(Int)
    case malformedBase64
    case byteCountMismatch(expected: Int, actual: Int)

    var displayDescription: String {
        switch self {
        case .negativePieceCount:
            "Transmission returned an invalid piece count."
        case .malformedBase64:
            "Transmission returned a malformed piece bitfield."
        case .byteCountMismatch:
            "Transmission returned a piece bitfield with the wrong length."
        }
    }
}

enum TorrentPieceMapState: Hashable, Sendable {
    case unavailable
    case invalid(TorrentPieceMapValidationError)
    case available(TorrentPieceMap)
    case complete(pieceCount: Int)

    init(base64Encoded: String?, pieceCount: Int?) {
        guard let base64Encoded, let pieceCount else {
            self = .unavailable
            return
        }

        do {
            self = .available(try TorrentPieceMap(
                base64Encoded: base64Encoded,
                pieceCount: pieceCount
            ))
        } catch let error as TorrentPieceMapValidationError {
            self = .invalid(error)
        } catch {
            self = .invalid(.malformedBase64)
        }
    }
}

/// Transmission's MSB-first piece bitfield, kept packed rather than expanded
/// into one object per piece.
struct TorrentPieceMap: Hashable, Sendable {
    let pieceCount: Int
    let completedPieceCount: Int
    private let bytes: Data

    init(base64Encoded: String, pieceCount: Int) throws {
        guard pieceCount >= 0 else {
            throw TorrentPieceMapValidationError.negativePieceCount(pieceCount)
        }
        guard let decoded = Data(base64Encoded: base64Encoded) else {
            throw TorrentPieceMapValidationError.malformedBase64
        }

        let expectedByteCount = pieceCount / 8 + (pieceCount.isMultiple(of: 8) ? 0 : 1)
        guard decoded.count == expectedByteCount else {
            throw TorrentPieceMapValidationError.byteCountMismatch(
                expected: expectedByteCount,
                actual: decoded.count
            )
        }

        self.pieceCount = pieceCount
        completedPieceCount = Self.countCompletedPieces(
            in: decoded,
            pieceCount: pieceCount
        )
        bytes = decoded
    }

    static func == (lhs: TorrentPieceMap, rhs: TorrentPieceMap) -> Bool {
        lhs.pieceCount == rhs.pieceCount && lhs.bytes == rhs.bytes
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pieceCount)
        hasher.combine(bytes)
    }

    var packedByteCount: Int {
        bytes.count
    }

    func isComplete(pieceAt index: Int) -> Bool? {
        guard index >= 0, index < pieceCount else { return nil }
        let byte = bytes[index / 8]
        let mask = UInt8(0x80) >> UInt8(index % 8)
        return byte & mask != 0
    }

    /// Counts packed MSB-first bits without expanding the requested range into
    /// one Boolean or model value per piece.
    func completedPieceCount(in range: Range<Int>) -> Int? {
        guard range.lowerBound >= 0, range.upperBound <= pieceCount else { return nil }

        var completed = 0
        var pieceIndex = range.lowerBound
        while pieceIndex < range.upperBound {
            let byteIndex = pieceIndex / 8
            let bitOffset = pieceIndex % 8
            let bitCount = min(8 - bitOffset, range.upperBound - pieceIndex)
            let leadingMask = UInt8.max >> bitOffset
            let trailingMask = UInt8.max << (8 - bitOffset - bitCount)
            completed += (bytes[byteIndex] & leadingMask & trailingMask).nonzeroBitCount
            pieceIndex += bitCount
        }
        return completed
    }

    private static func countCompletedPieces(in bytes: Data, pieceCount: Int) -> Int {
        guard pieceCount > 0 else { return 0 }

        let completeByteCount = pieceCount / 8
        var completed = bytes.prefix(completeByteCount).reduce(0) {
            $0 + $1.nonzeroBitCount
        }
        let remainingBits = pieceCount % 8
        if remainingBits > 0, let finalByte = bytes.last {
            let validBitsMask = UInt8.max << (8 - remainingBits)
            completed += (finalByte & validBitsMask).nonzeroBitCount
        }
        return completed
    }
}
