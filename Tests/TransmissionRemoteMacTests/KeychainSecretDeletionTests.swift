// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import Security
import XCTest
@testable import TransmissionRemoteMac

final class KeychainSecretDeletionTests: XCTestCase {
    func testKeychainSecretDecoderRejectsWrongTypeAndInvalidUTF8() throws {
        XCTAssertThrowsError(try KeychainSecretValueDecoder.decode("not-data" as CFString)) { error in
            XCTAssertEqual(error as? KeychainSecretValueError, .corruptItem)
        }
        XCTAssertThrowsError(try KeychainSecretValueDecoder.decode(Data([0xFF]) as CFData)) { error in
            XCTAssertEqual(error as? KeychainSecretValueError, .corruptItem)
        }
        XCTAssertEqual(
            try KeychainSecretValueDecoder.decode(Data("secret".utf8) as CFData),
            "secret"
        )
    }

    func testOnlyItemNotFoundCountsAsSuccessfulAbsence() {
        XCTAssertTrue(KeychainItemStatusPolicy.isAbsent(errSecItemNotFound))
        XCTAssertFalse(KeychainItemStatusPolicy.isAbsent(errSecInteractionNotAllowed))
        XCTAssertFalse(KeychainItemStatusPolicy.isAbsent(errSecAuthFailed))
        XCTAssertFalse(KeychainItemStatusPolicy.isAbsent(errSecNotAvailable))
    }

    func testDeletionRejectsLockedAuthenticationAndInteractionFailures() {
        XCTAssertTrue(KeychainItemStatusPolicy.deletionSucceeded(errSecSuccess))
        XCTAssertTrue(KeychainItemStatusPolicy.deletionSucceeded(errSecItemNotFound))
        XCTAssertFalse(KeychainItemStatusPolicy.deletionSucceeded(errSecInteractionNotAllowed))
        XCTAssertFalse(KeychainItemStatusPolicy.deletionSucceeded(errSecAuthFailed))
        XCTAssertFalse(KeychainItemStatusPolicy.deletionSucceeded(errSecNotAvailable))
    }
}
