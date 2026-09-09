// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentOverviewRequestPlan: Equatable, Sendable {
    let fields: [String]
    let omittedFields: Set<String>
    let pieceCount: Int?
    let pieceSize: Int64?

    init(
        summary: TorrentSummary,
        cachedInfo: TorrentGeneralInfo?,
        rpcVersion: Int,
        requiresPieceRevalidation: Bool = false
    ) {
        let fullFields = Set(TorrentDetailPane.overview.rpcFields(rpcVersion: rpcVersion))
        let pieceMapState = TorrentPiecePresentation.state(
            summary: summary,
            cachedInfo: cachedInfo,
            requiresPieceRevalidation: requiresPieceRevalidation
        )
        pieceCount = summary.pieceCount ?? cachedInfo?.pieceCount
        pieceSize = summary.pieceSize ?? cachedInfo?.pieceSize
        var omitted = Set<String>()

        // Empty immutable values are still loaded values. Cache ownership must
        // establish that this info came from a full overview for this identity.
        if let cachedInfo,
           cachedInfo.hasCompleteMetadataFromOverview,
           rpcVersion < 7 || (summary.isMetadataComplete && summary.metadataPercentComplete == 1) {
            omitted.formUnion(["comment", "creator", "dateCreated"])
            if let size = cachedInfo.pieceSize, size > 0 { omitted.insert("pieceSize") }
        }
        if case .complete = pieceMapState {
            omitted.formUnion(["pieces", "pieceCount", "pieceSize"])
        }

        omittedFields = omitted.intersection(fullFields)
        fields = fullFields.subtracting(omittedFields).sorted()
    }
}
