// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class NativeNavigationShortcutEventPolicyTests: XCTestCase {
    private let policy = NativeNavigationShortcutEventPolicy()

    func testPerformsExactConfiguredNavigationShortcut() {
        let optionP = shortcut("p", [.option])
        let bindings = [
            NativeCommandShortcutBinding(commandID: .showPeersDetails, shortcut: optionP),
            NativeCommandShortcutBinding(
                commandID: .filterActiveTorrents,
                shortcut: shortcut("4", [.option])
            ),
        ]

        XCTAssertEqual(
            disposition(matching: optionP, bindings: bindings),
            .perform(.showPeersDetails)
        )
        XCTAssertEqual(
            disposition(matching: shortcut("4", [.option]), bindings: bindings),
            .perform(.filterActiveTorrents)
        )
    }

    func testPassesThroughMismatchedModifiers() {
        let bindings = [
            NativeCommandShortcutBinding(
                commandID: .showPeersDetails,
                shortcut: shortcut("p", [.option])
            )
        ]

        XCTAssertEqual(
            disposition(matching: shortcut("p", [.option, .shift]), bindings: bindings),
            .passThrough
        )
        XCTAssertEqual(
            disposition(matching: shortcut("p", [.command]), bindings: bindings),
            .passThrough
        )
        XCTAssertEqual(
            disposition(matching: shortcut("p", []), bindings: bindings),
            .passThrough
        )
    }

    func testPassesThroughOtherWindowsButConsumesConfiguredShortcutDuringTextEditing() {
        let optionP = shortcut("p", [.option])
        let bindings = [
            NativeCommandShortcutBinding(commandID: .showPeersDetails, shortcut: optionP)
        ]

        XCTAssertEqual(
            policy.disposition(
                matching: optionP,
                belongsToTargetWindow: false,
                isTextEditing: false,
                isRepeat: false,
                bindings: bindings
            ),
            .passThrough
        )
        XCTAssertEqual(
            policy.disposition(
                matching: optionP,
                belongsToTargetWindow: true,
                isTextEditing: true,
                isRepeat: false,
                bindings: bindings
            ),
            .consume
        )
        XCTAssertEqual(
            policy.disposition(
                matching: shortcut("j", [.option]),
                belongsToTargetWindow: true,
                isTextEditing: true,
                isRepeat: false,
                bindings: bindings
            ),
            .passThrough
        )
    }

    func testConsumesMatchingRepeatWithoutPerformingAgain() {
        let optionP = shortcut("p", [.option])

        XCTAssertEqual(
            policy.disposition(
                matching: optionP,
                belongsToTargetWindow: true,
                isTextEditing: false,
                isRepeat: true,
                bindings: [
                    NativeCommandShortcutBinding(commandID: .showPeersDetails, shortcut: optionP)
                ]
            ),
            .consume
        )
    }

    func testPassesThroughDisabledAndNonNavigationBindings() {
        let optionP = shortcut("p", [.option])
        let bindings = [
            NativeCommandShortcutBinding(commandID: .showPeersDetails, shortcut: nil),
            NativeCommandShortcutBinding(commandID: .refresh, shortcut: optionP),
        ]

        XCTAssertEqual(disposition(matching: optionP, bindings: bindings), .passThrough)
    }

    func testUsesReplacementBindingsWithoutRetainingOldAssignment() {
        let optionP = shortcut("p", [.option])
        let optionJ = shortcut("j", [.option])

        XCTAssertEqual(
            disposition(
                matching: optionP,
                bindings: [
                    NativeCommandShortcutBinding(commandID: .showPeersDetails, shortcut: optionP)
                ]
            ),
            .perform(.showPeersDetails)
        )
        XCTAssertEqual(
            disposition(
                matching: optionP,
                bindings: [
                    NativeCommandShortcutBinding(commandID: .showPeersDetails, shortcut: optionJ)
                ]
            ),
            .passThrough
        )
        XCTAssertEqual(
            disposition(
                matching: optionJ,
                bindings: [
                    NativeCommandShortcutBinding(commandID: .showPeersDetails, shortcut: optionJ)
                ]
            ),
            .perform(.showPeersDetails)
        )
    }

    private func disposition(
        matching shortcut: NativeCommandShortcut,
        bindings: [NativeCommandShortcutBinding]
    ) -> NativeNavigationShortcutEventDisposition {
        policy.disposition(
            matching: shortcut,
            belongsToTargetWindow: true,
            isTextEditing: false,
            isRepeat: false,
            bindings: bindings
        )
    }

    private func shortcut(
        _ keyEquivalent: String,
        _ modifiers: [NativeShortcutModifier]
    ) -> NativeCommandShortcut {
        NativeCommandShortcut(
            normalizedKeyEquivalent: keyEquivalent,
            normalizedModifiers: modifiers
        )
    }
}
