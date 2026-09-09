// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Combine
import Foundation

struct PeerCountryDatabaseMetadata: Codable, Equatable, Sendable {
    static let sourceURL = URL(string: "https://db-ip.com/db/download/ip-to-country-lite")!

    var sourceFileName: String
    var databaseDate: Date?
    var importedAt: Date
    var rangeCount: Int
}

enum PeerCountryDatabaseStorageContract {
    static let ipv4RecordByteCount = 10
    static let ipv6RecordByteCount = 34
    static let maximumRangeCount = 2_000_000
    static let maximumPackedByteCount = maximumRangeCount * ipv6RecordByteCount
    static let streamReadByteCount = 64 * 1_024
    static let maximumCSVLineByteCount = 1_024
    static let maximumSourceByteCount = 512 * 1_024 * 1_024
}

/// A compact, immutable country index. Ranges are fixed-width packed bytes,
/// never millions of Swift objects or per-address arrays. Disk loads keep the
/// encoded file mapped and binary search records in place.
struct PeerCountryDatabase: Equatable, Sendable {
    let metadata: PeerCountryDatabaseMetadata
    let ipv4RangeCount: Int
    let ipv6RangeCount: Int

    private let ipv4Storage: Data
    private let ipv6Storage: Data
    private let ipv4Offset: Int
    private let ipv6Offset: Int

    var packedByteCount: Int {
        ipv4RangeCount * PeerCountryDatabaseStorageContract.ipv4RecordByteCount
            + ipv6RangeCount * PeerCountryDatabaseStorageContract.ipv6RecordByteCount
    }

    /// Logical resident payload. Stream imports retain exactly these packed
    /// buffers; mapped disk loads retain shared views of one encoded mapping.
    var storageByteCount: Int { packedByteCount }

    init(
        metadata: PeerCountryDatabaseMetadata,
        ipv4Records: Data,
        ipv6Records: Data
    ) throws {
        guard ipv4Records.count % PeerCountryDatabaseStorageContract.ipv4RecordByteCount == 0,
              ipv6Records.count % PeerCountryDatabaseStorageContract.ipv6RecordByteCount == 0 else {
            throw PeerCountryDatabaseError.invalidPackedStorage
        }
        try self.init(
            metadata: metadata,
            ipv4Storage: ipv4Records,
            ipv4Offset: 0,
            ipv4RangeCount: ipv4Records.count
                / PeerCountryDatabaseStorageContract.ipv4RecordByteCount,
            ipv6Storage: ipv6Records,
            ipv6Offset: 0,
            ipv6RangeCount: ipv6Records.count
                / PeerCountryDatabaseStorageContract.ipv6RecordByteCount
        )
    }

    init(
        metadata: PeerCountryDatabaseMetadata,
        ipv4Storage: Data,
        ipv4Offset: Int,
        ipv4RangeCount: Int,
        ipv6Storage: Data,
        ipv6Offset: Int,
        ipv6RangeCount: Int
    ) throws {
        let totalCount = ipv4RangeCount + ipv6RangeCount
        guard totalCount > 0,
              totalCount <= PeerCountryDatabaseStorageContract.maximumRangeCount,
              metadata.rangeCount == totalCount else {
            throw PeerCountryDatabaseError.invalidRangeCount
        }
        let ipv4Bytes = try Self.checkedByteCount(
            count: ipv4RangeCount,
            width: PeerCountryDatabaseStorageContract.ipv4RecordByteCount
        )
        let ipv6Bytes = try Self.checkedByteCount(
            count: ipv6RangeCount,
            width: PeerCountryDatabaseStorageContract.ipv6RecordByteCount
        )
        guard ipv4Offset >= 0,
              ipv4Offset + ipv4Bytes <= ipv4Storage.count,
              ipv6Offset >= 0,
              ipv6Offset + ipv6Bytes <= ipv6Storage.count,
              ipv4Bytes + ipv6Bytes <= PeerCountryDatabaseStorageContract.maximumPackedByteCount else {
            throw PeerCountryDatabaseError.invalidPackedStorage
        }
        self.metadata = metadata
        self.ipv4Storage = ipv4Storage
        self.ipv6Storage = ipv6Storage
        self.ipv4Offset = ipv4Offset
        self.ipv4RangeCount = ipv4RangeCount
        self.ipv6Offset = ipv6Offset
        self.ipv6RangeCount = ipv6RangeCount
        try validatePackedRecords()
    }

