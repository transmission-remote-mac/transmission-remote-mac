// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class AddTorrentAdvancedOptionsTests: XCTestCase {
    func testPeerLimitBlankUsesDaemonDefault() throws {
        XCTAssertNil(try AddTorrentPeerLimitParser.parse(""))
        XCTAssertNil(try AddTorrentPeerLimitParser.parse(" \n\t "))
    }

    func testPeerLimitAcceptsInclusiveBoundsAndTrimsWhitespace() throws {
        XCTAssertEqual(try AddTorrentPeerLimitParser.parse("1"), 1)
        XCTAssertEqual(try AddTorrentPeerLimitParser.parse(" 42 "), 42)
        XCTAssertEqual(try AddTorrentPeerLimitParser.parse("999"), 999)
    }

    func testPeerLimitRejectsMalformedValues() {
        for draft in ["one", "1.5", "1 2", "--1"] {
            XCTAssertThrowsError(try AddTorrentPeerLimitParser.parse(draft)) { error in
                XCTAssertEqual(error as? AddTorrentPeerLimitValidationError, .notInteger)
            }
        }
    }

    func testPeerLimitRejectsValuesOutsideInclusiveRange() {
        let drafts = [
            "0",
            "-1",
            "1000",
            "999999999999999999999999999999999999999999999999"
        ]
        for draft in drafts {
            XCTAssertThrowsError(try AddTorrentPeerLimitParser.parse(draft)) { error in
                XCTAssertEqual(error as? AddTorrentPeerLimitValidationError, .outOfRange)
            }
        }
    }

    func testSaveAsCapabilityRequiresRPC15CompleteMetadataAndRootName() {
        XCTAssertFalse(AddTorrentSaveAsCapability.isEditable(
            rpcVersion: 14,
            metadataComplete: true,
            rootName: "Ubuntu"
        ))
        XCTAssertFalse(AddTorrentSaveAsCapability.isEditable(
            rpcVersion: 15,
            metadataComplete: false,
            rootName: "Ubuntu"
        ))
        XCTAssertFalse(AddTorrentSaveAsCapability.isEditable(
            rpcVersion: 15,
            metadataComplete: true,
            rootName: nil
        ))
        XCTAssertFalse(AddTorrentSaveAsCapability.isEditable(
            rpcVersion: 15,
            metadataComplete: true,
            rootName: "  "
        ))
        XCTAssertTrue(AddTorrentSaveAsCapability.isEditable(
            rpcVersion: 15,
            metadataComplete: true,
            rootName: "Ubuntu"
        ))
    }

    func testAddCapabilitiesExposeSaveAsGateWithoutInventingRPCVersion() {
        XCTAssertFalse(AddTorrentCapabilities(rpcVersion: nil).supportsSaveAs)
        XCTAssertFalse(AddTorrentCapabilities(rpcVersion: 14).supportsSaveAs)
        XCTAssertTrue(AddTorrentCapabilities(rpcVersion: 15).supportsSaveAs)
    }

    func testProvisionalMetadataRequiresCompleteMetadataAndAuthoritativeRootName() {
        let incomplete = ProvisionalTorrentMetadataSnapshot(
            torrentID: 42,
            torrentHash: "hash",
            metadataPercentComplete: 0.99,
            rootName: "Ubuntu"
        )
        let missingName = ProvisionalTorrentMetadataSnapshot(
            torrentID: 42,
            torrentHash: "hash",
            metadataPercentComplete: 1,
            rootName: "  "
        )
        let ready = ProvisionalTorrentMetadataSnapshot(
            torrentID: 42,
            torrentHash: "hash",
            metadataPercentComplete: 1,
            rootName: "Ubuntu"
        )

        XCTAssertFalse(incomplete.hasAuthoritativeRootName)
        XCTAssertFalse(missingName.hasAuthoritativeRootName)
        XCTAssertTrue(ready.hasAuthoritativeRootName)
    }

    func testSaveAsValidationReturnsTrimmedSingleComponent() throws {
        XCTAssertEqual(
            try AddTorrentSaveAsValidator.validate("  Ubuntu 24.04  ", originalName: "Ubuntu"),
            "Ubuntu 24.04"
        )
    }

    func testSaveAsIntentValidationChecksShapeBeforeMetadataExists() throws {
        XCTAssertEqual(
            try AddTorrentSaveAsValidator.validateIntent("  Ubuntu 24.04  "),
            "Ubuntu 24.04"
        )
        assertSaveAsIntentError("folder/name", expected: .containsPathSeparator)
        assertSaveAsIntentError("..", expected: .reservedName)
    }

    func testCanonicalTransmissionHashRequiresExactlyFortyHexCharacters() {
        XCTAssertEqual(
            CanonicalTransmissionTorrentHash.normalize("  0123456789ABCDEF0123456789ABCDEF01234567  "),
            "0123456789abcdef0123456789abcdef01234567"
        )
        XCTAssertNil(CanonicalTransmissionTorrentHash.normalize(nil))
        XCTAssertNil(CanonicalTransmissionTorrentHash.normalize(""))
        XCTAssertNil(CanonicalTransmissionTorrentHash.normalize("abc"))
        XCTAssertNil(CanonicalTransmissionTorrentHash.normalize(String(repeating: "a", count: 39)))
        XCTAssertNil(CanonicalTransmissionTorrentHash.normalize(String(repeating: "a", count: 41)))
        XCTAssertNil(CanonicalTransmissionTorrentHash.normalize("g123456789abcdef0123456789abcdef01234567"))
    }

    func testSaveAsValidationRejectsEmptyReservedAndUnchangedNames() {
        assertSaveAsError(" \n ", originalName: "Ubuntu", expected: .empty)
        assertSaveAsError(".", originalName: "Ubuntu", expected: .reservedName)
        assertSaveAsError("..", originalName: "Ubuntu", expected: .reservedName)
        assertSaveAsError(" Ubuntu ", originalName: "Ubuntu", expected: .unchanged)
        assertSaveAsError("Ubuntu", originalName: " Ubuntu ", expected: .unchanged)
    }

    func testSaveAsValidationRejectsPathSeparatorsAndControlCharacters() {
        assertSaveAsError("folder/name", originalName: "Ubuntu", expected: .containsPathSeparator)
        assertSaveAsError(#"folder\name"#, originalName: "Ubuntu", expected: .containsPathSeparator)
        for draft in ["bad\u{0000}name", "bad\u{0007}name", "bad\nname"] {
            assertSaveAsError(
                draft,
                originalName: "Ubuntu",
                expected: .containsControlCharacter
            )
        }
    }

    func testProvisionalOwnerAllowsOnlyCurrentNonDuplicateOwnerToMutate() {
        let owner = makeOwner()
        XCTAssertTrue(owner.mayMutate(currentOwner: owner))
        XCTAssertFalse(owner.mayMutate(currentOwner: nil))

        let duplicate = makeOwner(isDuplicate: true)
        XCTAssertFalse(duplicate.mayMutate(currentOwner: duplicate))
    }

    func testProvisionalOwnerRejectsEveryStaleIdentityDimension() {
        let owner = makeOwner()
        let staleOwners = [
            makeOwner(requestID: UUID()),
            makeOwner(presentationID: UUID()),
            makeOwner(profileID: UUID()),
            makeOwner(connectionToken: UUID()),
            makeOwner(torrentID: 99),
            makeOwner(torrentHash: "different-hash")
        ]

        for staleOwner in staleOwners {
            XCTAssertFalse(owner.mayMutate(currentOwner: staleOwner))
        }
    }

    private func assertSaveAsError(
        _ draft: String,
        originalName: String,
        expected: AddTorrentSaveAsValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AddTorrentSaveAsValidator.validate(draft, originalName: originalName),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? AddTorrentSaveAsValidationError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func assertSaveAsIntentError(
        _ draft: String,
        expected: AddTorrentSaveAsValidationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try AddTorrentSaveAsValidator.validateIntent(draft),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? AddTorrentSaveAsValidationError, expected, file: file, line: line)
        }
    }

    private func makeOwner(
        requestID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        presentationID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        profileID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        connectionToken: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        torrentID: Int = 42,
        torrentHash: String = "0123456789abcdef0123456789abcdef01234567",
        isDuplicate: Bool = false
    ) -> ProvisionalTorrentAddOwner {
        ProvisionalTorrentAddOwner(
            requestID: requestID,
            presentationID: presentationID,
            profileID: profileID,
            connectionToken: connectionToken,
            torrentID: torrentID,
            torrentHash: torrentHash,
            isDuplicate: isDuplicate
        )
    }
}
