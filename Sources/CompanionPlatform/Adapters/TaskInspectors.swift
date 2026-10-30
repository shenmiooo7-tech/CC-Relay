import CompanionCore
import Foundation

public struct LiveCodeTaskInspector: CodeTaskInspecting {
    private let paths: AppPaths

    public init(paths: AppPaths) { self.paths = paths }

    public func activity() async -> TaskActivity {
        do {
            try SafetyTripwire.assertLiveActionsAllowed()
            let processes = try ProcessTable().entries()
            return TaskGuardEvaluator.evaluate(processes: processes,
                claudeMainExecutable: paths.claudeAppURL.appendingPathComponent("Contents/MacOS/Claude")) { pid in
                try Data(contentsOf: paths.claudeCLIHome.appendingPathComponent("sessions/\(pid).json"))
            }
        } catch { return .unknown(TaskUnknownReason.processTableUnavailable) }
    }
}

/// Script format: {"status":"idle"|"busy"|"unknown", "tasks":[{"pid":123}]}.
public struct SandboxTaskInspector: CodeTaskInspecting {
    public let stateFile: URL
    private let boundary: SandboxBoundary

    public init(root: URL, stateFile: URL? = nil) {
        boundary = SandboxBoundary(root: root)
        self.stateFile = stateFile ?? root.appendingPathComponent("task-state.json")
    }

    public func activity() async -> TaskActivity {
        do {
            try boundary.check(stateFile)
            let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
            switch state.status {
            case "idle": return .idle
            case "busy":
                guard let tasks = state.tasks, !tasks.isEmpty else { throw SandboxAdapterError.invalidState }
                return .busy(tasks.map { CodeTaskInfo(pid: $0.pid, sessionID: $0.sessionId,
                    workingDirectory: $0.cwd, reason: $0.shellChild.map { .shellChild(pid: $0) } ?? .statusBusy) })
            default: return .unknown(TaskUnknownReason.registryMismatch)
            }
        } catch { return .unknown(TaskUnknownReason.registryUnreadable) }
    }

    private struct State: Decodable {
        let status: String
        let tasks: [TaskRecord]?
    }
    private struct TaskRecord: Decodable {
        let pid: Int32
        let sessionId: String?
        let cwd: String?
        let shellChild: Int32?
    }
}
