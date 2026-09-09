// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class SettingsImportPlannerTests: XCTestCase {
    func testPlanReportsAddUpdateAndSkipWithoutMutatingInputs() throws {
        let existingID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000001"))
        let reservedID = try XCTUnwrap(UUID(uuidString: "10000000-0000-4000-8000-000000000002"))
        let additionID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000001"))
        let nameConflictID = try XCTUnwrap(UUID(uuidString: "20000000-0000-4000-8000-000000000002"))
        let currentPreferences = SettingsExportPreferences()
        let existingProfiles = [
            try ConnectionProfile.validated(
                id: existingID,
                name: "Existing",
                host: "old.example",
                password: "EXISTING-SECRET-MUST-STAY-OUTSIDE-PLAN"
            ),
            try ConnectionProfile.validated(
                id: reservedID,
                name: "Reserved",
                host: "reserved.example"
            ),
        ]
        let originalExistingProfiles = existingProfiles
        let importedProfiles = [
            try ConnectionProfile.validated(
                id: nameConflictID,
                name: "Reserved",
                host: "collision.example"
            ),
            try ConnectionProfile.validated(
                id: additionID,
                name: "Addition",
                host: "addition.example"
            ),
            try ConnectionProfile.validated(
                id: existingID,
                name: "Existing",
                host: "new.example"
            ),
        ]
        let document = try SettingsPortabilityService.makeDocument(
            snapshot: SettingsExportSnapshot(
                profiles: importedProfiles,
                selectedProfileID: additionID,
                applicationPreferences: currentPreferences
            )
        )

        let updatePlan = try SettingsPortabilityService.planImport(
            document: document,
            existingProfiles: existingProfiles,
            existingPreferences: currentPreferences,
            collisionPolicy: .updateMatchingIdentifier
        )
        let skipPlan = try SettingsPortabilityService.planImport(
            document: document,
            existingProfiles: existingProfiles,
            existingPreferences: currentPreferences,
            collisionPolicy: .skipExisting
        )

        XCTAssertEqual(updatePlan.profileAdditions.map(\.id), [additionID])
        XCTAssertEqual(updatePlan.profileUpdates.map(\.id), [existingID])
        XCTAssertEqual(updatePlan.profileUpdates[0].host, "new.example")
        XCTAssertEqual(
            updatePlan.profileSkips,
            [
                SettingsProfileImportSkip(
                    profileID: nameConflictID,
                    reason: .nameCollision(existingProfileID: reservedID)
                ),
            ]
        )
        XCTAssertEqual(updatePlan.selectedProfileID, additionID)
        XCTAssertEqual(updatePlan.applicationPreferences, .skipUnchanged)

        XCTAssertEqual(skipPlan.profileAdditions.map(\.id), [additionID])
        XCTAssertTrue(skipPlan.profileUpdates.isEmpty)
        XCTAssertEqual(
            skipPlan.profileSkips,
            [
                SettingsProfileImportSkip(profileID: existingID, reason: .identifierCollision),
                SettingsProfileImportSkip(
                    profileID: nameConflictID,
                    reason: .nameCollision(existingProfileID: reservedID)
                ),
            ]
        )
        XCTAssertEqual(existingProfiles, originalExistingProfiles)
        XCTAssertEqual(importedProfiles.map(\.password), ["", "", ""])
    }

    func testPlanSkipsUnchangedProfilesAndReportsPreferenceApplication() throws {
        let profileID = UUID()
        let profile = try ConnectionProfile.validated(
            id: profileID,
            name: "Same",
            host: "same.example"
        )
        let currentPreferences = SettingsExportPreferences()
        let importedPreferences = SettingsExportPreferences(
            polling: PollingPreferences(
                foregroundIntervalSeconds: 7,
                backgroundIntervalSeconds: 31,
                backgroundPolicy: .suspend
            )
        )
        let document = try SettingsPortabilityService.makeDocument(
            snapshot: SettingsExportSnapshot(
                profiles: [profile],
                selectedProfileID: profileID,
                applicationPreferences: importedPreferences
            )
        )

        let plan = try SettingsPortabilityService.planImport(
            document: document,
            existingProfiles: [profile],
            existingPreferences: currentPreferences,
            collisionPolicy: .updateMatchingIdentifier
        )

        XCTAssertTrue(plan.profileAdditions.isEmpty)
        XCTAssertTrue(plan.profileUpdates.isEmpty)
        XCTAssertEqual(
            plan.profileSkips,
            [SettingsProfileImportSkip(profileID: profileID, reason: .unchanged)]
        )
        guard case .apply(let preferences) = plan.applicationPreferences else {
            return XCTFail("Expected an application preferences update")
        }
        XCTAssertEqual(preferences.polling.foregroundIntervalSeconds, 7)
        XCTAssertEqual(preferences.polling.backgroundIntervalSeconds, 31)
        XCTAssertEqual(preferences.polling.backgroundPolicy, .suspend)
    }

    func testPlanEvaluatesBatchNameSwapAgainstFinalState() throws {
        let firstID = try XCTUnwrap(UUID(uuidString: "30000000-0000-4000-8000-000000000001"))
        let secondID = try XCTUnwrap(UUID(uuidString: "30000000-0000-4000-8000-000000000002"))
        let existingProfiles = [
            try ConnectionProfile.validated(
                id: firstID,
                name: "Alpha",
                host: "alpha.example"
            ),
            try ConnectionProfile.validated(
                id: secondID,
                name: "Beta",
                host: "beta.example"
            ),
        ]
        let swappedProfiles = [
            try ConnectionProfile.validated(
                id: firstID,
                name: "Beta",
                host: "alpha.example"
            ),
            try ConnectionProfile.validated(
                id: secondID,
                name: "Alpha",
                host: "beta.example"
            ),
        ]
        let document = try SettingsPortabilityService.makeDocument(
            snapshot: SettingsExportSnapshot(
                profiles: swappedProfiles,
                selectedProfileID: secondID,
                applicationPreferences: SettingsExportPreferences()
            )
        )

        let plan = try SettingsPortabilityService.planImport(
            document: document,
            existingProfiles: existingProfiles,
            existingPreferences: SettingsExportPreferences(),
            collisionPolicy: .updateMatchingIdentifier
        )

        XCTAssertEqual(Set(plan.profileUpdates.map(\.id)), Set([firstID, secondID]))
        XCTAssertTrue(plan.profileSkips.isEmpty)
        XCTAssertEqual(plan.selectedProfileID, secondID)
    }
}
