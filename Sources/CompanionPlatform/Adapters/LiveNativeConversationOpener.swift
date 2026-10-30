import AppKit
import CompanionCore
import Foundation

/// Opens an existing local conversation in the target profile's running Desktop. The link is
/// handed to the system only while that Desktop is the one running, so it has exactly one place
/// to go; no Automation permission is needed or requested, and nothing is started.
public struct LiveNativeConversationOpener: NativeConversationOpening {
    private let paths: AppPaths
    private let checkAccess: @Sendable () throws -> Void
    private let readProcesses: @Sendable () throws -> [ProcessEntry]
    private let readArguments: @Sendable (ProcessEntry) throws -> [String]
    private let readConfiguration: @Sendable (URL) throws -> ProfileConfiguration
    private let deliver: @Sendable (URL, URL) async throws -> Void

    public init(paths: AppPaths) {
        self.init(paths: paths,
            checkAccess: { try SafetyTripwire.assertLiveActionsAllowed() },
            readProcesses: {
                try ProcessTable().closingProcesses().map {
                    ProcessEntry(pid: $0.identity.pid, ppid: $0.parent,
                                 executableURL: $0.identity.executable, startedAt: $0.identity.startedAt)
                }
            },
            readArguments: { expected in
                guard let current = ProcessTable().record(pid: expected.pid), current.ppid == expected.ppid,
                      current.startedAt == expected.startedAt,
                      ProfilePaths.same(current.executableURL, expected.executableURL) else {
                    throw NativeConversationOpenError.identityChanged
                }
                return current.argv
            },
            readConfiguration: { try ProfileConfigReader().read(profile: $0) },
            deliver: { link, profile in try await Self.deliver(link, profile: profile, app: paths.claudeAppURL) })
    }

    /// Injection keeps platform tests away from running apps and profile files.
    init(paths: AppPaths, checkAccess: @escaping @Sendable () throws -> Void = {},
         readProcesses: @escaping @Sendable () throws -> [ProcessEntry],
         readArguments: @escaping @Sendable (ProcessEntry) throws -> [String],
         readConfiguration: @escaping @Sendable (URL) throws -> ProfileConfiguration,
         deliver: @escaping @Sendable (URL, URL) async throws -> Void) {
        self.paths = paths; self.checkAccess = checkAccess; self.readProcesses = readProcesses
        self.readArguments = readArguments; self.readConfiguration = readConfiguration
        self.deliver = deliver
    }

    public func open(profile: URL, account: AccountIdentity, desktopSessionID: String) async throws {
        try checkAccess()
        guard profile.isFileURL,
              desktopSessionID.range(of: "^local_[A-Za-z0-9-]{1,64}$", options: .regularExpression) != nil,
              let url = URL(string: "claude://code/continue?session=\(desktopSessionID)") else {
            throw NativeConversationOpenError.invalidSession
        }
        try DeepLinkValidation.validate(url)
        try verifyConfiguration(profile, account: account)
        let expected = try onlyDesktop(profile: profile)
        try Task.checkCancellation()
        try checkAccess()
        // Never hand over a link when the Desktop changed lifetime, executable, parent, profile
        // or account since it was checked, or another Desktop appeared meanwhile.
        try verifyConfiguration(profile, account: account)
        let current = try onlyDesktop(profile: profile)
        guard current.pid == expected.pid, current.ppid == expected.ppid, current.startedAt == expected.startedAt,
              ProfilePaths.same(current.executableURL, expected.executableURL) else {
            throw NativeConversationOpenError.identityChanged
        }
        do { try await deliver(url, profile) }
        catch { throw NativeConversationOpenError.deliveryFailed(Int32(clamping: (error as NSError).code)) }
        // Delivery is not a runtime handshake. The coordinator waits for the conversation's
        // independently verified report before it arms any continuation.
    }

    @MainActor private static func deliver(_ link: URL, profile: URL, app: URL) async throws {
        try SafetyTripwire.assertLiveActionsAllowed()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        // Only reached while this profile's Desktop runs. Should it quit in the meantime, a
        // start still opens this profile rather than the default one.
        configuration.arguments = ["--user-data-dir=\(profile.standardizedFileURL.path)"]
        configuration.environment = ProcessInfo.processInfo.environment.merging(["PWD": "/"]) { _, value in value }
        _ = try await NSWorkspace.shared.open([link], withApplicationAt: app, configuration: configuration)
    }

    private func verifyConfiguration(_ profile: URL, account: AccountIdentity) throws {
        guard !account.accountUUID.isEmpty, let org = account.activeOrganizationUUID, !org.isEmpty else {
            throw NativeConversationOpenError.identityChanged
        }
        let configuration = try readConfiguration(profile)
        guard configuration.accountUUID == account.accountUUID, configuration.activeOrganizationUUID == org else {
            throw NativeConversationOpenError.identityChanged
        }
    }

    /// The target profile's Desktop, when no other Desktop runs beside it. With several, the
    /// system may hand a link to any of them, so the conversation is left to be opened by hand.
    private func onlyDesktop(profile: URL) throws -> ProcessEntry {
        let executable = paths.claudeAppPath.appending(path: "Contents/MacOS/Claude")
        let desktops = try readProcesses().filter { $0.pid > 1 && ProfilePaths.same($0.executableURL, executable) }
        guard let desktop = desktops.first else { throw NativeConversationOpenError.targetNotRunning }
        guard desktops.count == 1 else { throw NativeConversationOpenError.ambiguousTarget }
        let explicit = try ClaudeArguments.profileDirectory(in: readArguments(desktop))
        guard ProfilePaths.same(explicit ?? paths.claudeProfilesRoot.appending(path: "Claude"), profile) else {
            throw NativeConversationOpenError.targetNotRunning
        }
        return desktop
    }
}

public enum NativeConversationOpenError: Error, Equatable, Sendable {
    case invalidSession, targetNotRunning, ambiguousTarget, identityChanged
    case deliveryFailed(Int32)
}
