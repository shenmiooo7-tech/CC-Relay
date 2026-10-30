import XCTest
@testable import CompanionCore

final class ProfileFolderTests: XCTestCase {
    func testDefaultAndConventionalNames() throws {
        let defaultFolder = try ProfileFolder("Claude")
        XCTAssertTrue(defaultFolder.isDefault)
        XCTAssertTrue(defaultFolder.isConventionalName)

        let conventional = try ProfileFolder("Claude_Kxm2")
        XCTAssertFalse(conventional.isDefault)
        XCTAssertTrue(conventional.isConventionalName)

        let trailing = try ProfileFolder("Claude_")
        XCTAssertFalse(trailing.isDefault)
        XCTAssertFalse(trailing.isConventionalName)

        let free = try ProfileFolder("Work Account")
        XCTAssertFalse(free.isDefault)
        XCTAssertFalse(free.isConventionalName)

        let lowercase = try ProfileFolder("claude")
        XCTAssertFalse(lowercase.isDefault)
        XCTAssertFalse(lowercase.isConventionalName)
    }

    func testRejectsEmptyReservedAndNestedNames() {
        XCTAssertThrowsError(try ProfileFolder("")) { error in
            XCTAssertEqual(error as? ProfileFolderError, .empty)
        }
        XCTAssertThrowsError(try ProfileFolder(".")) { error in
            XCTAssertEqual(error as? ProfileFolderError, .reserved)
        }
        XCTAssertThrowsError(try ProfileFolder("..")) { error in
            XCTAssertEqual(error as? ProfileFolderError, .reserved)
        }
        XCTAssertThrowsError(try ProfileFolder("Claude/hidden")) { error in
            XCTAssertEqual(error as? ProfileFolderError, .notASingleComponent)
        }
        XCTAssertThrowsError(try ProfileFolder("bad\0name")) { error in
            XCTAssertEqual(error as? ProfileFolderError, .notASingleComponent)
        }
    }

    func testEncodesAsASingleString() throws {
        let data = try StableJSON.encode(try ProfileFolder("Claude_204"))
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"Claude_204\"")
        XCTAssertThrowsError(try StableJSON.decode(ProfileFolder.self, from: Data("\"Claude/no\"".utf8)))
    }
}

final class ModelCodingTests: XCTestCase {
    func testStateRoundTripKeepsUnknownKeysFromFailing() throws {
        let state = try sampleState()
        let encoded = try StableJSON.encode(state)
        var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        object["futureFeature"] = ["enabled": true]
        var accounts = object["accounts"] as! [[String: Any]]
        accounts[0]["carrierPigeon"] = "ignore-me"
        object["accounts"] = accounts
        let mutated = try JSONSerialization.data(withJSONObject: object)

        let decoded = try StableJSON.decode(CompanionState.self, from: mutated)
        XCTAssertEqual(decoded, state)
    }

    func testAStateFileFromAnEarlierVersionStillLoads() throws {
        let state = try sampleState()
        var object = try JSONSerialization.jsonObject(with: StableJSON.encode(state)) as! [String: Any]
        // Earlier versions kept a record of the first-run import here; it is no longer read or written.
        object["takeover"] = ["completedAt": "2026-10-25T01:31:00.000Z", "importedFrom": "file:///Users/example/.old/"]
        let decoded = try StableJSON.decode(CompanionState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, state)
    }

    func testMissingOptionalKeysUseEmptyDefaults() throws {
        let json = """
        {
          "settings": { "language": "zhHans" }
        }
        """.data(using: .utf8)!
        let state = try StableJSON.decode(CompanionState.self, from: json)
        XCTAssertEqual(state.schemaVersion, CompanionState.currentSchemaVersion)
        XCTAssertEqual(state.accounts, [])
        XCTAssertNil(state.activeFolder)
        XCTAssertEqual(state.settings, Settings(language: .zhHans))
        XCTAssertTrue(state.settings.autoSyncOnSwitch)
        XCTAssertFalse(state.settings.autoSwitchOnQuota, "An upgrade must not silently opt an existing user into automatic closing")
        XCTAssertFalse(state.settings.autoCompactOnLowQuota, "Compaction needs the plugin, which is installed when it is turned on")
        XCTAssertFalse(state.settings.launchAtLogin, "Starting at login is the person's choice, made in the settings")
        XCTAssertTrue(state.settings.confirmSwitch)
        XCTAssertEqual(state.pendingSignIns, [])
        XCTAssertEqual(state.historyJobs, [])
        XCTAssertEqual(state.relaunchDebt, [])
        XCTAssertEqual(state.knownUnmanagedFolders, [])
    }

