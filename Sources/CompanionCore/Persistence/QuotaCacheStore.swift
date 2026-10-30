import Foundation

/// A wait claude.ai asked for, and the login it was about.
public struct QuotaWait: Codable, Equatable, Sendable {
    public var account: String
    public var organization: String?
    public var until: Date
    /// Such answers in a row, for a wait that grows when they name none.
    public var limits: Int

    public init(account: String, organization: String?, until: Date, limits: Int) {
        self.account = account
        self.organization = organization
        self.until = until
        self.limits = limits
    }
}

/// Last successful quota reading per profile folder, in `quota-cache.json`, and
/// the waits claude.ai asked for that still stand, in `quota-waits.json`.
///
/// The cache is a JSON object keyed by folder name. A missing file is an empty
/// cache. An undecodable file is copied to `quota-cache.corrupt-<stamp>.json`
/// and treated as empty, same as `StateStore`. One entry that cannot be decoded
/// is skipped and logged; the other entries are kept.
public actor QuotaCacheStore {
    private let fileURL: URL
    private let waitsURL: URL
    private let appDataDirectory: URL
    private let log: CompanionLog
    private let clock: any Clock

    public init(paths: AppPaths, log: CompanionLog, clock: any Clock = SystemClock()) {
        appDataDirectory = paths.companionDataDirectory
        fileURL = paths.companionDataDirectory.appending(path: "quota-cache.json")
        waitsURL = paths.companionDataDirectory.appending(path: "quota-waits.json")
        self.log = log
        self.clock = clock
    }

    /// By folder name. A file that cannot be read holds no wait.
    public func waits() -> [String: QuotaWait] {
        guard let data = try? AtomicFile.read(waitsURL) else { return [:] }
        return (try? StableJSON.decoder().decode([String: QuotaWait].self, from: data)) ?? [:]
    }

    public func saveWaits(_ waits: [String: QuotaWait]) throws {
        try AtomicFile.write(StableJSON.encode(waits), to: waitsURL, protectedRoot: appDataDirectory)
    }

    public func load() throws -> [ProfileFolder: QuotaSnapshot] {
        let data: Data
        do {
            data = try AtomicFile.read(fileURL)
        } catch let error as AtomicFileError {
            if case .notFound = error {
                return [:]
            }
            throw error
        }
        let skips = DecodeSkips()
        do {
            let cache = try Self.decode(data, skips: skips)
            for path in skips.paths {
                log.warning(.quota, "Skipped undecodable quota cache entry \(path).")
            }
            return cache
        } catch {
            let preserved = try preserve(data)
            log.warning(.quota, "Preserved an undecodable quota-cache.json as \(preserved.lastPathComponent).")
            return [:]
        }
    }

    public func save(_ cache: [ProfileFolder: QuotaSnapshot]) throws {
        try AtomicFile.write(Self.encode(cache), to: fileURL, protectedRoot: appDataDirectory)
    }

    public func update(_ body: (inout [ProfileFolder: QuotaSnapshot]) throws -> Void) throws {
        var cache = try load()
        try body(&cache)
        try save(cache)
    }

    private func preserve(_ data: Data) throws -> URL {
        let destination = CorruptFileName.url(
            prefix: "quota-cache",
            directory: appDataDirectory,
            date: clock.now()
        )
        try AtomicFile.write(data, to: destination, protectedRoot: appDataDirectory)
        try? FileManager.default.removeItem(at: fileURL)
        return destination
    }

    private static func encode(_ cache: [ProfileFolder: QuotaSnapshot]) throws -> Data {
        let document = QuotaCacheDocument(entries: Dictionary(uniqueKeysWithValues: cache.map { ($0.key.name, $0.value) }))
        return try StableJSON.encode(document)
    }

    private static func decode(_ data: Data, skips: DecodeSkips) throws -> [ProfileFolder: QuotaSnapshot] {
        let decoder = StableJSON.decoder()
        decoder.userInfo[DecodeSkips.userInfoKey] = skips
        let document = try decoder.decode(QuotaCacheDocument.self, from: data)
        var cache: [ProfileFolder: QuotaSnapshot] = [:]
        for (name, snapshot) in document.entries {
            guard let folder = try? ProfileFolder(name) else { continue }
            cache[folder] = snapshot
        }
        return cache
    }
}

private struct QuotaCacheDocument: Codable {
    var entries: [String: QuotaSnapshot]

    init(entries: [String: QuotaSnapshot]) {
        self.entries = entries
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        let skips = decoder.userInfo[DecodeSkips.userInfoKey] as? DecodeSkips
        var entries: [String: QuotaSnapshot] = [:]
        for key in container.allKeys {
            do {
                let snapshot = try container.decode(QuotaSnapshot.self, forKey: key)
                _ = try ProfileFolder(key.stringValue)
                entries[key.stringValue] = snapshot
            } catch {
                skips?.record(key.stringValue)
            }
        }
        self.entries = entries
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        for name in entries.keys.sorted() {
            guard let key = DynamicKey(stringValue: name), let snapshot = entries[name] else { continue }
            try container.encode(snapshot, forKey: key)
        }
    }
}

private struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}
