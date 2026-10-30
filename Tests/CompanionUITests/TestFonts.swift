import AppKit
import CoreText
@testable import CompanionUI

/// The app activates the fonts in its Resources/Fonts when it starts; tests that draw or measure the
/// wordmark load the repository's copies for this process instead.
enum TestFonts {
    static let folder = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Resources/Fonts", isDirectory: true)

    /// Whether the wordmark's face is ready to draw, after loading the bundled fonts once.
    static let loaded: Bool = {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
        guard let face = TextRole.headerTitle.bundledFace else { return false }
        return NSFont(name: face, size: 12) != nil
    }()
}
