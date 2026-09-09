// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class ClientIdentityFileLoaderTests: XCTestCase {
    func testOnlyPKCS12ExtensionsReachTheScopedReader() async throws {
        let probe = IdentityFileScopeProbe()
        let loader = ClientIdentityFileLoader(
            startAccess: { _ in probe.start(); return true },
            stopAccess: { _ in probe.stop() },
            read: { _ in Data([1]) }
        )
        for fileExtension in ["p12", "pfx", "P12", "PFX"] {
            let data = try await loader.load(at: url(fileExtension))
            XCTAssertEqual(data, Data([1]))
        }
        XCTAssertEqual(probe.counts, [4, 4])
        for fileExtension in ["pem", "txt", ""] {
            do {
                _ = try await loader.load(at: url(fileExtension))
                XCTFail("Unsupported extension must fail before scope/read")
            } catch {
                XCTAssertEqual(error as? ClientIdentityFileSelectionError, .unsupportedFileType)
            }
        }
        XCTAssertEqual(probe.counts, [4, 4])
    }

    func testEmptyOversizedAndReadFailuresAlwaysReleaseStartedScope() async {
        for size in [0, PendingClientIdentityImport.maximumByteCount + 1] {
            let probe = IdentityFileScopeProbe()
            let loader = ClientIdentityFileLoader(
                startAccess: { _ in probe.start(); return true },
                stopAccess: { _ in probe.stop() },
                read: { _ in Data(repeating: 0, count: size) }
            )
            do {
                _ = try await loader.load(at: url("p12"))
                XCTFail("Invalid size must fail")
            } catch {
                XCTAssertEqual(error as? ClientIdentityFileSelectionError, .invalidFileSize)
            }
            XCTAssertEqual(probe.counts, [1, 1])
        }
        let probe = IdentityFileScopeProbe()
        let loader = ClientIdentityFileLoader(
            startAccess: { _ in probe.start(); return true },
            stopAccess: { _ in probe.stop() },
            read: { _ in throw CocoaError(.fileReadNoSuchFile) }
        )
        do {
            _ = try await loader.load(at: url("p12"))
            XCTFail("Reader error must propagate")
        } catch {
            XCTAssertEqual((error as? CocoaError)?.code, .fileReadNoSuchFile)
        }
        XCTAssertEqual(probe.counts, [1, 1])
    }

    func testMaximumSizeIsAcceptedAndUnstartedScopeIsNeverStopped() async throws {
        let probe = IdentityFileScopeProbe()
        let loader = ClientIdentityFileLoader(
            startAccess: { _ in false },
            stopAccess: { _ in probe.stop() },
            read: { _ in Data(repeating: 0, count: PendingClientIdentityImport.maximumByteCount) }
        )
        let data = try await loader.load(at: url("pfx"))
        XCTAssertEqual(data.count, PendingClientIdentityImport.maximumByteCount)
        XCTAssertEqual(probe.counts, [0, 0])
    }

    func testProductionReaderEnforcesBoundBeforeReadingOversizedFixture() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("oversized.p12")
        try Data([1]).write(to: fileURL)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(PendingClientIdentityImport.maximumByteCount + 1))
        try handle.close()
        let loader = ClientIdentityFileLoader(startAccess: { _ in false }, stopAccess: { _ in })
        do {
            _ = try await loader.load(at: fileURL)
            XCTFail("Descriptor size must enforce the PKCS#12 bound")
        } catch {
            XCTAssertEqual(error as? ClientIdentityFileSelectionError, .invalidFileSize)
        }
    }

    func testCancellationReachesWorkerAndRejectsLateNoncooperativeResult() async {
        for cooperates in [true, false] {
            let started = expectation(description: "Scoped read began")
            let gate = DispatchSemaphore(value: 0)
            let probe = IdentityFileScopeProbe()
            let loader = ClientIdentityFileLoader(
                startAccess: { _ in probe.start(); return true },
                stopAccess: { _ in probe.stop() },
                read: { _ in
                    started.fulfill()
                    _ = gate.wait(timeout: .now() + 2)
                    if cooperates { try Task.checkCancellation() }
                    return Data([1])
                }
            )
            let fileURL = url("p12")
            let task = Task { try await loader.load(at: fileURL) }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            gate.signal()
            do {
                _ = try await task.value
                XCTFail("Canceled reads must not return credential bytes")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            XCTAssertEqual(probe.counts, [1, 1])
        }
    }

    func testLoadStateKeepsSaveDisabledUntilCurrentOwnedRequestFinishes() {
        var state = ClientIdentityFileLoader.LoadState()
        let firstProfile = UUID()
        let secondProfile = UUID()
        XCTAssertFalse(state.isLoading)
        let first = state.begin(profileID: firstProfile)
        XCTAssertTrue(state.isLoading)
        let replacement = state.begin(profileID: firstProfile)
        XCTAssertFalse(state.complete(first, profileID: firstProfile))
        state.cancel(first)
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(state.complete(replacement, profileID: secondProfile))
        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(state.complete(replacement, profileID: firstProfile))
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.complete(replacement, profileID: firstProfile))
    }

    func testCancelOrProfileSwitchRejectsPreviousCompletionWithoutClearingNewLoad() {
        var state = ClientIdentityFileLoader.LoadState()
        let firstProfile = UUID()
        let secondProfile = UUID()
        let first = state.begin(profileID: firstProfile)
        state.cancel()
        XCTAssertFalse(state.isLoading)
        XCTAssertFalse(state.complete(first, profileID: firstProfile))
        let current = state.begin(profileID: secondProfile)
        state.cancel(first)
        XCTAssertFalse(state.complete(first, profileID: secondProfile))
        XCTAssertEqual(state.request, current)
        XCTAssertTrue(state.complete(current, profileID: secondProfile))
        XCTAssertFalse(state.isLoading)
    }

    private func url(_ fileExtension: String) -> URL {
        URL(fileURLWithPath: "/tmp/identity-fixture.\(fileExtension)")
    }
}

private final class IdentityFileScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var starts = 0
    private var stops = 0
    func start() { lock.lock(); defer { lock.unlock() }; starts += 1 }
    func stop() { lock.lock(); defer { lock.unlock() }; stops += 1 }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return [starts, stops] }
}
