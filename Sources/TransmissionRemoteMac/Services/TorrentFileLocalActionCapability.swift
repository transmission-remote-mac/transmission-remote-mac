// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

/// A serial worker bounds filesystem work even when selection changes faster
/// than a mounted volume answers. Cancellation is checked before materializing
/// selection and between every path/component; no detached jobs are abandoned.
actor TorrentFileLocalActionCapabilityWorker {
    typealias Validator = @Sendable (TorrentFileLocalActionMapping, String, [TorrentFileNode]) throws -> Bool
    private let validate: Validator

    init(validate: @escaping Validator = { mapping, directory, nodes in
        try TorrentFileLocalPathResolver(mapping: mapping).validate(
            downloadDirectory: directory,
            nodes: nodes
        )
    }) {
        self.validate = validate
    }

    func evaluate(_ request: TorrentFileLocalActionCapabilityRequest, planner: TorrentFileSelectionPlanner) throws -> Bool {
        try Task.checkCancellation()
        let nodes = planner.nodes(in: request.selection)
        guard nodes.count == request.selection.count else { return false }
        try Task.checkCancellation()
        return try validate(request.mapping, request.downloadDirectory, nodes)
    }
}

@MainActor
final class TorrentFileLocalActionCapability: ObservableObject {
    @Published private var result: Result?
    private var generation = 0
    private let worker: TorrentFileLocalActionCapabilityWorker

    private struct Result {
        let request: TorrentFileLocalActionCapabilityRequest
        let allowed: Bool
    }

    init(worker: TorrentFileLocalActionCapabilityWorker = TorrentFileLocalActionCapabilityWorker()) {
        self.worker = worker
    }

    /// Reading enablement is pure. A successful check is a UI hint, never an
    /// authorization token: the action executor resolves all paths again.
    func allows(_ request: TorrentFileLocalActionCapabilityRequest?) -> Bool {
        guard let request, result?.request == request else { return false }
        return result?.allowed == true
    }

    func update(_ request: TorrentFileLocalActionCapabilityRequest?, planner: TorrentFileSelectionPlanner) async {
        generation += 1
        let expectedGeneration = generation
        result = nil
        guard let request, !Task.isCancelled else { return }
        let allowed = (try? await worker.evaluate(request, planner: planner)) == true
        guard !Task.isCancelled, generation == expectedGeneration else { return }
        result = Result(request: request, allowed: allowed)
    }
}
