// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation
import SwiftUI

struct TorrentPeersView: View {
    var state: TorrentDetailLoadState
    var isActive: Bool
    @ObservedObject var peerResolutionPreferencesStore: PeerResolutionPreferencesStore
    @ObservedObject var columnCustomizationController:
        TableColumnCustomizationPersistenceController<TorrentPeer>

    @AppStorage(SecondaryTablePreferenceKeys.peerLayout) private var persistedLayout = ""
    @AppStorage(SecondaryTablePreferenceKeys.peerSort) private var persistedSort = SecondaryTableDefaults.peerSort
    @State private var selectedPeerIDs = Set<TorrentPeer.ID>()
    @State private var sortedPeers: [TorrentPeer] = []
    @State private var sortOrder = TorrentPeerTableSorting.descriptors(for: SecondaryTableDefaults.peerSort)
    @State private var appliedSortPreference = SecondaryTableDefaults.peerSort
    @State private var projectionIdentity: TorrentPeersProjectionIdentity?
    @StateObject private var projectionCache =
        SecondaryTableProjectionCache<TorrentPeersProjectionIdentity, [TorrentPeer]>()
    @FocusState private var peersOwnFocus: Bool

    var body: some View {
        if let detail = state.detail {
            if detail.peers.isEmpty {
                ContentUnavailableView("No Peers", systemImage: "person.2.slash")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Text(selectedPeerIDs.count == 1 ? "1 peer selected" : "\(selectedPeerIDs.count) peers selected")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()

                        SecondaryTableColumnMenu(
                            title: "Peer Columns",
                            table: .peers,
                            customization: columnCustomizationController.binding(hidingColumnIDs: hiddenColumnIDs),
                            layoutPreference: peerLayoutBinding,
                            columns: [
                                .init(id: SecondaryTableColumnID.Peers.host, title: "Host", isRequired: true),
                                .init(id: SecondaryTableColumnID.Peers.port, title: "Port"),
                                .init(id: SecondaryTableColumnID.Peers.country, title: "Country"),
                                .init(id: SecondaryTableColumnID.Peers.client, title: "Client"),
                                .init(id: SecondaryTableColumnID.Peers.flags, title: "Flags"),
                                .init(id: SecondaryTableColumnID.Peers.progress, title: "Have"),
                                .init(id: SecondaryTableColumnID.Peers.upload, title: "Up speed"),
                                .init(id: SecondaryTableColumnID.Peers.download, title: "Down speed")
                            ].filter { !hiddenColumnIDs.contains($0.id) },
                            restoreDefaultColumns: columnCustomizationController.reset,
                            restoreDefaultSort: {
                                persistedSort = SecondaryTableDefaults.peerSort
                                synchronizeProjection()
                            }
                        )
                    }
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)

                    Divider()

                    Table(
                        displayedPeers(detail: detail),
                        selection: $selectedPeerIDs,
                        sortOrder: peerSortBinding(),
                        columnCustomization: columnCustomizationController.binding(hidingColumnIDs: hiddenColumnIDs)
                    ) {
                        TableColumn("Host", value: \.displayHost) { peer in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(TorrentDetailFormatters.placeholder(peer.displayHost))
                                if peer.resolvedHostName != nil {
                                    Text(peer.host)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .help(peer.resolvedHostName == nil ? peer.host : "Raw address: \(peer.host)")
                        }
                        .width(min: 140, ideal: 210)
                        .customizationID(SecondaryTableColumnID.Peers.host)
                        .defaultVisibility(.visible)
                        .disabledCustomizationBehavior(.visibility)

                        TableColumn("Port", value: \.port) { peer in
                            Text(peer.port > 0 ? "\(peer.port)" : "—")
                                .monospacedDigit()
                        }
                        .width(min: 60, ideal: 70)
                        .customizationID(SecondaryTableColumnID.Peers.port)
                        .defaultVisibility(.hidden)

                        TableColumn("Country", value: \.countryDisplay) { peer in
                            Text(TorrentDetailFormatters.placeholder(peer.countryDisplay))
                        }
                        .width(min: 80, ideal: 100)
                        .customizationID(SecondaryTableColumnID.Peers.country)
                        .defaultVisibility(.visible)
                        .disabledCustomizationBehavior(
                            peerResolutionPreferencesStore.preferences.resolveCountries ? [] : .visibility
                        )

                        TableColumn("Client", value: \.clientName) { peer in
                            Text(TorrentDetailFormatters.placeholder(peer.clientName))
                        }
                        .width(min: 130, ideal: 190)
                        .customizationID(SecondaryTableColumnID.Peers.client)
                        .defaultVisibility(.visible)

                        TableColumn("Flags", value: \.flags) { peer in
                            Text(TorrentDetailFormatters.placeholder(peer.flags))
                                .monospaced()
                        }
                        .width(min: 60, ideal: 70)
                        .customizationID(SecondaryTableColumnID.Peers.flags)
                        .defaultVisibility(.visible)

                        TableColumn("Have", value: \.progress) { peer in
                            Text(TorrentDetailFormatters.percent(peer.progress))
                                .monospacedDigit()
                        }
                        .width(min: 65, ideal: 70)
                        .customizationID(SecondaryTableColumnID.Peers.progress)
                        .defaultVisibility(.visible)

                        TableColumn("Up speed", value: \.rateToPeer) { peer in
                            Text(ByteCountFormatters.speed(peer.rateToPeer, zeroValue: ""))
                                .monospacedDigit()
                        }
                        .width(min: 80, ideal: 90)
                        .customizationID(SecondaryTableColumnID.Peers.upload)
                        .defaultVisibility(.visible)

                        TableColumn("Down speed", value: \.rateToClient) { peer in
                            Text(ByteCountFormatters.speed(peer.rateToClient, zeroValue: ""))
                                .monospacedDigit()
                        }
                        .width(min: 80, ideal: 90)
                        .customizationID(SecondaryTableColumnID.Peers.download)
                        .defaultVisibility(.visible)
                    }
                    .id(columnCustomizationController.replacementRevision)
                    .focusable()
                    .focused($peersOwnFocus)
                    .focusedValue(\.torrentTableCommandsActive, false)
                    .onKeyPress("a", phases: .down) { keyPress in
                        guard keyPress.modifiers == .command,
                              let selection = SecondaryTableFocusedSelectionAction.selectAll(
                                  isActive: isActive,
                                  ownsFocus: peersOwnFocus,
                                  ownsCurrentProjection: hasCurrentPeerProjection,
                                  availableIDs: Set(sortedPeers.map(\.id))
                              ) else {
                            return .ignored
                        }
                        selectedPeerIDs = selection
                        return .handled
                    }
                    .onCopyCommand {
                        selectedPeerCopyItems()
                    }
                    .contextMenu(forSelectionType: TorrentPeer.ID.self) { selection in
                        Button(selection.count == 1 ? "Copy Peer" : "Copy \(selection.count) Peers") {
                            selectedPeerIDs = selection
                            copyPeers(in: selection)
                        }
                        .disabled(selection.isEmpty)
                    }
                }
                .onAppear {
                    synchronizePeerColumnLayout()
                    synchronizeProjection()
                }
                .onChange(of: detail.peersSnapshotRevision) {
                    synchronizeProjection()
                }
                .onChange(of: persistedSort) {
                    synchronizeProjection()
                }
                .onChange(of: columnCustomizationController.customization) {
                    synchronizePeerColumnLayout()
                }
                .onChange(of: isActive) {
                    if !isActive {
                        peersOwnFocus = false
                    }
                }
            }
        } else {
            TorrentDetailStateUnavailableView(state: state, title: "Peer details")
        }
    }

    private var hiddenColumnIDs: Set<String> {
        peerResolutionPreferencesStore.preferences.resolveCountries
            ? [] : [SecondaryTableColumnID.Peers.country]
    }

    private func synchronizeProjection() {
        let preference = persistedSort.normalized(
            allowedColumnIDs: SecondaryTableColumnID.Peers.all,
            default: SecondaryTableDefaults.peerSort
        )
        synchronizePeerLayoutSort(preference)
        guard let detail = state.detail,
              let detailIdentity = TorrentPeersProjectionIdentity(detail: detail) else {
            clearPeerProjection()
            return
        }
        guard projectionIdentity != detailIdentity
                || appliedSortPreference != preference else {
            sortOrder = TorrentPeerTableSorting.descriptors(for: preference)
            return
        }
        sortOrder = TorrentPeerTableSorting.descriptors(for: preference)
        appliedSortPreference = preference
        sortedPeers = projectionCache.value(for: detailIdentity, sort: preference) {
            SecondaryTableSorting.peers(detail.peers, by: preference)
        }
        selectedPeerIDs.formIntersection(detail.peers.map(\.id))
        projectionIdentity = detailIdentity
    }

    private func displayedPeers(detail: TorrentDetail) -> [TorrentPeer] {
        guard let identity = TorrentPeersProjectionIdentity(detail: detail) else { return [] }
        let preference = persistedSort.normalized(
            allowedColumnIDs: SecondaryTableColumnID.Peers.all,
            default: SecondaryTableDefaults.peerSort
        )
        return projectionCache.value(for: identity, sort: preference) {
            SecondaryTableSorting.peers(detail.peers, by: preference)
        }
    }

    private func peerSortBinding() -> Binding<[KeyPathComparator<TorrentPeer>]> {
        Binding(
            get: { sortOrder },
            set: { newValue in
                guard let sourceDetail = state.detail,
                      let sourceIdentity = TorrentPeersProjectionIdentity(detail: sourceDetail),
                      TorrentPeersProjectionCommitGuard.canCommit(
                          expectedIdentity: sourceIdentity,
                          projectionOwnerIdentity: projectionIdentity,
                          currentIdentity: state.detail.flatMap { TorrentPeersProjectionIdentity(detail: $0) }
                      ) else {
                    clearPeerProjection()
                    return
                }
                let preference = TorrentPeerTableSorting.preference(for: newValue)
                    ?? SecondaryTableDefaults.peerSort
                let projectedRows = projectionCache.value(for: sourceIdentity, sort: preference) {
                    SecondaryTableSorting.peers(sourceDetail.peers, by: preference)
                }
                guard TorrentPeersProjectionCommitGuard.canCommit(
                    expectedIdentity: sourceIdentity,
                    projectionOwnerIdentity: projectionIdentity,
                    currentIdentity: state.detail.flatMap { TorrentPeersProjectionIdentity(detail: $0) }
                ) else {
                    clearPeerProjection()
                    return
                }
                sortOrder = TorrentPeerTableSorting.descriptors(for: preference)
                persistedSort = preference
                synchronizePeerLayoutSort(preference)
                appliedSortPreference = preference
                sortedPeers = projectedRows
                selectedPeerIDs.formIntersection(projectedRows.map(\.id))
                projectionIdentity = sourceIdentity
            }
        )
    }

    private var peerLayoutBinding: Binding<SecondaryTableLayoutPreference> {
        Binding(
            get: {
                SecondaryTableLayoutPreference.restored(from: persistedLayout, for: .peers)
            },
            set: { preference in
                storePeerLayout(preference)
            }
        )
    }

    private func synchronizePeerColumnLayout() {
        var preference = SecondaryTableLayoutPreference.restored(from: persistedLayout, for: .peers)
        for columnID in SecondaryTableColumnID.Peers.all {
            let visibility = columnCustomizationController.customization[
                visibility: columnID
            ]
            let isVisible = visibility == .visible
                || (visibility != .hidden && !SecondaryTableKind.peers.defaultHiddenColumnIDs.contains(columnID))
            preference = preference.settingColumnVisibility(
                isVisible,
                columnID: columnID,
                for: .peers
            )
        }
        storePeerLayout(preference.settingSort(persistedSort, for: .peers))
    }

    private func synchronizePeerLayoutSort(_ preference: SecondaryTableSortPreference) {
        let layout = SecondaryTableLayoutPreference
            .restored(from: persistedLayout, for: .peers)
            .settingSort(preference, for: .peers)
        storePeerLayout(layout)
    }

    private func storePeerLayout(_ preference: SecondaryTableLayoutPreference) {
        let rawValue = preference.normalized(for: .peers).rawValue
        if persistedLayout != rawValue {
            persistedLayout = rawValue
        }
    }

    private var hasCurrentPeerProjection: Bool {
        projectionIdentity?.matches(detail: state.detail) == true
    }

    private func clearPeerProjection() {
        sortedPeers.removeAll()
        selectedPeerIDs.removeAll()
        projectionIdentity = nil
    }

    private func selectedPeerCopyItems() -> [NSItemProvider] {
        guard SecondaryTableFocusedSelectionAction.canCopy(
            isActive: isActive,
            ownsFocus: peersOwnFocus,
            ownsCurrentProjection: hasCurrentPeerProjection,
            selectedCount: selectedPeerIDs.count
        ), let text = peerCopyText(in: selectedPeerIDs) else {
            return []
        }
        return [NSItemProvider(object: text as NSString)]
    }

    private func copyPeers(in selection: Set<TorrentPeer.ID>) {
        guard let text = peerCopyText(in: selection) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func peerCopyText(in selection: Set<TorrentPeer.ID>) -> String? {
        guard hasCurrentPeerProjection else { return nil }
        let rows = sortedPeers.filter { selection.contains($0.id) }
        guard !rows.isEmpty else { return nil }
        return rows.map { peer in
            let endpoint = peer.port > 0 ? "\(peer.host):\(peer.port)" : peer.host
            return "\(endpoint)\t\(peer.clientName)\t↓ \(ByteCountFormatters.speed(peer.rateToClient))\t↑ \(ByteCountFormatters.speed(peer.rateToPeer))"
        }.joined(separator: "\n")
    }
}

