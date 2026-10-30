import Foundation

/// Refreshes quota per profile folder and publishes the readings.
///
/// Network work goes through `SessionCookieReading`, `SafeStorageKeyProviding`,
/// and `HTTPTransport`. A folder has at most one refresh in flight.
public actor QuotaService: QuotaStatusProviding, AccountDetailsProviding {
    private let cookies: any SessionCookieReading
    private let safeStorage: any SafeStorageKeyProviding
    private let cache: QuotaCacheStore
    private let clock: any Clock
    private let jitter: any RefreshJitter
    private let log: CompanionLog
    private let decryptor: ChromiumCookieDecryptor
    private let client: ClaudeWebClient

    private var profiles: [ProfileFolder: QuotaProfile] = [:]
    private var states: [ProfileFolder: FolderState] = [:]
    private var flights: [ProfileFolder: Flight] = [:]
    private var loginGenerations: [ProfileFolder: LoginGeneration] = [:]
    private var subscribers: [UUID: AsyncStream<[ProfileFolder: QuotaReading]>.Continuation] = [:]
    private var detached: Set<UUID> = []
    private var emitted: [ProfileFolder: QuotaReading]?
    private var cacheLoad: Task<Void, Never>?
    private var pauseCacheLoad = false
    private var cacheLoadGate: CheckedContinuation<Void, Never>?
    private var keychainDeclined = false
    private var currentFolder: ProfileFolder?
    private var periodic: Task<Void, Never>?
    private var storedWaits: [String: QuotaWait] = [:]
    private(set) var refreshJoins = 0
    private(set) var previousLoginWaits = 0
    private(set) var cacheLoadJoins = 0

    public init(
        cookies: any SessionCookieReading,
        safeStorage: any SafeStorageKeyProviding,
        transport: any HTTPTransport,
        cache: QuotaCacheStore,
        clock: any Clock,
        jitter: any RefreshJitter = UniformRefreshJitter(),
        userAgent: String,
        log: CompanionLog,
        decryptor: ChromiumCookieDecryptor = ChromiumCookieDecryptor()
    ) {
        self.cookies = cookies
        self.safeStorage = safeStorage
        self.cache = cache
        self.clock = clock
        self.jitter = jitter
        self.log = log
        self.decryptor = decryptor
        client = ClaudeWebClient(transport: transport, userAgent: userAgent, now: { clock.now() })
    }

    public func readings() async -> AsyncStream<[ProfileFolder: QuotaReading]> {
        AsyncStream { continuation in
            let id = UUID()
            let attachTask = Task { await self.attach(id, continuation) }
            continuation.onTermination = { _ in
                attachTask.cancel()
                Task { await self.detach(id) }
            }
        }
    }

    public func currentReadings() async -> [ProfileFolder: QuotaReading] {
        await ensureLoaded()
        return presented(now: clock.now())
    }

    public func replaceProfiles(_ incoming: [QuotaProfile]) async {
        await ensureLoaded()
        var indexed: [ProfileFolder: QuotaProfile] = [:]
        for profile in incoming {
            indexed[profile.folder] = profile
            var state = states[profile.folder] ?? FolderState()
            // A failure, the throttle and a wait claude.ai asked for are about the login they were
            // measured on, not about another one the folder has signed in to since.
            if let owner = state.owner, owner != Owner(profile) {
                state.failure = nil
                state.lastAttempt = nil
                state.owner = nil
                state.notBefore = nil
                state.limits = 0
            }
            if !Self.matches(state.network, profile) {
                state.history = PlanUsageHistory.reading(for: profile)
            }
            states[profile.folder] = state
        }
        profiles = indexed
        publish()
        await storeWaits()
    }

    public func refresh(_ folders: [ProfileFolder], force: Bool) async {
        _ = await refreshWithResult(folders, force: force)
    }

    public func refreshWithResult(_ folders: [ProfileFolder], force: Bool) async -> [ProfileFolder: Bool] {
        await ensureLoaded()
        return await withTaskGroup(of: (ProfileFolder, Bool).self) { group in
            var scheduled: Set<ProfileFolder> = []
            for folder in folders where scheduled.insert(folder).inserted {
                group.addTask {
                    guard !Task.isCancelled else { return (folder, false) }
                    return (folder, await self.refreshOne(folder, policy: force ? .forced : .automatic))
                }
            }
            var results: [ProfileFolder: Bool] = [:]
            for await (folder, succeeded) in group {
                results[folder] = succeeded
            }
            return results
        }
    }

    /// The panel opened: every account is read again, all at once, whatever the age of its last
    /// reading, unless it was tried within `panelInterval`, so opening the panel twice in a row does
    /// not ask twice. Never asks the keychain.
    public func refreshVisible(_ folders: [ProfileFolder]) async {
        await ensureLoaded()
        await withTaskGroup(of: Void.self) { group in
            for folder in folders {
                group.addTask { _ = await self.refreshOne(folder, policy: .panel) }
            }
        }
    }

    /// Starts the current-account timer. A changed folder is refreshed once now.
    public func startPeriodicRefresh(current: ProfileFolder?) async {
        await ensureLoaded()
        let previous = currentFolder
        currentFolder = current
        let starting = periodic == nil
        if starting {
            periodic = Task { await self.runPeriodicRefresh() }
        }
        if current != previous, let current {
            await refresh([current], force: false)
        }
        // A stored reading still fresh skips that refresh, and a panel opening never asks the
        // keychain: without this, every opening soon after a launch would report it as refused.
        if starting { await prepareKey() }
    }

    public func stopPeriodicRefresh() async {
        periodic?.cancel()
        periodic = nil
    }

    public func accountDetails(for profile: QuotaProfile) async throws -> AccountRecord {
        await ensureLoaded()
        let credential = readCredential(for: profile)
        if profiles[profile.folder].map(Owner.init).map({ $0 == Owner(profile) }) ?? true {
            _ = observeLogin(profile, credential: credential)
        }
        if let state = states[profile.folder], state.owner == Owner(profile), let until = waitEnd(state, now: clock.now()) {
            throw QuotaFailure.rateLimited(until: until)
        }
        let key = try await sessionKey(credential: credential, askKeychain: true)
        do {
            return try await client.fetchAccount(
                sessionKey: key,
                expectedAccount: profile.accountUUID,
                activeOrganization: profile.organizationUUID
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ClaudeWebError {
            let reason = failure(error, folder: profile.folder)
            if case .rateLimited(let until) = reason {
                var state = states[profile.folder] ?? FolderState()
                state.owner = Owner(profile)
                state.notBefore = until
                state.limits += 1
                states[profile.folder] = state
                await storeWaits()
            }
            throw reason
        } catch {
            throw QuotaFailure.transportFailed
        }
    }

    private func refreshOne(_ folder: ProfileFolder, policy: RefreshPolicy) async -> Bool {
        while let existing = flights[folder] {
            let current = profiles[folder].map { observeLogin($0, credential: readCredential(for: $0)) }
            if existing.generation.id == current?.id {
                refreshJoins += 1
                let succeeded = await existing.task.value
                return succeeded && !Task.isCancelled && isCurrent(existing.generation, folder: folder)
            }
            // A replaced cookie is a new login even when the account and organization stay the same.
            // Keep one request in flight, but do not let the old response answer for the new login.
            previousLoginWaits += 1
            _ = await existing.task.value
            if flights[folder]?.id == existing.id {
                flights[folder] = nil
            }
        }
        // A cancelled waiter still leaves the old shared request alone, but must not start a
        // replacement request after waiting for a different login's flight to finish.
        guard !Task.isCancelled else { return false }
        guard let profile = profiles[folder] else { publish(); return false }
        // A new cookie is a new sign-in, which is asked about at once: that clears the last try.
        if policy != .forced, states[folder]?.failure == .signedOut {
            _ = observeLogin(profile, credential: readCredential(for: profile))
        }
        let state = states[folder] ?? FolderState()
        let now = clock.now()
        // claude.ai asked for fewer requests: nothing reads this login before the wait is over.
        if waitEnd(state, now: now) != nil { publish(); return false }
        let refused = state.failure == .signedOut
        let skip = switch policy {
        case .forced: false
        case .panel: tried(state, within: refused ? Self.refusedInterval : Self.panelInterval, now: now)
        case .automatic: tried(state, within: refused ? Self.refusedInterval : Self.throttleInterval, now: now) ||
            reusable(state, profile: profile, now: now)
        }
        if skip { publish(); return false }
        let credential = readCredential(for: profile)
        let generation = observeLogin(profile, credential: credential)
        let flight = Flight(generation: generation, task: Task {
            await self.perform(folder, profile: profile, credential: credential, generation: generation, policy: policy)
        })
        flights[folder] = flight
        let succeeded = await flight.task.value
        if flights[folder]?.id == flight.id {
            flights[folder] = nil
        }
        return succeeded && !Task.isCancelled && isCurrent(generation, folder: folder)
    }

    private func perform(_ folder: ProfileFolder, profile: QuotaProfile, credential: CredentialRead,
                         generation: LoginGeneration, policy: RefreshPolicy) async -> Bool {
        guard isCurrent(generation, folder: folder) else { publish(); return false }
        var state = states[folder] ?? FolderState()
        state.lastAttempt = clock.now()
        state.owner = Owner(profile)
        state.refreshing = true
        states[folder] = state
        publish()

        let result = await loadRemote(profile, credential: credential, generation: generation,
                                      askKeychain: policy == .forced, allowsKeychain: policy != .panel)
        state = states[folder] ?? state
        state.refreshing = false
        guard isCurrent(generation, folder: folder) else {
            // Neither a stale failure nor a stale success may overwrite a newer sign-in.
            states[folder] = state
            publish()
            return false
        }
        switch result {
        case .cancelled:
            states[folder] = state
            publish()
            return false
        case .success(let snapshot, let limitedUntil):
            state.network = snapshot
            state.failure = nil
            // A read that worked ends a run of limits, unless claude.ai refused part of it.
            state.notBefore = limitedUntil
            state.limits = limitedUntil == nil ? 0 : state.limits + 1
            states[folder] = state
            await store(snapshot, folder: folder)
            await storeWaits()
            log.info(.quota, "Refreshed quota for \(folder.name).")
            publish()
            return isCurrent(generation, folder: folder)
        case .failed(let failure):
            state.failure = failure
            if case .rateLimited(let until) = failure {
                state.notBefore = until
                state.limits += 1
            }
            if !failure.needsSignIn, !Self.matches(state.network, profile) {
                state.history = PlanUsageHistory.reading(for: profile)
            }
            states[folder] = state
            await storeWaits()
            log.warning(.quota, "Quota failed for \(folder.name) (\(Self.describe(failure))).")
            publish()
            return false
        }
    }

    /// When the wait claude.ai asked for ends. One longer than any it could be means the clock moved
    /// back, and is over too.
    private func waitEnd(_ state: FolderState, now: Date) -> Date? {
        guard let until = state.notBefore, until > now, until.timeIntervalSince(now) <= Self.limitCeiling else { return nil }
        return until
    }

    /// What claude.ai asked for outlasts this launch, for the login it was about.
    private func storeWaits() async {
        let now = clock.now()
        var waits: [String: QuotaWait] = [:]
        for (folder, state) in states {
            guard let owner = state.owner, let until = state.notBefore, until > now else { continue }
            waits[folder.name] = QuotaWait(account: owner.account, organization: owner.organization, until: until, limits: state.limits)
        }
        guard waits != storedWaits else { return }
        storedWaits = waits
        do { try await cache.saveWaits(waits) }
        catch { log.warning(.quota, "Kept a wait claude.ai asked for in memory only.") }
    }

    private func isCurrent(_ generation: LoginGeneration, folder: ProfileFolder) -> Bool {
        profiles[folder].map(Owner.init) == generation.stamp.owner &&
            loginGenerations[folder]?.id == generation.id
    }

    private func observeLogin(_ profile: QuotaProfile, credential: CredentialRead) -> LoginGeneration {
        let stamp = LoginStamp(owner: Owner(profile), credential: credential.identity)
        if let existing = loginGenerations[profile.folder], existing.stamp == stamp { return existing }
        let generation = LoginGeneration(stamp: stamp)
        if let previous = loginGenerations[profile.folder], var state = states[profile.folder] {
            state.lastAttempt = nil
            // A different cookie has not yet proved that this account is signed in again.
            // Keep its authentication failure (and hidden figures) until the new refresh succeeds.
            if previous.stamp.owner != stamp.owner {
                state.failure = nil
                state.owner = nil
                state.notBefore = nil
                state.limits = 0
            }
            states[profile.folder] = state
        }
        loginGenerations[profile.folder] = generation
        return generation
    }

    private func loadRemote(_ profile: QuotaProfile, credential: CredentialRead, generation: LoginGeneration,
                            askKeychain: Bool, allowsKeychain: Bool) async -> FetchResult {
        let key: String
        do {
            key = try await sessionKey(credential: credential, askKeychain: askKeychain, allowsKeychain: allowsKeychain)
        } catch is CancellationError {
            return .cancelled
        } catch let failure as QuotaFailure {
            return .failed(failure)
        } catch {
            return .failed(.cookieUnreadable)
        }

        let account: AccountRecord
        do {
            account = try await client.fetchAccount(
                sessionKey: key,
                expectedAccount: profile.accountUUID,
                activeOrganization: profile.organizationUUID
            )
        } catch is CancellationError {
            return .cancelled
        } catch let error as ClaudeWebError {
            return .failed(failure(error, folder: profile.folder))
        } catch {
            return .failed(.transportFailed)
        }

        guard isCurrent(generation, folder: profile.folder) else { return .cancelled }
        let usage: UsageRecord
        do {
            usage = try await client.fetchUsage(
                sessionKey: key,
                organizationUUID: account.organizationUUID
            )
        } catch is CancellationError {
            return .cancelled
        } catch let error as ClaudeWebError {
            return .failed(failure(error, folder: profile.folder))
        } catch {
            return .failed(.transportFailed)
        }

        guard isCurrent(generation, folder: profile.folder) else { return .cancelled }
        let now = clock.now()
        var channel = SubscriptionChannel.unknown
        var checked: Date?, limitedUntil: Date?
        if let previous = states[profile.folder]?.network, Self.matches(previous, profile) {
            channel = previous.channel
            checked = previous.channelCheckedAt
        }
        if channelDue(profile, checked: checked, now: now) {
            noteChannelAttempt(profile, at: now)
            do {
                channel = try await client.fetchChannel(
                    sessionKey: key,
                    organizationUUID: account.organizationUUID
                )
                checked = now
            } catch is CancellationError {
                return .cancelled
            } catch {
                // The figures stand without it, but a 429 holds this login back like any other read.
                if let error = error as? ClaudeWebError, case .rateLimited(let until) = failure(error, folder: profile.folder) {
                    limitedUntil = until
                }
                log.warning(.quota, "Kept subscription channel for \(profile.folder.name).")
            }
        }

        let organization = QuotaText.nonEmpty(profile.organizationUUID) ?? account.organizationUUID
        return .success(
            QuotaSnapshot(
                folder: profile.folder,
                accountUUID: profile.accountUUID,
                organizationUUID: organization,
                plan: account.plan,
                email: account.email,
                channel: channel,
                fiveHour: usage.fiveHour,
                sevenDay: usage.sevenDay,
                fetchedAt: now,
                channelCheckedAt: checked,
                source: .network
            ),
            limitedUntil: limitedUntil
        )
    }

    private func readCredential(for profile: QuotaProfile) -> CredentialRead {
        do {
            guard let cookie = try cookies.sessionCookie(profile: profile.directory) else {
                return .failed(.cookieMissing)
            }
            return .cookie(cookie)
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(.cookieUnreadable)
        }
    }

    private func sessionKey(credential: CredentialRead, askKeychain: Bool,
                            allowsKeychain: Bool = true) async throws -> String {
        let cookie: EncryptedCookie
        switch credential {
        case .cookie(let value): cookie = value
        case .failed(let failure): throw failure
        case .cancelled: throw CancellationError()
        }
        if cookie.encryptedValue.isEmpty {
            guard let plain = cookie.plaintextValue else {
                throw QuotaFailure.cookieMissing
            }
            do {
                try CookiePlaintext.validate(plain)
            } catch {
                throw QuotaFailure.decryptFailed
            }
            return plain
        }
        do {
            if await decryptor.hasRememberedKey {
                return try await decryptor.open(cookie, password: nil)
            }
            if !allowsKeychain || (keychainDeclined && !askKeychain) {
                throw QuotaFailure.keyUnavailable
            }
            let password = try await keychainPassword()
            return try await decryptor.open(cookie, password: password)
        } catch let failure as QuotaFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CookieDecryptError where error == .keyUnavailable {
            throw QuotaFailure.keyUnavailable
        } catch {
            throw QuotaFailure.decryptFailed
        }
    }

    /// Gets the cookie key without a network read, as an automatic refresh would (so not after a
    /// refusal), from the first encrypted sign-in cookie, the current account's first.
    private func prepareKey() async {
        guard !keychainDeclined, !(await decryptor.hasRememberedKey) else { return }
        let ordered = profiles.values.sorted {
            ($0.folder == currentFolder ? 0 : 1, $0.folder.name) < ($1.folder == currentFolder ? 0 : 1, $1.folder.name)
        }
        for profile in ordered {
            guard let cookie = try? cookies.sessionCookie(profile: profile.directory),
                  !cookie.encryptedValue.isEmpty else { continue }
            if let password = try? await keychainPassword() {
                _ = try? await decryptor.open(cookie, password: password)
            }
            return
        }
    }

    /// A refused or failed password read stays refused for automatic refreshes.
    private func keychainPassword() async throws -> Data {
        do {
            let password = try await safeStorage.password()
            keychainDeclined = false
            return password
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            keychainDeclined = true
            throw QuotaFailure.keyUnavailable
        }
    }

    private func store(_ snapshot: QuotaSnapshot, folder: ProfileFolder) async {
        do {
            try await cache.update { cache in
                cache[folder] = snapshot
            }
        } catch {
            log.warning(.quota, "Kept prior quota file for \(folder.name).")
        }
    }

    private func channelDue(_ profile: QuotaProfile, checked: Date?, now: Date) -> Bool {
        if let checked = trusted(checked, now: now), now.timeIntervalSince(checked) < Self.channelInterval {
            return false
        }
        let state = states[profile.folder]
        let organization = profile.organizationUUID ?? ""
        if state?.channelAccount == profile.accountUUID,
           state?.channelOrganization == organization,
           let attempt = trusted(state?.channelAttempt, now: now),
           now.timeIntervalSince(attempt) < Self.channelInterval {
            return false
        }
        return true
    }

    private func noteChannelAttempt(_ profile: QuotaProfile, at now: Date) {
        var state = states[profile.folder] ?? FolderState()
        state.channelAttempt = now
        state.channelAccount = profile.accountUUID
        state.channelOrganization = profile.organizationUUID ?? ""
        states[profile.folder] = state
    }

    private func tried(_ state: FolderState, within interval: TimeInterval, now: Date) -> Bool {
        guard let last = trusted(state.lastAttempt, now: now) else { return false }
        return now.timeIntervalSince(last) < interval
    }

    /// A stamp more than a minute ahead is ignored, the same way a future fetch is.
    private func trusted(_ date: Date?, now: Date) -> Date? {
        guard let date else { return nil }
        if date.timeIntervalSince(now) > Self.futureSkew { return nil }
        return date
    }

    private func reusable(_ state: FolderState, profile: QuotaProfile, now: Date) -> Bool {
        guard let snapshot = state.network, Self.matches(snapshot, profile) else { return false }
        return withinFreshWindow(snapshot, now: now) && !Self.resetCrossed(snapshot, now: now)
    }

    private func withinFreshWindow(_ snapshot: QuotaSnapshot, now: Date) -> Bool {
        guard snapshot.source == .network else { return false }
        if snapshot.fetchedAt.timeIntervalSince(now) > Self.futureSkew { return false }
        return now.timeIntervalSince(snapshot.fetchedAt) < Self.freshInterval
    }

    private func runPeriodicRefresh() async {
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: nextDelay())
            } catch {
                return
            }
            if Task.isCancelled { return }
            if let currentFolder {
                await refresh([currentFolder], force: false)
            }
        }
    }

    private func nextDelay() -> Duration {
        let offset = min(Self.jitterLimit, max(-Self.jitterLimit, jitter.secondsOffset()))
        return .seconds(Self.periodicBase + offset)
    }

    private func ensureLoaded() async {
        let task: Task<Void, Never>
        if let existing = cacheLoad {
            cacheLoadJoins += 1
            task = existing
        } else {
            let created = Task { await self.readStoredCache() }
            cacheLoad = created
            task = created
        }
        await task.value
    }

    private func readStoredCache() async {
        if pauseCacheLoad {
            pauseCacheLoad = false
            await withCheckedContinuation { continuation in
                cacheLoadGate = continuation
            }
        }
        do {
            let stored = try await cache.load()
            for (folder, snapshot) in stored where states[folder]?.network == nil {
                var state = states[folder] ?? FolderState()
                state.network = snapshot
                states[folder] = state
            }
        } catch {
            log.warning(.quota, "Started without a quota cache.")
        }
        let now = clock.now()
        for (name, wait) in await cache.waits() where wait.until > now {
            guard let folder = try? ProfileFolder(name) else { continue }
            var state = states[folder] ?? FolderState()
            state.owner = Owner(account: wait.account, organization: wait.organization)
            state.notBefore = wait.until
            state.limits = wait.limits
            state.failure = .rateLimited(until: wait.until)
            states[folder] = state
            storedWaits[name] = wait
        }
    }

    func pauseNextCacheLoad() {
        pauseCacheLoad = true
    }

    func releaseCacheLoad() {
        let gate = cacheLoadGate
        cacheLoadGate = nil
        gate?.resume()
    }

    var cacheLoadIsPaused: Bool {
        cacheLoadGate != nil
    }

    /// Registers folders without reading the cache, so a test can overlap that read.
    func stageProfiles(_ incoming: [QuotaProfile]) {
        var indexed: [ProfileFolder: QuotaProfile] = [:]
        for profile in incoming {
            indexed[profile.folder] = profile
        }
        profiles = indexed
    }

    private func presented(now: Date) -> [ProfileFolder: QuotaReading] {
        var result: [ProfileFolder: QuotaReading] = [:]
        for (folder, profile) in profiles {
            result[folder] = reading(for: profile, now: now)
        }
        return result
    }

    private func reading(for profile: QuotaProfile, now: Date) -> QuotaReading {
        let state = states[profile.folder] ?? FolderState()
        if state.refreshing {
            if let failure = state.failure, failure.needsSignIn {
                return QuotaReading(snapshot: nil, freshness: .refreshing, lastError: failure)
            }
            return QuotaReading(
                snapshot: display(chosen(state, profile), now: now),
                freshness: .refreshing,
                lastError: nil
            )
        }
        if let failure = state.failure, failure.needsSignIn {
            return QuotaReading(snapshot: nil, freshness: .unavailable, lastError: failure)
        }
        guard let snapshot = chosen(state, profile) else {
            return QuotaReading(snapshot: nil, freshness: .unavailable, lastError: state.failure)
        }
        let shown = display(snapshot, now: now)
        if Self.resetCrossed(snapshot, now: now) {
            return QuotaReading(snapshot: shown, freshness: .resetPassed, lastError: state.failure)
        }
        if state.failure != nil || snapshot.source != .network || !withinFreshWindow(snapshot, now: now) {
            return QuotaReading(snapshot: shown, freshness: .stale, lastError: state.failure)
        }
        return QuotaReading(snapshot: shown, freshness: .fresh, lastError: nil)
    }

    private func chosen(_ state: FolderState, _ profile: QuotaProfile) -> QuotaSnapshot? {
        if let network = state.network, Self.matches(network, profile) {
            return network
        }
        if let history = state.history, Self.matches(history, profile) {
            return history
        }
        return nil
    }

    /// Passed resets display as 0% used, which is 100% remaining.
    private func display(_ snapshot: QuotaSnapshot?, now: Date) -> QuotaSnapshot? {
        guard let snapshot, Self.resetCrossed(snapshot, now: now) else { return snapshot }
        var copy = snapshot
        if Self.crossed(copy.fiveHour, fetchedAt: snapshot.fetchedAt, now: now) {
            copy.fiveHour.usedPercent = 0
        }
        if Self.crossed(copy.sevenDay, fetchedAt: snapshot.fetchedAt, now: now) {
            copy.sevenDay.usedPercent = 0
        }
        return copy
    }

    private static func resetCrossed(_ snapshot: QuotaSnapshot, now: Date) -> Bool {
        crossed(snapshot.fiveHour, fetchedAt: snapshot.fetchedAt, now: now)
            || crossed(snapshot.sevenDay, fetchedAt: snapshot.fetchedAt, now: now)
    }

    /// The percent belongs to the previous window only if the reset was still ahead at fetch.
    private static func crossed(_ window: QuotaWindow, fetchedAt: Date, now: Date) -> Bool {
        guard window.usedPercent != nil, let resets = window.resetsAt else { return false }
        return resets > fetchedAt && resets <= now
    }

    private static func matches(_ snapshot: QuotaSnapshot?, _ profile: QuotaProfile) -> Bool {
        guard let snapshot else { return false }
        guard snapshot.folder == profile.folder, snapshot.accountUUID == profile.accountUUID else {
            return false
        }
        if let organization = QuotaText.nonEmpty(profile.organizationUUID) {
            return snapshot.organizationUUID == organization
        }
        return true
    }

    private func failure(_ error: ClaudeWebError, folder: ProfileFolder) -> QuotaFailure {
        switch error {
        case .signedOut:
            .signedOut
        case .refused:
            .refused
        case .rateLimited(let asked):
            .rateLimited(until: clock.now().addingTimeInterval(
                Self.limitWait(asked: asked, limits: (states[folder]?.limits ?? 0) + 1)))
        case .httpFailure(let status):
            .httpFailure(status)
        case .redirected:
            .redirected
        case .bodyTooLarge:
            .bodyTooLarge
        case .timedOut:
            .timedOut
        case .transportFailed:
            .transportFailed
        case .invalidResponse:
            .invalidResponse
        case .accountMismatch:
            .accountMismatch
        case .organizationUnavailable:
            .organizationUnavailable
        }
    }

    /// The wait after a limit: what claude.ai asked for, a day at most, or else five minutes doubling
    /// with every limit in a row, an hour at most; never under a minute.
    static func limitWait(asked: TimeInterval?, limits: Int) -> TimeInterval {
        let wait = asked.map { min($0, limitCeiling) } ??
            min(limitBase * pow(2, Double(min(max(limits, 1), 8) - 1)), backoffCeiling)
        return max(wait, 60)
    }

    private static func describe(_ failure: QuotaFailure) -> String {
        switch failure {
        case .signedOut:
            "signedOut"
        case .refused:
            "refused"
        case .rateLimited(let until):
            "rateLimited until \(until.formatted(.iso8601))"
        case .cookieMissing:
            "cookieMissing"
        case .cookieUnreadable:
            "cookieUnreadable"
        case .decryptFailed:
            "decryptFailed"
        case .keyUnavailable:
            "keyUnavailable"
        case .accountMismatch:
            "accountMismatch"
        case .organizationUnavailable:
            "organizationUnavailable"
        case .invalidResponse:
            "invalidResponse"
        case .httpFailure(let status):
            "httpFailure(\(status))"
        case .redirected:
            "redirected"
        case .timedOut:
            "timedOut"
        case .transportFailed:
            "transportFailed"
        case .bodyTooLarge:
            "bodyTooLarge"
        }
    }

    private func publish() {
        let readings = presented(now: clock.now())
        guard readings != emitted else { return }
        emitted = readings
        for continuation in subscribers.values {
            continuation.yield(readings)
        }
    }

    private func attach(
        _ id: UUID,
        _ continuation: AsyncStream<[ProfileFolder: QuotaReading]>.Continuation
    ) async {
        await ensureLoaded()
        if detached.remove(id) != nil || Task.isCancelled {
            return
        }
        subscribers[id] = continuation
        continuation.yield(presented(now: clock.now()))
    }

    private func detach(_ id: UUID) {
        if subscribers.removeValue(forKey: id) == nil {
            detached.insert(id)
        }
    }

    private struct Flight {
        let id = UUID()
        let generation: LoginGeneration
        var task: Task<Bool, Never>
    }

    /// Only an opaque generation and a one-way cookie fingerprint live beyond the request.
    /// Neither the cookie nor its fingerprint is logged or persisted.
    private struct LoginGeneration: Sendable {
        let id = UUID()
        let stamp: LoginStamp
    }

    private struct LoginStamp: Equatable, Sendable {
        let owner: Owner
        let credential: CredentialIdentity
    }

    private enum CredentialIdentity: Equatable, Sendable {
        case cookie(Data), failed(QuotaFailure), cancelled
    }

    private enum CredentialRead: Sendable {
        case cookie(EncryptedCookie), failed(QuotaFailure), cancelled

        var identity: CredentialIdentity {
            switch self {
            case .failed(let failure): return .failed(failure)
            case .cancelled: return .cancelled
            case .cookie(let cookie):
                // Length-prefix every field, including optional presence, so field boundaries cannot alias.
                var bytes = Data()
                let fields: [Data?] = [Data(cookie.hostKey.utf8), Data(String(cookie.databaseVersion).utf8),
                                       cookie.encryptedValue, cookie.plaintextValue.map { Data($0.utf8) }]
                for field in fields {
                    if let field {
                        bytes.append(contentsOf: "\(field.count):".utf8)
                        bytes.append(field)
                    } else { bytes.append(contentsOf: "-:".utf8) }
                }
                return .cookie(Data(ChromiumCookieDecryptor.digest(of: bytes)))
            }
        }
    }

    /// The login a read is about: the account, and the organization once the profile names one.
    private struct Owner: Equatable, Sendable {
        let account: String
        let organization: String?

        init(_ profile: QuotaProfile) {
            account = profile.accountUUID
            organization = QuotaText.nonEmpty(profile.organizationUUID)
        }

        init(account: String, organization: String?) {
            self.account = account
            self.organization = organization
        }
    }

    /// Automatic reads skip a fresh reading and anything tried in the last two minutes; a panel
    /// opening skips only what was tried in the last 30 s; a retry the user asked for skips nothing
    /// but a wait claude.ai asked for. A login claude.ai turned away is tried by the first two once
    /// an hour, in case the refusal was about something else, or when its cookie changes.
    private enum RefreshPolicy: Equatable { case automatic, panel, forced }

    private struct FolderState {
        var network: QuotaSnapshot?
        var history: QuotaSnapshot?
        var failure: QuotaFailure?
        var refreshing = false
        var lastAttempt: Date?
        /// The login `failure` and `lastAttempt` were measured on.
        var owner: Owner?
        var channelAttempt: Date?
        var channelAccount: String?
        var channelOrganization: String?
        /// No read before this: claude.ai asked for fewer requests. `limits` counts such answers in
        /// a row, for a wait that grows when they name none.
        var notBefore: Date?
        var limits = 0
    }

    private enum FetchResult {
        /// With `limitedUntil`, claude.ai refused part of the read with a 429: the figures stand, the login waits.
        case success(QuotaSnapshot, limitedUntil: Date? = nil)
        case failed(QuotaFailure)
        case cancelled
    }

    private static let freshInterval: TimeInterval = 600
    private static let throttleInterval: TimeInterval = 120
    private static let panelInterval: TimeInterval = 30
    private static let refusedInterval: TimeInterval = 3_600
    private static let futureSkew: TimeInterval = 60
    private static let channelInterval: TimeInterval = 86_400
    private static let limitBase: TimeInterval = 300
    private static let backoffCeiling: TimeInterval = 3_600
    private static let limitCeiling: TimeInterval = 86_400
    private static let periodicBase = 600
    private static let jitterLimit = 90
}
