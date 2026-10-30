import AppKit
import SwiftUI

public enum SnapshotRenderer {
    /// Renders the panel at 2×. Colors come from the `colorScheme` environment, not dynamic AppKit colors.
    @MainActor
    public static func png(state: PanelViewState, colorScheme: ColorScheme, scale: CGFloat = 2,
                           heightLimit: CGFloat? = nil) -> Data? {
        let view = PanelView(state: state, actions: .noop, heightLimit: heightLimit)
            .environment(\.drawsStill, true)
            .environment(\.colorScheme, colorScheme)
            .preferredColorScheme(colorScheme)
            .transaction { $0.disablesAnimations = true }
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: Metrics.panelWidth, height: nil)
        renderer.isOpaque = false
        guard let image = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])
    }
}
