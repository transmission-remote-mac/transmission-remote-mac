// Transmission Remote Mac
// SPDX-FileCopyrightText: 2026 aidpok
// SPDX-License-Identifier: GPL-2.0-only
// See CREDITS.md for upstream attribution.

import Foundation
@testable import TransmissionRemoteMac

final class TestPollingClock: PollingClock, @unchecked Sendable {
    private struct Waiter {
        var deadline: Duration
        var continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var currentTime: Duration = .zero
    private var waiters: [UUID: Waiter] = [:]
    private var cancellationTotal = 0

    func now() -> Duration {
        lock.withLock { currentTime }
    }

    func sleep(until deadline: Duration) async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if deadline <= currentTime {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiters[waiterID] = Waiter(deadline: deadline, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock { () -> CheckedContinuation<Void, Error>? in
                guard let waiter = self.waiters.removeValue(forKey: waiterID) else { return nil }
                self.cancellationTotal += 1
                return waiter.continuation
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let continuations = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            currentTime += duration
            let readyIDs = waiters.compactMap { id, waiter in
                waiter.deadline <= currentTime ? id : nil
            }
            return readyIDs.compactMap { waiters.removeValue(forKey: $0)?.continuation }
        }
        for continuation in continuations {
            continuation.resume()
        }
    }

    var pendingSleepCount: Int {
        lock.withLock { waiters.count }
    }

    var earliestPendingDeadline: Duration? {
        lock.withLock { waiters.values.map(\.deadline).min() }
    }

    var cancellationCount: Int {
        lock.withLock { cancellationTotal }
    }
}

func waitForPollingCondition(
    iterations: Int = 1_000,
    _ condition: () async -> Bool
) async -> Bool {
    for _ in 0..<iterations {
        if await condition() {
            return true
        }
        await Task.yield()
    }
    return await condition()
}
