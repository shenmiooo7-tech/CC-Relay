import Foundation

public enum ClaudeWebError: Error, Equatable, Sendable {
    case signedOut
    /// The read was turned away, but not the sign-in: something on the way answered instead of
    /// claude.ai, or claude.ai refused a read after accepting the session.
    case refused
    /// Too many requests. `retryAfter` is the wait in seconds the answer asked for, when it gave one.
    case rateLimited(retryAfter: TimeInterval?)
    case httpFailure(status: Int)
    case redirected
    case bodyTooLarge
    case timedOut
    case transportFailed
    case invalidResponse
    case accountMismatch
    case organizationUnavailable
}

public struct AccountRecord: Equatable, Sendable {
    public var accountUUID: String
    public var email: String?
    public var organizationUUID: String
    public var plan: String?

    public init(accountUUID: String, email: String?, organizationUUID: String, plan: String?) {
        self.accountUUID = accountUUID
        self.email = email
        self.organizationUUID = organizationUUID
        self.plan = plan
    }
}

public struct UsageRecord: Equatable, Sendable {
    public var fiveHour: QuotaWindow
    public var sevenDay: QuotaWindow

    public init(fiveHour: QuotaWindow, sevenDay: QuotaWindow) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }
}

/// Builds and parses the three claude.ai quota reads.
///
/// Errors name a kind only. Response bodies are never attached to them.
public struct ClaudeWebClient: Sendable {
    public static let timeout: Duration = .seconds(20)
    public static let maximumBodyBytes = 2 * 1024 * 1024

    private let transport: any HTTPTransport
    private let userAgent: String
    private let now: @Sendable () -> Date

    public init(transport: any HTTPTransport, userAgent: String, now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.userAgent = userAgent
        self.now = now
    }

    public func accountRequest(sessionKey: String) throws -> HTTPRequest {
        try request(path: "/api/account", sessionKey: sessionKey)
    }

    public func usageRequest(organizationUUID: String, sessionKey: String) throws -> HTTPRequest {
        guard OrganizationIdentity.isUUID(organizationUUID) else {
            throw ClaudeWebError.organizationUnavailable
        }
        return try request(path: "/api/organizations/\(organizationUUID)/usage", sessionKey: sessionKey)
    }

    public func subscriptionRequest(organizationUUID: String, sessionKey: String) throws -> HTTPRequest {
        guard OrganizationIdentity.isUUID(organizationUUID) else {
            throw ClaudeWebError.organizationUnavailable
        }
        return try request(
            path: "/api/organizations/\(organizationUUID)/subscription_details",
            sessionKey: sessionKey
        )
    }

    public func fetchAccount(
        sessionKey: String,
        expectedAccount: String,
        activeOrganization: String?
    ) async throws -> AccountRecord {
        let data = try await load(try accountRequest(sessionKey: sessionKey), checksSignIn: true)
        return try Self.parseAccount(
            data,
            expectedAccount: expectedAccount,
            activeOrganization: activeOrganization
        )
    }

    public func fetchUsage(sessionKey: String, organizationUUID: String) async throws -> UsageRecord {
        let data = try await load(try usageRequest(organizationUUID: organizationUUID, sessionKey: sessionKey))
        return try Self.parseUsage(data)
    }

    public func fetchChannel(sessionKey: String, organizationUUID: String) async throws -> SubscriptionChannel {
        let data = try await load(
            try subscriptionRequest(organizationUUID: organizationUUID, sessionKey: sessionKey)
        )
        return try Self.parseChannel(data)
    }

    public static func parseAccount(
        _ data: Data,
        expectedAccount: String,
        activeOrganization: String?
    ) throws -> AccountRecord {
        let object = try jsonObject(data)
        guard let account = try optionalString(object, "uuid") else {
            throw ClaudeWebError.invalidResponse
        }
        guard account == expectedAccount else {
            throw ClaudeWebError.accountMismatch
        }
        let email = try optionalString(object, "email_address").flatMap(trimmedNonEmpty)
        let memberships = try memberships(in: object)
        let selected = try select(memberships, activeOrganization: activeOrganization)
        return AccountRecord(
            accountUUID: account,
            email: email,
            organizationUUID: selected.organizationUUID,
            plan: PlanLabel.display(analytics: selected.plan, tier: selected.tier)
        )
    }

