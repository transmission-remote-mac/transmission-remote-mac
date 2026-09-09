// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class BencodeParserTests: XCTestCase {
    func testRejectsDepthAndNodeBudgetsDeterministically() {
        XCTAssertThrowsError(try BencodeParser.parse(data("llleee"), limits: .init(maximumDepth: 2, maximumNodes: 20))) {
            XCTAssertEqual($0 as? BencodeParserError, .nestingLimitExceeded(position: 2))
        }
        XCTAssertThrowsError(try BencodeParser.parse(data("li1ei2ee"), limits: .init(maximumDepth: 8, maximumNodes: 2))) {
            XCTAssertEqual($0 as? BencodeParserError, .nodeLimitExceeded(position: 4))
        }
        XCTAssertThrowsError(try BencodeParser.parse(data("d1:ai1ee"), limits: .init(maximumDepth: 8, maximumNodes: 2))) {
            XCTAssertEqual($0 as? BencodeParserError, .nodeLimitExceeded(position: 4))
        }
    }

    func testCancellationInterruptsParsingBeforeTheRemainingNodes() {
        var checks = 0
        XCTAssertThrowsError(try BencodeParser.parse(data("li1ei2ei3ee"), checkCancellation: {
            checks += 1
            if checks == 5 { throw CancellationError() }
        })) {
            XCTAssertTrue($0 is CancellationError)
        }
        XCTAssertEqual(checks, 5)
    }

    func testParsesDataSlicesWithoutAssumingAZeroStartIndex() throws {
        let bytes = data("prefix4:spam")
        XCTAssertEqual(try BencodeParser.parse(bytes.dropFirst(6)), .string(data("spam")))
    }

    func testOversizedDeclaredLengthAndIntegerFailWithoutOverflow() {
        XCTAssertThrowsError(try BencodeParser.parse(data("9223372036854775807:"))) {
            XCTAssertEqual($0 as? BencodeParserError, .unexpectedEnd(position: Int.max))
        }
        XCTAssertThrowsError(try BencodeParser.parse(data("i123456789012345678901e"))) {
            XCTAssertEqual($0 as? BencodeParserError, .invalidInteger(position: 0))
        }
    }

    func testDefaultBudgetsPermitTenThousandFileMetainfo() throws {
        let file = "d6:lengthi1e4:pathl1:aee"
        let metainfo = "d4:infod5:filesl" + String(repeating: file, count: 10_000) + "e4:name6:Bundleee"
        let summary = try TorrentMetainfoSummary(data: data(metainfo))
        XCTAssertEqual(summary.files.count, 10_000)
        XCTAssertEqual(summary.totalSize, 10_000)
    }

    func testParsesIntegerStringListAndDictionary() throws {
        let value = try BencodeParser.parse(data("d3:bar4:spam3:fooi42e4:listl4:spami-7eee"))

        XCTAssertEqual(value["bar"]?.utf8StringValue, "spam")
        XCTAssertEqual(value["foo"]?.integerValue, 42)
        XCTAssertEqual(value["list"]?.listValue, [
            .string(Data("spam".utf8)),
            .integer(-7)
        ])
    }

    func testRejectsTrailingData() {
        XCTAssertThrowsError(try BencodeParser.parse(data("4:spam4:eggs"))) { error in
            XCTAssertEqual(error as? BencodeParserError, .trailingData(position: 6))
        }
    }

    func testRejectsInvalidIntegersAndStringLengths() {
        XCTAssertThrowsError(try BencodeParser.parse(data("i03e"))) { error in
            XCTAssertEqual(error as? BencodeParserError, .invalidInteger(position: 0))
        }

        XCTAssertThrowsError(try BencodeParser.parse(data("i-0e"))) { error in
            XCTAssertEqual(error as? BencodeParserError, .invalidInteger(position: 0))
        }

        XCTAssertThrowsError(try BencodeParser.parse(data("03:abc"))) { error in
            XCTAssertEqual(error as? BencodeParserError, .invalidStringLength(position: 0))
        }
    }

    func testRejectsUnexpectedEnd() {
        XCTAssertThrowsError(try BencodeParser.parse(data("l4:spam"))) { error in
            XCTAssertEqual(error as? BencodeParserError, .unexpectedEnd(position: 7))
        }
    }

    func testRejectsInvalidDictionaryKeys() {
        XCTAssertThrowsError(try BencodeParser.parse(data("di1e4:spame"))) { error in
            XCTAssertEqual(error as? BencodeParserError, .dictionaryKeyNotString(position: 1))
        }

        XCTAssertThrowsError(try BencodeParser.parse(data("d1:ai1e1:ai2ee"))) { error in
            XCTAssertEqual(error as? BencodeParserError, .duplicateDictionaryKey(position: 7))
        }

        XCTAssertThrowsError(try BencodeParser.parse(data("d1:bi1e1:ai2ee"))) { error in
            XCTAssertEqual(error as? BencodeParserError, .dictionaryKeysOutOfOrder(position: 7))
        }
    }

    func testExtractsSingleFileTorrentMetadata() throws {
        let summary = try TorrentMetainfoSummary(data: data("d8:announce31:http://tracker.example/announce4:infod6:lengthi12345e4:name10:sample.iso12:piece lengthi16384e6:pieces0:ee"))

        XCTAssertEqual(summary.announceURL, "http://tracker.example/announce")
        XCTAssertEqual(summary.announceURLs, ["http://tracker.example/announce"])
        XCTAssertEqual(summary.displayName, "sample.iso")
        XCTAssertEqual(summary.totalSize, 12_345)
        XCTAssertEqual(summary.files, [
            TorrentMetainfoFile(pathComponents: ["sample.iso"], length: 12_345)
        ])
        XCTAssertEqual(summary.files.first?.path, "sample.iso")
    }

    func testExtractsMultiFileTorrentMetadataAndTrackers() throws {
        let summary = try TorrentMetainfoSummary(data: data("d8:announce11:http://t0/a13:announce-listll10:udp://t1/ael12:https://t2/aee4:infod5:filesld6:lengthi10e4:pathl7:dir.txteed6:lengthi20e4:pathl3:sub8:file.bineee4:name6:Bundle12:piece lengthi262144e6:pieces0:ee"))

        XCTAssertEqual(summary.announceURLs, [
            "http://t0/a",
            "udp://t1/a",
            "https://t2/a"
        ])
        XCTAssertEqual(summary.displayName, "Bundle")
        XCTAssertEqual(summary.totalSize, 30)
        XCTAssertEqual(summary.files.map(\.path), [
            "dir.txt",
            "sub/file.bin"
        ])
        XCTAssertEqual(summary.files.map(\.length), [10, 20])
    }

    func testBuildsTorrentAddFileSelectionArraysFromMetainfoSelection() throws {
        let summary = try TorrentMetainfoSummary(data: data("d4:infod5:filesld6:lengthi10e4:pathl7:one.txteed6:lengthi20e4:pathl7:two.bineed6:lengthi30e4:pathl9:three.mkveee4:name6:Bundle12:piece lengthi262144e6:pieces0:ee"))
        var selections = TorrentMetainfoFileSelection.selections(from: summary)

        selections[0].priority = .high
        selections[1].wanted = false
        selections[1].priority = .low

        let addSelection = TorrentAddFileSelection(files: selections)

        XCTAssertEqual(addSelection.filesWanted, [0, 2])
        XCTAssertEqual(addSelection.filesUnwanted, [1])
        XCTAssertEqual(addSelection.priorityHigh, [0])
        XCTAssertEqual(addSelection.priorityNormal, [2])
        XCTAssertEqual(addSelection.priorityLow, [1])
    }

    func testRejectsMalformedTorrentMetadata() {
        XCTAssertThrowsError(try TorrentMetainfoSummary(data: data("d4:infod6:lengthi1eee"))) { error in
            XCTAssertEqual(error as? TorrentMetainfoError, .missingName)
        }

        XCTAssertThrowsError(try TorrentMetainfoSummary(data: data("d4:infod5:filesle4:name4:Testee"))) { error in
            XCTAssertEqual(error as? TorrentMetainfoError, .invalidFilesList)
        }
    }

    private func data(_ string: String) -> Data {
        Data(string.utf8)
    }
}
