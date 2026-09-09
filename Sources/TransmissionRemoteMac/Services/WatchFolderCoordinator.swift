// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

struct WatchFolderRunOwner: Equatable, Sendable {
    var profileID: UUID
    var connectionToken: UUID
    var runToken: UUID

    init(
        profileID: UUID,
        connectionToken: UUID,
        runToken: UUID = UUID()
    ) {
        self.profileID = profileID
        self.connectionToken = connectionToken
        self.runToken = runToken
    }
}

struct WatchFolderCandidate: Equatable, Sendable {
    var job: WatchFolderScanJob
    var fileURL: URL
    var remoteDestination: String
}

protocol WatchFolderCoordinating: Sendable {
    func start(
        commandRevision: Int,
        owner: WatchFolderRunOwner,
        configuration: WatchFolderConfiguration,
        processingState: WatchFolderProcessingState,
        candidateHandler: @escaping WatchFolderDeadlineCoordinator.CandidateHandler,
        stateHandler: @escaping WatchFolderDeadlineCoordinator.StateHandler,
        errorHandler: @escaping WatchFolderDeadlineCoordinator.ErrorHandler
    ) async

    func stop(commandRevision: Int, reason: String) async
    func replaceProcessingState(
        _ processingState: WatchFolderProcessingState,
        commandRevision: Int
    ) async
    func resolve(
        job: WatchFolderScanJob,
        acknowledgment: WatchFolderAddAcknowledgment,
        owner: WatchFolderRunOwner
    ) async
}

enum WatchFolderBookmarkError: LocalizedError {
    case inaccessibleFolder
    case staleBookmarkCouldNotBeRenewed
    case missingProcessedFolder

    var errorDescription: String? {
        switch self {
        case .inaccessibleFolder:
            "The selected watch folder could not be accessed. Select it again."
        case .staleBookmarkCouldNotBeRenewed:
            "The watch-folder permission expired and could not be renewed. Select the folder again."
        case .missingProcessedFolder:
            "Select a processed-files folder before using the move policy."
        }
    }
}

enum WatchFolderBookmarkService {
    static func makeSecurityScopedBookmark(for folderURL: URL) throws -> Data {
        let didStartAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }
        return try folderURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        )
    }

    static func displayName(for bookmarkData: Data?) -> String? {
        guard let bookmarkData else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return url.lastPathComponent
    }
}

private struct OpenWatchFolderScope {
    var sourceURL: URL
    var processedURL: URL?
    var refreshedConfiguration: WatchFolderConfiguration
}

struct WatchFolderSourceCleanup {
    private let fileManager: FileManager
    private let fileCleanup: any RaceResistantFileCleaning

    init(
        fileManager: FileManager = .default,
        fileCleanup: any RaceResistantFileCleaning = DarwinRaceResistantFileCleanup()
    ) {
        self.fileManager = fileManager
        self.fileCleanup = fileCleanup
    }

    func apply(
        disposition: WatchFolderSourceDisposition,
        to sourceFileURL: URL,
        processedFolderURL: URL?,
        expectedIdentity: String
    ) -> Result<Void, Error> {
        guard fileManager.fileExists(atPath: sourceFileURL.path) else {
            return .success(())
        }

        do {
            if disposition == .none {
                return .success(())
            }
            guard let identity = RaceResistantFileIdentity(rawValue: expectedIdentity) else {
                throw WatchFolderCoordinatorError.stableIdentityUnavailable
            }
            switch disposition {
            case .none:
                return .success(())
            case .delete:
                try fileCleanup.removeRegularFile(
                    at: sourceFileURL,
                    matching: identity
                )
                return .success(())
            case .move:
                guard let processedFolderURL else {
                    throw WatchFolderBookmarkError.missingProcessedFolder
                }
                let destinationURL = processedFolderURL.appendingPathComponent(
                    sourceFileURL.lastPathComponent,
                    isDirectory: false
                )
                guard destinationURL.standardizedFileURL != sourceFileURL.standardizedFileURL else {
                    throw WatchFolderCoordinatorError.processedFolderMatchesSource
                }
                guard !fileManager.fileExists(atPath: destinationURL.path) else {
                    throw WatchFolderCoordinatorError.processedFileAlreadyExists
                }
                try fileCleanup.moveRegularFile(
                    at: sourceFileURL,
                    to: destinationURL,
                    matching: identity
                )
                return .success(())
            }
        } catch {
            return .failure(error)
        }
    }
}

