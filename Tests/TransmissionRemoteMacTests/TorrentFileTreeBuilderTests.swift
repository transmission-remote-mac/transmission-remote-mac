// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentFileTreeBuilderTests: XCTestCase {
    func testTreeUsesDeterministicFolderFirstNameOrderAndStableIDs() throws {
        let tree = TorrentFileNode.tree(from: [
            file(id: 0, path: "", name: "Beta.txt"),
            file(id: 1, path: "Zulu", name: "z.txt"),
            file(id: 2, path: "alpha", name: "a.txt"),
            file(id: 3, path: "", name: "Apple.txt")
        ])

        XCTAssertEqual(tree.map(\.id), [
            "folder-alpha",
            "folder-Zulu",
            "file-3",
            "file-0"
        ])
        XCTAssertEqual(tree.map(\.name), ["alpha", "Zulu", "Apple.txt", "Beta.txt"])
        XCTAssertEqual(try XCTUnwrap(tree.first).fileIndexes, [2])
        XCTAssertEqual(try XCTUnwrap(tree.dropFirst().first).fileIndexes, [1])
    }

    func testTreePreservesNestedFolderIDsAggregatesAndFileOrder() throws {
        let tree = TorrentFileNode.tree(from: [
            file(id: 7, path: "Series/Season 2", name: "Episode 2.mkv", length: 200, completed: 50),
            file(id: 3, path: "Series/Season 1", name: "Episode 1.mkv", length: 100, completed: 100),
            file(id: 5, path: "Series/Season 1", name: "Episode 2.mkv", length: 150, completed: 75)
        ])

        let series = try XCTUnwrap(tree.first)
        XCTAssertEqual(series.id, "folder-Series")
        XCTAssertEqual(series.length, 450)
        XCTAssertEqual(series.bytesCompleted, 225)
        XCTAssertEqual(series.fileIndexes, [3, 5, 7])
        XCTAssertEqual(series.children?.map(\.id), [
            "folder-Series/Season 1",
            "folder-Series/Season 2"
        ])
        XCTAssertEqual(series.children?.first?.children?.map(\.id), ["file-3", "file-5"])
    }

    func testTreeBuildsTenThousandSiblingFilesWithUniqueStableIDs() {
        let files = (0..<10_000).map { index in
            file(id: index, path: "Large", name: "File \(index).bin")
        }

        let tree = TorrentFileNode.tree(from: files)

        XCTAssertEqual(tree.map(\.id), ["folder-Large"])
        XCTAssertEqual(tree.first?.children?.count, 10_000)
        XCTAssertEqual(Set(tree.first?.children?.map(\.id) ?? []).count, 10_000)
        XCTAssertEqual(tree.first?.fileIndexes, Array(0..<10_000))
    }

    func testFolderAggregatesSaturateInsteadOfOverflowing() throws {
        let tree = TorrentFileNode.tree(from: [
            file(id: 0, path: "Large", name: "one.bin", length: Int64.max, completed: Int64.max),
            file(id: 1, path: "Large", name: "two.bin", length: Int64.max, completed: Int64.max),
        ])

        let folder = try XCTUnwrap(tree.first)
        XCTAssertEqual(folder.length, Int64.max)
        XCTAssertEqual(folder.bytesCompleted, Int64.max)
    }

    private func file(
        id: Int,
        path: String,
        name: String,
        length: Int64 = 1,
        completed: Int64 = 0
    ) -> TorrentFile {
        TorrentFile(
            id: id,
            path: path,
            name: name,
            length: length,
            bytesCompleted: completed,
            wanted: true,
            priority: 0
        )
    }
}
