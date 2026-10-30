import Foundation

struct PlatformTestDirectory {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-relay-platform-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func script(_ body: String) throws -> URL {
        let url = root.appendingPathComponent("script with space-\(UUID().uuidString)")
        try Data(("#!/bin/sh\n" + body).utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
