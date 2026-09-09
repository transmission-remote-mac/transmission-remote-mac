// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation

indirect enum BencodeValue: Equatable, Sendable {
    case integer(Int64)
    case string(Data)
    case list([BencodeValue])
    case dictionary([Data: BencodeValue])

    var integerValue: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var dataValue: Data? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var utf8StringValue: String? {
        guard case .string(let data) = self else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var listValue: [BencodeValue]? {
        guard case .list(let value) = self else { return nil }
        return value
    }

    var dictionaryValue: [Data: BencodeValue]? {
        guard case .dictionary(let value) = self else { return nil }
        return value
    }

    subscript(key: String) -> BencodeValue? {
        guard case .dictionary(let dictionary) = self else { return nil }
        return dictionary[Data(key.utf8)]
    }
}

enum BencodeParserError: LocalizedError, Equatable {
    case emptyInput
    case unexpectedEnd(position: Int)
    case unexpectedByte(UInt8, position: Int)
    case trailingData(position: Int)
    case invalidInteger(position: Int)
    case invalidStringLength(position: Int)
    case dictionaryKeyNotString(position: Int)
    case duplicateDictionaryKey(position: Int)
    case dictionaryKeysOutOfOrder(position: Int)
    case nestingLimitExceeded(position: Int)
    case nodeLimitExceeded(position: Int)

    var errorDescription: String? {
        switch self {
        case .emptyInput: "Empty bencode input"
        case .unexpectedEnd(let position): "Unexpected end of bencode input at byte \(position)"
        case .unexpectedByte(let byte, let position): "Unexpected bencode byte \(byte) at byte \(position)"
        case .trailingData(let position): "Trailing bencode data at byte \(position)"
        case .invalidInteger(let position): "Invalid bencode integer at byte \(position)"
        case .invalidStringLength(let position): "Invalid bencode string length at byte \(position)"
        case .dictionaryKeyNotString(let position): "Bencode dictionary key is not a string at byte \(position)"
        case .duplicateDictionaryKey(let position): "Duplicate bencode dictionary key at byte \(position)"
        case .dictionaryKeysOutOfOrder(let position): "Bencode dictionary keys are out of order at byte \(position)"
        case .nestingLimitExceeded(let position): "Bencode nesting limit exceeded at byte \(position)"
        case .nodeLimitExceeded(let position): "Bencode node limit exceeded at byte \(position)"
        }
    }
}

struct BencodeParser {
    struct Limits {
        var maximumDepth = 128
        var maximumNodes = 250_000
    }

    static func parse(_ data: Data, limits: Limits = Limits(), checkCancellation: @escaping () throws -> Void = { try Task.checkCancellation() }) throws -> BencodeValue {
        var parser = BencodeParser(bytes: data, limits: limits, checkCancellation: checkCancellation)
        let value = try parser.parseValue(depth: 1)
        try checkCancellation()
        guard parser.offset == parser.bytes.count else {
            throw BencodeParserError.trailingData(position: parser.offset)
        }
        return value
    }

    private let bytes: Data
    private let limits: Limits
    private let checkCancellation: () throws -> Void
    private var offset = 0
    private var nodes = 0

    private mutating func consumeNode() throws {
        try checkCancellation()
        guard nodes < limits.maximumNodes else {
            throw BencodeParserError.nodeLimitExceeded(position: offset)
        }
        nodes += 1
    }

    private mutating func parseValue(depth: Int) throws -> BencodeValue {
        try consumeNode()
        guard depth <= limits.maximumDepth else {
            throw BencodeParserError.nestingLimitExceeded(position: offset)
        }
        guard let byte = peek else {
            throw offset == 0 ? BencodeParserError.emptyInput : BencodeParserError.unexpectedEnd(position: offset)
        }

        switch byte {
        case Byte.i:
            let start = offset
            offset += 1
            return .integer(try parseInteger(startingAt: start))
        case Byte.l:
            offset += 1
            return .list(try parseList(depth: depth))
        case Byte.d:
            offset += 1
            return .dictionary(try parseDictionary(depth: depth))
        case Byte.zero...Byte.nine:
            return .string(try parseString())
        default:
            throw BencodeParserError.unexpectedByte(byte, position: offset)
        }
    }

    private mutating func parseInteger(startingAt start: Int) throws -> Int64 {
        var raw: [UInt8] = []
        while let byte = peek {
            try checkCancellation()
            offset += 1
            if byte == Byte.e {
                return try integer(from: raw, startingAt: start)
            }
            guard raw.count < 20 else {
                throw BencodeParserError.invalidInteger(position: start)
            }
            raw.append(byte)
        }
        throw BencodeParserError.unexpectedEnd(position: offset)
    }

    private func integer(from raw: [UInt8], startingAt start: Int) throws -> Int64 {
        guard !raw.isEmpty else {
            throw BencodeParserError.invalidInteger(position: start)
        }

        let digits: ArraySlice<UInt8>
        if raw[0] == Byte.minus {
            guard raw.count > 1, raw[1] != Byte.zero else {
                throw BencodeParserError.invalidInteger(position: start)
            }
            digits = raw.dropFirst()
        } else {
            guard raw[0] != Byte.zero || raw.count == 1 else {
                throw BencodeParserError.invalidInteger(position: start)
            }
            digits = raw[...]
        }

        guard digits.allSatisfy(Self.isDigit),
              let string = String(bytes: raw, encoding: .ascii),
              let value = Int64(string)
        else {
            throw BencodeParserError.invalidInteger(position: start)
        }
        return value
    }

    private mutating func parseString() throws -> Data {
        let start = offset
        var rawLength: [UInt8] = []
        while let byte = peek, Self.isDigit(byte) {
            try checkCancellation()
            guard rawLength.count < 19 else {
                throw BencodeParserError.invalidStringLength(position: start)
            }
            rawLength.append(byte)
            offset += 1
        }

        guard !rawLength.isEmpty else {
            throw BencodeParserError.invalidStringLength(position: start)
        }
        guard let byte = peek else {
            throw BencodeParserError.unexpectedEnd(position: offset)
        }
        guard byte == Byte.colon else {
            throw BencodeParserError.unexpectedByte(byte, position: offset)
        }
        guard rawLength[0] != Byte.zero || rawLength.count == 1,
              let string = String(bytes: rawLength, encoding: .ascii),
              let length = Int(string)
        else {
            throw BencodeParserError.invalidStringLength(position: start)
        }

        offset += 1
        guard length <= bytes.count - offset else {
            let (end, overflow) = offset.addingReportingOverflow(length)
            throw BencodeParserError.unexpectedEnd(position: overflow ? Int.max : end)
        }

        try checkCancellation()
        let end = offset + length
        let stringData = bytes.subdata(in: (bytes.startIndex + offset)..<(bytes.startIndex + end))
        try checkCancellation()
        offset = end
        return stringData
    }

    private mutating func parseList(depth: Int) throws -> [BencodeValue] {
        var values: [BencodeValue] = []
        while true {
            guard let byte = peek else {
                throw BencodeParserError.unexpectedEnd(position: offset)
            }
            if byte == Byte.e {
                offset += 1
                return values
            }
            values.append(try parseValue(depth: depth + 1))
        }
    }

    private mutating func parseDictionary(depth: Int) throws -> [Data: BencodeValue] {
        var dictionary: [Data: BencodeValue] = [:]
        var previousKey: Data?

        while true {
            guard let byte = peek else {
                throw BencodeParserError.unexpectedEnd(position: offset)
            }
            if byte == Byte.e {
                offset += 1
                return dictionary
            }
            guard Self.isDigit(byte) else {
                throw BencodeParserError.dictionaryKeyNotString(position: offset)
            }

            let keyStart = offset
            try consumeNode()
            let key = try parseString()
            if let previousKey {
                if key == previousKey {
                    throw BencodeParserError.duplicateDictionaryKey(position: keyStart)
                }
                guard previousKey.lexicographicallyPrecedes(key) else {
                    throw BencodeParserError.dictionaryKeysOutOfOrder(position: keyStart)
                }
            }
            previousKey = key
            dictionary[key] = try parseValue(depth: depth + 1)
        }
    }

    private var peek: UInt8? {
        offset < bytes.count ? bytes[bytes.startIndex + offset] : nil
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        (Byte.zero...Byte.nine).contains(byte)
    }

    private enum Byte {
        static let zero = UInt8(ascii: "0")
        static let nine = UInt8(ascii: "9")
        static let colon = UInt8(ascii: ":")
        static let d = UInt8(ascii: "d")
        static let e = UInt8(ascii: "e")
        static let i = UInt8(ascii: "i")
        static let l = UInt8(ascii: "l")
        static let minus = UInt8(ascii: "-")
    }
}
