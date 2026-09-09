// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class SettingsNavigationModelTests: XCTestCase {
    func testOrdinarySettingsPresentationDefaultsToApplication() {
        let navigation = SettingsNavigationModel()

        navigation.settingsDidAppear()

        XCTAssertEqual(navigation.selectedSection, .application)
        XCTAssertTrue(navigation.isSettingsPresented)
    }

    func testServerRequestSelectsServersAndCoalescesPendingOpenRequests() {
        let navigation = SettingsNavigationModel()
        var openCount = 0

        navigation.present(.servers) { openCount += 1 }
        navigation.present(.servers) { openCount += 1 }
        navigation.settingsDidAppear()

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(navigation.selectedSection, .servers)
    }

    func testFirstRunServerPresentationOccursOnlyOnce() {
        let navigation = SettingsNavigationModel()
        var openCount = 0

        navigation.presentServersForFirstRunIfNeeded(needsConnectionSetup: true) {
            openCount += 1
        }
        navigation.settingsDidAppear()
        navigation.settingsDidDisappear()
        navigation.presentServersForFirstRunIfNeeded(needsConnectionSetup: true) {
            openCount += 1
        }

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(navigation.selectedSection, .application)
    }

    func testServerRequestWhileSettingsAreOpenSelectsAndBringsWindowForward() {
        let navigation = SettingsNavigationModel()
        var openCount = 0
        navigation.settingsDidAppear()

        navigation.present(.servers) { openCount += 1 }

        XCTAssertEqual(openCount, 1)
        XCTAssertEqual(navigation.selectedSection, .servers)
    }
}
