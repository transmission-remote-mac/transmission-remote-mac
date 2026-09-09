// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

#if DEBUG
import XCTest
@testable import TransmissionRemoteMac

final class PerformanceHarnessApplicationStateProofTests: XCTestCase {
    func testProofUsesExactSecureInspectableFormat() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: fixture.environment,
            resolvedHomePath: fixture.home.path
        ))
        let recorder = try XCTUnwrap(
            PerformanceHarnessApplicationStateProofRecorder.requestedFromEnvironment(
                environment: fixture.environment,
                resolvedHomePath: fixture.home.path
            )
        )

        XCTAssertTrue(recorder.record(PerformanceHarnessApplicationState(
            activationCount: 2,
            isMainWindowVisibleAndNonMiniaturized: true
        )))

        let proofURL = fixture.home.appendingPathComponent("tmp").appendingPathComponent(
            PerformanceHarnessApplicationStateProofRecorder.proofName
        )
        XCTAssertEqual(
            try String(contentsOf: proofURL, encoding: .utf8),
            "\(PerformanceHarnessApplicationStateProofRecorder.compiledMarker)\n"
                + "\(token)\n"
                + "activation_count=2\n"
                + "main_window_visible_nonminiaturized=true\n"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: proofURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testProofRejectsInvalidationWithoutReplacingPriorState() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: fixture.environment,
            resolvedHomePath: fixture.home.path
        ))
        let recorder = try XCTUnwrap(
            PerformanceHarnessApplicationStateProofRecorder.requestedFromEnvironment(
                environment: fixture.environment,
                resolvedHomePath: fixture.home.path
            )
        )
        XCTAssertTrue(recorder.record(PerformanceHarnessApplicationState(
            activationCount: 0,
            isMainWindowVisibleAndNonMiniaturized: false
        )))
        let proofURL = fixture.home.appendingPathComponent("tmp").appendingPathComponent(
            PerformanceHarnessApplicationStateProofRecorder.proofName
        )
        let initialProof = try Data(contentsOf: proofURL)

        try "forged\n".write(
            to: fixture.home.appendingPathComponent(
                PerformancePasswordStoreIsolation.activationProofName
            ),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertFalse(recorder.record(PerformanceHarnessApplicationState(
            activationCount: 1,
            isMainWindowVisibleAndNonMiniaturized: true
        )))
        XCTAssertEqual(try Data(contentsOf: proofURL), initialProof)
    }

    func testMalformedProofRequestIsRejected() throws {
        var fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.environment[PerformanceHarnessApplicationStateProofRecorder.environmentKey] = "yes"
        _ = try XCTUnwrap(PerformancePasswordStoreIsolation.activateIfRequested(
            environment: fixture.environment,
            resolvedHomePath: fixture.home.path
        ))

        XCTAssertNil(PerformanceHarnessApplicationStateProofRecorder.requestedFromEnvironment(
            environment: fixture.environment,
            resolvedHomePath: fixture.home.path
        ))
    }

    private var token: String {
        "performance-application-state-token-000000000001"
    }

    private func makeFixture() throws -> (
        root: URL,
        home: URL,
        environment: [String: String]
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PerformanceApplicationState-\(UUID().uuidString)",
            isDirectory: true
        )
        let home = root.appendingPathComponent("home", isDirectory: true)
        let temporaryDirectory = home.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        try "\(token)\n".write(
            to: home.appendingPathComponent(PerformancePasswordStoreIsolation.requestMarkerName),
            atomically: true,
            encoding: .utf8
        )
        return (
            root,
            home,
            [
                PerformancePasswordStoreIsolation.modeEnvironmentKey: "1",
                PerformancePasswordStoreIsolation.homeEnvironmentKey: home.path,
                PerformancePasswordStoreIsolation.tokenEnvironmentKey: token,
                PerformancePreferencesIsolation.suiteEnvironmentKey:
                    "\(PerformancePreferencesIsolation.suitePrefix).\(token)",
                PerformanceHarnessApplicationStateProofRecorder.environmentKey: "1",
                "TMPDIR": temporaryDirectory.path,
            ]
        )
    }
}
#endif
