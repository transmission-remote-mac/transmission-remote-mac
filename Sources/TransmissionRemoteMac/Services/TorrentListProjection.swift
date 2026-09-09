// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentListProjectionChangeMetrics: Equatable, Sendable {
    var evaluatedRowCount: Int
    var authoritativeRowMutationCount: Int
    var visibleIndexRebuildCount: Int
    var sourceIndexRebuildCount: Int
    var pathCountMutationCount: Int
    var trackerCountMutationCount: Int
    var labelCountMutationCount: Int
    var visibleRowsChanged: Bool
    var filterCountsChanged: Bool
    var summaryInputsChanged: Bool

    static let empty = TorrentListProjectionChangeMetrics(
        evaluatedRowCount: 0,
        authoritativeRowMutationCount: 0,
        visibleIndexRebuildCount: 0,
        sourceIndexRebuildCount: 0,
        pathCountMutationCount: 0,
        trackerCountMutationCount: 0,
        labelCountMutationCount: 0,
        visibleRowsChanged: false,
        filterCountsChanged: false,
        summaryInputsChanged: false
    )

    var materializedStateChanged: Bool {
        visibleRowsChanged || filterCountsChanged || summaryInputsChanged
    }
}

/// Materialized torrent-list state. Full construction repairs every index.
/// Incremental application evaluates only the explicitly changed rows and
/// preserves the existing materialized projection everywhere else.
struct TorrentListProjection {
    static let empty = TorrentListProjection(
        torrents: [],
        filters: .empty,
        sortOrder: TorrentSorting.defaultSortOrder
    )

    private(set) var visibleRows: [TorrentSummary]
    private(set) var filterCounts: TorrentFilterCounts
    private(set) var visibleIDs: Set<TorrentSummary.ID>

    private var rowsByID: [TorrentSummary.ID: TorrentSummary]
    private var sourceIDs: [TorrentSummary.ID]
    private var sourceOrderByID: [TorrentSummary.ID: Int]
    private var visibleIndexByID: [TorrentSummary.ID: Int]
    private var activePollingTorrentIDs: Set<TorrentSummary.ID>
    private var totalCount: Int
    private var filteredSize: Int64
    private var fallbackDownloadSpeed: Int64
    private var fallbackUploadSpeed: Int64

    init(
        torrents: [TorrentSummary],
        filters: TorrentFilters,
        sortOrder: [KeyPathComparator<TorrentSummary>],
        filterEngine: TorrentFilterEngine = TorrentFilterEngine()
    ) {
        var rowsByID: [TorrentSummary.ID: TorrentSummary] = [:]
        var sourceIDs: [TorrentSummary.ID] = []
        rowsByID.reserveCapacity(torrents.count)
        sourceIDs.reserveCapacity(torrents.count)

        var fallbackDownloadSpeed: Int64 = 0
        var fallbackUploadSpeed: Int64 = 0
        for torrent in torrents {
            if rowsByID[torrent.id] == nil {
                sourceIDs.append(torrent.id)
            }
            rowsByID[torrent.id] = torrent
        }
        let sourceRows = sourceIDs.compactMap { rowsByID[$0] }
        for torrent in sourceRows {
            fallbackDownloadSpeed = Self.saturatedAdd(fallbackDownloadSpeed, max(0, torrent.rateDownload))
            fallbackUploadSpeed = Self.saturatedAdd(fallbackUploadSpeed, max(0, torrent.rateUpload))
        }

        var sourceOrderByID: [TorrentSummary.ID: Int] = [:]
        sourceOrderByID.reserveCapacity(sourceIDs.count)
        for (offset, id) in sourceIDs.enumerated() {
            sourceOrderByID[id] = offset
        }

        let visibleRows = TorrentSorting.sorted(
            filterEngine.filter(sourceRows, using: filters),
            using: sortOrder
        )
        var visibleIndexByID: [TorrentSummary.ID: Int] = [:]
        visibleIndexByID.reserveCapacity(visibleRows.count)
        for (offset, torrent) in visibleRows.enumerated() {
            visibleIndexByID[torrent.id] = offset
        }

        var filterCounts = filterEngine.counts(for: sourceRows)
        filterCounts.paths.sort { Self.countValuePrecedes($0.value, $1.value) }
        filterCounts.trackers.sort { Self.countValuePrecedes($0.value, $1.value) }
        filterCounts.labels.sort { Self.countValuePrecedes($0.value, $1.value) }

        self.visibleRows = visibleRows
        self.filterCounts = filterCounts
        self.visibleIDs = Set(visibleIndexByID.keys)
        self.rowsByID = rowsByID
        self.sourceIDs = sourceIDs
        self.sourceOrderByID = sourceOrderByID
        self.visibleIndexByID = visibleIndexByID
        self.activePollingTorrentIDs = Set(
            sourceRows.lazy
                .filter { AdaptivePollingCadencePolicy.requiresActiveCadence($0.status) }
                .map(\.id)
        )
        self.totalCount = sourceRows.count
        self.filteredSize = visibleRows.reduce(0) { Self.saturatedAdd($0, $1.displaySize) }
        self.fallbackDownloadSpeed = fallbackDownloadSpeed
        self.fallbackUploadSpeed = fallbackUploadSpeed
    }

