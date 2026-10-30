import Darwin
import Foundation

public enum SandboxFixtureError: Error, Equatable, Sendable {
    case rootNotAllowed(String)
    case outsideRoot(String)
    case invalidProfileFolder(String)
    case secretKeyRefused
    case unencodable
}

public struct OrganizationSpec: Equatable, Sendable {
    public var uuid: String
    /// RFC 3339 stamp written to `dxt:allowlistLastUpdated:<uuid>`.
    public var allowlistUpdatedAt: String

    public init(uuid: String, allowlistUpdatedAt: String) {
        self.uuid = uuid
        self.allowlistUpdatedAt = allowlistUpdatedAt
    }
}

public struct SessionSpec: Equatable, Sendable {
    public var sessionUUID: String
    public var cliSessionID: String
    public var title: String
    /// Directory under the sandbox root. Created, then stored as the session `cwd`.
    public var projectDirectory: String
    public var isArchived: Bool
    public var lastFocusedAt: Int
    public var createdAt: Int
    public var lastActivityAt: Int
    public var modifiedAt: Date?
    /// Registry `status`. `busy` or `idle`.
    public var cliStatus: String
    public var marker: String

    public init(
        sessionUUID: String,
        cliSessionID: String,
        title: String,
        projectDirectory: String,
        isArchived: Bool = false,
        lastFocusedAt: Int,
        createdAt: Int,
        lastActivityAt: Int,
        modifiedAt: Date? = nil,
        cliStatus: String = "idle",
        marker: String = "preserve-me"
    ) {
        self.sessionUUID = sessionUUID
        self.cliSessionID = cliSessionID
        self.title = title
        self.projectDirectory = projectDirectory
        self.isArchived = isArchived
        self.lastFocusedAt = lastFocusedAt
        self.createdAt = createdAt
        self.lastActivityAt = lastActivityAt
        self.modifiedAt = modifiedAt
        self.cliStatus = cliStatus
        self.marker = marker
    }

    public var desktopSessionID: String { "local_\(sessionUUID)" }
}

public struct BucketSpec: Equatable, Sendable {
    public var accountUUID: String
    public var organizationUUID: String
    public var sessions: [SessionSpec]

    public init(accountUUID: String, organizationUUID: String, sessions: [SessionSpec]) {
        self.accountUUID = accountUUID
        self.organizationUUID = organizationUUID
        self.sessions = sessions
    }
}

public struct UsageSampleSpec: Equatable, Sendable {
    public var timeMillis: Int
    public var organizationUUID: String
    public var fiveHourPercent: Int
    public var sevenDayPercent: Int

    public init(timeMillis: Int, organizationUUID: String, fiveHourPercent: Int, sevenDayPercent: Int) {
        self.timeMillis = timeMillis
        self.organizationUUID = organizationUUID
        self.fiveHourPercent = fiveHourPercent
        self.sevenDayPercent = sevenDayPercent
    }
}

public struct ProfileSpec: Equatable, Sendable {
    public var folder: String
    public var displayName: String
    public var accountUUID: String?
    public var locale: String
    public var organizations: [OrganizationSpec]
    public var buckets: [BucketSpec]
    public var usageSamples: [UsageSampleSpec]
    /// The address the sandbox's account reads report for this profile.
    public var email: String?

    public init(
        folder: String,
        displayName: String,
        accountUUID: String? = nil,
        locale: String = "zh-CN",
        organizations: [OrganizationSpec] = [],
        buckets: [BucketSpec] = [],
        usageSamples: [UsageSampleSpec] = [],
        email: String? = nil
    ) {
        self.folder = folder
        self.displayName = displayName
        self.accountUUID = accountUUID
        self.locale = locale
        self.organizations = organizations
        self.buckets = buckets
        self.usageSamples = usageSamples
        self.email = email
    }

    public static func awaitingSignIn(folder: String, displayName: String) -> ProfileSpec {
        ProfileSpec(folder: folder, displayName: displayName)
    }
}

