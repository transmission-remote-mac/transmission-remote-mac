// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentFilePrioritySortingTests: XCTestCase {
    func testTypedAndProjectionOrderingHandlesExtremeUnsupportedPriorities() {
        let expected: [TorrentFilePriorityState] = [
            .high, .normal, .low, .mixed, .skipped, .unknown,
            .other(Int.min), .other(-2), .other(2), .other(Int.max),
        ]
        let input = Array(expected.reversed())
        XCTAssertEqual(input.sorted(), expected)
        XCTAssertEqual(input.sorted(by: >), Array(expected.reversed()))

        let nodes = input.enumerated().map { index, priority in
            node(id: "node-\(index)", priority: priority)
        }
        let orders: [(SecondaryTableSortDirection, SortOrder)] = [
            (.ascending, .forward), (.descending, .reverse),
        ]
        for (direction, order) in orders {
            let expectedPriorities = direction == .ascending ? expected : Array(expected.reversed())
            let comparator = KeyPathComparator(\TorrentFileNode.priority, order: order)
            XCTAssertEqual(nodes.sorted(using: [comparator]).map(\.priority), expectedPriorities)
            XCTAssertEqual(
                SecondaryTableSorting.files(
                    nodes,
                    by: SecondaryTableSortPreference(
                        columnID: SecondaryTableColumnID.Files.priority,
                        direction: direction
                    )
                ).map(\.priority),
                expectedPriorities
            )
        }
    }

    func testEqualPriorityProjectionKeepsAscendingIDTiesInBothDirections() {
        for priority in [TorrentFilePriorityState.high, .other(Int.min), .other(Int.max)] {
            let nodes = [node(id: "b", priority: priority), node(id: "a", priority: priority)]
            XCTAssertEqual(
                KeyPathComparator(\TorrentFileNode.priority).compare(nodes[0], nodes[1]),
                .orderedSame
            )
            for direction in [SecondaryTableSortDirection.ascending, .descending] {
                XCTAssertEqual(
                    SecondaryTableSorting.files(
                        nodes,
                        by: SecondaryTableSortPreference(
                            columnID: SecondaryTableColumnID.Files.priority,
                            direction: direction
                        )
                    ).map(\.id),
                    ["a", "b"]
                )
            }
        }
    }

    private func node(id: String, priority: TorrentFilePriorityState) -> TorrentFileNode {
        TorrentFileNode(
            id: id,
            kind: .file(0),
            name: id,
            path: "",
            length: 1,
            bytesCompleted: 0,
            wanted: .wanted,
            priority: priority,
            children: nil
        )
    }
}
