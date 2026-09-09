// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum RemoteDestinationHistoryKind: String, CaseIterable, Codable, Sendable {
    case add
    case move
}

/// Non-secret, per-profile presentation preferences.
///
/// Authentication credentials, tokens, proxy passwords and client-identity
/// material deliberately do not belong in this payload. Remote paths can still
/// be private user data and should be redacted independently when exported.
struct ProfileTransferPreferences: Hashable, Codable, Sendable {
    static let currentSchemaVersion = 2
    static let containsAuthenticationSecrets = false

    static let allowedSpeedPresetKBps = 1 ... 999_999
    static let maximumSpeedPresetCount = 20
    static let allowedDestinationHistoryLimit = 0 ... 50
    static let defaultDestinationHistoryLimit = 50

    static let defaultDownloadSpeedPresetsKBps = SessionSpeedPreset.downloadPresets.compactMap(\.limitKBps)
    static let defaultUploadSpeedPresetsKBps = SessionSpeedPreset.uploadPresets.compactMap(\.limitKBps)

    static let defaults = ProfileTransferPreferences()

    private(set) var downloadSpeedPresetsKBps: [Int]
    private(set) var uploadSpeedPresetsKBps: [Int]
    private(set) var destinationHistoryLimit: Int
    private(set) var addDestinationHistory: [String]
    private(set) var moveDestinationHistory: [String]
    private(set) var addDestinationRules: AddTorrentDestinationRulesSnapshot

    init(
        downloadSpeedPresetsKBps: [Int] = Self.defaultDownloadSpeedPresetsKBps,
        uploadSpeedPresetsKBps: [Int] = Self.defaultUploadSpeedPresetsKBps,
        destinationHistoryLimit: Int = Self.defaultDestinationHistoryLimit,
        addDestinationHistory: [String] = [],
        moveDestinationHistory: [String] = [],
        addDestinationRules: AddTorrentDestinationRulesSnapshot = .empty
    ) {
        self.downloadSpeedPresetsKBps = Self.normalizedSpeedPresets(downloadSpeedPresetsKBps)
        self.uploadSpeedPresetsKBps = Self.normalizedSpeedPresets(uploadSpeedPresetsKBps)
        self.destinationHistoryLimit = Self.normalizedHistoryLimit(destinationHistoryLimit)
        self.addDestinationHistory = Self.normalizedDestinations(
            addDestinationHistory,
            limit: self.destinationHistoryLimit
        )
        self.moveDestinationHistory = Self.normalizedDestinations(
            moveDestinationHistory,
            limit: self.destinationHistoryLimit
        )
        self.addDestinationRules = addDestinationRules
    }

    mutating func setSpeedPresets(_ presetsKBps: [Int], for direction: SessionSpeedLimitDirection) {
        let normalized = Self.normalizedSpeedPresets(presetsKBps)
        switch direction {
        case .download:
            downloadSpeedPresetsKBps = normalized
        case .upload:
            uploadSpeedPresetsKBps = normalized
        }
    }

    func speedPresetsKBps(for direction: SessionSpeedLimitDirection) -> [Int] {
        switch direction {
        case .download:
            downloadSpeedPresetsKBps
        case .upload:
            uploadSpeedPresetsKBps
        }
    }

    mutating func setDestinationHistoryLimit(_ requestedLimit: Int) {
        destinationHistoryLimit = Self.normalizedHistoryLimit(requestedLimit)
        addDestinationHistory = Array(addDestinationHistory.prefix(destinationHistoryLimit))
        moveDestinationHistory = Array(moveDestinationHistory.prefix(destinationHistoryLimit))
    }

    @discardableResult
    mutating func recordDestination(
        _ destination: String,
        for history: RemoteDestinationHistoryKind
    ) throws -> Bool {
        let validated = try RemotePOSIXDestinationValidator.validated(destination)
        guard destinationHistoryLimit > 0 else { return false }

        var destinations = destinations(for: history)
        let previous = destinations
        destinations.removeAll { $0 == validated }
        destinations.insert(validated, at: 0)
        destinations = Array(destinations.prefix(destinationHistoryLimit))
        setDestinations(destinations, for: history)
        return destinations != previous
    }

    @discardableResult
    mutating func removeDestination(
        _ destination: String,
        from history: RemoteDestinationHistoryKind
    ) -> Bool {
        var destinations = destinations(for: history)
        let originalCount = destinations.count
        destinations.removeAll { $0 == destination }
        setDestinations(destinations, for: history)
        return destinations.count != originalCount
    }

    mutating func clearDestinations(for history: RemoteDestinationHistoryKind) {
        setDestinations([], for: history)
    }

    mutating func clearAllDestinations() {
        addDestinationHistory = []
        moveDestinationHistory = []
    }

    mutating func setAddDestinationRules(_ snapshot: AddTorrentDestinationRulesSnapshot) {
        addDestinationRules = snapshot
    }