    func row(for id: TorrentSummary.ID) -> TorrentSummary? {
        rowsByID[id]
    }

    var rowCount: Int {
        totalCount
    }

    var allRowIDs: [TorrentSummary.ID] {
        sourceIDs
    }

    var hasTorrentActivityRequiringActivePolling: Bool {
        !activePollingTorrentIDs.isEmpty
    }

    func allRowsInSourceOrder() -> [TorrentSummary] {
        sourceIDs.compactMap { rowsByID[$0] }
    }

    func ids(matchingHash hashString: String) -> [TorrentSummary.ID] {
        sourceIDs.filter { id in
            rowsByID[id]?.hashString.caseInsensitiveCompare(hashString) == .orderedSame
        }
    }

    func rows(for ids: Set<TorrentSummary.ID>) -> [TorrentSummary] {
        orderedRows(for: ids, using: sourceOrderByID)
    }

    func visibleRows(for ids: Set<TorrentSummary.ID>) -> [TorrentSummary] {
        guard ids.isSubset(of: visibleIDs) else { return [] }
        return orderedRows(for: ids, using: visibleIndexByID)
    }

    func selectedRowsInDisplayOrder(for ids: Set<TorrentSummary.ID>) -> [TorrentSummary] {
        let visibleSelection = ids.intersection(visibleIDs)
        if !visibleSelection.isEmpty {
            return orderedRows(for: visibleSelection, using: visibleIndexByID)
        }
        return orderedRows(for: ids, using: sourceOrderByID)
    }

    mutating func apply(
        upserted: [TorrentSummary],
        removedIDs: [TorrentSummary.ID],
        filters: TorrentFilters,
        sortOrder: [KeyPathComparator<TorrentSummary>],
        filterEngine: TorrentFilterEngine
    ) -> TorrentListProjectionChangeMetrics {
        let previousFilterCounts = filterCounts
        let previousTotalCount = totalCount
        let previousFilteredSize = filteredSize
        let previousFallbackDownloadSpeed = fallbackDownloadSpeed
        let previousFallbackUploadSpeed = fallbackUploadSpeed
        var evaluatedRowCount = 0
        var authoritativeRowMutationCount = 0
        var affectedVisibleIDs = Set<TorrentSummary.ID>()
        var topologyChanged = false
        var filterCountChanges = FilterCountChanges()

        for id in Set(removedIDs).sorted() {
            guard let removed = rowsByID.removeValue(forKey: id) else { continue }
            evaluatedRowCount += 1
            authoritativeRowMutationCount += 1
            topologyChanged = true
            if visibleIDs.contains(id) {
                affectedVisibleIDs.insert(id)
            }
            totalCount -= 1
            activePollingTorrentIDs.remove(id)
            filterCountChanges.include(previous: removed, current: nil, filterEngine: filterEngine)
            fallbackDownloadSpeed = Self.saturatedSubtract(fallbackDownloadSpeed, max(0, removed.rateDownload))
            fallbackUploadSpeed = Self.saturatedSubtract(fallbackUploadSpeed, max(0, removed.rateUpload))
        }

        for torrent in upserted.sorted(by: { $0.id < $1.id }) {
            let existing = rowsByID[torrent.id]
            guard existing != torrent else { continue }
            evaluatedRowCount += 1
            authoritativeRowMutationCount += 1
            if let existing {
                if visibleIDs.contains(torrent.id) {
                    affectedVisibleIDs.insert(torrent.id)
                }
                fallbackDownloadSpeed = Self.saturatedSubtract(
                    fallbackDownloadSpeed,
                    max(0, existing.rateDownload)
                )
                fallbackUploadSpeed = Self.saturatedSubtract(
                    fallbackUploadSpeed,
                    max(0, existing.rateUpload)
                )
            } else {
                topologyChanged = true
                totalCount += 1
            }

            rowsByID[torrent.id] = torrent
            if AdaptivePollingCadencePolicy.requiresActiveCadence(torrent.status) {
                activePollingTorrentIDs.insert(torrent.id)
            } else {
                activePollingTorrentIDs.remove(torrent.id)
            }
            if filterEngine.matches(torrent, filters: filters) {
                affectedVisibleIDs.insert(torrent.id)
            }
            filterCountChanges.include(previous: existing, current: torrent, filterEngine: filterEngine)
            fallbackDownloadSpeed = Self.saturatedAdd(fallbackDownloadSpeed, max(0, torrent.rateDownload))
            fallbackUploadSpeed = Self.saturatedAdd(fallbackUploadSpeed, max(0, torrent.rateUpload))
        }

        for (status, delta) in filterCountChanges.statuses where delta != 0 {
            filterCounts.statuses[status, default: 0] += delta
        }
        let pathCountMutationCount = Self.applyCountChanges(filterCountChanges.paths, to: &filterCounts.paths)
        let trackerCountMutationCount = Self.applyCountChanges(filterCountChanges.trackers, to: &filterCounts.trackers)
        let labelCountMutationCount = Self.applyCountChanges(filterCountChanges.labels, to: &filterCounts.labels)

        var sourceIndexRebuildCount = 0
        if topologyChanged {
            sourceIDs = rowsByID.keys.sorted()
            rebuildSourceIndexes()
            sourceIndexRebuildCount = 1
        }

        var visibleIndexRebuildCount = 0
        if !affectedVisibleIDs.isEmpty {
            let unaffectedRows = visibleRows.filter { !affectedVisibleIDs.contains($0.id) }
            let changedVisibleRows = TorrentSorting.sorted(
                affectedVisibleIDs.compactMap { id in
                    guard let torrent = rowsByID[id], filterEngine.matches(torrent, filters: filters) else {
                        return nil
                    }
                    return torrent
                },
                using: sortOrder
            )
            visibleRows = mergeSortedRows(unaffectedRows, changedVisibleRows, sortOrder: sortOrder)
            filteredSize = visibleRows.reduce(0) { Self.saturatedAdd($0, $1.displaySize) }
            rebuildVisibleIndexes()
            visibleIndexRebuildCount = 1
        }

        return TorrentListProjectionChangeMetrics(
            evaluatedRowCount: evaluatedRowCount,
            authoritativeRowMutationCount: authoritativeRowMutationCount,
            visibleIndexRebuildCount: visibleIndexRebuildCount,
            sourceIndexRebuildCount: sourceIndexRebuildCount,
            pathCountMutationCount: pathCountMutationCount,
            trackerCountMutationCount: trackerCountMutationCount,
            labelCountMutationCount: labelCountMutationCount,
            visibleRowsChanged: !affectedVisibleIDs.isEmpty,
            filterCountsChanged: filterCounts != previousFilterCounts,
            summaryInputsChanged: totalCount != previousTotalCount
                || filteredSize != previousFilteredSize
                || fallbackDownloadSpeed != previousFallbackDownloadSpeed
                || fallbackUploadSpeed != previousFallbackUploadSpeed
        )
    }

