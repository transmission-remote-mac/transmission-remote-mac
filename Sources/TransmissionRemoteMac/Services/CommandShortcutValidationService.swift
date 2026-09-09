// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct CommandShortcutValidationService {
    func makeImportPlan(
        from preferences: [CommandShortcutPreference],
        catalog: NativeCommandCatalog = .current
    ) -> CommandShortcutImportPlan {
        var issues: [CommandShortcutValidationIssue] = []
        var preferencesByCommand: [NativeCommandID: CommandShortcutPreference] = [:]
        let knownCommandIDs = Set(catalog.commands.map(\.id))

        for preference in preferences {
            guard let commandID = NativeCommandID(rawValue: preference.commandID),
                  knownCommandIDs.contains(commandID) else {
                issues.append(
                    issue(
                        .unknownCommand,
                        commandIDs: [preference.commandID],
                        "Unknown command ID \(preference.commandID)."
                    )
                )
                continue
            }
            guard preferencesByCommand[commandID] == nil else {
                issues.append(
                    issue(
                        .duplicateCommand,
                        commandIDs: [commandID.rawValue],
                        "Command \(commandID.rawValue) has more than one shortcut override."
                    )
                )
                continue
            }
            preferencesByCommand[commandID] = preference
        }

        var proposedBindings: [NativeCommandShortcutBinding] = []
        for command in catalog.commands {
            guard let preference = preferencesByCommand[command.id] else {
                proposedBindings.append(
                    NativeCommandShortcutBinding(
                        commandID: command.id,
                        shortcut: command.defaultShortcut
                    )
                )
                continue
            }

            guard let keyEquivalent = preference.keyEquivalent else {
                if !preference.modifiers.isEmpty {
                    issues.append(
                        issue(
                            .missingKeyEquivalent,
                            commandIDs: [command.id.rawValue],
                            "A disabled shortcut cannot retain modifiers."
                        )
                    )
                }
                proposedBindings.append(NativeCommandShortcutBinding(commandID: command.id, shortcut: nil))
                continue
            }

            switch normalizedShortcut(
                keyEquivalent: keyEquivalent,
                modifierNames: preference.modifiers,
                commandID: command.id
            ) {
            case let .success(shortcut):
                proposedBindings.append(
                    NativeCommandShortcutBinding(commandID: command.id, shortcut: shortcut)
                )
            case let .failure(issue):
                issues.append(issue)
                proposedBindings.append(
                    NativeCommandShortcutBinding(
                        commandID: command.id,
                        shortcut: command.defaultShortcut
                    )
                )
            }
        }

        let bindingsByCombination = Dictionary(grouping: proposedBindings.compactMap { binding in
            binding.shortcut.map { (binding.commandID, $0) }
        }) { $0.1.stableCombinationID }
        for combination in bindingsByCombination.keys.sorted() {
            let bindings = bindingsByCombination[combination] ?? []
            guard bindings.count > 1 else { continue }
            let commandIDs = bindings.map(\.0.rawValue).sorted()
            issues.append(
                issue(
                    .duplicateShortcut,
                    commandIDs: commandIDs,
                    "Shortcut \(combination) is assigned to more than one command."
                )
            )
        }

        return CommandShortcutImportPlan(
            proposedBindings: proposedBindings,
            issues: issues.sorted(by: issueOrdering)
        )
    }

    func makeConflictSafeUpgrade(
        from preferences: [CommandShortcutPreference],
        newCommandIDs: Set<NativeCommandID>,
        catalog: NativeCommandCatalog = .current
    ) -> CommandShortcutPreferenceUpgrade? {
        let originalPlan = makeImportPlan(from: preferences, catalog: catalog)
        guard originalPlan.validatedBindings == nil else { return nil }

        let explicitlyConfiguredCommandIDs = Set(
            preferences.compactMap { NativeCommandID(rawValue: $0.commandID) }
        )
        guard explicitlyConfiguredCommandIDs.isDisjoint(with: newCommandIDs),
              !originalPlan.issues.isEmpty,
              originalPlan.issues.allSatisfy({ $0.code == .duplicateShortcut }) else {
            return nil
        }

        var conflictingNewDefaults: Set<NativeCommandID> = []
        for issue in originalPlan.issues {
            let involvedCommandIDs = Set(issue.commandIDs.compactMap(NativeCommandID.init(rawValue:)))
            let newDefaults = involvedCommandIDs.intersection(newCommandIDs)
            let existingOverrides = involvedCommandIDs.intersection(explicitlyConfiguredCommandIDs)
            guard !newDefaults.isEmpty, !existingOverrides.isEmpty else { return nil }
            conflictingNewDefaults.formUnion(newDefaults)
        }

        var upgradedPreferences = preferences
        for command in catalog.commands where conflictingNewDefaults.contains(command.id) {
            upgradedPreferences.append(
                CommandShortcutPreference(
                    commandID: command.id,
                    keyEquivalent: nil,
                    modifiers: []
                )
            )
        }

        let upgradedPlan = makeImportPlan(from: upgradedPreferences, catalog: catalog)
        guard upgradedPlan.validatedBindings != nil else { return nil }
        return CommandShortcutPreferenceUpgrade(
            shortcutOverrides: upgradedPreferences,
            importPlan: upgradedPlan
        )
    }

    private func normalizedShortcut(
        keyEquivalent: String,
        modifierNames: [String],
        commandID: NativeCommandID
    ) -> Result<NativeCommandShortcut, CommandShortcutValidationIssue> {
        let normalizedKey: String
        do {
            normalizedKey = try normalizeKeyEquivalent(keyEquivalent)
        } catch {
            return .failure(
                issue(
                    .invalidKeyEquivalent,
                    commandIDs: [commandID.rawValue],
                    "Shortcut key \(keyEquivalent.debugDescription) is not supported."
                )
            )
        }

        var modifiers = Set<NativeShortcutModifier>()
        for modifierName in modifierNames {
            guard let modifier = normalizeModifier(modifierName) else {
                return .failure(
                    issue(
                        .invalidModifier,
                        commandIDs: [commandID.rawValue],
                        "Shortcut modifier \(modifierName.debugDescription) is not supported."
                    )
                )
            }
            modifiers.insert(modifier)
        }
        let shortcut = NativeCommandShortcut(
            normalizedKeyEquivalent: normalizedKey,
            normalizedModifiers: Array(modifiers)
        )

        if isReserved(shortcut) {
            return .failure(
                issue(
                    .reservedShortcut,
                    commandIDs: [commandID.rawValue],
                    "Shortcut \(shortcut.stableCombinationID) is reserved by macOS or standard editing commands."
                )
            )
        }
        let hasCommandLikeModifier = !Set(shortcut.modifiers)
            .intersection([.command, .option, .control])
            .isEmpty
        if !hasCommandLikeModifier && !isSafeUnmodifiedKey(shortcut.keyEquivalent) {
            return .failure(
                issue(
                    .unsafeUnmodifiedKey,
                    commandIDs: [commandID.rawValue],
                    "Printable shortcuts require Command, Option, or Control."
                )
            )
        }
        return .success(shortcut)
    }

    private func normalizeKeyEquivalent(_ value: String) throws -> String {
        let canonical = value.precomposedStringWithCanonicalMapping
        if canonical == " " {
            return "space"
        }
        let trimmed = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))
        let aliases = [
            "↩": "return",
            "enter": "return",
            "return": "return",
            "⌫": "delete",
            "backspace": "delete",
            "delete": "delete",
            "del": "delete",
            "↑": "upArrow",
            "up": "upArrow",
            "uparrow": "upArrow",
            "↓": "downArrow",
            "down": "downArrow",
            "downarrow": "downArrow",
            "←": "leftArrow",
            "left": "leftArrow",
            "leftarrow": "leftArrow",
            "→": "rightArrow",
            "right": "rightArrow",
            "rightarrow": "rightArrow",
            "esc": "escape",
            "escape": "escape",
            "spacebar": "space",
            "space": "space",
            "tab": "tab"
        ]
        if let alias = aliases[folded] {
            return alias
        }
        if folded.range(of: #"^f(?:[1-9]|1[0-9]|20)$"#, options: .regularExpression) != nil {
            return folded
        }
        guard trimmed.count == 1,
              let scalar = trimmed.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) else {
            throw NormalizationError.invalidKeyEquivalent
        }
        return folded
    }

    private func normalizeModifier(_ value: String) -> NativeShortcutModifier? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX")) {
        case "cmd", "command", "meta", "⌘": .command
        case "alt", "opt", "option", "⌥": .option
        case "control", "ctrl", "⌃": .control
        case "shift", "⇧": .shift
        default: nil
        }
    }

    private func isSafeUnmodifiedKey(_ keyEquivalent: String) -> Bool {
        keyEquivalent == "delete"
            || keyEquivalent.range(of: #"^f(?:[1-9]|1[0-9]|20)$"#, options: .regularExpression) != nil
    }

    private func isReserved(_ shortcut: NativeCommandShortcut) -> Bool {
        let command = shortcut.modifiers.contains(.command)
        let option = shortcut.modifiers.contains(.option)
        let control = shortcut.modifiers.contains(.control)
        let shift = shortcut.modifiers.contains(.shift)
        let key = shortcut.keyEquivalent

        if command && !option && !control && !shift,
           ["a", "c", "f", "h", "m", "q", "space", "tab", "v", "x", "z", ","].contains(key) {
            return true
        }
        if command && shift && !option && !control,
           ["3", "4", "5", "z"].contains(key) {
            return true
        }
        if command && option && key == "escape" {
            return true
        }
        if command && control && ["q", "space"].contains(key) {
            return true
        }
        return false
    }

    private func issue(
        _ code: CommandShortcutValidationCode,
        commandIDs: [String],
        _ message: String
    ) -> CommandShortcutValidationIssue {
        CommandShortcutValidationIssue(
            code: code,
            commandIDs: commandIDs.sorted(),
            message: message
        )
    }

    private func issueOrdering(
        lhs: CommandShortcutValidationIssue,
        rhs: CommandShortcutValidationIssue
    ) -> Bool {
        if lhs.code.rawValue != rhs.code.rawValue {
            return lhs.code.rawValue < rhs.code.rawValue
        }
        if lhs.commandIDs != rhs.commandIDs {
            return lhs.commandIDs.lexicographicallyPrecedes(rhs.commandIDs)
        }
        return lhs.message < rhs.message
    }

    private enum NormalizationError: Error {
        case invalidKeyEquivalent
    }
}

struct ApplicationInteractionPreferencesCodec {
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init() {
        decoder = JSONDecoder()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
    }

    func decodeOrDefaults(_ data: Data?) -> ApplicationInteractionPreferenceDecodeResult {
        guard let data,
              let preferences = try? decoder.decode(ApplicationInteractionPreferences.self, from: data) else {
            return ApplicationInteractionPreferenceDecodeResult(
                preferences: .defaults,
                usedDefaults: true
            )
        }
        return ApplicationInteractionPreferenceDecodeResult(
            preferences: preferences,
            usedDefaults: false
        )
    }

    func encode(_ preferences: ApplicationInteractionPreferences) throws -> Data {
        try encoder.encode(preferences)
    }
}
