import AppKit
import SwiftUI

/// What a card asks the panel for when its menu should open: which account, and where.
struct CardMenuRequest: Equatable {
    var id: String
    var name: String
    /// The account in use stays: its menu offers no removal.
    var isCurrent: Bool
    /// The pointer, or the "⋯" button's frame, in the panel's space, y down.
    var anchor: CGRect
    /// Opened from the "⋯" button: the menu hangs under its right end instead of at the pointer.
    var fromButton: Bool
    /// Opened from the keyboard: its first item takes the focus.
    var fromKeyboard: Bool
}

private struct OpenCardMenuKey: EnvironmentKey {
    static let defaultValue: (@MainActor (CardMenuRequest) -> Void)? = nil
}

extension EnvironmentValues {
    /// Set by the panel: cards ask it to open their menu.
    var openCardMenu: (@MainActor (CardMenuRequest) -> Void)? {
        get { self[OpenCardMenuKey.self] }
        set { self[OpenCardMenuKey.self] = newValue }
    }
}

/// Over a card: tells a right click, or a click with Control held, at once, with where it landed in the
/// panel. Every other click goes through to the card.
struct SecondaryClickArea: NSViewRepresentable {
    let onClick: @MainActor (CGPoint) -> Void

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.onClick = onClick
        return view
    }

    func updateNSView(_ view: ClickView, context: Context) {
        view.onClick = onClick
    }

    final class ClickView: NSView {
        var onClick: (@MainActor (CGPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let secondary = event.type == .rightMouseDown
                || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            return secondary ? super.hitTest(point) : nil
        }

        override func rightMouseDown(with event: NSEvent) {
            report(event)
        }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { report(event) }
        }

        private func report(_ event: NSEvent) {
            guard let point = PanelSpace.point(event.locationInWindow, in: window) else { return }
            onClick?(point)
        }
    }
}

/// Finds where a view is in the panel when asked, such as a button whose menu opens under it.
@MainActor
final class PanelFrameProbe {
    fileprivate weak var view: NSView?

    /// The view's frame in the panel's space, y down.
    var frame: CGRect? {
        guard let view, let window = view.window else { return nil }
        let rect = view.convert(view.bounds, to: nil)
        guard let top = PanelSpace.point(CGPoint(x: rect.minX, y: rect.maxY), in: window) else { return nil }
        return CGRect(x: top.x, y: top.y, width: rect.width, height: rect.height)
    }
}

struct PanelFrameReader: NSViewRepresentable {
    let probe: PanelFrameProbe

    func makeNSView(context: Context) -> PassView {
        let view = PassView()
        probe.view = view
        return view
    }

    func updateNSView(_ view: PassView, context: Context) {
        probe.view = view
    }

    final class PassView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The panel fills its window's content from the top, so a point in the window, turned y down, is a point
/// in the panel.
enum PanelSpace {
    @MainActor
    static func point(_ location: CGPoint, in window: NSWindow?) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let point = content.convert(location, from: nil)
        return CGPoint(x: point.x, y: content.isFlipped ? point.y : content.bounds.height - point.y)
    }
}

/// A card's own menu, in the panel's card style: the account's name, then "rename" and "remove", each with
/// a small tile like the settings rows. It pops in at the pointer or under the "⋯" button, inside the panel.
/// Up and down move between the items, Return picks, Esc closes; so does a click anywhere else.
struct CardMenu: View {
    let request: CardMenuRequest
    let actions: PanelActions
    let close: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @State private var highlighted: Int?
    @FocusState private var focused: Bool

    private struct Item {
        var title: String
        var tile: (UInt32, UInt32)
        var symbol: String
        var danger: Bool
        var enabled: Bool
        var note: String?
        var run: () -> Void
    }

