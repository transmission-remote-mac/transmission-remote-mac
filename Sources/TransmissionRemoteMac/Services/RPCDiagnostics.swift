// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import os

enum RPCDiagnosticMethod: String, Sendable {
    case blocklistUpdate = "blocklist-update"
    case freeSpace = "free-space"
    case portTest = "port-test"
    case queueMoveBottom = "queue-move-bottom"
    case queueMoveDown = "queue-move-down"
    case queueMoveTop = "queue-move-top"
    case queueMoveUp = "queue-move-up"
    case sessionGet = "session-get"
    case sessionSet = "session-set"
    case sessionStats = "session-stats"
    case torrentAdd = "torrent-add"
    case torrentGet = "torrent-get"
    case torrentReannounce = "torrent-reannounce"
    case torrentRemove = "torrent-remove"
    case torrentRenamePath = "torrent-rename-path"
    case torrentSet = "torrent-set"
    case torrentSetLocation = "torrent-set-location"
    case torrentStart = "torrent-start"
    case torrentStartNow = "torrent-start-now"
    case torrentStop = "torrent-stop"
    case torrentVerify = "torrent-verify"
    case other

    init(rpcMethod: String) {
        self = Self(rawValue: rpcMethod) ?? .other
    }

    var category: RPCDiagnosticCategory {
        switch self {
        case .sessionGet, .sessionSet, .sessionStats, .blocklistUpdate, .portTest:
            .session
        case .torrentGet:
            .torrentQuery
        case .torrentAdd, .torrentReannounce, .torrentRemove, .torrentRenamePath,
             .torrentSet, .torrentSetLocation, .torrentStart, .torrentStartNow,
             .torrentStop, .torrentVerify:
            .torrentMutation
        case .queueMoveBottom, .queueMoveDown, .queueMoveTop, .queueMoveUp:
            .queue
        case .freeSpace:
            .storage
        case .other:
            .other
        }
    }
}

enum RPCDiagnosticCategory: String, Sendable {
    case session
    case torrentQuery = "torrent-query"
    case torrentMutation = "torrent-mutation"
    case queue
    case storage
    case other
}

enum RPCTransportProtocolCategory: String, Hashable, Sendable {
    case http1 = "http-1"
    case http2 = "http-2"
    case http3 = "http-3"
    case mixed
    case other
    case unavailable

    init(networkProtocolName: String?) {
        guard let networkProtocolName else {
            self = .unavailable
            return
        }
        let normalized = networkProtocolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "http/1", "http/1.0", "http/1.1":
            self = .http1
        case "h2", "http/2", "http/2.0":
            self = .http2
        case "h3", "http/3", "http/3.0":
            self = .http3
        case "":
            self = .unavailable
        default:
            self = normalized.hasPrefix("h3-") ? .http3 : .other
        }
    }

    static func combined(_ categories: [Self]) -> Self {
        let availableCategories = Set(categories.filter { $0 != .unavailable })
        guard let first = availableCategories.first else { return .unavailable }
        return availableCategories.count == 1 ? first : .mixed
    }
}

struct RPCTransportMetrics: Equatable, Sendable {
    var transactionCount: Int
    var redirectCount: Int
    var reusedConnectionCount: Int
    var protocolCategory: RPCTransportProtocolCategory

    static let unavailable = Self(
        transactionCount: 0,
        redirectCount: 0,
        reusedConnectionCount: 0,
        protocolCategory: .unavailable
    )

    func adding(_ other: Self) -> Self {
        Self(
            transactionCount: transactionCount + other.transactionCount,
            redirectCount: redirectCount + other.redirectCount,
            reusedConnectionCount: reusedConnectionCount + other.reusedConnectionCount,
            protocolCategory: .combined([protocolCategory, other.protocolCategory])
        )
    }
}

enum RPCDiagnosticErrorClass: String, Sendable {
    case authentication
    case authorization
    case cancelled
    case httpClient = "http-client"
    case httpRedirect = "http-redirect"
    case httpServer = "http-server"
    case invalidRequest = "invalid-request"
    case malformedResponse = "malformed-response"
    case proxyAuthentication = "proxy-authentication"
    case rpcRejected = "rpc-rejected"
    case sessionNegotiation = "session-negotiation"
    case torrentUnavailable = "torrent-unavailable"
    case transport
    case unsupportedVersion = "unsupported-version"
    case other

