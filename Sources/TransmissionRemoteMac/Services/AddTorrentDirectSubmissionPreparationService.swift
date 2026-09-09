// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

protocol AddTorrentDirectSubmissionPreparing: Sendable {
    func prepare(
        _ request: AddTorrentDirectSubmissionPreparationRequest
    ) async throws -> AddTorrentDirectSubmissionPreparationOutcome
}

struct AddTorrentDirectSubmissionPreparationService: AddTorrentDirectSubmissionPreparing {
    var fileLoader = TorrentFilePreviewLoader()

    func prepare(
        _ request: AddTorrentDirectSubmissionPreparationRequest
    ) async throws -> AddTorrentDirectSubmissionPreparationOutcome {
        try Task.checkCancellation()
        let options = request.initialOptions.resolving(defaults: request.savedDefaults)
        let peerLimit: Int?
        switch options.peerLimit {
        case .daemonDefault:
            peerLimit = nil
        case .limited(let value):
            peerLimit = value
        }

        let payload: AddTorrentDirectSubmissionPreparation.Payload
        switch request.source {
        case .remote(let source):
            guard options.priority == .normal,
                  options.unwantedFiles == .daemonDefault else {
                return .requiresInteraction(
                    "Torrent metadata is needed to apply the selected file priority or wanted-file choices."
                )
            }
            do {
                payload = .remote(try AddTorrentInputValidator.normalizedRemoteSource(source))
            } catch {
                return .requiresInteraction(error.localizedDescription)
            }

        case .localFile(let sourceFileURL, let expectedStableIdentity):
            let loadResult = try await fileLoader.load(
                at: sourceFileURL,
                expectedStableIdentity: expectedStableIdentity
            )
            try Task.checkCancellation()
            switch loadResult {
            case .failed(let message):
                return .requiresInteraction(message)
            case .loaded(let snapshot, let summary, let previewError):
                let fileSelection: TorrentAddFileSelection?
                let trackerURLs: [String]
                if let summary {
                    let selections = options.seedingFileSelections(
                        TorrentMetainfoFileSelection.selections(from: summary)
                    )
                    fileSelection = selections.isEmpty
                        ? nil
                        : TorrentAddFileSelection(files: selections)
                    trackerURLs = summary.announceURLs
                } else {
                    guard options.priority == .normal,
                          options.unwantedFiles == .daemonDefault else {
                        return .requiresInteraction(
                            previewError
                                ?? "Torrent metadata is needed to apply the saved file choices."
                        )
                    }
                    fileSelection = nil
                    trackerURLs = []
                }
                payload = .localFile(
                    snapshot: snapshot,
                    sourceFileURL: sourceFileURL.standardizedFileURL,
                    fileSelection: fileSelection,
                    localTrackerURLs: trackerURLs
                )
            }
        }

        try Task.checkCancellation()
        return .ready(AddTorrentDirectSubmissionPreparation(
            payload: payload,
            startPaused: options.startIntent == .paused,
            downloadDirectory: AddTorrentDestinationHistory.normalizedDestination(
                request.explicitDownloadDirectory
            ),
            peerLimit: peerLimit
        ))
    }
}