    private var items: [Item] {
        [
            Item(title: L10nKey.rename.string(in: language), tile: PaletteHex.tileCompact, symbol: "pencil",
                 danger: false, enabled: true, note: nil, run: { actions.beginRename(request.id) }),
            Item(title: L10nKey.remove.string(in: language), tile: PaletteHex.tileQuit, symbol: "archivebox",
                 danger: true, enabled: !request.isCurrent,
                 note: request.isCurrent ? L10nKey.menuRemoveCurrent.string(in: language) : nil,
                 run: { actions.remove(request.id) }),
        ]
    }

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let items = items
        VStack(alignment: .leading, spacing: 0) {
            Text(request.name)
                .font(TextRole.menuTitle.font)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(palette.textTertiary)
                .padding(.horizontal, 8)
                .padding(.top, 5)
                .padding(.bottom, 6)
            ForEach(items.indices, id: \.self) { index in
                if index > 0 {
                    palette.hairline
                        .frame(height: Metrics.borderWidth)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                row(items[index], index: index, palette: palette)
            }
        }
        .padding(5)
        .frame(width: Metrics.menuWidth, alignment: .leading)
        .background(palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .strokeBorder(palette.hairline, lineWidth: Metrics.borderWidth)
        }
        .shadow(color: .black.opacity(0.2), radius: 15, y: 12)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { move(1, in: items); return .handled }
        .onKeyPress(.upArrow) { move(-1, in: items); return .handled }
        .onKeyPress(.return) {
            if let index = highlighted, items[index].enabled { pick(items[index]) }
            return .handled
        }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.tab) { close(); return .handled }
        .onAppear {
            focused = true
            if request.fromKeyboard { highlighted = items.firstIndex { $0.enabled } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(request.name)
    }

    private func row(_ item: Item, index: Int, palette: ThemePalette) -> some View {
        Button {
            pick(item)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: item.tile.1))
                    .frame(width: Metrics.menuTile, height: Metrics.menuTile)
                    .background(Color(hex: item.tile.0), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .scaleEffect(highlighted == index && item.enabled ? 1.12 : 1)
                    .rotationEffect(.degrees(highlighted == index && item.enabled ? -6 : 0))
                    .motion(Motion.bounce, value: highlighted == index)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(TextRole.menuItem.font)
                        .lineLimit(TextChrome.lineLimit)
                        .foregroundStyle(item.danger ? palette.quotaLowText : palette.textPrimary)
                    if let note = item.note {
                        Text(note)
                            .font(TextRole.menuNote.font)
                            .lineLimit(TextChrome.lineLimit)
                            .foregroundStyle(palette.textTertiary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                Color.gray.opacity(highlighted == index && item.enabled ? 0.12 : 0),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
            .opacity(item.enabled ? 1 : 0.45)
        }
        .buttonStyle(PressButtonStyle())
        .disabled(!item.enabled)
        .onHover { over in
            if over { highlighted = index } else if highlighted == index { highlighted = nil }
        }
        .motion(Motion.touch, value: highlighted)
    }

    private func move(_ step: Int, in items: [Item]) {
        let enabled = items.indices.filter { items[$0].enabled }
        guard !enabled.isEmpty else { return }
        guard let current = highlighted, let place = enabled.firstIndex(of: current) else {
            highlighted = step > 0 ? enabled.first : enabled.last
            return
        }
        highlighted = enabled[(place + step + enabled.count) % enabled.count]
    }

    private func pick(_ item: Item) {
        close()
        item.run()
    }

    /// Where the menu goes for `request` in a panel `size`: under the pointer, or under the button's right
    /// end; above instead when there is no room below; never past the panel's sides.
    static func placement(for request: CardMenuRequest, in size: CGSize) -> (x: CGFloat, y: CGFloat, up: Bool) {
        let width = Metrics.menuWidth
        let height = Metrics.menuHeightEstimate
        let edge = Metrics.menuEdgeInset
        var x = request.fromButton ? request.anchor.maxX - width : request.anchor.minX
        x = min(max(x, edge), max(edge, size.width - width - edge))
        let below = request.fromButton ? request.anchor.maxY + 4 : request.anchor.minY
        let up = below + height > size.height - edge
        let y = up ? (request.fromButton ? request.anchor.minY - 4 : request.anchor.minY) : below
        return (x, y, up)
    }
}
