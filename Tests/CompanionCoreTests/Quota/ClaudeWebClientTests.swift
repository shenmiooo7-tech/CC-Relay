import XCTest
@testable import CompanionCore

final class QuotaWebClientTests: XCTestCase {
    private let account = "11111111-1111-4111-8111-111111111111"
    private let organization = "22222222-2222-4222-8222-222222222222"
    private let otherOrganization = "33333333-3333-4333-8333-333333333333"
    private let marker = "zzbodyzz"

    func testRequestCarriesMethodURLHeadersTimeoutAndNoRedirect() throws {
        let client = ClaudeWebClient(transport: ScriptTransport(), userAgent: "TestAgent/1")
        let request = try client.accountRequest(sessionKey: "abc")
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, URL(string: "https://claude.ai/api/account"))
        XCTAssertEqual(request.headers["Cookie"], "sessionKey=abc")
        XCTAssertEqual(request.headers["Accept"], "application/json")
        XCTAssertEqual(request.headers["Origin"], "https://claude.ai")
        XCTAssertEqual(request.headers["Referer"], "https://claude.ai/")
        XCTAssertEqual(request.headers["User-Agent"], "TestAgent/1")
        XCTAssertEqual(request.headers.count, 5)
        XCTAssertNil(request.headers["Authorization"])
        XCTAssertNil(request.body)
        XCTAssertEqual(request.timeout, .seconds(20))
        XCTAssertFalse(request.allowsRedirects)
        XCTAssertEqual(request.maximumBodyBytes, 2 * 1024 * 1024)

