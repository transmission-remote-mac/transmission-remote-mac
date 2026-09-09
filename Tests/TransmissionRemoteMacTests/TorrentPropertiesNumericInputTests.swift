// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class TorrentPropertiesNumericInputTests: XCTestCase {
    func testNumericInputPreservesWholeAndFractionalDisplayWithoutTrappingOnRemoteValues() {
        var draft = makeDraft()
        XCTAssertEqual(TorrentPropertiesDraft.NumericInput(draft: draft).seedRatioText, "2")
        draft.seedRatio.limit = 1.25
        draft.seedIdle.limit = 2.5
        let input = TorrentPropertiesDraft.NumericInput(draft: draft)
        XCTAssertEqual(input.seedRatioText, "1.25")
        XCTAssertEqual(input.seedIdleText, "2")
        for value in [Double.infinity, -.infinity, .nan, Double.greatestFiniteMagnitude] {
            draft.seedRatio.limit = value
            draft.seedIdle.limit = value
            let invalid = TorrentPropertiesDraft.NumericInput(draft: draft)
            XCTAssertNotNil(draft.validationMessage(for: invalid, rpcVersion: 18))
        }
    }

    func testIntegerBoundsWhitespaceAndExactErrorPriority() {
        let draft = makeDraft()
        let valid = TorrentPropertiesDraft.NumericInput(draft: draft)
        for text in ["", "0", "-1", "1.5", "1000000", "99999999999999999999999", "nan"] {
            var input = valid
            input.downloadSpeedText = text
            XCTAssertEqual(draft.validationMessage(for: input, rpcVersion: 18),
                           "Download speed must be a whole number from 1 to 999999 KB/s.")
            input.downloadSpeedText = " \n999999 "
            input.uploadSpeedText = text
            XCTAssertEqual(draft.validationMessage(for: input, rpcVersion: 18),
                           "Upload speed must be a whole number from 1 to 999999 KB/s.")
            input.uploadSpeedText = " 1\n"
            input.seedIdleText = text
            XCTAssertEqual(draft.validationMessage(for: input, rpcVersion: 18),
                           "Inactive seeding must be a whole number from 1 to 999999 minutes.")
        }
        for peer in ["0", "1000", "1.5", ""] {
            var input = valid
            input.peerLimitText = peer
            XCTAssertEqual(draft.validationMessage(for: input, rpcVersion: 18),
                           "Peer limit must be a whole number from 1 to 999.")
        }
        var input = valid
        input.downloadSpeedText = " 999999\n"
        input.uploadSpeedText = "1"
        input.peerLimitText = "999"
        input.seedIdleText = "999999"
        input.seedRatioText = "9999"
        XCTAssertNil(draft.validationMessage(for: input, rpcVersion: 18))
    }

    func testRatioRejectsNonfiniteZeroNegativeAndOutOfRangeValues() {
        let draft = makeDraft()
        for ratio in ["nan", "inf", "-inf", "1e400", "0", "-1", "10000", ""] {
            var input = TorrentPropertiesDraft.NumericInput(draft: draft)
            input.seedRatioText = ratio
            XCTAssertEqual(draft.validationMessage(for: input, rpcVersion: 18),
                           "Seed ratio must be greater than 0 and no more than 9999.")
        }
        var input = TorrentPropertiesDraft.NumericInput(draft: draft)
        input.seedRatioText = " \n0.125 "
        XCTAssertNil(draft.validationMessage(for: input, rpcVersion: 18))
    }

    func testDisabledLimitsAndRPCGatesDoNotValidateUnavailableFields() {
        var draft = makeDraft()
        draft.downloadSpeedLimit.isEnabled = false
        draft.uploadSpeedLimit.isEnabled = false
        var input = TorrentPropertiesDraft.NumericInput(draft: draft)
        input.downloadSpeedText = "invalid"
        input.uploadSpeedText = "invalid"
        input.seedRatioText = "invalid"
        input.seedIdleText = "invalid"
        XCTAssertNil(draft.validationMessage(for: input, rpcVersion: 4))
        XCTAssertEqual(draft.validationMessage(for: input, rpcVersion: 5),
                       "Seed ratio must be greater than 0 and no more than 9999.")
        draft.seedRatio.mode = .global
        XCTAssertNil(draft.validationMessage(for: input, rpcVersion: 9))
        XCTAssertEqual(draft.validationMessage(for: input, rpcVersion: 10),
                       "Inactive seeding must be a whole number from 1 to 999999 minutes.")
        draft.seedIdle.mode = .unlimited
        XCTAssertNil(draft.validationMessage(for: input, rpcVersion: 18))
    }

    func testInvalidEditingKeepsPriorDomainValuesAndOnlyChangedFieldsAreUpdated() {
        var draft = makeDraft()
        draft.seedIdle.limit = 2.5
        let previous = TorrentPropertiesDraft.NumericInput(draft: draft)
        var input = previous
        input.downloadSpeedText = "invalid"
        input.uploadSpeedText = "0"
        input.peerLimitText = "42"
        input.seedRatioText = "inf"
        draft.updateNumericValues(from: input, previous: previous)
        XCTAssertEqual(draft.downloadSpeedLimit.limitKBps, 100)
        XCTAssertEqual(draft.uploadSpeedLimit.limitKBps, 200)
        XCTAssertEqual(draft.seedRatio.limit, 2)
        XCTAssertEqual(draft.peerLimit, 42)
        XCTAssertEqual(draft.seedIdle.limit, 2.5)
        var corrected = input
        corrected.downloadSpeedText = " 999999 "
        corrected.uploadSpeedText = "1"
        corrected.seedRatioText = "0.125"
        corrected.seedIdleText = "999999"
        draft.updateNumericValues(from: corrected, previous: input)
        XCTAssertEqual(draft.downloadSpeedLimit.limitKBps, 999_999)
        XCTAssertEqual(draft.uploadSpeedLimit.limitKBps, 1)
        XCTAssertEqual(draft.seedRatio.limit, 0.125)
        XCTAssertEqual(draft.seedIdle.limit, 999_999)
    }

    private func makeDraft() -> TorrentPropertiesDraft {
        TorrentPropertiesSnapshot(
            id: 1,
            downloadSpeedLimit: .init(isEnabled: true, limitKBps: 100),
            uploadSpeedLimit: .init(isEnabled: true, limitKBps: 200),
            peerLimit: 50,
            seedRatio: .init(mode: .single, limit: 2),
            seedIdle: .init(mode: .single, limit: 10)
        ).draft()
    }
}
