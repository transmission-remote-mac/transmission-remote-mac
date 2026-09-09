// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import SwiftUI
import UniformTypeIdentifiers

struct ApplicationSettingsView: View {
    var preferences: PollingPreferences

    @ObservedObject private var interactionPreferencesStore: ApplicationInteractionPreferencesStore
    @ObservedObject private var behaviorPreferencesStore: ApplicationBehaviorPreferencesStore
    @ObservedObject private var intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore
    @ObservedObject private var watchFolderPreferencesStore: WatchFolderPreferencesStore
    @ObservedObject private var workspacePreferencesStore: UIWorkspacePreferencesStore
    @ObservedObject private var peerResolutionPreferencesStore: PeerResolutionPreferencesStore
    @ObservedObject private var peerCountryDatabaseController: PeerCountryDatabaseController
    @ObservedObject private var draftSession: ApplicationSettingsDraftSession
    @State private var foregroundInterval = ""
    @State private var backgroundInterval = ""
    @State private var backgroundPolicy = BackgroundPollingPolicy.pollSlowly
    @State private var adaptiveIdleEnabled = false
    @State private var speedAveragingEnabled = false
    @State private var speedAverageSampleLimit = ""
    @State private var speedAverageWindowSeconds = ""
    @State private var completionNotificationsEnabled = true
    @State private var addStartIntent = AddTorrentStartIntent.start
    @State private var addPriority = AddTorrentDefaultPriority.normal
    @State private var addUnwantedFiles = AddTorrentUnwantedFilesDefault.daemonDefault
    @State private var addPeerLimit = ""
    @State private var promptsForDownloadOptions = true
    @State private var clipboardIntakeEnabled = false
    @State private var sourceTorrentDeletion = SourceTorrentDeletionPolicy.never
    @State private var automaticUpdateChecksEnabled = false
    @State private var automaticUpdateCadenceHours = ""
    @State private var watchFolderEnabled = false
    @State private var watchFolderSourceBookmark: Data?
    @State private var watchFolderSourceName: String?
    @State private var watchFolderRemoteDestination = ""
    @State private var watchFolderScanInterval = ""
    @State private var watchFolderSuccessPolicy = WatchFolderSuccessPolicy.keepSource
    @State private var watchFolderSubmissionPolicy =
        WatchFolderSubmissionPolicy.confirmBeforeAdding
    @State private var watchFolderProcessedBookmark: Data?
    @State private var watchFolderProcessedName: String?
    @State private var showingWatchFolderPicker = false
    @State private var watchFolderPickerTarget = WatchFolderPickerTarget.source
    @State private var showTrackerGroups = true
    @State private var showLabelGroups = true
    @State private var showDownloadFolderGroups = true
    @State private var resolvePeerHostNames = false
    @State private var resolvePeerCountries = false
    @State private var showPeerCountryFlags = false
    @State private var countryDatabaseSourceURL = ""
    @State private var dateDisplayMode = DateDisplayMode.absolute
    @State private var shortcutDrafts: [NativeCommandID: ShortcutEditorDraft] = [:]
    @State private var customizedCommandIDs: Set<NativeCommandID> = []
    @State private var persistenceError: String?
    @State private var didInitializeDraft = false

    private var onClearPeerResolutionCache: @MainActor () async -> PeerResolutionCacheClearOutcome

    private let shortcutValidationService = CommandShortcutValidationService()
    private let settingsSaveCoordinator: ApplicationSettingsSaveCoordinator

