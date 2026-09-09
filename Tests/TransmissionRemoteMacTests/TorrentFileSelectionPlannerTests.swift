// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentFileSelectionPlannerTests: XCTestCase {
    func testSelectionOutputsFollowStableTreeDisplayOrder() {
        let tree = sampleTree()
        let planner = TorrentFileSelectionPlanner(tree: tree)
        let selection: Set<TorrentFileNode.ID> = [
            "file-2",
            "folder-Series/Season 1",
            "folder-Series"
        ]

        XCTAssertEqual(
            planner.nodes(in: selection).map(\.id),
            ["folder-Series", "folder-Series/Season 1", "file-2"]
        )
        XCTAssertEqual(
            planner.relativePaths(in: selection),
            ["Series", "Series/Season 1", "Loose.txt"]
        )
    }

    func testSelectedDescendantsAreDeduplicatedInFileDisplayOrder() {
        let planner = TorrentFileSelectionPlanner(tree: sampleTree())
        let selection: Set<TorrentFileNode.ID> = [
            "folder-Series",
            "folder-Series/Season 1",
            "file-0",
            "file-2"
        ]

        XCTAssertEqual(planner.fileIndexes(in: selection), [0, 1, 2])
    }

    func testSelectionPruningAndSelectAllUseOnlyCurrentTreeIDs() {
        let planner = TorrentFileSelectionPlanner(tree: sampleTree())

        XCTAssertEqual(
            planner.pruned(["folder-Series", "file-404"]),
            ["folder-Series"]
        )
        XCTAssertEqual(
            planner.allNodeIDs,
            [
                "folder-Series",
                "file-0",
                "folder-Series/Season 1",
                "file-1",
                "file-2"
            ]
        )
    }

    func testContextActionUsesSelectionOnlyWhenClickedRowIsSelected() {
        let planner = TorrentFileSelectionPlanner(tree: sampleTree())
        let selection: Set<TorrentFileNode.ID> = ["folder-Series", "file-2"]

        XCTAssertEqual(
            planner.actionSelection(for: "folder-Series", currentSelection: selection),
            selection
        )
        XCTAssertEqual(
            planner.actionSelection(for: "file-0", currentSelection: selection),
            ["file-0"]
        )
        XCTAssertTrue(
            planner.actionSelection(for: "file-404", currentSelection: selection).isEmpty
        )
    }

    func testNodesResolveSelectedIDsInDisplayOrderAndIgnoreUnknownIDs() {
        let planner = TorrentFileSelectionPlanner(tree: sampleTree())

        XCTAssertEqual(
            planner.nodes(in: ["file-2", "file-404", "folder-Series", "file-1"]).map(\.id),
            ["folder-Series", "file-1", "file-2"]
        )
        XCTAssertTrue(planner.nodes(in: ["file-404"]).isEmpty)
    }

    func testLargeFolderUnionKeepsTenThousandFilesUnique() {
        let files = (0..<10_000).map { index in
            fileNode(id: index, path: "Large", name: "File-\(index)")
        }
        let folder = folderNode(id: "folder-Large", path: "", name: "Large", children: files)
        let planner = TorrentFileSelectionPlanner(tree: [folder])
        let selection = Set([folder.id] + files.prefix(5_000).map(\.id))

        XCTAssertEqual(planner.fileIndexes(in: selection), Array(0..<10_000))
    }

    private func sampleTree() -> [TorrentFileNode] {
        let episode = fileNode(id: 0, path: "Series", name: "Pilot.mkv")
        let finale = fileNode(id: 1, path: "Series/Season 1", name: "Finale.mkv")
        let season = folderNode(
            id: "folder-Series/Season 1",
            path: "Series",
            name: "Season 1",
            children: [finale]
        )
        let series = folderNode(
            id: "folder-Series",
            path: "",
            name: "Series",
            children: [episode, season]
        )
        return [series, fileNode(id: 2, path: "", name: "Loose.txt")]
    }

    private func fileNode(id: Int, path: String, name: String) -> TorrentFileNode {
        TorrentFileNode(
            id: "file-\(id)",
            kind: .file(id),
            name: name,
            path: path,
            length: 10,
            bytesCompleted: 0,
            wanted: .wanted,
            priority: .normal,
            children: nil
        )
    }

    private func folderNode(
        id: String,
        path: String,
        name: String,
        children: [TorrentFileNode]
    ) -> TorrentFileNode {
        TorrentFileNode(
            id: id,
            kind: .folder,
            name: name,
            path: path,
            length: Int64(children.count * 10),
            bytesCompleted: 0,
            wanted: .wanted,
            priority: .normal,
            children: children
        )
    }
}
