// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation
import SwiftUI

struct TorrentTrackersView: View {
    var state: TorrentDetailLoadState
    var isActive: Bool
    var canMutateTrackers: Bool
    var addTracker: (String) async -> Void
    var replaceTracker: (Int, String) async -> Void
    var removeTrackers: ([Int]) async -> Void
    @ObservedObject var columnCustomizationController:
        TableColumnCustomizationPersistenceController<TorrentTracker>

    @AppStorage(SecondaryTablePreferenceKeys.trackerLayout) private var persistedLayout = ""
    @AppStorage(SecondaryTablePreferenceKeys.trackerSort) private var persistedSort = SecondaryTableDefaults.trackerSort
    @State private var selectedTrackerIDs = Set<TorrentTracker.ID>()
    @State private var sortedTrackers: [TorrentTracker] = []
    @State private var sortOrder = TorrentTrackerTableSorting.descriptors(for: SecondaryTableDefaults.trackerSort)
    @State private var appliedSortPreference = SecondaryTableDefaults.trackerSort
    @State private var projectionIdentity: TorrentTrackersProjectionIdentity?
    @StateObject private var projectionCache =
        SecondaryTableProjectionCache<TorrentTrackersProjectionIdentity, [TorrentTracker]>()
    @State private var editorMode: TrackerEditorMode?
    @State private var editorAnnounceURL = ""
    @State private var removalTrackerIDs = Set<TorrentTracker.ID>()
    @State private var isConfirmingRemoval = false
    @State private var isMutating = false
    @FocusState private var trackersOwnFocus: Bool