    public static func parseUsage(_ data: Data) throws -> UsageRecord {
        let object = try jsonObject(data)
        let fiveHour = try window(object["five_hour"])
        let sevenDay = try window(object["seven_day"])
        guard fiveHour.usedPercent != nil || sevenDay.usedPercent != nil else {
            throw ClaudeWebError.invalidResponse
        }
        return UsageRecord(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    public static func parseChannel(_ data: Data) throws -> SubscriptionChannel {
        let object = try jsonObject(data)
        let raw = try optionalString(object, "subscription_details_url")
        return SubscriptionChannelLabel.channel(from: raw)
    }

    /// Only the account read answers for the sign-in: the others run after it accepted the session.
    private func load(_ request: HTTPRequest, checksSignIn: Bool = false) async throws -> Data {
        let response: HTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HTTPTransportError {
            throw Self.map(error)
        } catch {
            throw ClaudeWebError.transportFailed
        }
        if (300..<400).contains(response.statusCode) {
            throw ClaudeWebError.redirected
        }
        if response.statusCode == 401 {
            throw ClaudeWebError.signedOut
        }
        if response.statusCode == 403 {
            // claude.ai answers in JSON. A page in its place comes from something on the way, such as
            // a challenge or a network filter, and says nothing about the sign-in.
            throw checksSignIn && Self.isServiceAnswer(response.body) ? ClaudeWebError.signedOut : ClaudeWebError.refused
        }
        if response.statusCode == 429 {
            throw ClaudeWebError.rateLimited(retryAfter: Self.retryAfter(response.headers, now: now()))
        }
        if response.body.count > Self.maximumBodyBytes {
            throw ClaudeWebError.bodyTooLarge
        }
        guard response.statusCode == 200 else {
            throw ClaudeWebError.httpFailure(status: response.statusCode)
        }
        return response.body
    }

    /// Whether a body is claude.ai's own JSON answer rather than a page from something on the way.
    static func isServiceAnswer(_ body: Data) -> Bool {
        body.count <= maximumBodyBytes && (try? JSONSerialization.jsonObject(with: body)) is [String: Any]
    }

    /// The wait a 429 asked for, in whole seconds or as the date it ends. Anything else is left to the caller.
    static func retryAfter(_ headers: [String: String], now: Date) -> TimeInterval? {
        guard let value = headers.first(where: { $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame })?.value
            .trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = Int(value) { return seconds >= 0 ? TimeInterval(seconds) : nil }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return format.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }

    private func request(path: String, sessionKey: String) throws -> HTTPRequest {
        guard let url = URL(string: "https://claude.ai" + path) else {
            throw ClaudeWebError.invalidResponse
        }
        let headers = [
            "Accept": "application/json",
            "Cookie": "sessionKey=\(sessionKey)",
            "Origin": "https://claude.ai",
            "Referer": "https://claude.ai/",
            "User-Agent": userAgent,
        ]
        return HTTPRequest(
            method: "GET",
            url: url,
            headers: headers,
            body: nil,
            timeout: Self.timeout,
            allowsRedirects: false,
            maximumBodyBytes: Self.maximumBodyBytes
        )
    }

    private static func map(_ error: HTTPTransportError) -> ClaudeWebError {
        switch error {
        case .redirected:
            .redirected
        case .bodyTooLarge:
            .bodyTooLarge
        case .timedOut:
            .timedOut
        case .transportFailed:
            .transportFailed
        }
    }

    private static func jsonObject(_ data: Data) throws -> [String: Any] {
        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ClaudeWebError.invalidResponse
        }
        guard let object = parsed as? [String: Any] else {
            throw ClaudeWebError.invalidResponse
        }
        return object
    }

    private static func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        if value is NSNull { return nil }
        guard let string = value as? String else {
            throw ClaudeWebError.invalidResponse
        }
        return string
    }

