// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

enum DaemonOptionsApplyRejection: Equatable, Sendable {
    case notConnected
    case applyInProgress
    case maintenanceInProgress
    case connectionChanged

    var message: String {
        switch self {
        case .notConnected:
            "Transmission is not connected."
        case .applyInProgress:
            "Daemon options are already being applied."
        case .maintenanceInProgress:
            "Finish the active daemon maintenance operation before applying options."
        case .connectionChanged:
            "The Transmission connection changed before the daemon options update completed."
        }
    }
}

enum DaemonOptionsApplyResult: Equatable, Sendable {
    case succeeded
    case rejected(DaemonOptionsApplyRejection)
    case failed(String)

    var message: String {
        switch self {
        case .succeeded:
            "Daemon options applied."
        case .rejected(let rejection):
            rejection.message
        case .failed(let message):
            message
        }
    }

    var isFailure: Bool {
        switch self {
        case .succeeded:
            false
        case .rejected, .failed:
            true
        }
    }
}
