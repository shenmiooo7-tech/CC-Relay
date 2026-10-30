import Foundation

public struct PendingSignIn: Equatable, Sendable, Codable {
    public var folder: ProfileFolder
    public var createdAt: Date
    public var returnToFolder: ProfileFolder
    public var expectAccountUUID: String?

    public init(
        folder: ProfileFolder,
        createdAt: Date,
        returnToFolder: ProfileFolder,
        expectAccountUUID: String? = nil
    ) {
        self.folder = folder
        self.createdAt = createdAt
        self.returnToFolder = returnToFolder
        self.expectAccountUUID = expectAccountUUID
    }
}

public struct HistoryDonor: Equatable, Sendable, Codable, Hashable {
    public var folder: ProfileFolder
    public var accountUUID: String
    public var organizationUUID: String

    public init(folder: ProfileFolder, accountUUID: String, organizationUUID: String) {
        self.folder = folder
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
    }
}

public struct CodePreferenceIntent: Equatable, Sendable, Codable, Hashable {
    public var sourceAccountUUID: String
    public var bypassOptIn: Bool

    public init(sourceAccountUUID: String, bypassOptIn: Bool) {
        self.sourceAccountUUID = sourceAccountUUID
        self.bypassOptIn = bypassOptIn
    }
}

/// Why a history import is waiting. An unknown raw value decodes as `.failed`.
/// A non-string value still throws.
public enum HistoryIssue: String, Equatable, Sendable, Codable {
    case interrupted
    case failed
    case unavailable

    public init(from decoder: Decoder) throws {
        self = try LenientStringEnum.decode(from: decoder, fallback: .failed)
    }

    public func encode(to encoder: Encoder) throws {
        try LenientStringEnum.encode(self, to: encoder)
    }
}

public struct HistoryJob: Equatable, Sendable, Codable {
    public var target: ProfileFolder
    public var targetAccountUUID: String?
    public var targetOrganizationUUID: String?
    public var donors: [HistoryDonor]
    public var codePreference: CodePreferenceIntent?
    public var paused: Bool
    public var issue: HistoryIssue?
    public var revision: UInt64
    public var createdAt: Date

    public init(
        target: ProfileFolder,
        targetAccountUUID: String? = nil,
        targetOrganizationUUID: String? = nil,
        donors: [HistoryDonor] = [],
        codePreference: CodePreferenceIntent? = nil,
        paused: Bool = false,
        issue: HistoryIssue? = nil,
        revision: UInt64 = 0,
        createdAt: Date
    ) {
        self.target = target
        self.targetAccountUUID = targetAccountUUID
        self.targetOrganizationUUID = targetOrganizationUUID
        self.donors = donors
        self.codePreference = codePreference
        self.paused = paused
        self.issue = issue
        self.revision = revision
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case target
        case targetAccountUUID
        case targetOrganizationUUID
        case donors
        case codePreference
        case paused
        case issue
        case revision
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.target = try container.decode(ProfileFolder.self, forKey: .target)
        self.targetAccountUUID = try JSONFields.optional(String.self, from: container, forKey: .targetAccountUUID)
        self.targetOrganizationUUID = try JSONFields.optional(
            String.self,
            from: container,
            forKey: .targetOrganizationUUID
        )
        self.donors = try JSONFields.value([HistoryDonor].self, from: container, forKey: .donors, default: [])
        self.codePreference = try JSONFields.optional(
            CodePreferenceIntent.self,
            from: container,
            forKey: .codePreference
        )
        self.paused = try JSONFields.value(Bool.self, from: container, forKey: .paused, default: false)
        self.issue = try JSONFields.optional(HistoryIssue.self, from: container, forKey: .issue)
        self.revision = try JSONFields.value(UInt64.self, from: container, forKey: .revision, default: 0)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
