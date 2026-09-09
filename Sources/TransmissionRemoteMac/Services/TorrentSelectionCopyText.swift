// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

enum TorrentSelectionCopyText {
    static func make(
        visibleTorrents: [TorrentSummary],
        selectedIDs: Set<TorrentSummary.ID>
    ) -> String? {
        guard !selectedIDs.isEmpty else { return nil }

        let names = visibleTorrents.compactMap { torrent in
            selectedIDs.contains(torrent.id) ? torrent.name : nil
        }

        guard names.count == selectedIDs.count else { return nil }
        return names.joined(separator: "\n")
    }
}
