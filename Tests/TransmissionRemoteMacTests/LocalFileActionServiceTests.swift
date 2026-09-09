// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class LocalFileActionServiceTests: XCTestCase {
    func testCopyPreservesResolvedAbsolutePathsAsPlainText() throws {
        let clipboardWriter = RecordingClipboardWriter()
        let service = LocalFileActionService(
            clipboardWriter: clipboardWriter,
            workspaceOpener: RecordingWorkspaceOpener(),
            fileChecker: StubFileChecker(existingPaths: [])
        )
        let paths = ["/Volumes/Media/Movie.mkv ", "/Volumes/Media/Episode.mkv\n"]

        try service.copy(paths: [paths[0], "", paths[1]])

        XCTAssertEqual(clipboardWriter.writtenTexts, [paths.joined(separator: "\n")])
    }

    func testCopyRejectsUnresolvedLocalPathText() {
        let service = LocalFileActionService(
            clipboardWriter: RecordingClipboardWriter(),
            workspaceOpener: RecordingWorkspaceOpener(),
            fileChecker: StubFileChecker(existingPaths: [])
        )

        for path in ["relative/file.mkv", "~/Downloads/File.iso", " /Volumes/Media/Movie.mkv"] {
            XCTAssertThrowsError(try service.copy(paths: [path])) { error in
                XCTAssertEqual(error as? LocalFileActionError, .invalidLocalPath(path))
            }
        }
    }

    func testExecutorPreservesWhitespaceNamedFilesAndDownloadRootsThroughPlatformBoundary() throws {
        let fileManager = FileManager.default
        let mappedRoot = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let downloadRoot = mappedRoot.appendingPathComponent("Downloads \n", isDirectory: true)
        try fileManager.createDirectory(at: downloadRoot, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: mappedRoot) }

        let names = ["Movie.mkv ", "Episode.mkv\n"]
        let nodes = try names.enumerated().map { index, name in
            try Data("selected".utf8).write(to: downloadRoot.appendingPathComponent(name))
            try Data("other sibling".utf8).write(to: downloadRoot.appendingPathComponent(
                name.trimmingCharacters(in: .whitespacesAndNewlines)
            ))
            return TorrentFileNode(
                id: "file-\(index)",
                kind: .file(index),
                name: name,
                path: "",
                length: 8,
                bytesCompleted: 8,
                wanted: .wanted,
                priority: .normal,
                children: nil
            )
        }
        let clipboardWriter = RecordingClipboardWriter()
        let workspaceOpener = RecordingWorkspaceOpener()
        let service = LocalFileActionService(
            clipboardWriter: clipboardWriter,
            workspaceOpener: workspaceOpener,
            fileChecker: fileManager
        )
        let profile = try ConnectionProfile.validated(
            name: "Remote",
            host: "transmission.example",
            pathMappings: [PathMapping(remotePathPrefix: "/srv", localPathPrefix: mappedRoot.path)]
        )
        let executor = TorrentFileLocalActionExecutor(profile: profile, localFileActionService: service)
        let downloadDirectory = "/srv/Downloads \n"
        for node in nodes {
            try executor.perform(.open, downloadDirectory: downloadDirectory, node: node)
            try executor.perform(.reveal, downloadDirectory: downloadDirectory, node: node)
            try executor.perform(.copyPath, downloadDirectory: downloadDirectory, node: node)
        }
        try executor.copyPaths(downloadDirectory: downloadDirectory, nodes: nodes)

        let expectedPaths = names.map { downloadRoot.appendingPathComponent($0).path }
        XCTAssertEqual(workspaceOpener.openedPaths, expectedPaths)
        XCTAssertEqual(workspaceOpener.revealedPaths, expectedPaths.map { [$0] })
        XCTAssertEqual(clipboardWriter.writtenTexts, expectedPaths + [expectedPaths.joined(separator: "\n")])
    }

    func testRevealUsesExistingFileURLs() throws {
        let workspaceOpener = RecordingWorkspaceOpener()
        let service = LocalFileActionService(
            clipboardWriter: RecordingClipboardWriter(),
            workspaceOpener: workspaceOpener,
            fileChecker: StubFileChecker(existingPaths: ["/Volumes/Media/Movie.mkv"])
        )

        try service.reveal(paths: ["/Volumes/Media/Movie.mkv"])

        XCTAssertEqual(workspaceOpener.revealedPaths, [["/Volumes/Media/Movie.mkv"]])
        XCTAssertEqual(workspaceOpener.openedPaths, [])
    }

    func testOpenUsesExistingFileURLs() throws {
        let workspaceOpener = RecordingWorkspaceOpener()
        let service = LocalFileActionService(
            clipboardWriter: RecordingClipboardWriter(),
            workspaceOpener: workspaceOpener,
            fileChecker: StubFileChecker(existingPaths: ["/Volumes/Media/Movie.mkv", "/Volumes/Media/Episode.mkv"])
        )

        try service.open(paths: ["/Volumes/Media/Movie.mkv", "/Volumes/Media/Episode.mkv"])

        XCTAssertEqual(workspaceOpener.openedPaths, ["/Volumes/Media/Movie.mkv", "/Volumes/Media/Episode.mkv"])
        XCTAssertEqual(workspaceOpener.revealedPaths, [])
    }

    func testRevealAndOpenRejectMissingPathsBeforeInvokingWorkspace() {
        let workspaceOpener = RecordingWorkspaceOpener()
        let service = LocalFileActionService(
            clipboardWriter: RecordingClipboardWriter(),
            workspaceOpener: workspaceOpener,
            fileChecker: StubFileChecker(existingPaths: [])
        )

        XCTAssertThrowsError(try service.reveal(paths: ["/Volumes/Media/Missing.mkv"])) { error in
            XCTAssertEqual(error as? LocalFileActionError, .pathMissing("/Volumes/Media/Missing.mkv"))
        }
        XCTAssertThrowsError(try service.open(paths: ["/Volumes/Media/Missing.mkv"])) { error in
            XCTAssertEqual(error as? LocalFileActionError, .pathMissing("/Volumes/Media/Missing.mkv"))
        }
        XCTAssertEqual(workspaceOpener.revealedPaths, [])
        XCTAssertEqual(workspaceOpener.openedPaths, [])
    }

    func testOpenReportsFailedWorkspaceOpen() {
        let workspaceOpener = RecordingWorkspaceOpener()
        workspaceOpener.openResults["/Volumes/Media/Movie.mkv"] = false
        let service = LocalFileActionService(
            clipboardWriter: RecordingClipboardWriter(),
            workspaceOpener: workspaceOpener,
            fileChecker: StubFileChecker(existingPaths: ["/Volumes/Media/Movie.mkv"])
        )

        XCTAssertThrowsError(try service.open(paths: ["/Volumes/Media/Movie.mkv"])) { error in
            XCTAssertEqual(error as? LocalFileActionError, .openFailed("/Volumes/Media/Movie.mkv"))
        }
        XCTAssertEqual(workspaceOpener.openedPaths, ["/Volumes/Media/Movie.mkv"])
    }

    @MainActor
    func testAppStoreCopySelectedLocalPathResolvesThroughSelectedProfileMappings() throws {
        let localFileActions = RecordingLocalFileActionService()
        let store = AppStore(
            profileStore: temporaryProfileStore(),
            localFileActionService: localFileActions,
            downloadCompletionNotifier: NullDownloadCompletionNotifier()
        )
        let profile = try mappedProfile()
        store.profiles = [profile]
        store.selectedProfileID = profile.id
        store.torrents = [
            torrent(id: 2, name: "Beta.mkv", downloadDir: "/srv/downloads/tv"),
            torrent(id: 1, name: "Alpha.mkv", downloadDir: "/srv/downloads/movies")
        ]
        store.selectedTorrentIDs = [1, 2]

        store.copySelectedLocalPath()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(localFileActions.copiedPaths, [[
            "/Users/tester/Media/movies/Alpha.mkv",
            "/Users/tester/Media/tv/Beta.mkv"
        ]])
        XCTAssertEqual(localFileActions.revealedPaths, [])
        XCTAssertEqual(localFileActions.openedPaths, [])
    }

    @MainActor
    func testAppStoreRevealAndOpenSelectedLocalPathUseMappedLocalPath() throws {
        let localFileActions = RecordingLocalFileActionService()
        let store = AppStore(
            profileStore: temporaryProfileStore(),
            localFileActionService: localFileActions,
            downloadCompletionNotifier: NullDownloadCompletionNotifier()
        )
        let profile = try mappedProfile()
        store.profiles = [profile]
        store.selectedProfileID = profile.id
        store.torrents = [
            torrent(id: 1, name: "Movie.mkv", downloadDir: "/srv/downloads/movies")
        ]
        store.selectedTorrentIDs = [1]

        store.revealSelectedInFinder()
        store.openSelectedLocalPath()

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(localFileActions.revealedPaths, [["/Users/tester/Media/movies/Movie.mkv"]])
        XCTAssertEqual(localFileActions.openedPaths, [["/Users/tester/Media/movies/Movie.mkv"]])
        XCTAssertEqual(localFileActions.copiedPaths, [])
    }

    @MainActor
    func testAppStoreDoesNotInvokeLocalActionWhenSelectedPathCannotResolve() throws {
        let localFileActions = RecordingLocalFileActionService()
        let store = AppStore(
            profileStore: temporaryProfileStore(),
            localFileActionService: localFileActions,
            downloadCompletionNotifier: NullDownloadCompletionNotifier()
        )
        let profile = try mappedProfile()
        store.profiles = [profile]
        store.selectedProfileID = profile.id
        store.torrents = [
            torrent(id: 1, name: "Movie.mkv", downloadDir: "relative/downloads")
        ]
        store.selectedTorrentIDs = [1]

        store.openSelectedLocalPath()

        XCTAssertEqual(localFileActions.openedPaths, [])
        XCTAssertEqual(localFileActions.copiedPaths, [])
        XCTAssertEqual(localFileActions.revealedPaths, [])
        XCTAssertEqual(
            store.errorMessage,
            "Unable to resolve local path for Movie.mkv: No local path mapping matches relative/downloads/Movie.mkv. Add a server path mapping first."
        )
    }

    @MainActor
    func testPrimaryTorrentActionOpensCompletedMappedData() async throws {
        let localFileActions = RecordingLocalFileActionService()
        let store = AppStore(
            profileStore: temporaryProfileStore(),
            localFileActionService: localFileActions,
            downloadCompletionNotifier: NullDownloadCompletionNotifier()
        )
        let profile = try mappedProfile()
        store.profiles = [profile]
        store.selectedProfileID = profile.id
        store.torrents = [
            torrent(
                id: 1,
                name: "Movie.mkv",
                downloadDir: "/srv/downloads/movies",
                status: .seeding
            )
        ]

        await store.performPrimaryTorrentAction(in: [1])

        XCTAssertEqual(store.selectedTorrentIDs, [1])
        XCTAssertEqual(localFileActions.openedPaths, [["/Users/tester/Media/movies/Movie.mkv"]])
        XCTAssertNil(store.torrentPropertiesEditor)
        XCTAssertNil(store.errorMessage)
    }

    private func mappedProfile() throws -> ConnectionProfile {
        try ConnectionProfile.validated(
            id: UUID(),
            name: "Mapped",
            host: "transmission.example",
            pathMappings: [
                PathMapping(remotePathPrefix: "/srv/downloads", localPathPrefix: "/Users/tester/Media")
            ]
        )
    }

    private func temporaryProfileStore() -> ConnectionProfileStore {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        return ConnectionProfileStore(fileURL: fileURL, passwordStore: AppStoreTestPasswordStore())
    }

    private func torrent(
        id: Int,
        name: String,
        downloadDir: String,
        status: TorrentStatus = .stopped
    ) -> TorrentSummary {
        TorrentSummary(
            id: id,
            name: name,
            status: status,
            errorString: "",
            trackerError: "",
            globalError: "",
            trackerStatus: "",
            percentDone: 0,
            totalSize: 0,
            sizeWhenDone: 0,
            sizeToDownload: 0,
            leftUntilDone: 0,
            rateDownload: 0,
            rateUpload: 0,
            eta: -1,
            uploadRatio: 0,
            downloadedEver: 0,
            uploadedEver: 0,
            downloadDir: downloadDir,
            bandwidthPriority: 0,
            queuePosition: 0,
            secondsSeeding: 0,
            isPrivate: false,
            isMetadataComplete: true,
            seedsConnected: 0,
            seedsTotal: 0,
            peersConnected: 0,
            peersTotal: 0,
            labels: [],
            trackerHost: "tracker.example",
            addedDate: nil,
            completedDate: nil,
            activityDate: nil
        )
    }
}

private final class RecordingClipboardWriter: LocalFileActionClipboardWriting {
    private(set) var writtenTexts: [String] = []
    var succeeds = true

    func writePlainText(_ text: String) -> Bool {
        writtenTexts.append(text)
        return succeeds
    }
}

private final class RecordingWorkspaceOpener: LocalFileActionWorkspaceOpening {
    private(set) var revealedPaths: [[String]] = []
    private(set) var openedPaths: [String] = []
    var openResults: [String: Bool] = [:]

    func reveal(urls: [URL]) {
        revealedPaths.append(urls.map(\.path))
    }

    func open(url: URL) -> Bool {
        openedPaths.append(url.path)
        return openResults[url.path] ?? true
    }
}

private struct StubFileChecker: LocalFileActionFileChecking {
    let existingPaths: Set<String>

    func fileExists(atPath path: String) -> Bool {
        existingPaths.contains(path)
    }
}

private final class RecordingLocalFileActionService: LocalFileActionServicing {
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

private final class NullDownloadCompletionNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

private final class AppStoreTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        nil
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}

    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}
