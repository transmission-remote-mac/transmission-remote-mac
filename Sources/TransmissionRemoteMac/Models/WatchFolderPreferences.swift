// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum WatchFolderSuccessPolicy: String, Codable, Equatable, Sendable {
    case keepSource
    case moveSource
    case deleteSource
}

enum WatchFolderSubmissionPolicy: String, Codable, Equatable, Sendable {
    case confirmBeforeAdding
    case submitDirectly

    var disposition: AddTorrentSubmissionDisposition {
        switch self {
        case .confirmBeforeAdding:
            .presentOptions
        case .submitDirectly:
            .submitDirectly
        }
    }
}

/// Opt-in watch-folder configuration. Local locations are represented only by
/// opaque security-scoped bookmark bytes, never by persisted path strings.
struct WatchFolderConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    static let allowedScanIntervalSeconds = 5 ... 3_600
    static let defaults = WatchFolderConfiguration(
        isEnabled: false,
        sourceBookmarkData: nil,
        remoteDestination: "",
        scanIntervalSeconds: 60,
        successPolicy: .keepSource,
        submissionPolicy: .confirmBeforeAdding,
        processedFolderBookmarkData: nil
    )

    private(set) var isEnabled: Bool
    private(set) var sourceBookmarkData: Data?
    private(set) var remoteDestination: String
    private(set) var scanIntervalSeconds: Int
    private(set) var successPolicy: WatchFolderSuccessPolicy
    private(set) var submissionPolicy: WatchFolderSubmissionPolicy
    private(set) var processedFolderBookmarkData: Data?
    /// Store-assigned compare-and-swap token. It is deliberately excluded from
    /// user-visible configuration equality.
    private(set) var configurationRevision: UInt64

    init(
        isEnabled: Bool,
        sourceBookmarkData: Data?,
        remoteDestination: String,
        scanIntervalSeconds: Int,
        successPolicy: WatchFolderSuccessPolicy,
        submissionPolicy: WatchFolderSubmissionPolicy = .confirmBeforeAdding,
        processedFolderBookmarkData: Data?,
        configurationRevision: UInt64 = 0
    ) {
        self.isEnabled = isEnabled
        self.sourceBookmarkData = sourceBookmarkData?.nilWhenEmpty
        self.remoteDestination = (
            try? RemotePOSIXDestinationValidator.validated(remoteDestination)
        ) ?? ""
        self.scanIntervalSeconds = Self.allowedScanIntervalSeconds.clamped(
            scanIntervalSeconds
        )
        self.successPolicy = successPolicy
        self.submissionPolicy = submissionPolicy
        self.processedFolderBookmarkData = processedFolderBookmarkData?.nilWhenEmpty
        self.configurationRevision = configurationRevision
    }

    var isReadyToScan: Bool {
        guard isEnabled,
              sourceBookmarkData != nil,
              !remoteDestination.isEmpty else {
            return false
        }
        return successPolicy != .moveSource || processedFolderBookmarkData != nil
    }

    func redactedPortableConfiguration() -> RedactedPortableWatchFolderConfiguration {
        RedactedPortableWatchFolderConfiguration(
            isEnabled: false,
            remoteDestination: remoteDestination,
            scanIntervalSeconds: scanIntervalSeconds,
            successPolicy: successPolicy,
            submissionPolicy: submissionPolicy,
            requiresSourceFolderSelection: sourceBookmarkData != nil,
            requiresProcessedFolderSelection: successPolicy == .moveSource
                && processedFolderBookmarkData != nil
        )
    }

    func assigningRevision(_ revision: UInt64) -> WatchFolderConfiguration {
        var configuration = self
        configuration.configurationRevision = revision
        return configuration
    }

    static func == (
        lhs: WatchFolderConfiguration,
        rhs: WatchFolderConfiguration
    ) -> Bool {
        lhs.isEnabled == rhs.isEnabled
            && lhs.sourceBookmarkData == rhs.sourceBookmarkData
            && lhs.remoteDestination == rhs.remoteDestination
            && lhs.scanIntervalSeconds == rhs.scanIntervalSeconds
            && lhs.successPolicy == rhs.successPolicy
            && lhs.submissionPolicy == rhs.submissionPolicy
            && lhs.processedFolderBookmarkData == rhs.processedFolderBookmarkData
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case sourceBookmarkData
        case remoteDestination
        case scanIntervalSeconds
        case successPolicy
        case submissionPolicy
        case processedFolderBookmarkData
        case configurationRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        guard (1 ... Self.currentSchemaVersion).contains(schemaVersion) else {
            self = .defaults
            return
        }

        self.init(
            isEnabled: (try? container.decode(Bool.self, forKey: .isEnabled)) ?? false,
            sourceBookmarkData: try? container.decodeIfPresent(
                Data.self,
                forKey: .sourceBookmarkData
            ),
            remoteDestination: (try? container.decode(
                String.self,
                forKey: .remoteDestination
            )) ?? "",
            scanIntervalSeconds: (try? container.decode(
                Int.self,
                forKey: .scanIntervalSeconds
            )) ?? Self.defaults.scanIntervalSeconds,
            successPolicy: (try? container.decode(
                WatchFolderSuccessPolicy.self,
                forKey: .successPolicy
            )) ?? .keepSource,
            submissionPolicy: (try? container.decode(
                WatchFolderSubmissionPolicy.self,
                forKey: .submissionPolicy
            )) ?? .confirmBeforeAdding,
            processedFolderBookmarkData: try? container.decodeIfPresent(
                Data.self,
                forKey: .processedFolderBookmarkData
            ),
            configurationRevision: schemaVersion >= 2
                ? (try? container.decode(
                    UInt64.self,
                    forKey: .configurationRevision
                )) ?? 0
                : 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(sourceBookmarkData, forKey: .sourceBookmarkData)
        try container.encode(remoteDestination, forKey: .remoteDestination)
        try container.encode(scanIntervalSeconds, forKey: .scanIntervalSeconds)
        try container.encode(successPolicy, forKey: .successPolicy)
        try container.encode(submissionPolicy, forKey: .submissionPolicy)
        try container.encodeIfPresent(
            processedFolderBookmarkData,
            forKey: .processedFolderBookmarkData
        )
        try container.encode(configurationRevision, forKey: .configurationRevision)
    }
}

