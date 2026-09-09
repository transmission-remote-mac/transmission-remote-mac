// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// Owns the off-main read, parse and security scope for one preview request.
/// Presentation identity remains with the caller; cancellation owns the worker.
struct TorrentFilePreviewLoader: Sendable {
    static let maximumTorrentFileBytes = 64 * 1_024 * 1_024

    var startAccess: @Sendable (URL) -> Bool = { $0.startAccessingSecurityScopedResource() }
    var stopAccess: @Sendable (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }
    var read: @Sendable (URL) throws -> RaceResistantRegularFileSnapshot = {
        try DarwinRaceResistantFileCleanup().readRegularFile(
            at: $0,
            maximumBytes: maximumTorrentFileBytes,
            checkCancellation: { try Task.checkCancellation() }
        )
    }
    var summarize: @Sendable (Data) throws -> TorrentMetainfoSummary = { try TorrentMetainfoSummary(data: $0) }

    func load(at url: URL, expectedStableIdentity: String?) async throws -> TorrentFileLoadResult {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            let canAccess = startAccess(url)
            defer { if canAccess { stopAccess(url) } }
            do {
                try Task.checkCancellation()
                let snapshot = try read(url.standardizedFileURL)
                try Task.checkCancellation()
                if let expectedStableIdentity {
                    guard let scannedIdentity = RaceResistantFileIdentity(rawValue: expectedStableIdentity) else {
                        throw WatchFolderCoordinatorError.stableIdentityUnavailable
                    }
                    guard snapshot.identity == scannedIdentity else {
                        throw WatchFolderCoordinatorError.sourceFileWasReplaced
                    }
                }
                guard !snapshot.data.isEmpty else {
                    throw AddTorrentInputValidationError.emptyLocalTorrentFile
                }
                do {
                    let summary = try summarize(snapshot.data)
                    try Task.checkCancellation()
                    return TorrentFileLoadResult.loaded(snapshot: snapshot, summary: summary, previewError: nil)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    return .loaded(snapshot: snapshot, summary: nil, previewError: error.localizedDescription)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                return .failed(error.localizedDescription)
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}