    func testUnsupportedSchemaVersionDoesNotDecode() {
        let json = Data("{\"schemaVersion\":2,\"accounts\":[]}".utf8)
        XCTAssertThrowsError(try StableJSON.decode(CompanionState.self, from: json))
    }

    func testQuotaSnapshotFillsMissingOptionals() throws {
        let json = """
        {
          "folder": "Claude",
          "accountUUID": "11111111-1111-4111-8111-111111111111",
          "organizationUUID": "22222222-2222-4222-8222-222222222221",
          "fetchedAt": "2026-10-24T09:00:02Z",
          "extraWindow": 1
        }
        """.data(using: .utf8)!
        let snapshot = try StableJSON.decode(QuotaSnapshot.self, from: json)
        XCTAssertEqual(snapshot.folder, try ProfileFolder("Claude"))
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.email)
        XCTAssertEqual(snapshot.channel, .unknown)
        XCTAssertEqual(snapshot.fiveHour, QuotaWindow())
        XCTAssertEqual(snapshot.sevenDay, QuotaWindow())
        XCTAssertNil(snapshot.channelCheckedAt)
        XCTAssertEqual(snapshot.source, .network)
        XCTAssertEqual(snapshot.fetchedAt, Date(timeIntervalSince1970: 1_792_832_402))
    }

    func testHistoryJobAndProfileSnapshotRoundTrip() throws {
        let target = try ProfileFolder("Claude_Kxm2")
        let donorFolder = try ProfileFolder("Claude")
        let job = HistoryJob(
            target: target,
            targetAccountUUID: "33333333-3333-4333-8333-333333333333",
            targetOrganizationUUID: "33333333-3333-4333-8333-333333333301",
            donors: [
                HistoryDonor(
                    folder: donorFolder,
                    accountUUID: "11111111-1111-4111-8111-111111111111",
                    organizationUUID: "22222222-2222-4222-8222-222222222221"
                ),
            ],
            codePreference: CodePreferenceIntent(
                sourceAccountUUID: "11111111-1111-4111-8111-111111111111",
                bypassOptIn: true
            ),
            paused: true,
            issue: .interrupted,
            revision: 4,
            createdAt: Date(timeIntervalSince1970: 1_792_832_402.345)
        )
        let jobData = try StableJSON.encode(job)
        XCTAssertEqual(try StableJSON.decode(HistoryJob.self, from: jobData), job)
        XCTAssertTrue(String(decoding: jobData, as: UTF8.self).contains("2026-10-24T09:00:02.345Z"))

        let bucket = try SessionBucket(
            accountUUID: "11111111-1111-4111-8111-111111111111",
            organizationUUID: "22222222-2222-4222-8222-222222222221"
        )
        XCTAssertEqual(
            bucket.relativePath,
            "claude-code-sessions/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222221"
        )
        let snapshot = ProfileSnapshot(
            folder: donorFolder,
            url: URL(fileURLWithPath: "/tmp/profiles/Claude", isDirectory: true),
            status: .signedIn(
                AccountIdentity(
                    accountUUID: bucket.accountUUID,
                    activeOrganizationUUID: bucket.organizationUUID,
                    knownOrganizationUUIDs: [bucket.organizationUUID],
                    email: "ada@example.com",
                    plan: "Pro"
                )
            ),
            sessionBuckets: [bucket],
            readableBucket: bucket,
            duplicateOf: target
        )
        XCTAssertEqual(try StableJSON.decode(ProfileSnapshot.self, from: StableJSON.encode(snapshot)), snapshot)

        let signedOut = ProfileStatus.signedOut(lastAccountUUID: nil)
        XCTAssertEqual(try StableJSON.decode(ProfileStatus.self, from: StableJSON.encode(signedOut)), signedOut)
        let unreadable = ProfileStatus.unreadable(reason: .configUnparsable)
        XCTAssertEqual(try StableJSON.decode(ProfileStatus.self, from: StableJSON.encode(unreadable)), unreadable)
    }

    func testSessionBucketRejectsPathSeparators() {
        XCTAssertThrowsError(
            try SessionBucket(accountUUID: "acct/hidden", organizationUUID: "org")
        )
    }

    private func sampleState() throws -> CompanionState {
        let active = try ProfileFolder("Claude_Kxm2")
        let waiting = try ProfileFolder("Claude_Wait")
        let unmanaged = try ProfileFolder("Notes")
        let added = Date(timeIntervalSince1970: 1_792_832_402.345)
        return CompanionState(
            accounts: [
                ManagedAccount(folder: active, displayName: "203", addedAt: added),
            ],
            activeFolder: active,
            settings: Settings(
                autoSyncOnSwitch: false,
                autoSwitchOnQuota: true,
                autoCorrectDefaultLaunch: true,
                autoCompactOnLowQuota: false,
                launchAtLogin: false,
                language: .en,
                confirmSwitch: false
            ),
            pendingSignIns: [
                PendingSignIn(
                    folder: waiting,
                    createdAt: added,
                    returnToFolder: active,
                    expectAccountUUID: "33333333-3333-4333-8333-333333333333"
                ),
            ],
            historyJobs: [
                HistoryJob(
                    target: waiting,
                    targetAccountUUID: nil,
                    targetOrganizationUUID: nil,
                    donors: [
                        HistoryDonor(
                            folder: active,
                            accountUUID: "33333333-3333-4333-8333-333333333333",
                            organizationUUID: "33333333-3333-4333-8333-333333333301"
                        ),
                    ],
                    codePreference: nil,
                    paused: true,
                    issue: .failed,
                    revision: 2,
                    createdAt: added
                ),
            ],
            relaunchDebt: [active],
            knownUnmanagedFolders: [unmanaged]
        )
    }

    func testUnknownEnumRawValuesUseFallbacks() throws {
        XCTAssertEqual(try StableJSON.decode(AppLanguage.self, from: Data("\"ja\"".utf8)), .system)
        XCTAssertEqual(try StableJSON.decode(AppLanguage.self, from: Data("\"zhHans\"".utf8)), .zhHans)
        XCTAssertEqual(try StableJSON.decode(SubscriptionChannel.self, from: Data("\"carrier\"".utf8)), .unknown)
        XCTAssertEqual(try StableJSON.decode(SubscriptionChannel.self, from: Data("\"web\"".utf8)), .web)
        XCTAssertEqual(try StableJSON.decode(QuotaSource.self, from: Data("\"cache\"".utf8)), .network)
        XCTAssertEqual(try StableJSON.decode(QuotaSource.self, from: Data("\"localHistory\"".utf8)), .localHistory)
        XCTAssertEqual(try StableJSON.decode(HistoryIssue.self, from: Data("\"later\"".utf8)), .failed)
        XCTAssertEqual(try StableJSON.decode(HistoryIssue.self, from: Data("\"interrupted\"".utf8)), .interrupted)
        XCTAssertEqual(
            try StableJSON.decode(ProfileUnreadability.self, from: Data("\"gone\"".utf8)),
            .configUnparsable
        )
        XCTAssertEqual(
            try StableJSON.decode(ProfileUnreadability.self, from: Data("\"unreadableDirectory\"".utf8)),
            .unreadableDirectory
        )
        XCTAssertThrowsError(try StableJSON.decode(AppLanguage.self, from: Data("1".utf8)))
        XCTAssertThrowsError(try StableJSON.decode(SubscriptionChannel.self, from: Data("true".utf8)))
        XCTAssertThrowsError(try StableJSON.decode(QuotaSource.self, from: Data("[]".utf8)))
        XCTAssertThrowsError(try StableJSON.decode(HistoryIssue.self, from: Data("null".utf8)))
        XCTAssertThrowsError(try StableJSON.decode(ProfileUnreadability.self, from: Data("{}".utf8)))
    }
}

