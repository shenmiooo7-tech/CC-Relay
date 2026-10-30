import CoreGraphics

/// Where the panel hangs, in AppKit screen coordinates (origin at the bottom left).
public enum PanelPlacement {
    public static let gapBelowMenuBar: CGFloat = 4
    public static let screenMargin: CGFloat = 8

    /// Left edge under the status item like a menu, top edge just below the menu bar,
    /// pushed back inside the visible screen, and never taller than the screen below the menu bar.
    public static func frame(content: CGSize, statusItem anchor: CGRect, visible screen: CGRect) -> CGRect {
        let top = min(anchor.minY, screen.maxY) - gapBelowMenuBar
        let height = min(content.height, heightLimit(statusItem: anchor, visible: screen))
        let width = content.width
        let rightmost = screen.maxX - screenMargin - width
        let x = max(screen.minX + screenMargin, min(anchor.minX, rightmost))
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// The tallest the panel can hang below the menu bar; its page scrolls past that.
    public static func heightLimit(statusItem anchor: CGRect, visible screen: CGRect) -> CGFloat {
        max(0, min(anchor.minY, screen.maxY) - gapBelowMenuBar - screen.minY - screenMargin)
    }
}
