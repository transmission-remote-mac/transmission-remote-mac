// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI

struct DaemonSessionView: View {
    @ObservedObject var optionsController: DaemonOptionsSettingsController
    var sessionInfo: SessionInfo?
    var sessionStats: SessionStats?
    var isApplyingOptions = false
    var isTestingPort = false
    var isUpdatingBlocklist = false
    var maintenanceNotice: DaemonMaintenanceNotice?
    var onApplyOptions: (DaemonOptionsUpdate) async -> DaemonOptionsApplyResult = {
        _ in .rejected(.notConnected)
    }
    var onTestPort: (PortTestIPProtocol) -> Void = { _ in }
    var onUpdateBlocklist: () -> Void = {}
    var onDismissMaintenanceNotice: () -> Void = {}

    @State private var selectedPortTestProtocol: PortTestIPProtocol = .automatic

    var body: some View {
        Group {
            if let sessionInfo {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(for: sessionInfo)
                        statistics
                        options(for: sessionInfo.daemonOptions, capabilities: sessionInfo.capabilities)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "No Daemon Session",
                    systemImage: "bolt.horizontal.circle",
                    description: Text("Connect to a Transmission server to inspect daemon options and statistics.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .textSelection(.enabled)
        .onChange(of: sessionInfo) {
            if sessionInfo?.capabilities.hasProtocolSpecificPortTest != true {
                selectedPortTestProtocol = .automatic
            }
        }
    }

    private func header(for sessionInfo: SessionInfo) -> some View {
        GroupBox {
            DetailGrid(rows: [
                .init("Version", sessionInfo.version),
                .init("RPC version", "\(sessionInfo.rpcVersion)"),
                .init("Download folder", sessionInfo.downloadDir)
            ])
        } label: {
            Label("Session", systemImage: "antenna.radiowaves.left.and.right")
                .font(.headline)
        }
    }

    @ViewBuilder
    private var statistics: some View {
        if let sessionStats {
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    DetailGrid(rows: [
                        .init("Torrents", "\(sessionStats.torrentCount)"),
                        .init("Active", "\(sessionStats.activeTorrentCount)"),
                        .init("Paused", "\(sessionStats.pausedTorrentCount)"),
                        .init("Down speed", ByteCountFormatters.speed(sessionStats.downloadSpeed)),
                        .init("Up speed", ByteCountFormatters.speed(sessionStats.uploadSpeed))
                    ])

                    Divider()

                    StatsGrid(stats: sessionStats)
                }
            } label: {
                Label("Statistics", systemImage: "chart.bar")
                    .font(.headline)
            }
        } else {
            GroupBox {
                Text("Statistics are unavailable for this daemon or have not refreshed yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                Label("Statistics", systemImage: "chart.bar")
                    .font(.headline)
            }
        }
    }

    private func options(for options: DaemonOptions, capabilities: SessionCapabilities) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 14) {
                if let optionsDraftBinding = optionsDraftBinding(fallback: options) {
                    DaemonOptionsEditor(
                        draft: optionsDraftBinding,
                        capabilities: capabilities,
                        validationIssues: optionValidationIssues(capabilities: capabilities)
                    )
                    .disabled(isApplyingOptions || optionsController.isSubmitting)
                    maintenanceControls(options: options, capabilities: capabilities)
                } else {
                    Text("Daemon options have not refreshed yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                DetailGrid(rows: readOnlyRows(options: options, capabilities: capabilities))

                optionsFooter(capabilities: capabilities)
            }
        } label: {
            Label("Daemon Options", systemImage: "slider.horizontal.3")
                .font(.headline)
        }
    }

    private func readOnlyRows(options: DaemonOptions, capabilities: SessionCapabilities) -> [DetailGridRow] {
        var rows: [DetailGridRow] = []

        rows.append(contentsOf: [
            .init("Encryption", options.encryption?.rawValue.capitalized),
            .init("Port forwarding", Self.boolean(options.portForwardingEnabled)),
            .init("Peer port", options.peerPort.map(String.init)),
            .init("PEX", Self.boolean(options.pexEnabled)),
            .init("DHT", Self.boolean(options.dhtEnabled))
        ])

        if capabilities.hasModernSpeedKeys {
            rows.append(contentsOf: [
                .init("Blocklist", Self.boolean(options.blocklistEnabled)),
                .init("Seed ratio", Self.limitedValue(options.seedRatioLimited, options.seedRatioLimit))
            ])
            if capabilities.hasBlocklistURL {
                rows.append(.init("Blocklist URL", options.blocklistURL))
            }
        }

        if capabilities.hasIncompleteDirectory {
            rows.append(.init("Incomplete folder", Self.limitedValue(options.incompleteDirectoryEnabled, options.incompleteDirectory)))
        }

        return rows
    }

    private var hasOptionChanges: Bool {
        guard let sessionInfo else { return false }
        return optionsController.hasChanges(capabilities: sessionInfo.capabilities)
    }

    private func optionsDraftBinding(fallback options: DaemonOptions) -> Binding<DaemonOptionsDraft>? {
        if optionsController.draft == nil {
            return nil
        }

        return Binding(
            get: {
                optionsController.draft ?? DaemonOptionsDraft(options: options)
            },
            set: { nextDraft in
                optionsController.updateDraft(nextDraft)
            }
        )
    }

    private func optionValidationIssues(capabilities: SessionCapabilities) -> [String] {
        optionsController.validationIssues(capabilities: capabilities)
    }

    private func optionsFooter(capabilities: SessionCapabilities) -> some View {
        let validationIssues = optionValidationIssues(capabilities: capabilities)
        let update = optionsController.update(capabilities: capabilities)
        let maintenanceBusy = isTestingPort || isUpdatingBlocklist
        let applyBusy = isApplyingOptions || optionsController.isSubmitting
        let canApply = update != nil && validationIssues.isEmpty && !applyBusy && !maintenanceBusy

        return HStack {
            Text(optionsStatusText(validationIssues: validationIssues))
                .font(.caption)
                .foregroundStyle(optionsStatusColor(validationIssues: validationIssues))

            Spacer()

            Button("Revert") {
                optionsController.reset(with: sessionInfo)
            }
            .disabled(!hasOptionChanges || applyBusy || maintenanceBusy)

            Button(applyBusy ? "Applying…" : "Apply") {
                guard let update else { return }
                guard let submission = optionsController.beginSubmission() else { return }
                Task { @MainActor in
                    let result = await onApplyOptions(update)
                    optionsController.completeSubmission(submission, with: result)
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
        }
    }

    private func optionsStatusText(validationIssues: [String]) -> String {
        if let validationIssue = validationIssues.first {
            return validationIssue
        }
        if isApplyingOptions || optionsController.isSubmitting {
            return "Applying daemon options…"
        }
        if let result = optionsController.lastApplyResult {
            return result.message
        }
        if hasOptionChanges {
            return "Unsaved daemon option changes."
        }
        return "Editable speed and queue options match the daemon."
    }

    private func optionsStatusColor(validationIssues: [String]) -> Color {
        if !validationIssues.isEmpty || optionsController.lastApplyResult?.isFailure == true {
            return .red
        }
        if optionsController.lastApplyResult == .succeeded {
            return .green
        }
        return .secondary
    }

    @ViewBuilder
    private func maintenanceControls(
        options: DaemonOptions,
        capabilities: SessionCapabilities
    ) -> some View {
        if capabilities.hasPortTest || capabilities.hasBlocklistUpdate {
            Divider()

            VStack(alignment: .leading, spacing: 12) {
                Text("Daemon Maintenance")
                    .font(.headline)

                if capabilities.hasPortTest {
                    HStack(spacing: 10) {
                        if capabilities.hasProtocolSpecificPortTest {
                            Picker("Protocol", selection: $selectedPortTestProtocol) {
                                Text("Automatic").tag(PortTestIPProtocol.automatic)
                                Text("IPv4").tag(PortTestIPProtocol.ipv4)
                                Text("IPv6").tag(PortTestIPProtocol.ipv6)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 270)
                        }

                        Button {
                            onTestPort(selectedPortTestProtocol)
                        } label: {
                            if isTestingPort {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Testing…")
                                }
                            } else {
                                Text("Test Port")
                            }
                        }
                        .disabled(
                            isApplyingOptions
                                || optionsController.isSubmitting
                                || isTestingPort
                                || isUpdatingBlocklist
                        )

                        Text(appliedPortDescription(options.peerPort))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Spacer()
                    }
                }

                if capabilities.hasBlocklistUpdate {
                    HStack(spacing: 10) {
                        Button {
                            onUpdateBlocklist()
                        } label: {
                            if isUpdatingBlocklist {
                                HStack(spacing: 6) {
                                    ProgressView()
                                        .controlSize(.small)
                                    Text("Updating…")
                                }
                            } else {
                                Text("Update Blocklist")
                            }
                        }
                        .disabled(
                            options.blocklistEnabled != true
                                || isApplyingOptions
                                || optionsController.isSubmitting
                                || isTestingPort
                                || isUpdatingBlocklist
                        )

                        Text(
                            options.blocklistEnabled == true
                                ? "Downloads and applies the daemon's configured blocklist."
                                : "Enable and apply the blocklist before updating it."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Spacer()
                    }
                }

                if let maintenanceNotice {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: maintenanceNotice.isFailure ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(maintenanceNotice.isFailure ? Color.red : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(maintenanceNotice.title)
                                .font(.caption.weight(.semibold))
                            Text(maintenanceNotice.message)
                                .font(.caption)
                        }
                        Spacer()
                        Button("Dismiss") {
                            onDismissMaintenanceNotice()
                        }
                        .buttonStyle(.link)
                    }
                }
            }
        }
    }

    private func appliedPortDescription(_ peerPort: Int?) -> String {
        guard let peerPort else { return "Tests the daemon's currently applied port." }
        return "Tests currently applied port \(peerPort). Unsaved edits are not included."
    }

    private static func boolean(_ value: Bool?) -> String? {
        value.map { $0 ? "On" : "Off" }
    }

    private static func limitedValue<T>(_ isEnabled: Bool?, _ value: T?) -> String? {
        guard let isEnabled else { return value.map { "\($0)" } }
        guard isEnabled else { return "Off" }
        return value.map { "\($0)" } ?? "On"
    }
}

private struct DaemonOptionsEditor: View {
    @Binding var draft: DaemonOptionsDraft
    var capabilities: SessionCapabilities
    var validationIssues: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            optionSection("General") {
                TextOptionRow(title: "Download folder", text: $draft.downloadDirectory)

                Picker("Encryption", selection: $draft.encryption) {
                    ForEach(SessionEncryption.allCases, id: \.self) { encryption in
                        Text(encryption.displayName)
                            .tag(encryption)
                    }
                }
                .frame(maxWidth: 360, alignment: .leading)

                Toggle("Port forwarding", isOn: $draft.portForwardingEnabled)
            }

            optionSection("Speed Limits") {
                LimitRow(
                    title: "Download",
                    isEnabled: $draft.downloadSpeedLimitEnabled,
                    value: $draft.downloadSpeedLimitKBps
                )

                LimitRow(
                    title: "Upload",
                    isEnabled: $draft.uploadSpeedLimitEnabled,
                    value: $draft.uploadSpeedLimitKBps
                )
            }

            optionSection("Peers and Network") {
                PeerPortRow(
                    peerPort: $draft.peerPort,
                    randomOnStart: $draft.peerPortRandomOnStart,
                    supportsRandomPort: capabilities.hasModernSpeedKeys
                )

                if capabilities.hasModernSpeedKeys {
                    NumericOptionRow(title: "Global peer limit", text: $draft.peerLimitGlobal)
                    NumericOptionRow(title: "Per-torrent peer limit", text: $draft.peerLimitPerTorrent)
                } else {
                    NumericOptionRow(title: "Peer limit", text: $draft.legacyPeerLimit)
                }

                Toggle("PEX", isOn: $draft.pexEnabled)

                if capabilities.hasModernSpeedKeys {
                    Toggle("DHT", isOn: $draft.dhtEnabled)
                }

                if capabilities.hasLPD {
                    Toggle("LPD", isOn: $draft.lpdEnabled)
                }

                if capabilities.hasUTP {
                    Toggle("uTP", isOn: $draft.utpEnabled)
                }
            }

            if capabilities.hasModernSpeedKeys {
                optionSection("Seeding") {
                    ToggleNumberRow(
                        title: "Seed ratio",
                        isEnabled: $draft.seedRatioLimited,
                        value: $draft.seedRatioLimit,
                        suffix: "ratio"
                    )

                    if capabilities.hasSeedIdle {
                        ToggleNumberRow(
                            title: "Idle seed limit",
                            isEnabled: $draft.idleSeedingLimitEnabled,
                            value: $draft.idleSeedingLimitMinutes,
                            suffix: "minutes"
                        )
                    }
                }
            }

            if capabilities.hasIncompleteDirectory || capabilities.hasRenamePartialFiles {
                optionSection("Folders") {
                    if capabilities.hasIncompleteDirectory {
                        ToggleTextRow(
                            title: "Incomplete folder",
                            isEnabled: $draft.incompleteDirectoryEnabled,
                            text: $draft.incompleteDirectory
                        )
                    }

                    if capabilities.hasRenamePartialFiles {
                        Toggle("Rename partial files", isOn: $draft.renamePartialFiles)
                    }
                }
            }

            if capabilities.hasModernSpeedKeys {
                optionSection("Blocklist") {
                    Toggle("Enable blocklist", isOn: $draft.blocklistEnabled)
                    if capabilities.hasBlocklistURL {
                        TextOptionRow(title: "Blocklist URL", text: $draft.blocklistURL)
                            .disabled(!draft.blocklistEnabled)
                    }
                }
            }

            if capabilities.hasCacheSize {
                optionSection("Disk Cache") {
                    NumericOptionRow(title: "Cache MB", text: $draft.cacheSizeMB)
                }
            }

            if capabilities.hasModernSpeedKeys {
                optionSection("Alternate Speed") {
                    Toggle("Enable alternate speed", isOn: $draft.alternateSpeedEnabled)

                    NumericOptionRow(title: "Download KB/s", text: $draft.alternateSpeedDownKBps)
                    NumericOptionRow(title: "Upload KB/s", text: $draft.alternateSpeedUpKBps)

                    if capabilities.hasAlternateSpeedSchedule {
                        Toggle("Schedule alternate speed", isOn: $draft.alternateSpeedTimeEnabled)

                        if draft.alternateSpeedTimeEnabled {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("Schedule")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 150, alignment: .leading)

                                TimeField(
                                    text: $draft.alternateSpeedTimeBegin,
                                    accessibilityLabel: "Alternate speed start time"
                                )
                                Text("to")
                                    .foregroundStyle(.secondary)
                                TimeField(
                                    text: $draft.alternateSpeedTimeEnd,
                                    accessibilityLabel: "Alternate speed end time"
                                )

                                Spacer()
                            }

                            WeekdayToggleRow(
                                sunday: $draft.alternateSpeedSunday,
                                monday: $draft.alternateSpeedMonday,
                                tuesday: $draft.alternateSpeedTuesday,
                                wednesday: $draft.alternateSpeedWednesday,
                                thursday: $draft.alternateSpeedThursday,
                                friday: $draft.alternateSpeedFriday,
                                saturday: $draft.alternateSpeedSaturday
                            )
                        }
                    }
                }
            }

