import XCTest
@testable import CompanionCore

final class SafetyTripwireTests: XCTestCase {
    func testEmptyEnvironmentAllowsLiveActions() {
        XCTAssertNoThrow(try allow(environment: [:]))
        XCTAssertNoThrow(try allow(environment: ["HOME": "/Users/example"]))
    }

    func testTestFlagBlocksOnlyTheExactValue() throws {
        XCTAssertNoThrow(try allow(environment: [
            SafetyTripwire.testVariable: "0",
        ]))
        XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed(environment: [
            SafetyTripwire.testVariable: "1",
            "HOME": "/Users/example",
        ])) { error in
            XCTAssertEqual(error as? SafetyRefusal, SafetyRefusal(variable: SafetyTripwire.testVariable))
        }
    }

    func testAnySandboxValueBlocksWithoutEchoingThePath() {
        let secretPath = "/tmp/secret-sandbox-location"
        XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed(environment: [
            SafetyTripwire.sandboxVariable: secretPath,
        ])) { error in
            XCTAssertEqual(error as? SafetyRefusal, SafetyRefusal(variable: SafetyTripwire.sandboxVariable))
            XCTAssertFalse(String(describing: error).contains(secretPath))
        }

        XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed(environment: [
            SafetyTripwire.sandboxVariable: "",
        ])) { error in
            XCTAssertEqual(error as? SafetyRefusal, SafetyRefusal(variable: SafetyTripwire.sandboxVariable))
        }
    }

    func testDefaultParameterHonorsTheAmbientTestFlag() {
        XCTAssertEqual(ProcessInfo.processInfo.environment[SafetyTripwire.testVariable], "1")
        XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed()) { error in
            XCTAssertEqual(error as? SafetyRefusal, SafetyRefusal(variable: SafetyTripwire.testVariable))
        }
    }

    func testRunnerIdentityBlocksWhenTheFlagIsAbsent() {
        for name in ["xctest", "swiftpm-testing-helper", "/usr/bin/xctest"] {
            XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed(
                environment: [:],
                processName: name,
                loadedBundlePaths: [],
                xcTestConfigurationFilePath: nil
            )) { error in
                let expected = name == "/usr/bin/xctest" ? "xctest" : name
                XCTAssertEqual(error as? SafetyRefusal, SafetyRefusal(variable: expected))
            }
        }

        XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed(
            environment: [:],
            processName: "CCRelay",
            loadedBundlePaths: ["/tmp/CompanionCoreTests.xctest"],
            xcTestConfigurationFilePath: nil
        )) { error in
            XCTAssertEqual(error as? SafetyRefusal, SafetyRefusal(variable: ".xctest"))
        }

        XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed(
            environment: [:],
            processName: "CCRelay",
            loadedBundlePaths: ["/tmp/CompanionCoreTests.xctest/Contents/MacOS/runner"],
            xcTestConfigurationFilePath: nil
        )) { error in
            XCTAssertEqual(error as? SafetyRefusal, SafetyRefusal(variable: ".xctest"))
        }

        let configurationPath = "/tmp/xctest-configuration.plist"
        XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed(
            environment: [:],
            processName: "CCRelay",
            loadedBundlePaths: [],
            xcTestConfigurationFilePath: configurationPath
        )) { error in
            XCTAssertEqual(
                error as? SafetyRefusal,
                SafetyRefusal(variable: SafetyTripwire.xcTestConfigurationVariable)
            )
            XCTAssertFalse(String(describing: error).contains(configurationPath))
        }
    }

    func testAmbientRunnerBlocksEvenWithoutTheTestFlag() throws {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: SafetyTripwire.testVariable)
        environment.removeValue(forKey: SafetyTripwire.sandboxVariable)
        XCTAssertThrowsError(try SafetyTripwire.assertLiveActionsAllowed(environment: environment)) { error in
            let refusal = error as? SafetyRefusal
            XCTAssertNotNil(refusal)
            XCTAssertNotEqual(refusal?.variable, SafetyTripwire.testVariable)
            XCTAssertNotEqual(refusal?.variable, SafetyTripwire.sandboxVariable)
        }
    }

    /// A non-test process with no loaded test bundle. The real runner would fail this.
    private func allow(environment: [String: String]) throws {
        try SafetyTripwire.assertLiveActionsAllowed(
            environment: environment,
            processName: "CCRelay",
            loadedBundlePaths: [],
            xcTestConfigurationFilePath: nil
        )
    }
}
