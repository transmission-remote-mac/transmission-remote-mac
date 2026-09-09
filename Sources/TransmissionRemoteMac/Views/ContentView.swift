// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var workspacePreferencesStore: UIWorkspacePreferencesStore
    @ObservedObject private var interactionPreferencesStore: ApplicationInteractionPreferencesStore
    @State private var addTorrentPresentationOwnerID = UUID()

    init(store: AppStore) {
        self.store = store
        _workspacePreferencesStore = ObservedObject(
            wrappedValue: store.workspacePreferencesController
        )
        _interactionPreferencesStore = ObservedObject(
            wrappedValue: store.interactionPreferencesController
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: filterPaneColumnVisibility) {
            SidebarView(store: store)
                .background {
                    SidebarWidthWorkspaceBridge(
                        savedWidth: workspacePreferencesStore.preferences.sidebarWidth,
                        onWidthChange: workspacePreferencesStore.updateSidebarWidth
                    )
                    .frame(width: 0, height: 0)
                }
        } detail: {
            VStack(spacing: 0) {
                PersistedDetailSplitView(
                    isDetailVisible: store.isTorrentDetailVisible,
                    detailHeight: Binding(
                        get: { workspacePreferencesStore.preferences.infoPane.height },
                        set: workspacePreferencesStore.updateInfoPaneHeight
                    ),
                    minimumPrimaryHeight: 240,
                    minimumDetailHeight: 280
                ) {
                    TorrentTableView(
                        store: store,
                        interactionPreferencesStore: store.interactionPreferencesController,
                        tableColumnCustomizationController:
                            store.tableColumnCustomizationController.main,
                        onProjectionChange: store.setTorrentTableProjection
                    )
                } detail: {
                    torrentDetailContent
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                if !store.torrentOperationFeedback.isEmpty {
                    Divider()
                    TorrentOperationFeedbackView(
                        operations: store.torrentOperationFeedback,
                        onDismiss: { operationID in
                            store.dismissTorrentOperationFeedback(operationID: operationID)
                        }
                    )
                }
                if workspacePreferencesStore.preferences.statusSummary.isVisible {
                    Divider()
                    TorrentStatusSummaryView(
                        summary: store.torrentListSummary,
                        sessionInfo: store.sessionInfo
                    )
                }
            }
        }
        .background {
            MainWindowWorkspaceBridge(
                savedPlacement: workspacePreferencesStore.preferences.mainWindow,
                savedPlacementSourceID: workspacePreferencesStore.mainWindowPlacementSourceID,
                onPlacementChange: { placement, sourceID in
                    workspacePreferencesStore.updateMainWindowPlacement(
                        placement,
                        sourceID: sourceID
                    )
                }
            )
            .frame(width: 0, height: 0)

            NativeNavigationKeyEventBridge(
                shortcutBindings: nativeNavigationShortcutBindings,
                onCommand: store.performNativeNavigationCommand
            )
            .frame(width: 0, height: 0)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            TorrentFileDropIntakeService.receive(providers: providers) { fileURLs in
                guard !fileURLs.isEmpty else { return }
                store.requestAddTorrents(fileURLs.map { .localFile($0) })
            }
        }
        .navigationTitle("Transmission Remote Mac")
        .toolbar {
            ToolbarItem {
                connectionButton
            }

            ToolbarItemGroup {
                Button("Refresh") {
                    Task { await store.refresh() }
                }
                .disabled(!store.canRefresh)

                Button("Add") {
                    store.requestAddTorrent()
                }
                .disabled(!store.canAddTorrent)
            }

            ToolbarItemGroup {
                Button {
                    Task { await store.queueMoveSelectedUp() }
                } label: {
                    Label("Queue Up", systemImage: "arrow.up.circle")
                }
                .labelStyle(.iconOnly)
                .help("Move selected torrents up in the queue")
                .accessibilityLabel("Queue Up")
                .accessibilityHint("Moves the selected torrents one position up in the queue.")
                .disabled(!store.canQueueSelectedTorrents)

                Button {
                    Task { await store.queueMoveSelectedDown() }
                } label: {
                    Label("Queue Down", systemImage: "arrow.down.circle")
                }
                .labelStyle(.iconOnly)
                .help("Move selected torrents down in the queue")
                .accessibilityLabel("Queue Down")
                .accessibilityHint("Moves the selected torrents one position down in the queue.")
                .disabled(!store.canQueueSelectedTorrents)
            }

            ToolbarItemGroup {
                TorrentTableColumnMenu(
                    tableColumnCustomizationController:
                        store.tableColumnCustomizationController.main,
                    onProjectionChange: store.setTorrentTableProjection
                )

                Menu {
                    GlobalBandwidthMenuContent(store: store)
                } label: {
                    Label("Bandwidth", systemImage: "speedometer")
                }
                .disabled(!store.canSetGlobalSpeedLimit)

                Menu("Actions") {
                    Button("Start All") {
                        Task { await store.startAll() }
                    }
                    .disabled(!store.canStartAllTorrents)

                    Button("Stop All") {
                        Task { await store.stopAll() }
                    }
                    .disabled(!store.canStopAllTorrents)

                    Divider()

                    Button("Start Now") {
                        Task { await store.startSelectedNow() }
                    }
                    .disabled(!store.canStartNowSelectedTorrents)

                    Button("Verify") {
                        store.requestVerifySelected()
                    }
                    .disabled(!store.canVerifySelectedTorrents)

                    Button("Reannounce") {
                        Task { await store.reannounceSelected() }
                    }
                    .disabled(!store.canReannounceSelectedTorrents)

                    Button(store.selectedTorrentIDs.count == 1 ? "Copy Magnet Link" : "Copy Magnet Links") {
                        Task { await store.copySelectedMagnetLinks() }
                    }
                    .disabled(!store.canCopySelectedMagnetLinks)

                    Menu("Queue") {
                        Button("Move to Top") {
                            Task { await store.queueMoveSelectedTop() }
                        }
                        Button("Move Up") {
                            Task { await store.queueMoveSelectedUp() }
                        }
                        Button("Move Down") {
                            Task { await store.queueMoveSelectedDown() }
                        }
                        Button("Move to Bottom") {
                            Task { await store.queueMoveSelectedBottom() }
                        }
                    }
                    .disabled(!store.canQueueSelectedTorrents)

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

                    Button("Set Labels…") {
                        store.requestSetSelectedLabels()
                    }
                    .disabled(!store.canSetSelectedTorrentLabels)

                    Button("Properties…") {
                        Task { await store.requestEditSelectedTorrentProperties() }
                    }
                    .disabled(!store.canEditSelectedTorrentProperties)

                }

                Button("Start") {
                    Task { await store.startSelected() }
                }
                .disabled(!store.canStartSelectedTorrents)

                Button("Stop") {
                    Task { await store.stopSelected() }
                }
                .disabled(!store.canStopSelectedTorrents)

                Button("Remove…", role: .destructive) {
                    store.requestRemoveSelected()
                }
                .disabled(!store.canRemoveSelectedTorrents)
            }
        }
        .onAppear {
            store.registerAddTorrentPresentationOwner(addTorrentPresentationOwnerID)
        }
        .onDisappear {
            store.unregisterAddTorrentPresentationOwner(addTorrentPresentationOwnerID)
        }
        .sheet(item: addTorrentPresentationBinding) { request in
            AddTorrentView(
                store: store,
                request: request,
                presentationOwnerID: addTorrentPresentationOwnerID
            )
            .onDisappear {
                store.addTorrentSheetDidDismiss(
                    requestID: request.id,
                    ownerID: addTorrentPresentationOwnerID
                )
            }
        }
        .sheet(item: $store.torrentPropertiesEditor) { editor in
            TorrentPropertiesView(
                draft: torrentPropertiesDraftBinding(for: editor),
                torrentName: editor.torrentName,
                selectionCount: editor.selectionCount,
                rpcVersion: editor.rpcVersion,
                isApplying: store.torrentPropertiesEditor?.isApplying ?? editor.isApplying,
                onCancel: {
                    store.cancelTorrentPropertiesEditing()
                },
                onApply: {
                    Task { await store.applyTorrentProperties() }
                }
            )
        }
        .sheet(item: $store.passwordPrompt) { prompt in
            PasswordPromptView(
                prompt: prompt,
                onCancel: {
                    store.cancelPasswordPrompt()
                },
                onConnect: { password in
                    Task { await store.connectWithPromptPassword(password, for: prompt) }
                }
            )
        }
        .alert(
            removalTitle(for: store.removalConfirmation),
            isPresented: removalConfirmationBinding,
            presenting: store.removalConfirmation
        ) { confirmation in
            Button("Cancel", role: .cancel) {
                store.cancelRemoval(confirmation)
            }
            Button(removalButtonTitle(for: confirmation), role: .destructive) {
                Task { await store.confirmRemoval(confirmation) }
            }
            .disabled(store.isRemoving)
        } message: { confirmation in
            Text(removalMessage(for: confirmation))
        }
        .alert(
            store.verifyConfirmation?.title ?? "Verify Local Data?",
            isPresented: verifyConfirmationBinding,
            presenting: store.verifyConfirmation
        ) { confirmation in
            Button(confirmation.cancelTitle, role: .cancel) {
                store.cancelVerifyConfirmation()
            }
            .keyboardShortcut(.defaultAction)
            Button(confirmation.confirmTitle) {
                Task { await store.confirmVerify() }
            }
        } message: { confirmation in
            Text(confirmation.message)
        }
        .alert("Set Labels", isPresented: $store.showingLabelEditor) {
            TextField("Comma-separated labels", text: $store.labelDraft)
            Button("Cancel", role: .cancel) {}
            Button("Apply") {
                Task { await store.applySelectedLabelDraft() }
            }
        } message: {
            Text("This overwrites existing labels. Separate multiple labels with commas, or leave empty to clear them.")
        }
        .alert("Transmission Remote Mac", isPresented: errorBinding) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var nativeNavigationShortcutBindings: [NativeCommandShortcutBinding] {
        NativeCommandCatalog.current.commands.compactMap { command in
            guard NativeCommandCatalog.keyboardNavigationCommandIDs.contains(command.id) else {
                return nil
            }
            return NativeCommandShortcutBinding(
                commandID: command.id,
                shortcut: interactionPreferencesStore.shortcut(for: command.id)
            )
        }
    }

    private var filterPaneColumnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                workspacePreferencesStore.preferences.filterPane.isVisible
                    ? .all
                    : .detailOnly
            },
            set: { visibility in
                workspacePreferencesStore.updateFilterPaneVisibility(
                    visibility != .detailOnly
                )
            }
        )
    }

    @ViewBuilder
    private var torrentDetailContent: some View {
        let filesOwner = store.selectedTorrentFileMutationOwner
        let pathRenameOwner = store.selectedTorrentPathRenameOwner
        let trackersOwner = store.selectedTorrentTrackerMutationOwner
        TorrentDetailView(
            interactionPreferencesStore: store.interactionPreferencesController,
            peerResolutionPreferencesStore: store.peerResolutionPreferencesController,
            tableColumnCustomizationWorkspaceController: store.tableColumnCustomizationController,
            torrent: store.selectedTorrent,
            sessionStats: store.sessionStats,
            selectedPane: $store.selectedTorrentDetailPane,
            requiresPieceRevalidation: store.selectedTorrentRequiresPieceRevalidation,
            canMutateFiles: filesOwner != nil,
            setFileWanted: { wanted, fileIndexes in
                guard let filesOwner else { return }
                await store.setTorrentFilesWanted(wanted, fileIndexes: fileIndexes, owner: filesOwner)
            },
            setFilePriority: { priority, fileIndexes in
                guard let filesOwner else { return }
                await store.setTorrentFilesPriority(priority, fileIndexes: fileIndexes, owner: filesOwner)
            },
            canRenameFilePath: pathRenameOwner != nil,
            renameFilePath: { node, newBasename in
                guard let pathRenameOwner else { return }
                await store.renameTorrentPath(
                    node: node,
                    newBasename: newBasename,
                    owner: pathRenameOwner
                )
            },
            fileLocalActionExecutor: TorrentFileLocalActionExecutor(
                profile: store.selectedProfile
            ),
            canMutateTrackers: trackersOwner != nil,
            addTracker: { announceURL in
                guard let trackersOwner else { return }
                await store.addTorrentTracker(announceURL, owner: trackersOwner)
            },
            replaceTracker: { trackerID, announceURL in
                guard let trackersOwner else { return }
                await store.replaceTorrentTracker(
                    id: trackerID,
                    announceURL: announceURL,
                    owner: trackersOwner
                )
            },
            removeTrackers: { trackerIDs in
                guard let trackersOwner else { return }
                await store.removeTorrentTrackers(ids: trackerIDs, owner: trackersOwner)
            }
        )
    }

    @ViewBuilder
    private var connectionButton: some View {
        switch store.connectionState {
        case .disconnected, .failed:
            Button {
                Task { await store.connect() }
            } label: {
                Label("Connect", systemImage: "bolt.horizontal.circle")
            }
            .disabled(!store.canConnect)

        case .connecting:
            Button {
                store.disconnect()
            } label: {
                Label("Cancel", systemImage: "xmark.circle")
            }
            .disabled(!store.canDisconnect)

        case .reconnecting:
            Button {
                store.cancelRetry()
            } label: {
                Label("Cancel Retry", systemImage: "xmark.circle")
            }
            .disabled(!store.canDisconnect)

        case .connected:
            Button {
                store.disconnect()
            } label: {
                Label("Disconnect", systemImage: "bolt.slash.circle")
            }
            .disabled(!store.canDisconnect)
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )
    }

    private var addTorrentPresentationBinding: Binding<AppStore.PendingAddTorrent?> {
        Binding(
            get: {
                store.presentedAddTorrent(for: addTorrentPresentationOwnerID)
            },
            set: { request in
                guard
                    request == nil,
                    let presentedRequest = store.presentedAddTorrent(
                        for: addTorrentPresentationOwnerID
                    )
                else {
                    return
                }
                store.addTorrentPresentationWillDismiss(
                    requestID: presentedRequest.id,
                    ownerID: addTorrentPresentationOwnerID
                )
            }
        )
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { store.removalConfirmation != nil },
            set: { if !$0 { store.cancelRemoval() } }
        )
    }

    private var verifyConfirmationBinding: Binding<Bool> {
        Binding(
            get: { store.verifyConfirmation != nil },
            set: { if !$0 { store.cancelVerifyConfirmation() } }
        )
    }

    private func torrentPropertiesDraftBinding(
        for editor: AppStore.TorrentPropertiesEditorState
    ) -> Binding<TorrentPropertiesDraft> {
        Binding(
            get: {
                guard store.torrentPropertiesEditor?.id == editor.id else { return editor.draft }
                return store.torrentPropertiesEditor?.draft ?? editor.draft
            },
            set: { draft in
                guard store.torrentPropertiesEditor?.id == editor.id else { return }
                store.torrentPropertiesEditor?.draft = draft
            }
        )
    }

    private func removalMessage(for confirmation: AppStore.RemovalConfirmation) -> String {
        let size = ByteCountFormatters.fileSize(confirmation.totalSize)
        if confirmation.torrentNames.count == 1, let name = confirmation.torrentNames.first {
            if confirmation.deleteLocalData {
                return "“\(name)” will be removed, and its data (\(size)) will be permanently deleted from the Transmission server. This can’t be undone."
            }
            return "“\(name)” will be removed from Transmission. Its data (\(size)) will remain on the Transmission server."
        }

        if confirmation.deleteLocalData {
            return "These \(confirmation.torrentIDs.count) torrents will be removed, and their data (\(size) total) will be permanently deleted from the Transmission server. This can’t be undone.\n\n\(removalNamesPreview(for: confirmation))"
        }
        return "These \(confirmation.torrentIDs.count) torrents will be removed from Transmission. Their data (\(size) total) will remain on the Transmission server.\n\n\(removalNamesPreview(for: confirmation))"
    }

    private func removalTitle(for confirmation: AppStore.RemovalConfirmation?) -> String {
        guard let confirmation else { return "Remove Torrents?" }
        return confirmation.torrentIDs.count == 1
            ? "Remove Torrent?"
            : "Remove \(confirmation.torrentIDs.count) Torrents?"
    }

    private func removalButtonTitle(for confirmation: AppStore.RemovalConfirmation) -> String {
        if confirmation.deleteLocalData { return "Remove and Delete Data" }
        return confirmation.torrentIDs.count == 1 ? "Remove Torrent" : "Remove Torrents"
    }

    private func removalNamesPreview(for confirmation: AppStore.RemovalConfirmation) -> String {
        let visibleNames = confirmation.torrentNames.prefix(3).map { "“\($0)”" }
        let remainingCount = max(0, confirmation.torrentNames.count - visibleNames.count)
        if remainingCount == 0 {
            return "Selected: \(visibleNames.joined(separator: ", "))"
        }
        return "Selected: \(visibleNames.joined(separator: ", ")), and \(remainingCount) more"
    }
}