    func countryCode(for address: PeerIPAddress) -> String? {
        switch address.family {
        case .ipv4:
            lookup(
                address: address,
                storage: ipv4Storage,
                rangeOffset: ipv4Offset,
                rangeCount: ipv4RangeCount,
                recordWidth: PeerCountryDatabaseStorageContract.ipv4RecordByteCount
            )
        case .ipv6:
            lookup(
                address: address,
                storage: ipv6Storage,
                rangeOffset: ipv6Offset,
                rangeCount: ipv6RangeCount,
                recordWidth: PeerCountryDatabaseStorageContract.ipv6RecordByteCount
            )
        }
    }

    static func == (lhs: PeerCountryDatabase, rhs: PeerCountryDatabase) -> Bool {
        lhs.metadata == rhs.metadata
            && lhs.ipv4RangeCount == rhs.ipv4RangeCount
            && lhs.ipv6RangeCount == rhs.ipv6RangeCount
            && lhs.packedData(for: .ipv4) == rhs.packedData(for: .ipv4)
            && lhs.packedData(for: .ipv6) == rhs.packedData(for: .ipv6)
    }

    private func lookup(
        address: PeerIPAddress,
        storage: Data,
        rangeOffset: Int,
        rangeCount: Int,
        recordWidth: Int
    ) -> String? {
        storage.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let addressByteCount = address.bytes.count
            var lower = 0
            var upper = rangeCount
            while lower < upper {
                let midpoint = lower + (upper - lower) / 2
                let record = baseAddress.advanced(by: rangeOffset + midpoint * recordWidth)
                if Self.compare(address.bytes, to: record, count: addressByteCount) >= 0 {
                    lower = midpoint + 1
                } else {
                    upper = midpoint
                }
            }
            guard lower > 0 else { return nil }
            let record = baseAddress.advanced(by: rangeOffset + (lower - 1) * recordWidth)
            let upperBound = record.advanced(by: addressByteCount)
            guard Self.compare(address.bytes, to: upperBound, count: addressByteCount) <= 0 else {
                return nil
            }
            let country = record.advanced(by: addressByteCount * 2)
            return String(bytes: [country[0], country[1]], encoding: .ascii)
        }
    }

    fileprivate func writePackedRecords(to handle: FileHandle) throws {
        let ipv4ByteCount = ipv4RangeCount
            * PeerCountryDatabaseStorageContract.ipv4RecordByteCount
        let ipv6ByteCount = ipv6RangeCount
            * PeerCountryDatabaseStorageContract.ipv6RecordByteCount
        try handle.write(contentsOf: ipv4Storage[ipv4Offset ..< ipv4Offset + ipv4ByteCount])
        try handle.write(contentsOf: ipv6Storage[ipv6Offset ..< ipv6Offset + ipv6ByteCount])
    }

    private func validatePackedRecords() throws {
        try ipv4Storage.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                if ipv4RangeCount == 0 { return }
                throw PeerCountryDatabaseError.invalidPackedStorage
            }
            try Self.validateFamily(
                baseAddress: baseAddress,
                offset: ipv4Offset,
                count: ipv4RangeCount,
                addressByteCount: 4,
                recordWidth: PeerCountryDatabaseStorageContract.ipv4RecordByteCount
            )
        }
        try ipv6Storage.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                if ipv6RangeCount == 0 { return }
                throw PeerCountryDatabaseError.invalidPackedStorage
            }
            try Self.validateFamily(
                baseAddress: baseAddress,
                offset: ipv6Offset,
                count: ipv6RangeCount,
                addressByteCount: 16,
                recordWidth: PeerCountryDatabaseStorageContract.ipv6RecordByteCount
            )
        }
    }

    private func packedData(for family: PeerIPAddressFamily) -> Data.SubSequence {
        switch family {
        case .ipv4:
            let byteCount = ipv4RangeCount
                * PeerCountryDatabaseStorageContract.ipv4RecordByteCount
            return ipv4Storage[ipv4Offset ..< ipv4Offset + byteCount]
        case .ipv6:
            let byteCount = ipv6RangeCount
                * PeerCountryDatabaseStorageContract.ipv6RecordByteCount
            return ipv6Storage[ipv6Offset ..< ipv6Offset + byteCount]
        }
    }

    private static func validateFamily(
        baseAddress: UnsafePointer<UInt8>,
        offset: Int,
        count: Int,
        addressByteCount: Int,
        recordWidth: Int
    ) throws {
        var previousUpperBound: UnsafePointer<UInt8>?
        for index in 0 ..< count {
            let record = baseAddress.advanced(by: offset + index * recordWidth)
            let upperBound = record.advanced(by: addressByteCount)
            guard compare(record, to: upperBound, count: addressByteCount) <= 0 else {
                throw PeerCountryDatabaseError.invalidPackedStorage
            }
            if let previousUpperBound,
               compare(record, to: previousUpperBound, count: addressByteCount) <= 0 {
                throw PeerCountryDatabaseError.overlappingOrUnsortedRanges
            }
            let country = record.advanced(by: addressByteCount * 2)
            guard (65 ... 90).contains(country[0]), (65 ... 90).contains(country[1]) else {
                throw PeerCountryDatabaseError.invalidPackedStorage
            }
            previousUpperBound = upperBound
        }
    }

    private static func compare(
        _ lhs: [UInt8],
        to rhs: UnsafePointer<UInt8>,
        count: Int
    ) -> Int {
        lhs.withUnsafeBufferPointer { lhsBuffer in
            compare(lhsBuffer.baseAddress!, to: rhs, count: count)
        }
    }

    private static func compare(
        _ lhs: UnsafePointer<UInt8>,
        to rhs: UnsafePointer<UInt8>,
        count: Int
    ) -> Int {
        for index in 0 ..< count {
            if lhs[index] < rhs[index] { return -1 }
            if lhs[index] > rhs[index] { return 1 }
        }
        return 0
    }

    private static func checkedByteCount(count: Int, width: Int) throws -> Int {
        let result = count.multipliedReportingOverflow(by: width)
        guard !result.overflow else { throw PeerCountryDatabaseError.invalidPackedStorage }
        return result.partialValue
    }
}

