// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Darwin
import Foundation

enum PerformanceHarnessTiming {
    static func nanoseconds(in duration: Duration) -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else { return 0 }
        let seconds = UInt64(components.seconds)
        let nanoseconds = UInt64(components.attoseconds / 1_000_000_000)
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !multiplied.overflow else { return UInt64.max }
        let total = multiplied.partialValue.addingReportingOverflow(nanoseconds)
        return total.overflow ? UInt64.max : total.partialValue
    }
}

protocol PerformanceHarnessInstrumenting: Sendable {
    var requestsFilesPaneProof: Bool { get }
    func record(_ record: PerformanceHarnessTraceRecord)
}

final class PerformanceHarnessFilesViewInstrumentationOwner: ObservableObject {
    let controller: PerformanceHarnessFilesViewInstrumentationController?

    init(
        controller: PerformanceHarnessFilesViewInstrumentationController? =
            PerformanceHarnessFilesViewInstrumentationController.requestedFromEnvironment()
    ) {
        self.controller = controller
    }
}

final class PerformanceHarnessFilesViewInstrumentationController: @unchecked Sendable {
    private let lock = NSLock()
    private let targetTorrentID: TorrentSummary.ID
    private let minimumFileCount: Int
    private let instrumentation: any PerformanceHarnessInstrumenting
    private var acknowledgedRevisions = Set<UUID>()

    static func requestedFromEnvironment() -> PerformanceHarnessFilesViewInstrumentationController? {
#if DEBUG
        guard
            let selection = PerformanceHarnessDetailSelection.requestedFromEnvironment(),
            let instrumentation = PerformanceHarnessInstrumentationRecorder.requestedFromEnvironment()
        else {
            return nil
        }
        return PerformanceHarnessFilesViewInstrumentationController(
            targetTorrentID: selection.targetTorrentID,
            minimumFileCount: 10_000,
            instrumentation: instrumentation
        )
#else
        nil
#endif
    }

    static func enabledForTesting(
        targetTorrentID: TorrentSummary.ID,
        minimumFileCount: Int = 0,
        instrumentation: any PerformanceHarnessInstrumenting
    ) -> PerformanceHarnessFilesViewInstrumentationController {
        PerformanceHarnessFilesViewInstrumentationController(
            targetTorrentID: targetTorrentID,
            minimumFileCount: minimumFileCount,
            instrumentation: instrumentation
        )
    }

    private init(
        targetTorrentID: TorrentSummary.ID,
        minimumFileCount: Int,
        instrumentation: any PerformanceHarnessInstrumenting
    ) {
        self.targetTorrentID = targetTorrentID
        self.minimumFileCount = minimumFileCount
        self.instrumentation = instrumentation
    }

