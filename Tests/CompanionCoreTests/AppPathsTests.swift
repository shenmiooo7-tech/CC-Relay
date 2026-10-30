import XCTest
@testable import CompanionCore

final class AppPathsTests: XCTestCase {
    func testLiveRootsFollowTheGivenHome() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let paths = AppPaths.live(home: home)

        XCTAssertEqual(paths.home.path, "/Users/example")
        XCTAssertEqual(paths.claudeProfilesRoot.path, "/Users/example/Library/Application Support")
        XCTAssertEqual(
            paths.companionDataDirectory.path,
            "/Users/example/Library/Application Support/CC-Relay"
        )
        XCTAssertEqual(paths.launchAgentsDirectory.path, "/Users/example/Library/LaunchAgents")
        XCTAssertEqual(paths.claudeCLIHome.path, "/Users/example/.claude")
        XCTAssertEqual(paths.claudeAppPath.path, "/Applications/Claude.app")
        XCTAssertEqual(paths.claudeAppURL, paths.claudeAppPath)
    }

    func testClaudeFoundElsewhereMovesOnlyTheApp() {
        let paths = AppPaths.live(home: URL(fileURLWithPath: "/Users/example", isDirectory: true))
        let moved = paths.locatingClaude(at: URL(fileURLWithPath: "/Users/example/Applications/Claude 2.app"))
        XCTAssertEqual(moved.claudeAppPath.path, "/Users/example/Applications/Claude 2.app")
        XCTAssertEqual(moved.claudeAppURL, moved.claudeAppPath)
        XCTAssertEqual(moved.locatingClaude(at: paths.claudeAppPath), paths)
    }

    func testSandboxRepeatsTheHomeLayoutAndRelocatesTheClaudeApp() {
        let root = URL(fileURLWithPath: "/tmp/cc-relay box", isDirectory: true)
        let paths = AppPaths.sandbox(root: root)
        let live = AppPaths.live(home: URL(fileURLWithPath: "/Users/example", isDirectory: true))

        XCTAssertEqual(paths.home.path, "/tmp/cc-relay box/home")
        XCTAssertEqual(
            paths.claudeProfilesRoot.path,
            "/tmp/cc-relay box/home/Library/Application Support"
        )
        XCTAssertEqual(
            paths.companionDataDirectory.path,
            "/tmp/cc-relay box/home/Library/Application Support/CC-Relay"
        )
        XCTAssertEqual(paths.launchAgentsDirectory.path, "/tmp/cc-relay box/home/Library/LaunchAgents")
        XCTAssertEqual(paths.claudeCLIHome.path, "/tmp/cc-relay box/home/.claude")
        XCTAssertEqual(paths.claudeAppPath.path, "/tmp/cc-relay box/Applications/Claude.app")

        XCTAssertEqual(suffix(paths.claudeProfilesRoot, after: paths.home), suffix(live.claudeProfilesRoot, after: live.home))
        XCTAssertEqual(
            suffix(paths.companionDataDirectory, after: paths.home),
            suffix(live.companionDataDirectory, after: live.home)
        )
        XCTAssertEqual(
            suffix(paths.launchAgentsDirectory, after: paths.home),
            suffix(live.launchAgentsDirectory, after: live.home)
        )
        XCTAssertEqual(suffix(paths.claudeCLIHome, after: paths.home), suffix(live.claudeCLIHome, after: live.home))

        for path in [
            paths.home.path,
            paths.claudeProfilesRoot.path,
            paths.companionDataDirectory.path,
            paths.launchAgentsDirectory.path,
            paths.claudeCLIHome.path,
            paths.claudeAppPath.path,
        ] {
            XCTAssertTrue(path.hasPrefix("/tmp/cc-relay box/"), path)
        }
    }

    func testCurrentUsesSandboxWhenTheVariableIsSet() {
        let processInfo = EnvironmentProcessInfo(environment: [
            AppEnvironment.sandboxVariable: "  /tmp/sand box  ",
            "HOME": "/Users/ignored",
        ])
        let paths = AppEnvironment.current(processInfo: processInfo)

        XCTAssertEqual(paths.home.path, "/tmp/sand box/home")
        XCTAssertEqual(
            paths.companionDataDirectory.path,
            "/tmp/sand box/home/Library/Application Support/CC-Relay"
        )
        XCTAssertEqual(paths.claudeCLIHome.path, "/tmp/sand box/home/.claude")
        XCTAssertEqual(paths.claudeAppPath.path, "/tmp/sand box/Applications/Claude.app")
        XCTAssertFalse(paths.home.path.contains("/Users/ignored"))
    }

    func testCurrentUsesLiveHomeWhenSandboxIsAbsentOrBlank() {
        let home = "/Users/example"
        let absent = EnvironmentProcessInfo(environment: ["HOME": home])
        let blank = EnvironmentProcessInfo(environment: [
            AppEnvironment.sandboxVariable: " \n",
            "HOME": home,
        ])

        XCTAssertEqual(AppEnvironment.current(processInfo: absent), AppPaths.live(home: URL(fileURLWithPath: home, isDirectory: true)))
        XCTAssertEqual(AppEnvironment.current(processInfo: blank), AppPaths.live(home: URL(fileURLWithPath: home, isDirectory: true)))
    }

    private func suffix(_ url: URL, after home: URL) -> String {
        let prefix = home.path
        XCTAssertTrue(url.path.hasPrefix(prefix))
        return String(url.path.dropFirst(prefix.count))
    }
}

private final class EnvironmentProcessInfo: ProcessInfo, @unchecked Sendable {
    private let values: [String: String]

    init(environment: [String: String]) {
        self.values = environment
        super.init()
    }

    override var environment: [String: String] { values }
}
