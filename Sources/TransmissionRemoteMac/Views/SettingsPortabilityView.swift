// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct SettingsPortabilityFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw SettingsPortabilityError.malformedDocument
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SettingsPortabilityView: View {
    nonisolated private static let maximumImportBytes = 8 * 1_024 * 1_024

    @ObservedObject var coordinator: SettingsPortabilityCoordinator

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var exportDocument: SettingsPortabilityFileDocument?
    @State private var importTask: Task<Void, Never>?
    @State private var importID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Portable Settings")
                        .font(.title2.weight(.semibold))
                    Text("Export a redacted settings file, or review an import before anything is written. Custom country database URLs are omitted because they may contain private access tokens.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Export Settings…", action: beginExport)
                Button("Import Settings…") {
                    importTask?.cancel()
                    importID = nil
                    coordinator.cancelImport()
                    isImporting = true
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            if let preview = coordinator.preview {
                importPreview(preview)
            } else {
                ContentUnavailableView(
                    "No Import Preview",
                    systemImage: "doc.badge.arrow.up",
                    description: Text(
                        "Import reads and validates the file first. Confirm is the only action that writes settings."
                    )
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let message = coordinator.message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let errorMessage = coordinator.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                prepareImport(from: url)
            case .failure(let error):
                coordinator.present(error: error)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "Transmission Remote Mac Settings"
        ) { result in
            if case .failure(let error) = result {
                coordinator.present(error: error)
            }
            exportDocument = nil
        }
        .onDisappear {
            importTask?.cancel()
        }
    }

    private func importPreview(_ preview: SettingsImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import Preview")
                        .font(.headline)
                    Text(preview.sourceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "Update profiles with matching UUIDs",
                    isOn: Binding(
                        get: { coordinator.collisionPolicy == .updateMatchingIdentifier },
                        set: {
                            coordinator.collisionPolicy = $0
                                ? .updateMatchingIdentifier
                                : .skipExisting
                        }
                    )
                )
                .toggleStyle(.switch)
                .help("Off by default. Existing profile UUIDs are skipped unless this is enabled.")
            }

            Text(collisionPolicyExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    previewSection("Profiles") {
                        previewRows(preview)
                    }

                    previewSection("Application Settings") {
                        switch preview.plan.applicationPreferences {
                        case .apply:
                            Label(
                                "Polling, behavior, date display, shortcuts, intake, watch-folder, workspace, and table preferences will be updated.",
                                systemImage: "checkmark.circle"
                            )
                        case .skipUnchanged:
                            Label("Application settings are unchanged.", systemImage: "equal.circle")
                                .foregroundStyle(.secondary)
                        }
                    }

                    let watchFolder = preview.document.applicationPreferences.watchFolder
                    if watchFolder.requiresSourceFolderSelection
                        || watchFolder.requiresProcessedFolderSelection {
                        previewSection("Watch Folder") {
                            Label(
                                "Imported watch-folder automation stays disabled. Reselect local folders before enabling it.",
                                systemImage: "folder.badge.questionmark"
                            )
                        }
                    }

                    if !preview.credentialNotices.isEmpty {
                        previewSection("Re-entry Required") {
                            ForEach(preview.credentialNotices) { notice in
                                Label(
                                    "\(notice.profileName): \(notice.kind.title)",
                                    systemImage: notice.kind == .clientIdentity
                                        ? "person.badge.key"
                                        : "key"
                                )
                            }
                            Text("No credential, private key, Keychain reference, or identity binding is imported.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button("Cancel") {
                    coordinator.cancelImport()
                }
                Spacer()
                Button("Confirm Import") {
                    do {
                        try coordinator.confirmImport()
                    } catch {
                        coordinator.present(error: error)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func previewRows(_ preview: SettingsImportPreview) -> some View {
        if preview.plan.profileAdditions.isEmpty,
           preview.plan.profileUpdates.isEmpty,
           preview.plan.profileSkips.isEmpty {
            Text("No profiles in this file.")
                .foregroundStyle(.secondary)
        }
        ForEach(preview.plan.profileAdditions, id: \.id) { profile in
            previewRow("Add", profile.name, systemImage: "plus.circle")
        }
        ForEach(preview.plan.profileUpdates, id: \.id) { profile in
            previewRow("Update", profile.name, systemImage: "arrow.triangle.2.circlepath.circle")
        }
        ForEach(preview.plan.profileSkips, id: \.profileID) { skip in
            previewRow(
                "Skip",
                profileName(skip.profileID, in: preview.document),
                detail: skipReason(skip.reason),
                systemImage: "minus.circle"
            )
            .foregroundStyle(.secondary)
        }
    }

    private func previewRow(
        _ action: String,
        _ name: String,
        detail: String? = nil,
        systemImage: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(action, systemImage: systemImage)
                .frame(width: 90, alignment: .leading)
            Text(name)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func previewSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var collisionPolicyExplanation: String {
        switch coordinator.collisionPolicy {
        case .skipExisting:
            "Safe default: matching UUIDs are left untouched; only non-conflicting new profiles are added."
        case .updateMatchingIdentifier:
            "Matching UUIDs may be updated. Name swaps are checked against the complete final profile set."
        }
    }

    private func profileName(_ id: UUID, in document: SettingsPortabilityDocument) -> String {
        document.profiles.first { $0.id == id }?.name ?? id.uuidString
    }

    private func skipReason(_ reason: SettingsProfileImportSkipReason) -> String {
        switch reason {
        case .unchanged:
            "Unchanged"
        case .identifierCollision:
            "Matching UUID exists"
        case .nameCollision:
            "Name conflicts with the final profile set"
        }
    }

    private func beginExport() {
        do {
            coordinator.clearStatus()
            exportDocument = SettingsPortabilityFileDocument(
                data: try coordinator.exportData()
            )
            isExporting = true
        } catch {
            coordinator.present(error: error)
        }
    }

    private func prepareImport(from url: URL) {
        importTask?.cancel()
        coordinator.cancelImport()
        let nextImportID = UUID()
        importID = nextImportID
        let sourceName = url.lastPathComponent
        let hasSecurityScope = url.startAccessingSecurityScopedResource()
        importTask = Task { @MainActor in
            let result = await Task.detached {
                do {
                    let data = try DarwinRaceResistantFileCleanup().readRegularFile(
                        at: url,
                        maximumBytes: Self.maximumImportBytes
                    ).data
                    return SettingsImportLoadResult.loaded(
                        try SettingsPortabilityService.decodeAndValidate(data)
                    )
                } catch {
                    return SettingsImportLoadResult.failed(error.localizedDescription)
                }
            }.value
            if hasSecurityScope {
                url.stopAccessingSecurityScopedResource()
            }
            guard !Task.isCancelled, importID == nextImportID else { return }
            importTask = nil
            switch result {
            case .loaded(let document):
                do {
                    try coordinator.prepareImport(document, sourceName: sourceName)
                } catch {
                    coordinator.present(error: error)
                }
            case .failed(let message):
                coordinator.present(errorMessage: message)
            }
        }
    }
}

private enum SettingsImportLoadResult: Sendable {
    case loaded(SettingsPortabilityDocument)
    case failed(String)
}
