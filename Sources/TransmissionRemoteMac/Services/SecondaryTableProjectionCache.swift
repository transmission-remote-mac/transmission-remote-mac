// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine

/// A bounded, non-publishing memo for immutable pane snapshots. Rendering and
/// selection synchronization share the same result without invalidating a Table.
@MainActor
final class SecondaryTableProjectionCache<Identity: Equatable, Projection>: ObservableObject {
    private var identity: Identity?
    private var sort: SecondaryTableSortPreference?
    private var projection: Projection?

    func value(for identity: Identity, sort: SecondaryTableSortPreference, build: () -> Projection) -> Projection {
        if self.identity == identity, self.sort == sort, let projection {
            return projection
        }
        let result = build()
        self.identity = identity
        self.sort = sort
        projection = result
        return result
    }
}
