import SwiftUI

/// The settings page: a back arrow and the title, then groups that rise in one after another. A row
/// with a switch flips it wherever it is clicked.
struct SettingsView: View {
    let settings: SettingsViewState
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.l10nLanguage) private var language
    @State private var askingQuit = false
    @State private var fadingIgnored = FadingRows<IgnoredAccountRow>()

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        VStack(alignment: .leading, spacing: Metrics.settingsGroupSpacing) {
            titleRow(palette)
            group(text(.settingsAppearance), order: 0) {
                SegmentedChoice(
                    options: [
                        (AppearanceChoice.system, text(.appearanceSystem), "desktopcomputer"),
                        (.light, text(.appearanceLight), "sun.max"),
                        (.dark, text(.appearanceDark), "moon"),
                    ],
                    selected: settings.appearance,
                    pick: actions.setAppearance
                )
                .padding(Metrics.stackSpacing)
            }
            group(text(.language), order: 1) {
                SegmentedChoice(
                    options: [
                        (LanguageChoice.system, text(.languageSystem), nil),
                        (.zhHans, text(.languageZhHans), nil),
                        (.en, text(.languageEnglish), nil),
                    ],
                    selected: settings.language,
                    enabled: settings.controlsEnabled,
                    pick: actions.setLanguage
                )
                .padding(Metrics.stackSpacing)
            }
            group(text(.settingsGeneral), order: 2) {
                ToggleRow(
                    tile: PaletteHex.tileLaunch, symbol: "power",
                    title: text(.launchAtLogin), detail: text(.launchAtLoginDetail),
                    isOn: settings.launchAtLogin, enabled: settings.controlsEnabled,
                    set: actions.setLaunchAtLogin
                )
            }
            group(text(.settingsSwitching), order: 3) {
                ToggleRow(
                    tile: PaletteHex.tileConfirm, symbol: "checkmark.circle",
                    title: text(.confirmSwitch), detail: text(.confirmSwitchDetail),
                    isOn: settings.confirmSwitch, enabled: settings.controlsEnabled,
                    set: actions.setConfirmSwitch
                )
                RowSeparator()
                ToggleRow(
                    tile: PaletteHex.tileAutoSwitch, symbol: "bolt",
                    title: text(.autoSwitch), detail: text(.autoSwitchDetail),
                    isOn: settings.autoSwitchOnQuota, enabled: settings.controlsEnabled, set: actions.setAutoSwitch
                )
                RowSeparator()
                ToggleRow(
                    tile: PaletteHex.tileSync, symbol: "arrow.triangle.2.circlepath",
                    title: text(.autoSync), detail: text(.autoSyncDetail),
                    isOn: settings.autoSyncOnSwitch, enabled: settings.controlsEnabled,
                    set: actions.setAutoSync
                )
                if settings.pluginUpdateFailed {
                    RowSeparator()
                    pluginUpdateRow(palette)
                }
            }
            group(text(.settingsCompaction), order: 4) {
                ToggleRow(
                    tile: PaletteHex.tileCompact, symbol: "arrow.down.right.and.arrow.up.left",
                    title: text(.autoCompact), detail: text(.autoCompactDetail),
                    status: (settings.autoCompactStatus, settings.autoCompactTone),
                    isOn: settings.autoCompactOnLowQuota, enabled: settings.controlsEnabled,
                    set: actions.setAutoCompact
                )
            }
            let ignored = fadingIgnored.rows(settings.ignoredAccounts)
            if !ignored.isEmpty {
                group(text(.ignoredAccounts), order: 5) {
                    ForEach(ignored) { row in
                        ignoredRow(row, palette: palette)
                            .fadingRow(row, of: fadingIgnored, current: settings.ignoredAccounts)
                    }
                }
            }
            group(text(.settingsOther), order: 6) {
                LinkRow(
                    tile: PaletteHex.tileBackups, symbol: "folder",
                    title: text(.openBackups), detail: text(.openBackupsDetail),
                    action: actions.openBackups
                )
                RowSeparator()
                quitRow(palette)
            }
            versionButton(palette)
                .frame(maxWidth: .infinity)
                .rises(order: 7)
        }
        .fadesRows(settings.ignoredAccounts, in: $fadingIgnored)
        .padding(.horizontal, Metrics.panelPadding)
        .padding(.top, Metrics.panelPadding)
        .padding(.bottom, Metrics.settingsBottomPadding)
        .frame(width: Metrics.panelWidth, alignment: .leading)
    }

    private func text(_ key: L10nKey) -> String {
        key.string(in: language)
    }

    /// The back arrow on the left, the gear and title in the middle, and a space as wide as the back
    /// button on the right so the title stays centred. The title and the back button's word are lettered
    /// like the cartoon icons: the title peach like the gear, the word lavender like the arrow.
    private func titleRow(_ palette: ThemePalette) -> some View {
        HStack(spacing: 0) {
            Button(action: actions.closeSettings) {
                ArtLettering(text: text(.back), role: .artBack, fill: Color(hex: PaletteHex.cartoonBack))
            }
            .buttonStyle(BackButtonStyle())
            .frame(width: Metrics.backButtonWidth, alignment: .leading)
            .accessibilityLabel(text(.back))
            HStack(spacing: 7) {
                CartoonGear(side: Metrics.pageGear)
                    .enters(turn: -150, scale: 0.6, delay: 0)
                ArtLettering(text: text(.settings), role: .artTitle, fill: Color(hex: PaletteHex.cartoonGear))
                    .accessibilityAddTraits(.isHeader)
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: Metrics.backButtonWidth, height: 1)
        }
        .frame(height: Metrics.headerHeight)
    }

    /// A heading over a card, rising in at its turn.
    private func group<Content: View>(_ title: String, order: Int, @ViewBuilder content: () -> Content) -> some View {
        let palette = Theme.palette(for: colorScheme)
        return VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(TextRole.settingsSection.font)
                .lineLimit(TextChrome.lineLimit)
                .foregroundStyle(palette.textTertiary)
                .padding(.horizontal, Metrics.settingsSectionInset)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(Metrics.settingsCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous))
        }
        .rises(order: order)
    }

    private func ignoredRow(_ row: IgnoredAccountRow, palette: ThemePalette) -> some View {
        HStack(spacing: Metrics.settingsRowGap) {
            SettingsTileIcon(colors: PaletteHex.tileAccount, symbol: "person")
            Text(row.name)
                .font(TextRole.settingsLabel.font)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                actions.addIgnoredAccount(row.id)
            } label: {
                Text(text(.addBack))
                    .font(TextRole.button.font)
                    .lineLimit(TextChrome.lineLimit)
                    .foregroundStyle(palette.accentText)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
            .fixedSize()
            .disabled(!settings.controlsEnabled)
        }
        .padding(Metrics.settingsRowPadding)
    }

    /// Shown only when the plugin's own update failed: what happened, and a retry.
    private func pluginUpdateRow(_ palette: ThemePalette) -> some View {
        HStack(spacing: Metrics.settingsRowGap) {
            SettingsTileIcon(colors: PaletteHex.tileCompact, symbol: "puzzlepiece.extension")
            Text(text(.pluginUpdateFailed))
                .font(TextRole.settingsLabel.font)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(palette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: actions.retryPluginUpdate) {
                Text(text(.retry))
                    .font(TextRole.button.font)
                    .lineLimit(TextChrome.lineLimit)
                    .foregroundStyle(palette.accentText)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressButtonStyle())
            .fixedSize()
            .disabled(!settings.controlsEnabled)
        }
        .padding(Metrics.settingsRowPadding)
    }

    /// Quit asks first, under its row: what stops once CC-Relay is gone, and the two answers.
    private func quitRow(_ palette: ThemePalette) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                askingQuit.toggle()
            } label: {
                HStack(spacing: Metrics.settingsRowGap) {
                    SettingsTileIcon(colors: PaletteHex.tileQuit, symbol: "rectangle.portrait.and.arrow.right")
                    Text(text(.quitApp))
                        .font(TextRole.dangerLabel.font)
                        .lineLimit(TextChrome.lineLimit)
                        .foregroundStyle(palette.quotaLowText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(Metrics.settingsRowPadding)
                .contentShape(RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous))
            }
            .buttonStyle(RowButtonStyle())
            if askingQuit {
                VStack(alignment: .leading, spacing: Metrics.stackSpacing) {
                    SlotText(text: text(.quitConfirmBody), role: .settingsNote, color: palette.textSecondary)
                    HStack(spacing: Metrics.stackSpacing) {
                        Spacer(minLength: 0)
                        Button {
                            askingQuit = false
                        } label: {
                            Text(text(.cancel))
                                .font(TextRole.button.font)
                                .lineLimit(TextChrome.lineLimit)
                                .foregroundStyle(palette.textSecondary)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressButtonStyle())
                        Button(action: actions.quit) {
                            Text(text(.quitConfirm))
                                .font(TextRole.button.font)
                                .lineLimit(TextChrome.lineLimit)
                                .foregroundStyle(Theme.onButton)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 12)
                                .background(Theme.dangerButton, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(PressButtonStyle())
                    }
                }
                .padding(.leading, Metrics.settingsRowPadding + Metrics.settingsTile + Metrics.settingsRowGap)
                .padding([.trailing, .bottom], Metrics.settingsRowPadding)
                .padding(.top, Metrics.tightSpacing)
                .transition(.opacity.combined(with: .offset(y: -6)))
            }
        }
        .motion(Motion.fade, value: askingQuit)
    }

    /// The version line; a click copies it.
    private func versionButton(_ palette: ThemePalette) -> some View {
        Button(action: actions.copyVersion) {
            Text(L10nKey.version.string(in: language, parameters: ["version": settings.version]))
                .font(TextRole.version.font)
                .lineLimit(TextChrome.lineLimit)
                .foregroundStyle(palette.textTertiary)
                .padding(.vertical, 2)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressButtonStyle())
    }
}