enum WatchFolderDirectoryScanner {
    static func scan(at sourceURL: URL, fileManager: FileManager = .default, fileCleanup: any RaceResistantFileCleaning = DarwinRaceResistantFileCleanup()) throws -> [(entry: WatchFolderDirectoryEntry, url: URL)] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
        return try fileManager.contentsOfDirectory(
            at: sourceURL,
            includingPropertiesForKeys: Array(keys),
            options: []
        ).compactMap { url in
            let name = url.lastPathComponent
            guard WatchFolderDirectoryEntry.isEligibleTorrentFileName(name),
                  let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let kind: WatchFolderDirectoryEntryKind
            if values.isSymbolicLink == true {
                kind = .symbolicLink
            } else if values.isRegularFile == true {
                kind = .regularFile
            } else if values.isDirectory == true {
                kind = .directory
            } else {
                kind = .other
            }
            guard WatchFolderDirectoryEntry.isEligibleTorrentFile(
                fileName: name, kind: kind, isHidden: values.isHidden == true
            ), let identity = try? fileCleanup.stableIdentityOfRegularFile(at: url) else { return nil }
            return (WatchFolderDirectoryEntry(
                stableFileIdentity: identity.rawValue,
                fileName: name,
                kind: kind,
                isHidden: values.isHidden == true
            ), url)
        }
    }
}

private final class WatchFolderSecurityScopeOwner: @unchecked Sendable {
    private let fileManager: FileManager
    private let fileCleanup: any RaceResistantFileCleaning
    private let sourceCleanup: WatchFolderSourceCleanup
    private var sourceURL: URL?
    private var processedURL: URL?
    private var sourceAccessStarted = false
    private var processedAccessStarted = false

    init(
        fileManager: FileManager = .default,
        fileCleanup: any RaceResistantFileCleaning = DarwinRaceResistantFileCleanup()
    ) {
        self.fileManager = fileManager
        self.fileCleanup = fileCleanup
        sourceCleanup = WatchFolderSourceCleanup(
            fileManager: fileManager,
            fileCleanup: fileCleanup
        )
    }

    deinit {
        close()
    }

    func open(configuration: WatchFolderConfiguration) throws -> OpenWatchFolderScope {
        close()
        guard let sourceBookmarkData = configuration.sourceBookmarkData else {
            throw WatchFolderBookmarkError.inaccessibleFolder
        }

        let source = try resolve(bookmarkData: sourceBookmarkData)
        guard source.url.startAccessingSecurityScopedResource() else {
            throw WatchFolderBookmarkError.inaccessibleFolder
        }
        sourceURL = source.url
        sourceAccessStarted = true

        var processed: (url: URL, bookmarkData: Data)?
        if configuration.successPolicy == .moveSource {
            guard let processedBookmarkData = configuration.processedFolderBookmarkData else {
                close()
                throw WatchFolderBookmarkError.missingProcessedFolder
            }
            do {
                let resolvedProcessed = try resolve(bookmarkData: processedBookmarkData)
                guard resolvedProcessed.url.startAccessingSecurityScopedResource() else {
                    throw WatchFolderBookmarkError.inaccessibleFolder
                }
                processed = resolvedProcessed
                processedURL = resolvedProcessed.url
                processedAccessStarted = true
            } catch {
                close()
                throw error
            }
        }

        return OpenWatchFolderScope(
            sourceURL: source.url,
            processedURL: processed?.url,
            refreshedConfiguration: WatchFolderConfiguration(
                isEnabled: configuration.isEnabled,
                sourceBookmarkData: source.bookmarkData,
                remoteDestination: configuration.remoteDestination,
                scanIntervalSeconds: configuration.scanIntervalSeconds,
                successPolicy: configuration.successPolicy,
                submissionPolicy: configuration.submissionPolicy,
                processedFolderBookmarkData: processed?.bookmarkData
                    ?? configuration.processedFolderBookmarkData,
                configurationRevision: configuration.configurationRevision
            )
        )
    }

    func close() {
        if processedAccessStarted, let processedURL {
            processedURL.stopAccessingSecurityScopedResource()
        }
        if sourceAccessStarted, let sourceURL {
            sourceURL.stopAccessingSecurityScopedResource()
        }
        processedAccessStarted = false
        sourceAccessStarted = false
        processedURL = nil
        sourceURL = nil
    }

    func scan() throws -> [(entry: WatchFolderDirectoryEntry, url: URL)] {
        guard let sourceURL else {
            throw WatchFolderBookmarkError.inaccessibleFolder
        }
        return try WatchFolderDirectoryScanner.scan(at: sourceURL, fileManager: fileManager, fileCleanup: fileCleanup)
    }

