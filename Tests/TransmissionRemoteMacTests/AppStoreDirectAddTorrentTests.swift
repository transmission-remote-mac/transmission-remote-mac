// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreDirectAddTorrentTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testSpecifiedRemoteSourceSubmitsWithoutPresentingSheetUsingSavedDefaults() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Direct"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try await makeConnectedStore(
            addDefaults: AddTorrentDefaults(
                startIntent: .paused,
                priority: .normal,
                unwantedFiles: .daemonDefault,
                peerLimit: 37
            )
        )
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        store.requestAddTorrent(
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )

        XCTAssertFalse(store.showingAddTorrent)
        XCTAssertNil(store.presentedAddTorrent(for: ownerID))
        let didSubmit = await waitUntil {
            recorder.requests.contains {
                (try? $0.decodedActionBody().method) == "torrent-add"
            } && store.pendingAddTorrent == nil
        }
        XCTAssertTrue(didSubmit)
        let addAction = try XCTUnwrap(
            recorder.requests.compactMap { try? $0.decodedActionBody() }
                .first { $0.method == "torrent-add" }
        )
        XCTAssertEqual(addAction.arguments["paused"], .bool(true))
        XCTAssertEqual(addAction.arguments["peer-limit"], .int(37))
        XCTAssertNil(addAction.arguments["download-dir"])
        XCTAssertFalse(store.showingAddTorrent)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    func testToolbarAddRemainsInteractiveWhenPromptingIsDisabled() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            return appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let store = try await makeConnectedStore(
            addDefaults: directDefaults
        )
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        store.requestAddTorrent()

        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        XCTAssertEqual(request.source, .manual)
        XCTAssertTrue(store.showingAddTorrent)
        XCTAssertFalse(recorder.requests.compactMap { try? $0.decodedActionBody() }
            .contains { $0.method == "torrent-add" })
        cancelAndDismiss(request, ownerID: ownerID, store: store)
        store.disconnect()
    }

    func testOptedInClipboardCandidateUsesTheSameDirectSubmissionPath() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":43,"hashString":"abcdef0123456789abcdef0123456789abcdef01","name":"Clipboard"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let reader = DirectAddTorrentClipboardReader(payload: .plainText(
            "magnet:?xt=urn:btih:abcdef0123456789abcdef0123456789abcdef01"
        ))
        let store = try await makeConnectedStore(
            addDefaults: directDefaults,
            clipboardReader: reader,
            clipboardIntakeEnabled: true
        )
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        let didSubmit = await waitUntil {
            recorder.requests.compactMap { try? $0.decodedActionBody() }
                .contains { $0.method == "torrent-add" }
                && store.pendingAddTorrent == nil
        }
        XCTAssertTrue(didSubmit)
        XCTAssertEqual(reader.readCount, 1)
        XCTAssertNil(store.presentedAddTorrent(for: ownerID))
        XCTAssertFalse(store.showingAddTorrent)
        store.disconnect()
    }

    func testInvalidDirectSourceFallsBackToVisibleOptionsWithoutRPCMutation() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            return appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let store = try await makeConnectedStore(addDefaults: directDefaults)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        store.requestAddTorrent(source: "ftp://unsupported.example/file.torrent")

        let didPresentOptions = await waitUntil {
            store.presentedAddTorrent(for: ownerID) != nil
        }
        XCTAssertTrue(didPresentOptions)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        XCTAssertEqual(request.source, .remote("ftp://unsupported.example/file.torrent"))
        XCTAssertTrue(store.errorMessage?.contains("could not be added automatically") == true)
        XCTAssertFalse(recorder.requests.compactMap { try? $0.decodedActionBody() }
            .contains { $0.method == "torrent-add" })
        cancelAndDismiss(request, ownerID: ownerID, store: store)
        store.disconnect()
    }

    func testSavedRemoteFileChoicesFallBackWithoutRPCMutation() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            return appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let store = try await makeConnectedStore(
            addDefaults: AddTorrentDefaults(
                startIntent: .start,
                priority: .high,
                unwantedFiles: .daemonDefault,
                peerLimit: nil
            )
        )
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        store.requestAddTorrent(
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )

        let didPresentOptions = await waitUntil {
            store.presentedAddTorrent(for: ownerID) != nil
        }
        XCTAssertTrue(didPresentOptions)
        XCTAssertFalse(recorder.requests.compactMap { try? $0.decodedActionBody() }
            .contains { $0.method == "torrent-add" })
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        cancelAndDismiss(request, ownerID: ownerID, store: store)
        store.disconnect()
    }

    func testExplicitRemoteFileChoicesFallBackWithoutRPCMutation() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            return appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let store = try await makeConnectedStore(addDefaults: directDefaults)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        store.requestAddTorrent(
            source: "https://example.com/release.torrent",
            initialOptions: AddTorrentInitialOptions(
                unwantedFiles: .allUnwantedWhenFileListKnown
            )
        )

        let didPresentOptions = await waitUntil {
            store.presentedAddTorrent(for: ownerID) != nil
        }
        XCTAssertTrue(didPresentOptions)
        XCTAssertFalse(recorder.requests.compactMap { try? $0.decodedActionBody() }
            .contains { $0.method == "torrent-add" })
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        cancelAndDismiss(request, ownerID: ownerID, store: store)
        store.disconnect()
    }

    func testDirectLocalDuplicatePresentsMissingTrackerConsentAfterOneAddRPC() async throws {
        let fileURL = try temporaryTorrentFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = AppStoreRequestRecorder()
        let hash = "0123456789abcdef0123456789abcdef01234567"
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            switch action.method {
            case "torrent-add":
                return rpcTestResponse(
                    body: "{\"result\":\"success\",\"arguments\":{\"torrent-duplicate\":{\"id\":42,\"hashString\":\"\(hash)\",\"name\":\"Existing\"}}}"
                )
            case "torrent-get"
                where action.arguments["ids"] == .array([.string(hash)]):
                return rpcTestResponse(
                    body: "{\"result\":\"success\",\"arguments\":{\"torrents\":[{\"id\":42,\"hashString\":\"\(hash)\",\"trackers\":[]}]}}"
                )
            default:
                return appStoreRPCResponse(for: action.method)
            }
        }
        let store = try await makeConnectedStore(addDefaults: directDefaults)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        store.requestAddTorrent(fileURL: fileURL)

        let didPresentConsent = await waitUntil {
            store.presentedAddTorrent(for: ownerID)?.pendingDuplicateTrackerPlan != nil
        }
        XCTAssertTrue(didPresentConsent)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        let plan = try XCTUnwrap(request.pendingDuplicateTrackerPlan)
        XCTAssertEqual(plan.missingTrackerURLs, ["http://tracker.example/announce"])
        XCTAssertEqual(
            recorder.requests.compactMap { try? $0.decodedActionBody() }
                .filter { $0.method == "torrent-add" }.count,
            1
        )

        XCTAssertEqual(
            store.cancelDuplicateTorrentTrackerPlan(
                requestID: request.id,
                presentationOwnerID: ownerID,
                downloadDirectory: nil
            ),
            .succeeded
        )
        dismiss(request, ownerID: ownerID, store: store)
        store.disconnect()
    }

    func testDirectLocalSuccessUsesSavedSourceDeletionPolicy() async throws {
        let fileURL = try temporaryTorrentFile()
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":44,"hashString":"123456789abcdef0123456789abcdef012345678","name":"Deleted source"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let store = try await makeConnectedStore(
            addDefaults: directDefaults,
            sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd
        )

        store.requestAddTorrent(fileURL: fileURL)

        let didDeleteAfterAdd = await waitUntil {
            !FileManager.default.fileExists(atPath: fileURL.path)
                && store.pendingAddTorrent == nil
        }
        XCTAssertTrue(didDeleteAfterAdd)
        XCTAssertEqual(
            recorder.requests.compactMap { try? $0.decodedActionBody() }
                .filter { $0.method == "torrent-add" }.count,
            1
        )
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    func testProfileAndGenerationSwitchSilentlyDiscardsSuspendedPreparation() async throws {
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            return appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let preparationService = SuspendedDirectAddTorrentPreparationService()
        let store = try await makeConnectedStore(
            addDefaults: directDefaults,
            preparationService: preparationService
        )
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        store.requestAddTorrent(
            source: "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"
        )
        let preparationDidStart = await waitForPreparationToStart(preparationService)
        XCTAssertTrue(preparationDidStart)

        let otherProfile = try ConnectionProfile.validated(
            name: "Other",
            host: "other.example"
        )
        let profileResult = store.applyConnectionProfiles(
            [store.selectedProfile, otherProfile],
            selectedProfileID: otherProfile.id
        )
        guard case .success = profileResult else {
            return XCTFail("Expected the profile switch to be accepted")
        }
        await preparationService.release()

        let didReconnectWithoutStaleRequest = await waitUntil {
            store.selectedProfileID == otherProfile.id
                && store.connectionState == .connected(rpcVersion: 18)
                && store.pendingAddTorrent == nil
        }
        XCTAssertTrue(didReconnectWithoutStaleRequest)
        XCTAssertFalse(recorder.requests.compactMap { try? $0.decodedActionBody() }
            .contains { $0.method == "torrent-add" })
        XCTAssertNil(store.presentedAddTorrent(for: ownerID))
        XCTAssertFalse(store.showingAddTorrent)
        XCTAssertNil(store.errorMessage)
        store.disconnect()
    }

    private var directDefaults: AddTorrentDefaults {
        AddTorrentDefaults(
            startIntent: .start,
            priority: .normal,
            unwantedFiles: .daemonDefault,
            peerLimit: nil
        )
    }

    private func makeConnectedStore(
        addDefaults: AddTorrentDefaults,
        clipboardReader: (any ClipboardTorrentPayloadReading)? = nil,
        clipboardIntakeEnabled: Bool = false,
        sourceTorrentDeletion: SourceTorrentDeletionPolicy = .never,
        preparationService: any AddTorrentDirectSubmissionPreparing =
            AddTorrentDirectSubmissionPreparationService()
    ) async throws -> AppStore {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let profileStore = makePersistedConnectionProfileStore(
            fileURL: profileURL,
            passwordStore: DirectAddTorrentTestPasswordStore()
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let behaviorStore = ApplicationBehaviorPreferencesStore(userDefaults: defaults)
        try behaviorStore.save(ApplicationBehaviorPreferences(
            speedAveraging: .defaults,
            completionNotificationsEnabled: true,
            promptsForDownloadOptions: false,
            addDefaults: addDefaults
        ))
        let intakeStore = IntakeAutomationPreferencesStore(userDefaults: defaults)
        try intakeStore.save(IntakeAutomationPreferences(
            clipboardIntake: ClipboardTorrentIntakePolicy(
                isEnabled: clipboardIntakeEnabled
            ),
            sourceTorrentDeletion: sourceTorrentDeletion,
            updateChecks: .defaults
        ))
        let session = makeAppStoreMockSession()
        let store = AppStore(
            profileStore: profileStore,
            userDefaults: defaults,
            downloadCompletionNotifier: DirectAddTorrentTestNotifier(),
            behaviorPreferencesStore: behaviorStore,
            intakeAutomationPreferencesStore: intakeStore,
            clipboardTorrentPayloadReader: clipboardReader,
            directAddTorrentPreparationService: preparationService,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
        await store.connect()
        return store
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

    private func cancelAndDismiss(
        _ request: AppStore.PendingAddTorrent,
        ownerID: UUID,
        store: AppStore
    ) {
        XCTAssertTrue(store.cancelPendingAddTorrent(requestID: request.id, ownerID: ownerID))
        dismiss(request, ownerID: ownerID, store: store)
    }

    private func dismiss(
        _ request: AppStore.PendingAddTorrent,
        ownerID: UUID,
        store: AppStore
    ) {
        store.addTorrentPresentationWillDismiss(requestID: request.id, ownerID: ownerID)
        store.addTorrentSheetDidDismiss(requestID: request.id, ownerID: ownerID)
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

    private func waitForPreparationToStart(
        _ service: SuspendedDirectAddTorrentPreparationService
    ) async -> Bool {
        for _ in 0 ..< 200 {
            if await service.isWaiting { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await service.isWaiting
    }
}

private final class DirectAddTorrentTestPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class DirectAddTorrentTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

private actor SuspendedDirectAddTorrentPreparationService:
    AddTorrentDirectSubmissionPreparing {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    var isWaiting: Bool {
        continuation != nil
    }

    func prepare(
        _ request: AddTorrentDirectSubmissionPreparationRequest
    ) async throws -> AddTorrentDirectSubmissionPreparationOutcome {
        if !isReleased {
            await withCheckedContinuation { continuation = $0 }
        }
        isReleased = false
        try Task.checkCancellation()
        guard case .remote(let source) = request.source else {
            return .requiresInteraction("Expected a remote source")
        }
        return .ready(AddTorrentDirectSubmissionPreparation(
            payload: .remote(source),
            startPaused: false,
            downloadDirectory: nil,
            peerLimit: nil
        ))
    }

    func release() {
        isReleased = true
        let continuation = continuation
        self.continuation = nil
        continuation?.resume()
    }
}

@MainActor
private final class DirectAddTorrentClipboardReader: ClipboardTorrentPayloadReading {
    private var payload: ClipboardTorrentPayload?
    private(set) var readCount = 0

    init(payload: ClipboardTorrentPayload) {
        self.payload = payload
    }

    func readIfChanged() -> ClipboardTorrentPayload? {
        readCount += 1
        defer { payload = nil }
        return payload
    }
}
