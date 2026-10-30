import Foundation

/// A synchronous subscription point lets the facade yield an initial value immediately.
final class SnapshotHub: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CompanionSnapshot
    private var subscribers: [UUID: AsyncStream<CompanionSnapshot>.Continuation] = [:]

    init(_ value: CompanionSnapshot) { self.value = value }

    func stream() -> AsyncStream<CompanionSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            continuation.yield(value)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.remove(id) }
        }
    }

    func send(_ value: CompanionSnapshot) {
        lock.lock()
        self.value = value
        for continuation in subscribers.values { continuation.yield(value) }
        lock.unlock()
    }

    private func remove(_ id: UUID) {
        lock.lock()
        subscribers[id] = nil
        lock.unlock()
    }
}
