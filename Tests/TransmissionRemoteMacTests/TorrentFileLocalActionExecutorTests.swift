// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentFileLocalActionExecutorTests: XCTestCase {
    func testMappedFileActionsResolveTheSelectedFilePath() throws {
        let actions = RecordingTorrentFileLocalActions()
        let executor = TorrentFileLocalActionExecutor(
            profile: try remoteProfile(
                pathMappings: [
                    PathMapping(
                        remotePathPrefix: "/srv/downloads",
                        localPathPrefix: "/Users/tester/Media"
                    )
                ]
            ),
            localFileActionService: actions
        )
        let node = fileNode(path: "Series/Season 1", name: "Episode.mkv")

        try executor.perform(.open, downloadDirectory: "/srv/downloads", node: node)
        try executor.perform(.reveal, downloadDirectory: "/srv/downloads", node: node)
        try executor.perform(.copyPath, downloadDirectory: "/srv/downloads", node: node)

        let expectedPath = "/Users/tester/Media/Series/Season 1/Episode.mkv"
        XCTAssertEqual(actions.openedPaths, [[expectedPath]])
        XCTAssertEqual(actions.revealedPaths, [[expectedPath]])
        XCTAssertEqual(actions.copiedPaths, [[expectedPath]])
    }

    func testFolderActionTargetsTheFolderRatherThanItsFirstChild() throws {
        let actions = RecordingTorrentFileLocalActions()
        let executor = TorrentFileLocalActionExecutor(
            profile: try remoteProfile(
                pathMappings: [
                    PathMapping(
                        remotePathPrefix: "/srv/downloads",
                        localPathPrefix: "/Users/tester/Media"
                    )
                ]
            ),
            localFileActionService: actions
        )
        let node = folderNode(path: "Series", name: "Season 1")

        try executor.perform(.reveal, downloadDirectory: "/srv/downloads", node: node)

        XCTAssertEqual(actions.revealedPaths, [[
            "/Users/tester/Media/Series/Season 1"
        ]])
    }

    func testRemoteUnmappedFileActionsRemainUnavailable() throws {
        let actions = RecordingTorrentFileLocalActions()
        let executor = TorrentFileLocalActionExecutor(
            profile: try remoteProfile(pathMappings: []),
            localFileActionService: actions
        )
        let node = fileNode(path: "Series", name: "Episode.mkv")

        XCTAssertThrowsError(
            try executor.perform(.open, downloadDirectory: "/srv/downloads", node: node)
        ) { error in
            XCTAssertEqual(
                error as? PathMappingResolutionError,
                .noMappingForNonLocalPath("/srv/downloads")
            )
        }
        XCTAssertTrue(actions.openedPaths.isEmpty)
        XCTAssertTrue(actions.revealedPaths.isEmpty)
        XCTAssertTrue(actions.copiedPaths.isEmpty)
    }

    func testLoopbackProfileCanUseAbsoluteDaemonFilePathWithoutMapping() throws {
        let actions = RecordingTorrentFileLocalActions()
        let profile = try ConnectionProfile.validated(
            name: "Local",
            host: "127.0.0.1"
        )
        let executor = TorrentFileLocalActionExecutor(
            profile: profile,
            localFileActionService: actions
        )
        let node = fileNode(path: "", name: "Movie.mkv")

        try executor.perform(.copyPath, downloadDirectory: "/Users/tester/Downloads", node: node)

        XCTAssertEqual(actions.copiedPaths, [["/Users/tester/Downloads/Movie.mkv"]])
    }

    func testLoopbackProfileRejectsDotDotTraversalOutsideDownloadDirectory() throws {
        let actions = RecordingTorrentFileLocalActions()
        let profile = try ConnectionProfile.validated(
            name: "Local",
            host: "localhost"
        )
        let executor = TorrentFileLocalActionExecutor(
            profile: profile,
            localFileActionService: actions
        )
        let node = fileNode(path: "../Secrets", name: "token.txt")

        XCTAssertThrowsError(
            try executor.perform(.copyPath, downloadDirectory: "/Users/tester/Downloads", node: node)
        ) { error in
            XCTAssertEqual(
                error as? TorrentFileLocalActionError,
                .invalidRelativePath("../Secrets/token.txt")
            )
        }
        XCTAssertTrue(actions.copiedPaths.isEmpty)
    }

    func testRootMappingRejectsAbsoluteAndEmptyRelativeComponents() throws {
        let actions = RecordingTorrentFileLocalActions()
        let executor = TorrentFileLocalActionExecutor(
            profile: try remoteProfile(
                pathMappings: [
                    PathMapping(
                        remotePathPrefix: "/",
                        localPathPrefix: "/Users/tester/Remote"
                    )
                ]
            ),
            localFileActionService: actions
        )
        let absoluteNode = fileNode(path: "/etc", name: "hosts")
        let emptyComponentNode = fileNode(path: "Series//Season 1", name: "Episode.mkv")
        let dotComponentNode = fileNode(path: "Series/.", name: "Episode.mkv")

        XCTAssertThrowsError(
            try executor.perform(.open, downloadDirectory: "/downloads", node: absoluteNode)
        ) { error in
            XCTAssertEqual(
                error as? TorrentFileLocalActionError,
                .invalidRelativePath("/etc/hosts")
            )
        }
        XCTAssertThrowsError(
            try executor.perform(.reveal, downloadDirectory: "/downloads", node: emptyComponentNode)
        ) { error in
            XCTAssertEqual(
                error as? TorrentFileLocalActionError,
                .invalidRelativePath("Series//Season 1/Episode.mkv")
            )
        }
        XCTAssertThrowsError(
            try executor.perform(.copyPath, downloadDirectory: "/downloads", node: dotComponentNode)
        ) { error in
            XCTAssertEqual(
                error as? TorrentFileLocalActionError,
                .invalidRelativePath("Series/./Episode.mkv")
            )
        }
        XCTAssertTrue(actions.openedPaths.isEmpty)
        XCTAssertTrue(actions.revealedPaths.isEmpty)
        XCTAssertTrue(actions.copiedPaths.isEmpty)
    }

    func testRootMappingRejectsSymlinkEscapeOutsideResolvedDownloadRoot() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let mappedRoot = temporaryRoot.appendingPathComponent("mapped", isDirectory: true)
        let localDownloadRoot = mappedRoot
            .appendingPathComponent("downloads", isDirectory: true)
            .appendingPathComponent("current", isDirectory: true)
        let outsideRoot = mappedRoot.appendingPathComponent("outside", isDirectory: true)
        let escapeLink = localDownloadRoot.appendingPathComponent("escape")
        try fileManager.createDirectory(
            at: localDownloadRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: outsideRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createSymbolicLink(
            at: escapeLink,
            withDestinationURL: outsideRoot
        )
        defer {
            try? fileManager.removeItem(at: temporaryRoot)
        }

        let actions = RecordingTorrentFileLocalActions()
        let executor = TorrentFileLocalActionExecutor(
            profile: try remoteProfile(
                pathMappings: [
                    PathMapping(
                        remotePathPrefix: "/",
                        localPathPrefix: mappedRoot.path
                    )
                ]
            ),
            localFileActionService: actions
        )
        let node = fileNode(path: "escape", name: "private.dat")
        let escapedPath = outsideRoot.appendingPathComponent("private.dat").path

        XCTAssertThrowsError(
            try executor.perform(.copyPath, downloadDirectory: "/downloads/current", node: node)
        ) { error in
            XCTAssertEqual(
                error as? TorrentFileLocalActionError,
                .outsideDownloadDirectory(escapedPath)
            )
        }
        XCTAssertTrue(actions.copiedPaths.isEmpty)
    }

    func testCopyPathsPreservesDisplayOrderAndUsesMappedLocalPaths() throws {
        let actions = RecordingTorrentFileLocalActions()
        let executor = TorrentFileLocalActionExecutor(
            profile: try remoteProfile(
                pathMappings: [
                    PathMapping(
                        remotePathPrefix: "/srv/downloads",
                        localPathPrefix: "/Users/tester/Media"
                    )
                ]
            ),
            localFileActionService: actions
        )
        let nodes = [
            folderNode(path: "Series", name: "Season 1"),
            fileNode(path: "Series/Season 1", name: "Finale.mkv")
        ]

        try executor.copyPaths(downloadDirectory: "/srv/downloads", nodes: nodes)

        XCTAssertEqual(actions.copiedPaths, [[
            "/Users/tester/Media/Series/Season 1",
            "/Users/tester/Media/Series/Season 1/Finale.mkv"
        ]])
    }

    func testCopyPathsValidatesEveryNodeBeforeWritingClipboard() throws {
        let actions = RecordingTorrentFileLocalActions()
        let executor = TorrentFileLocalActionExecutor(
            profile: try remoteProfile(
                pathMappings: [
                    PathMapping(
                        remotePathPrefix: "/srv/downloads",
                        localPathPrefix: "/Users/tester/Media"
                    )
                ]
            ),
            localFileActionService: actions
        )
        let nodes = [
            fileNode(path: "Series", name: "Pilot.mkv"),
            fileNode(path: "../Secrets", name: "token.txt")
        ]

        XCTAssertThrowsError(
            try executor.copyPaths(downloadDirectory: "/srv/downloads", nodes: nodes)
        ) { error in
            XCTAssertEqual(
                error as? TorrentFileLocalActionError,
                .invalidRelativePath("../Secrets/token.txt")
            )
        }
        XCTAssertTrue(actions.copiedPaths.isEmpty)
    }

    @MainActor
    func testCachedCapabilityNeverAuthorizesASymlinkChangedBeforeExecution() async throws {
        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = temporary.appendingPathComponent("downloads")
        let child = root.appendingPathComponent("nested")
        let outside = temporary.appendingPathComponent("outside")
        try manager.createDirectory(at: child, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }

        let profile = ConnectionProfile(name: "Local", host: "localhost")
        let node = fileNode(path: "nested", name: "file.bin")
        let planner = TorrentFileSelectionPlanner(tree: [node])
        let identity = try XCTUnwrap(TorrentFilesProjectionIdentity(detail: TorrentDetail(
            id: 1,
            filesSnapshotRevision: TorrentFilesSnapshotRevision()
        )))
        let rootRequest = TorrentFileLocalActionCapabilityRequest(
            identity: identity,
            mapping: TorrentFileLocalActionMapping(profile: profile),
            downloadDirectory: root.path,
            selection: []
        )
        let rootCapability = TorrentFileLocalActionCapability()
        await rootCapability.update(rootRequest, planner: planner)
        XCTAssertTrue(rootCapability.allows(rootRequest))

        let selectionRequest = TorrentFileLocalActionCapabilityRequest(
            identity: identity,
            mapping: rootRequest.mapping,
            downloadDirectory: root.path,
            selection: [node.id]
        )
        let selectionCapability = TorrentFileLocalActionCapability()
        await selectionCapability.update(selectionRequest, planner: planner)
        XCTAssertTrue(selectionCapability.allows(selectionRequest))

        try manager.removeItem(at: child)
        try manager.createSymbolicLink(at: child, withDestinationURL: outside)
        // Both cached enablement and lexical menu eligibility are only hints.
        XCTAssertTrue(rootCapability.allows(rootRequest))
        XCTAssertTrue(selectionCapability.allows(selectionRequest))
        XCTAssertTrue(TorrentFileLocalPathResolver.hasSafeRelativePath(node))
        let actions = RecordingTorrentFileLocalActions()
        let executor = TorrentFileLocalActionExecutor(profile: profile, localFileActionService: actions)
        XCTAssertThrowsError(try executor.copyPaths(downloadDirectory: root.path, nodes: [node]))
        XCTAssertThrowsError(try executor.perform(.open, downloadDirectory: root.path, node: node))
        XCTAssertTrue(actions.copiedPaths.isEmpty)
        XCTAssertTrue(actions.openedPaths.isEmpty)
    }

    private func remoteProfile(pathMappings: [PathMapping]) throws -> ConnectionProfile {
        try ConnectionProfile.validated(
            name: "Remote",
            host: "transmission.example",
            pathMappings: pathMappings
        )
    }

    private func fileNode(path: String, name: String) -> TorrentFileNode {
        TorrentFileNode(
            id: "file-0",
            kind: .file(0),
            name: name,
            path: path,
            length: 100,
            bytesCompleted: 100,
            wanted: .wanted,
            priority: .normal,
            children: nil
        )
    }

    private func folderNode(path: String, name: String) -> TorrentFileNode {
        TorrentFileNode(
            id: "folder-\(path)/\(name)",
            kind: .folder,
            name: name,
            path: path,
            length: 100,
            bytesCompleted: 100,
            wanted: .wanted,
            priority: .normal,
            children: []
        )
    }
}

private final class RecordingTorrentFileLocalActions: LocalFileActionServicing {
    private(set) var copiedPaths: [[String]] = []
    private(set) var revealedPaths: [[String]] = []
    private(set) var openedPaths: [[String]] = []

    func copy(paths: [String]) throws {
        copiedPaths.append(paths)
    }

    func reveal(paths: [String]) throws {
        revealedPaths.append(paths)
    }

    func open(paths: [String]) throws {
        openedPaths.append(paths)
    }
}
