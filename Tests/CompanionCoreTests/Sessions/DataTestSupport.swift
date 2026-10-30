import Darwin
import Foundation
import XCTest
@testable import CompanionCore

struct SessionTestWorld {
    let scratch: ScratchDirectory
    let paths: AppPaths
    var source: ProfileSnapshot
    var target: ProfileSnapshot

    init() throws {
        scratch = try ScratchDirectory()
        let fixture = SandboxFixture(profiles: [
            ProfileSpec(folder: "Claude", displayName: "A", accountUUID: "account-a",
                organizations: [.init(uuid: "org-a", allowlistUpdatedAt: "2026-10-24T10:00:00Z")],
                buckets: [.init(accountUUID: "account-a", organizationUUID: "org-a", sessions: [])]),
            ProfileSpec(folder: "Claude_B", displayName: "B", accountUUID: "account-b",
                organizations: [.init(uuid: "org-b", allowlistUpdatedAt: "2026-10-24T10:00:00.100Z")],
                buckets: [.init(accountUUID: "account-b", organizationUUID: "org-b", sessions: [])]),
        ])
        paths = try fixture.materialize(at: scratch.root).paths
        let scan = try ProfileScanner(paths: paths).scan()
        source = scan.profiles[0]
        target = scan.profiles[1]
    }

    var sourceBucket: URL { source.url.appending(path: "claude-code-sessions/account-a/org-a") }
    var targetBucket: URL { target.url.appending(path: "claude-code-sessions/account-b/org-b") }
    var backups: URL { paths.companionDataDirectory.appending(path: "Backups/Claude") }
    func cleanup() { scratch.cleanup() }
}

@discardableResult
func writeSession(_ bucket: URL, _ id: String, fields: [String: Any] = [:],
                  seconds: Int = 100, nanos: Int = 0, mode: Int = 0o600) throws -> URL {
    var object = fields
    object["sessionId"] = "local_" + id
    if object["isArchived"] == nil { object["isArchived"] = false }
    let file = bucket.appending(path: "local_" + id + ".json")
    try AtomicFile.write(SessionJSON.compact(object), to: file, permissions: mode)
    try setFileTime(file, seconds: seconds, nanos: nanos)
    return file
}

func setFileTime(_ url: URL, seconds: Int, nanos: Int = 0) throws {
    var times = [timespec(tv_sec: seconds, tv_nsec: nanos), timespec(tv_sec: seconds, tv_nsec: nanos)]
    guard utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW) == 0 else {
        throw SessionDataError.filesystem(url, code: errno)
    }
}

func modifyJSON(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
    var object = try SessionJSON.object(AtomicFile.read(url), at: url)
    change(&object)
    try AtomicFile.write(SessionJSON.compact(object), to: url)
}

func assertNoStages(_ root: URL, file: StaticString = #filePath, line: UInt = #line) throws {
    let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let url as URL in enumerator {
        XCTAssertFalse(url.lastPathComponent.contains(".cc-tmp-") || url.lastPathComponent.hasSuffix(".partial"),
                       url.path, file: file, line: line)
    }
}
