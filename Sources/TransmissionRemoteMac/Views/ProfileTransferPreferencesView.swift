// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct ProfileTransferPreferencesView: View {
    @Binding var preferences: ProfileTransferPreferences
    @State private var downloadPreset = ""
    @State private var uploadPreset = ""

    var body: some View {
        speedPresetEditor(
            title: "Download speed presets",
            direction: .download,
            input: $downloadPreset
        )
        speedPresetEditor(
            title: "Upload speed presets",
            direction: .upload,
            input: $uploadPreset
        )

        Stepper(
            value: Binding(
                get: { preferences.destinationHistoryLimit },
                set: { preferences.setDestinationHistoryLimit($0) }
            ),
            in: ProfileTransferPreferences.allowedDestinationHistoryLimit
        ) {
            LabeledContent("Saved destinations") {
                Text(preferences.destinationHistoryLimit.formatted())
                    .monospacedDigit()
            }
        }

        HStack {
            Button("Restore Preset Defaults") {
                preferences.setSpeedPresets(
                    ProfileTransferPreferences.defaultDownloadSpeedPresetsKBps,
                    for: .download
                )
                preferences.setSpeedPresets(
                    ProfileTransferPreferences.defaultUploadSpeedPresetsKBps,
                    for: .upload
                )
            }

            Button("Clear Destination History", role: .destructive) {
                preferences.clearAllDestinations()
            }
            .disabled(
                preferences.addDestinationHistory.isEmpty
                    && preferences.moveDestinationHistory.isEmpty
            )
        }

        Divider()

        AddTorrentDestinationRulesEditor(preferences: $preferences)

        Text("Speed menus and recent add or move destinations are stored per server. A limit of zero disables destination history.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func speedPresetEditor(
        title: String,
        direction: SessionSpeedLimitDirection,
        input: Binding<String>
    ) -> some View {
        let values = preferences.speedPresetsKBps(for: direction)
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 6) {
                Text(values.isEmpty ? "Unlimited only" : values.map { "\($0) KB/s" }.joined(separator: ", "))
                    .foregroundStyle(values.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)

                HStack(spacing: 6) {
                    TextField("KB/s", text: input)
                        .frame(width: 90)
                        .monospacedDigit()

                    Button("Add") {
                        guard let value = parsedPreset(input.wrappedValue) else { return }
                        preferences.setSpeedPresets(values + [value], for: direction)
                        input.wrappedValue = ""
                    }
                    .disabled(!canAddPreset(input.wrappedValue, to: values))

                    Menu("Remove") {
                        ForEach(values, id: \.self) { value in
                            Button("\(value) KB/s") {
                                preferences.setSpeedPresets(
                                    values.filter { $0 != value },
                                    for: direction
                                )
                            }
                        }
                    }
                    .disabled(values.isEmpty)
                }
            }
        }
    }

    private func canAddPreset(_ text: String, to values: [Int]) -> Bool {
        guard let value = parsedPreset(text) else { return false }
        return !values.contains(value)
            && values.count < ProfileTransferPreferences.maximumSpeedPresetCount
    }

    private func parsedPreset(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed),
              ProfileTransferPreferences.allowedSpeedPresetKBps.contains(value) else {
            return nil
        }
        return value
    }
}
