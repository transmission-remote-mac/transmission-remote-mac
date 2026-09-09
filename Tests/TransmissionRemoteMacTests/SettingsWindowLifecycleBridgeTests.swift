// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class SettingsWindowLifecycleBridgeTests: XCTestCase {
    func testLifecycleOnlyBridgeDoesNotChangeNativeWindowGeometry() {
        let window = makeWindow()
        window.setContentSize(NSSize(width: 730, height: 550))
        let originalFrame = window.frame
        let originalStyle = window.styleMask
        let coordinator = SettingsWindowLifecycleBridge.Coordinator(onExit: {})

        coordinator.attach(to: window)
        coordinator.update(onExit: {})
        coordinator.attach(to: nil)
        coordinator.attach(to: window)

        XCTAssertEqual(window.frame, originalFrame)
        XCTAssertEqual(window.styleMask, originalStyle)
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertFalse(window.isVisible)
        window.close()
    }

    func testAttachedWindowCloseCommits() {
        var commitCount = 0
        let window = makeWindow()
        let coordinator = SettingsWindowLifecycleBridge.Coordinator {
            commitCount += 1
        }
        coordinator.attach(to: window)

        window.close()

        XCTAssertEqual(commitCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testFocusChangesDoNotRepublishPresentationBeforeExit() {
        var presentationCount = 0
        let coordinator = SettingsWindowLifecycleBridge.Coordinator(
            onPresentation: { presentationCount += 1 },
            onExit: {}
        )
        let window = makeWindow()
        coordinator.attach(to: window)

        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        coordinator.attach(to: nil)
        coordinator.attach(to: window)

        XCTAssertEqual(presentationCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testNavigationRemainsPresentedAndKeepsItsTabAcrossFocusChanges() {
        let navigation = SettingsNavigationModel()
        navigation.present(.servers, openSettings: {})
        let coordinator = SettingsWindowLifecycleBridge.Coordinator(
            onPresentation: navigation.settingsDidAppear,
            onExit: navigation.settingsDidDisappear
        )
        let window = makeWindow()
        coordinator.attach(to: window)
        navigation.selectedSection = .daemon

        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        coordinator.attach(to: nil)
        coordinator.attach(to: window)

        XCTAssertTrue(navigation.isSettingsPresented)
        XCTAssertEqual(navigation.selectedSection, .daemon)
        withExtendedLifetime(coordinator) {}
    }

    func testUnrelatedWindowCloseDoesNotCommit() {
        var commitCount = 0
        var coordinator: SettingsWindowLifecycleBridge.Coordinator? = .init {
            commitCount += 1
        }
        let attachedWindow = makeWindow()
        let unrelatedWindow = makeWindow()
        coordinator?.attach(to: attachedWindow)

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: unrelatedWindow
        )

        XCTAssertEqual(commitCount, 0)
        coordinator = nil
    }

    func testCallbackReplacementCommitsLatestDraftState() {
        var committedStates: [String] = []
        var coordinator: SettingsWindowLifecycleBridge.Coordinator? = .init {
            committedStates.append("stale")
        }
        let window = makeWindow()
        coordinator?.attach(to: window)
        coordinator?.update {
            committedStates.append("latest")
        }

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )

        XCTAssertEqual(committedStates, ["latest"])
        coordinator = nil
    }

    func testApplicationTerminationCommitsWithoutWindowClose() {
        var commitCount = 0
        let window = makeWindow()
        window.contentView = NSHostingView(rootView:
            Color.clear.background {
                SettingsWindowLifecycleBridge {
                    commitCount += 1
                }
                .frame(width: 0, height: 0)
            }
        )
        window.contentView?.layoutSubtreeIfNeeded()

        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared
        )

        XCTAssertEqual(commitCount, 1)
    }

    func testApplicationTerminationBeforePresentationDoesNotCommit() {
        var commitCount = 0
        let coordinator = SettingsWindowLifecycleBridge.Coordinator {
            commitCount += 1
        }

        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared
        )

        XCTAssertEqual(commitCount, 0)
        withExtendedLifetime(coordinator) {}
    }

    func testCloseAndTerminationPublishOneExitPerPresentation() {
        var commitCount = 0
        let coordinator = SettingsWindowLifecycleBridge.Coordinator {
            commitCount += 1
        }
        let window = makeWindow()
        coordinator.attach(to: window)

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.post(
            name: NSApplication.willTerminateNotification,
            object: NSApplication.shared
        )

        XCTAssertEqual(commitCount, 1)
        withExtendedLifetime(coordinator) {}
    }

    func testSameWindowCanPublishAgainAfterANewPresentation() {
        var commitCount = 0
        var presentationCount = 0
        let coordinator = SettingsWindowLifecycleBridge.Coordinator(
            onPresentation: { presentationCount += 1 },
            onExit: { commitCount += 1 }
        )
        let window = makeWindow()
        coordinator.attach(to: window)

        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )
        NotificationCenter.default.post(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.post(
            name: NSWindow.willCloseNotification,
            object: window
        )

        XCTAssertEqual(commitCount, 2)
        XCTAssertEqual(presentationCount, 2)
        withExtendedLifetime(coordinator) {}
    }

    private func makeWindow() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
