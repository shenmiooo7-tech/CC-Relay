import SwiftUI

/// Window contents for the menu-bar extra until account switching is wired.
/// Construction does not read or write user data.
public struct PlaceholderView: View {
    public init() {}

    public var body: some View {
        PanelView(state: .placeholder(), actions: .noop)
    }
}
