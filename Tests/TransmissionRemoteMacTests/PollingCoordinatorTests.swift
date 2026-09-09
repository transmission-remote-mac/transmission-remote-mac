// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
import XCTest
@testable import TransmissionRemoteMac

final class PollingCoordinatorTests: XCTestCase {
    func testUsesDirectListAndSessionDeadlines() async {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingEventRecorder()
        let token = UUID()

        await coordinator.start(
            commandRevision: 1,
            connectionToken: token,
            listInterval: .seconds(5),
            sessionInterval: .seconds(25)
        ) { token, work in
            await recorder.append(token: token, work: work)
        }
        let firstDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(firstDeadlineScheduled)

        clock.advance(by: .seconds(5))
        let firstRefreshCompleted = await waitForPollingCondition { await recorder.count == 1 }
        let eventsAfterFirstRefresh = await recorder.events
        XCTAssertTrue(firstRefreshCompleted)
        XCTAssertEqual(eventsAfterFirstRefresh, [.init(token: token, work: .torrents)])
        let secondDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(secondDeadlineScheduled)

        clock.advance(by: .seconds(20))
        let sessionRefreshCompleted = await waitForPollingCondition { await recorder.count == 2 }
        let finalEvents = await recorder.events
        XCTAssertTrue(sessionRefreshCompleted)
        XCTAssertEqual(finalEvents.last?.work, [.torrents, .session])
        await coordinator.stop(commandRevision: 2)
    }

    func testNewerCommandReplacesConnectionTokenOwner() async {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let recorder = PollingEventRecorder()
        let retiredToken = UUID()
        let activeToken = UUID()

        await coordinator.start(
            commandRevision: 1,
            connectionToken: retiredToken,
            listInterval: .seconds(5),
            sessionInterval: .seconds(25)
        ) { token, work in
            await recorder.append(token: token, work: work)
        }
        let retiredDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(retiredDeadlineScheduled)

        await coordinator.start(
            commandRevision: 2,
            connectionToken: activeToken,
            listInterval: .seconds(10),
            sessionInterval: .seconds(50)
        ) { token, work in
            await recorder.append(token: token, work: work)
        }
        let activeDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(activeDeadlineScheduled)
        await coordinator.start(
            commandRevision: 1,
            connectionToken: retiredToken,
            listInterval: .seconds(1),
            sessionInterval: .seconds(5)
        ) { token, work in
            await recorder.append(token: token, work: work)
        }

        clock.advance(by: .seconds(10))
        let refreshCompleted = await waitForPollingCondition { await recorder.count == 1 }
        let observedTokens = (await recorder.events).map(\.token)
        XCTAssertTrue(refreshCompleted)
        XCTAssertEqual(observedTokens, [activeToken])
        await coordinator.stop(commandRevision: 3)
    }

    func testStopCancelsPendingDeadlinePromptly() async {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)

        await coordinator.start(
            commandRevision: 1,
            connectionToken: UUID(),
            listInterval: .seconds(5),
            sessionInterval: .seconds(25)
        ) { _, _ in }
        let deadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(deadlineScheduled)

        await coordinator.stop(commandRevision: 2)

