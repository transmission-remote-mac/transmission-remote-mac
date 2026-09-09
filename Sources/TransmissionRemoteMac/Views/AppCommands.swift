// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI

struct TorrentTableCommandFocusKey: FocusedValueKey {
    typealias Value = Bool
}

extension FocusedValues {
    var torrentTableCommandsActive: Bool? {
        get { self[TorrentTableCommandFocusKey.self] }
        set { self[TorrentTableCommandFocusKey.self] = newValue }
    }
}

struct TorrentSearchFocusAction {
    let perform: @MainActor () -> Void
}

struct TorrentSearchFocusActionKey: FocusedValueKey {
    typealias Value = TorrentSearchFocusAction
}

extension FocusedValues {
    var torrentSearchFocusAction: TorrentSearchFocusAction? {
        get { self[TorrentSearchFocusActionKey.self] }
        set { self[TorrentSearchFocusActionKey.self] = newValue }
    }
}

struct AppCommands: Commands {
    @ObservedObject var store: AppStore
    @ObservedObject var settingsNavigation: SettingsNavigationModel
    @ObservedObject var interactionPreferencesStore: ApplicationInteractionPreferencesStore
    @ObservedObject private var workspacePreferencesStore: UIWorkspacePreferencesStore
    @Environment(\.openSettings) private var openSettings
    @FocusedValue(\.torrentTableCommandsActive) private var torrentTableCommandsActive
    @FocusedValue(\.torrentSearchFocusAction) private var torrentSearchFocusAction

