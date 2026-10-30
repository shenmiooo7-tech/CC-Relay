import CompanionCore
import CoreGraphics
import SwiftUI
import XCTest
@testable import CompanionUI

@MainActor
final class MenuBarBuddyTests: XCTestCase {
    func testTheMenuBarShowsTheCurrentAccountsBuddyInItsColour() async throws {
        for (week, color) in [(80.0, BuddyColor.ok), (20.0, .mid)] {
            let (image, face) = try await render(fiveHour: 80, week: week)
            XCTAssertEqual(face.color, color)
            XCTAssertEqual(image.width, Int(Metrics.menuBarAvatar * 4))
            // The forehead, above the eyes (8 of the buddy's 36 units down): its skin, as on the current
            // account's card.
            let skin = Theme.buddyHex(color).skin
            let pixel = rgb(pixels(image), width: image.width, x: image.width / 2, y: image.width * 8 / 36)
            for (shift, value) in zip([16, 8, 0] as [UInt32], [pixel.r, pixel.g, pixel.b]) {
                XCTAssertEqual(Int(value), Int((skin >> shift) & 0xFF), accuracy: 6, "\(color)")
            }
        }
    }

    func testTheMenuBarBuddyIsSquareAtRestWhateverItsMood() async throws {
        // Wide awake it stands taller on its card, asleep lower; in the menu bar it keeps its square.
        for (fiveHour, week, mood) in [(80.0, 80.0, BuddyMood.happy), (80.0, 0.0, .asleep)] {
            let (image, face) = try await render(fiveHour: fiveHour, week: week)
            XCTAssertEqual(face.mood, mood)
            let skin = Theme.buddyHex(face.color).skin
            let data = pixels(image)
            var top = Int.max, bottom = Int.min, left = Int.max, right = Int.min
            for y in 0..<image.height {
                for x in 0..<image.width where close(rgb(data, width: image.width, x: x, y: y), skin) {
                    top = min(top, y); bottom = max(bottom, y); left = min(left, x); right = max(right, x)
                }
            }
            XCTAssertEqual(bottom - top, right - left, accuracy: 2, "\(mood)")
        }
    }

    private func render(fiveHour: Double, week: Double) async throws -> (CGImage, BuddyFace) {
        var snapshot = PanelFixtures.mainSnapshot()
        let index = try XCTUnwrap(snapshot.accounts.firstIndex { $0.folder == snapshot.currentFolder })
        snapshot.accounts[index].quota?.fiveHour.usedPercent = 100 - fiveHour
        snapshot.accounts[index].quota?.sevenDay.usedPercent = 100 - week
        let model = PanelViewModel(facade: FakeCompanionFacade(snapshot: snapshot), clock: ManualClock(now: PanelFixtures.now),
                                   timeZone: PanelFixtures.timeZone, preferredLanguages: ["zh-Hans"])
        let applied = await model.waitUntilApplied()
        XCTAssertTrue(applied)
        let face = try XCTUnwrap(model.state.current?.buddy)
        // Nothing over it and nothing changing: it stands still.
        let renderer = ImageRenderer(content: MenuBarBuddy(model: model, presence: MenuBarPresence())
            .frame(width: Metrics.menuBarAvatar, height: Metrics.menuBarAvatar))
        renderer.scale = 4
        return (try XCTUnwrap(renderer.cgImage), face)
    }

    private func close(_ pixel: (r: UInt8, g: UInt8, b: UInt8), _ hex: UInt32) -> Bool {
        zip([16, 8, 0] as [UInt32], [pixel.r, pixel.g, pixel.b]).allSatisfy { abs(Int($1) - Int((hex >> $0) & 0xFF)) <= 6 }
    }

    /// RGBA, rows from the top.
    private func pixels(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    private func rgb(_ data: [UInt8], width: Int, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let offset = (y * width + x) * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }
}
