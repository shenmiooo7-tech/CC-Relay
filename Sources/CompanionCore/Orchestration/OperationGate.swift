import Foundation

public actor OperationGate {
    private var owner: UUID?
    private var background = false
    private var userWaiter: (id: UUID, continuation: CheckedContinuation<UUID?, Never>)?
    private let log: CompanionLog

    public init(log: CompanionLog) { self.log = log }

    public func acquire() -> UUID? {
        guard owner == nil else {
            log.info(.app, "Ignored an operation while another operation is in flight.")
            return nil
        }
        let token = UUID()
        owner = token
        background = false
        return token
    }

    public func acquireBackground() -> UUID? {
        guard owner == nil else { return nil }
        let token = UUID(); owner = token; background = true
        return token
    }

    /// An accepted user action waits behind a short background inspection. Foreground
    /// operations still reject duplicate actions. Transfer ownership before resuming it.
    public func acquireForUserAction() async -> UUID? {
        guard !Task.isCancelled else { return nil }
        if owner == nil { return acquire() }
        guard background, userWaiter == nil else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume(returning: nil) }
                else { userWaiter = (id, continuation) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard userWaiter?.id == id else { return }
        cancelPendingUserAction()
    }

    public func cancelPendingUserAction() {
        let waiter = userWaiter; userWaiter = nil
        waiter?.continuation.resume(returning: nil)
    }

    public func release(_ token: UUID) {
        guard owner == token else { return }
        if let waiter = userWaiter {
            userWaiter = nil
            let next = UUID(); owner = next; background = false
            waiter.continuation.resume(returning: next)
        } else { owner = nil; background = false }
    }

    public var isBusy: Bool { owner != nil }
    /// Held by an operation, not by a short background look that a user action waits behind.
    public var isBusyInForeground: Bool { owner != nil && !background }
    var hasPendingUserAction: Bool { userWaiter != nil }
}
