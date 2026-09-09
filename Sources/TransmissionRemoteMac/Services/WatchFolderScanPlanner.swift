// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum WatchFolderDirectoryEntryKind: String, Codable, Equatable, Sendable {
    case regularFile
    case directory
    case symbolicLink
    case other
}

struct WatchFolderDirectoryEntry: Equatable, Sendable {
    var stableFileIdentity: String
    var fileName: String
    var kind: WatchFolderDirectoryEntryKind
    var isHidden: Bool

    init(
        stableFileIdentity: String,
        fileName: String,
        kind: WatchFolderDirectoryEntryKind,
        isHidden: Bool = false
    ) {
        self.stableFileIdentity = stableFileIdentity
        self.fileName = fileName
        self.kind = kind
        self.isHidden = isHidden
    }
}

struct WatchFolderScanJob: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case addTorrent
        case sourceCleanup
    }

    var stableFileIdentity: String
    var fileName: String
    var attemptNumber: Int
    var isRetry: Bool
    var kind: Kind

    init(
        stableFileIdentity: String,
        fileName: String,
        attemptNumber: Int,
        isRetry: Bool,
        kind: Kind = .addTorrent
    ) {
        self.stableFileIdentity = stableFileIdentity
        self.fileName = fileName
        self.attemptNumber = attemptNumber
        self.isRetry = isRetry
        self.kind = kind
    }
}

enum WatchFolderAddAcknowledgment: Equatable, Sendable {
    case added
    case duplicate
    case failed(message: String)
}

enum WatchFolderSourceDisposition: Equatable, Sendable {
    case none
    case move(destinationBookmarkData: Data)
    case delete
}

struct WatchFolderJobResolution: Equatable, Sendable {
    var acknowledgment: WatchFolderAddAcknowledgment
    var sourceDisposition: WatchFolderSourceDisposition
}

enum WatchFolderScanPlannerError: Error, Equatable, Sendable {
    case noActiveJob
    case activeJobMismatch
}

struct WatchFolderRetryPolicy: Equatable, Sendable {
    static let defaults = WatchFolderRetryPolicy(
        initialDelaySeconds: 5,
        maximumDelaySeconds: 3_600
    )

    var initialDelaySeconds: Int
    var maximumDelaySeconds: Int

    init(initialDelaySeconds: Int, maximumDelaySeconds: Int) {
        self.initialDelaySeconds = min(max(initialDelaySeconds, 1), 3_600)
        self.maximumDelaySeconds = min(
            max(maximumDelaySeconds, self.initialDelaySeconds),
            86_400
        )
    }

    func delaySeconds(forAttempt attempt: Int) -> Int {
        let exponent = min(max(attempt - 1, 0), 20)
        let multiplier = 1 << exponent
        return min(maximumDelaySeconds, initialDelaySeconds * multiplier)
    }
}

/// Pure watch-folder scheduler. Directory enumeration, security-scope access,
/// RPC submission and source-file mutations are deliberately injected elsewhere.
struct WatchFolderScanPlanner: Sendable {
    static let maximumBatchSize = 10

    private(set) var configuration: WatchFolderConfiguration
    private(set) var state: WatchFolderProcessingState
    private(set) var activeJobs: [WatchFolderScanJob]
    private(set) var retryPolicy: WatchFolderRetryPolicy

    var activeJob: WatchFolderScanJob? {
        activeJobs.first
    }

    init(
        configuration: WatchFolderConfiguration,
        state: WatchFolderProcessingState = .defaults,
        retryPolicy: WatchFolderRetryPolicy = .defaults
    ) {
        self.configuration = configuration
        self.state = state
        activeJobs = []
        self.retryPolicy = retryPolicy
    }

    mutating func planNext(
        entries: [WatchFolderDirectoryEntry],
        now: TimeInterval
    ) -> WatchFolderScanJob? {
        guard activeJobs.isEmpty else { return nil }
        return planBatch(entries: entries, now: now, limit: 1).first
    }

