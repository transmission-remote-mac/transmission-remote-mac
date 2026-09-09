// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentListFieldPlan: Equatable, Sendable {
    let revision: Int
    let rpcVersion: Int
    let projectionColumns: Set<TorrentTableColumnID>
    let fullFields: [String]
    let deltaFields: [String]
    let bootstrapFields: [String]

    init(
        revision: Int,
        rpcVersion: Int,
        visibleColumns: Set<TorrentTableColumnID>,
        activeSortColumn: TorrentTableColumnID
    ) {
        self.revision = revision
        self.rpcVersion = rpcVersion

        let projectionColumns = visibleColumns.union([activeSortColumn, .name])
        self.projectionColumns = projectionColumns

        let identity = TorrentTableFieldRequirements.identityRequired
        let behavior = TorrentTableFieldRequirements.alwaysNeededBehaviorDynamicRequired
        let filterDynamic = TorrentTableFieldRequirements.filterSidebarDynamicRequired
        let trackerStatusDynamic = TorrentTableFieldRequirements.trackerStatusDynamicRequired
        let presentationDynamic = TorrentTableFieldRequirements.dynamicPresentationRequirements(
            for: projectionColumns
        )
        let filterStatic = TorrentTableFieldRequirements.filterSidebarStaticRequired
        let presentationStatic = TorrentTableFieldRequirements.staticPresentationRequirements(
            for: projectionColumns
        )
        let trackerMetadata = TorrentTableFieldRequirements.heavyweightTrackerMetadataRequired

        deltaFields = Self.supportedFields(
            identity
                .union(behavior)
                .union(filterDynamic)
                .union(trackerStatusDynamic)
                .union(presentationDynamic),
            rpcVersion: rpcVersion
        )
        fullFields = Self.supportedFields(
            identity
                .union(behavior)
                .union(filterDynamic)
                .union(presentationDynamic)
                .union(filterStatic)
                .union(TorrentTableFieldRequirements.overviewStaticRequired)
                .union(presentationStatic)
                .union(trackerMetadata),
            rpcVersion: rpcVersion
        )
        bootstrapFields = fullFields
    }

    private static func supportedFields(
        _ requirements: Set<TorrentRPCFieldRequirement>,
        rpcVersion: Int
    ) -> [String] {
        Array(Set(requirements.lazy.filter { $0.isSupported(by: rpcVersion) }.map(\.field))).sorted()
    }
}
