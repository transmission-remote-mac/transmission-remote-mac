// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    private let request: AppStore.PendingAddTorrent
    private let presentationOwnerID: UUID
    private let destinationBrowser: any MappedDestinationBrowsing
    private let initialOptions: ResolvedAddTorrentInitialOptions

    @State private var source = AddTorrentSource.remote
    @State private var sourceText = ""
    @State private var downloadDirectory = ""
    @State private var startAfterAdd = true
    @State private var peerLimitText = ""
    @State private var saveAsText = ""
    @State private var showingTorrentImporter = false
    @State private var selectedTorrentFile: URL?
    @State private var selectedTorrentSnapshot: RaceResistantRegularFileSnapshot?
    @State private var metainfoSummary: TorrentMetainfoSummary?
    @State private var metainfoFileSelections: [TorrentMetainfoFileSelection] = []
    @State private var metainfoPreviewError: String?
    @State private var fileSelectionError: String?
    @State private var validationMessage: String?
    @State private var destinationBrowserError: String?
    @State private var appliedPendingAddTorrentID: UUID?
    @State private var freeSpaceState = AddTorrentFreeSpaceViewState.hidden
    @State private var freeSpaceProbeTask: Task<Void, Never>?
    @State private var duplicateTrackerPlan: TorrentDuplicateTrackerPlan?
    @State private var isResolvingDuplicateTrackerPlan = false
    @State private var torrentFileLoadTask: Task<Void, Never>?
    @State private var torrentFileLoadID: UUID?
    @State private var destinationRecommendationState: AddTorrentDestinationRecommendationPresentationState
    @State private var destinationRecommendationTask: Task<Void, Never>?

    init(
        store: AppStore,
        request: AppStore.PendingAddTorrent,
        presentationOwnerID: UUID,
        destinationBrowser: any MappedDestinationBrowsing = MappedDestinationBrowser()
    ) {
        self.store = store
        self.request = request
        self.presentationOwnerID = presentationOwnerID
        self.destinationBrowser = destinationBrowser

        initialOptions = request.initialOptions.resolving(
            defaults: store.applicationBehaviorPreferences.addDefaults
        )
        _downloadDirectory = State(
            initialValue: request.suggestedDownloadDirectory ?? ""
        )
        _destinationRecommendationState = State(
            initialValue: AddTorrentDestinationRecommendationPresentationState(
                requestSuggestedDestination: request.suggestedDownloadDirectory
            )
        )
        _duplicateTrackerPlan = State(initialValue: request.pendingDuplicateTrackerPlan)
        _startAfterAdd = State(initialValue: initialOptions.startIntent == .start)
        switch initialOptions.peerLimit {
        case .daemonDefault:
            _peerLimitText = State(initialValue: "")
        case .limited(let peerLimit):
            _peerLimitText = State(initialValue: String(peerLimit))
        }

        switch request.source {
        case .manual:
            break
        case .remote(let sourceText):
            _source = State(initialValue: .remote)
            _sourceText = State(initialValue: sourceText)
        case .localFile:
            _source = State(initialValue: .localFile)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Torrent")
                .font(.title2.bold())

            Picker("Source", selection: $source) {
                ForEach(AddTorrentSource.allCases, id: \.self) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch source {
                case .remote:
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Info hash, magnet link, torrent URL, or daemon-visible path", text: $sourceText)
                            .textFieldStyle(.roundedBorder)

                        Text("Use a Base32/SHA-1/SHA-256 info hash, magnet:, http/https, or an absolute path visible to the daemon.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .localFile:
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Choose .torrent File…") {
                                showingTorrentImporter = true
                            }

                            if let selectedTorrentFile {
                                Text(selectedTorrentFile.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .foregroundStyle(.secondary)

                                Button("Clear") {
                                    clearSelectedFile()
                                }
                            } else {
                                Text("No file selected")
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let metainfoSummary {
                            TorrentMetainfoPreview(
                                summary: metainfoSummary,
                                fileSelections: $metainfoFileSelections
                            )
                        } else if let metainfoPreviewError {
                            Label("Preview unavailable: \(metainfoPreviewError)", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }

                        if let fileSelectionError {
                            Label(fileSelectionError, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                TextField("Download directory (optional)", text: $downloadDirectory)
                    .textFieldStyle(.roundedBorder)

                Button("Browse…") {
                    browseForDestination()
                }
                .disabled(
                    store.selectedProfile.pathMappings.isEmpty
                        || store.isAddingTorrent
                        || isResolvingDuplicateTrackerPlan
                )

                if !store.addTorrentDestinationHistory.isEmpty {
                    Menu {
                        ForEach(store.addTorrentDestinationHistory, id: \.self) { destination in
                            Button(destination) {
                                downloadDirectory = destination
                            }
                        }
                    } label: {
                        Label("Recent", systemImage: "clock.arrow.circlepath")
                    }
                    .fixedSize()
                }
            }

            HStack {
                Text("Leave blank to use the daemon default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Reset to Daemon Default") {
                    downloadDirectory = destinationRecommendationState
                        .destinationAfterResetToDaemonDefault()
                }
                .disabled(downloadDirectory.isEmpty)
            }

            destinationRecommendationView

            if let destinationBrowserError {
                Label(destinationBrowserError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let freeSpaceMessage = freeSpaceState.message {
                Label(freeSpaceMessage, systemImage: freeSpaceState.systemImage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Start after add", isOn: $startAfterAdd)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Peer limit")
                    .frame(width: 110, alignment: .leading)
                TextField("Daemon default", text: $peerLimitText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .disabled(isPostAddFlow || store.isAddingTorrent)
                Text("Optional, 1 to 999")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Save As")
                        .frame(width: 110, alignment: .leading)
                    TextField("Keep original name", text: $saveAsText)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!isSaveAsEditable || store.isAddingTorrent)
                }

                saveAsStatusView
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()

                if isPostAddFlow {
                    if case .timedOut = currentProvisionalState {
                        Button("Retry Metadata") {
                            store.retryProvisionalTorrentMetadata(
                                requestID: request.id,
                                presentationOwnerID: presentationOwnerID
                            )
                        }
                        .disabled(store.isAddingTorrent)
                    }

                    Button("Finish Without Renaming") {
                        finishWithoutRenaming()
                    }
                    .disabled(store.isAddingTorrent || isResolvingDuplicateTrackerPlan)

                    Button("Save As") {
                        Task { await renameProvisionalTorrent() }
                    }
                    .disabled(!canSubmitSaveAs || store.isAddingTorrent)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Cancel") {
                        cancel()
                    }
                    .disabled(store.isAddingTorrent || isResolvingDuplicateTrackerPlan)
                    Button("Add") {
                        Task { await addTorrent() }
                    }
                    .disabled(store.isAddingTorrent || isResolvingDuplicateTrackerPlan)
                    .keyboardShortcut(.defaultAction)
                }

                if store.isAddingTorrent || isResolvingDuplicateTrackerPlan {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .fileImporter(isPresented: $showingTorrentImporter, allowedContentTypes: [.torrentFile]) { result in
            switch result {
            case .success(let url):
                loadTorrentFile(at: url)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    fileSelectionError = error.localizedDescription
                }
            }
        }
        .alert(item: $duplicateTrackerPlan) { plan in
            Alert(
                title: Text(plan.torrentName.map { "Duplicate Torrent: \($0)" } ?? "Duplicate Torrent"),
                message: Text(plan.confirmationMessage),
                primaryButton: .default(Text("Add Missing Trackers")) {
                    resolveDuplicateTrackerPlan(plan, shouldApply: true)
                },
                secondaryButton: .cancel {
                    resolveDuplicateTrackerPlan(plan, shouldApply: false)
                }
            )
        }
        .onAppear {
            applyPendingAddTorrentIfNeeded(request)
            validationMessage = store.addTorrentOwnershipFailure(
                requestID: request.id,
                presentationOwnerID: presentationOwnerID
            )
            scheduleFreeSpaceProbe()
            scheduleDestinationRecommendation()
        }
        .onChange(of: downloadDirectory) { _, _ in
            destinationBrowserError = nil
            scheduleFreeSpaceProbe()
        }
        .onChange(of: store.canProbeAddTorrentFreeSpace) { _, _ in
            scheduleFreeSpaceProbe()
        }
        .onChange(of: store.selectedProfileID) { _, _ in
            destinationBrowserError = nil
            refreshOwnershipValidation()
            scheduleDestinationRecommendation()
        }
        .onChange(of: store.connectionState) { _, _ in
            refreshOwnershipValidation()
        }
        .onChange(of: source) { _, _ in
            saveAsText = ""
            validationMessage = nil
            scheduleDestinationRecommendation()
        }
        .onDisappear {
            freeSpaceProbeTask?.cancel()
            torrentFileLoadTask?.cancel()
            destinationRecommendationTask?.cancel()
            destinationRecommendationState.cancelEvaluation()
        }
        .interactiveDismissDisabled(
            store.isAddingTorrent || duplicateTrackerPlan != nil || isResolvingDuplicateTrackerPlan
        )
    }

    private var currentProvisionalState: ProvisionalTorrentAddState {
        let state = store.provisionalTorrentAddState
        guard let owner = state.owner else { return state }
        guard
            owner.requestID == request.id,
            owner.presentationID == presentationOwnerID
        else {
            return .idle
        }
        return state
    }

    private var isPostAddFlow: Bool {
        currentProvisionalState != .idle
    }

    private var isSaveAsEditable: Bool {
        guard store.addTorrentCapabilities.supportsSaveAs else { return false }
        switch currentProvisionalState {
        case .ready:
            return true
        case .idle:
            return true
        case .waiting, .timedOut, .duplicate, .unavailable:
            return false
        }
    }

    private var canSubmitSaveAs: Bool {
        guard case .ready = currentProvisionalState else { return false }
        return saveAsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    @ViewBuilder
    private var destinationRecommendationView: some View {
        switch destinationRecommendationState.status {
        case .idle:
            EmptyView()
        case .resolving:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Checking profile destination rules…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message):
            Label("Destination recommendation unavailable: \(message)", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .presenting(let presentation):
            VStack(alignment: .leading, spacing: 6) {
                destinationRecommendationProvenance(presentation)

                Text(presentation.destination)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)

                HStack {
                    Text("The destination changes only when you apply this recommendation.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Apply") {
                        downloadDirectory = destinationRecommendationState
                            .destinationAfterExplicitApply(
                                currentDestination: downloadDirectory
                            )
                    }
                    .disabled(downloadDirectory == presentation.destination)
                }
            }
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    @ViewBuilder
    private func destinationRecommendationProvenance(
        _ presentation: AddTorrentDestinationRecommendationPresentation
    ) -> some View {
        switch presentation {
        case .requestSuggested:
            Label("Requested destination", systemImage: "tray.and.arrow.down")
                .font(.caption.bold())
            Text("This add request supplied the destination, ahead of profile rules and defaults.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .resolved(let recommendation):
            switch recommendation.provenance {
            case .matchingRule(_, let label, let declarationIndex, let matchedFileCount, let matchedBytes):
                Label("Rule recommendation: \(label)", systemImage: "list.bullet.rectangle")
                    .font(.caption.bold())
                Text(
                    "Rule \(declarationIndex + 1) matched \(matchedFileCount) file(s), \(matchedBytes) bytes."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            case .profileDefault:
                Label("Profile default recommendation", systemImage: "folder")
                    .font(.caption.bold())
                Text("No positive file-rule match is required to use this profile default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var saveAsStatusView: some View {
        if !store.addTorrentCapabilities.supportsSaveAs {
            Label("Save As requires Transmission RPC 15 or newer.", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            switch currentProvisionalState {
            case .idle:
                if source == .localFile {
                    if let rootName = metainfoSummary?.displayName {
                        Text("Original root name: \(rootName)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Choose a readable .torrent file before setting Save As.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Optional. Magnets wait for metadata; torrent URLs and daemon paths use the name returned by Transmission.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .waiting(_, let attempt, let maximumAttempts):
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Waiting for magnet metadata, check \(attempt) of \(maximumAttempts). You can keep using the app.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            case .ready(_, let originalRootName):
                Label("Metadata ready. Original root name: \(originalRootName)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .timedOut:
                Label("Metadata did not finish in time. Retry, or finish without renaming.", systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.orange)
            case .duplicate(let name):
                Label(
                    name.map { "\($0) already exists. The existing torrent will not be renamed." }
                        ?? "This torrent already exists. The existing torrent will not be renamed.",
                    systemImage: "doc.on.doc"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            case .unavailable(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func loadTorrentFile(at url: URL) {
        torrentFileLoadTask?.cancel()
        let loadID = UUID()
        torrentFileLoadID = loadID
        fileSelectionError = nil
        metainfoPreviewError = nil
        validationMessage = nil
        selectedTorrentFile = nil
        selectedTorrentSnapshot = nil
        metainfoSummary = nil
        metainfoFileSelections = []
        scheduleDestinationRecommendation()

        let standardizedURL = url.standardizedFileURL
        let stableIdentity = request.watchFolderJob?.stableFileIdentity
        torrentFileLoadTask = Task { @MainActor in
            let result: TorrentFileLoadResult
            do {
                result = try await TorrentFilePreviewLoader().load(
                    at: url,
                    expectedStableIdentity: stableIdentity
                )
            } catch {
                return
            }
            guard !Task.isCancelled, torrentFileLoadID == loadID else { return }
            torrentFileLoadTask = nil
            switch result {
            case .loaded(let snapshot, let summary, let previewError):
                selectedTorrentFile = standardizedURL
                selectedTorrentSnapshot = snapshot
                sourceText = ""
                metainfoSummary = summary
                metainfoFileSelections = summary.map(seededFileSelections) ?? []
                metainfoPreviewError = previewError
                scheduleDestinationRecommendation()
            case .failed(let message):
                clearSelectedFile()
                fileSelectionError = message
            }
        }
    }

    @MainActor
    private func browseForDestination() {
        let profile = store.selectedProfile
        let result = destinationBrowser.browse(
            currentDaemonDestination: AddTorrentDestinationHistory.normalizedDestination(
                downloadDirectory
            ),
            mappings: profile.pathMappings
        )
        let state = MappedDestinationBrowserState(
            daemonDestination: downloadDirectory,
            errorMessage: destinationBrowserError
        ).applying(result)
        downloadDirectory = state.daemonDestination
        destinationBrowserError = state.errorMessage
    }

    private func applyPendingAddTorrentIfNeeded(_ request: AppStore.PendingAddTorrent?) {
        guard let request, appliedPendingAddTorrentID != request.id else { return }
        appliedPendingAddTorrentID = request.id

        switch request.source {
        case .manual:
            break
        case .remote(let source):
            self.source = .remote
            clearSelectedFile()
            sourceText = source
        case .localFile(let url):
            source = .localFile
            loadTorrentFile(at: url)
        }
    }

    private func clearSelectedFile() {
        torrentFileLoadTask?.cancel()
        torrentFileLoadTask = nil
        torrentFileLoadID = nil
        selectedTorrentFile = nil
        selectedTorrentSnapshot = nil
        metainfoSummary = nil
        metainfoFileSelections = []
        metainfoPreviewError = nil
        fileSelectionError = nil
        validationMessage = nil
        scheduleDestinationRecommendation()
    }

    private func seededFileSelections(
        for summary: TorrentMetainfoSummary
    ) -> [TorrentMetainfoFileSelection] {
        initialOptions.seedingFileSelections(
            TorrentMetainfoFileSelection.selections(from: summary)
        )
    }

    private func scheduleFreeSpaceProbe() {
        freeSpaceProbeTask?.cancel()

        guard
            store.addTorrentOwnershipFailure(
                requestID: request.id,
                presentationOwnerID: presentationOwnerID
            ) == nil,
            store.canProbeAddTorrentFreeSpace,
            let destination = AddTorrentDestinationHistory.normalizedDestination(downloadDirectory)
        else {
            freeSpaceState = .hidden
            return
        }

        freeSpaceState = .loading(destination)
        freeSpaceProbeTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            let result = await store.probeAddTorrentFreeSpace(path: destination)
            guard !Task.isCancelled,
                  AddTorrentDestinationHistory.normalizedDestination(downloadDirectory)
                    == destination else { return }

            switch result {
            case .available(let path, let sizeBytes):
                freeSpaceState = .available(path: path, sizeBytes: sizeBytes)
            case .failed(let path, let message):
                freeSpaceState = .failed(path: path, message: message)
            case nil:
                freeSpaceState = .hidden
            }
        }
    }

    private func scheduleDestinationRecommendation() {
        destinationRecommendationTask?.cancel()
        destinationRecommendationState.cancelEvaluation()

        let evaluationID = UUID()
        guard destinationRecommendationState.beginEvaluation(id: evaluationID) else {
            return
        }

        let files = source == .localFile ? (metainfoSummary?.files ?? []) : []
        destinationRecommendationTask = Task { @MainActor in
            let result = await store.addTorrentDestinationRecommendation(
                requestID: request.id,
                presentationOwnerID: presentationOwnerID,
                metainfoFiles: files
            )
            guard !Task.isCancelled else { return }
            guard let result else {
                destinationRecommendationState.cancelEvaluation()
                destinationRecommendationTask = nil
                return
            }
            _ = destinationRecommendationState.completeEvaluation(
                id: evaluationID,
                result: result
            )
            destinationRecommendationTask = nil
        }
    }

    private func cancel() {
        guard store.cancelPendingAddTorrent(
            requestID: request.id,
            ownerID: presentationOwnerID
        ) else {
            return
        }
        dismiss()
    }

    private func refreshOwnershipValidation() {
        if let ownershipFailure = store.addTorrentOwnershipFailure(
            requestID: request.id,
            presentationOwnerID: presentationOwnerID
        ) {
            validationMessage = ownershipFailure
        }
    }

    private func addTorrent() async {
        let directory = AddTorrentDestinationHistory.normalizedDestination(downloadDirectory)
        let startPaused = !startAfterAdd
        let peerLimit: Int?
        do {
            peerLimit = try AddTorrentPeerLimitParser.parse(peerLimitText)
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        let saveAsRequested = saveAsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        if saveAsRequested {
            do {
                _ = try AddTorrentSaveAsValidator.validateIntent(saveAsText)
            } catch {
                validationMessage = error.localizedDescription
                return
            }
        }

        switch source {
        case .remote:
            do {
                let remoteSource = try AddTorrentInputValidator.normalizedRemoteSource(sourceText)
                validationMessage = nil
                let result = await store.addTorrent(
                    requestID: request.id,
                    presentationOwnerID: presentationOwnerID,
                    source: remoteSource,
                    startPaused: startPaused,
                    downloadDirectory: directory,
                    peerLimit: peerLimit,
                    saveAsRequested: saveAsRequested
                )
                switch result {
                case .succeeded:
                    dismiss()
                case .awaitingSaveAs:
                    validationMessage = nil
                case .confirmDuplicateTrackers:
                    validationMessage = "A duplicate tracker confirmation was returned for a non-local source."
                case .failed(let message):
                    validationMessage = message
                }
            } catch {
                validationMessage = error.localizedDescription
            }
        case .localFile:
            do {
                guard let snapshot = selectedTorrentSnapshot else {
                    throw AddTorrentInputValidationError.missingLocalTorrentFile
                }
                let data = try AddTorrentInputValidator.validatedLocalTorrentData(snapshot.data)
                if saveAsRequested, metainfoSummary == nil {
                    validationMessage = "Save As requires readable torrent metadata with an original root name."
                    return
                }
                if saveAsRequested, let originalRootName = metainfoSummary?.displayName {
                    _ = try AddTorrentSaveAsValidator.validate(
                        saveAsText,
                        originalName: originalRootName
                    )
                }
                validationMessage = nil
                let result = await store.addTorrentFile(
                    requestID: request.id,
                    presentationOwnerID: presentationOwnerID,
                    data: data,
                    sourceFileURL: selectedTorrentFile,
                    sourceFileIdentity: snapshot.identity,
                    startPaused: startPaused,
                    downloadDirectory: directory,
                    fileSelection: metainfoFileSelections.isEmpty ? nil : TorrentAddFileSelection(files: metainfoFileSelections),
                    localTrackerURLs: metainfoSummary?.announceURLs ?? [],
                    peerLimit: peerLimit,
                    originalRootName: metainfoSummary?.displayName,
                    saveAsRequested: saveAsRequested
                )
                switch result {
                case .succeeded:
                    dismiss()
                case .awaitingSaveAs:
                    validationMessage = nil
                case .confirmDuplicateTrackers(let plan):
                    duplicateTrackerPlan = plan
                case .failed(let message):
                    validationMessage = message
                }
            } catch {
                validationMessage = fileSelectionError ?? error.localizedDescription
            }
        }
    }

    private func renameProvisionalTorrent() async {
        let result = await store.renameProvisionalTorrent(
            requestID: request.id,
            presentationOwnerID: presentationOwnerID,
            newName: saveAsText
        )
        switch result {
        case .succeeded:
            dismiss()
        case .awaitingSaveAs:
            break
        case .confirmDuplicateTrackers:
            validationMessage = "A duplicate torrent cannot be renamed automatically."
        case .failed(let message):
            validationMessage = message
        }
    }

    private func finishWithoutRenaming() {
        let result = store.finishProvisionalTorrentAdd(
            requestID: request.id,
            presentationOwnerID: presentationOwnerID
        )
        switch result {
        case .succeeded:
            dismiss()
        case .awaitingSaveAs:
            break
        case .confirmDuplicateTrackers(let plan):
            duplicateTrackerPlan = plan
        case .failed(let message):
            validationMessage = message
        }
    }

    private func resolveDuplicateTrackerPlan(
        _ plan: TorrentDuplicateTrackerPlan,
        shouldApply: Bool
    ) {
        let directory = AddTorrentDestinationHistory.normalizedDestination(downloadDirectory)
        duplicateTrackerPlan = nil
        isResolvingDuplicateTrackerPlan = true

        if shouldApply {
            Task { @MainActor in
                let result = await store.applyDuplicateTorrentTrackerPlan(
                    requestID: request.id,
                    presentationOwnerID: presentationOwnerID,
                    plan: plan,
                    downloadDirectory: directory
                )
                handleDuplicateTrackerResolution(result)
            }
        } else {
            let result = store.cancelDuplicateTorrentTrackerPlan(
                requestID: request.id,
                presentationOwnerID: presentationOwnerID,
                downloadDirectory: directory
            )
            handleDuplicateTrackerResolution(result)
        }
    }

    @MainActor
    private func handleDuplicateTrackerResolution(_ result: AppStore.AddTorrentSubmissionResult) {
        isResolvingDuplicateTrackerPlan = false
        switch result {
        case .succeeded:
            dismiss()
        case .awaitingSaveAs:
            validationMessage = nil
        case .confirmDuplicateTrackers(let plan):
            duplicateTrackerPlan = plan
        case .failed(let message):
            validationMessage = message
        }
    }
}

private enum AddTorrentFreeSpaceViewState: Equatable {
    case hidden
    case loading(String)
    case available(path: String, sizeBytes: Int64)
    case failed(path: String, message: String)

    var message: String? {
        switch self {
        case .hidden:
            nil
        case .loading(let path):
            "Checking free space for \(path)…"
        case .available(_, let sizeBytes):
            "Free space: \(ByteCountFormatters.fileSize(sizeBytes))"
        case .failed(_, let message):
            "Free space unavailable: \(message)"
        }
    }

    var systemImage: String {
        switch self {
        case .hidden:
            "internaldrive"
        case .loading:
            "arrow.clockwise"
        case .available:
            "internaldrive"
        case .failed:
            "exclamationmark.triangle"
        }
    }

}

private enum AddTorrentSource: CaseIterable, Hashable {
    case remote
    case localFile

    var title: String {
        switch self {
        case .remote: "URL / Magnet / Path"
        case .localFile: "Local .torrent"
        }
    }
}

private struct TorrentMetainfoPreview: View {
    var summary: TorrentMetainfoSummary
    @Binding var fileSelections: [TorrentMetainfoFileSelection]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(summary.displayName, systemImage: "doc.text")
                .font(.headline)

            HStack(spacing: 12) {
                Text(ByteCountFormatters.preciseFileSize(summary.totalSize))
                Text(fileCountText)
                Text(trackerCountText)
            }
            .foregroundStyle(.secondary)

            if let announceURL = summary.announceURL {
                Text(announceURL)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }

            if !fileSelections.isEmpty {
                Divider()
                    .padding(.vertical, 4)

                HStack {
                    Text("Files")
                        .font(.subheadline.bold())
                    Spacer()
                    Button("Select All") {
                        setAllWanted(true)
                    }
                    Button("Select None") {
                        setAllWanted(false)
                    }
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach($fileSelections) { $file in
                            TorrentMetainfoFileSelectionRow(file: $file)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var fileCountText: String {
        summary.files.count == 1 ? "1 file" : "\(summary.files.count) files"
    }

    private var trackerCountText: String {
        summary.announceURLs.count == 1 ? "1 tracker" : "\(summary.announceURLs.count) trackers"
    }

    private func setAllWanted(_ wanted: Bool) {
        for index in fileSelections.indices {
            fileSelections[index].wanted = wanted
        }
    }
}

private struct TorrentMetainfoFileSelectionRow: View {
    @Binding var file: TorrentMetainfoFileSelection

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Toggle(isOn: $file.wanted) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(ByteCountFormatters.preciseFileSize(file.length))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.checkbox)

            Spacer(minLength: 8)

            Picker("Priority", selection: $file.priority) {
                ForEach(TorrentMetainfoFilePriority.allCases) { priority in
                    Text(priority.title).tag(priority)
                }
            }
            .labelsHidden()
            .frame(width: 100)
        }
        .font(.caption)
    }
}

private extension UTType {
    static var torrentFile: UTType {
        UTType(filenameExtension: "torrent") ?? .data
    }
}
