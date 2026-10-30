import SwiftUI

/// sRGB hexes from the UI contract. Stored as plain values so a palette can be
/// chosen from `ColorScheme` instead of a dynamic `NSColor` (ImageRenderer would
/// otherwise paint dark snapshots with the light appearance).
enum PaletteHex {
    static let lightPanel: UInt32 = 0xFAF9F5
    static let darkPanel: UInt32 = 0x262624
    static let lightCard: UInt32 = 0xFFFFFF
    static let darkCard: UInt32 = 0x30302E
    static let lightHairline: UInt32 = 0xE8E5DA
    static let darkHairline: UInt32 = 0x3D3C38
    static let lightDashed: UInt32 = 0xD6D2C4
    static let darkDashed: UInt32 = 0x55534D
    static let lightTextPrimary: UInt32 = 0x141413
    static let darkTextPrimary: UInt32 = 0xF5F4EE
    static let lightTextSecondary: UInt32 = 0x73726C
    static let darkTextSecondary: UInt32 = 0xA6A39A
    static let lightTextTertiary: UInt32 = 0xA3A198
    static let darkTextTertiary: UInt32 = 0x8A877F
    static let lightBarTrack: UInt32 = 0xEEEBE2
    static let darkBarTrack: UInt32 = 0x45443F
    /// Quota bars: green above 50 % left, blue from 30 %, yellow above 10 %, red at 10 % or less.
    static let lightQuotaOK: UInt32 = 0x5E9E3A
    static let darkQuotaOK: UInt32 = 0x8CC46A
    static let lightQuotaFair: UInt32 = 0x3B7DD8
    static let darkQuotaFair: UInt32 = 0x6CA6EC
    static let lightQuotaMid: UInt32 = 0xE0B030
    static let darkQuotaMid: UInt32 = 0xE6BE45
    static let lightQuotaLow: UInt32 = 0xD64C3A
    static let darkQuotaLow: UInt32 = 0xE7705D
    /// The same four levels as text, dark enough to read at 4.5:1 on the panel and on a card.
    static let lightQuotaOKText: UInt32 = 0x3B6D11
    static let darkQuotaOKText: UInt32 = 0xA3D17F
    static let lightQuotaFairText: UInt32 = 0x1F5FA8
    static let darkQuotaFairText: UInt32 = 0x93C0F2
    static let lightQuotaMidText: UInt32 = 0x8A6100
    static let darkQuotaMidText: UInt32 = 0xECC75E
    static let lightQuotaLowText: UInt32 = 0xBC4A34
    static let darkQuotaLowText: UInt32 = 0xEE8A76
    /// Sheet buttons, the same in both schemes, with white text at 4.5:1 or more.
    static let primaryButton: UInt32 = 0xB5532F
    static let dangerButton: UInt32 = 0xBC4A34
    static let onButton: UInt32 = 0xFFFFFF
    static let accentClay: UInt32 = 0xD97757
    static let lightAccentText: UInt32 = 0xB5532F
    static let darkAccentText: UInt32 = 0xEE9E82

    /// The confirmation card in the middle of the panel: the opposite shade of the panel, and its undo
    /// button, light clay on the dark card and deep clay on the light one.
    static let lightHUD: UInt32 = 0x141413
    static let darkHUD: UInt32 = 0xF5F4EE
    static let lightHUDAction: UInt32 = 0xF2A07F
    static let darkHUDAction: UInt32 = 0xB5532F

    /// The suggested account's marker and reason.
    static let lightRecommendText: UInt32 = 0x56693F
    static let darkRecommendText: UInt32 = 0xB5C79A

    /// Plan labels, like a game's rare cards and the same in both schemes: colours that flow sideways,
    /// left to right, the first repeated at the end so the flow has no seam. Pro dazzling violets, Max a
    /// game's gold card, Max 20× a rainbow, other plans dazzling teal.
    static let planProStops: [UInt32] = [0x6A1FE0, 0x9B4DFF, 0xD6A8FF, 0xB05CFF, 0x7B2FF7, 0xE08CFF, 0x8A3CFF, 0x6A1FE0]
    static let planMaxStops: [UInt32] = [0xE08A00, 0xFFB800, 0xFFE066, 0xFFC21A, 0xF29B00, 0xFFD84D, 0xFFAA00, 0xE08A00]
    static let planOtherStops: [UInt32] = [0x0E9F8E, 0x19C6B0, 0x7EF0DC, 0x22D3B8, 0x0FB5A0, 0x5CE6CF, 0x14BFA6, 0x0E9F8E]
    static let planMax20Stops: [UInt32] = [0xFF4D6D, 0xFF9F43, 0xFFD43B, 0x3DDC84, 0x22B8F0, 0x7C6CFF, 0xE35BF5, 0xFF4D6D]
    static let planText: UInt32 = 0xFFFFFF

