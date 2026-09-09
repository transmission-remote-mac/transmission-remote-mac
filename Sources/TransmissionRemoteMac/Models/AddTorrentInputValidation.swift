// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum AddTorrentInputValidationError: LocalizedError, Equatable {
    case emptyRemoteSource
    case malformedInfoHash
    case unsupportedRemoteSource
    case missingLocalTorrentFile
    case emptyLocalTorrentFile

    var errorDescription: String? {
        switch self {
        case .emptyRemoteSource:
            "Enter an info hash, magnet link, torrent URL, or daemon-visible path."
        case .malformedInfoHash:
            "Info hashes must be 32 Base32 characters, 40 hexadecimal characters, or 64 hexadecimal characters."
        case .unsupportedRemoteSource:
            "Use an info hash, magnet link, http/https torrent URL, or absolute daemon-visible path."
        case .missingLocalTorrentFile:
            "Choose a local .torrent file first."
        case .emptyLocalTorrentFile:
            "The selected .torrent file is empty."
        }
    }
}

enum AddTorrentInputValidator {
    static func normalizedRemoteSource(_ source: String) throws -> String {
        do {
            return try TorrentSourceNormalizer.normalize(source)
        } catch let error as TorrentSourceNormalizationError {
            switch error {
            case .emptySource:
                throw AddTorrentInputValidationError.emptyRemoteSource
            case .malformedInfoHash:
                throw AddTorrentInputValidationError.malformedInfoHash
            case .unsupportedSource:
                throw AddTorrentInputValidationError.unsupportedRemoteSource
            }
        }
    }

    static func validatedLocalTorrentData(_ data: Data?) throws -> Data {
        guard let data else {
            throw AddTorrentInputValidationError.missingLocalTorrentFile
        }
        guard !data.isEmpty else {
            throw AddTorrentInputValidationError.emptyLocalTorrentFile
        }
        return data
    }
}
