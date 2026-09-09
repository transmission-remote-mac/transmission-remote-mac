// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI
import UniformTypeIdentifiers

struct PeerResolutionSettingsSection: View {
    @ObservedObject var databaseController: PeerCountryDatabaseController
    @Binding var resolveHostNames: Bool
    @Binding var resolveCountries: Bool
    @Binding var showCountryFlags: Bool
    @Binding var countryDatabaseSourceURL: String
    var onClearCache: @MainActor () async -> PeerResolutionCacheClearOutcome

    @State private var showingImporter = false
    @State private var showingRemoveConfirmation = false
    @State private var isMutatingDatabase = false
    @State private var databaseMutationTask: Task<Void, Never>?
    @State private var databaseMutationOperationID: UUID?
    @State private var cacheClearTask: Task<Void, Never>?
    @State private var cacheClearOperationID: UUID?
    @State private var isClearingCache = false
    @State private var operationMessage: String?
    @State private var operationError: String?

    var body: some View {
        Section {
            Toggle("Resolve host names", isOn: $resolveHostNames)

            Toggle("Resolve countries", isOn: $resolveCountries)

            if resolveCountries {
                Toggle("Show country flags", isOn: $showCountryFlags)
            }

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Country database") {
                    Text(databaseStatusTitle)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(databaseStatusDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if databaseController.status.isInstalled, !resolveCountries {
                    Text("Country lookup is off. Turn on Resolve countries and save to show countries in Peers.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("peer-country-lookup-disabled")
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Download source")
                TextField(
                    "",
                    text: $countryDatabaseSourceURL,
                    prompt: Text("Default: latest DB-IP Country Lite CSV")
                )
                .labelsHidden()
                .accessibilityLabel("Country database download source")
                .accessibilityIdentifier("peer-country-database-source")
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .disabled(isBusy)

                Text("Leave blank to download the latest published DB-IP Country Lite database. A custom HTTPS URL must provide the same three-column CSV format, as .csv or .csv.gz.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button("Use DB-IP Default") {
                    countryDatabaseSourceURL = ""
                    operationMessage = nil
                    operationError = nil
                }
                .accessibilityIdentifier("peer-country-database-default")
                .disabled(isBusy || countryDatabaseSourceURL.isEmpty)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    databaseActionButtons
                }
                VStack(alignment: .leading, spacing: 8) {
                    databaseActionButtons
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isMutatingDatabase {
                HStack {
                    ProgressView(databaseController.downloadPhase ?? "Updating country database…")
                        .controlSize(.small)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Cancel") {
                        databaseMutationTask?.cancel()
                    }
                    .accessibilityIdentifier("peer-country-database-cancel")
                }
            }
            if isClearingCache {
                ProgressView("Clearing peer resolution cache…")
                    .controlSize(.small)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let operationMessage {
                Label(operationMessage, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = operationError ?? databaseController.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label("Peer Resolution", systemImage: "network")
        } footer: {
            Text("Databases download only when you press Download or Update, never at startup or in the background. Country lookup runs entirely against the local index; peer addresses are never sent to a country web service. Host-name lookup is opt-in and uses your Mac's configured DNS. Saved country choices stay intact while a database is unavailable. DB-IP Country Lite is offered under CC BY 4.0, with attribution in Credits.")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.commaSeparatedText, .plainText],
            allowsMultipleSelection: false
        ) { result in
            handleImport(result)
        }
        .confirmationDialog(
            "Remove the local country database?",
            isPresented: $showingRemoveConfirmation
        ) {
            Button("Remove Database", role: .destructive) {
                removeDatabase()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Country names and flags will remain inactive until another validated database is installed. Your saved country choices will be preserved.")
        }
        .background {
            SettingsWindowLifecycleBridge(onPresentation: {}, onExit: cancelOperations)
                .frame(width: 0, height: 0)
        }
        .onDisappear(perform: cancelOperations)
    }

    @ViewBuilder
    private var databaseActionButtons: some View {
        Button(databaseController.status.isInstalled ? "Update Database" : "Download Database") {
            downloadDatabase()
        }
        .accessibilityIdentifier("peer-country-database-download")
        .fixedSize()
        .disabled(isBusy || !hasValidDownloadSource)

        Button("Import File…") {
            showingImporter = true
        }
        .fixedSize()
        .disabled(isBusy)

        Button("Remove Database", role: .destructive) {
            showingRemoveConfirmation = true
        }
        .fixedSize()
        .disabled(isBusy || !databaseController.status.isInstalled)

        Button("Clear Resolution Cache") {
            clearCache()
        }
        .fixedSize()
        .disabled(isBusy)
    }

    private var isBusy: Bool {
        isMutatingDatabase || isClearingCache || databaseController.downloadPhase != nil
    }

    private var hasValidDownloadSource: Bool {
        do {
            _ = try PeerCountryDownloadSource.validatedCustomURL(countryDatabaseSourceURL)
            return true
        } catch {
            return false
        }
    }

    private var databaseStatusTitle: String {
        switch databaseController.status {
        case .loading:
            "Checking…"
        case .unavailable:
            "Not installed"
        case .installed(let metadata):
            "Installed, \(metadata.rangeCount.formatted()) ranges"
        }
    }

    private var databaseStatusDetail: String {
        switch databaseController.status {
        case .loading:
            return "Saved country choices will be applied after this check completes."
        case .unavailable:
            return "Install a database, then turn on Resolve countries and save to show countries in Peers."
        case .installed(let metadata):
            let databaseDate = metadata.databaseDate.map {
                $0.formatted(.dateTime.year().month(.wide))
            } ?? "date not identified from file name"
            return "File \(metadata.sourceFileName), database \(databaseDate), imported \(metadata.importedAt.formatted(date: .abbreviated, time: .shortened))."
        }
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        do {
            guard let sourceURL = try result.get().first else { return }
            guard !isBusy else { return }
            let operationID = beginDatabaseMutation()
            databaseMutationTask = Task { @MainActor in
                let hasSecurityScope = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if hasSecurityScope {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                    finishDatabaseMutation(operationID)
                }
                do {
                    let database = try await databaseController.importDatabase(from: sourceURL)
                    try Task.checkCancellation()
                    guard databaseMutationOperationID == operationID else { return }
                    operationMessage = "Imported \(database.metadata.rangeCount.formatted()) normalized country ranges."
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled, databaseMutationOperationID == operationID else { return }
                    operationError = error.localizedDescription
                }
            }
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                operationError = error.localizedDescription
            }
        }
    }

    private func removeDatabase() {
        guard !isBusy else { return }
        let operationID = beginDatabaseMutation()
        databaseMutationTask = Task { @MainActor in
            defer {
                finishDatabaseMutation(operationID)
            }
            do {
                try await databaseController.removeDatabase()
                try Task.checkCancellation()
                guard databaseMutationOperationID == operationID else { return }
                operationMessage = "Local country database removed."
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, databaseMutationOperationID == operationID else { return }
                operationError = error.localizedDescription
            }
        }
    }

    private func clearCache() {
        guard !isBusy else { return }
        let operationID = UUID()
        cacheClearOperationID = operationID
        isClearingCache = true
        operationMessage = nil
        operationError = nil
        cacheClearTask?.cancel()
        cacheClearTask = Task { @MainActor in
            let outcome = await onClearCache()
            guard cacheClearOperationID == operationID else { return }

            cacheClearTask = nil
            cacheClearOperationID = nil
            isClearingCache = false
            guard !Task.isCancelled, outcome.confirmsCompletion else { return }
            operationMessage = "Peer resolution cache cleared."
        }
    }

    private func downloadDatabase() {
        guard !isBusy, hasValidDownloadSource else { return }
        let customURL = countryDatabaseSourceURL
        let operationID = beginDatabaseMutation()
        databaseMutationTask = Task { @MainActor in
            defer { finishDatabaseMutation(operationID) }
            do {
                let database = try await databaseController.downloadDatabase(customURL: customURL)
                try Task.checkCancellation()
                guard databaseMutationOperationID == operationID else { return }
                operationMessage = "Installed \(database.metadata.rangeCount.formatted()) normalized country ranges."
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, databaseMutationOperationID == operationID else { return }
                operationError = error.localizedDescription
            }
        }
    }

    private func beginDatabaseMutation() -> UUID {
        let operationID = UUID()
        databaseMutationOperationID = operationID
        isMutatingDatabase = true
        operationMessage = nil
        operationError = nil
        databaseController.clearError()
        return operationID
    }

    private func finishDatabaseMutation(_ operationID: UUID) {
        guard databaseMutationOperationID == operationID else { return }
        databaseMutationOperationID = nil
        isMutatingDatabase = false
        databaseMutationTask = nil
    }

    private func cancelOperations() {
        databaseMutationOperationID = nil
        databaseMutationTask?.cancel()
        databaseMutationTask = nil
        isMutatingDatabase = false
        cacheClearOperationID = nil
        cacheClearTask?.cancel()
        cacheClearTask = nil
        isClearingCache = false
    }
}
