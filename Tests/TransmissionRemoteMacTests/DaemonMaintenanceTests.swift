// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class DaemonMaintenanceTests: XCTestCase {
    func testPortTestProtocolVersionGates() {
        XCTAssertFalse(PortTestIPProtocol.automatic.isSupported(rpcVersion: 4))
        XCTAssertTrue(PortTestIPProtocol.automatic.isSupported(rpcVersion: 5))
        XCTAssertFalse(PortTestIPProtocol.ipv4.isSupported(rpcVersion: 17))
        XCTAssertFalse(PortTestIPProtocol.ipv6.isSupported(rpcVersion: 17))
        XCTAssertTrue(PortTestIPProtocol.ipv4.isSupported(rpcVersion: 18))
        XCTAssertTrue(PortTestIPProtocol.ipv6.isSupported(rpcVersion: 18))
        XCTAssertNil(PortTestIPProtocol.automatic.rpcArgumentValue)
        XCTAssertEqual(PortTestIPProtocol.ipv4.rpcArgumentValue, "ipv4")
        XCTAssertEqual(PortTestIPProtocol.ipv6.rpcArgumentValue, "ipv6")
    }

    func testSessionMaintenanceCapabilities() {
        let rpc4 = SessionCapabilities(rpcVersion: 4)
        XCTAssertFalse(rpc4.hasPortTest)
        XCTAssertFalse(rpc4.hasBlocklistUpdate)

        let rpc5 = SessionCapabilities(rpcVersion: 5)
        XCTAssertTrue(rpc5.hasPortTest)
        XCTAssertTrue(rpc5.hasBlocklistUpdate)
        XCTAssertFalse(rpc5.hasBlocklistURL)
        XCTAssertFalse(rpc5.hasProtocolSpecificPortTest)

        XCTAssertTrue(SessionCapabilities(rpcVersion: 11).hasBlocklistURL)
        XCTAssertTrue(SessionCapabilities(rpcVersion: 18).hasProtocolSpecificPortTest)
    }

    func testPortTestResultPreservesRequestedAndReportedProtocols() throws {
        let automatic = try PortTestResult(
            requestedProtocol: .automatic,
            arguments: ["port-is-open": .bool(true)]
        )
        XCTAssertEqual(automatic.requestedProtocol, .automatic)
        XCTAssertNil(automatic.reportedProtocol)
        XCTAssertTrue(automatic.isOpen)

        let ipv6 = try PortTestResult(
            requestedProtocol: .ipv6,
            arguments: [
                "port-is-open": .bool(false),
                "ip-protocol": .string("ipv6")
            ]
        )
        XCTAssertEqual(ipv6.requestedProtocol, .ipv6)
        XCTAssertEqual(ipv6.reportedProtocol, .ipv6)
        XCTAssertFalse(ipv6.isOpen)
    }

    func testPortTestResultRejectsMalformedResponse() {
        assertInvalidPortTest(arguments: [:])
        assertInvalidPortTest(arguments: ["port-is-open": .string("yes")])
        assertInvalidPortTest(arguments: [
            "port-is-open": .bool(true),
            "ip-protocol": .string("automatic")
        ])
        assertInvalidPortTest(arguments: [
            "port-is-open": .bool(true),
            "ip-protocol": .string("ipx")
        ])
        XCTAssertThrowsError(
            try PortTestResult(
                requestedProtocol: .automatic,
                reportedProtocol: .automatic,
                isOpen: true
            )
        )
    }

    func testBlocklistUpdateResultValidatesCount() throws {
        XCTAssertEqual(try BlocklistUpdateResult(entryCount: 0).entryCount, 0)
        XCTAssertEqual(
            try BlocklistUpdateResult(arguments: ["blocklist-size": .int(65_536)]).entryCount,
            65_536
        )
        XCTAssertThrowsError(try BlocklistUpdateResult(entryCount: -1))
        XCTAssertThrowsError(try BlocklistUpdateResult(arguments: [:]))
        XCTAssertThrowsError(
            try BlocklistUpdateResult(arguments: ["blocklist-size": .string("65536")])
        )
        XCTAssertThrowsError(
            try BlocklistUpdateResult(arguments: ["blocklist-size": .double(42.5)])
        )
    }

    func testOpenPortNoticeUsesPositiveVisualSemantics() throws {
        let notice = DaemonMaintenanceNotice.portTestSucceeded(
            try PortTestResult(requestedProtocol: .ipv4, reportedProtocol: .ipv4, isOpen: true)
        )
        XCTAssertEqual(notice.title, "Port Open")
        XCTAssertEqual(notice.message, "Incoming port is open.")
        XCTAssertFalse(notice.isFailure)
    }

    func testClosedPortNoticeUsesWarningVisualSemantics() throws {
        let notice = DaemonMaintenanceNotice.portTestSucceeded(
            try PortTestResult(requestedProtocol: .ipv6, reportedProtocol: .ipv6, isOpen: false)
        )
        XCTAssertEqual(notice.title, "Port Closed")
        XCTAssertEqual(notice.message, "Incoming port is closed. Check your firewall settings.")
        XCTAssertTrue(notice.isFailure)
    }

    func testPortTestRPCFailureUsesFailureVisualSemantics() {
        let notice = DaemonMaintenanceNotice.portTestFailed(
            requestedProtocol: .ipv6,
            message: "  "
        )
        XCTAssertEqual(notice.title, "Port Test Failed")
        XCTAssertEqual(notice.message, "Transmission did not complete the maintenance action.")
        XCTAssertTrue(notice.isFailure)
    }

    func testBlocklistSuccessUsesPositiveVisualSemantics() throws {
        let notice = DaemonMaintenanceNotice.blocklistUpdateSucceeded(
            try BlocklistUpdateResult(entryCount: 42)
        )
        XCTAssertEqual(notice.title, "Blocklist Updated")
        XCTAssertEqual(
            notice.message,
            "The blocklist has been updated successfully. Entries: 42."
        )
        XCTAssertFalse(notice.isFailure)
    }

    private func assertInvalidPortTest(
        arguments: RPCArguments,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try PortTestResult(requestedProtocol: .automatic, arguments: arguments),
            file: file,
            line: line
        )
    }
}
