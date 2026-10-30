import Foundation

public struct QuotaWindow: Equatable, Sendable, Codable {
    public var usedPercent: Double?
    public var resetsAt: Date?

    public init(usedPercent: Double? = nil, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

/// Where the subscription was bought. An unknown raw value decodes as `.unknown`.
/// A non-string value still throws.
public enum SubscriptionChannel: String, Equatable, Sendable, Codable {
    case web
    case appStore
    case googlePlay
    case unknown

    public init(from decoder: Decoder) throws {
        self = try LenientStringEnum.decode(from: decoder, fallback: .unknown)
    }

    public func encode(to encoder: Encoder) throws {
        try LenientStringEnum.encode(self, to: encoder)
    }
}

/// How a quota reading was obtained. An unknown raw value decodes as `.network`.
/// A non-string value still throws.
public enum QuotaSource: String, Equatable, Sendable, Codable {
    case network
    case localHistory

    public init(from decoder: Decoder) throws {
        self = try LenientStringEnum.decode(from: decoder, fallback: .network)
    }

    public func encode(to encoder: Encoder) throws {
        try LenientStringEnum.encode(self, to: encoder)
    }
}

public struct QuotaSnapshot: Equatable, Sendable, Codable {
    public var folder: ProfileFolder
    public var accountUUID: String
    public var organizationUUID: String
    public var plan: String?
    public var email: String?
    public var channel: SubscriptionChannel
    public var fiveHour: QuotaWindow
    public var sevenDay: QuotaWindow
    public var fetchedAt: Date
    public var channelCheckedAt: Date?
    public var source: QuotaSource

    public init(
        folder: ProfileFolder,
        accountUUID: String,
        organizationUUID: String,
        plan: String? = nil,
        email: String? = nil,
        channel: SubscriptionChannel = .unknown,
        fiveHour: QuotaWindow = QuotaWindow(),
        sevenDay: QuotaWindow = QuotaWindow(),
        fetchedAt: Date,
        channelCheckedAt: Date? = nil,
        source: QuotaSource = .network
    ) {
        self.folder = folder
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
        self.plan = plan
        self.email = email
        self.channel = channel
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
        self.channelCheckedAt = channelCheckedAt
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case folder
        case accountUUID
        case organizationUUID
        case plan
        case email
        case channel
        case fiveHour
        case sevenDay
        case fetchedAt
        case channelCheckedAt
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.folder = try container.decode(ProfileFolder.self, forKey: .folder)
        self.accountUUID = try container.decode(String.self, forKey: .accountUUID)
        self.organizationUUID = try container.decode(String.self, forKey: .organizationUUID)
        self.plan = try JSONFields.optional(String.self, from: container, forKey: .plan)
        self.email = try JSONFields.optional(String.self, from: container, forKey: .email)
        self.channel = try JSONFields.value(
            SubscriptionChannel.self,
            from: container,
            forKey: .channel,
            default: .unknown
        )
        self.fiveHour = try JSONFields.value(
            QuotaWindow.self,
            from: container,
            forKey: .fiveHour,
            default: QuotaWindow()
        )
        self.sevenDay = try JSONFields.value(
            QuotaWindow.self,
            from: container,
            forKey: .sevenDay,
            default: QuotaWindow()
        )
        self.fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        self.channelCheckedAt = try JSONFields.optional(Date.self, from: container, forKey: .channelCheckedAt)
        self.source = try JSONFields.value(
            QuotaSource.self,
            from: container,
            forKey: .source,
            default: .network
        )
    }
}
