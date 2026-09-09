// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class DaemonOptionsSettingsControllerTests: XCTestCase {
    func testSameOwnerReopenRetainsDirtyDraftAndFailure() throws {
        let owner = DaemonOptionsSettingsOwner(
            profileID: UUID(),
            connectionGeneration: UUID()
        )
        let session = makeSession(downloadDirectory: "/downloads")
        let controller = DaemonOptionsSettingsController()
        controller.synchronize(owner: owner, sessionInfo: session)
        var draft = try XCTUnwrap(controller.draft)
        draft.downloadDirectory = "/other"
        controller.updateDraft(draft)
        let submission = try XCTUnwrap(controller.beginSubmission())
        controller.completeSubmission(submission, with: .failed("permission denied"))

        controller.synchronize(owner: owner, sessionInfo: session)

        XCTAssertEqual(controller.currentOwner, owner)
        XCTAssertEqual(controller.draft?.downloadDirectory, "/other")
        XCTAssertEqual(controller.lastApplyResult, .failed("permission denied"))
        XCTAssertTrue(controller.hasChanges(capabilities: session.capabilities))
    }

    func testProfileAndReconnectOwnersResetDraftAndRejectStaleCompletion() throws {
        let firstOwner = DaemonOptionsSettingsOwner(
            profileID: UUID(),
            connectionGeneration: UUID()
        )
        let secondProfileOwner = DaemonOptionsSettingsOwner(
            profileID: UUID(),
            connectionGeneration: UUID()
        )
        let controller = DaemonOptionsSettingsController()
        controller.synchronize(
            owner: firstOwner,
            sessionInfo: makeSession(downloadDirectory: "/first")
        )
        var draft = try XCTUnwrap(controller.draft)
        draft.downloadDirectory = "/dirty-first"
        controller.updateDraft(draft)
        let firstSubmission = try XCTUnwrap(controller.beginSubmission())

        controller.synchronize(
            owner: secondProfileOwner,
            sessionInfo: makeSession(downloadDirectory: "/second")
        )
        controller.completeSubmission(firstSubmission, with: .failed("stale profile failure"))

        XCTAssertEqual(controller.currentOwner, secondProfileOwner)
        XCTAssertEqual(controller.draft?.downloadDirectory, "/second")
        XCTAssertNil(controller.lastApplyResult)
        XCTAssertFalse(controller.isSubmitting)

        draft = try XCTUnwrap(controller.draft)
        draft.downloadDirectory = "/dirty-second"
        controller.updateDraft(draft)
        let secondSubmission = try XCTUnwrap(controller.beginSubmission())
        let reconnectedOwner = DaemonOptionsSettingsOwner(
            profileID: secondProfileOwner.profileID,
            connectionGeneration: UUID()
        )

        controller.synchronize(
            owner: reconnectedOwner,
            sessionInfo: makeSession(downloadDirectory: "/reconnected")
        )
        controller.completeSubmission(secondSubmission, with: .failed("stale reconnect failure"))

        XCTAssertEqual(controller.currentOwner, reconnectedOwner)
        XCTAssertEqual(controller.draft?.downloadDirectory, "/reconnected")
        XCTAssertNil(controller.lastApplyResult)
        XCTAssertFalse(controller.isSubmitting)
    }

    private func makeSession(downloadDirectory: String) -> SessionInfo {
        SessionInfo(arguments: [
            "rpc-version": .int(14),
            "version": .string("4.0"),
            "download-dir": .string(downloadDirectory)
        ])
    }
}
