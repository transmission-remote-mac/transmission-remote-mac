// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class AppStoreConnectionTests: XCTestCase {
    override func tearDown() {
        AppStoreMockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testStartConnectsPersistedSelectedProfileExactlyOnce() async throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)

        await harness.store.start()
        harness.store.disconnect()
        await harness.store.start()

        XCTAssertEqual(recorder.count(host: profile.host, method: "session-get"), 1)
        XCTAssertEqual(harness.store.connectionState, .disconnected)
        XCTAssertFalse(harness.store.needsConnectionSetup)
    }

    func testConnectOnLaunchCanBeDisabledWithoutDisablingManualConnect() async throws {
        var profile = makeProfile(name: "Saved", host: "saved.example")
        profile.connectOnLaunch = false
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)

        await harness.store.start()

        XCTAssertEqual(harness.store.connectionState, .disconnected)
        XCTAssertTrue(recorder.requests.isEmpty)

        await harness.store.connect()

        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(recorder.count(host: profile.host, method: "session-get"), 1)
        harness.store.disconnect()
    }

    func testTorrentProjectionOwnsPlanAndOnlyExpansionQueuesRepair() async throws {
        let profile = makeProfile(name: "Projection", host: "projection.example")
        let torrentRequests = LockedValue<[RPCArguments]>([])
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-get" {
                torrentRequests.mutate { $0.append(action.arguments) }
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)

        await harness.store.connect()

        let initialPlan = try XCTUnwrap(harness.store.currentTorrentListFieldPlan)
        XCTAssertEqual(initialPlan.rpcVersion, 18)
        XCTAssertEqual(initialPlan.revision, harness.store.torrentListFieldPlanRevision)
        XCTAssertEqual(initialPlan.projectionColumns, harness.store.torrentTableVisibleColumns)
        XCTAssertEqual(torrentRequests.value.count, 1)

        var expandedColumns = harness.store.torrentTableVisibleColumns
        expandedColumns.insert(.uploaded)
        harness.store.setTorrentTableProjection(
            visibleColumns: expandedColumns,
            activeSortColumn: harness.store.torrentTableActiveSortColumn
        )
        let expansionRepaired = await waitUntil { torrentRequests.value.count == 2 }
        XCTAssertTrue(expansionRepaired)
        XCTAssertEqual(harness.store.torrentListFieldPlanRevision, initialPlan.revision + 1)
        let expandedFields = torrentRequests.value.last?["fields"]?.arrayValue?.compactMap(\.stringValue)
        XCTAssertTrue(expandedFields?.contains("uploadedEver") == true)

        let expansionRequestCount = torrentRequests.value.count
        let expansionRevision = harness.store.torrentListFieldPlanRevision
        expandedColumns.remove(.uploaded)
        harness.store.setTorrentTableProjection(
            visibleColumns: expandedColumns,
            activeSortColumn: harness.store.torrentTableActiveSortColumn
        )
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(torrentRequests.value.count, expansionRequestCount)
        XCTAssertEqual(harness.store.torrentListFieldPlanRevision, expansionRevision + 1)

        let contractionRevision = harness.store.torrentListFieldPlanRevision
        harness.store.setTorrentTableProjection(
            visibleColumns: expandedColumns,
            activeSortColumn: harness.store.torrentTableActiveSortColumn
        )
        await Task.yield()
        XCTAssertEqual(harness.store.torrentListFieldPlanRevision, contractionRevision)
        XCTAssertEqual(torrentRequests.value.count, expansionRequestCount)

        harness.store.disconnect()
        XCTAssertNil(harness.store.currentTorrentListFieldPlan)
        XCTAssertEqual(harness.store.torrentTableVisibleColumns, expandedColumns)
    }

    func testCancelledAppLifetimeStartupCanRetry() async throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        let firstRequestStarted = expectation(description: "first startup request started")
        let firstRequestGate = DispatchSemaphore(value: 0)
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            if action.method == "session-get",
               recorder.count(host: profile.host, method: "session-get") == 1 {
                firstRequestStarted.fulfill()
                _ = firstRequestGate.wait(timeout: .now() + 2)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [profile],
            selectedProfileID: profile.id,
            createsSeparateClientSessions: true
        )

        let firstStart = Task { await harness.store.start() }
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        firstStart.cancel()
        firstRequestGate.signal()
        await firstStart.value
        await harness.store.start()

        XCTAssertEqual(recorder.count(host: profile.host, method: "session-get"), 2)
        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        harness.store.disconnect()
    }

    func testCancellingLaunchPasswordPromptDoesNotPoisonManualConnect() async throws {
        let profile = makeProfile(name: "Protected", host: "protected.example", username: "user")
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)

        await harness.store.start()
        let launchPrompt = try XCTUnwrap(harness.store.passwordPrompt)
        harness.store.cancelPasswordPrompt()

        XCTAssertNil(harness.store.passwordPrompt)
        XCTAssertTrue(harness.store.canConnect)

        await harness.store.connect()
        let manualPrompt = try XCTUnwrap(harness.store.passwordPrompt)
        XCTAssertNotEqual(manualPrompt.id, launchPrompt.id)

        await harness.store.connectWithPromptPassword("one-use", for: manualPrompt)

        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        harness.store.disconnect()
    }

    func testFreshStartWaitsForConnectionSetupThenApplyPersistsAndConnects() async throws {
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [.localDefault],
            selectedProfileID: ConnectionProfile.localDefault.id,
            createsProfileFile: false
        )

        await harness.store.start()

        XCTAssertTrue(harness.store.needsConnectionSetup)
        XCTAssertEqual(harness.store.connectionState, .disconnected)
        XCTAssertTrue(recorder.requests.isEmpty)

        let savedProfile = makeProfile(name: "Saved", host: "saved.example")
        harness.store.applyConnectionProfiles(
            [savedProfile],
            selectedProfileID: savedProfile.id
        )
        let connected = await waitUntil {
            harness.store.connectionState == .connected(rpcVersion: 18)
        }
        let persisted = try harness.profileStore.load()

        XCTAssertTrue(connected)
        XCTAssertFalse(harness.store.needsConnectionSetup)
        XCTAssertEqual(harness.store.selectedProfileID, savedProfile.id)
        XCTAssertEqual(persisted.selectedProfileID, savedProfile.id)
        XCTAssertEqual(recorder.count(host: savedProfile.host, method: "session-get"), 1)
        harness.store.disconnect()
    }

    func testFreshStartHonorsDisabledConnectOnLaunchAfterSetup() async throws {
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [.localDefault],
            selectedProfileID: ConnectionProfile.localDefault.id,
            createsProfileFile: false
        )

        await harness.store.start()
        var savedProfile = makeProfile(name: "Saved", host: "saved.example")
        savedProfile.connectOnLaunch = false
        harness.store.applyConnectionProfiles([savedProfile], selectedProfileID: savedProfile.id)
        await Task.yield()

        XCTAssertFalse(harness.store.needsConnectionSetup)
        XCTAssertEqual(harness.store.connectionState, .disconnected)
        XCTAssertTrue(recorder.requests.isEmpty)

        await harness.store.connect()

        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(recorder.count(host: savedProfile.host, method: "session-get"), 1)
        harness.store.disconnect()
    }

    func testApplyConnectionProfilesReturnsExactPersistenceFailureWithoutPublishingDraft() throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        let fileWriter = ConnectionApplyTestFileWriter()
        let harness = try makeHarness(
            profiles: [profile],
            selectedProfileID: profile.id,
            fileWriter: fileWriter
        )
        var editedProfile = profile
        editedProfile.host = "edited.example"
        fileWriter.error = ConnectionApplyTestError.diskFull

        let result = harness.store.applyConnectionProfiles(
            [editedProfile],
            selectedProfileID: editedProfile.id
        )

        guard case .failure(let failure) = result else {
            return XCTFail("Expected the profile save to fail")
        }
        XCTAssertEqual(failure.kind, .persistence)
        XCTAssertEqual(failure.underlyingError as? ConnectionApplyTestError, .diskFull)
        XCTAssertEqual(failure.localizedDescription, ConnectionApplyTestError.diskFull.localizedDescription)
        XCTAssertEqual(harness.store.profiles, [profile])
        XCTAssertEqual(harness.store.selectedProfile.host, profile.host)
        XCTAssertEqual(harness.store.errorMessage, ConnectionApplyTestError.diskFull.localizedDescription)
    }

    func testApplyConnectionProfilesReturnsTypedValidationFailure() throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)

        let result = harness.store.applyConnectionProfiles([], selectedProfileID: nil)

        guard case .failure(let failure) = result else {
            return XCTFail("Expected the empty profile collection to fail")
        }
        XCTAssertEqual(failure.kind, .invalidProfiles)
        XCTAssertEqual(
            failure.underlyingError as? ConnectionProfileStoreError,
            .emptyProfileList
        )
        XCTAssertEqual(harness.store.profiles, [profile])
    }

    func testConnectionSettingsCoordinatorIsProcessLocalAndKeepsUnsavedSecrets() throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        let firstReference = harness.store.connectionSettingsCoordinatorController
        firstReference.draftProfiles[0].password = "unsaved-rpc-secret"
        firstReference.draftProfiles[0].proxyPassword = "unsaved-proxy-secret"

        let secondReference = harness.store.connectionSettingsCoordinatorController

        XCTAssertTrue(firstReference === secondReference)
        XCTAssertEqual(secondReference.draftProfiles[0].password, "unsaved-rpc-secret")
        XCTAssertEqual(secondReference.draftProfiles[0].proxyPassword, "unsaved-proxy-secret")
        XCTAssertEqual(harness.store.profiles, [profile])
    }

    func testSettingsImportRejectsUnsavedServerDraftWithoutWritingImportedState() throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        harness.store.connectionSettingsCoordinatorController.draftProfiles[0].host =
            "unsaved.example"
        var importedProfile = profile
        importedProfile.host = "imported.example"
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [importedProfile],
            selectedProfileID: importedProfile.id,
            applicationPreferences: .init()
        ))
        let coordinator = harness.store.settingsPortabilityController
        try coordinator.prepareImport(data, sourceName: "portable.json")
        coordinator.collisionPolicy = .updateMatchingIdentifier

        XCTAssertThrowsError(try coordinator.confirmImport()) { error in
            XCTAssertEqual(
                error as? SettingsPortabilityCoordinatorError,
                .commitRejected(
                    "Save or revert the unsaved Server settings before importing settings."
                )
            )
            coordinator.present(error: error)
        }

        XCTAssertEqual(
            coordinator.errorMessage,
            "Save or revert the unsaved Server settings before importing settings."
        )
        XCTAssertNotNil(coordinator.preview)
        XCTAssertEqual(try harness.profileStore.load().profiles, [profile])
    }

    func testSettingsImportRejectsRetainedApplicationDraftWithoutWritingImportedState() throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        harness.store.applicationSettingsDraftSessionController.retain(
            makeApplicationSettingsDraft(),
            errorMessage: "Application settings are unsaved."
        )
        var importedProfile = profile
        importedProfile.host = "imported.example"
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [importedProfile],
            selectedProfileID: importedProfile.id,
            applicationPreferences: .init()
        ))
        let coordinator = harness.store.settingsPortabilityController
        try coordinator.prepareImport(data, sourceName: "portable.json")
        coordinator.collisionPolicy = .updateMatchingIdentifier

        XCTAssertThrowsError(try coordinator.confirmImport()) { error in
            XCTAssertEqual(
                error as? SettingsPortabilityCoordinatorError,
                .commitRejected(
                    "Save or revert the unsaved Application settings before importing settings."
                )
            )
            coordinator.present(error: error)
        }

        XCTAssertEqual(
            coordinator.errorMessage,
            "Save or revert the unsaved Application settings before importing settings."
        )
        XCTAssertNotNil(coordinator.preview)
        XCTAssertEqual(try harness.profileStore.load().profiles, [profile])
    }

    func testSettingsImportRejectsUnsavedDaemonDraftWithoutWritingImportedState() async throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        await harness.store.connect()
        let daemonSettings = harness.store.daemonOptionsSettingsController
        var daemonDraft = try XCTUnwrap(daemonSettings.draft)
        daemonDraft.downloadDirectory = "/unsaved"
        daemonSettings.updateDraft(daemonDraft)
        var importedProfile = profile
        importedProfile.host = "imported.example"
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [importedProfile],
            selectedProfileID: importedProfile.id,
            applicationPreferences: .init()
        ))
        let coordinator = harness.store.settingsPortabilityController
        try coordinator.prepareImport(data, sourceName: "portable.json")
        coordinator.collisionPolicy = .updateMatchingIdentifier

        XCTAssertThrowsError(try coordinator.confirmImport()) { error in
            XCTAssertEqual(
                error as? SettingsPortabilityCoordinatorError,
                .commitRejected(
                    "Apply or revert the unsaved Transmission settings before importing settings."
                )
            )
        }

        XCTAssertNotNil(coordinator.preview)
        XCTAssertEqual(try harness.profileStore.load().profiles, [profile])
        XCTAssertEqual(daemonSettings.draft?.downloadDirectory, "/unsaved")
        harness.store.disconnect()
    }

    func testSettingsImportAppliesSidebarGroupingToObservedWorkspaceStore() throws {
        let profile = makeProfile(name: "Saved", host: "saved.example")
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        let existingWorkspace = harness.store.workspacePreferencesController.preferences
        let importedWorkspace = UIWorkspacePreferences(
            sidebarGrouping: SidebarGroupingPreferences(
                showsTrackers: false,
                showsLabels: true,
                showsDownloadFolders: false
            ),
            sidebarWidth: existingWorkspace.sidebarWidth,
            infoPane: existingWorkspace.infoPane,
            mainWindow: existingWorkspace.mainWindow,
            secondaryTables: existingWorkspace.secondaryTables
        )
        let data = try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: [profile],
            selectedProfileID: profile.id,
            applicationPreferences: SettingsExportPreferences(workspace: importedWorkspace)
        ))
        let coordinator = harness.store.settingsPortabilityController
        try coordinator.prepareImport(data, sourceName: "portable.json")

        let result = try coordinator.confirmImport()

        XCTAssertEqual(
            result.preferences.workspace.sidebarGrouping,
            importedWorkspace.sidebarGrouping
        )
        XCTAssertEqual(
            harness.store.workspacePreferencesController.preferences.sidebarGrouping,
            importedWorkspace.sidebarGrouping
        )
    }

    func testMalformedPersistedProfilesRequireSetupWithoutConnectingPlaceholder() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(to: fileURL)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let store = AppStore(
            profileStore: ConnectionProfileStore(
                fileURL: fileURL,
                passwordStore: ConnectionTestPasswordStore()
            ),
            userDefaults: temporaryUserDefaults(),
            downloadCompletionNotifier: ConnectionTestNotifier()
        )

        await store.start()

        XCTAssertTrue(store.needsConnectionSetup)
        XCTAssertEqual(store.connectionState, .disconnected)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(recorder.requests.isEmpty)
    }

    func testStartPresentsPasswordPromptWithoutSendingRPC() async throws {
        let profile = makeProfile(name: "Protected", host: "protected.example", username: "user")
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)

        await harness.store.start()

        XCTAssertEqual(harness.store.passwordPrompt?.profileID, profile.id)
        XCTAssertEqual(harness.store.passwordPrompt?.savesPassword, true)
        XCTAssertTrue(recorder.requests.isEmpty)
        XCTAssertEqual(harness.store.connectionState, .disconnected)
    }

    func testSwitchProfilePersistsSelectionAndConnectsImmediately() async throws {
        let first = makeProfile(name: "First", host: "first.example")
        let second = makeProfile(name: "Second", host: "second.example")
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [first, second], selectedProfileID: first.id)

        await harness.store.switchProfile(to: second.id)
        let persisted = try harness.profileStore.load()

        XCTAssertEqual(harness.store.selectedProfileID, second.id)
        XCTAssertEqual(persisted.selectedProfileID, second.id)
        XCTAssertEqual(recorder.count(host: second.host, method: "session-get"), 1)
        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        harness.store.disconnect()
    }

    func testSwitchDuringInFlightConnectRejectsOldAttempt() async throws {
        let first = makeProfile(name: "First", host: "first.example")
        let second = makeProfile(name: "Second", host: "second.example")
        let firstRequestStarted = expectation(description: "first profile connection started")
        let firstRequestGate = DispatchSemaphore(value: 0)
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let host = request.url?.host
            recorder.record(host: host, method: action.method)
            if host == first.host, action.method == "session-get" {
                firstRequestStarted.fulfill()
                _ = firstRequestGate.wait(timeout: .now() + 2)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [first, second],
            selectedProfileID: first.id,
            createsSeparateClientSessions: true
        )

        let firstStart = Task { await harness.store.start() }
        await fulfillment(of: [firstRequestStarted], timeout: 1)
        await harness.store.switchProfile(to: second.id)
        firstRequestGate.signal()
        await firstStart.value

        XCTAssertEqual(harness.store.selectedProfileID, second.id)
        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(recorder.count(host: first.host, method: "torrent-get"), 0)
        XCTAssertEqual(recorder.count(host: second.host, method: "session-get"), 1)
        XCTAssertGreaterThanOrEqual(recorder.count(host: second.host, method: "torrent-get"), 1)
        harness.store.disconnect()
    }

    func testStalePasswordPromptCannotConnectAfterProfileSwitch() async throws {
        let first = makeProfile(name: "Protected", host: "protected.example", username: "user")
        let second = makeProfile(name: "Second", host: "second.example")
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [first, second], selectedProfileID: first.id)
        await harness.store.start()
        let stalePrompt = try XCTUnwrap(harness.store.passwordPrompt)

        await harness.store.switchProfile(to: second.id)
        await harness.store.connectWithPromptPassword("stale-password", for: stalePrompt)

        XCTAssertNil(harness.store.passwordPrompt)
        XCTAssertEqual(harness.store.selectedProfileID, second.id)
        XCTAssertEqual(recorder.count(host: first.host, method: "session-get"), 0)
        XCTAssertEqual(recorder.count(host: second.host, method: "session-get"), 1)
        XCTAssertNil(harness.passwordStore.rawPassword(for: first.id))
        harness.store.disconnect()
    }

    func testPromptedPasswordIsSavedOnlyAfterSuccessfulSessionGet() async throws {
        let profile = makeProfile(name: "Protected", host: "protected.example", username: "user")
        let warmupStarted = expectation(description: "initial torrent warmup started")
        let warmupGate = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            if action.method == "torrent-get" {
                warmupStarted.fulfill()
                _ = warmupGate.wait(timeout: .now() + 2)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        await harness.store.start()
        let prompt = try XCTUnwrap(harness.store.passwordPrompt)

        let connection = Task {
            await harness.store.connectWithPromptPassword("correct-password", for: prompt)
        }
        await fulfillment(of: [warmupStarted], timeout: 1)

        XCTAssertEqual(harness.passwordStore.rawPassword(for: profile.id), "correct-password")
        XCTAssertEqual(harness.passwordStore.setValues(for: profile.id), ["correct-password"])
        warmupGate.signal()
        await connection.value
        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        harness.store.disconnect()
    }

    func testFailedPromptedAuthenticationDoesNotReplaceStoredPassword() async throws {
        let profile = makeProfile(name: "Protected", host: "protected.example", username: "user")
        let passwordStore = ConnectionTestPasswordStore(
            passwords: [profile.id: "known-good-password"],
            hidesPasswordsOnRead: true
        )
        AppStoreMockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 401,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        let harness = try makeHarness(
            profiles: [profile],
            selectedProfileID: profile.id,
            passwordStore: passwordStore,
            seedThroughStore: false
        )
        await harness.store.start()
        let prompt = try XCTUnwrap(harness.store.passwordPrompt)

        await harness.store.connectWithPromptPassword("mistyped-password", for: prompt)

        guard case .failed = harness.store.connectionState else {
            return XCTFail("Expected failed connection state")
        }
        XCTAssertEqual(passwordStore.rawPassword(for: profile.id), "known-good-password")
        XCTAssertTrue(passwordStore.setValues(for: profile.id).isEmpty)
    }

    func testAskEveryTimePasswordIsNeverPersisted() async throws {
        let profile = makeProfile(
            name: "Ask",
            host: "ask.example",
            username: "user",
            askPasswordAtConnect: true
        )
        AppStoreMockURLProtocol.requestHandler = { request in
            appStoreRPCResponse(for: try request.decodedActionBody().method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        await harness.store.start()
        let prompt = try XCTUnwrap(harness.store.passwordPrompt)

        await harness.store.connectWithPromptPassword("one-use-password", for: prompt)

        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        XCTAssertNil(harness.passwordStore.rawPassword(for: profile.id))
        XCTAssertTrue(harness.passwordStore.setValues(for: profile.id).isEmpty)
        harness.store.disconnect()
    }

    func testApplyingActiveProfileChangeDuringConnectRejectsOldAttemptAndReconnects() async throws {
        let profile = makeProfile(name: "Server", host: "old.example")
        let oldRequestStarted = expectation(description: "old profile connection started")
        let oldRequestGate = DispatchSemaphore(value: 0)
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let host = request.url?.host
            recorder.record(host: host, method: action.method)
            if host == profile.host, action.method == "session-get" {
                oldRequestStarted.fulfill()
                _ = oldRequestGate.wait(timeout: .now() + 2)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [profile],
            selectedProfileID: profile.id,
            createsSeparateClientSessions: true
        )
        let latestConnectionState = LockedValue(harness.store.connectionState)
        let disconnectedBeforePersistence = LockedValue<[Bool]>([])
        let stateObservation = harness.store.$connectionState.sink { state in
            latestConnectionState.set(state)
        }
        defer { stateObservation.cancel() }
        harness.passwordStore.setBeforeSetPassword {
            disconnectedBeforePersistence.mutate {
                $0.append(latestConnectionState.value == .disconnected)
            }
            oldRequestGate.signal()
            Thread.sleep(forTimeInterval: 0.05)
        }
        let firstStart = Task { await harness.store.start() }
        await fulfillment(of: [oldRequestStarted], timeout: 1)
        var editedProfile = profile
        editedProfile.host = "new.example"
        editedProfile.password = "new-password"

        harness.store.applyConnectionProfiles([editedProfile], selectedProfileID: editedProfile.id)
        await firstStart.value
        let reconnected = await waitUntil {
            harness.store.connectionState == .connected(rpcVersion: 18)
                && recorder.count(host: editedProfile.host, method: "torrent-get") > 0
        }

        XCTAssertTrue(reconnected)
        XCTAssertEqual(disconnectedBeforePersistence.value, [false])
        XCTAssertEqual(harness.store.selectedProfile.host, editedProfile.host)
        XCTAssertEqual(recorder.count(host: profile.host, method: "torrent-get"), 0)
        XCTAssertEqual(recorder.count(host: editedProfile.host, method: "session-get"), 1)
        harness.store.disconnect()
    }

    func testApplyingActiveProfileChangeWhilePasswordPromptIsOpenReconnects() async throws {
        let profile = makeProfile(name: "Protected", host: "old.example", username: "user")
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        await harness.store.start()
        XCTAssertNotNil(harness.store.passwordPrompt)

        var editedProfile = profile
        editedProfile.host = "new.example"
        editedProfile.username = ""
        harness.store.applyConnectionProfiles([editedProfile], selectedProfileID: editedProfile.id)
        let reconnected = await waitUntil {
            harness.store.connectionState == .connected(rpcVersion: 18)
        }

        XCTAssertTrue(reconnected)
        XCTAssertNil(harness.store.passwordPrompt)
        XCTAssertEqual(harness.store.selectedProfile.host, editedProfile.host)
        XCTAssertEqual(recorder.count(host: profile.host, method: "session-get"), 0)
        XCTAssertEqual(recorder.count(host: editedProfile.host, method: "session-get"), 1)
        harness.store.disconnect()
    }

    func testRapidPrimaryActionSupersedesEarlierPropertiesLoad() async throws {
        let profile = makeProfile(name: "Server", host: "server.example")
        let firstPropertiesRequestStarted = expectation(description: "first properties request started")
        let firstPropertiesRequestGate = DispatchSemaphore(value: 0)
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let hash = action.arguments["ids"]?.arrayValue?.first?.stringValue
            let torrentID = [1, 2].first { connectionTestHash(id: $0) == hash }
            let fields = action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if action.method == "torrent-get", fields.contains("seedRatioMode"), let torrentID {
                if torrentID == 1 {
                    firstPropertiesRequestStarted.fulfill()
                    _ = firstPropertiesRequestGate.wait(timeout: .now() + 2)
                }
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":\#(torrentID),"hashString":"\#(connectionTestHash(id: torrentID))","name":"Torrent \#(torrentID)"}]}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [profile],
            selectedProfileID: profile.id,
            createsSeparateClientSessions: true
        )
        await harness.store.connect()
        harness.store.torrents = [
            connectionTestTorrent(id: 1),
            connectionTestTorrent(id: 2),
        ]

        let firstAction = Task {
            await harness.store.performPrimaryTorrentAction(in: [1])
        }
        await fulfillment(of: [firstPropertiesRequestStarted], timeout: 1)
        let secondAction = Task {
            await harness.store.performPrimaryTorrentAction(in: [2])
        }
        await Task.yield()
        firstPropertiesRequestGate.signal()
        await firstAction.value
        await secondAction.value
        let secondLoaded = await waitUntil {
            harness.store.torrentPropertiesEditor?.torrentIDs == [2]
        }

        XCTAssertTrue(secondLoaded)
        XCTAssertEqual(harness.store.torrentPropertiesEditor?.torrentIDs, [2])
        XCTAssertEqual(harness.store.torrentPropertiesEditor?.torrentName, "Torrent 2")
        harness.store.disconnect()
    }

    func testPropertiesLoadRejectsReusedNumericIDWithoutReconnect() async throws {
        let profile = makeProfile(name: "Server", host: "server.example")
        let started = expectation(description: "properties request started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let fields = action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if action.method == "torrent-get", fields.contains("seedRatioMode") {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 2)
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"\#(connectionTestHash(id: 1))","name":"Original"}]}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        await harness.store.connect()
        defer { harness.store.disconnect() }
        harness.store.torrents = [connectionTestTorrent(id: 1)]
        harness.store.selectedTorrentIDs = [1]
        let load = Task { await harness.store.requestEditSelectedTorrentProperties() }
        await fulfillment(of: [started], timeout: 1)

        harness.store.torrents = [connectionTestTorrent(id: 1, hash: connectionTestHash(id: 2))]
        gate.signal()
        await load.value

        XCTAssertTrue(harness.store.connectionState.isConnected)
        XCTAssertEqual(harness.store.selectedTorrentIDs, [1])
        XCTAssertNil(harness.store.torrentPropertiesEditor)
        XCTAssertFalse(harness.store.isLoadingTorrentProperties)
    }

    func testPropertiesApplyRejectsReusedNumericIDInOpenEditor() async throws {
        let profile = makeProfile(name: "Server", host: "server.example")
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            let fields = action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if action.method == "torrent-get", fields.contains("seedRatioMode") {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"\#(connectionTestHash(id: 1))","name":"Original"}]}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        await harness.store.connect()
        defer { harness.store.disconnect() }
        harness.store.torrents = [connectionTestTorrent(id: 1)]
        harness.store.selectedTorrentIDs = [1]
        await harness.store.requestEditSelectedTorrentProperties()
        XCTAssertNotNil(harness.store.torrentPropertiesEditor)
        harness.store.torrentPropertiesEditor?.draft.peerLimit = 80

        harness.store.torrents = [connectionTestTorrent(id: 1, hash: connectionTestHash(id: 2))]
        await harness.store.applyTorrentProperties()

        XCTAssertTrue(harness.store.connectionState.isConnected)
        XCTAssertNil(harness.store.torrentPropertiesEditor)
        XCTAssertTrue(harness.store.errorMessage?.contains("Reopen Properties") == true)
        XCTAssertFalse(try recorder.requests.contains { try $0.decodedActionBody().method == "torrent-set" })
    }

    func testPropertiesApplyKeepsFrozenHashTargetsWhenSelectionChanges() async throws {
        let profile = makeProfile(name: "Server", host: "server.example")
        let recorder = AppStoreRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            let fields = action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if action.method == "torrent-get", fields.contains("seedRatioMode") {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"\#(connectionTestHash(id: 1))","name":"Original"}]}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)
        await harness.store.connect()
        defer { harness.store.disconnect() }
        harness.store.torrents = [connectionTestTorrent(id: 1), connectionTestTorrent(id: 2)]
        harness.store.selectedTorrentIDs = [1, 2]
        await harness.store.requestEditSelectedTorrentProperties()
        XCTAssertEqual(harness.store.torrentPropertiesEditor?.torrentIDs, [1, 2])
        harness.store.torrentPropertiesEditor?.draft.peerLimit = 80
        harness.store.selectedTorrentIDs = [2]

        await harness.store.applyTorrentProperties()

        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        let mutation = try XCTUnwrap(actions.first { $0.method == "torrent-set" })
        XCTAssertEqual(mutation.arguments["ids"], .array([1, 2].map { .string(connectionTestHash(id: $0)) }))
        XCTAssertEqual(mutation.arguments["peer-limit"], .int(80))
        XCTAssertNil(harness.store.torrentPropertiesEditor)
    }

    func testPropertiesSuccessDiscardsReplacedTargetWithoutRefreshingItsNumericID() async throws {
        try await assertPropertiesCompletionIgnoresReplacedTarget(fails: false)
    }

    func testPropertiesFailureDiscardsReplacedTargetWithoutPublishingItsError() async throws {
        try await assertPropertiesCompletionIgnoresReplacedTarget(fails: true)
    }

    func testPropertiesCompletionCannotCloseANewerEditorForReplacementTorrent() async throws {
        for fails in [false, true] {
            try await assertPropertiesCompletionIgnoresReplacedTarget(fails: fails, opensNewEditor: true)
        }
    }

    func testPropertiesLoadFailureDoesNotPublishAfterOrdinarySelectionChange() async throws {
        let profile = makeProfile(name: "Server", host: "server.example")
        let started = expectation(description: "properties load started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let fields = action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if action.method == "torrent-get", fields.contains("seedRatioMode") {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 2)
                return rpcTestResponse(body: #"{"result":"delayed original failure"}"#)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [profile], selectedProfileID: profile.id,
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock())
        )
        await harness.store.connect()
        defer { harness.store.disconnect() }
        harness.store.isTorrentDetailVisible = false
        harness.store.torrents = [connectionTestTorrent(id: 1), connectionTestTorrent(id: 2)]
        harness.store.selectedTorrentIDs = [1]
        let load = Task { await harness.store.requestEditSelectedTorrentProperties() }
        await fulfillment(of: [started], timeout: 1)

        harness.store.selectedTorrentIDs = [2]
        harness.store.errorMessage = "Current selection notice"
        gate.signal()
        await load.value

        XCTAssertEqual(harness.store.errorMessage, "Current selection notice")
        XCTAssertNil(harness.store.torrentPropertiesEditor)
        XCTAssertFalse(harness.store.isLoadingTorrentProperties)
    }

    private func assertPropertiesCompletionIgnoresReplacedTarget(
        fails: Bool,
        opensNewEditor: Bool = false
    ) async throws {
        let profile = makeProfile(name: "Server", host: "server.example")
        let recorder = AppStoreRequestRecorder()
        let started = expectation(description: "properties mutation started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        AppStoreMockURLProtocol.requestHandler = { request in
            recorder.record(request)
            let action = try request.decodedActionBody()
            if action.method == "torrent-set" {
                started.fulfill()
                _ = gate.wait(timeout: .now() + 2)
                return rpcTestResponse(body: fails
                    ? #"{"result":"delayed original failure"}"#
                    : #"{"result":"success"}"#)
            }
            let fields = action.arguments["fields"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if action.method == "torrent-get", fields.contains("seedRatioMode"),
               let hash = action.arguments["ids"]?.arrayValue?.first?.stringValue {
                return rpcTestResponse(
                    body: #"{"result":"success","arguments":{"torrents":[{"id":1,"hashString":"\#(hash)","name":"Torrent"}]}}"#
                )
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [profile], selectedProfileID: profile.id,
            pollingCoordinator: PollingCoordinator(clock: TestPollingClock())
        )
        await harness.store.connect()
        defer { harness.store.disconnect() }
        harness.store.isTorrentDetailVisible = false
        harness.store.torrents = [connectionTestTorrent(id: 1)]
        harness.store.selectedTorrentIDs = [1]
        await harness.store.requestEditSelectedTorrentProperties()
        XCTAssertNotNil(harness.store.torrentPropertiesEditor)
        harness.store.torrentPropertiesEditor?.draft.peerLimit = 80
        let apply = Task { await harness.store.applyTorrentProperties() }
        await fulfillment(of: [started], timeout: 1)
        XCTAssertEqual(harness.store.torrentPropertiesEditor?.isApplying, true)

        let replacementHash = connectionTestHash(id: 2)
        harness.store.torrents = [connectionTestTorrent(id: 1, hash: replacementHash)]
        var newEditorID: UUID?
        if opensNewEditor {
            harness.store.cancelTorrentPropertiesEditing()
            await harness.store.requestEditSelectedTorrentProperties()
            newEditorID = try XCTUnwrap(harness.store.torrentPropertiesEditor?.id)
        }
        harness.store.errorMessage = "Replacement notice"
        let requestCountBeforeCompletion = recorder.requests.count
        gate.signal()
        await apply.value
        await Task.yield()

        XCTAssertTrue(harness.store.connectionState.isConnected)
        XCTAssertEqual(harness.store.torrentPropertiesEditor?.id, newEditorID)
        XCTAssertNotEqual(harness.store.torrentPropertiesEditor?.isApplying, true)
        XCTAssertEqual(harness.store.errorMessage, "Replacement notice")
        XCTAssertEqual(harness.store.torrents.first?.hashString, replacementHash)
        XCTAssertEqual(recorder.requests.count, requestCountBeforeCompletion)
        let actions = try recorder.requests.map { try $0.decodedActionBody() }
        let mutation = try XCTUnwrap(actions.first { $0.method == "torrent-set" })
        XCTAssertEqual(mutation.arguments["ids"], .array([.string(connectionTestHash(id: 1))]))
    }

    func testStaleDaemonOptionsResponseCannotOverwriteSwitchedProfile() async throws {
        let first = makeProfile(name: "First", host: "first.example")
        let second = makeProfile(name: "Second", host: "second.example")
        let sessionSetStarted = expectation(description: "daemon options update started")
        let sessionSetGate = DispatchSemaphore(value: 0)
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let host = request.url?.host
            recorder.record(host: host, method: action.method)
            if host == first.host, action.method == "session-set" {
                sessionSetStarted.fulfill()
                _ = sessionSetGate.wait(timeout: .now() + 2)
            }
            if action.method == "session-get" {
                return connectionSessionResponse(downloadDirectory: host == second.host ? "/second" : "/first")
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [first, second],
            selectedProfileID: first.id,
            createsSeparateClientSessions: true
        )
        await harness.store.connect()
        XCTAssertEqual(harness.store.sessionInfo?.downloadDir, "/first")

        let optionsUpdate = Task {
            await harness.store.applyDaemonOptions(
                DaemonOptionsUpdate(downloadDirectory: "/changed")
            )
        }
        await fulfillment(of: [sessionSetStarted], timeout: 1)
        await harness.store.switchProfile(to: second.id)
        XCTAssertEqual(harness.store.sessionInfo?.downloadDir, "/second")
        sessionSetGate.signal()
        let result = await optionsUpdate.value

        XCTAssertEqual(result, .rejected(.connectionChanged))
        XCTAssertEqual(harness.store.selectedProfileID, second.id)
        XCTAssertEqual(harness.store.sessionInfo?.downloadDir, "/second")
        XCTAssertEqual(harness.store.connectionState, .connected(rpcVersion: 18))
        XCTAssertEqual(recorder.count(host: first.host, method: "session-get"), 1)
        XCTAssertNil(harness.store.errorMessage)
        harness.store.disconnect()
    }

    func testDisconnectedDaemonOptionsApplyReturnsExactGuardRejection() async throws {
        let profile = makeProfile(name: "Disconnected", host: "disconnected.example")
        let harness = try makeHarness(
            profiles: [profile],
            selectedProfileID: profile.id
        )

        let result = await harness.store.applyDaemonOptions(
            DaemonOptionsUpdate(downloadDirectory: "/changed")
        )

        XCTAssertEqual(result, .rejected(.notConnected))
        XCTAssertNil(harness.store.errorMessage)
    }

    func testProfileChangesAndDisconnectCapabilityAreBlockedDuringRemoval() async throws {
        let first = makeProfile(name: "First", host: "first.example")
        let second = makeProfile(name: "Second", host: "second.example")
        let removalStarted = expectation(description: "torrent removal started")
        let removalGate = DispatchSemaphore(value: 0)
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            recorder.record(host: request.url?.host, method: action.method)
            if action.method == "torrent-remove" {
                removalStarted.fulfill()
                _ = removalGate.wait(timeout: .now() + 2)
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [first, second],
            selectedProfileID: first.id,
            createsSeparateClientSessions: true
        )
        await harness.store.connect()
        harness.store.torrents = [connectionTestTorrent()]
        harness.store.selectedTorrentIDs = [1]
        harness.store.requestRemoveSelected()
        let confirmation = try XCTUnwrap(harness.store.removalConfirmation)
        let removal = Task {
            await harness.store.confirmRemoval(confirmation)
        }
        await fulfillment(of: [removalStarted], timeout: 1)
        XCTAssertTrue(harness.store.isRemoving)
        XCTAssertFalse(harness.store.canDisconnect)

        await harness.store.switchProfile(to: second.id)
        var editedFirst = first
        editedFirst.host = "edited.example"
        harness.store.applyConnectionProfiles(
            [editedFirst, second],
            selectedProfileID: second.id
        )
        let persisted = try harness.profileStore.load()

        XCTAssertEqual(harness.store.selectedProfileID, first.id)
        XCTAssertEqual(harness.store.selectedProfile.host, first.host)
        XCTAssertEqual(persisted.selectedProfileID, first.id)
        XCTAssertEqual(persisted.selectedProfile.host, first.host)
        XCTAssertEqual(recorder.count(host: second.host, method: "session-get"), 0)
        removalGate.signal()
        await removal.value
        XCTAssertFalse(harness.store.isRemoving)
        harness.store.disconnect()
    }

    func testEditingFailedActiveProfileReconnectsButDisconnectedEditDoesNot() async throws {
        let failedProfile = makeProfile(name: "Server", host: "failed.example")
        let recorder = ConnectionRequestRecorder()
        AppStoreMockURLProtocol.requestHandler = { request in
            let action = try request.decodedActionBody()
            let host = request.url?.host
            recorder.record(host: host, method: action.method)
            if host == failedProfile.host, action.method == "session-get" {
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (response, Data())
            }
            return appStoreRPCResponse(for: action.method)
        }
        let harness = try makeHarness(
            profiles: [failedProfile],
            selectedProfileID: failedProfile.id,
            createsSeparateClientSessions: true
        )
        await harness.store.connect()
        guard case .failed = harness.store.connectionState else {
            return XCTFail("Expected initial connection failure")
        }
        var recoveredProfile = failedProfile
        recoveredProfile.host = "recovered.example"

        harness.store.applyConnectionProfiles(
            [recoveredProfile],
            selectedProfileID: recoveredProfile.id
        )
        let reconnected = await waitUntil {
            harness.store.connectionState == .connected(rpcVersion: 18)
                && recorder.count(host: recoveredProfile.host, method: "session-get") == 1
        }

        XCTAssertTrue(reconnected)
        XCTAssertEqual(harness.store.selectedProfile.host, recoveredProfile.host)
        harness.store.disconnect()
        var disconnectedEdit = recoveredProfile
        disconnectedEdit.host = "disconnected.example"
        harness.store.applyConnectionProfiles(
            [disconnectedEdit],
            selectedProfileID: disconnectedEdit.id
        )
        await Task.yield()
        XCTAssertEqual(harness.store.connectionState, .disconnected)
        XCTAssertEqual(recorder.count(host: disconnectedEdit.host, method: "session-get"), 0)
    }

    func testConnectionCapabilitiesMatchConnectionState() throws {
        let profile = makeProfile(name: "Server", host: "server.example")
        let harness = try makeHarness(profiles: [profile], selectedProfileID: profile.id)

        harness.store.connectionState = .disconnected
        XCTAssertTrue(harness.store.canConnect)
        XCTAssertFalse(harness.store.canDisconnect)

        harness.store.connectionState = .connecting
        XCTAssertFalse(harness.store.canConnect)
        XCTAssertTrue(harness.store.canDisconnect)

        harness.store.connectionState = .connected(rpcVersion: 18)
        XCTAssertFalse(harness.store.canConnect)
        XCTAssertTrue(harness.store.canDisconnect)

        harness.store.connectionState = .failed("No route")
        XCTAssertTrue(harness.store.canConnect)
        XCTAssertFalse(harness.store.canDisconnect)
    }

    private func makeHarness(
        profiles: [ConnectionProfile],
        selectedProfileID: ConnectionProfile.ID,
        passwordStore: ConnectionTestPasswordStore = ConnectionTestPasswordStore(),
        seedThroughStore: Bool = true,
        createsProfileFile: Bool = true,
        createsSeparateClientSessions: Bool = false,
        fileWriter: any ConnectionProfileFileWriting = AtomicConnectionProfileFileWriter(),
        pollingCoordinator: PollingCoordinator? = nil
    ) throws -> ConnectionTestHarness {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directoryURL.appendingPathComponent("profiles.json")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directoryURL)
        }
        let profileStore = ConnectionProfileStore(
            fileURL: fileURL,
            passwordStore: passwordStore,
            fileWriter: fileWriter
        )
        let collection = try ConnectionProfileCollection(
            profiles: profiles,
            selectedProfileID: selectedProfileID
        )
        if createsProfileFile {
            if seedThroughStore {
                try profileStore.save(collection)
            } else {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                let encoder = JSONEncoder()
                try encoder.encode(collection).write(to: fileURL, options: .atomic)
            }
        }
        passwordStore.resetWrites()
        let sharedSession = makeAppStoreMockSession()
        let store = AppStore(
            profileStore: profileStore,
            userDefaults: temporaryUserDefaults(),
            downloadCompletionNotifier: ConnectionTestNotifier(),
            pollingCoordinator: pollingCoordinator ?? PollingCoordinator(),
            selectionDebounceDuration: .zero,
            clientFactory: { profile in
                let session = createsSeparateClientSessions ? makeAppStoreMockSession() : sharedSession
                return TransmissionRPCClient(profile: profile, urlSession: session)
            }
        )
        return ConnectionTestHarness(
            store: store,
            profileStore: profileStore,
            passwordStore: passwordStore
        )
    }

    private func temporaryUserDefaults() -> UserDefaults {
        let suiteName = "AppStoreConnectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeApplicationSettingsDraft() -> ApplicationSettingsDraft {
        ApplicationSettingsDraft(
            polling: ApplicationPollingSettingsDraft(
                foregroundInterval: "5",
                backgroundInterval: "20",
                backgroundPolicy: .pollSlowly,
                adaptiveIdleEnabled: false
            ),
            behavior: ApplicationBehaviorSettingsDraft(
                speedAveragingEnabled: false,
                speedAverageSampleLimit: "20",
                speedAverageWindowSeconds: "120",
                completionNotificationsEnabled: true,
                addStartIntent: .start,
                addPriority: .normal,
                addUnwantedFiles: .daemonDefault,
                addPeerLimit: ""
            ),
            intake: ApplicationIntakeSettingsDraft(
                clipboardIntakeEnabled: false,
                sourceTorrentDeletion: .never,
                automaticUpdateChecksEnabled: false,
                automaticUpdateCadenceHours: "24"
            ),
            watchFolder: ApplicationWatchFolderSettingsDraft(
                isEnabled: false,
                sourceBookmarkData: nil,
                remoteDestination: "",
                scanInterval: "60",
                successPolicy: .keepSource,
                processedFolderBookmarkData: nil
            ),
            sidebarGrouping: .defaults,
            interaction: .defaults,
            peerResolution: .defaults
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

private struct ConnectionTestHarness {
    let store: AppStore
    let profileStore: ConnectionProfileStore
    let passwordStore: ConnectionTestPasswordStore
}

private final class ConnectionApplyTestFileWriter: ConnectionProfileFileWriting {
    var error: (any Error)?

    func write(_ data: Data, to fileURL: URL) throws {
        if let error {
            throw error
        }
        try data.write(to: fileURL, options: .atomic)
    }
}

private enum ConnectionApplyTestError: LocalizedError, Equatable {
    case diskFull

    var errorDescription: String? {
        "The profile store is full."
    }
}

private func makeProfile(
    name: String,
    host: String,
    username: String = "",
    askPasswordAtConnect: Bool = false
) -> ConnectionProfile {
    ConnectionProfile(
        name: name,
        host: host,
        username: username,
        askPasswordAtConnect: askPasswordAtConnect
    )
}

private func connectionSessionResponse(downloadDirectory: String) -> (HTTPURLResponse, Data) {
    rpcTestResponse(
        body: #"{"result":"success","arguments":{"rpc-version":18,"version":"4.0","download-dir":"\#(downloadDirectory)"}}"#
    )
}

private func connectionTestHash(id: Int) -> String {
    String(format: "%040llx", Int64(id))
}

private func connectionTestTorrent(id: Int = 1, hash: String? = nil) -> TorrentSummary {
    TorrentSummary(json: [
        "id": .int(id),
        "name": .string("Torrent \(id)"),
        "status": .int(TorrentStatus.stopped.rawValue),
        "percentDone": .double(0.5),
        "totalSize": .int(100),
        "sizeWhenDone": .int(100),
        "leftUntilDone": .int(50),
        "hashString": .string(hash ?? connectionTestHash(id: id)),
        "downloadDir": .string("/downloads"),
        "trackerStats": .array([])
    ])
}

private final class ConnectionRequestRecorder {
    struct Request: Equatable {
        var host: String?
        var method: String
    }

    private let lock = NSLock()
    private var recordedRequests: [Request] = []

    var requests: [Request] {
        lock.withLock { recordedRequests }
    }

    func record(host: String?, method: String) {
        lock.withLock {
            recordedRequests.append(Request(host: host, method: method))
        }
    }

    func count(host: String, method: String) -> Int {
        requests.filter { $0.host == host && $0.method == method }.count
    }
}

private final class ConnectionTestPasswordStore: ConnectionPasswordStoring {
    enum Write: Equatable {
        case set(ConnectionProfile.ID, String)
        case remove(ConnectionProfile.ID)
    }

    private let lock = NSLock()
    private var passwords: [ConnectionProfile.ID: String]
    private var writes: [Write] = []
    private var beforeSetPassword: (() -> Void)?
    private let hidesPasswordsOnRead: Bool

    init(
        passwords: [ConnectionProfile.ID: String] = [:],
        hidesPasswordsOnRead: Bool = false
    ) {
        self.passwords = passwords
        self.hidesPasswordsOnRead = hidesPasswordsOnRead
    }

    func password(for profileID: ConnectionProfile.ID) throws -> String? {
        lock.withLock {
            hidesPasswordsOnRead ? nil : passwords[profileID]
        }
    }

    func setPassword(_ password: String, for profileID: ConnectionProfile.ID) throws {
        let callback = lock.withLock { beforeSetPassword }
        callback?()
        lock.withLock {
            passwords[profileID] = password
            writes.append(.set(profileID, password))
        }
    }

    func removePassword(for profileID: ConnectionProfile.ID) throws {
        lock.withLock {
            passwords.removeValue(forKey: profileID)
            writes.append(.remove(profileID))
        }
    }

    func rawPassword(for profileID: ConnectionProfile.ID) -> String? {
        lock.withLock { passwords[profileID] }
    }

    func setValues(for profileID: ConnectionProfile.ID) -> [String] {
        lock.withLock {
            writes.compactMap { write in
                guard case .set(let writtenProfileID, let value) = write, writtenProfileID == profileID else {
                    return nil
                }
                return value
            }
        }
    }

    func resetWrites() {
        lock.withLock {
            writes.removeAll()
        }
    }

    func setBeforeSetPassword(_ callback: @escaping () -> Void) {
        lock.withLock {
            beforeSetPassword = callback
        }
    }
}

private final class ConnectionTestNotifier: DownloadCompletionNotifying {
    func notifyDownloadCompleted(torrentName: String) {}
}

private final class LockedValue<Value> {
    private let lock = NSLock()
    private var storedValue: Value

    init(_ value: Value) {
        storedValue = value
    }

    var value: Value {
        lock.withLock { storedValue }
    }

    func set(_ value: Value) {
        lock.withLock {
            storedValue = value
        }
    }

    func mutate(_ mutation: (inout Value) -> Void) {
        lock.withLock {
            mutation(&storedValue)
        }
    }
}
