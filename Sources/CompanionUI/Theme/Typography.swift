import AppKit
import SwiftUI

enum TypeWeight: Equatable {
    case regular
    case medium
    case semibold
    case bold

    var fontWeight: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        }
    }
}

enum Typography {
    static func title() -> Font { font(size: Metrics.fontTitle, weight: .medium, monospacedDigits: false) }
    static func tileName() -> Font { font(size: Metrics.fontTileName, weight: .medium, monospacedDigits: false) }
    static func caption() -> Font { font(size: Metrics.fontCaption, weight: .regular, monospacedDigits: false) }

    static func font(size: CGFloat, weight: TypeWeight, monospacedDigits: Bool) -> Font {
        let base = Font.system(size: size, weight: weight.fontWeight)
        return monospacedDigits ? base.monospacedDigit() : base
    }
}

/// Where a string is drawn. Widths come from `Metrics` so the text-fit test and
/// the views measure the same slot.
enum TextRole: Equatable {
    case headerTitle
    case section
    case badge
    case heroName
    case tileName
    case identity
    case resetLine
    case quotaTitle
    case banner
    case button
    case settingsLabel
    case stepLabel
    case statusLine
    /// Why the card under the current account is there, on its last line.
    case reason
    case tooltip
    case version
    /// A confirmation in the middle of the panel.
    case hud
    /// The settings page: a group's heading, a choice in a segmented control, the line under a switch,
    /// the compaction status, a small tag beside a label, the quit row and the note under it.
    case settingsSection
    case segment
    case plainSegment
    case settingsDetail
    case settingsStatus
    case dangerLabel
    case settingsNote
    /// A dialog in the middle of the panel: its title, its words, a hint in small grey, and a step of a
    /// switch.
    case dialogTitle
    case dialogBody
    case dialogHint
    case stepRow
    /// A card's menu: the account's name over it, an item, and the note under one that can't be picked.
    case menuTitle
    case menuItem
    case menuNote
    /// The dashed seat in the list when there is no other account, and the add button's words.
    case seatTitle
    case seatBody
    case addPill
    /// The settings page's title and its back button's word, in brown-outlined lettering like the
    /// wordmark's.
    case artTitle
    case artBack

    var size: CGFloat {
        switch self {
        case .headerTitle: Metrics.fontWordmark
        case .artTitle: Metrics.fontPageTitle
        case .dialogTitle: Metrics.fontTitle
        case .menuItem, .seatTitle: Metrics.fontHUD
        case .artBack: Metrics.fontTileName
        case .dialogBody, .stepRow, .addPill: Metrics.fontSecondary
        case .dialogHint, .menuTitle, .menuNote, .seatBody: Metrics.fontCaption
        case .heroName: Metrics.fontTitle
        case .hud, .segment, .plainSegment: Metrics.fontHUD
        case .tileName, .button, .settingsLabel, .dangerLabel: Metrics.fontTileName
        case .settingsNote: Metrics.fontSecondary
        case .settingsSection, .settingsDetail, .settingsStatus: Metrics.fontCaption
        case .section, .identity, .statusLine: Metrics.fontSecondary
        case .badge, .resetLine, .quotaTitle, .banner, .stepLabel, .reason, .tooltip, .version:
            Metrics.fontCaption
        }
    }

    var weight: TypeWeight {
        switch self {
        case .headerTitle, .artTitle, .artBack: .semibold
        case .dialogTitle, .menuItem, .menuTitle, .seatTitle, .addPill: .medium
        case .dialogBody, .dialogHint, .stepRow, .menuNote, .seatBody: .regular
        case .heroName, .tileName, .button, .badge, .quotaTitle, .hud, .settingsSection, .segment, .plainSegment,
             .dangerLabel:
            .medium
        case .settingsDetail, .settingsStatus, .settingsNote:
            .regular
        case .section, .identity, .resetLine, .banner, .settingsLabel, .stepLabel, .statusLine, .reason, .tooltip,
             .version:
            .regular
        }
    }

    var monospacedDigits: Bool {
        switch self {
        case .resetLine, .version: true
        default: false
        }
    }

    /// The settings page's lettering uses the rounded system face, and so does the wordmark where its own
    /// face is missing.
    var rounded: Bool {
        switch self {
        case .headerTitle, .artTitle, .artBack: true
        default: false
        }
    }

    /// Art lettering spreads its letters a little and draws an outline round them, which take room too.
    var tracking: CGFloat {
        switch self {
        case .headerTitle, .artTitle, .artBack: size * 0.08
        default: 0
        }
    }

    var outline: CGFloat {
        switch self {
        case .headerTitle, .artTitle, .artBack: Metrics.artOutline
        default: 0
        }
    }