public struct CLISessionRecord: Equatable, Sendable {
    public var pid: Int
    public var cliSessionID: String
    public var hostSessionID: String
    public var cwd: URL
    public var status: String
    public var procStart: String
    public var registryFile: URL
    public var transcriptFile: URL
}

public struct SandboxWorld: Equatable, Sendable {
    public var root: URL
    public var paths: AppPaths
    public var cliSessions: [CLISessionRecord]

    public func profileDirectory(_ folder: String) -> URL {
        paths.claudeProfilesRoot.appending(path: folder, directoryHint: .isDirectory)
    }
}

/// Writes a fake Claude world under a disposable root.
///
/// The root must sit under `$TMPDIR` or under a directory named `sandbox`.
/// Every path is checked again before it is written, so a symlink cannot
/// redirect the tree onto a real profile.
public struct SandboxFixture: Equatable, Sendable {
    public enum ID {
        public static let defaultAccount = "11111111-1111-4111-8111-111111111111"
        public static let defaultOrganization = "22222222-2222-4222-8222-222222222221"
        public static let defaultOtherOrganization = "22222222-2222-4222-8222-222222222222"
        public static let liveSession = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa1"
        public static let archivedSession = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
        public static let otherSession = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"
        public static let account204 = "44444444-4444-4444-8444-444444444444"
        public static let organization204 = "44444444-4444-4444-8444-444444444401"
        public static let session204 = "44444444-4444-4444-8444-444444444441"
        public static let account203 = "33333333-3333-4333-8333-333333333333"
        public static let organization203 = "33333333-3333-4333-8333-333333333301"
        public static let session203 = "33333333-3333-4333-8333-333333333311"
        public static let account208 = "88888888-8888-4888-8888-888888888888"
        public static let organization208 = "88888888-8888-4888-8888-888888888801"
        public static let session208 = "88888888-8888-4888-8888-888888888881"
        public static let activeStamp = "2026-10-24T15:48:12.345Z"
        public static let olderStamp = "2026-10-20T00:00:00Z"
        public static let referenceTimestamp: TimeInterval = 1_792_832_402
    }

    public var profiles: [ProfileSpec]
    /// Paths relative to the sandbox root. Applied after the tree is written.
    public var modifiedAt: [String: Date]
    public var referenceDate: Date

    public init(
        profiles: [ProfileSpec],
        modifiedAt: [String: Date] = [:],
        referenceDate: Date = Date(timeIntervalSince1970: ID.referenceTimestamp)
    ) {
        self.profiles = profiles
        self.modifiedAt = modifiedAt
        self.referenceDate = referenceDate
    }

