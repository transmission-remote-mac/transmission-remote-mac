// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// An inspectable, profile-owned rule that can recommend an add destination.
///
/// Rules are immutable after validation. Editing uses
/// ``AddTorrentDestinationRuleDraft`` so invalid UI text never enters the
/// persisted or matching model.
struct AddTorrentDestinationRule: Identifiable, Hashable, Codable, Sendable {
    static let maximumLabelLength = 100
    static let maximumExtensionCount = 50
    static let maximumNameTokenCount = 20
    static let maximumMatcherLength = 100

    let id: UUID
    let label: String
    let isEnabled: Bool
    let destination: String
    let extensions: [String]
    let nameTokens: [String]

    init(
        id: UUID = UUID(),
        label: String,
        isEnabled: Bool = true,
        destination: String,
        extensions: [String] = [],
        nameTokens: [String] = []
    ) throws {
        self.id = id
        self.label = try AddTorrentDestinationRuleValidator.normalizedLabel(label)
        self.isEnabled = isEnabled
        self.destination = try AddTorrentDestinationRuleValidator.validatedDestination(
            destination
        )
        self.extensions = try AddTorrentDestinationRuleValidator.normalizedExtensions(
            extensions
        )
        self.nameTokens = try AddTorrentDestinationRuleValidator.normalizedNameTokens(
            nameTokens
        )
        try AddTorrentDestinationRuleValidator.validateMatchers(
            extensions: self.extensions,
            nameTokens: self.nameTokens
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case isEnabled
        case destination
        case extensions
        case nameTokens
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                id: container.decode(UUID.self, forKey: .id),
                label: container.decode(String.self, forKey: .label),
                isEnabled: container.decode(Bool.self, forKey: .isEnabled),
                destination: container.decode(String.self, forKey: .destination),
                extensions: container.decode([String].self, forKey: .extensions),
                nameTokens: container.decode([String].self, forKey: .nameTokens)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid add destination rule: \(error.localizedDescription)",
                    underlyingError: error
                )
            )
        }
    }
}

enum AddTorrentDestinationRuleValidationError: LocalizedError, Equatable, Sendable {
    case labelRequired
    case labelTooLong
    case invalidDestination(RemotePOSIXDestinationValidationError)
    case matcherRequired
    case tooManyExtensions
    case emptyExtension
    case invalidExtension(String)
    case tooManyNameTokens
    case emptyNameToken
    case invalidNameToken(String)
    case tooManyRules
    case duplicateRuleIdentifier(UUID)

    var errorDescription: String? {
        switch self {
        case .labelRequired:
            "A destination rule name is required."
        case .labelTooLong:
            "Destination rule names cannot exceed \(AddTorrentDestinationRule.maximumLabelLength) characters."
        case .invalidDestination(let error):
            error.localizedDescription
        case .matcherRequired:
            "A destination rule needs at least one extension or name token."
        case .tooManyExtensions:
            "A destination rule cannot have more than \(AddTorrentDestinationRule.maximumExtensionCount) extensions."
        case .emptyExtension:
            "Destination rule extensions cannot be empty."
        case .invalidExtension(let value):
            "The destination rule extension is invalid: \(value)"
        case .tooManyNameTokens:
            "A destination rule cannot have more than \(AddTorrentDestinationRule.maximumNameTokenCount) name tokens."
        case .emptyNameToken:
            "Destination rule name tokens cannot be empty."
        case .invalidNameToken(let value):
            "The destination rule name token is invalid: \(value)"
        case .tooManyRules:
            "A profile cannot have more than \(AddTorrentDestinationRulesSnapshot.maximumRuleCount) destination rules."
        case .duplicateRuleIdentifier(let id):
            "Destination rule identifier \(id.uuidString) is duplicated."
        }
    }
}

/// A validated profile-affine payload. This type owns no persistence and no
/// profile identity, so the caller must supply it from the active profile.
struct AddTorrentDestinationRulesSnapshot: Hashable, Codable, Sendable {
    static let maximumRuleCount = 100
    static let empty = AddTorrentDestinationRulesSnapshot()

    let defaultDestination: String?
    let rules: [AddTorrentDestinationRule]

    private init() {
        defaultDestination = nil
        rules = []
    }

