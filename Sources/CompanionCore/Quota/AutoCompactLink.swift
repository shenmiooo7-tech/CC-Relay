import Foundation

/// What CC-Relay shares with the Claude Code plugin in `AutoCompact/`: the switch the plugin
/// obeys (`settings.json`), the status each Desktop Code conversation reports
/// (`sessions/<id>.json`), one file per compaction (`results/`), and before a switch a request to
/// compact one conversation now (`switch-request.json`) with its answer (`switch-result.json`).
/// The plugin decides and compacts by itself (docs/low-quota-compaction.md); this side configures
/// it, asks before a switch and shows what it did.
/// The plugin writes numbers, plus the host's short reason when a compaction fails; never
/// conversation text.
public struct AutoCompactLink: Sendable {
    /// A conversation that reported within this long is watched right now.
    public static let liveInterval: TimeInterval = 120
    public static let minContextTokens = 100_000
    /// A conversation at least this long is compacted on the account it is leaving, before a switch.
    public static let switchContextTokens = 300_000
    private static let largestFile = 64 * 1024

    private let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    var directory: URL { paths.companionDataDirectory.appending(path: "AutoCompact", directoryHint: .isDirectory) }

    /// The plugin reads this before every check; without it, it is on and speaks English.
    public func writeSettings(enabled: Bool, language: AppLanguage, preferredLanguages: [String]) throws {
        let object: [String: Any] = [
            "enabled": enabled,
            "minContextTokens": Self.minContextTokens,
            "language": Self.pluginLanguage(language, preferredLanguages: preferredLanguages),
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try AtomicFile.write(data, to: directory.appending(path: "settings.json"), protectedRoot: paths.companionDataDirectory)
    }

    /// The plugin has its own Chinese and English texts, for the summary instructions and the
    /// message that resumes a paused task.
    static func pluginLanguage(_ language: AppLanguage, preferredLanguages: [String]) -> String {
        switch language {
        case .zhHans: return "zh-Hans"
        case .en: return "en"
        case .system: return preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
        }
    }

    /// The newest report among the conversations and how many reported within `liveInterval`.
    public func status(now: Date) -> AutoCompactStatus {
        let reports = files(in: directory.appending(path: "sessions", directoryHint: .isDirectory)).compactMap { url in
            object(at: url).flatMap { Self.date($0["updatedAt"]) }
        }
        return AutoCompactStatus(lastReport: reports.max(),
                                 liveConversations: reports.filter { now.timeIntervalSince($0) < Self.liveInterval }.count)
    }

    public enum SwitchReadiness: Equatable, Sendable {
        /// No report within `liveInterval`: no plugin, hooks switched off, or the conversation is not open.
        case notReporting
        /// It reports, but its plugin predates requests before a switch and would never answer one.
        case outdated
        case ready
    }

    /// Whether the conversation's plugin can take a request before a switch now.
    public func switchReadiness(sessionID: String, now: Date) -> SwitchReadiness {
        guard Self.validSessionID(sessionID),
              let fields = object(at: directory.appending(path: "sessions/\(sessionID).json")),
              let report = Self.date(fields["updatedAt"]), now.timeIntervalSince(report) < Self.liveInterval
        else { return .notReporting }
        return fields["switchRequests"] as? Bool == true ? .ready : .outdated
    }

    /// Asks the plugin in that conversation to compact it now, before a switch, until `until`.
    public func requestCompaction(id: Int, sessionID: String, until: Date) throws {
        guard Self.validSessionID(sessionID) else { throw CocoaError(.fileWriteInvalidFileName) }
        let object: [String: Any] = ["id": id, "sessionID": sessionID, "until": Int(until.timeIntervalSince1970 * 1000)]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try AtomicFile.write(data, to: directory.appending(path: "switch-request.json"), protectedRoot: paths.companionDataDirectory)
    }

    /// The plugin's answer to request `id`, once it has written one.
    public func compactionAnswer(id: Int) -> SwitchCompactionAnswer? {
        guard let fields = object(at: directory.appending(path: "switch-result.json")),
              (fields["id"] as? NSNumber)?.intValue == id else { return nil }
        return SwitchCompactionAnswer(fields)
    }

    /// True once the plugin has said that the compaction for request `id` has begun, and until it answers.
    public func compactionBegun(id: Int) -> Bool {
        guard let fields = object(at: directory.appending(path: "switch-result.json")),
              (fields["id"] as? NSNumber)?.intValue == id else { return false }
        return fields["status"] as? String == "compacting"
    }

    /// Takes the request back once the switch goes on, so nothing starts compacting after that.
    public func withdrawRequest() {
        try? FileManager.default.removeItem(at: directory.appending(path: "switch-request.json"))
    }

    /// The plugin's own rule for a session id, which also keeps it to one file name.
    static func validSessionID(_ id: String) -> Bool {
        (1...64).contains(id.utf8.count) && id.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }
    }

