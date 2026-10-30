import Foundation

public enum ArchiveIndexResult: Equatable, Sendable { case unchanged, rewritten }

public struct ArchiveIndexRebuilder: Sendable {
    private let io = SessionFileIO()
    public init() {}

    @discardableResult
    public func rebuild(bucket: URL) throws -> ArchiveIndexResult {
        try io.requireDirectory(bucket)
        let index = bucket.appending(path: "archived-sessions.idx")
        let metadata = try io.info(index)
        var originalData: Data?
        var original: [String: Any] = [:]
        var oldIDs = Set<String>()
        if let metadata {
            guard io.isRegular(metadata) else { throw SessionDataError.unsupportedIndex(index) }
            do {
                let data = try io.read(index)
                originalData = data
                original = try SessionJSON.object(data, at: index)
                guard SessionJSON.integer(original["v"]) == 1,
                      let ids = original["archived"] as? [String] else {
                    throw SessionDataError.unsupportedIndex(index)
                }
                oldIDs = Set(ids)
            } catch { throw SessionDataError.unsupportedIndex(index) }
        }
        var ids = Set<String>()
        var hasArchiveField = false
        for file in try io.list(bucket) where SessionFileIO.isSession(file.lastPathComponent) {
            let record = try SessionJSON.object(io.read(file), at: file)
            let id = file.deletingPathExtension().lastPathComponent
            guard record["sessionId"] as? String == id else { throw SessionDataError.invalidRecord(file) }
            if let value = record["isArchived"], !(value is NSNull) {
                guard let archived = SessionJSON.boolean(value) else { throw SessionDataError.invalidRecord(file) }
                hasArchiveField = true
                if archived { ids.insert(id) }
            } else if oldIDs.contains(id) { ids.insert(id) }
        }
        // Legacy records alone do not opt a bucket into a new index format.
        if metadata == nil && !hasArchiveField { return .unchanged }
        var fields = ["\"v\":1", "\"archived\":" + String(decoding: try SessionJSON.compact(ids.sorted()), as: UTF8.self)]
        for key in original.keys.sorted() where key != "v" && key != "archived" {
            fields.append(String(decoding: try SessionJSON.compact(key), as: UTF8.self) + ":" +
                String(decoding: try SessionJSON.compact(original[key]!), as: UTF8.self))
        }
        let data = Data(("{" + fields.joined(separator: ",") + "}").utf8)
        if data == originalData { return .unchanged }
        try AtomicFile.write(data, to: index, permissions: metadata.map { Int($0.st_mode & 0o777) } ?? 0o600)
        return .rewritten
    }
}