    func destinations(for history: RemoteDestinationHistoryKind) -> [String] {
        switch history {
        case .add:
            addDestinationHistory
        case .move:
            moveDestinationHistory
        }
    }

    private mutating func setDestinations(
        _ destinations: [String],
        for history: RemoteDestinationHistoryKind
    ) {
        switch history {
        case .add:
            addDestinationHistory = destinations
        case .move:
            moveDestinationHistory = destinations
        }
    }

    private static func normalizedSpeedPresets(_ presetsKBps: [Int]) -> [Int] {
        Array(
            Set(presetsKBps.filter(allowedSpeedPresetKBps.contains))
                .sorted()
                .prefix(maximumSpeedPresetCount)
        )
    }

    private static func normalizedHistoryLimit(_ limit: Int) -> Int {
        min(max(limit, allowedDestinationHistoryLimit.lowerBound), allowedDestinationHistoryLimit.upperBound)
    }

    private static func normalizedDestinations(_ destinations: [String], limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        var seen: Set<String> = []
        var normalized: [String] = []
        for destination in destinations {
            guard normalized.count < limit,
                  let validated = try? RemotePOSIXDestinationValidator.validated(destination),
                  seen.insert(validated).inserted else {
                continue
            }
            normalized.append(validated)
        }
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case downloadSpeedPresetsKBps
        case uploadSpeedPresetsKBps
        case destinationHistoryLimit
        case addDestinationHistory
        case moveDestinationHistory
        case addDestinationRules

        // Schema-zero migration aliases. They decode only and are never emitted.
        case downloadPresetsKBps
        case uploadPresetsKBps
        case historyLimit
        case addDestinations
        case moveDestinations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        guard (0 ... Self.currentSchemaVersion).contains(schemaVersion) else {
            self = .defaults
            return
        }

        let downloadPresets = Self.decodeArray(
            from: container,
            currentKey: .downloadSpeedPresetsKBps,
            legacyKey: .downloadPresetsKBps
        ) ?? Self.defaultDownloadSpeedPresetsKBps
        let uploadPresets = Self.decodeArray(
            from: container,
            currentKey: .uploadSpeedPresetsKBps,
            legacyKey: .uploadPresetsKBps
        ) ?? Self.defaultUploadSpeedPresetsKBps
        let historyLimit = Self.decodeValue(
            from: container,
            currentKey: .destinationHistoryLimit,
            legacyKey: .historyLimit
        ) ?? Self.defaultDestinationHistoryLimit
        let addDestinations: [String] = Self.decodeArray(
            from: container,
            currentKey: .addDestinationHistory,
            legacyKey: .addDestinations
        ) ?? []
        let moveDestinations: [String] = Self.decodeArray(
            from: container,
            currentKey: .moveDestinationHistory,
            legacyKey: .moveDestinations
        ) ?? []
        let addDestinationRules: AddTorrentDestinationRulesSnapshot
        if schemaVersion >= 2 {
            addDestinationRules = (try? container.decode(
                AddTorrentDestinationRulesSnapshot.self,
                forKey: .addDestinationRules
            )) ?? .empty
        } else {
            addDestinationRules = .empty
        }

        self.init(
            downloadSpeedPresetsKBps: downloadPresets,
            uploadSpeedPresetsKBps: uploadPresets,
            destinationHistoryLimit: historyLimit,
            addDestinationHistory: addDestinations,
            moveDestinationHistory: moveDestinations,
            addDestinationRules: addDestinationRules
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(downloadSpeedPresetsKBps, forKey: .downloadSpeedPresetsKBps)
        try container.encode(uploadSpeedPresetsKBps, forKey: .uploadSpeedPresetsKBps)
        try container.encode(destinationHistoryLimit, forKey: .destinationHistoryLimit)
        try container.encode(addDestinationHistory, forKey: .addDestinationHistory)
        try container.encode(moveDestinationHistory, forKey: .moveDestinationHistory)
        try container.encode(addDestinationRules, forKey: .addDestinationRules)
    }

    private static func decodeArray<Element: Decodable>(
        from container: KeyedDecodingContainer<CodingKeys>,
        currentKey: CodingKeys,
        legacyKey: CodingKeys
    ) -> [Element]? {
        if container.contains(currentKey) {
            return try? container.decode([Element].self, forKey: currentKey)
        }
        return try? container.decodeIfPresent([Element].self, forKey: legacyKey)
    }

    private static func decodeValue<Value: Decodable>(
        from container: KeyedDecodingContainer<CodingKeys>,
        currentKey: CodingKeys,
        legacyKey: CodingKeys
    ) -> Value? {
        if container.contains(currentKey) {
            return try? container.decode(Value.self, forKey: currentKey)
        }
        return try? container.decodeIfPresent(Value.self, forKey: legacyKey)
    }
}
