// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

struct SettingsPortabilityRuntimeState {
    var profiles: [ConnectionProfile]
    var selectedProfileID: ConnectionProfile.ID
    var polling: PollingPreferences
    var visibleTorrentColumns: Set<TorrentTableColumnID>
    var torrentSort: TorrentTableSortPreference
    var isInfoPaneVisible: Bool
    var selectedDetailPane: TorrentDetailPane
}

struct SettingsPortabilityCommitResult {
    var collection: ConnectionProfileCollection
    var preferences: SettingsExportPreferences
}

enum SettingsImportCredentialKind: String, Equatable, Sendable {
    case rpcPassword
    case proxyPassword
    case clientIdentity

    var title: String {
        switch self {
        case .rpcPassword: "RPC password"
        case .proxyPassword: "Proxy password"
        case .clientIdentity: "Client identity"
        }
    }
}

struct SettingsImportCredentialNotice: Identifiable, Equatable, Sendable {
    var profileID: UUID
    var profileName: String
    var kind: SettingsImportCredentialKind

    var id: String {
        "\(profileID.uuidString.lowercased())|\(kind.rawValue)"
    }
}

struct SettingsImportPreview: Equatable, Sendable {
    var sourceName: String
    var document: SettingsPortabilityDocument
    var plan: SettingsImportPlan
    var credentialNotices: [SettingsImportCredentialNotice]
}

enum SettingsPortabilityCoordinatorError: LocalizedError, Equatable {
    case noImportPreview
    case previewOutOfDate
    case commitRejected(String)
    case rollbackFailed(original: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .noImportPreview:
            "Choose a settings file and review its preview first."
        case .previewOutOfDate:
            "Settings changed after the preview was prepared. Review the refreshed preview before confirming."
        case .commitRejected(let message):
            message
        case .rollbackFailed(let original, let rollback):
            "Settings import failed (\(original)); rollback also failed (\(rollback))."
        }
    }
}

enum SettingsPortabilityPreferenceKeys {
    static let workspace = "application.uiWorkspacePreferences.v1"
}

private typealias SettingsRollbackAction = @MainActor () throws -> Void

private struct SettingsPreferenceStoreRollbackSnapshot {
    private let storageKey: String
    private let storedValue: Any?
    private let hadStoredValue: Bool

    init(userDefaults: UserDefaults, storageKey: String) {
        self.storageKey = storageKey
        storedValue = userDefaults.object(forKey: storageKey)
        hadStoredValue = storedValue != nil
    }

    func restore(
        in userDefaults: UserDefaults,
        after restoreTypedValue: () throws -> Void
    ) throws {
        do {
            try restoreTypedValue()
        } catch {
            restoreStoredValue(in: userDefaults)
            throw error
        }
        restoreStoredValue(in: userDefaults)
    }

    private func restoreStoredValue(in userDefaults: UserDefaults) {
        if hadStoredValue {
            userDefaults.set(storedValue, forKey: storageKey)
        } else {
            userDefaults.removeObject(forKey: storageKey)
        }
    }
}