    static func normalized(_ error: Error) -> Self {
        if error is CancellationError {
            return .cancelled
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled ? .cancelled : .transport
        }
        if error is EncodingError {
            return .invalidRequest
        }
        guard let rpcError = error as? TransmissionRPCError else {
            return .other
        }

        switch rpcError {
        case .httpStatus(let status, _):
            switch status {
            case 401: return Self.authentication
            case 403: return Self.authorization
            case 407: return Self.proxyAuthentication
            case 300..<400: return Self.httpRedirect
            case 400..<500: return Self.httpClient
            case 500..<600: return Self.httpServer
            default: return Self.other
            }
        case .missingSessionID, .sessionIDRejected:
            return Self.sessionNegotiation
        case .invalidResponse, .missingArguments, .invalidArguments, .malformedJSON:
            return Self.malformedResponse
        case .rpcFailure, .rpcFailureWithArguments:
            return Self.rpcRejected
        case .connectionFailed:
            return Self.transport
        case .unsupportedRPCVersion:
            return Self.unsupportedVersion
        case .torrentNotFound, .missingMagnetLinks:
            return Self.torrentUnavailable
        }
    }
}

struct RPCDiagnosticEvent: Equatable, Sendable {
    var completedAt: Date
    var method: RPCDiagnosticMethod
    var httpAttemptCount: Int
    var requestedFieldCount: Int
    var requestBytes: Int
    var responseBytes: Int
    var durationMilliseconds: Double
    var returnedTorrentRows: Int?
    var sessionChallengeRetryCount: Int
    var errorClass: RPCDiagnosticErrorClass?
    var transportMetrics: RPCTransportMetrics = .unavailable

    var category: RPCDiagnosticCategory { method.category }
    var applicationRequestCount: Int { 1 }
    var transportTransactionCount: Int { transportMetrics.transactionCount }
    var redirectCount: Int { transportMetrics.redirectCount }
    var reusedConnectionCount: Int { transportMetrics.reusedConnectionCount }
    var protocolCategory: RPCTransportProtocolCategory { transportMetrics.protocolCategory }
}

struct RPCDiagnosticsSnapshot: Equatable, Sendable {
    var events: [RPCDiagnosticEvent]
    var applicationRequestCount: Int
    var httpAttemptCount: Int
    var requestBytes: Int
    var responseBytes: Int
    var sessionChallengeRetryCount: Int
    var transportTransactionCount: Int
    var redirectCount: Int
    var reusedConnectionCount: Int
    var protocolCategoryCounts: [RPCTransportProtocolCategory: Int]
}

final class RPCURLSessionTaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var transportMetrics = RPCTransportMetrics.unavailable

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let transactions = metrics.transactionMetrics
        let capturedMetrics = RPCTransportMetrics(
            transactionCount: transactions.count,
            redirectCount: metrics.redirectCount,
            reusedConnectionCount: transactions.filter(\.isReusedConnection).count,
            protocolCategory: .combined(
                transactions.map { RPCTransportProtocolCategory(networkProtocolName: $0.networkProtocolName) }
            )
        )

        lock.lock()
        defer { lock.unlock() }
        transportMetrics = transportMetrics.adding(capturedMetrics)
    }

    func snapshot() -> RPCTransportMetrics {
        lock.lock()
        defer { lock.unlock() }
        return transportMetrics
    }
}

struct RPCDiagnosticTransaction: Sendable {
    private let diagnostics: RPCDiagnostics
    private let method: RPCDiagnosticMethod
    private let requestedFieldCount: Int
    private let startedAt: ContinuousClock.Instant
    private let signpostID: OSSignpostID
    private var httpAttemptCount = 0
    private var requestBytes = 0
    private var responseBytes = 0
    private var sessionChallengeRetryCount = 0
    private var transportMetrics = RPCTransportMetrics.unavailable
    private var isCompleted = false

    var semanticMethod: RPCDiagnosticMethod { method }

    fileprivate init(
        diagnostics: RPCDiagnostics,
        method: RPCDiagnosticMethod,
        requestedFieldCount: Int,
        signpostID: OSSignpostID
    ) {
        self.diagnostics = diagnostics
        self.method = method
        self.requestedFieldCount = requestedFieldCount
        self.startedAt = ContinuousClock().now
        self.signpostID = signpostID
    }

    mutating func beginHTTPAttempt(requestBytes: Int) {
        httpAttemptCount += 1
        self.requestBytes += max(0, requestBytes)
    }

    mutating func receiveResponse(bytes: Int) {
        responseBytes += max(0, bytes)
    }

    mutating func recordSessionChallengeRetry() {
        sessionChallengeRetryCount += 1
    }

    mutating func recordTransportMetrics(_ metrics: RPCTransportMetrics) {
        transportMetrics = transportMetrics.adding(metrics)
    }

    mutating func finish(returnedTorrentRows: Int? = nil, error: Error? = nil) {
        guard !isCompleted else { return }
        isCompleted = true

        let duration = startedAt.duration(to: ContinuousClock().now).components
        let durationMilliseconds = Double(duration.seconds) * 1_000
            + Double(duration.attoseconds) / 1_000_000_000_000_000
        diagnostics.record(
            RPCDiagnosticEvent(
                completedAt: Date(),
                method: method,
                httpAttemptCount: httpAttemptCount,
                requestedFieldCount: requestedFieldCount,
                requestBytes: requestBytes,
                responseBytes: responseBytes,
                durationMilliseconds: durationMilliseconds,
                returnedTorrentRows: returnedTorrentRows,
                sessionChallengeRetryCount: sessionChallengeRetryCount,
                errorClass: error.map(RPCDiagnosticErrorClass.normalized),
                transportMetrics: transportMetrics
            ),
            signpostID: signpostID
        )
    }
}