    mutating func planBatch(
        entries: [WatchFolderDirectoryEntry],
        now: TimeInterval,
        limit: Int = Self.maximumBatchSize
    ) -> [WatchFolderScanJob] {
        guard configuration.isReadyToScan, now.isFinite else { return [] }
        let availableSlots = min(
            max(limit, 0),
            Self.maximumBatchSize - activeJobs.count
        )
        guard availableSlots > 0 else { return [] }

        let eligibleEntries = Self.eligibleEntries(entries)
        let entriesByIdentity = Dictionary(
            eligibleEntries.map { ($0.stableFileIdentity, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let activeIdentities = Set(activeJobs.map(\.stableFileIdentity))
        let dueFailures = state.failureQueue.failures
            .filter {
                $0.nextRetryTime <= now
                    && (entriesByIdentity[$0.stableFileIdentity] != nil
                        || state.isAwaitingSourceCleanup($0.stableFileIdentity))
            }
            .sorted {
                if $0.nextRetryTime != $1.nextRetryTime {
                    return $0.nextRetryTime < $1.nextRetryTime
                }
                return $0.stableFileIdentity < $1.stableFileIdentity
            }
            .filter { !activeIdentities.contains($0.stableFileIdentity) }

        var plannedJobs: [WatchFolderScanJob] = []
        let activeAddJobCount = activeJobs.filter { $0.kind == .addTorrent }.count
        var availableAcknowledgmentSlots = max(
            0,
            WatchFolderProcessingState.maximumAcknowledgedIdentities
                - state.acknowledgedFileIdentities.count
                - activeAddJobCount
        )
        for dueFailure in dueFailures where plannedJobs.count < availableSlots {
            let entry = entriesByIdentity[dueFailure.stableFileIdentity]
                ?? WatchFolderDirectoryEntry(
                    stableFileIdentity: dueFailure.stableFileIdentity,
                    fileName: dueFailure.fileName,
                    kind: .regularFile
                )
            let kind: WatchFolderScanJob.Kind = state.isAwaitingSourceCleanup(
                entry.stableFileIdentity
            ) ? .sourceCleanup : .addTorrent
            guard kind == .sourceCleanup || availableAcknowledgmentSlots > 0 else {
                continue
            }
            plannedJobs.append(WatchFolderScanJob(
                stableFileIdentity: entry.stableFileIdentity,
                fileName: entry.fileName,
                attemptNumber: min(
                    dueFailure.attemptCount + 1,
                    WatchFolderFailureRecord.maximumAttemptCount
                ),
                isRetry: true,
                kind: kind
            ))
            if kind == .addTorrent {
                availableAcknowledgmentSlots -= 1
            }
        }

        let acknowledged = Set(state.acknowledgedFileIdentities)
        let failed = Set(state.failureQueue.failures.map(\.stableFileIdentity))
        let reserved = activeIdentities.union(plannedJobs.map(\.stableFileIdentity))
        let newEntries = eligibleEntries.filter {
            !acknowledged.contains($0.stableFileIdentity)
                && !failed.contains($0.stableFileIdentity)
                && !reserved.contains($0.stableFileIdentity)
        }
        let activeUnfailedAddJobCount = activeJobs.filter {
            $0.kind == .addTorrent
                && state.failureQueue.failure(for: $0.stableFileIdentity) == nil
        }.count
        let availableFailureSlots = max(
            0,
            WatchFolderFailureQueueState.maximumRetainedFailures
                - state.failureQueue.retainedCount
                - activeUnfailedAddJobCount
        )
        let availableNewEntryRetentionSlots = min(
            availableAcknowledgmentSlots,
            availableFailureSlots
        )
        state.setOverflowedFailureCount(
            max(0, newEntries.count - availableNewEntryRetentionSlots)
        )

        let availableNewJobSlots = min(
            availableSlots - plannedJobs.count,
            availableNewEntryRetentionSlots
        )
        if availableNewJobSlots > 0 {
            for entry in newEntries.prefix(availableNewJobSlots) {
                plannedJobs.append(WatchFolderScanJob(
                    stableFileIdentity: entry.stableFileIdentity,
                    fileName: entry.fileName,
                    attemptNumber: 1,
                    isRetry: false
                ))
            }
        }

        activeJobs.append(contentsOf: plannedJobs)
        return plannedJobs
    }

    mutating func acknowledge(
        _ acknowledgment: WatchFolderAddAcknowledgment,
        for job: WatchFolderScanJob,
        now: TimeInterval
    ) throws -> WatchFolderJobResolution {
        guard !activeJobs.isEmpty else {
            throw WatchFolderScanPlannerError.noActiveJob
        }
        guard let activeIndex = activeJobs.firstIndex(of: job) else {
            throw WatchFolderScanPlannerError.activeJobMismatch
        }

        activeJobs.remove(at: activeIndex)
        switch acknowledgment {
        case .added:
            if job.kind == .sourceCleanup {
                state.completeSourceCleanup(job.stableFileIdentity)
                return WatchFolderJobResolution(
                    acknowledgment: acknowledgment,
                    sourceDisposition: .none
                )
            }
            state.clearFailure(stableFileIdentity: job.stableFileIdentity)
            if configuration.successPolicy == .keepSource {
                state.acknowledge(job.stableFileIdentity)
            }
            return WatchFolderJobResolution(
                acknowledgment: acknowledgment,
                sourceDisposition: sourceDispositionAfterSuccessfulAdd()
            )
        case .duplicate:
            state.clearFailure(stableFileIdentity: job.stableFileIdentity)
            state.acknowledge(job.stableFileIdentity)
            return WatchFolderJobResolution(
                acknowledgment: acknowledgment,
                sourceDisposition: .none
            )
        case .failed(let message):
            let failureTime = now.isFinite ? now : 0
            let previous = state.failureQueue.failure(for: job.stableFileIdentity)
            let attemptCount = min(
                max(previous?.attemptCount ?? 0, job.attemptNumber),
                WatchFolderFailureRecord.maximumAttemptCount
            )
            let failure = WatchFolderFailureRecord(
                stableFileIdentity: job.stableFileIdentity,
                fileName: job.fileName,
                attemptCount: attemptCount,
                firstFailureTime: previous?.firstFailureTime ?? failureTime,
                lastFailureTime: failureTime,
                nextRetryTime: failureTime + TimeInterval(
                    retryPolicy.delaySeconds(forAttempt: attemptCount)
                ),
                errorMessage: message
            )
            state.replaceFailure(failure)
            return WatchFolderJobResolution(
                acknowledgment: acknowledgment,
                sourceDisposition: .none
            )
        }
    }

    func sourceDisposition(for job: WatchFolderScanJob) throws -> WatchFolderSourceDisposition {
        guard !activeJobs.isEmpty else {
            throw WatchFolderScanPlannerError.noActiveJob
        }
        guard activeJobs.contains(job) else {
            throw WatchFolderScanPlannerError.activeJobMismatch
        }
        return sourceDispositionAfterSuccessfulAdd()
    }

    mutating func deferSourceCleanup(
        for job: WatchFolderScanJob,
        message: String,
        now: TimeInterval
    ) throws {
        guard !activeJobs.isEmpty else {
            throw WatchFolderScanPlannerError.noActiveJob
        }
        guard let activeIndex = activeJobs.firstIndex(of: job) else {
            throw WatchFolderScanPlannerError.activeJobMismatch
        }
        activeJobs.remove(at: activeIndex)
        let failureTime = now.isFinite ? now : 0
        let previous = state.failureQueue.failure(for: job.stableFileIdentity)
        let attemptCount = min(
            max(previous?.attemptCount ?? 0, job.attemptNumber),
            WatchFolderFailureRecord.maximumAttemptCount
        )
        state.deferSourceCleanup(WatchFolderFailureRecord(
            stableFileIdentity: job.stableFileIdentity,
            fileName: job.fileName,
            attemptCount: attemptCount,
            firstFailureTime: previous?.firstFailureTime ?? failureTime,
            lastFailureTime: failureTime,
            nextRetryTime: failureTime + TimeInterval(
                retryPolicy.delaySeconds(forAttempt: attemptCount)
            ),
            errorMessage: message
        ))
    }

    mutating func failActiveJobs(message: String, now: TimeInterval) {
        let jobs = activeJobs
        for job in jobs {
            if job.kind == .sourceCleanup {
                try? deferSourceCleanup(for: job, message: message, now: now)
            } else {
                _ = try? acknowledge(.failed(message: message), for: job, now: now)
            }
        }
    }

    @discardableResult
    mutating func clearFailure(stableFileIdentity: String) -> Bool {
        guard !activeJobs.contains(where: {
            $0.stableFileIdentity == stableFileIdentity
        }) else {
            return false
        }
        return state.clearFailure(stableFileIdentity: stableFileIdentity)
    }

    mutating func clearAllFailures() {
        guard activeJobs.isEmpty else { return }
        state.clearAllFailures()
    }

    mutating func makeRetriesDue(at time: TimeInterval) {
        state.makeRetriesDue(at: time)
    }

    mutating func replaceState(_ state: WatchFolderProcessingState) {
        guard state.supersedesOrDiverges(from: self.state) else {
            return
        }
        self.state = state
    }

    mutating func replaceConfiguration(_ configuration: WatchFolderConfiguration) {
        self.configuration = configuration
        activeJobs = []
    }

    static func eligibleEntries(
        _ entries: [WatchFolderDirectoryEntry]
    ) -> [WatchFolderDirectoryEntry] {
        var identities = Set<String>()
        return entries
            .filter(\.isEligibleTorrentFile)
            .sorted {
                let nameComparison = $0.fileName.localizedStandardCompare($1.fileName)
                if nameComparison != .orderedSame {
                    return nameComparison == .orderedAscending
                }
                return $0.stableFileIdentity < $1.stableFileIdentity
            }
            .filter { identities.insert($0.stableFileIdentity).inserted }
    }

    private func sourceDispositionAfterSuccessfulAdd() -> WatchFolderSourceDisposition {
        switch configuration.successPolicy {
        case .keepSource:
            .none
        case .moveSource:
            configuration.processedFolderBookmarkData.map {
                .move(destinationBookmarkData: $0)
            } ?? .none
        case .deleteSource:
            .delete
        }
    }
}

extension WatchFolderDirectoryEntry {
    var isEligibleTorrentFile: Bool {
        !stableFileIdentity.isEmpty && Self.isEligibleTorrentFile(
            fileName: fileName, kind: kind, isHidden: isHidden
        )
    }

    static func isEligibleTorrentFile(fileName: String, kind: WatchFolderDirectoryEntryKind, isHidden: Bool) -> Bool {
        kind == .regularFile && !isHidden && isEligibleTorrentFileName(fileName)
    }

    static func isEligibleTorrentFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty,
              !fileName.hasPrefix("."),
              !fileName.contains("/"),
              !fileName.contains("\\"),
              !fileName.unicodeScalars.contains(where: {
                  $0.value == 0 || CharacterSet.controlCharacters.contains($0)
              }) else {
            return false
        }

        let lowercasedName = fileName.lowercased()
        guard lowercasedName.hasSuffix(".torrent") else {
            return false
        }
        let stem = String(lowercasedName.dropLast(".torrent".count))
        guard !stem.isEmpty,
              !stem.hasPrefix("~"),
              !stem.hasSuffix("~") else {
            return false
        }
        let temporaryStemSuffixes = [
            ".part",
            ".partial",
            ".tmp",
            ".temp",
            ".download",
            ".crdownload",
            ".aria2"
        ]
        return !temporaryStemSuffixes.contains { stem.hasSuffix($0) }
    }
}