    init(
        store: AppStore,
        settingsNavigation: SettingsNavigationModel,
        interactionPreferencesStore: ApplicationInteractionPreferencesStore
    ) {
        self.store = store
        self.settingsNavigation = settingsNavigation
        self.interactionPreferencesStore = interactionPreferencesStore
        _workspacePreferencesStore = ObservedObject(
            wrappedValue: store.workspacePreferencesController
        )
    }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(Bundle.main.applicationDisplayName)") {
                NSApp.orderFrontStandardAboutPanel(options: Bundle.main.aboutPanelOptions)
            }
        }

        CommandGroup(after: .newItem) {
            Button("Add Torrent…") {
                store.requestAddTorrent()
            }
            .keyboardShortcut(keyboardShortcut(for: .addTorrent))
            .disabled(!store.canAddTorrent)
        }

        CommandGroup(after: .pasteboard) {
            Button("Find Torrents") {
                focusTorrentSearch()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(torrentSearchFocusAction == nil)
            .accessibilityLabel("Find torrents")
            .accessibilityHint("Shows the Filter pane and moves keyboard focus to torrent search")
        }

        CommandGroup(after: .sidebar) {
            Button(
                workspacePreferencesStore.preferences.filterPane.isVisible
                    ? "Hide Filter Pane"
                    : "Show Filter Pane"
            ) {
                workspacePreferencesStore.toggleFilterPaneVisibility()
            }

            Button(store.isTorrentDetailVisible ? "Hide Info Pane" : "Show Info Pane") {
                store.isTorrentDetailVisible.toggle()
            }
            .keyboardShortcut(keyboardShortcut(for: .toggleInfoPane))

            Button(
                workspacePreferencesStore.preferences.statusSummary.isVisible
                    ? "Hide Status Summary"
                    : "Show Status Summary"
            ) {
                workspacePreferencesStore.toggleStatusSummaryVisibility()
            }

            Divider()

            Menu("Info Pane Tab") {
                ForEach(TorrentDetailPane.commandNavigationOrder, id: \.self) { pane in
                    detailPaneCommand(pane, registersShortcut: false)
                }
            }

            Menu("Status Filter") {
                ForEach(TorrentFilterStatus.allCases) { status in
                    statusFilterCommand(status, registersShortcut: false)
                }
            }
        }

        // AppCommands belongs to the main Window scene, which provides stable ownership while
        // menu tracking temporarily clears FocusedValues. Keep shortcuts on these direct items.
        CommandMenu("Navigate") {
            ForEach(TorrentDetailPane.commandNavigationOrder, id: \.self) { pane in
                detailPaneCommand(pane, registersShortcut: true)
            }

            Divider()

            ForEach(TorrentFilterStatus.allCases) { status in
                statusFilterCommand(status, registersShortcut: true)
            }
        }

        CommandMenu("Connection") {
            connectionCommand

            Divider()

            if !store.needsConnectionSetup {
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
            }

            Divider()

            Button("Refresh") {
                Task { await store.refresh() }
            }
            .keyboardShortcut(keyboardShortcut(for: .refresh))
            .disabled(!store.canRefresh)

            Divider()

            Button("Manage Servers…") {
                settingsNavigation.present(.servers) {
                    openSettings()
                }
            }
        }

        CommandMenu("Bandwidth") {
            GlobalBandwidthMenuContent(store: store)
        }

        CommandMenu("Torrent") {
            Button("Start") {
                Task { await store.startSelected() }
            }
            .keyboardShortcut(keyboardShortcut(for: .start))
            .disabled(!store.canStartSelectedTorrents)

            Button("Start Now") {
                Task { await store.startSelectedNow() }
            }
            .keyboardShortcut(keyboardShortcut(for: .startNow))
            .disabled(!store.canStartNowSelectedTorrents)

            Button("Stop") {
                Task { await store.stopSelected() }
            }
            .keyboardShortcut(keyboardShortcut(for: .stop))
            .disabled(!store.canStopSelectedTorrents)

            Divider()

            Button("Start All") {
                Task { await store.startAll() }
            }
            .disabled(!store.canStartAllTorrents)

            Button("Stop All") {
                Task { await store.stopAll() }
            }
            .disabled(!store.canStopAllTorrents)

            Divider()

            Button("Verify Local Data") {
                store.requestVerifySelected()
            }
            .keyboardShortcut(keyboardShortcut(for: .verify))
            .disabled(!store.canVerifySelectedTorrents)

            Button("Reannounce") {
                Task { await store.reannounceSelected() }
            }
            .keyboardShortcut(keyboardShortcut(for: .reannounce))
            .disabled(!store.canReannounceSelectedTorrents)

            Button(store.selectedTorrentIDs.count == 1 ? "Copy Magnet Link" : "Copy Magnet Links") {
                Task { await store.copySelectedMagnetLinks() }
            }
            .disabled(!store.canCopySelectedMagnetLinks)

            Menu("Bandwidth Priority") {
                Button("High") {
                    Task { await store.setSelectedBandwidthPriority(.high) }
                }

                Button("Normal") {
                    Task { await store.setSelectedBandwidthPriority(.normal) }
                }

                Button("Low") {
                    Task { await store.setSelectedBandwidthPriority(.low) }
                }
            }
            .disabled(!store.canSetSelectedBandwidthPriority)

            Divider()

            Button("Set Location…") {
                store.requestSetSelectedLocation()
            }
            .disabled(!store.canSetSelectedTorrentLocation)

            Button("Move Data…") {
                store.requestMoveSelectedData()
            }
            .disabled(!store.canSetSelectedTorrentLocation)

            Button("Rename…") {
                store.requestRenameSelectedTorrent()
            }
            .disabled(!store.canRenameSelectedTorrent)

            Divider()

            Button("Properties…") {
                Task { await store.requestEditSelectedTorrentProperties() }
            }
            .keyboardShortcut(keyboardShortcut(for: .properties))
            .disabled(!store.canEditSelectedTorrentProperties)

            Divider()

            removalCommand(deleteLocalData: false)
            removalCommand(deleteLocalData: true)
        }

        CommandMenu("Queue") {
            Button("Move to Top") {
                Task { await store.queueMoveSelectedTop() }
            }
            .keyboardShortcut(keyboardShortcut(for: .queueTop))
            .disabled(!store.canQueueSelectedTorrents)

            Button("Move Up") {
                Task { await store.queueMoveSelectedUp() }
            }
            .keyboardShortcut(keyboardShortcut(for: .queueUp))
            .disabled(!store.canQueueSelectedTorrents)

            Button("Move Down") {
                Task { await store.queueMoveSelectedDown() }
            }
            .keyboardShortcut(keyboardShortcut(for: .queueDown))
            .disabled(!store.canQueueSelectedTorrents)

            Button("Move to Bottom") {
                Task { await store.queueMoveSelectedBottom() }
            }
            .keyboardShortcut(keyboardShortcut(for: .queueBottom))
            .disabled(!store.canQueueSelectedTorrents)
        }

        CommandMenu("Labels") {
            Button("Set Labels…") {
                store.requestSetSelectedLabels()
            }
            .keyboardShortcut(keyboardShortcut(for: .setLabels))
            .disabled(!store.canSetSelectedTorrentLabels)

            Button("Clear Labels") {
                Task { await store.clearSelectedLabels() }
            }
            .disabled(!store.canSetSelectedTorrentLabels)
        }
    }

    @ViewBuilder
    private var connectionCommand: some View {
        switch store.connectionState {
        case .disconnected, .failed:
            Button("Connect") {
                Task { await store.connect() }
            }
            .keyboardShortcut(keyboardShortcut(for: .toggleConnection))
            .disabled(!store.canConnect)

        case .connecting:
            Button("Cancel Connection") {
                store.disconnect()
            }
            .keyboardShortcut(keyboardShortcut(for: .cancelConnection))
            .disabled(!store.canDisconnect)

        case .reconnecting:
            Button("Cancel Retry") {
                store.cancelRetry()
            }
            .keyboardShortcut(keyboardShortcut(for: .cancelConnection))
            .disabled(!store.canDisconnect)

        case .connected:
            Button("Disconnect") {
                store.disconnect()
            }
            .keyboardShortcut(keyboardShortcut(for: .cancelConnection))
            .disabled(!store.canDisconnect)
        }
    }

    @ViewBuilder
    private func removalCommand(deleteLocalData: Bool) -> some View {
        let title = deleteLocalData ? "Remove and Delete Data…" : "Remove…"
        if torrentTableCommandsActive == true {
            Button(title, role: .destructive) {
                store.requestRemoveSelected(deleteLocalData: deleteLocalData)
            }
            .keyboardShortcut(
                keyboardShortcut(for: deleteLocalData ? .removeAndDeleteData : .remove)
            )
            .disabled(deleteLocalData ? !store.canDeleteSelectedTorrentData : !store.canRemoveSelectedTorrents)
        } else {
            Button(title, role: .destructive) {
                store.requestRemoveSelected(deleteLocalData: deleteLocalData)
            }
            .disabled(deleteLocalData ? !store.canDeleteSelectedTorrentData : !store.canRemoveSelectedTorrents)
        }
    }

    private func keyboardShortcut(for commandID: NativeCommandID) -> KeyboardShortcut? {
        interactionPreferencesStore.shortcut(for: commandID)?.swiftUIKeyboardShortcut
    }

    private func focusTorrentSearch() {
        let focusAction = torrentSearchFocusAction
        if !workspacePreferencesStore.preferences.filterPane.isVisible {
            workspacePreferencesStore.updateFilterPaneVisibility(true)
        }
        Task { @MainActor in
            await Task.yield()
            focusAction?.perform()
        }
    }

    @ViewBuilder
    private func detailPaneCommand(
        _ pane: TorrentDetailPane,
        registersShortcut: Bool
    ) -> some View {
        let title = registersShortcut ? "Info Pane: \(pane.commandTitle)" : pane.commandTitle
        Button {
            store.performNativeNavigationCommand(pane.navigationCommandID)
        } label: {
            if store.selectedTorrentDetailPane == pane, store.isTorrentDetailVisible {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .keyboardShortcut(registersShortcut ? keyboardShortcut(for: pane.navigationCommandID) : nil)
        .accessibilityLabel("Show \(pane.commandTitle) in Info Pane")
        .accessibilityHint("Shows the Info Pane if it is hidden")
    }

    @ViewBuilder
    private func statusFilterCommand(
        _ status: TorrentFilterStatus,
        registersShortcut: Bool
    ) -> some View {
        let title = registersShortcut ? "Status Filter: \(status.title)" : status.title
        Button {
            store.performNativeNavigationCommand(status.navigationCommandID)
        } label: {
            if isSelectedStatusFilter(status) {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
        .keyboardShortcut(registersShortcut ? keyboardShortcut(for: status.navigationCommandID) : nil)
        .accessibilityLabel("Filter torrents by \(status.title)")
        .accessibilityHint("Replaces the current status selection and shows the Filter pane")
    }

    private func isSelectedStatusFilter(_ status: TorrentFilterStatus) -> Bool {
        status == .all
            ? store.torrentFilters.statuses.isEmpty
            : store.torrentFilters.statuses == [status]
    }
}

private extension Bundle {
    var applicationDisplayName: String {
        (object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    var aboutPanelOptions: [NSApplication.AboutPanelOptionKey: Any] {
        let sections = ["CREDITS", "PRIVACY"].compactMap { resourceName -> String? in
            guard
                let resourceURL = url(forResource: resourceName, withExtension: "md"),
                let text = try? String(contentsOf: resourceURL, encoding: .utf8)
            else { return nil }
            return text
        }

        guard !sections.isEmpty else { return [:] }
        return [.credits: NSAttributedString(string: sections.joined(separator: "\n\n"))]
    }
}

struct GlobalBandwidthMenuContent: View {
    @ObservedObject var store: AppStore

    var body: some View {
        Menu("Download Limit") {
            ForEach(store.speedPresets(for: .download), id: \.self) { preset in
                speedPresetButton(preset, direction: .download)
            }
        }
        .disabled(!store.canSetGlobalSpeedLimit)

        Menu("Upload Limit") {
            ForEach(store.speedPresets(for: .upload), id: \.self) { preset in
                speedPresetButton(preset, direction: .upload)
            }
        }
        .disabled(!store.canSetGlobalSpeedLimit)

        Divider()

        Toggle(
            "Alternate Speed",
            isOn: Binding(
                get: { store.isAlternateSpeedEnabled },
                set: { isEnabled in
                    Task { await store.setAlternateSpeedEnabled(isEnabled) }
                }
            )
        )
        .disabled(!store.canToggleAlternateSpeed)
    }

    private func speedPresetButton(
        _ preset: SessionSpeedPreset,
        direction: SessionSpeedLimitDirection
    ) -> some View {
        Toggle(
            preset.title,
            isOn: Binding(
                get: { store.isCurrentSpeedPreset(preset, direction: direction) },
                set: { _ in
                    Task { await store.setGlobalSpeedLimit(preset, direction: direction) }
                }
            )
        )
    }
}