    func recordProjection(
        identity: TorrentFilesProjectionIdentity,
        fileCount: Int,
        rowCount: Int,
        duration: Duration
    ) {
        guard owns(identity, fileCount: fileCount) else { return }
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .filesProjection,
            outcome: .measured,
            durationNanoseconds: PerformanceHarnessTiming.nanoseconds(in: duration),
            torrentID: identity.torrentID,
            revision: identity.filesSnapshotRevision.rawValue,
            rowCount: rowCount,
            fileCount: fileCount
        ))
    }

    func makeSelectAllPlan(
        identity: TorrentFilesProjectionIdentity,
        fileCount: Int,
        planner: TorrentFileSelectionPlanner
    ) -> PerformanceHarnessFilesSelectionPlan? {
        guard owns(identity, fileCount: fileCount) else { return nil }

        let selectStartedAt = ContinuousClock().now
        let selectedNodeIDs = planner.allNodeIDs
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .filesSelectAll,
            outcome: .measured,
            durationNanoseconds: PerformanceHarnessTiming.nanoseconds(
                in: selectStartedAt.duration(to: ContinuousClock().now)
            ),
            torrentID: identity.torrentID,
            revision: identity.filesSnapshotRevision.rawValue,
            fileCount: fileCount,
            selectedCount: selectedNodeIDs.count,
            operation: "plan"
        ))

        let mutationPlanStartedAt = ContinuousClock().now
        let selectedFileIndexes = planner.fileIndexes(in: selectedNodeIDs)
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .filesMutationPlan,
            outcome: .measured,
            durationNanoseconds: PerformanceHarnessTiming.nanoseconds(
                in: mutationPlanStartedAt.duration(to: ContinuousClock().now)
            ),
            torrentID: identity.torrentID,
            revision: identity.filesSnapshotRevision.rawValue,
            fileCount: fileCount,
            selectedCount: selectedFileIndexes.count,
            operation: "selected-file-indexes"
        ))
        return PerformanceHarnessFilesSelectionPlan(
            identity: identity,
            fileCount: fileCount,
            selectedNodeIDs: selectedNodeIDs
        )
    }

    @discardableResult
    func commitSelection(
        _ plan: PerformanceHarnessFilesSelectionPlan,
        currentIdentity: TorrentFilesProjectionIdentity,
        commit: () -> Void
    ) -> PerformanceHarnessFilesSelectionCommit? {
        guard plan.identity == currentIdentity, owns(currentIdentity, fileCount: plan.fileCount) else {
            recordStaleRevision(plan)
            return nil
        }
        let commitStartedAt = ContinuousClock().now
        commit()
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .filesSelectAll,
            outcome: .measured,
            durationNanoseconds: PerformanceHarnessTiming.nanoseconds(
                in: commitStartedAt.duration(to: ContinuousClock().now)
            ),
            torrentID: plan.identity.torrentID,
            revision: plan.identity.filesSnapshotRevision.rawValue,
            fileCount: plan.fileCount,
            selectedCount: plan.selectedNodeIDs.count,
            operation: "state-commit"
        ))
        return PerformanceHarnessFilesSelectionCommit(
            plan: plan,
            acknowledgementStartedAt: commitStartedAt
        )
    }

    @discardableResult
    func acknowledgeSelection(
        _ selectionCommit: PerformanceHarnessFilesSelectionCommit,
        currentIdentity: TorrentFilesProjectionIdentity?,
        selectedNodeIDs: Set<TorrentFileNode.ID>,
        filesPaneIsActive: Bool,
        acknowledgedAt: ContinuousClock.Instant = ContinuousClock().now
    ) -> Bool {
        let plan = selectionCommit.plan
        guard currentIdentity == plan.identity else {
            recordStaleRevision(plan)
            return false
        }
        let durationNanoseconds = PerformanceHarnessTiming.nanoseconds(
            in: selectionCommit.acknowledgementStartedAt.duration(to: acknowledgedAt)
        )
        guard
            durationNanoseconds > 0,
            filesPaneIsActive,
            selectedNodeIDs == plan.selectedNodeIDs,
            lock.withLock({ acknowledgedRevisions.insert(
                plan.identity.filesSnapshotRevision.rawValue
            ).inserted })
        else {
            return false
        }
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .filesPaneProof,
            outcome: .proven,
            durationNanoseconds: durationNanoseconds,
            torrentID: plan.identity.torrentID,
            revision: plan.identity.filesSnapshotRevision.rawValue,
            fileCount: plan.fileCount,
            selectedCount: selectedNodeIDs.count,
            pane: "files"
        ))
        return true
    }

    private func owns(_ identity: TorrentFilesProjectionIdentity, fileCount: Int) -> Bool {
        identity.torrentID == targetTorrentID && fileCount >= minimumFileCount
    }

    private func recordStaleRevision(_ plan: PerformanceHarnessFilesSelectionPlan) {
        instrumentation.record(PerformanceHarnessTraceRecord(
            event: .filesPaneProof,
            outcome: .rejected,
            torrentID: plan.identity.torrentID,
            revision: plan.identity.filesSnapshotRevision.rawValue,
            fileCount: plan.fileCount,
            reason: "stale-revision"
        ))
    }
}

