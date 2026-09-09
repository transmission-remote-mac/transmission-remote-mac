// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentPathRenameTests: XCTestCase {
    func testFileRequestCapturesStableIdentityAndNormalizesInput() throws {
        let request = try makeRequest(
            torrentHash: "  ABCDEF0123456789ABCDEF0123456789ABCDEF01  ",
            nodeID: "file-7",
            nodeKind: .file(index: 7),
            oldRelativePath: "Series/Pilot.mkv",
            originalBasename: "Pilot.mkv",
            newBasename: "  Pilot Remastered.mkv  "
        )

        XCTAssertEqual(request.torrentHash, "abcdef0123456789abcdef0123456789abcdef01")
        XCTAssertEqual(request.torrentID, 42)
        XCTAssertEqual(request.owner, owner)
        XCTAssertEqual(request.node.id, "file-7")
        XCTAssertEqual(request.node.kind, .file(index: 7))
        XCTAssertEqual(request.node.relativePath, "Series/Pilot.mkv")
        XCTAssertEqual(request.node.basename, "Pilot.mkv")
        XCTAssertEqual(request.newBasename, "Pilot Remastered.mkv")
    }

    func testNestedAndRootFolderPathsAreAcceptedExactly() throws {
        let nested = try makeRequest(
            nodeID: "folder-Series/Season 1",
            nodeKind: .folder,
            oldRelativePath: "Series/Season 1",
            originalBasename: "Season 1",
            newBasename: "Season One"
        )
        let root = try makeRequest(
            nodeID: "folder-Series",
            nodeKind: .folder,
            oldRelativePath: "Series",
            originalBasename: "Series",
            newBasename: "Complete Series"
        )

        XCTAssertEqual(nested.node.relativePath, "Series/Season 1")
        XCTAssertEqual(nested.newBasename, "Season One")
        XCTAssertEqual(root.node.relativePath, "Series")
        XCTAssertEqual(root.newBasename, "Complete Series")
    }

    func testFileTreeNodeOverloadPreservesExactFileAndFolderIdentity() throws {
        let fileNode = TorrentFileNode(
            id: "file-7",
            kind: .file(7),
            name: "Pilot.mkv",
            path: "Series/Season 1",
            length: 100,
            bytesCompleted: 50,
            wanted: .wanted,
            priority: .normal,
            children: nil
        )
        let fileRequest = try TorrentPathRenameValidator.request(
            torrentHash: "abcdef0123456789abcdef0123456789abcdef01",
            torrentID: 42,
            owner: owner,
            node: fileNode,
            newBasename: "Pilot Remastered.mkv"
        )

        XCTAssertEqual(fileRequest.node.kind, .file(index: 7))
        XCTAssertEqual(fileRequest.node.relativePath, "Series/Season 1/Pilot.mkv")

        let folderNode = TorrentFileNode(
            id: "folder-Series/Season 1",
            kind: .folder,
            name: "Season 1",
            path: "Series",
            length: 100,
            bytesCompleted: 50,
            wanted: .wanted,
            priority: .normal,
            children: [fileNode]
        )
        let folderRequest = try TorrentPathRenameValidator.request(
            torrentHash: "abcdef0123456789abcdef0123456789abcdef01",
            torrentID: 42,
            owner: owner,
            node: folderNode,
            newBasename: "Season One"
        )

        XCTAssertEqual(folderRequest.node.kind, .folder)
        XCTAssertEqual(folderRequest.node.relativePath, "Series/Season 1")
    }

    func testUnchangedAndReservedNamesAreRejectedAfterTrimming() throws {
        XCTAssertThrowsError(try makeRequest(newBasename: "  Pilot.mkv  ")) {
            XCTAssertEqual($0 as? TorrentPathRenameValidationError, .unchangedName)
        }
        for name in ["", "   ", ".", ".."] {
            XCTAssertThrowsError(try makeRequest(newBasename: name)) { error in
                let validationError = error as? TorrentPathRenameValidationError
                if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    XCTAssertEqual(validationError, .emptyName)
                } else {
                    XCTAssertEqual(validationError, .reservedName(name))
                }
            }
        }
    }

    func testPathSeparatorsNullAndUnicodeControlsAreRejectedWithoutReplacement() throws {
        let cases: [(String, TorrentPathRenameValidationError)] = [
            ("Season/Pilot.mkv", .containsPathSeparator),
            ("Season\\Pilot.mkv", .containsPathSeparator),
            ("Pilot\0.mkv", .containsNull),
            ("Pilot\u{0007}.mkv", .containsControlCharacter),
            ("Pilot\u{0085}.mkv", .containsControlCharacter),
            ("Pilot.mkv\n", .containsControlCharacter)
        ]

        for (name, expectedError) in cases {
            XCTAssertThrowsError(try makeRequest(newBasename: name)) {
                XCTAssertEqual($0 as? TorrentPathRenameValidationError, expectedError)
            }
        }
    }

    func testInvalidOrMismatchedCapturedNodeDataIsRejected() throws {
        XCTAssertThrowsError(try makeRequest(nodeID: " file-7 ")) {
            XCTAssertEqual($0 as? TorrentPathRenameValidationError, .invalidNodeIdentity)
        }
        XCTAssertThrowsError(try makeRequest(nodeKind: .file(index: -1))) {
            XCTAssertEqual($0 as? TorrentPathRenameValidationError, .invalidFileIndex)
        }
        for path in ["", "/Series/Pilot.mkv", "Series/Pilot.mkv/", "Series//Pilot.mkv", "Series/../Pilot.mkv", "Series\\Pilot.mkv"] {
            XCTAssertThrowsError(try makeRequest(oldRelativePath: path)) {
                XCTAssertEqual($0 as? TorrentPathRenameValidationError, .invalidOldPath)
            }
        }
        XCTAssertThrowsError(try makeRequest(originalBasename: "Other.mkv")) {
            XCTAssertEqual(
                $0 as? TorrentPathRenameValidationError,
                .nodeBasenameMismatch(expected: "Other.mkv", actual: "Pilot.mkv")
            )
        }
    }

    func testCurrentNodeMustExactlyMatchCapturedNode() throws {
        let request = try makeRequest()
        XCTAssertNoThrow(try TorrentPathRenameValidator.validateCurrentNode(request.node, for: request))

        let staleNode = TorrentPathRenameNode(
            id: request.node.id,
            kind: request.node.kind,
            relativePath: "Series/Pilot-Renamed.mkv",
            basename: "Pilot-Renamed.mkv"
        )
        XCTAssertThrowsError(try TorrentPathRenameValidator.validateCurrentNode(staleNode, for: request)) {
            XCTAssertEqual($0 as? TorrentPathRenameValidationError, .staleNode)
        }
    }

    func testTorrentHashNormalizationAndRejectionAreDeterministic() throws {
        XCTAssertEqual(
            try TorrentPathRenameValidator.normalizeTorrentHash(
                " FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF\n"
            ),
            "ffffffffffffffffffffffffffffffffffffffff"
        )

        for hash in [
            "",
            "abc",
            "gggggggggggggggggggggggggggggggggggggggg",
            "fffffffffffffffffffffffffffffffffffffffé",
            "fffffffffffffffffffffffffffffffffffffffff"
        ] {
            XCTAssertThrowsError(try TorrentPathRenameValidator.normalizeTorrentHash(hash)) {
                XCTAssertEqual($0 as? TorrentPathRenameValidationError, .invalidTorrentHash)
            }
        }
    }

    func testTorrentIDMustRemainAValidCapturedLocalIdentifier() throws {
        XCTAssertThrowsError(try makeRequest(torrentID: 0)) {
            XCTAssertEqual($0 as? TorrentPathRenameValidationError, .invalidTorrentID)
        }
    }

    private let owner = TorrentPathRenameOwner(
        connectionToken: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
        profileID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
        selectionRevision: 12,
        paneRevision: 34,
        filesRevision: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
    )

    private func makeRequest(
        torrentHash: String = "abcdef0123456789abcdef0123456789abcdef01",
        torrentID: Int = 42,
        nodeID: String = "file-7",
        nodeKind: TorrentPathRenameNodeKind = .file(index: 7),
        oldRelativePath: String = "Series/Pilot.mkv",
        originalBasename: String = "Pilot.mkv",
        newBasename: String = "Pilot Remastered.mkv"
    ) throws -> TorrentPathRenameRequest {
        try TorrentPathRenameValidator.request(
            torrentHash: torrentHash,
            torrentID: torrentID,
            owner: owner,
            nodeID: nodeID,
            nodeKind: nodeKind,
            oldRelativePath: oldRelativePath,
            originalBasename: originalBasename,
            newBasename: newBasename
        )
    }
}
