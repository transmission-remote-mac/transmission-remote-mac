// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI

struct TorrentTableView: View {
    @ObservedObject var store: AppStore
    @ObservedObject private var interactionPreferencesStore: ApplicationInteractionPreferencesStore
    @ObservedObject private var tableColumnCustomizationController:
        TableColumnCustomizationPersistenceController<TorrentSummary>
    var onProjectionChange: ((Set<TorrentTableColumnID>, TorrentTableColumnID) -> Void)?

    @AppStorage(TorrentTableColumnPreferenceKeys.sort) private var persistedSort = TorrentTableDefaults.sort

    init(
        store: AppStore,
        interactionPreferencesStore: ApplicationInteractionPreferencesStore,
        tableColumnCustomizationController: TableColumnCustomizationPersistenceController<TorrentSummary>,
        onProjectionChange: ((Set<TorrentTableColumnID>, TorrentTableColumnID) -> Void)? = nil
    ) {
        self.store = store
        _interactionPreferencesStore = ObservedObject(wrappedValue: interactionPreferencesStore)
        _tableColumnCustomizationController = ObservedObject(
            wrappedValue: tableColumnCustomizationController
        )
        self.onProjectionChange = onProjectionChange
    }

    var body: some View {
        Table(
            store.visibleTorrents,
            selection: $store.selectedTorrentIDs,
            sortOrder: sortOrderBinding,
            columnCustomization: tableColumnCustomizationController.binding
        ) {
            torrentColumns
        }
        .background(TableColumnResizePolicyBridge(widthsByTitle: Dictionary(uniqueKeysWithValues:
            TorrentTableColumnID.allCases.compactMap { column in
                tableColumnCustomizationController.columnWidths[column.rawValue].map { (column.title, $0) }
            }
        )))
        .id(tableColumnCustomizationController.replacementRevision)
        .accessibilityLabel("Torrents")
        .focusedValue(\.torrentTableCommandsActive, true)
        .onCopyCommand {
            guard let text = TorrentSelectionCopyText.make(
                visibleTorrents: store.visibleTorrents,
                selectedIDs: store.selectedTorrentIDs
            ) else {
                return []
            }

            return [NSItemProvider(object: text as NSString)]
        }
        .contextMenu(forSelectionType: TorrentSummary.ID.self) { selection in
            Button("Start") {
                store.selectedTorrentIDs = selection
                Task { await store.startSelected() }
            }
            .disabled(!store.canStartTorrents(in: selection))

            Button("Start Now") {
                store.selectedTorrentIDs = selection
                Task { await store.startSelectedNow() }
            }
            .disabled(!store.canStartNowTorrents(in: selection))

            Button("Stop") {
                store.selectedTorrentIDs = selection
                Task { await store.stopSelected() }
            }
            .disabled(!store.canStopTorrents(in: selection))

            Button("Verify") {
                store.selectedTorrentIDs = selection
                store.requestVerifySelected()
            }
            .disabled(!store.canVerifyTorrents(in: selection))

            Button("Reannounce") {
                store.selectedTorrentIDs = selection
                Task { await store.reannounceSelected() }
            }
            .disabled(!store.canReannounceTorrents(in: selection))

            Button(selection.count == 1 ? "Copy Magnet Link" : "Copy Magnet Links") {
                Task { await store.copyMagnetLinks(in: selection) }
            }
            .disabled(!store.canCopyMagnetLinks(in: selection))

            Divider()

            Menu("Queue") {
                Button("Move to Top") {
                    store.selectedTorrentIDs = selection
                    Task { await store.queueMoveSelectedTop() }
                }
                Button("Move Up") {
                    store.selectedTorrentIDs = selection
                    Task { await store.queueMoveSelectedUp() }
                }
                Button("Move Down") {
                    store.selectedTorrentIDs = selection
                    Task { await store.queueMoveSelectedDown() }
                }
                Button("Move to Bottom") {
                    store.selectedTorrentIDs = selection
                    Task { await store.queueMoveSelectedBottom() }
                }
            }
            .disabled(!store.canQueueTorrents(in: selection))

            Menu("Bandwidth Priority") {
                Button("High") {
                    store.selectedTorrentIDs = selection
                    Task { await store.setSelectedBandwidthPriority(.high) }
                }
                Button("Normal") {
                    store.selectedTorrentIDs = selection
                    Task { await store.setSelectedBandwidthPriority(.normal) }
                }
                Button("Low") {
                    store.selectedTorrentIDs = selection
                    Task { await store.setSelectedBandwidthPriority(.low) }
                }
            }
            .disabled(!store.canSetBandwidthPriorityForTorrents(in: selection))

            Divider()

            Button("Set Location…") {
                store.selectedTorrentIDs = selection
                store.requestSetSelectedLocation()
            }
            .disabled(!store.canSetTorrentLocation(in: selection))

            Button("Move Data…") {
                store.selectedTorrentIDs = selection
                store.requestMoveSelectedData()
            }
            .disabled(!store.canSetTorrentLocation(in: selection))

            Button("Rename…") {
                store.selectedTorrentIDs = selection
                store.requestRenameSelectedTorrent()
            }
            .disabled(!store.canRenameTorrent(in: selection))

            Divider()

            Button("Properties…") {
                store.selectedTorrentIDs = selection
                Task { await store.requestEditSelectedTorrentProperties() }
            }
            .disabled(!store.canEditTorrentProperties(in: selection))

            Divider()

            Button("Copy Local Path") {
                store.selectedTorrentIDs = selection
                store.copySelectedLocalPath()
            }
            .disabled(selection.isEmpty)

            Button("Reveal in Finder") {
                store.selectedTorrentIDs = selection
                store.revealSelectedInFinder()
            }
            .disabled(selection.isEmpty)

            Button("Open Local Path") {
                store.selectedTorrentIDs = selection
                store.openSelectedLocalPath()
            }
            .disabled(selection.isEmpty)

            Divider()

            Button("Remove…", role: .destructive) {
                store.requestRemoveTorrents(in: selection)
            }
            .disabled(!store.canRemoveTorrents(in: selection))

            Button("Remove and Delete Data…", role: .destructive) {
                store.requestRemoveTorrents(in: selection, deleteLocalData: true)
            }
            .disabled(!store.canDeleteTorrentData(in: selection))
        } primaryAction: { selection in
            Task { await store.performPrimaryTorrentAction(in: selection) }
        }
        .onAppear {
            synchronizePersistedSort()
            publishProjection()
        }
        .onChange(of: persistedSort) {
            synchronizePersistedSort()
            publishProjection()
        }
        .onChange(of: tableColumnCustomizationController.customization) {
            publishProjection()
        }
    }

