import Foundation
@testable import CompanionCore

final class SuspendingClock: CompanionCore.Clock, @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    private var waits: [UUID: (Date, CheckedContinuation<Void, any Error>)] = [:]
    private var sleeps: [Duration] = []
    private var cancelled: Set<UUID> = []

    init(now: Date) { instant = now }

    func now() -> Date { withLock(lock) { instant } }
    func recordedSleeps() -> [Duration] { withLock(lock) { sleeps } }

    func advance(by seconds: TimeInterval) {
        let ready = withLock(lock) {
            instant.addTimeInterval(seconds)
            let ready = waits.filter { $0.value.0 <= instant }
            for id in ready.keys { waits[id] = nil }
            return ready.values.map(\.1)
        }
        for continuation in ready { continuation.resume() }
    }

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let rejected = withLock(lock) {
                    if cancelled.remove(id) != nil || Task.isCancelled { return true }
                    let parts = duration.components
                    let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                    sleeps.append(duration)
                    waits[id] = (instant.addingTimeInterval(seconds), continuation)
                    return false
                }
                if rejected { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation = withLock(self.lock) {
                self.cancelled.insert(id)
                return self.waits.removeValue(forKey: id)?.1
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
