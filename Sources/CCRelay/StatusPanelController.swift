import AppKit
import CompanionUI
import SwiftUI

/// The status item and the panel under it. `MenuBarExtra` is not used: its window kept the height
/// it first had, framed the panel a second time, told the panel it appeared only once, and its label
/// dropped every text but one.
@MainActor
final class StatusPanelController: NSObject {
    private let model: PanelViewModel
    private let onClose: () -> Void
    private let statusItem: NSStatusItem
    private let panel = CompanionPanel()
    private var host: PanelHostingView?
    private var mouseMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    private let presence = MenuBarPresence()

    init(model: PanelViewModel, onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let host = PanelHostingView(rootView: PanelScreen(model: model))
        host.autoresizingMask = [.width, .height]
        host.onIdealSizeChange = { [weak self] in self?.contentSizeChanged() }
        panel.contentView = host
        panel.onCancel = { [weak self] in self?.close() }
        self.host = host
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            let buddy = MenuBarHostingView(rootView: MenuBarBuddy(model: model, presence: presence))
            buddy.sizingOptions = []
            buddy.frame = button.bounds
            buddy.autoresizingMask = [.width, .height]
            button.addSubview(buddy)
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: self))
        }
        observeMenuBar()
        observeAppearance()
    }

    /// The pointer over the status item sets its buddy moving.
    @objc(mouseEntered:) func mouseEntered(with event: NSEvent) {
        presence.hovered = true
    }

    @objc(mouseExited:) func mouseExited(with event: NSEvent) {
        presence.hovered = false
    }

    @objc private func toggle() {
        if panel.isVisible { close() } else { open() }
    }

    private func open() {
        guard let host else { return }
        place(host.idealSize)
        panel.makeKeyAndOrderFront(nil)
        statusItem.button?.highlight(true)
        startWatchingOutside()
        model.panelAppeared()
    }

    private func close() {
        guard panel.isVisible else { return }
        stopWatchingOutside()
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        model.panelClosed()
        onClose()
    }

    private func contentSizeChanged() {
        guard let host, panel.isVisible else { return }
        place(host.idealSize)
    }

    private func place(_ size: CGSize) {
        guard let anchor = statusItemFrame(),
              let screen = statusItem.button?.window?.screen ?? NSScreen.main else { return }
        // A page taller than the screen scrolls; the content then asks for this height, and this runs again.
        let limit = PanelPlacement.heightLimit(statusItem: anchor, visible: screen.visibleFrame)
        if model.heightLimit != limit { model.heightLimit = limit }
        let frame = PanelPlacement.frame(content: size, statusItem: anchor, visible: screen.visibleFrame)
        guard frame != panel.frame else { return }
        panel.setFrame(frame, display: true)
        // The shadow follows the rounded content, so it is redrawn whenever the size changes.
        panel.invalidateShadow()
    }

    private func statusItemFrame() -> CGRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Like a menu: a click anywhere else, or another app coming forward, closes the panel.
    private func startWatchingOutside() {
        stopWatchingOutside()
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A click on the status item is its own toggle.
                if let item = self.statusItemFrame(), item.contains(NSEvent.mouseLocation) { return }
                self.close()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func stopWatchingOutside() {
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
    }

    private func observeMenuBar() {
        let content = withObservationTracking {
            model.menuBarModel.content
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeMenuBar() }
        }
        show(content)
    }

    /// Light or dark as chosen in Settings, or the system's. The SwiftUI panel and the cards' menus
    /// follow the window.
    private func observeAppearance() {
        let choice = withObservationTracking {
            model.state.settings.appearance
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeAppearance() }
        }
        let appearance: NSAppearance? = switch choice {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        // Every change to the panel's state comes through here; the window is only touched on a new choice.
        if panel.appearance?.name != appearance?.name { panel.appearance = appearance }
    }

    /// The menu bar shows only the logo, so only what VoiceOver reads changes.
    private func show(_ content: MenuBarContent) {
        statusItem.button?.setAccessibilityLabel(content.accessibilityLabel)
    }
}

/// The buddy on the status item. Clicks go through it to the button.
final class MenuBarHostingView: NSHostingView<MenuBarBuddy> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Reports when SwiftUI says the content's ideal size may have changed: new data, a banner,
/// the settings page, or view state such as a rename error line. The window does not follow
/// on its own, so the panel is resized from here with its top edge kept under the menu bar.
final class PanelHostingView: NSHostingView<PanelScreen> {
    var onIdealSizeChange: (() -> Void)?
    private var notifyScheduled = false

    required init(rootView: PanelScreen) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used from a nib")
    }

    var idealSize: CGSize {
        CGSize(width: Metrics.panelWidth, height: intrinsicContentSize.height)
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // SwiftUI invalidates mid-update; measuring on the next turn reads the settled size once.
        guard !notifyScheduled else { return }
        notifyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.notifyScheduled = false
            self.onIdealSizeChange?()
        }
    }
}

/// Borderless and clear: the SwiftUI panel draws its own rounded frame. It takes key focus for the
/// rename field without bringing the app forward, so Claude stays the active app.
final class CompanionPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
