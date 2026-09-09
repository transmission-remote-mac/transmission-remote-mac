// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct TorrentDetailStateUnavailableView: View {
    var state: TorrentDetailLoadState
    var title: String

    var body: some View {
        switch state {
        case .notLoaded:
            ContentUnavailableView("\(title) not loaded", systemImage: "clock")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loading:
            ProgressView("Loading \(title.lowercased())…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Unable to Load \(title)", systemImage: "exclamationmark.triangle", description: Text(message))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            EmptyView()
        }
    }
}