    init(
        defaultDestination: String?,
        rules: [AddTorrentDestinationRule]
    ) throws {
        guard rules.count <= Self.maximumRuleCount else {
            throw AddTorrentDestinationRuleValidationError.tooManyRules
        }

        var identifiers = Set<UUID>()
        for rule in rules where !identifiers.insert(rule.id).inserted {
            throw AddTorrentDestinationRuleValidationError.duplicateRuleIdentifier(rule.id)
        }

        if let defaultDestination {
            self.defaultDestination = try AddTorrentDestinationRuleValidator.validatedDestination(
                defaultDestination
            )
        } else {
            self.defaultDestination = nil
        }
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case defaultDestination
        case rules
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        do {
            try self.init(
                defaultDestination: container.decodeIfPresent(
                    String.self,
                    forKey: .defaultDestination
                ),
                rules: container.decode([AddTorrentDestinationRule].self, forKey: .rules)
            )
        } catch let error as DecodingError {
            throw error
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Invalid add destination rules: \(error.localizedDescription)",
                    underlyingError: error
                )
            )
        }
    }
}

/// Raw editable fields for one rule. Commas and line breaks delimit extension
/// and token entries; spaces within a name token are preserved.
struct AddTorrentDestinationRuleDraft: Equatable, Sendable {
    var id: UUID
    var label: String
    var isEnabled: Bool
    var destination: String
    var extensionsText: String
    var nameTokensText: String

    init(
        id: UUID = UUID(),
        label: String = "",
        isEnabled: Bool = true,
        destination: String = "",
        extensionsText: String = "",
        nameTokensText: String = ""
    ) {
        self.id = id
        self.label = label
        self.isEnabled = isEnabled
        self.destination = destination
        self.extensionsText = extensionsText
        self.nameTokensText = nameTokensText
    }

    init(rule: AddTorrentDestinationRule) {
        self.init(
            id: rule.id,
            label: rule.label,
            isEnabled: rule.isEnabled,
            destination: rule.destination,
            extensionsText: rule.extensions.joined(separator: ", "),
            nameTokensText: rule.nameTokens.joined(separator: ", ")
        )
    }

    func validatedRule() throws -> AddTorrentDestinationRule {
        try AddTorrentDestinationRule(
            id: id,
            label: label,
            isEnabled: isEnabled,
            destination: destination,
            extensions: try Self.list(from: extensionsText),
            nameTokens: try Self.list(from: nameTokensText)
        )
    }

    private static func list(from text: String) throws -> [String] {
        guard !text.isEmpty else { return [] }
        let separators = CharacterSet(charactersIn: ",\n\r")
        return text.components(separatedBy: separators)
    }
}

/// UI-neutral edit session. Reset is staged, Cancel restores the last applied
/// snapshot, and Apply validates before replacing that baseline. Persistence is
/// deliberately left to the profile store after Apply returns successfully.
struct AddTorrentDestinationRulesDraft: Equatable, Sendable {
    var defaultDestination: String
    var rules: [AddTorrentDestinationRule]

    private var appliedSnapshot: AddTorrentDestinationRulesSnapshot

    init(snapshot: AddTorrentDestinationRulesSnapshot) {
        appliedSnapshot = snapshot
        defaultDestination = snapshot.defaultDestination ?? ""
        rules = snapshot.rules
    }

    var hasChanges: Bool {
        defaultDestination != (appliedSnapshot.defaultDestination ?? "")
            || rules != appliedSnapshot.rules
    }

    func validatedSnapshot() throws -> AddTorrentDestinationRulesSnapshot {
        try AddTorrentDestinationRulesSnapshot(
            defaultDestination: defaultDestination.isEmpty ? nil : defaultDestination,
            rules: rules
        )
    }

    @discardableResult
    mutating func apply() throws -> AddTorrentDestinationRulesSnapshot {
        let snapshot = try validatedSnapshot()
        appliedSnapshot = snapshot
        defaultDestination = snapshot.defaultDestination ?? ""
        rules = snapshot.rules
        return snapshot
    }

    mutating func cancel() {
        defaultDestination = appliedSnapshot.defaultDestination ?? ""
        rules = appliedSnapshot.rules
    }

    mutating func reset() {
        defaultDestination = ""
        rules = []
    }
}
