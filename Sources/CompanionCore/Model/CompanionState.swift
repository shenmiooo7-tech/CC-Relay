import Foundation

/// Durable registry written to `state.json`.
///
/// `schemaVersion` is 1. Missing keys load as empty defaults. Unknown keys are
/// ignored. Any other schema version fails decoding so a newer file can be
/// preserved aside instead of being rewritten without the fields we do not know.
/// A record inside `accounts`, `pendingSignIns`, `historyJobs`, `relaunchDebt`,
/// or `knownUnmanagedFolders` that cannot be decoded is skipped; the other
/// records are kept.
public struct CompanionState: Equatable, Sendable, Codable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var accounts: [ManagedAccount]
    public var activeFolder: ProfileFolder?
    public var settings: Settings
    public var pendingSignIns: [PendingSignIn]
    public var historyJobs: [HistoryJob]
    public var relaunchDebt: [ProfileFolder]
    public var knownUnmanagedFolders: [ProfileFolder]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        accounts: [ManagedAccount] = [],
        activeFolder: ProfileFolder? = nil,
        settings: Settings = Settings(),
        pendingSignIns: [PendingSignIn] = [],
        historyJobs: [HistoryJob] = [],
        relaunchDebt: [ProfileFolder] = [],
        knownUnmanagedFolders: [ProfileFolder] = []
    ) {
        self.schemaVersion = schemaVersion
        self.accounts = accounts
        self.activeFolder = activeFolder
        self.settings = settings
        self.pendingSignIns = pendingSignIns
        self.historyJobs = historyJobs
        self.relaunchDebt = relaunchDebt
        self.knownUnmanagedFolders = knownUnmanagedFolders
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case accounts
        case activeFolder
        case settings
        case pendingSignIns
        case historyJobs
        case relaunchDebt
        case knownUnmanagedFolders
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try JSONFields.value(
            Int.self,
            from: container,
            forKey: .schemaVersion,
            default: Self.currentSchemaVersion
        )
        guard version == Self.currentSchemaVersion else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath + [CodingKeys.schemaVersion],
                    debugDescription: "Unsupported schema version."
                )
            )
        }
        self.schemaVersion = version
        let skips = decoder.userInfo[DecodeSkips.userInfoKey] as? DecodeSkips
        self.accounts = try JSONFields.lenientArray(
            ManagedAccount.self,
            from: container,
            forKey: .accounts,
            path: "accounts",
            skips: skips
        )
        self.activeFolder = try JSONFields.optional(ProfileFolder.self, from: container, forKey: .activeFolder)
        self.settings = try JSONFields.value(Settings.self, from: container, forKey: .settings, default: Settings())
        self.pendingSignIns = try JSONFields.lenientArray(
            PendingSignIn.self,
            from: container,
            forKey: .pendingSignIns,
            path: "pendingSignIns",
            skips: skips
        )
        self.historyJobs = try JSONFields.lenientArray(
            HistoryJob.self,
            from: container,
            forKey: .historyJobs,
            path: "historyJobs",
            skips: skips
        )
        self.relaunchDebt = try JSONFields.lenientArray(
            ProfileFolder.self,
            from: container,
            forKey: .relaunchDebt,
            path: "relaunchDebt",
            skips: skips
        )
        self.knownUnmanagedFolders = try JSONFields.lenientArray(
            ProfileFolder.self,
            from: container,
            forKey: .knownUnmanagedFolders,
            path: "knownUnmanagedFolders",
            skips: skips
        )
    }
}