/// Portable watch-folder preferences deliberately omit both bookmark blobs.
/// An imported configuration stays disabled until the user reselects folders.
struct RedactedPortableWatchFolderConfiguration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion = Self.currentSchemaVersion
    var isEnabled: Bool
    var remoteDestination: String
    var scanIntervalSeconds: Int
    var successPolicy: WatchFolderSuccessPolicy
    var submissionPolicy: WatchFolderSubmissionPolicy
    var requiresSourceFolderSelection: Bool
    var requiresProcessedFolderSelection: Bool

    init(
        isEnabled: Bool,
        remoteDestination: String,
        scanIntervalSeconds: Int,
        successPolicy: WatchFolderSuccessPolicy,
        submissionPolicy: WatchFolderSubmissionPolicy = .confirmBeforeAdding,
        requiresSourceFolderSelection: Bool,
        requiresProcessedFolderSelection: Bool
    ) {
        self.isEnabled = isEnabled
        self.remoteDestination = remoteDestination
        self.scanIntervalSeconds = scanIntervalSeconds
        self.successPolicy = successPolicy
        self.submissionPolicy = submissionPolicy
        self.requiresSourceFolderSelection = requiresSourceFolderSelection
        self.requiresProcessedFolderSelection = requiresProcessedFolderSelection
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case isEnabled
        case remoteDestination
        case scanIntervalSeconds
        case successPolicy
        case submissionPolicy
        case requiresSourceFolderSelection
        case requiresProcessedFolderSelection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        remoteDestination = try container.decode(String.self, forKey: .remoteDestination)
        scanIntervalSeconds = try container.decode(Int.self, forKey: .scanIntervalSeconds)
        successPolicy = try container.decode(
            WatchFolderSuccessPolicy.self,
            forKey: .successPolicy
        )
        submissionPolicy = try container.decodeIfPresent(
            WatchFolderSubmissionPolicy.self,
            forKey: .submissionPolicy
        ) ?? .confirmBeforeAdding
        requiresSourceFolderSelection = try container.decode(
            Bool.self,
            forKey: .requiresSourceFolderSelection
        )
        requiresProcessedFolderSelection = try container.decode(
            Bool.self,
            forKey: .requiresProcessedFolderSelection
        )
    }
}