    init(
        preferences: PollingPreferences,
        interactionPreferencesStore: ApplicationInteractionPreferencesStore,
        behaviorPreferencesStore: ApplicationBehaviorPreferencesStore,
        intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore,
        watchFolderPreferencesStore: WatchFolderPreferencesStore,
        workspacePreferencesStore: UIWorkspacePreferencesStore,
        peerResolutionPreferencesStore: PeerResolutionPreferencesStore,
        peerCountryDatabaseController: PeerCountryDatabaseController,
        draftSession: ApplicationSettingsDraftSession,
        onClearPeerResolutionCache: @escaping @MainActor () async -> PeerResolutionCacheClearOutcome,
        onPersistPollingPreferences: @escaping @MainActor (PollingPreferences) -> Void,
        onApplyRuntimeSnapshot: @escaping @MainActor (PersistedApplicationSettingsSnapshot) -> Void
    ) {
        self.preferences = preferences
        _interactionPreferencesStore = ObservedObject(wrappedValue: interactionPreferencesStore)
        _behaviorPreferencesStore = ObservedObject(wrappedValue: behaviorPreferencesStore)
        _intakeAutomationPreferencesStore = ObservedObject(wrappedValue: intakeAutomationPreferencesStore)
        _watchFolderPreferencesStore = ObservedObject(wrappedValue: watchFolderPreferencesStore)
        _workspacePreferencesStore = ObservedObject(wrappedValue: workspacePreferencesStore)
        _peerResolutionPreferencesStore = ObservedObject(wrappedValue: peerResolutionPreferencesStore)
        _peerCountryDatabaseController = ObservedObject(wrappedValue: peerCountryDatabaseController)
        _draftSession = ObservedObject(wrappedValue: draftSession)
        self.onClearPeerResolutionCache = onClearPeerResolutionCache
        settingsSaveCoordinator = ApplicationSettingsSaveCoordinator(
            behaviorPreferencesStore: behaviorPreferencesStore,
            interactionPreferencesStore: interactionPreferencesStore,
            intakeAutomationPreferencesStore: intakeAutomationPreferencesStore,
            watchFolderPreferencesStore: watchFolderPreferencesStore,
            workspacePreferencesStore: workspacePreferencesStore,
            peerResolutionPreferencesStore: peerResolutionPreferencesStore,
            persistPollingPreferences: onPersistPollingPreferences,
            applyRuntimeSnapshot: onApplyRuntimeSnapshot
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                pollingSection
                speedDisplaySection
                notificationSection
                sidebarGroupsSection
                peerResolutionSection
                addTorrentDefaultsSection
                intakeAutomationSection
                watchFolderSection
                dateDisplaySection
                shortcutSection
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            SettingsWindowLifecycleBridge(
                onPresentation: draftSession.beginPresentation,
                onExit: {
                    commitDraftIfNeeded(trigger: .viewDisappeared)
                }
            )
            .frame(width: 0, height: 0)
        }
        .onAppear {
            draftSession.beginPresentation()
            initializeDraftIfNeeded()
        }
        .onDisappear {
            commitDraftIfNeeded(trigger: .viewDisappeared)
        }
        .onChange(of: preferences) { oldPreferences, _ in
            if draftSession.retainedDraft == nil,
               pollingDraftMatches(oldPreferences) {
                resetPollingDraft()
            }
        }
        .onChange(of: interactionPreferencesStore.preferences) { oldPreferences, _ in
            if draftSession.retainedDraft == nil,
               draftInteractionPreferences == oldPreferences {
                resetInteractionDraft()
            }
        }
        .onChange(of: behaviorPreferencesStore.preferences) { oldPreferences, _ in
            if draftSession.retainedDraft == nil,
               behaviorDraftMatches(oldPreferences) {
                resetBehaviorDraft()
            }
        }
        .onChange(of: intakeAutomationPreferencesStore.preferences) { oldPreferences, _ in
            if draftSession.retainedDraft == nil,
               intakeDraftMatches(oldPreferences) {
                resetIntakeAutomationDraft()
            }
        }
        .onChange(of: watchFolderPreferencesStore.snapshot) { oldSnapshot, _ in
            if draftSession.retainedDraft == nil,
               watchFolderDraftMatches(oldSnapshot.configuration) {
                resetWatchFolderDraft()
            }
        }
        .onChange(of: workspacePreferencesStore.preferences) { oldPreferences, _ in
            if draftSession.retainedDraft == nil,
               draftSidebarGroupingPreferences == oldPreferences.sidebarGrouping {
                resetSidebarGroupingDraft()
            }
        }
        .onChange(of: peerResolutionPreferencesStore.preferences) { oldPreferences, _ in
            if draftSession.retainedDraft == nil,
               draftPeerResolutionPreferences == oldPreferences {
                resetPeerResolutionDraft()
            }
        }
        .fileImporter(
            isPresented: $showingWatchFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleWatchFolderSelection(result)
        }
    }

    private var peerResolutionSection: some View {
        PeerResolutionSettingsSection(
            databaseController: peerCountryDatabaseController,
            resolveHostNames: $resolvePeerHostNames,
            resolveCountries: $resolvePeerCountries,
            showCountryFlags: $showPeerCountryFlags,
            countryDatabaseSourceURL: $countryDatabaseSourceURL,
            onClearCache: onClearPeerResolutionCache
        )
    }

