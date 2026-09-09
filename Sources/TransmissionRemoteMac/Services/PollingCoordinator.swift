// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Darwin
import Foundation

struct PollingWork: OptionSet, Equatable, Sendable {
    let rawValue: Int

    static let torrents = PollingWork(rawValue: 1 << 0)
    static let session = PollingWork(rawValue: 1 << 1)
}

protocol PollingClock: Sendable {
    func now() -> Duration
    func sleep(until deadline: Duration) async throws
}

protocol PollingWakeObserving: Sendable {
    func recordWake(connectionToken: UUID, work: PollingWork) async
}

struct ContinuousPollingClock: PollingClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    func now() -> Duration {
        origin.duration(to: clock.now)
    }

    func sleep(until deadline: Duration) async throws {
        try await clock.sleep(until: origin.advanced(by: deadline))
    }
}

actor PollingCoordinator {
    typealias Handler = @Sendable (_ connectionToken: UUID, _ work: PollingWork) async -> Void

    private struct Owner: Equatable {
        var connectionToken: UUID
        var generation: UUID
    }

    private let clock: any PollingClock
    private let wakeObserver: (any PollingWakeObserving)?
    private var latestCommandRevision = 0
    private var owner: Owner?
    private var scheduleTask: Task<Void, Never>?

    init(
        clock: any PollingClock = ContinuousPollingClock(),
        wakeObserver: (any PollingWakeObserving)? = PollingWakeObserverFactory.performanceHarnessIfRequested()
    ) {
        self.clock = clock
        self.wakeObserver = wakeObserver
    }

    func start(
        commandRevision: Int,
        connectionToken: UUID,
        listInterval: Duration,
        sessionInterval: Duration,
        handler: @escaping Handler
    ) {
        guard commandRevision > latestCommandRevision else { return }
        latestCommandRevision = commandRevision
        scheduleTask?.cancel()
        guard listInterval > .zero, sessionInterval > .zero else {
            owner = nil
            scheduleTask = nil
            return
        }

        let nextOwner = Owner(connectionToken: connectionToken, generation: UUID())
        owner = nextOwner
        scheduleTask = Task { [weak self] in
            await self?.run(
                owner: nextOwner,
                listInterval: listInterval,
                sessionInterval: sessionInterval,
                handler: handler
            )
        }
    }

    func stop(commandRevision: Int) {
        guard commandRevision > latestCommandRevision else { return }
        latestCommandRevision = commandRevision
        owner = nil
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    private func run(
        owner expectedOwner: Owner,
        listInterval: Duration,
        sessionInterval: Duration,
        handler: @escaping Handler
    ) async {
        let startedAt = clock.now()
        var nextListDeadline = startedAt + listInterval
        var nextSessionDeadline = startedAt + sessionInterval

        while ownsSchedule(expectedOwner) {
            let wakeDeadline = min(nextListDeadline, nextSessionDeadline)
            do {
                try await clock.sleep(until: wakeDeadline)
            } catch {
                break
            }

            guard !Task.isCancelled, ownsSchedule(expectedOwner) else { break }
            let now = clock.now()
            var work: PollingWork = []
            if now >= nextListDeadline {
                work.insert(.torrents)
            }
            if now >= nextSessionDeadline {
                work.insert(.session)
            }
            guard !work.isEmpty else { continue }

            await wakeObserver?.recordWake(
                connectionToken: expectedOwner.connectionToken,
                work: work
            )
            await handler(expectedOwner.connectionToken, work)
            guard !Task.isCancelled, ownsSchedule(expectedOwner) else { break }

            let completedAt = clock.now()
            if work.contains(.torrents) {
                nextListDeadline = nextDeadline(after: completedAt, from: nextListDeadline, interval: listInterval)
            }
            if work.contains(.session) {
                nextSessionDeadline = nextDeadline(after: completedAt, from: nextSessionDeadline, interval: sessionInterval)
            }
        }

        if owner == expectedOwner {
            owner = nil
            scheduleTask = nil
        }
    }

    private func ownsSchedule(_ expectedOwner: Owner) -> Bool {
        owner == expectedOwner
    }

    private func nextDeadline(after now: Duration, from deadline: Duration, interval: Duration) -> Duration {
        var next = deadline
        repeat {
            next += interval
        } while next <= now
        return next
    }
}

enum PollingWakeObserverFactory {
    static func performanceHarnessIfRequested() -> (any PollingWakeObserving)? {
#if DEBUG
        PerformanceHarnessPollingWakeRecorder.requestedFromEnvironment()
#else
        nil
#endif
    }
}

#if DEBUG
struct PerformanceHarnessContext: Equatable, Sendable {
    static let detailSelectionEnvironmentKey =
        "TRANSMISSION_REMOTE_MAC_PERFORMANCE_DETAIL_SELECTION"
    static let wakeRecordingEnvironmentKey =
        "TRANSMISSION_REMOTE_MAC_PERFORMANCE_WAKE_RECORDING"
    static let detailSelectionProofName =
        ".transmission-remote-mac-performance-detail-selection"
    static let wakeTraceName =
        ".transmission-remote-mac-performance-polling-wakes"

    let homeURL: URL
    let temporaryDirectoryURL: URL
    let token: String

    var detailSelectionProofURL: URL {
        temporaryDirectoryURL.appendingPathComponent(Self.detailSelectionProofName)
    }

    var wakeTraceURL: URL {
        temporaryDirectoryURL.appendingPathComponent(Self.wakeTraceName)
    }

    static func validatedIfRequested(
        featureEnvironmentKey: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedHomePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> PerformanceHarnessContext? {
        guard environment[featureEnvironmentKey] != nil else { return nil }
        guard
            environment[featureEnvironmentKey] == "1",
            environment[PerformancePasswordStoreIsolation.modeEnvironmentKey] == "1",
            let declaredHomePath = environment[PerformancePasswordStoreIsolation.homeEnvironmentKey],
            let temporaryPath = environment["TMPDIR"],
            let token = environment[PerformancePasswordStoreIsolation.tokenEnvironmentKey],
            token.count >= 32,
            let defaultsSuite = environment[PerformancePreferencesIsolation.suiteEnvironmentKey],
            defaultsSuite == "\(PerformancePreferencesIsolation.suitePrefix).\(token)"
        else {
            return nil
        }

        let homeURL = canonicalURL(for: declaredHomePath)
        let resolvedHomeURL = canonicalURL(for: resolvedHomePath)
        let temporaryDirectoryURL = canonicalURL(for: temporaryPath)
        let expectedTemporaryDirectoryURL = homeURL.appendingPathComponent("tmp", isDirectory: true)
        guard
            homeURL.path != "/",
            homeURL == resolvedHomeURL,
            temporaryDirectoryURL == expectedTemporaryDirectoryURL,
            fileManager.fileExists(atPath: temporaryDirectoryURL.path)
        else {
            return nil
        }

        let activationProofURL = homeURL.appendingPathComponent(
            PerformancePasswordStoreIsolation.activationProofName,
            isDirectory: false
        )
        let requestMarkerURL = homeURL.appendingPathComponent(
            PerformancePasswordStoreIsolation.requestMarkerName,
            isDirectory: false
        )
        guard
            !fileManager.fileExists(atPath: requestMarkerURL.path),
            isRegularFileWithoutFollowingLinks(at: activationProofURL),
            let activationProof = try? String(contentsOf: activationProofURL, encoding: .utf8),
            activationProof == "\(PerformancePasswordStoreIsolation.compiledMarker)\n\(token)\n"
        else {
            return nil
        }

        return PerformanceHarnessContext(
            homeURL: homeURL,
            temporaryDirectoryURL: temporaryDirectoryURL,
            token: token
        )
    }

    private static func canonicalURL(for path: String) -> URL {
        URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
    }

    private static func isRegularFileWithoutFollowingLinks(at url: URL) -> Bool {
        var status = stat()
        return lstat(url.path, &status) == 0 && (status.st_mode & S_IFMT) == S_IFREG
    }
}

struct PerformanceHarnessDetailSelection: Sendable {
    static let targetTorrentIDEnvironmentKey =
        "TRANSMISSION_REMOTE_MAC_PERFORMANCE_DETAIL_TORRENT_ID"

    private let proofURL: URL
    private let environment: [String: String]
    private let resolvedHomePath: String
    private let bypassesRuntimeValidationForTesting: Bool
    let targetTorrentID: TorrentSummary.ID

    static func requestedFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedHomePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> PerformanceHarnessDetailSelection? {
        guard let context = PerformanceHarnessContext.validatedIfRequested(
            featureEnvironmentKey: PerformanceHarnessContext.detailSelectionEnvironmentKey,
            environment: environment,
            resolvedHomePath: resolvedHomePath,
            fileManager: fileManager
        ) else {
            return nil
        }
        guard
            let targetText = environment[targetTorrentIDEnvironmentKey],
            let targetTorrentID = TorrentSummary.ID(targetText),
            targetTorrentID > 0,
            targetText == String(targetTorrentID)
        else {
            return nil
        }
        return PerformanceHarnessDetailSelection(
            proofURL: context.detailSelectionProofURL,
            environment: environment,
            resolvedHomePath: resolvedHomePath,
            bypassesRuntimeValidationForTesting: false,
            targetTorrentID: targetTorrentID
        )
    }

    static func enabledForTesting(
        proofURL: URL,
        targetTorrentID: TorrentSummary.ID
    ) -> PerformanceHarnessDetailSelection {
        PerformanceHarnessDetailSelection(
            proofURL: proofURL,
            environment: [:],
            resolvedHomePath: "",
            bypassesRuntimeValidationForTesting: true,
            targetTorrentID: targetTorrentID
        )
    }

    func isAuthorized(fileManager: FileManager = .default) -> Bool {
        if bypassesRuntimeValidationForTesting { return true }
        return PerformanceHarnessContext.validatedIfRequested(
            featureEnvironmentKey: PerformanceHarnessContext.detailSelectionEnvironmentKey,
            environment: environment,
            resolvedHomePath: resolvedHomePath,
            fileManager: fileManager
        )?.detailSelectionProofURL == proofURL
            && environment[Self.targetTorrentIDEnvironmentKey] == String(targetTorrentID)
    }

    @discardableResult
    func recordSelection(
        torrentID: TorrentSummary.ID,
        pane: TorrentDetailPane = .overview
    ) -> Bool {
        guard isAuthorized(), torrentID == targetTorrentID else { return false }
        let paneName = switch pane {
        case .overview: "overview"
        case .files: "files"
        case .peers: "peers"
        case .trackers: "trackers"
        case .statistics: "statistics"
        }
        let bytes = Array("\(torrentID) \(paneName)\n".utf8)
        guard !bytes.isEmpty, bytes.count <= 64 else { return false }
        let proofMode = mode_t(S_IRUSR | S_IWUSR)

        let descriptor = open(
            proofURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            proofMode
        )
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var openedStatus = stat()
        guard
            fchmod(descriptor, proofMode) == 0,
            fstat(descriptor, &openedStatus) == 0,
            (openedStatus.st_mode & S_IFMT) == S_IFREG,
            (openedStatus.st_mode & mode_t(0o777)) == proofMode,
            openedStatus.st_size == 0
        else {
            return false
        }

        guard writeAll(bytes, to: descriptor), synchronize(descriptor) else {
            _ = ftruncate(descriptor, 0)
            _ = synchronize(descriptor)
            return false
        }

        var writtenStatus = stat()
        var pathStatus = stat()
        guard
            fstat(descriptor, &writtenStatus) == 0,
            lstat(proofURL.path, &pathStatus) == 0,
            (pathStatus.st_mode & S_IFMT) == S_IFREG,
            writtenStatus.st_dev == pathStatus.st_dev,
            writtenStatus.st_ino == pathStatus.st_ino,
            writtenStatus.st_size == off_t(bytes.count),
            pathStatus.st_size == off_t(bytes.count),
            (pathStatus.st_mode & mode_t(0o777)) == proofMode
        else {
            return false
        }
        return true
    }
}

actor PerformanceHarnessPollingWakeRecorder: PollingWakeObserving {
    private static let maximumRecordCount = 4_096
    private static let maximumTraceBytes: off_t = 16 * 1_024

    private let environment: [String: String]
    private let resolvedHomePath: String
    private let fileManager: FileManager
    private var traceURL: URL?
    private var recordCount = 0

    static func requestedFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedHomePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> PerformanceHarnessPollingWakeRecorder? {
        guard environment[PerformanceHarnessContext.wakeRecordingEnvironmentKey] == "1" else {
            return nil
        }
        return PerformanceHarnessPollingWakeRecorder(
            environment: environment,
            resolvedHomePath: resolvedHomePath,
            fileManager: fileManager
        )
    }

    private init(
        environment: [String: String],
        resolvedHomePath: String,
        fileManager: FileManager
    ) {
        self.environment = environment
        self.resolvedHomePath = resolvedHomePath
        self.fileManager = fileManager
    }

    func recordWake(connectionToken: UUID, work: PollingWork) async {
        guard !work.isEmpty, recordCount < Self.maximumRecordCount else { return }
        _ = connectionToken
        if traceURL == nil {
            traceURL = PerformanceHarnessContext.validatedIfRequested(
                featureEnvironmentKey: PerformanceHarnessContext.wakeRecordingEnvironmentKey,
                environment: environment,
                resolvedHomePath: resolvedHomePath,
                fileManager: fileManager
            )?.wakeTraceURL
        }
        guard let traceURL else { return }

        let descriptor = open(
            traceURL.path,
            O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var status = stat()
        guard
            fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_size <= Self.maximumTraceBytes
        else {
            return
        }

        let line = "\(work.rawValue)\n"
        let bytes = Array(line.utf8)
        if writeAll(bytes, to: descriptor) {
            recordCount += 1
        }
    }
}

private func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
    bytes.withUnsafeBytes { buffer -> Bool in
        guard let baseAddress = buffer.baseAddress else { return false }
        var written = 0
        while written < bytes.count {
            let result = Darwin.write(
                descriptor,
                baseAddress.advanced(by: written),
                bytes.count - written
            )
            if result > 0 {
                written += result
            } else if result == -1 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

private func synchronize(_ descriptor: Int32) -> Bool {
    while true {
        if fsync(descriptor) == 0 { return true }
        if errno != EINTR { return false }
    }
}
#else
struct PerformanceHarnessDetailSelection: Sendable {
    static let targetTorrentIDEnvironmentKey =
        "TRANSMISSION_REMOTE_MAC_PERFORMANCE_DETAIL_TORRENT_ID"
    var targetTorrentID: TorrentSummary.ID { 0 }
    static func requestedFromEnvironment() -> PerformanceHarnessDetailSelection? { nil }
    func isAuthorized(fileManager: FileManager = .default) -> Bool { false }
    @discardableResult
    func recordSelection(
        torrentID: TorrentSummary.ID,
        pane: TorrentDetailPane = .overview
    ) -> Bool { false }
}
#endif