    @TableColumnBuilder<TorrentSummary, KeyPathComparator<TorrentSummary>>
    private var torrentColumns: some TableColumnContent<TorrentSummary, KeyPathComparator<TorrentSummary>> {
        Group {
            TableColumn("Name", value: \TorrentSummary.name) { torrent in
                Text(torrent.name)
                    .lineLimit(1)
                    .help(torrent.name)
                    .accessibilityLabel(Text("Name, \(torrent.name)"))
            }
            .width(min: 220, ideal: 560)
            .customizationID(TorrentTableColumnID.name.rawValue)
            .defaultVisibility(.visible)
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Size", value: \TorrentSummary.displaySize) { torrent in
                TorrentTableNumericCell(
                    text: TorrentTableFormatters.size(torrent.displaySize),
                    accessibilityLabel: "Size"
                )
            }
            .width(min: 64, ideal: 88)
            .customizationID(TorrentTableColumnID.size.rawValue)
            .defaultVisibility(.visible)

            TableColumn("Done", value: \TorrentSummary.percentDone) { torrent in
                HStack(spacing: 6) {
                    ProgressView(value: torrent.percentDone)
                        .frame(minWidth: 24)
                    Text(torrent.progressTitle)
                        .monospacedDigit()
                }
                .help(torrent.progressTitle)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Done")
                .accessibilityValue(torrent.progressTitle)
            }
            .width(min: 64, ideal: 86)
            .customizationID(TorrentTableColumnID.done.rawValue)
            .defaultVisibility(.visible)

            TableColumn("Status", value: \TorrentSummary.status.rawValue) { torrent in
                Text(torrent.status.title)
                    .lineLimit(1)
                    .foregroundStyle(torrent.errorString.isEmpty ? Color.primary : Color.red)
                    .help(torrent.errorString.isEmpty ? torrent.status.title : torrent.errorString)
                    .accessibilityLabel("Status")
                    .accessibilityValue(
                        torrent.errorString.isEmpty
                            ? torrent.status.title
                            : "\(torrent.status.title). Error: \(torrent.errorString)"
                    )
            }
            .width(min: 80, ideal: 100)
            .customizationID(TorrentTableColumnID.status.rawValue)
            .defaultVisibility(.visible)
        }