    public static func standard() -> SandboxFixture {
        let millis = Int(ID.referenceTimestamp * 1000)
        let live = SessionSpec(
            sessionUUID: ID.liveSession,
            cliSessionID: ID.liveSession,
            title: "Current chat",
            projectDirectory: "home/Projects/My Project",
            isArchived: false,
            lastFocusedAt: millis,
            createdAt: millis - 50_000,
            lastActivityAt: millis - 1_000,
            modifiedAt: Date(timeIntervalSince1970: ID.referenceTimestamp),
            cliStatus: "idle"
        )
        let archived = SessionSpec(
            sessionUUID: ID.archivedSession,
            cliSessionID: ID.archivedSession,
            title: "Old chat",
            projectDirectory: "home/Projects/201-archive",
            isArchived: true,
            lastFocusedAt: millis - 80_000,
            createdAt: millis - 90_000,
            lastActivityAt: millis - 70_000,
            cliStatus: "idle"
        )
        let other = SessionSpec(
            sessionUUID: ID.otherSession,
            cliSessionID: ID.otherSession,
            title: "Other org",
            projectDirectory: "home/Projects/201-other",
            lastFocusedAt: millis - 20_000,
            createdAt: millis - 30_000,
            lastActivityAt: millis - 15_000
        )
        let profile004 = signedInProfile(
            folder: "Claude_204",
            email: "bob@example.com",
            displayName: "204",
            account: ID.account204,
            organization: ID.organization204,
            session: ID.session204,
            project: "home/Projects/204",
            title: "Four",
            millis: millis
        )
        var profile003 = signedInProfile(
            folder: "Claude_Kxm2",
            email: "cara@example.com",
            displayName: "203",
            account: ID.account203,
            organization: ID.organization203,
            session: ID.session203,
            project: "home/Projects/203",
            title: "Three",
            millis: millis
        )
        profile003.buckets[0].sessions[0].cliStatus = "busy"
        let profile008 = signedInProfile(
            folder: "Claude_Kxm8",
            email: "dax@example.com",
            displayName: "208",
            account: ID.account208,
            organization: ID.organization208,
            session: ID.session208,
            project: "home/Projects/208",
            title: "Eight",
            millis: millis
        )
        let `default` = ProfileSpec(
            folder: "Claude",
            displayName: "201",
            accountUUID: ID.defaultAccount,
            organizations: [
                OrganizationSpec(uuid: ID.defaultOrganization, allowlistUpdatedAt: ID.activeStamp),
                OrganizationSpec(uuid: ID.defaultOtherOrganization, allowlistUpdatedAt: ID.olderStamp),
            ],
            buckets: [
                BucketSpec(accountUUID: ID.defaultAccount, organizationUUID: ID.defaultOrganization, sessions: [live, archived]),
                BucketSpec(accountUUID: ID.defaultAccount, organizationUUID: ID.defaultOtherOrganization, sessions: [other]),
            ],
            usageSamples: [
                UsageSampleSpec(
                    timeMillis: millis,
                    organizationUUID: ID.defaultOrganization,
                    fiveHourPercent: 12,
                    sevenDayPercent: 34
                ),
            ],
            email: "ada@example.com"
        )
        return SandboxFixture(
            profiles: [`default`, profile004, profile003, profile008]
        )
    }

    /// `ps -o lstart` in UTC with a C locale. The day is space-padded.
    public static func procStartString(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let day = calendar.component(.day, from: date)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM "
        let month = formatter.string(from: date)
        formatter.dateFormat = "HH:mm:ss yyyy"
        let clock = formatter.string(from: date)
        let dayText = day < 10 ? String(format: " %d", day) : String(day)
        return month + dayText + " " + clock
    }

