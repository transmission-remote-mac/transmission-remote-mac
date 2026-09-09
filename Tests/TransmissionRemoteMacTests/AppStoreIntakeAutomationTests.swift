// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreIntakeAutomationTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testClipboardOptInQueuesVisibleConfirmationAndDeduplicatesAfterCancel() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let reader = ClipboardTorrentPayloadReaderStub(
            payloads: [
                .plainText("magnet:?xt=urn:btih:abc"),
                .plainText("magnet:?xt=urn:btih:abc")
            ]
        )
        let preferenceStore = makePreferenceStore()
        try preferenceStore.save(
            IntakeAutomationPreferences(
                clipboardIntake: ClipboardTorrentIntakePolicy(isEnabled: true),
                sourceTorrentDeletion: .never,
                updateChecks: .defaults
            )
        )
        let store = makeStore(
            preferenceStore: preferenceStore,
            clipboardReader: reader,
            persistedProfile: true
        )
        await store.connect()
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))
        XCTAssertEqual(request.source, .remote("magnet:?xt=urn:btih:abc"))
        XCTAssertFalse(store.isAddingTorrent)
        XCTAssertTrue(store.cancelPendingAddTorrent(requestID: request.id, ownerID: ownerID))
        store.addTorrentPresentationWillDismiss(requestID: request.id, ownerID: ownerID)
        store.addTorrentSheetDidDismiss(requestID: request.id, ownerID: ownerID)

        store.inspectClipboardForTorrent()

        XCTAssertNil(store.presentedAddTorrent(for: ownerID))
        XCTAssertEqual(reader.readCount, 2)
    }

    func testDisabledClipboardPolicyDoesNotReadClipboard() {
        let reader = ClipboardTorrentPayloadReaderStub(
            payloads: [.plainText("magnet:?xt=urn:btih:abc")]
        )
        let store = makeStore(
            preferenceStore: makePreferenceStore(),
            clipboardReader: reader
        )
        store.connectionState = .connected(rpcVersion: 18)

        store.inspectClipboardForTorrent()

        XCTAssertEqual(reader.readCount, 0)
        XCTAssertNil(store.pendingAddTorrent)
    }

    func testEnablingClipboardPreferenceInspectsOnceWithoutPolling() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let reader = ClipboardTorrentPayloadReaderStub(
            payloads: [.plainText("https://example.com/release.torrent")]
        )
        let preferenceStore = makePreferenceStore()
        let store = makeStore(
            preferenceStore: preferenceStore,
            clipboardReader: reader,
            persistedProfile: true
        )
        await store.connect()
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)

        try preferenceStore.save(
            IntakeAutomationPreferences(
                clipboardIntake: ClipboardTorrentIntakePolicy(isEnabled: true),
                sourceTorrentDeletion: .never,
                updateChecks: .defaults
            )
        )
        await Task.yield()

        XCTAssertEqual(
            store.presentedAddTorrent(for: ownerID)?.source,
            .remote("https://example.com/release.torrent")
        )
        XCTAssertEqual(reader.readCount, 1)
    }

    func testRolledBackClipboardPreferenceDoesNotInspectAfterObserverTasksDrain() async throws {
        let reader = ClipboardTorrentPayloadReaderStub(
            payloads: [.plainText("magnet:?xt=urn:btih:stale")]
        )
        let preferenceStore = makePreferenceStore()
        let store = makeStore(
            preferenceStore: preferenceStore,
            clipboardReader: reader
        )
        store.connectionState = .connected(rpcVersion: 18)
        store.registerAddTorrentPresentationOwner(UUID())
        try preferenceStore.save(IntakeAutomationPreferences(
            clipboardIntake: ClipboardTorrentIntakePolicy(isEnabled: true),
            sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
            updateChecks: .defaults
        ))
        try preferenceStore.save(.defaults)

        for _ in 0 ..< 5 {
            await Task.yield()
        }

        XCTAssertEqual(reader.readCount, 0)
        XCTAssertNil(store.pendingAddTorrent)
        XCTAssertEqual(store.intakeAutomationPreferences, .defaults)
    }

    func testApplicationSettingsSnapshotUpdatesRuntimeMirrorsSynchronously() {
        let preferenceStore = makePreferenceStore()
        let store = makeStore(
            preferenceStore: preferenceStore,
            clipboardReader: ClipboardTorrentPayloadReaderStub(payloads: [])
        )
        let behavior = ApplicationBehaviorPreferences(
            speedAveraging: SpeedAveragingPolicy(
                isEnabled: true,
                sampleLimit: 10,
                windowSeconds: 30
            ),
            completionNotificationsEnabled: false,
            addDefaults: .defaults
        )
        let intake = IntakeAutomationPreferences(
            clipboardIntake: .defaults,
            sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
            updateChecks: .defaults
        )
        let polling = PollingPreferences(
            foregroundIntervalSeconds: 7,
            backgroundIntervalSeconds: 30,
            backgroundPolicy: .pollSlowly
        )
        let peerResolution = PeerResolutionPreferences(
            resolveHostNames: true,
            resolveCountries: false,
            showCountryFlags: false
        )
        let snapshot = PersistedApplicationSettingsSnapshot(
            polling: polling,
            behavior: behavior,
            intake: intake,
            watchFolder: store.watchFolderPreferencesController.snapshot,
            sidebarGrouping: store.workspacePreferencesController.preferences.sidebarGrouping,
            interaction: store.interactionPreferencesController.preferences,
            peerResolution: peerResolution
        )

        store.applyApplicationSettingsSnapshot(snapshot)

        XCTAssertEqual(store.pollingPreferences, polling)
        XCTAssertEqual(store.applicationBehaviorPreferences, behavior)
        XCTAssertEqual(store.intakeAutomationPreferences, intake)
        XCTAssertEqual(store.watchFolderPreferences, snapshot.watchFolder)
        XCTAssertEqual(store.peerResolutionPreferences, peerResolution)
    }

    func testConfirmedAddedLocalTorrentDeletesSource() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Release"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let fileManager = TorrentSourceDeletionFileManagerRecordingStub(fileType: .typeRegular)
        let store = try await makeConnectedDeletionStore(fileManager: fileManager)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent")
        store.requestAddTorrent(fileURL: fileURL)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: Data([0x01]),
            sourceFileURL: fileURL,
            sourceFileIdentity: fileManager.stableIdentity,
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertTrue(fileManager.identityRequests.isEmpty)
        XCTAssertEqual(fileManager.removalAttempts, [fileURL.standardizedFileURL])
        XCTAssertEqual(fileManager.removalIdentities, [fileManager.stableIdentity])
        XCTAssertNil(store.errorMessage)
    }

    func testJustSavedSourceDeletionPreferenceAppliesToTheNextLocalAdd() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Release"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let preferenceStore = makePreferenceStore()
        let fileManager = TorrentSourceDeletionFileManagerRecordingStub(fileType: .typeRegular)
        let store = makeStore(
            preferenceStore: preferenceStore,
            clipboardReader: ClipboardTorrentPayloadReaderStub(payloads: []),
            persistedProfile: true,
            torrentSourceDeletionService: TorrentSourceDeletionService(
                fileCleanup: fileManager
            )
        )
        await store.connect()
        XCTAssertTrue(store.connectionState.isConnected)
        try preferenceStore.save(
            IntakeAutomationPreferences(
                clipboardIntake: .defaults,
                sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
                updateChecks: .defaults
            )
        )
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent")
        store.requestAddTorrent(fileURL: fileURL)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: Data([0x01]),
            sourceFileURL: fileURL,
            sourceFileIdentity: fileManager.stableIdentity,
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(fileManager.removalAttempts, [fileURL.standardizedFileURL])
    }

    func testFailedLocalAddNeverDeletesSource() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"invalid metainfo","arguments":{}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let fileManager = TorrentSourceDeletionFileManagerRecordingStub(fileType: .typeRegular)
        let store = try await makeConnectedDeletionStore(fileManager: fileManager)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent")
        store.requestAddTorrent(fileURL: fileURL)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: Data([0x01]),
            sourceFileURL: fileURL,
            sourceFileIdentity: fileManager.stableIdentity,
            startPaused: false,
            downloadDirectory: nil
        )

        guard case .failed = result else {
            return XCTFail("Expected the rejected add to fail")
        }
        XCTAssertTrue(fileManager.removalAttempts.isEmpty)
    }

    func testConfirmedAddSurfacesSourceDeletionFailure() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Release"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let fileManager = TorrentSourceDeletionFileManagerRecordingStub(
            fileType: .typeRegular,
            removalError: IntakeAutomationTestError.removeFailed
        )
        let store = try await makeConnectedDeletionStore(fileManager: fileManager)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent")
        store.requestAddTorrent(fileURL: fileURL)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: Data([0x01]),
            sourceFileURL: fileURL,
            sourceFileIdentity: fileManager.stableIdentity,
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertEqual(fileManager.removalAttempts, [fileURL.standardizedFileURL])
        XCTAssertTrue(store.errorMessage?.contains("source .torrent could not be deleted") == true)
    }

    func testConfirmedAddWithoutReadTimeIdentityKeepsSourceAndFailsCleanupVisibly() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Release"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let fileManager = TorrentSourceDeletionFileManagerRecordingStub(fileType: .typeRegular)
        let store = try await makeConnectedDeletionStore(fileManager: fileManager)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent")
        store.requestAddTorrent(fileURL: fileURL)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: Data([0x01]),
            sourceFileURL: fileURL,
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertTrue(fileManager.identityRequests.isEmpty)
        XCTAssertTrue(fileManager.removalAttempts.isEmpty)
        XCTAssertTrue(store.errorMessage?.contains("identity was not captured") == true)
    }

    func testConfirmedDataOnlyAddDoesNotRequireASourceIdentity() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-added":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Release"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let fileManager = TorrentSourceDeletionFileManagerRecordingStub(fileType: .typeRegular)
        let store = try await makeConnectedDeletionStore(fileManager: fileManager)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        store.requestAddTorrent()
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: Data([0x01]),
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .succeeded)
        XCTAssertTrue(fileManager.identityRequests.isEmpty)
        XCTAssertTrue(fileManager.removalAttempts.isEmpty)
        XCTAssertNil(store.errorMessage)
    }

    func testDuplicateLocalTorrentNeverDeletesSource() async throws {
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-add" {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrent-duplicate":{"id":42,"hashString":"0123456789abcdef0123456789abcdef01234567","name":"Release"}}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let fileManager = TorrentSourceDeletionFileManagerRecordingStub(fileType: .typeRegular)
        let store = try await makeConnectedDeletionStore(fileManager: fileManager)
        let ownerID = UUID()
        store.registerAddTorrentPresentationOwner(ownerID)
        let fileURL = URL(fileURLWithPath: "/tmp/release.torrent")
        store.requestAddTorrent(fileURL: fileURL)
        let request = try XCTUnwrap(store.presentedAddTorrent(for: ownerID))

        let result = await store.addTorrentFile(
            requestID: request.id,
            presentationOwnerID: ownerID,
            data: Data([0x01]),
            sourceFileURL: fileURL,
            sourceFileIdentity: fileManager.stableIdentity,
            startPaused: false,
            downloadDirectory: nil
        )

        XCTAssertEqual(result, .awaitingSaveAs)
        XCTAssertTrue(fileManager.removalAttempts.isEmpty)
    }

    private func makeConnectedDeletionStore(
        fileManager: TorrentSourceDeletionFileManagerRecordingStub
    ) async throws -> AppStore {
        let preferenceStore = makePreferenceStore()
        try preferenceStore.save(
            IntakeAutomationPreferences(
                clipboardIntake: .defaults,
                sourceTorrentDeletion: .afterSuccessfulNonDuplicateAdd,
                updateChecks: .defaults
            )
        )
        let store = makeStore(
            preferenceStore: preferenceStore,
            clipboardReader: ClipboardTorrentPayloadReaderStub(payloads: []),
            persistedProfile: true,
            torrentSourceDeletionService: TorrentSourceDeletionService(
                fileCleanup: fileManager
            )
        )
        await store.connect()
        XCTAssertTrue(store.connectionState.isConnected)
        return store
    }

    private func makePreferenceStore() -> IntakeAutomationPreferencesStore {
        IntakeAutomationPreferencesStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!
        )
    }

    private func makeStore(
        preferenceStore: IntakeAutomationPreferencesStore,
        clipboardReader: ClipboardTorrentPayloadReaderStub,
        persistedProfile: Bool = false,
        torrentSourceDeletionService: TorrentSourceDeletionService = TorrentSourceDeletionService()
    ) -> AppStore {
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("profiles.json")
        let passwordStore = IntakeAutomationPasswordStore()
        let profileStore = persistedProfile
            ? makePersistedConnectionProfileStore(
                fileURL: profileURL,
                passwordStore: passwordStore
            )
            : ConnectionProfileStore(fileURL: profileURL, passwordStore: passwordStore)
        let session = makeAppStoreMockSession()
        return AppStore(
            profileStore: profileStore,
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            downloadCompletionNotifier: IntakeAutomationNotifier(),
            intakeAutomationPreferencesStore: preferenceStore,
            clipboardTorrentPayloadReader: clipboardReader,
            torrentSourceDeletionService: torrentSourceDeletionService,
            clientFactory: { profile in
                TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
    }
}

@MainActor
private final class ClipboardTorrentPayloadReaderStub: ClipboardTorrentPayloadReading {
    private var payloads: [ClipboardTorrentPayload]
    private(set) var readCount = 0

    init(payloads: [ClipboardTorrentPayload]) {
        self.payloads = payloads
    }

    func readIfChanged() -> ClipboardTorrentPayload? {
        readCount += 1
        return payloads.isEmpty ? nil : payloads.removeFirst()
    }
}

private final class TorrentSourceDeletionFileManagerRecordingStub: RaceResistantFileCleaning, @unchecked Sendable {
    let fileType: FileAttributeType
    let removalError: Error?
    private(set) var removalAttempts: [URL] = []
    private(set) var removalIdentities: [RaceResistantFileIdentity] = []
    private(set) var identityRequests: [URL] = []
    let stableIdentity = RaceResistantFileIdentity(
        deviceID: 1,
        fileID: 2,
        generation: 3
    )

    init(fileType: FileAttributeType, removalError: Error? = nil) {
        self.fileType = fileType
        self.removalError = removalError
    }

    func stableIdentityOfRegularFile(at fileURL: URL) throws -> RaceResistantFileIdentity {
        identityRequests.append(fileURL)
        guard fileType == .typeRegular else {
            throw RaceResistantFileCleanupError.sourceIsNotARegularFile
        }
        return stableIdentity
    }

    func removeRegularFile(
        at fileURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws {
        removalAttempts.append(fileURL)
        removalIdentities.append(identity)
        if let removalError { throw removalError }
    }

    func moveRegularFile(
        at sourceURL: URL,
        to destinationURL: URL,
        matching identity: RaceResistantFileIdentity
    ) throws {
        throw IntakeAutomationTestError.unexpectedMove
    }
}

private final class IntakeAutomationPasswordStore: ConnectionPasswordStoring {
    func password(for profileID: ConnectionProfile.ID) throws -> String? { nil }
    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {}
    func removePassword(for profileID: ConnectionProfile.ID) throws {}
}

private final class IntakeAutomationNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

private enum IntakeAutomationTestError: LocalizedError {
    case removeFailed
    case unexpectedMove

    var errorDescription: String? {
        switch self {
        case .removeFailed:
            "Removal failed"
        case .unexpectedMove:
            "Unexpected move"
        }
    }
}