    func makeSummary(
        selectedIDs: Set<TorrentSummary.ID>,
        sessionStats: SessionStats?,
        sessionInfo: SessionInfo?
    ) -> TorrentListSummary {
        var selectedCount = 0
        var selectedSize: Int64 = 0
        for id in selectedIDs {
            guard let torrent = rowsByID[id] else { continue }
            selectedCount += 1
            selectedSize = Self.saturatedAdd(selectedSize, torrent.displaySize)
        }

        return TorrentListSummary(
            filteredCount: visibleRows.count,
            totalCount: totalCount,
            selectedCount: selectedCount,
            selectedSize: selectedSize,
            filteredSize: filteredSize,
            downloadSpeed: sessionStats?.downloadSpeed ?? fallbackDownloadSpeed,
            uploadSpeed: sessionStats?.uploadSpeed ?? fallbackUploadSpeed,
            freeSpace: sessionInfo?.downloadDirFreeSpace
        )
    }

    private mutating func rebuildSourceIndexes() {
        sourceOrderByID = [:]
        sourceOrderByID.reserveCapacity(sourceIDs.count)
        for (offset, id) in sourceIDs.enumerated() {
            sourceOrderByID[id] = offset
        }
    }

    private mutating func rebuildVisibleIndexes() {
        visibleIndexByID = [:]
        visibleIndexByID.reserveCapacity(visibleRows.count)
        for (offset, torrent) in visibleRows.enumerated() {
            visibleIndexByID[torrent.id] = offset
        }
        visibleIDs = Set(visibleIndexByID.keys)
    }

    private func mergeSortedRows(
        _ existingRows: [TorrentSummary],
        _ changedRows: [TorrentSummary],
        sortOrder: [KeyPathComparator<TorrentSummary>]
    ) -> [TorrentSummary] {
        var result: [TorrentSummary] = []
        result.reserveCapacity(existingRows.count + changedRows.count)
        var existingIndex = 0
        var changedIndex = 0
        while existingIndex < existingRows.count, changedIndex < changedRows.count {
            if TorrentSorting.areInIncreasingOrder(
                existingRows[existingIndex],
                changedRows[changedIndex],
                using: sortOrder
            ) {
                result.append(existingRows[existingIndex])
                existingIndex += 1
            } else {
                result.append(changedRows[changedIndex])
                changedIndex += 1
            }
        }
        if existingIndex < existingRows.count {
            result.append(contentsOf: existingRows[existingIndex...])
        }
        if changedIndex < changedRows.count {
            result.append(contentsOf: changedRows[changedIndex...])
        }
        return result
    }

