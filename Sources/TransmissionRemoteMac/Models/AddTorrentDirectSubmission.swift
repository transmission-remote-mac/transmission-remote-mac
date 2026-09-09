// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum AddTorrentIntakeSourceKind: Equatable, Sendable {
    case manual
    case remote
    case localFile
}

enum AddTorrentSubmissionDisposition: Equatable, Sendable {
    case presentOptions
    case submitDirectly
}

struct AddTorrentSubmissionDispositionPolicy: Sendable {
    func disposition(
        for sourceKind: AddTorrentIntakeSourceKind,
        promptsForDownloadOptions: Bool
    ) -> AddTorrentSubmissionDisposition {
        guard !promptsForDownloadOptions else { return .presentOptions }
        switch sourceKind {
        case .manual:
            return .presentOptions
        case .remote, .localFile:
            return .submitDirectly
        }
    }
}

enum AddTorrentDirectSubmissionSource: Equatable, Sendable {
    case remote(String)
    case localFile(URL, expectedStableIdentity: String?)
}

struct AddTorrentDirectSubmissionPreparationRequest: Equatable, Sendable {
    var source: AddTorrentDirectSubmissionSource
    var initialOptions: AddTorrentInitialOptions
    var savedDefaults: AddTorrentDefaults
    var explicitDownloadDirectory: String?
}

struct AddTorrentDirectSubmissionPreparation: Equatable, Sendable {
    enum Payload: Equatable, Sendable {
        case remote(String)
        case localFile(
            snapshot: RaceResistantRegularFileSnapshot,
            sourceFileURL: URL,
            fileSelection: TorrentAddFileSelection?,
            localTrackerURLs: [String]
        )
    }

    var payload: Payload
    var startPaused: Bool
    var downloadDirectory: String?
    var peerLimit: Int?
}

enum AddTorrentDirectSubmissionPreparationOutcome: Equatable, Sendable {
    case ready(AddTorrentDirectSubmissionPreparation)
    case requiresInteraction(String)
}
