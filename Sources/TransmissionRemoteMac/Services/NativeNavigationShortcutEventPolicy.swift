// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit

enum NativeNavigationShortcutEventDisposition: Equatable {
    case passThrough
    case consume
    case perform(NativeCommandID)
}

@MainActor
struct NativeNavigationShortcutEventPolicy {
    let eligibleCommandIDs: Set<NativeCommandID>

    init(
        eligibleCommandIDs: Set<NativeCommandID> = NativeCommandCatalog.keyboardNavigationCommandIDs
    ) {
        self.eligibleCommandIDs = eligibleCommandIDs
    }

    func disposition(
        for event: NSEvent,
        targetWindow: NSWindow?,
        bindings: [NativeCommandShortcutBinding]
    ) -> NativeNavigationShortcutEventDisposition {
        disposition(
            matching: shortcut(for: event),
            belongsToTargetWindow: targetWindow.map {
                event.windowNumber == $0.windowNumber
            } ?? false,
            isTextEditing: Self.isTextEditing(targetWindow?.firstResponder),
            isRepeat: event.isARepeat,
            bindings: bindings
        )
    }

    func disposition(
        matching shortcut: NativeCommandShortcut?,
        belongsToTargetWindow: Bool,
        isTextEditing: Bool,
        isRepeat: Bool,
        bindings: [NativeCommandShortcutBinding]
    ) -> NativeNavigationShortcutEventDisposition {
        guard belongsToTargetWindow,
              let shortcut,
              let commandID = bindings.first(where: {
                  eligibleCommandIDs.contains($0.commandID) && $0.shortcut == shortcut
              })?.commandID else {
            return .passThrough
        }
        guard !isTextEditing else { return .consume }
        return isRepeat ? .consume : .perform(commandID)
    }

    private func shortcut(for event: NSEvent) -> NativeCommandShortcut? {
        guard let charactersIgnoringModifiers = event.charactersIgnoringModifiers,
              let keyEquivalent = Self.keyEquivalent(for: charactersIgnoringModifiers) else {
            return nil
        }

        var modifiers: [NativeShortcutModifier] = []
        if event.modifierFlags.contains(.command) { modifiers.append(.command) }
        if event.modifierFlags.contains(.option) { modifiers.append(.option) }
        if event.modifierFlags.contains(.control) { modifiers.append(.control) }
        if event.modifierFlags.contains(.shift) { modifiers.append(.shift) }
        return NativeCommandShortcut(
            normalizedKeyEquivalent: keyEquivalent,
            normalizedModifiers: modifiers
        )
    }

    private static func isTextEditing(_ responder: NSResponder?) -> Bool {
        if responder is NSText {
            return true
        }
        if let control = responder as? NSControl, control.currentEditor() != nil {
            return true
        }
        return false
    }

    private static func keyEquivalent(for characters: String) -> String? {
        let canonical = characters.precomposedStringWithCanonicalMapping
        guard let scalar = canonical.unicodeScalars.first else { return nil }

        switch scalar.value {
        case 0x03, 0x0A, 0x0D:
            return "return"
        case 0x08, 0x7F, 0xF728:
            return "delete"
        case 0x09, 0x19:
            return "tab"
        case 0x1B:
            return "escape"
        case 0x20:
            return "space"
        case 0xF700:
            return "upArrow"
        case 0xF701:
            return "downArrow"
        case 0xF702:
            return "leftArrow"
        case 0xF703:
            return "rightArrow"
        case 0xF704...0xF717:
            return "f\(scalar.value - 0xF704 + 1)"
        default:
            guard canonical.count == 1,
                  !CharacterSet.controlCharacters.contains(scalar) else {
                return nil
            }
            return canonical.lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
    }
}
