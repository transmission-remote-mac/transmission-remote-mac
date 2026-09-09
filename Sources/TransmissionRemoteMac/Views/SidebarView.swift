// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct SidebarView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var workspacePreferencesStore: UIWorkspacePreferencesStore
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var settingsNavigation: SettingsNavigationModel
    @FocusState private var searchFieldFocused: Bool

    init(store: AppStore) {
        self.store = store
        _workspacePreferencesStore = ObservedObject(
            wrappedValue: store.workspacePreferencesController
        )
    }

    var body: some View {
        List {
            Section("Connection") {
                if store.needsConnectionSetup {
                    Button {
                        presentServerSettings()
                    } label: {
                        Label("Set Up Server…", systemImage: "server.rack")
                            .fontWeight(.semibold)
                    }
                } else {
                    Menu {
                        ForEach(store.profiles) { profile in
                            Button {
                                Task { await store.switchProfile(to: profile.id) }
                            } label: {
                                if profile.id == store.selectedProfileID {
                                    Label(profile.name, systemImage: "checkmark")
                                } else {
                                    Text(profile.name)
                                }
                            }
                            .disabled(store.isRemoving)
                        }

                        Divider()

                        Button {
                            presentServerSettings()
                        } label: {
                            Label("Manage Servers…", systemImage: "gearshape")
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "server.rack")
                            Text(store.selectedProfile.name)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption)
                        }
                        .foregroundStyle(Color.primary)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .tint(Color.primary)
                    .accessibilityLabel("Server")
                    .accessibilityValue(store.selectedProfile.name)
                    .accessibilityHint("Choose a server or manage servers")
                }

                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionStatusColor)
                        .frame(width: 8, height: 8)

                    Text(store.needsConnectionSetup ? "Add a server to get started" : store.connectionState.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()

                    connectionButton
                }
            }

            Section("Filters") {
                TextField("Search torrents", text: $store.filterText)
                    .focused($searchFieldFocused)
                    .accessibilityLabel("Search torrents")
                    .accessibilityHint(
                        "Filters torrents by name, status, error, download folder, tracker, or label"
                    )
                if store.hasActiveFilters {
                    Button("Clear Filters") {
                        store.clearFilters()
                    }
                }
            }

            Section("Status") {
                ForEach(TorrentFilterStatus.allCases) { status in
                    Button {
                        store.toggleStatusFilter(status)
                    } label: {
                        filterRow(
                            title: status.title,
                            systemImage: status.systemImage,
                            count: store.filterCounts.statuses[status] ?? 0,
                            isSelected: status == .all
                                ? store.torrentFilters.statuses.isEmpty
                                : store.torrentFilters.statuses.contains(status)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(status.title)
                    .accessibilityValue(statusFilterAccessibilityValue(status))
                    .accessibilityHint(statusFilterAccessibilityHint(status))
                }
            }

            if sidebarGrouping.shouldRender(
                .trackers,
                hasContent: !store.filterCounts.trackers.isEmpty
            ) {
                Section("Trackers") {
                    ForEach(store.filterCounts.trackers) { tracker in
                        Button {
                            store.toggleTrackerFilter(tracker.value)
                        } label: {
                            filterRow(
                                title: tracker.value,
                                systemImage: "antenna.radiowaves.left.and.right",
                                count: tracker.count,
                                isSelected: store.torrentFilters.trackers.contains(tracker.value)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if sidebarGrouping.shouldRender(
                .labels,
                hasContent: !store.filterCounts.labels.isEmpty
            ) {
                Section("Labels") {
                    ForEach(store.filterCounts.labels) { label in
                        Button {
                            store.toggleLabelFilter(label.value)
                        } label: {
                            filterRow(
                                title: label.value,
                                systemImage: "tag",
                                count: label.count,
                                isSelected: store.torrentFilters.labels.contains(label.value)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if sidebarGrouping.shouldRender(
                .downloadFolders,
                hasContent: !store.filterCounts.paths.isEmpty
            ) {
                Section("Download Folders") {
                    ForEach(store.filterCounts.paths) { path in
                        Button {
                            store.togglePathFilter(path.value)
                        } label: {
                            filterRow(
                                title: path.value,
                                systemImage: "folder",
                                count: path.count,
                                isSelected: store.torrentFilters.paths.contains(path.value)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220)
        .focusedSceneValue(
            \.torrentSearchFocusAction,
            TorrentSearchFocusAction {
                searchFieldFocused = true
            }
        )
    }

    private func presentServerSettings() {
        settingsNavigation.present(.servers) {
            openSettings()
        }
    }

    private var sidebarGrouping: SidebarGroupingPreferences {
        workspacePreferencesStore.preferences.sidebarGrouping
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch store.connectionState {
        case .disconnected, .failed:
            Button("Connect") {
                Task { await store.connect() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.canConnect)

        case .connecting:
            Button("Cancel") {
                store.disconnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.canDisconnect)

        case .reconnecting:
            Button("Cancel Retry") {
                store.cancelRetry()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.canDisconnect)

        case .connected:
            Button("Disconnect") {
                store.disconnect()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!store.canDisconnect)
        }
    }

    private var connectionStatusColor: Color {
        switch store.connectionState {
        case .disconnected:
            .secondary
        case .connecting:
            .orange
        case .reconnecting:
            .orange
        case .connected:
            .green
        case .failed:
            .red
        }
    }

    private func filterRow(title: String, systemImage: String, count: Int, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : systemImage)
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Text(count.formatted())
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func statusFilterAccessibilityValue(_ status: TorrentFilterStatus) -> String {
        let count = store.filterCounts.statuses[status] ?? 0
        let countDescription = count == 1 ? "1 torrent" : "\(count) torrents"
        let selectionDescription = isSelectedStatusFilter(status) ? "selected" : "not selected"
        return "\(countDescription), \(selectionDescription)"
    }

    private func statusFilterAccessibilityHint(_ status: TorrentFilterStatus) -> String {
        status == .all
            ? "Clears status filters"
            : "Adds or removes this status from the current filter selection"
    }

    private func isSelectedStatusFilter(_ status: TorrentFilterStatus) -> Bool {
        status == .all
            ? store.torrentFilters.statuses.isEmpty
            : store.torrentFilters.statuses.contains(status)
    }
}