private enum TorrentPeerTableSorting {
    static func descriptors(
        for preference: SecondaryTableSortPreference
    ) -> [KeyPathComparator<TorrentPeer>] {
        let order = preference.direction.sortOrder
        switch preference.columnID {
        case SecondaryTableColumnID.Peers.port:
            return [KeyPathComparator(\TorrentPeer.port, order: order)]
        case SecondaryTableColumnID.Peers.country:
            return [KeyPathComparator(\TorrentPeer.countryDisplay, order: order)]
        case SecondaryTableColumnID.Peers.client:
            return [KeyPathComparator(\TorrentPeer.clientName, order: order)]
        case SecondaryTableColumnID.Peers.flags:
            return [KeyPathComparator(\TorrentPeer.flags, order: order)]
        case SecondaryTableColumnID.Peers.progress:
            return [KeyPathComparator(\TorrentPeer.progress, order: order)]
        case SecondaryTableColumnID.Peers.upload:
            return [KeyPathComparator(\TorrentPeer.rateToPeer, order: order)]
        case SecondaryTableColumnID.Peers.download:
            return [KeyPathComparator(\TorrentPeer.rateToClient, order: order)]
        default:
            return [KeyPathComparator(\TorrentPeer.displayHost, order: order)]
        }
    }

    static func preference(
        for descriptors: [KeyPathComparator<TorrentPeer>]
    ) -> SecondaryTableSortPreference? {
        guard let descriptor = descriptors.first else { return nil }
        let columnID: String
        if descriptor.keyPath == \TorrentPeer.port {
            columnID = SecondaryTableColumnID.Peers.port
        } else if descriptor.keyPath == \TorrentPeer.countryDisplay {
            columnID = SecondaryTableColumnID.Peers.country
        } else if descriptor.keyPath == \TorrentPeer.clientName {
            columnID = SecondaryTableColumnID.Peers.client
        } else if descriptor.keyPath == \TorrentPeer.flags {
            columnID = SecondaryTableColumnID.Peers.flags
        } else if descriptor.keyPath == \TorrentPeer.progress {
            columnID = SecondaryTableColumnID.Peers.progress
        } else if descriptor.keyPath == \TorrentPeer.rateToPeer {
            columnID = SecondaryTableColumnID.Peers.upload
        } else if descriptor.keyPath == \TorrentPeer.rateToClient {
            columnID = SecondaryTableColumnID.Peers.download
        } else if descriptor.keyPath == \TorrentPeer.displayHost {
            columnID = SecondaryTableColumnID.Peers.host
        } else {
            return nil
        }
        return SecondaryTableSortPreference(
            columnID: columnID,
            direction: SecondaryTableSortDirection(descriptor.order)
        )
    }
}
