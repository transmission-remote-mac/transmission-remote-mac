// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation
import SwiftUI

struct TorrentFilesView: View {
    var torrentID: Int
    var state: TorrentDetailLoadState
    var downloadDirectory: String
    var isActive: Bool
    var canMutateFiles: Bool
    var setFileWanted: (Bool, [Int]) async -> Void
    var setFilePriority: (TorrentFilePriority, [Int]) async -> Void
    var canRenameFilePath: Bool
    var renameFilePath: (TorrentFileNode, String) async -> Void
    var localActionExecutor: TorrentFileLocalActionExecutor?
    @ObservedObject var columnCustomizationController:
        TableColumnCustomizationPersistenceController<TorrentFileNode>

    @AppStorage(SecondaryTablePreferenceKeys.fileLayout) private var persistedLayout = ""
    @AppStorage(SecondaryTablePreferenceKeys.fileSort) private var persistedSort = SecondaryTableDefaults.fileSort
    @State private var localActionError: String?
    @State private var planner = TorrentFileSelectionPlanner()
    @State private var selectedNodeIDs: Set<TorrentFileNode.ID> = []
    @State private var projectionIdentity: TorrentFilesProjectionIdentity?
    @State private var sortOrder = TorrentFileTableSorting.descriptors(for: SecondaryTableDefaults.fileSort)
    @State private var appliedSortPreference = SecondaryTableDefaults.fileSort
    @StateObject private var projectionCache =
        SecondaryTableProjectionCache<TorrentFilesProjectionIdentity, TorrentFilesTableProjection>()
    @StateObject private var selectedLocalActionCapability = TorrentFileLocalActionCapability()
    @StateObject private var rootLocalActionCapability = TorrentFileLocalActionCapability()
    @State private var renameEditor: TorrentPathRenameEditor?
    @StateObject private var performanceHarnessInstrumentationOwner =
        PerformanceHarnessFilesViewInstrumentationOwner()
    @State private var pendingPerformanceHarnessAcknowledgement:
        PerformanceHarnessFilesSelectionCommit?
    @FocusState private var filesOwnFocus: Bool