enum PeerCountryDatabaseError: LocalizedError, Equatable {
    case sourceTooLarge
    case lineTooLong(line: Int)
    case invalidEncoding(line: Int)
    case emptySource
    case malformedCSV(line: Int)
    case invalidIPAddress(line: Int)
    case mixedAddressFamilies(line: Int)
    case invalidCountryCode(line: Int)
    case reversedRange(line: Int)
    case overlappingOrUnsortedRanges
    case invalidRangeCount
    case invalidPackedStorage
    case unsupportedSchemaVersion(Int)

    var errorDescription: String? {
        switch self {
        case .sourceTooLarge:
            "The country database CSV is larger than the supported 512 MB limit."
        case .lineTooLong(let line):
            "The country database CSV line \(line) exceeds the supported 1,024-byte row limit."
        case .invalidEncoding(let line):
            "The country database CSV contains invalid UTF-8 at line \(line)."
        case .emptySource:
            "The country database CSV contains no ranges."
        case .malformedCSV(let line):
            "Line \(line) is not a DB-IP Country Lite row in \"start IP\", \"end IP\", \"two-letter country code\" CSV format."
        case .invalidIPAddress(let line):
            "The country database contains an invalid IP address at line \(line)."
        case .mixedAddressFamilies(let line):
            "The country database mixes IPv4 and IPv6 in one range at line \(line)."
        case .invalidCountryCode(let line):
            "The country database contains an invalid two-letter country code at line \(line)."
        case .reversedRange(let line):
            "The country database contains a reversed IP range at line \(line)."
        case .overlappingOrUnsortedRanges:
            "The country database ranges must be sorted by start IP and must not overlap."
        case .invalidRangeCount:
            "The country database contains no ranges or exceeds the supported range limit."
        case .invalidPackedStorage:
            "The stored country database is not a valid packed range index."
        case .unsupportedSchemaVersion(let version):
            "The stored country database schema is not supported: \(version)."
        }
    }
}

