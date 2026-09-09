// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct TorrentOperationFeedbackView: View {
    private static let maximumVisibleOperations = 4

    let operations: [TorrentOperationFeedback]
    let onDismiss: (UUID) -> Void

    var body: some View {
        if !visibleOperations.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleOperations) { operation in
                    operationRow(operation)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Torrent operation feedback")
        }
    }

    private var visibleOperations: [TorrentOperationFeedback] {
        Array(operations.suffix(Self.maximumVisibleOperations).reversed())
    }

    private func operationRow(_ operation: TorrentOperationFeedback) -> some View {
        HStack(alignment: .top, spacing: 8) {
            statusIndicator(for: operation.phase)

            VStack(alignment: .leading, spacing: 2) {
                Text(operationTitle(for: operation))
                    .font(.callout.weight(.medium))
                Text(statusTitle(for: operation.phase))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if case .failed(let message) = operation.phase {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 8)

            if operation.phase.isTerminal {
                Button {
                    onDismiss(operation.id)
                } label: {
                    Label("Dismiss", systemImage: "xmark")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Dismiss operation feedback")
                .accessibilityLabel("Dismiss \(kindTitle(for: operation.ownership.kind)) feedback")
            }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func statusIndicator(for phase: TorrentOperationFeedbackPhase) -> some View {
        switch phase {
        case .submitted, .running:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        }
    }

    private func operationTitle(for operation: TorrentOperationFeedback) -> String {
        let targetCount = operation.ownership.torrentHashes.count
        let targetDescription = targetCount == 1 ? "1 torrent" : "\(targetCount) torrents"
        return "\(kindTitle(for: operation.ownership.kind)) (\(targetDescription))"
    }

    private func kindTitle(for kind: TorrentOperationKind) -> String {
        switch kind {
        case .verify:
            "Verify Local Data"
        case .setLocation:
            "Set Location"
        case .moveData:
            "Move Data"
        case .rename:
            "Rename"
        }
    }

    private func statusTitle(for phase: TorrentOperationFeedbackPhase) -> String {
        switch phase {
        case .submitted:
            "Submitted"
        case .running:
            "Running"
        case .completed:
            "Completed"
        case .failed:
            "Failed"
        }
    }
}
