// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class TorrentFilePreviewLoaderTests: XCTestCase {
    func testCancellationForwardsToReaderAndBalancesSecurityScope() async {
        await assertCancellation(duringParse: false)
    }

    func testCancellationForwardsToParserAndIsNotAPreviewFallback() async {
        await assertCancellation(duringParse: true)
    }

    func testInvalidMetainfoPreservesSnapshotAsPreviewFallback() async throws {
        let probe = PreviewProbe()
        let snapshot = Self.snapshot
        let loader = TorrentFilePreviewLoader(
            startAccess: { _ in probe.start(); return true },
            stopAccess: { _ in probe.stop() },
            read: { _ in snapshot }
        )
        let result = try await loader.load(at: Self.url, expectedStableIdentity: snapshot.identity.rawValue)
        guard case .loaded(let actual, let summary, let error) = result else {
            return XCTFail("Expected fallback snapshot")
        }
        XCTAssertEqual(actual, snapshot)
        XCTAssertNil(summary)
        XCTAssertNotNil(error)
        XCTAssertEqual(probe.counts, [1, 1])
    }

    func testIdentityMismatchFailsBeforePreviewAndBalancesScope() async throws {
        let probe = PreviewProbe()
        let snapshot = Self.snapshot
        let loader = TorrentFilePreviewLoader(
            startAccess: { _ in probe.start(); return true },
            stopAccess: { _ in probe.stop() },
            read: { _ in snapshot },
            summarize: { _ in XCTFail("Mismatched identity must not parse"); throw CancellationError() }
        )
        let other = RaceResistantFileIdentity(deviceID: 1, fileID: 99, generation: 0)
        let result = try await loader.load(at: Self.url, expectedStableIdentity: other.rawValue)
        guard case .failed(let error) = result else { return XCTFail("Expected identity failure") }
        XCTAssertEqual(error, WatchFolderCoordinatorError.sourceFileWasReplaced.localizedDescription)
        XCTAssertEqual(probe.counts, [1, 1])
    }

    func testNoScopeStopWhenAccessWasNotStarted() async throws {
        let probe = PreviewProbe()
        let loader = TorrentFilePreviewLoader(
            startAccess: { _ in false },
            stopAccess: { _ in probe.stop() },
            read: { _ in throw CocoaError(.fileReadNoSuchFile) }
        )
        guard case .failed = try await loader.load(at: Self.url, expectedStableIdentity: nil) else {
            return XCTFail("Expected read failure")
        }
        XCTAssertEqual(probe.counts, [0, 0])
    }

    private func assertCancellation(duringParse: Bool) async {
        let started = expectation(description: "Worker reached owned stage")
        let gate = DispatchSemaphore(value: 0)
        let probe = PreviewProbe()
        let snapshot = Self.snapshot
        let loader = TorrentFilePreviewLoader(
            startAccess: { _ in probe.start(); return true },
            stopAccess: { _ in probe.stop() },
            read: { _ in
                if !duringParse {
                    started.fulfill()
                    _ = gate.wait(timeout: .now() + 2)
                    try Task.checkCancellation()
                }
                return snapshot
            },
            summarize: { data in
                started.fulfill()
                _ = gate.wait(timeout: .now() + 2)
                try Task.checkCancellation()
                return try TorrentMetainfoSummary(data: data)
            }
        )
        let task = Task { try await loader.load(at: Self.url, expectedStableIdentity: nil) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        gate.signal()
        do {
            _ = try await task.value
            XCTFail("Cancelled worker must not publish a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(probe.counts, [1, 1])
    }

    private static let url = URL(fileURLWithPath: "/tmp/preview-fixture.torrent")
    private static var snapshot: RaceResistantRegularFileSnapshot {
        RaceResistantRegularFileSnapshot(data: Data("invalid".utf8), identity: .init(deviceID: 1, fileID: 2, generation: 0))
    }
}

private final class PreviewProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    func start() { lock.lock(); defer { lock.unlock() }; starts += 1 }
    func stop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [starts, stops] }
}
