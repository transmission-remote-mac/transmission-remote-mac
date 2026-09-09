// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

struct WatchFolderPreferencesSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let defaults = WatchFolderPreferencesSnapshot(
        configuration: .defaults,
        processingState: .defaults
    )

    var configuration: WatchFolderConfiguration
    var processingState: WatchFolderProcessingState

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case configuration
        case processingState
    }

    init(
        configuration: WatchFolderConfiguration,
        processingState: WatchFolderProcessingState
    ) {
        self.configuration = configuration
        self.processingState = processingState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = (try? container.decode(Int.self, forKey: .schemaVersion)) ?? 0
        guard schemaVersion == Self.currentSchemaVersion else {
            self = .defaults
            return
        }
        self.init(
            configuration: (try? container.decode(
                WatchFolderConfiguration.self,
                forKey: .configuration
            )) ?? .defaults,
            processingState: (try? container.decode(
                WatchFolderProcessingState.self,
                forKey: .processingState
            )) ?? .defaults
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(configuration, forKey: .configuration)
        try container.encode(processingState, forKey: .processingState)
    }
}

struct WatchFolderPreferencesTransactionSnapshot {
    let preferences: WatchFolderPreferencesSnapshot
    let persistedData: Data?
}

@MainActor
final class WatchFolderPreferencesStore: ObservableObject {
    nonisolated static let storageKey = "application.watchFolderPreferences.v1"
    static let shared = WatchFolderPreferencesStore(
        userDefaults: ApplicationUserDefaultsFactory.defaultStore
    )

    @Published private(set) var snapshot: WatchFolderPreferencesSnapshot

    var configuration: WatchFolderConfiguration { snapshot.configuration }
    var processingState: WatchFolderProcessingState { snapshot.processingState }

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let encoder: JSONEncoder
    private var preservesUnsupportedFutureStorage: Bool {
        StoredPreferenceSchema.isFutureVersion(
            in: userDefaults.data(forKey: storageKey),
            key: "schemaVersion",
            currentVersion: WatchFolderPreferencesSnapshot.currentSchemaVersion
        )
    }

    init(
        userDefaults: UserDefaults = .standard,
        storageKey: String = WatchFolderPreferencesStore.storageKey,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        self.encoder = encoder
        let storedData = userDefaults.data(forKey: storageKey)
        let preservesUnsupportedFutureStorage = StoredPreferenceSchema.isFutureVersion(
            in: storedData,
            key: "schemaVersion",
            currentVersion: WatchFolderPreferencesSnapshot.currentSchemaVersion
        )

        if !preservesUnsupportedFutureStorage,
           let data = storedData,
           let decoded = try? decoder.decode(WatchFolderPreferencesSnapshot.self, from: data) {
            snapshot = decoded
        } else {
            snapshot = .defaults
        }
        if !preservesUnsupportedFutureStorage {
            persist(snapshot)
        }
    }

    func saveConfiguration(_ configuration: WatchFolderConfiguration) throws {
        guard configuration != snapshot.configuration else { return }
        let nextConfiguration = configuration.assigningRevision(
            nextRevision(after: snapshot.configuration.configurationRevision)
        )
        try save(WatchFolderPreferencesSnapshot(
            configuration: nextConfiguration,
            processingState: snapshot.processingState
        ))
    }

    func saveProcessingState(_ processingState: WatchFolderProcessingState) throws {
        guard !preservesUnsupportedFutureStorage else { return }
        guard processingState != snapshot.processingState else { return }
        guard processingState.revision > snapshot.processingState.revision else { return }
        try save(WatchFolderPreferencesSnapshot(
            configuration: snapshot.configuration,
            processingState: processingState
        ))
    }

    func save(
        configuration: WatchFolderConfiguration,
        processingState: WatchFolderProcessingState
    ) throws {
        guard !preservesUnsupportedFutureStorage else { return }
        guard configuration.configurationRevision
                == snapshot.configuration.configurationRevision,
              processingState.revision >= snapshot.processingState.revision else {
            return
        }
        guard processingState.revision != snapshot.processingState.revision
                || processingState == snapshot.processingState else {
            return
        }
        let nextSnapshot = WatchFolderPreferencesSnapshot(
            configuration: configuration,
            processingState: processingState
        )
        guard nextSnapshot != snapshot else { return }
        try save(nextSnapshot)
    }

    func makeFailuresRetryableNow(at time: TimeInterval = Date().timeIntervalSince1970) throws {
        var state = snapshot.processingState
        state.makeRetriesDue(at: time)
        try saveProcessingState(state)
    }

    func makeTransactionSnapshot() -> WatchFolderPreferencesTransactionSnapshot {
        WatchFolderPreferencesTransactionSnapshot(
            preferences: snapshot,
            persistedData: userDefaults.data(forKey: storageKey)
        )
    }

    func restoreTransactionSnapshot(_ transaction: WatchFolderPreferencesTransactionSnapshot) {
        if let persistedData = transaction.persistedData {
            userDefaults.set(persistedData, forKey: storageKey)
        } else {
            userDefaults.removeObject(forKey: storageKey)
        }
        snapshot = transaction.preferences
    }

    private func save(_ snapshot: WatchFolderPreferencesSnapshot) throws {
        let data = try encoder.encode(snapshot)
        userDefaults.set(data, forKey: storageKey)
        self.snapshot = snapshot
    }

    private func persist(_ snapshot: WatchFolderPreferencesSnapshot) {
        guard let data = try? encoder.encode(snapshot) else { return }
        userDefaults.set(data, forKey: storageKey)
    }

    private func nextRevision(after revision: UInt64) -> UInt64 {
        revision < UInt64.max ? revision + 1 : revision
    }
}
