// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class ConnectionSettingsCoordinatorTests: XCTestCase {
    func testFailedSaveAndExactFailureSurviveFurtherEdits() throws {
        let profile = ConnectionProfile(name: "Server", host: "old.example")
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        coordinator.draftProfiles[0].host = "new.example"

        let result = try XCTUnwrap(coordinator.apply { _, _ in
            .failure(.persistence(TestSaveError.diskFull))
        })

        guard case .failure(let failure) = result else {
            return XCTFail("Expected the profile save to fail")
        }
        XCTAssertEqual(failure.kind, .persistence)
        XCTAssertEqual(failure.underlyingError as? TestSaveError, .diskFull)
        XCTAssertEqual(coordinator.draftProfiles[0].host, "new.example")
        XCTAssertTrue(coordinator.hasChanges)
        XCTAssertEqual(
            coordinator.saveFailureMessage,
            TestSaveError.diskFull.localizedDescription
        )

        coordinator.draftProfiles[0].host = "retry.example"
        XCTAssertEqual(
            coordinator.saveFailure?.underlyingError as? TestSaveError,
            .diskFull
        )
        XCTAssertEqual(
            coordinator.saveFailureMessage,
            TestSaveError.diskFull.localizedDescription
        )
        XCTAssertEqual(coordinator.draftProfiles[0].host, "retry.example")
    }

    func testSuccessfulSaveNormalizesTheDraftAndClearsDirtyState() throws {
        let profile = ConnectionProfile(name: "Server", host: "old.example")
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        coordinator.draftProfiles[0].name = "  Server  "
        coordinator.draftProfiles[0].host = " new.example "
        var submittedProfiles: [ConnectionProfile] = []

        let result = try XCTUnwrap(coordinator.apply { profiles, selectedProfileID in
            submittedProfiles = profiles
            XCTAssertEqual(selectedProfileID, profile.id)
            return .success(())
        })

        guard case .success = result else {
            return XCTFail("Expected the profile save to succeed")
        }
        XCTAssertEqual(submittedProfiles[0].name, "Server")
        XCTAssertEqual(submittedProfiles[0].host, "new.example")
        XCTAssertEqual(coordinator.draftProfiles[0].name, "Server")
        XCTAssertEqual(coordinator.draftProfiles[0].host, "new.example")
        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertNil(coordinator.saveFailureMessage)
    }

    func testExternalProfilePublishingDoesNotOverwriteDirtyDraft() {
        let profile = ConnectionProfile(name: "Server", host: "old.example")
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        coordinator.draftProfiles[0].host = "unsaved.example"
        var publishedProfile = profile
        publishedProfile.host = "published.example"

        coordinator.synchronize(
            profiles: [publishedProfile],
            selectedProfileID: publishedProfile.id
        )

        XCTAssertEqual(coordinator.draftProfiles[0].host, "unsaved.example")
        XCTAssertTrue(coordinator.hasChanges)
    }

    func testViewRecreationUsesSameProcessLocalDraftAndFailureUntilRevert() throws {
        let profile = ConnectionProfile(name: "Server", host: "old.example")
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        coordinator.draftProfiles[0].host = "unsaved.example"
        _ = try XCTUnwrap(coordinator.apply { _, _ in
            .failure(.persistence(TestSaveError.diskFull))
        })

        coordinator.synchronize(
            profiles: [profile],
            selectedProfileID: profile.id
        )

        XCTAssertEqual(coordinator.draftProfiles[0].host, "unsaved.example")
        XCTAssertEqual(
            coordinator.saveFailure?.underlyingError as? TestSaveError,
            .diskFull
        )

        coordinator.resetDrafts()

        XCTAssertEqual(coordinator.draftProfiles, [ConnectionProfileDraft(profile: profile)])
        XCTAssertNil(coordinator.saveFailure)
    }

    func testMappedProfileStartsCleanAndResetStaysClean() {
        let profile = makeMappedProfile(localPath: "/Volumes/Downloads")
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )

        XCTAssertFalse(coordinator.hasChanges)

        coordinator.draftProfiles[0].pathMappings[0].localPathPrefix = "/Volumes/Other"
        XCTAssertTrue(coordinator.hasChanges)

        coordinator.resetDrafts()

        XCTAssertEqual(
            coordinator.draftProfiles[0].pathMappings[0].localPathPrefix,
            "/Volumes/Downloads"
        )
        XCTAssertFalse(coordinator.hasChanges)
    }

    func testMappedProfileSuccessfulSaveAndReopenStayClean() throws {
        let profile = makeMappedProfile(localPath: "/Volumes/Downloads")
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        coordinator.draftProfiles[0].pathMappings[0].localPathPrefix = "/Volumes/Archive"
        var savedProfiles: [ConnectionProfile] = []

        _ = try XCTUnwrap(coordinator.apply { profiles, _ in
            savedProfiles = profiles
            return .success(())
        })

        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertEqual(savedProfiles[0].pathMappings[0].localPathPrefix, "/Volumes/Archive")

        coordinator.synchronize(
            profiles: savedProfiles,
            selectedProfileID: profile.id
        )

        XCTAssertFalse(coordinator.hasExternalChangeConflict)
        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertEqual(
            coordinator.draftProfiles[0].pathMappings[0].localPathPrefix,
            "/Volumes/Archive"
        )
    }

    func testMappedProfileExternalSyncReplacesOnlyCleanDraft() {
        let profile = makeMappedProfile(localPath: "/Volumes/Downloads")
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        let externalProfile = makeMappedProfile(
            id: profile.id,
            localPath: "/Volumes/External"
        )

        coordinator.synchronize(
            profiles: [externalProfile],
            selectedProfileID: externalProfile.id
        )

        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertEqual(
            coordinator.draftProfiles[0].pathMappings[0].localPathPrefix,
            "/Volumes/External"
        )

        coordinator.draftProfiles[0].pathMappings[0].localPathPrefix = "/Volumes/Unsaved"
        let secondExternalProfile = makeMappedProfile(
            id: profile.id,
            localPath: "/Volumes/SecondExternal"
        )
        coordinator.synchronize(
            profiles: [secondExternalProfile],
            selectedProfileID: secondExternalProfile.id
        )

        XCTAssertTrue(coordinator.hasChanges)
        XCTAssertEqual(
            coordinator.draftProfiles[0].pathMappings[0].localPathPrefix,
            "/Volumes/Unsaved"
        )
    }

    func testExternalPasswordChangeBlocksSaveAndSurvivesReopenUntilRevert() throws {
        let profile = ConnectionProfile(
            name: "Server",
            host: "old.example",
            password: "old-password"
        )
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        coordinator.draftProfiles[0].host = "unsaved.example"
        var externallyUpdatedProfile = profile
        externallyUpdatedProfile.password = "new-password"

        coordinator.synchronize(
            profiles: [externallyUpdatedProfile],
            selectedProfileID: externallyUpdatedProfile.id
        )

        XCTAssertTrue(coordinator.hasExternalChangeConflict)
        XCTAssertEqual(coordinator.saveFailure?.kind, .persistedProfilesChanged)
        XCTAssertEqual(
            coordinator.saveFailureMessage,
            "Server settings changed elsewhere while you were editing. Revert to load the newest saved settings before editing again."
        )
        XCTAssertEqual(coordinator.draftProfiles[0].host, "unsaved.example")
        XCTAssertEqual(coordinator.draftProfiles[0].password, "old-password")

        var saveCallCount = 0
        let result = try XCTUnwrap(coordinator.apply { _, _ in
            saveCallCount += 1
            return .success(())
        })
        guard case .failure(let failure) = result else {
            return XCTFail("Expected the conflicted save to be rejected")
        }
        XCTAssertEqual(failure.kind, .persistedProfilesChanged)
        XCTAssertEqual(saveCallCount, 0)

        coordinator.synchronize(
            profiles: [externallyUpdatedProfile],
            selectedProfileID: externallyUpdatedProfile.id
        )

        XCTAssertTrue(coordinator.hasExternalChangeConflict)
        XCTAssertEqual(coordinator.draftProfiles[0].host, "unsaved.example")
        XCTAssertEqual(coordinator.draftProfiles[0].password, "old-password")

        coordinator.resetDrafts()

        XCTAssertFalse(coordinator.hasExternalChangeConflict)
        XCTAssertFalse(coordinator.hasChanges)
        XCTAssertEqual(coordinator.draftProfiles[0].host, "old.example")
        XCTAssertEqual(coordinator.draftProfiles[0].password, "new-password")
    }

    func testExternalDestinationHistoryChangeBlocksStaleDraftPersistence() throws {
        let profile = ConnectionProfile(name: "Server", host: "old.example")
        let coordinator = ConnectionSettingsCoordinator(
            profiles: [profile],
            selectedProfileID: profile.id
        )
        coordinator.draftProfiles[0].host = "unsaved.example"
        var externallyUpdatedProfile = profile
        _ = try externallyUpdatedProfile.transferPreferences.recordDestination(
            "/new/downloads",
            for: .add
        )

        coordinator.synchronize(
            profiles: [externallyUpdatedProfile],
            selectedProfileID: externallyUpdatedProfile.id
        )

        var saveWasCalled = false
        let result = try XCTUnwrap(coordinator.apply { _, _ in
            saveWasCalled = true
            return .success(())
        })

        guard case .failure(let failure) = result else {
            return XCTFail("Expected the conflicted save to be rejected")
        }
        XCTAssertEqual(failure.kind, .persistedProfilesChanged)
        XCTAssertFalse(saveWasCalled)
        XCTAssertTrue(coordinator.draftProfiles[0].transferPreferences.addDestinationHistory.isEmpty)

        coordinator.resetDrafts()

        XCTAssertEqual(
            coordinator.draftProfiles[0].transferPreferences.addDestinationHistory,
            ["/new/downloads"]
        )
        XCTAssertFalse(coordinator.hasChanges)
    }

    private func makeMappedProfile(
        id: UUID = UUID(),
        localPath: String
    ) -> ConnectionProfile {
        ConnectionProfile(
            id: id,
            name: "Mapped",
            host: "mapped.example",
            pathMappings: [PathMapping(
                remotePathPrefix: "/downloads",
                localPathPrefix: localPath
            )]
        )
    }
}

private enum TestSaveError: LocalizedError, Equatable {
    case diskFull

    var errorDescription: String? {
        "The profile store is full."
    }
}
