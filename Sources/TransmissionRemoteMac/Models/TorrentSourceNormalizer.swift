// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

enum TorrentSourceNormalizationError: Error, Equatable {
    case emptySource
    case malformedInfoHash
    case unsupportedSource
}

enum TorrentSourceNormalizer {
    static func normalize(_ source: String) throws -> String {
        let normalizedSource = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSource.isEmpty else {
            throw TorrentSourceNormalizationError.emptySource
        }

        if isMagnet(normalizedSource)
            || isTorrentURL(normalizedSource)
            || isDaemonVisiblePath(normalizedSource) {
            return normalizedSource
        }

        if let magnet = try normalizedInfoHashMagnet(normalizedSource) {
            return magnet
        }
        throw TorrentSourceNormalizationError.unsupportedSource
    }

    private static func normalizedInfoHashMagnet(_ source: String) throws -> String? {
        if source.count == 32 {
            guard isBareInfoHashToken(source), let decodedHash = decodeBase32SHA1(source) else {
                throw TorrentSourceNormalizationError.malformedInfoHash
            }
            return "magnet:?xt=urn:btih:\(decodedHash)"
        }

        if source.count == 40 || source.count == 64 {
            guard isBareInfoHashToken(source), source.unicodeScalars.allSatisfy(isHexadecimal) else {
                throw TorrentSourceNormalizationError.malformedInfoHash
            }
            let lowercaseHash = source.lowercased()
            if source.count == 40 {
                return "magnet:?xt=urn:btih:\(lowercaseHash)"
            }
            return "magnet:?xt=urn:btmh:1220\(lowercaseHash)"
        }

        if looksLikeWrongLengthInfoHash(source) {
            throw TorrentSourceNormalizationError.malformedInfoHash
        }
        return nil
    }

    private static func decodeBase32SHA1(_ source: String) -> String? {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(20)
        var accumulator = 0
        var accumulatedBitCount = 0

        for scalar in source.uppercased().unicodeScalars {
            guard let value = base32Value(for: scalar) else { return nil }
            accumulator = (accumulator << 5) | value
            accumulatedBitCount += 5

            if accumulatedBitCount >= 8 {
                accumulatedBitCount -= 8
                bytes.append(UInt8((accumulator >> accumulatedBitCount) & 0xff))
                accumulator &= accumulatedBitCount == 0 ? 0 : (1 << accumulatedBitCount) - 1
            }
        }

        guard bytes.count == 20, accumulatedBitCount == 0 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func base32Value(for scalar: Unicode.Scalar) -> Int? {
        switch scalar.value {
        case 65...90:
            Int(scalar.value - 65)
        case 50...55:
            Int(scalar.value - 24)
        default:
            nil
        }
    }

    private static func looksLikeWrongLengthInfoHash(_ source: String) -> Bool {
        guard isBareInfoHashToken(source) else { return false }

        let length = source.count
        let isBase32 = source.uppercased().unicodeScalars.allSatisfy { base32Value(for: $0) != nil }
        if isBase32 && (30...34).contains(length) {
            return true
        }

        let isHex = source.unicodeScalars.allSatisfy(isHexadecimal)
        return isHex && ((38...42).contains(length) || (62...66).contains(length))
    }

    private static func isBareInfoHashToken(_ source: String) -> Bool {
        !source.isEmpty && source.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 48...57, 65...90, 97...122:
                true
            default:
                false
            }
        }
    }

    private static func isHexadecimal(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...70, 97...102:
            true
        default:
            false
        }
    }

    private static func isMagnet(_ source: String) -> Bool {
        source.lowercased().hasPrefix("magnet:?")
    }

    private static func isTorrentURL(_ source: String) -> Bool {
        guard let components = URLComponents(string: source),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        return !(components.host ?? "").isEmpty
    }

    private static func isDaemonVisiblePath(_ source: String) -> Bool {
        source.hasPrefix("/")
            || source.hasPrefix("\\\\")
            || source.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
    }
}
