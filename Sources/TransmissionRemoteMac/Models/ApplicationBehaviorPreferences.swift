// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct SpeedAveragingPolicy: Equatable, Codable, Sendable {
    static let allowedSampleLimit = 1 ... 120
    static let allowedWindowSeconds = 1 ... 3_600
    static let defaults = SpeedAveragingPolicy(
        isEnabled: false,
        sampleLimit: 20,
        windowSeconds: 120
    )

    private(set) var isEnabled: Bool
    private(set) var sampleLimit: Int
    private(set) var windowSeconds: Int

    init(isEnabled: Bool, sampleLimit: Int, windowSeconds: Int) {
        self.isEnabled = isEnabled
        self.sampleLimit = Self.allowedSampleLimit.clamped(sampleLimit)
        self.windowSeconds = Self.allowedWindowSeconds.clamped(windowSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case sampleLimit
        case windowSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: (try? container.decode(Bool.self, forKey: .isEnabled))
                ?? Self.defaults.isEnabled,
            sampleLimit: (try? container.decode(Int.self, forKey: .sampleLimit))
                ?? Self.defaults.sampleLimit,
            windowSeconds: (try? container.decode(Int.self, forKey: .windowSeconds))
                ?? Self.defaults.windowSeconds
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(sampleLimit, forKey: .sampleLimit)
        try container.encode(windowSeconds, forKey: .windowSeconds)
    }
}

enum AddTorrentStartIntent: String, Codable, Sendable {
    case start
    case paused
}

enum AddTorrentDefaultPriority: Int, Codable, Sendable {
    case low = -1
    case normal = 0
    case high = 1
}

enum AddTorrentUnwantedFilesDefault: String, Codable, Sendable {
    case daemonDefault
    case allUnwantedWhenFileListKnown
}

enum AddTorrentPeerLimitOverride: Equatable, Sendable {
    case daemonDefault
    case limited(Int)
}

/// Per-request choices supplied by an intake source. Nil fields deliberately
/// mean "use the saved application default" so explicit incoming choices win.
struct AddTorrentInitialOptions: Equatable, Sendable {
    static let unspecified = AddTorrentInitialOptions()

    var startIntent: AddTorrentStartIntent?
    var priority: AddTorrentDefaultPriority?
    var unwantedFiles: AddTorrentUnwantedFilesDefault?
    var peerLimit: AddTorrentPeerLimitOverride?

    init(
        startIntent: AddTorrentStartIntent? = nil,
        priority: AddTorrentDefaultPriority? = nil,
        unwantedFiles: AddTorrentUnwantedFilesDefault? = nil,
        peerLimit: AddTorrentPeerLimitOverride? = nil
    ) {
        self.startIntent = startIntent
        self.priority = priority
        self.unwantedFiles = unwantedFiles
        self.peerLimit = peerLimit
    }

    func resolving(defaults: AddTorrentDefaults) -> ResolvedAddTorrentInitialOptions {
        let resolvedPeerLimit: AddTorrentPeerLimitOverride
        if let peerLimit {
            resolvedPeerLimit = peerLimit
        } else if let savedPeerLimit = defaults.peerLimit {
            resolvedPeerLimit = .limited(savedPeerLimit)
        } else {
            resolvedPeerLimit = .daemonDefault
        }

        return ResolvedAddTorrentInitialOptions(
            startIntent: startIntent ?? defaults.startIntent,
            priority: priority ?? defaults.priority,
            unwantedFiles: unwantedFiles ?? defaults.unwantedFiles,
            peerLimit: resolvedPeerLimit
        )
    }
}

struct ResolvedAddTorrentInitialOptions: Equatable, Sendable {
    var startIntent: AddTorrentStartIntent
    var priority: AddTorrentDefaultPriority
    var unwantedFiles: AddTorrentUnwantedFilesDefault
    var peerLimit: AddTorrentPeerLimitOverride

    func seedingFileSelections(
        _ selections: [TorrentMetainfoFileSelection]
    ) -> [TorrentMetainfoFileSelection] {
        selections.map { selection in
            var selection = selection
            selection.wanted = unwantedFiles != .allUnwantedWhenFileListKnown
            switch priority {
            case .low:
                selection.priority = .low
            case .normal:
                selection.priority = .normal
            case .high:
                selection.priority = .high
            }
            return selection
        }
    }
}

struct AddTorrentDefaults: Equatable, Codable, Sendable {
    static let defaults = AddTorrentDefaults(
        startIntent: .start,
        priority: .normal,
        unwantedFiles: .daemonDefault,
        peerLimit: nil
    )

    private(set) var startIntent: AddTorrentStartIntent
    private(set) var priority: AddTorrentDefaultPriority
    private(set) var unwantedFiles: AddTorrentUnwantedFilesDefault
    private(set) var peerLimit: Int?

    init(
        startIntent: AddTorrentStartIntent,
        priority: AddTorrentDefaultPriority,
        unwantedFiles: AddTorrentUnwantedFilesDefault,
        peerLimit: Int?
    ) {
        self.startIntent = startIntent
        self.priority = priority
        self.unwantedFiles = unwantedFiles
        self.peerLimit = peerLimit.flatMap {
            AddTorrentPeerLimitParser.validRange.contains($0) ? $0 : nil
        }
    }

    /// Resolves the persisted all-unwanted intent only when the caller has an
    /// explicit file list. Returning `nil` means the RPC argument must be omitted.
    func unwantedFileIndexes(forExplicitFileIndexes fileIndexes: [Int]?) -> [Int]? {
        guard unwantedFiles == .allUnwantedWhenFileListKnown,
              let fileIndexes,
              fileIndexes.allSatisfy({ $0 >= 0 }) else {
            return nil
        }
        return Array(Set(fileIndexes)).sorted()
    }

