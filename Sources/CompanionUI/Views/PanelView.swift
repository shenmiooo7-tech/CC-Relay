import SwiftUI

/// Panel hosted on a view model. The window that shows it tells the model when it opens and closes,
/// because a hosted view appears only once however often its window is shown. While it is closed,
/// nothing on it moves.
public struct PanelScreen: View {
    private var model: PanelViewModel

    public init(model: PanelViewModel) {
        self.model = model
    }

    public var body: some View {
        PanelView(state: model.state, actions: model.makeActions(), heightLimit: model.heightLimit)
            .environment(\.motionPaused, !model.panelOpen)
            .fixedSize(horizontal: false, vertical: true)
            // The window takes a new height a moment after the content does; until then the content
            // keeps to the top, under the menu bar, instead of jumping to the middle of the old frame.
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

public struct PanelView: View {
    public var state: PanelViewState
    public var actions: PanelActions
    /// How tall the screen lets the panel be. The account page also stops at `Metrics.panelMaxHeight`;
    /// past either the account list scrolls, and the settings page past this one. Nil: no screen limit.
    public var heightLimit: CGFloat?

    @Environment(\.colorScheme) private var colorScheme
    @State private var menu: CardMenuRequest?
    @State private var menuHeight: CGFloat?

    public init(state: PanelViewState, actions: PanelActions, heightLimit: CGFloat? = nil) {
        self.state = state
        self.actions = actions
        self.heightLimit = heightLimit
    }

    public var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous)
        // One frame for every page. The window behind it is clear, so this shape is the panel's outline.
        panel
            .environment(\.l10nLanguage, state.language)
            .environment(\.openCardMenu, { request in
                guard !state.hasDialog, state.shownNotice == nil, !state.interactionLocked else { return }
                menu = request
            })
            .environment(\.shownMenuID, menu?.id)
            .frame(width: Metrics.panelWidth, alignment: .topLeading)
            .background(palette.panel)
            .overlay { dialogLayer }
            .overlay { menuLayer }
            .overlay { hudLayer }
            .clipShape(shape)
            .overlay { shape.strokeBorder(palette.hairline, lineWidth: Metrics.borderWidth) }
            .onChange(of: state.hasDialog || state.isSettingsOpen || state.interactionLocked) { _, closes in
                if closes { menu = nil }
            }
    }

    /// The dialog showing, if any: a switch first, then an account being added, renamed or removed, then
    /// a notice. The page under it is dimmed and out of reach.
    private enum Dialog: Equatable {
        case switching(SwitchDialogState)
        case adding(AddDialogState)
        case renaming(RenameDialogState)
        case removing(RemoveDialogState)
        case plugin(PluginDialogState)
        case notice(BannerState)

        /// A new dialog pops in; the same one changing what it says stays put.
        var key: String {
            switch self {
            case .switching(let state): "switch:\(state.targetID)"
            case .adding: "add"
            case .renaming(let state): "rename:\(state.id)"
            case .removing(let state): "remove:\(state.id)"
            case .plugin: "plugin"
            case .notice(let banner): "notice:\(banner.id)"
            }
        }
    }

    private var dialog: Dialog? {
        if let state = state.switchDialog { return .switching(state) }
        if let state = state.addDialog { return .adding(state) }
        if let state = state.renameDialog { return .renaming(state) }
        if let state = state.removeDialog { return .removing(state) }
        if let state = state.pluginDialog { return .plugin(state) }
        return state.shownNotice.map(Dialog.notice)
    }

    @ViewBuilder
    private func dialogView(_ dialog: Dialog, actions: PanelActions) -> some View {
        switch dialog {
        case .switching(let state): SwitchDialog(state: state, actions: actions)
        case .adding(let state): AddDialog(state: state, actions: actions)
        case .renaming(let state): RenameDialog(state: state, actions: actions)
        case .removing(let state): RemoveDialog(state: state, actions: actions)
        case .plugin(let state): PluginDialog(state: state, actions: actions)
        case .notice(let banner): NoticeDialog(banner: banner, actions: actions)
        }
    }

