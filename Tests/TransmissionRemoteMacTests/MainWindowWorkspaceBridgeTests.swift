// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class MainWindowWorkspaceBridgeTests: XCTestCase {
    func testFramePersistencePolicyRejectsRestorationLiveResizeAndFullScreen() {
        XCTAssertTrue(MainWindowFramePersistencePolicy.permitsPersistence(
            isRestoring: false,
            isInLiveResize: false,
            styleMask: [.titled, .resizable]
        ))
        XCTAssertFalse(MainWindowFramePersistencePolicy.permitsPersistence(
            isRestoring: true,
            isInLiveResize: false,
            styleMask: [.titled, .resizable]
        ))
        XCTAssertFalse(MainWindowFramePersistencePolicy.permitsPersistence(
            isRestoring: false,
            isInLiveResize: true,
            styleMask: [.titled, .resizable]
        ))
        XCTAssertFalse(MainWindowFramePersistencePolicy.permitsPersistence(
            isRestoring: false,
            isInLiveResize: false,
            styleMask: [.titled, .resizable, .fullScreen]
        ))
    }

    func testCoordinatorPublishesAUserResizeAndMove() async {
        let initialFrame = NSRect(x: 120, y: 140, width: 900, height: 700)
        let updatedFrame = NSRect(x: 260, y: 220, width: 1_100, height: 760)
        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        let updatePublished = expectation(description: "updated window placement published")
        let expectedPlacement = WorkspaceRect(
            x: Double(updatedFrame.origin.x),
            y: Double(updatedFrame.origin.y),
            width: Double(updatedFrame.width),
            height: Double(updatedFrame.height)
        )
        var receivedPlacement: MainWindowPlacement?
        coordinator.update(savedPlacement: nil) { placement, _ in
            guard placement.frame == expectedPlacement else { return }
            receivedPlacement = placement
            updatePublished.fulfill()
        }
        coordinator.attach(to: window)

        window.setFrame(updatedFrame, display: false)
        await fulfillment(of: [updatePublished], timeout: 2)

        XCTAssertEqual(receivedPlacement?.frame, expectedPlacement)
    }

    func testCoordinatorRestoresSavedPlacementOnlyWhenWindowAttaches() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let savedFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let initialFrame = savedFrame.offsetBy(dx: 40, dy: 30)
        let window = FrameTrackingWindow(
            contentRect: initialFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(
            width: screen.visibleFrame.width * 2,
            height: screen.visibleFrame.height * 2
        )
        window.resetSetFrameCallCount()
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        coordinator.update(
            savedPlacement: MainWindowPlacement(
                frame: savedFrame,
                displayIdentifier: nil
            ),
            onPlacementChange: { _, _ in }
        )

        coordinator.attach(to: window)

        XCTAssertEqual(window.trackedFrame, savedFrame)
        XCTAssertEqual(
            window.minSize,
            NSSize(
                width: WorkspaceSize.defaultMainWindowMinimum.width,
                height: WorkspaceSize.defaultMainWindowMinimum.height
            )
        )
        XCTAssertEqual(window.setFrameCallCount, 1)
    }

    func testPersistedResizeFeedbackDoesNotReapplyTheWindowFrame() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let savedFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let resizedFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let window = FrameTrackingWindow(
            contentRect: savedFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        let placementPublished = expectation(description: "resized placement published")
        var receivedPlacement: MainWindowPlacement?
        var receivedSourceID: UUID?
        coordinator.update(
            savedPlacement: MainWindowPlacement(
                frame: savedFrame,
                displayIdentifier: nil
            )
        ) { placement, sourceID in
            receivedPlacement = placement
            receivedSourceID = sourceID
            placementPublished.fulfill()
        }
        coordinator.attach(to: window)
        window.setFrame(resizedFrame.appKitRect, display: false)

        await fulfillment(of: [placementPublished], timeout: 2)
        let publishedPlacement = try XCTUnwrap(receivedPlacement)
        let publishedSourceID = try XCTUnwrap(receivedSourceID)
        window.resetSetFrameCallCount()
        coordinator.update(
            savedPlacement: publishedPlacement,
            savedPlacementSourceID: publishedSourceID,
            onPlacementChange: { _, _ in }
        )

        XCTAssertEqual(window.trackedFrame, resizedFrame)
        XCTAssertEqual(window.setFrameCallCount, 0)
    }

    func testExternalPlacementChangeAppliesOnceOutsideLiveResize() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let initialSavedFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let latestSavedFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let temporaryFrame = testFrame(in: screen.visibleFrame, width: 840, height: 640)
        let window = FrameTrackingWindow(
            contentRect: initialSavedFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        coordinator.update(
            savedPlacement: MainWindowPlacement(
                frame: initialSavedFrame,
                displayIdentifier: nil
            ),
            onPlacementChange: { _, _ in }
        )
        coordinator.attach(to: window)
        window.setFrame(temporaryFrame.appKitRect, display: false)
        window.resetSetFrameCallCount()

        coordinator.update(
            savedPlacement: MainWindowPlacement(
                frame: latestSavedFrame,
                displayIdentifier: nil
            ),
            onPlacementChange: { _, _ in }
        )

        XCTAssertEqual(window.trackedFrame, latestSavedFrame)
        XCTAssertEqual(window.setFrameCallCount, 1)
    }

    func testLocallyPublishedDisplayIdentityDoesNotReapplyTheWindowFrame() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let savedFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let window = FrameTrackingWindow(
            contentRect: savedFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        let placementPublished = expectation(description: "display identity published")
        var receivedPlacement: MainWindowPlacement?
        var receivedSourceID: UUID?
        coordinator.update(
            savedPlacement: MainWindowPlacement(
                frame: savedFrame,
                displayIdentifier: "disconnected-display"
            )
        ) { placement, sourceID in
            receivedPlacement = placement
            receivedSourceID = sourceID
            placementPublished.fulfill()
        }
        coordinator.attach(to: window)

        await fulfillment(of: [placementPublished], timeout: 2)
        let publishedPlacement = try XCTUnwrap(receivedPlacement)
        let publishedSourceID = try XCTUnwrap(receivedSourceID)
        window.resetSetFrameCallCount()
        coordinator.update(
            savedPlacement: publishedPlacement,
            savedPlacementSourceID: publishedSourceID,
            onPlacementChange: { _, _ in }
        )

        XCTAssertEqual(window.trackedFrame, savedFrame)
        XCTAssertEqual(window.setFrameCallCount, 0)
    }

    func testUnchangedPersistenceDoesNotMaskALaterExternalRestore() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let firstSavedFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let secondSavedFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let window = FrameTrackingWindow(
            contentRect: firstSavedFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: firstSavedFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )
        coordinator.attach(to: window)
        try? await Task.sleep(for: .milliseconds(250))

        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: secondSavedFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )
        window.resetSetFrameCallCount()
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: firstSavedFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )

        XCTAssertEqual(window.trackedFrame, firstSavedFrame)
        XCTAssertEqual(window.setFrameCallCount, 1)
    }

    func testDelayedLocalPlacementEchoesNeverReapplyOlderFrames() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let initialFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let firstFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let secondFrame = testFrame(in: screen.visibleFrame, width: 840, height: 640)
        let window = FrameTrackingWindow(
            contentRect: initialFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        let firstPlacementPublished = expectation(description: "first local placement published")
        let secondPlacementPublished = expectation(description: "second local placement published")
        var publishedPlacements: [(placement: MainWindowPlacement, sourceID: UUID)] = []
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: initialFrame, displayIdentifier: nil)
        ) { placement, sourceID in
            publishedPlacements.append((placement, sourceID))
            if publishedPlacements.count == 1 {
                firstPlacementPublished.fulfill()
            } else if publishedPlacements.count == 2 {
                secondPlacementPublished.fulfill()
            }
        }
        coordinator.attach(to: window)

        window.setFrame(firstFrame.appKitRect, display: false)
        await fulfillment(of: [firstPlacementPublished], timeout: 2)
        window.setFrame(secondFrame.appKitRect, display: false)
        await fulfillment(of: [secondPlacementPublished], timeout: 2)
        XCTAssertEqual(publishedPlacements.count, 2)
        window.resetSetFrameCallCount()

        coordinator.update(
            savedPlacement: publishedPlacements[0].placement,
            savedPlacementSourceID: publishedPlacements[0].sourceID,
            onPlacementChange: { _, _ in }
        )
        XCTAssertEqual(window.trackedFrame, secondFrame)
        XCTAssertEqual(window.setFrameCallCount, 0)
        coordinator.update(
            savedPlacement: publishedPlacements[1].placement,
            savedPlacementSourceID: publishedPlacements[1].sourceID,
            onPlacementChange: { _, _ in }
        )

        XCTAssertEqual(window.trackedFrame, secondFrame)
        XCTAssertEqual(window.setFrameCallCount, 0)
    }

    func testOldWindowSourceDoesNotMaskPlacementAfterWindowReplacement() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let firstFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let publishedFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let replacementFrame = testFrame(in: screen.visibleFrame, width: 840, height: 640)
        let firstWindow = FrameTrackingWindow(
            contentRect: firstFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        let placementPublished = expectation(description: "old-window placement published")
        var receivedPlacement: MainWindowPlacement?
        var receivedSourceID: UUID?
        coordinator.update(savedPlacement: nil) { placement, sourceID in
            receivedPlacement = placement
            receivedSourceID = sourceID
            placementPublished.fulfill()
        }
        coordinator.attach(to: firstWindow)
        firstWindow.setFrame(publishedFrame.appKitRect, display: false)
        await fulfillment(of: [placementPublished], timeout: 2)
        let oldPlacement = try XCTUnwrap(receivedPlacement)
        let oldSourceID = try XCTUnwrap(receivedSourceID)

        let replacementWindow = FrameTrackingWindow(
            contentRect: replacementFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        coordinator.attach(to: replacementWindow)
        replacementWindow.resetSetFrameCallCount()
        coordinator.update(
            savedPlacement: oldPlacement,
            savedPlacementSourceID: oldSourceID,
            onPlacementChange: { _, _ in }
        )

        XCTAssertEqual(replacementWindow.trackedFrame, publishedFrame)
        XCTAssertEqual(replacementWindow.setFrameCallCount, 1)
    }

    func testExternalPlacementMatchingAPriorLocalFrameStillRestores() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let initialFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let localFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let externalFrame = testFrame(in: screen.visibleFrame, width: 840, height: 640)
        let window = FrameTrackingWindow(
            contentRect: initialFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        let localPlacementPublished = expectation(description: "local placement published")
        let localPlacementRepublished = expectation(description: "local placement republished")
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: initialFrame, displayIdentifier: nil)
        ) { _, _ in
            localPlacementPublished.fulfill()
        }
        coordinator.attach(to: window)
        window.setFrame(localFrame.appKitRect, display: false)
        await fulfillment(of: [localPlacementPublished], timeout: 2)

        window.resetSetFrameCallCount()
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: externalFrame, displayIdentifier: nil)
        ) { placement, _ in
            guard placement.frame == localFrame else { return }
            localPlacementRepublished.fulfill()
        }
        XCTAssertEqual(window.trackedFrame, externalFrame)
        XCTAssertEqual(window.setFrameCallCount, 1)

        window.setFrame(localFrame.appKitRect, display: false)
        await fulfillment(of: [localPlacementRepublished], timeout: 2)

        XCTAssertEqual(window.trackedFrame, localFrame)
    }

    func testPendingExternalRestoreDoesNotCrossWindowReplacement() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let initialFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let externalFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let firstWindow = FrameTrackingWindow(
            contentRect: initialFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: initialFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )
        coordinator.attach(to: firstWindow)
        firstWindow.reportsFullScreen = true
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: externalFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )

        let replacementWindow = FrameTrackingWindow(
            contentRect: initialFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        coordinator.attach(to: replacementWindow)
        XCTAssertEqual(replacementWindow.trackedFrame, externalFrame)
        replacementWindow.resetSetFrameCallCount()

        NotificationCenter.default.post(
            name: NSWindow.didExitFullScreenNotification,
            object: replacementWindow
        )

        XCTAssertEqual(replacementWindow.setFrameCallCount, 0)
    }

    func testExternalPlacementDuringLiveResizeAppliesAfterTheGestureEnds() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let initialFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let draggedFrame = testFrame(in: screen.visibleFrame, width: 900, height: 680)
        let externalFrame = testFrame(in: screen.visibleFrame, width: 840, height: 640)
        let window = FrameTrackingWindow(
            contentRect: initialFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: initialFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )
        coordinator.attach(to: window)
        window.reportsLiveResize = true
        window.setFrame(draggedFrame.appKitRect, display: false)
        window.resetSetFrameCallCount()

        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: externalFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )
        XCTAssertEqual(window.trackedFrame, draggedFrame)
        XCTAssertEqual(window.setFrameCallCount, 0)

        window.reportsLiveResize = false
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)

        XCTAssertEqual(window.trackedFrame, externalFrame)
        XCTAssertEqual(window.setFrameCallCount, 1)
    }

    func testExternalPlacementDuringFullScreenAppliesAfterExit() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let initialFrame = testFrame(in: screen.visibleFrame, width: 1_100, height: 760)
        let externalFrame = testFrame(in: screen.visibleFrame, width: 840, height: 640)
        let window = FrameTrackingWindow(
            contentRect: initialFrame.appKitRect,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: initialFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )
        coordinator.attach(to: window)
        window.reportsFullScreen = true
        window.resetSetFrameCallCount()

        coordinator.update(
            savedPlacement: MainWindowPlacement(frame: externalFrame, displayIdentifier: nil),
            onPlacementChange: { _, _ in }
        )

        XCTAssertEqual(window.trackedFrame, initialFrame)
        XCTAssertEqual(window.setFrameCallCount, 0)

        window.reportsFullScreen = false
        window.resetSetFrameCallCount()
        NotificationCenter.default.post(name: NSWindow.didExitFullScreenNotification, object: window)

        XCTAssertEqual(window.trackedFrame, externalFrame)
        XCTAssertEqual(window.setFrameCallCount, 1)
    }

    func testFullScreenGeometryIsNotPublished() async {
        let window = FrameTrackingWindow(
            contentRect: NSRect(x: 120, y: 140, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.reportsFullScreen = true
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        var publishedCount = 0
        coordinator.update(savedPlacement: nil) { _, _ in
            publishedCount += 1
        }

        coordinator.attach(to: window)
        NotificationCenter.default.post(name: NSWindow.didMoveNotification, object: window)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        try? await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(publishedCount, 0)
    }

    func testRepeatedAttachDoesNotOverwriteALaterMinimumSize() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 140, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        coordinator.update(savedPlacement: nil, onPlacementChange: { _, _ in })
        coordinator.attach(to: window)
        let laterMinimumSize = NSSize(width: 860, height: 660)
        window.minSize = laterMinimumSize

        coordinator.attach(to: window)

        XCTAssertEqual(window.minSize, laterMinimumSize)
    }

    func testAttachPreservesAnExistingFrameAutosaveOwner() {
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 140, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        let autosaveName = NSWindow.FrameAutosaveName("ExistingTestOwner-\(UUID().uuidString)")
        defer { NSWindow.removeFrame(usingName: autosaveName) }
        window.setFrameAutosaveName(autosaveName)
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        coordinator.update(savedPlacement: nil, onPlacementChange: { _, _ in })

        coordinator.attach(to: window)

        XCTAssertEqual(window.frameAutosaveName, autosaveName)
    }

    func testLiveResizePublishesOnlyAfterTheGestureEnds() async {
        let window = FrameTrackingWindow(
            contentRect: NSRect(x: 120, y: 140, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.reportsLiveResize = true
        let coordinator = MainWindowWorkspaceBridge.Coordinator()
        let placementPublished = expectation(description: "completed live resize published")
        var publishedCount = 0
        coordinator.update(savedPlacement: nil) { _, _ in
            publishedCount += 1
            placementPublished.fulfill()
        }
        coordinator.attach(to: window)

        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: window)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(publishedCount, 0)

        window.reportsLiveResize = false
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
        await fulfillment(of: [placementPublished], timeout: 2)
        XCTAssertEqual(publishedCount, 1)
    }

    private func testFrame(
        in visibleFrame: NSRect,
        width requestedWidth: CGFloat,
        height requestedHeight: CGFloat
    ) -> WorkspaceRect {
        let width = min(max(requestedWidth, 820), visibleFrame.width)
        let height = min(max(requestedHeight, 620), visibleFrame.height)
        return WorkspaceRect(
            x: Double((visibleFrame.midX - width / 2).rounded(.down)),
            y: Double((visibleFrame.midY - height / 2).rounded(.down)),
            width: Double(width),
            height: Double(height)
        )
    }
}

private final class FrameTrackingWindow: NSWindow {
    private(set) var setFrameCallCount = 0
    var reportsLiveResize = false
    var reportsFullScreen = false

    override var inLiveResize: Bool {
        reportsLiveResize
    }

    override var styleMask: NSWindow.StyleMask {
        get {
            reportsFullScreen
                ? super.styleMask.union(.fullScreen)
                : super.styleMask
        }
        set {
            super.styleMask = newValue
        }
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        setFrameCallCount += 1
        super.setFrame(frameRect, display: flag)
    }

    func resetSetFrameCallCount() {
        setFrameCallCount = 0
    }

    var trackedFrame: WorkspaceRect {
        WorkspaceRect(
            x: Double(frame.origin.x),
            y: Double(frame.origin.y),
            width: Double(frame.width),
            height: Double(frame.height)
        )
    }
}

private extension WorkspaceRect {
    var appKitRect: NSRect {
        NSRect(x: x, y: y, width: width, height: height)
    }

    func offsetBy(dx: Double, dy: Double) -> WorkspaceRect {
        WorkspaceRect(x: x + dx, y: y + dy, width: width, height: height)
    }
}