struct WatchFolderFailureRecord: Codable, Equatable, Identifiable, Sendable {
    static let maximumAttemptCount = 10_000
    static let maximumErrorLength = 500

    var id: String { stableFileIdentity }
    private(set) var stableFileIdentity: String
    private(set) var fileName: String
    private(set) var attemptCount: Int
    private(set) var firstFailureTime: TimeInterval
    private(set) var lastFailureTime: TimeInterval
    private(set) var nextRetryTime: TimeInterval
    private(set) var errorMessage: String

    init(
        stableFileIdentity: String,
        fileName: String,
        attemptCount: Int,
        firstFailureTime: TimeInterval,
        lastFailureTime: TimeInterval,
        nextRetryTime: TimeInterval,
        errorMessage: String
    ) {
        self.stableFileIdentity = stableFileIdentity
        self.fileName = fileName
        self.attemptCount = min(max(attemptCount, 1), Self.maximumAttemptCount)
        self.firstFailureTime = firstFailureTime.isFinite ? firstFailureTime : 0
        self.lastFailureTime = lastFailureTime.isFinite ? lastFailureTime : 0
        self.nextRetryTime = nextRetryTime.isFinite ? nextRetryTime : 0
        self.errorMessage = String(errorMessage.prefix(Self.maximumErrorLength))
    }

    mutating func makeRetryDue(at time: TimeInterval) {
        nextRetryTime = time.isFinite ? time : 0
    }

    private enum CodingKeys: String, CodingKey {
        case stableFileIdentity
        case fileName
        case attemptCount
        case firstFailureTime
        case lastFailureTime
        case nextRetryTime
        case errorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            stableFileIdentity: (try? container.decode(
                String.self,
                forKey: .stableFileIdentity
            )) ?? "",
            fileName: (try? container.decode(String.self, forKey: .fileName)) ?? "",
            attemptCount: (try? container.decode(Int.self, forKey: .attemptCount)) ?? 1,
            firstFailureTime: (try? container.decode(
                TimeInterval.self,
                forKey: .firstFailureTime
            )) ?? 0,
            lastFailureTime: (try? container.decode(
                TimeInterval.self,
                forKey: .lastFailureTime
            )) ?? 0,
            nextRetryTime: (try? container.decode(
                TimeInterval.self,
                forKey: .nextRetryTime
            )) ?? 0,
            errorMessage: (try? container.decode(String.self, forKey: .errorMessage)) ?? ""
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableFileIdentity, forKey: .stableFileIdentity)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(attemptCount, forKey: .attemptCount)
        try container.encode(firstFailureTime, forKey: .firstFailureTime)
        try container.encode(lastFailureTime, forKey: .lastFailureTime)
        try container.encode(nextRetryTime, forKey: .nextRetryTime)
        try container.encode(errorMessage, forKey: .errorMessage)
    }
}

struct WatchFolderFailureQueueState: Codable, Equatable, Sendable {
    static let maximumRetainedFailures = 500
    static let empty = WatchFolderFailureQueueState()

    private(set) var failures: [WatchFolderFailureRecord]
    /// Eligible items held back because admitting them could not be tracked
    /// durably. Retained failures are never evicted to make room for these.
    private(set) var overflowedFailureCount: Int

    init(
        failures: [WatchFolderFailureRecord] = [],
        overflowedFailureCount: Int = 0
    ) {
        let unique = failures.deduplicatedByStableIdentity()
        self.failures = Array(unique.prefix(Self.maximumRetainedFailures))
        self.overflowedFailureCount = Self.boundedCount(
            max(0, overflowedFailureCount),
            adding: max(0, unique.count - Self.maximumRetainedFailures)
        )
    }

    var isVisible: Bool {
        !failures.isEmpty || overflowedFailureCount > 0
    }

    var count: Int {
        Self.boundedCount(failures.count, adding: overflowedFailureCount)
    }

    var retainedCount: Int {
        failures.count
    }

    func failure(for stableFileIdentity: String) -> WatchFolderFailureRecord? {
        failures.first { $0.stableFileIdentity == stableFileIdentity }
    }