    private static func memberships(in object: [String: Any]) throws -> [Membership] {
        guard let value = object["memberships"] else { return [] }
        if value is NSNull { return [] }
        guard let rows = value as? [Any] else {
            throw ClaudeWebError.invalidResponse
        }
        var memberships: [Membership] = []
        for row in rows {
            guard let entry = row as? [String: Any] else {
                throw ClaudeWebError.invalidResponse
            }
            guard let organization = entry["organization"] else { continue }
            if organization is NSNull { continue }
            guard let fields = organization as? [String: Any] else {
                throw ClaudeWebError.invalidResponse
            }
            guard let uuid = try optionalString(fields, "uuid") else { continue }
            memberships.append(
                Membership(
                    organizationUUID: uuid,
                    plan: try optionalString(fields, "analytics_subscription_plan"),
                    tier: try optionalString(fields, "rate_limit_tier")
                )
            )
        }
        return memberships
    }

    private static func select(_ memberships: [Membership], activeOrganization: String?) throws -> Membership {
        if let active = QuotaText.nonEmpty(activeOrganization),
           let match = memberships.first(where: { $0.organizationUUID == active }) {
            guard OrganizationIdentity.isUUID(match.organizationUUID) else {
                throw ClaudeWebError.organizationUnavailable
            }
            return match
        }
        if memberships.count == 1 {
            guard OrganizationIdentity.isUUID(memberships[0].organizationUUID) else {
                throw ClaudeWebError.organizationUnavailable
            }
            return memberships[0]
        }
        throw ClaudeWebError.organizationUnavailable
    }

    private static func window(_ value: Any?) throws -> QuotaWindow {
        if value == nil || value is NSNull {
            return QuotaWindow()
        }
        guard let object = value as? [String: Any] else {
            throw ClaudeWebError.invalidResponse
        }
        let used: Double?
        if let raw = object["utilization"], !(raw is NSNull) {
            guard let number = JSONNumbers.finite(raw), (0...100).contains(number) else {
                throw ClaudeWebError.invalidResponse
            }
            used = number
        } else {
            used = nil
        }
        let resets: Date?
        if let raw = object["resets_at"], !(raw is NSNull) {
            guard let text = raw as? String, let parsed = ISO8601Fractional.date(from: text) else {
                throw ClaudeWebError.invalidResponse
            }
            resets = ResetTimestamp.snap(parsed)
        } else {
            resets = nil
        }
        return QuotaWindow(usedPercent: used, resetsAt: resets)
    }

    private static func trimmedNonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private struct Membership: Equatable {
    var organizationUUID: String
    var plan: String?
    var tier: String?
}

enum PlanLabel {
    static func display(analytics: String?, tier: String?) -> String? {
        let normalized = normalize(analytics)
        switch normalized {
        case "free":
            return "Free"
        case "pro":
            return "Pro"
        case "max":
            return refinedMax(tier) ?? "Max"
        case "max_5x":
            return "Max 5×"
        case "max_20x":
            return "Max 20×"
        case "team":
            return "Team"
        case "enterprise":
            return "Enterprise"
        default:
            return nil
        }
    }

    private static func normalize(_ analytics: String?) -> String {
        let lowered = (analytics ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "claude_"
        guard lowered.hasPrefix(prefix) else { return lowered }
        return String(lowered.dropFirst(prefix.count))
    }

    /// Only a generic Max plan looks at the tier. 20× wins if both tokens appear.
    private static func refinedMax(_ tier: String?) -> String? {
        let lowered = (tier ?? "").lowercased()
        if lowered.contains("max_20x") { return "Max 20×" }
        if lowered.contains("max_5x") { return "Max 5×" }
        return nil
    }
}

enum SubscriptionChannelLabel {
    static func channel(from url: String?) -> SubscriptionChannel {
        guard let trimmed = url.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              !trimmed.isEmpty
        else {
            return .unknown
        }
        if trimmed.contains("apps.apple.com") { return .appStore }
        if trimmed.contains("play.google.com") { return .googlePlay }
        return .web
    }
}