enum PeerCountryCSVImporter {
    static func parse(
        data: Data,
        sourceFileName: String,
        importedAt: Date = Date()
    ) throws -> PeerCountryDatabase {
        try Task.checkCancellation()
        var parser = IncrementalParser(sourceFileName: sourceFileName, importedAt: importedAt)
        var offset = 0
        while offset < data.count {
            try Task.checkCancellation()
            let end = min(offset + PeerCountryDatabaseStorageContract.streamReadByteCount, data.count)
            try parser.consume(data[offset ..< end])
            offset = end
        }
        return try parser.finish()
    }

    static func parse(
        sourceURL: URL,
        sourceFileName: String? = nil,
        importedAt: Date = Date(),
        checkOperation: () throws -> Void = {}
    ) throws -> PeerCountryDatabase {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        var parser = IncrementalParser(
            sourceFileName: sourceFileName ?? sourceURL.lastPathComponent,
            importedAt: importedAt
        )
        while let chunk = try handle.read(upToCount: PeerCountryDatabaseStorageContract.streamReadByteCount),
              !chunk.isEmpty {
            try Task.checkCancellation()
            try checkOperation()
            try parser.consume(chunk)
        }
        return try parser.finish()
    }

    private struct IncrementalParser {
        var sourceFileName: String
        var importedAt: Date
        var ipv4Records = Data()
        var ipv6Records = Data()
        var lineBuffer: [UInt8] = []
        var sourceByteCount = 0
        var lineNumber = 1
        var parsedRangeCount = 0
        var lastIPv4UpperBound: [UInt8]?
        var lastIPv6UpperBound: [UInt8]?

        mutating func consume<C: Collection>(_ bytes: C) throws where C.Element == UInt8 {
            sourceByteCount += bytes.count
            guard sourceByteCount <= PeerCountryDatabaseStorageContract.maximumSourceByteCount else {
                throw PeerCountryDatabaseError.sourceTooLarge
            }
            for byte in bytes {
                if byte == 0x0a {
                    try consumeBufferedLine()
                    lineNumber += 1
                    lineBuffer.removeAll(keepingCapacity: true)
                } else {
                    lineBuffer.append(byte)
                    guard lineBuffer.count <= PeerCountryDatabaseStorageContract.maximumCSVLineByteCount else {
                        throw PeerCountryDatabaseError.lineTooLong(line: lineNumber)
                    }
                }
            }
        }

        mutating func finish() throws -> PeerCountryDatabase {
            if !lineBuffer.isEmpty { try consumeBufferedLine() }
            guard parsedRangeCount > 0 else { throw PeerCountryDatabaseError.emptySource }
            return try PeerCountryDatabase(
                metadata: PeerCountryDatabaseMetadata(
                    sourceFileName: sourceFileName,
                    databaseDate: PeerCountryCSVImporter.inferredDatabaseDate(from: sourceFileName),
                    importedAt: importedAt,
                    rangeCount: parsedRangeCount
                ),
                ipv4Records: ipv4Records,
                ipv6Records: ipv6Records
            )
        }

        private mutating func consumeBufferedLine() throws {
            var bytes = lineBuffer
            if bytes.last == 0x0d { bytes.removeLast() }
            if lineNumber == 1, bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
            guard !bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { return }
            guard let line = String(bytes: bytes, encoding: .utf8) else {
                throw PeerCountryDatabaseError.invalidEncoding(line: lineNumber)
            }
            let fields = try PeerCountryCSVImporter.parseCSVLine(line, lineNumber: lineNumber)
            if parsedRangeCount == 0, PeerCountryCSVImporter.isHeader(fields) { return }
            guard fields.count == 3 else {
                throw PeerCountryDatabaseError.malformedCSV(line: lineNumber)
            }
            guard let lowerBound = PeerIPAddress(parsing: fields[0]),
                  let upperBound = PeerIPAddress(parsing: fields[1]) else {
                throw PeerCountryDatabaseError.invalidIPAddress(line: lineNumber)
            }
            guard lowerBound.family == upperBound.family else {
                throw PeerCountryDatabaseError.mixedAddressFamilies(line: lineNumber)
            }
            guard lowerBound <= upperBound else {
                throw PeerCountryDatabaseError.reversedRange(line: lineNumber)
            }
            let countryCode = PeerCountryPresentation.normalizedCountryCode(fields[2])
            guard countryCode.utf8.count == 2,
                  countryCode.utf8.allSatisfy({ (65 ... 90).contains($0) }) else {
                throw PeerCountryDatabaseError.invalidCountryCode(line: lineNumber)
            }
            try append(lowerBound: lowerBound, upperBound: upperBound, countryCode: countryCode)
            parsedRangeCount += 1
            guard parsedRangeCount <= PeerCountryDatabaseStorageContract.maximumRangeCount else {
                throw PeerCountryDatabaseError.invalidRangeCount
            }
        }