    var body: some View {
        let canMutateCurrentFiles = canMutateFiles && hasCurrentFileProjection
        let capabilityRequest = localActionCapabilityRequest(for: selectedNodeIDs)
        let rootCapabilityRequest = localActionCapabilityRequest(for: [], allowsRootPreflight: true)
        let canCopySelectedFullPaths = selectedLocalActionCapability.allows(capabilityRequest)

        Group {
            if let detail = state.detail {
                if detail.files.isEmpty {
                    ContentUnavailableView("No Files", systemImage: "folder.badge.questionmark")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        TorrentFileSelectionToolbar(
                            selectedCount: selectedNodeIDs.count,
                            canMutateFiles: canMutateCurrentFiles,
                            canRename: canRenameFilePath
                                && hasCurrentFileProjection
                                && selectedNodeIDs.count == 1,
                            canCopyFullPaths: canCopySelectedFullPaths,
                            setWanted: performSelectedWanted,
                            setPriority: performSelectedPriority,
                            rename: { requestRename(in: selectedNodeIDs) },
                            copyRelativePaths: copySelectedRelativePaths,
                            copyFullPaths: copySelectedFullPaths,
                            clearSelection: { selectedNodeIDs.removeAll() },
                            columnCustomization: columnCustomizationController.binding,
                            layoutPreference: fileLayoutBinding,
                            restoreDefaultColumns: columnCustomizationController.reset,
                            restoreDefaultSort: {
                                persistedSort = SecondaryTableDefaults.fileSort
                                synchronizeFileProjection()
                            }
                        )
                        Divider()
                        Table(
                            displayedFileTree(detail: detail),
                            children: \.children,
                            selection: $selectedNodeIDs,
                            sortOrder: fileSortBinding(),
                            columnCustomization: columnCustomizationController.binding
                        ) {
                            TableColumn("Path / name", value: \.sortPath) { node in
                                TorrentFileNameCell(node: node)
                            }
                            .width(min: 220, ideal: 420)
                            .customizationID(SecondaryTableColumnID.Files.name)
                            .defaultVisibility(.visible)
                            .disabledCustomizationBehavior(.visibility)

                            TableColumn("Size", value: \.length) { node in
                                Text(TorrentDetailFormatters.size(node.length))
                                    .monospacedDigit()
                            }
                            .width(min: 70, ideal: 92)
                            .customizationID(SecondaryTableColumnID.Files.size)
                            .defaultVisibility(.visible)

                            TableColumn("Done", value: \.bytesCompleted) { node in
                                Text(ByteCountFormatters.transferSize(node.bytesCompleted))
                                    .monospacedDigit()
                            }
                            .width(min: 70, ideal: 92)
                            .customizationID(SecondaryTableColumnID.Files.completed)
                            .defaultVisibility(.visible)

                            TableColumn("Progress", value: \.progress) { node in
                                Text(TorrentDetailFormatters.percent(node.progress))
                                    .monospacedDigit()
                            }
                            .width(min: 70, ideal: 76)
                            .customizationID(SecondaryTableColumnID.Files.progress)
                            .defaultVisibility(.visible)

                            TableColumn("Wanted", value: \.wantedSortRank) { node in
                                TorrentFileWantedCell(
                                    node: node,
                                    canMutateFiles: canMutateCurrentFiles,
                                    setFileWanted: { wanted in
                                        performWanted(wanted, selection: [node.id])
                                    }
                                )
                            }
                            .width(min: 64, ideal: 72)
                            .customizationID(SecondaryTableColumnID.Files.wanted)
                            .defaultVisibility(.visible)

                            TableColumn("Priority", value: \.priority) { node in
                                TorrentFilePriorityCell(
                                    node: node,
                                    canMutateFiles: canMutateCurrentFiles,
                                    setFilePriority: { priority in
                                        performPriority(priority, selection: [node.id])
                                    }
                                )
                            }
                            .width(min: 80, ideal: 90)
                            .customizationID(SecondaryTableColumnID.Files.priority)
                            .defaultVisibility(.visible)
                        }
                        .id(columnCustomizationController.replacementRevision)
                        .textSelection(.disabled)
                        .focusable()
                        .focused($filesOwnFocus)
                        .focusedValue(\.torrentTableCommandsActive, false)
                        .onKeyPress("a", phases: .down) { keyPress in
                            guard keyPress.modifiers == .command,
                                  let selection = SecondaryTableFocusedSelectionAction.selectAll(
                                      isActive: isActive,
                                      ownsFocus: filesOwnFocus,
                                      ownsCurrentProjection: hasCurrentFileProjection,
                                      availableIDs: planner.allNodeIDs
                                  ) else {
                                return .ignored
                            }
                            selectedNodeIDs = selection
                            return .handled
                        }
                        .onCopyCommand {
                            selectedRelativePathCopyItems()
                        }
                        .contextMenu(forSelectionType: TorrentFileNode.ID.self) { selection in
                            fileContextMenu(selection: selection)
                        } primaryAction: { selection in
                            performPrimaryFileAction(selection: selection)
                        }
                        .accessibilityLabel("Torrent files")
                    }
                }
            } else {
                TorrentDetailStateUnavailableView(state: state, title: "File details")
            }
        }
        .onAppear {
            synchronizeFileColumnLayout()
            synchronizePlanner()
        }
        .onChange(of: torrentID) {
            projectionIdentity = nil
            selectedNodeIDs.removeAll()
            synchronizePlanner()
        }
        .onChange(of: state.detail?.filesSnapshotRevision) {
            synchronizePlanner()
        }
        .onChange(of: persistedSort) {
            synchronizeFileProjection()
        }
        .onChange(of: columnCustomizationController.customization) {
            synchronizeFileColumnLayout()
        }
        .onChange(of: isActive) {
            if !isActive {
                filesOwnFocus = false
            }
        }
        .task(id: capabilityRequest) {
            await selectedLocalActionCapability.update(capabilityRequest, planner: planner)
        }
        .task(id: rootCapabilityRequest) {
            await rootLocalActionCapability.update(rootCapabilityRequest, planner: planner)
        }
        .task(
            id: pendingPerformanceHarnessAcknowledgement?
                .plan.identity.filesSnapshotRevision
        ) {
            await acknowledgePendingPerformanceHarnessSelection()
        }
        .alert(
            "File Action Failed",
            isPresented: Binding(
                get: { localActionError != nil },
                set: { isPresented in
                    if !isPresented {
                        localActionError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                localActionError = nil
            }
        } message: {
            Text(localActionError ?? "")
        }
        .sheet(item: $renameEditor) { editor in
            TorrentPathRenameSheet(
                editor: editor,
                onCancel: {
                    renameEditor = nil
                },
                onRename: { normalizedName in
                    renameEditor = nil
                    Task {
                        await renameFilePath(editor.node, normalizedName)
                    }
                }
            )
        }
    }

    private var hasCurrentFileProjection: Bool {
        projectionIdentity?.matches(torrentID: torrentID, detail: state.detail) == true
    }

    private func localActionCapabilityRequest(for selection: Set<TorrentFileNode.ID>, allowsRootPreflight: Bool = false) -> TorrentFileLocalActionCapabilityRequest? {
        guard hasCurrentFileProjection,
              isActive,
              let projectionIdentity,
              let localActionExecutor,
              allowsRootPreflight || !selection.isEmpty else {
            return nil
        }
        return TorrentFileLocalActionCapabilityRequest(
            identity: projectionIdentity,
            mapping: localActionExecutor.mapping,
            downloadDirectory: downloadDirectory,
            selection: selection
        )
    }

    private func synchronizePlanner() {
        guard let detail = state.detail,
              detail.id == torrentID,
              TorrentFilesProjectionIdentity(detail: detail) != nil else {
            clearFileProjection()
            return
        }
        synchronizeFileProjection()
    }

    private func synchronizeFileProjection() {
        let preference = persistedSort.normalized(
            allowedColumnIDs: SecondaryTableColumnID.Files.all,
            default: SecondaryTableDefaults.fileSort
        )
        synchronizeFileLayoutSort(preference)
        guard let detail = state.detail,
              detail.id == torrentID,
              let detailIdentity = TorrentFilesProjectionIdentity(detail: detail) else {
            clearFileProjection()
            return
        }
        guard projectionIdentity != detailIdentity
                || appliedSortPreference != preference else {
            sortOrder = TorrentFileTableSorting.descriptors(for: preference)
            return
        }
        let performanceHarnessInstrumentation = performanceHarnessInstrumentationOwner.controller
        let projection = fileProjection(detail: detail, identity: detailIdentity, sort: preference)
        let updatedPlanner = projection.planner
        selectedNodeIDs = updatedPlanner.pruned(selectedNodeIDs)
        planner = updatedPlanner
        sortOrder = TorrentFileTableSorting.descriptors(for: preference)
        appliedSortPreference = preference
        projectionIdentity = detailIdentity
        pendingPerformanceHarnessAcknowledgement = nil
        guard let selectionPlan = performanceHarnessInstrumentation?.makeSelectAllPlan(
            identity: detailIdentity,
            fileCount: detail.files.count,
            planner: updatedPlanner
        ) else {
            return
        }
        guard let selectionCommit = performanceHarnessInstrumentation?.commitSelection(
            selectionPlan,
            currentIdentity: detailIdentity,
            commit: { selectedNodeIDs = selectionPlan.selectedNodeIDs }
        ) else {
            return
        }
        pendingPerformanceHarnessAcknowledgement = selectionCommit
    }

    @MainActor
    private func acknowledgePendingPerformanceHarnessSelection() async {
        guard let selectionCommit = pendingPerformanceHarnessAcknowledgement else { return }
        await Task.yield()
        guard !Task.isCancelled else { return }
        guard
            pendingPerformanceHarnessAcknowledgement?.acknowledgementStartedAt
                == selectionCommit.acknowledgementStartedAt,
            projectionIdentity == selectionCommit.plan.identity,
            selectedNodeIDs == selectionCommit.plan.selectedNodeIDs,
            isActive
        else {
            if pendingPerformanceHarnessAcknowledgement?.acknowledgementStartedAt
                == selectionCommit.acknowledgementStartedAt {
                pendingPerformanceHarnessAcknowledgement = nil
            }
            return
        }
        _ = performanceHarnessInstrumentationOwner.controller?.acknowledgeSelection(
            selectionCommit,
            currentIdentity: projectionIdentity,
            selectedNodeIDs: selectedNodeIDs,
            filesPaneIsActive: isActive
        )
        if pendingPerformanceHarnessAcknowledgement?.acknowledgementStartedAt
            == selectionCommit.acknowledgementStartedAt {
            pendingPerformanceHarnessAcknowledgement = nil
        }
    }

    private func displayedFileTree(detail: TorrentDetail) -> [TorrentFileNode] {
        guard detail.id == torrentID,
              let identity = TorrentFilesProjectionIdentity(detail: detail) else { return [] }
        return fileProjection(
            detail: detail,
            identity: identity,
            sort: persistedSort.normalized(
                allowedColumnIDs: SecondaryTableColumnID.Files.all,
                default: SecondaryTableDefaults.fileSort
            )
        ).tree
    }

    private func fileProjection(detail: TorrentDetail, identity: TorrentFilesProjectionIdentity, sort: SecondaryTableSortPreference) -> TorrentFilesTableProjection {
        projectionCache.value(for: identity, sort: sort) {
            let instrumentation = performanceHarnessInstrumentationOwner.controller
            let startedAt = instrumentation == nil ? nil : ContinuousClock().now
            let tree = SecondaryTableSorting.files(detail.fileTree, by: sort)
            let projection = TorrentFilesTableProjection(
                tree: tree,
                planner: TorrentFileSelectionPlanner(tree: tree)
            )
            if let startedAt {
                instrumentation?.recordProjection(
                    identity: identity,
                    fileCount: detail.files.count,
                    rowCount: projection.planner.allNodeIDs.count,
                    duration: startedAt.duration(to: ContinuousClock().now)
                )
            }
            return projection
        }
    }

    private func fileSortBinding() -> Binding<[KeyPathComparator<TorrentFileNode>]> {
        Binding(
            get: { sortOrder },
            set: { newValue in
                guard let sourceDetail = state.detail,
                      sourceDetail.id == torrentID,
                      let sourceIdentity = TorrentFilesProjectionIdentity(detail: sourceDetail) else {
                    clearFileProjection()
                    return
                }
                let currentIdentityBeforeBuild = state.detail.flatMap {
                    TorrentFilesProjectionIdentity(detail: $0)
                }
                guard TorrentFilesProjectionCommitGuard.canCommit(
                    expectedIdentity: sourceIdentity,
                    projectionOwnerIdentity: projectionIdentity,
                    currentIdentity: currentIdentityBeforeBuild
                ) else {
                    clearFileProjection()
                    return
                }
                let preference = TorrentFileTableSorting.preference(for: newValue)
                    ?? SecondaryTableDefaults.fileSort
                let projection = fileProjection(detail: sourceDetail, identity: sourceIdentity, sort: preference)
                let updatedPlanner = projection.planner
                let currentIdentity = state.detail.flatMap {
                    TorrentFilesProjectionIdentity(detail: $0)
                }
                guard TorrentFilesProjectionCommitGuard.canCommit(
                    expectedIdentity: sourceIdentity,
                    projectionOwnerIdentity: projectionIdentity,
                    currentIdentity: currentIdentity
                ) else {
                    clearFileProjection()
                    return
                }
                sortOrder = TorrentFileTableSorting.descriptors(for: preference)
                persistedSort = preference
                synchronizeFileLayoutSort(preference)
                selectedNodeIDs = updatedPlanner.pruned(selectedNodeIDs)
                planner = updatedPlanner
                appliedSortPreference = preference
                projectionIdentity = sourceIdentity
            }
        )
    }

    private var fileLayoutBinding: Binding<SecondaryTableLayoutPreference> {
        Binding(
            get: {
                SecondaryTableLayoutPreference.restored(from: persistedLayout, for: .files)
            },
            set: { preference in
                storeFileLayout(preference)
            }
        )
    }

    private func synchronizeFileColumnLayout() {
        var preference = SecondaryTableLayoutPreference.restored(from: persistedLayout, for: .files)
        for columnID in SecondaryTableColumnID.Files.all {
            let visibility = columnCustomizationController.customization[
                visibility: columnID
            ]
            let isVisible = visibility == .visible
                || (visibility != .hidden && !SecondaryTableKind.files.defaultHiddenColumnIDs.contains(columnID))
            preference = preference.settingColumnVisibility(
                isVisible,
                columnID: columnID,
                for: .files
            )
        }
        storeFileLayout(preference.settingSort(persistedSort, for: .files))
    }

    private func synchronizeFileLayoutSort(_ preference: SecondaryTableSortPreference) {
        let layout = SecondaryTableLayoutPreference
            .restored(from: persistedLayout, for: .files)
            .settingSort(preference, for: .files)
        storeFileLayout(layout)
    }

    private func storeFileLayout(_ preference: SecondaryTableLayoutPreference) {
        let rawValue = preference.normalized(for: .files).rawValue
        if persistedLayout != rawValue {
            persistedLayout = rawValue
        }
    }

    private func clearFileProjection() {
        planner = TorrentFileSelectionPlanner()
        selectedNodeIDs.removeAll()
        projectionIdentity = nil
        pendingPerformanceHarnessAcknowledgement = nil
    }

    private func performSelectedWanted(_ wanted: Bool) {
        performWanted(wanted, selection: selectedNodeIDs)
    }

    private func performSelectedPriority(_ priority: TorrentFilePriority) {
        performPriority(priority, selection: selectedNodeIDs)
    }

    private func performWanted(_ wanted: Bool, selection: Set<TorrentFileNode.ID>) {
        guard hasCurrentFileProjection, canMutateFiles else { return }
        let fileIndexes = planner.fileIndexes(in: selection)
        guard !fileIndexes.isEmpty else { return }
        Task {
            await setFileWanted(wanted, fileIndexes)
        }
    }

    private func performPriority(
        _ priority: TorrentFilePriority,
        selection: Set<TorrentFileNode.ID>
    ) {
        guard hasCurrentFileProjection, canMutateFiles else { return }
        let fileIndexes = planner.fileIndexes(in: selection)
        guard !fileIndexes.isEmpty else { return }
        Task {
            await setFilePriority(priority, fileIndexes)
        }
    }

    private func copySelectedRelativePaths() {
        copyRelativePaths(in: selectedNodeIDs)
    }

    private func copySelectedFullPaths() {
        copyFullPaths(in: selectedNodeIDs)
    }

    private func selectedRelativePathCopyItems() -> [NSItemProvider] {
        guard SecondaryTableFocusedSelectionAction.canCopy(
            isActive: isActive,
            ownsFocus: filesOwnFocus,
            ownsCurrentProjection: hasCurrentFileProjection,
            selectedCount: selectedNodeIDs.count
        ) else {
            return []
        }
        let paths = planner.relativePaths(in: selectedNodeIDs)
        guard !paths.isEmpty else { return [] }
        return [NSItemProvider(object: paths.joined(separator: "\n") as NSString)]
    }

    private func copyRelativePaths(in selection: Set<TorrentFileNode.ID>) {
        guard hasCurrentFileProjection else { return }
        let paths = planner.relativePaths(in: selection)
        guard !paths.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(paths.joined(separator: "\n"), forType: .string) else {
            localActionError = LocalFileActionError.copyFailed.localizedDescription
            return
        }
    }

    private func copyFullPaths(in selection: Set<TorrentFileNode.ID>) {
        guard hasCurrentFileProjection, let localActionExecutor else { return }
        do {
            try localActionExecutor.copyPaths(
                downloadDirectory: downloadDirectory,
                nodes: planner.nodes(in: selection)
            )
        } catch {
            localActionError = error.localizedDescription
        }
    }

    private func performLocalAction(_ action: TorrentFileLocalAction, node: TorrentFileNode) {
        guard hasCurrentFileProjection, let localActionExecutor else { return }
        do {
            try localActionExecutor.perform(
                action,
                downloadDirectory: downloadDirectory,
                node: node
            )
        } catch {
            localActionError = error.localizedDescription
        }
    }

    private func requestRename(in selection: Set<TorrentFileNode.ID>) {
        guard
            canRenameFilePath,
            hasCurrentFileProjection,
            selection.count == 1,
            let selectedID = selection.first,
            let node = planner.nodes(in: [selectedID]).first
        else {
            return
        }
        renameEditor = TorrentPathRenameEditor(node: node)
    }

    @ViewBuilder
    private func fileContextMenu(selection: Set<TorrentFileNode.ID>) -> some View {
        let contextSelection = hasCurrentFileProjection
            ? (selection.isEmpty ? selectedNodeIDs : selection)
            : []
        let selectionCount = contextSelection.count
        let selectedNode = selectionCount == 1
            ? contextSelection.first.flatMap { planner.nodes(in: [$0]).first }
            : nil
        // Native menus need not run SwiftUI task lifecycles. Reuse root preflight
        // and pure lexical eligibility here; execution always checks symlinks again.
        let rootRequest = localActionCapabilityRequest(for: [], allowsRootPreflight: true)
        let canCopyFullPaths = rootLocalActionCapability.allows(rootRequest)
            && !contextSelection.isEmpty
            && planner.allNodes(
                in: contextSelection,
                satisfy: TorrentFileLocalPathResolver.hasSafeRelativePath
            )
        let canRequestLocalAction = selectedNode != nil && canCopyFullPaths
        let canRequestRename = canRenameFilePath
            && hasCurrentFileProjection
            && selectedNode != nil

        Button {
            performWanted(true, selection: contextSelection)
        } label: {
            Label(contextActionTitle("Mark Wanted", count: selectionCount), systemImage: "checkmark.square")
        }
        .disabled(!canMutateFiles || !hasCurrentFileProjection || contextSelection.isEmpty)

        Button {
            performWanted(false, selection: contextSelection)
        } label: {
            Label(contextActionTitle("Mark Unwanted", count: selectionCount), systemImage: "square")
        }
        .disabled(!canMutateFiles || !hasCurrentFileProjection || contextSelection.isEmpty)

        Menu {
            ForEach(TorrentFilePriority.allCases) { priority in
                Button(priority.title) {
                    performPriority(priority, selection: contextSelection)
                }
            }
        } label: {
            Label(contextActionTitle("Priority", count: selectionCount), systemImage: "flag")
        }
        .disabled(!canMutateFiles || !hasCurrentFileProjection || contextSelection.isEmpty)

        Divider()

        Button {
            requestRename(in: contextSelection)
        } label: {
            Label("Rename…", systemImage: "pencil")
        }
        .disabled(!canRequestRename)

        Divider()

        Button {
            if let selectedNode {
                performLocalAction(.open, node: selectedNode)
            }
        } label: {
            Label("Open", systemImage: "arrow.up.forward.app")
        }
        .disabled(!canRequestLocalAction)

        Button {
            if let selectedNode {
                performLocalAction(.reveal, node: selectedNode)
            }
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(!canRequestLocalAction)

        Divider()

        Button {
            copyRelativePaths(in: contextSelection)
        } label: {
            Label(contextActionTitle("Copy Relative Path(s)", count: selectionCount), systemImage: "doc.on.doc")
        }
        .disabled(contextSelection.isEmpty)

        Button {
            copyFullPaths(in: contextSelection)
        } label: {
            Label(contextActionTitle("Copy Full Mapped Path(s)", count: selectionCount), systemImage: "externaldrive")
        }
        .disabled(!canCopyFullPaths)
    }

    private func performPrimaryFileAction(selection: Set<TorrentFileNode.ID>) {
        guard hasCurrentFileProjection,
              selection.count == 1,
              let selectedID = selection.first,
              let node = planner.nodes(in: [selectedID]).first else {
            return
        }
        performLocalAction(.open, node: node)
    }

    private func contextActionTitle(_ title: String, count: Int) -> String {
        count > 1 ? "\(title) (\(count))" : title
    }
}

private struct TorrentFileSelectionToolbar: View {
    var selectedCount: Int
    var canMutateFiles: Bool
    var canRename: Bool
    var canCopyFullPaths: Bool
    var setWanted: (Bool) -> Void
    var setPriority: (TorrentFilePriority) -> Void
    var rename: () -> Void
    var copyRelativePaths: () -> Void
    var copyFullPaths: () -> Void
    var clearSelection: () -> Void
    @Binding var columnCustomization: TableColumnCustomization<TorrentFileNode>
    @Binding var layoutPreference: SecondaryTableLayoutPreference
    var restoreDefaultColumns: () -> Void
    var restoreDefaultSort: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(selectedCount == 1 ? "1 item selected" : "\(selectedCount) items selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(selectedCount) torrent file items selected")

            Spacer()

            Menu {
                Button {
                    setWanted(true)
                } label: {
                    Label("Mark Wanted", systemImage: "checkmark.square")
                }
                Button {
                    setWanted(false)
                } label: {
                    Label("Mark Unwanted", systemImage: "square")
                }
            } label: {
                Label("Wanted", systemImage: "checkmark.square")
            }
            .help("Change wanted state for selected files and folders")
            .disabled(selectedCount == 0 || !canMutateFiles)

            Menu {
                ForEach(TorrentFilePriority.allCases) { priority in
                    Button(priority.title) {
                        setPriority(priority)
                    }
                }
            } label: {
                Label("Priority", systemImage: "flag")
            }
            .help("Change priority for selected files and folders")
            .disabled(selectedCount == 0 || !canMutateFiles)

            Button(action: rename) {
                Label("Rename", systemImage: "pencil")
            }
            .help("Rename the selected file or folder on the Transmission server")
            .disabled(!canRename)

            Menu {
                Button {
                    copyRelativePaths()
                } label: {
                    Label("Copy Relative Path(s)", systemImage: "doc.on.doc")
                }
                Button {
                    copyFullPaths()
                } label: {
                    Label("Copy Full Mapped Path(s)", systemImage: "externaldrive")
                }
                .disabled(!canCopyFullPaths)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .help("Copy selected paths in display order")
            .disabled(selectedCount == 0)

            Button(action: clearSelection) {
                Label("Clear", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .help("Clear file selection")
            .disabled(selectedCount == 0)

            SecondaryTableColumnMenu(
                title: "File Columns",
                table: .files,
                customization: $columnCustomization,
                layoutPreference: $layoutPreference,
                columns: [
                    .init(id: SecondaryTableColumnID.Files.name, title: "Path / name", isRequired: true),
                    .init(id: SecondaryTableColumnID.Files.size, title: "Size"),
                    .init(id: SecondaryTableColumnID.Files.completed, title: "Done"),
                    .init(id: SecondaryTableColumnID.Files.progress, title: "Progress"),
                    .init(id: SecondaryTableColumnID.Files.wanted, title: "Wanted"),
                    .init(id: SecondaryTableColumnID.Files.priority, title: "Priority")
                ],
                restoreDefaultColumns: restoreDefaultColumns,
                restoreDefaultSort: restoreDefaultSort
            )
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

private struct TorrentPathRenameEditor: Identifiable {
    let id = UUID()
    let node: TorrentFileNode
}

private struct TorrentPathRenameSheet: View {
    let editor: TorrentPathRenameEditor
    var onCancel: () -> Void
    var onRename: (String) -> Void

    @State private var name: String
    @FocusState private var nameHasFocus: Bool

    init(
        editor: TorrentPathRenameEditor,
        onCancel: @escaping () -> Void,
        onRename: @escaping (String) -> Void
    ) {
        self.editor = editor
        self.onCancel = onCancel
        self.onRename = onRename
        _name = State(initialValue: editor.node.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editor.node.isFolder ? "Rename Folder" : "Rename File")
                .font(.title2.weight(.semibold))

            Text(editor.node.path.isEmpty ? editor.node.name : "\(editor.node.path)/\(editor.node.name)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)

            TextField("New name", text: $name)
                .focused($nameHasFocus)
                .onSubmit(submit)

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedName == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            nameHasFocus = true
        }
    }

    private var normalizedName: String? {
        try? TorrentPathRenameValidator.normalizeNewBasename(
            name,
            originalBasename: editor.node.name
        )
    }

    private var validationMessage: String? {
        do {
            _ = try TorrentPathRenameValidator.normalizeNewBasename(
                name,
                originalBasename: editor.node.name
            )
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func submit() {
        guard let normalizedName else { return }
        onRename(normalizedName)
    }
}

private struct TorrentFileNameCell: View {
    var node: TorrentFileNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "doc")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(TorrentDetailFormatters.placeholder(node.name))
                    .lineLimit(1)
                if !node.path.isEmpty {
                    Text(node.path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

private struct TorrentFileWantedCell: View {
    var node: TorrentFileNode
    var canMutateFiles: Bool
    var setFileWanted: (Bool) -> Void

    var body: some View {
        Button {
            setFileWanted(node.nextWantedValue)
        } label: {
            Label(node.wanted.title, systemImage: node.wanted.systemImage)
                .labelStyle(.iconOnly)
        }
        .buttonStyle(.plain)
        .help(node.wantedToggleHelp)
        .accessibilityLabel("Wanted: \(node.wanted.title)")
        .disabled(!canMutateFiles)
    }
}

private struct TorrentFilePriorityCell: View {
    var node: TorrentFileNode
    var canMutateFiles: Bool
    var setFilePriority: (TorrentFilePriority) -> Void

    var body: some View {
        Menu {
            ForEach(TorrentFilePriority.allCases) { priority in
                Button {
                    setFilePriority(priority)
                } label: {
                    if node.priority.editablePriority == priority {
                        Label(priority.title, systemImage: "checkmark")
                    } else {
                        Text(priority.title)
                    }
                }
            }
        } label: {
            Text(node.priority.title)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .controlSize(.small)
        .disabled(!canMutateFiles)
    }
}

private extension TorrentFileNode {
    var sortPath: String {
        path.isEmpty ? name : "\(path)/\(name)"
    }

    var wantedSortRank: Int {
        switch wanted {
        case .wanted: 0
        case .mixed: 1
        case .unwanted: 2
        case .unknown: 3
        }
    }

    var nextWantedValue: Bool {
        switch wanted {
        case .wanted:
            false
        case .unwanted, .mixed, .unknown:
            true
        }
    }

    var wantedToggleHelp: String {
        switch wanted {
        case .wanted:
            "Mark file unwanted"
        case .unwanted:
            "Mark file wanted"
        case .mixed:
            "Mark folder contents wanted"
        case .unknown:
            "Mark file wanted"
        }
    }
}

private extension TorrentFileWantedState {
    var systemImage: String {
        switch self {
        case .wanted:
            "checkmark.square"
        case .unwanted:
            "square"
        case .mixed:
            "minus.square"
        case .unknown:
            "questionmark.square"
        }
    }
}

private enum TorrentFileTableSorting {
    static func descriptors(
        for preference: SecondaryTableSortPreference
    ) -> [KeyPathComparator<TorrentFileNode>] {
        let order = preference.direction.sortOrder
        switch preference.columnID {
        case SecondaryTableColumnID.Files.size:
            return [KeyPathComparator(\TorrentFileNode.length, order: order)]
        case SecondaryTableColumnID.Files.completed:
            return [KeyPathComparator(\TorrentFileNode.bytesCompleted, order: order)]
        case SecondaryTableColumnID.Files.progress:
            return [KeyPathComparator(\TorrentFileNode.progress, order: order)]
        case SecondaryTableColumnID.Files.wanted:
            return [KeyPathComparator(\TorrentFileNode.wantedSortRank, order: order)]
        case SecondaryTableColumnID.Files.priority:
            return [KeyPathComparator(\TorrentFileNode.priority, order: order)]
        default:
            return [KeyPathComparator(\TorrentFileNode.sortPath, order: order)]
        }
    }

    static func preference(
        for descriptors: [KeyPathComparator<TorrentFileNode>]
    ) -> SecondaryTableSortPreference? {
        guard let descriptor = descriptors.first else { return nil }
        let columnID: String
        if descriptor.keyPath == \TorrentFileNode.length {
            columnID = SecondaryTableColumnID.Files.size
        } else if descriptor.keyPath == \TorrentFileNode.bytesCompleted {
            columnID = SecondaryTableColumnID.Files.completed
        } else if descriptor.keyPath == \TorrentFileNode.progress {
            columnID = SecondaryTableColumnID.Files.progress
        } else if descriptor.keyPath == \TorrentFileNode.wantedSortRank {
            columnID = SecondaryTableColumnID.Files.wanted
        } else if descriptor.keyPath == \TorrentFileNode.priority {
            columnID = SecondaryTableColumnID.Files.priority
        } else if descriptor.keyPath == \TorrentFileNode.sortPath {
            columnID = SecondaryTableColumnID.Files.name
        } else {
            return nil
        }
        return SecondaryTableSortPreference(
            columnID: columnID,
            direction: SecondaryTableSortDirection(descriptor.order)
        )
    }
}
