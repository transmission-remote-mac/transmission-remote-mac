// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum RemotePOSIXDestinationValidationError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case notAbsolute
    case containsNullByte

    var errorDescription: String? {
        switch self {
        case .empty:
            "The remote destination cannot be empty."
        case .notAbsolute:
            "The remote destination must be an absolute POSIX path."
        case .containsNullByte:
            "The remote destination cannot contain a null byte."
        }
    }
}

enum RemotePOSIXDestinationValidator {
    /// Validates an absolute path for the remote daemon and returns it byte-for-byte.
    ///
    /// The daemon owns path semantics, so this deliberately does not trim whitespace,
    /// collapse separators, standardize dot components, expand tildes, resolve links
    /// or normalize Unicode.
    static func validated(_ destination: String) throws -> String {
        guard !destination.isEmpty else {
            throw RemotePOSIXDestinationValidationError.empty
        }
        guard destination.first == "/" else {
            throw RemotePOSIXDestinationValidationError.notAbsolute
        }
        guard !destination.unicodeScalars.contains(where: { $0.value == 0 }) else {
            throw RemotePOSIXDestinationValidationError.containsNullByte
        }
        return destination
    }
}