            if capabilities.hasQueueControls {
                optionSection("Queue") {
                    ToggleNumberRow(
                        title: "Download queue",
                        isEnabled: $draft.downloadQueueEnabled,
                        value: $draft.downloadQueueSize,
                        suffix: "torrents"
                    )

                    ToggleNumberRow(
                        title: "Seed queue",
                        isEnabled: $draft.seedQueueEnabled,
                        value: $draft.seedQueueSize,
                        suffix: "torrents"
                    )

                    ToggleNumberRow(
                        title: "Stalled queue",
                        isEnabled: $draft.queueStalledEnabled,
                        value: $draft.queueStalledMinutes,
                        suffix: "minutes"
                    )
                }
            }

            if !validationIssues.isEmpty {
                Text(validationIssues.joined(separator: " "))
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private func optionSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)

            content()
        }
    }
}

private struct LimitRow: View {
    var title: String
    @Binding var isEnabled: Bool
    @Binding var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(title, isOn: $isEnabled)
                .frame(width: 150, alignment: .leading)

            NumericField(text: $value, accessibilityLabel: title)
                .disabled(!isEnabled)

            Text("KB/s")
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

private struct ToggleNumberRow: View {
    var title: String
    @Binding var isEnabled: Bool
    @Binding var value: String
    var suffix: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(title, isOn: $isEnabled)
                .frame(width: 150, alignment: .leading)

