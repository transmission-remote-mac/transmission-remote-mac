// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct ClipboardTorrentIntakePolicy: Equatable, Codable, Sendable {
    static let defaults = ClipboardTorrentIntakePolicy(isEnabled: false)

    var isEnabled: Bool

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled))
            ?? Self.defaults.isEnabled
    }
}

enum SourceTorrentDeletionPolicy: String, Codable, Sendable {
    case never
    case afterSuccessfulNonDuplicateAdd
}

struct UpdateCheckPolicy: Equatable, Codable, Sendable {
    static let allowedAutomaticCadenceHours = 1 ... 720
    static let defaults = UpdateCheckPolicy(
        automaticChecksEnabled: false,
        automaticCadenceHours: 24
    )

    private(set) var automaticChecksEnabled: Bool
    private(set) var automaticCadenceHours: Int

    init(automaticChecksEnabled: Bool, automaticCadenceHours: Int) {
        self.automaticChecksEnabled = automaticChecksEnabled
        self.automaticCadenceHours = min(
            max(automaticCadenceHours, Self.allowedAutomaticCadenceHours.lowerBound),
            Self.allowedAutomaticCadenceHours.upperBound
        )
    }

    var automaticCadence: TimeInterval {
        TimeInterval(automaticCadenceHours * 60 * 60)
    }

    private enum CodingKeys: String, CodingKey {
        case automaticChecksEnabled
        case automaticCadenceHours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            automaticChecksEnabled: (
                try? container.decode(Bool.self, forKey: .automaticChecksEnabled)
            ) ?? Self.defaults.automaticChecksEnabled,
            automaticCadenceHours: (
                try? container.decode(Int.self, forKey: .automaticCadenceHours)
            ) ?? Self.defaults.automaticCadenceHours
        )
    }
}

/// Non-secret preferences for opt-in intake automation and update checks.
/// Clipboard values, source paths and update-client identifiers are runtime-only
/// concerns and are deliberately excluded from this payload.
struct IntakeAutomationPreferences: Equatable, Codable, Sendable {
    static let currentSchemaVersion = 1
    static let containsAuthenticationSecrets = false
    static let containsClipboardContents = false
    static let containsTelemetryIdentifiers = false
    static let defaults = IntakeAutomationPreferences(
        clipboardIntake: .defaults,
        sourceTorrentDeletion: .never,
        updateChecks: .defaults
    )

    var clipboardIntake: ClipboardTorrentIntakePolicy
    var sourceTorrentDeletion: SourceTorrentDeletionPolicy
    var updateChecks: UpdateCheckPolicy

    init(
        clipboardIntake: ClipboardTorrentIntakePolicy,
        sourceTorrentDeletion: SourceTorrentDeletionPolicy,
        updateChecks: UpdateCheckPolicy
    ) {
        self.clipboardIntake = clipboardIntake
        self.sourceTorrentDeletion = sourceTorrentDeletion
        self.updateChecks = updateChecks
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case clipboardIntake
        case sourceTorrentDeletion
        case updateChecks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        guard schemaVersion == Self.currentSchemaVersion else {
            self = .defaults
            return
        }

        self.init(
            clipboardIntake: (
                try? container.decode(ClipboardTorrentIntakePolicy.self, forKey: .clipboardIntake)
            ) ?? .defaults,
            sourceTorrentDeletion: (
                try? container.decode(
                    SourceTorrentDeletionPolicy.self,
                    forKey: .sourceTorrentDeletion
                )
            ) ?? .never,
            updateChecks: (
                try? container.decode(UpdateCheckPolicy.self, forKey: .updateChecks)
            ) ?? .defaults
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(clipboardIntake, forKey: .clipboardIntake)
        try container.encode(sourceTorrentDeletion, forKey: .sourceTorrentDeletion)
        try container.encode(updateChecks, forKey: .updateChecks)
    }
}
