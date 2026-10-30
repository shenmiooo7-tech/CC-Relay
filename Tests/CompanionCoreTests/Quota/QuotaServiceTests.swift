import XCTest
@testable import CompanionCore

final class QuotaServiceTests: XCTestCase {
    private var scratch: ScratchDirectory!
    private var clock: TestClock!
    private var cookies: FakeCookieReader!
    private var storage: FakeSafeStorage!
    private var transport: PathTransport!
    private var service: QuotaService!
    private var folder: ProfileFolder!
    private var profileURL: URL!
    private var gate: GateClock?

    private let account = "11111111-1111-4111-8111-111111111111"
    private let organization = "22222222-2222-4222-8222-222222222222"
    private let otherAccount = "33333333-3333-4333-8333-333333333333"
    private let otherOrganization = "44444444-4444-4444-8444-444444444444"
    private let password = Data("cc-relay-test-secret".utf8)
    private let session = "session-key-value"

    override func setUp() async throws {
        scratch = try ScratchDirectory()
        clock = TestClock(now: Date(timeIntervalSince1970: 1_792_832_402))
        cookies = FakeCookieReader()
        storage = FakeSafeStorage()
        transport = PathTransport()
        folder = try ProfileFolder("Claude")
        profileURL = scratch.root.appending(path: "Claude", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        service = makeService(clock: clock, jitter: ScriptedJitter(0))
        transport.setAccount(body: accountBody())
        transport.setUsage(body: usageBody())
        transport.setChannel(body: channelBody("https://apps.apple.com/account"))
    }

    override func tearDown() async throws {
        await service?.stopPeriodicRefresh()
        gate?.cancelAll()
        scratch?.cleanup()
    }

    func testColdPanelRefreshDoesNotRequestTheKeychainAndExplicitRetryCan() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refreshVisible([folder])
        XCTAssertEqual(storage.callCount(), 0)
        XCTAssertTrue(transport.recorded().isEmpty)
        checkEqual(try await shownReading(folder).lastError, .keyUnavailable)
        await service.refresh([folder], force: true)
        XCTAssertEqual(storage.callCount(), 1)
        checkEqual(try await shownReading(folder).freshness, .fresh)
    }

    func testALaunchWithAFreshStoredReadingStillFetchesTheKeyForThePanel() async throws {
        try installEncryptedCookie()
        let gateClock = try await launchWithAFreshStoredReading()
        // The stored reading needs no network read, but the first panel opening needs the key.
        XCTAssertTrue(transport.recorded().isEmpty)
        XCTAssertEqual(storage.callCount(), 1)
        await service.refreshVisible([folder])
        checkNil(try await shownReading(folder).lastError)
        checkEqual(try await shownReading(folder).freshness, .fresh)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        XCTAssertEqual(storage.callCount(), 1)
        await service.stopPeriodicRefresh()
        gateClock.cancelAll()
    }

    func testARefusalAtLaunchIsReportedAndNotAskedAgainByThePanel() async throws {
        try installEncryptedCookie(enqueuePassword: false)
        storage.enqueue(.failure(.failed("refused")))
        let gateClock = try await launchWithAFreshStoredReading()
        XCTAssertEqual(storage.callCount(), 1)
        await service.refreshVisible([folder])
        checkEqual(try await shownReading(folder).lastError, .keyUnavailable)
        XCTAssertEqual(storage.callCount(), 1)
        XCTAssertTrue(transport.recorded().isEmpty)
        await service.stopPeriodicRefresh()
        gateClock.cancelAll()
    }