            NumericField(text: $value, accessibilityLabel: title)
                .disabled(!isEnabled)

            Text(suffix)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

private struct NumericOptionRow: View {
    var title: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            NumericField(text: $text, accessibilityLabel: title)

            Spacer()
        }
    }
}

private struct TextOptionRow: View {
    var title: String
    @Binding var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .accessibilityLabel(title)

            Spacer()
        }
    }
}

private struct ToggleTextRow: View {
    var title: String
    @Binding var isEnabled: Bool
    @Binding var text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle(title, isOn: $isEnabled)
                .frame(width: 150, alignment: .leading)

            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .disabled(!isEnabled)
                .accessibilityLabel(title)

            Spacer()
        }
    }
}

private struct PeerPortRow: View {
    @Binding var peerPort: String
    @Binding var randomOnStart: Bool
    var supportsRandomPort: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Peer port")
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            NumericField(text: $peerPort, accessibilityLabel: "Peer port")
                .disabled(supportsRandomPort && randomOnStart)

            if supportsRandomPort {
                Toggle("Randomize on start", isOn: $randomOnStart)
            }

            Spacer()
        }
    }
}

private struct NumericField: View {
    @Binding var text: String
    var accessibilityLabel: String

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 90)
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct TimeField: View {
    @Binding var text: String
    var accessibilityLabel: String

    var body: some View {
        TextField("HH:MM", text: $text)
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .frame(width: 72)
            .accessibilityLabel(accessibilityLabel)
    }
}