        let deadlineCancelled = await waitForPollingCondition { clock.pendingSleepCount == 0 }
        XCTAssertTrue(deadlineCancelled)
        XCTAssertEqual(clock.cancellationCount, 1)
    }

    func testHandlerCompletionPreventsOverlappingRefreshDrains() async {
        let clock = TestPollingClock()
        let coordinator = PollingCoordinator(clock: clock)
        let probe = BlockingPollingHandler()

        await coordinator.start(
            commandRevision: 1,
            connectionToken: UUID(),
            listInterval: .seconds(5),
            sessionInterval: .seconds(25)
        ) { _, _ in
            await probe.handle()
        }
        let deadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(deadlineScheduled)

        clock.advance(by: .seconds(5))
        let firstHandlerStarted = await waitForPollingCondition { await probe.activeCount == 1 }
        XCTAssertTrue(firstHandlerStarted)
        clock.advance(by: .seconds(95))
        await Task.yield()
        let maximumWhileBlocked = await probe.maximumActiveCount
        let callsWhileBlocked = await probe.callCount
        XCTAssertEqual(maximumWhileBlocked, 1)
        XCTAssertEqual(callsWhileBlocked, 1)

        await probe.release()
        let secondHandlerStarted = await waitForPollingCondition { await probe.callCount == 2 }
        let finalMaximumActiveCount = await probe.maximumActiveCount
        XCTAssertTrue(secondHandlerStarted)
        XCTAssertEqual(finalMaximumActiveCount, 1)
        await probe.release()
        let nextDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(nextDeadlineScheduled)
        await coordinator.stop(commandRevision: 2)
    }

    func testWakeObserverRecordsOnlyActualWorkCycles() async {
        let clock = TestPollingClock()
        let wakeRecorder = PollingWakeRecorder()
        let coordinator = PollingCoordinator(clock: clock, wakeObserver: wakeRecorder)
        let handlerRecorder = PollingEventRecorder()
        let token = UUID()

        await coordinator.start(
            commandRevision: 1,
            connectionToken: token,
            listInterval: .seconds(5),
            sessionInterval: .seconds(25)
        ) { token, work in
            await handlerRecorder.append(token: token, work: work)
        }
        let firstDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(firstDeadlineScheduled)

        clock.advance(by: .seconds(4))
        await Task.yield()
        let eventsBeforeDeadline = await wakeRecorder.events
        XCTAssertEqual(eventsBeforeDeadline, [])

        clock.advance(by: .seconds(1))
        let firstWakeRecorded = await waitForPollingCondition { await wakeRecorder.count == 1 }
        let firstHandlerCompleted = await waitForPollingCondition { await handlerRecorder.count == 1 }
        let eventsAfterFirstWake = await wakeRecorder.events
        let handlerCountAfterFirstWake = await handlerRecorder.count
        XCTAssertTrue(firstWakeRecorded)
        XCTAssertTrue(firstHandlerCompleted)
        XCTAssertEqual(eventsAfterFirstWake, [.init(token: token, work: .torrents)])
        XCTAssertEqual(handlerCountAfterFirstWake, 1)

        let secondDeadlineScheduled = await waitForPollingCondition { clock.pendingSleepCount == 1 }
        XCTAssertTrue(secondDeadlineScheduled)
        clock.advance(by: .seconds(20))
        let secondWakeRecorded = await waitForPollingCondition { await wakeRecorder.count == 2 }
        let secondHandlerCompleted = await waitForPollingCondition { await handlerRecorder.count == 2 }
        let finalWake = await wakeRecorder.events.last
        let finalHandlerCount = await handlerRecorder.count
        XCTAssertTrue(secondWakeRecorded)
        XCTAssertTrue(secondHandlerCompleted)
        XCTAssertEqual(finalWake, .init(token: token, work: [.torrents, .session]))
        XCTAssertEqual(finalHandlerCount, 2)

        await coordinator.stop(commandRevision: 2)
        clock.advance(by: .seconds(100))
        await Task.yield()
        let wakeCountAfterStop = await wakeRecorder.count
        XCTAssertEqual(wakeCountAfterStop, 2)
    }
}

private actor PollingEventRecorder {
    struct Event: Equatable {
        var token: UUID
        var work: PollingWork
    }

    private(set) var events: [Event] = []
    var count: Int { events.count }

    func append(token: UUID, work: PollingWork) {
        events.append(Event(token: token, work: work))
    }
}

private actor PollingWakeRecorder: PollingWakeObserving {
    struct Event: Equatable {
        var token: UUID
        var work: PollingWork
    }

    private(set) var events: [Event] = []
    var count: Int { events.count }

    func recordWake(connectionToken: UUID, work: PollingWork) async {
        events.append(Event(token: connectionToken, work: work))
    }
}

private actor BlockingPollingHandler {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var activeCount = 0
    private(set) var maximumActiveCount = 0
    private(set) var callCount = 0

    func handle() async {
        callCount += 1
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
        activeCount -= 1
    }

    func release() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }
}
