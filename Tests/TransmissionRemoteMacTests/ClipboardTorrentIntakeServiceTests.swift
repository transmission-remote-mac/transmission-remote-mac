// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class ClipboardTorrentIntakeServiceTests: XCTestCase {
    func testClipboardIntakeIsDisabledByDefault() {
        var service = ClipboardTorrentIntakeService()

        XCTAssertEqual(
            service.inspect(
                .plainText("magnet:?xt=urn:btih:abc"),
                policy: .defaults
            ),
            .ignore(.disabled)
        )
        XCTAssertEqual(service.retainedDigestCount, 0)
    }

    func testExplicitSourcesProduceNormalizedCandidates() throws {
        var service = ClipboardTorrentIntakeService()
        let policy = ClipboardTorrentIntakePolicy(isEnabled: true)
        let inputs: [(String, ClipboardTorrentSourceKind)] = [
            ("magnet:?xt=urn:btih:abc", .magnetLink),
            ("https://example.com/release.torrent", .remoteURL),
            ("0123456789ABCDEF0123456789ABCDEF01234567", .rawInfoHash)
        ]

        for (source, expectedKind) in inputs {
            guard case let .candidate(candidate) = service.inspect(
                .plainText(source),
                policy: policy
            ) else {
                return XCTFail("Expected a normalized candidate for \(source)")
            }

            XCTAssertEqual(candidate.sourceKind, expectedKind)
            XCTAssertEqual(candidate.normalizedSource, try TorrentSourceNormalizer.normalize(source))
        }
    }

    func testIgnoresPasswordsArbitraryTextFilesPathsAndCredentialURLs() {
        var service = ClipboardTorrentIntakeService()
        let policy = ClipboardTorrentIntakePolicy(isEnabled: true)
        let ignoredText = [
            "correct horse battery staple",
            "hunter2",
            "/Users/example/Downloads/example.torrent",
            "file:///Users/example/Downloads/example.torrent",
            "https://person:secret@example.com/example.torrent",
            "magnet:?xt=urn:btih:abc\nsecond line"
        ]

        for text in ignoredText {
            XCTAssertEqual(
                service.inspect(.plainText(text), policy: policy),
                .ignore(.unsupportedText)
            )
        }
        XCTAssertEqual(
            service.inspect(
                .fileURLs([URL(fileURLWithPath: "/tmp/example.torrent")]),
                policy: policy
            ),
            .ignore(.filePayload)
        )
        XCTAssertFalse(ClipboardTorrentIntakeService.persistsClipboardContents)
        XCTAssertEqual(service.retainedDigestCount, 0)
    }

    func testDeduplicatesNormalizedSourcesUsingBoundedInMemoryDigests() {
        var service = ClipboardTorrentIntakeService(deduplicationCapacity: 2)
        let policy = ClipboardTorrentIntakePolicy(isEnabled: true)
        let uppercaseHash = "0123456789ABCDEF0123456789ABCDEF01234567"
        let lowercaseHash = uppercaseHash.lowercased()

        guard case .candidate = service.inspect(.plainText(uppercaseHash), policy: policy) else {
            return XCTFail("Expected the first hash to produce a candidate")
        }
        XCTAssertEqual(
            service.inspect(.plainText(lowercaseHash), policy: policy),
            .ignore(.duplicateCandidate)
        )

        _ = service.inspect(
            .plainText("https://example.com/one.torrent"),
            policy: policy
        )
        _ = service.inspect(
            .plainText("https://example.com/two.torrent"),
            policy: policy
        )
        XCTAssertEqual(service.retainedDigestCount, 2)

        guard case .candidate = service.inspect(.plainText(uppercaseHash), policy: policy) else {
            return XCTFail("Expected an evicted digest to be eligible again")
        }
    }

    func testResetClearsOnlyDeduplicationState() {
        var service = ClipboardTorrentIntakeService()
        let policy = ClipboardTorrentIntakePolicy(isEnabled: true)
        let source = "https://example.com/release.torrent"

        _ = service.inspect(.plainText(source), policy: policy)
        service.resetDeduplication()

        XCTAssertEqual(service.retainedDigestCount, 0)
        guard case .candidate = service.inspect(.plainText(source), policy: policy) else {
            return XCTFail("Expected reset source to produce a candidate again")
        }
    }
}
