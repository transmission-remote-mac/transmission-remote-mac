// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import XCTest
@testable import TransmissionRemoteMac

final class MainWindowRestorationPlannerTests: XCTestCase {
    func testSavedDisplayWithNegativeOriginIsSelectedAndConstrained() throws {
        let displays = [
            WorkspaceDisplayDescriptor(
                identifier: "main",
                visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1728, height: 1080)
            ),
            WorkspaceDisplayDescriptor(
                identifier: "left",
                visibleFrame: WorkspaceRect(x: -1920, y: -120, width: 1920, height: 1080)
            ),
        ]
        let placement = MainWindowPlacement(
            frame: WorkspaceRect(x: -2200, y: -300, width: 1000, height: 700),
            displayIdentifier: "left"
        )

        let plan = try XCTUnwrap(MainWindowRestorationPlanner.plan(
            savedPlacement: placement,
            displays: displays
        ))

        XCTAssertEqual(plan.displayIdentifier, "left")
        XCTAssertEqual(plan.selectionReason, .savedDisplay)
        XCTAssertEqual(plan.frame, WorkspaceRect(x: -1920, y: -120, width: 1000, height: 700))
    }

    func testDisconnectedSavedDisplayFallsBackToGreatestVisibleIntersection() throws {
        let displays = [
            WorkspaceDisplayDescriptor(
                identifier: "main",
                visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1440, height: 900)
            ),
            WorkspaceDisplayDescriptor(
                identifier: "right",
                visibleFrame: WorkspaceRect(x: 1440, y: 100, width: 1920, height: 1080)
            ),
        ]
        let placement = MainWindowPlacement(
            frame: WorkspaceRect(x: 1700, y: 160, width: 1100, height: 760),
            displayIdentifier: "disconnected"
        )

        let plan = try XCTUnwrap(MainWindowRestorationPlanner.plan(
            savedPlacement: placement,
            displays: displays
        ))

        XCTAssertEqual(plan.displayIdentifier, "right")
        XCTAssertEqual(plan.selectionReason, .greatestVisibleIntersection)
        XCTAssertEqual(plan.frame, placement.frame)
    }

    func testOversizedOffscreenFrameIsConstrainedIntoVisibleBounds() throws {
        let display = WorkspaceDisplayDescriptor(
            identifier: "main",
            visibleFrame: WorkspaceRect(x: -100, y: 50, width: 1400, height: 850)
        )
        let placement = MainWindowPlacement(
            frame: WorkspaceRect(x: 9_000, y: -8_000, width: 5_000, height: 4_000),
            displayIdentifier: nil
        )

        let plan = try XCTUnwrap(MainWindowRestorationPlanner.plan(
            savedPlacement: placement,
            displays: [display]
        ))

        XCTAssertEqual(plan.displayIdentifier, "main")
        XCTAssertEqual(plan.frame, display.visibleFrame)
    }

    func testTinyFrameIsClampedToMinimumBeforePositionConstraint() throws {
        let display = WorkspaceDisplayDescriptor(
            identifier: "main",
            visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        let placement = MainWindowPlacement(
            frame: WorkspaceRect(x: 1500, y: 950, width: 50, height: 40),
            displayIdentifier: "main"
        )

        let plan = try XCTUnwrap(MainWindowRestorationPlanner.plan(
            savedPlacement: placement,
            displays: [display],
            minimumSize: WorkspaceSize(width: 800, height: 600)
        ))

        XCTAssertEqual(plan.frame, WorkspaceRect(x: 800, y: 400, width: 800, height: 600))
    }

    func testInvalidGeometryOrNoUsableDisplaysReturnsNoPlan() {
        let validPlacement = MainWindowPlacement(
            frame: WorkspaceRect(x: 0, y: 0, width: 900, height: 700),
            displayIdentifier: nil
        )
        let invalidPlacement = MainWindowPlacement(
            frame: WorkspaceRect(x: .nan, y: 0, width: 900, height: 700),
            displayIdentifier: nil
        )
        let invalidDisplay = WorkspaceDisplayDescriptor(
            identifier: "invalid",
            visibleFrame: WorkspaceRect(x: 0, y: 0, width: 0, height: 900)
        )

        XCTAssertNil(MainWindowRestorationPlanner.plan(
            savedPlacement: invalidPlacement,
            displays: [WorkspaceDisplayDescriptor(
                identifier: "main",
                visibleFrame: WorkspaceRect(x: 0, y: 0, width: 1440, height: 900)
            )]
        ))
        XCTAssertNil(MainWindowRestorationPlanner.plan(
            savedPlacement: validPlacement,
            displays: []
        ))
        XCTAssertNil(MainWindowRestorationPlanner.plan(
            savedPlacement: validPlacement,
            displays: [invalidDisplay]
        ))
    }
}
