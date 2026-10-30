import XCTest
import Foundation
@testable import CompanionCore

struct ScratchDirectory {
    let root: URL
    let paths: AppPaths

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "cc-relay-core-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        paths = AppPaths.sandbox(root: root)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

func posixMode(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let number = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
    return number.intValue & 0o777
}
