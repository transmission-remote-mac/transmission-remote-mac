// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum ConnectionProfileApplyFailure: LocalizedError {
    enum Kind: Equatable {
        case torrentRemovalInProgress
        case torrentAddInProgress
        case persistedProfilesChanged
        case invalidProfiles
        case persistence
    }

    case torrentRemovalInProgress
    case torrentAddInProgress
    case persistedProfilesChanged
    case invalidProfiles(any Error)
    case persistence(any Error)

    var kind: Kind {
        switch self {
        case .torrentRemovalInProgress:
            .torrentRemovalInProgress
        case .torrentAddInProgress:
            .torrentAddInProgress
        case .persistedProfilesChanged:
            .persistedProfilesChanged
        case .invalidProfiles:
            .invalidProfiles
        case .persistence:
            .persistence
        }
    }

    var underlyingError: (any Error)? {
        switch self {
        case .torrentRemovalInProgress, .torrentAddInProgress, .persistedProfilesChanged:
            nil
        case .invalidProfiles(let error), .persistence(let error):
            error
        }
    }

    var errorDescription: String? {
        switch self {
        case .torrentRemovalInProgress:
            "Wait for the torrent removal to finish before changing the Transmission connection."
        case .torrentAddInProgress:
            "Wait for the torrent add request to finish before changing the Transmission connection."
        case .persistedProfilesChanged:
            "Server settings changed elsewhere while you were editing. Revert to load the newest saved settings before editing again."
        case .invalidProfiles(let error), .persistence(let error):
            error.localizedDescription
        }
    }
}