    var width: CGFloat {
        switch self {
        case .headerTitle: Metrics.headerTitleWidth
        case .section, .tooltip, .version: Metrics.contentWidth
        case .badge: Metrics.badgeTextWidth
        case .heroName: Metrics.heroNameWidth
        case .tileName: Metrics.tileNameWidth
        case .identity: Metrics.heroTextColumnWidth
        case .resetLine: min(Metrics.tileResetTextWidth, Metrics.heroResetTextWidth)
        case .quotaTitle, .stepLabel, .statusLine: Metrics.tileInnerWidth
        case .reason: Metrics.heroInnerWidth
        case .banner: Metrics.bannerTextWidth
        case .button: Metrics.buttonTextWidth
        case .settingsLabel: Metrics.settingsLabelWidth
        case .hud: Metrics.hudTextWidth
        case .settingsSection: Metrics.contentWidth - 2 * Metrics.settingsSectionInset
        case .segment: Metrics.segmentTextWidth
        case .plainSegment: Metrics.segmentTextWidth + Metrics.segmentIcon + 5
        case .settingsDetail, .dangerLabel: Metrics.settingsLabelWidth
        case .settingsStatus: Metrics.settingsLabelWidth - Metrics.statusDot - Metrics.inlineGap
        case .settingsNote: Metrics.settingsNoteWidth
        case .dialogTitle, .dialogBody, .dialogHint: Metrics.dialogTextWidth
        case .stepRow: Metrics.dialogTextWidth - 24
        case .menuTitle: Metrics.menuWidth - 2 * 5 - 2 * 8
        case .menuItem, .menuNote: Metrics.menuTextWidth
        case .seatTitle, .seatBody: Metrics.seatTextWidth
        case .addPill: Metrics.contentWidth / 2
        case .artTitle: Metrics.pageTitleWidth
        case .artBack: Metrics.backLabelWidth
        }
    }

    /// Names and emails truncate instead of wrapping.
    var truncates: Bool {
        switch self {
        case .heroName, .tileName, .identity: true
        default: false
        }
    }

    /// Banners, dialog titles and words, and the lines under settings are pre-broken on "\n". Each piece
    /// is one sentence that fits the slot, so SwiftUI never has to wrap or ellipsize it; one that names an
    /// account may still wrap.
    var isParagraph: Bool {
        switch self {
        case .banner, .settingsDetail, .settingsNote, .dialogTitle, .dialogBody, .seatBody: true
        default: false
        }
    }

    /// The wordmark's own face: bubble letters the app carries in its Resources/Fonts, activated at launch.
    var bundledFace: String? {
        switch self {
        case .headerTitle: "DynaPuff-Bold"
        default: nil
        }
    }

    var font: Font {
        if let face = bundledFace, NSFont(name: face, size: size) != nil {
            return .custom(face, fixedSize: size)
        }
        if rounded {
            return .system(size: size, weight: weight.fontWeight, design: .rounded)
        }
        return Typography.font(size: size, weight: weight, monospacedDigits: monospacedDigits)
    }
}

enum TextChrome {
    static let lineLimit = 1
    static let tailTruncation = Text.TruncationMode.tail
}

/// Result copy is either the hero's result line (beside the dismiss mark) or a banner.
enum ResultLayout {
    static var heroTextWidth: CGFloat {
        Metrics.heroInnerWidth - Metrics.tightSpacing - SingleLineLayout.symbolWidth(
            "xmark",
            size: Metrics.fontCaption,
            weight: .medium
        )
    }

    static func fitsHero(_ text: String) -> Bool {
        fits(text, role: .statusLine, width: heroTextWidth)
    }

    static func fitsBanner(_ text: String) -> Bool {
        fits(text, role: .banner, width: Metrics.bannerTextWidth)
    }

    private static func fits(_ text: String, role: TextRole, width: CGFloat) -> Bool {
        text.components(separatedBy: "\n").allSatisfy { line in
            !line.isEmpty && SingleLineLayout.width(of: line, role: role) <= width + 0.01
        }
    }
}

enum SingleLineLayout {
    static func width(of text: String, role: TextRole) -> CGFloat {
        if let face = role.bundledFace, let font = NSFont(name: face, size: role.size) {
            return lettered(text, in: font, role: role)
        }
        if role.rounded {
            let base = NSFont.systemFont(ofSize: role.size, weight: role.weight.nsWeight)
            let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: role.size) } ?? base
            return lettered(text, in: font, role: role)
        }
        return width(of: text, size: role.size, weight: role.weight, monospacedDigits: role.monospacedDigits)
    }

    /// Lettering's width: the letters with their spacing, and the outline on both sides.
    private static func lettered(_ text: String, in font: NSFont, role: TextRole) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font, .kern: role.tracking]).width + 2 * role.outline
    }

    static func symbolWidth(_ name: String, size: CGFloat, weight: TypeWeight) -> CGFloat {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight.nsWeight)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else {
            return size
        }
        return image.size.width
    }

    static func width(of text: String, size: CGFloat, weight: TypeWeight, monospacedDigits: Bool) -> CGFloat {
        let font = nsFont(size: size, weight: weight, monospacedDigits: monospacedDigits)
        return (text as NSString).size(withAttributes: [.font: font]).width
    }

    static func nsFont(size: CGFloat, weight: TypeWeight, monospacedDigits: Bool) -> NSFont {
        if monospacedDigits {
            return NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight.nsWeight)
        }
        return NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
    }
}

struct SlotText: View {
    let text: String
    let role: TextRole
    let color: Color
    /// A paragraph's lines start at the left, or sit in the middle.
    var centred = false

    var body: some View {
        if role.isParagraph {
            Text(text)
                .font(role.font)
                .foregroundStyle(color)
                .lineSpacing(Metrics.lineSpacing)
                .multilineTextAlignment(centred ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
        } else {
            Text(text)
                .font(role.font)
                .lineLimit(TextChrome.lineLimit)
                .truncationMode(TextChrome.tailTruncation)
                .foregroundStyle(color)
        }
    }
}