        Group {
            TableColumn("Seeds", value: \TorrentSummary.seedsConnected) { torrent in
                TorrentTableNumericCell(
                    text: TorrentTableFormatters.shortPeerCount(
                        connected: torrent.seedsConnected,
                        total: torrent.seedsTotal
                    ),
                    accessibilityLabel: "Seeds",
                    help: torrent.seedsDisplay
                )
            }
            .width(min: 54, ideal: 70)
            .customizationID(TorrentTableColumnID.seeds.rawValue)
            .defaultVisibility(.visible)

            TableColumn("Peers", value: \TorrentSummary.peersConnected) { torrent in
                TorrentTableNumericCell(
                    text: TorrentTableFormatters.shortPeerCount(
                        connected: torrent.peersConnected,
                        total: torrent.peersTotal
                    ),
                    accessibilityLabel: "Peers",
                    help: torrent.peersDisplay
                )
            }
            .width(min: 54, ideal: 70)
            .customizationID(TorrentTableColumnID.peers.rawValue)
            .defaultVisibility(.visible)

            TableColumn("Down speed", value: \TorrentSummary.rateDownload) { torrent in
                TorrentTableNumericCell(
                    text: TorrentTableFormatters.speed(torrent.rateDownload),
                    accessibilityLabel: "Download speed"
                )
            }
            .width(min: 72, ideal: 88)
            .customizationID(TorrentTableColumnID.downloadSpeed.rawValue)
            .defaultVisibility(.visible)

            TableColumn("Up speed", value: \TorrentSummary.rateUpload) { torrent in
                TorrentTableNumericCell(
                    text: TorrentTableFormatters.speed(torrent.rateUpload),
                    accessibilityLabel: "Upload speed"
                )
            }
            .width(min: 64, ideal: 88)
            .customizationID(TorrentTableColumnID.uploadSpeed.rawValue)
            .defaultVisibility(.visible)
        }

        Group {
            TableColumn("ETA", value: \TorrentSummary.eta) { torrent in
                TorrentTableNumericCell(
                    text: DurationFormatters.eta(torrent.eta),
                    accessibilityLabel: "Estimated time remaining"
                )
            }
            .width(min: 52, ideal: 76)
            .customizationID(TorrentTableColumnID.eta.rawValue)
            .defaultVisibility(.visible)
        }

        Group {
            TableColumn("Ratio", value: \TorrentSummary.uploadRatio) { torrent in
                TorrentTableNumericCell(
                    text: TorrentTableFormatters.ratio(torrent.uploadRatio),
                    accessibilityLabel: "Ratio"
                )
            }
            .width(min: 52, ideal: 70)
            .customizationID(TorrentTableColumnID.ratio.rawValue)
            .defaultVisibility(.visible)

            TableColumn("Downloaded", value: \TorrentSummary.downloadedEver) { torrent in
                TorrentTableNumericCell(
                    text: ByteCountFormatters.transferSize(torrent.downloadedEver),
                    accessibilityLabel: "Downloaded"
                )
            }
            .width(min: 76, ideal: 92)
            .customizationID(TorrentTableColumnID.downloaded.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Uploaded", value: \TorrentSummary.uploadedEver) { torrent in
                TorrentTableNumericCell(
                    text: ByteCountFormatters.transferSize(torrent.uploadedEver),
                    accessibilityLabel: "Uploaded"
                )
            }
            .width(min: 68, ideal: 92)
            .customizationID(TorrentTableColumnID.uploaded.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Tracker", value: \TorrentSummary.trackerHost) { torrent in
                Text(torrent.trackerHost)
                    .lineLimit(1)
                    .help(torrent.trackerHost)
                    .accessibilityLabel("Tracker, \(torrent.trackerHost)")
            }
            .width(min: 130, ideal: 220)
            .customizationID(TorrentTableColumnID.tracker.rawValue)
            .defaultVisibility(.hidden)
        }

        Group {
            TableColumn("Tracker status", value: \TorrentSummary.trackerStatusDisplay) { torrent in
                Text(torrent.trackerStatusDisplay)
                    .lineLimit(1)
                    .foregroundStyle(torrent.trackerError.isEmpty && torrent.globalError.isEmpty ? Color.primary : Color.red)
                    .help(torrent.trackerStatusDisplay)
                    .accessibilityLabel("Tracker status, \(torrent.trackerStatusDisplay)")
            }
            .width(min: 120, ideal: 190)
            .customizationID(TorrentTableColumnID.trackerStatus.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Added on", value: \TorrentSummary.addedSortDate) { torrent in
                TorrentTableDateCell(
                    title: "Added on",
                    presentation: datePresentation(for: torrent.addedDate)
                )
            }
            .width(min: 96, ideal: 140)
            .customizationID(TorrentTableColumnID.addedOn.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Completed on", value: \TorrentSummary.completedSortDate) { torrent in
                TorrentTableDateCell(
                    title: "Completed on",
                    presentation: datePresentation(for: torrent.completedDate)
                )
            }
            .width(min: 112, ideal: 140)
            .customizationID(TorrentTableColumnID.completedOn.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Last active", value: \TorrentSummary.activitySortDate) { torrent in
                TorrentTableDateCell(
                    title: "Last active",
                    presentation: datePresentation(for: torrent.activityDate)
                )
            }
            .width(min: 96, ideal: 140)
            .customizationID(TorrentTableColumnID.lastActive.rawValue)
            .defaultVisibility(.hidden)
        }

