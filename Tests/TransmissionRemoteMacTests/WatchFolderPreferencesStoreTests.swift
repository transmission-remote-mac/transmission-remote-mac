// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class WatchFolderPreferencesStoreTests: XCTestCase {
    func testMissingAndMalformedStorageCanonicaliseToDisabledDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        defaults.set(
            Data("not-json".utf8),
            forKey: WatchFolderPreferencesStore.storageKey
        )

        let store = WatchFolderPreferencesStore(userDefaults: defaults)

        XCTAssertEqual(store.snapshot, .defaults)
        XCTAssertEqual(
            try JSONDecoder().decode(
                WatchFolderPreferencesSnapshot.self,
                from: XCTUnwrap(
                    defaults.data(forKey: WatchFolderPreferencesStore.storageKey)
                )
            ),
            .defaults
        )
    }

    func testFutureSchemaBlocksAutomaticStateWritesUntilConfigurationIsExplicitlySaved() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let futureData = Data(#"{"schemaVersion":99,"futureValue":"keep"}"#.utf8)
        defaults.set(futureData, forKey: WatchFolderPreferencesStore.storageKey)
        let store = WatchFolderPreferencesStore(userDefaults: defaults)
        var processingState = WatchFolderProcessingState.defaults
        processingState.acknowledge("automatic")

        try store.saveProcessingState(processingState)

        XCTAssertEqual(store.snapshot, .defaults)
        XCTAssertEqual(defaults.data(forKey: WatchFolderPreferencesStore.storageKey), futureData)
        try store.saveConfiguration(configuration(destination: "/explicit"))
        XCTAssertNotEqual(defaults.data(forKey: WatchFolderPreferencesStore.storageKey), futureData)
    }

    func testConfigurationAndProcessingStatePersistTogether() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = WatchFolderPreferencesStore(userDefaults: defaults)
        let configuration = WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: Data([0x01]),
            remoteDestination: "/srv/incoming",
            scanIntervalSeconds: 30,
            successPolicy: .keepSource,
            submissionPolicy: .submitDirectly,
            processedFolderBookmarkData: nil
        )
        try store.saveConfiguration(configuration)
        let persistedConfiguration = store.configuration
        var processingState = WatchFolderProcessingState.defaults
        processingState.acknowledge("one")

        try store.save(
            configuration: persistedConfiguration,
            processingState: processingState
        )

        let restored = WatchFolderPreferencesStore(userDefaults: defaults)
        XCTAssertEqual(restored.configuration, configuration)
        XCTAssertEqual(restored.processingState, processingState)
    }

    func testStaleCoordinatorSaveCannotOverwriteNewerConfiguration() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = WatchFolderPreferencesStore(userDefaults: defaults)
        try store.saveConfiguration(configuration(destination: "/old"))
        let staleConfiguration = store.configuration
        var staleProcessingState = store.processingState
        staleProcessingState.replaceFailure(failure(identity: "stale"))

        try store.saveConfiguration(configuration(destination: "/new"))
        let currentConfigurationRevision = store.configuration.configurationRevision
        try store.save(
            configuration: staleConfiguration,
            processingState: staleProcessingState
        )

        XCTAssertEqual(store.configuration.remoteDestination, "/new")
        XCTAssertEqual(
            store.configuration.configurationRevision,
            currentConfigurationRevision
        )
        XCTAssertEqual(store.processingState, .defaults)
    }

    func testEqualRevisionDivergentPlannerStateCannotReplaceNewerState() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = WatchFolderPreferencesStore(userDefaults: defaults)
        try store.saveConfiguration(configuration(destination: "/watch"))
        let activeConfiguration = store.configuration
        var firstState = store.processingState
        firstState.replaceFailure(failure(identity: "first"))
        try store.save(
            configuration: activeConfiguration,
            processingState: firstState
        )

        var currentState = firstState
        currentState.replaceFailure(failure(identity: "current"))
        try store.saveProcessingState(currentState)
        var staleBranch = firstState
        staleBranch.replaceFailure(failure(identity: "stale"))
        XCTAssertEqual(staleBranch.revision, currentState.revision)

        try store.save(
            configuration: activeConfiguration,
            processingState: staleBranch
        )

        XCTAssertEqual(store.processingState, currentState)
        XCTAssertNil(store.processingState.failureQueue.failure(for: "stale"))
    }

    func testRetryNowPreservesFailureAndMakesItsDeadlineDue() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let store = WatchFolderPreferencesStore(userDefaults: defaults)
        let failure = WatchFolderFailureRecord(
            stableFileIdentity: "one",
            fileName: "one.torrent",
            attemptCount: 2,
            firstFailureTime: 1,
            lastFailureTime: 2,
            nextRetryTime: 9_999,
            errorMessage: "offline"
        )
        var state = WatchFolderProcessingState.defaults
        state.replaceFailure(failure)
        try store.saveProcessingState(state)

        try store.makeFailuresRetryableNow(at: 50)

        XCTAssertEqual(
            store.processingState.failureQueue.failures.first?.nextRetryTime,
            50
        )
        XCTAssertEqual(
            store.processingState.failureQueue.failures.first?.errorMessage,
            "offline"
        )
    }

    private func configuration(destination: String) -> WatchFolderConfiguration {
        WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: Data([0x01]),
            remoteDestination: destination,
            scanIntervalSeconds: 30,
            successPolicy: .keepSource,
            processedFolderBookmarkData: nil
        )
    }

    private func failure(identity: String) -> WatchFolderFailureRecord {
        WatchFolderFailureRecord(
            stableFileIdentity: identity,
            fileName: "\(identity).torrent",
            attemptCount: 1,
            firstFailureTime: 1,
            lastFailureTime: 1,
            nextRetryTime: 10,
            errorMessage: "offline"
        )
    }
}