    var body: some View {
        if let detail = state.detail {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Button {
                        beginAddingTracker()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(!canMutateTrackers || isMutating)

                    Button {
                        beginEditingTrackers(selectedTrackerIDs, trackers: detail.trackers)
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    .disabled(!canEdit(selectedTrackerIDs, trackers: detail.trackers))

                    Button(role: .destructive) {
                        requestRemoval(selectedTrackerIDs, trackers: detail.trackers)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .disabled(!canRemove(selectedTrackerIDs, trackers: detail.trackers))

                    Spacer()

                    if isMutating {
                        ProgressView()
                            .controlSize(.small)
                    }

                    SecondaryTableColumnMenu(
                        title: "Tracker Columns",
                        table: .trackers,
                        customization: columnCustomizationController.binding,
                        layoutPreference: trackerLayoutBinding,
                        columns: [
                            .init(id: SecondaryTableColumnID.Trackers.tracker, title: "Tracker", isRequired: true),
                            .init(id: SecondaryTableColumnID.Trackers.status, title: "Status"),
                            .init(id: SecondaryTableColumnID.Trackers.update, title: "Update in"),
                            .init(id: SecondaryTableColumnID.Trackers.seeds, title: "Seeds"),
                            .init(id: SecondaryTableColumnID.Trackers.leechers, title: "Leechers"),
                            .init(id: SecondaryTableColumnID.Trackers.downloads, title: "Downloads")
                        ],
                        restoreDefaultColumns: columnCustomizationController.reset,
                        restoreDefaultSort: {
                            persistedSort = SecondaryTableDefaults.trackerSort
                            synchronizeProjection()
                        }
                    )
                }
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)

                Divider()

                if detail.trackers.isEmpty {
                    ContentUnavailableView("No Trackers", systemImage: "antenna.radiowaves.left.and.right.slash")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Table(
                        displayedTrackers(detail: detail),
                        selection: $selectedTrackerIDs,
                        sortOrder: trackerSortBinding(),
                        columnCustomization: columnCustomizationController.binding
                    ) {
                        TableColumn("Tracker", value: \.announce) { tracker in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(TorrentDetailFormatters.placeholder(tracker.host))
                                    .lineLimit(1)
                                Text(TorrentDetailFormatters.placeholder(tracker.announce))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .width(min: 220, ideal: 380)
                        .customizationID(SecondaryTableColumnID.Trackers.tracker)
                        .defaultVisibility(.visible)
                        .disabledCustomizationBehavior(.visibility)

                        TableColumn("Status", value: \.status) { tracker in
                            Text(TorrentDetailFormatters.placeholder(tracker.status))
                        }
                        .width(min: 100, ideal: 140)
                        .customizationID(SecondaryTableColumnID.Trackers.status)
                        .defaultVisibility(.visible)

                        TableColumn("Update in", value: \.nextAnnounceSortDate) { tracker in
                            Text(TorrentDetailFormatters.updateIn(tracker.nextAnnounceDate))
                                .monospacedDigit()
                        }
                        .width(min: 80, ideal: 90)
                        .customizationID(SecondaryTableColumnID.Trackers.update)
                        .defaultVisibility(.visible)

                        TableColumn("Seeds", value: \.seederCount) { tracker in
                            Text(TorrentDetailFormatters.count(tracker.seederCount))
                                .monospacedDigit()
                        }
                        .width(min: 60, ideal: 70)
                        .customizationID(SecondaryTableColumnID.Trackers.seeds)
                        .defaultVisibility(.visible)

                        TableColumn("Leechers", value: \.leecherCount) { tracker in
                            Text(TorrentDetailFormatters.count(tracker.leecherCount))
                                .monospacedDigit()
                        }
                        .width(min: 70, ideal: 80)
                        .customizationID(SecondaryTableColumnID.Trackers.leechers)
                        .defaultVisibility(.visible)

                        TableColumn("Downloads", value: \.downloadCount) { tracker in
                            Text(TorrentDetailFormatters.count(tracker.downloadCount))
                                .monospacedDigit()
                        }
                        .width(min: 75, ideal: 85)
                        .customizationID(SecondaryTableColumnID.Trackers.downloads)
                        .defaultVisibility(.hidden)
                    }
                    .id(columnCustomizationController.replacementRevision)
                    .focusable()
                    .focused($trackersOwnFocus)
                    .focusedValue(\.torrentTableCommandsActive, false)
                    .onKeyPress("a", phases: .down) { keyPress in
                        guard keyPress.modifiers == .command,
                              let selection = SecondaryTableFocusedSelectionAction.selectAll(
                                  isActive: isActive,
                                  ownsFocus: trackersOwnFocus,
                                  ownsCurrentProjection: hasCurrentTrackerProjection,
                                  availableIDs: Set(sortedTrackers.map(\.id))
                              ) else {
                            return .ignored
                        }
                        selectedTrackerIDs = selection
                        return .handled
                    }
                    .onCopyCommand {
                        selectedTrackerCopyItems()
                    }
                    .onKeyPress(.delete, phases: .down) { keyPress in
                        guard isActive,
                              trackersOwnFocus,
                              keyPress.modifiers.isEmpty,
                              canRemove(selectedTrackerIDs, trackers: detail.trackers) else {
                            return .ignored
                        }
                        requestRemoval(selectedTrackerIDs, trackers: detail.trackers)
                        return .handled
                    }
                    .contextMenu(forSelectionType: TorrentTracker.ID.self) { selection in
                        Button("Edit Tracker…") {
                            beginEditingTrackers(selection, trackers: detail.trackers)
                        }
                        .disabled(!canEdit(selection, trackers: detail.trackers))

                        Button(selection.count == 1 ? "Delete Tracker…" : "Delete \(selection.count) Trackers…", role: .destructive) {
                            requestRemoval(selection, trackers: detail.trackers)
                        }
                        .disabled(!canRemove(selection, trackers: detail.trackers))

                        Divider()

                        Button(selection.count == 1 ? "Copy Tracker URL" : "Copy \(selection.count) Tracker URLs") {
                            selectedTrackerIDs = selection
                            copyTrackers(in: selection)
                        }
                        .disabled(selection.isEmpty)
                    } primaryAction: { selection in
                        beginEditingTrackers(selection, trackers: detail.trackers)
                    }
                }
            }
            .onAppear {
                synchronizeTrackerColumnLayout()
                synchronizeProjection()
            }
            .onChange(of: detail.trackersSnapshotRevision) {
                synchronizeProjection()
                let trackers = state.detail?.trackers ?? []
                let validTrackerIDs = trackers.map(\.id)
                selectedTrackerIDs.formIntersection(validTrackerIDs)
                removalTrackerIDs.formIntersection(validTrackerIDs)
                if removalTrackerIDs.isEmpty {
                    isConfirmingRemoval = false
                }
                if let mode = editorMode,
                   !mode.owner.matches(detail: state.detail, requiresTracker: mode.requiresTracker) {
                    editorMode = nil
                }
            }
            .onChange(of: persistedSort) {
                synchronizeProjection()
            }
            .onChange(of: columnCustomizationController.customization) {
                synchronizeTrackerColumnLayout()
            }
            .onChange(of: isActive) {
                if !isActive {
                    trackersOwnFocus = false
                }
            }
            .alert(editorTitle, isPresented: editorPresented) {
                TextField("Announce URL", text: $editorAnnounceURL)

                Button("Cancel", role: .cancel) {
                    editorMode = nil
                }

                Button(editorActionTitle) {
                    submitEditor()
                }
                .disabled(trimmedEditorAnnounceURL.isEmpty || isMutating)
            } message: {
                Text("Enter the tracker's announce URL.")
            }
            .confirmationDialog(
                removalConfirmationTitle,
                isPresented: $isConfirmingRemoval,
                titleVisibility: .visible
            ) {
                Button(removalActionTitle, role: .destructive) {
                    submitRemoval(trackers: detail.trackers)
                }
                .disabled(!canRemove(removalTrackerIDs, trackers: detail.trackers))

                Button("Cancel", role: .cancel) {
                    removalTrackerIDs.removeAll()
                }
            } message: {
                Text("This removes the selected tracker configuration from the torrent.")
            }
        } else {
            TorrentDetailStateUnavailableView(state: state, title: "Tracker details")
        }
    }

    private var editorPresented: Binding<Bool> {
        Binding(
            get: { editorMode != nil },
            set: { isPresented in
                if !isPresented {
                    editorMode = nil
                }
            }
        )
    }

    private var editorTitle: String {
        switch editorMode {
        case .add:
            "Add Tracker"
        case .edit:
            "Edit Tracker"
        case nil:
            "Tracker"
        }
    }

    private var editorActionTitle: String {
        switch editorMode {
        case .add:
            "Add"
        case .edit:
            "Save"
        case nil:
            "Save"
        }
    }

    private var trimmedEditorAnnounceURL: String {
        editorAnnounceURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func synchronizeProjection() {
        let preference = persistedSort.normalized(
            allowedColumnIDs: SecondaryTableColumnID.Trackers.all,
            default: SecondaryTableDefaults.trackerSort
        )
        synchronizeTrackerLayoutSort(preference)
        guard let detail = state.detail,
              let detailIdentity = TorrentTrackersProjectionIdentity(detail: detail) else {
            clearTrackerProjection()
            return
        }
        guard projectionIdentity != detailIdentity
                || appliedSortPreference != preference else {
            sortOrder = TorrentTrackerTableSorting.descriptors(for: preference)
            return
        }
        sortOrder = TorrentTrackerTableSorting.descriptors(for: preference)
        appliedSortPreference = preference
        sortedTrackers = projectionCache.value(for: detailIdentity, sort: preference) {
            SecondaryTableSorting.trackers(detail.trackers, by: preference)
        }
        selectedTrackerIDs.formIntersection(detail.trackers.map(\.id))
        projectionIdentity = detailIdentity
    }

    private func displayedTrackers(detail: TorrentDetail) -> [TorrentTracker] {
        guard let identity = TorrentTrackersProjectionIdentity(detail: detail) else { return [] }
        let preference = persistedSort.normalized(
            allowedColumnIDs: SecondaryTableColumnID.Trackers.all,
            default: SecondaryTableDefaults.trackerSort
        )
        return projectionCache.value(for: identity, sort: preference) {
            SecondaryTableSorting.trackers(detail.trackers, by: preference)
        }
    }

    private func trackerSortBinding() -> Binding<[KeyPathComparator<TorrentTracker>]> {
        Binding(
            get: { sortOrder },
            set: { newValue in
                guard let sourceDetail = state.detail,
                      let sourceIdentity = TorrentTrackersProjectionIdentity(detail: sourceDetail),
                      TorrentTrackersProjectionCommitGuard.canCommit(
                          expectedIdentity: sourceIdentity,
                          projectionOwnerIdentity: projectionIdentity,
                          currentIdentity: state.detail.flatMap { TorrentTrackersProjectionIdentity(detail: $0) }
                      ) else {
                    clearTrackerProjection()
                    return
                }
                let preference = TorrentTrackerTableSorting.preference(for: newValue)
                    ?? SecondaryTableDefaults.trackerSort
                let projectedRows = projectionCache.value(for: sourceIdentity, sort: preference) {
                    SecondaryTableSorting.trackers(sourceDetail.trackers, by: preference)
                }
                guard TorrentTrackersProjectionCommitGuard.canCommit(
                    expectedIdentity: sourceIdentity,
                    projectionOwnerIdentity: projectionIdentity,
                    currentIdentity: state.detail.flatMap { TorrentTrackersProjectionIdentity(detail: $0) }
                ) else {
                    clearTrackerProjection()
                    return
                }
                sortOrder = TorrentTrackerTableSorting.descriptors(for: preference)
                persistedSort = preference
                synchronizeTrackerLayoutSort(preference)
                appliedSortPreference = preference
                sortedTrackers = projectedRows
                selectedTrackerIDs.formIntersection(projectedRows.map(\.id))
                projectionIdentity = sourceIdentity
            }
        )
    }

    private var trackerLayoutBinding: Binding<SecondaryTableLayoutPreference> {
        Binding(
            get: {
                SecondaryTableLayoutPreference.restored(from: persistedLayout, for: .trackers)
            },
            set: { preference in
                storeTrackerLayout(preference)
            }
        )
    }

    private func synchronizeTrackerColumnLayout() {
        var preference = SecondaryTableLayoutPreference.restored(from: persistedLayout, for: .trackers)
        for columnID in SecondaryTableColumnID.Trackers.all {
            let visibility = columnCustomizationController.customization[
                visibility: columnID
            ]
            let isVisible = visibility == .visible
                || (visibility != .hidden && !SecondaryTableKind.trackers.defaultHiddenColumnIDs.contains(columnID))
            preference = preference.settingColumnVisibility(
                isVisible,
                columnID: columnID,
                for: .trackers
            )
        }
        storeTrackerLayout(preference.settingSort(persistedSort, for: .trackers))
    }

    private func synchronizeTrackerLayoutSort(_ preference: SecondaryTableSortPreference) {
        let layout = SecondaryTableLayoutPreference
            .restored(from: persistedLayout, for: .trackers)
            .settingSort(preference, for: .trackers)
        storeTrackerLayout(layout)
    }

    private func storeTrackerLayout(_ preference: SecondaryTableLayoutPreference) {
        let rawValue = preference.normalized(for: .trackers).rawValue
        if persistedLayout != rawValue {
            persistedLayout = rawValue
        }
    }

    private var hasCurrentTrackerProjection: Bool {
        projectionIdentity?.matches(detail: state.detail) == true
    }

    private func clearTrackerProjection() {
        sortedTrackers.removeAll()
        selectedTrackerIDs.removeAll()
        removalTrackerIDs.removeAll()
        projectionIdentity = nil
        isConfirmingRemoval = false
        editorMode = nil
    }

    private func selectedTrackerCopyItems() -> [NSItemProvider] {
        guard SecondaryTableFocusedSelectionAction.canCopy(
            isActive: isActive,
            ownsFocus: trackersOwnFocus,
            ownsCurrentProjection: hasCurrentTrackerProjection,
            selectedCount: selectedTrackerIDs.count
        ), let text = trackerCopyText(in: selectedTrackerIDs) else {
            return []
        }
        return [NSItemProvider(object: text as NSString)]
    }

    private func copyTrackers(in selection: Set<TorrentTracker.ID>) {
        guard let text = trackerCopyText(in: selection) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func trackerCopyText(in selection: Set<TorrentTracker.ID>) -> String? {
        guard hasCurrentTrackerProjection else { return nil }
        let rows = sortedTrackers.filter { selection.contains($0.id) }
        guard !rows.isEmpty else { return nil }
        return rows.map(\.announce).joined(separator: "\n")
    }

    private var removalConfirmationTitle: String {
        removalTrackerIDs.count == 1
            ? "Delete 1 tracker?"
            : "Delete \(removalTrackerIDs.count) trackers?"
    }

    private var removalActionTitle: String {
        removalTrackerIDs.count == 1
            ? "Delete Tracker"
            : "Delete \(removalTrackerIDs.count) Trackers"
    }

    private func canEdit(_ selection: Set<TorrentTracker.ID>, trackers: [TorrentTracker]) -> Bool {
        canMutateTrackers
            && !isMutating
            && tracker(for: selection, trackers: trackers) != nil
    }

    private func canRemove(_ selection: Set<TorrentTracker.ID>, trackers: [TorrentTracker]) -> Bool {
        canMutateTrackers
            && !isMutating
            && !selection.isEmpty
            && selection.allSatisfy { id in trackers.contains(where: { $0.id == id }) }
    }

    private func tracker(
        for selection: Set<TorrentTracker.ID>,
        trackers: [TorrentTracker]
    ) -> TorrentTracker? {
        guard selection.count == 1, let selectedID = selection.first else { return nil }
        return trackers.first(where: { $0.id == selectedID })
    }

    private func beginAddingTracker() {
        guard canMutateTrackers,
              !isMutating,
              let detail = state.detail,
              let owner = TrackerEditorOwner(detail: detail, tracker: nil) else {
            return
        }
        editorAnnounceURL = ""
        editorMode = .add(owner: owner)
    }

    private func beginEditingTrackers(
        _ selection: Set<TorrentTracker.ID>,
        trackers: [TorrentTracker]
    ) {
        guard canEdit(selection, trackers: trackers),
              let selectedTracker = tracker(for: selection, trackers: trackers),
              let detail = state.detail,
              let owner = TrackerEditorOwner(detail: detail, tracker: selectedTracker) else {
            return
        }
        selectedTrackerIDs = selection
        editorAnnounceURL = selectedTracker.announce
        editorMode = .edit(owner: owner)
    }

    private func requestRemoval(
        _ selection: Set<TorrentTracker.ID>,
        trackers: [TorrentTracker]
    ) {
        guard canRemove(selection, trackers: trackers) else { return }
        selectedTrackerIDs = selection
        removalTrackerIDs = selection
        isConfirmingRemoval = true
    }

    private func submitEditor() {
        guard let mode = editorMode,
              canMutateTrackers,
              !isMutating,
              !trimmedEditorAnnounceURL.isEmpty,
              mode.owner.matches(detail: state.detail, requiresTracker: mode.requiresTracker) else {
            editorMode = nil
            return
        }

        let announceURL = trimmedEditorAnnounceURL
        editorMode = nil
        isMutating = true

        Task {
            guard mode.owner.matches(detail: state.detail, requiresTracker: mode.requiresTracker) else {
                isMutating = false
                return
            }
            switch mode {
            case .add:
                await addTracker(announceURL)
            case .edit(let owner):
                guard let trackerID = owner.daemonTrackerID else {
                    isMutating = false
                    return
                }
                await replaceTracker(trackerID, announceURL)
            }
            isMutating = false
        }
    }

    private func submitRemoval(trackers: [TorrentTracker]) {
        guard canRemove(removalTrackerIDs, trackers: trackers) else { return }
        let trackerIDs = trackers
            .filter { removalTrackerIDs.contains($0.id) }
            .map(\.trackerID)
        removalTrackerIDs.removeAll()
        isMutating = true

        Task {
            await removeTrackers(trackerIDs)
            isMutating = false
        }
    }
}

private extension TorrentTracker {
    var nextAnnounceSortDate: Date {
        nextAnnounceDate ?? .distantPast
    }
}

private enum TorrentTrackerTableSorting {
    static func descriptors(
        for preference: SecondaryTableSortPreference
    ) -> [KeyPathComparator<TorrentTracker>] {
        let order = preference.direction.sortOrder
        switch preference.columnID {
        case SecondaryTableColumnID.Trackers.status:
            return [KeyPathComparator(\TorrentTracker.status, order: order)]
        case SecondaryTableColumnID.Trackers.update:
            return [KeyPathComparator(\TorrentTracker.nextAnnounceSortDate, order: order)]
        case SecondaryTableColumnID.Trackers.seeds:
            return [KeyPathComparator(\TorrentTracker.seederCount, order: order)]
        case SecondaryTableColumnID.Trackers.leechers:
            return [KeyPathComparator(\TorrentTracker.leecherCount, order: order)]
        case SecondaryTableColumnID.Trackers.downloads:
            return [KeyPathComparator(\TorrentTracker.downloadCount, order: order)]
        default:
            return [KeyPathComparator(\TorrentTracker.announce, order: order)]
        }
    }

    static func preference(
        for descriptors: [KeyPathComparator<TorrentTracker>]
    ) -> SecondaryTableSortPreference? {
        guard let descriptor = descriptors.first else { return nil }
        let columnID: String
        if descriptor.keyPath == \TorrentTracker.status {
            columnID = SecondaryTableColumnID.Trackers.status
        } else if descriptor.keyPath == \TorrentTracker.nextAnnounceSortDate {
            columnID = SecondaryTableColumnID.Trackers.update
        } else if descriptor.keyPath == \TorrentTracker.seederCount {
            columnID = SecondaryTableColumnID.Trackers.seeds
        } else if descriptor.keyPath == \TorrentTracker.leecherCount {
            columnID = SecondaryTableColumnID.Trackers.leechers
        } else if descriptor.keyPath == \TorrentTracker.downloadCount {
            columnID = SecondaryTableColumnID.Trackers.downloads
        } else if descriptor.keyPath == \TorrentTracker.announce {
            columnID = SecondaryTableColumnID.Trackers.tracker
        } else {
            return nil
        }
        return SecondaryTableSortPreference(
            columnID: columnID,
            direction: SecondaryTableSortDirection(descriptor.order)
        )
    }
}

private enum TrackerEditorMode {
    case add(owner: TrackerEditorOwner)
    case edit(owner: TrackerEditorOwner)

    var owner: TrackerEditorOwner {
        switch self {
        case .add(let owner), .edit(let owner):
            owner
        }
    }

    var requiresTracker: Bool {
        if case .edit = self { return true }
        return false
    }
}