    private var dialogLayer: some View {
        let palette = Theme.palette(for: colorScheme)
        let shown = dialog
        return ZStack {
            if let shown {
                palette.textPrimary.opacity(Metrics.overlayOpacity)
                    .transition(.opacity)
                dialogView(shown, actions: actions)
                    .environment(\.l10nLanguage, state.language)
                    .id(shown.key)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.88).combined(with: .opacity),
                        removal: .scale(scale: 0.92).combined(with: .opacity)
                    ))
            }
        }
        .motion(Motion.pop, value: shown?.key)
    }

    /// A card's menu, over the page where it was asked for; a click anywhere else closes it.
    private var menuLayer: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                if let menu {
                    let place = CardMenu.placement(for: menu, in: proxy.size)
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { self.menu = nil }
                    CardMenu(request: menu, actions: actions, close: { self.menu = nil })
                        .environment(\.l10nLanguage, state.language)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { menuHeight = $0 }
                        .offset(x: place.x, y: place.up ? place.y - (menuHeight ?? Metrics.menuHeightEstimate) : place.y)
                        .id(menu.id + (menu.fromButton ? ":button" : ":\(menu.anchor.minX),\(menu.anchor.minY)"))
                        .transition(.scale(scale: 0.86, anchor: Self.menuAnchor(menu, up: place.up)).combined(with: .opacity))
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
        .motion(Motion.pop, value: menu)
    }

    /// The corner the menu grows from: the pointer's, or the button's.
    private static func menuAnchor(_ menu: CardMenuRequest, up: Bool) -> UnitPoint {
        switch (up, menu.fromButton) {
        case (false, false): .topLeading
        case (false, true): .topTrailing
        case (true, false): .bottomLeading
        case (true, true): .bottomTrailing
        }
    }

    /// The line in the middle of whichever page is open. Each new one pops in afresh. Only one with an undo
    /// button takes clicks. It steps aside while a dialog is up, and comes back if it is still due.
    private var hudLayer: some View {
        ZStack {
            if let hud = state.hud, dialog == nil {
                HUDView(hud: hud, action: actions.hudAction)
                    .environment(\.l10nLanguage, state.language)
                    .id(hud.id)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.9).combined(with: .opacity).animation(Motion.pop),
                        removal: .opacity.animation(Motion.fade)
                    ))
            }
        }
        .motion(Motion.pop, value: state.hud)
        // Leaves the card `Metrics.hudTextWidth` for its words.
        .padding(.horizontal, Metrics.panelPadding)
        .allowsHitTesting(state.hud?.actionTitle != nil)
    }

    private var panel: some View {
        ZStack(alignment: .top) {
            // An overlay never sizes its host: an invisible copy of the dialog keeps the panel at least
            // as tall as the dialog it shows.
            if let dialog {
                dialogView(dialog, actions: .noop)
                    .padding(Metrics.panelPadding)
                    .hidden()
                    .disabled(true)
                    .accessibilityHidden(true)
                    .environment(\.drawsStill, true)
            }
            if state.isSettingsOpen {
                PanelScroll(limit: heightLimit) { SettingsView(settings: state.settings, actions: actions) }
                    .transition(.move(edge: .trailing))
            } else {
                accountPanel
                    .transition(.move(edge: .leading))
            }
        }
        .motion(Motion.slide, value: state.isSettingsOpen)
    }

    private var accountPanel: some View {
        AccountPanel(
            state: state,
            actions: actions,
            heightLimit: min(Metrics.panelMaxHeight, heightLimit ?? Metrics.panelMaxHeight)
        )
    }
}

/// A page no taller than `limit`: past it the page scrolls, below it the page is as tall as it is.
private struct PanelScroll<Content: View>: View {
    let limit: CGFloat?
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let limit {
            ScrollArea(content: content)
                .frame(maxHeight: limit)
        } else {
            content()
        }
    }
}

/// A vertical scroll view as tall as its content allows. For a still picture it is the content's top part
/// instead, since ImageRenderer draws no scroll view.
private struct ScrollArea<Content: View>: View {
    /// Set while the content is scrolled away from its top. Reported on macOS 15 and later.
    var scrolled: Binding<Bool>?
    @ViewBuilder let content: () -> Content

    @Environment(\.drawsStill) private var drawsStill

    var body: some View {
        if drawsStill {
            content()
                .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipped()
        } else if #available(macOS 15.0, *), let scrolled {
            scrollView
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentOffset.y + geometry.contentInsets.top > 0.5
                } action: { _, isScrolled in
                    scrolled.wrappedValue = isScrolled
                }
        } else {
            scrollView
        }
    }

    private var scrollView: some View {
        ScrollView(.vertical) { content() }
            .scrollBounceBehavior(.basedOnSize)
    }
}

private struct DrawsStillKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MotionPausedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set when the panel is rendered as a picture rather than shown in a window.
    public var drawsStill: Bool {
        get { self[DrawsStillKey.self] }
        set { self[DrawsStillKey.self] = newValue }
    }

    /// Set while the panel is closed: whatever moves on its own holds its frame, and goes on from the
    /// clock when the panel opens. Unlike `drawsStill` it changes nothing else, so the panel comes back
    /// as it was. A closed panel's moving parts would otherwise keep the processor busy.
    var motionPaused: Bool {
        get { self[MotionPausedKey.self] }
        set { self[MotionPausedKey.self] = newValue }
    }
}

