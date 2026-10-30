import Foundation

/// Blocks real-machine adapters while a test runner or a sandbox is in effect.
///
/// Call `assertLiveActionsAllowed()` before launching a process, reading a
/// profile, touching the keychain, or writing outside the sandbox. The check
/// reads the supplied environment and does not change the process environment.
public enum SafetyTripwire {
    public static let testVariable = "CC_RELAY_TEST"
    public static let sandboxVariable = AppEnvironment.sandboxVariable
    /// Present whenever XCTest launched this process, even without our own flag.
    public static let xcTestConfigurationVariable = "XCTestConfigurationFilePath"

    /// Throws when live actions must not run.
    ///
    /// Checked in order, so the reported variable is the first one that applies:
    /// `CC_RELAY_TEST=1`; any present `CC_RELAY_SANDBOX` value,
    /// including an empty one; a process named `xctest` or `swiftpm-testing-helper`;
    /// a loaded bundle whose path ends in `.xctest`; then a set
    /// `XCTestConfigurationFilePath`. The process checks still apply when the
    /// environment flag was never exported, which is what a direct `swift test`
    /// looks like. A refusal never includes the sandbox path or the configuration
    /// file path.
    public static func assertLiveActionsAllowed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processName: String = ProcessInfo.processInfo.processName,
        loadedBundlePaths: [String] = Bundle.allBundles.map(\.bundlePath) + Bundle.allFrameworks.map(\.bundlePath),
        xcTestConfigurationFilePath: String? = ProcessInfo.processInfo.environment[xcTestConfigurationVariable]
    ) throws {
        if environment[testVariable] == "1" {
            throw SafetyRefusal(variable: testVariable)
        }
        if environment[sandboxVariable] != nil {
            throw SafetyRefusal(variable: sandboxVariable)
        }
        if let runner = matchedTestProcessName(processName) {
            throw SafetyRefusal(variable: runner)
        }
        if loadedBundlePaths.contains(where: isTestBundlePath) {
            throw SafetyRefusal(variable: testBundleSuffix)
        }
        if xcTestConfigurationFilePath != nil {
            throw SafetyRefusal(variable: xcTestConfigurationVariable)
        }
    }

    private static let testProcessNames: Set<String> = ["xctest", "swiftpm-testing-helper"]
    private static let testBundleSuffix = ".xctest"

    /// `xctest` may show up as a bare process name or as the last component of a path.
    private static func matchedTestProcessName(_ name: String) -> String? {
        if testProcessNames.contains(name) {
            return name
        }
        let leaf = URL(fileURLWithPath: name).lastPathComponent
        if testProcessNames.contains(leaf) {
            return leaf
        }
        return nil
    }

    /// Matches both `Foo.xctest` and a binary nested inside that bundle.
    private static func isTestBundlePath(_ path: String) -> Bool {
        let lowered = path.lowercased()
        if lowered.hasSuffix(testBundleSuffix) {
            return true
        }
        return lowered.split(separator: "/").contains { $0.hasSuffix(testBundleSuffix) }
    }
}

public struct SafetyRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    public let variable: String

    public var description: String {
        "Live actions are blocked (\(variable) is set)."
    }
}
