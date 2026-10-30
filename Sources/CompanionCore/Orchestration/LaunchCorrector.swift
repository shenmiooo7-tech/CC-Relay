import Foundation

public actor LaunchCorrector {
    public enum Decision: Sendable { case ignore, correct, paused }
    private let clock: any Clock
    private var lastCorrection: Date?
    private var disabledUntil: Date?

    public init(clock: any Clock) { self.clock = clock }

    public var isPaused: Bool { disabledUntil.map { $0 > clock.now() } ?? false }

    public func consider(_ event: LaunchEvent, active: ProfileSnapshot?, enabled: Bool,
                         busy: Bool, defaultDirectory: URL) -> Decision {
        guard enabled, !busy, !event.hasExplicitProfileFlag,
              ProfilePaths.same(event.profileDirectory, defaultDirectory),
              let active, !active.folder.isDefault, active.identity != nil else { return .ignore }
        let now = clock.now()
        if let disabledUntil, now < disabledUntil { return .paused }
        if let lastCorrection, now.timeIntervalSince(lastCorrection) < 60 {
            disabledUntil = now.addingTimeInterval(600)
            return .paused
        }
        lastCorrection = now
        return .correct
    }
}
