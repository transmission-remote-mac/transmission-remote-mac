// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class CommandShortcutValidationServiceTests: XCTestCase {
    private let service = CommandShortcutValidationService()

    func testCurrentCatalogMatchesAppCommandsDefaultsAndUsesStableIDs() throws {
        let catalog = NativeCommandCatalog.current

        XCTAssertEqual(catalog.commands.map(\.id), NativeCommandID.allCases)
        XCTAssertEqual(Set(catalog.commands.map(\.id)).count, catalog.commands.count)
        XCTAssertEqual(shortcut(for: .addTorrent, in: catalog).stableCombinationID, "command+o")
        XCTAssertEqual(shortcut(for: .toggleInfoPane, in: catalog).stableCombinationID, "f12")
        XCTAssertEqual(shortcut(for: .showGeneralDetails, in: catalog).stableCombinationID, "option+g")
        XCTAssertEqual(shortcut(for: .showFilesDetails, in: catalog).stableCombinationID, "option+f")
        XCTAssertEqual(shortcut(for: .showPeersDetails, in: catalog).stableCombinationID, "option+p")
        XCTAssertEqual(shortcut(for: .showTrackersDetails, in: catalog).stableCombinationID, "option+k")
        XCTAssertEqual(shortcut(for: .showStatisticsDetails, in: catalog).stableCombinationID, "option+s")
        XCTAssertEqual(shortcut(for: .filterAllTorrents, in: catalog).stableCombinationID, "option+1")
        XCTAssertEqual(shortcut(for: .filterWaitingTorrents, in: catalog).stableCombinationID, "option+8")
        XCTAssertEqual(shortcut(for: .startNow, in: catalog).stableCombinationID, "command+option+return")
        XCTAssertEqual(shortcut(for: .removeAndDeleteData, in: catalog).stableCombinationID, "shift+delete")
        XCTAssertEqual(shortcut(for: .queueTop, in: catalog).stableCombinationID, "command+option+upArrow")
        XCTAssertEqual(shortcut(for: .setLabels, in: catalog).stableCombinationID, "command+shift+l")

        let plan = service.makeImportPlan(from: [], catalog: catalog)
        XCTAssertTrue(plan.issues.isEmpty)
        XCTAssertNotNil(plan.validatedBindings)
        XCTAssertEqual(plan.proposedBindings.map(\.commandID), NativeCommandID.allCases)
    }

    func testDetailAndStatusNavigationCommandsHaveCompleteTypedMappings() {
        XCTAssertEqual(
            TorrentDetailPane.commandNavigationOrder.map(\.navigationCommandID),
            [
                .showGeneralDetails,
                .showFilesDetails,
                .showPeersDetails,
                .showTrackersDetails,
                .showStatisticsDetails,
            ]
        )
        XCTAssertEqual(
            TorrentFilterStatus.allCases.map(\.navigationCommandID),
            [
                .filterAllTorrents,
                .filterDownloadingTorrents,
                .filterDoneTorrents,
                .filterActiveTorrents,
                .filterInactiveTorrents,
                .filterStoppedTorrents,
                .filterErrorTorrents,
                .filterWaitingTorrents,
            ]
        )
        XCTAssertEqual(
            NativeCommandID.showPeersDetails.navigationAction,
            .showDetailPane(.peers)
        )
        XCTAssertEqual(
            NativeCommandID.filterActiveTorrents.navigationAction,
            .selectStatusFilter(.active)
        )
        XCTAssertNil(NativeCommandID.refresh.navigationAction)
    }

    func testOldCatalogOverrideWinsByDisablingOnlyTheConflictingNewDefault() throws {
        let oldOverride = CommandShortcutPreference(
            commandID: .refresh,
            keyEquivalent: "g",
            modifiers: ["option"]
        )
        XCTAssertNil(service.makeImportPlan(from: [oldOverride]).validatedBindings)

        let upgrade = try XCTUnwrap(
            service.makeConflictSafeUpgrade(
                from: [oldOverride],
                newCommandIDs: NativeCommandCatalog.keyboardNavigationCommandIDs
            )
        )

        XCTAssertEqual(upgrade.shortcutOverrides.first, oldOverride)
        XCTAssertEqual(
            upgrade.shortcutOverrides.filter { $0.keyEquivalent == nil }.map(\.commandID),
            [NativeCommandID.showGeneralDetails.rawValue]
        )
        XCTAssertEqual(
            upgrade.importPlan.proposedBindings.first { $0.commandID == .refresh }?.shortcut?.stableCombinationID,
            "option+g"
        )
        XCTAssertNil(
            upgrade.importPlan.proposedBindings.first { $0.commandID == .showGeneralDetails }?.shortcut
        )
        XCTAssertEqual(
            upgrade.importPlan.proposedBindings.first { $0.commandID == .showFilesDetails }?.shortcut?.stableCombinationID,
            "option+f"
        )
        XCTAssertNotNil(upgrade.importPlan.validatedBindings)
    }

    func testImportNormalizesAliasesCaseModifierOrderAndDuplicates() throws {
        let plan = service.makeImportPlan(from: [
            CommandShortcutPreference(
                commandID: .refresh,
                keyEquivalent: " R ",
                modifiers: ["SHIFT", "cmd", "Command", "opt"]
            )
        ])

        XCTAssertTrue(plan.issues.isEmpty)
        let binding = try XCTUnwrap(plan.validatedBindings?.first { $0.commandID == .refresh })
        XCTAssertEqual(binding.shortcut?.keyEquivalent, "r")
        XCTAssertEqual(binding.shortcut?.modifiers, [.command, .option, .shift])
        XCTAssertEqual(binding.shortcut?.stableCombinationID, "command+option+shift+r")
    }

    func testImportRejectsDuplicateNormalizedShortcutsWithoutPartialValidation() {
        let plan = service.makeImportPlan(from: [
            CommandShortcutPreference(
                commandID: .refresh,
                keyEquivalent: "I",
                modifiers: ["command"]
            )
        ])

        XCTAssertNil(plan.validatedBindings)
        XCTAssertEqual(plan.issues.map(\.code), [.duplicateShortcut])
        XCTAssertEqual(
            plan.issues.first?.commandIDs,
            [NativeCommandID.properties.rawValue, NativeCommandID.refresh.rawValue].sorted()
        )
    }

    func testImportRejectsReservedDangerousAndUnsafeBareKeys() {
        let reserved = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: "Q", modifiers: ["cmd"])
        ])
        let screenshot = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: "4", modifiers: ["shift", "command"])
        ])
        let unsafeBare = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: "r", modifiers: [])
        ])
        let unsafeShiftOnly = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: "r", modifiers: ["shift"])
        ])
        let settingsShortcut = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: ",", modifiers: ["command"])
        ])
        let findShortcut = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: "f", modifiers: ["command"])
        ])

        XCTAssertTrue(reserved.issues.contains { $0.code == .reservedShortcut })
        XCTAssertTrue(screenshot.issues.contains { $0.code == .reservedShortcut })
        XCTAssertTrue(unsafeBare.issues.contains { $0.code == .unsafeUnmodifiedKey })
        XCTAssertTrue(unsafeShiftOnly.issues.contains { $0.code == .unsafeUnmodifiedKey })
        XCTAssertTrue(settingsShortcut.issues.contains { $0.code == .reservedShortcut })
        XCTAssertTrue(findShortcut.issues.contains { $0.code == .reservedShortcut })
        XCTAssertNil(reserved.validatedBindings)
        XCTAssertNil(screenshot.validatedBindings)
        XCTAssertNil(unsafeBare.validatedBindings)
        XCTAssertNil(unsafeShiftOnly.validatedBindings)
        XCTAssertNil(settingsShortcut.validatedBindings)
        XCTAssertNil(findShortcut.validatedBindings)
    }

    func testImportRejectsUnknownDuplicateAndMalformedValues() {
        let plan = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: "removed.command", keyEquivalent: "x", modifiers: ["cmd"]),
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: "r", modifiers: ["hyper"]),
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: "page down", modifiers: ["cmd"])
        ])

        XCTAssertNil(plan.validatedBindings)
        XCTAssertEqual(
            Set(plan.issues.map(\.code)),
            [.duplicateCommand, .invalidModifier, .unknownCommand]
        )
    }

    func testDisabledShortcutRequiresNoModifiersAndDoesNotConflict() throws {
        let valid = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: nil, modifiers: [])
        ])
        let invalid = service.makeImportPlan(from: [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: nil, modifiers: ["command"])
        ])

        XCTAssertNil(try XCTUnwrap(valid.validatedBindings?.first { $0.commandID == .refresh }).shortcut)
        XCTAssertTrue(invalid.issues.contains { $0.code == .missingKeyEquivalent })
        XCTAssertNil(invalid.validatedBindings)
    }

    func testPreferencesMigrateLegacyFromNowAndFallbackOnFutureOrCorruptPayloads() throws {
        let codec = ApplicationInteractionPreferencesCodec()
        let legacy = codec.decodeOrDefaults(Data(#"{"fromNow":true}"#.utf8))
        let future = codec.decodeOrDefaults(Data(#"{"version":999}"#.utf8))
        let corrupt = codec.decodeOrDefaults(Data("not-json".utf8))

        XCTAssertFalse(legacy.usedDefaults)
        XCTAssertEqual(legacy.preferences.dateDisplay.mode, .relative)
        XCTAssertEqual(legacy.preferences.shortcutOverrides, [])
        XCTAssertTrue(future.usedDefaults)
        XCTAssertEqual(future.preferences, .defaults)
        XCTAssertTrue(corrupt.usedDefaults)
        XCTAssertEqual(corrupt.preferences, .defaults)
    }

    func testEncodedPreferencesHaveOnlyVersionedNonSecretFieldsAndRoundTrip() throws {
        let codec = ApplicationInteractionPreferencesCodec()
        let preferences = ApplicationInteractionPreferences(
            dateDisplay: DateDisplayPreferences(mode: .relative),
            shortcutOverrides: [
                CommandShortcutPreference(commandID: .refresh, keyEquivalent: "r", modifiers: ["command"])
            ]
        )
        let data = try codec.encode(preferences)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(Set(object.keys), ["dateDisplay", "shortcutOverrides", "version"])
        XCTAssertNil(object["password"])
        XCTAssertNil(object["token"])
        XCTAssertNil(object["keychainReference"])
        XCTAssertEqual(codec.decodeOrDefaults(data).preferences, preferences)
    }

    func testImportPlanIsDetachedFromMutableInputStorage() throws {
        var source = [
            CommandShortcutPreference(commandID: .refresh, keyEquivalent: "n", modifiers: ["command"])
        ]
        let plan = service.makeImportPlan(from: source)
        source[0] = CommandShortcutPreference(commandID: .refresh, keyEquivalent: "p", modifiers: ["command"])

        let binding = try XCTUnwrap(plan.validatedBindings?.first { $0.commandID == .refresh })
        XCTAssertEqual(binding.shortcut?.stableCombinationID, "command+n")
    }

    private func shortcut(
        for commandID: NativeCommandID,
        in catalog: NativeCommandCatalog
    ) -> NativeCommandShortcut {
        catalog.commands.first { $0.id == commandID }!.defaultShortcut
    }
}
