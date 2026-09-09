// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import AppKit
import SwiftUI
import XCTest
@testable import TransmissionRemoteMac

@MainActor
final class DaemonScheduleVisibilityTests: XCTestCase {
    func testMountedScheduleHidesTimeFieldsAndRetainsDraftWithoutResizingWindow() async throws {
        try await withMountedDaemon(rpcVersion: 5) { host, window, controller in
            let originalFrame = window.frame
            XCTAssertTrue(scheduleFields(in: host).isEmpty)
            XCTAssertEqual(manualSpeedFields(in: host).count, 2)
            XCTAssertTrue(manualSpeedFields(in: host).allSatisfy(\.isEnabled))

            var draft = try XCTUnwrap(controller.draft)
            draft.alternateSpeedTimeBegin = "07:23"
            draft.alternateSpeedTimeEnd = "19:41"
            draft.alternateSpeedMonday = true
            draft.alternateSpeedWednesday = false
            draft.alternateSpeedTimeEnabled = true
            controller.updateDraft(draft)
            await settleLayout(in: host)

            XCTAssertEqual(Set(scheduleFields(in: host).map(\.stringValue)), ["07:23", "19:41"])
            XCTAssertEqual(controller.draft?.alternateSpeedMonday, true)
            XCTAssertEqual(controller.draft?.alternateSpeedWednesday, false)

            draft.alternateSpeedTimeEnabled = false
            controller.updateDraft(draft)
            await settleLayout(in: host)

            XCTAssertTrue(scheduleFields(in: host).isEmpty)
            XCTAssertEqual(controller.draft, draft)
            XCTAssertEqual(manualSpeedFields(in: host).count, 2)

            draft.alternateSpeedTimeEnabled = true
            controller.updateDraft(draft)
            await settleLayout(in: host)

            XCTAssertEqual(Set(scheduleFields(in: host).map(\.stringValue)), ["07:23", "19:41"])
            XCTAssertEqual(controller.draft, draft)
            XCTAssertEqual(manualSpeedFields(in: host).count, 2)
            XCTAssertTrue(manualSpeedFields(in: host).allSatisfy(\.isEnabled))
            XCTAssertEqual(window.frame, originalFrame)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
        }
    }

    func testMountedRPCFourHidesUnsupportedAlternateSpeedFieldsEvenWithEnabledDraft() async throws {
        try await withMountedDaemon(rpcVersion: 4) { host, window, controller in
            var draft = try XCTUnwrap(controller.draft)
            draft.alternateSpeedTimeEnabled = true
            draft.alternateSpeedTimeBegin = "07:23"
            draft.alternateSpeedTimeEnd = "19:41"
            draft.alternateSpeedDownKBps = "456"
            draft.alternateSpeedUpKBps = "123"
            controller.updateDraft(draft)
            await settleLayout(in: host)

            XCTAssertTrue(scheduleFields(in: host).isEmpty)
            XCTAssertTrue(manualSpeedFields(in: host).isEmpty)
            XCTAssertEqual(controller.draft, draft)
            XCTAssertFalse(window.isVisible)
            XCTAssertFalse(window.isKeyWindow)
        }
    }

    private func withMountedDaemon(rpcVersion: Int, operation: (NSView, NSWindow, DaemonOptionsSettingsController) async throws -> Void) async throws {
        _ = NSApplication.shared
        let session = SessionInfo(arguments: [
            "rpc-version": .int(rpcVersion),
            "version": .string("Fixture Daemon"),
            "download-dir": .string("/downloads"),
            "alt-speed-enabled": .bool(false),
            "alt-speed-down": .int(456),
            "alt-speed-up": .int(123),
            "alt-speed-time-enabled": .bool(false),
            "alt-speed-time-begin": .int(405),
            "alt-speed-time-end": .int(1_335),
            "alt-speed-time-day": .int(21)
        ])
        let controller = DaemonOptionsSettingsController()
        controller.reset(with: session)
        let host = NSHostingView(rootView: DaemonSessionView(
            optionsController: controller,
            sessionInfo: session,
            sessionStats: nil
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        await settleLayout(in: host)
        try await operation(host, window, controller)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    private func scheduleFields(in view: NSView) -> [NSTextField] {
        descendants(of: view).compactMap { $0 as? NSTextField }
            .filter { $0.isEditable && $0.placeholderString == "HH:MM" }
    }

    private func manualSpeedFields(in view: NSView) -> [NSTextField] {
        descendants(of: view).compactMap { $0 as? NSTextField }
            .filter { $0.isEditable && ["456", "123"].contains($0.stringValue) }
    }

    private func settleLayout(in view: NSView) async {
        for _ in 0..<6 {
            view.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        view.layoutSubtreeIfNeeded()
    }
}