    /// Results written since the last call, oldest first. Each file read is moved to
    /// `results/seen/`, so a result is reported once. Unreadable files are moved too.
    public func takeResults() -> [AutoCompactResult] {
        let folder = directory.appending(path: "results", directoryHint: .isDirectory)
        let seen = folder.appending(path: "seen", directoryHint: .isDirectory)
        var results: [AutoCompactResult] = []
        for url in files(in: folder).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if let fields = object(at: url), let result = AutoCompactResult(fields) { results.append(result) }
            do {
                try FileManager.default.createDirectory(at: seen, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: url, to: seen.appending(path: url.lastPathComponent))
            } catch {
                // The name is taken in seen/: a unique one instead. A file that cannot move at all
                // is reported again next time, which is the lesser harm than losing it.
                try? FileManager.default.moveItem(at: url, to: seen.appending(path: UUID().uuidString + "-" + url.lastPathComponent))
            }
        }
        return results.sorted { $0.finishedAt < $1.finishedAt }
    }

    private func files(in folder: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        return names.filter { $0.pathExtension == "json" && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    private func object(at url: URL) -> [String: Any]? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.largestFile,
              let data = try? AtomicFile.read(url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// The plugin writes times as milliseconds since 1970.
    static func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        return Date(timeIntervalSince1970: number.doubleValue / 1000)
    }
}

public struct AutoCompactStatus: Equatable, Sendable, Codable {
    public var lastReport: Date?
    public var liveConversations: Int

    public init(lastReport: Date? = nil, liveConversations: Int = 0) {
        self.lastReport = lastReport
        self.liveConversations = liveConversations
    }
}

/// One compaction the plugin did, or tried.
public struct AutoCompactResult: Equatable, Sendable, Codable {
    public enum Trigger: String, Equatable, Sendable, Codable {
        /// After a reply, past the early line.
        case early
        /// A long task was paused between two steps past the hard line, then resumed.
        case hard
        /// CC-Relay asked for it right before moving the conversation to another account.
        case beforeSwitch = "switch"
    }

    public enum Outcome: String, Equatable, Sendable, Codable {
        case compacted
        /// Another hook declined the compaction.
        case skipped
        case failed
    }

    public var trigger: Trigger
    public var outcome: Outcome
    public var tokensBefore: Int
    public var tokensAfter: Int?
    public var finishedAt: Date
    public var resumed: Bool
    /// Why it was skipped or failed, or why a paused task did not go on, as the host put it: one
    /// short English line.
    public var error: String?

    /// A task paused at the hard line that could not be told to go on: the person has to.
    public var leftTaskPaused: Bool { trigger == .hard && !resumed }

    public init(trigger: Trigger, outcome: Outcome, tokensBefore: Int, tokensAfter: Int?, finishedAt: Date, resumed: Bool,
                error: String? = nil) {
        self.trigger = trigger
        self.outcome = outcome
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.finishedAt = finishedAt
        self.resumed = resumed
        self.error = error
    }

    init?(_ fields: [String: Any]) {
        guard let trigger = (fields["reason"] as? String).flatMap(Trigger.init(rawValue:)),
              let outcome = (fields["status"] as? String).flatMap(Outcome.init(rawValue:)),
              let before = (fields["tokensBefore"] as? NSNumber)?.intValue, before >= 0,
              let finishedAt = AutoCompactLink.date(fields["finishedAt"]) else { return nil }
        self.init(trigger: trigger, outcome: outcome, tokensBefore: before,
                  tokensAfter: (fields["tokensAfter"] as? NSNumber).map(\.intValue).flatMap { $0 >= 0 ? $0 : nil },
                  finishedAt: finishedAt, resumed: fields["resumed"] as? Bool ?? false,
                  error: (fields["error"] as? String).flatMap(Self.oneLine))
    }

    /// The plugin shortens the reason already; a file is not trusted to.
    static func oneLine(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.isEmpty ? nil : String(line.prefix(200)).trimmingCharacters(in: .whitespaces)
    }
}

/// What the plugin answered a request to compact before a switch.
public struct SwitchCompactionAnswer: Equatable, Sendable {
    /// `skipped` here also covers a conversation that could not be compacted right now.
    public var outcome: AutoCompactResult.Outcome
    public var tokensBefore: Int?
    public var tokensAfter: Int?
    /// Why it was not compacted, as the plugin or the host put it: one short English line.
    public var error: String?

    public init(outcome: AutoCompactResult.Outcome, tokensBefore: Int? = nil, tokensAfter: Int? = nil, error: String? = nil) {
        self.outcome = outcome
        self.tokensBefore = tokensBefore
        self.tokensAfter = tokensAfter
        self.error = error
    }

    init?(_ fields: [String: Any]) {
        guard let outcome = (fields["status"] as? String).flatMap(AutoCompactResult.Outcome.init(rawValue:)) else { return nil }
        self.init(outcome: outcome,
                  tokensBefore: (fields["tokensBefore"] as? NSNumber).map(\.intValue).flatMap { $0 >= 0 ? $0 : nil },
                  tokensAfter: (fields["tokensAfter"] as? NSNumber).map(\.intValue).flatMap { $0 >= 0 ? $0 : nil },
                  error: (fields["error"] as? String).flatMap(AutoCompactResult.oneLine))
    }
}
