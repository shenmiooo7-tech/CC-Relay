import CompanionCore
import Foundation
import ServiceManagement

struct LoginItemFile: Sendable {
    let directory: URL
    var label = AppIdentity.bundleIdentifier
    var url: URL { directory.appendingPathComponent(label + ".plist") }
    var isEnabled: Bool { FileManager.default.fileExists(atPath: url.path) }

    func enable(executable: URL) throws {
        do {
            let plist: [String: Any] = ["Label": label, "ProgramArguments": [executable.path],
                                        "RunAtLoad": true, "ProcessType": "Interactive"]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try AtomicFile.write(data, to: url)
        } catch { throw LoginItemError.writeFailed }
    }

    func disable() throws {
        do { try FileManager.default.removeItem(at: url) }
        catch CocoaError.fileNoSuchFile { return }
        catch { throw LoginItemError.notRemoved }
    }
}

/// The app as a login item of the system's own service, listed by name in System Settings. Where
/// the service turns the app down for a reason the person did not choose, a launch agent file does
/// the job.
public struct AppServiceLoginItem: LoginItemManaging {
    private let file: LoginItemFile

    public init(paths: AppPaths) {
        file = LoginItemFile(directory: paths.launchAgentsDirectory)
    }

    public var isEnabled: Bool {
        get async throws {
            try SafetyTripwire.assertLiveActionsAllowed()
            return SMAppService.mainApp.status == .enabled || file.isEnabled
        }
    }

    public func enable(executable: URL) async throws {
        try SafetyTripwire.assertLiveActionsAllowed()
        do {
            try SMAppService.mainApp.register()
        } catch {
            switch SMAppService.mainApp.status {
            case .enabled: break
            // Turned off in System Settings: that choice stands.
            case .requiresApproval: throw LoginItemError.writeFailed
            default:
                try file.enable(executable: executable)
                return
            }
        }
        try? file.disable()
    }

    public func disable() async throws {
        try SafetyTripwire.assertLiveActionsAllowed()
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval:
            do { try await SMAppService.mainApp.unregister() } catch { throw LoginItemError.notRemoved }
        default: break
        }
        try file.disable()
    }
}

public struct SandboxLoginItem: LoginItemManaging {
    private let boundary: SandboxBoundary
    private let file: LoginItemFile

    public init(root: URL) {
        boundary = SandboxBoundary(root: root)
        file = LoginItemFile(directory: AppPaths.sandbox(root: root).launchAgentsDirectory)
    }

    public var isEnabled: Bool {
        get async throws { try boundary.check(file.url); return file.isEnabled }
    }
    public func enable(executable: URL) async throws {
        try boundary.check(file.url)
        try file.enable(executable: executable)
    }
    public func disable() async throws {
        try boundary.check(file.url)
        try file.disable()
    }
}
