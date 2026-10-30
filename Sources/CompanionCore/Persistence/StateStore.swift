import Foundation

/// Loads and saves `state.json` in the app data directory.
///
/// A missing file is a default `CompanionState`. A file that does not decode at
/// all, including a `schemaVersion` other than 1, is copied to
/// `state.corrupt-<stamp>.json` and treated as missing. That path does not throw.
/// The copy is written before the original is removed, so the bad bytes are kept.
/// If the copy itself cannot be written, this throws and leaves the original in
/// place rather than risk replacing it.
///
/// A file that decodes but skips individual records is kept as the current
/// `state.json`. The original bytes are copied once to `state.partial-<stamp>.json`
/// (same stamp and collision rules as the corrupt copy) and `load` returns the
/// records that decoded. The next `update` writes that cleaned state.
public actor StateStore {
    private let fileURL: URL
    private let appDataDirectory: URL
    private let log: CompanionLog
    private let clock: any Clock

    public init(paths: AppPaths, log: CompanionLog, clock: any Clock = SystemClock()) {
        appDataDirectory = paths.companionDataDirectory
        fileURL = paths.companionDataDirectory.appending(path: "state.json")
        self.log = log
        self.clock = clock
    }

    public func load() throws -> CompanionState {
        let data: Data
        do {
            data = try AtomicFile.read(fileURL)
        } catch let error as AtomicFileError {
            if case .notFound = error {
                return CompanionState()
            }
            throw error
        }
        let skips = DecodeSkips()
        do {
            let decoder = StableJSON.decoder()
            decoder.userInfo[DecodeSkips.userInfoKey] = skips
            let state = try decoder.decode(CompanionState.self, from: data)
            if !skips.isEmpty {
                try preservePartialOnce(data, skips: skips)
            }
            return state
        } catch {
            let preserved = try preserve(data, label: "corrupt")
            log.warning(.app, "Preserved an undecodable state.json as \(preserved.lastPathComponent).")
            return CompanionState()
        }
    }

    public func update(_ body: (inout CompanionState) throws -> Void) throws {
        var state = try load()
        try body(&state)
        let data = try StableJSON.encode(state)
        try AtomicFile.write(data, to: fileURL, protectedRoot: appDataDirectory)
    }

    /// One partial copy per distinct byte sequence. A later load of the same
    /// file must not mint `state.partial-…-2.json` before `update` rewrites it.
    private func preservePartialOnce(_ data: Data, skips: DecodeSkips) throws {
        for path in skips.paths {
            log.warning(.app, "Skipped undecodable state record at \(path).")
        }
        if hasPreservedCopy(of: data, label: "partial") {
            return
        }
        let destination = try preserve(data, label: "partial", removeOriginal: false)
        log.warning(.app, "Preserved a state.json with skipped records as \(destination.lastPathComponent).")
    }

    private func hasPreservedCopy(of data: Data, label: String) -> Bool {
        let prefix = "state.\(label)-"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: appDataDirectory.path) else {
            return false
        }
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let url = appDataDirectory.appending(path: name)
            if let existing = try? AtomicFile.read(url), existing == data {
                return true
            }
        }
        return false
    }

    private func preserve(_ data: Data, label: String, removeOriginal: Bool = true) throws -> URL {
        let destination = CorruptFileName.url(
            prefix: "state",
            directory: appDataDirectory,
            date: clock.now(),
            label: label
        )
        try AtomicFile.write(data, to: destination, protectedRoot: appDataDirectory)
        if removeOriginal {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                // The copy already holds the bytes. Leaving the original means the
                // next load preserves another copy rather than deleting them.
            }
        }
        return destination
    }
}
