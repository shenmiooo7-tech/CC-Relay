import Foundation

public enum PreferenceInheritanceFailure: Error, Equatable, Sendable {
    case invalidConfiguration, accountChanged, concurrentChange
}

public struct PreparedCodePreference: Sendable {
    let file: URL
    let profile: URL
    let accountUUID: String
    let original: Data?
    let replacement: Data
    let permissions: Int
}

public struct CodePreferenceInheritance: Sendable {
    public static let fileName = "claude_desktop_config.json"
    private let io = SessionFileIO()

    public init() {}

    public func capture(profile: ProfileSnapshot) throws -> CodePreferenceIntent? {
        guard let identity = profile.identity else { return nil }
        let file = profile.url.appending(path: Self.fileName)
        guard try io.info(file) != nil else { return nil }
        let object = try SessionJSON.object(io.read(file), at: file)
        let preferences = object["preferences"] as? [String: Any]
        let choices = preferences?["bypassPermissionsOptInByAccount"] as? [String: Any]
        return SessionJSON.boolean(choices?[identity.accountUUID]).map {
            CodePreferenceIntent(sourceAccountUUID: identity.accountUUID, bypassOptIn: $0)
        }
    }

    /// Whether a conversation in bypass mode can go on in this profile: Claude allows the mode for
    /// its account, and the account has chosen it. Read only; an unreadable file counts as no.
    public func allowsBypass(profile: ProfileSnapshot) -> Bool {
        guard let account = profile.identity?.accountUUID else { return false }
        let file = profile.url.appending(path: Self.fileName)
        guard let data = try? io.read(file), let object = try? SessionJSON.object(data, at: file),
              let preferences = object["preferences"] as? [String: Any] else { return false }
        let choices = preferences["bypassPermissionsOptInByAccount"] as? [String: Any]
        let gates = preferences["bypassPermissionsGateByAccount"] as? [String: Any]
        return SessionJSON.boolean(gates?[account]) == true && SessionJSON.boolean(choices?[account]) == true
    }

    public func prepare(intent: CodePreferenceIntent?, target: ProfileSnapshot) throws -> PreparedCodePreference? {
        guard let intent, let account = target.identity?.accountUUID else { return nil }
        guard try ProfileConfigReader().read(profile: target.url).accountUUID == account else {
            throw PreferenceInheritanceFailure.accountChanged
        }
        let file = target.url.appending(path: Self.fileName)
        try io.checkPath(file, under: target.url)
        let info = try io.info(file)
        if let info, !io.isRegular(info) { throw SessionDataError.unexpectedType(file) }
        let original = try info.map { _ in try io.read(file) }
        var object = try original.map { try SessionJSON.object($0, at: file) } ?? [:]
        if let value = object["preferences"], !(value is [String: Any]) {
            throw PreferenceInheritanceFailure.invalidConfiguration
        }
        var preferences = object["preferences"] as? [String: Any] ?? [:]
        let choiceKey = "bypassPermissionsOptInByAccount"
        let gateKey = "bypassPermissionsGateByAccount"
        if let value = preferences[choiceKey], !(value is [String: Any]) {
            throw PreferenceInheritanceFailure.invalidConfiguration
        }
        var choices = preferences[choiceKey] as? [String: Any] ?? [:]
        // Any existing entry belongs to Desktop/the user, including an unknown future value.
        guard choices[account] == nil else { return nil }
        let gates = preferences[gateKey] as? [String: Any] ?? [:]
        if intent.bypassOptIn && SessionJSON.boolean(gates[account]) != true { return nil }
        choices[account] = intent.bypassOptIn
        preferences[choiceKey] = choices
        object["preferences"] = preferences
        return PreparedCodePreference(file: file, profile: target.url, accountUUID: account,
            original: original, replacement: try SessionJSON.compact(object),
            permissions: info.map { Int($0.st_mode & 0o777) } ?? 0o600)
    }

    public func apply(_ prepared: PreparedCodePreference?) throws {
        try apply(prepared, beforeCommit: {})
    }

    func apply(_ prepared: PreparedCodePreference?, beforeCommit: () throws -> Void) throws {
        guard let prepared else { return }
        let stage = prepared.file.deletingLastPathComponent().appending(path: ".code-preference-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try AtomicFile.write(prepared.replacement, to: stage, permissions: prepared.permissions)
        try beforeCommit()
        try io.checkPath(prepared.file, under: prepared.profile)
        guard try ProfileConfigReader().read(profile: prepared.profile).accountUUID == prepared.accountUUID else {
            throw PreferenceInheritanceFailure.accountChanged
        }
        let info = try io.info(prepared.file)
        if let info, !io.isRegular(info) { throw SessionDataError.unexpectedType(prepared.file) }
        let current = try info.map { _ in try io.read(prepared.file) }
        guard current == prepared.original else { throw PreferenceInheritanceFailure.concurrentChange }
        try io.rename(stage, prepared.file, replacing: true)
    }
}