    mutating func replace(_ failure: WatchFolderFailureRecord) {
        if let index = failures.firstIndex(where: {
            $0.stableFileIdentity == failure.stableFileIdentity
        }) {
            failures[index] = failure
        } else if failures.count < Self.maximumRetainedFailures {
            failures.append(failure)
        } else {
            overflowedFailureCount = Self.boundedCount(
                overflowedFailureCount,
                adding: 1
            )
        }
    }

    mutating func setOverflowedFailureCount(_ count: Int) {
        overflowedFailureCount = max(0, count)
    }

    @discardableResult
    mutating func clear(stableFileIdentity: String) -> Bool {
        let previousCount = failures.count
        failures.removeAll { $0.stableFileIdentity == stableFileIdentity }
        return failures.count != previousCount
    }

    mutating func clearAll() {
        failures.removeAll(keepingCapacity: false)
        overflowedFailureCount = 0
    }

    mutating func makeRetriesDue(at time: TimeInterval) {
        for index in failures.indices {
            failures[index].makeRetryDue(at: time)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case failures
        case overflowedFailureCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            failures: (try? container.decode(
                [WatchFolderFailureRecord].self,
                forKey: .failures
            )) ?? [],
            overflowedFailureCount: (try? container.decode(
                Int.self,
                forKey: .overflowedFailureCount
            )) ?? 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(failures, forKey: .failures)
        try container.encode(overflowedFailureCount, forKey: .overflowedFailureCount)
    }

    private static func boundedCount(_ count: Int, adding increment: Int) -> Int {
        guard increment > 0 else { return max(0, count) }
        return count > Int.max - increment ? Int.max : count + increment
    }
}

struct WatchFolderProcessingState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    static let maximumAcknowledgedIdentities = 2_048
    static let defaults = WatchFolderProcessingState()

    private(set) var acknowledgedFileIdentities: [String]
    private(set) var failureQueue: WatchFolderFailureQueueState
    private(set) var pendingSourceCleanupIdentities: [String]
    private(set) var revision: UInt64

    init(
        acknowledgedFileIdentities: [String] = [],
        failureQueue: WatchFolderFailureQueueState = .empty,
        pendingSourceCleanupIdentities: [String] = [],
        revision: UInt64 = 0
    ) {
        self.acknowledgedFileIdentities = Array(
            acknowledgedFileIdentities
                .filter { !$0.isEmpty }
                .uniquedPreservingOrder()
                .prefix(Self.maximumAcknowledgedIdentities)
        )
        self.failureQueue = failureQueue
        self.pendingSourceCleanupIdentities = Array(
            pendingSourceCleanupIdentities
                .filter { !$0.isEmpty }
                .uniquedPreservingOrder()
                .prefix(Self.maximumAcknowledgedIdentities)
        )
        self.revision = revision
    }

    @discardableResult
    mutating func acknowledge(_ stableFileIdentity: String) -> Bool {
        guard !stableFileIdentity.isEmpty else { return false }
        var changed = removePendingSourceCleanup(stableFileIdentity)
        if acknowledgedFileIdentities.contains(stableFileIdentity) {
            if changed {
                advanceRevision()
            }
            return true
        }
        guard acknowledgedFileIdentities.count < Self.maximumAcknowledgedIdentities else {
            let previousOverflowCount = failureQueue.overflowedFailureCount
            failureQueue.setOverflowedFailureCount(max(previousOverflowCount, 1))
            changed = changed || failureQueue.overflowedFailureCount != previousOverflowCount
            if changed {
                advanceRevision()
            }
            return false
        }
        acknowledgedFileIdentities.append(stableFileIdentity)
        advanceRevision()
        return true
    }

    mutating func replaceFailure(_ failure: WatchFolderFailureRecord) {
        let previousQueue = failureQueue
        failureQueue.replace(failure)
        if failureQueue != previousQueue {
            advanceRevision()
        }
    }

    mutating func deferSourceCleanup(_ failure: WatchFolderFailureRecord) {
        let previousQueue = failureQueue
        var changed = false
        if !pendingSourceCleanupIdentities.contains(failure.stableFileIdentity),
           pendingSourceCleanupIdentities.count < Self.maximumAcknowledgedIdentities {
            pendingSourceCleanupIdentities.append(failure.stableFileIdentity)
            changed = true
        }
        failureQueue.replace(failure)
        changed = changed || failureQueue != previousQueue
        if changed {
            advanceRevision()
        }
    }