private struct WeekdayToggleRow: View {
    @Binding var sunday: Bool
    @Binding var monday: Bool
    @Binding var tuesday: Bool
    @Binding var wednesday: Bool
    @Binding var thursday: Bool
    @Binding var friday: Bool
    @Binding var saturday: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("Days")
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)

            Toggle("Sun", isOn: $sunday)
            Toggle("Mon", isOn: $monday)
            Toggle("Tue", isOn: $tuesday)
            Toggle("Wed", isOn: $wednesday)
            Toggle("Thu", isOn: $thursday)
            Toggle("Fri", isOn: $friday)
            Toggle("Sat", isOn: $saturday)

            Spacer()
        }
        .toggleStyle(.checkbox)
    }
}

private struct StatsGrid: View {
    var stats: SessionStats

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                Text("")
                Text("Current")
                    .fontWeight(.semibold)
                Text("Total")
                    .fontWeight(.semibold)
            }

            GridRow {
                Text("Downloaded")
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatters.transferSize(stats.current.downloadedBytes))
                Text(ByteCountFormatters.transferSize(stats.cumulative.downloadedBytes))
            }
            GridRow {
                Text("Uploaded")
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatters.transferSize(stats.current.uploadedBytes))
                Text(ByteCountFormatters.transferSize(stats.cumulative.uploadedBytes))
            }
            GridRow {
                Text("Files added")
                    .foregroundStyle(.secondary)
                Text("\(stats.current.filesAdded)")
                Text("\(stats.cumulative.filesAdded)")
            }
            GridRow {
                Text("Sessions")
                    .foregroundStyle(.secondary)
                Text("\(stats.current.sessionCount)")
                Text("\(stats.cumulative.sessionCount)")
            }
            GridRow {
                Text("Active time")
                    .foregroundStyle(.secondary)
                Text(DurationFormatters.elapsed(stats.current.secondsActive))
                Text(DurationFormatters.elapsed(stats.cumulative.secondsActive))
            }
        }
    }
}

private struct DetailGrid: View {
    var rows: [DetailGridRow]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(.secondary)
                        .frame(width: 130, alignment: .leading)

                    Text(row.displayValue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailGridRow: Identifiable {
    var id: String { label }
    var label: String
    var value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var displayValue: String {
        guard let value, !value.isEmpty else { return "—" }
        return value
    }
}

private extension SessionEncryption {
    var displayName: String {
        switch self {
        case .tolerated: "Allow encryption"
        case .preferred: "Prefer encryption"
        case .required: "Require encryption"
        }
    }
}
