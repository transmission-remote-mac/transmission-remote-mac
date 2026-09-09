// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentFileLocalActionCapabilityTests: XCTestCase {
    @MainActor
    func testEnablementReadsNeverValidateAndValidationRunsOffMain() async throws {
        let calls = CapabilityValidationCounter()
        let worker = TorrentFileLocalActionCapabilityWorker { _, _, nodes in
            XCTAssertFalse(Thread.isMainThread)
            calls.increment()
            return nodes.count == 1
        }
        let capability = TorrentFileLocalActionCapability(worker: worker)
        let (request, planner) = try fixture()
        for _ in 0..<100 { XCTAssertFalse(capability.allows(request)) }
        XCTAssertEqual(calls.value, 0)
        await capability.update(request, planner: planner)
        for _ in 0..<100 { XCTAssertTrue(capability.allows(request)) }
        XCTAssertEqual(calls.value, 1)
    }

    @MainActor
    func testSelectionSnapshotDirectoryAndMappingChangesFailClosedBeforeUpdate() async throws {
        let capability = TorrentFileLocalActionCapability(worker: TorrentFileLocalActionCapabilityWorker { _, _, _ in true })
        let (request, planner) = try fixture()
        await capability.update(request, planner: planner)
        XCTAssertTrue(capability.allows(request))
        let changedIdentity = try XCTUnwrap(TorrentFilesProjectionIdentity(detail: TorrentDetail(
            id: request.identity.torrentID,
            filesSnapshotRevision: TorrentFilesSnapshotRevision()
        )))
        let changedMapping = TorrentFileLocalActionMapping(profile: ConnectionProfile(name: "Other", host: "localhost"))
        for other in [
            TorrentFileLocalActionCapabilityRequest(identity: changedIdentity, mapping: request.mapping, downloadDirectory: request.downloadDirectory, selection: request.selection),
            TorrentFileLocalActionCapabilityRequest(identity: request.identity, mapping: changedMapping, downloadDirectory: request.downloadDirectory, selection: request.selection),
            TorrentFileLocalActionCapabilityRequest(identity: request.identity, mapping: request.mapping, downloadDirectory: "/other", selection: request.selection),
            TorrentFileLocalActionCapabilityRequest(identity: request.identity, mapping: request.mapping, downloadDirectory: request.downloadDirectory, selection: ["different"])
        ] {
            XCTAssertFalse(capability.allows(other))
        }
        XCTAssertFalse(capability.allows(nil))
    }

    @MainActor
    func testInvalidationRejectsAnOlderInFlightResult() async throws {
        let started = expectation(description: "background validation started")
        let release = DispatchSemaphore(value: 0)
        let capability = TorrentFileLocalActionCapability(worker: TorrentFileLocalActionCapabilityWorker { _, _, _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return true
        })
        let (request, planner) = try fixture()
        let oldTask = Task { await capability.update(request, planner: planner) }
        await fulfillment(of: [started], timeout: 1)
        await capability.update(nil, planner: planner)
        release.signal()
        await oldTask.value
        XCTAssertFalse(capability.allows(request))
    }

    @MainActor
    func testCancelledCallerDoesNotPublishCapability() async throws {
        let started = expectation(description: "background validation started")
        let release = DispatchSemaphore(value: 0)
        let cancellationSeen = expectation(description: "worker sees cancellation")
        let capability = TorrentFileLocalActionCapability(worker: TorrentFileLocalActionCapabilityWorker { _, _, _ in
            started.fulfill()
            _ = release.wait(timeout: .now() + 2)
            if Task.isCancelled { cancellationSeen.fulfill() }
            try Task.checkCancellation()
            return true
        })
        let (request, planner) = try fixture()
        let task = Task { await capability.update(request, planner: planner) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        release.signal()
        await task.value
        await fulfillment(of: [cancellationSeen], timeout: 1)
        XCTAssertFalse(capability.allows(request))
    }

    @MainActor
    func testUnknownSelectionDoesNotReachFilesystemValidator() async throws {
        let calls = CapabilityValidationCounter()
        let capability = TorrentFileLocalActionCapability(worker: TorrentFileLocalActionCapabilityWorker { _, _, _ in
            calls.increment()
            return true
        })
        let (original, planner) = try fixture()
        let request = TorrentFileLocalActionCapabilityRequest(
            identity: original.identity,
            mapping: original.mapping,
            downloadDirectory: original.downloadDirectory,
            selection: ["missing"]
        )
        await capability.update(request, planner: planner)
        XCTAssertFalse(capability.allows(request))
        XCTAssertEqual(calls.value, 0)
    }

    func testMappingIdentityExcludesUnrelatedPreferencesAndSecrets() {
        let profile = ConnectionProfile(name: "Local", host: "localhost")
        var unrelated = profile
        unrelated.name = "Renamed"
        unrelated.password = "test-only"
        unrelated.requestTimeoutSeconds += 1
        XCTAssertEqual(TorrentFileLocalActionMapping(profile: profile), TorrentFileLocalActionMapping(profile: unrelated))
        unrelated.pathMappings = [PathMapping(remotePathPrefix: "/remote", localPathPrefix: "/local")]
        XCTAssertNotEqual(TorrentFileLocalActionMapping(profile: profile), TorrentFileLocalActionMapping(profile: unrelated))
    }

    func testLexicalMenuEligibilityRejectsUnknownAndTraversalWithoutResolvingPaths() throws {
        let (_, planner) = try fixture()
        XCTAssertTrue(planner.allNodes(in: planner.allNodeIDs, satisfy: TorrentFileLocalPathResolver.hasSafeRelativePath))
        XCTAssertFalse(planner.allNodes(in: ["missing"], satisfy: TorrentFileLocalPathResolver.hasSafeRelativePath))
        for path in ["..", "/absolute", "a//b", "a/./b", "a/../b"] {
            let node = TorrentFileNode(id: path, kind: .file(0), name: "file.bin", path: path,
                                       length: 1, bytesCompleted: 0, wanted: .wanted, priority: .normal, children: nil)
            XCTAssertFalse(TorrentFileLocalPathResolver.hasSafeRelativePath(node), path)
        }
    }

    private func fixture() throws -> (TorrentFileLocalActionCapabilityRequest, TorrentFileSelectionPlanner) {
        let detail = TorrentDetail(
            id: 1,
            files: [TorrentFile(id: 0, path: "", name: "file.bin", length: 10, bytesCompleted: 0, wanted: true, priority: 0)],
            filesSnapshotRevision: TorrentFilesSnapshotRevision()
        )
        let planner = TorrentFileSelectionPlanner(tree: detail.fileTree)
        let request = TorrentFileLocalActionCapabilityRequest(
            identity: try XCTUnwrap(TorrentFilesProjectionIdentity(detail: detail)),
            mapping: TorrentFileLocalActionMapping(profile: ConnectionProfile(name: "Local", host: "localhost")),
            downloadDirectory: "/tmp",
            selection: planner.allNodeIDs
        )
        return (request, planner)
    }
}

private final class CapabilityValidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
