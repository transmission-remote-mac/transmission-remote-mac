// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

private struct PollingRefreshKind: OptionSet, Sendable {
    let rawValue: Int

    static let torrents = PollingRefreshKind(rawValue: 1 << 0)
    static let details = PollingRefreshKind(rawValue: 1 << 1)
    static let sessionInfo = PollingRefreshKind(rawValue: 1 << 2)
    static let sessionStats = PollingRefreshKind(rawValue: 1 << 3)
    static let torrentRepair = PollingRefreshKind(rawValue: 1 << 4)
    static let torrentRows = PollingRefreshKind(rawValue: 1 << 5)

    static let session: PollingRefreshKind = [.sessionInfo, .sessionStats]
    static let all: PollingRefreshKind = [.torrentRepair, .details, .session]
}

private enum DetailRefreshPriority: Sendable {
    case prefetch
    case active
}

private struct SequencedTorrentListUpdate {
    let update: TorrentListUpdate
    let requestSequenceByHash: [String: UInt64]
    let profileID: ConnectionProfile.ID
    let connectionGeneration: UUID
    let requestSequence: UInt64
}

private struct DetailRefreshRequest: Sendable {
    struct Key: Hashable, Sendable {
        var connectionToken: UUID
        var selectionGeneration: Int
        var torrentID: TorrentSummary.ID
        var torrentHash: String
        var pane: TorrentDetailPane
        var paneRevision: Int
    }

    var key: Key
    var priority: DetailRefreshPriority
}

private enum AppStoreDefaultsKey {
    static let addTorrentDestinationHistory = "addTorrentDestinationHistory"
    static let torrentDetailVisibility = "mainWindow.torrentDetailVisibility.v1"
}

private enum LaunchConnectionPolicyState {
    case notStarted
    case waitingForProfile
    case attempting
    case complete
}

struct DownloadCompletionTransition: Equatable {
    var torrentID: TorrentSummary.ID
    var torrentName: String
}

struct DownloadCompletionTracker {
    private var completionStateByTorrentID: [TorrentSummary.ID: Bool] = [:]

    mutating func transitions(afterRefreshing torrents: [TorrentSummary]) -> [DownloadCompletionTransition] {
        var transitions: [DownloadCompletionTransition] = []
        var nextCompletionStateByTorrentID: [TorrentSummary.ID: Bool] = [:]

        for torrent in torrents {
            let isComplete = Self.isComplete(torrent)
            if let wasComplete = completionStateByTorrentID[torrent.id], !wasComplete, isComplete {
                transitions.append(DownloadCompletionTransition(torrentID: torrent.id, torrentName: torrent.name))
            }
            nextCompletionStateByTorrentID[torrent.id] = isComplete
        }

        completionStateByTorrentID = nextCompletionStateByTorrentID
        return transitions
    }

    mutating func transitions(
        afterApplying upserted: [TorrentSummary],
        removedIDs: [TorrentSummary.ID]
    ) -> [DownloadCompletionTransition] {
        for removedID in removedIDs {
            completionStateByTorrentID[removedID] = nil
        }

        var transitions: [DownloadCompletionTransition] = []
        for torrent in upserted {
            let isComplete = Self.isComplete(torrent)
            if let wasComplete = completionStateByTorrentID[torrent.id], !wasComplete, isComplete {
                transitions.append(DownloadCompletionTransition(torrentID: torrent.id, torrentName: torrent.name))
            }
            completionStateByTorrentID[torrent.id] = isComplete
        }
        return transitions
    }

    mutating func reset() {
        completionStateByTorrentID = [:]
    }

    private static func isComplete(_ torrent: TorrentSummary) -> Bool {
        torrent.status == .seeding
            || torrent.status == .finished
            || (torrent.percentDone >= 1 && torrent.sizeWhenDone > 0 && torrent.leftUntilDone == 0)
    }
}

@MainActor
final class AppStore: ObservableObject {
    private enum DaemonMaintenanceKind: Equatable, Sendable {
        case portTest
        case blocklistUpdate
    }

    private struct DaemonMaintenanceOwner: Equatable, Sendable {
        let id: UUID
        let kind: DaemonMaintenanceKind
        let profileID: ConnectionProfile.ID
        let connectionToken: UUID
    }

    private struct ConnectionProfileTransition {
        let shouldDisconnect: Bool
        let shouldResumeLaunchConnection: Bool
        let shouldReconnect: Bool
    }