        Group {
            TableColumn("Path", value: \TorrentSummary.downloadDir) { torrent in
                Text(TorrentTableFormatters.placeholder(torrent.downloadDir))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(torrent.downloadDir)
                    .accessibilityLabel("Path, \(TorrentTableFormatters.placeholder(torrent.downloadDir))")
            }
            .width(min: 180, ideal: 300)
            .customizationID(TorrentTableColumnID.path.rawValue)
            .defaultVisibility(.hidden)
        }

        Group {
            TableColumn("Priority", value: \TorrentSummary.bandwidthPriority) { torrent in
                Text(torrent.priorityTitle)
                    .accessibilityLabel("Priority, \(torrent.priorityTitle)")
            }
            .width(min: 62, ideal: 82)
            .customizationID(TorrentTableColumnID.priority.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Size to download", value: \TorrentSummary.sizeToDownload) { torrent in
                TorrentTableNumericCell(
                    text: TorrentTableFormatters.size(torrent.sizeToDownload),
                    accessibilityLabel: "Size to download"
                )
            }
            .width(min: 96, ideal: 112)
            .customizationID(TorrentTableColumnID.sizeToDownload.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("ID", value: \TorrentSummary.id) { torrent in
                TorrentTableNumericCell(text: "\(torrent.id)", accessibilityLabel: "Torrent ID")
            }
            .width(min: 42, ideal: 62)
            .customizationID(TorrentTableColumnID.torrentID.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Queue position", value: \TorrentSummary.queuePosition) { torrent in
                TorrentTableNumericCell(
                    text: torrent.queuePositionTitle,
                    accessibilityLabel: "Queue position"
                )
            }
            .width(min: 88, ideal: 104)
            .customizationID(TorrentTableColumnID.queuePosition.rawValue)
            .defaultVisibility(.hidden)
        }

        Group {
            TableColumn("Seeding time", value: \TorrentSummary.secondsSeeding) { torrent in
                TorrentTableNumericCell(text: DurationFormatters.elapsed(torrent.secondsSeeding), accessibilityLabel: "Seeding time")
            }
            .width(min: 84, ideal: 105)
            .customizationID(TorrentTableColumnID.seedingTime.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Size left", value: \TorrentSummary.leftUntilDone) { torrent in
                TorrentTableNumericCell(
                    text: ByteCountFormatters.transferSize(torrent.leftUntilDone),
                    accessibilityLabel: "Size left"
                )
            }
            .width(min: 68, ideal: 92)
            .customizationID(TorrentTableColumnID.sizeLeft.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Private", value: \TorrentSummary.privacySortValue) { torrent in
                Text(torrent.privacyTitle)
                    .accessibilityLabel("Private, \(torrent.isPrivate ? "Yes" : "No")")
            }
            .width(min: 58, ideal: 72)
            .customizationID(TorrentTableColumnID.privateTorrent.rawValue)
            .defaultVisibility(.hidden)

            TableColumn("Labels", value: \TorrentSummary.labelsDisplay) { torrent in
                Text(TorrentTableFormatters.placeholder(torrent.labelsDisplay))
                    .lineLimit(1)
                    .help(torrent.labelsDetailDisplay)
                    .accessibilityLabel("Labels, \(torrent.labelsDetailDisplay)")
            }
            .width(min: 110, ideal: 170)
            .customizationID(TorrentTableColumnID.labels.rawValue)
            .defaultVisibility(.visible)
        }
    }

    private var sortOrderBinding: Binding<[KeyPathComparator<TorrentSummary>]> {
        Binding(
            get: { store.torrentSortOrder },
            set: { descriptors in
                let preference = TorrentTableSortMapping.preference(for: descriptors)
                    ?? TorrentTableDefaults.sort
                persistedSort = preference
                store.torrentSortOrder = TorrentTableSortMapping.descriptors(for: preference)
            }
        )
    }

