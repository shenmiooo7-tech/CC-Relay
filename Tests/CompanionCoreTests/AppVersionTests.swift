import XCTest
@testable import CompanionCore

final class AppVersionTests: XCTestCase {
    func testTheVersionShowsTheRevisionTheAppWasBuiltFrom() {
        XCTAssertEqual(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0", "CompanionRevision": "5d42a6f"]),
                       "0.1.0 (5d42a6f)")
        // A build with uncommitted changes says so.
        XCTAssertEqual(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0", "CompanionRevision": "5d42a6f+"]),
                       "0.1.0 (5d42a6f+)")
        // Built outside a git checkout, or by an older script: the version alone.
        XCTAssertEqual(AppVersion.display(info: ["CFBundleShortVersionString": "0.1.0", "CompanionRevision": " "]), "0.1.0")
        XCTAssertEqual(AppVersion.display(info: ["CFBundleShortVersionString": "0.2.0"]), "0.2.0")
        XCTAssertEqual(AppVersion.display(info: nil), "0.1.0")
    }

    func testTheRevisionSurvivesTheLogsMasking() {
        // The startup line is only useful if the log keeps the revision readable.
        XCTAssertEqual(Redaction.scrub("Started version 0.1.0 (5d42a6f+)."), "Started version 0.1.0 (5d42a6f+).")
    }

    func testTheBuildStampMarksEveryChangeTheCommitDoesNotHold() throws {
        let scratch = try ScratchDirectory()
        defer { scratch.cleanup() }
        let repository = scratch.root.appending(path: "repository", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try Data("struct Tracked {}\n".utf8).write(to: repository.appending(path: "Tracked.swift"))
        _ = try shell("git init -q && git add Tracked.swift && git -c user.name=test -c user.email=test@example.com "
            + "-c commit.gpgsign=false commit -q -m start", in: repository)
        func stamp() throws -> String { try shell("cc_relay_revision \"$PWD\"", in: repository) }

        let clean = try stamp()
        XCTAssertFalse(clean.isEmpty)
        XCTAssertFalse(clean.hasSuffix("+"), clean)
        try Data("struct Tracked { var edited = true }\n".utf8).write(to: repository.appending(path: "Tracked.swift"))
        XCTAssertEqual(try stamp(), clean + "+")
        _ = try shell("git checkout -q -- Tracked.swift", in: repository)
        // A new file the commit does not hold is built too.
        try Data("struct New {}\n".utf8).write(to: repository.appending(path: "New.swift"))
        XCTAssertEqual(try stamp(), clean + "+")
    }

    /// Runs `script` in bash with scripts/app-config.sh loaded, away from any git configuration of this Mac.
    private func shell(_ script: String, in directory: URL) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "source \"$CONFIG\" && " + script]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": directory.path, "GIT_CONFIG_NOSYSTEM": "1",
                               "GIT_CONFIG_GLOBAL": "/dev/null",
                               "CONFIG": root.appending(path: "scripts/app-config.sh").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, script)
        return String(decoding: data, as: UTF8.self)
    }
}
