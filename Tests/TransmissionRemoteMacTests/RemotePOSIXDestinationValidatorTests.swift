// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class RemotePOSIXDestinationValidatorTests: XCTestCase {
    func testValidRemotePOSIXPathsAreReturnedWithoutMangling() throws {
        let destinations = [
            "/",
            "/srv/downloads",
            "/srv//Anime/../Season 1/épisode #1/",
            "/srv/downloads/keep ",
            "/srv/backslash\\is-a-valid-name",
            "/srv/日本語"
        ]

        for destination in destinations {
            XCTAssertEqual(try RemotePOSIXDestinationValidator.validated(destination), destination)
        }
    }

    func testEmptyRelativeAndNullContainingPathsAreRejected() {
        XCTAssertThrowsError(try RemotePOSIXDestinationValidator.validated("")) { error in
            XCTAssertEqual(error as? RemotePOSIXDestinationValidationError, .empty)
        }
        XCTAssertThrowsError(try RemotePOSIXDestinationValidator.validated("srv/downloads")) { error in
            XCTAssertEqual(error as? RemotePOSIXDestinationValidationError, .notAbsolute)
        }
        XCTAssertThrowsError(try RemotePOSIXDestinationValidator.validated(" /srv/downloads ")) { error in
            XCTAssertEqual(error as? RemotePOSIXDestinationValidationError, .notAbsolute)
        }
        XCTAssertThrowsError(try RemotePOSIXDestinationValidator.validated("/srv/\0downloads")) { error in
            XCTAssertEqual(error as? RemotePOSIXDestinationValidationError, .containsNullByte)
        }
    }
}
