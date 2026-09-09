// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

extension NativeCommandShortcut {
    var swiftUIKeyboardShortcut: KeyboardShortcut? {
        guard let key = swiftUIKeyEquivalent else { return nil }
        var eventModifiers: EventModifiers = []
        for modifier in modifiers {
            switch modifier {
            case .command:
                eventModifiers.insert(.command)
            case .option:
                eventModifiers.insert(.option)
            case .control:
                eventModifiers.insert(.control)
            case .shift:
                eventModifiers.insert(.shift)
            }
        }
        return KeyboardShortcut(key, modifiers: eventModifiers)
    }

    private var swiftUIKeyEquivalent: KeyEquivalent? {
        switch keyEquivalent {
        case "return": return .return
        case "delete": return .delete
        case "upArrow": return .upArrow
        case "downArrow": return .downArrow
        case "leftArrow": return .leftArrow
        case "rightArrow": return .rightArrow
        case "escape": return .escape
        case "space": return .space
        case "tab": return .tab
        default:
            if keyEquivalent.hasPrefix("f"),
               let functionNumber = Int(keyEquivalent.dropFirst()),
               (1...20).contains(functionNumber),
               let scalar = UnicodeScalar(0xF704 + functionNumber - 1) {
                return KeyEquivalent(Character(String(scalar)))
            }
            guard keyEquivalent.count == 1, let character = keyEquivalent.first else { return nil }
            return KeyEquivalent(character)
        }
    }
}
