// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum SettingsPortabilityService {
    static let maximumDocumentByteCount = 2 * 1_024 * 1_024

    static func encode(snapshot: SettingsExportSnapshot) throws -> Data {
        let document = try makeDocument(snapshot: snapshot)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(document)
        guard data.count <= maximumDocumentByteCount else {
            throw SettingsPortabilityError.settingsDocumentTooLarge
        }
        return data
    }

    static func makeDocument(snapshot: SettingsExportSnapshot) throws -> SettingsPortabilityDocument {
        let profiles = try snapshot.profiles.map { profile in
            try portableProfile(
                from: profile,
                clientCertificateMetadata: snapshot.clientCertificateMetadataByProfileID[profile.id]
                    ?? profile.effectiveClientIdentityMetadata
            )
        }
        return try validated(SettingsPortabilityDocument(
            profiles: profiles,
            selectedProfileID: snapshot.selectedProfileID,
            applicationPreferences: try portablePreferences(from: snapshot.applicationPreferences)
        ))
    }

    static func decodeAndValidate(_ data: Data) throws -> SettingsPortabilityDocument {
        guard data.count <= maximumDocumentByteCount else {
            throw SettingsPortabilityError.settingsDocumentTooLarge
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SettingsPortabilityError.malformedDocument
        }
        if let forbiddenField = firstForbiddenField(in: root) {
            throw SettingsPortabilityError.forbiddenField(forbiddenField)
        }

        let decoder = JSONDecoder()
        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw SettingsPortabilityError.malformedDocument
        }
        guard probe.schemaIdentifier == SettingsPortabilityDocument.schemaIdentifier else {
            throw SettingsPortabilityError.invalidSchemaIdentifier(probe.schemaIdentifier)
        }
        guard
            probe.schemaVersion == SettingsPortabilityDocument.currentSchemaVersion
                || probe.schemaVersion == SettingsPortabilityDocument.legacySchemaVersion
        else {
            throw SettingsPortabilityError.unsupportedSchemaVersion(probe.schemaVersion)
        }

        do {
            return try validated(decoder.decode(SettingsPortabilityDocument.self, from: data))
        } catch let error as SettingsPortabilityError {
            throw error
        } catch {
            throw SettingsPortabilityError.malformedDocument
        }
    }

    static func validated(_ document: SettingsPortabilityDocument) throws -> SettingsPortabilityDocument {
        guard document.schemaIdentifier == SettingsPortabilityDocument.schemaIdentifier else {
            throw SettingsPortabilityError.invalidSchemaIdentifier(document.schemaIdentifier)
        }
        let isLegacyDocument = document.schemaVersion == SettingsPortabilityDocument.legacySchemaVersion
        guard isLegacyDocument
                || document.schemaVersion == SettingsPortabilityDocument.currentSchemaVersion else {
            throw SettingsPortabilityError.unsupportedSchemaVersion(document.schemaVersion)
        }

        var profileIDs = Set<UUID>()
        var profileNames = Set<String>()
        var profiles: [PortableConnectionProfile] = []
        for profile in document.profiles {
            guard profileIDs.insert(profile.id).inserted else {
                throw SettingsPortabilityError.duplicateProfileIdentifier(profile.id)
            }
            let normalized = try validated(profile)
            let normalizedName = normalized.name.lowercased()
            guard profileNames.insert(normalizedName).inserted else {
                throw SettingsPortabilityError.duplicateProfileName(normalized.name)
            }
            profiles.append(normalized)
        }
        profiles.sort { stableUUID($0.id) < stableUUID($1.id) }

        if let selectedProfileID = document.selectedProfileID,
           !profileIDs.contains(selectedProfileID) {
            throw SettingsPortabilityError.selectedProfileMissing(selectedProfileID)
        }

        return SettingsPortabilityDocument(
            profiles: profiles,
            selectedProfileID: document.selectedProfileID,
            applicationPreferences: try validated(
                document.applicationPreferences,
                allowsLegacyTableDefaults: isLegacyDocument
            )
        )
    }

    static func planImport(
        document: SettingsPortabilityDocument,
        existingProfiles: [ConnectionProfile],
        existingPreferences: SettingsExportPreferences,
        existingClientCertificateMetadataByProfileID: [UUID: ClientIdentityMetadata] = [:],
        collisionPolicy: SettingsProfileCollisionPolicy
    ) throws -> SettingsImportPlan {
        let document = try validated(document)
        let existingPortableProfiles = try existingProfiles.map { profile in
            try portableProfile(
                from: profile,
                clientCertificateMetadata: existingClientCertificateMetadataByProfileID[profile.id]
                    ?? profile.effectiveClientIdentityMetadata
            )
        }

        var existingByID: [UUID: PortableConnectionProfile] = [:]
        var existingNames = Set<String>()
        for profile in existingPortableProfiles {
            guard existingByID.updateValue(profile, forKey: profile.id) == nil else {
                throw SettingsPortabilityError.duplicateExistingProfileIdentifier(profile.id)
            }
            guard existingNames.insert(profile.name.lowercased()).inserted else {
                throw SettingsPortabilityError.duplicateProfileName(profile.name)
            }
        }

        var candidateUpdates: [UUID: PortableConnectionProfile] = [:]
        var candidateAdditions: [UUID: PortableConnectionProfile] = [:]
        var skipsByID: [UUID: SettingsProfileImportSkipReason] = [:]

        for profile in document.profiles {
            guard let existing = existingByID[profile.id] else {
                candidateAdditions[profile.id] = profile
                continue
            }
            guard !hasSamePortableConfiguration(existing, profile) else {
                skipsByID[profile.id] = .unchanged
                continue
            }
            guard collisionPolicy == .updateMatchingIdentifier else {
                skipsByID[profile.id] = .identifierCollision
                continue
            }
            candidateUpdates[profile.id] = profile
        }

        let accepted = resolveFinalNameCollisions(
            existingProfiles: existingPortableProfiles,
            candidateUpdates: candidateUpdates,
            candidateAdditions: candidateAdditions
        )
        for (profileID, conflictingID) in accepted.rejectedByID {
            skipsByID[profileID] = .nameCollision(existingProfileID: conflictingID)
        }

        let additions = candidateAdditions.values
            .filter { accepted.acceptedAdditionIDs.contains($0.id) }
            .sorted { stableUUID($0.id) < stableUUID($1.id) }
        let updates = candidateUpdates.values
            .filter { accepted.acceptedUpdateIDs.contains($0.id) }
            .sorted { stableUUID($0.id) < stableUUID($1.id) }
        let skips = skipsByID.map {
            SettingsProfileImportSkip(profileID: $0.key, reason: $0.value)
        }.sorted { stableUUID($0.profileID) < stableUUID($1.profileID) }

        let importedPreferences = try importedPreferences(from: document.applicationPreferences)
        let comparableExistingPreferences = try normalizedExportPreferences(existingPreferences)
        let preferenceAction: SettingsApplicationPreferencesImportAction =
            importedPreferences == comparableExistingPreferences
                ? .skipUnchanged
                : .apply(document.applicationPreferences)
        let availableProfileIDs = Set(existingPortableProfiles.map(\.id))
            .union(additions.map(\.id))
        let selectedProfileID = document.selectedProfileID.flatMap {
            availableProfileIDs.contains($0) ? $0 : nil
        }

        return SettingsImportPlan(
            profileAdditions: additions,
            profileUpdates: updates,
            profileSkips: skips,
            selectedProfileID: selectedProfileID,
            applicationPreferences: preferenceAction
        )
    }

    static func importedConnectionProfile(
        from portableProfile: PortableConnectionProfile,
        replacing existingProfile: ConnectionProfile?
    ) throws -> ConnectionProfile {
        let portableProfile = try validated(portableProfile)
        let transferPreferences = importedTransferPreferences(
            from: portableProfile.transferPreferences,
            preservingDestinationHistoryFrom: existingProfile?.transferPreferences
        )
        let removesExistingIdentity = existingProfile?.hasClientIdentity == true
        let identityEditState = removesExistingIdentity
            ? ClientIdentityEditState(removeOnApply: true)
            : nil

        do {
            return try ConnectionProfile.validated(
                id: portableProfile.id,
                name: portableProfile.name,
                scheme: portableProfile.scheme,
                host: portableProfile.host,
                port: portableProfile.port,
                rpcPath: portableProfile.rpcPath,
                username: portableProfile.username,
                password: "",
                pathMappings: portableProfile.pathMappings.map {
                    PathMapping(
                        remotePathPrefix: $0.remotePathPrefix,
                        localPathPrefix: $0.localPathPrefix
                    )
                },
                askPasswordAtConnect: portableProfile.askPasswordAtConnect,
                connectOnLaunch: portableProfile.connectOnLaunch,
                autoReconnect: portableProfile.autoReconnect,
                requestTimeoutSeconds: portableProfile.requestTimeoutSeconds,
                transferPreferences: transferPreferences,
                proxySettings: ProxySettings(
                    transport: portableProfile.proxy.transport,
                    host: portableProfile.proxy.host,
                    port: portableProfile.proxy.port,
                    authenticationEnabled: portableProfile.proxy.authenticationEnabled,
                    username: portableProfile.proxy.username
                ),
                proxyPassword: "",
                clientIdentityMetadata: existingProfile?.effectiveClientIdentityMetadata,
                clientIdentityEditState: identityEditState
            )
        } catch {
            throw SettingsPortabilityError.invalidProfile(
                portableProfile.id,
                error.localizedDescription
            )
        }
    }

    static func importedPreferences(
        from portablePreferences: PortableApplicationPreferences
    ) throws -> SettingsExportPreferences {
        let portablePreferences = try validated(portablePreferences)
        let polling = PollingPreferences(
            foregroundIntervalSeconds: portablePreferences.polling.foregroundIntervalSeconds,
            backgroundIntervalSeconds: portablePreferences.polling.backgroundIntervalSeconds,
            backgroundPolicy: portablePreferences.polling.backgroundPolicy,
            adaptiveIdleEnabled: portablePreferences.polling.adaptiveIdleEnabled
        )
        let visibleColumns = Set(portablePreferences.torrentTable.visibleColumnIDs.compactMap(
            TorrentTableColumnID.init(rawValue:)
        ))
        let torrentSort = TorrentTableSortPreference(
            columnID: TorrentTableColumnID(rawValue: portablePreferences.torrentTable.sortColumnID)
                ?? TorrentTableDefaults.sort.columnID,
            direction: torrentSortDirection(portablePreferences.torrentTable.sortDirection)
        )
        let watchFolder = WatchFolderConfiguration(
            isEnabled: false,
            sourceBookmarkData: nil,
            remoteDestination: portablePreferences.watchFolder.remoteDestination,
            scanIntervalSeconds: portablePreferences.watchFolder.scanIntervalSeconds,
            successPolicy: portablePreferences.watchFolder.successPolicy,
            submissionPolicy: portablePreferences.watchFolder.submissionPolicy,
            processedFolderBookmarkData: nil
        )

        return SettingsExportPreferences(
            polling: polling,
            behavior: portablePreferences.behavior,
            interaction: portablePreferences.interaction,
            intake: portablePreferences.intake,
            peerResolution: portablePreferences.peerResolution,
            watchFolderConfiguration: watchFolder,
            workspace: portablePreferences.workspace,
            visibleTorrentColumns: visibleColumns,
            torrentSort: torrentSort,
            tableColumnCustomizations: portablePreferences.tableColumnCustomizations
        )
    }

    private static func portableProfile(
        from profile: ConnectionProfile,
        clientCertificateMetadata: ClientIdentityMetadata?
    ) throws -> PortableConnectionProfile {
        let requiresSavedRPCCredential = !profile.askPasswordAtConnect && !profile.password.isEmpty
        let requiresSavedProxyCredential = profile.proxySettings.authenticationEnabled
            && !profile.proxyPassword.isEmpty
        let normalized: ConnectionProfile
        do {
            normalized = try profile.normalized()
        } catch {
            throw SettingsPortabilityError.invalidProfile(profile.id, error.localizedDescription)
        }

        let clientCertificate: PortableClientCertificateMetadata?
        if let clientCertificateMetadata {
            guard normalized.scheme == "https" else {
                throw SettingsPortabilityError.clientCertificateRequiresHTTPS(normalized.id)
            }
            clientCertificate = try portableCertificate(
                from: clientCertificateMetadata,
                profileID: normalized.id
            )
        } else {
            clientCertificate = nil
        }

        return PortableConnectionProfile(
            id: normalized.id,
            name: normalized.name,
            scheme: normalized.scheme,
            host: normalized.host,
            port: normalized.port,
            rpcPath: normalized.rpcPath,
            username: normalized.username,
            askPasswordAtConnect: normalized.askPasswordAtConnect,
            rpcCredentialRequirement: requiresSavedRPCCredential ? .reenterAfterImport : .none,
            pathMappings: normalized.pathMappings.map {
                PortablePathMapping(
                    remotePathPrefix: $0.remotePathPrefix,
                    localPathPrefix: $0.localPathPrefix
                )
            },
            connectOnLaunch: normalized.connectOnLaunch,
            autoReconnect: normalized.autoReconnect,
            requestTimeoutSeconds: normalized.requestTimeoutSeconds,
            transferPreferences: PortableProfileTransferPreferences(
                downloadSpeedPresetsKBps: normalized.transferPreferences.downloadSpeedPresetsKBps,
                uploadSpeedPresetsKBps: normalized.transferPreferences.uploadSpeedPresetsKBps,
                destinationHistoryLimit: normalized.transferPreferences.destinationHistoryLimit
            ),
            proxy: PortableProxySettings(
                transport: normalized.proxySettings.transport,
                host: normalized.proxySettings.host,
                port: normalized.proxySettings.port,
                authenticationEnabled: normalized.proxySettings.authenticationEnabled,
                username: normalized.proxySettings.username,
                credentialRequirement: requiresSavedProxyCredential ? .reenterAfterImport : .none
            ),
            clientCertificate: clientCertificate
        )
    }

    private static func validated(_ profile: PortableConnectionProfile) throws -> PortableConnectionProfile {
        let proxySettings: ProxySettings
        do {
            proxySettings = try ProxySettings.validated(
                transport: profile.proxy.transport,
                host: profile.proxy.host,
                port: profile.proxy.port,
                authenticationEnabled: profile.proxy.authenticationEnabled,
                username: profile.proxy.username
            )
        } catch {
            throw SettingsPortabilityError.invalidProfile(profile.id, error.localizedDescription)
        }

        let normalizedTransferPreferences = try validated(
            profile.transferPreferences,
            profileID: profile.id
        )
        let pathMappings = profile.pathMappings.map {
            PathMapping(remotePathPrefix: $0.remotePathPrefix, localPathPrefix: $0.localPathPrefix)
        }
        let normalized: ConnectionProfile
        do {
            normalized = try ConnectionProfile.validated(
                id: profile.id,
                name: profile.name,
                scheme: profile.scheme,
                host: profile.host,
                port: profile.port,
                rpcPath: profile.rpcPath,
                username: profile.username,
                password: "",
                pathMappings: pathMappings,
                askPasswordAtConnect: profile.askPasswordAtConnect,
                connectOnLaunch: profile.connectOnLaunch,
                autoReconnect: profile.autoReconnect,
                requestTimeoutSeconds: profile.requestTimeoutSeconds,
                transferPreferences: importedTransferPreferences(
                    from: normalizedTransferPreferences,
                    preservingDestinationHistoryFrom: nil
                ),
                proxySettings: proxySettings
            )
        } catch {
            throw SettingsPortabilityError.invalidProfile(profile.id, error.localizedDescription)
        }

        if profile.askPasswordAtConnect,
           profile.rpcCredentialRequirement != .none {
            throw SettingsPortabilityError.invalidProfile(
                profile.id,
                "Ask-every-time profiles cannot also require an omitted saved password."
            )
        }
        if !profile.proxy.authenticationEnabled,
           profile.proxy.credentialRequirement != .none {
            throw SettingsPortabilityError.invalidProfile(
                profile.id,
                "A direct or unauthenticated proxy cannot require credentials."
            )
        }

        let clientCertificate: PortableClientCertificateMetadata?
        if let certificate = profile.clientCertificate {
            guard normalized.scheme == "https" else {
                throw SettingsPortabilityError.clientCertificateRequiresHTTPS(profile.id)
            }
            clientCertificate = try validated(certificate, profileID: profile.id)
        } else {
            clientCertificate = nil
        }

        return PortableConnectionProfile(
            id: normalized.id,
            name: normalized.name,
            scheme: normalized.scheme,
            host: normalized.host,
            port: normalized.port,
            rpcPath: normalized.rpcPath,
            username: normalized.username,
            askPasswordAtConnect: normalized.askPasswordAtConnect,
            rpcCredentialRequirement: profile.rpcCredentialRequirement,
            pathMappings: normalized.pathMappings.map {
                PortablePathMapping(
                    remotePathPrefix: $0.remotePathPrefix,
                    localPathPrefix: $0.localPathPrefix
                )
            }.sorted {
                if $0.remotePathPrefix == $1.remotePathPrefix {
                    return $0.localPathPrefix < $1.localPathPrefix
                }
                return $0.remotePathPrefix < $1.remotePathPrefix
            },
            connectOnLaunch: normalized.connectOnLaunch,
            autoReconnect: normalized.autoReconnect,
            requestTimeoutSeconds: normalized.requestTimeoutSeconds,
            transferPreferences: normalizedTransferPreferences,
            proxy: PortableProxySettings(
                transport: proxySettings.transport,
                host: proxySettings.host,
                port: proxySettings.port,
                authenticationEnabled: proxySettings.authenticationEnabled,
                username: proxySettings.username,
                credentialRequirement: profile.proxy.credentialRequirement
            ),
            clientCertificate: clientCertificate
        )
    }

    private static func validated(
        _ preferences: PortableProfileTransferPreferences,
        profileID: UUID
    ) throws -> PortableProfileTransferPreferences {
        guard preferences.downloadSpeedPresetsKBps.count <= ProfileTransferPreferences.maximumSpeedPresetCount,
              preferences.uploadSpeedPresetsKBps.count <= ProfileTransferPreferences.maximumSpeedPresetCount,
              Set(preferences.downloadSpeedPresetsKBps).count == preferences.downloadSpeedPresetsKBps.count,
              Set(preferences.uploadSpeedPresetsKBps).count == preferences.uploadSpeedPresetsKBps.count,
              preferences.downloadSpeedPresetsKBps.allSatisfy({
                  ProfileTransferPreferences.allowedSpeedPresetKBps.contains($0)
              }),
              preferences.uploadSpeedPresetsKBps.allSatisfy({
                  ProfileTransferPreferences.allowedSpeedPresetKBps.contains($0)
              }),
              ProfileTransferPreferences.allowedDestinationHistoryLimit.contains(
                  preferences.destinationHistoryLimit
              ) else {
            throw SettingsPortabilityError.invalidProfile(
                profileID,
                "Transfer presets or destination history limits are invalid."
            )
        }
        return PortableProfileTransferPreferences(
            downloadSpeedPresetsKBps: preferences.downloadSpeedPresetsKBps.sorted(),
            uploadSpeedPresetsKBps: preferences.uploadSpeedPresetsKBps.sorted(),
            destinationHistoryLimit: preferences.destinationHistoryLimit
        )
    }

    private static func importedTransferPreferences(
        from portable: PortableProfileTransferPreferences,
        preservingDestinationHistoryFrom existing: ProfileTransferPreferences?
    ) -> ProfileTransferPreferences {
        ProfileTransferPreferences(
            downloadSpeedPresetsKBps: portable.downloadSpeedPresetsKBps,
            uploadSpeedPresetsKBps: portable.uploadSpeedPresetsKBps,
            destinationHistoryLimit: portable.destinationHistoryLimit,
            addDestinationHistory: existing?.addDestinationHistory ?? [],
            moveDestinationHistory: existing?.moveDestinationHistory ?? [],
            addDestinationRules: existing?.addDestinationRules ?? .empty
        )
    }

    private static func portableCertificate(
        from metadata: ClientIdentityMetadata,
        profileID: UUID
    ) throws -> PortableClientCertificateMetadata {
        let certificate = PortableClientCertificateMetadata(
            sha256Fingerprint: canonicalFingerprint(metadata.sha256Fingerprint),
            notBeforeUnixSeconds: Int64(metadata.notBefore.timeIntervalSince1970.rounded(.down)),
            notAfterUnixSeconds: Int64(metadata.notAfter.timeIntervalSince1970.rounded(.down))
        )
        return try validated(certificate, profileID: profileID)
    }

    private static func validated(
        _ certificate: PortableClientCertificateMetadata,
        profileID: UUID
    ) throws -> PortableClientCertificateMetadata {
        let fingerprint = canonicalFingerprint(certificate.sha256Fingerprint)
        guard fingerprint.count == 64,
              fingerprint.utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0)
              }),
              certificate.notBeforeUnixSeconds <= certificate.notAfterUnixSeconds else {
            throw SettingsPortabilityError.invalidClientCertificate(profileID)
        }
        return PortableClientCertificateMetadata(
            sha256Fingerprint: fingerprint,
            notBeforeUnixSeconds: certificate.notBeforeUnixSeconds,
            notAfterUnixSeconds: certificate.notAfterUnixSeconds
        )
    }

    private static func portablePreferences(
        from preferences: SettingsExportPreferences
    ) throws -> PortableApplicationPreferences {
        let preferences = try normalizedExportPreferences(preferences)
        var peerResolution = preferences.peerResolution
        // A custom URL can contain credentials in its path or query. Omit the
        // entire source from redacted exports without altering local settings.
        peerResolution.countryDatabaseSourceURL = ""
        return PortableApplicationPreferences(
            polling: PortablePollingPreferences(
                foregroundIntervalSeconds: preferences.polling.foregroundIntervalSeconds,
                backgroundIntervalSeconds: preferences.polling.backgroundIntervalSeconds,
                backgroundPolicy: preferences.polling.backgroundPolicy,
                adaptiveIdleEnabled: preferences.polling.adaptiveIdleEnabled
            ),
            behavior: preferences.behavior,
            interaction: preferences.interaction,
            intake: preferences.intake,
            peerResolution: peerResolution,
            watchFolder: preferences.watchFolderConfiguration.redactedPortableConfiguration(),
            workspace: preferences.workspace,
            torrentTable: PortableTorrentTablePreferences(
                visibleColumnIDs: preferences.visibleTorrentColumns.map(\.rawValue).sorted(),
                sortColumnID: preferences.torrentSort.columnID.rawValue,
                sortDirection: portableSortDirection(preferences.torrentSort.direction)
            ),
            tableColumnCustomizations: preferences.tableColumnCustomizations
        )
    }

    private static func validated(
        _ preferences: PortableApplicationPreferences,
        allowsLegacyTableDefaults: Bool = false
    ) throws -> PortableApplicationPreferences {
        let polling = PollingPreferences(
            foregroundIntervalSeconds: preferences.polling.foregroundIntervalSeconds,
            backgroundIntervalSeconds: preferences.polling.backgroundIntervalSeconds,
            backgroundPolicy: preferences.polling.backgroundPolicy,
            adaptiveIdleEnabled: preferences.polling.adaptiveIdleEnabled
        )
        guard polling.validationIssues.isEmpty else {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                polling.validationIssues.joined(separator: " ")
            )
        }

        let allTorrentColumns = Set(TorrentTableColumnID.allCases.map(\.rawValue))
        let visibleColumns = preferences.torrentTable.visibleColumnIDs
        guard Set(visibleColumns).count == visibleColumns.count else {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                "Torrent table columns must not be repeated."
            )
        }
        guard visibleColumns.allSatisfy({ allTorrentColumns.contains($0) }) else {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                "Torrent table contains an unknown column."
            )
        }
        guard visibleColumns.contains(TorrentTableColumnID.name.rawValue) else {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                "The torrent name column is required."
            )
        }
        guard TorrentTableColumnID(rawValue: preferences.torrentTable.sortColumnID) != nil else {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                "Torrent table sort column is unknown."
            )
        }

        let tableSnapshot: TableColumnCustomizationPortabilitySnapshot
        if let tableColumnCustomizations = preferences.tableColumnCustomizations {
            tableSnapshot = try TableColumnCustomizationPortabilityService.validated(
                tableColumnCustomizations
            )
            guard Set(visibleColumns) == Set(tableSnapshot.visibleTorrentColumns.map(\.rawValue)) else {
                throw SettingsPortabilityError.invalidApplicationPreferences(
                    "Torrent table visibility must match its complete table customization."
                )
            }
            let secondaryTables = preferences.workspace.secondaryTables
            guard
                secondaryTables.files.normalized(for: .files).hiddenColumnIDs
                    == tableSnapshot.hiddenFileColumnIDs,
                secondaryTables.peers.normalized(for: .peers).hiddenColumnIDs
                    == tableSnapshot.hiddenPeerColumnIDs,
                secondaryTables.trackers.normalized(for: .trackers).hiddenColumnIDs
                    == tableSnapshot.hiddenTrackerColumnIDs
            else {
                throw SettingsPortabilityError.invalidApplicationPreferences(
                    "Secondary table visibility must match each complete table customization."
                )
            }
        } else {
            guard allowsLegacyTableDefaults else {
                throw SettingsPortabilityError.invalidApplicationPreferences(
                    "Complete table customizations are missing."
                )
            }
            tableSnapshot = try TableColumnCustomizationPortabilityService.validated(
                TableColumnCustomizationPortabilityService.legacyPortableValue(
                    visibleTorrentColumns: Set(visibleColumns.compactMap(
                        TorrentTableColumnID.init(rawValue:)
                    )),
                    secondaryTables: preferences.workspace.secondaryTables
                )
            )
        }

        let shortcutPlan = CommandShortcutValidationService().makeImportPlan(
            from: preferences.interaction.shortcutOverrides
        )
        guard shortcutPlan.validatedBindings != nil else {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                shortcutPlan.issues.first?.message ?? "Shortcut preferences are invalid."
            )
        }

        do {
            _ = try PeerCountryDownloadSource.validatedCustomURL(
                preferences.peerResolution.countryDatabaseSourceURL
            )
        } catch {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                error.localizedDescription
            )
        }

        if let placement = preferences.workspace.mainWindow {
            guard
                placement.frame.hasFiniteGeometry,
                placement.frame.width > 0,
                placement.frame.height > 0
            else {
                throw SettingsPortabilityError.invalidApplicationPreferences(
                    "Main window placement must have positive finite dimensions."
                )
            }
        }

        let watchFolder = try validated(preferences.watchFolder)
        let workspace = workspaceApplyingTableSnapshot(
            preferences.workspace,
            applying: tableSnapshot
        )

        return PortableApplicationPreferences(
            polling: PortablePollingPreferences(
                foregroundIntervalSeconds: polling.foregroundIntervalSeconds,
                backgroundIntervalSeconds: polling.backgroundIntervalSeconds,
                backgroundPolicy: polling.backgroundPolicy,
                adaptiveIdleEnabled: polling.adaptiveIdleEnabled
            ),
            behavior: preferences.behavior,
            interaction: preferences.interaction,
            intake: preferences.intake,
            peerResolution: preferences.peerResolution,
            watchFolder: watchFolder,
            workspace: workspace,
            torrentTable: PortableTorrentTablePreferences(
                visibleColumnIDs: tableSnapshot.visibleTorrentColumns.map(\.rawValue).sorted(),
                sortColumnID: preferences.torrentTable.sortColumnID,
                sortDirection: preferences.torrentTable.sortDirection
            ),
            tableColumnCustomizations: tableSnapshot.portableValue
        )
    }

    private static func normalizedExportPreferences(
        _ preferences: SettingsExportPreferences
    ) throws -> SettingsExportPreferences {
        let tableSnapshot: TableColumnCustomizationPortabilitySnapshot
        if let tableColumnCustomizations = preferences.tableColumnCustomizations {
            tableSnapshot = try TableColumnCustomizationPortabilityService.validated(
                tableColumnCustomizations
            )
        } else {
            tableSnapshot = try TableColumnCustomizationPortabilityService.validated(
                TableColumnCustomizationPortabilityService.legacyPortableValue(
                    visibleTorrentColumns: preferences.visibleTorrentColumns,
                    secondaryTables: preferences.workspace.secondaryTables
                )
            )
        }

        var normalized = preferences
        normalized.workspace = workspaceApplyingTableSnapshot(
            preferences.workspace,
            applying: tableSnapshot
        )
        normalized.visibleTorrentColumns = tableSnapshot.visibleTorrentColumns
        normalized.tableColumnCustomizations = tableSnapshot.portableValue
        return normalized
    }

    private static func workspaceApplyingTableSnapshot(
        _ workspace: UIWorkspacePreferences,
        applying tableSnapshot: TableColumnCustomizationPortabilitySnapshot
    ) -> UIWorkspacePreferences {
        UIWorkspacePreferences(
            sidebarGrouping: workspace.sidebarGrouping,
            filterPane: workspace.filterPane,
            statusSummary: workspace.statusSummary,
            sidebarWidth: workspace.sidebarWidth,
            infoPane: workspace.infoPane,
            mainWindow: workspace.mainWindow,
            secondaryTables: SecondaryTableWorkspacePreferences(
                files: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: tableSnapshot.hiddenFileColumnIDs,
                    sortPreference: workspace.secondaryTables.files.sortPreference
                ),
                peers: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: tableSnapshot.hiddenPeerColumnIDs,
                    sortPreference: workspace.secondaryTables.peers.sortPreference
                ),
                trackers: SecondaryTableLayoutPreference(
                    hiddenColumnIDs: tableSnapshot.hiddenTrackerColumnIDs,
                    sortPreference: workspace.secondaryTables.trackers.sortPreference
                )
            )
        )
    }

    private static func validated(
        _ watchFolder: RedactedPortableWatchFolderConfiguration
    ) throws -> RedactedPortableWatchFolderConfiguration {
        guard (1 ... RedactedPortableWatchFolderConfiguration.currentSchemaVersion).contains(
                  watchFolder.schemaVersion
              ),
              !watchFolder.isEnabled,
              WatchFolderConfiguration.allowedScanIntervalSeconds.contains(
                  watchFolder.scanIntervalSeconds
              ),
              watchFolder.successPolicy == .moveSource
                  || !watchFolder.requiresProcessedFolderSelection else {
            throw SettingsPortabilityError.invalidApplicationPreferences(
                "Watch-folder settings must be redacted, disabled, and valid."
            )
        }
        if !watchFolder.remoteDestination.isEmpty {
            do {
                _ = try RemotePOSIXDestinationValidator.validated(watchFolder.remoteDestination)
            } catch {
                throw SettingsPortabilityError.invalidApplicationPreferences(
                    error.localizedDescription
                )
            }
        }
        return RedactedPortableWatchFolderConfiguration(
            isEnabled: false,
            remoteDestination: watchFolder.remoteDestination,
            scanIntervalSeconds: watchFolder.scanIntervalSeconds,
            successPolicy: watchFolder.successPolicy,
            submissionPolicy: watchFolder.submissionPolicy,
            requiresSourceFolderSelection: watchFolder.requiresSourceFolderSelection,
            requiresProcessedFolderSelection: watchFolder.requiresProcessedFolderSelection
        )
    }

    private static func hasSamePortableConfiguration(
        _ lhs: PortableConnectionProfile,
        _ rhs: PortableConnectionProfile
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.rpcCredentialRequirement = .none
        rhs.rpcCredentialRequirement = .none
        lhs.proxy.credentialRequirement = .none
        rhs.proxy.credentialRequirement = .none
        lhs.clientCertificate = nil
        rhs.clientCertificate = nil
        return lhs == rhs
    }

    private static func resolveFinalNameCollisions(
        existingProfiles: [PortableConnectionProfile],
        candidateUpdates: [UUID: PortableConnectionProfile],
        candidateAdditions: [UUID: PortableConnectionProfile]
    ) -> FinalNameResolution {
        var acceptedUpdateIDs = Set(candidateUpdates.keys)
        var acceptedAdditionIDs = Set(candidateAdditions.keys)
        var rejectedByID: [UUID: UUID] = [:]

        while true {
            var ownersByName: [String: [FinalNameOwner]] = [:]
            for existing in existingProfiles {
                if acceptedUpdateIDs.contains(existing.id),
                   let update = candidateUpdates[existing.id] {
                    ownersByName[update.name.lowercased(), default: []].append(
                        FinalNameOwner(id: existing.id, isCandidate: true)
                    )
                } else {
                    ownersByName[existing.name.lowercased(), default: []].append(
                        FinalNameOwner(id: existing.id, isCandidate: false)
                    )
                }
            }
            for additionID in acceptedAdditionIDs {
                guard let addition = candidateAdditions[additionID] else { continue }
                ownersByName[addition.name.lowercased(), default: []].append(
                    FinalNameOwner(id: additionID, isCandidate: true)
                )
            }

            var newlyRejected: [UUID: UUID] = [:]
            for owners in ownersByName.values where owners.count > 1 {
                let ordered = owners.sorted { stableUUID($0.id) < stableUUID($1.id) }
                let winner = ordered.first(where: { !$0.isCandidate }) ?? ordered[0]
                for owner in ordered where owner.isCandidate && owner.id != winner.id {
                    newlyRejected[owner.id] = winner.id
                }
            }
            guard !newlyRejected.isEmpty else { break }

            for (profileID, conflictingID) in newlyRejected {
                acceptedUpdateIDs.remove(profileID)
                acceptedAdditionIDs.remove(profileID)
                rejectedByID[profileID] = conflictingID
            }
        }

        return FinalNameResolution(
            acceptedUpdateIDs: acceptedUpdateIDs,
            acceptedAdditionIDs: acceptedAdditionIDs,
            rejectedByID: rejectedByID
        )
    }

    private static func canonicalFingerprint(_ fingerprint: String) -> String {
        fingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
    }

    private static func stableUUID(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func portableSortDirection(
        _ direction: TorrentTableSortDirection
    ) -> PortableSortDirection {
        direction == .ascending ? .ascending : .descending
    }

    private static func torrentSortDirection(
        _ direction: PortableSortDirection
    ) -> TorrentTableSortDirection {
        direction == .ascending ? .ascending : .descending
    }

    private static func firstForbiddenField(in value: Any, path: String = "$") -> String? {
        if let dictionary = value as? [String: Any] {
            for key in dictionary.keys.sorted() {
                let normalizedKey = key.lowercased().filter(\.isLetter)
                if isForbiddenKey(normalizedKey) {
                    return "\(path).\(key)"
                }
                if let child = dictionary[key],
                   let nested = firstForbiddenField(in: child, path: "\(path).\(key)") {
                    return nested
                }
            }
        } else if let array = value as? [Any] {
            for (index, item) in array.enumerated() {
                if let nested = firstForbiddenField(in: item, path: "\(path)[\(index)]") {
                    return nested
                }
            }
        }
        return nil
    }

    private static func isForbiddenKey(_ normalizedKey: String) -> Bool {
        if normalizedKey == "askpasswordatconnect" {
            return false
        }
        if forbiddenKeyTerms.contains(where: normalizedKey.contains) {
            return true
        }

        let isSensitiveReference = normalizedKey.contains("reference")
            && sensitiveReferenceSubjects.contains(where: normalizedKey.contains)
        let isSensitivePayload = sensitivePayloadContainers.contains(where: normalizedKey.contains)
            && sensitivePayloadSubjects.contains(where: normalizedKey.contains)
        return isSensitiveReference || isSensitivePayload
    }

    private static let forbiddenKeyTerms = [
        "password",
        "passphrase",
        "persistentreference",
        "persistentref",
        "keychainreference",
        "keychain",
        "privatekey",
        "secret",
        "sharedsecret",
        "clientsecret",
        "secretkey",
        "token",
        "apitoken",
        "accesstoken",
        "refreshtoken",
        "authtoken",
        "bearertoken",
        "sessiontoken",
        "apikey",
        "accesskey",
        "authkey",
        "signingkey",
        "encryptionkey",
        "pkcs",
        "authorization",
        "cookie",
        "bookmark",
        "failure",
        "failurequeue",
        "watchfolderfailure",
        "processingstate",
        "pendingsourcecleanup",
        "acknowledgedfile",
    ]

    private static let sensitiveReferenceSubjects = [
        "certificate",
        "credential",
        "identity",
        "key",
        "pkcs",
    ]

    private static let sensitivePayloadContainers = [
        "blob",
        "bytes",
        "data",
        "der",
        "pem",
        "payload",
        "raw",
    ]

    private static let sensitivePayloadSubjects = [
        "certificate",
        "credential",
        "auth",
        "identity",
        "key",
        "pkcs",
        "secret",
        "token",
    ]

    private struct FinalNameOwner {
        var id: UUID
        var isCandidate: Bool
    }

    private struct FinalNameResolution {
        var acceptedUpdateIDs: Set<UUID>
        var acceptedAdditionIDs: Set<UUID>
        var rejectedByID: [UUID: UUID]
    }

    private struct VersionProbe: Decodable {
        var schemaIdentifier: String
        var schemaVersion: Int
    }
}