/// A row with a coloured square, its words and a switch. The whole row flips the switch.
private struct ToggleRow: View {
    let tile: (UInt32, UInt32)
    let symbol: String
    let title: String
    let detail: String
    var status: (text: String, tone: CompactStatusTone)?
    let isOn: Bool
    let enabled: Bool
    let set: (Bool) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        Button {
            set(!isOn)
        } label: {
            HStack(spacing: Metrics.settingsRowGap) {
                SettingsTileIcon(colors: tile, symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TextRole.settingsLabel.font)
                        .lineLimit(TextChrome.lineLimit)
                        .foregroundStyle(palette.textPrimary)
                    SlotText(text: detail, role: .settingsDetail, color: palette.textSecondary)
                    if let status {
                        CompactStatusLine(text: status.text, tone: status.tone)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SwitchKnob(isOn: isOn)
                    .opacity(enabled ? 1 : 0.5)
            }
            .padding(Metrics.settingsRowPadding)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous))
        }
        .buttonStyle(RowButtonStyle())
        .disabled(!enabled)
        // On the button itself, which keeps its press for VoiceOver.
        .accessibilityLabel(title)
        .accessibilityHint(detail.replacingOccurrences(of: "\n", with: ""))
        .accessibilityValue(isOn ? "1" : "0")
        .accessibilityAddTraits(.isToggle)
    }
}