    fileprivate struct PromptedTorrentMutationOwner: Equatable {
        struct Target: Equatable, Sendable {
            let id: TorrentSummary.ID
            let hash: String
        }

        let profileID: ConnectionProfile.ID
        let connectionToken: UUID
        let client: TransmissionRPCClient
        let targets: [Target]

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.profileID == rhs.profileID
                && lhs.connectionToken == rhs.connectionToken
                && lhs.client === rhs.client
                && lhs.targets == rhs.targets
        }
    }

    private struct PendingVerifyOperation {
        let confirmation: TorrentVerifyConfirmation
        let owner: PromptedTorrentMutationOwner
    }

    private struct TrackedTorrentOperation {
        let expectation: TorrentOperationCompletionExpectation
        let owner: PromptedTorrentMutationOwner
        let refreshIDs: [TorrentSummary.ID]
        let completedDestinationHistory: String?
        var postAcknowledgementObservation: TorrentOperationPostAcknowledgementObservation?
    }

    struct DetailMutationOwner: Equatable, Sendable {
        let connectionToken: UUID
        let profileID: ConnectionProfile.ID
        let torrentID: TorrentSummary.ID
        let torrentHash: String
        let pane: TorrentDetailPane
        let selectionGeneration: Int
        let paneRevision: Int
        let filesSnapshotRevision: TorrentFilesSnapshotRevision?
    }

    struct TorrentListUpdateMetrics: Equatable, Sendable {
        var isFullSnapshot: Bool
        var mappedRowCount: Int
        var projectionEvaluatedRowCount: Int
        var authoritativeRowMutationCount: Int
        var visibleIndexRebuildCount: Int
        var sourceIndexRebuildCount: Int
        var publishedDerivedValueCount: Int

        static let empty = TorrentListUpdateMetrics(
            isFullSnapshot: true,
            mappedRowCount: 0,
            projectionEvaluatedRowCount: 0,
            authoritativeRowMutationCount: 0,
            visibleIndexRebuildCount: 0,
            sourceIndexRebuildCount: 0,
            publishedDerivedValueCount: 0
        )
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case reconnecting(message: String, secondsRemaining: Int, attempt: Int)
        case connected(rpcVersion: Int)
        case failed(String)

        var title: String {
            switch self {
            case .disconnected: "Disconnected"
            case .connecting: "Connecting…"
            case .reconnecting(let message, let secondsRemaining, _):
                "Reconnect in \(secondsRemaining)s · \(message)"
            case .connected(let rpcVersion): "Connected · RPC \(rpcVersion)"
            case .failed(let message): "Error · \(message)"
            }
        }

        var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }
    }

    struct RemovalConfirmation: Identifiable, Equatable {
        let id = UUID()
        let torrentIDs: [TorrentSummary.ID]
        let torrentHashes: [String]
        let torrentNames: [String]
        let totalSize: Int64
        let profileID: ConnectionProfile.ID
        let connectionToken: UUID
        let deleteLocalData: Bool
    }

    struct PasswordPrompt: Identifiable, Equatable {
        let id = UUID()
        var profileID: ConnectionProfile.ID
        var profileName: String
        var username: String
        var savesPassword: Bool
    }

    struct PendingAddTorrent: Identifiable, Equatable {
        enum Source: Equatable {
            case manual
            case remote(String)
            case localFile(URL)
        }

        let id = UUID()
        var source: Source
        let profileID: ConnectionProfile.ID
        let connectionToken: UUID
        var initialOptions: AddTorrentInitialOptions = .unspecified
        var suggestedDownloadDirectory: String? = nil
        var watchFolderJob: WatchFolderScanJob? = nil
        var watchFolderOwner: WatchFolderRunOwner? = nil
        var submissionDisposition: AddTorrentSubmissionDisposition = .presentOptions
        var directSubmissionDefaults: AddTorrentDefaults? = nil
        var pendingDuplicateTrackerPlan: TorrentDuplicateTrackerPlan? = nil
        var presentationOwnerID: UUID? = nil
    }

    private struct UnboundPendingAddTorrent: Equatable {
        var source: PendingAddTorrent.Source
        var initialOptions: AddTorrentInitialOptions
    }

    enum AddTorrentSubmissionResult: Equatable {
        case succeeded
        case awaitingSaveAs
        case confirmDuplicateTrackers(TorrentDuplicateTrackerPlan)
        case failed(String)
    }

    private struct ActiveAddTorrentMutation: Equatable {
        let requestID: PendingAddTorrent.ID
        let profileID: ConnectionProfile.ID
        let connectionToken: UUID
        let presentationOwnerID: UUID
    }

    private struct DirectAddTorrentPreparationOwnership: Equatable {
        let requestID: PendingAddTorrent.ID
        let profileID: ConnectionProfile.ID
        let connectionToken: UUID
        let taskID: UUID
    }

    struct TorrentPropertiesEditorState: Identifiable, Equatable {
        let id = UUID()
        fileprivate let owner: PromptedTorrentMutationOwner
        var torrentName: String
        var rpcVersion: Int
        var draft: TorrentPropertiesDraft
        var isApplying = false

        var torrentIDs: [TorrentSummary.ID] { owner.targets.map(\.id) }
        var selectionCount: Int { owner.targets.count }
    }

    @Published var profiles: [ConnectionProfile] = [.localDefault]
    @Published var selectedProfileID: ConnectionProfile.ID = ConnectionProfile.localDefault.id {
        didSet {
            guard selectedProfileID != oldValue else { return }
            synchronizeDaemonOptionsSettings()
        }
    }
    @Published var connectionState: ConnectionState = .disconnected
    @Published private(set) var needsConnectionSetup = false
    var torrents: [TorrentSummary] {
        get { materializeTorrentSnapshot() }
        set { replaceTorrentSnapshot(newValue) }
    }
    @Published var sessionInfo: SessionInfo? {
        didSet {
            refreshTorrentListSummary()
            synchronizeDaemonOptionsSettings()
        }
    }
    @Published var sessionStats: SessionStats? {
        didSet { refreshTorrentListSummary() }
    }
    @Published var selectedTorrentIDs = Set<TorrentSummary.ID>() {
        didSet {
            guard selectedTorrentIDs != oldValue else { return }
            refreshTorrentListSummary()
            selectedTorrentDidChange(from: oldValue)
        }
    }
    @Published var torrentSortOrder = TorrentSorting.defaultSortOrder {
        didSet { rebuildTorrentListProjection() }
    }
    @Published var filterText = "" {
        didSet {
            guard filterText != oldValue else { return }
            rebuildTorrentListProjection()
            pruneSelectionToVisibleTorrents()
        }
    }
    @Published var torrentFilters = TorrentFilters() {
        didSet {
            guard torrentFilters != oldValue else { return }
            rebuildTorrentListProjection()
            pruneSelectionToVisibleTorrents()
        }
    }
    @Published private(set) var visibleTorrents: [TorrentSummary] = []
    @Published private(set) var filterCounts = TorrentListProjection.empty.filterCounts
    @Published private(set) var torrentListSummary = TorrentListProjection.empty.makeSummary(
        selectedIDs: [],
        sessionStats: nil,
        sessionInfo: nil
    )
    private(set) var torrentListUpdateMetrics = TorrentListUpdateMetrics.empty
    private(set) var torrentSnapshotMaterializationCount = 0
    private(set) var torrentOperationReconciliationSnapshotCount = 0
    @Published private(set) var torrentListMaterializationRevision = 0
    @Published private(set) var showingAddTorrent = false
    @Published private(set) var pendingAddTorrent: PendingAddTorrent?
    @Published private(set) var isAddingTorrent = false
    @Published private(set) var provisionalTorrentAddState: ProvisionalTorrentAddState = .idle
    @Published var showingLabelEditor = false
    @Published var labelDraft = ""
    @Published var errorMessage: String?
    @Published var removalConfirmation: RemovalConfirmation?
    @Published private(set) var verifyConfirmation: TorrentVerifyConfirmation?
    @Published private(set) var torrentOperationFeedback: [TorrentOperationFeedback] = []
    @Published private(set) var isRemoving = false
    @Published var passwordPrompt: PasswordPrompt?
    @Published var torrentPropertiesEditor: TorrentPropertiesEditorState?
    @Published private(set) var isLoadingTorrentProperties = false
    @Published private(set) var isUpdatingGlobalBandwidth = false
    @Published private(set) var addTorrentDestinationHistory: [String] = []
    @Published private(set) var selectedTorrentDetailState: TorrentDetailLoadState = .notLoaded
    @Published var isTorrentDetailVisible: Bool {
        didSet {
            guard isTorrentDetailVisible != oldValue else { return }
            userDefaults.set(isTorrentDetailVisible, forKey: AppStoreDefaultsKey.torrentDetailVisibility)
            workspacePreferencesStore.updateInfoPaneVisibility(isTorrentDetailVisible)
            torrentDetailVisibilityDidChange()
        }
    }
    @Published var selectedTorrentDetailPane: TorrentDetailPane = .overview {
        didSet {
            guard selectedTorrentDetailPane != oldValue else { return }
            workspacePreferencesStore.updateSelectedDetailPane(selectedTorrentDetailPane)
            selectedTorrentDetailPaneDidChange()
        }
    }
    @Published private(set) var pollingPreferences: PollingPreferences
    @Published private(set) var applicationBehaviorPreferences: ApplicationBehaviorPreferences
    @Published private(set) var intakeAutomationPreferences: IntakeAutomationPreferences
    @Published private(set) var peerResolutionPreferences: PeerResolutionPreferences
    @Published private(set) var watchFolderPreferences: WatchFolderPreferencesSnapshot
    @Published private(set) var pollingVisibility: PollingVisibilityState = .foreground
    @Published private(set) var isApplyingDaemonOptions = false
    @Published private(set) var isTestingPort = false
    @Published private(set) var isUpdatingBlocklist = false
    @Published private(set) var daemonMaintenanceNotice: DaemonMaintenanceNotice?

    private let profileStore: ConnectionProfileStore
    private let userDefaults: UserDefaults
    private let localFileActionService: any LocalFileActionServicing
    private let magnetLinkPasteboardService: MagnetLinkPasteboardService
    private let downloadCompletionNotifier: any DownloadCompletionNotifying
    private let reconnectSleeper: any ReconnectSleeping
    private let provisionalMetadataSleeper: any ReconnectSleeping
    private let provisionalMetadataPollingPolicy: ProvisionalTorrentMetadataPollingPolicy
    private let pollingCoordinator: PollingCoordinator
    private let adaptivePollingCadencePolicy: AdaptivePollingCadencePolicy
    private let adaptivePollingClock: any PollingClock
    private let behaviorPreferencesStore: ApplicationBehaviorPreferencesStore
    private let interactionPreferencesStore: ApplicationInteractionPreferencesStore
    private let workspacePreferencesStore: UIWorkspacePreferencesStore
    private let tableColumnCustomizationWorkspaceController:
        TableColumnCustomizationWorkspaceController
    private let intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore
    private let peerResolutionPreferencesStore: PeerResolutionPreferencesStore
    private let peerCountryDatabase: PeerCountryDatabaseController
    private let peerEndpointResolver: PeerEndpointResolver
    private let watchFolderPreferencesStore: WatchFolderPreferencesStore
    private let applicationSettingsDraftSession = ApplicationSettingsDraftSession()
    private let daemonOptionsSettings = DaemonOptionsSettingsController()
    private let watchFolderCoordinator: any WatchFolderCoordinating
    private let clipboardTorrentPayloadReader: any ClipboardTorrentPayloadReading
    private var clipboardTorrentIntakeService: ClipboardTorrentIntakeService
    private let torrentSourceDeletionService: TorrentSourceDeletionService
    private let addTorrentDestinationRecommendationService: any AddTorrentDestinationRecommendationServicing
    private let directAddTorrentPreparationService: any AddTorrentDirectSubmissionPreparing
    private let torrentOperationPrompter: any TorrentOperationPrompting
    private let torrentOperationMonitoringClock: any PollingClock
    private let detailRefreshPolicy: TorrentDetailRefreshPolicy
    private let performanceHarnessDetailSelection: PerformanceHarnessDetailSelection?
    private let performanceHarnessInstrumentation: (any PerformanceHarnessInstrumenting)?
    private let mutationRefreshPolicy = TorrentMutationRefreshPolicy()
    private let clientFactory: (ConnectionProfile) -> TransmissionRPCClient
    private let filterEngine = TorrentFilterEngine()
    private var torrentListProjection = TorrentListProjection.empty
    private var client: TransmissionRPCClient?

    var interactionPreferencesController: ApplicationInteractionPreferencesStore {
        interactionPreferencesStore
    }

    var workspacePreferencesController: UIWorkspacePreferencesStore {
        workspacePreferencesStore
    }

    var tableColumnCustomizationController: TableColumnCustomizationWorkspaceController {
        tableColumnCustomizationWorkspaceController
    }

    var behaviorPreferencesController: ApplicationBehaviorPreferencesStore {
        behaviorPreferencesStore
    }

    var intakeAutomationPreferencesController: IntakeAutomationPreferencesStore {
        intakeAutomationPreferencesStore
    }

    var watchFolderPreferencesController: WatchFolderPreferencesStore {
        watchFolderPreferencesStore
    }

    var peerResolutionPreferencesController: PeerResolutionPreferencesStore {
        peerResolutionPreferencesStore
    }

    var applicationSettingsDraftSessionController: ApplicationSettingsDraftSession {
        applicationSettingsDraftSession
    }

    var daemonOptionsSettingsController: DaemonOptionsSettingsController {
        daemonOptionsSettings
    }

    private(set) lazy var connectionSettingsCoordinatorController = ConnectionSettingsCoordinator(
        profiles: profiles,
        selectedProfileID: selectedProfileID
    )

    var peerCountryDatabaseController: PeerCountryDatabaseController {
        peerCountryDatabase
    }

    private(set) lazy var settingsPortabilityController = SettingsPortabilityCoordinator(
        profileStore: profileStore,
        userDefaults: userDefaults,
        behaviorPreferencesStore: behaviorPreferencesStore,
        interactionPreferencesStore: interactionPreferencesStore,
        intakeAutomationPreferencesStore: intakeAutomationPreferencesStore,
        peerResolutionPreferencesStore: peerResolutionPreferencesStore,
        watchFolderPreferencesStore: watchFolderPreferencesStore,
        currentState: { [unowned self] in
            self.settingsPortabilityRuntimeState()
        },
        commitReadinessIssue: { [unowned self] in
            self.settingsPortabilityCommitReadinessIssue
        },
        didCommit: { [weak self] result in
            self?.settingsPortabilityDidCommit(result)
        }
    )

    private var unboundAddTorrents: [UnboundPendingAddTorrent] = []
    private var queuedAddTorrents: [PendingAddTorrent] = []
    private var addTorrentPresentationOwners: [UUID] = []
    private let directAddTorrentOwnerID = UUID()
    private var directAddTorrentTask: Task<Void, Never>?
    private var directAddTorrentPreparationOwnership:
        DirectAddTorrentPreparationOwnership?
    private var completedAddTorrentPresentation: (requestID: PendingAddTorrent.ID, ownerID: UUID)?
    private var activeAddTorrentMutation: ActiveAddTorrentMutation?
    private var provisionalMetadataTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var activeConnectionTask: Task<SessionInfo, Error>?
    private var activeConnectionTaskToken: UUID?
    private var reconnectToken = UUID()
    private var reconnectBackoff = ReconnectBackoff()
    private var reconnectAttempt = 0
    private var shouldMaintainConnection = false
    private var sessionPasswords: [ConnectionProfile.ID: String] = [:]
    private var selectedDetailDebounceTask: Task<Void, Never>?
    private var selectedDetailDebounceOwnerID: UUID?
    private var selectedDetailTorrentID: TorrentSummary.ID?
    private var selectedDetailTorrentHash: String?
    @Published private var selectedDetailLoadedPanes = Set<TorrentDetailPane>()
    private var selectedDetailSnapshots: [TorrentDetailPane: TorrentDetail] = [:]
    private var torrentDetailCache = TorrentDetailCache()
    private var activeDetailMutations: [UUID: Set<String>] = [:]
    private var pieceRevalidationHashes = Set<String>()
    @Published private(set) var selectedTorrentRequiresPieceRevalidation = false
    private var selectedDetailPaneRevisions: [TorrentDetailPane: Int] = [:]
    private var selectedDetailSelectionGeneration = 0
    private var prefetchedSelectionGeneration: Int?
    private var queuedDetailRefreshes: [DetailRefreshRequest] = []
    private var activeDetailRefreshOperationID: UUID?
    private var activeDetailRefreshKey: DetailRefreshRequest.Key?
    private var activeDetailRefreshPriority: DetailRefreshPriority?
    private var activeDetailRefreshTask: Task<TorrentDetail, Error>?
    private var queuedRefreshKinds: PollingRefreshKind = []
    private var queuedTorrentRowRefreshIDs = Set<TorrentSummary.ID>()
    private var activeRefreshDrainToken: UUID?
    private var connectionToken = UUID()
    private var activeRemovalID: UUID?
    private var pendingVerifyOperation: PendingVerifyOperation?
    private var torrentOperationFeedbackLifecycle = TorrentOperationFeedbackLifecycle()
    private var trackedTorrentOperations: [UUID: TrackedTorrentOperation] = [:]
    private var torrentOperationRPCTasks: [UUID: Task<Void, Error>] = [:]
    private var torrentOperationMonitoringCoordinator: TorrentOperationMonitoringCoordinator
    private var torrentOperationMonitorTask: Task<Void, Never>?
    private var torrentListRequestSequence: UInt64 = 0
    private var sessionInfoRequestSequence: UInt64 = 0
    private var latestPublishedSessionInfoRequestSequence: UInt64 = 0
    private var activeBandwidthUpdateID: UUID?
    private var activeBandwidthUpdateTask: Task<Void, Error>?
    private var retiredBandwidthUpdate: (id: UUID, task: Task<Void, Error>)?
    private var torrentPropertiesLoadID: UUID?
    private var downloadCompletionTracker = DownloadCompletionTracker()
    private var downloadSpeedAverager: SpeedAverager
    private var uploadSpeedAverager: SpeedAverager
    private var latestRawSessionStats: SessionStats?
    private var behaviorPreferencesCancellable: AnyCancellable?
    private var intakeAutomationPreferencesCancellable: AnyCancellable?
    private var watchFolderPreferencesCancellable: AnyCancellable?
    private var peerResolutionPreferencesCancellable: AnyCancellable?
    private var peerCountryDatabaseCancellable: AnyCancellable?
    private var peerResolutionTask: Task<Void, Never>?
    private var peerResolutionOwnerID: UUID?
    private var peerResolutionRequest: PeerResolutionRequest?
    private var peerResolutionCommandGeneration = 0
    private var peerResolutionCacheClearTask: Task<Void, Never>?
    private var peerResolutionCacheClearLifecycle = PeerResolutionCacheClearLifecycle()
    private var isClearingPeerResolutionCaches = false
    private var peerCountryDatabaseGeneration = 0
    private var watchFolderCommandRevision = 0
    private var activeWatchFolderOwner: WatchFolderRunOwner?
    private var launchConnectionPolicyState: LaunchConnectionPolicyState = .notStarted
    private var pollingCommandRevision = 0
    private var scheduledPollingIntervalSeconds: Int?
    private var recentPollingMutation: AdaptivePollingMutationActivity?
    private var detailPollingTick = 0
    private var performanceHarnessDidSelectTorrentDetail = false
    private var performanceHarnessDidMeasureLargeList = false
    private var torrentListDeltaAccumulator = TorrentListDeltaAccumulator()
    private(set) var torrentTableVisibleColumns = Set(
        TorrentTableColumnID.allCases.filter(\.isVisibleByDefault)
    )
    private(set) var torrentTableActiveSortColumn = TorrentTableDefaults.sort.columnID
    private(set) var torrentListFieldPlanRevision = 0
    private(set) var currentTorrentListFieldPlan: TorrentListFieldPlan?
    private var activeDaemonOptionsApplyID: UUID?
    private var activeDaemonMaintenanceOwner: DaemonMaintenanceOwner?
    private var activeDaemonMaintenanceTask: Task<Void, Never>?

    private let selectionDebounceDuration: Duration
    private let torrentListRepairInterval: Duration
    private let speedSampleClock: () -> TimeInterval

    init(
        profileStore: ConnectionProfileStore = ConnectionProfileStore(),
        userDefaults: UserDefaults = .standard,
        localFileActionService: any LocalFileActionServicing = LocalFileActionService(),
        magnetLinkPasteboardService: MagnetLinkPasteboardService = MagnetLinkPasteboardService(),
        downloadCompletionNotifier: any DownloadCompletionNotifying = DownloadCompletionNotificationService(),
        reconnectSleeper: any ReconnectSleeping = TaskReconnectSleeper(),
        provisionalMetadataSleeper: any ReconnectSleeping = TaskReconnectSleeper(),
        provisionalMetadataPollingPolicy: ProvisionalTorrentMetadataPollingPolicy = .standard,
        pollingCoordinator: PollingCoordinator = PollingCoordinator(),
        adaptivePollingCadencePolicy: AdaptivePollingCadencePolicy = .standard,
        adaptivePollingClock: any PollingClock = ContinuousPollingClock(),
        behaviorPreferencesStore: ApplicationBehaviorPreferencesStore? = nil,
        interactionPreferencesStore: ApplicationInteractionPreferencesStore? = nil,
        workspacePreferencesStore: UIWorkspacePreferencesStore? = nil,
        intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore? = nil,
        peerResolutionPreferencesStore: PeerResolutionPreferencesStore? = nil,
        peerCountryDatabaseController: PeerCountryDatabaseController? = nil,
        peerEndpointResolver: PeerEndpointResolver = PeerEndpointResolver(),
        watchFolderPreferencesStore: WatchFolderPreferencesStore? = nil,
        watchFolderCoordinator: any WatchFolderCoordinating = WatchFolderDeadlineCoordinator(),
        clipboardTorrentPayloadReader: (any ClipboardTorrentPayloadReading)? = nil,
        clipboardTorrentIntakeService: ClipboardTorrentIntakeService = ClipboardTorrentIntakeService(),
        torrentSourceDeletionService: TorrentSourceDeletionService = TorrentSourceDeletionService(),
        addTorrentDestinationRecommendationService: any AddTorrentDestinationRecommendationServicing = AddTorrentDestinationRecommendationService(),
        directAddTorrentPreparationService: any AddTorrentDirectSubmissionPreparing =
            AddTorrentDirectSubmissionPreparationService(),
        torrentOperationPrompter: (any TorrentOperationPrompting)? = nil,
        torrentOperationMonitoringPolicy: TorrentOperationMonitoringPolicy = .standard,
        torrentOperationMonitoringClock: any PollingClock = ContinuousPollingClock(),
        detailRefreshPolicy: TorrentDetailRefreshPolicy = .standard,
        performanceHarnessDetailSelection: PerformanceHarnessDetailSelection? = .requestedFromEnvironment(),
        performanceHarnessInstrumentation: (any PerformanceHarnessInstrumenting)? = PerformanceHarnessInstrumentationFactory.requestedFromEnvironment(),
        selectionDebounceDuration: Duration = .milliseconds(100),
        torrentListRepairInterval: Duration = .seconds(600),
        speedSampleClock: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        clientFactory: @escaping (ConnectionProfile) -> TransmissionRPCClient = {
            TransmissionRPCClient(profile: $0)
        }
    ) {
        self.profileStore = profileStore
        self.userDefaults = userDefaults
        self.tableColumnCustomizationWorkspaceController =
            TableColumnCustomizationWorkspaceController(userDefaults: userDefaults)
        self.localFileActionService = localFileActionService
        self.magnetLinkPasteboardService = magnetLinkPasteboardService
        self.downloadCompletionNotifier = downloadCompletionNotifier
        self.reconnectSleeper = reconnectSleeper
        self.provisionalMetadataSleeper = provisionalMetadataSleeper
        self.provisionalMetadataPollingPolicy = provisionalMetadataPollingPolicy
        self.pollingCoordinator = pollingCoordinator
        self.adaptivePollingCadencePolicy = adaptivePollingCadencePolicy
        self.adaptivePollingClock = adaptivePollingClock
        let resolvedBehaviorPreferencesStore = behaviorPreferencesStore
            ?? (userDefaults === UserDefaults.standard
                ? .shared
                : ApplicationBehaviorPreferencesStore(userDefaults: userDefaults))
        self.behaviorPreferencesStore = resolvedBehaviorPreferencesStore
        let resolvedInteractionPreferencesStore = interactionPreferencesStore
            ?? (userDefaults === UserDefaults.standard
                ? .shared
                : ApplicationInteractionPreferencesStore(userDefaults: userDefaults))
        self.interactionPreferencesStore = resolvedInteractionPreferencesStore
        let resolvedWorkspacePreferencesStore = workspacePreferencesStore
            ?? UIWorkspacePreferencesStore(userDefaults: userDefaults)
        self.workspacePreferencesStore = resolvedWorkspacePreferencesStore
        let resolvedIntakeAutomationPreferencesStore = intakeAutomationPreferencesStore
            ?? (userDefaults === UserDefaults.standard
                ? .shared
                : IntakeAutomationPreferencesStore(userDefaults: userDefaults))
        self.intakeAutomationPreferencesStore = resolvedIntakeAutomationPreferencesStore
        let resolvedPeerResolutionPreferencesStore = peerResolutionPreferencesStore
            ?? (userDefaults === UserDefaults.standard
                ? .shared
                : PeerResolutionPreferencesStore(userDefaults: userDefaults))
        self.peerResolutionPreferencesStore = resolvedPeerResolutionPreferencesStore
        let resolvedPeerCountryDatabase = peerCountryDatabaseController
            ?? (userDefaults === UserDefaults.standard ? .shared : .isolated())
        self.peerCountryDatabase = resolvedPeerCountryDatabase
        self.peerEndpointResolver = peerEndpointResolver
        let resolvedWatchFolderPreferencesStore = watchFolderPreferencesStore
            ?? (userDefaults === UserDefaults.standard
                ? .shared
                : WatchFolderPreferencesStore(userDefaults: userDefaults))
        self.watchFolderPreferencesStore = resolvedWatchFolderPreferencesStore
        self.watchFolderCoordinator = watchFolderCoordinator
        self.clipboardTorrentPayloadReader = clipboardTorrentPayloadReader
            ?? SystemClipboardTorrentPayloadReader()
        self.clipboardTorrentIntakeService = clipboardTorrentIntakeService
        self.torrentSourceDeletionService = torrentSourceDeletionService
        self.addTorrentDestinationRecommendationService = addTorrentDestinationRecommendationService
        self.directAddTorrentPreparationService = directAddTorrentPreparationService
        self.torrentOperationPrompter = torrentOperationPrompter
            ?? NativeTorrentOperationPrompter()
        self.torrentOperationMonitoringClock = torrentOperationMonitoringClock
        self.torrentOperationMonitoringCoordinator = TorrentOperationMonitoringCoordinator(
            policy: torrentOperationMonitoringPolicy
        )
        self.detailRefreshPolicy = detailRefreshPolicy
        self.performanceHarnessDetailSelection = performanceHarnessDetailSelection
        self.performanceHarnessInstrumentation = performanceHarnessInstrumentation
        self.selectionDebounceDuration = selectionDebounceDuration
        self.torrentListRepairInterval = torrentListRepairInterval
        self.speedSampleClock = speedSampleClock
        self.clientFactory = clientFactory
        self.pollingPreferences = PollingPreferences.load(from: userDefaults)
        self.applicationBehaviorPreferences = resolvedBehaviorPreferencesStore.preferences
        self.intakeAutomationPreferences = resolvedIntakeAutomationPreferencesStore.preferences
        self.peerResolutionPreferences = resolvedPeerResolutionPreferencesStore.preferences.effective(
            countryDatabaseAvailable: resolvedPeerCountryDatabase.status.isInstalled
        )
        self.watchFolderPreferences = resolvedWatchFolderPreferencesStore.snapshot
        self.downloadSpeedAverager = SpeedAverager(
            policy: resolvedBehaviorPreferencesStore.preferences.speedAveraging
        )
        self.uploadSpeedAverager = SpeedAverager(
            policy: resolvedBehaviorPreferencesStore.preferences.speedAveraging
        )
        self.needsConnectionSetup = !profileStore.hasPersistedProfiles
        if resolvedWorkspacePreferencesStore.hadPersistedPreferencesAtLaunch {
            self.isTorrentDetailVisible = resolvedWorkspacePreferencesStore.preferences.infoPane.isVisible
        } else {
            self.isTorrentDetailVisible = userDefaults.object(
                forKey: AppStoreDefaultsKey.torrentDetailVisibility
            ) == nil
                ? true
                : userDefaults.bool(forKey: AppStoreDefaultsKey.torrentDetailVisibility)
        }
        self.selectedTorrentDetailPane = resolvedWorkspacePreferencesStore.preferences.infoPane.selectedDetailPane
        loadProfiles()
        loadSelectedProfileTransferPreferences(migratingLegacyHistory: true)
        observeBehaviorPreferences()
        observeIntakeAutomationPreferences()
        observePeerResolutionPreferences()
        observePeerCountryDatabase()
        observeWatchFolderPreferences()
        synchronizePeerCountryDatabase()
    }

    deinit {
        directAddTorrentTask?.cancel()
        provisionalMetadataTask?.cancel()
        activeConnectionTask?.cancel()
        selectedDetailDebounceTask?.cancel()
        torrentOperationRPCTasks.values.forEach { $0.cancel() }
        torrentOperationMonitorTask?.cancel()
        peerResolutionTask?.cancel()
        peerResolutionCacheClearTask?.cancel()
        let pollingCoordinator = pollingCoordinator
        let finalCommandRevision = pollingCommandRevision + 1
        let watchFolderCoordinator = watchFolderCoordinator
        let finalWatchFolderCommandRevision = watchFolderCommandRevision + 1
        let peerEndpointResolver = peerEndpointResolver
        Task {
            await peerEndpointResolver.cancelAll()
            await pollingCoordinator.stop(commandRevision: finalCommandRevision)
            await watchFolderCoordinator.stop(
                commandRevision: finalWatchFolderCommandRevision,
                reason: "The application closed before the queued add was confirmed."
            )
        }
    }

    var selectedProfile: ConnectionProfile {
        profiles.first { $0.id == selectedProfileID } ?? .localDefault
    }

    var activeTorrentFilters: TorrentFilters {
        var filters = torrentFilters
        filters.searchText = filterText
        return filters
    }

    var hasActiveFilters: Bool {
        !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !torrentFilters.statuses.isEmpty
            || !torrentFilters.paths.isEmpty
            || !torrentFilters.trackers.isEmpty
            || !torrentFilters.labels.isEmpty
    }

    var canProbeAddTorrentFreeSpace: Bool {
        connectionState.isConnected && sessionInfo?.capabilities.hasFreeSpace == true && client != nil
    }

    var selectedTorrent: TorrentSummary? {
        guard let selectedID = selectedTorrentIDs.sorted().first else { return nil }
        guard var torrent = torrentListProjection.row(for: selectedID) else { return nil }
        if
            selectedDetailTorrentID == selectedID,
            selectedDetailTorrentHash == CanonicalTransmissionTorrentHash.normalize(torrent.hashString)
        {
            torrent.detailState = selectedTorrentDetailState
        }
        return torrent
    }

    var connectedRPCVersion: Int? {
        if case .connected(let rpcVersion) = connectionState { return rpcVersion }
        return nil
    }

    var addTorrentCapabilities: AddTorrentCapabilities {
        AddTorrentCapabilities(rpcVersion: connectedRPCVersion)
    }

    var canConnect: Bool {
        guard !needsConnectionSetup, !isRemoving, !isAddingTorrent, passwordPrompt == nil else { return false }
        switch connectionState {
        case .disconnected, .failed:
            return true
        case .connecting, .reconnecting, .connected:
            return false
        }
    }

    var canDisconnect: Bool {
        guard !isRemoving, !isAddingTorrent else { return false }
        switch connectionState {
        case .connecting, .reconnecting, .connected:
            return true
        case .disconnected, .failed:
            return false
        }
    }

    var canRefresh: Bool {
        connectionState.isConnected
    }

    var canAddTorrent: Bool {
        connectionState.isConnected && !isAddingTorrent
    }

    var canSetGlobalSpeedLimit: Bool {
        connectionState.isConnected && sessionInfo != nil && client != nil && !isUpdatingGlobalBandwidth
    }

    var canToggleAlternateSpeed: Bool {
        canSetGlobalSpeedLimit && sessionInfo?.capabilities.hasAlternateSpeedSchedule == true
    }

    private func rejectConnectionChangeDuringAddIfNeeded() -> Bool {
        guard isAddingTorrent else { return true }
        errorMessage = "Wait for the torrent add request to finish before changing the Transmission connection."
        return false
    }

    var isAlternateSpeedEnabled: Bool {
        sessionInfo?.isAlternateSpeedEnabled == true
    }

    var canStartAllTorrents: Bool {
        connectionState.isConnected
    }

    var canStopAllTorrents: Bool {
        connectionState.isConnected
    }

    var canActOnSelectedTorrents: Bool {
        canActOnTorrents(in: selectedTorrentIDs)
    }

    var canStartSelectedTorrents: Bool {
        canStartTorrents(in: selectedTorrentIDs)
    }

    var canStartNowSelectedTorrents: Bool {
        canStartNowTorrents(in: selectedTorrentIDs)
    }

    var canStopSelectedTorrents: Bool {
        canStopTorrents(in: selectedTorrentIDs)
    }

    var canVerifySelectedTorrents: Bool {
        canVerifyTorrents(in: selectedTorrentIDs)
    }

    var canReannounceSelectedTorrents: Bool {
        canReannounceTorrents(in: selectedTorrentIDs)
    }

    var canQueueSelectedTorrents: Bool {
        canQueueTorrents(in: selectedTorrentIDs)
    }

    var canSetSelectedBandwidthPriority: Bool {
        canSetBandwidthPriorityForTorrents(in: selectedTorrentIDs)
    }

    var canSetSelectedTorrentLabels: Bool {
        canActOnSelectedTorrents && (connectedRPCVersion ?? 0) >= 16
    }

    var canEditSelectedTorrentProperties: Bool {
        canEditTorrentProperties(in: selectedTorrentIDs)
    }

    var canSetSelectedTorrentLocation: Bool {
        canSetTorrentLocation(in: selectedTorrentIDs)
    }

    var canRenameSelectedTorrent: Bool {
        canRenameTorrent(in: selectedTorrentIDs)
    }

    var selectedTorrentFileMutationOwner: DetailMutationOwner? {
        makeDetailMutationOwner(pane: .files, requiresFilesSnapshot: true)
    }

    var selectedTorrentPathRenameOwner: TorrentPathRenameOwner? {
        guard
            (connectedRPCVersion ?? 0) >= 15,
            let mutationOwner = selectedTorrentFileMutationOwner,
            let filesRevision = mutationOwner.filesSnapshotRevision?.rawValue,
            (try? TorrentPathRenameValidator.normalizeTorrentHash(mutationOwner.torrentHash)) != nil
        else {
            return nil
        }
        return TorrentPathRenameOwner(
            connectionToken: mutationOwner.connectionToken,
            profileID: mutationOwner.profileID,
            selectionRevision: selectedDetailSelectionGeneration,
            paneRevision: mutationOwner.paneRevision,
            filesRevision: filesRevision
        )
    }

    var selectedTorrentTrackerMutationOwner: DetailMutationOwner? {
        makeDetailMutationOwner(pane: .trackers, requiresFilesSnapshot: false)
    }

    private func makeDetailMutationOwner(
        pane: TorrentDetailPane,
        requiresFilesSnapshot: Bool
    ) -> DetailMutationOwner? {
        guard
            connectionState.isConnected,
            selectedTorrentIDs.count == 1,
            let torrent = selectedTorrentsInDisplayOrder().first,
            !torrent.hashString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            selectedDetailTorrentID == torrent.id,
            selectedTorrentDetailPane == pane,
            selectedDetailLoadedPanes.contains(pane),
            let paneSnapshot = selectedDetailSnapshots[pane],
            paneSnapshot.id == torrent.id
        else {
            return nil
        }
        if pane == .trackers, (connectedRPCVersion ?? 0) < 10 {
            return nil
        }
        let filesSnapshotRevision = paneSnapshot.filesSnapshotRevision
        if requiresFilesSnapshot {
            guard filesSnapshotRevision != nil, !paneSnapshot.files.isEmpty else { return nil }
        }
        return DetailMutationOwner(
            connectionToken: connectionToken,
            profileID: selectedProfileID,
            torrentID: torrent.id,
            torrentHash: torrent.hashString,
            pane: pane,
            selectionGeneration: selectedDetailSelectionGeneration,
            paneRevision: selectedDetailPaneRevisions[pane, default: 0],
            filesSnapshotRevision: filesSnapshotRevision
        )
    }

    var canRemoveSelectedTorrents: Bool {
        canRemoveTorrents(in: selectedTorrentIDs)
    }

    var canDeleteSelectedTorrentData: Bool {
        canDeleteTorrentData(in: selectedTorrentIDs)
    }

    var canCopySelectedMagnetLinks: Bool {
        canCopyMagnetLinks(in: selectedTorrentIDs)
    }

    private func canActOnTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        connectionState.isConnected && !ids.isEmpty && torrentRows(for: ids).count == ids.count
    }

    func canStartTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids) && torrentRows(for: ids).contains { torrent in
            switch torrent.status {
            case .downloading, .seeding, .checking:
                return false
            case .stopped, .checkWait, .downloadWait, .seedWait, .finished, .unknown:
                return true
            }
        }
    }

    func canStartNowTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        canStartTorrents(in: ids) && (connectedRPCVersion ?? 0) >= 14
    }

    func canStopTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids) && torrentRows(for: ids).contains { torrent in
            torrent.status != .stopped && torrent.status != .finished
        }
    }

    func canVerifyTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids)
    }

    func canReannounceTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids)
            && (connectedRPCVersion ?? 0) >= 5
            && torrentRows(for: ids).contains { torrent in
                !torrent.trackerHost.isEmpty && torrent.trackerHost != "No tracker"
            }
    }

    func canQueueTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids) && (connectedRPCVersion ?? 0) >= 14
    }

    func canSetBandwidthPriorityForTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids) && (connectedRPCVersion ?? 0) >= 5
    }

    func canSetTorrentLocation(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids) && (connectedRPCVersion ?? 0) >= 6
    }

    func canEditTorrentProperties(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids) && !isLoadingTorrentProperties
    }

    func canRenameTorrent(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids)
            && (connectedRPCVersion ?? 0) >= 15
            && torrentRows(for: ids).count == 1
    }

    func canRemoveTorrents(in ids: Set<TorrentSummary.ID>) -> Bool {
        !isRemoving && canActOnTorrents(in: ids)
    }

    func canDeleteTorrentData(in ids: Set<TorrentSummary.ID>) -> Bool {
        // Match transgui's compatibility gate even though later RPC specs document the flag on torrent-remove.
        canRemoveTorrents(in: ids) && (connectedRPCVersion ?? 0) >= 4
    }

    func canCopyMagnetLinks(in ids: Set<TorrentSummary.ID>) -> Bool {
        canActOnTorrents(in: ids) && (connectedRPCVersion ?? 0) >= 7
    }

    func start() async {
        switch launchConnectionPolicyState {
        case .notStarted:
            break
        case .waitingForProfile, .attempting, .complete:
            return
        }

        guard !needsConnectionSetup else {
            launchConnectionPolicyState = .waitingForProfile
            return
        }

        launchConnectionPolicyState = .attempting
        guard selectedProfile.connectOnLaunch else {
            launchConnectionPolicyState = .complete
            return
        }

        defer {
            launchConnectionPolicyState = Task.isCancelled ? .notStarted : .complete
        }
        await connect()
    }

    func switchProfile(to profileID: ConnectionProfile.ID) async {
        guard !isRemoving else { return }
        guard rejectConnectionChangeDuringAddIfNeeded() else { return }
        guard profiles.contains(where: { $0.id == profileID }) else {
            errorMessage = ConnectionProfileStoreError.unknownProfile(profileID).localizedDescription
            return
        }

        if selectedProfileID == profileID {
            switch connectionState {
            case .connecting, .reconnecting, .connected:
                return
            case .disconnected, .failed:
                guard passwordPrompt == nil else { return }
                await connect()
                return
            }
        }

        do {
            let collection = try ConnectionProfileCollection(
                profiles: profiles,
                selectedProfileID: profileID
            )
            try profileStore.save(collection)
            disconnect()
            profiles = collection.profiles
            selectedProfileID = collection.selectedProfileID
            loadSelectedProfileTransferPreferences()
            await connect()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func connect() async {
        guard rejectConnectionChangeDuringAddIfNeeded() else { return }
        guard canConnect, passwordPrompt == nil else { return }
        cancelReconnect(resetBackoff: true)
        shouldMaintainConnection = true
        invalidateRemovalState()
        let profile = selectedProfile
        if profile.askPasswordAtConnect || (!profile.username.isEmpty && profile.password.isEmpty) {
            passwordPrompt = PasswordPrompt(
                profileID: profile.id,
                profileName: profile.name,
                username: profile.username,
                savesPassword: !profile.askPasswordAtConnect
            )
            return
        }

        _ = await connect(using: profile)
    }

    func connectWithPromptPassword(_ password: String, for prompt: PasswordPrompt) async {
        guard
            passwordPrompt == prompt,
            selectedProfileID == prompt.profileID,
            let profile = profiles.first(where: { $0.id == prompt.profileID })
        else {
            return
        }

        passwordPrompt = nil
        var runtimeProfile = profile
        runtimeProfile.password = password
        let passwordToSave = prompt.savesPassword && !profile.askPasswordAtConnect ? password : nil
        let sessionPasswordToCache = profile.askPasswordAtConnect ? password : nil
        _ = await connect(
            using: runtimeProfile,
            passwordToSave: passwordToSave,
            sessionPasswordToCache: sessionPasswordToCache
        )
    }

    func cancelPasswordPrompt() {
        shouldMaintainConnection = false
        passwordPrompt = nil
    }

    private func savePassword(_ password: String, for profile: ConnectionProfile) {
        do {
            var nextProfiles = profiles
            guard let index = nextProfiles.firstIndex(where: { $0.id == profile.id }) else { return }
            nextProfiles[index].password = password
            let collection = try ConnectionProfileCollection(
                profiles: nextProfiles,
                selectedProfileID: selectedProfileID
            )
            try profileStore.save(collection)
            profiles = collection.profiles
            selectedProfileID = collection.selectedProfileID
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func connect(
        using profile: ConnectionProfile,
        passwordToSave: String? = nil,
        sessionPasswordToCache: String? = nil,
        isAutomaticRetry: Bool = false
    ) async -> Bool {
        invalidateTorrentOperationState()
        activeConnectionTask?.cancel()
        activeConnectionTask = nil
        activeConnectionTaskToken = nil
        let attemptToken = UUID()
        connectionToken = attemptToken
        recentPollingMutation = nil
        connectionState = .connecting
        await stopWatchFolderAutomation(
            reason: "The Transmission connection changed before the queued add was confirmed."
        )
        guard connectionToken == attemptToken else { return false }
        if let sessionPasswordToCache {
            sessionPasswords[profile.id] = sessionPasswordToCache
        }
        invalidateDaemonMaintenanceState(clearNotice: true)
        invalidateDaemonOptionsApplyState()
        invalidateRemovalState()
        passwordPrompt = nil
        stopPolling()
        resetRefreshQueue()
        torrentPropertiesEditor = nil
        torrentPropertiesLoadID = nil
        isLoadingTorrentProperties = false
        downloadCompletionTracker.reset()
        resetSelectedTorrentDetail()
        torrentListDeltaAccumulator.reset(for: attemptToken)
        currentTorrentListFieldPlan = nil
        client = nil
        torrents = []
        sessionInfo = nil
        resetDisplayedSpeedAverages()
        sessionStats = nil
        await cancelGlobalBandwidthUpdate()
        guard connectionToken == attemptToken else { return false }

        let nextClient = clientFactory(profile)
        let connectionTask = Task {
            try await nextClient.getSession()
        }
        activeConnectionTask = connectionTask
        activeConnectionTaskToken = attemptToken
        defer {
            if activeConnectionTaskToken == attemptToken {
                activeConnectionTask = nil
                activeConnectionTaskToken = nil
            }
        }
        do {
            let session = try await withTaskCancellationHandler {
                try await connectionTask.value
            } onCancel: {
                connectionTask.cancel()
            }
            guard connectionToken == attemptToken else { return false }
            installTorrentListFieldPlan(rpcVersion: session.rpcVersion)
            client = nextClient
            sessionInfo = session
            connectionState = .connected(rpcVersion: session.rpcVersion)
            bindUnboundAddTorrentsToCurrentConnection()
            presentNextPendingAddTorrentIfPossible()
            reconnectBackoff.reset()
            reconnectAttempt = 0
            if let passwordToSave {
                savePassword(passwordToSave, for: profile)
                guard connectionToken == attemptToken else { return false }
            }
            await enqueueRefresh([.torrentRepair, .sessionStats])
            guard connectionToken == attemptToken else { return false }
            startPolling()
            inspectClipboardForTorrent()
            await startWatchFolderAutomation()
            return true
        } catch {
            guard connectionToken == attemptToken else { return false }
            client = nil
            sessionInfo = nil
            resetDisplayedSpeedAverages()
            sessionStats = nil
            resetSelectedTorrentDetail()
            downloadCompletionTracker.reset()
            if operationWasCancelled(error) {
                if profile.askPasswordAtConnect {
                    sessionPasswords[profile.id] = nil
                }
                shouldMaintainConnection = false
                connectionState = .disconnected
                return false
            }
            if shouldScheduleReconnect(after: error, profile: profile) {
                scheduleReconnect(after: error)
            } else {
                if profile.askPasswordAtConnect {
                    sessionPasswords[profile.id] = nil
                }
                shouldMaintainConnection = false
                connectionState = .failed(error.localizedDescription)
                if !isAutomaticRetry {
                    errorMessage = error.localizedDescription
                }
            }
            return false
        }
    }

    func disconnect() {
        guard rejectConnectionChangeDuringAddIfNeeded() else { return }
        shouldMaintainConnection = false
        cancelReconnect(resetBackoff: true)
        sessionPasswords = [:]
        clearConnectionResources()
        connectionState = .disconnected
    }

    func cancelRetry() {
        disconnect()
    }

    private func clearConnectionResources() {
        invalidateTorrentOperationState()
        scheduleWatchFolderStop(
            reason: "Transmission disconnected before the queued add was confirmed."
        )
        cancelProvisionalMetadataPolling(resetState: true)
        invalidateBoundAddTorrentRequests()
        invalidateDaemonMaintenanceState(clearNotice: true)
        invalidateDaemonOptionsApplyState()
        invalidateRemovalState()
        passwordPrompt = nil
        invalidateGlobalBandwidthState()
        stopPolling()
        resetRefreshQueue()
        torrentPropertiesEditor = nil
        torrentPropertiesLoadID = nil
        isLoadingTorrentProperties = false
        activeConnectionTask?.cancel()
        activeConnectionTask = nil
        activeConnectionTaskToken = nil
        connectionToken = UUID()
        recentPollingMutation = nil
        torrentListDeltaAccumulator.reset(for: nil)
        currentTorrentListFieldPlan = nil
        client = nil
        torrents = []
        downloadCompletionTracker.reset()
        sessionInfo = nil
        resetDisplayedSpeedAverages()
        sessionStats = nil
        selectedTorrentIDs = []
        resetSelectedTorrentDetail()
    }

    private func shouldScheduleReconnect(after error: Error, profile: ConnectionProfile) -> Bool {
        shouldMaintainConnection && profile.autoReconnect && isRetryableConnectionError(error)
    }

    private func isRetryableConnectionError(_ error: Error) -> Bool {
        guard !isCancellation(error) else { return false }
        guard let rpcError = error as? TransmissionRPCError else { return false }
        switch rpcError {
        case .connectionFailed, .sessionIDRejected:
            return true
        default:
            return false
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        error is CancellationError
    }

    private func operationWasCancelled(_ error: Error) -> Bool {
        Task.isCancelled || isCancellation(error)
    }

    private func scheduleReconnect(after error: Error) {
        guard !isAddingTorrent else { return }
        guard reconnectTask == nil else { return }
        let profile = selectedProfile
        guard shouldMaintainConnection, profile.autoReconnect else {
            shouldMaintainConnection = false
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
            return
        }

        let delay = reconnectBackoff.nextDelay()
        reconnectAttempt += 1
        let attempt = reconnectAttempt
        let message = error.localizedDescription
        let token = UUID()
        reconnectToken = token
        connectionState = .reconnecting(
            message: message,
            secondsRemaining: delay,
            attempt: attempt
        )
        let sleeper = reconnectSleeper

        reconnectTask = Task { @MainActor [weak self] in
            defer {
                if self?.reconnectToken == token {
                    self?.reconnectTask = nil
                }
            }
            for secondsRemaining in stride(from: delay, through: 1, by: -1) {
                guard
                    let self,
                    !Task.isCancelled,
                    self.reconnectToken == token,
                    self.shouldMaintainConnection,
                    self.selectedProfileID == profile.id
                else {
                    return
                }
                self.connectionState = .reconnecting(
                    message: message,
                    secondsRemaining: secondsRemaining,
                    attempt: attempt
                )
                do {
                    try await sleeper.sleep(for: .seconds(1))
                } catch {
                    return
                }
            }

            guard
                let self,
                !Task.isCancelled,
                self.reconnectToken == token,
                self.shouldMaintainConnection,
                self.selectedProfileID == profile.id
            else {
                return
            }

            self.reconnectTask = nil
            var runtimeProfile = self.selectedProfile
            var sessionPasswordToCache: String?
            if runtimeProfile.askPasswordAtConnect {
                guard let password = self.sessionPasswords[runtimeProfile.id] else {
                    self.shouldMaintainConnection = false
                    self.connectionState = .failed("Password required to reconnect")
                    return
                }
                runtimeProfile.password = password
                sessionPasswordToCache = password
            }
            _ = await self.connect(
                using: runtimeProfile,
                sessionPasswordToCache: sessionPasswordToCache,
                isAutomaticRetry: true
            )
        }
    }

    private func cancelReconnect(resetBackoff: Bool) {
        reconnectToken = UUID()
        reconnectTask?.cancel()
        reconnectTask = nil
        if resetBackoff {
            reconnectBackoff.reset()
            reconnectAttempt = 0
        }
    }

    private func handleBackgroundRefreshFailure(
        _ error: Error,
        token: UUID,
        surfaceNonRetryableError: Bool = true
    ) {
        guard isCurrentConnection(token: token) else { return }
        guard !isAddingTorrent else { return }
        guard !operationWasCancelled(error) else { return }

        let profile = selectedProfile
        guard isRetryableConnectionError(error) else {
            if surfaceNonRetryableError {
                errorMessage = error.localizedDescription
            }
            return
        }

        let shouldReconnect = shouldScheduleReconnect(after: error, profile: profile)
        clearConnectionResources()
        if shouldReconnect {
            scheduleReconnect(after: error)
        } else {
            shouldMaintainConnection = false
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func refresh() async {
        queueCurrentDetailRefresh(priority: .active, force: true)
        await enqueueRefresh(.all)
    }

    func applyPollingPreferences(_ preferences: PollingPreferences) {
        guard preferences.validationIssues.isEmpty else {
            errorMessage = preferences.validationIssues[0]
            return
        }

        guard preferences != pollingPreferences else { return }
        pollingPreferences = preferences
        preferences.save(to: userDefaults)
        restartPollingForCurrentState()
    }

    func applyApplicationSettingsSnapshot(
        _ snapshot: PersistedApplicationSettingsSnapshot
    ) {
        applyPollingPreferences(snapshot.polling)
        behaviorPreferencesDidChange(snapshot.behavior)
        intakeAutomationPreferencesDidChange(snapshot.intake)
        watchFolderPreferencesDidChange(snapshot.watchFolder)
        peerResolutionPreferencesDidChange(snapshot.peerResolution)
    }

    func persistApplicationPollingPreferences(_ preferences: PollingPreferences) {
        preferences.save(to: userDefaults)
    }

    func clearPeerResolutionCaches() async -> PeerResolutionCacheClearOutcome {
        guard !Task.isCancelled else { return .cancelled }

        cancelPeerResolution()
        let generation = peerResolutionCacheClearLifecycle.begin()
        isClearingPeerResolutionCaches = true
        peerResolutionCacheClearTask?.cancel()
        let clearTask = Task { [peerEndpointResolver] in
            await peerEndpointResolver.clearCaches()
        }
        peerResolutionCacheClearTask = clearTask
        await clearTask.value

        let outcome = peerResolutionCacheClearLifecycle.completionOutcome(
            for: generation,
            isCancelled: Task.isCancelled
        )
        guard outcome != .superseded else { return outcome }

        peerResolutionCacheClearTask = nil
        isClearingPeerResolutionCaches = false
        schedulePeerResolutionForCurrentSnapshot()
        return outcome
    }

    private func observeBehaviorPreferences() {
        behaviorPreferencesCancellable = behaviorPreferencesStore.$preferences
            .dropFirst()
            .sink { [weak self] preferences in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.behaviorPreferencesStore.preferences == preferences else {
                        return
                    }
                    self.behaviorPreferencesDidChange(preferences)
                }
            }
    }

    private func observeIntakeAutomationPreferences() {
        intakeAutomationPreferencesCancellable = intakeAutomationPreferencesStore.$preferences
            .dropFirst()
            .sink { [weak self] preferences in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.intakeAutomationPreferencesStore.preferences == preferences else {
                        return
                    }
                    self.intakeAutomationPreferencesDidChange(preferences)
                }
            }
    }

    private func observePeerResolutionPreferences() {
        peerResolutionPreferencesCancellable = peerResolutionPreferencesStore.$preferences
            .dropFirst()
            .sink { [weak self] preferences in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.peerResolutionPreferencesStore.preferences == preferences else {
                        return
                    }
                    self.peerResolutionPreferencesDidChange(preferences)
                }
            }
    }

    private func observePeerCountryDatabase() {
        peerCountryDatabaseCancellable = peerCountryDatabase.$status
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.synchronizePeerCountryDatabase()
                }
            }
    }

    private func peerResolutionPreferencesDidChange(
        _ preferences: PeerResolutionPreferences
    ) {
        let effective = preferences.effective(
            countryDatabaseAvailable: peerCountryDatabase.status.isInstalled
        )
        guard effective != peerResolutionPreferences else { return }
        peerResolutionPreferences = effective
        schedulePeerResolutionForCurrentSnapshot()
    }

    private func synchronizePeerCountryDatabase() {
        peerCountryDatabaseGeneration &+= 1
        let generation = peerCountryDatabaseGeneration
        cancelPeerResolution()

        Task { [peerCountryDatabase, peerEndpointResolver, weak self] in
            let database: PeerCountryDatabase?
            do {
                database = try await peerCountryDatabase.databaseSnapshot()
            } catch {
                database = nil
            }
            guard let self, self.peerCountryDatabaseGeneration == generation else { return }
            await peerEndpointResolver.installCountryDatabase(database)
            guard self.peerCountryDatabaseGeneration == generation else { return }
            self.peerResolutionPreferencesDidChange(
                self.peerResolutionPreferencesStore.preferences
            )
            self.schedulePeerResolutionForCurrentSnapshot()
        }
    }

    private func observeWatchFolderPreferences() {
        watchFolderPreferencesCancellable = watchFolderPreferencesStore.$snapshot
            .dropFirst()
            .sink { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.watchFolderPreferencesStore.snapshot == snapshot else {
                        return
                    }
                    self.watchFolderPreferencesDidChange(snapshot)
                }
            }
    }

    private func watchFolderPreferencesDidChange(
        _ snapshot: WatchFolderPreferencesSnapshot
    ) {
        guard snapshot != watchFolderPreferences else { return }
        let configurationChanged = snapshot.configuration
            != watchFolderPreferences.configuration
        let processingStateChanged = snapshot.processingState
            != watchFolderPreferences.processingState
        watchFolderPreferences = snapshot

        if configurationChanged {
            activeWatchFolderOwner = nil
            discardPendingWatchFolderAdds()
            Task { @MainActor [weak self] in
                await self?.synchronizeWatchFolderAutomation(
                    stopReason: "Watch-folder settings changed before the queued add was confirmed."
                )
            }
        } else if processingStateChanged {
            let revision = watchFolderCommandRevision
            Task { [watchFolderCoordinator] in
                await watchFolderCoordinator.replaceProcessingState(
                    snapshot.processingState,
                    commandRevision: revision
                )
            }
        }
    }

    private func synchronizeWatchFolderAutomation(stopReason: String) async {
        guard connectionState.isConnected,
              watchFolderPreferences.configuration.isReadyToScan else {
            await stopWatchFolderAutomation(reason: stopReason)
            return
        }
        await startWatchFolderAutomation()
    }

    private func startWatchFolderAutomation() async {
        guard connectionState.isConnected,
              watchFolderPreferences.configuration.isReadyToScan else {
            return
        }
        watchFolderCommandRevision += 1
        let revision = watchFolderCommandRevision
        let owner = WatchFolderRunOwner(
            profileID: selectedProfileID,
            connectionToken: connectionToken
        )
        activeWatchFolderOwner = owner
        let configuration = watchFolderPreferences.configuration
        let processingState = watchFolderPreferences.processingState
        await watchFolderCoordinator.start(
            commandRevision: revision,
            owner: owner,
            configuration: configuration,
            processingState: processingState,
            candidateHandler: { [weak self] candidate, expectedOwner in
                await self?.enqueueWatchFolderCandidate(
                    candidate,
                    owner: expectedOwner
                ) ?? false
            },
            stateHandler: { [weak self] configuration, processingState in
                await self?.saveWatchFolderState(
                    configuration: configuration,
                    processingState: processingState
                )
            },
            errorHandler: { [weak self] message in
                await self?.setWatchFolderError(message)
            }
        )
    }

    private func saveWatchFolderState(
        configuration: WatchFolderConfiguration,
        processingState: WatchFolderProcessingState
    ) {
        do {
            try watchFolderPreferencesStore.save(
                configuration: configuration,
                processingState: processingState
            )
        } catch {
            errorMessage = "Watch-folder state could not be saved: \(error.localizedDescription)"
        }
    }

    private func setWatchFolderError(_ message: String) {
        errorMessage = message
    }

    private func stopWatchFolderAutomation(reason: String) async {
        watchFolderCommandRevision += 1
        let revision = watchFolderCommandRevision
        activeWatchFolderOwner = nil
        discardPendingWatchFolderAdds()
        await watchFolderCoordinator.stop(
            commandRevision: revision,
            reason: reason
        )
    }

    private func scheduleWatchFolderStop(reason: String) {
        watchFolderCommandRevision += 1
        let revision = watchFolderCommandRevision
        activeWatchFolderOwner = nil
        discardPendingWatchFolderAdds()
        Task { [watchFolderCoordinator] in
            await watchFolderCoordinator.stop(
                commandRevision: revision,
                reason: reason
            )
        }
    }

    private func discardPendingWatchFolderAdds() {
        queuedAddTorrents.removeAll { $0.watchFolderJob != nil }
        guard !isAddingTorrent, pendingAddTorrent?.watchFolderJob != nil else {
            return
        }
        cancelProvisionalMetadataPolling(resetState: true)
        showingAddTorrent = false
        pendingAddTorrent = nil
        completedAddTorrentPresentation = nil
        presentNextPendingAddTorrentIfPossible()
    }

    private func enqueueWatchFolderCandidate(
        _ candidate: WatchFolderCandidate,
        owner: WatchFolderRunOwner
    ) -> Bool {
        let configuration = watchFolderPreferences.configuration
        guard connectionState.isConnected,
              owner == activeWatchFolderOwner,
              owner.profileID == selectedProfileID,
              owner.connectionToken == connectionToken,
              configuration.isReadyToScan,
              !containsPendingAddTorrent(
                .localFile(candidate.fileURL),
                profileID: owner.profileID,
                connectionToken: owner.connectionToken
              ) else {
            return false
        }

        queuedAddTorrents.append(PendingAddTorrent(
            source: .localFile(candidate.fileURL),
            profileID: owner.profileID,
            connectionToken: owner.connectionToken,
            initialOptions: .unspecified,
            suggestedDownloadDirectory: candidate.remoteDestination,
            watchFolderJob: candidate.job,
            watchFolderOwner: owner,
            submissionDisposition: configuration.submissionPolicy.disposition,
            directSubmissionDefaults: configuration.submissionPolicy == .submitDirectly
                ? applicationBehaviorPreferences.addDefaults
                : nil
        ))
        presentNextPendingAddTorrentIfPossible()
        return true
    }

    private func intakeAutomationPreferencesDidChange(
        _ preferences: IntakeAutomationPreferences
    ) {
        guard preferences != intakeAutomationPreferences else { return }
        let clipboardWasEnabled = intakeAutomationPreferences.clipboardIntake.isEnabled
        intakeAutomationPreferences = preferences

        if !preferences.clipboardIntake.isEnabled {
            clipboardTorrentIntakeService.resetDeduplication()
        } else if !clipboardWasEnabled {
            clipboardTorrentIntakeService.resetDeduplication()
            inspectClipboardForTorrent()
        }
    }

    private func behaviorPreferencesDidChange(_ preferences: ApplicationBehaviorPreferences) {
        guard preferences != applicationBehaviorPreferences else { return }
        let speedPolicyChanged = preferences.speedAveraging
            != applicationBehaviorPreferences.speedAveraging
        applicationBehaviorPreferences = preferences

        guard speedPolicyChanged else { return }
        downloadSpeedAverager.replacePolicy(preferences.speedAveraging)
        uploadSpeedAverager.replacePolicy(preferences.speedAveraging)
        if let latestRawSessionStats {
            sessionStats = displayedSessionStats(
                from: latestRawSessionStats,
                timestamp: speedSampleClock()
            )
        }
    }

    func updatePollingVisibility(_ visibility: PollingVisibilityState) {
        guard visibility != pollingVisibility else { return }
        pollingVisibility = visibility
        if visibility == .background {
            dropQueuedDetailPrefetches()
        }
        restartPollingForCurrentState()
    }

    func setTorrentTableProjection(
        visibleColumns: Set<TorrentTableColumnID>,
        activeSortColumn: TorrentTableColumnID
    ) {
        var normalizedVisibleColumns = visibleColumns
        normalizedVisibleColumns.insert(.name)
        guard
            normalizedVisibleColumns != torrentTableVisibleColumns
                || activeSortColumn != torrentTableActiveSortColumn
        else {
            return
        }

        let previousPlan = currentTorrentListFieldPlan
        torrentTableVisibleColumns = normalizedVisibleColumns
        torrentTableActiveSortColumn = activeSortColumn
        torrentListFieldPlanRevision &+= 1

        guard let rpcVersion = connectedRPCVersion else {
            currentTorrentListFieldPlan = nil
            return
        }

        let nextPlan = makeTorrentListFieldPlan(rpcVersion: rpcVersion)
        currentTorrentListFieldPlan = nextPlan
        guard
            let previousPlan,
            !Set(nextPlan.fullFields).isSubset(of: Set(previousPlan.fullFields))
        else {
            return
        }

        Task { [weak self] in
            await self?.enqueueRefresh(.torrentRepair)
        }
    }

    func startAll() async {
        await runTorrentAction(
            ids: torrentListProjection.allRowIDs,
            mutation: .state
        ) { client in
            try await client.start()
        }
    }

    func stopAll() async {
        await runTorrentAction(
            ids: torrentListProjection.allRowIDs,
            mutation: .state
        ) { client in
            try await client.stop()
        }
    }

    func setGlobalSpeedLimit(_ preset: SessionSpeedPreset, direction: SessionSpeedLimitDirection) async {
        guard canSetGlobalSpeedLimit, let client else { return }
        await updateGlobalBandwidth {
            try await client.setSpeedLimit(
                direction: direction,
                enabled: preset.limitKBps != nil,
                limitKBps: preset.limitKBps
            )
        }
    }

    func setAlternateSpeedEnabled(_ isEnabled: Bool) async {
        guard canToggleAlternateSpeed, let client else { return }
        await updateGlobalBandwidth {
            try await client.setAlternateSpeedEnabled(isEnabled)
        }
    }

    func isCurrentSpeedPreset(_ preset: SessionSpeedPreset, direction: SessionSpeedLimitDirection) -> Bool {
        sessionInfo?.isCurrentSpeedPreset(preset, direction: direction) == true
    }

    func speedPresets(for direction: SessionSpeedLimitDirection) -> [SessionSpeedPreset] {
        let standardPresets = [.unlimited] + selectedProfile.transferPreferences
            .speedPresetsKBps(for: direction)
            .map(SessionSpeedPreset.limited)
        guard let sessionInfo, !sessionInfo.isAlternateSpeedEnabled else { return standardPresets }
        let currentLimit = switch direction {
        case .download: sessionInfo.daemonOptions.downloadSpeedLimit
        case .upload: sessionInfo.daemonOptions.uploadSpeedLimit
        }
        guard currentLimit.isEnabled else { return standardPresets }
        let currentPreset = SessionSpeedPreset.limited(currentLimit.limitKBps)
        guard !standardPresets.contains(currentPreset) else { return standardPresets }
        return [.unlimited] + (standardPresets.dropFirst() + [currentPreset]).sorted {
            ($0.limitKBps ?? 0) < ($1.limitKBps ?? 0)
        }
    }

    func startSelected() async {
        await runSelectionAction(mutation: .state) { client, ids in
            try await client.start(ids: ids)
        }
    }

    func startSelectedNow() async {
        await runSelectionAction(mutation: .state) { client, ids in
            try await client.startNow(ids: ids)
        }
    }

    func stopSelected() async {
        await runSelectionAction(mutation: .state) { client, ids in
            try await client.stop(ids: ids)
        }
    }

    func requestVerifySelected() {
        guard verifyConfirmation == nil, canVerifySelectedTorrents else { return }
        let selectedTorrents = selectedTorrentsInDisplayOrder()
        guard let owner = promptedTorrentMutationOwner(for: selectedTorrents) else { return }

        do {
            let ownership = try TorrentOperationOwnership(
                kind: .verify,
                profileID: owner.profileID,
                connectionToken: owner.connectionToken,
                torrentHashes: owner.targets.map(\.hash)
            )
            let confirmation = TorrentVerifyConfirmation(
                ownership: ownership,
                torrentNames: selectedTorrents.map(\.name)
            )
            pendingVerifyOperation = PendingVerifyOperation(
                confirmation: confirmation,
                owner: owner
            )
            verifyConfirmation = confirmation
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func cancelVerifyConfirmation() {
        pendingVerifyOperation = nil
        verifyConfirmation = nil
    }

    func confirmVerify() async {
        guard
            let pendingVerifyOperation,
            verifyConfirmation == pendingVerifyOperation.confirmation
        else {
            return
        }
        self.pendingVerifyOperation = nil
        verifyConfirmation = nil

        let expectation: TorrentOperationCompletionExpectation
        do {
            expectation = try .verify(
                ownership: pendingVerifyOperation.confirmation.ownership
            )
        } catch {
            guard isCurrentPromptedTorrentMutationOwner(pendingVerifyOperation.owner) else { return }
            errorMessage = error.localizedDescription
            return
        }

        await runTrackedTorrentOperation(
            owner: pendingVerifyOperation.owner,
            expectation: expectation,
            mutation: .verify
        ) { client, hashes in
            try await client.verify(hashes: hashes)
        }
    }

    func dismissTorrentOperationFeedback(operationID: UUID) {
        torrentOperationFeedbackLifecycle.removeTerminal(operationID: operationID)
        publishTorrentOperationFeedback()
    }

    func reannounceSelected() async {
        await runSelectionAction(mutation: .reannounce) { client, ids in
            try await client.reannounce(ids: ids)
        }
    }

    func queueMoveSelectedTop() async {
        await runSelectionAction(mutation: .queue) { client, ids in
            try await client.queueMoveTop(ids: ids)
        }
    }

    func queueMoveSelectedUp() async {
        await runSelectionAction(mutation: .queue) { client, ids in
            try await client.queueMoveUp(ids: ids)
        }
    }

    func queueMoveSelectedDown() async {
        await runSelectionAction(mutation: .queue) { client, ids in
            try await client.queueMoveDown(ids: ids)
        }
    }

    func queueMoveSelectedBottom() async {
        await runSelectionAction(mutation: .queue) { client, ids in
            try await client.queueMoveBottom(ids: ids)
        }
    }

    func setSelectedBandwidthPriority(_ priority: TransmissionRPCClient.BandwidthPriority) async {
        await runSelectionAction(mutation: .bandwidthPriority) { client, ids in
            try await client.setBandwidthPriority(priority, ids: ids)
        }
    }

    func requestSetSelectedLocation() {
        requestSelectedLocationChange(moveData: false)
    }

    func requestMoveSelectedData() {
        requestSelectedLocationChange(moveData: true)
    }

    func requestRenameSelectedTorrent() {
        guard canRenameSelectedTorrent, let torrent = torrentRows(for: selectedTorrentIDs).first else { return }
        guard let owner = promptedTorrentMutationOwner(for: [torrent]) else { return }
        let oldPath = torrent.name
        guard let newName = torrentOperationPrompter.requestRename(currentName: oldPath) else { return }

        Task { [weak self] in
            await self?.renameTorrent(owner: owner, path: oldPath, name: newName)
        }
    }

    private func setSelectedLabels(fromCommaSeparatedText text: String) async {
        await runSelectionAction(mutation: .labels) { client, ids in
            try await client.setLabels(fromCommaSeparatedText: text, ids: ids)
        }
    }

    func requestSetSelectedLabels() {
        guard canSetSelectedTorrentLabels else { return }
        labelDraft = selectedTorrent?.labels.joined(separator: ", ") ?? ""
        showingLabelEditor = true
    }

    func applySelectedLabelDraft() async {
        let labels = labelDraft
        showingLabelEditor = false
        await setSelectedLabels(fromCommaSeparatedText: labels)
    }

    func clearSelectedLabels() async {
        await setSelectedLabels(fromCommaSeparatedText: "")
    }

    func requestEditSelectedTorrentProperties() async {
        await requestEditSelectedTorrentProperties(supersedingCurrentLoad: false)
    }

    private func requestEditSelectedTorrentProperties(supersedingCurrentLoad: Bool) async {
        guard
            canActOnTorrents(in: selectedTorrentIDs),
            supersedingCurrentLoad || !isLoadingTorrentProperties,
            let client,
            let rpcVersion = connectedRPCVersion
        else {
            return
        }

        let selectedTorrents = selectedTorrentsInDisplayOrder()
        guard
            let owner = promptedTorrentMutationOwner(for: selectedTorrents),
            let sourceTarget = owner.targets.first
        else { return }
        let torrentIDs = owner.targets.map(\.id)
        let sourceTorrentID = sourceTarget.id

        let loadID = UUID()
        torrentPropertiesLoadID = loadID
        isLoadingTorrentProperties = true
        defer {
            if torrentPropertiesLoadID == loadID {
                torrentPropertiesLoadID = nil
                isLoadingTorrentProperties = false
            }
        }

        do {
            let snapshot = try await client.fetchTorrentProperties(id: sourceTorrentID, hash: sourceTarget.hash)
            guard
                isCurrentPromptedTorrentMutationOwner(owner),
                torrentPropertiesLoadID == loadID,
                Set(torrentIDs) == selectedTorrentIDs
            else {
                return
            }

            let fallbackName = selectedTorrents.first(where: { $0.id == sourceTorrentID })?.name ?? "Torrent"
            torrentPropertiesEditor = TorrentPropertiesEditorState(
                owner: owner,
                torrentName: snapshot.name.isEmpty ? fallbackName : snapshot.name,
                rpcVersion: rpcVersion,
                draft: snapshot.draft()
            )
        } catch {
            guard
                isCurrentPromptedTorrentMutationOwner(owner),
                torrentPropertiesLoadID == loadID,
                Set(torrentIDs) == selectedTorrentIDs
            else { return }
            errorMessage = error.localizedDescription
        }
    }

    func performPrimaryTorrentAction(in ids: Set<TorrentSummary.ID>) async {
        guard ids.count == 1, let torrent = torrentRows(for: ids).first else { return }
        selectedTorrentIDs = ids

        let isComplete = torrent.status == .seeding
            || torrent.status == .finished
            || (torrent.percentDone >= 1 && torrent.sizeWhenDone > 0 && torrent.leftUntilDone == 0)
        if isComplete {
            do {
                try localFileActionService.open(paths: try selectedLocalPaths())
                return
            } catch is LocalTorrentPathResolutionError {
                // Match transgui: unavailable mapped data falls back to torrent properties.
            } catch LocalFileActionError.pathMissing {
                // Match transgui: unavailable local data falls back to torrent properties.
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        await requestEditSelectedTorrentProperties(supersedingCurrentLoad: true)
    }

    func cancelTorrentPropertiesEditing() {
        torrentPropertiesEditor = nil
    }

    func applyTorrentProperties() async {
        guard var editor = torrentPropertiesEditor, !editor.isApplying else { return }
        guard isCurrentPromptedTorrentMutationOwner(editor.owner) else {
            torrentPropertiesEditor = nil
            errorMessage = "The selected torrents changed. Reopen Properties before applying changes."
            return
        }
        let client = editor.owner.client

        editor.isApplying = true
        torrentPropertiesEditor = editor
        let editorID = editor.id
        let update = editor.draft.update(
            forceAllGeneral: editor.selectionCount > 1,
            includeTrackers: editor.selectionCount == 1 || editor.rpcVersion >= 17
        )
        let detailMutationID = beginDetailMutation(ids: editor.torrentIDs, mutation: .properties(update))
        defer {
            finishDetailMutation(
                detailMutationID,
                resumeRefresh: isCurrentPromptedTorrentMutationConnection(editor.owner)
            )
        }

        do {
            try await client.setTorrentProperties(
                update: update,
                hashes: editor.owner.targets.map(\.hash),
                rpcVersion: editor.rpcVersion
            )
            guard torrentPropertiesEditor?.id == editorID else { return }
            guard isCurrentPromptedTorrentMutationOwner(editor.owner) else {
                torrentPropertiesEditor = nil
                return
            }
            finishDetailMutation(detailMutationID)
            torrentPropertiesEditor = nil
            await refreshAfterTorrentMutation(
                ids: editor.torrentIDs,
                invalidation: mutationRefreshPolicy.invalidation(for: .properties(update))
            )
        } catch {
            guard torrentPropertiesEditor?.id == editorID else { return }
            guard isCurrentPromptedTorrentMutationOwner(editor.owner) else {
                torrentPropertiesEditor = nil
                return
            }
            torrentPropertiesEditor?.isApplying = false
            errorMessage = error.localizedDescription
        }
    }

    func setTorrentFilesWanted(
        _ wanted: Bool,
        fileIndexes: [Int],
        owner: DetailMutationOwner
    ) async {
        await runTorrentFileAction(fileIndexes: fileIndexes, owner: owner) { client, torrentID, indexes in
            try await client.setFileWanted(wanted, torrentID: torrentID, fileIndexes: indexes)
        }
    }

    func setTorrentFilesPriority(
        _ priority: TorrentFilePriority,
        fileIndexes: [Int],
        owner: DetailMutationOwner
    ) async {
        await runTorrentFileAction(fileIndexes: fileIndexes, owner: owner) { client, torrentID, indexes in
            try await client.setFilePriority(priority, torrentID: torrentID, fileIndexes: indexes)
        }
    }

    func renameTorrentPath(
        node: TorrentFileNode,
        newBasename: String,
        owner: TorrentPathRenameOwner
    ) async {
        guard
            selectedTorrentPathRenameOwner == owner,
            let torrent = selectedTorrentsInDisplayOrder().first
        else {
            return
        }

        let request: TorrentPathRenameRequest
        do {
            request = try TorrentPathRenameValidator.request(
                torrentHash: torrent.hashString,
                torrentID: torrent.id,
                owner: owner,
                node: node,
                newBasename: newBasename
            )
        } catch {
            guard selectedTorrentPathRenameOwner == owner else { return }
            errorMessage = error.localizedDescription
            return
        }

        guard let client = validatedTorrentPathRenameClient(for: request) else { return }
        let detailMutationID = beginDetailMutation(ids: [request.torrentID], mutation: .rename)
        let submittedPaneRevision = selectedDetailPaneRevisions[.files, default: 0]
        defer { finishDetailMutation(detailMutationID) }
        do {
            try await client.renamePath(request)
            finishDetailMutation(detailMutationID)
            guard isCurrentTorrentPathRenameRequest(request, submittedPaneRevision: submittedPaneRevision) else { return }
            await refreshAfterTorrentMutation(
                ids: [request.torrentID],
                invalidation: mutationRefreshPolicy.invalidation(for: .rename)
            )
        } catch {
            guard isCurrentTorrentPathRenameRequest(request, submittedPaneRevision: submittedPaneRevision) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func addTorrentTracker(_ announceURL: String, owner: DetailMutationOwner) async {
        await runTorrentTrackerAction(owner: owner) { client, torrentHash in
            try await client.addTracker(announceURL: announceURL, torrentHash: torrentHash)
        }
    }

    func replaceTorrentTracker(
        id: Int,
        announceURL: String,
        owner: DetailMutationOwner
    ) async {
        await runTorrentTrackerAction(owner: owner) { client, torrentHash in
            try await client.replaceTracker(id: id, announceURL: announceURL, torrentHash: torrentHash)
        }
    }

    func removeTorrentTrackers(ids: [Int], owner: DetailMutationOwner) async {
        await runTorrentTrackerAction(owner: owner) { client, torrentHash in
            try await client.removeTrackers(ids: ids, torrentHash: torrentHash)
        }
    }

    func copySelectedLocalPath() {
        runLocalFileAction {
            try localFileActionService.copy(paths: try selectedLocalPaths())
        }
    }

    func revealSelectedInFinder() {
        runLocalFileAction {
            try localFileActionService.reveal(paths: try selectedLocalPaths())
        }
    }

    func openSelectedLocalPath() {
        runLocalFileAction {
            try localFileActionService.open(paths: try selectedLocalPaths())
        }
    }

    func copySelectedMagnetLinks() async {
        await copyMagnetLinks(in: selectedTorrentIDs)
    }

    func copyMagnetLinks(in torrentIDs: Set<TorrentSummary.ID>) async {
        guard
            canCopyMagnetLinks(in: torrentIDs),
            let client,
            let rpcVersion = connectedRPCVersion
        else {
            return
        }

        let orderedTorrents = torrentListProjection.visibleRows(for: torrentIDs)
        guard orderedTorrents.count == torrentIDs.count else { return }
        let hashes = orderedTorrents.map { $0.hashString.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard hashes.allSatisfy({ !$0.isEmpty }) else {
            errorMessage = "Transmission did not return stable torrent identities. Refresh the list before copying magnet links."
            return
        }

        let token = connectionToken
        do {
            let magnetLinks = try await client.fetchMagnetLinks(hashes: hashes, rpcVersion: rpcVersion)
            guard isCurrentConnection(token: token) else { return }
            try magnetLinkPasteboardService.copy(magnetLinks)
        } catch {
            guard isCurrentConnection(token: token) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func requestRemoveSelected(deleteLocalData: Bool = false) {
        requestRemoveTorrents(in: selectedTorrentIDs, deleteLocalData: deleteLocalData)
    }

    func requestRemoveTorrents(in torrentIDs: Set<TorrentSummary.ID>, deleteLocalData: Bool = false) {
        let canRequestRemoval = deleteLocalData
            ? canDeleteTorrentData(in: torrentIDs)
            : canRemoveTorrents(in: torrentIDs)
        guard canRequestRemoval else { return }

        let selectedTorrents = torrentListProjection.visibleRows(for: torrentIDs)
        guard selectedTorrents.count == torrentIDs.count else { return }
        let hashes = selectedTorrents.map { $0.hashString.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard hashes.allSatisfy({ !$0.isEmpty }) else {
            errorMessage = "Transmission did not return stable torrent identities. Refresh the list before removing torrents."
            return
        }
        removalConfirmation = RemovalConfirmation(
            torrentIDs: selectedTorrents.map(\.id),
            torrentHashes: hashes,
            torrentNames: selectedTorrents.map(\.name),
            totalSize: downloadedRemovalSize(for: selectedTorrents),
            profileID: selectedProfileID,
            connectionToken: connectionToken,
            deleteLocalData: deleteLocalData
        )
    }

    func cancelRemoval(_ confirmation: RemovalConfirmation? = nil) {
        guard !isRemoving else { return }
        if let confirmation, removalConfirmation?.id != confirmation.id { return }
        removalConfirmation = nil
    }

    func requestAddTorrent(initialOptions: AddTorrentInitialOptions = .unspecified) {
        requestAddTorrents([.manual], initialOptions: initialOptions)
    }

    func requestAddTorrent(
        source: String,
        initialOptions: AddTorrentInitialOptions = .unspecified
    ) {
        requestAddTorrents([.remote(source)], initialOptions: initialOptions)
    }

    func requestAddTorrent(
        fileURL: URL,
        initialOptions: AddTorrentInitialOptions = .unspecified
    ) {
        requestAddTorrents([.localFile(fileURL)], initialOptions: initialOptions)
    }

    /// Called only from application lifecycle events or an explicit preference
    /// transition. Clipboard contents are never persisted or written back.
    func inspectClipboardForTorrent() {
        guard connectionState.isConnected,
              intakeAutomationPreferences.clipboardIntake.isEnabled,
              let payload = clipboardTorrentPayloadReader.readIfChanged() else {
            return
        }

        switch clipboardTorrentIntakeService.inspect(
            payload,
            policy: intakeAutomationPreferences.clipboardIntake
        ) {
        case .candidate(let candidate):
            requestAddTorrent(source: candidate.normalizedSource)
        case .ignore:
            break
        }
    }

    func requestAddTorrents(
        _ sources: [PendingAddTorrent.Source],
        initialOptions: AddTorrentInitialOptions = .unspecified
    ) {
        let requests = sources.map {
            UnboundPendingAddTorrent(source: $0, initialOptions: initialOptions)
        }
        guard connectionState.isConnected, client != nil else {
            enqueueUnboundAddTorrents(requests)
            return
        }
        bindAddTorrentsToCurrentConnection(requests)
        presentNextPendingAddTorrentIfPossible()
    }

    private func enqueueUnboundAddTorrents(_ requests: [UnboundPendingAddTorrent]) {
        for request in requests where !unboundAddTorrents.contains(where: {
            $0.source == request.source
        }) {
            unboundAddTorrents.append(request)
        }
    }

    private func bindUnboundAddTorrentsToCurrentConnection() {
        guard connectionState.isConnected, client != nil, !unboundAddTorrents.isEmpty else {
            return
        }
        let requests = unboundAddTorrents
        unboundAddTorrents = []
        bindAddTorrentsToCurrentConnection(requests)
    }

    private func bindAddTorrentsToCurrentConnection(
        _ requests: [UnboundPendingAddTorrent]
    ) {
        guard connectionState.isConnected, client != nil else {
            enqueueUnboundAddTorrents(requests)
            return
        }
        let profileID = selectedProfileID
        let token = connectionToken
        let savedDefaults = applicationBehaviorPreferences.addDefaults
        let dispositionPolicy = AddTorrentSubmissionDispositionPolicy()
        let promptsForDownloadOptions =
            applicationBehaviorPreferences.promptsForDownloadOptions
        for request in requests where !containsPendingAddTorrent(
            request.source,
            profileID: profileID,
            connectionToken: token
        ) {
            let disposition = dispositionPolicy.disposition(
                for: addTorrentIntakeSourceKind(for: request.source),
                promptsForDownloadOptions: promptsForDownloadOptions
            )
            queuedAddTorrents.append(
                PendingAddTorrent(
                    source: request.source,
                    profileID: profileID,
                    connectionToken: token,
                    initialOptions: request.initialOptions,
                    submissionDisposition: disposition,
                    directSubmissionDefaults: disposition == .submitDirectly
                        ? savedDefaults
                        : nil
                )
            )
        }
    }

    private func addTorrentIntakeSourceKind(
        for source: PendingAddTorrent.Source
    ) -> AddTorrentIntakeSourceKind {
        switch source {
        case .manual:
            .manual
        case .remote:
            .remote
        case .localFile:
            .localFile
        }
    }

    func registerAddTorrentPresentationOwner(_ ownerID: UUID) {
        guard !addTorrentPresentationOwners.contains(ownerID) else { return }
        addTorrentPresentationOwners.append(ownerID)
        presentNextPendingAddTorrentIfPossible()
    }

    func unregisterAddTorrentPresentationOwner(_ ownerID: UUID) {
        addTorrentPresentationOwners.removeAll { $0 == ownerID }
        guard
            !isAddingTorrent,
            var request = pendingAddTorrent,
            request.presentationOwnerID == ownerID
        else {
            return
        }

        cancelProvisionalMetadataPolling(resetState: true)

        showingAddTorrent = false
        pendingAddTorrent = nil
        if completedAddTorrentPresentation?.requestID == request.id,
           completedAddTorrentPresentation?.ownerID == ownerID {
            completedAddTorrentPresentation = nil
            presentNextPendingAddTorrentIfPossible()
            return
        }
        completedAddTorrentPresentation = nil
        request.presentationOwnerID = nil
        queuedAddTorrents.insert(request, at: 0)
        presentNextPendingAddTorrentIfPossible()
    }

    func presentedAddTorrent(for ownerID: UUID) -> PendingAddTorrent? {
        guard
            showingAddTorrent,
            pendingAddTorrent?.presentationOwnerID == ownerID
        else {
            return nil
        }
        return pendingAddTorrent
    }

    func addTorrentDestinationRecommendation(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID,
        metainfoFiles: [TorrentMetainfoFile]
    ) async -> AddTorrentDestinationRecommendationEvaluation? {
        guard
            showingAddTorrent,
            let request = pendingAddTorrent,
            request.id == requestID,
            request.presentationOwnerID == presentationOwnerID,
            request.profileID == selectedProfileID,
            request.connectionToken == connectionToken,
            let profile = profiles.first(where: { $0.id == request.profileID })
        else {
            return nil
        }

        let ownership = AddTorrentDestinationRecommendationOwnership(
            requestID: request.id,
            presentationOwnerID: presentationOwnerID,
            profileID: request.profileID,
            connectionToken: request.connectionToken
        )
        let response = await addTorrentDestinationRecommendationService.evaluate(
            AddTorrentDestinationRecommendationServiceRequest(
                ownership: ownership,
                rules: profile.transferPreferences.addDestinationRules,
                metainfoFiles: metainfoFiles
            )
        )
        guard
            !Task.isCancelled,
            response?.ownership == ownership,
            showingAddTorrent,
            let currentRequest = pendingAddTorrent,
            currentRequest.id == ownership.requestID,
            currentRequest.presentationOwnerID == ownership.presentationOwnerID,
            currentRequest.profileID == ownership.profileID,
            currentRequest.connectionToken == ownership.connectionToken,
            selectedProfileID == ownership.profileID,
            connectionToken == ownership.connectionToken
        else {
            return nil
        }
        return response?.evaluation
    }

    func addTorrentPresentationWillDismiss(
        requestID: PendingAddTorrent.ID,
        ownerID: UUID
    ) {
        guard
            !isAddingTorrent,
            showingAddTorrent,
            isCurrentAddTorrentPresentation(requestID: requestID, ownerID: ownerID)
        else {
            return
        }
        cancelProvisionalMetadataPolling(resetState: true)
        showingAddTorrent = false
    }

    @discardableResult
    func cancelPendingAddTorrent(
        requestID: PendingAddTorrent.ID,
        ownerID: UUID
    ) -> Bool {
        guard
            !isAddingTorrent,
            completedAddTorrentPresentation == nil,
            isCurrentAddTorrentPresentation(requestID: requestID, ownerID: ownerID)
        else {
            return false
        }
        cancelProvisionalMetadataPolling(resetState: true)
        scheduleWatchFolderJobResolution(
            for: pendingAddTorrent,
            acknowledgment: .failed(
                message: "The queued watch-folder add was cancelled before Transmission confirmed it."
            )
        )
        completedAddTorrentPresentation = (requestID, ownerID)
        return true
    }

    func addTorrentSheetDidDismiss(
        requestID: PendingAddTorrent.ID,
        ownerID: UUID
    ) {
        guard
            !isAddingTorrent,
            !showingAddTorrent,
            isCurrentAddTorrentPresentation(requestID: requestID, ownerID: ownerID)
        else {
            return
        }
        cancelProvisionalMetadataPolling(resetState: true)
        if completedAddTorrentPresentation == nil {
            scheduleWatchFolderJobResolution(
                for: pendingAddTorrent,
                acknowledgment: .failed(
                    message: "The queued watch-folder add was dismissed before Transmission confirmed it."
                )
            )
        }
        completedAddTorrentPresentation = nil
        showingAddTorrent = false
        pendingAddTorrent = nil
        presentNextPendingAddTorrentIfPossible()
    }

    private func containsPendingAddTorrent(
        _ source: PendingAddTorrent.Source,
        profileID: ConnectionProfile.ID,
        connectionToken: UUID
    ) -> Bool {
        let isDuplicate: (PendingAddTorrent) -> Bool = {
            $0.source == source
                && $0.profileID == profileID
                && $0.connectionToken == connectionToken
        }
        return pendingAddTorrent.map(isDuplicate) == true || queuedAddTorrents.contains(where: isDuplicate)
    }

    private func presentNextPendingAddTorrentIfPossible() {
        guard
            !showingAddTorrent,
            pendingAddTorrent == nil,
            !queuedAddTorrents.isEmpty
        else {
            return
        }

        var request = queuedAddTorrents[0]
        let ownerID: UUID
        switch request.submissionDisposition {
        case .submitDirectly:
            guard connectionState.isConnected, client != nil else {
                return
            }
            ownerID = directAddTorrentOwnerID
        case .presentOptions:
            guard let presentationOwnerID = addTorrentPresentationOwners.first else {
                return
            }
            ownerID = presentationOwnerID
        }

        queuedAddTorrents.removeFirst()
        cancelProvisionalMetadataPolling(resetState: true)
        request.presentationOwnerID = ownerID
        pendingAddTorrent = request
        if request.submissionDisposition == .submitDirectly {
            showingAddTorrent = false
            startDirectAddTorrentSubmission(requestID: request.id)
        } else {
            showingAddTorrent = true
        }
    }

    private func startDirectAddTorrentSubmission(requestID: PendingAddTorrent.ID) {
        guard let request = currentDirectAddTorrentRequest(requestID: requestID) else {
            discardDirectAddTorrentPreparation(requestID: requestID)
            return
        }
        let ownership = DirectAddTorrentPreparationOwnership(
            requestID: request.id,
            profileID: request.profileID,
            connectionToken: request.connectionToken,
            taskID: UUID()
        )
        directAddTorrentPreparationOwnership = ownership
        directAddTorrentTask = Task { @MainActor [weak self] in
            await self?.performDirectAddTorrentSubmission(ownership: ownership)
        }
    }

    private func performDirectAddTorrentSubmission(
        ownership: DirectAddTorrentPreparationOwnership
    ) async {
        defer {
            if directAddTorrentPreparationOwnership == ownership {
                directAddTorrentTask = nil
                directAddTorrentPreparationOwnership = nil
            }
        }

        guard let request = currentDirectAddTorrentRequest(ownership: ownership) else {
            discardDirectAddTorrentPreparation(ownership: ownership)
            return
        }
        let source: AddTorrentDirectSubmissionSource
        switch request.source {
        case .manual:
            transitionDirectAddTorrentToOptions(
                ownership: ownership,
                message: "Toolbar Add needs a source before it can be submitted."
            )
            return
        case .remote(let remoteSource):
            source = .remote(remoteSource)
        case .localFile(let fileURL):
            source = .localFile(
                fileURL,
                expectedStableIdentity: request.watchFolderJob?.stableFileIdentity
            )
        }

        let preparationOutcome: AddTorrentDirectSubmissionPreparationOutcome
        do {
            preparationOutcome = try await directAddTorrentPreparationService.prepare(
                AddTorrentDirectSubmissionPreparationRequest(
                    source: source,
                    initialOptions: request.initialOptions,
                    savedDefaults: request.directSubmissionDefaults
                        ?? applicationBehaviorPreferences.addDefaults,
                    explicitDownloadDirectory: request.suggestedDownloadDirectory
                )
            )
        } catch is CancellationError {
            return
        } catch {
            transitionDirectAddTorrentToOptions(
                ownership: ownership,
                message: error.localizedDescription
            )
            return
        }

        guard currentDirectAddTorrentRequest(ownership: ownership) != nil else {
            discardDirectAddTorrentPreparation(ownership: ownership)
            return
        }

        switch preparationOutcome {
        case .requiresInteraction(let message):
            transitionDirectAddTorrentToOptions(
                ownership: ownership,
                message: message
            )
        case .ready(let preparation):
            let result: AddTorrentSubmissionResult
            switch preparation.payload {
            case .remote(let remoteSource):
                result = await addTorrent(
                    requestID: ownership.requestID,
                    presentationOwnerID: directAddTorrentOwnerID,
                    source: remoteSource,
                    startPaused: preparation.startPaused,
                    downloadDirectory: preparation.downloadDirectory,
                    peerLimit: preparation.peerLimit
                )
            case .localFile(
                let snapshot,
                let sourceFileURL,
                let fileSelection,
                let localTrackerURLs
            ):
                result = await addTorrentFile(
                    requestID: ownership.requestID,
                    presentationOwnerID: directAddTorrentOwnerID,
                    data: snapshot.data,
                    sourceFileURL: sourceFileURL,
                    sourceFileIdentity: snapshot.identity,
                    startPaused: preparation.startPaused,
                    downloadDirectory: preparation.downloadDirectory,
                    fileSelection: fileSelection,
                    localTrackerURLs: localTrackerURLs,
                    peerLimit: preparation.peerLimit
                )
            }
            handleDirectAddTorrentSubmissionResult(result)
        }
    }

    private func currentDirectAddTorrentRequest(
        requestID: PendingAddTorrent.ID
    ) -> PendingAddTorrent? {
        guard let request = pendingAddTorrent,
              request.id == requestID,
              request.presentationOwnerID == directAddTorrentOwnerID,
              request.submissionDisposition == .submitDirectly,
              request.profileID == selectedProfileID,
              request.connectionToken == connectionToken,
              connectionState.isConnected,
              client != nil else {
            return nil
        }
        return request
    }

    private func currentDirectAddTorrentRequest(
        ownership: DirectAddTorrentPreparationOwnership
    ) -> PendingAddTorrent? {
        guard directAddTorrentPreparationOwnership == ownership,
              let request = currentDirectAddTorrentRequest(requestID: ownership.requestID),
              request.profileID == ownership.profileID,
              request.connectionToken == ownership.connectionToken else {
            return nil
        }
        return request
    }

    private func transitionDirectAddTorrentToOptions(
        ownership: DirectAddTorrentPreparationOwnership,
        message: String
    ) {
        guard !isAddingTorrent,
              var request = currentDirectAddTorrentRequest(ownership: ownership) else {
            return
        }
        request.submissionDisposition = .presentOptions
        request.presentationOwnerID = nil
        pendingAddTorrent = nil
        queuedAddTorrents.insert(request, at: 0)
        errorMessage = "The torrent could not be added automatically. \(message) Review the options and try again."
        presentNextPendingAddTorrentIfPossible()
    }

    private func invalidateBoundAddTorrentRequests() {
        directAddTorrentPreparationOwnership = nil
        directAddTorrentTask?.cancel()
        directAddTorrentTask = nil
        queuedAddTorrents.removeAll()
        guard !isAddingTorrent else { return }
        showingAddTorrent = false
        pendingAddTorrent = nil
        completedAddTorrentPresentation = nil
    }

    private func discardDirectAddTorrentPreparation(
        ownership: DirectAddTorrentPreparationOwnership
    ) {
        guard directAddTorrentPreparationOwnership == ownership else { return }
        discardDirectAddTorrentPreparation(requestID: ownership.requestID)
    }

    private func discardDirectAddTorrentPreparation(
        requestID: PendingAddTorrent.ID
    ) {
        queuedAddTorrents.removeAll { $0.id == requestID }
        guard !isAddingTorrent,
              let request = pendingAddTorrent,
              request.id == requestID,
              request.presentationOwnerID == directAddTorrentOwnerID else {
            return
        }
        showingAddTorrent = false
        pendingAddTorrent = nil
        completedAddTorrentPresentation = nil
    }

    private func handleDirectAddTorrentSubmissionResult(
        _ result: AddTorrentSubmissionResult
    ) {
        switch result {
        case .succeeded, .awaitingSaveAs, .confirmDuplicateTrackers:
            break
        case .failed(let message):
            errorMessage = "The torrent could not be added automatically. \(message) Review the options and try again."
        }
    }

    private func isCurrentAddTorrentPresentation(
        requestID: PendingAddTorrent.ID,
        ownerID: UUID
    ) -> Bool {
        pendingAddTorrent?.id == requestID
            && pendingAddTorrent?.presentationOwnerID == ownerID
    }

    func probeAddTorrentFreeSpace(path: String) async -> AddTorrentFreeSpaceProbeResult? {
        guard canProbeAddTorrentFreeSpace,
              let path = AddTorrentDestinationHistory.normalizedDestination(path),
              let client else { return nil }

        do {
            let sizeBytes = try await client.freeSpace(path: path)
            return .available(path: path, sizeBytes: sizeBytes)
        } catch {
            return .failed(path: path, message: error.localizedDescription)
        }
    }

    func confirmRemoval(_ confirmation: RemovalConfirmation) async {
        guard activeRemovalID == nil, !isRemoving else { return }
        guard
            confirmation.profileID == selectedProfileID,
            confirmation.connectionToken == connectionToken,
            connectionState.isConnected,
            let client
        else {
            cancelRemoval(confirmation)
            errorMessage = "The Transmission connection changed. Review the current torrents before removing them."
            return
        }

        let torrentIDs = Set(confirmation.torrentIDs)
        let canConfirmRemoval = confirmation.deleteLocalData
            ? canDeleteTorrentData(in: torrentIDs)
            : canRemoveTorrents(in: torrentIDs)
        guard torrentIDs.count == confirmation.torrentIDs.count, canConfirmRemoval else {
            cancelRemoval(confirmation)
            errorMessage = "The removal target is no longer available. Review the current torrents and try again."
            return
        }

        removalConfirmation = nil
        activeRemovalID = confirmation.id
        isRemoving = true
        defer {
            if activeRemovalID == confirmation.id {
                activeRemovalID = nil
                isRemoving = false
            }
        }

        let detailMutationID = beginDetailMutation(ids: confirmation.torrentIDs, mutation: .removal)
        defer { finishDetailMutation(detailMutationID) }
        do {
            try await client.remove(
                hashes: confirmation.torrentHashes,
                deleteLocalData: confirmation.deleteLocalData
            )
            finishDetailMutation(detailMutationID)
            guard isCurrentRemoval(confirmation) else { return }
            for hash in confirmation.torrentHashes { torrentDetailCache.remove(hash: hash) }
            selectedTorrentIDs.subtract(torrentIDs)
            recordRecentPollingMutation()
            await refresh()
        } catch {
            guard isCurrentRemoval(confirmation) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func addTorrent(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID,
        source: String,
        startPaused: Bool,
        downloadDirectory: String?,
        peerLimit: Int? = nil,
        saveAsRequested: Bool = false
    ) async -> AddTorrentSubmissionResult {
        if saveAsRequested {
            guard addTorrentCapabilities.supportsSaveAs else {
                return .failed("Save As requires Transmission RPC 15 or newer.")
            }
        }
        guard let (ownership, client) = beginAddTorrentMutation(
            requestID: requestID,
            presentationOwnerID: presentationOwnerID
        ) else {
            return .failed(addTorrentOwnershipFailure(
                requestID: requestID,
                presentationOwnerID: presentationOwnerID
            ) ?? "This add request is already being submitted.")
        }
        cancelProvisionalMetadataPolling(resetState: true)
        defer { finishAddTorrentMutation(ownership) }

        do {
            let addResult = try await client.addTorrent(
                filename: source,
                startPaused: startPaused,
                downloadDirectory: downloadDirectory,
                peerLimit: peerLimit
            )
            guard isCurrentAddTorrentMutation(ownership, client: client) else {
                return .failed(connectionChangedDuringAddMessage)
            }
            recordAddTorrentDestination(downloadDirectory)
            if addResult.outcome == .added {
                await refreshNewlyAddedTorrent(addResult)
            }
            guard isCurrentAddTorrentMutation(ownership, client: client) else {
                return .failed(connectionChangedDuringAddMessage)
            }

            if addResult.isDuplicate {
                if ownership.presentationOwnerID == directAddTorrentOwnerID {
                    completeAddTorrentPresentation(ownership)
                    return .succeeded
                }
                provisionalTorrentAddState = .duplicate(name: addResult.name)
                return .awaitingSaveAs
            }

            if saveAsRequested {
                guard let provisionalOwner = makeProvisionalTorrentAddOwner(
                    addResult: addResult,
                    ownership: ownership
                ) else {
                    provisionalTorrentAddState = .unavailable(
                        "Transmission added the torrent but did not return a stable torrent identity. It was not renamed or removed."
                    )
                    return .awaitingSaveAs
                }
                if Self.isMagnetSource(source) {
                    startProvisionalMetadataPolling(owner: provisionalOwner, client: client)
                } else if let originalRootName = Self.normalizedRootName(addResult.name) {
                    provisionalTorrentAddState = .ready(
                        owner: provisionalOwner,
                        originalRootName: originalRootName
                    )
                } else {
                    provisionalTorrentAddState = .unavailable(
                        "Transmission added the torrent but did not return its authoritative root name. It was not renamed or removed."
                    )
                }
                return .awaitingSaveAs
            }

            completeAddTorrentPresentation(ownership)
            return .succeeded
        } catch {
            return .failed(
                isCurrentAddTorrentMutation(ownership, client: client)
                    ? error.localizedDescription
                    : connectionChangedDuringAddMessage
            )
        }
    }

    func addTorrentFile(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID,
        data: Data,
        sourceFileURL: URL? = nil,
        sourceFileIdentity: RaceResistantFileIdentity? = nil,
        startPaused: Bool,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection? = nil,
        localTrackerURLs: [String] = [],
        peerLimit: Int? = nil,
        originalRootName: String? = nil,
        saveAsRequested: Bool = false
    ) async -> AddTorrentSubmissionResult {
        let requestedRootName: String?
        if saveAsRequested {
            guard addTorrentCapabilities.supportsSaveAs else {
                return .failed("Save As requires Transmission RPC 15 or newer.")
            }
            guard let originalRootName = Self.normalizedRootName(originalRootName) else {
                return .failed("Save As requires readable torrent metadata with an original root name.")
            }
            requestedRootName = originalRootName
        } else {
            requestedRootName = nil
        }
        guard let (ownership, client) = beginAddTorrentMutation(
            requestID: requestID,
            presentationOwnerID: presentationOwnerID
        ) else {
            return .failed(addTorrentOwnershipFailure(
                requestID: requestID,
                presentationOwnerID: presentationOwnerID
            ) ?? "This add request is already being submitted.")
        }
        cancelProvisionalMetadataPolling(resetState: true)
        defer { finishAddTorrentMutation(ownership) }
        let preparedSourceDeletion = prepareLocalTorrentSourceDeletion(
            sourceFileURL,
            sourceIdentity: sourceFileIdentity,
            for: ownership
        )

        do {
            let addResult = try await client.addTorrent(
                metainfo: data,
                startPaused: startPaused,
                downloadDirectory: downloadDirectory,
                fileSelection: fileSelection,
                peerLimit: peerLimit
            )
            guard isCurrentAddTorrentMutation(ownership, client: client) else {
                return .failed(connectionChangedDuringAddMessage)
            }
            let duplicateTrackerPlan = try await TorrentDuplicateTrackerMerge().planIfNeeded(
                addResult: addResult,
                localTrackerURLs: localTrackerURLs,
                rpcVersion: connectedRPCVersion ?? 0,
                rpc: client
            )
            guard isCurrentAddTorrentMutation(ownership, client: client) else {
                return .failed(connectionChangedDuringAddMessage)
            }
            if let duplicateTrackerPlan {
                await resolveWatchFolderJob(
                    for: ownership,
                    acknowledgment: .duplicate
                )
                if ownership.presentationOwnerID == directAddTorrentOwnerID,
                   var request = pendingAddTorrent,
                   request.id == ownership.requestID {
                    request.submissionDisposition = .presentOptions
                    request.pendingDuplicateTrackerPlan = duplicateTrackerPlan
                    pendingAddTorrent = request
                }
                provisionalTorrentAddState = .duplicate(name: addResult.name)
                return .confirmDuplicateTrackers(duplicateTrackerPlan)
            }
            recordAddTorrentDestination(downloadDirectory)
            if addResult.outcome == .added {
                await refreshNewlyAddedTorrent(addResult)
            }
            guard isCurrentAddTorrentMutation(ownership, client: client) else {
                return .failed(connectionChangedDuringAddMessage)
            }
            if addResult.outcome == .added {
                if pendingAddTorrent?.watchFolderJob == nil {
                    deleteLocalTorrentSourceIfNeeded(
                        preparedSourceDeletion,
                        addOutcome: .added
                    )
                }
                await resolveWatchFolderJob(
                    for: ownership,
                    acknowledgment: .added
                )
            }

            if addResult.isDuplicate {
                await resolveWatchFolderJob(
                    for: ownership,
                    acknowledgment: .duplicate
                )
                if ownership.presentationOwnerID == directAddTorrentOwnerID {
                    completeAddTorrentPresentation(ownership)
                    return .succeeded
                }
                provisionalTorrentAddState = .duplicate(name: addResult.name)
                return .awaitingSaveAs
            }

            if let originalRootName = requestedRootName {
                guard let provisionalOwner = makeProvisionalTorrentAddOwner(
                    addResult: addResult,
                    ownership: ownership
                ) else {
                    provisionalTorrentAddState = .unavailable(
                        "Transmission added the torrent but did not return a stable torrent identity. It was not renamed or removed."
                    )
                    return .awaitingSaveAs
                }
                provisionalTorrentAddState = .ready(
                    owner: provisionalOwner,
                    originalRootName: originalRootName
                )
                return .awaitingSaveAs
            }

            completeAddTorrentPresentation(ownership)
            return .succeeded
        } catch {
            return .failed(
                isCurrentAddTorrentMutation(ownership, client: client)
                    ? error.localizedDescription
                    : connectionChangedDuringAddMessage
            )
        }
    }

    private func prepareLocalTorrentSourceDeletion(
        _ sourceFileURL: URL?,
        sourceIdentity: RaceResistantFileIdentity?,
        for ownership: ActiveAddTorrentMutation
    ) -> Result<PreparedTorrentSourceDeletion?, Error>? {
        guard let sourceFileURL,
              pendingAddTorrent?.id == ownership.requestID,
              pendingAddTorrent?.watchFolderJob == nil else {
            return nil
        }
        let deletionPolicy = intakeAutomationPreferencesStore.preferences.sourceTorrentDeletion
        guard case .deleteLocalTorrentFile = TorrentSourceDeletionService.decision(
            policy: deletionPolicy,
            sourceFileURL: sourceFileURL,
            addOutcome: .added
        ) else {
            return .success(nil)
        }
        guard let sourceIdentity else {
            return .failure(
                TorrentSourceDeletionPreparationError.missingReadTimeIdentity
            )
        }
        return Result {
            try torrentSourceDeletionService.prepareDeletionIfNeeded(
                policy: deletionPolicy,
                sourceFileURL: sourceFileURL,
                sourceIdentity: sourceIdentity
            )
        }
    }

    private func deleteLocalTorrentSourceIfNeeded(
        _ preparedDeletion: Result<PreparedTorrentSourceDeletion?, Error>?,
        addOutcome: ConfirmedTorrentAddOutcome
    ) {
        guard let preparedDeletion else { return }

        let deletionResult: TorrentSourceDeletionResult
        switch preparedDeletion {
        case .success(let preparedDeletion):
            deletionResult = torrentSourceDeletionService.deleteIfAllowed(
                preparedDeletion: preparedDeletion,
                addOutcome: addOutcome
            )
        case .failure(let error):
            deletionResult = .failed(error.localizedDescription)
        }

        switch deletionResult {
        case .kept, .deleted:
            break
        case .failed(let message):
            errorMessage = "Transmission added the torrent, but the source .torrent could not be deleted: \(message)"
        }
    }

    private func resolveWatchFolderJob(
        for ownership: ActiveAddTorrentMutation,
        acknowledgment: WatchFolderAddAcknowledgment
    ) async {
        guard pendingAddTorrent?.id == ownership.requestID else { return }
        await resolveWatchFolderJob(
            for: pendingAddTorrent,
            acknowledgment: acknowledgment
        )
    }

    private func scheduleWatchFolderJobResolution(
        for request: PendingAddTorrent?,
        acknowledgment: WatchFolderAddAcknowledgment
    ) {
        guard let job = request?.watchFolderJob,
              let owner = request?.watchFolderOwner else {
            return
        }
        Task { [watchFolderCoordinator] in
            await watchFolderCoordinator.resolve(
                job: job,
                acknowledgment: acknowledgment,
                owner: owner
            )
        }
    }

    private func resolveWatchFolderJob(
        for request: PendingAddTorrent?,
        acknowledgment: WatchFolderAddAcknowledgment
    ) async {
        guard let job = request?.watchFolderJob,
              let owner = request?.watchFolderOwner else {
            return
        }
        await watchFolderCoordinator.resolve(
            job: job,
            acknowledgment: acknowledgment,
            owner: owner
        )
    }

    func renameProvisionalTorrent(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID,
        newName: String
    ) async -> AddTorrentSubmissionResult {
        guard case .ready(let provisionalOwner, let originalRootName) = provisionalTorrentAddState else {
            return .failed("Wait for Transmission to finish loading the torrent metadata before using Save As.")
        }
        guard provisionalOwner.mayMutate(currentOwner: provisionalTorrentAddState.owner) else {
            return .failed("This torrent cannot be renamed from the current add request.")
        }

        let validatedName: String
        do {
            validatedName = try AddTorrentSaveAsValidator.validate(
                newName,
                originalName: originalRootName
            )
        } catch {
            return .failed(error.localizedDescription)
        }

        guard let (ownership, client) = beginAddTorrentMutation(
            requestID: requestID,
            presentationOwnerID: presentationOwnerID
        ) else {
            return .failed(addTorrentOwnershipFailure(
                requestID: requestID,
                presentationOwnerID: presentationOwnerID
            ) ?? "This Save As request is already being submitted.")
        }
        defer { finishAddTorrentMutation(ownership) }

        guard provisionalOwnerMatchesMutation(
            provisionalOwner,
            ownership: ownership,
            client: client
        ) else {
            return .failed(connectionChangedDuringAddMessage)
        }

        let detailMutationID = beginDetailMutation(ids: [provisionalOwner.torrentID], mutation: .rename)
        defer { finishDetailMutation(detailMutationID) }
        do {
            try await client.renameProvisionalTorrentRoot(
                torrentHash: provisionalOwner.torrentHash,
                originalRootName: originalRootName,
                newName: validatedName,
                rpcVersion: connectedRPCVersion
            )
            finishDetailMutation(detailMutationID)
            guard provisionalOwnerMatchesMutation(
                provisionalOwner,
                ownership: ownership,
                client: client
            ) else {
                return .failed(connectionChangedDuringAddMessage)
            }
            await refreshAfterTorrentMutation(
                ids: [provisionalOwner.torrentID],
                invalidation: mutationRefreshPolicy.invalidation(for: .rename)
            )
            guard provisionalOwnerMatchesMutation(
                provisionalOwner,
                ownership: ownership,
                client: client
            ) else {
                return .failed(connectionChangedDuringAddMessage)
            }
            completeAddTorrentPresentation(ownership)
            return .succeeded
        } catch {
            return .failed(
                provisionalOwnerMatchesMutation(
                    provisionalOwner,
                    ownership: ownership,
                    client: client
                ) ? error.localizedDescription : connectionChangedDuringAddMessage
            )
        }
    }

    func finishProvisionalTorrentAdd(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID
    ) -> AddTorrentSubmissionResult {
        guard let (ownership, _) = beginAddTorrentMutation(
            requestID: requestID,
            presentationOwnerID: presentationOwnerID
        ) else {
            return .failed(addTorrentOwnershipFailure(
                requestID: requestID,
                presentationOwnerID: presentationOwnerID
            ) ?? "This add request is no longer active.")
        }
        defer { finishAddTorrentMutation(ownership) }

        cancelProvisionalMetadataPolling(resetState: true)
        completeAddTorrentPresentation(ownership)
        return .succeeded
    }

    func retryProvisionalTorrentMetadata(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID
    ) {
        guard
            case .timedOut(let owner) = provisionalTorrentAddState,
            owner.requestID == requestID,
            owner.presentationID == presentationOwnerID,
            isCurrentProvisionalTorrentAddOwner(owner),
            let client
        else {
            return
        }
        startProvisionalMetadataPolling(owner: owner, client: client)
    }

    private func refreshNewlyAddedTorrent(_ addResult: TorrentAddResult) async {
        guard let torrentID = addResult.id, torrentID > 0 else {
            await refreshAfterTorrentMutation(ids: [], invalidation: .rowsOnly)
            await enqueueRefresh(.torrentRepair)
            return
        }
        await refreshAfterTorrentMutation(ids: [torrentID], invalidation: .rowsOnly)
    }

    private func makeProvisionalTorrentAddOwner(
        addResult: TorrentAddResult,
        ownership: ActiveAddTorrentMutation
    ) -> ProvisionalTorrentAddOwner? {
        guard
            addResult.outcome == .added,
            let torrentID = addResult.id,
            torrentID > 0,
            let torrentHash = Self.normalizedTorrentHash(addResult.hashString)
        else {
            return nil
        }
        return ProvisionalTorrentAddOwner(
            requestID: ownership.requestID,
            presentationID: ownership.presentationOwnerID,
            profileID: ownership.profileID,
            connectionToken: ownership.connectionToken,
            torrentID: torrentID,
            torrentHash: torrentHash,
            isDuplicate: false
        )
    }

    private func startProvisionalMetadataPolling(
        owner: ProvisionalTorrentAddOwner,
        client expectedClient: TransmissionRPCClient
    ) {
        provisionalMetadataTask?.cancel()
        provisionalTorrentAddState = .waiting(
            owner: owner,
            attempt: 0,
            maximumAttempts: provisionalMetadataPollingPolicy.maximumAttempts
        )
        provisionalMetadataTask = Task { @MainActor [weak self] in
            await self?.pollProvisionalTorrentMetadata(owner: owner, client: expectedClient)
        }
    }

    private func pollProvisionalTorrentMetadata(
        owner: ProvisionalTorrentAddOwner,
        client expectedClient: TransmissionRPCClient
    ) async {
        for attempt in 1 ... provisionalMetadataPollingPolicy.maximumAttempts {
            do {
                try await provisionalMetadataSleeper.sleep(
                    for: provisionalMetadataPollingPolicy.interval
                )
            } catch {
                return
            }
            guard !Task.isCancelled, isCurrentProvisionalTorrentAddOwner(owner, client: expectedClient) else {
                return
            }

            provisionalTorrentAddState = .waiting(
                owner: owner,
                attempt: attempt,
                maximumAttempts: provisionalMetadataPollingPolicy.maximumAttempts
            )
            do {
                let snapshot = try await expectedClient.fetchProvisionalTorrentMetadata(
                    torrentHash: owner.torrentHash
                )
                guard !Task.isCancelled, isCurrentProvisionalTorrentAddOwner(owner, client: expectedClient) else {
                    return
                }
                guard let snapshot else { continue }
                guard
                    snapshot.torrentID == owner.torrentID,
                    snapshot.torrentHash == owner.torrentHash
                else {
                    provisionalTorrentAddState = .unavailable(
                        "Transmission returned a different torrent while checking metadata. Nothing was renamed or removed."
                    )
                    provisionalMetadataTask = nil
                    return
                }
                if snapshot.hasAuthoritativeRootName,
                   let rootName = Self.normalizedRootName(snapshot.rootName) {
                    provisionalTorrentAddState = .ready(
                        owner: owner,
                        originalRootName: rootName
                    )
                    provisionalMetadataTask = nil
                    return
                }
            } catch {
                guard !Task.isCancelled, isCurrentProvisionalTorrentAddOwner(owner, client: expectedClient) else {
                    return
                }
            }
        }

        guard !Task.isCancelled, isCurrentProvisionalTorrentAddOwner(owner, client: expectedClient) else {
            return
        }
        provisionalTorrentAddState = .timedOut(owner: owner)
        provisionalMetadataTask = nil
    }

    private func isCurrentProvisionalTorrentAddOwner(
        _ owner: ProvisionalTorrentAddOwner,
        client expectedClient: TransmissionRPCClient? = nil
    ) -> Bool {
        owner.mayMutate(currentOwner: provisionalTorrentAddState.owner)
            && isCurrentAddTorrentPresentation(
                requestID: owner.requestID,
                ownerID: owner.presentationID
            )
            && owner.profileID == selectedProfileID
            && owner.connectionToken == connectionToken
            && connectionState.isConnected
            && client != nil
            && (expectedClient == nil || client === expectedClient)
    }

    private func provisionalOwnerMatchesMutation(
        _ provisionalOwner: ProvisionalTorrentAddOwner,
        ownership: ActiveAddTorrentMutation,
        client expectedClient: TransmissionRPCClient
    ) -> Bool {
        provisionalOwner.requestID == ownership.requestID
            && provisionalOwner.presentationID == ownership.presentationOwnerID
            && provisionalOwner.profileID == ownership.profileID
            && provisionalOwner.connectionToken == ownership.connectionToken
            && provisionalOwner.mayMutate(currentOwner: provisionalTorrentAddState.owner)
            && isCurrentAddTorrentMutation(ownership, client: expectedClient)
    }

    private func cancelProvisionalMetadataPolling(resetState: Bool) {
        provisionalMetadataTask?.cancel()
        provisionalMetadataTask = nil
        if resetState {
            provisionalTorrentAddState = .idle
        }
    }

    private static func normalizedTorrentHash(_ hash: String?) -> String? {
        CanonicalTransmissionTorrentHash.normalize(hash)
    }

    private static func normalizedRootName(_ name: String?) -> String? {
        guard let name else { return nil }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func isMagnetSource(_ source: String) -> Bool {
        source.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("magnet:")
    }

    func applyDuplicateTorrentTrackerPlan(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID,
        plan: TorrentDuplicateTrackerPlan,
        downloadDirectory: String?
    ) async -> AddTorrentSubmissionResult {
        guard let (ownership, client) = beginAddTorrentMutation(
            requestID: requestID,
            presentationOwnerID: presentationOwnerID
        ) else {
            return .failed(addTorrentOwnershipFailure(
                requestID: requestID,
                presentationOwnerID: presentationOwnerID
            ) ?? "This duplicate torrent tracker update is already being submitted.")
        }
        defer { finishAddTorrentMutation(ownership) }
        let affectedTorrentIDs = torrentIDs(for: plan.target)
        let detailMutationID = beginDetailMutation(ids: affectedTorrentIDs, mutation: .trackers)
        defer { finishDetailMutation(detailMutationID) }

        do {
            try await TorrentDuplicateTrackerMerge().apply(plan, rpc: client)
            finishDetailMutation(detailMutationID)
            guard isCurrentAddTorrentMutation(ownership, client: client) else {
                return .failed(connectionChangedDuringAddMessage)
            }
            recordAddTorrentDestination(downloadDirectory)
            await refreshAfterTorrentMutation(
                ids: affectedTorrentIDs,
                invalidation: mutationRefreshPolicy.invalidation(for: .trackers)
            )
            if affectedTorrentIDs.isEmpty {
                await enqueueRefresh(.torrentRepair)
            }
            guard isCurrentAddTorrentMutation(ownership, client: client) else {
                return .failed(connectionChangedDuringAddMessage)
            }
            completeAddTorrentPresentation(ownership)
            return .succeeded
        } catch {
            return .failed(
                isCurrentAddTorrentMutation(ownership, client: client)
                    ? error.localizedDescription
                    : connectionChangedDuringAddMessage
            )
        }
    }

    func cancelDuplicateTorrentTrackerPlan(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID,
        downloadDirectory: String?
    ) -> AddTorrentSubmissionResult {
        guard let (ownership, _) = beginAddTorrentMutation(
            requestID: requestID,
            presentationOwnerID: presentationOwnerID
        ) else {
            return .failed(addTorrentOwnershipFailure(
                requestID: requestID,
                presentationOwnerID: presentationOwnerID
            ) ?? "This duplicate torrent confirmation is no longer active.")
        }
        defer { finishAddTorrentMutation(ownership) }

        recordAddTorrentDestination(downloadDirectory)
        completeAddTorrentPresentation(ownership)
        return .succeeded
    }

    func addTorrentOwnershipFailure(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID
    ) -> String? {
        guard isCurrentAddTorrentPresentation(
            requestID: requestID,
            ownerID: presentationOwnerID
        ) else {
            return "This add request is no longer active."
        }
        guard let request = pendingAddTorrent else {
            return "This add request is no longer active."
        }
        guard request.profileID == selectedProfileID else {
            return connectionChangedDuringAddMessage
        }
        guard request.connectionToken == connectionToken else {
            return connectionChangedDuringAddMessage
        }
        guard connectionState.isConnected, client != nil else {
            return "Transmission is not connected. Cancel this request, reconnect, and open it again."
        }
        return nil
    }

    private var connectionChangedDuringAddMessage: String {
        "The Transmission connection changed. This torrent was not submitted to another server. Cancel and open it again."
    }

    private func beginAddTorrentMutation(
        requestID: PendingAddTorrent.ID,
        presentationOwnerID: UUID
    ) -> (ActiveAddTorrentMutation, TransmissionRPCClient)? {
        guard activeAddTorrentMutation == nil, !isAddingTorrent else { return nil }
        guard addTorrentOwnershipFailure(
            requestID: requestID,
            presentationOwnerID: presentationOwnerID
        ) == nil else {
            return nil
        }
        guard let request = pendingAddTorrent, let client else { return nil }

        let ownership = ActiveAddTorrentMutation(
            requestID: request.id,
            profileID: request.profileID,
            connectionToken: request.connectionToken,
            presentationOwnerID: presentationOwnerID
        )
        activeAddTorrentMutation = ownership
        isAddingTorrent = true
        return (ownership, client)
    }

    private func finishAddTorrentMutation(_ ownership: ActiveAddTorrentMutation) {
        guard activeAddTorrentMutation == ownership else { return }
        activeAddTorrentMutation = nil
        isAddingTorrent = false
        guard
            !addTorrentPresentationOwners.contains(ownership.presentationOwnerID),
            var request = pendingAddTorrent,
            isCurrentAddTorrentPresentation(
                requestID: ownership.requestID,
                ownerID: ownership.presentationOwnerID
            )
        else {
            return
        }

        let completedPresentation =
            completedAddTorrentPresentation?.requestID == ownership.requestID
                && completedAddTorrentPresentation?.ownerID == ownership.presentationOwnerID
        completedAddTorrentPresentation = nil
        showingAddTorrent = false
        pendingAddTorrent = nil
        if !completedPresentation {
            request.presentationOwnerID = nil
            if ownership.presentationOwnerID == directAddTorrentOwnerID {
                request.submissionDisposition = .presentOptions
            }
            queuedAddTorrents.insert(request, at: 0)
        }
        presentNextPendingAddTorrentIfPossible()
    }

    private func isCurrentAddTorrentMutation(
        _ ownership: ActiveAddTorrentMutation,
        client expectedClient: TransmissionRPCClient
    ) -> Bool {
        activeAddTorrentMutation == ownership
            && isCurrentAddTorrentPresentation(
                requestID: ownership.requestID,
                ownerID: ownership.presentationOwnerID
            )
            && ownership.profileID == selectedProfileID
            && ownership.connectionToken == connectionToken
            && connectionState.isConnected
            && client === expectedClient
    }

    private func completeAddTorrentPresentation(_ ownership: ActiveAddTorrentMutation) {
        guard
            activeAddTorrentMutation == ownership,
            isCurrentAddTorrentPresentation(
                requestID: ownership.requestID,
                ownerID: ownership.presentationOwnerID
            ),
            ownership.profileID == selectedProfileID,
            ownership.connectionToken == connectionToken,
            connectionState.isConnected,
            client != nil
        else {
            return
        }
        completedAddTorrentPresentation = (ownership.requestID, ownership.presentationOwnerID)
    }

    func applyDaemonOptions(_ update: DaemonOptionsUpdate) async -> DaemonOptionsApplyResult {
        guard connectionState.isConnected, let client else {
            return .rejected(.notConnected)
        }
        guard !isApplyingDaemonOptions else { return .rejected(.applyInProgress) }
        guard activeDaemonMaintenanceOwner == nil else {
            return .rejected(.maintenanceInProgress)
        }
        let applyID = UUID()
        let token = connectionToken
        let profileID = selectedProfileID
        activeDaemonOptionsApplyID = applyID
        isApplyingDaemonOptions = true
        defer {
            if activeDaemonOptionsApplyID == applyID {
                activeDaemonOptionsApplyID = nil
                isApplyingDaemonOptions = false
            }
        }
        do {
            try await client.setDaemonOptions(update)
            guard
                activeDaemonOptionsApplyID == applyID,
                profileID == selectedProfileID,
                isCurrentConnection(token: token),
                self.client === client
            else {
                return .rejected(.connectionChanged)
            }
            let refreshSequence = nextSessionInfoRequestSequence()
            let refreshedSessionInfo = try await client.getSession()
            guard
                activeDaemonOptionsApplyID == applyID,
                profileID == selectedProfileID,
                isCurrentConnection(token: token),
                self.client === client
            else {
                return .rejected(.connectionChanged)
            }
            _ = publishSessionInfo(
                refreshedSessionInfo,
                client: client,
                token: token,
                requestSequence: refreshSequence
            )
            return .succeeded
        } catch {
            guard
                activeDaemonOptionsApplyID == applyID,
                profileID == selectedProfileID,
                isCurrentConnection(token: token),
                self.client === client
            else {
                return .rejected(.connectionChanged)
            }
            errorMessage = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    private func synchronizeDaemonOptionsSettings() {
        let owner = sessionInfo.map { _ in
            DaemonOptionsSettingsOwner(
                profileID: selectedProfileID,
                connectionGeneration: connectionToken
            )
        }
        daemonOptionsSettings.synchronize(owner: owner, sessionInfo: sessionInfo)
    }

    func testPort(_ requestedProtocol: PortTestIPProtocol) {
        guard
            let client,
            let sessionInfo,
            sessionInfo.capabilities.hasPortTest,
            requestedProtocol.isSupported(rpcVersion: sessionInfo.rpcVersion),
            !isApplyingDaemonOptions,
            activeDaemonMaintenanceOwner == nil
        else {
            return
        }

        let owner = DaemonMaintenanceOwner(
            id: UUID(),
            kind: .portTest,
            profileID: selectedProfileID,
            connectionToken: connectionToken
        )
        activeDaemonMaintenanceOwner = owner
        daemonMaintenanceNotice = nil
        isTestingPort = true
        activeDaemonMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.testPort(
                    requestedProtocol,
                    rpcVersion: sessionInfo.rpcVersion
                )
                guard self.isCurrentDaemonMaintenance(owner, client: client) else { return }
                self.daemonMaintenanceNotice = .portTestSucceeded(result)
            } catch {
                guard self.isCurrentDaemonMaintenance(owner, client: client) else { return }
                self.daemonMaintenanceNotice = .portTestFailed(
                    requestedProtocol: requestedProtocol,
                    message: error.localizedDescription
                )
            }
            self.finishDaemonMaintenance(owner)
        }
    }

    func updateBlocklist() {
        guard
            let client,
            let sessionInfo,
            sessionInfo.capabilities.hasBlocklistUpdate,
            sessionInfo.daemonOptions.blocklistEnabled == true,
            !isApplyingDaemonOptions,
            activeDaemonMaintenanceOwner == nil
        else {
            return
        }

        let owner = DaemonMaintenanceOwner(
            id: UUID(),
            kind: .blocklistUpdate,
            profileID: selectedProfileID,
            connectionToken: connectionToken
        )
        activeDaemonMaintenanceOwner = owner
        daemonMaintenanceNotice = nil
        isUpdatingBlocklist = true
        activeDaemonMaintenanceTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.updateBlocklist(rpcVersion: sessionInfo.rpcVersion)
                guard self.isCurrentDaemonMaintenance(owner, client: client) else { return }
                self.daemonMaintenanceNotice = .blocklistUpdateSucceeded(result)
                _ = await self.refreshSessionInfo(client: client, token: owner.connectionToken)
                guard self.isCurrentDaemonMaintenance(owner, client: client) else { return }
            } catch {
                guard self.isCurrentDaemonMaintenance(owner, client: client) else { return }
                self.daemonMaintenanceNotice = .blocklistUpdateFailed(message: error.localizedDescription)
            }
            self.finishDaemonMaintenance(owner)
        }
    }

    func dismissDaemonMaintenanceNotice() {
        daemonMaintenanceNotice = nil
    }

    @discardableResult
    func applyConnectionProfiles(
        _ nextProfiles: [ConnectionProfile],
        selectedProfileID nextSelectedProfileID: ConnectionProfile.ID?
    ) -> Result<Void, ConnectionProfileApplyFailure> {
        guard !isRemoving else { return .failure(.torrentRemovalInProgress) }
        guard rejectConnectionChangeDuringAddIfNeeded() else {
            return .failure(.torrentAddInProgress)
        }

        let collection: ConnectionProfileCollection
        do {
            collection = try ConnectionProfileCollection(
                profiles: nextProfiles,
                selectedProfileID: nextSelectedProfileID
            )
        } catch {
            return connectionProfileApplyFailure(.invalidProfiles(error))
        }

        let transition = connectionProfileTransition(to: collection)

        do {
            try profileStore.save(collection)
        } catch {
            return connectionProfileApplyFailure(.persistence(error))
        }

        installPersistedProfiles(collection, transition: transition)
        resumeConnection(after: transition)
        return .success(())
    }

    private func connectionProfileTransition(
        to collection: ConnectionProfileCollection
    ) -> ConnectionProfileTransition {
        let activeProfileChanged = selectedProfileID != collection.selectedProfileID
            || selectedProfile.requiresConnectionRestart(comparedTo: collection.selectedProfile)
        let shouldResumeLaunchConnection: Bool
        if needsConnectionSetup, case .waitingForProfile = launchConnectionPolicyState {
            shouldResumeLaunchConnection = true
        } else {
            shouldResumeLaunchConnection = false
        }
        let shouldReconnect: Bool
        switch connectionState {
        case .connecting, .reconnecting, .connected, .failed:
            shouldReconnect = activeProfileChanged
        case .disconnected:
            shouldReconnect = activeProfileChanged && passwordPrompt != nil
        }
        return ConnectionProfileTransition(
            shouldDisconnect: needsConnectionSetup || shouldReconnect,
            shouldResumeLaunchConnection: shouldResumeLaunchConnection,
            shouldReconnect: shouldReconnect
        )
    }

    private func installPersistedProfiles(
        _ collection: ConnectionProfileCollection,
        transition: ConnectionProfileTransition
    ) {
        let nextProfilesByID = Dictionary(uniqueKeysWithValues: collection.profiles.map { ($0.id, $0) })
        for profile in profiles where nextProfilesByID[profile.id] != profile {
            sessionPasswords[profile.id] = nil
        }
        if transition.shouldDisconnect {
            disconnect()
        }
        profiles = collection.profiles
        selectedProfileID = collection.selectedProfileID
        loadSelectedProfileTransferPreferences()
        needsConnectionSetup = false
    }

    private func resumeConnection(after transition: ConnectionProfileTransition) {
        if transition.shouldResumeLaunchConnection {
            launchConnectionPolicyState = .notStarted
            Task { @MainActor [weak self] in
                await self?.start()
            }
        } else if transition.shouldReconnect {
            Task { @MainActor [weak self] in
                await self?.connect()
            }
        }
    }

    private func connectionProfileApplyFailure(
        _ failure: ConnectionProfileApplyFailure
    ) -> Result<Void, ConnectionProfileApplyFailure> {
        errorMessage = failure.localizedDescription
        return .failure(failure)
    }

    private var settingsPortabilityCommitReadinessIssue: String? {
        if applicationSettingsDraftSession.retainedDraft != nil {
            return "Save or revert the unsaved Application settings before importing settings."
        }
        if connectionSettingsCoordinatorController.blocksSettingsImport {
            return "Save or revert the unsaved Server settings before importing settings."
        }
        if isAddingTorrent || pendingAddTorrent != nil {
            return "Finish or cancel the current Add Torrent workflow before importing settings."
        }
        if isRemoving || isApplyingDaemonOptions || activeDaemonMaintenanceOwner != nil {
            return "Wait for the current Transmission operation to finish before importing settings."
        }
        if let sessionInfo,
           daemonOptionsSettings.hasChanges(capabilities: sessionInfo.capabilities) {
            return "Apply or revert the unsaved Transmission settings before importing settings."
        }
        return nil
    }

    private func settingsPortabilityRuntimeState() -> SettingsPortabilityRuntimeState {
        let persistedSort = userDefaults.string(forKey: TorrentTableColumnPreferenceKeys.sort)
            .map(TorrentTableSortPreference.init(rawValue:))
            ?? TorrentTableSortMapping.preference(for: torrentSortOrder)
            ?? TorrentTableDefaults.sort
        return SettingsPortabilityRuntimeState(
            profiles: profiles,
            selectedProfileID: selectedProfileID,
            polling: pollingPreferences,
            visibleTorrentColumns: torrentTableVisibleColumns,
            torrentSort: persistedSort,
            isInfoPaneVisible: isTorrentDetailVisible,
            selectedDetailPane: selectedTorrentDetailPane
        )
    }

    private func settingsPortabilityDidCommit(_ result: SettingsPortabilityCommitResult) {
        let collection = result.collection
        let transition = connectionProfileTransition(to: collection)
        installPersistedProfiles(collection, transition: transition)

        if result.preferences.polling != pollingPreferences {
            pollingPreferences = result.preferences.polling
            restartPollingForCurrentState()
        }
        behaviorPreferencesDidChange(result.preferences.behavior)
        intakeAutomationPreferencesDidChange(result.preferences.intake)
        watchFolderPreferencesDidChange(watchFolderPreferencesStore.snapshot)
        tableColumnCustomizationWorkspaceController.reloadFromPersistence()
        torrentSortOrder = TorrentTableSortMapping.descriptors(
            for: result.preferences.torrentSort
        )
        setTorrentTableProjection(
            visibleColumns: result.preferences.visibleTorrentColumns,
            activeSortColumn: result.preferences.torrentSort.columnID
        )
        workspacePreferencesStore.replace(with: result.preferences.workspace)
        isTorrentDetailVisible = result.preferences.workspace.infoPane.isVisible
        selectedTorrentDetailPane = result.preferences.workspace.infoPane.selectedDetailPane

        resumeConnection(after: transition)
    }

    func toggleStatusFilter(_ status: TorrentFilterStatus) {
        if status == .all {
            torrentFilters.statuses = []
        } else if torrentFilters.statuses.contains(status) {
            torrentFilters.statuses.remove(status)
        } else {
            torrentFilters.statuses.remove(.all)
            torrentFilters.statuses.insert(status)
        }
    }

    func selectStatusFilter(_ status: TorrentFilterStatus) {
        var filters = torrentFilters
        filters.statuses = status == .all ? [] : [status]
        torrentFilters = filters
    }

    func showTorrentDetailPane(_ pane: TorrentDetailPane) {
        selectedTorrentDetailPane = pane
        isTorrentDetailVisible = true
    }

    func performNativeNavigationCommand(_ commandID: NativeCommandID) {
        guard let navigationAction = commandID.navigationAction else { return }
        switch navigationAction {
        case .showDetailPane(let pane):
            showTorrentDetailPane(pane)
        case .selectStatusFilter(let status):
            if !workspacePreferencesStore.preferences.filterPane.isVisible {
                workspacePreferencesStore.updateFilterPaneVisibility(true)
            }
            selectStatusFilter(status)
        }
    }

    func togglePathFilter(_ path: String) {
        toggleValue(path, in: &torrentFilters.paths)
    }

    func toggleTrackerFilter(_ tracker: String) {
        toggleValue(tracker, in: &torrentFilters.trackers)
    }

    func toggleLabelFilter(_ label: String) {
        toggleValue(label, in: &torrentFilters.labels)
    }

    func clearFilters() {
        filterText = ""
        torrentFilters = .empty
    }

    private func runSelectionAction(
        mutation: TorrentMutationKind,
        _ action: (TransmissionRPCClient, [Int]) async throws -> Void
    ) async {
        guard let client, !selectedTorrentIDs.isEmpty else { return }
        let ids = selectedTorrentIDs.sorted()
        let token = connectionToken
        let detailMutationID = beginDetailMutation(ids: ids, mutation: mutation)
        defer { finishDetailMutation(detailMutationID) }
        do {
            try await action(client, ids)
            finishDetailMutation(detailMutationID)
            guard isCurrentConnection(token: token) else { return }
            await refreshAfterTorrentMutation(
                ids: ids,
                invalidation: mutationRefreshPolicy.invalidation(for: mutation)
            )
        } catch {
            guard isCurrentConnection(token: token) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func runTorrentFileAction(
        fileIndexes: [Int],
        owner: DetailMutationOwner,
        _ action: (TransmissionRPCClient, Int, [Int]) async throws -> Void
    ) async {
        let normalizedFileIndexes = Array(Set(fileIndexes.filter { $0 >= 0 })).sorted()
        guard
            let client = validatedDetailMutationClient(
                owner: owner,
                pane: .files,
                requiresFilesSnapshot: true
            ),
            !normalizedFileIndexes.isEmpty
        else {
            return
        }

        let detailMutationID = beginDetailMutation(ids: [owner.torrentID], mutation: .files)
        defer { finishDetailMutation(detailMutationID) }
        do {
            try await action(client, owner.torrentID, normalizedFileIndexes)
            finishDetailMutation(detailMutationID)
            guard isCurrentDetailMutationConnection(owner) else { return }
            await refreshAfterTorrentMutation(
                ids: [owner.torrentID],
                invalidation: mutationRefreshPolicy.invalidation(for: .files)
            )
        } catch {
            guard isCurrentDetailMutationConnection(owner) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func runTorrentTrackerAction(
        owner: DetailMutationOwner,
        _ action: (TransmissionRPCClient, String) async throws -> Void
    ) async {
        guard
            let client = validatedDetailMutationClient(
                owner: owner,
                pane: .trackers,
                requiresFilesSnapshot: false
            )
        else {
            return
        }

        let detailMutationID = beginDetailMutation(ids: [owner.torrentID], mutation: .trackers)
        defer { finishDetailMutation(detailMutationID) }
        do {
            try await action(client, owner.torrentHash)
            finishDetailMutation(detailMutationID)
            guard isCurrentDetailMutationConnection(owner) else { return }
            await refreshAfterTorrentMutation(
                ids: [owner.torrentID],
                invalidation: mutationRefreshPolicy.invalidation(for: .trackers)
            )
        } catch {
            guard isCurrentDetailMutationConnection(owner) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func validatedTorrentPathRenameClient(
        for request: TorrentPathRenameRequest
    ) -> TransmissionRPCClient? {
        guard isCurrentTorrentPathRenameRequest(request), let client else { return nil }
        return client
    }

    private func isCurrentTorrentPathRenameRequest(
        _ request: TorrentPathRenameRequest,
        submittedPaneRevision: Int? = nil
    ) -> Bool {
        let owner = request.owner
        guard
            owner.profileID == selectedProfileID,
            isCurrentConnection(token: owner.connectionToken),
            connectionState.isConnected,
            (connectedRPCVersion ?? 0) >= 15,
            selectedDetailSelectionGeneration == owner.selectionRevision,
            selectedTorrentIDs == [request.torrentID],
            selectedDetailTorrentID == request.torrentID,
            selectedTorrentDetailPane == .files,
            submittedPaneRevision != nil || selectedDetailLoadedPanes.contains(.files),
            selectedDetailPaneRevisions[.files, default: 0] == (submittedPaneRevision ?? owner.paneRevision),
            let currentTorrent = torrentListProjection.row(for: request.torrentID),
            currentTorrent.hashString.caseInsensitiveCompare(request.torrentHash) == .orderedSame,
            let filesSnapshot = selectedDetailSnapshots[.files],
            filesSnapshot.id == request.torrentID,
            filesSnapshot.filesSnapshotRevision?.rawValue == owner.filesRevision,
            let currentNode = Self.torrentPathRenameNode(
                id: request.node.id,
                in: filesSnapshot.fileTree
            )
        else {
            return false
        }
        return (try? TorrentPathRenameValidator.validateCurrentNode(currentNode, for: request)) != nil
    }

    private static func torrentPathRenameNode(
        id: TorrentFileNode.ID,
        in nodes: [TorrentFileNode]
    ) -> TorrentPathRenameNode? {
        for node in nodes {
            if node.id == id {
                return TorrentPathRenameNode(fileNode: node)
            }
            if let match = torrentPathRenameNode(id: id, in: node.children ?? []) {
                return match
            }
        }
        return nil
    }

    private func validatedDetailMutationClient(
        owner: DetailMutationOwner,
        pane: TorrentDetailPane,
        requiresFilesSnapshot: Bool
    ) -> TransmissionRPCClient? {
        guard
            owner.pane == pane,
            owner.profileID == selectedProfileID,
            isCurrentConnection(token: owner.connectionToken),
            connectionState.isConnected,
            selectedTorrentIDs == [owner.torrentID],
            selectedDetailTorrentID == owner.torrentID,
            selectedTorrentDetailPane == pane,
            selectedDetailSelectionGeneration == owner.selectionGeneration,
            selectedDetailLoadedPanes.contains(pane),
            selectedDetailPaneRevisions[pane, default: 0] == owner.paneRevision,
            let currentTorrent = torrentListProjection.row(for: owner.torrentID),
            currentTorrent.hashString.caseInsensitiveCompare(owner.torrentHash) == .orderedSame,
            let paneSnapshot = selectedDetailSnapshots[pane],
            paneSnapshot.id == owner.torrentID,
            let client
        else {
            return nil
        }
        if requiresFilesSnapshot {
            guard
                let ownerRevision = owner.filesSnapshotRevision,
                paneSnapshot.filesSnapshotRevision == ownerRevision
            else {
                return nil
            }
        }
        return client
    }

    private func isCurrentDetailMutationConnection(_ owner: DetailMutationOwner) -> Bool {
        owner.profileID == selectedProfileID
            && isCurrentConnection(token: owner.connectionToken)
    }

    @discardableResult
    private func runTorrentAction(
        ids: [TorrentSummary.ID],
        mutation: TorrentMutationKind,
        _ action: (TransmissionRPCClient) async throws -> Void
    ) async -> Bool {
        guard let client else { return false }
        let token = connectionToken
        let detailMutationID = beginDetailMutation(ids: ids, mutation: mutation)
        defer { finishDetailMutation(detailMutationID) }
        do {
            try await action(client)
            finishDetailMutation(detailMutationID)
            guard isCurrentConnection(token: token) else { return false }
            await refreshAfterTorrentMutation(
                ids: ids,
                invalidation: mutationRefreshPolicy.invalidation(for: mutation)
            )
            return true
        } catch {
            guard isCurrentConnection(token: token) else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func refreshAfterTorrentMutation(
        ids: [TorrentSummary.ID],
        invalidation: TorrentMutationInvalidation
    ) async {
        recordRecentPollingMutation()

        let torrentIDs = Set(ids.filter { $0 > 0 })
        guard !torrentIDs.isEmpty else { return }

        torrentDetailCache.invalidate(torrentIDs: torrentIDs, panes: invalidation.detailPanes.union([.overview]))

        var refreshKinds: PollingRefreshKind = []
        if invalidation.refreshTorrentRows {
            queuedTorrentRowRefreshIDs.formUnion(torrentIDs)
            refreshKinds.insert(.torrentRows)
        }

        for pane in invalidation.detailPanes {
            guard invalidateSelectedDetailPane(pane, affectedTorrentIDs: torrentIDs) else { continue }
            refreshKinds.insert(.details)
        }

        await enqueueRefresh(refreshKinds)
    }

    @discardableResult
    private func invalidateSelectedDetailPane(
        _ pane: TorrentDetailPane,
        affectedTorrentIDs: Set<TorrentSummary.ID>,
        queueRefresh: Bool = true
    ) -> Bool {
        guard
            let selectedID = selectedTorrentIDs.sorted().first,
            selectedDetailTorrentID == selectedID,
            affectedTorrentIDs.contains(selectedID)
        else {
            return false
        }

        selectedDetailLoadedPanes.remove(pane)
        if pane == .overview,
           selectedDetailTorrentHash.map(pieceRevalidationHashes.contains) == true,
           var snapshot = selectedDetailSnapshots[pane] {
            // Keep text visible, but invalidated completion evidence must not
            // survive a verify/location mutation while revalidation is pending.
            snapshot.generalInfo?.pieceMapState = .unavailable
            snapshot.generalInfo?.isPieceCompletionInvalidated = true
            selectedDetailSnapshots[pane] = snapshot
            renderSelectedTorrentDetail()
        }
        selectedDetailPaneRevisions[pane, default: 0] += 1
        queuedDetailRefreshes.removeAll {
            $0.key.torrentID == selectedID && $0.key.pane == pane
        }
        cancelActiveDetailRefreshUnless { key in
            key.pane != pane
                || key.paneRevision == selectedDetailPaneRevisions[pane, default: 0]
        }

        guard queueRefresh, isTorrentDetailVisible, selectedTorrentDetailPane == pane else {
            return false
        }
        queueCurrentDetailRefresh(pane: pane, priority: .active, force: true)
        return true
    }

    private func beginDetailMutation(ids: [Int], mutation: TorrentMutationKind) -> UUID {
        let invalidation = mutationRefreshPolicy.invalidation(for: mutation)
        let torrentIDs = Set(ids)
        let hashes = Set(ids.compactMap { torrentListProjection.row(for: $0)?.hashString }
            .compactMap(CanonicalTransmissionTorrentHash.normalize))
        let token = UUID()
        activeDetailMutations[token] = hashes
        torrentDetailCache.invalidate(torrentIDs: torrentIDs, panes: invalidation.detailPanes.union([.overview]))
        if mutationRefreshPolicy.requiresPieceRevalidation(after: mutation) { pieceRevalidationHashes.formUnion(hashes) }
        for pane in invalidation.detailPanes {
            invalidateSelectedDetailPane(pane, affectedTorrentIDs: torrentIDs, queueRefresh: false)
        }
        updateSelectedPieceRevalidationRequirement()
        return token
    }

    private func finishDetailMutation(_ token: UUID, resumeRefresh: Bool = true) {
        guard let hashes = activeDetailMutations.removeValue(forKey: token),
              resumeRefresh,
              let selectedHash = selectedDetailTorrentHash,
              hashes.contains(selectedHash),
              isTorrentDetailVisible,
              selectedTorrentDetailPane.needsRPCRefresh,
              !selectedDetailLoadedPanes.contains(selectedTorrentDetailPane),
              !activeDetailMutations.values.contains(where: { $0.contains(selectedHash) }) else { return }
        // A pane change during submission must not be lost behind the barrier.
        // Reuse the active-demand key and existing drain, never prefetch here.
        queueCurrentDetailRefresh(priority: .active, force: false)
        guard !queuedDetailRefreshes.isEmpty else { return }
        let connection = connectionToken
        let generation = selectedDetailSelectionGeneration
        let pane = selectedTorrentDetailPane
        Task { [weak self] in
            guard let self,
                  self.isCurrentConnection(token: connection),
                  self.selectedDetailSelectionGeneration == generation,
                  self.selectedDetailTorrentHash == selectedHash,
                  self.selectedTorrentDetailPane == pane,
                  self.isTorrentDetailVisible else { return }
            await self.enqueueRefresh(.details)
        }
    }

    private func updateSelectedPieceRevalidationRequirement() {
        let required = selectedDetailTorrentHash.map(pieceRevalidationHashes.contains) ?? false
        if selectedTorrentRequiresPieceRevalidation != required {
            selectedTorrentRequiresPieceRevalidation = required
        }
    }

    private func updateGlobalBandwidth(_ action: @escaping () async throws -> Void) async {
        let token = connectionToken
        let updateID = UUID()
        let updateTask = Task {
            try await action()
        }
        activeBandwidthUpdateID = updateID
        activeBandwidthUpdateTask = updateTask
        isUpdatingGlobalBandwidth = true
        defer {
            if activeBandwidthUpdateID == updateID {
                activeBandwidthUpdateID = nil
                activeBandwidthUpdateTask = nil
                isUpdatingGlobalBandwidth = false
            }
        }

        do {
            try await updateTask.value
            guard activeBandwidthUpdateID == updateID, isCurrentConnection(token: token) else { return }
            await enqueueRefresh(.sessionInfo)
        } catch {
            guard activeBandwidthUpdateID == updateID, isCurrentConnection(token: token) else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func requestSelectedLocationChange(moveData: Bool) {
        let selectedTorrents = selectedTorrentsInDisplayOrder()
        guard canSetSelectedTorrentLocation, !selectedTorrents.isEmpty else { return }
        guard let owner = promptedTorrentMutationOwner(for: selectedTorrents) else { return }
        let defaultLocation = commonDownloadDirectory(in: selectedTorrents)
            ?? selectedTorrents.first?.downloadDir
            ?? sessionInfo?.downloadDir
            ?? ""
        guard let location = torrentOperationPrompter.requestLocation(
            defaultLocation: defaultLocation,
            moveData: moveData,
            suggestions: selectedProfile.transferPreferences.moveDestinationHistory
        ) else {
            return
        }

        Task { [weak self] in
            await self?.setTorrentLocation(owner: owner, location: location, moveData: moveData)
        }
    }

    private func setTorrentLocation(
        owner: PromptedTorrentMutationOwner,
        location: String,
        moveData: Bool
    ) async {
        let ownership: TorrentOperationOwnership
        let expectation: TorrentOperationCompletionExpectation
        do {
            ownership = try TorrentOperationOwnership(
                kind: moveData ? .moveData : .setLocation,
                profileID: owner.profileID,
                connectionToken: owner.connectionToken,
                torrentHashes: owner.targets.map(\.hash)
            )
            if moveData {
                expectation = try .moveData(
                    ownership: ownership,
                    destination: location
                )
            } else {
                expectation = try .setLocation(
                    ownership: ownership,
                    destination: location
                )
            }
        } catch {
            guard isCurrentPromptedTorrentMutationOwner(owner) else { return }
            errorMessage = error.localizedDescription
            return
        }

        await runTrackedTorrentOperation(
            owner: owner,
            expectation: expectation,
            mutation: .location,
            completedDestinationHistory: location
        ) { client, hashes in
            try await client.setLocation(hashes: hashes, location: location, moveData: moveData)
        }
    }

    private func renameTorrent(
        owner: PromptedTorrentMutationOwner,
        path: String,
        name: String
    ) async {
        let ownership: TorrentOperationOwnership
        let expectation: TorrentOperationCompletionExpectation
        do {
            ownership = try TorrentOperationOwnership(
                kind: .rename,
                profileID: owner.profileID,
                connectionToken: owner.connectionToken,
                torrentHashes: owner.targets.map(\.hash)
            )
            expectation = try .rename(
                ownership: ownership,
                requestedName: name,
                originalName: path
            )
        } catch {
            guard isCurrentPromptedTorrentMutationOwner(owner) else { return }
            errorMessage = error.localizedDescription
            return
        }

        await runTrackedTorrentOperation(
            owner: owner,
            expectation: expectation,
            mutation: .rename
        ) { client, hashes in
            guard let hash = hashes.first else { return }
            try await client.renamePath(hash: hash, path: path, name: name)
        }
    }

    private func promptedTorrentMutationOwner(
        for torrents: [TorrentSummary]
    ) -> PromptedTorrentMutationOwner? {
        guard connectionState.isConnected, let client, !torrents.isEmpty else { return nil }
        let targets = torrents.compactMap { torrent -> PromptedTorrentMutationOwner.Target? in
            guard let hash = CanonicalTransmissionTorrentHash.normalize(torrent.hashString) else { return nil }
            return .init(id: torrent.id, hash: hash)
        }
        guard targets.count == torrents.count else { return nil }
        return PromptedTorrentMutationOwner(
            profileID: selectedProfileID,
            connectionToken: connectionToken,
            client: client,
            targets: targets.sorted { $0.id < $1.id }
        )
    }

    private func isCurrentPromptedTorrentMutationOwner(
        _ owner: PromptedTorrentMutationOwner
    ) -> Bool {
        guard isCurrentPromptedTorrentMutationConnection(owner) else { return false }
        return owner.targets.allSatisfy { target in
            guard let torrent = torrentListProjection.row(for: target.id) else { return false }
            return CanonicalTransmissionTorrentHash.normalize(torrent.hashString) == target.hash
        }
    }

    private func isCurrentPromptedTorrentMutationConnection(
        _ owner: PromptedTorrentMutationOwner
    ) -> Bool {
        guard
            owner.profileID == selectedProfileID,
            isCurrentConnection(token: owner.connectionToken),
            connectionState.isConnected,
            let client,
            client === owner.client
        else {
            return false
        }
        return true
    }

    private func runTrackedTorrentOperation(
        owner: PromptedTorrentMutationOwner,
        expectation: TorrentOperationCompletionExpectation,
        mutation: TorrentMutationKind,
        completedDestinationHistory: String? = nil,
        _ action: @escaping (TransmissionRPCClient, [String]) async throws -> Void
    ) async {
        guard
            expectation.ownership.profileID == owner.profileID,
            expectation.ownership.connectionToken == owner.connectionToken,
            expectation.ownership.torrentHashes == owner.targets.map(\.hash),
            isCurrentPromptedTorrentMutationOwner(owner)
        else {
            return
        }

        let operationID = expectation.ownership.operationID
        let trackedOperation = TrackedTorrentOperation(
            expectation: expectation,
            owner: owner,
            refreshIDs: owner.targets.map(\.id),
            completedDestinationHistory: completedDestinationHistory,
            postAcknowledgementObservation: nil
        )
        guard case .applied = torrentOperationFeedbackLifecycle.submit(expectation.ownership) else {
            return
        }
        trackedTorrentOperations[operationID] = trackedOperation
        publishTorrentOperationFeedback()

        let detailMutationID = beginDetailMutation(ids: trackedOperation.refreshIDs, mutation: mutation)
        defer { finishDetailMutation(detailMutationID) }

        let rpcTask = Task {
            try await action(owner.client, expectation.ownership.torrentHashes)
        }
        torrentOperationRPCTasks[operationID] = rpcTask
        defer {
            torrentOperationRPCTasks[operationID] = nil
        }

        do {
            try await rpcTask.value
            finishDetailMutation(detailMutationID)
            guard isCurrentTrackedTorrentOperation(operationID) else {
                invalidateTrackedTorrentOperation(operationID)
                return
            }
            guard var acknowledgedOperation = trackedTorrentOperations[operationID] else {
                return
            }
            acknowledgedOperation.postAcknowledgementObservation =
                TorrentOperationPostAcknowledgementObservation(
                    targetHashes: expectation.ownership.torrentHashes,
                    acknowledgementRequestSequenceWatermark: torrentListRequestSequence
                )
            trackedTorrentOperations[operationID] = acknowledgedOperation
            let runningResult = torrentOperationFeedbackLifecycle.markRunning(
                expectation.ownership,
                context: publicationContext(for: expectation.ownership)
            )
            guard case .applied = runningResult else {
                invalidateTrackedTorrentOperation(operationID)
                return
            }
            publishTorrentOperationFeedback()
            torrentOperationMonitoringCoordinator.register(
                operationID: operationID,
                kind: expectation.ownership.kind,
                torrentIDs: trackedOperation.refreshIDs,
                now: torrentOperationMonitoringClock.now()
            )
            restartTorrentOperationMonitor()
            await refreshAfterTorrentMutation(
                ids: trackedOperation.refreshIDs,
                invalidation: mutationRefreshPolicy.invalidation(for: mutation)
            )
        } catch {
            guard isCurrentTrackedTorrentOperation(operationID) else {
                invalidateTrackedTorrentOperation(operationID)
                return
            }
            let failureResult = torrentOperationFeedbackLifecycle.markFailed(
                expectation.ownership,
                message: error.localizedDescription,
                context: publicationContext(for: expectation.ownership)
            )
            guard case .applied = failureResult else {
                invalidateTrackedTorrentOperation(operationID)
                return
            }
            trackedTorrentOperations[operationID] = nil
            publishTorrentOperationFeedback()
        }
    }

    private func isCurrentTrackedTorrentOperation(_ operationID: UUID) -> Bool {
        guard let trackedOperation = trackedTorrentOperations[operationID] else { return false }
        guard isCurrentTrackedTorrentOperationConnection(
            operationID,
            trackedOperation: trackedOperation
        ) else {
            return false
        }
        return TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
            trackedOperation.expectation,
            torrents: torrentListProjection.allRowsInSourceOrder()
        ) != .stale
    }

    private func isCurrentTrackedTorrentOperationConnection(
        _ operationID: UUID,
        trackedOperation: TrackedTorrentOperation
    ) -> Bool {
        guard
            trackedOperation.expectation.ownership.operationID == operationID,
            trackedOperation.expectation.ownership.profileID == selectedProfileID,
            trackedOperation.expectation.ownership.connectionToken == connectionToken,
            connectionState.isConnected,
            let client,
            client === trackedOperation.owner.client
        else {
            return false
        }
        return true
    }

    private func publicationContext(
        for ownership: TorrentOperationOwnership
    ) -> TorrentOperationFeedbackPublicationContext {
        TorrentOperationFeedbackPublicationContext(
            profileID: ownership.profileID,
            connectionToken: ownership.connectionToken,
            torrentHashes: ownership.torrentHashes
        )
    }

    private func reconcileTrackedTorrentOperations(
        requestSequenceByHash: [String: UInt64]
    ) {
        // Terminal feedback still needs identity invalidation after monitoring ends.
        guard !torrentOperationFeedbackLifecycle.isEmpty || !trackedTorrentOperations.isEmpty else {
            return
        }
        torrentOperationReconciliationSnapshotCount &+= 1
        let currentTorrents = materializeTorrentSnapshot()
        let staleOperationIDs = torrentOperationFeedbackLifecycle.invalidateStale(
            in: TorrentOperationFeedbackPublicationContext(
                profileID: selectedProfileID,
                connectionToken: connectionToken,
                torrentHashes: currentTorrents.map(\.hashString)
            )
        )
        for operationID in staleOperationIDs {
            torrentOperationRPCTasks[operationID]?.cancel()
            torrentOperationRPCTasks[operationID] = nil
            torrentOperationMonitoringCoordinator.remove(operationID: operationID)
            trackedTorrentOperations[operationID] = nil
        }
        if !staleOperationIDs.isEmpty {
            publishTorrentOperationFeedback()
        }
        guard !trackedTorrentOperations.isEmpty else { return }

        let operationIDs = Array(trackedTorrentOperations.keys)

        for operationID in operationIDs {
            guard var trackedOperation = trackedTorrentOperations[operationID] else { continue }
            guard isCurrentTrackedTorrentOperationConnection(
                operationID,
                trackedOperation: trackedOperation
            ) else {
                invalidateTrackedTorrentOperation(operationID)
                continue
            }
            guard torrentOperationFeedbackLifecycle
                .feedback(operationID: operationID)?.phase.stage == .running else {
                continue
            }
            guard var observation = trackedOperation.postAcknowledgementObservation else {
                continue
            }
            observation.consume(requestSequenceByHash)
            trackedOperation.postAcknowledgementObservation = observation
            trackedTorrentOperations[operationID] = trackedOperation

            switch TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
                trackedOperation.expectation,
                torrents: currentTorrents
            ) {
            case .running:
                continue

            case .completed:
                guard observation.hasObservedEveryTarget else {
                    continue
                }
                let result = torrentOperationFeedbackLifecycle.markCompleted(
                    trackedOperation.expectation.ownership,
                    context: publicationContext(for: trackedOperation.expectation.ownership)
                )
                guard case .applied = result else {
                    invalidateTrackedTorrentOperation(operationID)
                    continue
                }
                torrentOperationMonitoringCoordinator.remove(operationID: operationID)
                trackedTorrentOperations[operationID] = nil
                if let destination = trackedOperation.completedDestinationHistory {
                    recordDestination(destination, for: .move)
                }
                publishTorrentOperationFeedback()

            case .stale:
                invalidateTrackedTorrentOperation(operationID)
            }
        }
    }

    private func restartTorrentOperationMonitor() {
        torrentOperationMonitorTask?.cancel()
        let clock = torrentOperationMonitoringClock
        torrentOperationMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let deadline = self?.torrentOperationMonitoringCoordinator.nextDeadline else {
                    return
                }
                do {
                    try await clock.sleep(until: deadline)
                } catch {
                    return
                }
                guard !Task.isCancelled else {
                    return
                }
                guard await self?.performTorrentOperationMonitorStep(now: clock.now()) == true else {
                    return
                }
            }
        }
    }

    private func performTorrentOperationMonitorStep(now: Duration) async -> Bool {
        let batch = torrentOperationMonitoringCoordinator.advance(at: now)
        for operationID in batch.exhaustedOperationIDs {
            exhaustTrackedTorrentOperationMonitoring(operationID)
        }

        if !batch.torrentIDs.isEmpty {
            await refreshAfterTorrentMutation(
                ids: batch.torrentIDs,
                invalidation: .rowsOnly
            )
        }
        return torrentOperationMonitoringCoordinator.nextDeadline != nil
    }

    private func exhaustTrackedTorrentOperationMonitoring(_ operationID: UUID) {
        guard
            let trackedOperation = trackedTorrentOperations[operationID],
            isCurrentTrackedTorrentOperation(operationID)
        else {
            invalidateTrackedTorrentOperation(operationID)
            return
        }
        let kind = trackedOperation.expectation.ownership.kind
        if kind == .verify {
            let evaluation = TorrentOperationCompletionEvaluator.evaluateAcceptedSubmission(
                trackedOperation.expectation,
                torrents: torrentListProjection.allRowsInSourceOrder()
            )
            if evaluation == .running
                || trackedOperation.postAcknowledgementObservation?.hasObservedEveryTarget != true {
                return
            }
        }
        let message = switch kind {
        case .verify:
            "Transmission did not report verification completion within 30 minutes."
        case .setLocation, .moveData, .rename:
            "Transmission did not report operation completion within 20 seconds."
        }
        let result = torrentOperationFeedbackLifecycle.markFailed(
            trackedOperation.expectation.ownership,
            message: message,
            context: publicationContext(for: trackedOperation.expectation.ownership)
        )
        guard case .applied = result else {
            invalidateTrackedTorrentOperation(operationID)
            return
        }
        trackedTorrentOperations[operationID] = nil
        publishTorrentOperationFeedback()
    }

    private func invalidateTrackedTorrentOperation(_ operationID: UUID) {
        torrentOperationRPCTasks[operationID]?.cancel()
        torrentOperationRPCTasks[operationID] = nil
        torrentOperationMonitoringCoordinator.remove(operationID: operationID)
        trackedTorrentOperations[operationID] = nil
        torrentOperationFeedbackLifecycle.invalidate(operationID: operationID)
        publishTorrentOperationFeedback()
    }

    private func invalidateTorrentOperationState() {
        verifyConfirmation = nil
        pendingVerifyOperation = nil
        torrentOperationRPCTasks.values.forEach { $0.cancel() }
        torrentOperationRPCTasks = [:]
        torrentOperationMonitorTask?.cancel()
        torrentOperationMonitorTask = nil
        torrentOperationMonitoringCoordinator.removeAll()
        trackedTorrentOperations = [:]
        torrentOperationFeedbackLifecycle = TorrentOperationFeedbackLifecycle()
        torrentOperationFeedback = []
    }

    private func publishTorrentOperationFeedback() {
        let nextFeedback = torrentOperationFeedbackLifecycle.feedback
        if torrentOperationFeedback != nextFeedback {
            torrentOperationFeedback = nextFeedback
        }
    }

    private func commonDownloadDirectory(in torrents: [TorrentSummary]) -> String? {
        guard let first = torrents.first?.downloadDir, !first.isEmpty else { return nil }
        return torrents.allSatisfy { $0.downloadDir == first } ? first : nil
    }

    private func runLocalFileAction(_ action: () throws -> Void) {
        do {
            try action()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectedLocalPaths() throws -> [String] {
        let selectedTorrents = selectedTorrentsInDisplayOrder()
        guard !selectedTorrents.isEmpty else {
            throw LocalFileActionError.noPaths
        }

        let pathMappingService = PathMappingService(profile: selectedProfile)
        return try selectedTorrents.map { torrent in
            do {
                return try pathMappingService.resolvedLocalPath(forDaemonPath: torrent.fullPath)
            } catch {
                throw LocalTorrentPathResolutionError(torrentName: torrent.name, message: error.localizedDescription)
            }
        }
    }

    private func selectedTorrentsInDisplayOrder() -> [TorrentSummary] {
        torrentListProjection.selectedRowsInDisplayOrder(for: selectedTorrentIDs)
    }

    private func loadSelectedProfileTransferPreferences(migratingLegacyHistory: Bool = false) {
        if migratingLegacyHistory,
           let legacyHistory = userDefaults.stringArray(forKey: AppStoreDefaultsKey.addTorrentDestinationHistory),
           !legacyHistory.isEmpty {
            do {
                try updateSelectedProfileTransferPreferences { preferences in
                    guard preferences.addDestinationHistory.isEmpty else { return }
                    for destination in legacyHistory.reversed() {
                        _ = try? preferences.recordDestination(destination, for: .add)
                    }
                }
                userDefaults.removeObject(forKey: AppStoreDefaultsKey.addTorrentDestinationHistory)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        addTorrentDestinationHistory = selectedProfile.transferPreferences.addDestinationHistory
    }

    private func recordAddTorrentDestination(_ requestedDownloadDirectory: String?) {
        let destination = AddTorrentDestinationHistory.normalizedDestination(requestedDownloadDirectory)
            ?? AddTorrentDestinationHistory.normalizedDestination(sessionInfo?.downloadDir)
        guard let destination else { return }

        recordDestination(destination, for: .add)
    }

    private func recordDestination(_ destination: String, for history: RemoteDestinationHistoryKind) {
        do {
            try updateSelectedProfileTransferPreferences { preferences in
                _ = try preferences.recordDestination(destination, for: history)
            }
            addTorrentDestinationHistory = selectedProfile.transferPreferences.addDestinationHistory
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateSelectedProfileTransferPreferences(
        _ update: (inout ProfileTransferPreferences) throws -> Void
    ) throws {
        guard let index = profiles.firstIndex(where: { $0.id == selectedProfileID }) else {
            throw ConnectionProfileStoreError.unknownProfile(selectedProfileID)
        }
        var nextProfiles = profiles
        let previousPreferences = nextProfiles[index].transferPreferences
        try update(&nextProfiles[index].transferPreferences)
        guard nextProfiles[index].transferPreferences != previousPreferences else { return }

        let collection = try ConnectionProfileCollection(
            profiles: nextProfiles,
            selectedProfileID: selectedProfileID
        )
        try profileStore.save(collection)
        profiles = collection.profiles
    }

    private func loadProfiles() {
        do {
            let collection = try profileStore.load()
            profiles = collection.profiles
            selectedProfileID = collection.selectedProfileID
        } catch {
            needsConnectionSetup = true
            errorMessage = error.localizedDescription
        }
    }

    private func startPolling() {
        stopPolling()
        detailPollingTick = 0
        let token = connectionToken
        guard
            isPollingCurrent(token: token),
            let intervalSeconds = adaptivePollingCadencePolicy.intervalSeconds(
                preferences: pollingPreferences,
                visibility: pollingVisibility,
                hasTorrentActivity: torrentListProjection.hasTorrentActivityRequiringActivePolling,
                recentMutation: recentPollingMutation,
                connectionToken: token,
                now: adaptivePollingClock.now()
            )
        else {
            return
        }

        scheduledPollingIntervalSeconds = intervalSeconds
        pollingCommandRevision &+= 1
        let commandRevision = pollingCommandRevision
        let listInterval = Duration.seconds(intervalSeconds)
        let sessionInterval = Duration.seconds(intervalSeconds * 5)
        Task { [pollingCoordinator] in
            await pollingCoordinator.start(
                commandRevision: commandRevision,
                connectionToken: token,
                listInterval: listInterval,
                sessionInterval: sessionInterval
            ) { [weak self] connectionToken, work in
                await self?.performPollingRefresh(work, connectionToken: connectionToken)
            }
        }
    }

    private func stopPolling() {
        detailPollingTick = 0
        scheduledPollingIntervalSeconds = nil
        pollingCommandRevision &+= 1
        let commandRevision = pollingCommandRevision
        Task { [pollingCoordinator] in
            await pollingCoordinator.stop(commandRevision: commandRevision)
        }
    }

    private func restartPollingForCurrentState() {
        guard isPollingCurrent(token: connectionToken) else {
            stopPolling()
            return
        }
        startPolling()
    }

    private func reconcileAdaptivePollingCadenceIfNeeded() {
        guard let scheduledPollingIntervalSeconds else { return }
        let desiredIntervalSeconds = adaptivePollingCadencePolicy.intervalSeconds(
            preferences: pollingPreferences,
            visibility: pollingVisibility,
            hasTorrentActivity: torrentListProjection.hasTorrentActivityRequiringActivePolling,
            recentMutation: recentPollingMutation,
            connectionToken: connectionToken,
            now: adaptivePollingClock.now()
        )
        guard desiredIntervalSeconds != scheduledPollingIntervalSeconds else { return }
        restartPollingForCurrentState()
    }

    private func recordRecentPollingMutation() {
        recentPollingMutation = AdaptivePollingMutationActivity(
            connectionToken: connectionToken,
            observedAt: adaptivePollingClock.now()
        )
        reconcileAdaptivePollingCadenceIfNeeded()
    }

    private func performPollingRefresh(_ work: PollingWork, connectionToken: UUID) async {
        guard isPollingCurrent(token: connectionToken) else { return }
        var refreshKinds: PollingRefreshKind = []
        if work.contains(.torrents) {
            refreshKinds.insert(.torrents)
            detailPollingTick = detailPollingTick == Int.max ? 1 : detailPollingTick + 1
            if
                isTorrentDetailVisible,
                selectedTorrentDetailPane.needsRPCRefresh,
                detailRefreshPolicy.shouldPoll(
                    pane: selectedTorrentDetailPane,
                    visibility: pollingVisibility,
                    regularTick: detailPollingTick
                )
            {
                queueCurrentDetailRefresh(priority: .active, force: true)
                refreshKinds.insert(.details)
            }
        }
        if work.contains(.session) {
            refreshKinds.insert(.session)
        }
        await enqueueRefresh(refreshKinds)
    }

    private func selectedTorrentDidChange(from oldSelection: Set<TorrentSummary.ID>) {
        let oldID = oldSelection.sorted().first
        let selectedID = selectedTorrentIDs.sorted().first
        guard selectedID != oldID else { return }
        let selectedHash = selectedID.flatMap { id in
            torrentListProjection.row(for: id)?.hashString
        }.flatMap(CanonicalTransmissionTorrentHash.normalize)

        cancelSelectedDetailDebounce()
        cancelPeerResolution()
        selectedDetailSelectionGeneration &+= 1
        selectedDetailTorrentID = selectedID
        selectedDetailTorrentHash = selectedHash
        updateSelectedPieceRevalidationRequirement()
        selectedDetailLoadedPanes = []
        selectedDetailSnapshots = selectedHash.flatMap { hash in
            selectedID.map { torrentDetailCache.snapshots(hash: hash, torrentID: $0) }
        } ?? [:]
        if let selectedID, let summary = torrentListProjection.row(for: selectedID),
           var overview = selectedDetailSnapshots[.overview], let info = overview.generalInfo {
            overview.generalInfo = info.overlayingCachedDisplay(with: summary)
            selectedDetailSnapshots[.overview] = overview
        }
        selectedDetailPaneRevisions = [:]
        prefetchedSelectionGeneration = nil
        queuedDetailRefreshes.removeAll { $0.key.selectionGeneration != selectedDetailSelectionGeneration }
        cancelActiveDetailRefreshUnless { key in
            key.connectionToken == connectionToken
                && key.selectionGeneration == selectedDetailSelectionGeneration
                && key.torrentID == selectedID
                && key.torrentHash == selectedHash
        }

        guard
            let selectedID,
            selectedHash != nil,
            isTorrentDetailVisible,
            selectedTorrentDetailPane.needsRPCRefresh,
            torrentListProjection.row(for: selectedID) != nil
        else {
            updateSelectedTorrentDetailState(.notLoaded)
            return
        }

        renderSelectedTorrentDetail()
        scheduleSelectedTorrentDetailRefresh()
    }

    private func reconcileSelectedDetailIdentityWithCurrentTorrentList() {
        // Bounded by the cache (not the complete torrent list). Prunes removed
        // torrents and numeric ID reuse, including nonselected cached entries.
        torrentDetailCache.reconcile { torrentListProjection.row(for: $0)?.hashString }
        if !pieceRevalidationHashes.isEmpty {
            let currentHashes = Set(torrentListProjection.allRowIDs.compactMap {
                torrentListProjection.row(for: $0)?.hashString
            }.compactMap(CanonicalTransmissionTorrentHash.normalize))
            pieceRevalidationHashes.formIntersection(currentHashes)
        }
        guard
            let selectedID = selectedTorrentIDs.sorted().first,
            selectedDetailTorrentID == selectedID
        else {
            return
        }
        let currentHash = torrentListProjection.row(for: selectedID).flatMap {
            CanonicalTransmissionTorrentHash.normalize($0.hashString)
        }
        guard currentHash != selectedDetailTorrentHash else { return }

        cancelSelectedDetailDebounce()
        cancelPeerResolution()
        selectedDetailSelectionGeneration &+= 1
        selectedDetailTorrentHash = currentHash
        updateSelectedPieceRevalidationRequirement()
        selectedDetailLoadedPanes = []
        selectedDetailSnapshots = [:]
        selectedDetailPaneRevisions = [:]
        prefetchedSelectionGeneration = nil
        queuedDetailRefreshes.removeAll {
            $0.key.selectionGeneration != selectedDetailSelectionGeneration
                || $0.key.torrentHash != currentHash
        }
        cancelActiveDetailRefreshUnless { key in
            key.connectionToken == connectionToken
                && key.selectionGeneration == selectedDetailSelectionGeneration
                && key.torrentID == selectedID
                && key.torrentHash == currentHash
        }

        guard
            currentHash != nil,
            isTorrentDetailVisible,
            selectedTorrentDetailPane.needsRPCRefresh
        else {
            updateSelectedTorrentDetailState(.notLoaded)
            return
        }
        scheduleSelectedTorrentDetailRefresh()
    }

    private func scheduleSelectedTorrentDetailRefresh() {
        cancelSelectedDetailDebounce()
        let pane = selectedTorrentDetailPane
        guard
            isTorrentDetailVisible,
            let selectedID = selectedTorrentIDs.sorted().first,
            selectedDetailTorrentID == selectedID,
            selectedDetailTorrentHash == torrentListProjection.row(for: selectedID).flatMap({
                CanonicalTransmissionTorrentHash.normalize($0.hashString)
            }),
            selectedDetailTorrentHash != nil,
            pane.needsRPCRefresh,
            torrentListProjection.row(for: selectedID) != nil,
            !selectedDetailLoadedPanes.contains(pane)
        else {
            return
        }

        if selectedDetailSnapshots[pane] == nil {
            updateSelectedTorrentDetailState(.loading)
        }
        let generation = selectedDetailSelectionGeneration
        let debounceDuration = selectionDebounceDuration
        let ownerID = UUID()
        selectedDetailDebounceOwnerID = ownerID
        selectedDetailDebounceTask = Task { @MainActor [weak self] in
            defer {
                self?.completeSelectedDetailDebounce(ownerID: ownerID)
            }
            do {
                try await Task.sleep(for: debounceDuration)
            } catch {
                return
            }
            guard
                let self,
                self.isTorrentDetailVisible,
                self.selectedDetailSelectionGeneration == generation,
                self.selectedDetailTorrentID == selectedID,
                self.selectedDetailTorrentHash == CanonicalTransmissionTorrentHash.normalize(
                    self.torrentListProjection.row(for: selectedID)?.hashString
                ),
                self.selectedTorrentDetailPane == pane
            else {
                return
            }
            self.queueCurrentDetailRefresh(priority: .active, force: false)
            await self.enqueueRefresh(.details)
        }
    }

    private func cancelSelectedDetailDebounce() {
        selectedDetailDebounceTask?.cancel()
        selectedDetailDebounceTask = nil
        selectedDetailDebounceOwnerID = nil
    }

    private func completeSelectedDetailDebounce(ownerID: UUID) {
        guard selectedDetailDebounceOwnerID == ownerID else { return }
        selectedDetailDebounceTask = nil
        selectedDetailDebounceOwnerID = nil
    }

    private func selectedTorrentDetailPaneDidChange() {
        cancelSelectedDetailDebounce()
        cancelActiveDetailRefreshUnless { key in
            key.connectionToken == connectionToken
                && key.selectionGeneration == selectedDetailSelectionGeneration
                && key.torrentID == selectedDetailTorrentID
                && key.torrentHash == selectedDetailTorrentHash
                && key.pane == selectedTorrentDetailPane
                && key.paneRevision == selectedDetailPaneRevisions[key.pane, default: 0]
        }
        renderSelectedTorrentDetail()
        guard selectedTorrentDetailPane.needsRPCRefresh else {
            queuedDetailRefreshes = []
            queuedRefreshKinds.remove(.details)
            prefetchedSelectionGeneration = nil
            return
        }
        guard isTorrentDetailVisible else {
            return
        }
        if selectedDetailLoadedPanes.contains(selectedTorrentDetailPane) {
            queueDetailPrefetches(
                selectionGeneration: selectedDetailSelectionGeneration,
                excluding: selectedTorrentDetailPane
            )
            Task { [weak self] in
                await self?.enqueueRefresh(.details)
            }
            return
        }
        queueCurrentDetailRefresh(priority: .active, force: false)
        Task { [weak self] in
            await self?.enqueueRefresh(.details)
        }
    }

    private func torrentDetailVisibilityDidChange() {
        if !isTorrentDetailVisible {
            cancelSelectedDetailDebounce()
            cancelActiveDetailRefreshUnless { _ in false }
            queuedDetailRefreshes = []
            queuedRefreshKinds.remove(.details)
            prefetchedSelectionGeneration = nil
            return
        }

        prefetchedSelectionGeneration = nil
        renderSelectedTorrentDetail()
        queueCurrentDetailRefresh(priority: .active, force: true)
        Task { [weak self] in
            await self?.enqueueRefresh(.details)
        }
    }

    private func queueCurrentDetailRefresh(
        pane: TorrentDetailPane? = nil,
        priority: DetailRefreshPriority,
        force: Bool
    ) {
        let pane = pane ?? selectedTorrentDetailPane
        guard
            let selectedID = selectedTorrentIDs.sorted().first,
            selectedDetailTorrentID == selectedID,
            let torrentHash = torrentListProjection.row(for: selectedID).flatMap({
                CanonicalTransmissionTorrentHash.normalize($0.hashString)
            }),
            selectedDetailTorrentHash == torrentHash,
            !activeDetailMutations.values.contains(where: { $0.contains(torrentHash) }),
            pane.needsRPCRefresh,
            torrentListProjection.row(for: selectedID) != nil
        else {
            return
        }
        guard
            isTorrentDetailVisible,
            force || !selectedDetailLoadedPanes.contains(pane)
        else {
            return
        }

        let request = DetailRefreshRequest(
            key: DetailRefreshRequest.Key(
                connectionToken: connectionToken,
                selectionGeneration: selectedDetailSelectionGeneration,
                torrentID: selectedID,
                torrentHash: torrentHash,
                pane: pane,
                paneRevision: selectedDetailPaneRevisions[pane, default: 0]
            ),
            priority: priority
        )
        enqueueDetailRefresh(request)
    }

    private func enqueueDetailRefresh(_ request: DetailRefreshRequest) {
        guard isTorrentDetailVisible else { return }
        if request.priority == .prefetch {
            guard pollingVisibility == .foreground else { return }
        } else if activeDetailRefreshKey == request.key {
            if activeDetailRefreshPriority == .prefetch {
                activeDetailRefreshPriority = .active
            }
            dropQueuedDetailPrefetches()
            return
        }
        if activeDetailRefreshKey == request.key {
            return
        }
        if let existingIndex = queuedDetailRefreshes.firstIndex(where: { $0.key == request.key }) {
            guard
                request.priority == .active,
                queuedDetailRefreshes[existingIndex].priority == .prefetch
            else {
                return
            }
            var promotedRequest = queuedDetailRefreshes.remove(at: existingIndex)
            promotedRequest.priority = .active
            dropQueuedDetailPrefetches()
            let insertionIndex = queuedDetailRefreshes.firstIndex { $0.priority == .prefetch }
                ?? queuedDetailRefreshes.endIndex
            queuedDetailRefreshes.insert(promotedRequest, at: insertionIndex)
            queuedRefreshKinds.insert(.details)
            return
        }

        if request.priority == .active {
            dropQueuedDetailPrefetches()
            let insertionIndex = queuedDetailRefreshes.firstIndex { $0.priority == .prefetch }
                ?? queuedDetailRefreshes.endIndex
            queuedDetailRefreshes.insert(request, at: insertionIndex)
        } else {
            queuedDetailRefreshes.append(request)
        }
        queuedRefreshKinds.insert(.details)
    }

    private func cancelActiveDetailRefreshUnless(
        _ stillOwnsRequest: (DetailRefreshRequest.Key) -> Bool
    ) {
        guard
            let activeDetailRefreshKey,
            !stillOwnsRequest(activeDetailRefreshKey)
        else {
            return
        }
        activeDetailRefreshTask?.cancel()
    }

    private func dropQueuedDetailPrefetches() {
        if activeDetailRefreshPriority == .prefetch {
            prefetchedSelectionGeneration = nil
        }
        let queuedCount = queuedDetailRefreshes.count
        queuedDetailRefreshes.removeAll { $0.priority == .prefetch }
        if queuedDetailRefreshes.count != queuedCount {
            prefetchedSelectionGeneration = nil
        }
        if queuedDetailRefreshes.isEmpty {
            queuedRefreshKinds.remove(.details)
        }
    }

    private func enqueueRefresh(_ refreshKinds: PollingRefreshKind) async {
        var requestedRefreshKinds = refreshKinds
        if !isTorrentDetailVisible {
            requestedRefreshKinds.remove(.details)
        }
        guard !requestedRefreshKinds.isEmpty, client != nil, connectionState.isConnected else { return }
        queuedRefreshKinds.formUnion(requestedRefreshKinds)
        guard activeRefreshDrainToken == nil else { return }

        let drainToken = UUID()
        activeRefreshDrainToken = drainToken
        defer {
            if activeRefreshDrainToken == drainToken {
                activeRefreshDrainToken = nil
            }
        }

        while activeRefreshDrainToken == drainToken, !queuedRefreshKinds.isEmpty, client != nil, connectionState.isConnected {
            let nextRefreshKinds = queuedRefreshKinds
            queuedRefreshKinds = []
            await performRefresh(nextRefreshKinds)
        }
    }

    private func performRefresh(_ refreshKinds: PollingRefreshKind) async {
        guard let client else { return }
        let token = connectionToken
        var didRefreshDetail = false
        let shouldPrioritizeActiveDetail = isTorrentDetailVisible
            && refreshKinds.contains(.details)
            && queuedDetailRefreshes.first?.priority == .active
        if shouldPrioritizeActiveDetail {
            await refreshNextTorrentDetail(client: client)
            didRefreshDetail = true
        }
        guard isCurrentConnection(token: token) else { return }

        if refreshKinds.contains(.torrentRows) {
            let targetedTorrentIDs = queuedTorrentRowRefreshIDs.sorted()
            queuedTorrentRowRefreshIDs.subtract(targetedTorrentIDs)
            await refreshTorrentRows(
                targetedTorrentIDs,
                client: client,
                token: token
            )
        }
        guard isCurrentConnection(token: token) else { return }

        if refreshKinds.contains(.torrents) || refreshKinds.contains(.torrentRepair) {
            await refreshTorrents(
                client: client,
                token: token,
                forceFullSnapshot: refreshKinds.contains(.torrentRepair)
            )
        }
        guard isCurrentConnection(token: token) else { return }
        if
            !didRefreshDetail,
            isTorrentDetailVisible,
            queuedDetailRefreshes.first?.priority == .active
        {
            queuedRefreshKinds.remove(.details)
            await refreshNextTorrentDetail(client: client)
            didRefreshDetail = true
        }
        guard isCurrentConnection(token: token) else { return }
        if
            !didRefreshDetail,
            isTorrentDetailVisible,
            refreshKinds.contains(.details)
        {
            await refreshNextTorrentDetail(client: client)
        }
        guard isCurrentConnection(token: token) else { return }
        if refreshKinds.contains(.sessionInfo) {
            guard let refreshedSessionInfo = await refreshSessionInfo(client: client, token: token) else { return }
            if refreshKinds.contains(.sessionStats) {
                await refreshSessionStats(
                    client: client,
                    token: token,
                    sessionInfo: refreshedSessionInfo
                )
            }
        } else if refreshKinds.contains(.sessionStats), let sessionInfo {
            await refreshSessionStats(client: client, token: token, sessionInfo: sessionInfo)
        }
    }

    private func refreshTorrentRows(
        _ torrentIDs: [TorrentSummary.ID],
        client: TransmissionRPCClient,
        token: UUID
    ) async {
        guard !torrentIDs.isEmpty, let fieldPlan = currentTorrentListFieldPlan else { return }
        let requestProfileID = selectedProfileID
        let owner = TorrentListRequestOwner(
            connectionGeneration: token,
            fieldPlanRevision: fieldPlan.revision
        )
        let requestSequence = nextTorrentListRequestSequence()
        do {
            let update = try await client.fetchTorrentList(
                mode: .targeted(torrentIDs),
                fieldPlan: fieldPlan
            )
            guard
                isCurrentConnection(token: token),
                owner.isCurrent(
                    connectionGeneration: connectionToken,
                    fieldPlanRevision: currentTorrentListFieldPlan?.revision
                )
            else {
                recordRejectedTorrentListPublication(
                    profileID: requestProfileID,
                    connectionGeneration: token,
                    requestSequence: requestSequence,
                    rowCount: update.torrents.count,
                    reason: "stale-owner"
                )
                return
            }
            applyTorrentListUpdate(
                SequencedTorrentListUpdate(
                    update: update,
                    requestSequenceByHash: torrentListRequestSequenceByHash(
                        in: update,
                        requestSequence: requestSequence
                    ),
                    profileID: requestProfileID,
                    connectionGeneration: token,
                    requestSequence: requestSequence
                ),
                token: token
            )
        } catch {
            guard
                isCurrentConnection(token: token),
                owner.isCurrent(
                    connectionGeneration: connectionToken,
                    fieldPlanRevision: currentTorrentListFieldPlan?.revision
                )
            else {
                recordRejectedTorrentListPublication(
                    profileID: requestProfileID,
                    connectionGeneration: token,
                    requestSequence: requestSequence,
                    rowCount: 0,
                    reason: "stale-owner"
                )
                return
            }
            handleBackgroundRefreshFailure(error, token: token)
        }
    }

    private func refreshTorrents(
        client: TransmissionRPCClient,
        token: UUID,
        forceFullSnapshot: Bool
    ) async {
        guard let fieldPlan = currentTorrentListFieldPlan else { return }
        let requestProfileID = selectedProfileID
        let owner = TorrentListRequestOwner(
            connectionGeneration: token,
            fieldPlanRevision: fieldPlan.revision
        )
        let requestSequence = nextTorrentListRequestSequence()
        do {
            let requestedMode = forceFullSnapshot
                ? TorrentListFetchMode.fullSnapshot
                : torrentListDeltaAccumulator.fetchMode()
            let update = try await client.fetchTorrentList(
                mode: requestedMode,
                fieldPlan: fieldPlan
            )
            guard
                isCurrentConnection(token: token),
                owner.isCurrent(
                    connectionGeneration: connectionToken,
                    fieldPlanRevision: currentTorrentListFieldPlan?.revision
                )
            else {
                recordRejectedTorrentListPublication(
                    profileID: requestProfileID,
                    connectionGeneration: token,
                    requestSequence: requestSequence,
                    rowCount: update.torrents.count,
                    reason: "stale-owner"
                )
                return
            }
            guard let completedUpdate = try await completeRecentlyActiveBootstrapIfNeeded(
                update,
                requestSequence: requestSequence,
                profileID: requestProfileID,
                client: client,
                fieldPlan: fieldPlan,
                owner: owner
            ) else {
                return
            }
            applyTorrentListUpdate(completedUpdate, token: token)
            if completedUpdate.update.mode == .fullSnapshot {
                queuedRefreshKinds.remove(.torrents)
            }
        } catch {
            guard
                isCurrentConnection(token: token),
                owner.isCurrent(
                    connectionGeneration: connectionToken,
                    fieldPlanRevision: currentTorrentListFieldPlan?.revision
                )
            else {
                recordRejectedTorrentListPublication(
                    profileID: requestProfileID,
                    connectionGeneration: token,
                    requestSequence: requestSequence,
                    rowCount: 0,
                    reason: "stale-owner"
                )
                return
            }
            handleBackgroundRefreshFailure(error, token: token)
        }
    }

    private func completeRecentlyActiveBootstrapIfNeeded(
        _ update: TorrentListUpdate,
        requestSequence: UInt64,
        profileID: ConnectionProfile.ID,
        client: TransmissionRPCClient,
        fieldPlan: TorrentListFieldPlan,
        owner: TorrentListRequestOwner
    ) async throws -> SequencedTorrentListUpdate? {
        let updateRequestSequenceByHash = torrentListRequestSequenceByHash(
            in: update,
            requestSequence: requestSequence
        )
        let bootstrapIDs = torrentListDeltaAccumulator.bootstrapIDs(for: update)
        guard !bootstrapIDs.isEmpty else {
            return SequencedTorrentListUpdate(
                update: update,
                requestSequenceByHash: updateRequestSequenceByHash,
                profileID: profileID,
                connectionGeneration: owner.connectionGeneration,
                requestSequence: requestSequence
            )
        }

        let bootstrapRequestSequence = nextTorrentListRequestSequence()
        let bootstrap = try await client.fetchTorrentList(
            mode: .targeted(bootstrapIDs),
            fieldPlan: fieldPlan
        )
        guard
            isCurrentConnection(token: owner.connectionGeneration),
            owner.isCurrent(
                connectionGeneration: connectionToken,
                fieldPlanRevision: currentTorrentListFieldPlan?.revision
            )
        else {
            recordRejectedTorrentListPublication(
                profileID: profileID,
                connectionGeneration: owner.connectionGeneration,
                requestSequence: bootstrapRequestSequence,
                rowCount: bootstrap.torrents.count,
                reason: "stale-owner"
            )
            return nil
        }
        guard let mergedUpdate = update.mergingBootstrap(
            bootstrap,
            requestedIDs: bootstrapIDs
        ) else {
            torrentListDeltaAccumulator.requireFullSnapshot()
            recordRejectedTorrentListPublication(
                profileID: profileID,
                connectionGeneration: owner.connectionGeneration,
                requestSequence: bootstrapRequestSequence,
                rowCount: bootstrap.torrents.count,
                reason: "bootstrap"
            )
            return nil
        }

        var requestSequenceByHash = updateRequestSequenceByHash
        for (hash, sequence) in torrentListRequestSequenceByHash(
            in: bootstrap,
            requestSequence: bootstrapRequestSequence
        ) {
            requestSequenceByHash[hash] = max(requestSequenceByHash[hash] ?? 0, sequence)
        }
        return SequencedTorrentListUpdate(
            update: mergedUpdate,
            requestSequenceByHash: requestSequenceByHash,
            profileID: profileID,
            connectionGeneration: owner.connectionGeneration,
            requestSequence: bootstrapRequestSequence
        )
    }

    private func applyTorrentListUpdate(
        _ sequencedUpdate: SequencedTorrentListUpdate,
        token: UUID
    ) {
        let applyStartedAt = performanceHarnessInstrumentation == nil
            ? nil
            : ContinuousClock().now
        let update = sequencedUpdate.update
        guard
            let rpcVersion = connectedRPCVersion,
            let fieldPlan = currentTorrentListFieldPlan,
            update.fieldPlanRevision == fieldPlan.revision
        else {
            recordRejectedTorrentListPublication(
                sequencedUpdate,
                reason: "field-plan",
                applyStartedAt: applyStartedAt
            )
            return
        }
        guard let result = torrentListDeltaAccumulator.apply(
            update,
            connectionGeneration: token,
            rpcVersion: rpcVersion,
            repairInterval: torrentListRepairInterval
        ) else {
            recordRejectedTorrentListPublication(
                sequencedUpdate,
                reason: "accumulator",
                applyStartedAt: applyStartedAt
            )
            return
        }
        defer { reconcileAdaptivePollingCadenceIfNeeded() }
        switch result {
        case .full(let refreshedTorrents):
            let completedDownloads = downloadCompletionTracker.transitions(afterRefreshing: refreshedTorrents)
            torrentListProjection = TorrentListProjection(
                torrents: refreshedTorrents,
                filters: activeTorrentFilters,
                sortOrder: torrentSortOrder,
                filterEngine: filterEngine
            )
            reconcileSelectedDetailIdentityWithCurrentTorrentList()
            let publishedDerivedValueCount = publishTorrentListProjection()
            pruneUnavailableDynamicFilters()
            pruneSelectionToVisibleTorrents()
            updateTorrentListMetrics(TorrentListUpdateMetrics(
                isFullSnapshot: true,
                mappedRowCount: result.mappedRowCount,
                projectionEvaluatedRowCount: refreshedTorrents.count,
                authoritativeRowMutationCount: refreshedTorrents.count,
                visibleIndexRebuildCount: refreshedTorrents.isEmpty ? 0 : 1,
                sourceIndexRebuildCount: refreshedTorrents.isEmpty ? 0 : 1,
                publishedDerivedValueCount: publishedDerivedValueCount
            ))
            notifyCompletedDownloads(completedDownloads)
            applyPerformanceHarnessDetailSelectionIfNeeded()
            reconcileTrackedTorrentOperations(
                requestSequenceByHash: sequencedUpdate.requestSequenceByHash
            )
        case .changes(let upserted, let removedIDs):
            guard !upserted.isEmpty || !removedIDs.isEmpty else {
                updateTorrentListMetrics(TorrentListUpdateMetrics(
                    isFullSnapshot: false,
                    mappedRowCount: 0,
                    projectionEvaluatedRowCount: 0,
                    authoritativeRowMutationCount: 0,
                    visibleIndexRebuildCount: 0,
                    sourceIndexRebuildCount: 0,
                    publishedDerivedValueCount: 0
                ))
                reconcileTrackedTorrentOperations(
                    requestSequenceByHash: sequencedUpdate.requestSequenceByHash
                )
                recordAcceptedTorrentListPublication(
                    sequencedUpdate,
                    applyStartedAt: applyStartedAt
                )
                measurePerformanceHarnessLargeListIfNeeded()
                return
            }
            let completedDownloads = downloadCompletionTracker.transitions(
                afterApplying: upserted,
                removedIDs: removedIDs
            )
            let projectionMetrics = torrentListProjection.apply(
                upserted: upserted,
                removedIDs: removedIDs,
                filters: activeTorrentFilters,
                sortOrder: torrentSortOrder,
                filterEngine: filterEngine
            )
            reconcileSelectedDetailIdentityWithCurrentTorrentList()
            let publishedDerivedValueCount = projectionMetrics.materializedStateChanged
                ? publishTorrentListProjection()
                : 0
            updateTorrentListMetrics(TorrentListUpdateMetrics(
                isFullSnapshot: false,
                mappedRowCount: result.mappedRowCount,
                projectionEvaluatedRowCount: projectionMetrics.evaluatedRowCount,
                authoritativeRowMutationCount: projectionMetrics.authoritativeRowMutationCount,
                visibleIndexRebuildCount: projectionMetrics.visibleIndexRebuildCount,
                sourceIndexRebuildCount: projectionMetrics.sourceIndexRebuildCount,
                publishedDerivedValueCount: publishedDerivedValueCount
            ))
            if projectionMetrics.filterCountsChanged {
                pruneUnavailableDynamicFilters()
            }
            if projectionMetrics.visibleRowsChanged || projectionMetrics.sourceIndexRebuildCount > 0 {
                pruneSelectionToVisibleTorrents()
            }
            notifyCompletedDownloads(completedDownloads)
            reconcileTrackedTorrentOperations(
                requestSequenceByHash: sequencedUpdate.requestSequenceByHash
            )
        }
        recordAcceptedTorrentListPublication(
            sequencedUpdate,
            applyStartedAt: applyStartedAt
        )
        measurePerformanceHarnessLargeListIfNeeded()
    }

    private func nextTorrentListRequestSequence() -> UInt64 {
        torrentListRequestSequence = torrentListRequestSequence == .max
            ? 1
            : torrentListRequestSequence + 1
        return torrentListRequestSequence
    }

    private func torrentListRequestSequenceByHash(
        in update: TorrentListUpdate,
        requestSequence: UInt64
    ) -> [String: UInt64] {
        Dictionary(
            update.torrents.compactMap { torrent in
                torrent.hashString.flatMap(CanonicalTransmissionTorrentHash.normalize).map {
                    ($0, requestSequence)
                }
            },
            uniquingKeysWith: { max($0, $1) }
        )
    }

    private func recordRejectedTorrentListPublication(
        profileID: ConnectionProfile.ID,
        connectionGeneration: UUID,
        requestSequence: UInt64,
        rowCount: Int,
        reason: String
    ) {
        performanceHarnessInstrumentation?.record(PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .rejected,
            ownership: PerformanceHarnessTraceOwnership(
                profileID: profileID,
                connectionGeneration: connectionGeneration,
                requestSequence: requestSequence
            ),
            rowCount: rowCount,
            reason: reason
        ))
    }

    private func recordRejectedTorrentListPublication(
        _ update: SequencedTorrentListUpdate,
        reason: String,
        applyStartedAt: ContinuousClock.Instant?
    ) {
        guard let instrumentation = performanceHarnessInstrumentation, let applyStartedAt else {
            return
        }
        let duration = PerformanceHarnessTiming.nanoseconds(
            in: applyStartedAt.duration(to: ContinuousClock().now)
        )
        let ownership = PerformanceHarnessTraceOwnership(
            profileID: update.profileID,
            connectionGeneration: update.connectionGeneration,
            requestSequence: update.requestSequence
        )
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .rejected,
            ownership: ownership,
            durationNanoseconds: duration,
            rowCount: update.update.torrents.count,
            reason: reason
        ))
        recordMainThreadApply(
            ownership: ownership,
            rowCount: update.update.torrents.count,
            durationNanoseconds: duration
        )
    }

    private func recordAcceptedTorrentListPublication(
        _ update: SequencedTorrentListUpdate,
        applyStartedAt: ContinuousClock.Instant?
    ) {
        guard let instrumentation = performanceHarnessInstrumentation, let applyStartedAt else {
            return
        }
        let duration = PerformanceHarnessTiming.nanoseconds(
            in: applyStartedAt.duration(to: ContinuousClock().now)
        )
        let ownership = PerformanceHarnessTraceOwnership(
            profileID: update.profileID,
            connectionGeneration: update.connectionGeneration,
            requestSequence: update.requestSequence
        )
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .accepted,
            ownership: ownership,
            durationNanoseconds: duration,
            rowCount: update.update.torrents.count
        ))
        recordMainThreadApply(
            ownership: ownership,
            rowCount: update.update.torrents.count,
            durationNanoseconds: duration
        )
    }

    private func recordMainThreadApply(
        ownership: PerformanceHarnessTraceOwnership,
        rowCount: Int,
        durationNanoseconds: UInt64
    ) {
        guard let performanceHarnessInstrumentation else { return }
        performanceHarnessInstrumentation.record(PerformanceHarnessTraceRecord(
            event: .mainThreadApply,
            outcome: .measured,
            ownership: ownership,
            durationNanoseconds: durationNanoseconds,
            rowCount: rowCount
        ))
    }

    private func measurePerformanceHarnessLargeListIfNeeded() {
        guard
            let instrumentation = performanceHarnessInstrumentation,
            !performanceHarnessDidMeasureLargeList,
            torrentListProjection.rowCount >= 1_000
        else {
            return
        }
        performanceHarnessDidMeasureLargeList = true
        let rows = torrentListProjection.allRowsInSourceOrder()
        guard let firstRow = rows.first else { return }

        var searchFilters = TorrentFilters.empty
        searchFilters.searchText = firstRow.name
        recordPerformanceHarnessListMeasurement(
            instrumentation: instrumentation,
            operation: "search",
            rowCount: rows.count
        ) {
            filterEngine.filter(rows, using: searchFilters).count
        }
        recordPerformanceHarnessListMeasurement(
            instrumentation: instrumentation,
            operation: "sort",
            rowCount: rows.count
        ) {
            TorrentSorting.sorted(Array(rows.reversed()), using: torrentSortOrder).count
        }
        var statusFilters = TorrentFilters.empty
        statusFilters.statuses = [.active]
        recordPerformanceHarnessListMeasurement(
            instrumentation: instrumentation,
            operation: "filter",
            rowCount: rows.count
        ) {
            filterEngine.filter(rows, using: statusFilters).count
        }

        let selectedIDs = Set(rows.prefix(10).map(\.id))
        let startedAt = ContinuousClock().now
        let selectedCount = torrentListProjection.rows(for: selectedIDs).count
        let duration = PerformanceHarnessTiming.nanoseconds(
            in: startedAt.duration(to: ContinuousClock().now)
        )
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .cachedSelection,
            outcome: .measured,
            durationNanoseconds: duration,
            rowCount: rows.count,
            selectedCount: selectedCount,
            operation: "lookup"
        ))
    }

    private func recordPerformanceHarnessListMeasurement(
        instrumentation: any PerformanceHarnessInstrumenting,
        operation: String,
        rowCount: Int,
        _ action: () -> Int
    ) {
        let startedAt = ContinuousClock().now
        let resultCount = action()
        let duration = PerformanceHarnessTiming.nanoseconds(
            in: startedAt.duration(to: ContinuousClock().now)
        )
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .listProjection,
            outcome: .measured,
            durationNanoseconds: duration,
            rowCount: rowCount,
            selectedCount: resultCount,
            operation: operation
        ))
    }

    private func applyPerformanceHarnessDetailSelectionIfNeeded() {
        guard
            let performanceHarnessDetailSelection,
            performanceHarnessDetailSelection.isAuthorized(),
            !performanceHarnessDidSelectTorrentDetail,
            connectionState.isConnected,
            torrentListProjection.visibleIDs.contains(
                performanceHarnessDetailSelection.targetTorrentID
            )
        else {
            return
        }
        let torrentID = performanceHarnessDetailSelection.targetTorrentID

        let selectedPane: TorrentDetailPane = performanceHarnessInstrumentation?.requestsFilesPaneProof == true
            ? .files
            : .overview
        guard performanceHarnessDetailSelection.recordSelection(
            torrentID: torrentID,
            pane: selectedPane
        ) else {
            return
        }
        performanceHarnessDidSelectTorrentDetail = true
        isTorrentDetailVisible = true
        selectedTorrentDetailPane = selectedPane
        selectedTorrentIDs = [torrentID]
        cancelSelectedDetailDebounce()
        queueCurrentDetailRefresh(priority: .active, force: true)
    }

    private func updateTorrentListMetrics(_ metrics: TorrentListUpdateMetrics) {
        guard metrics != torrentListUpdateMetrics else { return }
        torrentListUpdateMetrics = metrics
    }

    private func materializeTorrentSnapshot() -> [TorrentSummary] {
        torrentSnapshotMaterializationCount &+= 1
        return torrentListProjection.allRowsInSourceOrder()
    }

    private func replaceTorrentSnapshot(_ snapshot: [TorrentSummary]) {
        torrentListProjection = TorrentListProjection(
            torrents: snapshot,
            filters: activeTorrentFilters,
            sortOrder: torrentSortOrder,
            filterEngine: filterEngine
        )
        reconcileSelectedDetailIdentityWithCurrentTorrentList()
        publishTorrentListProjection()
        pruneUnavailableDynamicFilters()
        pruneSelectionToVisibleTorrents()
    }

    /// Rebuilds the O(n log n) list projection only when filters or sorting
    /// change. Incremental RPC updates mutate the indexed projection directly.
    private func rebuildTorrentListProjection() {
        let snapshot = materializeTorrentSnapshot()
        let projection = TorrentListProjection(
            torrents: snapshot,
            filters: activeTorrentFilters,
            sortOrder: torrentSortOrder,
            filterEngine: filterEngine
        )
        torrentListProjection = projection
        publishTorrentListProjection()
    }

    @discardableResult
    private func publishTorrentListProjection() -> Int {
        var publishedDerivedValueCount = 0
        if visibleTorrents != torrentListProjection.visibleRows {
            visibleTorrents = torrentListProjection.visibleRows
            publishedDerivedValueCount += 1
        }
        if filterCounts != torrentListProjection.filterCounts {
            filterCounts = torrentListProjection.filterCounts
            publishedDerivedValueCount += 1
        }
        if refreshTorrentListSummary() {
            publishedDerivedValueCount += 1
        }
        if publishedDerivedValueCount > 0 {
            torrentListMaterializationRevision &+= 1
        }
        return publishedDerivedValueCount
    }

    @discardableResult
    private func refreshTorrentListSummary() -> Bool {
        let summary = torrentListProjection.makeSummary(
            selectedIDs: selectedTorrentIDs,
            sessionStats: sessionStats,
            sessionInfo: sessionInfo
        )
        if torrentListSummary != summary {
            torrentListSummary = summary
            return true
        }
        return false
    }

    private func pruneSelectionToVisibleTorrents() {
        let preservedIDs = selectedTorrentIDs.intersection(torrentListProjection.visibleIDs)
        if preservedIDs != selectedTorrentIDs {
            selectedTorrentIDs = preservedIDs
        }
    }

    private func pruneUnavailableDynamicFilters() {
        var filters = torrentFilters
        filters.paths.formIntersection(filterCounts.paths.map(\.value))
        filters.trackers.formIntersection(filterCounts.trackers.map(\.value))
        filters.labels.formIntersection(filterCounts.labels.map(\.value))
        if filters != torrentFilters {
            torrentFilters = filters
        }
    }

    private func notifyCompletedDownloads(_ completedDownloads: [DownloadCompletionTransition]) {
        guard applicationBehaviorPreferences.completionNotificationsEnabled else { return }
        for completedDownload in completedDownloads {
            downloadCompletionNotifier.notifyDownloadCompleted(torrentName: completedDownload.torrentName)
        }
    }

    private func refreshNextTorrentDetail(client: TransmissionRPCClient) async {
        if pollingVisibility == .background {
            dropQueuedDetailPrefetches()
        }
        guard isTorrentDetailVisible else { return }
        var request: DetailRefreshRequest?
        while !queuedDetailRefreshes.isEmpty, request == nil {
            let candidate = queuedDetailRefreshes.removeFirst()
            if isCurrentDetailRefresh(candidate) {
                request = candidate
            }
        }
        guard let request else { return }
        let operationID = UUID()
        activeDetailRefreshOperationID = operationID
        activeDetailRefreshKey = request.key
        activeDetailRefreshPriority = request.priority
        let detailFetchStartedAt = request.key.pane == .files
            && performanceHarnessInstrumentation != nil
            ? ContinuousClock().now
            : nil
        let previousSnapshot = selectedDetailSnapshots[request.key.pane]
        let overviewPlan = request.key.pane == .overview
            ? torrentListProjection.row(for: request.key.torrentID).map {
                TorrentOverviewRequestPlan(
                    summary: $0,
                    cachedInfo: previousSnapshot?.generalInfo,
                    rpcVersion: connectedRPCVersion ?? 0,
                    requiresPieceRevalidation: pieceRevalidationHashes.contains(request.key.torrentHash)
                )
            }
            : nil
        let refreshTask = Task<TorrentDetail, Error> {
            try await client.fetchTorrentDetail(
                id: request.key.torrentID,
                pane: request.key.pane,
                hash: request.key.torrentHash,
                overviewPlan: overviewPlan
            )
        }
        activeDetailRefreshTask = refreshTask
        defer {
            if activeDetailRefreshOperationID == operationID {
                activeDetailRefreshOperationID = nil
                activeDetailRefreshKey = nil
                activeDetailRefreshPriority = nil
                activeDetailRefreshTask = nil
                if !queuedDetailRefreshes.isEmpty {
                    queuedRefreshKinds.insert(.details)
                }
            }
        }

        do {
            var partialDetail = try await refreshTask.value
            guard
                activeDetailRefreshOperationID == operationID,
                isCurrentDetailRefresh(request),
                detailResponseMatchesRequestIdentity(partialDetail, request: request)
            else {
                return
            }

            if request.key.pane == .overview,
               hasAuthoritativePieceRevalidation(partialDetail, request: request, plan: overviewPlan) {
                pieceRevalidationHashes.remove(request.key.torrentHash)
                updateSelectedPieceRevalidationRequirement()
            }

            if let overviewPlan, let info = partialDetail.generalInfo,
               let summary = torrentListProjection.row(for: request.key.torrentID) {
                var mergedInfo = previousSnapshot?.generalInfo.map {
                    info.retainingOmittedFields(overviewPlan.omittedFields, from: $0)
                } ?? info
                if overviewPlan.omittedFields.contains("pieceCount") { mergedInfo.pieceCount = overviewPlan.pieceCount }
                if overviewPlan.omittedFields.contains("pieceSize") { mergedInfo.pieceSize = overviewPlan.pieceSize }
                mergedInfo.pieceMapState = TorrentPiecePresentation.state(summary: summary, cachedInfo: mergedInfo)
                partialDetail.generalInfo = mergedInfo
            }
            if let previousSnapshot {
                partialDetail = partialDetail.preservingUnchangedRevision(from: previousSnapshot, pane: request.key.pane)
            }
            let changed = previousSnapshot.map {
                !partialDetail.hasSamePayload(as: $0, pane: request.key.pane)
            } ?? true
            selectedDetailSnapshots[request.key.pane] = changed ? partialDetail : previousSnapshot
            if !selectedDetailLoadedPanes.contains(request.key.pane) {
                selectedDetailLoadedPanes.insert(request.key.pane)
            }
            if changed {
                selectedDetailPaneRevisions[request.key.pane, default: 0] &+= 1
                renderSelectedTorrentDetail()
            }
            torrentDetailCache.store(partialDetail, pane: request.key.pane, hash: request.key.torrentHash)
            recordPerformanceHarnessFilesRPCLatencyIfNeeded(
                detail: partialDetail,
                pane: request.key.pane,
                fetchStartedAt: detailFetchStartedAt
            )
            if request.key.pane == .peers {
                schedulePeerResolutionForCurrentSnapshot()
            }
            queueDetailPrefetches(after: request)
        } catch {
            if refreshTask.isCancelled || operationWasCancelled(error) {
                return
            }
            guard
                activeDetailRefreshOperationID == operationID,
                isCurrentDetailRefresh(request)
            else {
                return
            }
            if
                request.key.pane == selectedTorrentDetailPane,
                selectedDetailSnapshots[request.key.pane] == nil
            {
                updateSelectedTorrentDetailState(.failed(error.localizedDescription))
            }
            handleBackgroundRefreshFailure(
                error,
                token: request.key.connectionToken,
                surfaceNonRetryableError: effectiveDetailRefreshPriority(for: request) == .active
            )
        }
    }

    private func hasAuthoritativePieceRevalidation(
        _ detail: TorrentDetail,
        request: DetailRefreshRequest,
        plan: TorrentOverviewRequestPlan?
    ) -> Bool {
        if plan?.fields.contains("pieces") == true, case .available = detail.generalInfo?.pieceMapState {
            return true
        }
        // RPC 1-4 has no bitfield. Require explicit, current selected-response
        // status and byte evidence, rather than leaving an unfulfillable tombstone.
        guard (connectedRPCVersion ?? 0) < 5,
              let info = detail.generalInfo, info.status != nil,
              info.haveValid != nil, info.haveUnchecked != nil,
              let summary = torrentListProjection.row(for: request.key.torrentID) else { return false }
        if case .complete = TorrentPiecePresentation.state(summary: summary, cachedInfo: info) { return true }
        return false
    }

    private func detailResponseMatchesRequestIdentity(
        _ detail: TorrentDetail,
        request: DetailRefreshRequest
    ) -> Bool {
        guard
            detail.id == request.key.torrentID,
            let returnedHash = detail.generalInfo.flatMap({
                CanonicalTransmissionTorrentHash.normalize($0.hashString)
            })
        else {
            return false
        }
        return returnedHash == request.key.torrentHash
    }

    private func recordPerformanceHarnessFilesRPCLatencyIfNeeded(
        detail: TorrentDetail,
        pane: TorrentDetailPane,
        fetchStartedAt: ContinuousClock.Instant?
    ) {
        guard
            pane == .files,
            let instrumentation = performanceHarnessInstrumentation,
            let fetchStartedAt,
            detail.id == performanceHarnessDetailSelection?.targetTorrentID,
            let revision = detail.filesSnapshotRevision?.rawValue
        else {
            return
        }
        let fileCount = detail.files.count
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .filesRPCLatency,
            outcome: .measured,
            durationNanoseconds: PerformanceHarnessTiming.nanoseconds(
                in: fetchStartedAt.duration(to: ContinuousClock().now)
            ),
            torrentID: detail.id,
            revision: revision,
            fileCount: fileCount
        ))
    }

    private func installTorrentListFieldPlan(rpcVersion: Int) {
        torrentListFieldPlanRevision &+= 1
        currentTorrentListFieldPlan = makeTorrentListFieldPlan(rpcVersion: rpcVersion)
    }

    private func makeTorrentListFieldPlan(rpcVersion: Int) -> TorrentListFieldPlan {
        TorrentListFieldPlan(
            revision: torrentListFieldPlanRevision,
            rpcVersion: rpcVersion,
            visibleColumns: torrentTableVisibleColumns,
            activeSortColumn: torrentTableActiveSortColumn
        )
    }

    private func queueDetailPrefetches(after request: DetailRefreshRequest) {
        guard
            effectiveDetailRefreshPriority(for: request) == .active,
            pollingVisibility == .foreground
        else {
            return
        }
        queueDetailPrefetches(
            selectionGeneration: request.key.selectionGeneration,
            excluding: request.key.pane
        )
    }

    private func queueDetailPrefetches(
        selectionGeneration: Int,
        excluding pane: TorrentDetailPane
    ) {
        guard
            isTorrentDetailVisible,
            pollingVisibility == .foreground,
            selectedDetailSelectionGeneration == selectionGeneration,
            selectedTorrentDetailPane.needsRPCRefresh,
            prefetchedSelectionGeneration != selectionGeneration,
            let selectedID = selectedTorrentIDs.sorted().first,
            let torrent = torrentListProjection.row(for: selectedID),
            selectedDetailTorrentHash == CanonicalTransmissionTorrentHash.normalize(torrent.hashString)
        else {
            return
        }
        prefetchedSelectionGeneration = selectionGeneration
        for candidatePane in detailRefreshPolicy.prefetchPanes(for: torrent, excluding: pane) {
            queueCurrentDetailRefresh(pane: candidatePane, priority: .prefetch, force: false)
        }
    }

    private func renderSelectedTorrentDetail() {
        guard
            let selectedID = selectedTorrentIDs.sorted().first,
            selectedDetailTorrentID == selectedID,
            let selectedTorrent = torrentListProjection.row(for: selectedID),
            selectedDetailTorrentHash == CanonicalTransmissionTorrentHash.normalize(
                selectedTorrent.hashString
            )
        else {
            updateSelectedTorrentDetailState(.notLoaded)
            return
        }

        guard selectedTorrentDetailPane.needsRPCRefresh else {
            updateSelectedTorrentDetailState(.notLoaded)
            return
        }

        guard selectedDetailSnapshots[selectedTorrentDetailPane] != nil else {
            updateSelectedTorrentDetailState(.loading)
            return
        }

        var detail = TorrentDetail(id: selectedID)
        for pane in TorrentDetailRefreshPolicy.rpcPanes {
            if let snapshot = selectedDetailSnapshots[pane] {
                detail = detail.replacing(pane, with: snapshot)
            }
        }
        updateSelectedTorrentDetailState(.loaded(detail))
    }

    private func updateSelectedTorrentDetailState(_ state: TorrentDetailLoadState) {
        guard state != selectedTorrentDetailState else { return }
        selectedTorrentDetailState = state
    }

    private func schedulePeerResolutionForCurrentSnapshot() {
        guard !isClearingPeerResolutionCaches else {
            cancelPeerResolution()
            return
        }

        let effectivePreferences = peerResolutionPreferences.effective(
            countryDatabaseAvailable: peerCountryDatabase.status.isInstalled
        )
        guard effectivePreferences.resolveHostNames || effectivePreferences.resolveCountries else {
            cancelPeerResolution()
            clearPeerResolutionFromCurrentSnapshot()
            return
        }
        guard
            connectionState.isConnected,
            let selectedTorrentID = selectedDetailTorrentID,
            selectedTorrentIDs == [selectedTorrentID],
            let snapshot = selectedDetailSnapshots[.peers],
            snapshot.id == selectedTorrentID,
            let peersSnapshotRevision = snapshot.peersSnapshotRevision?.rawValue
        else {
            cancelPeerResolution()
            return
        }

        let endpoints = snapshot.peers.compactMap {
            PeerEndpoint(rawAddress: $0.host, port: $0.port)
        }
        guard !endpoints.isEmpty else {
            cancelPeerResolution()
            return
        }
        let context = PeerResolutionContext(
            profileID: selectedProfileID,
            connectionToken: connectionToken,
            selectionGeneration: selectedDetailSelectionGeneration,
            torrentID: selectedTorrentID,
            detailGeneration: selectedDetailPaneRevisions[.peers, default: 0],
            peersSnapshotRevision: peersSnapshotRevision
        )
        let request = PeerResolutionRequest(
            context: context,
            endpoints: endpoints,
            preferences: effectivePreferences
        )
        // Peer statistics change every poll, but DNS work belongs to the stable
        // connection/selection and address set, not to a stats revision.
        if peerResolutionTask != nil,
           peerResolutionRequest?.canReuseResolution(for: request) == true {
            peerResolutionRequest = request
            return
        }
        cancelPeerResolution()
        peerResolutionRequest = request
        let ownerID = UUID()
        let commandGeneration = peerResolutionCommandGeneration
        peerResolutionOwnerID = ownerID
        peerResolutionTask = Task { [peerEndpointResolver, weak self] in
            defer {
                if let self, self.peerResolutionOwnerID == ownerID {
                    self.peerResolutionTask = nil
                    self.peerResolutionOwnerID = nil
                    self.peerResolutionRequest = nil
                }
            }
            guard
                let batch = await peerEndpointResolver.resolve(request, ownerID: ownerID),
                batch.context == request.context,
                !Task.isCancelled,
                let self,
                self.peerResolutionOwnerID == ownerID,
                self.peerResolutionCommandGeneration == commandGeneration,
                let latestRequest = self.peerResolutionRequest,
                request.canReuseResolution(for: latestRequest)
            else {
                return
            }
            // Rebind only proven reusable work. The existing strict publication
            // guard still checks the latest snapshot and all connection owners.
            self.publishPeerResolution(PeerResolutionBatch(
                context: latestRequest.context,
                metadataByAddress: batch.metadataByAddress
            ))
        }
    }

    private func cancelPeerResolution() {
        peerResolutionCommandGeneration &+= 1
        peerResolutionTask?.cancel()
        peerResolutionTask = nil
        peerResolutionRequest = nil
        guard let ownerID = peerResolutionOwnerID else { return }
        peerResolutionOwnerID = nil
        Task { [peerEndpointResolver] in
            await peerEndpointResolver.cancel(ownerID: ownerID)
        }
    }

    private func publishPeerResolution(_ batch: PeerResolutionBatch) {
        guard
            PeerResolutionPublicationGuard.canPublish(
                expected: batch.context,
                profileID: selectedProfileID,
                connectionToken: connectionToken,
                selectionGeneration: selectedDetailSelectionGeneration,
                torrentID: selectedDetailTorrentID,
                detailGeneration: selectedDetailPaneRevisions[.peers, default: 0],
                peersSnapshotRevision: selectedDetailSnapshots[.peers]?
                    .peersSnapshotRevision?.rawValue
            ),
            var snapshot = selectedDetailSnapshots[.peers]
        else {
            return
        }
        let peers = snapshot.peers.map { peer -> TorrentPeer in
            let address = PeerIPAddress(parsing: peer.host)
            return peer.applying(address.flatMap { batch.metadataByAddress[$0] })
        }
        guard peers != snapshot.peers else { return }
        snapshot.peers = peers
        snapshot.peersSnapshotRevision = TorrentPeersSnapshotRevision()
        selectedDetailSnapshots[.peers] = snapshot
        if let hash = selectedDetailTorrentHash { torrentDetailCache.store(snapshot, pane: .peers, hash: hash) }
        selectedDetailPaneRevisions[.peers, default: 0] &+= 1
        renderSelectedTorrentDetail()
    }

    private func clearPeerResolutionFromCurrentSnapshot() {
        guard var snapshot = selectedDetailSnapshots[.peers] else { return }
        let peers = snapshot.peers.map(\.clearingResolution)
        guard peers != snapshot.peers else { return }
        snapshot.peers = peers
        snapshot.peersSnapshotRevision = TorrentPeersSnapshotRevision()
        selectedDetailSnapshots[.peers] = snapshot
        if let hash = selectedDetailTorrentHash { torrentDetailCache.store(snapshot, pane: .peers, hash: hash) }
        selectedDetailPaneRevisions[.peers, default: 0] &+= 1
        renderSelectedTorrentDetail()
    }

    private func isCurrentDetailRefresh(_ request: DetailRefreshRequest) -> Bool {
        isCurrentConnection(token: request.key.connectionToken)
            && (effectiveDetailRefreshPriority(for: request) == .active || pollingVisibility == .foreground)
            && selectedDetailSelectionGeneration == request.key.selectionGeneration
            && selectedDetailTorrentID == request.key.torrentID
            && selectedDetailTorrentHash == request.key.torrentHash
            && !activeDetailMutations.values.contains(where: { $0.contains(request.key.torrentHash) })
            && selectedTorrentIDs.sorted().first == request.key.torrentID
            && torrentListProjection.row(for: request.key.torrentID).flatMap {
                CanonicalTransmissionTorrentHash.normalize($0.hashString)
            } == request.key.torrentHash
            && selectedDetailPaneRevisions[request.key.pane, default: 0] == request.key.paneRevision
    }

    private func effectiveDetailRefreshPriority(
        for request: DetailRefreshRequest
    ) -> DetailRefreshPriority {
        guard activeDetailRefreshKey == request.key else { return request.priority }
        return activeDetailRefreshPriority ?? request.priority
    }

    private func refreshSessionInfo(
        client: TransmissionRPCClient,
        token: UUID
    ) async -> SessionInfo? {
        let requestSequence = nextSessionInfoRequestSequence()
        let refreshedSessionInfo: SessionInfo
        do {
            refreshedSessionInfo = try await client.getSession()
            guard publishSessionInfo(
                refreshedSessionInfo,
                client: client,
                token: token,
                requestSequence: requestSequence
            ) else { return nil }
        } catch {
            guard
                isCurrentConnection(token: token),
                self.client === client,
                requestSequence > latestPublishedSessionInfoRequestSequence
            else {
                return nil
            }
            handleBackgroundRefreshFailure(error, token: token)
            return nil
        }
        return refreshedSessionInfo
    }

    private func nextSessionInfoRequestSequence() -> UInt64 {
        sessionInfoRequestSequence &+= 1
        return sessionInfoRequestSequence
    }

    private func publishSessionInfo(
        _ refreshedSessionInfo: SessionInfo,
        client expectedClient: TransmissionRPCClient,
        token: UUID,
        requestSequence: UInt64
    ) -> Bool {
        guard
            isCurrentConnection(token: token),
            client === expectedClient,
            requestSequence > latestPublishedSessionInfoRequestSequence
        else {
            return false
        }
        latestPublishedSessionInfoRequestSequence = requestSequence
        if sessionInfo != refreshedSessionInfo {
            sessionInfo = refreshedSessionInfo
        }
        let connectedState = ConnectionState.connected(rpcVersion: refreshedSessionInfo.rpcVersion)
        if connectionState != connectedState {
            connectionState = connectedState
        }
        return true
    }

    private func refreshSessionStats(
        client: TransmissionRPCClient,
        token: UUID,
        sessionInfo: SessionInfo
    ) async {
        guard sessionInfo.capabilities.hasSessionStats else {
            resetDisplayedSpeedAverages()
            if sessionStats != nil {
                sessionStats = nil
            }
            return
        }

        do {
            let refreshedSessionStats = try await client.getSessionStats()
            guard isCurrentConnection(token: token) else { return }
            latestRawSessionStats = refreshedSessionStats
            let displayedStats = displayedSessionStats(
                from: refreshedSessionStats,
                timestamp: speedSampleClock()
            )
            if sessionStats != displayedStats {
                sessionStats = displayedStats
            }
        } catch {
            guard isCurrentConnection(token: token) else { return }
            handleBackgroundRefreshFailure(error, token: token)
        }
    }

    private func displayedSessionStats(
        from rawStats: SessionStats,
        timestamp: TimeInterval
    ) -> SessionStats {
        let downloadSnapshot = downloadSpeedAverager.update(
            bytesPerSecond: rawStats.downloadSpeed,
            at: timestamp
        )
        let uploadSnapshot = uploadSpeedAverager.update(
            bytesPerSecond: rawStats.uploadSpeed,
            at: timestamp
        )

        var displayedStats = rawStats
        displayedStats.downloadSpeed = Int64(downloadSnapshot.averageBytesPerSecond.rounded())
        displayedStats.uploadSpeed = Int64(uploadSnapshot.averageBytesPerSecond.rounded())
        return displayedStats
    }

    private func resetDisplayedSpeedAverages() {
        latestRawSessionStats = nil
        downloadSpeedAverager.reset()
        uploadSpeedAverager.reset()
    }

    private func resetRefreshQueue() {
        activeDetailRefreshTask?.cancel()
        activeDetailRefreshOperationID = nil
        activeDetailRefreshTask = nil
        queuedRefreshKinds = []
        queuedTorrentRowRefreshIDs = []
        queuedDetailRefreshes = []
        activeDetailRefreshKey = nil
        activeDetailRefreshPriority = nil
        activeRefreshDrainToken = nil
    }

    private func resetSelectedTorrentDetail() {
        torrentDetailCache.removeAll()
        activeDetailMutations = [:]
        pieceRevalidationHashes = []
        selectedTorrentRequiresPieceRevalidation = false
        cancelSelectedDetailDebounce()
        cancelPeerResolution()
        selectedDetailSelectionGeneration &+= 1
        selectedDetailTorrentID = nil
        selectedDetailTorrentHash = nil
        selectedDetailLoadedPanes = []
        selectedDetailSnapshots = [:]
        selectedDetailPaneRevisions = [:]
        prefetchedSelectionGeneration = nil
        updateSelectedTorrentDetailState(.notLoaded)
    }

    private func isPollingCurrent(token: UUID) -> Bool {
        isCurrentConnection(token: token) && connectionState.isConnected
    }

    private func isCurrentConnection(token: UUID) -> Bool {
        connectionToken == token && client != nil
    }

    private func isCurrentDaemonMaintenance(
        _ owner: DaemonMaintenanceOwner,
        client expectedClient: TransmissionRPCClient
    ) -> Bool {
        activeDaemonMaintenanceOwner == owner
            && owner.profileID == selectedProfileID
            && isCurrentConnection(token: owner.connectionToken)
            && client === expectedClient
    }

    private func finishDaemonMaintenance(_ owner: DaemonMaintenanceOwner) {
        guard activeDaemonMaintenanceOwner == owner else { return }
        activeDaemonMaintenanceOwner = nil
        activeDaemonMaintenanceTask = nil
        isTestingPort = false
        isUpdatingBlocklist = false
    }

    private func invalidateDaemonMaintenanceState(clearNotice: Bool) {
        activeDaemonMaintenanceOwner = nil
        activeDaemonMaintenanceTask?.cancel()
        activeDaemonMaintenanceTask = nil
        isTestingPort = false
        isUpdatingBlocklist = false
        if clearNotice {
            daemonMaintenanceNotice = nil
        }
    }

    private func invalidateDaemonOptionsApplyState() {
        activeDaemonOptionsApplyID = nil
        isApplyingDaemonOptions = false
    }

    private func isCurrentRemoval(_ confirmation: RemovalConfirmation) -> Bool {
        activeRemovalID == confirmation.id
            && confirmation.profileID == selectedProfileID
            && isCurrentConnection(token: confirmation.connectionToken)
    }

    private func invalidateRemovalState() {
        removalConfirmation = nil
        activeRemovalID = nil
        isRemoving = false
    }

    private func downloadedRemovalSize(for torrents: [TorrentSummary]) -> Int64 {
        torrents.reduce(into: Int64(0)) { total, torrent in
            let result = total.addingReportingOverflow(torrent.downloadedDataSize)
            total = result.overflow ? .max : result.partialValue
        }
    }

    private func invalidateGlobalBandwidthState() {
        if let updateID = activeBandwidthUpdateID, let updateTask = activeBandwidthUpdateTask {
            updateTask.cancel()
            retiredBandwidthUpdate = (updateID, updateTask)
        }
        activeBandwidthUpdateTask = nil
        activeBandwidthUpdateID = nil
        isUpdatingGlobalBandwidth = false
    }

    private func cancelGlobalBandwidthUpdate() async {
        invalidateGlobalBandwidthState()
        guard let retiredUpdate = retiredBandwidthUpdate else { return }
        _ = await retiredUpdate.task.result
        if retiredBandwidthUpdate?.id == retiredUpdate.id {
            retiredBandwidthUpdate = nil
        }
    }

    private func toggleValue(_ value: String, in set: inout Set<String>) {
        if set.contains(value) {
            set.remove(value)
        } else {
            set.insert(value)
        }
    }

    private func torrentRows(for ids: Set<TorrentSummary.ID>) -> [TorrentSummary] {
        guard !ids.isEmpty else { return [] }
        return torrentListProjection.rows(for: ids)
    }

    private func torrentIDs(for target: TorrentDuplicateTrackerTarget) -> [TorrentSummary.ID] {
        switch target {
        case .id(let id):
            return id > 0 ? [id] : []
        case .hash(let hashString):
            let normalizedHash = hashString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedHash.isEmpty else { return [] }
            return torrentListProjection.ids(matchingHash: normalizedHash)
        }
    }
}

private struct LocalTorrentPathResolutionError: LocalizedError, Equatable {
    var torrentName: String
    var message: String

    var errorDescription: String? {
        "Unable to resolve local path for \(torrentName): \(message)"
    }
}
