// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct TorrentPropertiesView: View {
    @Binding private var draft: TorrentPropertiesDraft

    private let torrentName: String
    private let selectionCount: Int
    private let rpcVersion: Int
    private let isApplying: Bool
    private let onCancel: () -> Void
    private let onApply: () -> Void

    @State private var numericInput: TorrentPropertiesDraft.NumericInput

    init(
        draft: Binding<TorrentPropertiesDraft>,
        torrentName: String,
        selectionCount: Int,
        rpcVersion: Int,
        isApplying: Bool,
        onCancel: @escaping () -> Void,
        onApply: @escaping () -> Void
    ) {
        _draft = draft
        self.torrentName = torrentName
        self.selectionCount = selectionCount
        self.rpcVersion = rpcVersion
        self.isApplying = isApplying
        self.onCancel = onCancel
        self.onApply = onApply

        _numericInput = State(initialValue: TorrentPropertiesDraft.NumericInput(draft: draft.wrappedValue))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header

            TabView {
                generalTab
                    .tabItem {
                        Label("General", systemImage: "slider.horizontal.3")
                    }

                if supportsTrackerEditing {
                    trackersTab
                        .tabItem {
                            Label("Trackers", systemImage: "antenna.radiowaves.left.and.right")
                        }
                }
            }
            .frame(height: 310)
            .disabled(isApplying)

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 560)
        .interactiveDismissDisabled(isApplying)
        .onChange(of: numericInput) { previous, input in
            draft.updateNumericValues(from: input, previous: previous)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Torrent Properties")
                .font(.title2.bold())

            Text(selectionTitle)
                .font(.headline)
                .lineLimit(2)
                .truncationMode(.middle)

            if selectionCount > 1 {
                Text("Changes will be applied to all selected torrents.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if rpcVersion >= 10, !supportsTrackerEditing {
                    Text("Tracker editing requires one selected torrent on RPC 10–16.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            GroupBox("Speed Limits") {
                VStack(spacing: 10) {
                    speedLimitRow(
                        title: "Maximum download speed",
                        isEnabled: $draft.downloadSpeedLimit.isEnabled,
                        text: $numericInput.downloadSpeedText
                    )

                    speedLimitRow(
                        title: "Maximum upload speed",
                        isEnabled: $draft.uploadSpeedLimit.isEnabled,
                        text: $numericInput.uploadSpeedText
                    )
                }
                .padding(.vertical, 4)
            }

            GroupBox("Connections") {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("Peer limit")
                    Spacer()
                    numericField("Peers", text: $numericInput.peerLimitText)
                }
                .padding(.vertical, 4)
            }

            if rpcVersion >= 5 {
                GroupBox("Seeding") {
                    VStack(spacing: 10) {
                        limitModeRow(
                            title: "Seed ratio",
                            selection: seedRatioMode,
                            text: $numericInput.seedRatioText,
                            suffix: "ratio",
                            isLimit: draft.seedRatio.mode == .single
                        )

                        if rpcVersion >= 10 {
                            limitModeRow(
                                title: "Inactive seeding",
                                selection: seedIdleMode,
                                text: $numericInput.seedIdleText,
                                suffix: "minutes",
                                isLimit: draft.seedIdle.mode == .single
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(12)
    }

    private var trackersTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(trackerHelp)
                .font(.caption)
                .foregroundStyle(.secondary)

            TextEditor(text: $draft.trackerText)
                .font(.body.monospaced())
                .border(Color.secondary.opacity(0.35))
        }
        .padding(12)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Group {
                if isApplying {
                    ProgressView()
                        .controlSize(.small)
                    Text(selectionCount > 1 ? "Applying to all selected torrents…" : "Applying changes…")
                } else if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)

            Spacer()

            Button("Cancel", role: .cancel, action: onCancel)
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)

            Button(isApplying ? "Applying…" : "Apply", action: onApply)
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || validationMessage != nil)
        }
    }

    private func speedLimitRow(
        title: String,
        isEnabled: Binding<Bool>,
        text: Binding<String>
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(title, isOn: isEnabled)
            Spacer()
            numericField("Speed", text: text)
                .disabled(!isEnabled.wrappedValue)
            Text("KB/s")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
    }

    private func limitModeRow(
        title: String,
        selection: Binding<Int>,
        text: Binding<String>,
        suffix: String,
        isLimit: Bool
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .frame(width: 105, alignment: .leading)

            Picker("Mode", selection: selection) {
                Text("Follow Global").tag(TorrentPropertiesLimitMode.global.rawValue)
                Text("Limit").tag(TorrentPropertiesLimitMode.single.rawValue)
                Text("Unlimited").tag(TorrentPropertiesLimitMode.unlimited.rawValue)
            }
            .labelsHidden()
            .frame(width: 130)

            Spacer()

            numericField("Limit", text: text)
                .disabled(!isLimit)

            Text(suffix)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
    }

    private func numericField(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 88)
    }

    private var seedRatioMode: Binding<Int> {
        Binding(
            get: { draft.seedRatio.mode.rawValue },
            set: { draft.seedRatio.mode = TorrentPropertiesLimitMode(rawValue: $0) ?? .global }
        )
    }

    private var seedIdleMode: Binding<Int> {
        Binding(
            get: { draft.seedIdle.mode.rawValue },
            set: { draft.seedIdle.mode = TorrentPropertiesLimitMode(rawValue: $0) ?? .global }
        )
    }

    private var selectionTitle: String {
        selectionCount == 1 ? torrentName : "\(selectionCount) selected torrents"
    }

    private var trackerHelp: String {
        if rpcVersion >= 17 {
            return "Enter one tracker URL per line. Separate tiers with blank lines."
        }
        return "Enter one tracker URL per line."
    }

    private var supportsTrackerEditing: Bool {
        rpcVersion >= 10 && (selectionCount == 1 || rpcVersion >= 17)
    }

    private var validationMessage: String? {
        draft.validationMessage(for: numericInput, rpcVersion: rpcVersion)
    }
}