/// A row that opens something: a coloured square, its words and an arrow that nudges on hover.
private struct LinkRow: View {
    let tile: (UInt32, UInt32)
    let symbol: String
    let title: String
    let detail: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        Button(action: action) {
            HStack(spacing: Metrics.settingsRowGap) {
                SettingsTileIcon(colors: tile, symbol: symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TextRole.settingsLabel.font)
                        .lineLimit(TextChrome.lineLimit)
                        .foregroundStyle(palette.textPrimary)
                    SlotText(text: detail, role: .settingsDetail, color: palette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Chevron()
            }
            .padding(Metrics.settingsRowPadding)
            .contentShape(RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous))
        }
        .buttonStyle(RowButtonStyle())
    }
}

private struct Chevron: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rowHovered) private var hovered

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: Metrics.fontCaption, weight: .semibold))
            .foregroundStyle(Theme.palette(for: colorScheme).textTertiary)
            .offset(x: hovered ? 3 : 0)
            .motion(Motion.touch, value: hovered)
    }
}

/// A rounded square in a pastel with a line symbol in its ink.
private struct SettingsTileIcon: View {
    let colors: (UInt32, UInt32)
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hex: colors.1))
            .frame(width: Metrics.settingsTile, height: Metrics.settingsTile)
            .background(Color(hex: colors.0), in: RoundedRectangle(cornerRadius: Metrics.settingsTileRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A hairline between two rows of a card, from under the words to the card's edge.
private struct RowSeparator: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Theme.palette(for: colorScheme).hairline
            .frame(height: Metrics.borderWidth)
            .padding(.leading, Metrics.settingsRowPadding + Metrics.settingsTile + Metrics.settingsRowGap)
            .padding(.trailing, Metrics.settingsRowPadding)
    }
}

