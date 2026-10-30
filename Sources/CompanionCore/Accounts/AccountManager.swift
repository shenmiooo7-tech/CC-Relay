import Darwin
import Foundation

public enum AccountManagementError: Error, Equatable, Sendable {
    case refused(FailureReason)
    case invalidName
}

public enum SignInResult: Sendable {
    case waiting
    case duplicate(ProfileFolder)
    case completed(ProfileFolder, details: AccountRecord?)
}

public actor AccountManager {
    private let paths: AppPaths
    private let store: StateStore
    private let lifecycle: ClaudeLifecycle
    private let guardService: TaskGuard
    private let cookies: any SessionCookieReading
    private let details: any AccountDetailsProviding
    private let cache: QuotaCacheStore
    private let clock: any Clock
    private let scanner: ProfileScanner
    private let preferences = CodePreferenceInheritance()
    private let io = SessionFileIO()
    private let log: CompanionLog
    /// The sign-in cookie the service last turned down, per folder: it is not sent again.
    private var refusedCookies: [ProfileFolder: EncryptedCookie] = [:]

    public init(paths: AppPaths, store: StateStore, lifecycle: ClaudeLifecycle, taskGuard: TaskGuard,
                cookies: any SessionCookieReading, details: any AccountDetailsProviding,
                cache: QuotaCacheStore, clock: any Clock, log: CompanionLog) {
        self.paths = paths
        self.store = store
        self.lifecycle = lifecycle
        guardService = taskGuard
        self.cookies = cookies
        self.details = details
        self.cache = cache
        self.clock = clock
        self.log = log
        scanner = ProfileScanner(paths: paths)
    }

    public func begin(prompt: @escaping @Sendable (TaskGuardPrompt?) async -> Void,
                      progress: @escaping @Sendable (OperationState) async -> Void) async throws -> ProfileFolder {
        let state = try await store.load()
        let profiles = try scanner.scan(managed: state.accounts.map(\.folder)).profiles
        let defaultFolder = try ProfileFolder("Claude")
        let returnTo = state.activeFolder ?? state.accounts.first?.folder ?? defaultFolder
        let permission = await guardService.check(target: returnTo, publish: prompt)
        if case .cancelled = permission { throw AccountManagementError.refused(.cancelled) }
        let donors = profiles.filter { profile in
            guard state.accounts.contains(where: { $0.folder == profile.folder }),
                  let bucket = profile.readableBucket,
                  let info = try? io.info(profile.url.appending(path: bucket.relativePath)) else { return false }
            return io.isDirectory(info)
        }.compactMap { profile -> HistoryDonor? in
            guard let identity = profile.identity, let org = identity.activeOrganizationUUID else { return nil }
            return HistoryDonor(folder: profile.folder, accountUUID: identity.accountUUID, organizationUUID: org)
        }.sorted { $0.folder.name < $1.folder.name }
        var preference: CodePreferenceIntent?
        if let current = profiles.first(where: { $0.folder == returnTo }) {
            do { preference = try preferences.capture(profile: current) }
            catch { log.warning(.sync, "The source Code preference could not be captured.") }
        }
        await progress(.addingAccount(phase: .closingClaude))
        let running = try await lifecycle.processes.runningInstances()
        let previouslyOpen = running.compactMap { try? ProfileFolder($0.profileDirectory.lastPathComponent) }
        let bystanders = running.compactMap { instance -> ProfileFolder? in
            guard !ProfilePaths.same(instance.profileDirectory, directory(returnTo)) else { return nil }
            return try? ProfileFolder(instance.profileDirectory.lastPathComponent)
        }
        do {
            try await lifecycle.close(owing: previouslyOpen, allowForce: Self.isOverride(permission))
        } catch { throw AccountManagementError.refused(.couldNotCloseClaude) }
        let folder: ProfileFolder
        do {
            folder = try createProfile()
            let now = clock.now()
            let pending = PendingSignIn(folder: folder, createdAt: now, returnToFolder: returnTo)
            let job = HistoryJob(target: folder, donors: donors, codePreference: preference, createdAt: now)
            do {
                try await store.update {
                    $0.pendingSignIns.append(pending)
                    $0.historyJobs.append(job)
                    // The new account opens instead of the one it returns to. What earlier operations
                    // owe for profiles this close did not touch stays owed.
                    let earlier = $0.relaunchDebt.filter { !previouslyOpen.contains($0) }
                    var seen = Set<ProfileFolder>()
                    $0.relaunchDebt = ([folder] + bystanders + earlier).filter { seen.insert($0).inserted }
                }
            } catch {
                _ = try? archive(folder)
                throw error
            }
        } catch {
            try? await lifecycle.relaunchOwed()
            throw error
        }
        await progress(.addingAccount(phase: .openingClaude))
        do { try await lifecycle.relaunchOwed(target: folder) }
        catch {
            await abandon(folder, reopening: previouslyOpen.contains(returnTo) ? returnTo : nil)
            throw AccountManagementError.refused(.couldNotOpenClaude)
        }
        try await store.update { $0.activeFolder = folder }
        await progress(.addingAccount(phase: .waitingForSignIn))
        return folder
    }

    /// The new account did not open: no sign-in is left waiting for a window that is not there, its
    /// empty folder goes to the archive, and the account it replaced opens again. A Claude that runs
    /// on the new folder after all, or a helper still using it, keeps everything as it is, for the
    /// user to sign in or cancel.
    private func abandon(_ folder: ProfileFolder, reopening previous: ProfileFolder?) async {
        do {
            let running = try await lifecycle.processes.runningInstances()
            guard !running.contains(where: { ProfilePaths.same($0.profileDirectory, directory(folder)) }) else { return }
            // A helper can outlive its main instance: a folder any Claude process may still use is not moved.
            let inUse = try await lifecycle.processes.profilesInUse()
            guard !inUse.unattributed, !inUse.profiles.contains(where: { ProfilePaths.same($0, directory(folder)) }) else { return }
            // The records go first: a folder they still name is never archived from under them.
            try await store.update {
                $0.pendingSignIns.removeAll { $0.folder == folder }
                $0.historyJobs.removeAll { $0.target == folder }
                $0.relaunchDebt.removeAll { $0 == folder }
                if let previous, !$0.relaunchDebt.contains(previous) { $0.relaunchDebt.insert(previous, at: 0) }
            }
        } catch {
            log.warning(.app, "A new account that did not open could not be set aside.")
            return
        }
        do { _ = try archive(folder) }
        catch { log.warning(.app, "The empty folder of a new account that did not open could not be archived.") }
        guard let previous else { return }
        try? await lifecycle.relaunchOwed(target: previous)
    }

    private func createProfile() throws -> ProfileFolder {
        try io.makeDirectory(paths.claudeProfilesRoot)
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        for _ in 0..<100 {
            let candidate = try ProfileFolder("Claude_" + String((0..<6).map { _ in alphabet.randomElement()! }))
            let url = directory(candidate)
            guard try io.info(url) == nil else { continue }
            if mkdir(url.path, 0o700) != 0 {
                if errno == EEXIST { continue }
                throw SessionDataError.filesystem(url, code: errno)
            }
            if chmod(url.path, 0o700) != 0 {
                let code = errno
                _ = try? archive(candidate)
                throw SessionDataError.filesystem(url, code: code)
            }
            return candidate
        }
        throw SessionDataError.noAvailableName(paths.claudeProfilesRoot)
    }

    public func detectSignIn(_ pending: PendingSignIn, keepDuplicate: Bool = false) async throws -> SignInResult {
        let state = try await store.load()
        guard state.pendingSignIns.contains(pending) else { return .waiting }
        let profiles = try scanner.scan(managed: state.accounts.map(\.folder), pending: state.pendingSignIns.map(\.folder)).profiles
        guard let profile = profiles.first(where: { $0.folder == pending.folder }),
              let identity = profile.identity, identity.activeOrganizationUUID != nil,
              let cookie = try? cookies.sessionCookie(profile: profile.url) else { return .waiting }
        if let expected = pending.expectAccountUUID, expected != identity.accountUUID {
            throw AccountManagementError.refused(.signedInAccountDiffers)
        }
        if !state.accounts.contains(where: { $0.folder == pending.folder }), !keepDuplicate,
           let duplicate = profiles.first(where: { other in
               other.folder != pending.folder && state.accounts.contains { $0.folder == other.folder } &&
               other.identity?.accountUUID == identity.accountUUID
           }) { return .duplicate(duplicate.folder) }
        var email: String?
        var fetchedDetails: AccountRecord?
        if let quota = profile.quotaProfile {
            // A cookie the service turned down is not sent again every poll; signing in again
            // writes a new one (the login in config.json stays the same), and that one is asked about.
            guard refusedCookies[pending.folder] != cookie else { return .waiting }
            do {
                let account = try await details.accountDetails(for: quota)
                guard account.accountUUID == identity.accountUUID,
                      account.organizationUUID == identity.activeOrganizationUUID else { throw QuotaFailure.accountMismatch }
                email = account.email
                fetchedDetails = account
            } catch QuotaFailure.signedOut {
                refusedCookies[pending.folder] = cookie
                return .waiting
            } catch QuotaFailure.accountMismatch {
                throw AccountManagementError.refused(.signedInAccountDiffers)
            } catch is CancellationError {
                throw CancellationError()
            } catch { log.info(.quota, "Account details unavailable during registration; automatic naming remains pending.") }
        }
        let proposed = Self.emailName(email) ?? Self.placeholder(language: state.settings.language, firstRun: false)
        let name = Self.uniqueName(proposed, accounts: state.accounts, excluding: pending.folder)
        let managed = ManagedAccount(folder: pending.folder, displayName: name, addedAt: clock.now(),
                                     nameIsAutomatic: Self.emailName(email) == nil)
        try await store.update { state in
            guard state.pendingSignIns.contains(pending) else { return }
            if !state.accounts.contains(where: { $0.folder == pending.folder }) { state.accounts.append(managed) }
            state.pendingSignIns.removeAll { $0 == pending }
            state.activeFolder = pending.folder
            if let index = state.historyJobs.firstIndex(where: { $0.target == pending.folder }) {
                state.historyJobs[index].targetAccountUUID = identity.accountUUID
                state.historyJobs[index].targetOrganizationUUID = identity.activeOrganizationUUID
                state.historyJobs[index].revision += 1
            }
        }
        refusedCookies[pending.folder] = nil
        return .completed(pending.folder, details: fetchedDetails)
    }

    public func recordSignInAgain(folder: ProfileFolder, expected: String?) async throws {
        let state = try await store.load()
        let pending = PendingSignIn(folder: folder, createdAt: clock.now(),
            returnToFolder: state.activeFolder ?? folder, expectAccountUUID: expected)
        try await store.update { state in
            state.pendingSignIns.removeAll { $0.folder == folder }
            state.pendingSignIns.append(pending)
        }
    }

    /// A sign-in again is waited for in the Claude window opened for it. A switch to another
    /// account closes that window, so the wait ends with the switch.
    public func endSignInAgain(except folder: ProfileFolder) async throws {
        let state = try await store.load()
        let managed = Set(state.accounts.map(\.folder))
        let ended: @Sendable (PendingSignIn) -> Bool = { $0.folder != folder && managed.contains($0.folder) }
        guard state.pendingSignIns.contains(where: ended) else { return }
        try await store.update { $0.pendingSignIns.removeAll(where: ended) }
    }

    public func cancel(folder: ProfileFolder, prompt: @escaping @Sendable (TaskGuardPrompt?) async -> Void) async throws {
        let state = try await store.load()
        guard let pending = state.pendingSignIns.first(where: { $0.folder == folder }) else { return }
        let permission = await guardService.check(target: pending.returnToFolder, publish: prompt)
        if case .cancelled = permission { throw AccountManagementError.refused(.cancelled) }
        let running = try await lifecycle.processes.runningInstances()
        let bystanders = running.filter { !ProfilePaths.same($0.profileDirectory, directory(folder)) }
            .compactMap { try? ProfileFolder($0.profileDirectory.lastPathComponent) }
        do { try await lifecycle.close(owing: [pending.returnToFolder] + bystanders, allowForce: Self.isOverride(permission)) }
        catch { throw AccountManagementError.refused(.couldNotCloseClaude) }
        do {
            // Closing only owns its captured process set. A late helper can outlive that
            // set without a main instance, so prove the app is closed before moving a profile.
            let stillRunning: Bool
            do { stillRunning = try await lifecycle.processes.hasAnyProcess() }
            catch { throw AccountManagementError.refused(.runningStateUnknown) }
            guard !stillRunning else { throw AccountManagementError.refused(.refusedWhileRunning) }
            if !state.accounts.contains(where: { $0.folder == folder }) { _ = try archive(folder) }
            try await store.update {
                $0.pendingSignIns.removeAll { $0.folder == folder }
                $0.historyJobs.removeAll { $0.target == folder }
                $0.activeFolder = pending.returnToFolder
            }
        } catch {
            try? await lifecycle.relaunchOwed(target: pending.returnToFolder)
            throw error
        }
        try await lifecycle.relaunchOwed(target: pending.returnToFolder)
    }

    public func rename(folder: ProfileFolder, name: String) async throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...20).contains(trimmed.count) else { throw AccountManagementError.invalidName }
        try await store.update { state in
            guard let index = state.accounts.firstIndex(where: { $0.folder == folder }) else { return }
            state.accounts[index].displayName = trimmed
            state.accounts[index].nameIsAutomatic = false
        }
    }

    public func remove(folder: ProfileFolder) async throws -> Bool {
        let state = try await store.load()
        guard folder != state.activeFolder else { throw AccountManagementError.refused(.refusedActiveAccount) }
        guard state.accounts.count > 1 else { throw AccountManagementError.refused(.refusedLastAccount) }
        guard state.accounts.contains(where: { $0.folder == folder }) else { throw AccountManagementError.refused(.targetMissing) }
        let running: [ClaudeInstance]
        let inUse: ProfilesInUse
        do {
            running = try await lifecycle.processes.runningInstances()
            inUse = try await lifecycle.processes.profilesInUse()
        } catch { throw AccountManagementError.refused(.runningStateUnknown) }
        let target = directory(folder)
        // Helpers and the tasks under them can outlive their main process and still use the folder.
        guard !running.contains(where: { ProfilePaths.same($0.profileDirectory, target) }),
              !inUse.profiles.contains(where: { ProfilePaths.same($0, target) }) else {
            throw AccountManagementError.refused(.refusedWhileRunning)
        }
        // One that names no profile may be this account's: the folder stays until that is known.
        guard !inUse.unattributed else { throw AccountManagementError.refused(.runningStateUnknown) }
        _ = try archive(folder)
        var partial = false
        do {
            try await store.update {
                $0.accounts.removeAll { $0.folder == folder }
                $0.pendingSignIns.removeAll { $0.folder == folder }
                $0.historyJobs.removeAll { $0.target == folder }
                $0.knownUnmanagedFolders.removeAll { $0 == folder }
                // An archived folder is never reopened: Claude would start an empty profile there.
                $0.relaunchDebt.removeAll { $0 == folder }
            }
        } catch { partial = true }
        do { try await cache.update { $0[folder] = nil } }
        catch { partial = true }
        return partial
    }

    @discardableResult
    private func archive(_ folder: ProfileFolder) throws -> URL {
        let source = directory(folder)
        try io.checkPath(source, under: paths.claudeProfilesRoot)
        try io.requireDirectory(source)
        let root = paths.companionDataDirectory.appending(path: "Archive")
        try io.makeDirectory(root)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = folder.name + "-" + formatter.string(from: clock.now())
        for suffix in 0..<100 {
            let destination = root.appending(path: base + (suffix == 0 ? "" : "-\(suffix)"))
            guard try io.info(destination) == nil else { continue }
            try io.rename(source, destination)
            return destination
        }
        throw SessionDataError.noAvailableName(root)
    }

    private func directory(_ folder: ProfileFolder) -> URL { paths.claudeProfilesRoot.appending(path: folder.name) }
    private static func isOverride(_ permission: TaskGuardPermission) -> Bool {
        if case .override = permission { return true }; return false
    }

    static func emailName(_ email: String?) -> String? {
        guard let email, let local = email.split(separator: "@", omittingEmptySubsequences: false).first,
              !local.isEmpty else { return nil }
        return String(local.prefix(20))
    }

    static func placeholder(language: AppLanguage, firstRun: Bool) -> String {
        let chinese = language == .zhHans || (language == .system && Locale.preferredLanguages.first?.hasPrefix("zh") == true)
        return chinese ? (firstRun ? "默认账号" : "新账号") : (firstRun ? "Default" : "New account")
    }

    static func uniqueName(_ proposed: String, accounts: [ManagedAccount], excluding: ProfileFolder? = nil) -> String {
        let used = Set(accounts.filter { $0.folder != excluding }.map(\.displayName))
        let base = String(proposed.prefix(20))
        if !used.contains(base) { return base }
        var number = 2
        while true {
            let suffix = "-\(number)"
            let name = String(base.prefix(max(1, 20 - suffix.count))) + suffix
            if !used.contains(name) { return name }
            number += 1
        }
    }
}
