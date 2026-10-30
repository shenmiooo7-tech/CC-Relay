import Foundation
@testable import CompanionCore

/// Manual clock. `sleep` advances the instant and returns immediately, except while the clock is
/// held: a sleep that reaches the held instant then waits for `release()`.
final class TestClock: CompanionCore.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    private var heldAt: Date?
    private var parked: [CheckedContinuation<Void, Never>] = []

    init(now: Date = Date(timeIntervalSince1970: 1_792_832_402)) {
        instant = now
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        instant.addTimeInterval(interval)
        lock.unlock()
    }

    /// A loop that only this clock drives runs ahead in no real time; holding it at `instant` lets a
    /// test look at the world when that moment comes.
    func hold(at instant: Date) {
        lock.lock()
        heldAt = instant
        lock.unlock()
    }

    /// How many sleeps wait for `release()` right now.
    func waitingSleeps() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return parked.count
    }

    func release() {
        release(holdingAgainAt: nil)
    }

    /// Lets the waiting sleeps go on to `instant`, where the clock is held again.
    func release(holdingAgainAt instant: Date?) {
        lock.lock()
        let waiting = parked
        parked = []
        heldAt = instant
        lock.unlock()
        for continuation in waiting { continuation.resume() }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let parts = duration.components
        let seconds = TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
        // The lock itself runs in synchronous helpers. NSLock cannot be taken
        // directly from an async function on this SDK.
        advance(by: seconds)
        if isHeld() { await withCheckedContinuation { park($0) } }
    }

    private func isHeld() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return heldAt.map { instant >= $0 } ?? false
    }

    private func park(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        // A release between the check and here must not leave the sleep waiting.
        if let heldAt, instant >= heldAt {
            parked.append(continuation)
            lock.unlock()
        } else {
            lock.unlock()
            continuation.resume()
        }
    }
}