    /// The cartoon buttons: one brown outline, each its own fill.
    static let cartoonInk: UInt32 = 0x5A3E2B
    static let cartoonGear: UInt32 = 0xF4C3A4
    static let cartoonRefresh: UInt32 = 0xA9DCCB
    static let cartoonBack: UInt32 = 0xD2C7F4
    /// The wordmark's first part, a deeper peach than the gear; the rest is filled like the refresh arrow.
    static let wordmarkLead: UInt32 = 0xF2A584

    /// The coloured squares at the start of the settings rows, a pastel and the ink of its symbol,
    /// the same in both schemes.
    static let tileLaunch: (UInt32, UInt32) = (0xDCE5CF, 0x3B4A28)
    static let tileSync: (UInt32, UInt32) = (0xDCE8F7, 0x24518C)
    static let tileCompact: (UInt32, UInt32) = (0xE6E1F8, 0x4B3C9E)
    static let tileAutoSwitch: (UInt32, UInt32) = (0xD5EEE9, 0x1D5F57)
    static let tileConfirm: (UInt32, UInt32) = (0xF4DDB0, 0x6B4512)
    static let tileBackups: (UInt32, UInt32) = (0xF5CDB9, 0x5A2E1E)
    static let tileQuit: (UInt32, UInt32) = (0xF8D7D0, 0xA33A26)
    static let tileAccount: (UInt32, UInt32) = (0xE4E2DD, 0x5F5E5A)

    /// Buddy skins by weekly band, a soft version of the bar's colour, and the ink drawn on each. A
    /// character keeps its colours in both schemes.
    static let buddyOkSkin: UInt32 = 0xC4E3A8
    static let buddyOkInk: UInt32 = 0x24400F
    static let buddyFairSkin: UInt32 = 0xBFD8F6
    static let buddyFairInk: UInt32 = 0x173D6B
    static let buddyMidSkin: UInt32 = 0xF8DA86
    static let buddyMidInk: UInt32 = 0x5E3F05
    static let buddyLowSkin: UInt32 = 0xF6B7AA
    static let buddyLowInk: UInt32 = 0x66200F
    static let buddyEmptySkin: UInt32 = 0xE4E2DD
    static let buddyEmptyInk: UInt32 = 0x5F5E5A
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// A plan label, like a game's rare card and the same in both schemes.
public struct PlanStyle: Equatable, Sendable {
    /// Left to right, the colours that flow under the label's gloss; the first repeats at the end.
    public var stops: [Color]
    /// The light edge, the glow around the label and the shadow under its white text.
    public var rim: Color
    public var glow: Color
    public var ink: Color
    public var text: Color

    init(_ stops: [UInt32], rim: Color, glow: Color, ink: Color) {
        self.stops = stops.map(Color.init(hex:))
        self.rim = rim
        self.glow = glow
        self.ink = ink
        self.text = Color(hex: PaletteHex.planText)
    }
}

public struct ThemePalette: Equatable, Sendable {
    public var panel: Color
    public var card: Color
    public var hairline: Color
    public var dashed: Color
    public var textPrimary: Color
    public var textSecondary: Color
    public var textTertiary: Color
    public var barTrack: Color
    public var quotaOK: Color
    public var quotaFair: Color
    public var quotaMid: Color
    public var quotaLow: Color
    public var quotaOKText: Color
    public var quotaFairText: Color
    public var quotaMidText: Color
    public var quotaLowText: Color
    public var accentClay: Color
    public var accentText: Color
    public var recommendText: Color
    public var hudBackground: Color
    public var hudText: Color
    public var hudAction: Color

    public func quotaColor(_ level: QuotaLevel) -> Color {
        switch level {
        case .ok: quotaOK
        case .fair: quotaFair
        case .mid: quotaMid
        case .low: quotaLow
        }
    }

    public func quotaTextColor(_ level: QuotaLevel) -> Color {
        switch level {
        case .ok: quotaOKText
        case .fair: quotaFairText
        case .mid: quotaMidText
        case .low: quotaLowText
        }
    }

    static let light = ThemePalette(
        panel: Color(hex: PaletteHex.lightPanel),
        card: Color(hex: PaletteHex.lightCard),
        hairline: Color(hex: PaletteHex.lightHairline),
        dashed: Color(hex: PaletteHex.lightDashed),
        textPrimary: Color(hex: PaletteHex.lightTextPrimary),
        textSecondary: Color(hex: PaletteHex.lightTextSecondary),
        textTertiary: Color(hex: PaletteHex.lightTextTertiary),
        barTrack: Color(hex: PaletteHex.lightBarTrack),
        quotaOK: Color(hex: PaletteHex.lightQuotaOK),
        quotaFair: Color(hex: PaletteHex.lightQuotaFair),
        quotaMid: Color(hex: PaletteHex.lightQuotaMid),
        quotaLow: Color(hex: PaletteHex.lightQuotaLow),
        quotaOKText: Color(hex: PaletteHex.lightQuotaOKText),
        quotaFairText: Color(hex: PaletteHex.lightQuotaFairText),
        quotaMidText: Color(hex: PaletteHex.lightQuotaMidText),
        quotaLowText: Color(hex: PaletteHex.lightQuotaLowText),
        accentClay: Color(hex: PaletteHex.accentClay),
        accentText: Color(hex: PaletteHex.lightAccentText),
        recommendText: Color(hex: PaletteHex.lightRecommendText),
        hudBackground: Color(hex: PaletteHex.lightHUD).opacity(0.86),
        hudText: Color(hex: PaletteHex.lightPanel),
        hudAction: Color(hex: PaletteHex.lightHUDAction)
    )