enum PerformanceHarnessInstrumentationFactory {
    static func requestedFromEnvironment() -> (any PerformanceHarnessInstrumenting)? {
#if DEBUG
        PerformanceHarnessInstrumentationRecorder.requestedFromEnvironment()
#else
        nil
#endif
    }
}

#if DEBUG
final class PerformanceHarnessInstrumentationRecorder: PerformanceHarnessInstrumenting, @unchecked Sendable {
    static let environmentKey = "TRANSMISSION_REMOTE_MAC_PERFORMANCE_INSTRUMENTATION"
    static let traceName = ".transmission-remote-mac-performance-instrumentation"

    private static let maximumRecordCount = 8_192
    private static let maximumTraceBytes: off_t = 1_048_576
    private static let maximumRecordBytes = 1_024
    private static let writerRegistry = PerformanceHarnessTraceWriterRegistry(
        maximumRecordCount: maximumRecordCount,
        maximumTraceBytes: maximumTraceBytes,
        maximumRecordBytes: maximumRecordBytes
    )

    let requestsFilesPaneProof = true

    private let environment: [String: String]
    private let resolvedHomePath: String
    private let fileManager: FileManager
    private let testingTraceURL: URL?

    static func requestedFromEnvironment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        resolvedHomePath: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> PerformanceHarnessInstrumentationRecorder? {
        guard environment[environmentKey] == "1" else { return nil }
        guard PerformanceHarnessContext.validatedIfRequested(
            featureEnvironmentKey: environmentKey,
            environment: environment,
            resolvedHomePath: resolvedHomePath,
            fileManager: fileManager
        ) != nil else {
            return nil
        }
        return PerformanceHarnessInstrumentationRecorder(
            environment: environment,
            resolvedHomePath: resolvedHomePath,
            fileManager: fileManager,
            testingTraceURL: nil
        )
    }

    static func enabledForTesting(traceURL: URL) -> PerformanceHarnessInstrumentationRecorder {
        PerformanceHarnessInstrumentationRecorder(
            environment: [:],
            resolvedHomePath: "",
            fileManager: .default,
            testingTraceURL: traceURL
        )
    }

    private init(
        environment: [String: String],
        resolvedHomePath: String,
        fileManager: FileManager,
        testingTraceURL: URL?
    ) {
        self.environment = environment
        self.resolvedHomePath = resolvedHomePath
        self.fileManager = fileManager
        self.testingTraceURL = testingTraceURL
    }

    func record(_ record: PerformanceHarnessTraceRecord) {
        guard record.isValid else { return }
        let traceURL: URL
        if let testingTraceURL {
            traceURL = testingTraceURL
        } else {
            guard let context = PerformanceHarnessContext.validatedIfRequested(
                featureEnvironmentKey: Self.environmentKey,
                environment: environment,
                resolvedHomePath: resolvedHomePath,
                fileManager: fileManager
            ) else {
                return
            }
            traceURL = context.temporaryDirectoryURL.appendingPathComponent(Self.traceName)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard var bytes = try? encoder.encode(record), bytes.count < Self.maximumRecordBytes else {
            return
        }
        bytes.append(0x0A)
        Self.writerRegistry.writer(for: traceURL).append(bytes)
    }
}

private final class PerformanceHarnessTraceWriterRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumRecordCount: Int
    private let maximumTraceBytes: off_t
    private let maximumRecordBytes: Int
    private var writersByPath: [String: PerformanceHarnessTraceWriter] = [:]

    init(maximumRecordCount: Int, maximumTraceBytes: off_t, maximumRecordBytes: Int) {
        self.maximumRecordCount = maximumRecordCount
        self.maximumTraceBytes = maximumTraceBytes
        self.maximumRecordBytes = maximumRecordBytes
    }

    func writer(for traceURL: URL) -> PerformanceHarnessTraceWriter {
        let standardizedURL = traceURL.standardizedFileURL
        return lock.withLock {
            if let writer = writersByPath[standardizedURL.path] {
                return writer
            }
            let writer = PerformanceHarnessTraceWriter(
                traceURL: standardizedURL,
                maximumRecordCount: maximumRecordCount,
                maximumTraceBytes: maximumTraceBytes,
                maximumRecordBytes: maximumRecordBytes
            )
            writersByPath[standardizedURL.path] = writer
            return writer
        }
    }
}

