import Foundation

public enum TaskGuardPermission: Sendable { case idle, override, cancelled }

public actor TaskGuard {
    private let inspector: any CodeTaskInspecting
    private let clock: any Clock
    private var continuation: CheckedContinuation<TaskGuardPermission, Never>?
    private var waiter: Task<Void, Never>?
    private var target: ProfileFolder?
    private var lastActivity: TaskActivity = .idle
    private var publish: (@Sendable (TaskGuardPrompt?) async -> Void)?

    public init(inspector: any CodeTaskInspecting, clock: any Clock) {
        self.inspector = inspector
        self.clock = clock
    }

    public func check(target: ProfileFolder,
                      publish: @escaping @Sendable (TaskGuardPrompt?) async -> Void) async -> TaskGuardPermission {
        let activity = await inspector.activity()
        if activity == .idle { return .idle }
        self.target = target
        lastActivity = activity
        self.publish = publish
        // Install the continuation before publishing so a fast UI reply cannot be lost.
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { await self.show(activity, waiting: false) }
        }
    }

    public func choose(_ choice: TaskGuardChoice) async {
        guard continuation != nil else { return }
        switch choice {
        case .cancel: await finish(.cancelled)
        case .switchNow: await finish(.override)
        case .waitThenSwitch:
            guard waiter == nil else { return }
            await show(lastActivity, waiting: true)
            guard continuation != nil else { return }
            waiter = Task { [weak self, clock] in
                do {
                    while !Task.isCancelled {
                        try await clock.sleep(for: .seconds(5))
                        guard let self else { return }
                        if await self.recheck() { return }
                    }
                } catch { }
            }
        }
    }

    private func recheck() async -> Bool {
        guard continuation != nil else { return true }
        let activity = await inspector.activity()
        if activity == .idle { await finish(.idle); return true }
        await show(activity, waiting: true)
        return false
    }

    private func show(_ activity: TaskActivity, waiting: Bool) async {
        guard continuation != nil, let target else { return }
        lastActivity = activity
        let count: Int
        let unknown: Bool
        switch activity {
        case .idle: count = 0; unknown = false
        case .busy(let tasks): count = tasks.count; unknown = false
        case .unknown: count = 0; unknown = true
        }
        await publish?(TaskGuardPrompt(target: target, busyCount: count, unknown: unknown, isWaiting: waiting))
    }

    private func finish(_ permission: TaskGuardPermission) async {
        let saved = continuation
        continuation = nil
        waiter?.cancel()
        waiter = nil
        await publish?(nil)
        publish = nil
        target = nil
        saved?.resume(returning: permission)
    }
}
