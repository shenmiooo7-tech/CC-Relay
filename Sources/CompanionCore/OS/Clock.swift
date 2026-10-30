import Foundation

/// Time source injected anywhere a decision depends on the clock.
///
/// `sleep(for:)` suspends the caller until the duration has elapsed.
/// Cancellation throws and must not be reported as a successful wait.
/// `SystemClock` uses the wall clock. Tests use a manual clock instead.
public protocol Clock: Sendable {
    func now() -> Date
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: Clock {
    public init() {}

    public func now() -> Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}