    static let dark = ThemePalette(
        panel: Color(hex: PaletteHex.darkPanel),
        card: Color(hex: PaletteHex.darkCard),
        hairline: Color(hex: PaletteHex.darkHairline),
        dashed: Color(hex: PaletteHex.darkDashed),
        textPrimary: Color(hex: PaletteHex.darkTextPrimary),
        textSecondary: Color(hex: PaletteHex.darkTextSecondary),
        textTertiary: Color(hex: PaletteHex.darkTextTertiary),
        barTrack: Color(hex: PaletteHex.darkBarTrack),
        quotaOK: Color(hex: PaletteHex.darkQuotaOK),
        quotaFair: Color(hex: PaletteHex.darkQuotaFair),
        quotaMid: Color(hex: PaletteHex.darkQuotaMid),
        quotaLow: Color(hex: PaletteHex.darkQuotaLow),
        quotaOKText: Color(hex: PaletteHex.darkQuotaOKText),
        quotaFairText: Color(hex: PaletteHex.darkQuotaFairText),
        quotaMidText: Color(hex: PaletteHex.darkQuotaMidText),
        quotaLowText: Color(hex: PaletteHex.darkQuotaLowText),
        accentClay: Color(hex: PaletteHex.accentClay),
        accentText: Color(hex: PaletteHex.darkAccentText),
        recommendText: Color(hex: PaletteHex.darkRecommendText),
        hudBackground: Color(hex: PaletteHex.darkHUD).opacity(0.94),
        hudText: Color(hex: PaletteHex.lightTextPrimary),
        hudAction: Color(hex: PaletteHex.darkHUDAction)
    )
}

public enum Theme {
    /// A sheet's main button, its destructive one, and the text on both.
    public static let primaryButton = Color(hex: PaletteHex.primaryButton)
    public static let dangerButton = Color(hex: PaletteHex.dangerButton)
    public static let onButton = Color(hex: PaletteHex.onButton)

    /// Cream used on top of the clay fill. It is the dark-mode primary text token,
    /// not a separate color.
    public static let onClay = Color(hex: PaletteHex.darkTextPrimary)

    /// Pro violet, Max 5× and a Max of unknown size gold, Max 20× a rainbow, other plans teal.
    public static func plan(_ tier: PlanTier) -> PlanStyle {
        switch tier {
        case .pro:
            PlanStyle(PaletteHex.planProStops,
                      rim: Color(hex: 0xE4D0FF).opacity(0.95), glow: Color(hex: 0x8C50FF).opacity(0.55),
                      ink: Color(hex: 0x370A87).opacity(0.75))
        case .max:
            PlanStyle(PaletteHex.planMaxStops,
                      rim: Color(hex: 0xFFE48C).opacity(0.95), glow: Color(hex: 0xFFAA00).opacity(0.6),
                      ink: Color(hex: 0x783C00).opacity(0.85))
        case .max20:
            PlanStyle(PaletteHex.planMax20Stops,
                      rim: Color.white.opacity(0.75), glow: Color(hex: 0xAA64FF).opacity(0.5),
                      ink: Color(hex: 0x281450).opacity(0.7))
        case .other:
            PlanStyle(PaletteHex.planOtherStops,
                      rim: Color(hex: 0xBEFFF0).opacity(0.95), glow: Color(hex: 0x14C8AA).opacity(0.5),
                      ink: Color(hex: 0x004B41).opacity(0.8))
        }
    }

    /// A buddy's skin and the ink of its face and outline.
    public static func buddy(_ color: BuddyColor) -> (skin: Color, ink: Color) {
        let hex = buddyHex(color)
        return (Color(hex: hex.skin), Color(hex: hex.ink))
    }

    /// The same as hexes, so a change of colour can blend from one to the other.
    static func buddyHex(_ color: BuddyColor) -> (skin: UInt32, ink: UInt32) {
        switch color {
        case .ok: (PaletteHex.buddyOkSkin, PaletteHex.buddyOkInk)
        case .fair: (PaletteHex.buddyFairSkin, PaletteHex.buddyFairInk)
        case .mid: (PaletteHex.buddyMidSkin, PaletteHex.buddyMidInk)
        case .low: (PaletteHex.buddyLowSkin, PaletteHex.buddyLowInk)
        case .empty: (PaletteHex.buddyEmptySkin, PaletteHex.buddyEmptyInk)
        }
    }

    public static func palette(for colorScheme: ColorScheme) -> ThemePalette {
        switch colorScheme {
        case .dark:
            return .dark
        default:
            return .light
        }
    }
}