final class RPCDiagnostics: @unchecked Sendable {
    static let shared = RPCDiagnostics()

    private static let logger = Logger(
        subsystem: "net.pokwer.TransmissionRemoteMac",
        category: "RPC"
    )
    private static let signpostLog = OSLog(
        subsystem: "net.pokwer.TransmissionRemoteMac",
        category: "RPC"
    )

    private let capacity: Int
    private let lock = NSLock()
    private var events: [RPCDiagnosticEvent] = []
    private var applicationRequestCount = 0
    private var httpAttemptCount = 0
    private var requestBytes = 0
    private var responseBytes = 0
    private var sessionChallengeRetryCount = 0
    private var transportTransactionCount = 0
    private var redirectCount = 0
    private var reusedConnectionCount = 0
    private var protocolCategoryCounts: [RPCTransportProtocolCategory: Int] = [:]

    init(capacity: Int = 200) {
        self.capacity = max(1, capacity)
    }

    func begin(method rpcMethod: String, requestedFieldCount: Int) -> RPCDiagnosticTransaction {
        let signpostID = OSSignpostID(log: Self.signpostLog)
        os_signpost(
            .begin,
            log: Self.signpostLog,
            name: "RPC request",
            signpostID: signpostID
        )
        return RPCDiagnosticTransaction(
            diagnostics: self,
            method: RPCDiagnosticMethod(rpcMethod: rpcMethod),
            requestedFieldCount: max(0, requestedFieldCount),
            signpostID: signpostID
        )
    }

    func record(_ event: RPCDiagnosticEvent, signpostID: OSSignpostID? = nil) {
        if let signpostID {
            os_signpost(
                .end,
                log: Self.signpostLog,
                name: "RPC request",
                signpostID: signpostID
            )
        }

        lock.lock()
        do {
            defer { lock.unlock() }
            events.append(event)
            applicationRequestCount += 1
            httpAttemptCount += event.httpAttemptCount
            requestBytes += event.requestBytes
            responseBytes += event.responseBytes
            sessionChallengeRetryCount += event.sessionChallengeRetryCount
            transportTransactionCount += event.transportTransactionCount
            redirectCount += event.redirectCount
            reusedConnectionCount += event.reusedConnectionCount
            protocolCategoryCounts[event.protocolCategory, default: 0] += 1
            if events.count > capacity {
                events.removeFirst(events.count - capacity)
            }
        }

        if let errorClass = event.errorClass {
            Self.logger.error(
                "RPC \(event.method.rawValue, privacy: .public) category=\(event.category.rawValue, privacy: .public) error=\(errorClass.rawValue, privacy: .public) attempts=\(event.httpAttemptCount, privacy: .public) retries=\(event.sessionChallengeRetryCount, privacy: .public) transactions=\(event.transportTransactionCount, privacy: .public) redirects=\(event.redirectCount, privacy: .public) reused=\(event.reusedConnectionCount, privacy: .public) protocol=\(event.protocolCategory.rawValue, privacy: .public) duration_ms=\(event.durationMilliseconds, privacy: .public)"
            )
        } else {
            Self.logger.debug(
                "RPC \(event.method.rawValue, privacy: .public) category=\(event.category.rawValue, privacy: .public) attempts=\(event.httpAttemptCount, privacy: .public) fields=\(event.requestedFieldCount, privacy: .public) request_bytes=\(event.requestBytes, privacy: .public) response_bytes=\(event.responseBytes, privacy: .public) transactions=\(event.transportTransactionCount, privacy: .public) redirects=\(event.redirectCount, privacy: .public) reused=\(event.reusedConnectionCount, privacy: .public) protocol=\(event.protocolCategory.rawValue, privacy: .public) duration_ms=\(event.durationMilliseconds, privacy: .public)"
            )
        }
    }

    func snapshot() -> RPCDiagnosticsSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RPCDiagnosticsSnapshot(
            events: events,
            applicationRequestCount: applicationRequestCount,
            httpAttemptCount: httpAttemptCount,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            sessionChallengeRetryCount: sessionChallengeRetryCount,
            transportTransactionCount: transportTransactionCount,
            redirectCount: redirectCount,
            reusedConnectionCount: reusedConnectionCount,
            protocolCategoryCounts: protocolCategoryCounts
        )
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        events.removeAll(keepingCapacity: true)
        applicationRequestCount = 0
        httpAttemptCount = 0
        requestBytes = 0
        responseBytes = 0
        sessionChallengeRetryCount = 0
        transportTransactionCount = 0
        redirectCount = 0
        reusedConnectionCount = 0
        protocolCategoryCounts.removeAll(keepingCapacity: true)
    }
}