    private enum CodingKeys: String, CodingKey {
        case startIntent
        case priority
        case unwantedFiles
        case peerLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let startIntent = (try? container.decode(AddTorrentStartIntent.self, forKey: .startIntent))
            ?? Self.defaults.startIntent
        let priority = (try? container.decode(AddTorrentDefaultPriority.self, forKey: .priority))
            ?? Self.defaults.priority
        let unwantedFiles = (
            try? container.decode(AddTorrentUnwantedFilesDefault.self, forKey: .unwantedFiles)
        ) ?? Self.defaults.unwantedFiles
        let peerLimit: Int?
        if container.contains(.peerLimit) {
            peerLimit = try? container.decodeIfPresent(Int.self, forKey: .peerLimit)
        } else {
            peerLimit = nil
        }

        self.init(
            startIntent: startIntent,
            priority: priority,
            unwantedFiles: unwantedFiles,
            peerLimit: peerLimit
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(startIntent, forKey: .startIntent)
        try container.encode(priority, forKey: .priority)
        try container.encode(unwantedFiles, forKey: .unwantedFiles)
        try container.encodeIfPresent(peerLimit, forKey: .peerLimit)
    }
}

/// Non-secret application behaviour settings. Polling cadence belongs to
/// `PollingPreferences` and is deliberately excluded from this payload.
struct ApplicationBehaviorPreferences: Equatable, Codable, Sendable {
    static let currentSchemaVersion = 2
    static let containsAuthenticationSecrets = false
    static let defaults = ApplicationBehaviorPreferences(
        speedAveraging: .defaults,
        completionNotificationsEnabled: true,
        promptsForDownloadOptions: true,
        addDefaults: .defaults
    )

    var speedAveraging: SpeedAveragingPolicy
    var completionNotificationsEnabled: Bool
    var promptsForDownloadOptions: Bool
    var addDefaults: AddTorrentDefaults

    init(
        speedAveraging: SpeedAveragingPolicy,
        completionNotificationsEnabled: Bool,
        promptsForDownloadOptions: Bool = true,
        addDefaults: AddTorrentDefaults
    ) {
        self.speedAveraging = speedAveraging
        self.completionNotificationsEnabled = completionNotificationsEnabled
        self.promptsForDownloadOptions = promptsForDownloadOptions
        self.addDefaults = addDefaults
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case speedAveraging
        case completionNotificationsEnabled
        case promptsForDownloadOptions
        case addDefaults

        // Schema-zero migration aliases. They decode only and are never emitted.
        case averageSpeeds
        case speedAverageSamples
        case speedAverageWindowSeconds
        case notifyOnCompletion
        case startPaused
        case addPriority
        case markAllFilesUnwanted
        case addPeerLimit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        guard (0 ... Self.currentSchemaVersion).contains(schemaVersion) else {
            self = .defaults
            return
        }

        if schemaVersion == 0 {
            self = Self.migratedSchemaZero(from: container)
            return
        }

        self.init(
            speedAveraging: (try? container.decode(
                SpeedAveragingPolicy.self,
                forKey: .speedAveraging
            )) ?? .defaults,
            completionNotificationsEnabled: (try? container.decode(
                Bool.self,
                forKey: .completionNotificationsEnabled
            )) ?? Self.defaults.completionNotificationsEnabled,
            promptsForDownloadOptions: (try? container.decode(
                Bool.self,
                forKey: .promptsForDownloadOptions
            )) ?? Self.defaults.promptsForDownloadOptions,
            addDefaults: (try? container.decode(AddTorrentDefaults.self, forKey: .addDefaults))
                ?? .defaults
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(speedAveraging, forKey: .speedAveraging)
        try container.encode(completionNotificationsEnabled, forKey: .completionNotificationsEnabled)
        try container.encode(promptsForDownloadOptions, forKey: .promptsForDownloadOptions)
        try container.encode(addDefaults, forKey: .addDefaults)
    }

    private static func migratedSchemaZero(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> ApplicationBehaviorPreferences {
        let speedAveraging = SpeedAveragingPolicy(
            isEnabled: (try? container.decode(Bool.self, forKey: .averageSpeeds))
                ?? defaults.speedAveraging.isEnabled,
            sampleLimit: (try? container.decode(Int.self, forKey: .speedAverageSamples))
                ?? defaults.speedAveraging.sampleLimit,
            windowSeconds: (try? container.decode(Int.self, forKey: .speedAverageWindowSeconds))
                ?? defaults.speedAveraging.windowSeconds
        )
        let startPaused = (try? container.decode(Bool.self, forKey: .startPaused)) ?? false
        let priorityRawValue = (try? container.decode(Int.self, forKey: .addPriority))
            ?? AddTorrentDefaultPriority.normal.rawValue
        let markAllUnwanted = (
            try? container.decode(Bool.self, forKey: .markAllFilesUnwanted)
        ) ?? false
        let peerLimit = try? container.decodeIfPresent(Int.self, forKey: .addPeerLimit)

        return ApplicationBehaviorPreferences(
            speedAveraging: speedAveraging,
            completionNotificationsEnabled: (try? container.decode(
                Bool.self,
                forKey: .notifyOnCompletion
            )) ?? defaults.completionNotificationsEnabled,
            promptsForDownloadOptions: true,
            addDefaults: AddTorrentDefaults(
                startIntent: startPaused ? .paused : .start,
                priority: AddTorrentDefaultPriority(rawValue: priorityRawValue) ?? .normal,
                unwantedFiles: markAllUnwanted
                    ? .allUnwantedWhenFileListKnown
                    : .daemonDefault,
                peerLimit: peerLimit
            )
        )
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
