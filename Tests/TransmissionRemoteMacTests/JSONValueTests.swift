// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class JSONValueTests: XCTestCase {
    func testUnixDateAccessorRejectsMissingNonFiniteAndUnsupportedTimestamps() {
        for seconds in [
            -1, 0, Double.infinity, -.infinity, .nan, 1e300,
            Double(Int.max), Date.distantFuture.timeIntervalSince1970 + 1,
        ] {
            XCTAssertNil(JSONValue.double(seconds).dateFromUnixTime)
        }
        for value in [JSONValue.null, .bool(true), .string("1700000000"), .int(.max)] {
            XCTAssertNil(value.dateFromUnixTime)
        }
    }

    func testUnixDateAccessorPreservesSupportedIntegerAndFractionalTimestamps() {
        XCTAssertEqual(JSONValue.int(1).dateFromUnixTime, Date(timeIntervalSince1970: 1))
        XCTAssertEqual(
            JSONValue.double(1_700_000_000.25).dateFromUnixTime,
            Date(timeIntervalSince1970: 1_700_000_000.25)
        )
        XCTAssertEqual(
            JSONValue.double(Date.distantFuture.timeIntervalSince1970).dateFromUnixTime,
            Date.distantFuture
        )
    }

    func testIntegerAccessorsRejectFractionalNonFiniteAndOutOfRangeDoubles() {
        for value in [
            JSONValue.double(1.5),
            JSONValue.double(.infinity),
            JSONValue.double(.nan),
            JSONValue.double(Double(Int.max)),
        ] {
            XCTAssertNil(value.intValue)
        }
        XCTAssertEqual(JSONValue.double(42).intValue, 42)
        XCTAssertNil(JSONValue.double(Double(Int64.max)).int64Value)
        XCTAssertEqual(JSONValue.double(42).int64Value, 42)
    }

    func testDecodesMixedObject() throws {
        let data = """
        {
          "id": 7,
          "name": "Ubuntu",
          "percentDone": 0.5,
          "labels": ["linux"],
          "isFinished": false
        }
        """.data(using: .utf8)!

        let value = try JSONDecoder().decode([String: JSONValue].self, from: data)

        XCTAssertEqual(value["id"]?.intValue, 7)
        XCTAssertEqual(value["name"]?.stringValue, "Ubuntu")
        XCTAssertEqual(value["percentDone"]?.doubleValue, 0.5)
        XCTAssertEqual(value["labels"]?.arrayValue?.first?.stringValue, "linux")
        XCTAssertEqual(value["isFinished"]?.boolValue, false)
    }
}