    func testALaunchWithOnlyAPlaintextCookieLeavesTheKeychainAlone() async throws {
        cookies.setCookie(
            EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: session, databaseVersion: 23),
            for: profileURL
        )
        let gateClock = try await launchWithAFreshStoredReading()
        XCTAssertEqual(storage.callCount(), 0)
        await service.stopPeriodicRefresh()
        gateClock.cancelAll()
    }

    func testEncryptedRefreshPublishesAFreshReading() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)

        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertNil(reading.lastError)
        XCTAssertEqual(reading.snapshot?.email, "ada@example.com")
        XCTAssertEqual(reading.snapshot?.plan, "Max 5×")
        XCTAssertEqual(reading.snapshot?.channel, .appStore)
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 12.5)
        XCTAssertEqual(reading.snapshot?.sevenDay.usedPercent, 40)
        XCTAssertEqual(reading.snapshot?.source, .network)
        XCTAssertEqual(reading.snapshot?.accountUUID, account)
        XCTAssertEqual(reading.snapshot?.organizationUUID, organization)
        XCTAssertEqual(storage.callCount(), 1)

        let requests = transport.recorded()
        XCTAssertEqual(requests.map(\.url.path), [
            "/api/account",
            "/api/organizations/\(organization)/usage",
            "/api/organizations/\(organization)/subscription_details",
        ])
        let first = try XCTUnwrap(requests.first)
        XCTAssertEqual(first.method, "GET")
        XCTAssertEqual(first.headers["Cookie"], "sessionKey=\(session)")
        XCTAssertEqual(first.headers["Accept"], "application/json")
        XCTAssertEqual(first.headers["Origin"], "https://claude.ai")
        XCTAssertEqual(first.headers["Referer"], "https://claude.ai/")
        XCTAssertEqual(first.headers["User-Agent"], "TestAgent/1")
        XCTAssertEqual(first.headers.count, 5)
        XCTAssertEqual(first.timeout, .seconds(20))
        XCTAssertFalse(first.allowsRedirects)
        XCTAssertEqual(first.maximumBodyBytes, 2 * 1024 * 1024)

        let stored = try await loadCache()
        XCTAssertEqual(stored[folder]?.fiveHour.usedPercent, 12.5)
        XCTAssertEqual(stored[folder]?.channel, .appStore)
        let cacheText = try String(contentsOf: cacheFile(), encoding: .utf8)
        XCTAssertFalse(cacheText.contains(session))
        let logText = (try? String(contentsOf: logFile(), encoding: .utf8)) ?? ""
        XCTAssertFalse(logText.contains(session))
        XCTAssertFalse(logText.contains("cc-relay-test-secret"))
    }

    func testPlaintextCookieSkipsTheKeychain() async throws {
        cookies.setCookie(
            EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: session, databaseVersion: 23),
            for: profileURL
        )
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertEqual(storage.callCount(), 0)
        XCTAssertEqual(transport.recorded().first?.headers["Cookie"], "sessionKey=\(session)")
    }

    func testFreshnessThrottleAndForce() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        // Opening the panel twice within half a minute reads once.
        clock.advance(by: 20)
        await service.refreshVisible([folder])
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        XCTAssertEqual(storage.callCount(), 1)

        // Any later opening reads again, though the reading is well within its ten fresh minutes,
        // and without asking the keychain.
        clock.advance(by: 15)
        await service.refreshVisible([folder])
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        XCTAssertEqual(storage.callCount(), 1)

        // The automatic refresh still skips a fresh reading.
        clock.advance(by: 120)
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 2)

        clock.advance(by: 30)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 3)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 1)
        XCTAssertEqual(storage.callCount(), 1)

        clock.advance(by: 600)
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 4)
    }

    func testFailureThrottleAlsoApplies() async throws {
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: false)
        checkEqual(try await shownReading(folder).lastError, .cookieMissing)
        XCTAssertEqual(cookies.recordedProfiles().count, 1)

        await service.refresh([folder], force: false)
        XCTAssertEqual(cookies.recordedProfiles().count, 1)

        clock.advance(by: 120)
        await service.refresh([folder], force: false)
        XCTAssertEqual(cookies.recordedProfiles().count, 2)
    }

    func testResetPassedShowsFullRemainingUntilANewReading() async throws {
        try installEncryptedCookie()
        let fiveReset = clock.now().addingTimeInterval(30)
        let sevenReset = clock.now().addingTimeInterval(7 * 24 * 60 * 60)
        transport.setUsage(body: usageBody(five: 40, seven: 10, fiveReset: iso(fiveReset), sevenReset: iso(sevenReset)))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)

        var reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 40)

        clock.advance(by: 31)
        reading = try await self.shownReading(folder)
        XCTAssertEqual(reading.freshness, .resetPassed)
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 0)
        XCTAssertEqual(reading.snapshot?.sevenDay.usedPercent, 10)

        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        checkEqual(try await loadCache()[folder]?.fiveHour.usedPercent, 40)

        clock.advance(by: 90)
        transport.setUsage(body: usageBody(five: 5, seven: 10, fiveReset: iso(clock.now().addingTimeInterval(3_600)), sevenReset: iso(sevenReset)))
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        reading = try await self.shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 5)
    }

    func testFailuresKeepTheLastGoodReadingStale() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        transport.setAccount(status: 500, body: Data("zzbodyzz".utf8))
        clock.advance(by: 601)
        await service.refresh([folder], force: false)

        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .stale)
        XCTAssertEqual(reading.lastError, .httpFailure(500))
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 12.5)
        XCTAssertEqual(reading.snapshot?.source, .network)
        checkEqual(try await loadCache()[folder]?.fiveHour.usedPercent, 12.5)
        let logText = (try? String(contentsOf: logFile(), encoding: .utf8)) ?? ""
        XCTAssertFalse(logText.contains("zzbodyzz"))
        XCTAssertFalse(logText.contains(session))
    }

    func testSignedOutHidesTheCachedReading() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        transport.setAccount(status: 401, body: Data("zzbodyzz".utf8))
        clock.advance(by: 601)
        await service.refresh([folder], force: false)

        let reading = try await shownReading(folder)
        XCTAssertNil(reading.snapshot)
        XCTAssertEqual(reading.freshness, .unavailable)
        XCTAssertEqual(reading.lastError, .signedOut)
        XCTAssertEqual(transport.count(ending: "/usage"), 1)
        checkEqual(try await loadCache()[folder]?.fiveHour.usedPercent, 12.5)

        // The account read accepting the session again ends the sign-out, whatever the next read meets.
        transport.setAccount(status: 200, body: accountBody())
        transport.setUsage(status: 403, body: Data("zzbodyzz".utf8))
        clock.advance(by: 121)
        await service.refresh([folder], force: true)
        let refused = try await shownReading(folder)
        XCTAssertEqual(refused.lastError, .refused)
        XCTAssertEqual(refused.snapshot?.fiveHour.usedPercent, 12.5)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 1)
    }

    func testChannelFailureKeepsThePreviousChannelAndIsNotRetriedTheSameDay() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).snapshot?.channel, .appStore)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 1)

        clock.advance(by: 660)
        transport.setChannel(status: 500, body: Data("zzbodyzz".utf8))
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 1)
        checkEqual(try await shownReading(folder).snapshot?.channel, .appStore)
        checkEqual(try await shownReading(folder).freshness, .fresh)

        clock.advance(by: 86_400)
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 2)
        let afterFailure = try await shownReading(folder)
        XCTAssertEqual(afterFailure.snapshot?.channel, .appStore)
        XCTAssertEqual(afterFailure.freshness, .fresh)
        XCTAssertNil(afterFailure.lastError)

        clock.advance(by: 660)
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 2)

        clock.advance(by: 86_400)
        transport.setChannel(status: 200, body: channelBody("https://play.google.com/store"))
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 3)
        checkEqual(try await shownReading(folder).snapshot?.channel, .googlePlay)
    }

    func testSubscriptionForbiddenDoesNotSignTheProfileOut() async throws {
        try installEncryptedCookie()
        transport.setChannel(status: 403, body: Data("zzbodyzz".utf8))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertNil(reading.lastError)
        XCTAssertEqual(reading.snapshot?.channel, .unknown)
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 12.5)
    }

    func testStaleCacheFromADifferentAccountIsNotShown() async throws {
        try await seedCache(account: otherAccount, organization: organization, five: 77, seven: 66, fetchedAt: clock.now())
        await service.replaceProfiles([profile()])
        let hidden = try await shownReading(folder)
        XCTAssertNil(hidden.snapshot)
        XCTAssertEqual(hidden.freshness, .unavailable)

        await service.refresh([folder], force: true)
        let failed = try await shownReading(folder)
        XCTAssertNil(failed.snapshot)
        checkEqual(try await loadCache()[folder]?.accountUUID, otherAccount)
    }

    func testStaleCacheFromADifferentOrganizationIsNotShown() async throws {
        try await seedCache(account: account, organization: otherOrganization, five: 77, seven: 66, fetchedAt: clock.now())
        await service.replaceProfiles([profile()])
        checkNil(try await shownReading(folder).snapshot)
    }

    func testMatchingCacheIsKeptWhenTheAccountMismatches() async throws {
        try installEncryptedCookie()
        try await seedCache(account: account, organization: organization, five: 8, seven: 9, fetchedAt: clock.now().addingTimeInterval(-30))
        transport.setAccount(body: accountBody(uuid: otherAccount))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .stale)
        XCTAssertEqual(reading.lastError, .accountMismatch)
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 8)
        XCTAssertEqual(transport.count(ending: "/usage"), 0)
        checkEqual(try await loadCache()[folder]?.fiveHour.usedPercent, 8)
    }

    func testAFutureCacheIsNotTreatedAsFresh() async throws {
        try installEncryptedCookie()
        try await seedCache(account: account, organization: organization, five: 3, seven: 4, fetchedAt: clock.now().addingTimeInterval(120))
        await service.replaceProfiles([profile()])
        checkEqual(try await shownReading(folder).freshness, .stale)
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        checkEqual(try await shownReading(folder).freshness, .fresh)
        checkEqual(try await shownReading(folder).snapshot?.fiveHour.usedPercent, 12.5)
    }

    func testOfflineHistoryIsPercentOnlyAndLabelledWithItsTime() async throws {
        try writeHistory()
        await service.replaceProfiles([profile()])
        let shown = try await shownReading(folder)
        XCTAssertEqual(shown.freshness, .stale)
        XCTAssertEqual(shown.snapshot?.source, .localHistory)
        XCTAssertEqual(shown.snapshot?.fiveHour.usedPercent, nil)
        XCTAssertEqual(shown.snapshot?.sevenDay.usedPercent, 7)
        XCTAssertEqual(shown.snapshot?.fetchedAt, Date(timeIntervalSince1970: 4))
        XCTAssertNil(shown.snapshot?.fiveHour.resetsAt)
        XCTAssertNil(shown.snapshot?.plan)
        XCTAssertNil(shown.snapshot?.email)
        XCTAssertEqual(shown.snapshot?.channel, .unknown)

        try installEncryptedCookie()
        await service.refresh([folder], force: true)
        let fresh = try await shownReading(folder)
        XCTAssertEqual(fresh.freshness, .fresh)
        XCTAssertEqual(fresh.snapshot?.source, .network)
        XCTAssertEqual(fresh.snapshot?.fiveHour.usedPercent, 12.5)
    }

    func testHistoryDoesNotReplaceAMatchingCacheOrASignedOutProfile() async throws {
        try writeHistory()
        try await seedCache(account: account, organization: organization, five: 10, seven: 15, fetchedAt: clock.now().addingTimeInterval(-30))
        try installEncryptedCookie()
        transport.setAccount(status: 500, body: Data())
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        let stale = try await shownReading(folder)
        XCTAssertEqual(stale.freshness, .stale)
        XCTAssertEqual(stale.snapshot?.fiveHour.usedPercent, 10)
        XCTAssertEqual(stale.snapshot?.source, .network)

        transport.setAccount(status: 401, body: Data())
        clock.advance(by: 601)
        await service.refresh([folder], force: false)
        let signedOut = try await shownReading(folder)
        XCTAssertNil(signedOut.snapshot)
        XCTAssertEqual(signedOut.lastError, .signedOut)
        XCTAssertNotEqual(signedOut.snapshot?.sevenDay.usedPercent, 7)
    }

    func testAmbiguousOrganizationDoesNotRequestUsage() async throws {
        try installEncryptedCookie()
        transport.setAccount(body: Data("""
        {"uuid":"\(account)","memberships":[
          {"organization":{"uuid":"\(otherOrganization)","analytics_subscription_plan":"pro"}},
          {"organization":{"uuid":"55555555-5555-4555-8555-555555555555","analytics_subscription_plan":"team"}}
        ]}
        """.utf8))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).lastError, .organizationUnavailable)
        XCTAssertEqual(transport.count(ending: "/usage"), 0)
    }

    func testSingleMembershipFallbackUsesThatUsageButRecordsTheProfileOrganization() async throws {
        try installEncryptedCookie()
        transport.setAccount(body: accountBody(organization: otherOrganization, plan: "claude_team", tier: nil))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.recorded().map(\.url.path)[1], "/api/organizations/\(otherOrganization)/usage")
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertEqual(reading.snapshot?.organizationUUID, organization)
        XCTAssertEqual(reading.snapshot?.plan, "Team")
    }

    func testInvalidUsageDoesNotSaveOrFetchTheChannel() async throws {
        try installEncryptedCookie()
        transport.setUsage(body: Data(#"{"five_hour":{"utilization":140}}"#.utf8))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.lastError, .invalidResponse)
        XCTAssertEqual(reading.freshness, .unavailable)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 0)
        checkTrue(try await loadCache().isEmpty)
    }

    func testKeychainDenialAndCorruptCookieStayOffline() async throws {
        let denying = StorageScript()
        denying.error = SafeStorageError.userDenied
        service = makeService(clock: clock, jitter: ScriptedJitter(0), storage: denying)
        try installEncryptedCookie(enqueuePassword: false)
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).lastError, .keyUnavailable)
        XCTAssertEqual(transport.recorded().count, 0)
        checkFalse(String(describing: try await shownReading(folder)).contains("userDenied"))

        denying.error = SafeStorageError.notFound
        clock.advance(by: 121)
        await service.refresh([folder], force: false)
        checkEqual(try await shownReading(folder).lastError, .keyUnavailable)

        denying.error = SafeStorageError.commandFailed(exitCode: 44)
        clock.advance(by: 121)
        await service.refresh([folder], force: false)
        checkEqual(try await shownReading(folder).lastError, .keyUnavailable)

        service = makeService(clock: clock, jitter: ScriptedJitter(0))
        cookies.setCookie(
            EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data("v10".utf8), databaseVersion: 24),
            for: profileURL
        )
        storage.enqueue(.success(password))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).lastError, .decryptFailed)
        XCTAssertEqual(transport.recorded().count, 0)

        cookies.setCookie(
            EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: "a;b", databaseVersion: 23),
            for: profileURL
        )
        clock.advance(by: 121)
        await service.refresh([folder], force: false)
        checkEqual(try await shownReading(folder).lastError, .decryptFailed)

        cookies.fail(.failed("secret-db-path"), for: profileURL)
        clock.advance(by: 121)
        await service.refresh([folder], force: false)
        let unreadable = try await shownReading(folder)
        XCTAssertEqual(unreadable.lastError, .cookieUnreadable)
        XCTAssertFalse(String(describing: unreadable).contains("secret-db-path"))
    }

    func testTransportErrorsAreRecordedWithoutABody() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        let cases: [(Error, QuotaFailure)] = [
            (HTTPTransportError.timedOut, .timedOut),
            (HTTPTransportError.redirected, .redirected),
            (HTTPTransportError.bodyTooLarge, .bodyTooLarge),
            (HTTPTransportError.transportFailed, .transportFailed),
        ]
        for (index, pair) in cases.enumerated() {
            if index > 0 { clock.advance(by: 121) }
            transport.setAccount(status: 500, body: Data(), error: pair.0)
            await service.refresh([folder], force: false)
            let reading = try await shownReading(folder)
            XCTAssertEqual(reading.lastError, pair.1)
            XCTAssertNil(reading.snapshot)
            XCTAssertFalse(String(describing: reading).contains(session))
        }
    }

    func testACacheWriteFailureStillPublishesTheReading() async throws {
        try installEncryptedCookie()
        let cacheURL = scratch.paths.companionDataDirectory.appending(path: "quota-cache.json")
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 12.5)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheURL.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testSingleFlightJoinsInsteadOfStartingAnotherRequest() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.pauseNext = true
        let quota = service!
        let target = folder!
        async let first: Void = quota.refresh([target], force: true)
        await transport.waitUntilPaused()
        async let second: Void = quota.refresh([target], force: true)
        await waitUntil { await quota.refreshJoins == 1 }
        XCTAssertEqual(transport.recorded().count, 1)
        transport.release()
        _ = await (first, second)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        XCTAssertEqual(transport.count(ending: "/usage"), 1)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 1)
        checkEqual(try await shownReading(folder).freshness, .fresh)
    }

    func testRefreshResultReportsThisAttemptInsteadOfCachedFreshnessOrTimestamp() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        let missing = try ProfileFolder("Claude_missing")
        let first = await service.refreshWithResult([folder, missing, folder], force: true)
        XCTAssertEqual(first, [folder: true, missing: false])
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        let original = try await shownReading(folder).snapshot

        let skipped = await service.refreshWithResult([folder], force: false)
        XCTAssertEqual(skipped[folder], false)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        transport.setAccount(body: Data(), error: CancellationError())
        let cancelled = await service.refreshWithResult([folder], force: true)
        XCTAssertEqual(cancelled[folder], false)
        checkEqual(try await shownReading(folder).freshness, .fresh)
        checkEqual(try await shownReading(folder).snapshot, original)

        transport.setAccount(status: 500, body: Data())
        let failed = await service.refreshWithResult([folder], force: true)
        XCTAssertEqual(failed[folder], false)
        checkEqual(try await shownReading(folder).snapshot, original)
        transport.setAccount(body: accountBody())
        let succeeded = await service.refreshWithResult([folder], force: true)
        XCTAssertEqual(succeeded[folder], true)
        // The injected clock has not advanced: equal fetchedAt values still represent a new successful read.
        checkEqual(try await shownReading(folder).snapshot?.fetchedAt, original?.fetchedAt)
    }

    func testRefreshResultStartsAllUniqueAccountsTogetherAndPublishesBeforeASlowFailure() async throws {
        let profiles = try installPlaintextProfiles(count: 5)
        let folders = profiles.map(\.folder)
        let slowSession = "session-\(folders[0].name)"
        transport.setAccount(status: 500, body: Data(), sessionKey: slowSession)
        transport.holdAccountRequests()
        defer { transport.releaseAccountRequests() }
        let quota = service!
        await quota.replaceProfiles(profiles)
        let readings = ReadingBox()
        let stream = await quota.readings()
        let observation = Task { for await value in stream { readings.append(value) } }
        defer { observation.cancel() }
        let requested = folders + [folders[0], folders[4]]
        let refresh = Task { await quota.refreshWithResult(requested, force: true) }

        // Every account reaches its blocked request before any is released: no serial or bounded queue.
        await waitUntil { self.transport.heldAccountCount() == folders.count }
        XCTAssertEqual(transport.count(ending: "/account"), folders.count)
        for folder in folders.dropFirst() {
            transport.releaseAccountRequest(sessionKey: "session-\(folder.name)")
        }
        await waitUntil { folders.dropFirst().allSatisfy { readings.latest()[$0]?.freshness == .fresh } }
        XCTAssertEqual(readings.latest()[folders[0]]?.freshness, .refreshing)
        transport.releaseAccountRequests()

        let result = await refresh.value
        XCTAssertEqual(result, Dictionary(uniqueKeysWithValues: folders.enumerated().map { ($0.element, $0.offset != 0) }))
        XCTAssertEqual(transport.count(ending: "/account"), folders.count)
        XCTAssertEqual(transport.count(ending: "/usage"), folders.count - 1)
        for folder in folders {
            XCTAssertEqual(transport.recorded().filter {
                $0.url.path.hasSuffix("/account") && $0.headers["Cookie"] == "sessionKey=session-\(folder.name)"
            }.count, 1)
        }
        checkEqual(try await shownReading(folders[0]).lastError, .httpFailure(500))
    }

    func testCancellingAConcurrentRefreshKeepsSharedRequestsButReportsNoPendingSuccess() async throws {
        let profiles = try installPlaintextProfiles(count: 3)
        let folders = profiles.map(\.folder)
        transport.holdAccountRequests()
        defer { transport.releaseAccountRequests() }
        let quota = service!
        await quota.replaceProfiles(profiles)
        let refresh = Task { await quota.refreshWithResult(folders, force: true) }
        await waitUntil { self.transport.heldAccountCount() == folders.count }
        let shared = Task { await quota.refreshWithResult([folders[0]], force: true) }
        await waitUntil { await quota.refreshJoins == 1 }
        refresh.cancel()
        transport.releaseAccountRequests()

        let result = await refresh.value
        let sharedResult = await shared.value
        XCTAssertEqual(result, Dictionary(uniqueKeysWithValues: folders.map { ($0, false) }))
        XCTAssertEqual(sharedResult, [folders[0]: true])
        XCTAssertEqual(transport.count(ending: "/account"), folders.count)
        let readings = await quota.currentReadings()
        XCTAssertTrue(folders.allSatisfy { readings[$0]?.freshness == .fresh })
    }

    func testCancellingRefreshBeforeDispatchReportsEveryUniqueAccountWithoutRequests() async throws {
        let profiles = try installPlaintextProfiles(count: 3)
        let folders = profiles.map(\.folder)
        let quota = service!
        await quota.stageProfiles(profiles)
        await quota.pauseNextCacheLoad()
        let refresh = Task { await quota.refreshWithResult(folders + [folders[0]], force: true) }
        await waitUntil { await quota.cacheLoadIsPaused }
        refresh.cancel()
        await quota.releaseCacheLoad()

        let result = await refresh.value
        XCTAssertEqual(result, Dictionary(uniqueKeysWithValues: folders.map { ($0, false) }))
        XCTAssertTrue(transport.recorded().isEmpty)
    }

    func testConfirmedSameAccountSignInInvalidatesAnOldCookieRefusalAndCoalescesNewRefreshes() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setAccount(status: 401, body: Data())
        transport.pauseNext = true
        let quota = service!
        let target = folder!
        async let old: [ProfileFolder: Bool] = quota.refreshWithResult([target], force: true)
        await transport.waitUntilPaused()
        defer { transport.release() }
        let newCookie = "replacement-session-marker"
        let blob = try CookieFixture.blob(version: 24, cookie: newCookie, host: ".claude.ai", password: password)
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: blob, databaseVersion: 24), for: profileURL)
        transport.setAccount(body: accountBody())
        let verified = try await quota.accountDetails(for: profile())
        XCTAssertEqual(verified.accountUUID, account)
        XCTAssertEqual(verified.organizationUUID, organization)
        async let first: [ProfileFolder: Bool] = quota.refreshWithResult([target], force: true)
        async let second: [ProfileFolder: Bool] = quota.refreshWithResult([target], force: true)
        await waitUntil { await quota.previousLoginWaits == 2 }
        transport.pauseNext = true
        transport.release()
        let oldResult = await old
        XCTAssertEqual(oldResult[target], false)
        await transport.waitUntilPaused()
        await waitUntil { await quota.refreshJoins == 1 }
        let during = try await shownReading(folder)
        XCTAssertNil(during.lastError)
        XCTAssertNil(during.snapshot)
        XCTAssertEqual(during.freshness, .refreshing)
        checkNil(try await loadCache()[folder])
        transport.release()
        let results = await (first, second)
        XCTAssertEqual(results.0[target], true)
        XCTAssertEqual(results.1[target], true)
        checkEqual(try await shownReading(folder).freshness, .fresh)
        XCTAssertEqual(transport.count(ending: "/account"), 3) // old, sign-in confirmation, shared new refresh
        XCTAssertEqual(transport.count(ending: "/usage"), 1)
        XCTAssertEqual(transport.recorded().filter { $0.url.path.hasSuffix("/account") }.map { $0.headers["Cookie"] },
                       ["sessionKey=\(session)", "sessionKey=\(newCookie)", "sessionKey=\(newCookie)"])
        let persisted = (try? String(contentsOf: cacheFile(), encoding: .utf8)) ?? ""
        let logged = (try? String(contentsOf: logFile(), encoding: .utf8)) ?? ""
        XCTAssertFalse(persisted.contains(newCookie))
        XCTAssertFalse(logged.contains(newCookie))
    }

    func testForcedRefreshDetectsANewCookieWithoutAnAccountDetailsReadAndDropsOldSuccess() async throws {
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: session,
                                         databaseVersion: 23), for: profileURL)
        await service.replaceProfiles([profile()])
        transport.setUsage(body: usageBody(five: 88, seven: 90))
        transport.pauseNext(ending: "/usage")
        let quota = service!
        let target = folder!
        async let old: [ProfileFolder: Bool] = quota.refreshWithResult([target], force: true)
        await transport.waitUntilPaused()
        defer { transport.release() }
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: "new-session",
                                         databaseVersion: 23), for: profileURL)
        transport.setUsage(body: usageBody(five: 12, seven: 30))
        async let new: [ProfileFolder: Bool] = quota.refreshWithResult([target], force: true)
        await waitUntil { await quota.previousLoginWaits == 1 }
        // The old usage response succeeds late; only the new cookie's usage may be published and cached.
        transport.pauseNext = true
        transport.release()
        let oldResult = await old
        XCTAssertEqual(oldResult[target], false)
        await transport.waitUntilPaused()
        checkNil(try await shownReading(folder).snapshot)
        checkNil(try await loadCache()[folder])
        transport.release()
        let newResult = await new
        XCTAssertEqual(newResult[target], true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        XCTAssertEqual(transport.recorded().filter { $0.url.path.hasSuffix("/account") }.map { $0.headers["Cookie"] },
                       ["sessionKey=\(session)", "sessionKey=new-session"])
        checkEqual(try await shownReading(folder).snapshot?.fiveHour.usedPercent, 12)
        checkEqual(try await loadCache()[folder]?.fiveHour.usedPercent, 12)
        checkEqual(try await shownReading(folder).snapshot?.channel, .appStore)
    }

    func testCancellingOneRefreshWaiterDoesNotCancelTheSharedRequestOrReportItsSuccess() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.pauseNext = true
        let quota = service!
        let target = folder!
        let first = Task { await quota.refreshWithResult([target], force: true) }
        await transport.waitUntilPaused()
        defer { transport.release() }
        let second = Task { await quota.refreshWithResult([target], force: true) }
        await waitUntil { await quota.refreshJoins == 1 }
        second.cancel()
        transport.release()
        let firstResult = await first.value
        let secondResult = await second.value
        XCTAssertEqual(firstResult[target], true)
        XCTAssertEqual(secondResult[target], false)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        checkEqual(try await shownReading(folder).freshness, .fresh)
    }

    func testCancelledNewLoginWaitDoesNotStartAReplacementRequest() async throws {
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: session,
                                         databaseVersion: 23), for: profileURL)
        await service.replaceProfiles([profile()])
        transport.pauseNext = true
        let quota = service!
        let target = folder!
        let old = Task { await quota.refreshWithResult([target], force: true) }
        await transport.waitUntilPaused()
        defer { transport.release() }
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: "new-session",
                                         databaseVersion: 23), for: profileURL)
        let replacement = Task { await quota.refreshWithResult([target], force: true) }
        await waitUntil { await quota.previousLoginWaits == 1 }
        replacement.cancel()
        transport.release()

        let oldResult = await old.value
        let cancelledResult = await replacement.value
        XCTAssertEqual(oldResult[target], false, "The old login's response remains invalidated")
        XCTAssertEqual(cancelledResult[target], false)
        XCTAssertEqual(transport.count(ending: "/account"), 1,
            "Cancellation while waiting must not start another login's request")
        XCTAssertEqual(transport.count(ending: "/usage"), 0)

        let retried = await quota.refreshWithResult([target], force: true)
        XCTAssertEqual(retried[target], true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        XCTAssertEqual(transport.recorded().filter { $0.url.path.hasSuffix("/account") }.map { $0.headers["Cookie"] },
            ["sessionKey=\(session)", "sessionKey=new-session"])
        checkEqual(try await shownReading(folder).freshness, .fresh)
    }

    func testRemovingAProfileDuringItsRefreshDropsTheSuccessfulResponse() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.pauseNext(ending: "/usage")
        let quota = service!
        let target = folder!
        async let pending: [ProfileFolder: Bool] = quota.refreshWithResult([target], force: true)
        await transport.waitUntilPaused()
        defer { transport.release() }
        await quota.replaceProfiles([])
        transport.release()
        let result = await pending
        XCTAssertEqual(result[target], false)
        checkNil(await quota.currentReadings()[target])
        checkNil(try await loadCache()[target])
    }

    func testConfirmingTheSameCookieKeepsTheExistingSingleFlightAndItsResult() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.pauseNext = true
        let quota = service!
        let target = folder!
        async let first: [ProfileFolder: Bool] = quota.refreshWithResult([target], force: true)
        await transport.waitUntilPaused()
        defer { transport.release() }
        _ = try await quota.accountDetails(for: profile())
        async let second: [ProfileFolder: Bool] = quota.refreshWithResult([target], force: true)
        await waitUntil { await quota.refreshJoins == 1 }
        transport.release()
        let results = await (first, second)
        XCTAssertEqual(results.0[target], true)
        XCTAssertEqual(results.1[target], true)
        checkEqual(await quota.previousLoginWaits, 0)
        XCTAssertEqual(transport.count(ending: "/account"), 2) // one refresh and the independent identity confirmation
        XCTAssertEqual(transport.count(ending: "/usage"), 1)
    }

    func testEveryOpeningReadsAllVisibleFoldersButNotTwiceWithinHalfAMinute() async throws {
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: session, databaseVersion: 23), for: profileURL)
        let second = try ProfileFolder("Claude_B")
        let secondURL = scratch.root.appending(path: "Claude_B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        await service.replaceProfiles([
            profile(),
            QuotaProfile(folder: second, directory: secondURL, accountUUID: otherAccount, organizationUUID: otherOrganization),
        ])
        await service.refreshVisible([folder, second])
        checkEqual(try await shownReading(folder).freshness, .fresh)
        checkEqual(try await shownReading(second).lastError, .cookieMissing)
        XCTAssertEqual(cookies.recordedProfiles().count, 2)

        clock.advance(by: 20)
        await service.refreshVisible([folder, second])
        XCTAssertEqual(cookies.recordedProfiles().count, 2)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        clock.advance(by: 40)
        await service.refreshVisible([folder, second])
        XCTAssertEqual(cookies.recordedProfiles().count, 4)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
    }

    func testPeriodicRefreshSleepsWithJitterAndSkipsUntilTheReadingIsOld() async throws {
        try installEncryptedCookie()
        let gateClock = GateClock(now: clock.now())
        gate = gateClock
        let jitter = ScriptedJitter(-90, 90)
        service = makeService(clock: gateClock, jitter: jitter)
        await service.replaceProfiles([profile()])
        await service.startPeriodicRefresh(current: folder)
        await waitUntil { gateClock.recordedSleeps().count == 1 }
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        XCTAssertEqual(gateClock.recordedSleeps(), [510])

        await service.startPeriodicRefresh(current: folder)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        gateClock.releaseOldest()
        await waitUntil { gateClock.recordedSleeps().count >= 2 }
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        XCTAssertEqual(gateClock.recordedSleeps()[1], 690)

        gateClock.releaseOldest()
        await waitUntil { self.transport.count(ending: "/account") == 2 }
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 1)
        await service.stopPeriodicRefresh()
        gateClock.cancelAll()
    }

    func testSwitchingTheCurrentFolderRefreshesIt() async throws {
        try installEncryptedCookie()
        let gateClock = GateClock(now: clock.now())
        gate = gateClock
        service = makeService(clock: gateClock, jitter: ScriptedJitter(0))
        let second = try ProfileFolder("Claude_B")
        let secondURL = scratch.root.appending(path: "Claude_B", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        await service.replaceProfiles([
            profile(),
            QuotaProfile(folder: second, directory: secondURL, accountUUID: otherAccount, organizationUUID: otherOrganization),
        ])
        await service.startPeriodicRefresh(current: nil)
        await waitUntil { gateClock.recordedSleeps().count == 1 }
        XCTAssertEqual(transport.recorded().count, 0)

        await service.startPeriodicRefresh(current: second)
        checkEqual(try await shownReading(second).lastError, .cookieMissing)
        await service.stopPeriodicRefresh()
        gateClock.cancelAll()
    }

    func testReadingsStreamEmitsTheCurrentMapAndUpdates() async throws {
        let box = ReadingBox()
        let stream = await service.readings()
        let task = Task {
            for await value in stream {
                box.append(value)
            }
        }
        await waitUntil { box.count() >= 1 }
        XCTAssertTrue(box.latest().isEmpty)
        await service.replaceProfiles([profile()])
        await waitUntil { box.count() >= 2 }
        XCTAssertEqual(box.latest()[folder]?.freshness, .unavailable)
        task.cancel()
    }

    func testAccountDetailsReadsIdentityWithoutRecordingARefresh() async throws {
        try installEncryptedCookie()
        let quota = service!
        let subject = profile()
        await quota.replaceProfiles([subject])
        let before = await quota.currentReadings()

        let details = try await quota.accountDetails(for: subject)
        XCTAssertEqual(details.accountUUID, account)
        XCTAssertEqual(details.email, "ada@example.com")
        XCTAssertEqual(details.organizationUUID, organization)
        XCTAssertEqual(details.plan, "Max 5×")
        XCTAssertEqual(transport.recorded().map(\.url.path), ["/api/account"])
        let afterSuccess = await quota.currentReadings()
        XCTAssertEqual(afterSuccess, before)

        transport.setAccount(status: 401, body: Data("zzbodyzz".utf8))
        do {
            _ = try await quota.accountDetails(for: subject)
            XCTFail("expected signed out")
        } catch let error as QuotaFailure {
            XCTAssertEqual(error, .signedOut)
            XCTAssertFalse(String(describing: error).contains("zzbodyzz"))
        }

        transport.setAccount(status: 200, body: accountBody(uuid: otherAccount))
        do {
            _ = try await quota.accountDetails(for: subject)
            XCTFail("expected an account mismatch")
        } catch let error as QuotaFailure {
            XCTAssertEqual(error, .accountMismatch)
            XCTAssertFalse(String(describing: error).contains(otherAccount))
        }
        let afterErrors = await quota.currentReadings()
        XCTAssertEqual(afterErrors, before)

        transport.setAccount(status: 200, body: accountBody())
        await quota.refresh([subject.folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 4)
        let refreshed = try await shownReading(subject.folder)
        XCTAssertEqual(refreshed.freshness, .fresh)
    }

    func testRefreshWaitsUntilTheCacheLoadFinishes() async throws {
        try await seedCache(
            account: account,
            organization: organization,
            five: 12.5,
            seven: 40,
            fetchedAt: clock.now()
        )
        try installEncryptedCookie()
        let quota = service!
        let target = folder!
        await quota.pauseNextCacheLoad()
        await quota.stageProfiles([profile()])
        async let initial = quota.currentReadings()
        await waitUntil { await quota.cacheLoadIsPaused }
        async let refreshed: Void = quota.refresh([target], force: false)
        await waitUntil { await quota.cacheLoadJoins == 1 }
        XCTAssertEqual(transport.recorded().count, 0)
        XCTAssertEqual(storage.callCount(), 0)
        await quota.releaseCacheLoad()
        let loaded = await initial
        await refreshed
        XCTAssertEqual(transport.recorded().count, 0)
        XCTAssertEqual(loaded[target]?.freshness, .fresh)
        XCTAssertEqual(loaded[target]?.snapshot?.fiveHour.usedPercent, 12.5)
    }

    func testSignedOutRefreshHidesTheCachedNumbers() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        transport.setAccount(status: 401, body: Data())
        clock.advance(by: 601)
        await service.refresh([folder], force: false)
        let signedOut = try await shownReading(folder)
        XCTAssertNil(signedOut.snapshot)

        transport.pauseNext = true
        transport.setAccount(status: 200, body: accountBody())
        clock.advance(by: 121)
        let quota = service!
        let target = folder!
        async let refreshing: Void = quota.refresh([target], force: true)
        await transport.waitUntilPaused()
        let reading = try await shownReading(folder)
        XCTAssertNil(reading.snapshot)
        XCTAssertEqual(reading.freshness, .refreshing)
        XCTAssertEqual(reading.lastError, .signedOut)
        transport.release()
        await refreshing
    }

    func testAMissingSignInCookieHidesTheCachedNumbersLikeASignOut() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        cookies.setCookie(nil, for: profileURL)
        clock.advance(by: 601)
        await service.refresh([folder], force: false)
        let missing = try await shownReading(folder)
        XCTAssertNil(missing.snapshot)
        XCTAssertEqual(missing.freshness, .unavailable)
        XCTAssertEqual(missing.lastError, .cookieMissing)
        checkEqual(try await loadCache()[folder]?.fiveHour.usedPercent, 12.5)

        // Signing in again brings a cookie back.
        try installEncryptedCookie(enqueuePassword: false)
        transport.pauseNext = true
        clock.advance(by: 121)
        let quota = service!
        let target = folder!
        async let refreshing: Void = quota.refresh([target], force: true)
        await transport.waitUntilPaused()
        let reading = try await shownReading(folder)
        XCTAssertNil(reading.snapshot)
        XCTAssertEqual(reading.freshness, .refreshing)
        XCTAssertEqual(reading.lastError, .cookieMissing)
        transport.release()
        await refreshing
        checkEqual(try await shownReading(folder).freshness, .fresh)
    }

    func testAReadStartedForTheFolderPreviousLoginDoesNotAnswerForTheNewOne() async throws {
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: session, databaseVersion: 23), for: profileURL)
        await service.replaceProfiles([profile()])
        transport.setAccount(status: 401, body: Data())
        transport.pauseNext = true
        let quota = service!
        let target = folder!
        let directory = profileURL!
        async let first: Void = quota.refresh([target], force: false)
        await transport.waitUntilPaused()
        // The folder now holds another login, which is signed in.
        await quota.replaceProfiles([
            QuotaProfile(folder: target, directory: directory, accountUUID: otherAccount, organizationUUID: otherOrganization),
        ])
        transport.setAccount(body: accountBody(uuid: otherAccount, organization: otherOrganization))
        async let forced: Void = quota.refresh([target], force: true)
        await waitUntil { await quota.previousLoginWaits == 1 }
        transport.pauseNext = true
        transport.release()
        await first
        await transport.waitUntilPaused()
        // The old login's refusal is dropped while the new login is read.
        let during = try await shownReading(folder)
        XCTAssertNil(during.lastError)
        XCTAssertEqual(during.freshness, .refreshing)
        transport.release()
        await forced

        let reading = try await shownReading(folder)
        XCTAssertNil(reading.lastError)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertEqual(reading.snapshot?.accountUUID, otherAccount)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        let joins = await quota.refreshJoins
        XCTAssertEqual(joins, 0)
        checkEqual(try await loadCache()[folder]?.accountUUID, otherAccount)
    }

    func testAnotherLoginInTheFolderInheritsNeitherTheSignOutNorTheThrottle() async throws {
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(), plaintextValue: session, databaseVersion: 23), for: profileURL)
        await service.replaceProfiles([profile()])
        transport.setAccount(status: 401, body: Data())
        await service.refresh([folder], force: false)
        checkEqual(try await shownReading(folder).lastError, .signedOut)

        await service.replaceProfiles([
            QuotaProfile(folder: folder, directory: profileURL, accountUUID: otherAccount, organizationUUID: otherOrganization),
        ])
        let waiting = try await shownReading(folder)
        XCTAssertNil(waiting.lastError)
        XCTAssertNil(waiting.snapshot)
        transport.setAccount(body: accountBody(uuid: otherAccount, organization: otherOrganization))
        await service.refresh([folder], force: false)
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertEqual(reading.snapshot?.accountUUID, otherAccount)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
    }

    func testARefusedReadKeepsTheAccountSignedInWithItsLastFigures() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        transport.setUsage(status: 403, body: Data(#"{"type":"error","error":{"type":"permission_error","message":"zzbodyzz"}}"#.utf8))
        clock.advance(by: 601)
        await service.refresh([folder], force: false)

        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.lastError, .refused)
        XCTAssertEqual(reading.freshness, .stale)
        XCTAssertEqual(reading.snapshot?.fiveHour.usedPercent, 12.5)
    }

    func testTooManyRequestsWaitsWhatClaudeAsksBeforeAnyRead() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 429, body: Data("zzbodyzz".utf8), headers: ["Retry-After": "900"])
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).lastError, .rateLimited(until: clock.now().addingTimeInterval(900)))
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        // Neither the panel, the timer nor a read the switch forces asks again before then.
        transport.setUsage(status: 200, body: usageBody())
        clock.advance(by: 899)
        await service.refreshVisible([folder])
        await service.refresh([folder], force: false)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        clock.advance(by: 1)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        let reading = try await shownReading(folder)
        XCTAssertNil(reading.lastError)
        XCTAssertEqual(reading.freshness, .fresh)
    }

    func testTooManyRequestsForTheSubscriptionAlsoHoldsTheLoginBack() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setChannel(status: 429, body: Data(), headers: ["Retry-After": "900"])
        await service.refresh([folder], force: true)
        // The figures read before it stand; the wait claude.ai asked for holds every read of this login.
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 1)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        clock.advance(by: 31)
        await service.refreshVisible([folder])
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        clock.advance(by: 869)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
    }

    func testTooManyRequestsWithoutAWaitBacksOffLongerEachTimeUntilAReadWorks() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 429, body: Data("zzbodyzz".utf8))
        await service.refresh([folder], force: true)
        // Five minutes, doubling with each limit in a row, an hour at most.
        for wait: TimeInterval in [300, 600, 1_200, 2_400, 3_600, 3_600] {
            let reads = transport.count(ending: "/account")
            clock.advance(by: wait - 1)
            await service.refresh([folder], force: true)
            XCTAssertEqual(transport.count(ending: "/account"), reads, "read before \(Int(wait)) s")
            clock.advance(by: 1)
            await service.refresh([folder], force: true)
            XCTAssertEqual(transport.count(ending: "/account"), reads + 1, "no read after \(Int(wait)) s")
        }

        transport.setUsage(status: 200, body: usageBody())
        clock.advance(by: 3_600)
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).lastError, nil)

        // After a read that worked, the next limit starts again from five minutes.
        transport.setUsage(status: 429, body: Data("zzbodyzz".utf8))
        clock.advance(by: 121)
        await service.refresh([folder], force: true)
        let reads = transport.count(ending: "/account")
        clock.advance(by: 300)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), reads + 1)
    }

    func testAnotherLoginInTheFolderDoesNotInheritTheWaitClaudeAskedFor() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 429, body: Data(), headers: ["Retry-After": "3600"])
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        await service.replaceProfiles([
            QuotaProfile(folder: folder, directory: profileURL, accountUUID: otherAccount, organizationUUID: otherOrganization),
        ])
        transport.setAccount(body: accountBody(uuid: otherAccount, organization: otherOrganization))
        transport.setUsage(status: 200, body: usageBody())
        clock.advance(by: 10)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        checkEqual(try await shownReading(folder).snapshot?.accountUUID, otherAccount)
    }

    func testALoginClaudeTurnedAwayIsAskedAgainHourlyOrWhenItsCookieChanges() async throws {
        try installEncryptedCookie()
        transport.setAccount(status: 401, body: Data("zzbodyzz".utf8))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).lastError, .signedOut)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        // Neither the panel nor the timer sends the same cookie again within the hour.
        clock.advance(by: 3_599)
        await service.refreshVisible([folder])
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        // Then once, so a refusal that was about something else does not last.
        clock.advance(by: 1)
        await service.refreshVisible([folder])
        await service.refreshVisible([folder])
        XCTAssertEqual(transport.count(ending: "/account"), 2)

        // The person's own retry does not wait for the hour.
        clock.advance(by: 31)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 3)

        // A new cookie is a new sign-in: it is asked about at once, and it counts.
        transport.setAccount(body: accountBody(), sessionKey: "fresh-session")
        cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(),
                                          plaintextValue: "fresh-session", databaseVersion: 23), for: profileURL)
        clock.advance(by: 1)
        await service.refreshVisible([folder])
        XCTAssertEqual(transport.count(ending: "/account"), 4)
        let reading = try await shownReading(folder)
        XCTAssertNil(reading.lastError)
        XCTAssertEqual(reading.freshness, .fresh)
    }

    func testAWaitOfSeveralHoursIsWaitedInFull() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 429, body: Data(), headers: ["Retry-After": "7200"])
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).lastError, .rateLimited(until: clock.now().addingTimeInterval(7_200)))

        transport.setUsage(status: 200, body: usageBody())
        clock.advance(by: 7_199)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        clock.advance(by: 1)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
    }

    func testAWaitAskedForBeyondADayEndsAfterADay() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 429, body: Data(), headers: ["Retry-After": "604800"])
        await service.refresh([folder], force: true)
        checkEqual(try await shownReading(folder).lastError, .rateLimited(until: clock.now().addingTimeInterval(86_400)))
    }

    func testAWaitOutlastsARestartAndStaysWithItsLogin() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 429, body: Data(), headers: ["Retry-After": "7200"])
        await service.refresh([folder], force: true)
        let until = clock.now().addingTimeInterval(7_200)

        await service.stopPeriodicRefresh()
        service = makeService(clock: clock, jitter: ScriptedJitter(0))
        storage.enqueue(.success(password))
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 200, body: usageBody())
        clock.advance(by: 7_199)
        await service.refreshVisible([folder])
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        checkEqual(try await shownReading(folder).lastError, .rateLimited(until: until))

        // Over, and cleared by the read that works: the next start owes nothing.
        clock.advance(by: 1)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        await service.stopPeriodicRefresh()
        service = makeService(clock: clock, jitter: ScriptedJitter(0))
        storage.enqueue(.success(password))
        await service.replaceProfiles([profile()])
        clock.advance(by: 121)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 3)
    }

    func testAWaitBroughtBackFromARestartIsNotAnotherLogins() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 429, body: Data(), headers: ["Retry-After": "7200"])
        await service.refresh([folder], force: true)

        await service.stopPeriodicRefresh()
        service = makeService(clock: clock, jitter: ScriptedJitter(0))
        storage.enqueue(.success(password))
        await service.replaceProfiles([
            QuotaProfile(folder: folder, directory: profileURL, accountUUID: otherAccount, organizationUUID: otherOrganization),
        ])
        transport.setAccount(body: accountBody(uuid: otherAccount, organization: otherOrganization))
        transport.setUsage(status: 200, body: usageBody())
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        checkEqual(try await shownReading(folder).snapshot?.accountUUID, otherAccount)
    }

    func testTheSignInCheckWaitsLikeAnyOtherRead() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setUsage(status: 429, body: Data(), headers: ["Retry-After": "900"])
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        let until = clock.now().addingTimeInterval(900)

        await assertThrows(.rateLimited(until: until)) { [service, profile] in
            _ = try await service!.accountDetails(for: profile())
        }
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        clock.advance(by: 900)
        _ = try await service.accountDetails(for: profile())
        XCTAssertEqual(transport.count(ending: "/account"), 2)
    }

    func testTooManyRequestsToTheSignInCheckHoldsTheLoginBack() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        transport.setAccount(status: 429, body: Data(), headers: ["Retry-After": "900"])
        await assertThrows(.rateLimited(until: clock.now().addingTimeInterval(900))) { [service, profile] in
            _ = try await service!.accountDetails(for: profile())
        }
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        transport.setAccount(body: accountBody())
        clock.advance(by: 899)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)
        clock.advance(by: 1)
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
    }

    func testKeychainRefusalIsNotRepeatedForAutomaticRefreshes() async throws {
        try installEncryptedCookie(enqueuePassword: false)
        storage.enqueue(.failure(.failed("refused")))
        storage.enqueue(.success(password))
        await service.replaceProfiles([profile()])

        await service.refresh([folder], force: false)
        let refused = try await shownReading(folder)
        XCTAssertEqual(refused.lastError, .keyUnavailable)
        XCTAssertEqual(storage.callCount(), 1)
        XCTAssertEqual(transport.recorded().count, 0)

        clock.advance(by: 121)
        await service.refresh([folder], force: false)
        let stillRefused = try await shownReading(folder)
        XCTAssertEqual(stillRefused.lastError, .keyUnavailable)
        XCTAssertEqual(storage.callCount(), 1)
        XCTAssertEqual(transport.recorded().count, 0)

        await service.refresh([folder], force: true)
        XCTAssertEqual(storage.callCount(), 2)
        let recovered = try await shownReading(folder)
        XCTAssertEqual(recovered.freshness, .fresh)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        clock.advance(by: 601)
        await service.refresh([folder], force: false)
        XCTAssertEqual(storage.callCount(), 2)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        let automatic = try await shownReading(folder)
        XCTAssertEqual(automatic.freshness, .fresh)
    }

    func testAccountDetailsClearsAKeychainRefusal() async throws {
        try installEncryptedCookie(enqueuePassword: false)
        storage.enqueue(.failure(.failed("refused")))
        storage.enqueue(.success(password))
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: false)
        XCTAssertEqual(storage.callCount(), 1)

        clock.advance(by: 121)
        let details = try await service.accountDetails(for: profile())
        XCTAssertEqual(details.email, "ada@example.com")
        XCTAssertEqual(storage.callCount(), 2)

        await service.refresh([folder], force: false)
        XCTAssertEqual(storage.callCount(), 2)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
        let recovered = try await shownReading(folder)
        XCTAssertEqual(recovered.freshness, .fresh)
    }

    func testAFutureAttemptDoesNotThrottle() async throws {
        try installEncryptedCookie()
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: true)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        clock.advance(by: -50)
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 1)

        clock.advance(by: -40)
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/account"), 2)
    }

    func testAFutureChannelCheckDoesNotBlockTheNextRead() async throws {
        try installEncryptedCookie()
        try await seedCache(
            account: account,
            organization: organization,
            five: 9,
            seven: 8,
            fetchedAt: clock.now().addingTimeInterval(-601),
            channelCheckedAt: clock.now().addingTimeInterval(3 * 24 * 60 * 60)
        )
        await service.replaceProfiles([profile()])
        await service.refresh([folder], force: false)
        XCTAssertEqual(transport.count(ending: "/subscription_details"), 1)
        let reading = try await shownReading(folder)
        XCTAssertEqual(reading.freshness, .fresh)
    }

    private func makeService(
        clock: any CompanionCore.Clock,
        jitter: any RefreshJitter,
        storage: (any SafeStorageKeyProviding)? = nil
    ) -> QuotaService {
        let log = CompanionLog(paths: scratch.paths, clock: clock)
        let cache = QuotaCacheStore(paths: scratch.paths, log: log, clock: clock)
        return QuotaService(
            cookies: cookies,
            safeStorage: storage ?? self.storage,
            transport: transport,
            cache: cache,
            clock: clock,
            jitter: jitter,
            userAgent: "TestAgent/1",
            log: log
        )
    }

    private func profile() -> QuotaProfile {
        QuotaProfile(folder: folder, directory: profileURL, accountUUID: account, organizationUUID: organization)
    }

    private func installPlaintextProfiles(count: Int) throws -> [QuotaProfile] {
        try (0..<count).map { index in
            let folder = try ProfileFolder("Claude_batch_\(index)")
            let directory = scratch.root.appending(path: folder.name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let account = UUID().uuidString.lowercased()
            let session = "session-\(folder.name)"
            cookies.setCookie(EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data(),
                                             plaintextValue: session, databaseVersion: 23), for: directory)
            transport.setAccount(body: accountBody(uuid: account), sessionKey: session)
            return QuotaProfile(folder: folder, directory: directory, accountUUID: account, organizationUUID: organization)
        }
    }

    private func installEncryptedCookie(enqueuePassword: Bool = true) throws {
        let blob = try CookieFixture.blob(version: 24, cookie: session, host: ".claude.ai", password: password)
        cookies.setCookie(
            EncryptedCookie(hostKey: ".claude.ai", encryptedValue: blob, databaseVersion: 24),
            for: profileURL
        )
        if enqueuePassword {
            storage.enqueue(.success(password))
        }
    }


    private func assertThrows(_ expected: QuotaFailure, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("nothing was thrown", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? QuotaFailure, expected, file: file, line: line)
        }
    }

    private func checkEqual<T: Equatable>(
        _ actual: T,
        _ expected: T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func checkNil(
        _ actual: Any?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(actual, file: file, line: line)
    }

    private func checkTrue(
        _ actual: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(actual, file: file, line: line)
    }

    private func checkFalse(
        _ actual: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(actual, file: file, line: line)
    }

    private func shownReading(_ folder: ProfileFolder) async throws -> QuotaReading {
        let readings = await service.currentReadings()
        return try XCTUnwrap(readings[folder])
    }

    private func loadCache() async throws -> [ProfileFolder: QuotaSnapshot] {
        let log = CompanionLog(paths: scratch.paths, clock: clock)
        let cache = QuotaCacheStore(paths: scratch.paths, log: log, clock: clock)
        return try await cache.load()
    }

    private func seedCache(
        account: String,
        organization: String,
        five: Double,
        seven: Double,
        fetchedAt: Date,
        channelCheckedAt: Date? = nil
    ) async throws {
        let snapshot = QuotaSnapshot(
            folder: folder,
            accountUUID: account,
            organizationUUID: organization,
            plan: "Pro",
            email: "ada@example.com",
            channel: .web,
            fiveHour: QuotaWindow(usedPercent: five),
            sevenDay: QuotaWindow(usedPercent: seven),
            fetchedAt: fetchedAt,
            channelCheckedAt: channelCheckedAt,
            source: .network
        )
        let log = CompanionLog(paths: scratch.paths, clock: clock)
        let cache = QuotaCacheStore(paths: scratch.paths, log: log, clock: clock)
        try await cache.save([folder: snapshot])
    }

    /// Starts the timer as the app does at launch, with a reading stored moments before quitting.
    private func launchWithAFreshStoredReading() async throws -> GateClock {
        let gateClock = GateClock(now: clock.now())
        gate = gateClock
        service = makeService(clock: gateClock, jitter: ScriptedJitter(0))
        try await seedCache(account: account, organization: organization, five: 10, seven: 20, fetchedAt: gateClock.now())
        await service.replaceProfiles([profile()])
        await service.startPeriodicRefresh(current: folder)
        return gateClock
    }

    private func writeHistory() throws {
        let body = """
        {"version":2,"samples":[
          {"t":1000,"org":"\(organization)","u":{"fh":1,"sd":2}},
          {"t":5000,"org":"\(otherOrganization)","u":{"fh":99,"sd":98}},
          {"t":4500,"org":"\(organization)","note":true},
          {"t":3000,"org":"\(organization)","u":{"fh":12,"sd":34}},
          {"t":4000,"org":"\(organization)","u":{"fh":140,"sd":7,"extra":1}}
        ]}
        """
        try Data(body.utf8).write(to: profileURL.appending(path: "plan-usage-history.json"))
    }

    private func accountBody(
        uuid: String? = nil,
        organization: String? = nil,
        plan: String = "claude_max",
        tier: String? = "default_claude_max_5x"
    ) -> Data {
        let id = uuid ?? account
        let org = organization ?? self.organization
        let tierField = tier.map { "\"rate_limit_tier\":\"\($0)\"" } ?? "\"rate_limit_tier\":null"
        return Data("""
        {"uuid":"\(id)","email_address":"  ada@example.com ","extra":true,"memberships":[
          {"organization":{"uuid":"\(org)","analytics_subscription_plan":"\(plan)",\(tierField),"name":"Personal"}}
        ]}
        """.utf8)
    }

    private func usageBody(
        five: Double = 12.5,
        seven: Double = 40,
        fiveReset: String? = nil,
        sevenReset: String? = nil
    ) -> Data {
        let fiveDate = fiveReset.map { "\"resets_at\":\"\($0)\"" } ?? "\"resets_at\":null"
        let sevenDate = sevenReset.map { "\"resets_at\":\"\($0)\"" } ?? "\"resets_at\":null"
        return Data("""
        {"five_hour":{"utilization":\(five),\(fiveDate)},"seven_day":{"utilization":\(seven),\(sevenDate)},"extra":1}
        """.utf8)
    }

    private func channelBody(_ url: String) -> Data {
        Data("""
        {"subscription_details_url":"\(url)","next_charge_date":"2026-12-01"}
        """.utf8)
    }

    private func iso(_ date: Date) -> String {
        ISO8601Fractional.string(from: date)
    }

    private func cacheFile() -> URL {
        scratch.paths.companionDataDirectory.appending(path: "quota-cache.json")
    }

    private func logFile() -> URL {
        scratch.paths.companionDataDirectory
            .appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: "cc-relay.log")
    }

    private func waitUntil(
        _ predicate: @escaping () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        // By time, not by scheduler turns: on a busy machine a thousand turns can pass before the
        // work under test has run at all.
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("condition was not reached", file: file, line: line)
    }
}