    mutating func completeSourceCleanup(_ stableFileIdentity: String) {
        let removedPending = removePendingSourceCleanup(stableFileIdentity)
        let removedFailure = failureQueue.clear(stableFileIdentity: stableFileIdentity)
        if removedPending || removedFailure {
            advanceRevision()
        }
    }

    func isAwaitingSourceCleanup(_ stableFileIdentity: String) -> Bool {
        pendingSourceCleanupIdentities.contains(stableFileIdentity)
    }

    func supersedesOrDiverges(from other: WatchFolderProcessingState) -> Bool {
        revision > other.revision || (revision == other.revision && self != other)
    }

    @discardableResult
    mutating func clearFailure(stableFileIdentity: String) -> Bool {
        let cleared = failureQueue.clear(stableFileIdentity: stableFileIdentity)
        if cleared {
            advanceRevision()
        }
        return cleared
    }

    mutating func clearAllFailures() {
        let previousQueue = failureQueue
        failureQueue.clearAll()
        if failureQueue != previousQueue {
            advanceRevision()
        }
    }

    mutating func makeRetriesDue(at time: TimeInterval) {
        let previousQueue = failureQueue
        failureQueue.makeRetriesDue(at: time)
        if failureQueue != previousQueue {
            advanceRevision()
        }
    }

    mutating func setOverflowedFailureCount(_ count: Int) {
        let previousCount = failureQueue.overflowedFailureCount
        failureQueue.setOverflowedFailureCount(count)
        if failureQueue.overflowedFailureCount != previousCount {
            advanceRevision()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case acknowledgedFileIdentities
        case failureQueue
        case pendingSourceCleanupIdentities
        case revision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        guard (1 ... Self.currentSchemaVersion).contains(schemaVersion) else {
            self = .defaults
            return
        }
        self.init(
            acknowledgedFileIdentities: (try? container.decode(
                [String].self,
                forKey: .acknowledgedFileIdentities
            )) ?? [],
            failureQueue: (try? container.decode(
                WatchFolderFailureQueueState.self,
                forKey: .failureQueue
            )) ?? .empty,
            pendingSourceCleanupIdentities: schemaVersion >= 2
                ? (try? container.decode(
                    [String].self,
                    forKey: .pendingSourceCleanupIdentities
                )) ?? []
                : [],
            revision: schemaVersion >= 3
                ? (try? container.decode(UInt64.self, forKey: .revision)) ?? 0
                : 0
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(acknowledgedFileIdentities, forKey: .acknowledgedFileIdentities)
        try container.encode(failureQueue, forKey: .failureQueue)
        try container.encode(
            pendingSourceCleanupIdentities,
            forKey: .pendingSourceCleanupIdentities
        )
        try container.encode(revision, forKey: .revision)
    }

    private mutating func removePendingSourceCleanup(_ stableFileIdentity: String) -> Bool {
        let previousCount = pendingSourceCleanupIdentities.count
        pendingSourceCleanupIdentities.removeAll { $0 == stableFileIdentity }
        return pendingSourceCleanupIdentities.count != previousCount
    }

    private mutating func advanceRevision() {
        if revision < UInt64.max {
            revision += 1
        }
    }
}

private extension Data {
    var nilWhenEmpty: Data? {
        isEmpty ? nil : self
    }
}

private extension ClosedRange where Bound == Int {
    func clamped(_ value: Int) -> Int {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}

private extension Array where Element == String {
    func uniquedPreservingOrder() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}

private extension Array where Element == WatchFolderFailureRecord {
    func deduplicatedByStableIdentity() -> [WatchFolderFailureRecord] {
        var indicesByIdentity: [String: Int] = [:]
        var result: [WatchFolderFailureRecord] = []
        for failure in self where !failure.stableFileIdentity.isEmpty {
            if let index = indicesByIdentity[failure.stableFileIdentity] {
                result[index] = failure
            } else {
                indicesByIdentity[failure.stableFileIdentity] = result.count
                result.append(failure)
            }
        }
        return result
    }
}
