// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum DateDisplayMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case absolute
    case relative

    var id: Self { self }
}

struct DateDisplayPreferences: Codable, Equatable, Sendable {
    static let defaults = DateDisplayPreferences(mode: .absolute)

    let mode: DateDisplayMode
}

struct ApplicationInteractionPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2
    static let defaults = ApplicationInteractionPreferences(
        dateDisplay: .defaults,
        shortcutOverrides: []
    )

    let dateDisplay: DateDisplayPreferences
    let shortcutOverrides: [CommandShortcutPreference]

    init(
        dateDisplay: DateDisplayPreferences,
        shortcutOverrides: [CommandShortcutPreference]
    ) {
        self.dateDisplay = dateDisplay
        self.shortcutOverrides = shortcutOverrides
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...Self.currentSchemaVersion).contains(version) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version,
                in: container,
                debugDescription: "Unsupported interaction preference schema version \(version)."
            )
        }

        if let dateDisplay = try container.decodeIfPresent(DateDisplayPreferences.self, forKey: .dateDisplay) {
            self.dateDisplay = dateDisplay
        } else if let fromNow = try container.decodeIfPresent(Bool.self, forKey: .fromNow) {
            dateDisplay = DateDisplayPreferences(mode: fromNow ? .relative : .absolute)
        } else {
            dateDisplay = .defaults
        }
        shortcutOverrides = try container.decodeIfPresent(
            [CommandShortcutPreference].self,
            forKey: .shortcutOverrides
        ) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .version)
        try container.encode(dateDisplay, forKey: .dateDisplay)
        try container.encode(shortcutOverrides, forKey: .shortcutOverrides)
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case dateDisplay
        case fromNow
        case shortcutOverrides
    }
}

struct ApplicationInteractionPreferenceDecodeResult: Equatable, Sendable {
    let preferences: ApplicationInteractionPreferences
    let usedDefaults: Bool
}