    public func materialize(
        at root: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> SandboxWorld {
        let lexical = root.standardizedFileURL
        guard Self.rootIsAllowed(lexical, environment: environment) else {
            throw SandboxFixtureError.rootNotAllowed(lexical.path)
        }
        if Self.isSymbolicLink(lexical) {
            let resolved = Self.resolve(lexical)
            guard Self.rootIsAllowed(resolved, environment: environment) else {
                throw SandboxFixtureError.rootNotAllowed(resolved.path)
            }
        }
        try FileManager.default.createDirectory(at: lexical, withIntermediateDirectories: true)
        let resolved = Self.resolve(lexical)
        guard Self.rootIsAllowed(resolved, environment: environment) else {
            throw SandboxFixtureError.rootNotAllowed(resolved.path)
        }
        let writer = FixtureWriter(root: resolved, fixture: self)
        let sessions = try writer.write()
        return SandboxWorld(root: resolved, paths: AppPaths.sandbox(root: resolved), cliSessions: sessions)
    }

    static func rootIsAllowed(_ url: URL, environment: [String: String]) -> Bool {
        let resolved = resolve(url)
        guard resolved.path.hasPrefix("/") else { return false }
        if resolved.pathComponents.contains("sandbox") {
            return true
        }
        return isUnderTemporaryDirectory(resolved, environment: environment)
    }

    private static func signedInProfile(
        folder: String,
        email: String,
        displayName: String,
        account: String,
        organization: String,
        session: String,
        project: String,
        title: String,
        millis: Int
    ) -> ProfileSpec {
        ProfileSpec(
            folder: folder,
            displayName: displayName,
            accountUUID: account,
            organizations: [OrganizationSpec(uuid: organization, allowlistUpdatedAt: ID.activeStamp)],
            buckets: [
                BucketSpec(
                    accountUUID: account,
                    organizationUUID: organization,
                    sessions: [
                        SessionSpec(
                            sessionUUID: session,
                            cliSessionID: session,
                            title: title,
                            projectDirectory: project,
                            lastFocusedAt: millis,
                            createdAt: millis - 10_000,
                            lastActivityAt: millis - 500
                        ),
                    ]
                ),
            ],
            usageSamples: [
                UsageSampleSpec(
                    timeMillis: millis,
                    organizationUUID: organization,
                    fiveHourPercent: 8,
                    sevenDayPercent: 16
                ),
            ],
            email: email
        )
    }

    private static func resolve(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return info.st_mode & S_IFMT == S_IFLNK
    }

    private static func isUnderTemporaryDirectory(_ url: URL, environment: [String: String]) -> Bool {
        var candidates: [URL] = []
        if let raw = environment["TMPDIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            candidates.append(URL(fileURLWithPath: raw, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        candidates.append(FileManager.default.temporaryDirectory)
        let path = url.path
        return candidates.contains { candidate in
            let parent = resolve(candidate).path
            if path == parent { return true }
            let prefix = parent.hasSuffix("/") ? parent : parent + "/"
            return path.hasPrefix(prefix)
        }
    }
}

private struct FixtureWriter {
    let root: URL
    let fixture: SandboxFixture
    private let fileManager = FileManager.default

    func write() throws -> [CLISessionRecord] {
        try validate()
        let paths = AppPaths.sandbox(root: root)
        var records: [CLISessionRecord] = []
        var stamps: [String: Date] = [:]
        var nextPID = 45001
        let procStart = SandboxFixture.procStartString(from: fixture.referenceDate)
        let startedAt = Int((fixture.referenceDate.timeIntervalSince1970 * 1000).rounded())

        for profile in fixture.profiles {
            let directory = try child(relative: relativeUnderHome("Library/Application Support/\(profile.folder)"))
            try writeJSON(config(for: profile), to: directory.appending(path: "config.json"))
            if !profile.usageSamples.isEmpty {
                try writeJSON(planUsage(profile.usageSamples), to: directory.appending(path: "plan-usage-history.json"))
            }
            for bucket in profile.buckets {
                let bucketURL = directory
                    .appending(path: "claude-code-sessions", directoryHint: .isDirectory)
                    .appending(path: bucket.accountUUID, directoryHint: .isDirectory)
                    .appending(path: bucket.organizationUUID, directoryHint: .isDirectory)
                try requireInside(bucketURL)
                var archived: [String] = []
                for session in bucket.sessions {
                    let project = try child(relative: session.projectDirectory)
                    try makeDirectory(project)
                    let file = bucketURL.appending(path: "\(session.desktopSessionID).json")
                    try requireInside(file)
                    try writeJSON(sessionObject(session, cwd: project), to: file)
                    if let modified = session.modifiedAt {
                        stamps[relativePath(of: file)] = modified
                    }
                    if session.isArchived {
                        archived.append(session.desktopSessionID)
                    }
                    let record = try writeCLI(
                        session: session,
                        cwd: project,
                        pid: nextPID,
                        procStart: procStart,
                        startedAt: startedAt,
                        paths: paths
                    )
                    records.append(record)
                    nextPID += 1
                }
                try writeExact(archiveIndex(archived), to: bucketURL.appending(path: "archived-sessions.idx"))
                try writeJSON(scheduledTasks(), to: bucketURL.appending(path: "scheduled-tasks.json"))
                try makeDirectory(bucketURL.appending(path: "waiting-input", directoryHint: .isDirectory))
            }
        }

        for (relative, date) in fixture.modifiedAt {
            stamps[relative] = date
        }
        for (relative, date) in stamps {
            let url = try child(relative: relative)
            try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return records
    }

    private func validate() throws {
        for profile in fixture.profiles {
            try requireFolder(profile.folder)
            for bucket in profile.buckets {
                try requireComponent(bucket.accountUUID)
                try requireComponent(bucket.organizationUUID)
                for session in bucket.sessions {
                    try requireRelative(session.projectDirectory)
                }
            }
        }
        for relative in fixture.modifiedAt.keys {
            try requireRelative(relative)
        }
    }

    private func config(for profile: ProfileSpec) -> [String: Any] {
        var object: [String: Any] = [
            "updaterLastSeenVersion": "1.2.3",
            "updaterRunningInstance": [
                "pid": 999001,
                "bootEpochMs": 1_792_832_402_000,
                "appVersion": "1.2.3",
                "launchedEpochMs": 1_792_832_402_000,
            ],
            "first_launch_at": "2026-01-01T00:00:00Z",
            "version_first_launch": "1.0.0",
            "locale": profile.locale,
            "lastQuitCleanup": [
                "completed": true,
                "for_update": false,
                "quit_epoch_ms": 0,
            ],
            "bootFrameLayout": [String: String](),
        ]
        if let account = profile.accountUUID {
            object["lastKnownAccountUuid"] = account
            object["bootSideSessions"] = ["accountUuid": account, "supported": true]
        }
        for organization in profile.organizations {
            object["dxt:allowlistEnabled:\(organization.uuid)"] = true
            object["dxt:allowlistLastUpdated:\(organization.uuid)"] = organization.allowlistUpdatedAt
            object["dxt:allowlistCache:\(organization.uuid)"] = [String: String]()
        }
        return object
    }

    private func sessionObject(_ session: SessionSpec, cwd: URL) -> [String: Any] {
        [
            "sessionId": session.desktopSessionID,
            "cliSessionId": session.cliSessionID,
            "cwd": cwd.path,
            "originCwd": cwd.path,
            "gitAnchors": [String](),
            "lastFocusedAt": session.lastFocusedAt,
            "createdAt": session.createdAt,
            "lastActivityAt": session.lastActivityAt,
            "model": "claude-sonnet",
            "effort": "medium",
            "isArchived": session.isArchived,
            "title": session.title,
            "titleSource": "ai",
            "permissionMode": "default",
            "remoteMcpServersConfig": [String: String](),
            "chromePermissionMode": "ask",
            "completedTurns": 1,
            "titleTurn": 1,
            "postTurnSummary": NSNull(),
            "postTurnSummaryFor": NSNull(),
            "lastAssistantUuid": NSNull(),
            "latestUserFrameAt": NSNull(),
            "spawnSeed": NSNull(),
            "promptAppendSnapshot": NSNull(),
            "toolSurfaceSnapshot": NSNull(),
            "companionFixtureMarker": ["keep": true, "value": session.marker],
        ]
    }

    private func planUsage(_ samples: [UsageSampleSpec]) -> [String: Any] {
        [
            "version": 2,
            "samples": samples.map { sample -> [String: Any] in
                [
                    "t": sample.timeMillis,
                    "org": sample.organizationUUID,
                    "u": ["fh": sample.fiveHourPercent, "sd": sample.sevenDayPercent],
                ]
            },
        ]
    }

    private func scheduledTasks() -> [String: Any] {
        [
            "scheduledTasks": [String](),
            "recordedSkips": [String](),
            "sundayAliasBoundaryStamped": false,
            "dayFieldsOrBoundaryStamped": false,
        ]
    }

    private func archiveIndex(_ ids: [String]) -> Data {
        let quoted = ids.sorted().map { "\"\($0)\"" }.joined(separator: ",")
        return Data("{\"v\":1,\"archived\":[\(quoted)]}".utf8)
    }

    private func writeCLI(
        session: SessionSpec,
        cwd: URL,
        pid: Int,
        procStart: String,
        startedAt: Int,
        paths: AppPaths
    ) throws -> CLISessionRecord {
        let slug = projectSlug(cwd.path)
        let transcript = paths.claudeCLIHome
            .appending(path: "projects", directoryHint: .isDirectory)
            .appending(path: slug, directoryHint: .isDirectory)
            .appending(path: "\(session.cliSessionID).jsonl")
        let registry = paths.claudeCLIHome
            .appending(path: "sessions", directoryHint: .isDirectory)
            .appending(path: "\(pid).json")
        let socket = paths.claudeCLIHome
            .appending(path: "sockets", directoryHint: .isDirectory)
            .appending(path: "\(pid).sock")
        try requireInside(transcript)
        try requireInside(registry)
        let record: [String: Any] = [
            "pid": pid,
            "sessionId": session.cliSessionID,
            "cwd": cwd.path,
            "startedAt": startedAt,
            "procStart": procStart,
            "version": "0.0.0-fixture",
            "peerProtocol": 1,
            "peerFeatures": [String](),
            "kind": "session",
            "entrypoint": "claude-desktop",
            "hostSessionId": session.desktopSessionID,
            "pidDomain": "user",
            "messagingSocketPath": socket.path,
            "name": session.title,
            "nameSince": startedAt,
            "updatedAt": startedAt,
            "status": session.cliStatus,
            "statusUpdatedAt": startedAt,
        ]
        try writeJSON(record, to: registry)
        let lines = [
            #"{"type":"user","sessionId":"\#(session.cliSessionID)","message":{"role":"user","content":"Hello from the fixture"}}"#,
            #"{"type":"assistant","sessionId":"\#(session.cliSessionID)","message":{"role":"assistant","content":"Hello back"}}"#,
        ]
        try writeExact(Data(lines.joined(separator: "\n").utf8), to: transcript)
        return CLISessionRecord(
            pid: pid,
            cliSessionID: session.cliSessionID,
            hostSessionID: session.desktopSessionID,
            cwd: cwd,
            status: session.cliStatus,
            procStart: procStart,
            registryFile: registry,
            transcriptFile: transcript
        )
    }

    private func writeJSON(_ object: Any, to url: URL) throws {
        try rejectSecrets(object)
        try requireInside(url)
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else {
            throw SandboxFixtureError.unencodable
        }
        try AtomicFile.write(data, to: url)
    }

    private func writeExact(_ data: Data, to url: URL) throws {
        try requireInside(url)
        try AtomicFile.write(data, to: url)
    }

    private func rejectSecrets(_ value: Any) throws {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if key.lowercased().hasPrefix("oauth:") {
                    throw SandboxFixtureError.secretKeyRefused
                }
                try rejectSecrets(child)
            }
        } else if let array = value as? [Any] {
            for child in array {
                try rejectSecrets(child)
            }
        }
    }

    private func makeDirectory(_ url: URL) throws {
        try requireInside(url)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        _ = chmod(url.path, mode_t(0o700))
    }

    private func child(relative: String) throws -> URL {
        try requireRelative(relative)
        return append(relative: relative, to: root)
    }

    private func requireFolder(_ name: String) throws {
        do {
            _ = try ProfileFolder(name)
        } catch {
            throw SandboxFixtureError.invalidProfileFolder(name)
        }
    }

    private func requireComponent(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." || name.contains("/") || name.contains("\0") {
            throw SandboxFixtureError.outsideRoot(name)
        }
    }

    private func requireRelative(_ relative: String) throws {
        if relative.hasPrefix("/") || relative.contains("\0") {
            throw SandboxFixtureError.outsideRoot(relative)
        }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        if parts.contains(".") || parts.contains("..") || parts.contains(where: { $0.isEmpty }) {
            throw SandboxFixtureError.outsideRoot(relative)
        }
    }

    private func requireInside(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        let rootPath = root.path
        if path == rootPath { return }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else {
            throw SandboxFixtureError.outsideRoot(path)
        }
    }

    private func relativeUnderHome(_ path: String) -> String {
        "home/" + path
    }

    private func relativePath(of url: URL) -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return String(url.path.dropFirst(prefix.count))
    }

    private func append(relative: String, to base: URL) -> URL {
        relative.split(separator: "/").reduce(base) { url, part in
            url.appending(path: String(part))
        }
    }

    private func projectSlug(_ path: String) -> String {
        let mapped = path.map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "-"
        }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
