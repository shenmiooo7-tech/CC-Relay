import Foundation

public struct AccountIdentity: Equatable, Sendable, Codable {
    public var accountUUID: String
    public var activeOrganizationUUID: String?
    public var knownOrganizationUUIDs: [String]
    public var email: String?
    public var plan: String?

    public init(
        accountUUID: String,
        activeOrganizationUUID: String? = nil,
        knownOrganizationUUIDs: [String] = [],
        email: String? = nil,
        plan: String? = nil
    ) {
        self.accountUUID = accountUUID
        self.activeOrganizationUUID = activeOrganizationUUID
        self.knownOrganizationUUIDs = knownOrganizationUUIDs
        self.email = email
        self.plan = plan
    }

    private enum CodingKeys: String, CodingKey {
        case accountUUID
        case activeOrganizationUUID
        case knownOrganizationUUIDs
        case email
        case plan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.accountUUID = try container.decode(String.self, forKey: .accountUUID)
        self.activeOrganizationUUID = try JSONFields.optional(
            String.self,
            from: container,
            forKey: .activeOrganizationUUID
        )
        self.knownOrganizationUUIDs = try JSONFields.value(
            [String].self,
            from: container,
            forKey: .knownOrganizationUUIDs,
            default: []
        )
        self.email = try JSONFields.optional(String.self, from: container, forKey: .email)
        self.plan = try JSONFields.optional(String.self, from: container, forKey: .plan)
    }

    /// Whether a reading or account record is about this login. With no organization stamp the
    /// quota service reads the account's only organization, so any organization belongs to it.
    public func matches(account: String, organization: String) -> Bool {
        account == accountUUID && (activeOrganizationUUID.map { $0 == organization } ?? true)
    }
}

/// Why a profile could not be read. An unknown raw value decodes as
/// `.configUnparsable`. A non-string value still throws.
public enum ProfileUnreadability: String, Equatable, Sendable, Codable {
    case configUnparsable
    case unreadableDirectory

    public init(from decoder: Decoder) throws {
        self = try LenientStringEnum.decode(from: decoder, fallback: .configUnparsable)
    }

    public func encode(to encoder: Encoder) throws {
        try LenientStringEnum.encode(self, to: encoder)
    }
}

public enum ProfileStatus: Equatable, Sendable, Codable {
    case signedIn(AccountIdentity)
    case awaitingSignIn
    case signedOut(lastAccountUUID: String?)
    case unreadable(reason: ProfileUnreadability)
}

public struct SessionBucket: Equatable, Hashable, Sendable, Codable {
    public let accountUUID: String
    public let organizationUUID: String

    public var relativePath: String {
        "claude-code-sessions/\(accountUUID)/\(organizationUUID)"
    }

    public init(accountUUID: String, organizationUUID: String) throws {
        self.accountUUID = try Self.component(accountUUID)
        self.organizationUUID = try Self.component(organizationUUID)
    }

    private enum CodingKeys: String, CodingKey {
        case accountUUID
        case organizationUUID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            accountUUID: try container.decode(String.self, forKey: .accountUUID),
            organizationUUID: try container.decode(String.self, forKey: .organizationUUID)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(accountUUID, forKey: .accountUUID)
        try container.encode(organizationUUID, forKey: .organizationUUID)
    }

    private static func component(_ value: String) throws -> String {
        if value.isEmpty {
            throw ProfileFolderError.empty
        }
        if value == "." || value == ".." {
            throw ProfileFolderError.reserved
        }
        if value.contains("/") || value.contains("\0") {
            throw ProfileFolderError.notASingleComponent
        }
        return value
    }
}

public struct ProfileSnapshot: Equatable, Sendable, Codable {
    public var folder: ProfileFolder
    public var url: URL
    public var status: ProfileStatus
    public var sessionBuckets: [SessionBucket]
    public var readableBucket: SessionBucket?
    public var duplicateOf: ProfileFolder?

    public init(
        folder: ProfileFolder,
        url: URL,
        status: ProfileStatus,
        sessionBuckets: [SessionBucket] = [],
        readableBucket: SessionBucket? = nil,
        duplicateOf: ProfileFolder? = nil
    ) {
        self.folder = folder
        self.url = url
        self.status = status
        self.sessionBuckets = sessionBuckets
        self.readableBucket = readableBucket
        self.duplicateOf = duplicateOf
    }

    private enum CodingKeys: String, CodingKey {
        case folder
        case url
        case status
        case sessionBuckets
        case readableBucket
        case duplicateOf
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.folder = try container.decode(ProfileFolder.self, forKey: .folder)
        self.url = try container.decode(URL.self, forKey: .url)
        self.status = try container.decode(ProfileStatus.self, forKey: .status)
        self.sessionBuckets = try JSONFields.value(
            [SessionBucket].self,
            from: container,
            forKey: .sessionBuckets,
            default: []
        )
        self.readableBucket = try JSONFields.optional(
            SessionBucket.self,
            from: container,
            forKey: .readableBucket
        )
        self.duplicateOf = try JSONFields.optional(ProfileFolder.self, from: container, forKey: .duplicateOf)
    }
}

public struct ManagedAccount: Equatable, Sendable, Codable {
    public var folder: ProfileFolder
    public var displayName: String
    public var addedAt: Date
    public var nameIsAutomatic: Bool

    public init(folder: ProfileFolder, displayName: String, addedAt: Date, nameIsAutomatic: Bool = false) {
        self.folder = folder
        self.displayName = displayName
        self.addedAt = addedAt
        self.nameIsAutomatic = nameIsAutomatic
    }

    private enum CodingKeys: String, CodingKey { case folder, displayName, addedAt, nameIsAutomatic }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folder = try values.decode(ProfileFolder.self, forKey: .folder)
        displayName = try values.decode(String.self, forKey: .displayName)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        nameIsAutomatic = try values.decodeIfPresent(Bool.self, forKey: .nameIsAutomatic) ?? false
    }
}
