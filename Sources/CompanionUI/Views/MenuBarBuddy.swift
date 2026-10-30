import SwiftUI

/// Whether the pointer is over the status item.
@MainActor
@Observable
public final class MenuBarPresence {
    public var hovered = false

    public init() {}
}

/// The status item: the current account's buddy, as on its card but square, like the icons beside it.
/// It stands still, and moves only while the pointer is over it and when its quota steps to another
/// level: its face and colour change, and it perks up or sighs.
public struct MenuBarBuddy: View {
    let model: PanelViewModel
    let presence: MenuBarPresence

    @State private var changing = false
    @State private var settling: Task<Void, Never>?

    public init(model: PanelViewModel, presence: MenuBarPresence) {
        self.model = model
        self.presence = presence
    }

    public var body: some View {
        let current = model.state.current
        let face = current?.buddy ?? .unknown
        BuddyView(face: face, side: Metrics.menuBarAvatar, id: current?.id ?? "", keepsShape: true)
            .environment(\.buddyHovered, presence.hovered)
            .environment(\.drawsStill, !(presence.hovered || changing))
            .onChange(of: face) { keepMoving() }
            .onChange(of: presence.hovered) { _, over in if !over { keepMoving() } }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Long enough for the slowest move a new level or the pointer starts, a sigh, to end.
    private func keepMoving() {
        changing = true
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .seconds(1.1))
            if !Task.isCancelled { changing = false }
        }
    }
}
