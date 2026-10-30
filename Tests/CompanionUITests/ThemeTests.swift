import AppKit
import SwiftUI
import XCTest
@testable import CompanionUI

final class ThemeTests: XCTestCase {
    func testPaletteMatchesContractHexes() {
        assertPalette(.light, panel: PaletteHex.lightPanel, card: PaletteHex.lightCard, text: PaletteHex.lightTextPrimary, clay: PaletteHex.accentClay)
        assertPalette(.dark, panel: PaletteHex.darkPanel, card: PaletteHex.darkCard, text: PaletteHex.darkTextPrimary, clay: PaletteHex.accentClay)
        let light = Theme.palette(for: .light)
        let dark = Theme.palette(for: .dark)
        XCTAssertNotEqual(light.panel, dark.panel)
        assertHex(light.quotaOK, PaletteHex.lightQuotaOK)
        assertHex(dark.quotaLow, PaletteHex.darkQuotaLow)
        assertHex(light.accentText, PaletteHex.lightAccentText)
        assertHex(dark.accentText, PaletteHex.darkAccentText)
        assertHex(light.quotaLowText, PaletteHex.lightQuotaLowText)
        assertHex(dark.quotaOKText, PaletteHex.darkQuotaOKText)
    }

    func testQuotaLevelsAreGreenBlueYellowRedAndTheirTextReads() {
        for scheme in [ColorScheme.light, .dark] {
            let palette = Theme.palette(for: scheme)
            XCTAssertEqual(hue(palette.quotaColor(.ok)), 100, accuracy: 25, "\(scheme)")
            XCTAssertEqual(hue(palette.quotaColor(.fair)), 213, accuracy: 15, "\(scheme)")
            XCTAssertEqual(hue(palette.quotaColor(.mid)), 47, accuracy: 10, "\(scheme)")
            XCTAssertLessThan(hue(palette.quotaColor(.low)), 15, "\(scheme)")
            for background in [palette.panel, palette.card] {
                for level in QuotaLevel.allCases {
                    XCTAssertGreaterThanOrEqual(contrast(palette.quotaTextColor(level), background), 4.5, "\(scheme) \(level)")
                }
            }
        }
        for fill in [Theme.primaryButton, Theme.dangerButton] {
            XCTAssertGreaterThanOrEqual(contrast(Theme.onButton, fill), 4.5)
        }
    }

    func testPlanLabelsAndBuddiesHaveTheirColours() {
        // Every label flows like the rainbow, each in its own colours: violets, game-card gold, teal.
        assertHex(Theme.plan(.pro).stops[1], 0x9B4DFF)
        assertHex(Theme.plan(.max).stops[2], 0xFFE066)
        assertHex(Theme.plan(.other).stops[1], 0x19C6B0)
        assertHex(Theme.plan(.max20).stops[4], 0x22B8F0)
        for tier in [PlanTier.pro, .max, .max20, .other] {
            let stops = Theme.plan(tier).stops
            XCTAssertEqual(stops.count, 8, "\(tier)")
            // Each strip ends where the next begins, so the flow has no seam.
            XCTAssertEqual(stops.first, stops.last, "\(tier)")
            assertHex(Theme.plan(tier).text, 0xFFFFFF)
        }
        XCTAssertEqual(Set([PlanTier.pro, .max, .max20, .other].map { Theme.plan($0).glow }).count, 4)
        let light = Theme.palette(for: .light)
        let dark = Theme.palette(for: .dark)
        assertHex(light.recommendText, PaletteHex.lightRecommendText)
        assertHex(dark.recommendText, PaletteHex.darkRecommendText)
        assertHex(Theme.buddy(.ok).skin, 0xC4E3A8)
        assertHex(Theme.buddy(.fair).skin, 0xBFD8F6)
        assertHex(Theme.buddy(.mid).skin, 0xF8DA86)
        assertHex(Theme.buddy(.low).skin, 0xF6B7AA)
        assertHex(Theme.buddy(.empty).skin, 0xE4E2DD)
        XCTAssertEqual(Set(BuddyColor.allCases.map { Theme.buddy($0).skin }).count, BuddyColor.allCases.count)
    }

