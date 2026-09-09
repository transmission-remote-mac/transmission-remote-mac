// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class TorrentFileDropIntakeServiceTests: XCTestCase {
    func testNormalizesOnlyLocalTorrentFileURLs() {
        let torrentURL = URL(fileURLWithPath: "/tmp/folder/../Example.TORRENT")

        XCTAssertEqual(
            TorrentFileDropIntakeService.normalizedTorrentFileURL(torrentURL),
            URL(fileURLWithPath: "/tmp/Example.TORRENT")
        )
        XCTAssertNil(
            TorrentFileDropIntakeService.normalizedTorrentFileURL(
                URL(fileURLWithPath: "/tmp/Example.txt")
            )
        )
        XCTAssertNil(
            TorrentFileDropIntakeService.normalizedTorrentFileURL(
                URL(string: "https://example.com/Example.torrent")!
            )
        )
    }

    func testDecodesFileURLDataAndRejectsInvalidOrOversizedRepresentations() {
        let fileURL = URL(fileURLWithPath: "/tmp/Example File.torrent")

        XCTAssertEqual(
            TorrentFileDropIntakeService.normalizedTorrentFileURL(
                from: fileURL.dataRepresentation
            ),
            fileURL
        )
        XCTAssertNil(
            TorrentFileDropIntakeService.normalizedTorrentFileURL(
                from: Data("not a URL".utf8)
            )
        )
        XCTAssertNil(
            TorrentFileDropIntakeService.normalizedTorrentFileURL(
                from: Data(
                    repeating: 0x61,
                    count: TorrentFileDropIntakeService.maximumFileURLRepresentationBytes + 1
                )
            )
        )
    }

    func testCollectorPreservesProviderOrderWhileOmittingRejectedItems() {
        let completion = expectation(description: "ordered valid torrent URLs")
        let firstURL = URL(fileURLWithPath: "/tmp/first.torrent")
        let thirdURL = URL(fileURLWithPath: "/tmp/third.torrent")
        let collector = TorrentFileDropResultCollector(expectedIndexes: [0, 1, 2]) { urls in
            XCTAssertEqual(urls, [firstURL, thirdURL])
            completion.fulfill()
        }

        collector.record(thirdURL, at: 2)
        collector.record(thirdURL, at: 2)
        collector.record(nil, at: 1)
        collector.record(firstURL, at: 0)

        wait(for: [completion], timeout: 1)
    }

    func testProviderLoadingIgnoresUnsupportedAndInvalidItemsWithoutPoisoningBatch() {
        let completion = expectation(description: "valid dropped files")
        let firstURL = URL(fileURLWithPath: "/tmp/first.torrent")
        let lastURL = URL(fileURLWithPath: "/tmp/last.TORRENT")
        let providers = [
            fileURLProvider(firstURL),
            NSItemProvider(object: "unsupported" as NSString),
            fileURLProvider(URL(fileURLWithPath: "/tmp/not-a-torrent.txt")),
            fileURLProvider(lastURL)
        ]

        XCTAssertTrue(
            TorrentFileDropIntakeService.receive(providers: providers) { urls in
                XCTAssertEqual(urls, [firstURL, lastURL])
                completion.fulfill()
            }
        )

        wait(for: [completion], timeout: 1)
    }

    func testRejectsDropWithoutAnyFileURLProviders() {
        XCTAssertFalse(
            TorrentFileDropIntakeService.receive(
                providers: [NSItemProvider(object: "unsupported" as NSString)],
                onTorrentFiles: { _ in
                    XCTFail("Unsupported providers must not invoke intake")
                }
            )
        )
    }

    private func fileURLProvider(_ url: URL) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.fileURL.identifier,
            visibility: .all
        ) { completion in
            completion(url.dataRepresentation, nil)
            return nil
        }
        return provider
    }
}