private struct AccountPanel: View {
    let state: PanelViewState
    let actions: PanelActions
    let heightLimit: CGFloat

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused
    @State private var listScrolled = false
    @State private var act: BuddyAct?
    @State private var buddyIDs: [String] = []

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: Metrics.gridGap),
            GridItem(.flexible()),
        ]
    }

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        PinnedTopLayout(limit: heightLimit, minimumList: Metrics.minimumListHeight) {
            // A scroll view only so a very tall top (a long suggestion, a large text size) still shows all of itself.
            ScrollArea { top(palette) }
                .overlay(alignment: .bottom) {
                    palette.hairline
                        .frame(height: Metrics.borderWidth)
                        .opacity(listScrolled ? 1 : 0)
                }
            ScrollArea(scrolled: $listScrolled) { list }
        }
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
        .environment(\.buddyAct, act)
        .onChange(of: ids, initial: true) { _, ids in buddyIDs = ids }
        .task(id: paused) { await pickMoves() }
    }

    /// Every buddy on the page, by account.
    private var ids: [String] {
        (state.current.map { [$0.id] } ?? []) + state.others.map(\.id)
    }

    /// Now and then one buddy, picked at random, makes a move of its own, in keeping with how awake it is.
    private func pickMoves() async {
        guard !(reduceMotion || drawsStill || paused) else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled, let id = buddyIDs.randomElement() else { continue }
            act = BuddyAct(id: id, pick: Int.random(in: 0..<4), started: Date())
        }
    }

    /// The header, the current account, the card under it and the add button: they stay while the list scrolls.
    private func top(_ palette: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            header(palette)
            if let current = state.current {
                CurrentAccountCard(card: current, actions: actions, locked: state.interactionLocked)
            }
            switch state.recommendation {
            case .card(let recommended):
                RecommendedCard(state: recommended, actions: actions, locked: state.interactionLocked)
            case .note(let text):
                SlotText(text: text, role: .section, color: palette.textSecondary)
            case nil:
                EmptyView()
            }
            AddAccountButton(enabled: state.canAddAccount) {
                guard state.canAddAccount else { return }
                actions.addAccount()
            }
        }
        .environment(\.quotaRefresh, state.header.refresh)
        .padding([.horizontal, .top], Metrics.panelPadding)
        .padding(.bottom, Metrics.listGap)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
    }

    /// The other accounts, two to a row; a new one pops in. With none, an empty seat says why to add one.
    private var list: some View {
        Group {
            if state.others.isEmpty {
                EmptySeat()
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: Metrics.gridGap) {
                    ForEach(state.others) { card in
                        AccountTile(card: card, actions: actions, locked: state.interactionLocked)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    }
                }
                .motion(Motion.pop, value: state.others.map(\.id))
            }
        }
        .environment(\.quotaRefresh, state.header.refresh)
        .padding([.horizontal, .bottom], Metrics.panelPadding)
        .padding(.top, Metrics.listGap)
        .frame(width: Metrics.panelWidth, alignment: .topLeading)
    }

    /// The wordmark in the middle, the refresh arrow and the gear on the right, and a space as wide as
    /// them on the left so the wordmark stays centred.
    private func header(_ palette: ThemePalette) -> some View {
        let refresh = L10nKey.refreshQuota.string(in: language)
        let settings = L10nKey.settings.string(in: language)
        return HStack(spacing: Metrics.inlineGap) {
            Color.clear.frame(width: Metrics.headerButtonsWidth, height: 1)
            Wordmark(title: state.header.title)
                .frame(maxWidth: .infinity)
            HStack(spacing: Metrics.tightSpacing) {
                Button(action: actions.refreshAllQuotas) {
                    CartoonRefresh(phase: state.header.refresh)
                }
                .buttonStyle(CartoonButtonStyle(hoverTurn: 60, pressTurn: 120))
                .disabled(!state.header.canRefresh)
                .help(refresh)
                .accessibilityLabel(refresh)
                .accessibilityValue(state.header.refresh == .refreshing ? L10nKey.quotaRefreshing.string(in: language) : "")
                Button(action: actions.openSettings) {
                    CartoonGear()
                }
                .buttonStyle(CartoonButtonStyle(hoverTurn: 90, pressTurn: 180))
                .help(settings)
                .accessibilityLabel(settings)
            }
        }
        .frame(height: Metrics.headerHeight)
    }
}

/// Stacks the part above the account list (first) on the list (second), within `limit`: the top keeps its
/// height and the list gets the rest, scrolling past it. A top so tall that it would leave the list less than
/// `minimumList` gives up height instead and scrolls in its own place.
struct PinnedTopLayout: Layout {
    var limit: CGFloat
    var minimumList: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Metrics.panelWidth
        let heights = split(width: width, subviews: subviews)
        return CGSize(width: width, height: heights.top + heights.list)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = split(width: bounds.width, subviews: subviews)
        guard subviews.count == 2 else { return }
        subviews[0].place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: heights.top)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + heights.top),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: heights.list)
        )
    }

    func split(width: CGFloat, subviews: Subviews) -> (top: CGFloat, list: CGFloat) {
        guard subviews.count == 2 else { return (0, 0) }
        let natural = ProposedViewSize(width: width, height: nil)
        return Self.split(
            top: subviews[0].sizeThatFits(natural).height,
            list: subviews[1].sizeThatFits(natural).height,
            limit: limit,
            minimumList: minimumList
        )
    }

    /// The arithmetic on its own, for the tests: the heights each part asks for, and what each gets.
    static func split(top: CGFloat, list: CGFloat, limit: CGFloat, minimumList: CGFloat) -> (top: CGFloat, list: CGFloat) {
        let shownTop = min(top, max(0, limit - min(list, minimumList)))
        return (shownTop, min(list, max(0, limit - shownTop)))
    }
}
