// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest

final class BuildAndRunInstallOnlyContractTests: XCTestCase {
    func testModeValidationRunsBeforeAnyBuildOrInstallSideEffect() throws {
        let script = try buildScript()
        let validation = try XCTUnwrap(script.range(of: #"case "$MODE" in"#))
        let validationEnd = try XCTUnwrap(
            script.range(of: "esac", range: validation.upperBound..<script.endIndex)
        )
        let validationBlock = String(script[validation.lowerBound..<validationEnd.upperBound])

        XCTAssertTrue(validationBlock.contains(
            "run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|--install-only|install-only"
        ))
        XCTAssertTrue(validationBlock.contains(
            """
              *)
                echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--install-only]" >&2
                exit 2
                ;;
            """
        ))

        let sideEffectMarkers = [
            #"CODESIGN_IDENTITY="${CODESIGN_IDENTITY"#,
            #"DEVELOPMENT_CERT_SHA1="$(resolve_codesigning_identity_sha1"#,
            #"terminate_executable "$APP_BUNDLE/Contents/MacOS/$APP_EXECUTABLE_NAME""#,
            #""$SWIFT_BIN" build"#,
            #"/usr/bin/codesign --force"#,
            #"/bin/cp -RX "$APP_BUNDLE" "$APPLICATIONS_STAGING_BUNDLE""#,
            #"terminate_executable "$APPLICATIONS_EXECUTABLE""#,
            #"/bin/mv "$APPLICATIONS_STAGING_BUNDLE" "$APPLICATIONS_BUNDLE""#,
        ]
        for marker in sideEffectMarkers {
            let sideEffect = try XCTUnwrap(script.range(of: marker), marker)
            XCTAssertLessThan(validationEnd.upperBound, sideEffect.lowerBound, marker)
        }
    }

    func testInstallOnlyKeepsSignedAtomicInstallWithoutLaunching() throws {
        let script = try buildScript()
        let installedVerification = try XCTUnwrap(
            script.range(of: #"verify_development_signature "$APPLICATIONS_BUNDLE""#)
        )
        let modeDispatch = try XCTUnwrap(
            script.range(of: #"case "$MODE" in"#, range: installedVerification.upperBound..<script.endIndex)
        )
        let installOnly = try XCTUnwrap(
            script.range(of: "--install-only|install-only)", range: modeDispatch.upperBound..<script.endIndex)
        )
        let fallback = try XCTUnwrap(
            script.range(of: "  *)", range: installOnly.upperBound..<script.endIndex)
        )
        let installOnlyBranch = String(script[installOnly.lowerBound..<fallback.lowerBound])

        XCTAssertLessThan(installedVerification.lowerBound, modeDispatch.lowerBound)
        XCTAssertEqual(installOnlyBranch, "--install-only|install-only)\n    ;;\n")
        XCTAssertFalse(installOnlyBranch.contains("open_app"))
        XCTAssertFalse(installOnlyBranch.contains("verify_exact_app_process"))
    }

    func testVerifyStillLaunchesAndChecksExactInstalledProcess() throws {
        let script = try buildScript()
        let verifyStart = try XCTUnwrap(script.range(of: "--verify|verify)"))
        let installOnlyStart = try XCTUnwrap(
            script.range(of: "--install-only|install-only)", range: verifyStart.upperBound..<script.endIndex)
        )
        let verifyBranch = String(script[verifyStart.lowerBound..<installOnlyStart.lowerBound])

        XCTAssertTrue(verifyBranch.contains("open_app"))
        XCTAssertEqual(verifyBranch.components(separatedBy: "verify_exact_app_process").count - 1, 2)
    }

    private func buildScript() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let repositoryRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repositoryRoot.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
    }
}