    func sourceFileURL(named fileName: String) throws -> URL {
        guard let sourceURL else {
            throw WatchFolderBookmarkError.inaccessibleFolder
        }
        return sourceURL.appendingPathComponent(fileName, isDirectory: false)
    }

    func apply(
        disposition: WatchFolderSourceDisposition,
        to sourceFileURL: URL,
        expectedIdentity: String
    ) -> Result<Void, Error> {
        sourceCleanup.apply(
            disposition: disposition,
            to: sourceFileURL,
            processedFolderURL: processedURL,
            expectedIdentity: expectedIdentity
        )
    }

    private func resolve(bookmarkData: Data) throws -> (url: URL, bookmarkData: Data) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard isStale else { return (url, bookmarkData) }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let refreshedBookmark = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.nameKey, .isDirectoryKey],
            relativeTo: nil
        ) else {
            throw WatchFolderBookmarkError.staleBookmarkCouldNotBeRenewed
        }
        return (url, refreshedBookmark)
    }
}

enum WatchFolderCoordinatorError: LocalizedError {
    case stableIdentityUnavailable
    case sourceFileWasReplaced
    case sourceCleanupWasNotApplied
    case sourceCleanupFailed(String)
    case processedFolderMatchesSource
    case processedFileAlreadyExists
    case candidateCouldNotBeQueued

    var errorDescription: String? {
        switch self {
        case .stableIdentityUnavailable:
            "A stable identity could not be read for this .torrent file."
        case .sourceFileWasReplaced:
            "The source file was replaced after it entered the add queue, so it was left untouched."
        case .sourceCleanupWasNotApplied:
            "The successful-add source policy could not be applied."
        case .sourceCleanupFailed(let message):
            "The successful-add source policy failed: \(message)"
        case .processedFolderMatchesSource:
            "The processed-files folder cannot be the watch folder."
        case .processedFileAlreadyExists:
            "A file with the same name already exists in the processed-files folder."
        case .candidateCouldNotBeQueued:
            "The .torrent file could not enter the visible Add Torrent queue."
        }
    }
}