        private mutating func append(
            lowerBound: PeerIPAddress,
            upperBound: PeerIPAddress,
            countryCode: String
        ) throws {
            switch lowerBound.family {
            case .ipv4:
                if let lastIPv4UpperBound,
                   !lastIPv4UpperBound.lexicographicallyPrecedes(lowerBound.bytes) {
                    throw PeerCountryDatabaseError.overlappingOrUnsortedRanges
                }
                ipv4Records.append(contentsOf: lowerBound.bytes)
                ipv4Records.append(contentsOf: upperBound.bytes)
                ipv4Records.append(contentsOf: countryCode.utf8)
                lastIPv4UpperBound = upperBound.bytes
            case .ipv6:
                if let lastIPv6UpperBound,
                   !lastIPv6UpperBound.lexicographicallyPrecedes(lowerBound.bytes) {
                    throw PeerCountryDatabaseError.overlappingOrUnsortedRanges
                }
                ipv6Records.append(contentsOf: lowerBound.bytes)
                ipv6Records.append(contentsOf: upperBound.bytes)
                ipv6Records.append(contentsOf: countryCode.utf8)
                lastIPv6UpperBound = upperBound.bytes
            }
        }
    }

    private static func parseCSVLine(_ line: String, lineNumber: Int) throws -> [String] {
        var fields: [String] = []
        var field = ""
        var isQuoted = false
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" {
                let next = line.index(after: index)
                if isQuoted, next < line.endIndex, line[next] == "\"" {
                    field.append("\"")
                    index = line.index(after: next)
                    continue
                }
                isQuoted.toggle()
            } else if character == ",", !isQuoted {
                fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
                field = ""
            } else {
                field.append(character)
            }
            index = line.index(after: index)
        }
        guard !isQuoted else {
            throw PeerCountryDatabaseError.malformedCSV(line: lineNumber)
        }
        fields.append(field.trimmingCharacters(in: .whitespacesAndNewlines))
        return fields
    }

    private static func isHeader(_ fields: [String]) -> Bool {
        guard fields.count == 3 else { return false }
        return fields[0].lowercased().contains("ip")
            && fields[1].lowercased().contains("ip")
            && fields[2].lowercased().contains("country")
    }

    private static func inferredDatabaseDate(from fileName: String) -> Date? {
        let expression = try? NSRegularExpression(pattern: #"(20\d{2})[-_.]?(0[1-9]|1[0-2])"#)
        let range = NSRange(fileName.startIndex..., in: fileName)
        guard let match = expression?.firstMatch(in: fileName, range: range),
              let yearRange = Range(match.range(at: 1), in: fileName),
              let monthRange = Range(match.range(at: 2), in: fileName),
              let year = Int(fileName[yearRange]),
              let month = Int(fileName[monthRange]) else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }
}

private enum PeerCountryDatabaseCodec {
    static let schemaVersion: UInt32 = 1
    static let headerByteCount = 24
    static let magic = Data("TRMPCDB1".utf8)

    static func headerAndMetadata(for database: PeerCountryDatabase) throws -> Data {
        let metadata = try JSONEncoder().encode(database.metadata)
        guard metadata.count <= Int(UInt32.max) else {
            throw PeerCountryDatabaseError.invalidPackedStorage
        }
        var data = Data()
        data.reserveCapacity(headerByteCount + metadata.count)
        data.append(magic)
        data.appendUInt32(schemaVersion)
        data.appendUInt32(UInt32(metadata.count))
        data.appendUInt32(UInt32(database.ipv4RangeCount))
        data.appendUInt32(UInt32(database.ipv6RangeCount))
        data.append(metadata)
        return data
    }

