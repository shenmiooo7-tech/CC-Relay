import XCTest
@testable import CompanionCore

final class OSFakeTests: XCTestCase {
    func testClockSleepAdvancesImmediately() async throws {
        let clock = TestClock(now: Date(timeIntervalSince1970: 100))
        try await clock.sleep(for: .milliseconds(2500))
        clock.advance(by: 1)
        XCTAssertEqual(clock.now().timeIntervalSince1970, 103.5, accuracy: 0.000_1)
    }

    func testProcessControllerAndLaunchMonitorAreScriptable() async throws {
        let processes = FakeProcessController()
        let profile = URL(fileURLWithPath: "/tmp/profiles/Claude", isDirectory: true)
        let instance = ClaudeInstance(
            pid: 42,
            profileDirectory: profile,
            hasExplicitProfileFlag: true,
            startedAt: Date(timeIntervalSince1970: 10),
            executableURL: URL(fileURLWithPath: "/Applications/Claude.app/Contents/MacOS/Claude")
        )
        processes.setInstances([instance])
        let listed = try await processes.runningInstances()
        XCTAssertEqual(listed, [instance])
        XCTAssertEqual(processes.runningQueryCount(), 1)

        processes.enqueueQuit(.failure(.failed("closed")))
        do {
            _ = try await processes.quitAll(timeout: .seconds(20))
            XCTFail("expected the scripted quit failure")
        } catch let error as FakeScriptError {
            XCTAssertEqual(error, .failed("closed"))
        }
        XCTAssertEqual(processes.recordedQuitTimeouts(), [.seconds(20)])

        let closed = URL(fileURLWithPath: "/tmp/Claude_a", isDirectory: true)
        processes.consultBeforeForce(closedProfilesWhenRefused: [closed])
        do {
            _ = try await processes.quitAll(timeout: .seconds(20), beforeForce: { false })
            XCTFail("expected the refused force to fail the quit")
        } catch let error as ClaudeProcessError {
            XCTAssertEqual(error, .stillRunning(pids: [], closedProfiles: [closed]))
        }
        XCTAssertEqual(processes.recordedBeforeForceAnswers(), [false])

        processes.enqueueLaunch(.success(instance))
        let launched = try await processes.launch(profile: profile, deepLink: URL(string: "claude://code/continue?session=local_abc"))
        XCTAssertEqual(launched, instance)
        XCTAssertTrue(launched.hasExplicitProfileFlag)
        XCTAssertEqual(processes.recordedLaunches().count, 1)
        XCTAssertEqual(processes.recordedLaunches()[0].profile, profile)

        let monitor = FakeLaunchMonitor()
        let stream = monitor.launches()
        let event = LaunchEvent(pid: 42, profileDirectory: profile, hasExplicitProfileFlag: false)
        monitor.emit(event)
        monitor.finish()
        var received: [LaunchEvent] = []
        for await item in stream {
            received.append(item)
        }
        XCTAssertEqual(received, [event])
        XCTAssertFalse(received[0].hasExplicitProfileFlag)
        XCTAssertEqual(monitor.startCount(), 1)
    }

    func testRemainingFakesRecordCallsAndReplayResults() async throws {
        let tasks = FakeTaskInspector()
        let info = CodeTaskInfo(pid: 7, sessionID: "cli", workingDirectory: "/tmp/work", reason: .statusBusy)
        tasks.enqueue(.busy([info]))
        tasks.enqueue(.unknown(TaskUnknownReason.registryMismatch))
        let busy = await tasks.activity()
        let unknown = await tasks.activity()
        let idle = await tasks.activity()
        XCTAssertEqual(busy, .busy([info]))
        XCTAssertEqual(unknown, .unknown(TaskUnknownReason.registryMismatch))
        XCTAssertEqual(idle, .idle)
        XCTAssertEqual(tasks.callCount(), 3)

        let keys = FakeSafeStorage()
        keys.enqueue(.success(Data("secret".utf8)))
        let password = try await keys.password()
        XCTAssertEqual(password, Data("secret".utf8))
        XCTAssertEqual(keys.callCount(), 1)

        let cookies = FakeCookieReader()
        let profile = URL(fileURLWithPath: "/tmp/Claude", isDirectory: true)
        let cookie = EncryptedCookie(hostKey: ".claude.ai", encryptedValue: Data([1, 2]), databaseVersion: 24)
        cookies.setCookie(cookie, for: profile)
        XCTAssertEqual(try cookies.sessionCookie(profile: profile), cookie)
        XCTAssertEqual(cookies.recordedProfiles(), [profile])

        let http = FakeHTTPTransport()
        let request = HTTPRequest(method: "GET", url: URL(string: "https://claude.ai/api/account")!)
        let response = HTTPResponse(statusCode: 200, body: Data("{}".utf8), finalURL: request.url)
        http.enqueue(.success(response))
        let sent = try await http.send(request)
        XCTAssertEqual(sent, response)
        XCTAssertEqual(http.recordedRequests(), [request])
        XCTAssertFalse(request.allowsRedirects)
        XCTAssertEqual(request.timeout, .seconds(20))
        XCTAssertEqual(request.maximumBodyBytes, 2 * 1024 * 1024)

        let login = FakeLoginItems()
        let initiallyDisabled = try await login.isEnabled
        XCTAssertFalse(initiallyDisabled)
        let executable = URL(fileURLWithPath: "/tmp/CC-Relay")
        try await login.enable(executable: executable)
        let enabled = try await login.isEnabled
        XCTAssertTrue(enabled)
        XCTAssertEqual(login.recordedEnables(), [executable])
        try await login.disable()
        let disabled = try await login.isEnabled
        XCTAssertFalse(disabled)
        XCTAssertEqual(login.disableCount(), 1)

        let revealer = FakeFileRevealer()
        try await revealer.reveal(executable)
        XCTAssertEqual(revealer.recordedURLs(), [executable])
    }
}