@MainActor
final class SettingsPortabilityCoordinator: ObservableObject {
    @Published private(set) var preview: SettingsImportPreview?
    @Published private(set) var message: String?
    @Published private(set) var errorMessage: String?
    @Published var collisionPolicy: SettingsProfileCollisionPolicy = .skipExisting {
        didSet {
            guard collisionPolicy != oldValue, importedDocument != nil else { return }
            do {
                try rebuildPreview()
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private let profileStore: ConnectionProfileStore
    private let userDefaults: UserDefaults
    private let behaviorPreferencesStore: ApplicationBehaviorPreferencesStore
    private let interactionPreferencesStore: ApplicationInteractionPreferencesStore
    private let intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore
    private let peerResolutionPreferencesStore: PeerResolutionPreferencesStore
    private let watchFolderPreferencesStore: WatchFolderPreferencesStore
    private let currentState: @MainActor () -> SettingsPortabilityRuntimeState
    private let commitReadinessIssue: @MainActor () -> String?
    private let didCommit: @MainActor (SettingsPortabilityCommitResult) -> Void

    private var importedDocument: SettingsPortabilityDocument?
    private var importedSourceName = "Settings file"

    init(
        profileStore: ConnectionProfileStore,
        userDefaults: UserDefaults,
        behaviorPreferencesStore: ApplicationBehaviorPreferencesStore,
        interactionPreferencesStore: ApplicationInteractionPreferencesStore,
        intakeAutomationPreferencesStore: IntakeAutomationPreferencesStore,
        peerResolutionPreferencesStore: PeerResolutionPreferencesStore,
        watchFolderPreferencesStore: WatchFolderPreferencesStore,
        currentState: @escaping @MainActor () -> SettingsPortabilityRuntimeState,
        commitReadinessIssue: @escaping @MainActor () -> String? = { nil },
        didCommit: @escaping @MainActor (SettingsPortabilityCommitResult) -> Void = { _ in }
    ) {
        self.profileStore = profileStore
        self.userDefaults = userDefaults
        self.behaviorPreferencesStore = behaviorPreferencesStore
        self.interactionPreferencesStore = interactionPreferencesStore
        self.intakeAutomationPreferencesStore = intakeAutomationPreferencesStore
        self.peerResolutionPreferencesStore = peerResolutionPreferencesStore
        self.watchFolderPreferencesStore = watchFolderPreferencesStore
        self.currentState = currentState
        self.commitReadinessIssue = commitReadinessIssue
        self.didCommit = didCommit
    }

    func exportData() throws -> Data {
        let runtime = currentState()
        let metadataByProfileID = Dictionary(uniqueKeysWithValues: runtime.profiles.compactMap { profile in
            profile.effectiveClientIdentityMetadata.map { (profile.id, $0) }
        })
        return try SettingsPortabilityService.encode(snapshot: SettingsExportSnapshot(
            profiles: runtime.profiles,
            selectedProfileID: runtime.selectedProfileID,
            applicationPreferences: try exportPreferences(for: runtime),
            clientCertificateMetadataByProfileID: metadataByProfileID
        ))
    }

    func prepareImport(_ data: Data, sourceName: String) throws {
        try prepareImport(
            SettingsPortabilityService.decodeAndValidate(data),
            sourceName: sourceName
        )
    }

    func prepareImport(
        _ document: SettingsPortabilityDocument,
        sourceName: String
    ) throws {
        importedDocument = nil
        preview = nil
        message = nil
        errorMessage = nil
        collisionPolicy = .skipExisting

        importedDocument = document
        importedSourceName = sourceName.isEmpty ? "Settings file" : sourceName
        try rebuildPreview()
    }

    /// Cancelling discards only in-memory preview state. No store or defaults key
    /// is touched before confirmImport() enters its commit transaction.
    func cancelImport() {
        importedDocument = nil
        preview = nil
        message = nil
        errorMessage = nil
        collisionPolicy = .skipExisting
    }

    @discardableResult
    func confirmImport() throws -> SettingsPortabilityCommitResult {
        guard let importedDocument, let preview else {
            throw SettingsPortabilityCoordinatorError.noImportPreview
        }
        if let issue = commitReadinessIssue() {
            throw SettingsPortabilityCoordinatorError.commitRejected(issue)
        }

        let runtime = currentState()
        let existingPreferences = try exportPreferences(for: runtime)
        let freshPlan = try SettingsPortabilityService.planImport(
            document: importedDocument,
            existingProfiles: runtime.profiles,
            existingPreferences: existingPreferences,
            existingClientCertificateMetadataByProfileID: identityMetadataByProfileID(
                in: runtime.profiles
            ),
            collisionPolicy: collisionPolicy
        )
        guard freshPlan == preview.plan else {
            self.preview = makePreview(
                document: importedDocument,
                plan: freshPlan,
                runtime: runtime
            )
            throw SettingsPortabilityCoordinatorError.previewOutOfDate
        }

        let collection = try importedCollection(plan: freshPlan, runtime: runtime)
        let importedPreferences: SettingsExportPreferences
        switch freshPlan.applicationPreferences {
        case .apply(let portablePreferences):
            importedPreferences = try SettingsPortabilityService.importedPreferences(
                from: portablePreferences
            )
        case .skipUnchanged:
            importedPreferences = existingPreferences
        }

        var rollbackActions: [SettingsRollbackAction] = []
        do {
            if importedPreferences != existingPreferences {
                try applyPreferences(
                    importedPreferences,
                    replacing: existingPreferences,
                    rollbackActions: &rollbackActions
                )
            }

            let currentCollection = try ConnectionProfileCollection(
                profiles: runtime.profiles,
                selectedProfileID: runtime.selectedProfileID
            )
            if collection != currentCollection {
                try profileStore.save(collection)
            }
        } catch {
            var rollbackErrors: [Error] = []
            for rollback in rollbackActions.reversed() {
                do {
                    try rollback()
                } catch {
                    rollbackErrors.append(error)
                }
            }
            if !rollbackErrors.isEmpty {
                throw SettingsPortabilityCoordinatorError.rollbackFailed(
                    original: error.localizedDescription,
                    rollback: rollbackErrors.map(\.localizedDescription).joined(separator: "; ")
                )
            }
            throw error
        }

        let result = SettingsPortabilityCommitResult(
            collection: collection,
            preferences: importedPreferences
        )
        didCommit(result)
        self.importedDocument = nil
        self.preview = nil
        message = "Settings imported. Re-enter any listed credentials and reselect any listed folders or identities."
        errorMessage = nil
        return result
    }

    func present(error: Error) {
        errorMessage = error.localizedDescription
        message = nil
    }

    func present(errorMessage: String) {
        self.errorMessage = errorMessage
        message = nil
    }

    func clearStatus() {
        errorMessage = nil
        message = nil
    }

    private func rebuildPreview() throws {
        guard let importedDocument else {
            preview = nil
            return
        }
        let runtime = currentState()
        let plan = try SettingsPortabilityService.planImport(
            document: importedDocument,
            existingProfiles: runtime.profiles,
            existingPreferences: try exportPreferences(for: runtime),
            existingClientCertificateMetadataByProfileID: identityMetadataByProfileID(
                in: runtime.profiles
            ),
            collisionPolicy: collisionPolicy
        )
        preview = makePreview(document: importedDocument, plan: plan, runtime: runtime)
    }

    private func makePreview(
        document: SettingsPortabilityDocument,
        plan: SettingsImportPlan,
        runtime: SettingsPortabilityRuntimeState
    ) -> SettingsImportPreview {
        let existingByID = Dictionary(uniqueKeysWithValues: runtime.profiles.map { ($0.id, $0) })
        let changedProfileIDs = Set(
            (plan.profileAdditions + plan.profileUpdates).map(\.id)
        )
        let unchangedProfileIDs = Set(plan.profileSkips.compactMap { skip in
            skip.reason == .unchanged ? skip.profileID : nil
        })
        var notices: [SettingsImportCredentialNotice] = []
        for profile in document.profiles
            where changedProfileIDs.contains(profile.id) || unchangedProfileIDs.contains(profile.id) {
            let existing = existingByID[profile.id]
            let isChanged = changedProfileIDs.contains(profile.id)
            if isChanged
                ? (profile.rpcCredentialRequirement == .reenterAfterImport
                    || existing?.password.isEmpty == false)
                : (profile.rpcCredentialRequirement == .reenterAfterImport
                    && existing?.password.isEmpty != false) {
                notices.append(SettingsImportCredentialNotice(
                    profileID: profile.id,
                    profileName: profile.name,
                    kind: .rpcPassword
                ))
            }
            if isChanged
                ? (profile.proxy.credentialRequirement == .reenterAfterImport
                    || existing?.proxyPassword.isEmpty == false)
                : (profile.proxy.credentialRequirement == .reenterAfterImport
                    && existing?.proxyPassword.isEmpty != false) {
                notices.append(SettingsImportCredentialNotice(
                    profileID: profile.id,
                    profileName: profile.name,
                    kind: .proxyPassword
                ))
            }
            if isChanged
                ? (profile.clientCertificate != nil || existing?.hasClientIdentity == true)
                : (profile.clientCertificate != nil && existing?.hasClientIdentity != true) {
                notices.append(SettingsImportCredentialNotice(
                    profileID: profile.id,
                    profileName: profile.name,
                    kind: .clientIdentity
                ))
            }
        }
        notices.sort {
            if $0.profileName != $1.profileName {
                return $0.profileName.localizedStandardCompare($1.profileName) == .orderedAscending
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return SettingsImportPreview(
            sourceName: importedSourceName,
            document: document,
            plan: plan,
            credentialNotices: notices
        )
    }

    private func importedCollection(
        plan: SettingsImportPlan,
        runtime: SettingsPortabilityRuntimeState
    ) throws -> ConnectionProfileCollection {
        var profiles = runtime.profiles
        for portableProfile in plan.profileUpdates {
            guard let index = profiles.firstIndex(where: { $0.id == portableProfile.id }) else {
                continue
            }
            profiles[index] = try SettingsPortabilityService.importedConnectionProfile(
                from: portableProfile,
                replacing: profiles[index]
            )
        }
        for portableProfile in plan.profileAdditions {
            profiles.append(try SettingsPortabilityService.importedConnectionProfile(
                from: portableProfile,
                replacing: nil
            ))
        }
        return try ConnectionProfileCollection(
            profiles: profiles,
            selectedProfileID: plan.selectedProfileID ?? runtime.selectedProfileID
        )
    }

    private func exportPreferences(
        for runtime: SettingsPortabilityRuntimeState
    ) throws -> SettingsExportPreferences {
        let storedWorkspace = UIWorkspacePersistenceService.decode(
            userDefaults.data(forKey: SettingsPortabilityPreferenceKeys.workspace)
        )
        let storedSecondaryTables = SecondaryTableWorkspacePreferences(
            files: secondaryTablePreference(for: .files),
            peers: secondaryTablePreference(for: .peers),
            trackers: secondaryTablePreference(for: .trackers)
        )
        let tableSnapshot = try TableColumnCustomizationPortabilityService.persistedSnapshot(
            from: userDefaults,
            fallbackVisibleTorrentColumns: runtime.visibleTorrentColumns,
            fallbackSecondaryTables: storedSecondaryTables
        )
        let secondaryTables = SecondaryTableWorkspacePreferences(
            files: SecondaryTableLayoutPreference(
                hiddenColumnIDs: tableSnapshot.hiddenFileColumnIDs,
                sortPreference: storedSecondaryTables.files.sortPreference
            ),
            peers: SecondaryTableLayoutPreference(
                hiddenColumnIDs: tableSnapshot.hiddenPeerColumnIDs,
                sortPreference: storedSecondaryTables.peers.sortPreference
            ),
            trackers: SecondaryTableLayoutPreference(
                hiddenColumnIDs: tableSnapshot.hiddenTrackerColumnIDs,
                sortPreference: storedSecondaryTables.trackers.sortPreference
            )
        )
        let workspace = UIWorkspacePreferences(
            sidebarGrouping: storedWorkspace.sidebarGrouping,
            filterPane: storedWorkspace.filterPane,
            statusSummary: storedWorkspace.statusSummary,
            sidebarWidth: storedWorkspace.sidebarWidth,
            infoPane: InfoPaneWorkspacePreferences(
                isVisible: runtime.isInfoPaneVisible,
                height: storedWorkspace.infoPane.height,
                selectedDetailPane: runtime.selectedDetailPane
            ),
            mainWindow: storedWorkspace.mainWindow,
            secondaryTables: secondaryTables
        )
        return SettingsExportPreferences(
            polling: runtime.polling,
            behavior: behaviorPreferencesStore.preferences,
            interaction: interactionPreferencesStore.preferences,
            intake: intakeAutomationPreferencesStore.preferences,
            peerResolution: peerResolutionPreferencesStore.preferences,
            watchFolderConfiguration: watchFolderPreferencesStore.configuration,
            workspace: workspace,
            visibleTorrentColumns: tableSnapshot.visibleTorrentColumns,
            torrentSort: runtime.torrentSort,
            tableColumnCustomizations: tableSnapshot.portableValue
        )
    }

    private func secondaryTablePreference(
        for table: SecondaryTableKind
    ) -> SecondaryTableLayoutPreference {
        let layout = SecondaryTableLayoutPreference.restored(
            from: userDefaults.string(forKey: table.layoutStorageKey),
            for: table
        )
        let sortKey = sortStorageKey(for: table)
        guard let rawSort = userDefaults.string(forKey: sortKey),
              let sort = SecondaryTableSortPreference(rawValue: rawSort) else {
            return layout
        }
        return layout.settingSort(sort, for: table)
    }

    private func applyPreferences(
        _ preferences: SettingsExportPreferences,
        replacing previous: SettingsExportPreferences,
        rollbackActions: inout [SettingsRollbackAction]
    ) throws {
        if preferences.behavior != previous.behavior {
            let snapshot = SettingsPreferenceStoreRollbackSnapshot(
                userDefaults: userDefaults,
                storageKey: ApplicationBehaviorPreferencesStore.storageKey
            )
            try behaviorPreferencesStore.save(preferences.behavior)
            rollbackActions.append { [behaviorPreferencesStore, userDefaults] in
                try snapshot.restore(in: userDefaults) {
                    try behaviorPreferencesStore.save(previous.behavior)
                }
            }
        }
        if preferences.interaction != previous.interaction {
            let snapshot = SettingsPreferenceStoreRollbackSnapshot(
                userDefaults: userDefaults,
                storageKey: ApplicationInteractionPreferencesStore.storageKey
            )
            try interactionPreferencesStore.save(preferences.interaction)
            rollbackActions.append { [interactionPreferencesStore, userDefaults] in
                try snapshot.restore(in: userDefaults) {
                    try interactionPreferencesStore.save(previous.interaction)
                }
            }
        }
        if preferences.intake != previous.intake {
            let snapshot = SettingsPreferenceStoreRollbackSnapshot(
                userDefaults: userDefaults,
                storageKey: IntakeAutomationPreferencesStore.storageKey
            )
            try intakeAutomationPreferencesStore.save(preferences.intake)
            rollbackActions.append { [intakeAutomationPreferencesStore, userDefaults] in
                try snapshot.restore(in: userDefaults) {
                    try intakeAutomationPreferencesStore.save(previous.intake)
                }
            }
        }
        if preferences.peerResolution != previous.peerResolution {
            let snapshot = SettingsPreferenceStoreRollbackSnapshot(
                userDefaults: userDefaults,
                storageKey: PeerResolutionPreferencesStore.storageKey
            )
            try peerResolutionPreferencesStore.save(preferences.peerResolution)
            rollbackActions.append { [peerResolutionPreferencesStore, userDefaults] in
                try snapshot.restore(in: userDefaults) {
                    try peerResolutionPreferencesStore.save(previous.peerResolution)
                }
            }
        }
        if preferences.watchFolderConfiguration != previous.watchFolderConfiguration {
            let previousSnapshot = watchFolderPreferencesStore.makeTransactionSnapshot()
            try watchFolderPreferencesStore.saveConfiguration(preferences.watchFolderConfiguration)
            rollbackActions.append { [watchFolderPreferencesStore] in
                watchFolderPreferencesStore.restoreTransactionSnapshot(previousSnapshot)
            }
        }
        if preferences.polling != previous.polling {
            preferences.polling.save(to: userDefaults)
            rollbackActions.append { [userDefaults] in
                previous.polling.save(to: userDefaults)
            }
        }

        let defaultsTransaction = try makeDefaultsTransaction(for: preferences)
        if defaultsTransaction.hasChanges(in: userDefaults) {
            let snapshot = defaultsTransaction.snapshot(from: userDefaults)
            defaultsTransaction.apply(to: userDefaults)
            rollbackActions.append { [userDefaults] in
                snapshot.restore(to: userDefaults)
            }
        }
    }

    private func makeDefaultsTransaction(
        for preferences: SettingsExportPreferences
    ) throws -> SettingsDefaultsTransaction {
        guard let portableTableValue = preferences.tableColumnCustomizations else {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                "Complete table customizations are missing."
            )
        }
        let tableSnapshot = try TableColumnCustomizationPortabilityService.validated(
            portableTableValue
        )

        let secondary = preferences.workspace.secondaryTables
        return SettingsDefaultsTransaction(values: [
            SettingsPortabilityPreferenceKeys.workspace:
                try UIWorkspacePersistenceService.encode(preferences.workspace),
            TorrentTableColumnPreferenceKeys.customization:
                tableSnapshot.portableValue.main.encodedValue,
            TorrentTableColumnPreferenceKeys.sort:
                preferences.torrentSort.rawValue,
            SecondaryTablePreferenceKeys.fileColumns:
                tableSnapshot.portableValue.files.encodedValue,
            SecondaryTablePreferenceKeys.fileLayout:
                secondary.files.normalized(for: .files).rawValue,
            SecondaryTablePreferenceKeys.fileSort:
                secondary.files.normalized(for: .files).sortPreference.rawValue,
            SecondaryTablePreferenceKeys.peerColumns:
                tableSnapshot.portableValue.peers.encodedValue,
            SecondaryTablePreferenceKeys.peerLayout:
                secondary.peers.normalized(for: .peers).rawValue,
            SecondaryTablePreferenceKeys.peerSort:
                secondary.peers.normalized(for: .peers).sortPreference.rawValue,
            SecondaryTablePreferenceKeys.trackerColumns:
                tableSnapshot.portableValue.trackers.encodedValue,
            SecondaryTablePreferenceKeys.trackerLayout:
                secondary.trackers.normalized(for: .trackers).rawValue,
            SecondaryTablePreferenceKeys.trackerSort:
                secondary.trackers.normalized(for: .trackers).sortPreference.rawValue,
        ])
    }

    private func sortStorageKey(for table: SecondaryTableKind) -> String {
        switch table {
        case .files: SecondaryTablePreferenceKeys.fileSort
        case .peers: SecondaryTablePreferenceKeys.peerSort
        case .trackers: SecondaryTablePreferenceKeys.trackerSort
        }
    }

    private func identityMetadataByProfileID(
        in profiles: [ConnectionProfile]
    ) -> [UUID: ClientIdentityMetadata] {
        Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in
            profile.effectiveClientIdentityMetadata.map { (profile.id, $0) }
        })
    }
}

private struct SettingsDefaultsTransaction {
    var values: [String: Any]

    func hasChanges(in userDefaults: UserDefaults) -> Bool {
        values.contains { entry in
            !Self.valuesEqual(userDefaults.object(forKey: entry.key), entry.value)
        }
    }

    func snapshot(from userDefaults: UserDefaults) -> SettingsDefaultsSnapshot {
        var previousValues: [String: Any] = [:]
        var missingKeys = Set<String>()
        for key in values.keys {
            if let value = userDefaults.object(forKey: key) {
                previousValues[key] = value
            } else {
                missingKeys.insert(key)
            }
        }
        return SettingsDefaultsSnapshot(values: previousValues, missingKeys: missingKeys)
    }

    func apply(to userDefaults: UserDefaults) {
        for (key, value) in values {
            userDefaults.set(value, forKey: key)
        }
    }

    private static func valuesEqual(_ lhs: Any?, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case let (lhs as Data, rhs as Data): lhs == rhs
        case let (lhs as String, rhs as String): lhs == rhs
        case let (lhs as NSNumber, rhs as NSNumber): lhs == rhs
        default: false
        }
    }
}

private struct SettingsDefaultsSnapshot {
    var values: [String: Any]
    var missingKeys: Set<String>

    func restore(to userDefaults: UserDefaults) {
        for key in missingKeys {
            userDefaults.removeObject(forKey: key)
        }
        for (key, value) in values {
            userDefaults.set(value, forKey: key)
        }
    }
}