final class StorageScript: SafeStorageKeyProviding, @unchecked Sendable {
    var error: Error = SafeStorageError.notFound

    func password() async throws -> Data {
        throw error
    }
}

final class ScriptedJitter: RefreshJitter, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int]

    init(_ values: Int...) {
        self.values = values
    }

    func secondsOffset() -> Int {
        withLock(lock) { values.isEmpty ? 0 : values.removeFirst() }
    }
}

final class PathTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var error: Error?
        var headers: [String: String] = [:]
    }

    private let lock = NSLock()
    private var requests: [HTTPRequest] = []
    private var account = Reply(status: 200, body: Data())
    private var usage = Reply(status: 200, body: Data())
    private var channel = Reply(status: 200, body: Data())
    private var accountReplies: [String: Reply] = [:]
    private var holdingAccounts = false
    private var heldAccounts: [String: [CheckedContinuation<Void, Never>]] = [:]
    var pauseNext = false
    private var paused: CheckedContinuation<Void, Never>?
    private var pauseSuffix: String?

    func pauseNext(ending suffix: String) {
        withLock(lock) { pauseSuffix = suffix }
    }

    func setAccount(status: Int = 200, body: Data, error: Error? = nil, sessionKey: String? = nil,
                    headers: [String: String] = [:]) {
        withLock(lock) {
            let reply = Reply(status: status, body: body, error: error, headers: headers)
            if let sessionKey { accountReplies["sessionKey=\(sessionKey)"] = reply }
            else { account = reply }
        }
    }

    func holdAccountRequests() {
        withLock(lock) { holdingAccounts = true }
    }

    func heldAccountCount() -> Int {
        withLock(lock) { heldAccounts.values.reduce(0) { $0 + $1.count } }
    }

    func releaseAccountRequest(sessionKey: String) {
        let continuations = withLock(lock) { heldAccounts.removeValue(forKey: "sessionKey=\(sessionKey)") ?? [] }
        for continuation in continuations { continuation.resume() }
    }

    func releaseAccountRequests() {
        let continuations = withLock(lock) {
            holdingAccounts = false
            let continuations = heldAccounts.values.flatMap { $0 }
            heldAccounts.removeAll()
            return continuations
        }
        for continuation in continuations { continuation.resume() }
    }

    func setUsage(status: Int = 200, body: Data, error: Error? = nil, headers: [String: String] = [:]) {
        withLock(lock) { usage = Reply(status: status, body: body, error: error, headers: headers) }
    }

    func setChannel(status: Int = 200, body: Data, error: Error? = nil, headers: [String: String] = [:]) {
        withLock(lock) { channel = Reply(status: status, body: body, error: error, headers: headers) }
    }

    func recorded() -> [HTTPRequest] {
        withLock(lock) { requests }
    }

    func count(ending suffix: String) -> Int {
        recorded().filter { $0.url.path.hasSuffix(suffix) }.count
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply = withLock(lock) { () -> (Reply, Bool) in
            requests.append(request)
            let matchedSuffix = pauseSuffix.map { request.url.path.hasSuffix($0) } ?? false
            let shouldPause = pauseNext || matchedSuffix
            if shouldPause { pauseNext = false }
            if matchedSuffix { pauseSuffix = nil }
            if request.url.path.hasSuffix("/subscription_details") { return (channel, shouldPause) }
            if request.url.path.hasSuffix("/usage") { return (usage, shouldPause) }
            return (accountReplies[request.headers["Cookie"] ?? ""] ?? account, shouldPause)
        }
        if request.url.path.hasSuffix("/account") {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let held = withLock(lock) {
                    guard holdingAccounts else { return false }
                    heldAccounts[request.headers["Cookie"] ?? "", default: []].append(continuation)
                    return true
                }
                if !held { continuation.resume() }
            }
        }
        if reply.1 {
            await withCheckedContinuation { continuation in
                withLock(lock) { paused = continuation }
            }
        }
        if let error = reply.0.error { throw error }
        return HTTPResponse(statusCode: reply.0.status, headers: reply.0.headers, body: reply.0.body, finalURL: request.url)
    }

    func waitUntilPaused(file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let ready = withLock(lock) { paused != nil }
            if ready { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("no request reached the transport", file: file, line: line)
    }

    func release() {
        let continuation = withLock(lock) { () -> CheckedContinuation<Void, Never>? in
            let current = paused
            paused = nil
            return current
        }
        continuation?.resume()
    }
}

