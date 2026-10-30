import CoreGraphics
import SwiftUI

/// Every layout constant for the 360 pt panel. Text-fit slots are derived from these.
public enum Metrics {
    public static let panelWidth: CGFloat = 360
    public static let panelPadding: CGFloat = 14
    public static let cardCornerRadius: CGFloat = 14
    public static let panelCornerRadius: CGFloat = 16
    public static let gridGap: CGFloat = 8
    public static let heroPadding: CGFloat = 14
    public static let tilePadding: CGFloat = 12
    /// The buddy is square: these are its sides on the big cards and on the tiles.
    public static let heroAvatar: CGFloat = 36
    public static let tileAvatar: CGFloat = 24
    /// And in the menu bar, as tall as the icons beside it.
    public static let menuBarAvatar: CGFloat = 18
    /// The account page stops here, or sooner where the screen does; past it the account list scrolls.
    public static let panelMaxHeight: CGFloat = 720
    /// The least of the account list the page keeps in view when the part above it is tall.
    public static let minimumListHeight: CGFloat = 160
    /// Between the part that stays in place and the account list scrolling under it.
    public static let listGap: CGFloat = 8
    public static let recommendBorderOpacity: Double = 0.6
    /// "CC-Relay" at the top of the panel; its bubble face's capitals stand as tall as the system face's at 21.
    public static let fontWordmark: CGFloat = 20
    public static let fontTitle: CGFloat = 15
    public static let fontHUD: CGFloat = 13
    public static let fontPageTitle: CGFloat = 18
    public static let fontTileName: CGFloat = 14
    public static let fontSecondary: CGFloat = 12
    public static let fontCaption: CGFloat = 11
    public static let barHeight: CGFloat = 5
    public static let minimumBarFraction: CGFloat = 0.02
    public static let lineSpacing: CGFloat = 3
    public static let stackSpacing: CGFloat = 8
    public static let sectionSpacing: CGFloat = 12
    public static let tightSpacing: CGFloat = 4
    public static let inlineGap: CGFloat = 6
    public static let avatarTextGap: CGFloat = 8
    public static let borderWidth: CGFloat = 1
    public static let clayBorderOpacity: Double = 0.55
    public static let settingsButtonSide: CGFloat = 28
    /// The cartoon gear and refresh arrow inside their 28 pt buttons, and the header row's height.
    public static let cartoonIcon: CGFloat = 23
    public static let cartoonBackIcon: CGFloat = 24
    public static let headerHeight: CGFloat = 36
    public static let hudHorizontalPadding: CGFloat = 18
    public static let hudCornerRadius: CGFloat = 16
    public static let hudCheck: CGFloat = 30
    public static let dialogCornerRadius: CGFloat = 18
    public static let dialogIcon: CGFloat = 44
    public static let dialogPadding: CGFloat = 12
    /// The two buddies side by side in the switch's dialog.
    public static let dialogBuddy: CGFloat = 40
    /// A card's menu: its width, the small tile at the start of each item, about how tall it is, and how
    /// near the panel's edges it may come.
    public static let menuWidth: CGFloat = 190
    public static let menuTile: CGFloat = 22
    public static let menuHeightEstimate: CGFloat = 120
    public static let menuEdgeInset: CGFloat = 8
    /// The "⋯" button on a card, shown under the pointer, beside the line under the name.
    public static let moreButtonWidth: CGFloat = 26
    public static let moreButtonHeight: CGFloat = 20
    public static let heroMoreTop: CGFloat = 37
    public static let tileMoreTop: CGFloat = 38
    /// The shorter grey line under a quota's bar while its reading is on its way.
    public static let skeletonLineWidth: CGFloat = 88
    /// The add button's capsule under the cards.
    public static let addPillHeight: CGFloat = 24
    /// The art lettering's outline and the drop under it.
    public static let artOutline: CGFloat = 1.5
    public static let artDrop: CGFloat = 2.6
    public static let refreshSymbol: CGFloat = 11
    public static let resetSymbolGap: CGFloat = 3
    public static let badgeHorizontalPadding: CGFloat = 6
    public static let planPillHorizontalPadding: CGFloat = 6
    public static let planPillVerticalPadding: CGFloat = 1
    public static let bannerPadding: CGFloat = 8
    public static let buttonHorizontalPadding: CGFloat = 10
    public static let buttonVerticalPadding: CGFloat = 7
    public static let switchWidth: CGFloat = 38
    public static let switchHeight: CGFloat = 22
    public static let switchKnob: CGFloat = 18
    /// Settings: a group's card and its rows, the coloured square at a row's start, the back button
    /// and the small gear by the page title.
    public static let settingsCardPadding: CGFloat = 4
    public static let settingsGroupSpacing: CGFloat = 14
    public static let settingsBottomPadding: CGFloat = 18
    public static let settingsRowPadding: CGFloat = 8
    public static let settingsRowGap: CGFloat = 10
    public static let settingsTile: CGFloat = 26
    public static let settingsTileRadius: CGFloat = 8
    public static let settingsRowRadius: CGFloat = 10
    public static let settingsSectionInset: CGFloat = 6
    public static let segmentPadding: CGFloat = 3
    public static let segmentIcon: CGFloat = 13
    public static let statusDot: CGFloat = 6
    public static let backButtonWidth: CGFloat = 72
    public static let pageGear: CGFloat = 20
    public static let currentDot: CGFloat = 6
    /// "Max 20×" at bold caption size plus the pill's horizontal padding.
    public static let planPillReserve: CGFloat = 61
    public static let currentBadgeReserve: CGFloat = 72
    public static let maxNameCharacters: Int = 20
    public static let switchStepCount: Int = 4
    public static let dashLength: CGFloat = 4
    public static let dashGap: CGFloat = 3
    public static let overlayOpacity: Double = 0.22
    public static let pressedOpacity: Double = 0.7
    /// A tile under a press gives a little.
    public static let pressedScale: CGFloat = 0.98
    public static let hoverBorderOpacity: Double = 0.45
    public static let bannerTapDelay: TimeInterval = 0.6

