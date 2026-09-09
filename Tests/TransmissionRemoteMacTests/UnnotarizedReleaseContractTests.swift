// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest

final class UnnotarizedReleaseContractTests: XCTestCase {
    func testReleaseLoadsOnlyItsSharedLibrariesAndOwnsItsToolchainSetup() throws {
        let script = try releaseScript()

        XCTAssertTrue(script.contains(#"source "$ROOT_DIR/script/lib/app_bundle.sh""#))
        XCTAssertTrue(script.contains(#"source "$ROOT_DIR/script/lib/release_contract.sh""#))
        XCTAssertTrue(script.contains(#"XCRUN_BIN="/usr/bin/xcrun""#))
        XCTAssertTrue(script.contains(#"SWIFT_BIN="$("$XCRUN_BIN" --find swift)""#))
        XCTAssertTrue(script.contains(#"XCODEBUILD_BIN="$("$XCRUN_BIN" --find xcodebuild)""#))
        XCTAssertFalse(script.contains(#"source "$ROOT_DIR/script/release.sh""#))
        XCTAssertFalse(script.contains("unused-by-unnotarized-release"))
    }

    func testReleasePinsTheProjectCertificateAndReportsTrustLimits() throws {
        let script = try releaseScript()

        XCTAssertTrue(script.contains(
            #"UNNOTARIZED_CODESIGN_IDENTITY="Transmission Remote Mac Release""#
        ))
        XCTAssertTrue(script.contains(
            #"RELEASE_CERTIFICATE_RELATIVE="Resources/ReleaseSigningCertificate.cer""#
        ))
        XCTAssertTrue(script.contains(#"working_blob" == "$tagged_blob"#))
        XCTAssertTrue(script.contains(#"RELEASE_CERT_SHA1" == "$PINNED_CERT_SHA1"#))
        XCTAssertTrue(script.contains(#"SIGNED_LEAF_SHA256" == "$PINNED_CERT_SHA256"#))
        XCTAssertTrue(script.contains(#"--sign "$RELEASE_CERT_SHA1""#))
        XCTAssertTrue(script.contains(#"--identifier "$APP_BUNDLE_ID""#))
        XCTAssertTrue(script.contains(
            #"--requirements "=designated => anchor = H\"$PINNED_CERT_SHA1\" and identifier \"$APP_BUNDLE_ID\"""#
        ))
        XCTAssertTrue(script.contains("--options runtime"))
        XCTAssertTrue(script.contains("--timestamp=none"))
        XCTAssertTrue(script.contains(#""type": "project-self-signed""#))
        XCTAssertTrue(script.contains(#""appleTrust": False"#))
        XCTAssertTrue(script.contains(#""status": "not-submitted""#))
        XCTAssertTrue(script.contains(#""keychainACLContinuity": "unverified""#))
        XCTAssertTrue(script.contains(#""$designated_requirement" != *"cdhash"*"#))
        XCTAssertTrue(script.contains(#""hardenedRuntime": True"#))
        XCTAssertTrue(script.contains(#"pairs != [("commonName", expected_common_name)]"#))
        XCTAssertTrue(script.contains(#"certificate.get("subjectAltName")"#))
        XCTAssertTrue(script.contains("X509v3 Subject Alternative Name:"))
        XCTAssertTrue(script.contains("ssl.cert_time_to_seconds"))
        XCTAssertTrue(script.contains("X509v3 Extended Key Usage"))
        XCTAssertTrue(script.contains("Digital Signature"))
        XCTAssertTrue(script.contains("/usr/bin/security verify-cert "))
        XCTAssertFalse(script.contains("notarytool"))
        XCTAssertFalse(script.contains("stapler"))
        XCTAssertFalse(script.contains("--sign -"))
    }

    func testDesignatedRequirementAcceptsCodesignCanonicalCertificateRootOnlyWhenPinned() throws {
        let pinnedSHA1 = "1234567890ABCDEF1234567890ABCDEF12345678"
        let bundleIdentifier = "net.pokwer.TransmissionRemoteMac"
        let canonicalResult = try runReleaseLibraryShell(
            #"""
            APP_BUNDLE_ID="$1"
            PINNED_CERT_SHA1="$2"
            validate_designated_requirement \
              "designated => certificate root = H\"$2\" and identifier \"$1\""
            """#,
            arguments: [bundleIdentifier, pinnedSHA1]
        )
        let sourceFormResult = try runReleaseLibraryShell(
            #"""
            APP_BUNDLE_ID="$1"
            PINNED_CERT_SHA1="$2"
            validate_designated_requirement \
              "designated => anchor = H\"$2\" and identifier \"$1\""
            """#,
            arguments: [bundleIdentifier, pinnedSHA1]
        )
        let unanchoredResult = try runReleaseLibraryShell(
            #"""
            APP_BUNDLE_ID="$1"
            PINNED_CERT_SHA1="$2"
            validate_designated_requirement \
              "designated => identifier \"$1\" and certificate leaf = H\"$2\""
            """#,
            arguments: [bundleIdentifier, pinnedSHA1]
        )
        let wrongFingerprintResult = try runReleaseLibraryShell(
            #"""
            APP_BUNDLE_ID="$1"
            PINNED_CERT_SHA1="$2"
            validate_designated_requirement \
              "designated => certificate root = H\"0000000000000000000000000000000000000000\" and identifier \"$1\""
            """#,
            arguments: [bundleIdentifier, pinnedSHA1]
        )

        XCTAssertEqual(canonicalResult.status, 0, canonicalResult.stderr)
        XCTAssertEqual(sourceFormResult.status, 0, sourceFormResult.stderr)
        XCTAssertNotEqual(unanchoredResult.status, 0)
        XCTAssertTrue(unanchoredResult.stderr.contains("not anchored to the exact tracked certificate"))
        XCTAssertNotEqual(wrongFingerprintResult.status, 0)
        XCTAssertTrue(wrongFingerprintResult.stderr.contains("not anchored to the exact tracked certificate"))
    }

    func testReleaseRequiresArm64AndFreezesZipBeforeInspection() throws {
        let script = try releaseScript()
        let zip = try XCTUnwrap(
            script.range(of: "/usr/bin/ditto -c -k --keepParent --norsrc")
        )
        let freeze = try XCTUnwrap(
            script.range(
                of: "freeze_regular_file STAGED_ARTIFACT_SNAPSHOT",
                range: zip.upperBound..<script.endIndex
            )
        )
        let validation = try XCTUnwrap(
            script.range(of: "validate_final_artifact", range: freeze.upperBound..<script.endIndex)
        )

        XCTAssertLessThan(zip.lowerBound, freeze.lowerBound)
        XCTAssertLessThan(freeze.lowerBound, validation.lowerBound)
        XCTAssertTrue(script.contains(#"/usr/bin/uname -m"#))
        XCTAssertTrue(script.contains(#"/usr/bin/lipo -archs"#))
        XCTAssertTrue(script.contains(#""architecture": "arm64""#))
        XCTAssertTrue(script.contains("os.O_NOFOLLOW"))
        XCTAssertTrue(script.contains("validate_zip_members"))
        XCTAssertTrue(script.contains("validate_expected_bundle_members"))
        XCTAssertTrue(script.contains("verify_release_xattrs"))
        XCTAssertTrue(script.contains(#"spctl --assess --type execute --raw"#))
        XCTAssertTrue(script.contains(#"assessment.get("assessment:verdict") is not False"#))
        XCTAssertTrue(script.contains(#""rawVerdict": False"#))
        XCTAssertTrue(script.contains(#""spctlExitStatus": int(gatekeeper_exit_status)"#))
        XCTAssertTrue(script.contains(#""exactArtifactStatus": "not-attested""#))
        XCTAssertTrue(script.contains(#""reproducibility": {"status": "not-claimed"}"#))
    }

    func testBothReleasePathsBuildInsideTheirOwnedWorkDirectories() throws {
        let unnotarized = try releaseScript()
        let developerID = try developerIDReleaseScript()

        for script in [unnotarized, developerID] {
            XCTAssertTrue(script.contains(#"SWIFT_BUILD_DIR="$WORK_DIR/swift-build""#))
            XCTAssertTrue(script.contains(
                #"build -c release --scratch-path "$SWIFT_BUILD_DIR""#
            ))
            XCTAssertTrue(script.contains(
                #"build -c release --scratch-path "$SWIFT_BUILD_DIR" --show-bin-path"#
            ))
            XCTAssertFalse(script.contains(#"build -c release --show-bin-path"#))
        }
    }

    func testManifestRecordsToolchainHostAndUnattestedPerformance() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedManifest")
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let result = try runReleaseLibraryShell(
            """
            STAGED_MANIFEST="$1"
            ARTIFACT=/release/app.zip
            ARTIFACT_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            SOURCE_ARTIFACT=/release/source.tar.gz
            SOURCE_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
            CHECKSUM_FILE=/release/SHA256SUMS.txt
            MANIFEST=/release/manifest.json
            APP_VERSION=1.2.3
            APP_BUILD_NUMBER=4
            APP_BUNDLE_ID=net.pokwer.TransmissionRemoteMac
            APP_MINIMUM_SYSTEM_VERSION=14.0
            RELEASE_TAG=v1.2.3
            RELEASE_COMMIT=0123456789abcdef
            RELEASE_CERTIFICATE_RELATIVE=Resources/ReleaseSigningCertificate.cer
            PINNED_CERT_SHA1=1111111111111111111111111111111111111111
            PINNED_CERT_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
            GATEKEEPER_EXIT_STATUS=3
            SWIFT_VERSION='Apple Swift version 6.2'
            XCODE_VERSION='Xcode 26.0 Build version 17A123'
            MACOS_VERSION=26.0
            MACOS_BUILD=25A123
            write_manifest
            """,
            arguments: [manifestURL.path]
        )
        XCTAssertEqual(result.status, 0, result.stderr)

        let data = try Data(contentsOf: manifestURL)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let environment = try XCTUnwrap(manifest["buildEnvironment"] as? [String: Any])
        XCTAssertEqual(environment["swift"] as? String, "Apple Swift version 6.2")
        XCTAssertEqual(environment["xcode"] as? String, "Xcode 26.0 Build version 17A123")
        XCTAssertEqual(environment["macOSVersion"] as? String, "26.0")
        XCTAssertEqual(environment["macOSBuild"] as? String, "25A123")
        let performance = try XCTUnwrap(manifest["performance"] as? [String: Any])
        XCTAssertEqual(performance["exactArtifactStatus"] as? String, "not-attested")
        let reproducibility = try XCTUnwrap(manifest["reproducibility"] as? [String: Any])
        XCTAssertEqual(reproducibility["status"] as? String, "not-claimed")
    }

    func testStrictJSONValidationRejectsDuplicateKeysAndTrailingContent() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedStrictJSON")
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = directory.appendingPathComponent("valid.json")
        let duplicate = directory.appendingPathComponent("duplicate.json")
        let trailing = directory.appendingPathComponent("trailing.json")
        try Data(#"{"schemaVersion":1}"#.utf8).write(to: valid)
        try Data(#"{"schemaVersion":1,"schemaVersion":2}"#.utf8).write(to: duplicate)
        try Data(#"{"schemaVersion":1} trailing"#.utf8).write(to: trailing)

        let validResult = try runReleaseLibraryShell(
            #"validate_strict_json_file "$1""#,
            arguments: [valid.path]
        )
        let duplicateResult = try runReleaseLibraryShell(
            #"validate_strict_json_file "$1""#,
            arguments: [duplicate.path]
        )
        let trailingResult = try runReleaseLibraryShell(
            #"validate_strict_json_file "$1""#,
            arguments: [trailing.path]
        )

        XCTAssertEqual(validResult.status, 0, validResult.stderr)
        XCTAssertNotEqual(duplicateResult.status, 0)
        XCTAssertTrue(duplicateResult.stderr.contains("duplicate JSON object key"))
        XCTAssertNotEqual(trailingResult.status, 0)
        XCTAssertTrue(trailingResult.stderr.contains("invalid strict JSON"))
    }

    func testGeneratedArtifactSanitizerHonoursTheProvenanceOnlyContract() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedGeneratedXattrs")
        defer { try? FileManager.default.removeItem(at: directory) }
        let artifact = directory.appendingPathComponent("artifact")
        try Data("release bytes".utf8).write(to: artifact)

        let result = try runReleaseLibraryShell(
            """
            WORK_DIR="$(dirname "$1")"
            before="$(sha256_file "$1")"
            /usr/bin/xattr -w com.example.release-test present "$1"
            sanitize_and_verify_generated_file_xattrs "$1"
            after="$(sha256_file "$1")"
            [[ "$before" == "$after" ]]
            ! /usr/bin/xattr -p com.example.release-test "$1" >/dev/null 2>&1
            verify_release_xattrs "$1"
            validate_release_xattr_names generated com.apple.provenance
            validate_release_xattr_names generated ''
            """,
            arguments: [artifact.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try String(contentsOf: artifact, encoding: .utf8), "release bytes")

        let unexpectedResult = try runReleaseLibraryShell(
            """
            WORK_DIR="$(dirname "$1")"
            /usr/bin/xattr -w com.example.release-test present "$1"
            verify_release_xattrs "$1"
            """,
            arguments: [artifact.path]
        )
        XCTAssertNotEqual(unexpectedResult.status, 0)
        XCTAssertTrue(unexpectedResult.stderr.contains("unexpected extended attributes"))
    }

    func testXattrEnumerationFailureIsRejectedBeforeInspection() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedXattrEnumeration")
        defer { try? FileManager.default.removeItem(at: directory) }
        let missing = directory.appendingPathComponent("missing-release-input")

        let result = try runReleaseLibraryShell(
            """
            WORK_DIR="$1"
            verify_release_xattrs "$2"
            """,
            arguments: [directory.path, missing.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(
            result.stderr.contains("Unable to enumerate release input"),
            result.stderr
        )
        let script = try releaseScript()
        XCTAssertTrue(script.contains(#"if ! /usr/bin/find "$path" -print0 >"$paths_file""#))
        XCTAssertFalse(script.contains(#"done < <(/usr/bin/find "$path" -print0)"#))
    }

    func testManifestPrecedesChecksumsAndPublishedEvidenceGetsFinalSetVerification() throws {
        let script = try releaseScript()
        let manifestWrite = try XCTUnwrap(script.range(of: "\nwrite_manifest\n"))
        let manifestFreeze = try XCTUnwrap(
            script.range(
                of: "freeze_regular_file STAGED_MANIFEST_SNAPSHOT",
                range: manifestWrite.upperBound..<script.endIndex
            )
        )
        let checksumWrite = try XCTUnwrap(
            script.range(of: #">"$STAGED_CHECKSUMS""#, range: manifestFreeze.upperBound..<script.endIndex)
        )
        let publication = try XCTUnwrap(
            script.range(of: #"publish_release_output \"#, range: checksumWrite.upperBound..<script.endIndex)
        )
        let finalVerification = try XCTUnwrap(
            script.range(
                of: "verify_published_release_evidence",
                range: publication.upperBound..<script.endIndex
            )
        )

        XCTAssertLessThan(manifestWrite.lowerBound, manifestFreeze.lowerBound)
        XCTAssertLessThan(manifestFreeze.lowerBound, checksumWrite.lowerBound)
        XCTAssertLessThan(checksumWrite.lowerBound, publication.lowerBound)
        XCTAssertLessThan(publication.lowerBound, finalVerification.lowerBound)
        XCTAssertTrue(script.contains(#""covers": [artifact, source_artifact, manifest_file]"#))
        XCTAssertGreaterThanOrEqual(
            script.components(separatedBy: "verify_published_release_evidence").count - 1,
            3
        )
    }

    func testDirtyCheckoutPreflightRejectsBeforeReleaseWork() throws {
        let repository = try makeTemporaryDirectory(named: "UnnotarizedDirtyCheckout")
        defer { try? FileManager.default.removeItem(at: repository) }
        let setup = try runBash(
            """
            git init -q "$1"
            printf 'tracked\n' >"$1/tracked"
            git -C "$1" add tracked
            git -C "$1" -c user.name=Test -c user.email=test@example.invalid commit -q -m initial
            git -C "$1" tag v1.0.0
            """,
            arguments: [repository.path]
        )
        XCTAssertEqual(setup.status, 0, setup.stderr)
        try Data("dirty".utf8).write(to: repository.appendingPathComponent("dirty"))

        let result = try runReleaseLibraryShell(
            """
            ROOT_DIR="$1"
            RELEASE_TAG=v1.0.0
            assert_release_checkout
            """,
            arguments: [repository.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Release checkout must be clean"), result.stderr)
    }

    func testWrongTagPreflightRejectsCleanCheckout() throws {
        let repository = try makeTemporaryDirectory(named: "UnnotarizedWrongTag")
        defer { try? FileManager.default.removeItem(at: repository) }
        let setup = try runBash(
            """
            git init -q "$1"
            printf 'first\n' >"$1/tracked"
            git -C "$1" add tracked
            git -C "$1" -c user.name=Test -c user.email=test@example.invalid commit -q -m first
            git -C "$1" tag v1.0.0
            printf 'second\n' >"$1/tracked"
            git -C "$1" add tracked
            git -C "$1" -c user.name=Test -c user.email=test@example.invalid commit -q -m second
            """,
            arguments: [repository.path]
        )
        XCTAssertEqual(setup.status, 0, setup.stderr)

        let result = try runReleaseLibraryShell(
            """
            ROOT_DIR="$1"
            RELEASE_TAG=v1.0.0
            assert_release_checkout
            """,
            arguments: [repository.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("must point at HEAD"), result.stderr)
    }

    func testShallowCheckoutPreflightRejectsBeforeReleaseWork() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedShallowCheckout")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source", isDirectory: true)
        let clone = directory.appendingPathComponent("clone", isDirectory: true)
        let setup = try runBash(
            """
            git init -q "$1"
            printf 'tracked\n' >"$1/tracked"
            git -C "$1" add tracked
            git -C "$1" -c user.name=Test -c user.email=test@example.invalid commit -q -m initial
            git -C "$1" tag v1.0.0
            git clone -q --depth 1 --branch v1.0.0 "file://$1" "$2"
            """,
            arguments: [source.path, clone.path]
        )
        XCTAssertEqual(setup.status, 0, setup.stderr)

        let result = try runReleaseLibraryShell(
            """
            ROOT_DIR="$1"
            RELEASE_TAG=v1.0.0
            assert_release_checkout
            """,
            arguments: [clone.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("must not be shallow"), result.stderr)
    }

    func testConcurrentWorkCleanupPreservesAnotherInvocationAndForeignWork() throws {
        let repository = try makeTemporaryDirectory(named: "UnnotarizedConcurrentWork")
        defer { try? FileManager.default.removeItem(at: repository) }

        let result = try runReleaseLibraryShell(
            """
            ROOT_DIR="$1"
            create_unnotarized_work_dir >"$1/first-record" &
            first_job=$!
            create_unnotarized_work_dir >"$1/second-record" &
            second_job=$!
            wait "$first_job"
            wait "$second_job"
            first_record="$(cat "$1/first-record")"
            first="${first_record%%|*}"
            first_metadata="${first_record#*|}"
            first_device="${first_metadata%%|*}"
            first_inode="${first_metadata#*|}"
            second_record="$(cat "$1/second-record")"
            second="${second_record%%|*}"
            second_metadata="${second_record#*|}"
            second_device="${second_metadata%%|*}"
            second_inode="${second_metadata#*|}"
            [[ "$first" != "$second" ]]
            /bin/mkdir "$1/dist/github-release/foreign-work"
            /usr/bin/printf keep >"$first/first-marker"
            /usr/bin/printf keep >"$1/dist/github-release/foreign-work/marker"
            remove_unnotarized_work_dir "$second" "$second_device" "$second_inode"
            [[ -f "$first/first-marker" ]]
            [[ -f "$1/dist/github-release/foreign-work/marker" ]]
            remove_unnotarized_work_dir "$first" "$first_device" "$first_inode"
            [[ -f "$1/dist/github-release/foreign-work/marker" ]]
            """,
            arguments: [repository.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testWorkCleanupRefusesAReplacementAtTheOwnedPath() throws {
        let repository = try makeTemporaryDirectory(named: "UnnotarizedReplacedWork")
        defer { try? FileManager.default.removeItem(at: repository) }

        let result = try runReleaseLibraryShell(
            """
            ROOT_DIR="$1"
            record="$(create_unnotarized_work_dir)"
            work="${record%%|*}"
            metadata="${record#*|}"
            device="${metadata%%|*}"
            inode="${metadata#*|}"
            /bin/mv "$work" "$work.original"
            /bin/mkdir -m 700 "$work"
            /usr/bin/printf replacement >"$work/marker"
            if remove_unnotarized_work_dir "$work" "$device" "$inode"; then
              exit 9
            fi
            [[ -f "$work/marker" ]]
            /bin/rm -rf "$work" "$work.original"
            """,
            arguments: [repository.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testZIPValidationRejectsRepeatedSeparatorsAndDotComponents() throws {
        let hostileNames = [
            "TransmissionRemoteMac.app/Contents//Info.plist",
            "TransmissionRemoteMac.app/Contents/./Info.plist",
        ]
        for name in hostileNames {
            let result = try validateZIPMembers([name])
            XCTAssertNotEqual(result.status, 0, name)
            XCTAssertTrue(result.stderr.contains("non-canonical ZIP member"), result.stderr)
        }
    }

    func testZIPValidationRejectsCanonicalizedDuplicateMembers() throws {
        let result = try validateZIPMembers([
            "TransmissionRemoteMac.app/Contents/Info.plist",
            "TransmissionRemoteMac.app/Contents/info.plist",
        ])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("canonical duplicate ZIP member"), result.stderr)
    }

    func testZIPValidationRejectsSpecialMemberModes() throws {
        let result = try validateZIPMembers(
            ["TransmissionRemoteMac.app/Contents/FIFO"],
            fileType: "fifo"
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("non-regular special member"), result.stderr)
    }

    func testTrackedReleaseCertificatePassesPrivacyAndCodeSigningValidation() throws {
        let certificate = repositoryRoot()
            .appendingPathComponent("Resources/ReleaseSigningCertificate.cer")
        let directory = try makeTemporaryDirectory(named: "UnnotarizedCertificateValidation")
        defer { try? FileManager.default.removeItem(at: directory) }
        let pem = directory.appendingPathComponent("certificate.pem")

        let result = try runReleaseLibraryShell(
            #"validate_release_certificate_file "$1" "$2" "Transmission Remote Mac Release""#,
            arguments: [certificate.path, pem.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
    }

    func testCertificatePrivacyValidationRejectsAdditionalSubjectMetadata() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedPrivateCertificate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = directory.appendingPathComponent("openssl.cnf")
        let privateKey = directory.appendingPathComponent("private.pem")
        let certificatePEM = directory.appendingPathComponent("certificate.pem")
        let certificateDER = directory.appendingPathComponent("certificate.cer")
        try Data(
            """
            [req]
            distinguished_name = subject
            x509_extensions = extensions
            prompt = no
            [subject]
            CN = Transmission Remote Mac Release
            O = Personal Metadata
            [extensions]
            basicConstraints = critical,CA:TRUE
            keyUsage = critical,digitalSignature
            extendedKeyUsage = codeSigning
            """.utf8
        ).write(to: configuration)
        let creation = try runBash(
            """
            openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
              -config "$1" -keyout "$2" -out "$3" >/dev/null 2>&1
            openssl x509 -in "$3" -outform DER -out "$4"
            """,
            arguments: [
                configuration.path,
                privateKey.path,
                certificatePEM.path,
                certificateDER.path,
            ]
        )
        XCTAssertEqual(creation.status, 0, creation.stderr)

        let result = try runReleaseLibraryShell(
            #"validate_release_certificate_file "$1" "$2" "Transmission Remote Mac Release""#,
            arguments: [certificateDER.path, certificatePEM.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("subject must contain only"), result.stderr)
    }

    func testCertificatePrivacyValidationRejectsSubjectAlternativeName() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedSANCertificate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = try makeTestCertificate(
            in: directory,
            subject: "CN = Transmission Remote Mac Release",
            extensions: """
            basicConstraints = critical,CA:TRUE
            keyUsage = critical,digitalSignature
            extendedKeyUsage = codeSigning
            subjectAltName = DNS:release.example.invalid
            """
        )
        let pem = directory.appendingPathComponent("validated.pem")

        let result = try runReleaseLibraryShell(
            #"validate_release_certificate_file "$1" "$2" "Transmission Remote Mac Release""#,
            arguments: [certificate.path, pem.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("must not contain subjectAltName"), result.stderr)
    }

    func testCertificateValidationRejectsNonCodeSigningUsage() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedServerCertificate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = try makeTestCertificate(
            in: directory,
            subject: "CN = Transmission Remote Mac Release",
            extensions: """
            basicConstraints = critical,CA:TRUE
            keyUsage = critical,digitalSignature
            extendedKeyUsage = serverAuth
            """
        )
        let pem = directory.appendingPathComponent("validated.pem")

        let result = try runReleaseLibraryShell(
            #"validate_release_certificate_file "$1" "$2" "Transmission Remote Mac Release""#,
            arguments: [certificate.path, pem.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("code-signing extended key usage"), result.stderr)
    }

    func testCertificateValidationRejectsNearExpiry() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedNearExpiryCertificate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = try makeTestCertificate(
            in: directory,
            subject: "CN = Transmission Remote Mac Release",
            extensions: """
            basicConstraints = critical,CA:TRUE
            keyUsage = critical,digitalSignature
            extendedKeyUsage = codeSigning
            """,
            days: 30
        )
        let pem = directory.appendingPathComponent("validated.pem")

        let result = try runReleaseLibraryShell(
            #"validate_release_certificate_file "$1" "$2" "Transmission Remote Mac Release""#,
            arguments: [certificate.path, pem.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("remain valid for at least 730 days"), result.stderr)
    }

    func testCertificateValidationRejectsCustomExtensionOID() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedCustomOIDCertificate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = try makeTestCertificate(
            in: directory,
            subject: "CN = Transmission Remote Mac Release",
            extensions: """
            basicConstraints = critical,CA:TRUE
            keyUsage = critical,digitalSignature
            extendedKeyUsage = codeSigning
            1.2.3.4 = ASN1:UTF8String:unexpected
            """
        )
        let pem = directory.appendingPathComponent("validated.pem")

        let result = try runReleaseLibraryShell(
            #"validate_release_certificate_file "$1" "$2" "Transmission Remote Mac Release""#,
            arguments: [certificate.path, pem.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("unsupported extensions: 1.2.3.4"), result.stderr)
    }

    func testCertificateValidationRequiresCertificateAuthorityConstraint() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedNonCACertificate")
        defer { try? FileManager.default.removeItem(at: directory) }
        let certificate = try makeTestCertificate(
            in: directory,
            subject: "CN = Transmission Remote Mac Release",
            extensions: """
            basicConstraints = critical,CA:FALSE
            keyUsage = critical,digitalSignature
            extendedKeyUsage = codeSigning
            """
        )
        let pem = directory.appendingPathComponent("validated.pem")

        let result = try runReleaseLibraryShell(
            #"validate_release_certificate_file "$1" "$2" "Transmission Remote Mac Release""#,
            arguments: [certificate.path, pem.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("Basic Constraints must require CA:TRUE"), result.stderr)
    }

    func testArchitectureHelperAcceptsXCTestArm64AndRejectsNonMachOInput() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedArchitecture")
        defer { try? FileManager.default.removeItem(at: directory) }
        let arm64 = try XCTUnwrap(
            Bundle(for: UnnotarizedReleaseContractTests.self).executableURL
        )
        let invalid = directory.appendingPathComponent("invalid")
        try Data("not a Mach-O".utf8).write(to: invalid)

        let accepted = try runReleaseLibraryShell(
            #"assert_arm64_architecture "$1""#,
            arguments: [arm64.path]
        )
        let rejected = try runReleaseLibraryShell(
            #"assert_arm64_architecture "$1""#,
            arguments: [invalid.path]
        )

        XCTAssertEqual(accepted.status, 0, accepted.stderr)
        XCTAssertNotEqual(rejected.status, 0)
    }

    func testPublicationRefusesToOverwriteAnExistingOutput() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedPublicationCollision")
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("staged")
        let published = directory.appendingPathComponent("published")
        try Data("new".utf8).write(to: staged)
        try Data("existing".utf8).write(to: published)

        let result = try runReleaseLibraryShell(
            """
            snapshot="$(regular_file_snapshot "$1")"
            ownership=0
            publish_release_output "$1" "$2" "$snapshot" ownership
            """,
            arguments: [staged.path, published.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "existing")
        XCTAssertEqual(try String(contentsOf: staged, encoding: .utf8), "new")
    }

    func testCleanupDoesNotDeleteAReplacedPublishedPath() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedCleanupReplacement")
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("staged")
        let published = directory.appendingPathComponent("published")
        try Data("owned".utf8).write(to: staged)

        let result = try runReleaseLibraryShell(
            """
            snapshot="$(regular_file_snapshot "$1")"
            /bin/ln "$1" "$2"
            /bin/rm "$1"
            /bin/rm "$2"
            /usr/bin/printf replacement >"$2"
            remove_owned_release_output 1 "$2" "$1" "$snapshot"
            """,
            arguments: [staged.path, published.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "replacement")
    }

    func testCleanupDeletesOnlyTheFrozenPublishedInode() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedOwnedCleanup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("staged")
        let published = directory.appendingPathComponent("published")
        try Data("owned".utf8).write(to: staged)

        let result = try runReleaseLibraryShell(
            """
            snapshot="$(regular_file_snapshot "$1")"
            /bin/ln "$1" "$2"
            /bin/rm "$1"
            remove_owned_release_output 1 "$2" "$1" "$snapshot"
            """,
            arguments: [staged.path, published.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))
    }

    func testArmedCleanupRemovesPublishedInodeAfterStagedLinkWasRemoved() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedArmedAfterUnlink")
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("staged")
        let published = directory.appendingPathComponent("published")
        try Data("owned".utf8).write(to: staged)

        let result = try runReleaseLibraryShell(
            """
            snapshot="$(regular_file_snapshot "$1")"
            /bin/ln "$1" "$2"
            /bin/rm "$1"
            remove_owned_release_output armed "$2" "$1" "$snapshot"
            """,
            arguments: [staged.path, published.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: published.path))

        let contract = try sharedReleaseContractScript()
        let link = try XCTUnwrap(contract.range(of: #"/bin/ln "$staged" "$final""#))
        let unlink = try XCTUnwrap(
            contract.range(of: #"/bin/rm -f "$staged""#, range: link.upperBound..<contract.endIndex)
        )
        let publishedState = try XCTUnwrap(
            contract.range(
                of: #"printf -v "$published_flag" '%s' 1"#,
                range: unlink.upperBound..<contract.endIndex
            )
        )
        XCTAssertLessThan(link.lowerBound, unlink.lowerBound)
        XCTAssertLessThan(unlink.lowerBound, publishedState.lowerBound)
    }

    func testArmedCleanupDoesNotDeleteACompetingPath() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedArmedCleanup")
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("staged")
        let competing = directory.appendingPathComponent("published")
        try Data("owned".utf8).write(to: staged)
        try Data("competing".utf8).write(to: competing)

        let result = try runReleaseLibraryShell(
            #"remove_owned_release_output armed "$2" "$1""#,
            arguments: [staged.path, competing.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(try String(contentsOf: competing, encoding: .utf8), "competing")
    }

    func testFrozenEvidenceRejectsMutatedBytes() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedFrozenEvidence")
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = directory.appendingPathComponent("evidence")
        try Data("original".utf8).write(to: evidence)

        let result = try runReleaseLibraryShell(
            """
            snapshot="$(regular_file_snapshot "$1")"
            /usr/bin/printf changed >"$1"
            verify_regular_file_snapshot "$1" "$snapshot" exact evidence
            """,
            arguments: [evidence.path]
        )

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("changed after its release identity was frozen"))
    }

    func testPublicationPreservesFrozenBytesAndArmsOwnership() throws {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedPublication")
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = directory.appendingPathComponent("staged")
        let published = directory.appendingPathComponent("published")
        try Data("release bytes".utf8).write(to: staged)

        let result = try runReleaseLibraryShell(
            """
            snapshot="$(regular_file_snapshot "$1")"
            ownership=0
            publish_release_output "$1" "$2" "$snapshot" ownership
            [[ "$ownership" == 1 ]]
            verify_regular_file_snapshot "$2" "$snapshot" moved published
            """,
            arguments: [staged.path, published.path]
        )

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        XCTAssertEqual(try String(contentsOf: published, encoding: .utf8), "release bytes")
    }

    func testUnexpectedArgumentsFailBeforeMetadataOrBuildSideEffects() throws {
        let result = try runBash(
            #""$1" unexpected"#,
            arguments: [releaseScriptURL().path]
        )

        XCTAssertEqual(result.status, 2)
        XCTAssertTrue(result.stderr.contains("usage: BUILD_NUMBER=<number>"))
        XCTAssertFalse(result.stderr.contains("Release builds require an explicit BUILD_NUMBER"))
    }

    func testInterruptAndTerminationTrapsExitWithNonzeroSignalStatuses() throws {
        let script = try releaseScript()
        XCTAssertTrue(script.contains(#"trap 'cleanup_unnotarized_release_state 130' INT"#))
        XCTAssertTrue(script.contains(#"trap 'cleanup_unnotarized_release_state 143' TERM"#))

        for (signal, expectedStatus) in [("INT", Int32(130)), ("TERM", Int32(143))] {
            let result = try runReleaseLibraryShell(
                """
                remove_owned_release_output() { :; }
                remove_unnotarized_work_dir() { :; }
                RELEASE_COMPLETE=0
                PUBLISHED_ARTIFACT=0
                PUBLISHED_SOURCE=0
                PUBLISHED_CHECKSUMS=0
                PUBLISHED_MANIFEST=0
                ARTIFACT=/unused/artifact
                SOURCE_ARTIFACT=/unused/source
                CHECKSUM_FILE=/unused/checksums
                MANIFEST=/unused/manifest
                STAGED_ARTIFACT=/unused/staged-artifact
                STAGED_SOURCE=/unused/staged-source
                STAGED_CHECKSUMS=/unused/staged-checksums
                STAGED_MANIFEST=/unused/staged-manifest
                WORK_DIR=/unused/work
                WORK_DIR_DEVICE=1
                WORK_DIR_INODE=1
                install_unnotarized_release_traps
                kill -\(signal) "$$"
                exit 99
                """
            )

            XCTAssertEqual(result.status, expectedStatus, result.stderr)
        }
    }

    private func runReleaseLibraryShell(
        _ body: String,
        arguments: [String] = []
    ) throws -> ShellResult {
        try runBash(
            """
            export TRANSMISSION_REMOTE_MAC_UNNOTARIZED_RELEASE_CONTRACT_LIBRARY=1
            source "$1"
            shift
            \(body)
            """,
            arguments: [releaseScriptURL().path] + arguments
        )
    }

    private func runBash(
        _ body: String,
        arguments: [String] = []
    ) throws -> ShellResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", body, "release-contract"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return ShellResult(
            status: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }

    private func makeTemporaryDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func validateZIPMembers(
        _ memberNames: [String],
        fileType: String = "regular"
    ) throws -> ShellResult {
        let directory = try makeTemporaryDirectory(named: "UnnotarizedHostileZIP")
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("hostile.zip")
        return try runReleaseLibraryShell(
            """
            STAGED_ARTIFACT="$1"
            APP_EXECUTABLE_NAME=TransmissionRemoteMac
            /usr/bin/python3 - "$@" <<'PY'
            import stat
            import sys
            import zipfile

            archive_path, file_type, *member_names = sys.argv[1:]
            file_modes = {
                "fifo": stat.S_IFIFO | 0o600,
                "regular": stat.S_IFREG | 0o644,
            }
            with zipfile.ZipFile(archive_path, "w") as output:
                for member_name in member_names:
                    member = zipfile.ZipInfo(member_name)
                    member.create_system = 3
                    member.external_attr = file_modes[file_type] << 16
                    output.writestr(member, b"test")
            PY
            validate_zip_members
            """,
            arguments: [archive.path, fileType] + memberNames
        )
    }

    private func makeTestCertificate(
        in directory: URL,
        subject: String,
        extensions: String,
        days: Int = 1_095
    ) throws -> URL {
        let configuration = directory.appendingPathComponent("openssl.cnf")
        let privateKey = directory.appendingPathComponent("private.pem")
        let certificatePEM = directory.appendingPathComponent("certificate.pem")
        let certificateDER = directory.appendingPathComponent("certificate.cer")
        try Data(
            """
            [req]
            distinguished_name = subject
            x509_extensions = extensions
            prompt = no
            [subject]
            \(subject)
            [extensions]
            \(extensions)
            """.utf8
        ).write(to: configuration)
        let creation = try runBash(
            """
            openssl req -x509 -newkey rsa:2048 -nodes -days "$5" \
              -config "$1" -keyout "$2" -out "$3" >/dev/null 2>&1
            openssl x509 -in "$3" -outform DER -out "$4"
            """,
            arguments: [
                configuration.path,
                privateKey.path,
                certificatePEM.path,
                certificateDER.path,
                String(days),
            ]
        )
        guard creation.status == 0 else {
            throw NSError(
                domain: "UnnotarizedReleaseContractTests",
                code: Int(creation.status),
                userInfo: [NSLocalizedDescriptionKey: creation.stderr]
            )
        }
        return certificateDER
    }

    private func releaseScript() throws -> String {
        try String(contentsOf: releaseScriptURL(), encoding: .utf8)
    }

    private func developerIDReleaseScript() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent("script/release.sh"),
            encoding: .utf8
        )
    }

    private func sharedReleaseContractScript() throws -> String {
        try String(
            contentsOf: repositoryRoot().appendingPathComponent("script/lib/release_contract.sh"),
            encoding: .utf8
        )
    }

    private func releaseScriptURL() -> URL {
        repositoryRoot().appendingPathComponent("script/release_unnotarized.sh")
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}
