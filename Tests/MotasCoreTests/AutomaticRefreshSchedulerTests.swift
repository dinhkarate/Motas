import Foundation
import Testing
@testable import MotasCore

/// A test-only gate: `sleep` waits until `release()` resumes exactly one waiter,
/// making the scheduler's interval loop deterministic.
private final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var requestedIntervals: [Duration] = []

    func makeSleep() -> @Sendable (Duration) async throws -> Void {
        { [self] interval in
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                requestedIntervals.append(interval)
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        let waiter = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        waiter?.resume(returning: ())
    }

    func releaseAll() {
        lock.lock()
        let all = waiters
        waiters.removeAll()
        lock.unlock()
        all.forEach { $0.resume(returning: ()) }
    }

    var waiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return waiters.count
    }

    var firstInterval: Duration? {
        lock.lock()
        defer { lock.unlock() }
        return requestedIntervals.first
    }
}

private func waitForSleepRegistration(_ gate: SleepGate) async {
    for _ in 0..<100 {
        if gate.waiterCount > 0 { return }
        await Task.yield()
    }
    Issue.record("Scheduler did not register its sleep waiter")
}

private actor RefreshCounter {
    var count = 0
    func tick() { count += 1 }
}

@Test
@MainActor
func schedulerStartsIdle() async {
    let gate = SleepGate()
    let counter = RefreshCounter()
    let scheduler = AutomaticRefreshScheduler(sleep: gate.makeSleep())
    scheduler.start(interval: .seconds(60)) { await counter.tick() }

    try? await Task.sleep(for: .milliseconds(20))
    #expect(await counter.count == 0)
    scheduler.stop()
    gate.releaseAll()
}

@Test
@MainActor
func schedulerReleasesOneTick() async {
    let gate = SleepGate()
    let counter = RefreshCounter()
    let scheduler = AutomaticRefreshScheduler(sleep: gate.makeSleep())
    scheduler.start(interval: .seconds(60)) { await counter.tick() }

    await waitForSleepRegistration(gate)
    gate.release()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await counter.count == 1)

    scheduler.stop()
    gate.releaseAll()
}

@Test
@MainActor
func schedulerClampsShortInterval() async {
    let gate = SleepGate()
    let counter = RefreshCounter()
    let scheduler = AutomaticRefreshScheduler(sleep: gate.makeSleep())
    scheduler.start(interval: .seconds(1)) { await counter.tick() }

    await waitForSleepRegistration(gate)
    #expect(gate.firstInterval == .seconds(60))
    gate.release()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await counter.count == 1)

    scheduler.stop()
    gate.releaseAll()
}

@Test
@MainActor
func schedulerStopsPermanently() async {
    let gate = SleepGate()
    let counter = RefreshCounter()
    let scheduler = AutomaticRefreshScheduler(sleep: gate.makeSleep())
    scheduler.start(interval: .seconds(60)) { await counter.tick() }

    await waitForSleepRegistration(gate)
    scheduler.stop()
    gate.release()
    try? await Task.sleep(for: .milliseconds(20))
    #expect(await counter.count == 0)

    scheduler.stop()
    gate.releaseAll()
}