    private func publishProjection() {
        onProjectionChange?(
            TorrentTableColumnVisibility.resolvedColumns(
                in: tableColumnCustomizationController.customization
            ),
            persistedSort.columnID
        )
    }

    private func synchronizePersistedSort() {
        let descriptors = TorrentTableSortMapping.descriptors(for: persistedSort)
        if store.torrentSortOrder != descriptors {
            store.torrentSortOrder = descriptors
        }
    }

    private func datePresentation(for date: Date?) -> DateDisplayPresentation? {
        guard let date else { return nil }
        return interactionPreferencesStore.dateDisplayFormattingService.presentation(
            for: date,
            relativeTo: Date(),
            preferences: interactionPreferencesStore.preferences.dateDisplay,
            context: .table
        )
    }
}

private struct TorrentTableNumericCell: View {
    var text: String
    var accessibilityLabel: String
    var help: String?

    var body: some View {
        Text(text)
            .monospacedDigit()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(help ?? text)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(text)
    }
}

private struct TorrentTableDateCell: View {
    var title: String
    var presentation: DateDisplayPresentation?

    var body: some View {
        let text = presentation?.primary ?? "—"
        Text(text)
            .monospacedDigit()
            .help(presentation?.alternate ?? text)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        guard let presentation else { return "Not available" }
        return "\(presentation.primary), alternate timestamp \(presentation.alternate)"
    }
}

struct TorrentTableColumnMenu: View {
    @ObservedObject private var tableColumnCustomizationController:
        TableColumnCustomizationPersistenceController<TorrentSummary>
    var onProjectionChange: ((Set<TorrentTableColumnID>, TorrentTableColumnID) -> Void)?

    @AppStorage(TorrentTableColumnPreferenceKeys.sort) private var persistedSort = TorrentTableDefaults.sort

    init(
        tableColumnCustomizationController: TableColumnCustomizationPersistenceController<TorrentSummary>,
        onProjectionChange: ((Set<TorrentTableColumnID>, TorrentTableColumnID) -> Void)? = nil
    ) {
        _tableColumnCustomizationController = ObservedObject(
            wrappedValue: tableColumnCustomizationController
        )
        self.onProjectionChange = onProjectionChange
    }

    var body: some View {
        Menu("Columns") {
            ForEach(TorrentTableColumnID.allCases) { columnID in
                Toggle(
                    columnID.isRequired ? "\(columnID.title) (Always Shown)" : columnID.title,
                    isOn: visibilityBinding(for: columnID)
                )
                .disabled(columnID.isRequired)
            }

            Divider()

            Button("Restore Default Columns") {
                tableColumnCustomizationController.reset()
            }

            Button("Restore Default Sort") {
                persistedSort = TorrentTableDefaults.sort
                publishProjection(sortColumn: TorrentTableDefaults.sort.columnID)
            }
        }
        .help("Show, hide, reorder, or restore torrent columns")
    }

    private func visibilityBinding(for columnID: TorrentTableColumnID) -> Binding<Bool> {
        if columnID.isRequired {
            return .constant(true)
        }
        return Binding(
            get: {
                TorrentTableColumnVisibility.isVisible(
                    columnID,
                    in: tableColumnCustomizationController.customization
                )
            },
            set: {
                var customization = tableColumnCustomizationController.customization
                customization[visibility: columnID.rawValue] = $0 ? .visible : .hidden
                tableColumnCustomizationController.update(customization)
            }
        )
    }

    private func publishProjection(sortColumn: TorrentTableColumnID? = nil) {
        onProjectionChange?(
            TorrentTableColumnVisibility.resolvedColumns(
                in: tableColumnCustomizationController.customization
            ),
            sortColumn ?? persistedSort.columnID
        )
    }
}

enum TorrentTableFormatters {
    static func speed(_ bytesPerSecond: Int64) -> String {
        ByteCountFormatters.speed(bytesPerSecond, zeroValue: "")
    }

    static func size(_ bytes: Int64) -> String {
        bytes >= 0 ? ByteCountFormatters.fileSize(bytes) : "—"
    }

    static func ratio(_ ratio: Double) -> String {
        ratio.isInfinite ? "∞" : ratio.formatted(.number.precision(.fractionLength(2)))
    }

    static func placeholder(_ value: String) -> String {
        value.isEmpty ? "—" : value
    }

    static func shortPeerCount(connected: Int, total: Int) -> String {
        total >= 0 ? "\(connected)/\(total)" : "\(connected)"
    }
}
