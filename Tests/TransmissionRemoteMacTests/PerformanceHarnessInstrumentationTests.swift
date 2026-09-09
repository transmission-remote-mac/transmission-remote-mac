// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class PerformanceHarnessInstrumentationTests: XCTestCase {
    func testTraceRecordRequiresOwnedListPublicationAndKnownRejectionReason() {
        let ownership = PerformanceHarnessTraceOwnership(
            profileID: UUID(),
            connectionGeneration: UUID(),
            requestSequence: 7
        )

        XCTAssertTrue(PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .accepted,
            ownership: ownership,
            rowCount: 1_000
        ).isValid)
        XCTAssertFalse(PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .accepted,
            rowCount: 1_000
        ).isValid)
        XCTAssertFalse(PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .rejected,
            ownership: ownership,
            rowCount: 1_000,
            reason: "arbitrary-payload"
        ).isValid)
        XCTAssertFalse(PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .accepted,
            ownership: PerformanceHarnessTraceOwnership(
                profileID: UUID(),
                connectionGeneration: UUID(),
                requestSequence: 0
            ),
            rowCount: 1_000
        ).isValid)
    }

#if DEBUG
    func testAuthorizedDetailSelectionCanProveFilesPane() throws {
        let proofURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceFilesPane-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: proofURL) }
        let selection = PerformanceHarnessDetailSelection.enabledForTesting(
            proofURL: proofURL,
            targetTorrentID: 17
        )

        XCTAssertFalse(selection.recordSelection(torrentID: 18, pane: .files))
        XCTAssertTrue(selection.recordSelection(torrentID: 17, pane: .files))
        XCTAssertEqual(try String(contentsOf: proofURL, encoding: .utf8), "17 files\n")
    }

    func testRecorderWritesFlatBoundedJSONLAndRejectsInvalidRecord() throws {
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceInstrumentation-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: traceURL) }
        let recorder = PerformanceHarnessInstrumentationRecorder.enabledForTesting(
            traceURL: traceURL
        )
        recorder.record(PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .accepted,
            rowCount: 1_000
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: traceURL.path))

        let ownership = PerformanceHarnessTraceOwnership(
            profileID: UUID(),
            connectionGeneration: UUID(),
            requestSequence: 42
        )
        let expected = PerformanceHarnessTraceRecord(
            event: .torrentListPublication,
            outcome: .rejected,
            ownership: ownership,
            durationNanoseconds: 123,
            rowCount: 1_000,
            reason: "stale-owner"
        )
        recorder.record(expected)

        let data = try Data(contentsOf: traceURL)
        XCTAssertEqual(data.last, 0x0A)
        let attributes = try FileManager.default.attributesOfItem(atPath: traceURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let line = try XCTUnwrap(data.split(separator: 0x0A).first)
        let decoded = try JSONDecoder().decode(
            PerformanceHarnessTraceRecord.self,
            from: Data(line)
        )
        XCTAssertEqual(decoded, expected)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line)) as? [String: Any]
        )
        XCTAssertEqual(object["profileID"] as? String, ownership.profileID.uuidString)
        XCTAssertNil(object["ownership"])
    }

    func testRecordersSharePreexistingGlobalRecordBoundWithoutInterleavingJSONL() throws {
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceInstrumentation-Shared-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: traceURL) }
        let expected = PerformanceHarnessTraceRecord(
            event: .listProjection,
            outcome: .measured,
            rowCount: 0,
            operation: "sort"
        )
        let line = try encodedJSONL(expected)
        var preexistingTrace = Data()
        preexistingTrace.reserveCapacity(line.count * 8_190)
        for _ in 0..<8_190 {
            preexistingTrace.append(line)
        }
        try preexistingTrace.write(to: traceURL)

        let recorders = [
            PerformanceHarnessInstrumentationRecorder.enabledForTesting(traceURL: traceURL),
            PerformanceHarnessInstrumentationRecorder.enabledForTesting(traceURL: traceURL),
        ]
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            recorders[index % recorders.count].record(expected)
        }

        let data = try Data(contentsOf: traceURL)
        XCTAssertEqual(data.last, 0x0A)
        let records = try decodedTraceRecords(from: data)
        XCTAssertEqual(records.count, 8_192)
        XCTAssertTrue(records.allSatisfy { $0 == expected })
        let attributes = try FileManager.default.attributesOfItem(atPath: traceURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRecordersShareGlobalTraceByteBound() throws {
        let traceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceInstrumentation-Bytes-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: traceURL) }
        let expected = PerformanceHarnessTraceRecord(
            event: .listProjection,
            outcome: .measured,
            rowCount: 0,
            operation: "sort",
            reason: String(repeating: "x", count: 850)
        )
        XCTAssertTrue(expected.isValid)
        XCTAssertLessThan(try encodedJSONL(expected).count, 1_025)
        let firstRecorder = PerformanceHarnessInstrumentationRecorder.enabledForTesting(
            traceURL: traceURL
        )
        let secondRecorder = PerformanceHarnessInstrumentationRecorder.enabledForTesting(
            traceURL: traceURL
        )

        for index in 0..<2_000 {
            (index.isMultiple(of: 2) ? firstRecorder : secondRecorder).record(expected)
        }
        let boundedData = try Data(contentsOf: traceURL)
        XCTAssertLessThanOrEqual(boundedData.count, 1_048_576)
        XCTAssertFalse(try decodedTraceRecords(from: boundedData).isEmpty)

        firstRecorder.record(expected)
        secondRecorder.record(expected)
        XCTAssertEqual(try Data(contentsOf: traceURL), boundedData)
    }

    func testRecordersKeepIndependentTraceURLsIsolated() throws {
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceInstrumentation-First-\(UUID().uuidString).jsonl")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PerformanceInstrumentation-Second-\(UUID().uuidString).jsonl")
        addTeardownBlock {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let firstRecord = PerformanceHarnessTraceRecord(
            event: .listProjection,
            outcome: .measured,
            rowCount: 1,
            operation: "search"
        )
        let secondRecord = PerformanceHarnessTraceRecord(
            event: .listProjection,
            outcome: .measured,
            rowCount: 2,
            operation: "filter"
        )

        PerformanceHarnessInstrumentationRecorder.enabledForTesting(traceURL: firstURL)
            .record(firstRecord)
        PerformanceHarnessInstrumentationRecorder.enabledForTesting(traceURL: secondURL)
            .record(secondRecord)

        XCTAssertEqual(
            try decodedTraceRecords(from: Data(contentsOf: firstURL)),
            [firstRecord]
        )
        XCTAssertEqual(
            try decodedTraceRecords(from: Data(contentsOf: secondURL)),
            [secondRecord]
        )
    }

    private func encodedJSONL(_ record: PerformanceHarnessTraceRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    private func decodedTraceRecords(from data: Data) throws -> [PerformanceHarnessTraceRecord] {
        XCTAssertEqual(data.last, 0x0A)
        return try data.split(separator: 0x0A).map {
            try JSONDecoder().decode(PerformanceHarnessTraceRecord.self, from: Data($0))
        }
    }
#endif

    func testDurationConversionIsDeterministic() {
        XCTAssertEqual(
            PerformanceHarnessTiming.nanoseconds(in: .seconds(2) + .nanoseconds(345)),
            2_000_000_345
        )
    }

    func testFilesPaneProofRequiresPositiveAcknowledgementDuration() {
        let revision = UUID()
        let zeroDuration = PerformanceHarnessTraceRecord(
            event: .filesPaneProof,
            outcome: .proven,
            torrentID: 1,
            revision: revision,
            fileCount: 10_000,
            selectedCount: 10_001,
            pane: "files"
        )
        let measuredDuration = PerformanceHarnessTraceRecord(
            event: .filesPaneProof,
            outcome: .proven,
            durationNanoseconds: 1,
            torrentID: 1,
            revision: revision,
            fileCount: 10_000,
            selectedCount: 10_001,
            pane: "files"
        )

        XCTAssertFalse(zeroDuration.isValid)
        XCTAssertTrue(measuredDuration.isValid)
    }

    func testFilesInstrumentationTargetsOnlyTheExactFixtureTorrent() throws {
        let recorder = CapturingPerformanceHarnessInstrumentation()
        let controller = PerformanceHarnessFilesViewInstrumentationController.enabledForTesting(
            targetTorrentID: 1,
            instrumentation: recorder
        )
        let otherIdentity = try makeFilesIdentity(torrentID: 2)
        let planner = TorrentFileSelectionPlanner(tree: sampleFileTree())

        controller.recordProjection(
            identity: otherIdentity,
            fileCount: 2,
            rowCount: planner.allNodeIDs.count,
            duration: .milliseconds(1)
        )

        XCTAssertNil(controller.makeSelectAllPlan(
            identity: otherIdentity,
            fileCount: 2,
            planner: planner
        ))
        XCTAssertTrue(recorder.records.isEmpty)
    }

    func testFilesInstrumentationOwnerRetainsTheStableControllerInstance() {
        let controller = PerformanceHarnessFilesViewInstrumentationController.enabledForTesting(
            targetTorrentID: 1,
            instrumentation: CapturingPerformanceHarnessInstrumentation()
        )
        let owner = PerformanceHarnessFilesViewInstrumentationOwner(controller: controller)

        XCTAssertTrue(owner.controller === controller)
    }

    func testFilesInstrumentationMeasuresStateCommitAndDeduplicatesStableAcknowledgement() throws {
        let recorder = CapturingPerformanceHarnessInstrumentation()
        let controller = PerformanceHarnessFilesViewInstrumentationController.enabledForTesting(
            targetTorrentID: 1,
            instrumentation: recorder
        )
        let identity = try makeFilesIdentity(torrentID: 1)
        let planner = TorrentFileSelectionPlanner(tree: sampleFileTree())

        controller.recordProjection(
            identity: identity,
            fileCount: 2,
            rowCount: planner.allNodeIDs.count,
            duration: .milliseconds(2)
        )
        let plan = try XCTUnwrap(controller.makeSelectAllPlan(
            identity: identity,
            fileCount: 2,
            planner: planner
        ))
        var selectedNodeIDs = Set<TorrentFileNode.ID>()

        let selectionCommit = try XCTUnwrap(controller.commitSelection(
            plan,
            currentIdentity: identity,
            commit: { selectedNodeIDs = plan.selectedNodeIDs }
        ))
        XCTAssertEqual(selectedNodeIDs, planner.allNodeIDs)
        let acknowledgedAt = selectionCommit.acknowledgementStartedAt.advanced(
            by: .milliseconds(5)
        )
        XCTAssertTrue(controller.acknowledgeSelection(
            selectionCommit,
            currentIdentity: identity,
            selectedNodeIDs: selectedNodeIDs,
            filesPaneIsActive: true,
            acknowledgedAt: acknowledgedAt
        ))
        XCTAssertFalse(controller.acknowledgeSelection(
            selectionCommit,
            currentIdentity: identity,
            selectedNodeIDs: selectedNodeIDs,
            filesPaneIsActive: true,
            acknowledgedAt: acknowledgedAt.advanced(by: .milliseconds(1))
        ))

        XCTAssertEqual(recorder.records.map(\.event), [
            .filesProjection,
            .filesSelectAll,
            .filesMutationPlan,
            .filesSelectAll,
            .filesPaneProof,
        ])
        XCTAssertEqual(recorder.records.map(\.operation), [
            nil,
            "plan",
            "selected-file-indexes",
            "state-commit",
            nil,
        ])
        XCTAssertEqual(recorder.records.last?.outcome, .proven)
        XCTAssertEqual(recorder.records.last?.pane, "files")
        XCTAssertEqual(recorder.records.last?.revision, identity.filesSnapshotRevision.rawValue)
        XCTAssertEqual(recorder.records.last?.selectedCount, planner.allNodeIDs.count)
        XCTAssertEqual(recorder.records.last?.durationNanoseconds, 5_000_000)
    }

    func testFilesInstrumentationRejectsAStaleSwiftUIRevisionAcknowledgement() throws {
        let recorder = CapturingPerformanceHarnessInstrumentation()
        let controller = PerformanceHarnessFilesViewInstrumentationController.enabledForTesting(
            targetTorrentID: 1,
            instrumentation: recorder
        )
        let originalIdentity = try makeFilesIdentity(torrentID: 1)
        let replacementIdentity = try makeFilesIdentity(torrentID: 1)
        let planner = TorrentFileSelectionPlanner(tree: sampleFileTree())
        let plan = try XCTUnwrap(controller.makeSelectAllPlan(
            identity: originalIdentity,
            fileCount: 2,
            planner: planner
        ))
        let selectionCommit = try XCTUnwrap(controller.commitSelection(
            plan,
            currentIdentity: originalIdentity,
            commit: {}
        ))
        recorder.removeAll()

        XCTAssertFalse(controller.acknowledgeSelection(
            selectionCommit,
            currentIdentity: replacementIdentity,
            selectedNodeIDs: plan.selectedNodeIDs,
            filesPaneIsActive: true,
            acknowledgedAt: selectionCommit.acknowledgementStartedAt.advanced(
                by: .milliseconds(1)
            )
        ))
        XCTAssertEqual(recorder.records, [PerformanceHarnessTraceRecord(
            event: .filesPaneProof,
            outcome: .rejected,
            torrentID: 1,
            revision: originalIdentity.filesSnapshotRevision.rawValue,
            fileCount: 2,
            reason: "stale-revision"
        )])
    }

    private func makeFilesIdentity(torrentID: Int) throws -> TorrentFilesProjectionIdentity {
        try XCTUnwrap(TorrentFilesProjectionIdentity(
            detail: TorrentDetail(
                id: torrentID,
                filesSnapshotRevision: TorrentFilesSnapshotRevision()
            )
        ))
    }

    private func sampleFileTree() -> [TorrentFileNode] {
        [0, 1].map { index in
            TorrentFileNode(
                id: "file-\(index)",
                kind: .file(index),
                name: "File \(index)",
                path: "",
                length: 10,
                bytesCompleted: 0,
                wanted: .wanted,
                priority: .normal,
                children: nil
            )
        }
    }
}

private final class CapturingPerformanceHarnessInstrumentation:
    PerformanceHarnessInstrumenting,
    @unchecked Sendable {
    let requestsFilesPaneProof = true

    private let lock = NSLock()
    private var storage: [PerformanceHarnessTraceRecord] = []

    var records: [PerformanceHarnessTraceRecord] {
        lock.withLock { storage }
    }

    func record(_ record: PerformanceHarnessTraceRecord) {
        lock.withLock { storage.append(record) }
    }

    func removeAll() {
        lock.withLock { storage.removeAll() }
    }
}
