import Foundation

public struct BucketInventory: Equatable, Sendable {
    public let bucket: SessionBucket
    public let localRecordCount: Int
    public let newestModification: Date?
}

public struct ProfileScan: Equatable, Sendable {
    public var profiles: [ProfileSnapshot]
    public var inventory: [ProfileFolder: [BucketInventory]]
    /// Account directories may exist without any organization directories.
    public var accountDirectories: [ProfileFolder: [String]]
}

public struct ProfileScanner: Sendable {
    private let root: URL
    private let appDirectory: URL
    private let io: SessionFileIO

    public init(paths: AppPaths) {
        self.init(paths: paths, io: SessionFileIO())
    }

    init(paths: AppPaths, io: SessionFileIO) {
        root = paths.claudeProfilesRoot
        appDirectory = paths.companionDataDirectory
        self.io = io
    }

    public func scan(managed: [ProfileFolder] = [], pending: [ProfileFolder] = []) throws -> ProfileScan {
        let explicit = Set(managed + pending)
        let pending = Set(pending)
        guard try io.info(root) != nil else {
            return ProfileScan(profiles: [], inventory: [:], accountDirectories: [:])
        }
        var result = ProfileScan(profiles: [], inventory: [:], accountDirectories: [:])
        for directory in try io.list(root) {
            guard directory.standardizedFileURL.resolvingSymlinksInPath().path != appDirectory.standardizedFileURL.resolvingSymlinksInPath().path,
                  let folder = try? ProfileFolder(directory.lastPathComponent),
                  folder.name == "Claude" || folder.name.hasPrefix("Claude_") || explicit.contains(folder)
            else { continue }
            do {
                if let inspected = try inspect(directory, folder: folder, pending: pending.contains(folder)) {
                    result.profiles.append(inspected.profile)
                    if let inventory = inspected.inventory {
                        result.inventory[folder] = inventory.1
                        result.accountDirectories[folder] = inventory.0
                    }
                }
            } catch {
                result.profiles.append(ProfileSnapshot(folder: folder, url: directory,
                    status: .unreadable(reason: .unreadableDirectory)))
            }
        }
        result.profiles.sort { a, b in
            a.folder.isDefault != b.folder.isDefault ? a.folder.isDefault : a.folder.name < b.folder.name
        }
        for index in result.profiles.indices {
            guard case .signedIn(let identity) = result.profiles[index].status else { continue }
            result.profiles[index].duplicateOf = result.profiles.first {
                guard $0.folder != result.profiles[index].folder,
                      case .signedIn(let other) = $0.status else { return false }
                return identity.accountUUID == other.accountUUID
            }?.folder
        }
        return result
    }

    private func inspect(_ directory: URL, folder: ProfileFolder, pending: Bool) throws
        -> (profile: ProfileSnapshot, inventory: ([String], [BucketInventory])?)? {
        guard let metadata = try io.info(directory), io.isDirectory(metadata) else { return nil }
        let configExists = try io.info(directory.appending(path: "config.json")) != nil
        var status: ProfileStatus?
        var readable: SessionBucket?
        if configExists {
            do {
                let config = try ProfileConfigReader().read(profile: directory)
                if let account = config.accountUUID {
                    status = .signedIn(AccountIdentity(accountUUID: account,
                        activeOrganizationUUID: config.activeOrganizationUUID,
                        knownOrganizationUUIDs: config.knownOrganizationUUIDs))
                    if let org = config.activeOrganizationUUID {
                        readable = try? SessionBucket(accountUUID: account, organizationUUID: org)
                    }
                }
            } catch { status = .unreadable(reason: .configUnparsable) }
        }
        let sessions = directory.appending(path: "claude-code-sessions")
        var qualifies = configExists || pending
        var inspectedSessionsPath = false
        var contents: ([String], [BucketInventory])?
        do {
            let metadata = try io.info(sessions)
            inspectedSessionsPath = true
            qualifies = qualifies || metadata.map(io.isDirectory) == true
            contents = try inventory(sessions)
        } catch {
            // A failed stat cannot establish that this candidate is an empty folder.
            if !inspectedSessionsPath { qualifies = true }
        }
        guard qualifies else { return nil }
        if status == nil {
            if let accounts = contents?.0 {
                status = accounts.isEmpty ? .awaitingSignIn : .signedOut(lastAccountUUID: accounts.count == 1 ? accounts[0] : nil)
            } else { status = .unreadable(reason: .unreadableDirectory) }
        }
        let profile = ProfileSnapshot(folder: folder, url: directory, status: status!,
            sessionBuckets: contents?.1.map(\.bucket) ?? [], readableBucket: readable)
        return (profile, contents)
    }

    private func inventory(_ sessions: URL) throws -> ([String], [BucketInventory]) {
        guard let metadata = try io.info(sessions) else { return ([], []) }
        guard io.isDirectory(metadata) else { throw SessionDataError.unexpectedType(sessions) }
        var accounts: [String] = [], buckets: [BucketInventory] = []
        for account in try io.list(sessions) {
            guard let value = try io.info(account), io.isDirectory(value) else { continue }
            accounts.append(account.lastPathComponent)
            for org in try io.list(account) {
                guard let value = try io.info(org), io.isDirectory(value) else { continue }
                var count = 0
                var newest: Date?
                for record in try io.list(org) where SessionFileIO.isSession(record.lastPathComponent) {
                    guard let info = try io.info(record), io.isRegular(info) else { continue }
                    count += 1
                    let date = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
                    newest = max(newest ?? date, date)
                }
                buckets.append(BucketInventory(bucket: try SessionBucket(accountUUID: account.lastPathComponent,
                    organizationUUID: org.lastPathComponent), localRecordCount: count, newestModification: newest))
            }
        }
        return (accounts, buckets)
    }
}
