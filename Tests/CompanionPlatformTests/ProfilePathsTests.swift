import CompanionCore
import Foundation
import XCTest
@testable import CompanionPlatform

final class ProfilePathsTests: XCTestCase {
    func testSameIgnoresTrailingSlashAndDistinguishesDirectories() throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let path = directory.root.appendingPathComponent("a/b").path
        let withoutSlash = URL(fileURLWithPath: path, isDirectory: false)
        let withSlash = URL(fileURLWithPath: path, isDirectory: true)
        XCTAssertNotEqual(withoutSlash, withSlash)
        XCTAssertTrue(ProfilePaths.same(withoutSlash, withSlash))
        XCTAssertEqual(ProfilePaths.canonical(withoutSlash), ProfilePaths.canonical(withSlash))
        XCTAssertTrue(ProfilePaths.canonical(withoutSlash).absoluteString.hasSuffix("/"))
        XCTAssertFalse(ProfilePaths.same(withoutSlash, directory.root.appendingPathComponent("a/c")))
    }

    func testCanonicalStandardizesAndResolvesExistingSymlinks() throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let target = directory.root.appendingPathComponent("profile", isDirectory: true)
        let alias = directory.root.appendingPathComponent("profile-alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let unstandardized = target.appendingPathComponent("../profile", isDirectory: false)
        XCTAssertTrue(ProfilePaths.same(unstandardized, target))
        XCTAssertTrue(ProfilePaths.same(alias, target))
        XCTAssertEqual(ProfilePaths.canonical(alias), ProfilePaths.canonical(target))
    }

    func testInstanceAndLaunchEventPathsAreCanonicalForExplicitAndDefaultProfiles() throws {
        let directory = try PlatformTestDirectory()
        defer { directory.remove() }
        let target = directory.root.appendingPathComponent("profile", isDirectory: true)
        let alias = directory.root.appendingPathComponent("profile-alias", isDirectory: false)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let main = directory.root.appendingPathComponent("Claude")
        for argv in [[main.path], [main.path, "--user-data-dir=\(alias.path)"]] {
            let record = ProcessRecord(pid: 42, ppid: 1, executableURL: main, argv: argv, startedAt: .distantPast)
            let instance = try XCTUnwrap(InstanceMapping.instance(record, mainExecutable: main, defaultProfile: alias))
            XCTAssertEqual(instance.profileDirectory, ProfilePaths.canonical(target))
            XCTAssertEqual(InstanceMapping.event(instance).profileDirectory, ProfilePaths.canonical(target))
        }
        let instance = ClaudeInstance(pid: 42, profileDirectory: alias, hasExplicitProfileFlag: false,
                                      startedAt: .distantPast, executableURL: main)
        XCTAssertEqual(InstanceMapping.event(instance).profileDirectory, ProfilePaths.canonical(target))
    }
}