    public static var contentWidth: CGFloat { panelWidth - panelPadding * 2 }
    public static var heroInnerWidth: CGFloat { contentWidth - heroPadding * 2 }
    public static var columnWidth: CGFloat { (contentWidth - gridGap) / 2 }
    public static var tileInnerWidth: CGFloat { columnWidth - tilePadding * 2 }
    public static var heroQuotaWidth: CGFloat { (heroInnerWidth - gridGap) / 2 }
    public static var resetTextInset: CGFloat { refreshSymbol + resetSymbolGap }
    public static var tileResetTextWidth: CGFloat { tileInnerWidth - resetTextInset }
    public static var heroResetTextWidth: CGFloat { heroQuotaWidth - resetTextInset }
    public static var bannerTextWidth: CGFloat { contentWidth - bannerPadding * 2 }
    public static var dialogTextWidth: CGFloat { contentWidth - dialogPadding * 2 }
    /// A card's menu item, after its tile and gap, inside the menu's and the item's padding.
    public static var menuTextWidth: CGFloat { menuWidth - 2 * 5 - 2 * 8 - menuTile - 9 }
    /// The empty seat's words, inside its dashed outline.
    public static var seatTextWidth: CGFloat { contentWidth - 2 * 16 }
    /// A full-width dialog answer, less a little air at its ends.
    public static var buttonTextWidth: CGFloat { dialogTextWidth - buttonHorizontalPadding * 2 }
    /// A settings row's words, between its coloured square and its switch.
    public static var settingsLabelWidth: CGFloat {
        contentWidth - 2 * settingsCardPadding - 2 * settingsRowPadding - settingsTile - 2 * settingsRowGap - switchWidth
    }
    /// The quit row's note, from under its words to the card's edge.
    public static var settingsNoteWidth: CGFloat {
        contentWidth - 2 * settingsCardPadding - 2 * settingsRowPadding - settingsTile - settingsRowGap
    }
    /// A third of a segmented control, less an icon, its gap and a little air.
    public static var segmentTextWidth: CGFloat {
        (contentWidth - 2 * stackSpacing - 2 * segmentPadding) / 3 - segmentIcon - 5 - stackSpacing
    }
    public static var pageTitleWidth: CGFloat { contentWidth - 2 * backButtonWidth - pageGear - 7 }
    public static var backLabelWidth: CGFloat { backButtonWidth - cartoonBackIcon - 3 }
    /// The wordmark sits centred between the two header buttons and a spacer as wide as them.
    public static var headerTitleWidth: CGFloat { contentWidth - 2 * headerButtonsWidth - 2 * inlineGap }
    public static var headerButtonsWidth: CGFloat { 2 * settingsButtonSide + tightSpacing }
    public static var hudTextWidth: CGFloat { contentWidth - 2 * hudHorizontalPadding }
    public static var heroTextColumnWidth: CGFloat { heroInnerWidth - heroAvatar - avatarTextGap }
    public static var heroNameWidth: CGFloat {
        heroTextColumnWidth - inlineGap - planPillReserve - inlineGap - currentBadgeReserve
    }
    public static var tileNameWidth: CGFloat {
        tileInnerWidth - tileAvatar - avatarTextGap - inlineGap - planPillReserve
    }
    public static var badgeTextWidth: CGFloat { currentBadgeReserve - badgeHorizontalPadding * 2 }
}