actor WatchFolderDeadlineCoordinator: WatchFolderCoordinating {
    typealias CandidateHandler = @Sendable (
        _ candidate: WatchFolderCandidate,
        _ owner: WatchFolderRunOwner
    ) async -> Bool
    typealias StateHandler = @Sendable (
        _ configuration: WatchFolderConfiguration,
        _ processingState: WatchFolderProcessingState
    ) async -> Void
    typealias ErrorHandler = @Sendable (_ message: String) async -> Void

    private struct Session {
        var owner: WatchFolderRunOwner
        var generation: UUID
        var commandRevision: Int
        var configuration: WatchFolderConfiguration
        var candidateHandler: CandidateHandler
        var stateHandler: StateHandler
        var errorHandler: ErrorHandler
    }

    private let clock: any PollingClock
    private let scopeOwner: WatchFolderSecurityScopeOwner
    private var latestCommandRevision = 0
    private var planner: WatchFolderScanPlanner?
    private var session: Session?
    private var scheduleTask: Task<Void, Never>?
    private var scheduleTaskID: UUID?

    init(
        clock: any PollingClock = ContinuousPollingClock(),
        fileManager: FileManager = .default,
        fileCleanup: any RaceResistantFileCleaning = DarwinRaceResistantFileCleanup()
    ) {
        self.clock = clock
        scopeOwner = WatchFolderSecurityScopeOwner(
            fileManager: fileManager,
            fileCleanup: fileCleanup
        )
    }

    func start(
        commandRevision: Int,
        owner: WatchFolderRunOwner,
        configuration: WatchFolderConfiguration,
        processingState: WatchFolderProcessingState,
        candidateHandler: @escaping CandidateHandler,
        stateHandler: @escaping StateHandler,
        errorHandler: @escaping ErrorHandler
    ) async {
        guard commandRevision > latestCommandRevision else { return }
        latestCommandRevision = commandRevision
        scheduleTask?.cancel()
        scheduleTask = nil
        scheduleTaskID = nil
        var effectiveProcessingState = processingState
        if var planner {
            if effectiveProcessingState.supersedesOrDiverges(from: planner.state) {
                planner.replaceState(effectiveProcessingState)
            }
            let hadActiveJobs = !planner.activeJobs.isEmpty
            if hadActiveJobs {
                planner.failActiveJobs(
                    message: "Watch-folder automation restarted before the queued add was confirmed.",
                    now: Date().timeIntervalSince1970
                )
            }
            effectiveProcessingState = planner.state
            self.planner = planner
            if hadActiveJobs {
                guard ownsCommand(commandRevision) else { return }
                await stateHandler(configuration, effectiveProcessingState)
                guard ownsCommand(commandRevision) else { return }
                if let currentPlanner = self.planner,
                   currentPlanner.state.supersedesOrDiverges(from: effectiveProcessingState) {
                    effectiveProcessingState = currentPlanner.state
                }
                scheduleTask?.cancel()
                scheduleTask = nil
                scheduleTaskID = nil
            }
        }
        scopeOwner.close()
        session = nil

        guard configuration.isReadyToScan else {
            planner = WatchFolderScanPlanner(
                configuration: configuration,
                state: effectiveProcessingState
            )
            return
        }

        do {
            let openedScope = try scopeOwner.open(configuration: configuration)
            let activeConfiguration = openedScope.refreshedConfiguration
            let nextSession = Session(
                owner: owner,
                generation: UUID(),
                commandRevision: commandRevision,
                configuration: activeConfiguration,
                candidateHandler: candidateHandler,
                stateHandler: stateHandler,
                errorHandler: errorHandler
            )
            planner = WatchFolderScanPlanner(
                configuration: activeConfiguration,
                state: effectiveProcessingState
            )
            session = nextSession
            if activeConfiguration != configuration {
                guard await publishState(
                    effectiveProcessingState,
                    for: nextSession
                ) else {
                    return
                }
            }
            schedule(session: nextSession, scanImmediately: true)
        } catch {
            planner = WatchFolderScanPlanner(
                configuration: configuration,
                state: effectiveProcessingState
            )
            guard ownsCommand(commandRevision) else { return }
            await errorHandler(error.localizedDescription)
            guard ownsCommand(commandRevision) else { return }
        }
    }

    func stop(commandRevision: Int, reason: String) async {
        guard commandRevision > latestCommandRevision else { return }
        latestCommandRevision = commandRevision
        scheduleTask?.cancel()
        scheduleTask = nil
        scheduleTaskID = nil
        let stoppedSession = session
        session = nil
        scopeOwner.close()
        if var planner, !planner.activeJobs.isEmpty {
            planner.failActiveJobs(
                message: reason,
                now: Date().timeIntervalSince1970
            )
            self.planner = planner
            if let stoppedSession {
                guard ownsCommand(commandRevision) else { return }
                await stoppedSession.stateHandler(
                    stoppedSession.configuration,
                    planner.state
                )
                guard ownsCommand(commandRevision) else { return }
            }
        }
    }

    func replaceProcessingState(
        _ processingState: WatchFolderProcessingState,
        commandRevision: Int
    ) async {
        guard commandRevision == latestCommandRevision,
              var planner,
              processingState.supersedesOrDiverges(from: planner.state) else {
            return
        }
        planner.replaceState(processingState)
        self.planner = planner
        guard planner.activeJobs.isEmpty, let session else { return }
        scheduleTask?.cancel()
        schedule(session: session, scanImmediately: true)
    }

    func resolve(
        job: WatchFolderScanJob,
        acknowledgment: WatchFolderAddAcknowledgment,
        owner: WatchFolderRunOwner
    ) async {
        guard let expectedSession = session,
              expectedSession.owner == owner,
              owns(expectedSession),
              var planner else {
            return
        }
        let now = Date().timeIntervalSince1970
        do {
            let cleanupErrorMessage: String?
            switch acknowledgment {
            case .added:
                cleanupErrorMessage = try resolveSuccessfulAdd(
                    job: job,
                    planner: &planner,
                    now: now
                )
            case .duplicate, .failed(_):
                _ = try planner.acknowledge(acknowledgment, for: job, now: now)
                cleanupErrorMessage = nil
            }
            guard owns(expectedSession) else { return }
            self.planner = planner
            let publishedState = planner.state
            guard await publishState(
                publishedState,
                for: expectedSession
            ) else {
                return
            }
            if let cleanupErrorMessage {
                guard owns(expectedSession, processingState: publishedState) else {
                    return
                }
                await expectedSession.errorHandler(cleanupErrorMessage)
                guard owns(expectedSession, processingState: publishedState) else {
                    return
                }
            }
        } catch {
            guard owns(expectedSession) else { return }
            await expectedSession.errorHandler(error.localizedDescription)
            guard owns(expectedSession) else { return }
        }
    }

    private func schedule(session: Session, scanImmediately: Bool) {
        let taskID = UUID()
        scheduleTaskID = taskID
        scheduleTask = Task { [weak self] in
            await self?.run(
                session: session,
                scanImmediately: scanImmediately,
                taskID: taskID
            )
        }
    }

    private func run(
        session expectedSession: Session,
        scanImmediately: Bool,
        taskID: UUID
    ) async {
        var nextDeadline = clock.now()
        if !scanImmediately {
            nextDeadline += .seconds(expectedSession.configuration.scanIntervalSeconds)
        }

        while owns(expectedSession) {
            if clock.now() < nextDeadline {
                do {
                    try await clock.sleep(until: nextDeadline)
                } catch {
                    break
                }
            }
            guard !Task.isCancelled, owns(expectedSession) else { break }
            await scanOnce(session: expectedSession)
            guard !Task.isCancelled, owns(expectedSession) else { break }
            let interval = Duration.seconds(
                expectedSession.configuration.scanIntervalSeconds
            )
            repeat {
                nextDeadline += interval
            } while nextDeadline <= clock.now()
        }

        if owns(expectedSession), scheduleTaskID == taskID {
            scheduleTask = nil
            scheduleTaskID = nil
        }
    }

    private func scanOnce(session expectedSession: Session) async {
        guard owns(expectedSession), var planner else { return }
        do {
            let scannedEntries = try scopeOwner.scan()
            let urlsByIdentity = Dictionary(
                scannedEntries.map { ($0.entry.stableFileIdentity, $0.url) },
                uniquingKeysWith: { first, _ in first }
            )
            let previousStateRevision = planner.state.revision
            let jobs = planner.planBatch(
                entries: scannedEntries.map(\.entry),
                now: Date().timeIntervalSince1970
            )
            guard owns(expectedSession) else { return }
            self.planner = planner
            if planner.state.revision != previousStateRevision {
                guard await publishState(planner.state, for: expectedSession) else {
                    return
                }
            }

            for job in jobs where owns(expectedSession) {
                let fileURL: URL
                if let scannedURL = urlsByIdentity[job.stableFileIdentity] {
                    fileURL = scannedURL
                } else {
                    fileURL = try scopeOwner.sourceFileURL(named: job.fileName)
                }
                if job.kind == .sourceCleanup {
                    await resolve(
                        job: job,
                        acknowledgment: .added,
                        owner: expectedSession.owner
                    )
                    guard !Task.isCancelled, owns(expectedSession) else { return }
                    continue
                }
                let accepted = await expectedSession.candidateHandler(
                    WatchFolderCandidate(
                        job: job,
                        fileURL: fileURL,
                        remoteDestination: expectedSession.configuration.remoteDestination
                    ),
                    expectedSession.owner
                )
                guard !Task.isCancelled, owns(expectedSession) else { return }
                guard !accepted else { continue }
                await resolve(
                    job: job,
                    acknowledgment: .failed(
                        message: WatchFolderCoordinatorError.candidateCouldNotBeQueued.localizedDescription
                    ),
                    owner: expectedSession.owner
                )
                guard !Task.isCancelled, owns(expectedSession) else { return }
            }
        } catch {
            guard owns(expectedSession) else { return }
            await expectedSession.errorHandler(error.localizedDescription)
            guard owns(expectedSession) else { return }
        }
    }

    private func resolveSuccessfulAdd(
        job: WatchFolderScanJob,
        planner: inout WatchFolderScanPlanner,
        now: TimeInterval
    ) throws -> String? {
        let disposition = try planner.sourceDisposition(for: job)
        let sourceFileURL = try scopeOwner.sourceFileURL(named: job.fileName)
        switch scopeOwner.apply(
            disposition: disposition,
            to: sourceFileURL,
            expectedIdentity: job.stableFileIdentity
        ) {
        case .success:
            _ = try planner.acknowledge(.added, for: job, now: now)
            return nil
        case .failure(let error):
            try planner.deferSourceCleanup(
                for: job,
                message: error.localizedDescription,
                now: now
            )
            return "Transmission added \(job.fileName), but watch-folder cleanup failed: \(error.localizedDescription)"
        }
    }

    private func owns(_ expectedSession: Session) -> Bool {
        ownsCommand(expectedSession.commandRevision)
            && session?.owner == expectedSession.owner
            && session?.generation == expectedSession.generation
    }

    private func owns(
        _ expectedSession: Session,
        processingState: WatchFolderProcessingState
    ) -> Bool {
        owns(expectedSession) && planner?.state == processingState
    }

    private func ownsCommand(_ commandRevision: Int) -> Bool {
        latestCommandRevision == commandRevision
    }

    private func publishState(
        _ processingState: WatchFolderProcessingState,
        for expectedSession: Session
    ) async -> Bool {
        guard owns(expectedSession, processingState: processingState) else {
            return false
        }
        await expectedSession.stateHandler(
            expectedSession.configuration,
            processingState
        )
        return owns(expectedSession, processingState: processingState)
    }
}
