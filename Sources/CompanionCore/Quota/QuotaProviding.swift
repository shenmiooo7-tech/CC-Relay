import Foundation

public protocol QuotaStatusProviding: Sendable {
    func readings() async -> AsyncStream<[ProfileFolder: QuotaReading]>
    func currentReadings() async -> [ProfileFolder: QuotaReading]
    func replaceProfiles(_ profiles: [QuotaProfile]) async
    func refresh(_ folders: [ProfileFolder], force: Bool) async
    /// True only when this call made or joined a successful network refresh for the current login.
    /// Missing profiles, skipped reads, cancellation and failures return false.
    func refreshWithResult(_ folders: [ProfileFolder], force: Bool) async -> [ProfileFolder: Bool]
    func refreshVisible(_ folders: [ProfileFolder]) async
    func startPeriodicRefresh(current: ProfileFolder?) async
    func stopPeriodicRefresh() async
}

public protocol AccountDetailsProviding: Sendable {
    /// Reads the identity of a signed-in profile from /api/account. Throws `QuotaFailure`.
    func accountDetails(for profile: QuotaProfile) async throws -> AccountRecord
}
