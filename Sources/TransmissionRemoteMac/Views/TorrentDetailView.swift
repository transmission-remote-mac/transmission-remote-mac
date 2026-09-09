// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI

struct TorrentDetailView: View {
    @ObservedObject private var interactionPreferencesStore: ApplicationInteractionPreferencesStore
    private let peerResolutionPreferencesStore: PeerResolutionPreferencesStore
    private let tableColumnCustomizationWorkspaceController:
        TableColumnCustomizationWorkspaceController
    var torrent: TorrentSummary?
    var sessionStats: SessionStats?
    var requiresPieceRevalidation: Bool
    @Binding var selectedPane: TorrentDetailPane
    var canMutateFiles = false
    var setFileWanted: (Bool, [Int]) async -> Void = { _, _ in }
    var setFilePriority: (TorrentFilePriority, [Int]) async -> Void = { _, _ in }
    var canRenameFilePath = false
    var renameFilePath: (TorrentFileNode, String) async -> Void = { _, _ in }
    var fileLocalActionExecutor: TorrentFileLocalActionExecutor? = nil
    var canMutateTrackers = false
    var addTracker: (String) async -> Void = { _ in }
    var replaceTracker: (Int, String) async -> Void = { _, _ in }
    var removeTrackers: ([Int]) async -> Void = { _ in }

    init(
        interactionPreferencesStore: ApplicationInteractionPreferencesStore,
        peerResolutionPreferencesStore: PeerResolutionPreferencesStore,
        tableColumnCustomizationWorkspaceController: TableColumnCustomizationWorkspaceController,
        torrent: TorrentSummary?,
        sessionStats: SessionStats?,
        selectedPane: Binding<TorrentDetailPane>,
        requiresPieceRevalidation: Bool = false,
        canMutateFiles: Bool = false,
        setFileWanted: @escaping (Bool, [Int]) async -> Void = { _, _ in },
        setFilePriority: @escaping (TorrentFilePriority, [Int]) async -> Void = { _, _ in },
        canRenameFilePath: Bool = false,
        renameFilePath: @escaping (TorrentFileNode, String) async -> Void = { _, _ in },
        fileLocalActionExecutor: TorrentFileLocalActionExecutor? = nil,
        canMutateTrackers: Bool = false,
        addTracker: @escaping (String) async -> Void = { _ in },
        replaceTracker: @escaping (Int, String) async -> Void = { _, _ in },
        removeTrackers: @escaping ([Int]) async -> Void = { _ in }
    ) {
        _interactionPreferencesStore = ObservedObject(wrappedValue: interactionPreferencesStore)
        self.peerResolutionPreferencesStore = peerResolutionPreferencesStore
        self.tableColumnCustomizationWorkspaceController =
            tableColumnCustomizationWorkspaceController
        self.torrent = torrent
        self.sessionStats = sessionStats
        _selectedPane = selectedPane
        self.requiresPieceRevalidation = requiresPieceRevalidation
        self.canMutateFiles = canMutateFiles
        self.setFileWanted = setFileWanted
        self.setFilePriority = setFilePriority
        self.canRenameFilePath = canRenameFilePath
        self.renameFilePath = renameFilePath
        self.fileLocalActionExecutor = fileLocalActionExecutor
        self.canMutateTrackers = canMutateTrackers
        self.addTracker = addTracker
        self.replaceTracker = replaceTracker
        self.removeTrackers = removeTrackers
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let torrent, selectedPane != .statistics {
                TorrentDetailHeader(
                    name: torrent.name,
                    fullPath: torrent.fullPath,
                    status: torrent.status,
                    hasError: !torrent.errorString.isEmpty,
                    percentDone: torrent.percentDone,
                    progressTitle: torrent.progressTitle
                )
                    .equatable()
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
            }

            TabView(selection: $selectedPane) {
                Group {
                    if let torrent {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 14) {
                                TorrentPieceMapSectionView(state: TorrentPiecePresentation.state(
                                    summary: torrent,
                                    cachedInfo: torrent.detailState.detail?.generalInfo,
                                    requiresPieceRevalidation: requiresPieceRevalidation
                                ))
                                .equatable()
                                ForEach(overviewSections(for: torrent, generalInfo: torrent.detailState.detail?.generalInfo)) { section in
                                    TorrentOverviewSectionView(section: section)
                                        .equatable()
                                }
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else {
                        noTorrentSelectedView
                    }
                }
                .tabItem {
                    Label("General", systemImage: "info.circle")
                }
                .tag(TorrentDetailPane.overview)

                Group {
                    if let torrent {
                        TorrentFilesView(
                            torrentID: torrent.id,
                            state: torrent.detailState,
                            downloadDirectory: torrent.downloadDir,
                            isActive: selectedPane == .files,
                            canMutateFiles: canMutateFiles,
                            setFileWanted: setFileWanted,
                            setFilePriority: setFilePriority,
                            canRenameFilePath: canRenameFilePath,
                            renameFilePath: renameFilePath,
                            localActionExecutor: fileLocalActionExecutor,
                            columnCustomizationController:
                                tableColumnCustomizationWorkspaceController.files
                        )
                        .id(torrent.id)
                    } else {
                        noTorrentSelectedView
                    }
                }
                .tabItem {
                    Label("Files", systemImage: "folder")
                }
                .tag(TorrentDetailPane.files)

                Group {
                    if let torrent {
                        TorrentPeersView(
                            state: torrent.detailState,
                            isActive: selectedPane == .peers,
                            peerResolutionPreferencesStore: peerResolutionPreferencesStore,
                            columnCustomizationController:
                                tableColumnCustomizationWorkspaceController.peers
                        )
                        .id(torrent.id)
                    } else {
                        noTorrentSelectedView
                    }
                }
                .tabItem {
                    Label("Peers", systemImage: "person.2")
                }
                .tag(TorrentDetailPane.peers)

                Group {
                    if let torrent {
                        TorrentTrackersView(
                            state: torrent.detailState,
                            isActive: selectedPane == .trackers,
                            canMutateTrackers: canMutateTrackers,
                            addTracker: addTracker,
                            replaceTracker: replaceTracker,
                            removeTrackers: removeTrackers,
                            columnCustomizationController:
                                tableColumnCustomizationWorkspaceController.trackers
                        )
                        .id(torrent.id)
                    } else {
                        noTorrentSelectedView
                    }
                }
                .tabItem {
                    Label("Trackers", systemImage: "antenna.radiowaves.left.and.right")
                }
                .tag(TorrentDetailPane.trackers)

                GlobalStatisticsView(sessionStats: sessionStats)
                    .tabItem {
                        Label("Statistics", systemImage: "chart.bar.xaxis")
                    }
                    .tag(TorrentDetailPane.statistics)
            }
        }
        .frame(minHeight: 220)
        .textSelection(.enabled)
    }

