// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum PerformanceHarnessTraceEvent: String, Codable, Sendable {
    case torrentListPublication = "torrent_list_publication"
    case mainThreadApply = "main_thread_apply"
    case listProjection = "list_projection"
    case cachedSelection = "cached_selection"
    case filesRPCLatency = "files_rpc_latency"
    case filesProjection = "files_projection"
    case filesSelectAll = "files_select_all"
    case filesMutationPlan = "files_mutation_plan"
    case filesPaneProof = "files_pane_proof"
}

enum PerformanceHarnessTraceOutcome: String, Codable, Sendable {
    case accepted
    case rejected
    case measured
    case proven
}

struct PerformanceHarnessTraceOwnership: Codable, Equatable, Sendable {
    let profileID: UUID
    let connectionGeneration: UUID
    let requestSequence: UInt64

    var isValid: Bool {
        requestSequence > 0
    }
}

struct PerformanceHarnessTraceRecord: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let event: PerformanceHarnessTraceEvent
    let outcome: PerformanceHarnessTraceOutcome
    let profileID: UUID?
    let connectionGeneration: UUID?
    let requestSequence: UInt64?
    let durationNanoseconds: UInt64
    let torrentID: Int?
    let revision: UUID?
    let rowCount: Int?
    let fileCount: Int?
    let selectedCount: Int?
    let operation: String?
    let pane: String?
    let reason: String?

    init(
        event: PerformanceHarnessTraceEvent,
        outcome: PerformanceHarnessTraceOutcome,
        ownership: PerformanceHarnessTraceOwnership? = nil,
        durationNanoseconds: UInt64 = 0,
        torrentID: Int? = nil,
        revision: UUID? = nil,
        rowCount: Int? = nil,
        fileCount: Int? = nil,
        selectedCount: Int? = nil,
        operation: String? = nil,
        pane: String? = nil,
        reason: String? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.event = event
        self.outcome = outcome
        profileID = ownership?.profileID
        connectionGeneration = ownership?.connectionGeneration
        requestSequence = ownership?.requestSequence
        self.durationNanoseconds = durationNanoseconds
        self.torrentID = torrentID
        self.revision = revision
        self.rowCount = rowCount
        self.fileCount = fileCount
        self.selectedCount = selectedCount
        self.operation = operation
        self.pane = pane
        self.reason = reason
    }

    var isValid: Bool {
        guard schemaVersion == Self.currentSchemaVersion else { return false }
        guard rowCount.map({ $0 >= 0 }) ?? true else { return false }
        guard fileCount.map({ $0 >= 0 }) ?? true else { return false }
        guard selectedCount.map({ $0 >= 0 }) ?? true else { return false }
        guard torrentID.map({ $0 > 0 }) ?? true else { return false }

        switch event {
        case .torrentListPublication:
            guard traceOwnership?.isValid == true, rowCount != nil else { return false }
            switch outcome {
            case .accepted:
                return reason == nil
            case .rejected:
                return Self.rejectionReasons.contains(reason ?? "")
            case .measured, .proven:
                return false
            }

        case .mainThreadApply:
            return outcome == .measured && traceOwnership?.isValid == true && rowCount != nil

        case .listProjection:
            return outcome == .measured
                && rowCount != nil
                && Self.projectionOperations.contains(operation ?? "")

        case .cachedSelection:
            return outcome == .measured
                && rowCount != nil
                && selectedCount != nil
                && operation == "lookup"

        case .filesRPCLatency:
            return outcome == .measured && torrentID != nil && revision != nil && fileCount != nil

        case .filesProjection:
            return outcome == .measured
                && torrentID != nil
                && revision != nil
                && fileCount != nil
                && rowCount != nil

        case .filesSelectAll:
            return outcome == .measured
                && torrentID != nil
                && revision != nil
                && fileCount != nil
                && selectedCount != nil
                && Self.selectionOperations.contains(operation ?? "")

        case .filesMutationPlan:
            return outcome == .measured
                && torrentID != nil
                && revision != nil
                && fileCount != nil
                && selectedCount != nil
                && operation == "selected-file-indexes"

        case .filesPaneProof:
            guard torrentID != nil, revision != nil, fileCount != nil else { return false }
            if outcome == .rejected {
                return reason == "stale-revision"
            }
            return outcome == .proven
                && durationNanoseconds > 0
                && pane == "files"
                && selectedCount != nil
        }
    }

    private static let rejectionReasons = Set([
        "stale-owner",
        "field-plan",
        "accumulator",
        "bootstrap",
    ])
    private static let projectionOperations = Set(["search", "sort", "filter"])
    private static let selectionOperations = Set(["plan", "state-commit"])

    private var traceOwnership: PerformanceHarnessTraceOwnership? {
        guard let profileID, let connectionGeneration, let requestSequence else { return nil }
        return PerformanceHarnessTraceOwnership(
            profileID: profileID,
            connectionGeneration: connectionGeneration,
            requestSequence: requestSequence
        )
    }
}

struct PerformanceHarnessFilesSelectionPlan: Equatable, Sendable {
    let identity: TorrentFilesProjectionIdentity
    let fileCount: Int
    let selectedNodeIDs: Set<TorrentFileNode.ID>
}

struct PerformanceHarnessFilesSelectionCommit: Sendable {
    let plan: PerformanceHarnessFilesSelectionPlan
    let acknowledgementStartedAt: ContinuousClock.Instant
}
