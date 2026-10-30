import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import CompanionUI

final class AppIconArtworkTests: XCTestCase {
    func testIconsetHasEverySizeIconutilExpects() {
        XCTAssertEqual(AppIconArtwork.iconsetFiles.map(\.name), [
            "icon_16x16.png", "icon_16x16@2x.png", "icon_32x32.png", "icon_32x32@2x.png",
            "icon_128x128.png", "icon_128x128@2x.png", "icon_256x256.png", "icon_256x256@2x.png",
            "icon_512x512.png", "icon_512x512@2x.png",
        ])
        XCTAssertEqual(AppIconArtwork.iconsetFiles.map(\.pixels), [16, 32, 32, 64, 128, 256, 256, 512, 512, 1024])
    }

    func testIconIsOpaqueInsideTheTileAndClearInTheCorners() throws {
        let image = try XCTUnwrap(AppIconArtwork.iconImage(pixels: 128))
        let pixels = rgba(image)
        XCTAssertEqual(alpha(pixels, image.width, 64, 64), 255)
        // Outside the rounded tile only the faint edge of its shadow remains, and the shadow falls below it.
        XCTAssertLessThan(alpha(pixels, image.width, 1, 1), 16)
        XCTAssertLessThan(alpha(pixels, image.width, 126, 126), 16)
        XCTAssertGreaterThan(alpha(pixels, image.width, 64, 117), alpha(pixels, image.width, 64, 11))
    }

    func testTheIconShowsATiredBuddyHandingOverToAnAwakeOne() throws {
        let image = try XCTUnwrap(AppIconArtwork.iconImage(pixels: 256))
        let pixels = rgba(image)
        let awake = colour(pixels, image.width, 165, 117)
        XCTAssertGreaterThan(awake.green, awake.red, "the awake buddy, on the right, is green")
        XCTAssertGreaterThan(awake.green, awake.blue, "the awake buddy, on the right, is green")
        let tired = colour(pixels, image.width, 82, 135)
        XCTAssertGreaterThan(tired.red, tired.green, "the tired buddy, on the left, is pink")
        XCTAssertGreaterThan(tired.red, tired.blue, "the tired buddy, on the left, is pink")
    }

    func testWriteIconsetWritesPNGsOfTheListedPixelSizes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("icon-\(UUID().uuidString).iconset")
        defer { try? FileManager.default.removeItem(at: directory) }
        try AppIconArtwork.writeIconset(to: directory)
        for file in AppIconArtwork.iconsetFiles {
            let url = directory.appendingPathComponent(file.name)
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil), file.name)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file.name)
            XCTAssertEqual(image.width, file.pixels, file.name)
            XCTAssertEqual(image.height, file.pixels, file.name)
        }
    }

    private func rgba(_ image: CGImage) -> [UInt8] {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return data
    }

    /// Alpha at column `x`, row `y` counted from the top.
    private func alpha(_ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> UInt8 {
        pixels[(y * width + x) * 4 + 3]
    }

    private func colour(_ pixels: [UInt8], _ width: Int, _ x: Int, _ y: Int) -> (red: UInt8, green: UInt8, blue: UInt8) {
        let i = (y * width + x) * 4
        return (pixels[i], pixels[i + 1], pixels[i + 2])
    }
}