    private var noTorrentSelectedView: some View {
        ContentUnavailableView("No Torrent Selected", systemImage: "tray")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func overviewSections(for torrent: TorrentSummary, generalInfo: TorrentGeneralInfo?) -> [TorrentOverviewSection] {
        [
            TorrentOverviewSection(
                title: "Transfer",
                systemImage: "arrow.down.arrow.up",
                columns: [
                    TorrentOverviewColumn(
                        id: "state",
                        rows: [
                            .init("Status", generalInfo?.status?.title ?? torrent.status.title),
                            .init("Downloaded", TorrentDetailFormatters.optionalSize(generalInfo?.downloadedEver)),
                            .init("Wasted", TorrentDetailFormatters.wasted(
                                bytes: generalInfo?.corruptEver,
                                pieceSize: generalInfo?.pieceSize
                            )),
                            .init("Download speed", TorrentDetailFormatters.speed(generalInfo?.rateDownload)),
                            .init("Average down", TorrentDetailFormatters.averageSpeed(
                                bytes: generalInfo?.downloadedEver,
                                seconds: generalInfo?.secondsDownloading
                            )),
                            .init("Down limit", TorrentDetailFormatters.speedLimit(generalInfo?.downloadSpeedLimit)),
                            .init("Seeds", generalInfo?.seedsDisplay ?? "—"),
                            .init("Priority", TorrentDetailFormatters.priority(generalInfo?.bandwidthPriority))
                        ]
                    ),
                    TorrentOverviewColumn(
                        id: "totals",
                        rows: [
                            .init("Uploaded", TorrentDetailFormatters.optionalSize(generalInfo?.uploadedEver)),
                            .init("Upload speed", TorrentDetailFormatters.speed(generalInfo?.rateUpload)),
                            .init("Up limit", TorrentDetailFormatters.speedLimit(generalInfo?.uploadSpeedLimit)),
                            .init("Peers", generalInfo?.peersDisplay ?? "—"),
                            .init("Max peers", TorrentDetailFormatters.count(generalInfo?.maxConnectedPeers)),
                            .init("Tracker", generalInfo?.trackerHost ?? "—"),
                            .init("Tracker status", generalInfo?.trackerStatus ?? "—"),
                            .init("Tracker update", TorrentDetailFormatters.trackerUpdate(generalInfo?.trackerUpdate))
                        ]
                    ),
                    TorrentOverviewColumn(
                        id: "remaining",
                        rows: [
                            .init("Remaining", TorrentDetailFormatters.optionalSize(generalInfo?.leftUntilDone)),
                            .init("ETA", TorrentDetailFormatters.eta(generalInfo?.eta)),
                            .init("Ratio", TorrentDetailFormatters.optionalRatio(generalInfo?.uploadRatio)),
                            .init("Downloading time", TorrentDetailFormatters.elapsed(generalInfo?.secondsDownloading)),
                            .init("Seeding time", TorrentDetailFormatters.elapsed(generalInfo?.secondsSeeding)),
                            dateRow("Last active", generalInfo?.activityDate),
                            .init("Queue position", TorrentDetailFormatters.count(generalInfo?.queuePosition)),
                            .init("Desired available", TorrentDetailFormatters.optionalSize(generalInfo?.desiredAvailable))
                        ]
                    )
                ],
                fullSpanRows: errorRows(for: torrent)
            ),
            TorrentOverviewSection(
                title: "Torrent",
                systemImage: "doc.text",
                columns: TorrentOverviewColumn.balanced(
                    rows: torrentMetadataRows(for: torrent, generalInfo: generalInfo),
                    columnCount: 3,
                    idPrefix: "torrent-metadata"
                ),
                fullSpanRows: [
                    nonEmptyLongRow(
                        "Download folder",
                        firstNonEmptyValue(generalInfo?.downloadDir, torrent.downloadDir)
                    ),
                    nonEmptyLongRow(
                        "Full path",
                        generalInfo?.fullPath(torrentName: torrent.name)
                            ?? (torrent.downloadDir.isEmpty ? nil : torrent.fullPath)
                    ),
                    nonEmptyLongRow(
                        "Hash",
                        firstNonEmptyValue(generalInfo?.hashString, torrent.hashString)
                    ),
                    nonEmptyLongRow("Magnet link", generalInfo?.magnetLink),
                    nonEmptyCommentRow(generalInfo?.comment)
                ].compactMap { $0 }
            )
        ]
    }

    private func torrentMetadataRows(
        for torrent: TorrentSummary,
        generalInfo: TorrentGeneralInfo?
    ) -> [TorrentDetailRow] {
        var rows = [TorrentDetailRow("ID", "\(torrent.id)")]
        if let isMetadataComplete = generalInfo?.isMetadataComplete
            ?? torrent.metadataPercentComplete.map({ $0 == 1 }) {
            rows.append(TorrentDetailRow(
                "Metadata",
                isMetadataComplete ? "Complete" : "Fetching metadata"
            ))
        }
        if let isPrivate = generalInfo?.isPrivate {
            rows.append(TorrentDetailRow("Privacy", isPrivate ? "Private" : "Public"))
        }
        if let labels = generalInfo?.labels, !labels.isEmpty {
            rows.append(TorrentDetailRow("Labels", labels.joined(separator: ", ")))
        }

        rows += [
            knownSizeRow("Total size", generalInfo?.totalSize ?? torrent.reportedTotalSize),
            knownSizeRow("Size to download", generalInfo?.sizeWhenDone ?? (
                torrent.metadataPercentComplete == 1 ? torrent.reportedSizeWhenDone : nil
            )),
            knownSizeRow("Done", generalInfo?.completedSize ?? torrent.reportedCompletedSize, format: ByteCountFormatters.transferSize),
            knownCountRow("Piece count", generalInfo?.pieceCount ?? torrent.pieceCount),
            knownSizeRow("Piece size", generalInfo?.pieceSize ?? torrent.pieceSize),
            knownSizeRow("Have valid", generalInfo?.haveValid ?? torrent.haveValid, format: ByteCountFormatters.transferSize),
            knownSizeRow("Have unchecked", generalInfo?.haveUnchecked ?? torrent.haveUnchecked, format: ByteCountFormatters.transferSize),
            nonEmptyRow("Creator", generalInfo?.creator),
            dateRowIfPresent("Created", generalInfo?.dateCreated),
            dateRowIfPresent("Added", generalInfo?.addedDate ?? torrent.addedDate),
            dateRowIfPresent("Completed", generalInfo?.completedDate ?? torrent.completedDate),
            dateRowIfPresent("Last active", generalInfo?.activityDate ?? torrent.activityDate)
        ].compactMap { $0 }
        return rows
    }

    private func knownSizeRow(_ label: String, _ bytes: Int64?, format: (Int64) -> String = TorrentDetailFormatters.size) -> TorrentDetailRow? {
        guard let bytes, bytes >= 0 else { return nil }
        return TorrentDetailRow(label, format(bytes))
    }

    private func knownCountRow(_ label: String, _ value: Int?) -> TorrentDetailRow? {
        guard let value, value >= 0 else { return nil }
        return TorrentDetailRow(label, "\(value)")
    }

    private func nonEmptyRow(_ label: String, _ value: String?) -> TorrentDetailRow? {
        guard let value,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return TorrentDetailRow(label, value)
    }

    private func nonEmptyLongRow(_ label: String, _ value: String?) -> TorrentDetailRow? {
        guard let row = nonEmptyRow(label, value) else { return nil }
        return TorrentDetailRow(
            row.label,
            row.value,
            isLongText: true,
            help: row.help,
            accessibilityValue: row.accessibilityValue
        )
    }

    private func nonEmptyCommentRow(_ value: String?) -> TorrentDetailRow? {
        guard let row = nonEmptyRow("Comment", value) else { return nil }
        return TorrentDetailRow(
            row.label,
            row.value,
            isLongText: true,
            help: row.help,
            accessibilityValue: row.accessibilityValue,
            linkTarget: TorrentCommentWebURL(row.value)
        )
    }

    private func firstNonEmptyValue(_ values: String?...) -> String? {
        for value in values {
            guard let value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            return value
        }
        return nil
    }

    private func dateRowIfPresent(_ label: String, _ date: Date?) -> TorrentDetailRow? {
        guard date != nil else { return nil }
        return dateRow(label, date)
    }

    private func errorRows(for torrent: TorrentSummary) -> [TorrentDetailRow] {
        var seen = Set<String>()
        return [
            ("Error", torrent.errorString),
            ("Tracker error", torrent.trackerError),
            ("Global error", torrent.globalError)
        ].compactMap { label, value in
            guard !value.isEmpty, seen.insert(value).inserted else { return nil }
            return TorrentDetailRow(label, value, isWarning: true, isLongText: true)
        }
    }

    private func dateRow(_ label: String, _ date: Date?) -> TorrentDetailRow {
        TorrentDetailRow.date(
            label,
            date,
            relativeTo: Date(),
            preferences: interactionPreferencesStore.preferences.dateDisplay,
            formatter: interactionPreferencesStore.dateDisplayFormattingService
        )
    }
}

private struct TorrentDetailHeader: View, Equatable {
    var name: String
    var fullPath: String
    var status: TorrentStatus
    var hasError: Bool
    var percentDone: Double
    var progressTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.headline)
                        .lineLimit(1)

                    Text(fullPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(status.title)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        hasError ? Color.red.opacity(0.18) : Color.secondary.opacity(0.12),
                        in: Capsule()
                    )

                Text(progressTitle)
                    .font(.headline.monospacedDigit())
            }

            ProgressView(value: percentDone)
        }
    }
}