final class StableJSONTests: XCTestCase {
    private struct Sample: Codable, Equatable {
        var zebra: String
        var alpha: Date
        var link: String
    }

    func testSortedKeysPrettyPrintingAndFractionalDates() throws {
        let date = Date(timeIntervalSince1970: 1_792_832_402.345)
        let data = try StableJSON.encode(Sample(zebra: "z", alpha: date, link: "https://claude.ai/api"))
        let text = String(decoding: data, as: UTF8.self)
        let alpha = try XCTUnwrap(text.range(of: "\"alpha\""))
        let link = try XCTUnwrap(text.range(of: "\"link\""))
        let zebra = try XCTUnwrap(text.range(of: "\"zebra\""))
        XCTAssertLessThan(alpha.lowerBound, link.lowerBound)
        XCTAssertLessThan(link.lowerBound, zebra.lowerBound)
        XCTAssertTrue(text.contains("https://claude.ai/api"))
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertTrue(text.contains("2026-10-24T09:00:02.345Z"))
        XCTAssertEqual(try StableJSON.decode(Sample.self, from: data), Sample(zebra: "z", alpha: date, link: "https://claude.ai/api"))
    }

    func testDecoderAcceptsDatesWithoutFractionalSeconds() throws {
        let json = Data("{\"alpha\":\"2026-10-24T09:00:02Z\",\"link\":\"x\",\"zebra\":\"z\"}".utf8)
        let sample = try StableJSON.decode(Sample.self, from: json)
        XCTAssertEqual(sample.alpha, Date(timeIntervalSince1970: 1_792_832_402))
    }
}