    private var pollingSection: some View {
        Section {
            pollingIntervalRow(
                title: "While active",
                explanation: "Refresh torrent activity while the application window is visible.",
                value: $foregroundInterval
            )

            pollingIntervalRow(
                title: "While hidden",
                explanation: "Use a lower polling rate when the application is inactive, minimized or occluded.",
                value: $backgroundInterval
            )
            .disabled(backgroundPolicy == .suspend && !adaptiveIdleEnabled)

            Toggle("Use the slower interval while torrents are idle", isOn: $adaptiveIdleEnabled)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Background behaviour", selection: $backgroundPolicy) {
                ForEach(BackgroundPollingPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .pickerStyle(.radioGroup)
            .fixedSize(horizontal: false, vertical: true)
        } header: {
            Label("RPC Polling", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text("Idle polling applies only when nothing is transferring, checking, queued or recently mutated. Manual refresh and reconnect remain immediate.")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dateDisplaySection: some View {
        Section {
            Picker("Torrent dates", selection: $dateDisplayMode) {
                Text("Absolute date and time").tag(DateDisplayMode.absolute)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Relative time").tag(DateDisplayMode.relative)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .pickerStyle(.radioGroup)
            .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    dateDisplayExplanation.fixedSize()
                    Spacer(minLength: 0)
                    restoreDateDefaultButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    dateDisplayExplanation
                    restoreDateDefaultButton
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        } header: {
            Label("Date Display", systemImage: "calendar.badge.clock")
        }
    }

    private var speedDisplaySection: some View {
        Section {
            Toggle("Average aggregate transfer speeds", isOn: $speedAveragingEnabled)
                .fixedSize(horizontal: false, vertical: true)

            if speedAveragingEnabled {
                LabeledContent("Samples") {
                    ApplicationSettingsValueField(
                        accessibilityLabel: "Speed averaging samples",
                        text: $speedAverageSampleLimit
                    )
                }

                LabeledContent("Maximum window") {
                    ApplicationSettingsValueField(
                        accessibilityLabel: "Maximum averaging window in seconds",
                        text: $speedAverageWindowSeconds,
                        unit: "seconds"
                    )
                }
            }
        } header: {
            Label("Speed Display", systemImage: "gauge.with.dots.needle.67percent")
        } footer: {
            Text("Averages only the displayed global download and upload rates. RPC polling cadence is unchanged.")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var dateDisplayExplanation: some View {
        Text("The alternate timestamp remains available as help and accessibility text.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var restoreDateDefaultButton: some View {
        Button("Restore Date Default") {
            dateDisplayMode = DateDisplayPreferences.defaults.mode
            persistenceError = nil
        }
        .disabled(dateDisplayMode == DateDisplayPreferences.defaults.mode)
        .fixedSize()
    }

    private var notificationSection: some View {
        Section {
            Toggle("Notify when a download completes", isOn: $completionNotificationsEnabled)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Label("Notifications", systemImage: "bell")
        } footer: {
            Text("Disabling this suppresses new completion notifications without replaying them later.")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sidebarGroupsSection: some View {
        Section {
            Toggle("Trackers", isOn: $showTrackerGroups)
            Toggle("Labels", isOn: $showLabelGroups)
            Toggle("Download Folders", isOn: $showDownloadFolderGroups)
        } header: {
            Label("Sidebar Groups", systemImage: "sidebar.left")
        } footer: {
            Text("Choose which dynamic filter groups appear in the torrent sidebar. Hidden groups keep their saved workspace data and can be restored at any time.")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var addTorrentDefaultsSection: some View {
        Section {
            Toggle(
                "Prompt for download options when adding a new torrent",
                isOn: $promptsForDownloadOptions
            )
            .fixedSize(horizontal: false, vertical: true)

            Picker("Start new torrents", selection: $addStartIntent) {
                Text("Immediately").tag(AddTorrentStartIntent.start)
                Text("Paused").tag(AddTorrentStartIntent.paused)
            }
            .fixedSize(horizontal: false, vertical: true)

            Picker("File priority", selection: $addPriority) {
                Text("Low").tag(AddTorrentDefaultPriority.low)
                Text("Normal").tag(AddTorrentDefaultPriority.normal)
                Text("High").tag(AddTorrentDefaultPriority.high)
            }
            .fixedSize(horizontal: false, vertical: true)

            Picker("Files", selection: $addUnwantedFiles) {
                Text("Use daemon defaults").tag(AddTorrentUnwantedFilesDefault.daemonDefault)
                Text("Mark all unwanted when file list is known")
                    .tag(AddTorrentUnwantedFilesDefault.allUnwantedWhenFileListKnown)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

            LabeledContent("Peer limit") {
                ApplicationSettingsValueField(
                    accessibilityLabel: "New torrent peer limit",
                    text: $addPeerLimit,
                    prompt: "Daemon default",
                    fieldWidth: 110
                )
            }
        } header: {
            Label("New Torrents", systemImage: "plus.circle")
        } footer: {
            Text(
                "When prompting is disabled, already-specified torrent files and supported links submit with these saved "
                    + "choices. Toolbar Add remains interactive. Explicit incoming choices take precedence, and file "
                    + "defaults apply only when metadata supplies an explicit file list."
            )
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var intakeAutomationSection: some View {
        Section {
            Toggle(
                "Offer supported torrent links copied to the clipboard",
                isOn: $clipboardIntakeEnabled
            )
            .fixedSize(horizontal: false, vertical: true)

            Picker("Source .torrent files", selection: $sourceTorrentDeletion) {
                Text("Keep after adding").tag(SourceTorrentDeletionPolicy.never)
                Text("Delete after confirmed successful add")
                    .tag(SourceTorrentDeletionPolicy.afterSuccessfulNonDuplicateAdd)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)

            if UpdateCheckPolicyService.releaseChannelConfigured {
                Toggle(
                    "Check automatically for updates",
                    isOn: $automaticUpdateChecksEnabled
                )
                .fixedSize(horizontal: false, vertical: true)

                LabeledContent("Update cadence") {
                    ApplicationSettingsValueField(
                        accessibilityLabel: "Update cadence in hours",
                        text: $automaticUpdateCadenceHours,
                        unit: "hours"
                    )
                }
                .disabled(!automaticUpdateChecksEnabled)
            } else {
                Label(
                    "No release channel is configured in this build, so update checks remain disabled.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label("Intake and Updates", systemImage: "tray.and.arrow.down")
        } footer: {
            Text(
                "Clipboard intake is opt-in and follows the New Torrents prompt preference. It never clears the "
                    + "clipboard. Source deletion applies only to a regular local .torrent file after Transmission "
                    + "confirms a non-duplicate add."
            )
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var watchFolderFooterText: String {
        let submissionDescription = switch watchFolderSubmissionPolicy {
        case .confirmBeforeAdding:
            "Files enter the normal Add Torrent confirmation queue."
        case .submitDirectly:
            "Files are submitted using the configured daemon destination and the saved New Torrent defaults. "
                + "If those choices cannot be applied safely, the normal Add Torrent options appear."
        }
        return "This feature is opt-in. Turn it on to configure its folders, daemon destination, scan interval, and "
            + "success action. Turning it off keeps the last saved configuration for the next enable. "
            + "\(submissionDescription) Scans enqueue deterministic batches of at most 10. Folder access uses "
            + "security-scoped bookmarks and stops when disconnected, disabled, or switching servers."
    }

    private var watchFolderSection: some View {
        Section {
            Toggle("Watch a folder for .torrent files", isOn: $watchFolderEnabled)
                .fixedSize(horizontal: false, vertical: true)

            if watchFolderEnabled {
                LabeledContent("Watch folder") {
                    HStack(spacing: 8) {
                        Text(watchFolderSourceName ?? "Not selected")
                            .foregroundStyle(
                                watchFolderSourceName == nil ? Color.secondary : Color.primary
                            )
                            .fixedSize(horizontal: false, vertical: true)
                            .multilineTextAlignment(.trailing)
                        Button("Choose…") {
                            watchFolderPickerTarget = .source
                            showingWatchFolderPicker = true
                        }
                        .fixedSize()
                    }
                }

                LabeledContent("Daemon destination") {
                    TextField("", text: $watchFolderRemoteDestination, prompt: Text("/downloads"))
                        .labelsHidden()
                        .accessibilityLabel("Watch folder daemon destination")
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 160, idealWidth: 280, maxWidth: .infinity)
                }

                LabeledContent("Scan every") {
                    ApplicationSettingsValueField(
                        accessibilityLabel: "Watch folder scan interval in seconds",
                        text: $watchFolderScanInterval,
                        unit: "seconds"
                    )
                }

                Picker("When a torrent is found", selection: $watchFolderSubmissionPolicy) {
                    Text("Review Add Torrent options")
                        .tag(WatchFolderSubmissionPolicy.confirmBeforeAdding)
                    Text("Add immediately")
                        .tag(WatchFolderSubmissionPolicy.submitDirectly)
                }
                .fixedSize(horizontal: false, vertical: true)

                Picker("After a confirmed add", selection: $watchFolderSuccessPolicy) {
                    Text("Keep source file").tag(WatchFolderSuccessPolicy.keepSource)
                    Text("Move source file").tag(WatchFolderSuccessPolicy.moveSource)
                    Text("Delete source file").tag(WatchFolderSuccessPolicy.deleteSource)
                }
                .fixedSize(horizontal: false, vertical: true)

                if watchFolderSuccessPolicy == .moveSource {
                    LabeledContent("Processed-files folder") {
                        HStack(spacing: 8) {
                            Text(watchFolderProcessedName ?? "Not selected")
                                .foregroundStyle(
                                    watchFolderProcessedName == nil
                                        ? Color.secondary
                                        : Color.primary
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                .multilineTextAlignment(.trailing)
                            Button("Choose…") {
                                watchFolderPickerTarget = .processed
                                showingWatchFolderPicker = true
                            }
                            .fixedSize()
                        }
                    }
                }
            }

            if watchFolderEnabled, watchFolderSuccessPolicy == .deleteSource {
                Label(
                    "Deletion happens only after Transmission confirms a non-duplicate add.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if watchFolderPreferencesStore.processingState.failureQueue.isVisible {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        "\(watchFolderPreferencesStore.processingState.failureQueue.count) watch-folder item(s) need attention.",
                        systemImage: "exclamationmark.arrow.triangle.2.circlepath"
                    )
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                    ForEach(
                        watchFolderPreferencesStore.processingState.failureQueue.failures.prefix(5)
                    ) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.fileName)
                                .font(.caption.bold())
                                .fixedSize(horizontal: false, vertical: true)
                            Text(failure.errorMessage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Button("Retry Failed Items Now") {
                        retryWatchFolderFailures()
                    }
                }
            }
        } header: {
            Label("Watch Folder", systemImage: "folder.badge.gearshape")
        } footer: {
            Text(watchFolderFooterText)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var shortcutSection: some View {
        Section {
            ForEach(NativeCommandCatalog.current.commands, id: \.id) { command in
                shortcutRow(command)
            }

            HStack {
                Spacer()
                Button("Restore All Shortcut Defaults") {
                    restoreAllShortcutDefaults()
                }
                .disabled(customizedCommandIDs.isEmpty)
                .fixedSize()
            }
        } header: {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
        } footer: {
            Text("Printable keys require Command, Option, or Control. macOS-reserved and duplicate shortcuts cannot be applied.")
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func pollingIntervalRow(
        title: String,
        explanation: String,
        value: Binding<String>
    ) -> some View {
        LabeledContent {
            ApplicationSettingsValueField(
                accessibilityLabel: "\(title) polling interval in seconds",
                text: value,
                unit: "seconds",
                fieldWidth: 64
            )
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func shortcutRow(_ command: NativeCommandDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    shortcutLabel(command).fixedSize()
                    Spacer(minLength: 0)
                    shortcutControls(command).fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) {
                    shortcutLabel(command)
                    shortcutControls(command)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            ForEach(shortcutIssues(for: command.id), id: \.message) { issue in
                Text(issue.message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcutLabel(_ command: NativeCommandDescriptor) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(command.title)
            Text("Default: \(command.defaultShortcut.displayLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func shortcutControls(_ command: NativeCommandDescriptor) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                shortcutBindingControls(command)
                shortcutActionButtons(command)
            }
            VStack(alignment: .trailing, spacing: 8) {
                shortcutBindingControls(command)
                shortcutActionButtons(command)
            }
        }
    }

    private func shortcutBindingControls(_ command: NativeCommandDescriptor) -> some View {
        HStack(spacing: 8) {
            TextField("", text: keyEquivalentBinding(for: command), prompt: Text("Key"))
                .labelsHidden()
                .accessibilityLabel("\(command.title) shortcut key")
                .textFieldStyle(.roundedBorder)
                .frame(width: 92)

            Menu(modifierSummary(for: command.id)) {
                ForEach(NativeShortcutModifier.allCases, id: \.self) { modifier in
                    Toggle(modifier.title, isOn: modifierBinding(modifier, for: command))
                }
            }
            .accessibilityLabel("\(command.title) shortcut modifiers")
            .accessibilityValue(modifierSummary(for: command.id))
            .frame(minWidth: 148)
        }
        .fixedSize()
    }

    private func shortcutActionButtons(_ command: NativeCommandDescriptor) -> some View {
        HStack(spacing: 8) {
            Button("Clear") {
                updateShortcut(for: command) { draft in
                    draft.keyEquivalent = ""
                    draft.modifiers = []
                }
            }
            .accessibilityLabel("Clear \(command.title) shortcut")

            Button("Restore Default") {
                restoreShortcutDefault(for: command)
            }
            .accessibilityLabel("Restore \(command.title) shortcut default")
            .disabled(!customizedCommandIDs.contains(command.id))
        }
        .fixedSize()
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                footerStatus.fixedSize()
                Spacer(minLength: 0)
                footerActions
            }
            VStack(alignment: .leading, spacing: 8) {
                footerStatus
                footerActions.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footerStatus: some View {
        Text(statusText)
            .font(.caption)
            .foregroundStyle(
                validationIssues.isEmpty && persistenceError == nil ? Color.secondary : Color.red
            )
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footerActions: some View {
        HStack(spacing: 8) {
            Button("Revert") {
                draftSession.clear()
                resetDraft()
            }
            .disabled(!hasChanges)

            Button("Save Changes") {
                commitDraftIfNeeded(trigger: .explicit)
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!hasChanges || !validationIssues.isEmpty)
        }
        .fixedSize()
    }

    private var draftInteractionPreferences: ApplicationInteractionPreferences {
        let overrides: [CommandShortcutPreference] = NativeCommandCatalog.current.commands.compactMap { command in
            guard customizedCommandIDs.contains(command.id),
                  let draft = shortcutDrafts[command.id] else {
                return nil
            }
            let keyEquivalent = draft.keyEquivalent.isEmpty ? nil : draft.keyEquivalent
            let modifiers = NativeShortcutModifier.allCases
                .filter(draft.modifiers.contains)
                .map(\.rawValue)
            return CommandShortcutPreference(
                commandID: command.id,
                keyEquivalent: keyEquivalent,
                modifiers: modifiers
            )
        }
        return ApplicationInteractionPreferences(
            dateDisplay: DateDisplayPreferences(mode: dateDisplayMode),
            shortcutOverrides: overrides
        )
    }

    private var draftPeerResolutionPreferences: PeerResolutionPreferences {
        PeerResolutionPreferences(
            resolveHostNames: resolvePeerHostNames,
            resolveCountries: resolvePeerCountries,
            showCountryFlags: showPeerCountryFlags,
            countryDatabaseSourceURL: countryDatabaseSourceURL
        )
    }

    private var draftSidebarGroupingPreferences: SidebarGroupingPreferences {
        SidebarGroupingPreferences(
            showsTrackers: showTrackerGroups,
            showsLabels: showLabelGroups,
            showsDownloadFolders: showDownloadFolderGroups
        )
    }

    private var settingsDraft: ApplicationSettingsDraft {
        ApplicationSettingsDraft(
            polling: ApplicationPollingSettingsDraft(
                foregroundInterval: foregroundInterval,
                backgroundInterval: backgroundInterval,
                backgroundPolicy: backgroundPolicy,
                adaptiveIdleEnabled: adaptiveIdleEnabled
            ),
            behavior: ApplicationBehaviorSettingsDraft(
                speedAveragingEnabled: speedAveragingEnabled,
                speedAverageSampleLimit: speedAverageSampleLimit,
                speedAverageWindowSeconds: speedAverageWindowSeconds,
                completionNotificationsEnabled: completionNotificationsEnabled,
                addStartIntent: addStartIntent,
                addPriority: addPriority,
                addUnwantedFiles: addUnwantedFiles,
                addPeerLimit: addPeerLimit,
                promptsForDownloadOptions: promptsForDownloadOptions
            ),
            intake: ApplicationIntakeSettingsDraft(
                clipboardIntakeEnabled: clipboardIntakeEnabled,
                sourceTorrentDeletion: sourceTorrentDeletion,
                automaticUpdateChecksEnabled: automaticUpdateChecksEnabled,
                automaticUpdateCadenceHours: automaticUpdateCadenceHours
            ),
            watchFolder: ApplicationWatchFolderSettingsDraft(
                isEnabled: watchFolderEnabled,
                sourceBookmarkData: watchFolderSourceBookmark,
                remoteDestination: watchFolderRemoteDestination,
                scanInterval: watchFolderScanInterval,
                successPolicy: watchFolderSuccessPolicy,
                submissionPolicy: watchFolderSubmissionPolicy,
                processedFolderBookmarkData: watchFolderProcessedBookmark
            ),
            sidebarGrouping: draftSidebarGroupingPreferences,
            interaction: draftInteractionPreferences,
            peerResolution: draftPeerResolutionPreferences
        )
    }

    private var shortcutPlan: CommandShortcutImportPlan {
        shortcutValidationService.makeImportPlan(
            from: draftInteractionPreferences.shortcutOverrides
        )
    }

    private var validationIssues: [String] {
        draftEvaluation.validationIssues
    }

    private var hasChanges: Bool {
        draftEvaluation.hasChanges
    }

    private var draftEvaluation: ApplicationSettingsDraftEvaluation {
        settingsSaveCoordinator.evaluate(
            settingsDraft,
            currentPollingPreferences: preferences
        )
    }

    private var statusText: String {
        if let issue = validationIssues.first {
            return issue
        }
        if let persistenceError {
            return persistenceError
        }
        if hasChanges {
            return "Unsaved application changes."
        }
        return "Application settings are saved."
    }

    private func shortcutIssues(for commandID: NativeCommandID) -> [CommandShortcutValidationIssue] {
        shortcutPlan.issues.filter { $0.commandIDs.contains(commandID.rawValue) }
    }

    private func keyEquivalentBinding(for command: NativeCommandDescriptor) -> Binding<String> {
        Binding(
            get: { shortcutDrafts[command.id]?.keyEquivalent ?? command.defaultShortcut.keyEquivalent },
            set: { value in
                updateShortcut(for: command) { $0.keyEquivalent = value }
            }
        )
    }

    private func modifierBinding(
        _ modifier: NativeShortcutModifier,
        for command: NativeCommandDescriptor
    ) -> Binding<Bool> {
        Binding(
            get: {
                (shortcutDrafts[command.id]?.modifiers
                    ?? Set(command.defaultShortcut.modifiers)).contains(modifier)
            },
            set: { isEnabled in
                updateShortcut(for: command) { draft in
                    if isEnabled {
                        draft.modifiers.insert(modifier)
                    } else {
                        draft.modifiers.remove(modifier)
                    }
                }
            }
        )
    }

    private func modifierSummary(for commandID: NativeCommandID) -> String {
        let modifiers = shortcutDrafts[commandID]?.modifiers ?? []
        guard !modifiers.isEmpty else { return "No Modifiers" }
        return NativeShortcutModifier.allCases
            .filter(modifiers.contains)
            .map(\.symbol)
            .joined(separator: " ")
    }

    private func updateShortcut(
        for command: NativeCommandDescriptor,
        _ update: (inout ShortcutEditorDraft) -> Void
    ) {
        var draft = shortcutDrafts[command.id]
            ?? ShortcutEditorDraft(shortcut: command.defaultShortcut)
        update(&draft)
        shortcutDrafts[command.id] = draft
        customizedCommandIDs.insert(command.id)
        persistenceError = nil
    }

    private func restoreShortcutDefault(for command: NativeCommandDescriptor) {
        shortcutDrafts[command.id] = ShortcutEditorDraft(shortcut: command.defaultShortcut)
        customizedCommandIDs.remove(command.id)
        persistenceError = nil
    }

    private func restoreAllShortcutDefaults() {
        shortcutDrafts = Dictionary(
            uniqueKeysWithValues: NativeCommandCatalog.current.commands.map {
                ($0.id, ShortcutEditorDraft(shortcut: $0.defaultShortcut))
            }
        )
        customizedCommandIDs = []
        persistenceError = nil
    }

    private func commitDraftIfNeeded(trigger: ApplicationSettingsSaveTrigger) {
        let draft = settingsDraft
        if trigger == .viewDisappeared,
           !draftSession.claimAutomaticSaveAttempt(for: draft) {
            return
        }
        let result = settingsSaveCoordinator.commitIfNeeded(
            trigger: trigger,
            draft: draft,
            currentPollingPreferences: preferences
        )
        draftSession.handleSaveResult(result, retaining: draft)
        switch result {
        case .success(nil):
            persistenceError = nil
        case .success(let snapshot?):
            resetPollingDraft(snapshot.polling)
            resetBehaviorDraft()
            resetIntakeAutomationDraft()
            resetWatchFolderDraft()
            resetSidebarGroupingDraft()
            resetPeerResolutionDraft()
            resetInteractionDraft()
            persistenceError = nil
        case .failure:
            persistenceError = draftSession.saveErrorMessage
        }
    }

    private func initializeDraftIfNeeded() {
        guard !didInitializeDraft else { return }
        didInitializeDraft = true
        if let retainedDraft = draftSession.retainedDraft {
            restoreDraft(retainedDraft)
            persistenceError = draftSession.saveErrorMessage
        } else {
            resetDraft()
        }
    }

    private func pollingDraftMatches(_ pollingPreferences: PollingPreferences) -> Bool {
        foregroundInterval == String(pollingPreferences.foregroundIntervalSeconds)
            && backgroundInterval == String(pollingPreferences.backgroundIntervalSeconds)
            && backgroundPolicy == pollingPreferences.backgroundPolicy
            && adaptiveIdleEnabled == pollingPreferences.adaptiveIdleEnabled
    }

    private func behaviorDraftMatches(
        _ storedPreferences: ApplicationBehaviorPreferences
    ) -> Bool {
        speedAveragingEnabled == storedPreferences.speedAveraging.isEnabled
            && speedAverageSampleLimit == String(storedPreferences.speedAveraging.sampleLimit)
            && speedAverageWindowSeconds == String(storedPreferences.speedAveraging.windowSeconds)
            && completionNotificationsEnabled
                == storedPreferences.completionNotificationsEnabled
            && addStartIntent == storedPreferences.addDefaults.startIntent
            && addPriority == storedPreferences.addDefaults.priority
            && addUnwantedFiles == storedPreferences.addDefaults.unwantedFiles
            && addPeerLimit == (storedPreferences.addDefaults.peerLimit.map(String.init) ?? "")
            && promptsForDownloadOptions
                == storedPreferences.promptsForDownloadOptions
    }

    private func intakeDraftMatches(
        _ storedPreferences: IntakeAutomationPreferences
    ) -> Bool {
        clipboardIntakeEnabled == storedPreferences.clipboardIntake.isEnabled
            && sourceTorrentDeletion == storedPreferences.sourceTorrentDeletion
            && automaticUpdateChecksEnabled
                == storedPreferences.updateChecks.automaticChecksEnabled
            && automaticUpdateCadenceHours
                == String(storedPreferences.updateChecks.automaticCadenceHours)
    }

    private func watchFolderDraftMatches(
        _ storedConfiguration: WatchFolderConfiguration
    ) -> Bool {
        watchFolderEnabled == storedConfiguration.isEnabled
            && watchFolderSourceBookmark == storedConfiguration.sourceBookmarkData
            && watchFolderRemoteDestination == storedConfiguration.remoteDestination
            && watchFolderScanInterval == String(storedConfiguration.scanIntervalSeconds)
            && watchFolderSuccessPolicy == storedConfiguration.successPolicy
            && watchFolderSubmissionPolicy == storedConfiguration.submissionPolicy
            && watchFolderProcessedBookmark
                == storedConfiguration.processedFolderBookmarkData
    }

    private func resetDraft() {
        resetPollingDraft()
        resetBehaviorDraft()
        resetIntakeAutomationDraft()
        resetWatchFolderDraft()
        resetSidebarGroupingDraft()
        resetPeerResolutionDraft()
        resetInteractionDraft()
        persistenceError = nil
    }

    private func restoreDraft(_ draft: ApplicationSettingsDraft) {
        foregroundInterval = draft.polling.foregroundInterval
        backgroundInterval = draft.polling.backgroundInterval
        backgroundPolicy = draft.polling.backgroundPolicy
        adaptiveIdleEnabled = draft.polling.adaptiveIdleEnabled
        speedAveragingEnabled = draft.behavior.speedAveragingEnabled
        speedAverageSampleLimit = draft.behavior.speedAverageSampleLimit
        speedAverageWindowSeconds = draft.behavior.speedAverageWindowSeconds
        completionNotificationsEnabled = draft.behavior.completionNotificationsEnabled
        addStartIntent = draft.behavior.addStartIntent
        addPriority = draft.behavior.addPriority
        addUnwantedFiles = draft.behavior.addUnwantedFiles
        addPeerLimit = draft.behavior.addPeerLimit
        promptsForDownloadOptions = draft.behavior.promptsForDownloadOptions
        clipboardIntakeEnabled = draft.intake.clipboardIntakeEnabled
        sourceTorrentDeletion = draft.intake.sourceTorrentDeletion
        automaticUpdateChecksEnabled = draft.intake.automaticUpdateChecksEnabled
        automaticUpdateCadenceHours = draft.intake.automaticUpdateCadenceHours
        watchFolderEnabled = draft.watchFolder.isEnabled
        watchFolderSourceBookmark = draft.watchFolder.sourceBookmarkData
        watchFolderSourceName = WatchFolderBookmarkService.displayName(
            for: draft.watchFolder.sourceBookmarkData
        )
        watchFolderRemoteDestination = draft.watchFolder.remoteDestination
        watchFolderScanInterval = draft.watchFolder.scanInterval
        watchFolderSuccessPolicy = draft.watchFolder.successPolicy
        watchFolderSubmissionPolicy = draft.watchFolder.submissionPolicy
        watchFolderProcessedBookmark = draft.watchFolder.processedFolderBookmarkData
        watchFolderProcessedName = WatchFolderBookmarkService.displayName(
            for: draft.watchFolder.processedFolderBookmarkData
        )
        showTrackerGroups = draft.sidebarGrouping.showsTrackers
        showLabelGroups = draft.sidebarGrouping.showsLabels
        showDownloadFolderGroups = draft.sidebarGrouping.showsDownloadFolders
        resolvePeerHostNames = draft.peerResolution.resolveHostNames
        resolvePeerCountries = draft.peerResolution.resolveCountries
        showPeerCountryFlags = draft.peerResolution.showCountryFlags
        countryDatabaseSourceURL = draft.peerResolution.countryDatabaseSourceURL
        dateDisplayMode = draft.interaction.dateDisplay.mode
        let shortcutState = ApplicationShortcutDraftState.restoring(
            draft.interaction.shortcutOverrides
        )
        customizedCommandIDs = shortcutState.customizedCommandIDs
        shortcutDrafts = shortcutState.draftsByCommandID
    }

    private func resetPollingDraft() {
        resetPollingDraft(preferences)
    }

    private func resetPollingDraft(_ savedPreferences: PollingPreferences) {
        foregroundInterval = String(savedPreferences.foregroundIntervalSeconds)
        backgroundInterval = String(savedPreferences.backgroundIntervalSeconds)
        backgroundPolicy = savedPreferences.backgroundPolicy
        adaptiveIdleEnabled = savedPreferences.adaptiveIdleEnabled
    }

    private func resetInteractionDraft() {
        let storedPreferences = interactionPreferencesStore.preferences
        dateDisplayMode = storedPreferences.dateDisplay.mode
        customizedCommandIDs = Set(
            storedPreferences.shortcutOverrides.compactMap {
                NativeCommandID(rawValue: $0.commandID)
            }
        )
        let plan = shortcutValidationService.makeImportPlan(from: storedPreferences.shortcutOverrides)
        shortcutDrafts = Dictionary(
            uniqueKeysWithValues: plan.proposedBindings.map {
                ($0.commandID, ShortcutEditorDraft(shortcut: $0.shortcut))
            }
        )
    }

    private func resetBehaviorDraft() {
        let storedPreferences = behaviorPreferencesStore.preferences
        speedAveragingEnabled = storedPreferences.speedAveraging.isEnabled
        speedAverageSampleLimit = String(storedPreferences.speedAveraging.sampleLimit)
        speedAverageWindowSeconds = String(storedPreferences.speedAveraging.windowSeconds)
        completionNotificationsEnabled = storedPreferences.completionNotificationsEnabled
        addStartIntent = storedPreferences.addDefaults.startIntent
        addPriority = storedPreferences.addDefaults.priority
        addUnwantedFiles = storedPreferences.addDefaults.unwantedFiles
        addPeerLimit = storedPreferences.addDefaults.peerLimit.map(String.init) ?? ""
        promptsForDownloadOptions = storedPreferences.promptsForDownloadOptions
    }

    private func resetIntakeAutomationDraft() {
        let storedPreferences = intakeAutomationPreferencesStore.preferences
        clipboardIntakeEnabled = storedPreferences.clipboardIntake.isEnabled
        sourceTorrentDeletion = storedPreferences.sourceTorrentDeletion
        automaticUpdateChecksEnabled = storedPreferences.updateChecks.automaticChecksEnabled
        automaticUpdateCadenceHours = String(
            storedPreferences.updateChecks.automaticCadenceHours
        )
    }

    private func resetWatchFolderDraft() {
        let stored = watchFolderPreferencesStore.configuration
        watchFolderEnabled = stored.isEnabled
        watchFolderSourceBookmark = stored.sourceBookmarkData
        watchFolderSourceName = WatchFolderBookmarkService.displayName(
            for: stored.sourceBookmarkData
        )
        watchFolderRemoteDestination = stored.remoteDestination
        watchFolderScanInterval = String(stored.scanIntervalSeconds)
        watchFolderSuccessPolicy = stored.successPolicy
        watchFolderSubmissionPolicy = stored.submissionPolicy
        watchFolderProcessedBookmark = stored.processedFolderBookmarkData
        watchFolderProcessedName = WatchFolderBookmarkService.displayName(
            for: stored.processedFolderBookmarkData
        )
    }

    private func resetSidebarGroupingDraft() {
        let stored = workspacePreferencesStore.preferences.sidebarGrouping
        showTrackerGroups = stored.showsTrackers
        showLabelGroups = stored.showsLabels
        showDownloadFolderGroups = stored.showsDownloadFolders
    }

    private func resetPeerResolutionDraft() {
        let stored = peerResolutionPreferencesStore.preferences
        resolvePeerHostNames = stored.resolveHostNames
        resolvePeerCountries = stored.resolveCountries
        showPeerCountryFlags = stored.showCountryFlags
        countryDatabaseSourceURL = stored.countryDatabaseSourceURL
    }

    private func handleWatchFolderSelection(
        _ result: Result<[URL], Error>
    ) {
        do {
            guard let folderURL = try result.get().first else { return }
            let bookmark = try WatchFolderBookmarkService.makeSecurityScopedBookmark(
                for: folderURL
            )
            switch watchFolderPickerTarget {
            case .source:
                watchFolderSourceBookmark = bookmark
                watchFolderSourceName = folderURL.lastPathComponent
            case .processed:
                watchFolderProcessedBookmark = bookmark
                watchFolderProcessedName = folderURL.lastPathComponent
            }
            persistenceError = nil
        } catch {
            if (error as NSError).code != NSUserCancelledError {
                persistenceError = error.localizedDescription
            }
        }
    }

    private func retryWatchFolderFailures() {
        do {
            try watchFolderPreferencesStore.makeFailuresRetryableNow()
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}

/// The surrounding settings row supplies the visible label; this control keeps
/// its editable value and optional unit together without an implicit form label.
struct ApplicationSettingsValueField: View {
    var accessibilityLabel: String
    @Binding var text: String
    var unit: String? = nil
    var prompt: String? = nil
    var fieldWidth: CGFloat = 72

    var body: some View {
        HStack(spacing: 6) {
            TextField("", text: $text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .accessibilityLabel(Text(accessibilityLabel))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: fieldWidth)
            if let unit {
                Text(unit)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
    }
}

private enum WatchFolderPickerTarget {
    case source
    case processed
}

private extension NativeShortcutModifier {
    var title: String {
        switch self {
        case .command: "Command"
        case .option: "Option"
        case .control: "Control"
        case .shift: "Shift"
        }
    }

    var symbol: String {
        switch self {
        case .command: "⌘"
        case .option: "⌥"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }
}

private extension NativeCommandShortcut {
    var displayLabel: String {
        let modifierLabel = modifiers.map(\.symbol).joined()
        let keyLabel: String
        switch keyEquivalent {
        case "return": keyLabel = "↩"
        case "delete": keyLabel = "⌫"
        case "upArrow": keyLabel = "↑"
        case "downArrow": keyLabel = "↓"
        case "leftArrow": keyLabel = "←"
        case "rightArrow": keyLabel = "→"
        case "space": keyLabel = "Space"
        case "escape": keyLabel = "Esc"
        default: keyLabel = keyEquivalent.uppercased()
        }
        return modifierLabel + keyLabel
    }
}

#Preview {
    ApplicationSettingsPreview()
}

private struct ApplicationSettingsPreview: View {
    @State private var preferences = PollingPreferences.defaults

    var body: some View {
        ApplicationSettingsView(
            preferences: preferences,
            interactionPreferencesStore: .shared,
            behaviorPreferencesStore: .shared,
            intakeAutomationPreferencesStore: .shared,
            watchFolderPreferencesStore: .shared,
            workspacePreferencesStore: UIWorkspacePreferencesStore(),
            peerResolutionPreferencesStore: .shared,
            peerCountryDatabaseController: .shared,
            draftSession: ApplicationSettingsDraftSession(),
            onClearPeerResolutionCache: { .completed },
            onPersistPollingPreferences: { _ in },
            onApplyRuntimeSnapshot: { preferences = $0.polling }
        )
    }
}