    static func decode(_ data: Data) throws -> PeerCountryDatabase {
        guard data.count >= headerByteCount, data.prefix(magic.count) == magic else {
            throw PeerCountryDatabaseError.invalidPackedStorage
        }
        let version = try data.readUInt32(at: 8)
        guard version == schemaVersion else {
            throw PeerCountryDatabaseError.unsupportedSchemaVersion(Int(version))
        }
        let metadataByteCount = Int(try data.readUInt32(at: 12))
        let ipv4RangeCount = Int(try data.readUInt32(at: 16))
        let ipv6RangeCount = Int(try data.readUInt32(at: 20))
        guard ipv4RangeCount + ipv6RangeCount > 0,
              ipv4RangeCount + ipv6RangeCount
                <= PeerCountryDatabaseStorageContract.maximumRangeCount else {
            throw PeerCountryDatabaseError.invalidRangeCount
        }
        let metadataOffset = headerByteCount
        let ipv4Offset = metadataOffset + metadataByteCount
        let ipv4ByteCountResult = ipv4RangeCount.multipliedReportingOverflow(
            by: PeerCountryDatabaseStorageContract.ipv4RecordByteCount
        )
        guard !ipv4ByteCountResult.overflow else {
            throw PeerCountryDatabaseError.invalidPackedStorage
        }
        let ipv4ByteCount = ipv4ByteCountResult.partialValue
        let ipv6Offset = ipv4Offset + ipv4ByteCount
        let ipv6ByteCountResult = ipv6RangeCount.multipliedReportingOverflow(
            by: PeerCountryDatabaseStorageContract.ipv6RecordByteCount
        )
        guard !ipv6ByteCountResult.overflow else {
            throw PeerCountryDatabaseError.invalidPackedStorage
        }
        let ipv6ByteCount = ipv6ByteCountResult.partialValue
        guard metadataByteCount >= 0,
              ipv6Offset >= ipv4Offset,
              ipv6Offset + ipv6ByteCount == data.count else {
            throw PeerCountryDatabaseError.invalidPackedStorage
        }
        let metadata = try JSONDecoder().decode(
            PeerCountryDatabaseMetadata.self,
            from: data[metadataOffset ..< ipv4Offset]
        )
        return try PeerCountryDatabase(
            metadata: metadata,
            ipv4Storage: data,
            ipv4Offset: ipv4Offset,
            ipv4RangeCount: ipv4RangeCount,
            ipv6Storage: data,
            ipv6Offset: ipv6Offset,
            ipv6RangeCount: ipv6RangeCount
        )
    }
}

