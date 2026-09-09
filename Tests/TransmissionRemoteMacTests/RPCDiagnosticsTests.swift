// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class RPCDiagnosticsTests: XCTestCase {
    func testSnapshotIsBoundedAndAggregatesRetainedEvents() {
        let diagnostics = RPCDiagnostics(capacity: 2)
        diagnostics.record(event(method: .sessionGet, attempts: 1, requestBytes: 20, responseBytes: 40))
        diagnostics.record(
            event(
                method: .torrentGet,
                attempts: 2,
                requestBytes: 100,
                responseBytes: 200,
                retries: 1,
                transportMetrics: RPCTransportMetrics(
                    transactionCount: 2,
                    redirectCount: 1,
                    reusedConnectionCount: 1,
                    protocolCategory: .http2
                )
            )
        )
        diagnostics.record(
            event(
                method: .torrentSet,
                attempts: 1,
                requestBytes: 50,
                responseBytes: 30,
                transportMetrics: RPCTransportMetrics(
                    transactionCount: 1,
                    redirectCount: 0,
                    reusedConnectionCount: 1,
                    protocolCategory: .http2
                )
            )
        )

        let snapshot = diagnostics.snapshot()

        XCTAssertEqual(snapshot.events.map(\.method), [.torrentGet, .torrentSet])
        XCTAssertEqual(snapshot.applicationRequestCount, 3)
        XCTAssertEqual(snapshot.httpAttemptCount, 4)
        XCTAssertEqual(snapshot.requestBytes, 170)
        XCTAssertEqual(snapshot.responseBytes, 270)
        XCTAssertEqual(snapshot.sessionChallengeRetryCount, 1)
        XCTAssertEqual(snapshot.transportTransactionCount, 3)
        XCTAssertEqual(snapshot.redirectCount, 1)
        XCTAssertEqual(snapshot.reusedConnectionCount, 2)
        XCTAssertEqual(snapshot.protocolCategoryCounts[.unavailable], 1)
        XCTAssertEqual(snapshot.protocolCategoryCounts[.http2], 2)
    }

    func testTaskMetricsCollectorDefaultsWhenURLSessionProvidesNoMetrics() {
        let metrics = RPCURLSessionTaskMetricsCollector().snapshot()

        XCTAssertEqual(metrics, .unavailable)
    }

    func testTransportMetricsAggregateAcrossHTTPAttempts() {
        let firstAttempt = RPCTransportMetrics(
            transactionCount: 1,
            redirectCount: 0,
            reusedConnectionCount: 0,
            protocolCategory: .http1
        )
        let retryAttempt = RPCTransportMetrics(
            transactionCount: 2,
            redirectCount: 1,
            reusedConnectionCount: 1,
            protocolCategory: .http2
        )

        XCTAssertEqual(
            firstAttempt.adding(retryAttempt),
            RPCTransportMetrics(
                transactionCount: 3,
                redirectCount: 1,
                reusedConnectionCount: 1,
                protocolCategory: .mixed
            )
        )
    }

    func testTransportProtocolCategoryIsNormalizedAndRedacted() {
        XCTAssertEqual(RPCTransportProtocolCategory(networkProtocolName: "http/1.1"), .http1)
        XCTAssertEqual(RPCTransportProtocolCategory(networkProtocolName: "h2"), .http2)
        XCTAssertEqual(RPCTransportProtocolCategory(networkProtocolName: "h3-29"), .http3)
        XCTAssertEqual(RPCTransportProtocolCategory(networkProtocolName: "private-protocol-value"), .other)
        XCTAssertEqual(RPCTransportProtocolCategory(networkProtocolName: nil), .unavailable)
        XCTAssertEqual(RPCTransportProtocolCategory.combined([.unavailable, .http2]), .http2)
        XCTAssertEqual(RPCTransportProtocolCategory.combined([.http1, .http2]), .mixed)
    }

    func testMethodClassificationNeverRetainsUnknownMethodText() {
        let method = RPCDiagnosticMethod(rpcMethod: "torrent-get?endpoint=secret")

        XCTAssertEqual(method, .other)
        XCTAssertEqual(method.rawValue, "other")
        XCTAssertEqual(method.category, .other)
        XCTAssertEqual(RPCDiagnosticMethod(rpcMethod: "torrent-get").category, .torrentQuery)
        XCTAssertEqual(RPCDiagnosticMethod(rpcMethod: "torrent-start").category, .torrentMutation)
        XCTAssertEqual(RPCDiagnosticMethod(rpcMethod: "port-test"), .portTest)
        XCTAssertEqual(RPCDiagnosticMethod(rpcMethod: "blocklist-update"), .blocklistUpdate)
        XCTAssertEqual(RPCDiagnosticMethod.portTest.category, .session)
        XCTAssertEqual(RPCDiagnosticMethod.blocklistUpdate.category, .session)
    }

    func testErrorNormalizationDoesNotRetainServerMessages() {
        XCTAssertEqual(
            RPCDiagnosticErrorClass.normalized(TransmissionRPCError.httpStatus(401, "private response")),
            .authentication
        )
        XCTAssertEqual(
            RPCDiagnosticErrorClass.normalized(TransmissionRPCError.rpcFailure("private response")),
            .rpcRejected
        )
        XCTAssertEqual(
            RPCDiagnosticErrorClass.normalized(
                TransmissionRPCError.rpcFailureWithArguments(
                    "private response",
                    ["ip-protocol": .string("ipv6")]
                )
            ),
            .rpcRejected
        )
        XCTAssertEqual(
            RPCDiagnosticErrorClass.normalized(TransmissionRPCError.connectionFailed("private endpoint")),
            .transport
        )
        XCTAssertEqual(RPCDiagnosticErrorClass.normalized(CancellationError()), .cancelled)
    }

    private func event(
        method: RPCDiagnosticMethod,
        attempts: Int,
        requestBytes: Int,
        responseBytes: Int,
        retries: Int = 0,
        transportMetrics: RPCTransportMetrics = .unavailable
    ) -> RPCDiagnosticEvent {
        RPCDiagnosticEvent(
            completedAt: Date(timeIntervalSince1970: 1),
            method: method,
            httpAttemptCount: attempts,
            requestedFieldCount: 0,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            durationMilliseconds: 1,
            returnedTorrentRows: nil,
            sessionChallengeRetryCount: retries,
            errorClass: nil,
            transportMetrics: transportMetrics
        )
    }
}