final class GateClock: CompanionCore.Clock, @unchecked Sendable {
    final class Pending: @unchecked Sendable {
        let seconds: TimeInterval
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ seconds: TimeInterval, _ continuation: CheckedContinuation<Void, Error>) {
            self.seconds = seconds
            self.continuation = continuation
        }

        func resume(throwing error: Error? = nil) {
            let continuation = withLock(lock) { () -> CheckedContinuation<Void, Error>? in
                let current = self.continuation
                self.continuation = nil
                return current
            }
            if let error {
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume()
            }
        }
    }

    private let lock = NSLock()
    private var instant: Date
    private var queue: [Pending] = []
    private var sleeps: [TimeInterval] = []

    init(now: Date) {
        instant = now
    }

    func now() -> Date {
        withLock(lock) { instant }
    }

    func recordedSleeps() -> [TimeInterval] {
        withLock(lock) { sleeps }
    }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        let seconds = Self.seconds(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let pending = Pending(seconds, continuation)
                withLock(lock) {
                    sleeps.append(seconds)
                    queue.append(pending)
                }
            }
        } onCancel: {
            self.cancelAll()
        }
    }

    func releaseOldest() {
        let item = withLock(lock) { () -> Pending? in
            guard !queue.isEmpty else { return nil }
            return queue.removeFirst()
        }
        guard let item else { return }
        withLock(lock) { instant.addTimeInterval(item.seconds) }
        item.resume()
    }

    func cancelAll() {
        let items = withLock(lock) { () -> [Pending] in
            let current = queue
            queue.removeAll()
            return current
        }
        for item in items {
            item.resume(throwing: CancellationError())
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}

final class ReadingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [[ProfileFolder: QuotaReading]] = []

    func append(_ value: [ProfileFolder: QuotaReading]) {
        withLock(lock) { values.append(value) }
    }

    func count() -> Int {
        withLock(lock) { values.count }
    }

    func latest() -> [ProfileFolder: QuotaReading] {
        withLock(lock) { values.last ?? [:] }
    }
}