actor PeerCountryDatabaseRepository {
    nonisolated let destinationURL: URL
    nonisolated let isEphemeral: Bool
    private let fileManager: FileManager
    private var ephemeralDatabase: PeerCountryDatabase?

    init(
        destinationURL: URL = PeerCountryDatabaseRepository.defaultDestinationURL(),
        fileManager: FileManager = .default
    ) {
        self.destinationURL = destinationURL
        isEphemeral = false
        self.fileManager = fileManager
    }

    private init(ephemeralIdentifier: UUID, fileManager: FileManager = .default) {
        destinationURL = fileManager.temporaryDirectory
            .appendingPathComponent("TransmissionRemoteMac-Isolated", isDirectory: true)
            .appendingPathComponent(ephemeralIdentifier.uuidString, isDirectory: true)
            .appendingPathComponent("country-ranges-v1.bin", isDirectory: false)
        isEphemeral = true
        self.fileManager = fileManager
    }

    nonisolated static func ephemeral() -> PeerCountryDatabaseRepository {
        PeerCountryDatabaseRepository(ephemeralIdentifier: UUID())
    }

    func load() throws -> PeerCountryDatabase? {
        if isEphemeral { return ephemeralDatabase }
        guard fileManager.fileExists(atPath: destinationURL.path) else { return nil }
        return try PeerCountryDatabaseCodec.decode(
            Data(contentsOf: destinationURL, options: .mappedIfSafe)
        )
    }

    func importCSV(
        from sourceURL: URL,
        importedAt: Date = Date(),
        operation: PeerCountryDatabaseOperation? = nil
    ) throws -> PeerCountryDatabase {
        let database = try PeerCountryCSVImporter.parse(sourceURL: sourceURL, importedAt: importedAt) {
            try operation?.checkCancellation()
        }
        try install(database, operation: operation)
        return database
    }

    func importCSV(
        data: Data,
        sourceFileName: String,
        importedAt: Date = Date()
    ) throws -> PeerCountryDatabase {
        let database = try PeerCountryCSVImporter.parse(
            data: data,
            sourceFileName: sourceFileName,
            importedAt: importedAt
        )
        try install(database)
        return database
    }

    func remove(operation: PeerCountryDatabaseOperation? = nil) throws {
        try withActiveOperation(operation) {
            if isEphemeral {
                ephemeralDatabase = nil
                return
            }
            guard fileManager.fileExists(atPath: destinationURL.path) else { return }
            try fileManager.removeItem(at: destinationURL)
        }
    }

    func install(_ database: PeerCountryDatabase, operation: PeerCountryDatabaseOperation? = nil) throws {
        try Task.checkCancellation()
        if isEphemeral {
            try withActiveOperation(operation) { ephemeralDatabase = database }
            return
        }
        let directory = destinationURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let headerAndMetadata = try PeerCountryDatabaseCodec.headerAndMetadata(for: database)
        let temporaryURL = directory.appendingPathComponent(
            ".\(destinationURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        do {
            guard fileManager.createFile(atPath: temporaryURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: temporaryURL)
            do {
                try Task.checkCancellation()
                try handle.write(contentsOf: headerAndMetadata)
                try database.writePackedRecords(to: handle)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try withActiveOperation(operation) {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    _ = try fileManager.replaceItemAt(
                        destinationURL,
                        withItemAt: temporaryURL,
                        backupItemName: nil,
                        options: .usingNewMetadataOnly
                    )
                } else {
                    try fileManager.moveItem(at: temporaryURL, to: destinationURL)
                }
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    nonisolated static func defaultDestinationURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TransmissionRemoteMac", isDirectory: true)
            .appendingPathComponent("PeerCountry", isDirectory: true)
            .appendingPathComponent("country-ranges-v1.bin", isDirectory: false)
    }

    private func withActiveOperation(_ operation: PeerCountryDatabaseOperation?, body: () throws -> Void) throws {
        if let operation {
            try operation.performIfActive(body)
        } else {
            try Task.checkCancellation()
            try body()
        }
    }
}

/// Invalidated synchronously when a newer user intent starts. The final atomic
/// disk swap and invalidation cannot race, even across the repository actor hop.
final class PeerCountryDatabaseOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var isActive = true

    func cancel() {
        lock.lock()
        isActive = false
        lock.unlock()
    }

    func checkCancellation() throws {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { throw CancellationError() }
    }

    func performIfActive(_ body: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard isActive else { throw CancellationError() }
        try Task.checkCancellation()
        try body()
    }
}

enum PeerCountryDatabaseStatus: Equatable, Sendable {
    case loading
    case unavailable
    case installed(PeerCountryDatabaseMetadata)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

@MainActor
final class PeerCountryDatabaseController: ObservableObject {
    static let shared = PeerCountryDatabaseController()

    @Published private(set) var status = PeerCountryDatabaseStatus.loading
    @Published private(set) var errorMessage: String?
    @Published private(set) var downloadPhase: String?

    private let repository: PeerCountryDatabaseRepository
    private let downloader: any PeerCountryDatabaseDownloading
    private var currentDatabase: PeerCountryDatabase?
    private var stateGeneration = 0
    private var activeOperation: PeerCountryDatabaseOperation?
    private var downloadTask: Task<PeerCountryDatabase, Error>?
    nonisolated let storageURL: URL
    nonisolated let usesEphemeralRepository: Bool

    init(
        repository: PeerCountryDatabaseRepository = PeerCountryDatabaseRepository(),
        downloader: any PeerCountryDatabaseDownloading = PeerCountryDatabaseDownloader()
    ) {
        self.repository = repository
        self.downloader = downloader
        storageURL = repository.destinationURL
        usesEphemeralRepository = repository.isEphemeral
        Task { await reload() }
    }

    static func isolated() -> PeerCountryDatabaseController {
        PeerCountryDatabaseController(repository: .ephemeral())
    }

    func databaseSnapshot() async throws -> PeerCountryDatabase? {
        currentDatabase
    }

    @discardableResult
    func importDatabase(from sourceURL: URL) async throws -> PeerCountryDatabase {
        let operation = beginOperation()
        let generation = stateGeneration
        do {
            let database = try await withTaskCancellationHandler {
                try await repository.importCSV(from: sourceURL, operation: operation)
            } onCancel: {
                operation.cancel()
            }
            guard generation == stateGeneration else { throw CancellationError() }
            publishDatabase(database)
            errorMessage = nil
            return database
        } catch {
            await reload(generation: generation, operationError: error)
            throw error
        }
    }

    @discardableResult
    func downloadDatabase(customURL: String) async throws -> PeerCountryDatabase {
        let operation = beginOperation()
        let generation = stateGeneration
        downloadPhase = "Preparing country database download…"
        let downloader = downloader
        let worker = Task {
            try await downloader.download(customURL: customURL) { [weak self] phase in
                Task { @MainActor [weak self] in
                    guard let self, self.stateGeneration == generation, self.downloadTask != nil else { return }
                    self.downloadPhase = phase
                }
            }
        }
        downloadTask = worker
        defer {
            if generation == stateGeneration {
                downloadTask = nil
                downloadPhase = nil
            }
        }
        do {
            return try await withTaskCancellationHandler {
                let database = try await worker.value
                try Task.checkCancellation()
                guard generation == stateGeneration else { throw CancellationError() }
                downloadPhase = "Installing country database…"
                try await repository.install(database, operation: operation)
                guard generation == stateGeneration else { throw CancellationError() }
                publishDatabase(database)
                errorMessage = nil
                return database
            } onCancel: {
                operation.cancel()
                worker.cancel()
            }
        } catch {
            await reload(generation: generation, operationError: error)
            throw error
        }
    }

    func removeDatabase() async throws {
        let operation = beginOperation()
        let generation = stateGeneration
        do {
            try await withTaskCancellationHandler {
                try await repository.remove(operation: operation)
            } onCancel: {
                operation.cancel()
            }
            guard generation == stateGeneration else { throw CancellationError() }
            publishDatabase(nil)
            errorMessage = nil
        } catch {
            await reload(generation: generation, operationError: error)
            throw error
        }
    }

    func clearError() { errorMessage = nil }

    private func beginOperation() -> PeerCountryDatabaseOperation {
        activeOperation?.cancel()
        downloadTask?.cancel()
        downloadTask = nil
        downloadPhase = nil
        errorMessage = nil
        stateGeneration &+= 1
        let operation = PeerCountryDatabaseOperation()
        activeOperation = operation
        return operation
    }

    private func reload(generation requestedGeneration: Int? = nil, operationError: Error? = nil) async {
        let generation = requestedGeneration ?? stateGeneration
        guard generation == stateGeneration else { return }
        do {
            // A superseded operation may already have committed before losing
            // publication ownership. Reconcile that commit if its successor
            // fails, including cancellation, without starting another import.
            let database = try await repository.load()
            guard generation == stateGeneration else { return }
            publishDatabase(database)
            errorMessage = operationError.flatMap { $0 is CancellationError ? nil : $0.localizedDescription }
        } catch {
            guard generation == stateGeneration else { return }
            publishDatabase(nil)
            errorMessage = error.localizedDescription
        }
    }

    private func publishDatabase(_ database: PeerCountryDatabase?) {
        let nextStatus = database.map { PeerCountryDatabaseStatus.installed($0.metadata) } ?? .unavailable
        let changed = currentDatabase != database
        currentDatabase = database
        if changed || status != nextStatus { status = nextStatus }
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var bigEndian = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndian) { append(contentsOf: $0) }
    }

    func readUInt32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset + MemoryLayout<UInt32>.size <= count else {
            throw PeerCountryDatabaseError.invalidPackedStorage
        }
        return UInt32(self[offset]) << 24
            | UInt32(self[offset + 1]) << 16
            | UInt32(self[offset + 2]) << 8
            | UInt32(self[offset + 3])
    }
}