        let usage = try client.usageRequest(organizationUUID: organization, sessionKey: "abc")
        XCTAssertEqual(usage.url.path, "/api/organizations/\(organization)/usage")
        let channel = try client.subscriptionRequest(organizationUUID: organization.uppercased(), sessionKey: "abc")
        XCTAssertEqual(
            channel.url.path,
            "/api/organizations/\(organization.uppercased())/subscription_details"
        )
    }

    func testInvalidOrganizationNeverBuildsAPath() throws {
        let client = ClaudeWebClient(transport: ScriptTransport(), userAgent: "TestAgent/1")
        for bad in ["not-a-uuid", "../etc", "22222222-2222-4222-8222-22222222222", ""] {
            XCTAssertThrowsError(try client.usageRequest(organizationUUID: bad, sessionKey: "abc")) { error in
                XCTAssertEqual(error as? ClaudeWebError, .organizationUnavailable)
                XCTAssertFalse(String(describing: error).contains(bad))
            }
        }
    }

    func testAccountParsingSelectsMembershipAndMapsPlan() throws {
        let parsed = try ClaudeWebClient.parseAccount(
            Data("""
            {"uuid":"\(account)","email_address":"  Ada@Example.com  ","display_name":"ignored",
             "memberships":[
               {"organization":{"uuid":"\(otherOrganization)","analytics_subscription_plan":"claude_pro","extra":1}},
               {"organization":{"uuid":"\(organization)","name":"Personal","analytics_subscription_plan":"  CLAUDE_MAX ",
                 "rate_limit_tier":"default_claude_max_5x"}}
             ]}
            """.utf8),
            expectedAccount: account,
            activeOrganization: organization
        )
        XCTAssertEqual(parsed.email, "Ada@Example.com")
        XCTAssertEqual(parsed.organizationUUID, organization)
        XCTAssertEqual(parsed.plan, "Max 5×")

        let cases: [(String?, String?, String?)] = [
            ("claude_pro", nil, "Pro"),
            ("claude_free", nil, "Free"),
            ("team", nil, "Team"),
            ("enterprise", nil, "Enterprise"),
            ("max", "default_claude_max", "Max"),
            ("max", "default_claude_max_5x", "Max 5×"),
            ("max", "team_max_20x_extra", "Max 20×"),
            ("claude_max_5x", "default_claude_max", "Max 5×"),
            ("claude_max_20x", nil, "Max 20×"),
            ("claude_api", "default_claude_max_5x", nil),
            ("  ", nil, nil),
            (nil, "default_claude_max_5x", nil),
        ]
        for (plan, tier, expected) in cases {
            let record = try ClaudeWebClient.parseAccount(
                accountJSON(plan: plan, tier: tier, organization: organization),
                expectedAccount: account,
                activeOrganization: organization
            )
            XCTAssertEqual(record.plan, expected, "\(plan ?? "nil") / \(tier ?? "nil")")
        }
    }

    func testUnknownPlanIsNotTakenFromAnotherMembership() throws {
        let record = try ClaudeWebClient.parseAccount(
            Data("""
            {"uuid":"\(account)","memberships":[
              {"organization":{"uuid":"\(otherOrganization)","analytics_subscription_plan":"claude_pro"}},
              {"organization":{"uuid":"\(organization)","analytics_subscription_plan":"claude_api","rate_limit_tier":"default_claude_max_5x"}}
            ]}
            """.utf8),
            expectedAccount: account,
            activeOrganization: organization
        )
        XCTAssertNil(record.plan)
        XCTAssertNil(record.email)
    }

    func testMembershipFallbackAndRejection() throws {
        let only = try ClaudeWebClient.parseAccount(
            accountJSON(plan: "pro", tier: nil, organization: otherOrganization),
            expectedAccount: account,
            activeOrganization: nil
        )
        XCTAssertEqual(only.organizationUUID, otherOrganization)
        XCTAssertEqual(only.plan, "Pro")

        let fallback = try ClaudeWebClient.parseAccount(
            accountJSON(plan: "team", tier: nil, organization: otherOrganization),
            expectedAccount: account,
            activeOrganization: organization
        )
        XCTAssertEqual(fallback.organizationUUID, otherOrganization)

        XCTAssertThrowsError(
            try ClaudeWebClient.parseAccount(
                twoMemberships(),
                expectedAccount: account,
                activeOrganization: nil
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeWebError, .organizationUnavailable)
        }
        XCTAssertThrowsError(
            try ClaudeWebClient.parseAccount(
                twoMemberships(),
                expectedAccount: account,
                activeOrganization: "44444444-4444-4444-8444-444444444444"
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeWebError, .organizationUnavailable)
        }
        XCTAssertThrowsError(
            try ClaudeWebClient.parseAccount(
                accountJSON(plan: "pro", tier: nil, organization: "not-a-uuid"),
                expectedAccount: account,
                activeOrganization: nil
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeWebError, .organizationUnavailable)
            XCTAssertFalse(String(describing: error).contains("not-a-uuid"))
        }
    }

    func testAccountIdentityErrorsOmitTheBody() throws {
        let mismatchID = "99999999-9999-4999-8999-999999999999"
        XCTAssertThrowsError(
            try ClaudeWebClient.parseAccount(
                Data("{\"uuid\":\"\(mismatchID)\",\"note\":\"\(marker)\"}".utf8),
                expectedAccount: account,
                activeOrganization: organization
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeWebError, .accountMismatch)
            let text = String(describing: error)
            XCTAssertFalse(text.contains(marker))
            XCTAssertFalse(text.contains(mismatchID))
        }
        XCTAssertThrowsError(
            try ClaudeWebClient.parseAccount(
                Data("{\"email_address\":\"ada@example.com\",\"note\":\"\(marker)\"}".utf8),
                expectedAccount: account,
                activeOrganization: organization
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeWebError, .invalidResponse)
            XCTAssertFalse(String(describing: error).contains(marker))
        }
    }

    func testUsageParsesFractionsNullsAndRejectsABadWindow() throws {
        let parsed = try ClaudeWebClient.parseUsage(Data("""
        {"five_hour":{"utilization":12.5,"resets_at":"2026-10-25T15:00:30Z","extra":1},
         "seven_day":null,"cedar":{"eligible":false}}
        """.utf8))
        XCTAssertEqual(parsed.fiveHour.usedPercent, 12.5)
        XCTAssertNotNil(parsed.fiveHour.resetsAt)
        XCTAssertNil(parsed.sevenDay.usedPercent)
        XCTAssertNil(parsed.sevenDay.resetsAt)

        let zero = try ClaudeWebClient.parseUsage(Data(#"{"seven_day":{"utilization":0,"resets_at":null}}"#.utf8))
        XCTAssertEqual(zero.sevenDay.usedPercent, 0)
        XCTAssertNil(zero.fiveHour.usedPercent)

        let full = try ClaudeWebClient.parseUsage(Data(#"{"five_hour":{"utilization":100}}"#.utf8))
        XCTAssertEqual(full.fiveHour.usedPercent, 100)

        for bad in [
            #"{"five_hour":{"utilization":100.1}}"#,
            #"{"five_hour":{"utilization":-0.1}}"#,
            #"{"five_hour":{"utilization":true}}"#,
            #"{"five_hour":{"utilization":"12"}}"#,
            #"{"five_hour":null,"seven_day":null}"#,
            #"{"extra":1}"#,
            #"{"five_hour":{"resets_at":"2026-10-25T15:00:30Z"}}"#,
            #"{"five_hour":{"utilization":1,"resets_at":"tomorrow"}}"#,
            #"{"five_hour":{"utilization":1,"resets_at":1700000000}}"#,
        ] {
            XCTAssertThrowsError(try ClaudeWebClient.parseUsage(Data(bad.utf8))) { error in
                XCTAssertEqual(error as? ClaudeWebError, .invalidResponse)
                XCTAssertFalse(String(describing: error).contains("tomorrow"))
            }
        }
    }

    func testResetTimesWithinASecondSnapToTheMinute() throws {
        let cases = [
            ("2026-10-25T15:00:00.400Z", "2026-10-25T15:00:00Z"),
            ("2026-10-25T15:00:59.200Z", "2026-10-25T15:01:00Z"),
            ("2026-10-25T15:00:30.000Z", "2026-10-25T15:00:30Z"),
            ("2026-10-25T15:00:01.100Z", "2026-10-25T15:00:01.100Z"),
            ("2026-10-25T15:00:58.900Z", "2026-10-25T15:00:58.900Z"),
            ("2026-10-25T15:00:01.000Z", "2026-10-25T15:00:00Z"),
            ("2026-10-25T15:00:59.000Z", "2026-10-25T15:01:00Z"),
        ]
        for (raw, wanted) in cases {
            let usage = try ClaudeWebClient.parseUsage(
                Data(#"{"five_hour":{"utilization":1,"resets_at":"\#(raw)"}}"#.utf8)
            )
            let expected = try XCTUnwrap(ISO8601Fractional.date(from: wanted))
            let actual = try XCTUnwrap(usage.fiveHour.resetsAt)
            XCTAssertEqual(actual.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.001, raw)
        }
    }

    func testChannelMapping() throws {
        XCTAssertEqual(try channel(#"{"subscription_details_url":"https://apps.apple.com/account","next_charge_date":"2026-12-01"}"#), .appStore)
        XCTAssertEqual(try channel(#"{"subscription_details_url":"https://play.google.com/store","extra":1}"#), .googlePlay)
        XCTAssertEqual(try channel(#"{"subscription_details_url":"https://claude.ai/settings/billing"}"#), .web)
        XCTAssertEqual(try channel(#"{}"#), .unknown)
        XCTAssertEqual(try channel(#"{"subscription_details_url":null}"#), .unknown)
        XCTAssertEqual(try channel(#"{"subscription_details_url":"  "}"#), .unknown)
        XCTAssertThrowsError(try channel(#"{"subscription_details_url":3,"note":"\#(marker)"}"#)) { error in
            XCTAssertEqual(error as? ClaudeWebError, .invalidResponse)
            XCTAssertFalse(String(describing: error).contains(marker))
        }
    }

    func testStatusRedirectAndBodyCap() async throws {
        let transport = ScriptTransport()
        let client = ClaudeWebClient(transport: transport, userAgent: "TestAgent/1")
        let url = try XCTUnwrap(URL(string: "https://claude.ai/api/account"))

        transport.enqueue(.success(HTTPResponse(statusCode: 401, body: Data(marker.utf8), finalURL: url)))
        try await expect(.signedOut) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }

        transport.enqueue(.success(HTTPResponse(statusCode: 403, body: Data(marker.utf8), finalURL: url)))
        try await expect(.refused) { try await client.fetchUsage(sessionKey: "abc", organizationUUID: organization) }

        transport.enqueue(.success(HTTPResponse(statusCode: 500, body: Data(marker.utf8), finalURL: url)))
        try await expect(.httpFailure(status: 500)) {
            try await client.fetchChannel(sessionKey: "abc", organizationUUID: organization)
        }

        transport.enqueue(.success(HTTPResponse(statusCode: 404, body: Data(marker.utf8), finalURL: url)))
        try await expect(.httpFailure(status: 404)) {
            try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil)
        }

        transport.enqueue(.success(HTTPResponse(statusCode: 302, body: Data(accountJSON(plan: "pro", tier: nil, organization: organization)), finalURL: url)))
        try await expect(.redirected) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: organization) }

        transport.enqueue(.failure(HTTPTransportError.redirected))
        try await expect(.redirected) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }
        transport.enqueue(.failure(HTTPTransportError.timedOut))
        try await expect(.timedOut) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }
        transport.enqueue(.failure(HTTPTransportError.bodyTooLarge))
        try await expect(.bodyTooLarge) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }
        transport.enqueue(.failure(HTTPTransportError.transportFailed))
        try await expect(.transportFailed) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }

        transport.enqueue(.success(HTTPResponse(statusCode: 200, body: Data(count: 2 * 1024 * 1024 + 1), finalURL: url)))
        try await expect(.bodyTooLarge) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }

        transport.enqueue(.success(HTTPResponse(statusCode: 200, body: Data(count: 2 * 1024 * 1024), finalURL: url)))
        try await expect(.invalidResponse) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }

        XCTAssertEqual(transport.recorded().count, 11)
    }

    func testOnlyClaudeTurningTheSessionAwaySignsTheAccountOut() async throws {
        let transport = ScriptTransport()
        let client = ClaudeWebClient(transport: transport, userAgent: "TestAgent/1")
        let url = try XCTUnwrap(URL(string: "https://claude.ai/api/account"))
        let refusal = Data(#"{"type":"error","error":{"type":"permission_error","message":"\#(marker)"}}"#.utf8)
        let page = Data("<!DOCTYPE html><html><title>Just a moment...</title>\(marker)</html>".utf8)

        // claude.ai refusing the session itself: the account has to sign in again.
        transport.enqueue(.success(HTTPResponse(statusCode: 403, body: refusal, finalURL: url)))
        try await expect(.signedOut) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }
        transport.enqueue(.success(HTTPResponse(statusCode: 401, body: page, finalURL: url)))
        try await expect(.signedOut) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }

        // A page from something on the way (a challenge, a filter) says nothing about the sign-in.
        transport.enqueue(.success(HTTPResponse(statusCode: 403, headers: ["Content-Type": "text/html"], body: page, finalURL: url)))
        try await expect(.refused) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }

        // The account read has just accepted the session: a refused usage or plan read is about that read.
        transport.enqueue(.success(HTTPResponse(statusCode: 403, body: refusal, finalURL: url)))
        try await expect(.refused) { try await client.fetchUsage(sessionKey: "abc", organizationUUID: organization) }
        transport.enqueue(.success(HTTPResponse(statusCode: 403, body: refusal, finalURL: url)))
        try await expect(.refused) { try await client.fetchChannel(sessionKey: "abc", organizationUUID: organization) }
    }

    func testTooManyRequestsCarriesTheWaitTheServerAsksFor() async throws {
        let transport = ScriptTransport()
        let client = ClaudeWebClient(transport: transport, userAgent: "TestAgent/1")
        let url = try XCTUnwrap(URL(string: "https://claude.ai/api/account"))
        let body = Data(marker.utf8)

        transport.enqueue(.success(HTTPResponse(statusCode: 429, headers: ["Retry-After": "120"], body: body, finalURL: url)))
        try await expect(.rateLimited(retryAfter: 120)) { try await client.fetchUsage(sessionKey: "abc", organizationUUID: organization) }
        transport.enqueue(.success(HTTPResponse(statusCode: 429, headers: ["retry-after": " 30 "], body: body, finalURL: url)))
        try await expect(.rateLimited(retryAfter: 30)) { try await client.fetchAccount(sessionKey: "abc", expectedAccount: account, activeOrganization: nil) }
        // No wait, or one this client does not read (a negative or absurd number, some other text): the caller decides.
        for value in [nil, "soon", "-5", "99999999999999999999"] {
            let headers = value.map { ["Retry-After": $0] } ?? [:]
            transport.enqueue(.success(HTTPResponse(statusCode: 429, headers: headers, body: body, finalURL: url)))
            try await expect(.rateLimited(retryAfter: nil)) { try await client.fetchUsage(sessionKey: "abc", organizationUUID: organization) }
        }
    }

    func testAWaitGivenAsADateCountsFromNow() async throws {
        let transport = ScriptTransport()
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-21T07:28:00Z"))
        let client = ClaudeWebClient(transport: transport, userAgent: "TestAgent/1", now: { date.addingTimeInterval(-7_200) })
        let url = try XCTUnwrap(URL(string: "https://claude.ai/api/account"))
        let headers = ["Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"]

        transport.enqueue(.success(HTTPResponse(statusCode: 429, headers: headers, body: Data(), finalURL: url)))
        try await expect(.rateLimited(retryAfter: 7_200)) { try await client.fetchUsage(sessionKey: "abc", organizationUUID: organization) }

        // A date already past asks for no wait at all.
        let late = ClaudeWebClient(transport: transport, userAgent: "TestAgent/1", now: { date.addingTimeInterval(10) })
        transport.enqueue(.success(HTTPResponse(statusCode: 429, headers: headers, body: Data(), finalURL: url)))
        try await expect(.rateLimited(retryAfter: 0)) { try await late.fetchUsage(sessionKey: "abc", organizationUUID: organization) }
    }

    private func channel(_ json: String) throws -> SubscriptionChannel {
        try ClaudeWebClient.parseChannel(Data(json.utf8))
    }

    private func accountJSON(plan: String?, tier: String?, organization: String) -> Data {
        let planField = plan.map { "\"analytics_subscription_plan\":\"\($0)\"" } ?? "\"analytics_subscription_plan\":null"
        let tierField = tier.map { "\"rate_limit_tier\":\"\($0)\"" } ?? "\"rate_limit_tier\":null"
        return Data("""
        {"uuid":"\(account)","memberships":[{"organization":{"uuid":"\(organization)",\(planField),\(tierField)}}]}
        """.utf8)
    }

    private func twoMemberships() -> Data {
        Data("""
        {"uuid":"\(account)","memberships":[
          {"organization":{"uuid":"\(organization)","analytics_subscription_plan":"pro"}},
          {"organization":{"uuid":"\(otherOrganization)","analytics_subscription_plan":"team"}}
        ]}
        """.utf8)
    }

    private func expect<T>(
        _ expected: ClaudeWebError,
        _ body: () async throws -> T
    ) async throws {
        do {
            _ = try await body()
            XCTFail("expected \(expected)")
        } catch let error as ClaudeWebError {
            XCTAssertEqual(error, expected)
            XCTAssertFalse(String(describing: error).contains(marker))
            XCTAssertFalse(String(reflecting: error).contains(marker))
        }
    }
}

final class ScriptTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [Result<HTTPResponse, Error>] = []
    private var requests: [HTTPRequest] = []

    func enqueue(_ result: Result<HTTPResponse, Error>) {
        withLock(lock) { steps.append(result) }
    }

    func recorded() -> [HTTPRequest] {
        withLock(lock) { requests }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let result = withLock(lock) { () -> Result<HTTPResponse, Error> in
            requests.append(request)
            return steps.isEmpty ? .failure(HTTPTransportError.transportFailed) : steps.removeFirst()
        }
        return try result.get()
    }
}
