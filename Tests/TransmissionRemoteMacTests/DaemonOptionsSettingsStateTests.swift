// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class DaemonOptionsSettingsStateTests: XCTestCase {
    func testFailureRetainsDirtyDraftAndPublishesExactFailure() throws {
        let session = makeSession(downloadDirectory: "/downloads")
        var state = DaemonOptionsSettingsState()
        state.synchronize(with: session)
        var draft = try XCTUnwrap(state.draft)
        draft.downloadDirectory = "/other"
        state.updateDraft(draft)

        state.beginSubmission()
        state.synchronize(with: session)

        XCTAssertEqual(state.draft?.downloadDirectory, "/other")
        XCTAssertTrue(state.hasChanges(capabilities: session.capabilities))

        state.completeSubmission(with: .failed("permission denied"))

        XCTAssertEqual(state.draft?.downloadDirectory, "/other")
        XCTAssertEqual(state.sourceOptions?.downloadDirectory, "/downloads")
        XCTAssertTrue(state.hasChanges(capabilities: session.capabilities))
        XCTAssertEqual(state.lastApplyResult, .failed("permission denied"))
        XCTAssertFalse(state.isSubmitting)
    }

    func testMatchingDaemonSnapshotRebasesWhileSubmissionIsInFlight() throws {
        let originalSession = makeSession(downloadDirectory: "/downloads")
        var state = DaemonOptionsSettingsState()
        state.synchronize(with: originalSession)
        var draft = try XCTUnwrap(state.draft)
        draft.downloadDirectory = "/other"
        state.updateDraft(draft)

        state.beginSubmission()
        let confirmedSession = makeSession(downloadDirectory: "/other")
        state.synchronize(with: confirmedSession)
        state.completeSubmission(with: .succeeded)

        XCTAssertEqual(state.draft?.downloadDirectory, "/other")
        XCTAssertFalse(state.hasChanges(capabilities: confirmedSession.capabilities))
        XCTAssertEqual(state.lastApplyResult, .succeeded)
    }

    func testSuccessfulSubmissionRebasesUnrelatedDaemonDriftFromLatestSnapshot() throws {
        let originalSession = makeSession(
            downloadDirectory: "/downloads",
            downloadSpeedLimit: 100
        )
        var state = DaemonOptionsSettingsState()
        state.synchronize(with: originalSession)
        var draft = try XCTUnwrap(state.draft)
        draft.downloadDirectory = "/other"
        state.updateDraft(draft)

        state.beginSubmission()
        let confirmedSession = makeSession(
            downloadDirectory: "/other",
            downloadSpeedLimit: 200
        )
        state.synchronize(with: confirmedSession)
        state.completeSubmission(with: .succeeded)

        XCTAssertEqual(state.draft?.downloadDirectory, "/other")
        XCTAssertEqual(state.draft?.downloadSpeedLimitKBps, "200")
        XCTAssertEqual(state.sourceOptions?.downloadSpeedLimit.limitKBps, 200)
        XCTAssertFalse(state.hasChanges(capabilities: confirmedSession.capabilities))
        XCTAssertEqual(state.lastApplyResult, .succeeded)
    }

    private func makeSession(
        downloadDirectory: String,
        downloadSpeedLimit: Int = 100
    ) -> SessionInfo {
        SessionInfo(arguments: [
            "rpc-version": .int(14),
            "version": .string("4.0"),
            "download-dir": .string(downloadDirectory),
            "speed-limit-down-enabled": .bool(false),
            "speed-limit-down": .int(downloadSpeedLimit),
            "speed-limit-up-enabled": .bool(false),
            "speed-limit-up": .int(100),
            "peer-port": .int(51_413),
            "peer-limit-global": .int(200),
            "peer-limit-per-torrent": .int(50),
            "pex-enabled": .bool(true),
            "dht-enabled": .bool(true),
            "seedRatioLimited": .bool(false),
            "seedRatioLimit": .double(2),
            "blocklist-enabled": .bool(false),
            "alt-speed-enabled": .bool(false),
            "alt-speed-down": .int(50),
            "alt-speed-up": .int(25),
            "alt-speed-time-enabled": .bool(false),
            "alt-speed-time-begin": .int(60),
            "alt-speed-time-end": .int(120),
            "alt-speed-time-day": .int(62),
            "incomplete-dir-enabled": .bool(false),
            "cache-size-mb": .int(4),
            "idle-seeding-limit-enabled": .bool(false),
            "idle-seeding-limit": .int(30),
            "download-queue-enabled": .bool(false),
            "download-queue-size": .int(3),
            "seed-queue-enabled": .bool(false),
            "seed-queue-size": .int(4),
            "queue-stalled-enabled": .bool(false),
            "queue-stalled-minutes": .int(30)
        ])
    }
}
