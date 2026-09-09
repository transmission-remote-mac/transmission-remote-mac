// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct TorrentStatusSummaryView: View {
    var summary: TorrentListSummary
    var sessionInfo: SessionInfo?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fullSummary
            compactSummary
            minimalSummary
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(.bar)
    }

    private var fullSummary: some View {
        HStack(spacing: 10) {
            SummaryItem(text: summary.countDisplay)
            Divider()
            SummaryItem(text: summary.selectedDisplay)
            Divider()
            SummaryItem(text: summary.filteredSizeDisplay)
            Divider()
            SummaryItem(text: summary.speedDisplay, monospaced: true)
            if let sessionInfo {
                Divider()
                SummaryItem(text: sessionInfo.activeSpeedLimitsDisplay, monospaced: true)
            }
            if let freeSpaceDisplay = summary.freeSpaceDisplay {
                Divider()
                SummaryItem(text: freeSpaceDisplay)
            }
            Spacer(minLength: 0)
        }
    }

    private var compactSummary: some View {
        HStack(spacing: 10) {
            SummaryItem(text: summary.countDisplay)
            Divider()
            SummaryItem(text: summary.selectedDisplay)
            Spacer(minLength: 4)
            SummaryItem(text: summary.speedDisplay, monospaced: true)
                .layoutPriority(2)
            if let sessionInfo {
                Divider()
                SummaryItem(text: sessionInfo.activeSpeedLimitsDisplay, monospaced: true)
                    .layoutPriority(2)
            }
        }
    }

    private var minimalSummary: some View {
        HStack(spacing: 10) {
            SummaryItem(text: summary.countDisplay)
            Spacer(minLength: 4)
            SummaryItem(text: summary.speedDisplay, monospaced: true)
                .layoutPriority(2)
            if let sessionInfo {
                Divider()
                SummaryItem(text: sessionInfo.activeSpeedLimitsDisplay, monospaced: true)
                    .layoutPriority(2)
            }
        }
    }
}

private struct SummaryItem: View {
    var text: String
    var monospaced = false

    var body: some View {
        Text(text)
            .lineLimit(1)
            .truncationMode(.middle)
            .modifier(MonospacedIfNeeded(isEnabled: monospaced))
    }
}

private struct MonospacedIfNeeded: ViewModifier {
    var isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content.monospacedDigit()
        } else {
            content
        }
    }
}
