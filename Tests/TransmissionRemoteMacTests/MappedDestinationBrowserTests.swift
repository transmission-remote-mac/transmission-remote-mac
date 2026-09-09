// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class MappedDestinationBrowserTests: XCTestCase {
    func testUsesCurrentMappedDestinationAsInitialDirectory() throws {
        let fixture = try Fixture()
        let nestedDirectory = fixture.localRoot.appendingPathComponent("TV/Series", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        let chooser = RecordingDirectoryChooser(selectedDirectory: nil)
        let browser = MappedDestinationBrowser(directoryChooser: chooser)

        XCTAssertEqual(
            browser.browse(
                currentDaemonDestination: "/srv/downloads/TV/Series",
                mappings: [fixture.mapping]
            ),
            .cancelled
        )
        XCTAssertEqual(chooser.initialDirectory?.path, nestedDirectory.resolvingSymlinksInPath().path)
    }

    func testFallsBackToFirstAvailableMappedRoot() throws {
        let fixture = try Fixture()
        let unavailableMapping = try PathMapping.validated(
            remotePathPrefix: "/srv/unavailable",
            localPathPrefix: fixture.temporaryRoot.appendingPathComponent("Unavailable").path
        )
        let chooser = RecordingDirectoryChooser(selectedDirectory: nil)
        let browser = MappedDestinationBrowser(directoryChooser: chooser)

        XCTAssertEqual(
            browser.browse(
                currentDaemonDestination: "/somewhere/unmapped",
                mappings: [unavailableMapping, fixture.mapping]
            ),
            .cancelled
        )
        XCTAssertEqual(chooser.initialDirectory?.path, fixture.localRoot.resolvingSymlinksInPath().path)
    }

    func testCancelReturnsWithoutResolvingDestination() throws {
        let fixture = try Fixture()
        let browser = MappedDestinationBrowser(
            directoryChooser: RecordingDirectoryChooser(selectedDirectory: nil)
        )

        XCTAssertEqual(
            browser.browse(currentDaemonDestination: nil, mappings: [fixture.mapping]),
            .cancelled
        )
    }

    func testCancelLeavesPresentationStateUntouched() {
        let state = MappedDestinationBrowserState(
            daemonDestination: "/srv/current",
            errorMessage: "Existing error"
        )

        XCTAssertEqual(state.applying(.cancelled), state)
    }

    func testSelectedMappedDirectoryReturnsDaemonVisiblePath() throws {
        let fixture = try Fixture()
        let selectedDirectory = fixture.localRoot.appendingPathComponent("Films/New Releases", isDirectory: true)
        try FileManager.default.createDirectory(at: selectedDirectory, withIntermediateDirectories: true)
        let browser = MappedDestinationBrowser(
            directoryChooser: RecordingDirectoryChooser(selectedDirectory: selectedDirectory)
        )

        XCTAssertEqual(
            browser.browse(currentDaemonDestination: nil, mappings: [fixture.mapping]),
            .selectedDaemonPath("/srv/downloads/Films/New Releases")
        )
    }

    func testSuccessUpdatesDestinationAndClearsPreviousError() {
        let state = MappedDestinationBrowserState(
            daemonDestination: "/srv/current",
            errorMessage: "Existing error"
        )

        XCTAssertEqual(
            state.applying(.selectedDaemonPath("/srv/new")),
            MappedDestinationBrowserState(daemonDestination: "/srv/new", errorMessage: nil)
        )
    }

    func testSelectionOutsideMappingsReturnsActionSpecificError() throws {
        let fixture = try Fixture()
        let outsideDirectory = fixture.temporaryRoot.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let browser = MappedDestinationBrowser(
            directoryChooser: RecordingDirectoryChooser(selectedDirectory: outsideDirectory)
        )

        XCTAssertEqual(
            browser.browse(currentDaemonDestination: nil, mappings: [fixture.mapping]),
            .failed(
                .pathResolution(
                    .noMappingForLocalPath(outsideDirectory.path)
                )
            )
        )
    }

    func testFailurePreservesDestinationAndPublishesInlineError() {
        let state = MappedDestinationBrowserState(
            daemonDestination: "/srv/current",
            errorMessage: nil
        )
        let error = MappedDestinationBrowserError.pathResolution(
            .noMappingForLocalPath("/tmp/outside")
        )

        XCTAssertEqual(
            state.applying(.failed(error)),
            MappedDestinationBrowserState(
                daemonDestination: "/srv/current",
                errorMessage: error.localizedDescription
            )
        )
    }

    func testNoAvailableMappedRootFailsBeforeOpeningChooser() throws {
        let fixture = try Fixture(createLocalRoot: false)
        let chooser = RecordingDirectoryChooser(selectedDirectory: fixture.localRoot)
        let browser = MappedDestinationBrowser(directoryChooser: chooser)

        XCTAssertEqual(
            browser.browse(currentDaemonDestination: nil, mappings: [fixture.mapping]),
            .failed(.noAvailableMappedDirectory)
        )
        XCTAssertNil(chooser.initialDirectory)
    }
}

@MainActor
private final class RecordingDirectoryChooser: LocalDirectoryChoosing {
    private let selectedDirectory: URL?
    private(set) var initialDirectory: URL?

    init(selectedDirectory: URL?) {
        self.selectedDirectory = selectedDirectory
    }

    func chooseDirectory(startingAt initialDirectory: URL) -> URL? {
        self.initialDirectory = initialDirectory
        return selectedDirectory
    }
}

private final class Fixture {
    let temporaryRoot: URL
    let localRoot: URL
    let mapping: PathMapping

    init(createLocalRoot: Bool = true) throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        localRoot = temporaryRoot.appendingPathComponent("Mapped Downloads", isDirectory: true)
        if createLocalRoot {
            try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        }
        mapping = try PathMapping.validated(
            remotePathPrefix: "/srv/downloads",
            localPathPrefix: localRoot.path
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }
}