/// A row's own hover and press: a faint grey behind it, a little darker under a press. It also tells
/// the row's switch and arrow that the row is pressed or hovered.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    var body: some View {
        let pressed = isEnabled && configuration.isPressed
        let shade = pressed ? 0.15 : (isEnabled && hovering ? 0.08 : 0)
        configuration.label
            .environment(\.rowPressed, pressed)
            .environment(\.rowHovered, isEnabled && hovering)
            .background(
                Color.gray.opacity(shade),
                in: RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous)
            )
            .motion(Motion.touch, value: shade)
            .onHover { hovering = $0 }
    }
}

/// A switch drawn in SwiftUI, so a picture does not depend on the AppKit control (which ImageRenderer
/// replaces with a missing-symbol placeholder). Its knob springs across and stretches under a press.
private struct SwitchKnob: View {
    let isOn: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.rowPressed) private var pressed

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let travel = Metrics.switchWidth - Metrics.switchKnob - 4
        ZStack(alignment: .leading) {
            Capsule()
                .fill(isOn ? palette.accentClay : palette.barTrack)
                .motion(Motion.fade, value: isOn)
            Circle()
                .fill(.white)
                .shadow(color: .black.opacity(0.25), radius: 1, y: 1)
                .frame(width: Metrics.switchKnob, height: Metrics.switchKnob)
                .scaleEffect(x: pressed ? 1.25 : 1, anchor: isOn ? .trailing : .leading)
                .motion(Motion.touch, value: pressed)
                .offset(x: 2 + (isOn ? travel : 0))
                .motion(Motion.knob, value: isOn)
        }
        .frame(width: Metrics.switchWidth, height: Metrics.switchHeight)
    }
}

/// Three choices on a track, the chosen one on a raised card that slides to it.
private struct SegmentedChoice<Choice: Hashable>: View {
    let options: [(choice: Choice, title: String, symbol: String?)]
    let selected: Choice
    var enabled = true
    let pick: (Choice) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let index = options.firstIndex { $0.choice == selected } ?? 0
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { position in
                let option = options[position]
                let chosen = position == index
                Button {
                    pick(option.choice)
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol)
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: Metrics.segmentIcon)
                        }
                        Text(option.title)
                            .font((option.symbol == nil ? TextRole.plainSegment : .segment).font)
                            .fontWeight(chosen ? .medium : .regular)
                            .lineLimit(TextChrome.lineLimit)
                    }
                    .foregroundStyle(chosen ? palette.textPrimary : palette.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressButtonStyle())
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(Metrics.segmentPadding)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                let width = (proxy.size.width - 2 * Metrics.segmentPadding) / CGFloat(max(1, options.count))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(palette.card)
                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                    .frame(width: width, height: max(0, proxy.size.height - 2 * Metrics.segmentPadding))
                    .offset(x: Metrics.segmentPadding + width * CGFloat(index), y: Metrics.segmentPadding)
                    .motion(Motion.segment, value: index)
            }
        }
        .background(palette.barTrack, in: RoundedRectangle(cornerRadius: Metrics.settingsRowRadius, style: .continuous))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// The line under the compaction switch: a dot that breathes while the plugin is connected, yellow when
/// it has not been heard from, grey when compaction is off.
private struct CompactStatusLine: View {
    let text: String
    let tone: CompactStatusTone

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @Environment(\.motionPaused) private var paused

