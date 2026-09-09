// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum PortTestIPProtocol: String, CaseIterable, Equatable, Sendable {
    case automatic
    case ipv4
    case ipv6

    var rpcArgumentValue: String? {
        switch self {
        case .automatic: nil
        case .ipv4, .ipv6: rawValue
        }
    }

    func isSupported(rpcVersion: Int) -> Bool {
        switch self {
        case .automatic: rpcVersion >= 5
        case .ipv4, .ipv6: rpcVersion >= 18
        }
    }

    fileprivate init(reportedRPCValue: String) throws {
        guard let value = Self(rawValue: reportedRPCValue), value != .automatic else {
            throw TransmissionRPCError.invalidArguments
        }
        self = value
    }
}

struct PortTestResult: Equatable, Sendable {
    let requestedProtocol: PortTestIPProtocol
    let reportedProtocol: PortTestIPProtocol?
    let isOpen: Bool

    init(
        requestedProtocol: PortTestIPProtocol,
        reportedProtocol: PortTestIPProtocol? = nil,
        isOpen: Bool
    ) throws {
        guard reportedProtocol != .automatic else {
            throw TransmissionRPCError.invalidArguments
        }
        self.requestedProtocol = requestedProtocol
        self.reportedProtocol = reportedProtocol
        self.isOpen = isOpen
    }

    init(requestedProtocol: PortTestIPProtocol, arguments: RPCArguments) throws {
        guard let isOpen = arguments["port-is-open"]?.boolValue else {
            throw TransmissionRPCError.invalidArguments
        }
        let reportedProtocol = try arguments["ip-protocol"].map { value in
            guard let rawValue = value.stringValue else {
                throw TransmissionRPCError.invalidArguments
            }
            return try PortTestIPProtocol(reportedRPCValue: rawValue)
        }
        try self.init(
            requestedProtocol: requestedProtocol,
            reportedProtocol: reportedProtocol,
            isOpen: isOpen
        )
    }
}

struct BlocklistUpdateResult: Equatable, Sendable {
    let entryCount: Int

    init(entryCount: Int) throws {
        guard entryCount >= 0 else {
            throw TransmissionRPCError.invalidArguments
        }
        self.entryCount = entryCount
    }

    init(arguments: RPCArguments) throws {
        guard let value = arguments["blocklist-size"] else {
            throw TransmissionRPCError.invalidArguments
        }
        let entryCount: Int
        switch value {
        case .int(let value):
            entryCount = value
        case .double(let value):
            guard let exactValue = Int(exactly: value) else {
                throw TransmissionRPCError.invalidArguments
            }
            entryCount = exactValue
        default:
            throw TransmissionRPCError.invalidArguments
        }
        try self.init(entryCount: entryCount)
    }
}

enum DaemonMaintenanceNotice: Equatable, Sendable {
    case portTestSucceeded(PortTestResult)
    case portTestFailed(requestedProtocol: PortTestIPProtocol, message: String)
    case blocklistUpdateSucceeded(BlocklistUpdateResult)
    case blocklistUpdateFailed(message: String)

    var title: String {
        switch self {
        case .portTestSucceeded(let result): result.isOpen ? "Port Open" : "Port Closed"
        case .portTestFailed: "Port Test Failed"
        case .blocklistUpdateSucceeded: "Blocklist Updated"
        case .blocklistUpdateFailed: "Blocklist Update Failed"
        }
    }

    var message: String {
        switch self {
        case .portTestSucceeded(let result):
            result.isOpen
                ? "Incoming port is open."
                : "Incoming port is closed. Check your firewall settings."
        case .portTestFailed(_, let message), .blocklistUpdateFailed(let message):
            Self.normalizedFailureMessage(message)
        case .blocklistUpdateSucceeded(let result):
            "The blocklist has been updated successfully. Entries: \(result.entryCount)."
        }
    }

    var isFailure: Bool {
        switch self {
        case .portTestSucceeded(let result): !result.isOpen
        case .blocklistUpdateSucceeded: false
        case .portTestFailed, .blocklistUpdateFailed: true
        }
    }

    private static func normalizedFailureMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Transmission did not complete the maintenance action." : trimmed
    }
}
