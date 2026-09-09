// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class WatchFolderPreferencesTests: XCTestCase {
    func testConfigurationUsesOpaqueBookmarksAndBoundsScanInterval() throws {
        let sourceBookmark = Data([0x01, 0x02, 0x03])
        let processedBookmark = Data([0x04, 0x05, 0x06])
        let configuration = WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: sourceBookmark,
            remoteDestination: "/srv/incoming",
            scanIntervalSeconds: Int.max,
            successPolicy: .moveSource,
            processedFolderBookmarkData: processedBookmark
        )

        XCTAssertTrue(configuration.isReadyToScan)
        XCTAssertEqual(configuration.sourceBookmarkData, sourceBookmark)
        XCTAssertEqual(configuration.processedFolderBookmarkData, processedBookmark)
        XCTAssertEqual(configuration.submissionPolicy, .confirmBeforeAdding)
        XCTAssertEqual(
            configuration.scanIntervalSeconds,
            WatchFolderConfiguration.allowedScanIntervalSeconds.upperBound
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration))
                as? [String: Any]
        )
        XCTAssertNil(object["sourcePath"])
        XCTAssertNil(object["processedFolderPath"])
        XCTAssertFalse(String(describing: object).contains("/Users/"))
    }

    func testConfigurationRequiresAllOptInCapabilitiesBeforeScanning() {
        let bookmark = Data([0x01])

        XCTAssertFalse(WatchFolderConfiguration(
            isEnabled: false,
            sourceBookmarkData: bookmark,
            remoteDestination: "/downloads",
            scanIntervalSeconds: 60,
            successPolicy: .keepSource,
            processedFolderBookmarkData: nil
        ).isReadyToScan)
        XCTAssertFalse(WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: nil,
            remoteDestination: "/downloads",
            scanIntervalSeconds: 60,
            successPolicy: .keepSource,
            processedFolderBookmarkData: nil
        ).isReadyToScan)
        XCTAssertFalse(WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: bookmark,
            remoteDestination: "relative",
            scanIntervalSeconds: 60,
            successPolicy: .keepSource,
            processedFolderBookmarkData: nil
        ).isReadyToScan)
        XCTAssertFalse(WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: bookmark,
            remoteDestination: "/downloads",
            scanIntervalSeconds: 60,
            successPolicy: .moveSource,
            processedFolderBookmarkData: nil
        ).isReadyToScan)
    }

    func testRedactedPortabilityNeverExportsBookmarkBytesAndDisablesImport() throws {
        let configuration = WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: Data("private-source-bookmark".utf8),
            remoteDestination: "/srv/watch",
            scanIntervalSeconds: 30,
            successPolicy: .moveSource,
            submissionPolicy: .submitDirectly,
            processedFolderBookmarkData: Data("private-move-bookmark".utf8)
        )

        let redacted = configuration.redactedPortableConfiguration()
        let data = try JSONEncoder().encode(redacted)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertFalse(redacted.isEnabled)
        XCTAssertTrue(redacted.requiresSourceFolderSelection)
        XCTAssertTrue(redacted.requiresProcessedFolderSelection)
        XCTAssertEqual(redacted.remoteDestination, "/srv/watch")
        XCTAssertEqual(redacted.submissionPolicy, .submitDirectly)
        XCTAssertFalse(object.keys.contains { $0.lowercased().contains("bookmark") })
        XCTAssertFalse(encoded.contains("private-source-bookmark"))
        XCTAssertFalse(encoded.contains("private-move-bookmark"))
    }

    func testVersionedCodableRoundTripsAndFutureOrMalformedDataUsesSafeDefaults() throws {
        let configuration = WatchFolderConfiguration(
            isEnabled: true,
            sourceBookmarkData: Data([0x01]),
            remoteDestination: "/srv/watch",
            scanIntervalSeconds: 10,
            successPolicy: .deleteSource,
            submissionPolicy: .submitDirectly,
            processedFolderBookmarkData: nil
        )
        let encoded = try JSONEncoder().encode(configuration)

        XCTAssertEqual(
            try JSONDecoder().decode(WatchFolderConfiguration.self, from: encoded),
            configuration
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WatchFolderConfiguration.self,
                from: Data(#"{"schemaVersion":99,"isEnabled":true}"#.utf8)
            ),
            .defaults
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                WatchFolderConfiguration.self,
                from: Data(#"{"schemaVersion":1,"isEnabled":"bad"}"#.utf8)
            ),
            .defaults
        )
    }

    func testVersionTwoConfigurationAndVersionOnePortableDataMigrateToConfirmation() throws {
        let legacyConfiguration = Data(
            #"{"schemaVersion":2,"isEnabled":true,"sourceBookmarkData":"AQ==","remoteDestination":"/srv/watch","scanIntervalSeconds":30,"successPolicy":"keepSource","configurationRevision":7}"#.utf8
        )
        let legacyPortable = Data(
            #"{"schemaVersion":1,"isEnabled":false,"remoteDestination":"/srv/watch","scanIntervalSeconds":30,"successPolicy":"keepSource","requiresSourceFolderSelection":true,"requiresProcessedFolderSelection":false}"#.utf8
        )
        let invalidPolicyConfiguration = Data(
            #"{"schemaVersion":3,"isEnabled":true,"sourceBookmarkData":"AQ==","remoteDestination":"/srv/watch","scanIntervalSeconds":30,"successPolicy":"keepSource","submissionPolicy":"unknown-future-policy","configurationRevision":7}"#.utf8
        )

        let configuration = try JSONDecoder().decode(
            WatchFolderConfiguration.self,
            from: legacyConfiguration
        )
        let portable = try JSONDecoder().decode(
            RedactedPortableWatchFolderConfiguration.self,
            from: legacyPortable
        )
        let invalidPolicy = try JSONDecoder().decode(
            WatchFolderConfiguration.self,
            from: invalidPolicyConfiguration
        )

        XCTAssertEqual(configuration.submissionPolicy, .confirmBeforeAdding)
        XCTAssertEqual(configuration.configurationRevision, 7)
        XCTAssertEqual(portable.submissionPolicy, .confirmBeforeAdding)
        XCTAssertEqual(portable.schemaVersion, 1)
        XCTAssertEqual(invalidPolicy.submissionPolicy, .confirmBeforeAdding)
    }

    func testDurableFailureQueueIsVisibleDeduplicatedAndBounded() throws {
        let failures = (0 ... WatchFolderFailureQueueState.maximumRetainedFailures).map { index in
            WatchFolderFailureRecord(
                stableFileIdentity: "id-\(index)",
                fileName: "\(index).torrent",
                attemptCount: index + 1,
                firstFailureTime: 1,
                lastFailureTime: 2,
                nextRetryTime: 3,
                errorMessage: String(repeating: "x", count: 600)
            )
        }
        let queue = WatchFolderFailureQueueState(failures: failures)
        let state = WatchFolderProcessingState(failureQueue: queue)
        let roundTrip = try JSONDecoder().decode(
            WatchFolderProcessingState.self,
            from: JSONEncoder().encode(state)
        )

        XCTAssertTrue(queue.isVisible)
        XCTAssertEqual(
            queue.retainedCount,
            WatchFolderFailureQueueState.maximumRetainedFailures
        )
        XCTAssertEqual(
            queue.count,
            WatchFolderFailureQueueState.maximumRetainedFailures + 1
        )
        XCTAssertEqual(queue.overflowedFailureCount, 1)
        XCTAssertEqual(roundTrip, state)
        XCTAssertEqual(queue.failures.last?.errorMessage.count, 500)
    }

    func testFailureQueueKeepsItsRetainedSetStableAfterCapacityIsReached() {
        let retainedFailures = (0 ..< WatchFolderFailureQueueState.maximumRetainedFailures).map {
            failure(identity: "retained-\($0)")
        }
        var queue = WatchFolderFailureQueueState(failures: retainedFailures)
        let retainedIdentities = queue.failures.map(\.stableFileIdentity)

        queue.replace(failure(identity: "overflow-one"))
        queue.replace(failure(identity: "overflow-two"))

        XCTAssertEqual(queue.failures.map(\.stableFileIdentity), retainedIdentities)
        XCTAssertEqual(queue.overflowedFailureCount, 2)
        XCTAssertEqual(
            queue.count,
            WatchFolderFailureQueueState.maximumRetainedFailures + 2
        )
    }

    func testAcknowledgmentRetentionStopsInsteadOfEvictingOlderKeepSourceItems() {
        let retainedIdentities = (0 ..< WatchFolderProcessingState.maximumAcknowledgedIdentities)
            .map { "retained-\($0)" }
        var state = WatchFolderProcessingState(
            acknowledgedFileIdentities: retainedIdentities
        )

        XCTAssertFalse(state.acknowledge("overflow"))
        XCTAssertEqual(state.acknowledgedFileIdentities, retainedIdentities)
        XCTAssertEqual(state.failureQueue.overflowedFailureCount, 1)
        XCTAssertTrue(state.failureQueue.isVisible)
    }

    private func failure(identity: String) -> WatchFolderFailureRecord {
        WatchFolderFailureRecord(
            stableFileIdentity: identity,
            fileName: "\(identity).torrent",
            attemptCount: 1,
            firstFailureTime: 1,
            lastFailureTime: 1,
            nextRetryTime: 2,
            errorMessage: "offline"
        )
    }
}