    var body: some View {
        let palette = Theme.palette(for: colorScheme)
        let colors: (dot: Color, text: Color) = switch tone {
        case .live: (palette.quotaOK, palette.quotaOKText)
        case .quiet: (palette.quotaMid, palette.textSecondary)
        case .off: (palette.textTertiary, palette.textTertiary)
        }
        let breathing = tone == .live && !(reduceMotion || drawsStill)
        HStack(spacing: Metrics.inlineGap) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !breathing || paused)) { timeline in
                let ring = breathing ? Self.ring(at: timeline.date) : (spread: 0, opacity: 0)
                Circle()
                    .fill(colors.dot)
                    .frame(width: Metrics.statusDot, height: Metrics.statusDot)
                    .background {
                        Circle()
                            .fill(colors.dot.opacity(ring.opacity))
                            .frame(width: Metrics.statusDot + 2 * ring.spread, height: Metrics.statusDot + 2 * ring.spread)
                    }
            }
            .frame(width: Metrics.statusDot, height: Metrics.statusDot)
            Text(text)
                .font(TextRole.settingsStatus.font)
                .lineLimit(TextChrome.lineLimit)
                .foregroundStyle(colors.text)
        }
        .motion(Motion.fade, value: tone)
    }

    /// A ring that grows to 6 pt around the dot and fades over most of 1.8 s, then waits.
    static func ring(at date: Date) -> (spread: CGFloat, opacity: Double) {
        let turn = 1.8
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn) / turn
        guard phase < 0.7 else { return (0, 0) }
        let grown = phase / 0.7
        return (6 * grown, 0.55 * (1 - grown))
    }
}

/// The back button: the lavender arrow pops in, leans back on hover and darts further under a press.
private struct BackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BackButtonBody(configuration: configuration)
    }
}

private struct BackButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        HStack(spacing: 3) {
            CartoonBack()
                .rotationEffect(.degrees(hovering && !pressed ? -8 : 0))
                .scaleEffect(pressed ? 0.88 : 1)
                .offset(x: pressed ? -7 : (hovering ? -4 : 0))
                .motion(Motion.bounce, value: [pressed, hovering])
                .enters(offset: 12, scale: 0.6, delay: 0.08)
            configuration.label
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct RowPressedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct RowHoveredKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set on a settings row's contents while the row is held down or the pointer is over it.
    fileprivate var rowPressed: Bool {
        get { self[RowPressedKey.self] }
        set { self[RowPressedKey.self] = newValue }
    }

    fileprivate var rowHovered: Bool {
        get { self[RowHoveredKey.self] }
        set { self[RowHoveredKey.self] = newValue }
    }
}

extension View {
    /// Rises 8 pt into place and fades in when the page opens, `order` steps after the first group.
    func rises(order: Int) -> some View {
        modifier(Rises(order: order))
    }

    /// Pops in once from a turn, a size and a sideways offset to where it is.
    func enters(turn: Double = 0, offset: CGFloat = 0, scale: CGFloat, delay: Double) -> some View {
        modifier(Enters(turn: turn, offset: offset, scale: scale, delay: delay))
    }
}

private struct Rises: ViewModifier {
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @State private var risen = false

    func body(content: Content) -> some View {
        let shown = risen || reduceMotion || drawsStill
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 8)
            .onAppear {
                guard !(reduceMotion || drawsStill) else { return }
                withAnimation(Motion.rise.delay(0.03 + Motion.riseStep * Double(order))) { risen = true }
            }
    }
}

private struct Enters: ViewModifier {
    let turn: Double
    let offset: CGFloat
    let scale: CGFloat
    let delay: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.drawsStill) private var drawsStill
    @State private var entered = false

    func body(content: Content) -> some View {
        let shown = entered || reduceMotion || drawsStill
        content
            .rotationEffect(.degrees(shown ? 0 : turn))
            .scaleEffect(shown ? 1 : scale)
            .offset(x: shown ? 0 : offset)
            .opacity(shown ? 1 : 0)
            .onAppear {
                guard !(reduceMotion || drawsStill) else { return }
                withAnimation(Motion.bounce.delay(delay)) { entered = true }
            }
    }
}