    /// Accumulate only changed contributions, then mutate each facet value once
    /// for the whole batch. Unchanged facets never touch their sorted arrays.
    private struct FilterCountChanges {
        var statuses: [TorrentFilterStatus: Int] = [:]
        var paths: [String: Int] = [:]
        var trackers: [String: Int] = [:]
        var labels: [String: Int] = [:]

        mutating func include(previous: TorrentSummary?, current: TorrentSummary?, filterEngine: TorrentFilterEngine) {
            for status in TorrentFilterStatus.allCases {
                let oldMatch = previous.map { filterEngine.matches($0, status: status) } ?? false
                let newMatch = current.map { filterEngine.matches($0, status: status) } ?? false
                if oldMatch != newMatch {
                    statuses[status, default: 0] += newMatch ? 1 : -1
                }
            }
            Self.include(previous: previous?.downloadDir, current: current?.downloadDir, in: &paths)
            Self.include(previous: previous?.trackerHost, current: current?.trackerHost, in: &trackers)
            if previous?.labels != current?.labels {
                for label in previous?.labels ?? [] where !label.isEmpty {
                    labels[label, default: 0] -= 1
                }
                for label in current?.labels ?? [] where !label.isEmpty {
                    labels[label, default: 0] += 1
                }
            }
        }

        private static func include(previous: String?, current: String?, in changes: inout [String: Int]) {
            guard previous != current else { return }
            if let previous, !previous.isEmpty {
                changes[previous, default: 0] -= 1
            }
            if let current, !current.isEmpty {
                changes[current, default: 0] += 1
            }
        }
    }

    private static func applyCountChanges(_ changes: [String: Int], to counts: inout [TorrentFilterCount]) -> Int {
        var mutationCount = 0
        for (value, delta) in changes where delta != 0 {
            adjustCount(&counts, value: value, by: delta)
            mutationCount += 1
        }
        return mutationCount
    }

    private static func adjustCount(
        _ counts: inout [TorrentFilterCount],
        value: String,
        by delta: Int
    ) {
        guard delta != 0 else { return }
        let index = countInsertionIndex(for: value, in: counts)
        if index < counts.count, counts[index].value == value {
            let nextCount = counts[index].count + delta
            if nextCount > 0 {
                counts[index].count = nextCount
            } else {
                counts.remove(at: index)
            }
        } else if delta > 0 {
            counts.insert(TorrentFilterCount(value: value, count: delta), at: index)
        }
    }

    private static func countInsertionIndex(
        for value: String,
        in counts: [TorrentFilterCount]
    ) -> Int {
        var lowerBound = 0
        var upperBound = counts.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if countValuePrecedes(counts[middle].value, value) {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func countValuePrecedes(_ lhs: String, _ rhs: String) -> Bool {
        let comparison = lhs.localizedCaseInsensitiveCompare(rhs)
        if comparison == .orderedSame {
            return lhs < rhs
        }
        return comparison == .orderedAscending
    }

    private func orderedRows(
        for ids: Set<TorrentSummary.ID>,
        using orderByID: [TorrentSummary.ID: Int]
    ) -> [TorrentSummary] {
        let indexedRows: [(offset: Int, row: TorrentSummary)] = ids.compactMap { id in
            guard let row = rowsByID[id], let offset = orderByID[id] else { return nil }
            return (offset: offset, row: row)
        }
        return indexedRows
            .sorted { $0.offset < $1.offset }
            .map(\.row)
    }

    private static func saturatedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? .max : result.partialValue
    }

    private static func saturatedSubtract(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard rhs > 0 else { return lhs }
        return max(0, lhs - min(lhs, rhs))
    }
}

extension TorrentListSummary {
    init(
        filteredCount: Int,
        totalCount: Int,
        selectedCount: Int,
        selectedSize: Int64,
        filteredSize: Int64,
        downloadSpeed: Int64,
        uploadSpeed: Int64,
        freeSpace: Int64?
    ) {
        self.filteredCount = filteredCount
        self.totalCount = totalCount
        self.selectedCount = selectedCount
        self.selectedSize = selectedSize
        self.filteredSize = filteredSize
        self.downloadSpeed = downloadSpeed
        self.uploadSpeed = uploadSpeed
        self.freeSpace = freeSpace
    }
}
