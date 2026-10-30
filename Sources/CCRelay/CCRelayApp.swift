import AppKit
import CompanionCore
import CompanionPlatform
import CompanionUI

@main
enum CompanionEntry {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.dropFirst().first == "--sandbox-control" {
            guard arguments.count >= 4 else {
                fputs("\(SandboxControlError.invalidCommand)\n", stderr)
                exit(2)
            }
            Task {
                do {
                    print(try await SandboxControl(root: URL(fileURLWithPath: arguments[2]))
                        .perform(Array(arguments.dropFirst(3))))
                    exit(0)
                } catch {
                    let message = String(describing: error).replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\r", with: " ")
                    fputs("Sandbox control failed: \(message)\n", stderr)
                    exit(1)
                }
            }
            dispatchMain()
        }
        if arguments.dropFirst().first == "--make-sandbox" {
            guard arguments.count == 3 else { exit(2) }
            do {
                let source = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent().appendingPathComponent("FakeClaude")
                let world = try SandboxWorldGenerator.generate(at: URL(fileURLWithPath: arguments[2]), fakeClaude: source)
                print(world.root.path)
                return
            } catch {
                fputs("Could not generate sandbox: \(error)\n", stderr)
                exit(1)
            }
        }
        if arguments.dropFirst().first == "--render-icon" {
            // scripts/make-icon.sh turns this iconset into Resources/AppIcon.icns.
            guard arguments.count == 3 else { exit(2) }
            do {
                try AppIconArtwork.writeIconset(to: URL(fileURLWithPath: arguments[2]))
                return
            } catch {
                fputs("Could not render the app icon: \(error)\n", stderr)
                exit(1)
            }
        }
        let pids = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleIdentifier).map(\.processIdentifier)
        guard !AppLaunchPolicy.shouldExit(currentPID: ProcessInfo.processInfo.processIdentifier, runningPIDs: pids) else { return }
        let app = NSApplication.shared
        let delegate = CompanionAppDelegate()
        app.delegate = delegate
        // The bundle says LSUIElement; a bare debug binary has no bundle, so ask for it here as well.
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

enum AppLaunchPolicy {
    static func shouldExit(currentPID: Int32, runningPIDs: [Int32]) -> Bool {
        runningPIDs.contains { $0 != currentPID }
    }
}

@MainActor
final class CompanionAppDelegate: NSObject, NSApplicationDelegate {
    lazy var services: AppServices = {
        do {
            return try AppServices.current { [weak self] in await self?.engineFinished() }
        } catch {
            fputs("App service initialization refused: \(error)\n", stderr)
            exit(1)
        }
    }()
    lazy var panelViewModel = PanelViewModel(facade: services.engine) { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    private var statusPanel: StatusPanelController?
    private(set) var termination = AppTerminationState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let engine = services.engine
        statusPanel = StatusPanelController(model: panelViewModel) {
            Task { await engine.panelClosed() }
        }
        Task { await engine.start() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch termination.request() {
        case .finished: return .terminateNow
        case .waiting: return .terminateLater
        case .begin:
            Task { await services.engine.perform(.quitApp) }
            return .terminateLater
        }
    }

    private func engineFinished() {
        if termination.finish() { NSApplication.shared.reply(toApplicationShouldTerminate: true) }
        else { NSApplication.shared.terminate(nil) }
    }
}

/// Checked without AppKit startup; the delegate can receive either quit entry point first.
struct AppTerminationState {
    enum Request: Equatable { case begin, waiting, finished }
    private var waiting = false
    private var finished = false

    mutating func request() -> Request {
        if finished { return .finished }
        if waiting { return .waiting }
        waiting = true
        return .begin
    }

    mutating func finish() -> Bool {
        finished = true
        return waiting
    }
}
