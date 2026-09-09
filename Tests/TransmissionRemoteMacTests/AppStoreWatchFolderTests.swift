// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreWatchFolderTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testCoordinatorCandidateEntersVisibleQueueWithSavedDestination() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let coordinator = RecordingWatchFolderCoordinator()
        let store = try makeStore(
            coordinator: coordinator,
            addDefaults: AddTorrentDefaults(
                startIntent: .start,
                priority: .normal,
                unwantedFiles: .daemonDefault,
                peerLimit: nil
            ),
            promptsForDownloadOptions: false
        ).store
        let presentationOwnerID = UUID()
        store.registerAddTorrentPresentationOwner(presentationOwnerID)
        await store.connect()
        let startedOwner = await coordinator.startedOwner
        let owner = try XCTUnwrap(startedOwner)
        let job = WatchFolderScanJob(
            stableFileIdentity: "device:inode",
            fileName: "queued.torrent",
            attemptNumber: 1,
            isRetry: false
        )
        let fileURL = URL(fileURLWithPath: "/tmp/queued.torrent")

        let accepted = await coordinator.submit(
            WatchFolderCandidate(
                job: job,
                fileURL: fileURL,
                remoteDestination: "/srv/watch"
            )
        )
        XCTAssertTrue(accepted)

        let request = try XCTUnwrap(store.presentedAddTorrent(for: presentationOwnerID))
        XCTAssertEqual(request.source, .localFile(fileURL))
        XCTAssertEqual(request.suggestedDownloadDirectory, "/srv/watch")
        XCTAssertEqual(request.watchFolderJob, job)
        XCTAssertEqual(request.watchFolderOwner, owner)
        XCTAssertEqual(request.submissionDisposition, .presentOptions)
        XCTAssertNil(request.directSubmissionDefaults)
        store.disconnect()
    }

    func testOptedInCandidateSubmitsDirectlyWithFrozenDefaultsAndWatchDestination() async throws {
        let fileURL = try temporaryTorrentFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let identity = try DarwinRaceResistantFileCleanup()
            .stableIdentityOfRegularFile(at: fileURL)
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Watched"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let coordinator = RecordingWatchFolderCoordinator()
        let frozenDefaults = AddTorrentDefaults(
            startIntent: .paused,
            priority: .high,
            unwantedFiles: .allUnwantedWhenFileListKnown,
            peerLimit: 37
        )
        let store = try makeStore(
            coordinator: coordinator,
            watchFolderSubmissionPolicy: .submitDirectly,
            addDefaults: frozenDefaults
        ).store
        await store.connect()
        let startedOwner = await coordinator.startedOwner
        let owner = try XCTUnwrap(startedOwner)
        let job = WatchFolderScanJob(
            stableFileIdentity: identity.rawValue,
            fileName: fileURL.lastPathComponent,
            attemptNumber: 1,
            isRetry: false
        )

        let accepted = await coordinator.submit(WatchFolderCandidate(
            job: job,
            fileURL: fileURL,
            remoteDestination: "/srv/watch"
        ))

        XCTAssertTrue(accepted)
        let resolution = try await coordinator.waitForResolution()
        XCTAssertEqual(resolution.job, job)
        XCTAssertEqual(resolution.owner, owner)
        XCTAssertEqual(resolution.acknowledgment, .added)
        let finished = await waitUntil { store.pendingAddTorrent == nil }
        XCTAssertTrue(finished)
        let addAction = try XCTUnwrap(
            recorder.requests.compactMap { try? $0.decodedActionBody() }
                .first { $0.method == "torrent-add" }
        )
        XCTAssertEqual(addAction.arguments["download-dir"], .string("/srv/watch"))
        XCTAssertEqual(addAction.arguments["paused"], .bool(true))
        XCTAssertEqual(addAction.arguments["peer-limit"], .int(37))
        XCTAssertEqual(addAction.arguments["files-unwanted"], .array([.int(0)]))
        XCTAssertEqual(addAction.arguments["priority-high"], .array([.int(0)]))
        XCTAssertFalse(store.showingAddTorrent)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    func testCancellingVisibleWatchCandidateReportsRetryableFailure() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let coordinator = RecordingWatchFolderCoordinator()
        let store = try makeStore(coordinator: coordinator).store
        let presentationOwnerID = UUID()
        store.registerAddTorrentPresentationOwner(presentationOwnerID)
        await store.connect()
        let job = WatchFolderScanJob(
            stableFileIdentity: "device:inode",
            fileName: "cancelled.torrent",
            attemptNumber: 1,
            isRetry: false
        )
        let accepted = await coordinator.submit(WatchFolderCandidate(
            job: job,
            fileURL: URL(fileURLWithPath: "/tmp/cancelled.torrent"),
            remoteDestination: "/srv/watch"
        ))
        XCTAssertTrue(accepted)
        let request = try XCTUnwrap(store.pendingAddTorrent)

        XCTAssertTrue(store.cancelPendingAddTorrent(
            requestID: request.id,
            ownerID: presentationOwnerID
        ))
        let resolution = try await coordinator.waitForResolution()
        XCTAssertEqual(resolution.job, job)
        guard case .failed(let message) = resolution.acknowledgment else {
            return XCTFail("Expected a retryable failure acknowledgment")
        }
        XCTAssertTrue(message.contains("cancelled"))
        store.disconnect()
    }

    func testRolledBackWatchPreferenceDoesNotStartAfterObserverTasksDrain() async throws {
        let coordinator = RecordingWatchFolderCoordinator()
        let setup = try makeStore(
            coordinator: coordinator,
            watchFolderEnabled: false
        )
        setup.store.connectionState = .connected(rpcVersion: 18)
        try setup.watchStore.saveConfiguration(WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: Data([0x01]),
            remoteDestination: "/srv/watch",
            scanIntervalSeconds: 60,
            successPolicy: .keepSource,
            processedFolderBookmarkData: nil
        ))
        try setup.watchStore.saveConfiguration(.defaults)

        for _ in 0 ..< 5 {
            await Task.yield()
        }

        let startedOwner = await coordinator.startedOwner
        XCTAssertNil(startedOwner)
        XCTAssertEqual(setup.store.watchFolderPreferences.configuration, .defaults)
    }

    func testCandidateFromReplacedWatchConfigurationCannotEnterTheAddQueue() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let coordinator = RecordingWatchFolderCoordinator()
        let setup = try makeStore(
            coordinator: coordinator,
            watchFolderSubmissionPolicy: .submitDirectly
        )
        await setup.store.connect()
        let startedOwner = await coordinator.currentOwner()
        let originalOwner = try XCTUnwrap(startedOwner)
        try setup.watchStore.saveConfiguration(WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: Data([0x01]),
            remoteDestination: "/srv/reconfigured",
            scanIntervalSeconds: 60,
            successPolicy: .keepSource,
            submissionPolicy: .submitDirectly,
            processedFolderBookmarkData: nil
        ))
        let didRestart = await coordinator.waitForOwnerChange(from: originalOwner)
        XCTAssertTrue(didRestart)
        let staleJob = WatchFolderScanJob(
            stableFileIdentity: "stale-identity",
            fileName: "stale.torrent",
            attemptNumber: 1,
            isRetry: false
        )

        let accepted = await coordinator.submit(
            WatchFolderCandidate(
                job: staleJob,
                fileURL: URL(fileURLWithPath: "/tmp/stale.torrent"),
                remoteDestination: "/srv/watch"
            ),
            owner: originalOwner
        )

        XCTAssertFalse(accepted)
        XCTAssertNil(setup.store.pendingAddTorrent)
        setup.store.disconnect()
    }

    private func makeStore(
        coordinator: RecordingWatchFolderCoordinator,
        watchFolderEnabled: Bool = true,
        watchFolderSubmissionPolicy: WatchFolderSubmissionPolicy = .confirmBeforeAdding,
        addDefaults: AddTorrentDefaults = .defaults,
        promptsForDownloadOptions: Bool = true
    ) throws -> (store: AppStore, watchStore: WatchFolderPreferencesStore) {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let behaviorStore = ApplicationBehaviorPreferencesStore(userDefaults: defaults)
        try behaviorStore.save(ApplicationBehaviorPreferences(
            speedAveraging: .defaults,
            completionNotificationsEnabled: true,
            promptsForDownloadOptions: promptsForDownloadOptions,
            addDefaults: addDefaults
        ))
        let watchStore = WatchFolderPreferencesStore(userDefaults: defaults)
        if watchFolderEnabled {
            try watchStore.saveConfiguration(WatchFolderConfiguration(
                isEnabled: true,
                sourceBookmarkData: Data([0x01]),
                remoteDestination: "/srv/watch",
                scanIntervalSeconds: 60,
                successPolicy: .keepSource,
                submissionPolicy: watchFolderSubmissionPolicy,
                processedFolderBookmarkData: nil
            ))
        }
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let passwordStore = WatchFolderTestPasswordStore()
        let profileStore = makePersistedConnectionProfileStore(
            fileURL: profileURL,
            passwordStore: passwordStore
        )
        let store = AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: WatchFolderTestNotifier(),
            behaviorPreferencesStore: behaviorStore,
            watchFolderPreferencesStore: watchStore,
            watchFolderCoordinator: coordinator,
            clientFactory: { profile in
                TransmissionRPCClient(
                    profile: profile,
                    urlSession: makeAppStoreMockSession()
                )
            }
        )
        return (store, watchStore)
    }

    private func temporaryTorrentFile() throws -> URL {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("torrent")
        try Data(
            "d8:announce31:http://tracker.example/announce4:infod6:lengthi12345e4:name10:sample.iso12:piece lengthi16384e6:pieces0:ee"
                .utf8
        ).write(to: fileURL)
        return fileURL
    }

    private func waitUntil(
        attempts: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0 ..< attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private actor RecordingWatchFolderCoordinator: WatchFolderCoordinating {
    struct Resolution: Sendable {
        var job: WatchFolderScanJob
        var acknowledgment: WatchFolderAddAcknowledgment
        var owner: WatchFolderRunOwner
    }

    private(set) var startedOwner: WatchFolderRunOwner?
    private(set) var resolutions: [Resolution] = []
    private var candidateHandler: WatchFolderDeadlineCoordinator.CandidateHandler?

    func start(
        commandRevision: Int,
        owner: WatchFolderRunOwner,
        configuration: WatchFolderConfiguration,
        processingState: WatchFolderProcessingState,
        candidateHandler: @escaping WatchFolderDeadlineCoordinator.CandidateHandler,
        stateHandler: @escaping WatchFolderDeadlineCoordinator.StateHandler,
        errorHandler: @escaping WatchFolderDeadlineCoordinator.ErrorHandler
    ) {
        startedOwner = owner
        self.candidateHandler = candidateHandler
    }

    func stop(commandRevision: Int, reason: String) {}

    func replaceProcessingState(
        _ processingState: WatchFolderProcessingState,
        commandRevision: Int
    ) {}

    func resolve(
        job: WatchFolderScanJob,
        acknowledgment: WatchFolderAddAcknowledgment,
        owner: WatchFolderRunOwner
    ) {
        resolutions.append(Resolution(
            job: job,
            acknowledgment: acknowledgment,
            owner: owner
        ))
    }

    func submit(_ candidate: WatchFolderCandidate) async -> Bool {
        guard let startedOwner, let candidateHandler else { return false }
        return await candidateHandler(candidate, startedOwner)
    }

    func submit(
        _ candidate: WatchFolderCandidate,
        owner: WatchFolderRunOwner
    ) async -> Bool {
        guard let candidateHandler else { return false }
        return await candidateHandler(candidate, owner)
    }

    func currentOwner() -> WatchFolderRunOwner? {
        startedOwner
    }

    nonisolated func waitForOwnerChange(
        from previousOwner: WatchFolderRunOwner
    ) async -> Bool {
        for _ in 0..<50 {
            if let currentOwner = await startedOwner,
               currentOwner != previousOwner {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await startedOwner != previousOwner
    }

    nonisolated func waitForResolution() async throws -> Resolution {
        for _ in 0..<50 {
            if let resolution = await resolutions.last {
                return resolution
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw WatchFolderTestError.resolutionTimedOut
    }
}

private enum WatchFolderTestError: Error {
    case resolutionTimedOut
}

private final class WatchFolderTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class WatchFolderTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}
