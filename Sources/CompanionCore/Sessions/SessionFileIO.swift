import Darwin
import Foundation

public enum SessionDataError: Error, Equatable, Sendable {
    case filesystem(URL, code: Int32)
    case unexpectedType(URL)
    case invalidRecord(URL)
    case unsupportedIndex(URL)
    case invalidPlan
    case noAvailableName(URL)
    case treeChanged
    case rollbackFailed
}

/// Shared only by the session-data services; hooks permit deterministic failure tests.
struct SessionFileIO: Sendable {
    var beforeInfo: (@Sendable (URL) throws -> Void)?
    var beforeList: (@Sendable (URL) throws -> Void)?
    var beforeCopy: (@Sendable (URL, URL) throws -> Void)?
    var beforeRename: (@Sendable (URL, URL) throws -> Void)?

    func info(_ url: URL) throws -> stat? {
        try beforeInfo?(url)
        var value = stat()
        if lstat(url.path, &value) == 0 { return value }
        if errno == ENOENT { return nil }
        throw SessionDataError.filesystem(url, code: errno)
    }

    func isDirectory(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFDIR }
    func isRegular(_ value: stat) -> Bool { value.st_mode & S_IFMT == S_IFREG }

    func requireDirectory(_ url: URL) throws {
        guard let value = try info(url), isDirectory(value) else {
            throw SessionDataError.unexpectedType(url)
        }
    }

    func list(_ url: URL) throws -> [URL] {
        try beforeList?(url)
        try requireDirectory(url)
        return try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .map { URL(fileURLWithPath: url.path + "/" + $0.lastPathComponent, isDirectory: false) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func makeDirectory(_ url: URL) throws {
        if let value = try info(url) {
            guard isDirectory(value) else { throw SessionDataError.unexpectedType(url) }
            return
        }
        try makeDirectory(url.deletingLastPathComponent())
        if mkdir(url.path, 0o700) != 0 {
            if errno == EEXIST { try requireDirectory(url); return }
            throw SessionDataError.filesystem(url, code: errno)
        }
        if chmod(url.path, 0o700) != 0 {
            throw SessionDataError.filesystem(url, code: errno)
        }
    }

    /// Check each component below a caller-supplied root without following links.
    func checkPath(_ url: URL, under root: URL) throws {
        // standardizedFileURL resolves /private/var only for existing paths. Mixing
        // existing and absent destinations would then break containment and remapping.
        let base = root.path
        let path = url.path
        guard path == base || path.hasPrefix(base + "/") else { throw SessionDataError.invalidPlan }
        guard !path.split(separator: "/").contains(".."), !path.split(separator: "/").contains(".") else {
            throw SessionDataError.invalidPlan
        }
        try requireDirectory(root)
        var current = root
        for part in path.dropFirst(base.count).split(separator: "/") {
            current.append(path: String(part))
            if let value = try info(current), value.st_mode & S_IFMT == S_IFLNK {
                throw SessionDataError.unexpectedType(current)
            }
        }
    }

    func read(_ url: URL) throws -> Data {
        guard let value = try info(url), isRegular(value) else {
            throw SessionDataError.unexpectedType(url)
        }
        // AtomicFile supplies the common full-read/error handling after the type check.
        return try AtomicFile.read(url)
    }

    func rename(_ source: URL, _ target: URL, replacing: Bool = false) throws {
        try beforeRename?(source, target)
        let result = replacing ? Darwin.rename(source.path, target.path) :
            renamex_np(source.path, target.path, UInt32(RENAME_EXCL))
        if result != 0 {
            throw SessionDataError.filesystem(target, code: errno)
        }
    }

    func copy(_ source: URL, to target: URL) throws {
        try beforeCopy?(source, target)
        let input = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw SessionDataError.filesystem(source, code: errno) }
        defer { _ = close(input) }
        var metadata = stat()
        guard fstat(input, &metadata) == 0 else { throw SessionDataError.filesystem(source, code: errno) }
        guard isRegular(metadata) else { throw SessionDataError.unexpectedType(source) }
        try makeDirectory(target.deletingLastPathComponent())
        if let existing = try info(target), !isRegular(existing) {
            throw SessionDataError.unexpectedType(target)
        }
        let stage = target.deletingLastPathComponent()
            .appending(path: target.lastPathComponent + ".cc-tmp-" + UUID().uuidString)
        let output = Darwin.open(stage.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw SessionDataError.filesystem(stage, code: errno) }
        var opened = true
        defer {
            if opened { _ = close(output) }
            _ = unlink(stage.path)
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw SessionDataError.filesystem(source, code: errno)
            }
            try buffer.withUnsafeBytes { raw in
                var offset = 0
                while offset < count {
                    let wrote = Darwin.write(output, raw.baseAddress!.advanced(by: offset), count - offset)
                    if wrote < 0 && errno == EINTR { continue }
                    guard wrote > 0 else { throw SessionDataError.filesystem(stage, code: errno) }
                    offset += wrote
                }
            }
        }
        let mode = metadata.st_mode & 0o777
        var times = [metadata.st_atimespec, metadata.st_mtimespec]
        guard fchmod(output, mode) == 0, futimens(output, &times) == 0, fsync(output) == 0 else {
            throw SessionDataError.filesystem(stage, code: errno)
        }
        opened = false
        guard close(output) == 0 else { throw SessionDataError.filesystem(stage, code: errno) }
        if let existing = try info(target), !isRegular(existing) {
            throw SessionDataError.unexpectedType(target)
        }
        try rename(stage, target, replacing: true)
        let parent = Darwin.open(target.deletingLastPathComponent().path, O_RDONLY)
        if parent >= 0 { _ = fsync(parent); _ = close(parent) }
    }

    func copyTree(_ source: URL, to target: URL) throws {
        try requireDirectory(source)
        try makeDirectory(target)
        for child in try list(source) {
            if Self.isIgnoredMetadata(child.lastPathComponent) { continue }
            guard let value = try info(child) else { throw SessionDataError.treeChanged }
            let destination = target.appending(path: child.lastPathComponent)
            if isDirectory(value) { try copyTree(child, to: destination) }
            else if isRegular(value) { try copy(child, to: destination) }
            else { throw SessionDataError.unexpectedType(child) }
        }
    }

    static func isSession(_ name: String) -> Bool {
        name.hasPrefix("local_") && name.hasSuffix(".json")
    }

    static func isIgnoredMetadata(_ name: String) -> Bool {
        name == ".DS_Store" || name.hasPrefix("._")
    }

    static func newer(_ first: stat, than second: stat) -> Bool {
        let a = first.st_mtimespec, b = second.st_mtimespec
        return a.tv_sec > b.tv_sec || (a.tv_sec == b.tv_sec && a.tv_nsec > b.tv_nsec)
    }
}

enum SessionJSON {
    static func object(_ data: Data, at url: URL) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionDataError.invalidRecord(url)
        }
        return result
    }

    static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(value) else { return nil }
        return value.int64Value
    }

    static func compact(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
}
