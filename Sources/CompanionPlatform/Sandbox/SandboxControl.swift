import CompanionCore
import Foundation

public enum SandboxControlError: Error, Equatable, Sendable, CustomStringConvertible {
    case notGeneratedSandbox
    case invalidCommand
    case profileUnavailable
    case profileNotPending
    case alreadySignedIn

    public var description: String {
        switch self {
        case .notGeneratedSandbox: "Refused: expected a generated sandbox."
        case .invalidCommand: "Usage: --sandbox-control <dir> sign-in <folder> [email] | task busy|idle | open-default | fail-launch <folder> on|off | status"
        case .profileUnavailable: "Refused: the sandbox profile is unavailable."
        case .profileNotPending: "Refused: the profile has no pending sign-in."
        case .alreadySignedIn: "Refused: the profile is already signed in."
        }
    }
}

/// Manual fixture controls. No command assembles live services or starts AppKit.
public struct SandboxControl: Sendable {
    private let root: URL
    private var boundary: SandboxBoundary { SandboxBoundary(root: root) }
    private var paths: AppPaths { .sandbox(root: root) }

    public init(root: URL) { self.root = root.standardizedFileURL }

    public func perform(_ arguments: [String]) async throws -> String {
        try validateSandbox()
        switch arguments.first {
        case "sign-in" where (2...3).contains(arguments.count):
            let folder = try profileFolder(arguments[1])
            guard try state().pendingSignIns.contains(where: { $0.folder == folder }) else {
                throw SandboxControlError.profileNotPending
            }
            let profile = try profileDirectory(folder)
            let config = profile.appendingPathComponent("config.json")
            try boundary.check(config)
            if FileManager.default.fileExists(atPath: config.path) {
                _ = try readRegularFile(config)
                guard try ProfileConfigReader().read(profile: profile).accountUUID == nil else {
                    throw SandboxControlError.alreadySignedIn
                }
            }
            let email = arguments.count == 3 ? arguments[2] : "sandbox.user@example.com"
            guard !email.isEmpty, email.contains("@"), email.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else {
                throw SandboxControlError.invalidCommand
            }
            try SandboxWorldGenerator.installSignIn(root: root, folder: folder, account: UUID().uuidString.lowercased(),
                organization: UUID().uuidString.lowercased(), email: email)
            return "Signed in \(folder.name)."
        case "task" where arguments.count == 2 && ["busy", "idle"].contains(arguments[1]):
            let value: [String: Any] = arguments[1] == "busy"
                ? ["status": "busy", "tasks": [["pid": 424242]]] : ["status": "idle"]
            try writeJSON(value, to: root.appendingPathComponent("task-state.json"))
            return "Task \(arguments[1])."
        case "open-default" where arguments.count == 1:
            _ = try profileDirectory(ProfileFolder("Claude"))
            let pid = try await controller().launchDefault()
            return "Default launch requested (pid \(pid))."
        case "fail-launch" where arguments.count == 3 && ["on", "off"].contains(arguments[2]):
            let folder = try profileFolder(arguments[1])
            let marker = try profileDirectory(folder).appendingPathComponent(".fake-claude/fail-launch")
            try boundary.check(marker)
            if arguments[2] == "on" {
                try AtomicFile.write(Data(), to: marker)
            } else if FileManager.default.fileExists(atPath: marker.path) {
                let disabled = marker.deletingLastPathComponent().appendingPathComponent("disabled-fail-launch-\(UUID().uuidString)")
                try boundary.check(disabled)
                try FileManager.default.moveItem(at: marker, to: disabled)
            }
            return "Launch failure \(arguments[2]) for \(folder.name)."
        case "status" where arguments.count == 1:
            let pending = try state().pendingSignIns.map { $0.folder.name }.sorted()
            let running = try await controller().runningInstances().sorted { $0.pid < $1.pid }.map {
                Status.Instance(pid: $0.pid, folder: $0.profileDirectory.lastPathComponent,
                    hasExplicitProfileFlag: $0.hasExplicitProfileFlag)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return String(decoding: try encoder.encode(Status(pendingSignIns: pending, runningInstances: running)), as: UTF8.self)
        default: throw SandboxControlError.invalidCommand
        }
    }

    private func validateSandbox() throws {
        let manifest = root.appendingPathComponent("sandbox.json")
        do {
            try boundary.check(manifest)
            let value = try JSONDecoder().decode(Manifest.self, from: readRegularFile(manifest))
            let recorded = URL(fileURLWithPath: value.fakeClaude)
            let expected = SandboxWorldGenerator.fakeClaudeExecutable(root: root)
            try boundary.check(recorded)
            try boundary.check(expected)
            guard value.schemaVersion == 1, ProfilePaths.same(recorded, expected),
                  FileManager.default.isExecutableFile(atPath: expected.path) else {
                throw SandboxControlError.notGeneratedSandbox
            }
        } catch { throw SandboxControlError.notGeneratedSandbox }
    }

    private func controller() -> SandboxClaudeProcessController {
        SandboxClaudeProcessController(root: root, fakeClaudeExecutable: SandboxWorldGenerator.fakeClaudeExecutable(root: root))
    }

    private func state() throws -> CompanionState {
        let file = paths.companionDataDirectory.appendingPathComponent("state.json")
        try boundary.check(file)
        guard FileManager.default.fileExists(atPath: file.path) else { return CompanionState() }
        return try StableJSON.decode(CompanionState.self, from: readRegularFile(file))
    }

    private func profileFolder(_ name: String) throws -> ProfileFolder {
        guard name.rangeOfCharacter(from: .controlCharacters) == nil, let folder = try? ProfileFolder(name) else {
            throw SandboxControlError.profileUnavailable
        }
        return folder
    }

    private func profileDirectory(_ folder: ProfileFolder) throws -> URL {
        let profile = paths.claudeProfilesRoot.appendingPathComponent(folder.name)
        try boundary.check(profile)
        guard try FileManager.default.attributesOfItem(atPath: profile.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw SandboxControlError.profileUnavailable
        }
        return profile
    }

    private func readRegularFile(_ url: URL) throws -> Data {
        try boundary.check(url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 2 * 1024 * 1024 else {
            throw SandboxAdapterError.invalidState
        }
        return try AtomicFile.read(url)
    }

    private func writeJSON(_ value: [String: Any], to url: URL) throws {
        try boundary.check(url)
        try AtomicFile.write(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: url)
    }

    private struct Manifest: Decodable { let schemaVersion: Int; let fakeClaude: String }
    private struct Status: Encodable {
        let pendingSignIns: [String]
        let runningInstances: [Instance]
        struct Instance: Encodable {
            let pid: Int32
            let folder: String
            let hasExplicitProfileFlag: Bool
        }
    }
}