    func testPlanShineWaitsThenSweeps() {
        let turn = ShineSchedule.turn
        let start = Date(timeIntervalSinceReferenceDate: 0)
        XCTAssertEqual(ShineSchedule.lead(at: start), -0.7, accuracy: 0.0001)
        XCTAssertEqual(ShineSchedule.lead(at: start + turn * 0.6), -0.7, accuracy: 0.0001)
        XCTAssertEqual(ShineSchedule.lead(at: start + turn * 0.81), 0.35, accuracy: 0.01)
        XCTAssertEqual(ShineSchedule.lead(at: start + turn * 0.9999), 1.4, accuracy: 0.01)
        // While the light waits, the next frame is the start of its sweep; while it sweeps, a frame apart.
        var entries = ShineSchedule().entries(from: start, mode: .normal).makeIterator()
        XCTAssertEqual(entries.next(), start)
        let sweep = try! XCTUnwrap(entries.next())
        XCTAssertEqual(sweep.timeIntervalSince(start), turn * ShineSchedule.rest, accuracy: 0.0001)
        let following = try! XCTUnwrap(entries.next())
        XCTAssertEqual(following.timeIntervalSince(sweep), ShineSchedule.frame, accuracy: 0.0001)
    }

    func testMetricsDeriveThePanelSlots() {
        XCTAssertEqual(Metrics.panelWidth, 360)
        XCTAssertEqual(Metrics.contentWidth, 332)
        XCTAssertEqual(Metrics.heroInnerWidth, 304)
        XCTAssertEqual(Metrics.columnWidth, 162)
        XCTAssertEqual(Metrics.tileInnerWidth, 138)
        XCTAssertEqual(Metrics.fontTitle, 15)
        XCTAssertEqual(Metrics.fontTileName, 14)
        XCTAssertEqual(Metrics.fontSecondary, 12)
        XCTAssertEqual(Metrics.fontCaption, 11)
        XCTAssertEqual(Metrics.barHeight, 5)
        XCTAssertLessThan(Metrics.tileResetTextWidth, Metrics.heroResetTextWidth)
    }

    private func assertPalette(_ scheme: ColorScheme, panel: UInt32, card: UInt32, text: UInt32, clay: UInt32) {
        let palette = Theme.palette(for: scheme)
        assertHex(palette.panel, panel)
        assertHex(palette.card, card)
        assertHex(palette.textPrimary, text)
        assertHex(palette.accentClay, clay)
    }

    private func contrast(_ a: Color, _ b: Color) -> Double {
        func luminance(_ color: Color) -> Double {
            let ns = NSColor(color).usingColorSpace(.sRGB)!
            func channel(_ value: CGFloat) -> Double {
                let v = Double(value)
                return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(ns.redComponent) + 0.7152 * channel(ns.greenComponent) + 0.0722 * channel(ns.blueComponent)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Degrees around the colour wheel: red near 0, yellow near 50, green near 100, blue near 215.
    private func hue(_ color: Color) -> Double {
        Double(NSColor(color).usingColorSpace(.sRGB)!.hueComponent) * 360
    }

    private func assertHex(_ color: Color, _ hex: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        let ns = NSColor(color).usingColorSpace(.sRGB)
        XCTAssertNotNil(ns, file: file, line: line)
        guard let ns else { return }
        XCTAssertEqual(ns.redComponent, Double((hex >> 16) & 0xFF) / 255, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(ns.greenComponent, Double((hex >> 8) & 0xFF) / 255, accuracy: 0.002, file: file, line: line)
        XCTAssertEqual(ns.blueComponent, Double(hex & 0xFF) / 255, accuracy: 0.002, file: file, line: line)
    }
}
