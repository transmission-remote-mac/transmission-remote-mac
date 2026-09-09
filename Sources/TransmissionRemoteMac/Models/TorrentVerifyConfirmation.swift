// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct TorrentVerifyConfirmation: Identifiable, Equatable, Sendable {
    let ownership: TorrentOperationOwnership
    let torrentNames: [String]

    var id: UUID { ownership.operationID }
    var torrentCount: Int { ownership.torrentHashes.count }

    var title: String {
        if torrentCount == 1 {
            return torrentNames.first.map { "Verify \($0)?" }
                ?? "Verify 1 Torrent?"
        }
        return "Verify \(torrentCount) Torrents?"
    }

    var message: String {
        "Verification can take a long time and may temporarily affect transfer performance."
    }

    var confirmTitle: String { "Verify" }
    var cancelTitle: String { "Cancel" }
}
