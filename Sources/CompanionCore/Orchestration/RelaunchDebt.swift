import Foundation

/// Profiles that were closed and are owed a relaunch. A record leaves the store only once its
/// profile is open again, so a crash or a failed launch still owes it to the next pickup, however
/// many closes come in between. While a launcher holds a profile, no other launcher takes it, so
/// nothing is opened twice.
public actor RelaunchDebt {
    private let store: StateStore
    private var inFlight: Set<ProfileFolder> = []
    /// Profiles an operation copies sessions into: no launcher but the operation's own opens them.
    private nonisolated let held = HeldProfiles()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(store: StateStore) { self.store = store }

    /// Owes `folders` a relaunch, in their order and ahead of older records, and returns the ones
    /// that were not owed before. An older record whose profile is in `open` is settled: that
    /// profile is open again, and this close decides by itself whether it reopens.
    @discardableResult
    public func record(_ folders: [ProfileFolder], open: [ProfileFolder] = []) async throws -> [ProfileFolder] {
        try await exclusive {
            let owed = try await store.load().relaunchDebt
            var seen = Set<ProfileFolder>()
            let ordered = folders.filter { seen.insert($0).inserted }
            let older = owed.filter { !seen.contains($0) && !open.contains($0) }
            try await store.update { $0.relaunchDebt = ordered + older }
            return ordered.filter { !owed.contains($0) }
        }
    }

    /// While an operation writes into `folder`, no launcher opens it: Claude and the copy would
    /// write the same files. It stays owed, so a quit meanwhile leaves it to the next start.
    /// Synchronous, so the operation can end its hold in a `defer` whichever way it returns.
    nonisolated func hold(_ folder: ProfileFolder) { held.insert(folder) }

    nonisolated func release(_ folder: ProfileFolder) { held.remove(folder) }

    /// Takes every owed profile that no other launcher or operation holds. Each one must be settled.
    func claim() async throws -> [ProfileFolder] {
        try await exclusive {
            let free = try await store.load().relaunchDebt.filter { !inFlight.contains($0) && !held.contains($0) }
            inFlight.formUnion(free)
            return free
        }
    }

    /// Takes one owed profile. False when it is not owed or another launcher or operation holds it.
    func claim(_ folder: ProfileFolder) async throws -> Bool {
        try await exclusive {
            guard !inFlight.contains(folder), !held.contains(folder),
                  try await store.load().relaunchDebt.contains(folder) else { return false }
            inFlight.insert(folder)
            return true
        }
    }

    /// Ends a claim. An opened profile is no longer owed; one that failed stays owed.
    /// A failed write only leaves the record behind, and the next pickup finds that profile open.
    func settle(_ folder: ProfileFolder, opened: Bool) async {
        await exclusive {
            inFlight.remove(folder)
            guard opened else { return }
            try? await store.update { $0.relaunchDebt.removeAll { $0 == folder } }
        }
    }

    /// Forgets records without launching them.
    func drop(_ folders: [ProfileFolder]) async throws {
        guard !folders.isEmpty else { return }
        try await exclusive { try await store.update { $0.relaunchDebt.removeAll { folders.contains($0) } } }
    }

    /// Reserve the target attempt while keeping crash/quit recovery durable until it succeeds.
    func claimSwitchTarget(_ target: ProfileFolder, fallback: ProfileFolder?) async throws -> [ProfileFolder]? {
        try await exclusive {
            guard !inFlight.contains(target) else { return nil }
            let owed = try await store.load().relaunchDebt
            guard owed.contains(target) else { return nil }
            inFlight.insert(target)
            if let fallback { inFlight.insert(fallback) }
            return owed.filter { $0 != target }
        }
    }

    /// Keep the target durable until its attempt ends. Only a confirmed, cleaned-up failure
    /// transfers recovery to the previous account; quit must not open it beside a pending target.
    func finishSwitchTarget(_ target: ProfileFolder, fallback: ProfileFolder?, restorePrevious: Bool,
                            keepTarget: Bool = false) async throws {
        try await exclusive {
            // The claims end even when the record cannot be written, or nothing could relaunch them.
            defer {
                inFlight.remove(target)
                if let fallback { inFlight.remove(fallback) }
            }
            try await store.update { state in
                if !keepTarget { state.relaunchDebt.removeAll { $0 == target } }
                if restorePrevious, let fallback, !state.relaunchDebt.contains(fallback) {
                    state.relaunchDebt.append(fallback)
                }
            }
        }
    }

    /// Store reads and writes suspend, so without this two launchers could both see a record free.
    private func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        while busy { await withCheckedContinuation { waiters.append($0) } }
        busy = true
        defer {
            busy = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

private final class HeldProfiles: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: Set<ProfileFolder> = []

    func insert(_ folder: ProfileFolder) {
        lock.lock()
        folders.insert(folder)
        lock.unlock()
    }

    func remove(_ folder: ProfileFolder) {
        lock.lock()
        folders.remove(folder)
        lock.unlock()
    }

    func contains(_ folder: ProfileFolder) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return folders.contains(folder)
    }
}
