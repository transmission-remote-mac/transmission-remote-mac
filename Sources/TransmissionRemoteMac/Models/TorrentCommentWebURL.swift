// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

/// A torrent comment that is safe to hand to the system web-URL opener.
/// The original comment remains the display and copy source; this value only
/// owns the validated destination used by the optional Open Link action.
struct TorrentCommentWebURL: Equatable, Sendable {
    let url: URL

    init?(_ comment: String) {
        let candidate = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.contains(where: { $0.isWhitespace || $0.isNewline }),
              candidate.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !candidate.contains("\\"),
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.port.map({ (1 ... 65_535).contains($0) }) ?? true,
              let url = components.url else {
            return nil
        }

        self.url = url
    }
}
