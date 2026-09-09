// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentFileSelectionPlanner: Sendable {
    private struct Row: Sendable {
        var node: TorrentFileNode
        var descendantFileOffsets: Range<Int>
    }

    private var rows: [Row]
    private var rowOffsetsByID: [TorrentFileNode.ID: Int]
    private var fileIndexesInDisplayOrder: [Int]
    private(set) var allNodeIDs: Set<TorrentFileNode.ID>

    init(tree: [TorrentFileNode] = []) {
        let buildResult = Self.buildRows(from: tree)
        rows = buildResult.rows
        rowOffsetsByID = Dictionary(
            uniqueKeysWithValues: buildResult.rows.enumerated().map { ($1.node.id, $0) }
        )
        fileIndexesInDisplayOrder = buildResult.fileIndexesInDisplayOrder
        allNodeIDs = Set(rowOffsetsByID.keys)
    }

    func pruned(_ selection: Set<TorrentFileNode.ID>) -> Set<TorrentFileNode.ID> {
        selection.intersection(allNodeIDs)
    }

    func actionSelection(
        for nodeID: TorrentFileNode.ID,
        currentSelection: Set<TorrentFileNode.ID>
    ) -> Set<TorrentFileNode.ID> {
        guard allNodeIDs.contains(nodeID) else { return [] }
        return currentSelection.contains(nodeID) ? pruned(currentSelection) : [nodeID]
    }

    func nodes(in selection: Set<TorrentFileNode.ID>) -> [TorrentFileNode] {
        guard !selection.isEmpty else { return [] }
        return selection
            .compactMap { rowOffsetsByID[$0] }
            .sorted()
            .map { rows[$0].node }
    }

    /// Predicate-only queries do not need display-order sorting or a node array.
    func allNodes(in selection: Set<TorrentFileNode.ID>, satisfy predicate: (TorrentFileNode) -> Bool) -> Bool {
        selection.allSatisfy { id in
            guard let offset = rowOffsetsByID[id] else { return false }
            return predicate(rows[offset].node)
        }
    }

    func relativePaths(in selection: Set<TorrentFileNode.ID>) -> [String] {
        nodes(in: selection).map(Self.relativePath)
    }

    func fileIndexes(in selection: Set<TorrentFileNode.ID>) -> [Int] {
        guard !selection.isEmpty else { return [] }

        let ranges = selection.compactMap { id in
            rowOffsetsByID[id].map { rows[$0].descendantFileOffsets }
        }
        guard !ranges.isEmpty else { return [] }

        let sortedRanges = ranges.sorted {
            if $0.lowerBound == $1.lowerBound {
                return $0.upperBound < $1.upperBound
            }
            return $0.lowerBound < $1.lowerBound
        }
        var mergedRanges: [Range<Int>] = []
        mergedRanges.reserveCapacity(sortedRanges.count)
        for range in sortedRanges where !range.isEmpty {
            guard let last = mergedRanges.last else {
                mergedRanges.append(range)
                continue
            }
            if range.lowerBound <= last.upperBound {
                mergedRanges[mergedRanges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                mergedRanges.append(range)
            }
        }

        var result: [Int] = []
        result.reserveCapacity(mergedRanges.reduce(0) { $0 + $1.count })
        for range in mergedRanges {
            result.append(contentsOf: fileIndexesInDisplayOrder[range])
        }
        return result
    }

    private static func relativePath(_ node: TorrentFileNode) -> String {
        node.path.isEmpty ? node.name : "\(node.path)/\(node.name)"
    }

    private static func buildRows(
        from tree: [TorrentFileNode]
    ) -> (rows: [Row], fileIndexesInDisplayOrder: [Int]) {
        var rows: [Row] = []
        var fileIndexesInDisplayOrder: [Int] = []

        func append(_ nodes: [TorrentFileNode]) {
            for node in nodes {
                let rowOffset = rows.count
                let firstFileOffset = fileIndexesInDisplayOrder.count
                rows.append(
                    Row(
                        node: node,
                        descendantFileOffsets: firstFileOffset..<firstFileOffset
                    )
                )

                switch node.kind {
                case .file(let fileIndex):
                    fileIndexesInDisplayOrder.append(fileIndex)
                case .folder:
                    append(node.children ?? [])
                }

                rows[rowOffset].descendantFileOffsets = firstFileOffset..<fileIndexesInDisplayOrder.count
            }
        }

        append(tree)
        return (rows, fileIndexesInDisplayOrder)
    }
}
