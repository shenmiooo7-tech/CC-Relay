import Foundation

/// Scripted facade for UI tests and previews.
///
/// `perform` records the action and does not change the snapshot. Call `push`
/// to publish the next snapshot to every active stream.
public final class FakeCompanionFacade: CompanionFacade, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: CompanionSnapshot
    private var actions: [CompanionAction] = []
    private var receipts: [CompanionActionReceipt] = []
    private var continuations: [UUID: AsyncStream<CompanionSnapshot>.Continuation] = [:]

    public init(snapshot: CompanionSnapshot = .empty()) {
        self.snapshot = snapshot
    }

    public func snapshots() -> AsyncStream<CompanionSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            let current = self.subscribe(id, continuation)
            continuation.yield(current)
            continuation.onTermination = { [weak self] _ in
                self?.unsubscribe(id)
            }
        }
    }

    public func perform(_ action: CompanionAction) async {
        record(action)
    }

    /// Script the receipts independently of snapshots, including delayed or absent snapshot updates.
    public func enqueueReceipt(_ receipt: CompanionActionReceipt) {
        lock.withLock { receipts.append(receipt) }
    }

    public func performWithReceipt(_ action: CompanionAction) async -> CompanionActionReceipt {
        lock.withLock {
            actions.append(action)
            return receipts.isEmpty ? .unreported : receipts.removeFirst()
        }
    }

    public func push(_ snapshot: CompanionSnapshot) {
        let targets = replace(snapshot)
        for target in targets {
            target.yield(snapshot)
        }
    }

    public func recordedActions() -> [CompanionAction] {
        lock.lock()
        defer { lock.unlock() }
        return actions
    }

    private func record(_ action: CompanionAction) {
        lock.lock()
        actions.append(action)
        lock.unlock()
    }

    private func subscribe(
        _ id: UUID,
        _ continuation: AsyncStream<CompanionSnapshot>.Continuation
    ) -> CompanionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        continuations[id] = continuation
        return snapshot
    }

    private func unsubscribe(_ id: UUID) {
        lock.lock()
        continuations[id] = nil
        lock.unlock()
    }

    private func replace(_ snapshot: CompanionSnapshot) -> [AsyncStream<CompanionSnapshot>.Continuation] {
        lock.lock()
        defer { lock.unlock() }
        self.snapshot = snapshot
        return Array(continuations.values)
    }
}