private final class PerformanceHarnessTraceWriter: @unchecked Sendable {
    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    private struct FileState {
        let identity: FileIdentity
        let size: off_t
        let recordCount: Int
    }

    private let lock = NSLock()
    private let traceURL: URL
    private let maximumRecordCount: Int
    private let maximumTraceBytes: off_t
    private let maximumRecordBytes: Int
    private var fileState: FileState?

    init(
        traceURL: URL,
        maximumRecordCount: Int,
        maximumTraceBytes: off_t,
        maximumRecordBytes: Int
    ) {
        self.traceURL = traceURL
        self.maximumRecordCount = maximumRecordCount
        self.maximumTraceBytes = maximumTraceBytes
        self.maximumRecordBytes = maximumRecordBytes
    }

    func append(_ data: Data) {
        lock.withLock {
            appendWhileLocked(data)
        }
    }

    private func appendWhileLocked(_ data: Data) {
        let traceMode = mode_t(S_IRUSR | S_IWUSR)
        let descriptor = open(
            traceURL.path,
            O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW,
            traceMode
        )
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }

        var status = stat()
        guard
            fchmod(descriptor, traceMode) == 0,
            fstat(descriptor, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            (status.st_mode & mode_t(0o777)) == traceMode,
            status.st_size >= 0,
            status.st_size <= maximumTraceBytes
        else {
            return
        }

        let identity = FileIdentity(device: status.st_dev, inode: status.st_ino)
        let currentState: FileState
        if
            let fileState,
            fileState.identity == identity,
            fileState.size == status.st_size
        {
            currentState = fileState
        } else {
            guard let inspectedState = inspectExistingFile(
                descriptor: descriptor,
                identity: identity,
                size: status.st_size
            ) else {
                fileState = nil
                return
            }
            currentState = inspectedState
            fileState = inspectedState
        }

        guard
            currentState.recordCount < maximumRecordCount,
            data.count <= maximumRecordBytes,
            off_t(data.count) <= maximumTraceBytes - currentState.size
        else {
            return
        }

        guard writeAll(data, descriptor: descriptor) else {
            _ = ftruncate(descriptor, currentState.size)
            fileState = nil
            return
        }
        fileState = FileState(
            identity: identity,
            size: currentState.size + off_t(data.count),
            recordCount: currentState.recordCount + 1
        )
    }

    private func inspectExistingFile(
        descriptor: Int32,
        identity: FileIdentity,
        size: off_t
    ) -> FileState? {
        guard size <= maximumTraceBytes else { return nil }
        guard size > 0 else {
            return FileState(identity: identity, size: 0, recordCount: 0)
        }

        var bytes = Data(count: Int(size))
        let readSucceeded = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var bytesRead = 0
            while bytesRead < buffer.count {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: bytesRead),
                    buffer.count - bytesRead,
                    off_t(bytesRead)
                )
                if result > 0 {
                    bytesRead += result
                } else if result == -1 && errno == EINTR {
                    continue
                } else {
                    return false
                }
            }
            return true
        }
        guard readSucceeded, bytes.last == 0x0A else { return nil }

        let records = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
        guard records.last?.isEmpty == true else { return nil }
        let existingRecords = records.dropLast()
        guard existingRecords.count <= maximumRecordCount else { return nil }
        for record in existingRecords {
            guard
                !record.isEmpty,
                record.count + 1 <= maximumRecordBytes,
                (try? JSONSerialization.jsonObject(with: Data(record))) != nil
            else {
                return nil
            }
        }
        return FileState(identity: identity, size: size, recordCount: existingRecords.count)
    }

    private func writeAll(_ data: Data, descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            var written = 0
            while written < data.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: written),
                    data.count - written
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
}
#endif
