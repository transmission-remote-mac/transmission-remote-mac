// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentPiecePresentation {
    static func state(
        summary: TorrentSummary,
        cachedInfo: TorrentGeneralInfo?,
        requiresPieceRevalidation: Bool = false
    ) -> TorrentPieceMapState {
        if requiresPieceRevalidation || cachedInfo?.isPieceCompletionInvalidated == true {
            return .unavailable
        }
        let cachedState = cachedInfo?.pieceMapState ?? .unavailable
        if case .invalid = cachedState { return cachedState }
        if case .available(let map) = cachedState,
           map.completedPieceCount != map.pieceCount {
            return cachedState
        }

        if let pieceCount = provenCompletePieceCount(summary: summary, cachedInfo: cachedInfo) {
            return .complete(pieceCount: pieceCount)
        }

        // A compact complete snapshot is valid only while the current list
        // evidence agrees. Verification and invalidation must not keep it blue.
        if case .complete = cachedState { return .unavailable }
        return cachedState
    }

    private static func provenCompletePieceCount(
        summary: TorrentSummary,
        cachedInfo: TorrentGeneralInfo?
    ) -> Int? {
        guard summary.isMetadataComplete,
              summary.metadataPercentComplete == 1,
              summary.status != .checking,
              summary.status != .checkWait,
              summary.status != .unknown,
              summary.errorString.isEmpty || summary.errorString == summary.trackerError,
              summary.globalError.isEmpty,
              summary.totalSize > 0,
              summary.reportedTotalSize == summary.totalSize,
              summary.haveValid == summary.totalSize,
              summary.haveUnchecked == 0,
              summary.leftUntilDone == 0,
              summary.sizeWhenDone > 0,
              summary.sizeWhenDone <= summary.totalSize,
              let pieceCount = summary.pieceCount ?? cachedInfo?.pieceCount,
              let pieceSize = summary.pieceSize ?? cachedInfo?.pieceSize,
              pieceCount > 0,
              pieceSize > 0 else {
            return nil
        }

        let expectedCount = summary.totalSize / pieceSize
            + (summary.totalSize.isMultiple(of: pieceSize) ? 0 : 1)
        guard Int64(pieceCount) == expectedCount else { return nil }
        if let cachedCount = cachedInfo?.pieceCount, cachedCount != pieceCount { return nil }
        if let cachedSize = cachedInfo?.pieceSize, cachedSize != pieceSize { return nil }
        if let cachedTotal = cachedInfo?.totalSize, cachedTotal != summary.totalSize { return nil }
        if let valid = cachedInfo?.haveValid, valid != summary.totalSize { return nil }
        if let unchecked = cachedInfo?.haveUnchecked, unchecked != 0 { return nil }
        if let remaining = cachedInfo?.leftUntilDone, remaining != 0 { return nil }
        if let metadata = cachedInfo?.metadataPercentComplete, metadata != 1 { return nil }
        if let status = cachedInfo?.status,
           status == .checking || status == .checkWait || status == .unknown {
            return nil
        }
        // Transmission's tracker warning/error codes (1/2) do not invalidate
        // verified local bytes. Local data errors and unknown errors still do.
        if let error = cachedInfo?.error, !(0...2).contains(error) { return nil }
        if let error = cachedInfo?.errorString, !error.isEmpty,
           cachedInfo?.error != 1, cachedInfo?.error != 2 {
            return nil
        }
        if let hash = cachedInfo?.hashString, !hash.isEmpty, hash != summary.hashString { return nil }
        if let cachedState = cachedInfo?.pieceMapState,
           case .available(let map) = cachedState,
           map.pieceCount != pieceCount || map.completedPieceCount != pieceCount {
            return nil
        }
        return pieceCount
    }
}
