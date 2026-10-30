import AppKit
import SwiftUI
import XCTest
import CompanionCore
import QuartzCore
@testable import CompanionUI

@MainActor
final class SnapshotGenerationTests: XCTestCase {
    nonisolated override func setUp() {
        super.setUp()
        XCTAssertTrue(TestFonts.loaded)
    }

    func testRendersABlockedContinuationAndFailureFeedbackInBothLanguagesAndSchemes() async throws {
        let directory = ProcessInfo.processInfo.environment["CC_RELAY_TEST_SNAPSHOTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("cc-relay-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var summary = NativeRecoverySummary(operationID: "preview-recovery")
        summary.attention = 4
        summary.issues = [
            NativeRecoveryIssue(sessionID: "12345678-1234-4234-8234-123456789abc", reason: .runtimeUnavailable),
            NativeRecoveryIssue(sessionID: "23456789-2345-4345-8345-23456789abcd", reason: .blocked),
            NativeRecoveryIssue(sessionID: "3456789a-3456-4456-8456-3456789abcde", reason: .recoveryIncomplete),
            NativeRecoveryIssue(sessionID: "456789ab-4567-4567-8567-456789abcdef", reason: .executionFailed),
        ]
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.banners = [.nativeRecovery(summary)]
        var quotaSnapshot = PanelFixtures.mainSnapshot()
        quotaSnapshot.accounts[1].quota = nil
        quotaSnapshot.accounts[1].quotaFreshness = .unavailable
        quotaSnapshot.accounts[1].quotaFailure = .timedOut
        quotaSnapshot.accounts[2].quotaFreshness = .stale
        quotaSnapshot.accounts[2].quotaFailure = .transportFailed
        quotaSnapshot.accounts[2].quota?.fetchedAt = PanelFixtures.date(2026, 10, 24, 18, 30)
        quotaSnapshot.accounts[2].duplicateOf = quotaSnapshot.accounts[0].folder
        for language in L10nLanguage.allCases {
            let state = try await PanelFixtures.load(snapshot, language: language) { $0.showHUD(.recoveryFailed) }
            let quotaState = try await PanelFixtures.load(quotaSnapshot, language: language)
            XCTAssertEqual(state.shownNotice?.text, L10nKey.nativeRecoveryStateBlocked.string(in: language) + "\n"
                + L10nKey.nativeRecoveryReasonsVary.string(in: language, parameters: ["n": "4"]))
            XCTAssertEqual(state.shownNotice?.actionFeedback, L10nKey.hudRecoveryFailed.string(in: language))
            let notice = try XCTUnwrap(state.shownNotice)
            let cards = Array(quotaState.others.prefix(2))
            XCTAssertEqual(cards.count, 2)
            for scheme in [ColorScheme.light, .dark] {
                let dialog = NoticeDialog(banner: notice, actions: .noop)
                    .padding(Metrics.panelPadding)
                let tiles = HStack(alignment: .top, spacing: Metrics.gridGap) {
                    ForEach(cards) { card in
                        AccountTile(card: card, actions: .noop)
                            .frame(width: Metrics.columnWidth)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Metrics.panelPadding)
                let rendered = [
                    ("native-recovery", try await hostedPNG(dialog, language: language, scheme: scheme)),
                    ("quota-errors", try await hostedPNG(tiles, language: language, scheme: scheme)),
                ]
                for (name, data) in rendered {
                    let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
                    XCTAssertEqual(rep.pixelsWide, Int(Metrics.panelWidth * 2))
                    XCTAssertGreaterThan(rep.pixelsHigh, 200)
                    let schemeName = scheme == .dark ? "dark" : "light"
                    let file = directory.appendingPathComponent("\(name)-\(language.fileToken)-\(schemeName).png")
                    try data.write(to: file, options: .atomic)
                }
            }
        }
        print("Blocked continuation snapshots: \(directory.path)")
    }

    func testRendersTheKeptWatchNoticeInBothLanguagesAndSchemes() async throws {
        let directory = ProcessInfo.processInfo.environment["CC_RELAY_TEST_SNAPSHOTS"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? FileManager.default.temporaryDirectory.appendingPathComponent("cc-relay-watches-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshot = PanelFixtures.mainSnapshot()
        snapshot.banners = [.watchesStayed(account: try ProfileFolder("Claude"), titles: ["Review the launch page", ""])]
        for language in L10nLanguage.allCases {
            let state = try await PanelFixtures.load(snapshot, language: language)
            let notice = try XCTUnwrap(state.shownNotice)
            XCTAssertEqual(notice.details.count, 2)
            for scheme in [ColorScheme.light, .dark] {
                let dialog = NoticeDialog(banner: notice, actions: .noop).padding(Metrics.panelPadding)
                let data = try await hostedPNG(dialog, language: language, scheme: scheme)
                let schemeName = scheme == .dark ? "dark" : "light"
                try data.write(to: directory.appendingPathComponent("watches-stayed-\(language.fileToken)-\(schemeName).png"),
                               options: .atomic)
            }
        }
        print("Kept watch snapshots: \(directory.path)")
    }

    /// ImageRenderer cannot draw the AppKit scroll/text-selection and card-menu views. Host these
    /// particular production components offscreen; the window is never ordered or made key.
    private func hostedPNG(_ view: some View, language: L10nLanguage, scheme: ColorScheme) async throws -> Data {
        let root = view
            .frame(width: Metrics.panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(Theme.palette(for: scheme).panel)
            .environment(\.l10nLanguage, language)
            .environment(\.drawsStill, true)
            .environment(\.colorScheme, scheme)
            .transaction { $0.disablesAnimations = true }
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 700),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let size = NSSize(width: Metrics.panelWidth, height: ceil(host.fittingSize.height))
        XCTAssertGreaterThan(size.height, 100)
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        // Let SwiftUI install its AppKit children before caching the view hierarchy.
        for _ in 0..<3 {
            await Task.yield()
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        CATransaction.flush()
        XCTAssertFalse(window.isVisible)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    func testRendersEverySceneInBothLanguagesAndSchemes() async throws {
        let directory = repoRoot().appendingPathComponent(".build/snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lightMain: Data?
        var darkMain: Data?
        print("Facade scenes: \(PanelFixtures.scenes.map(\.name).joined(separator: ", "))")
        for scene in PanelFixtures.scenes {
            for language in L10nLanguage.allCases {
                for scheme in [ColorScheme.light, ColorScheme.dark] {
                    let state = try await scene.make(language)
                    let data = try XCTUnwrap(
                        SnapshotRenderer.png(state: state, colorScheme: scheme),
                        "no image for \(scene.name)"
                    )
                    XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
                    let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
                    XCTAssertEqual(rep.pixelsWide, Int(Metrics.panelWidth * 2), scene.name)
                    XCTAssertGreaterThan(rep.pixelsHigh, 200, scene.name)
                    let schemeName = scheme == .dark ? "dark" : "light"
                    let url = directory.appendingPathComponent("\(scene.name)-\(language.fileToken)-\(schemeName).png")
                    try data.write(to: url, options: .atomic)
                    if scene.name == "main" && language == .zhHans {
                        if scheme == .light { lightMain = data }
                        if scheme == .dark { darkMain = data }
                    }
                }
            }
        }
        XCTAssertNotEqual(lightMain, darkMain)
        let written = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for scene in PanelFixtures.scenes {
            for language in ["zhHans", "en"] {
                for scheme in ["light", "dark"] {
                    let name = "\(scene.name)-\(language)-\(scheme).png"
                    XCTAssertTrue(written.contains { $0.lastPathComponent == name }, "missing \(name)")
                }
            }
        }
    }

    func testAPanelTallerThanTheScreenStopsThereAndScrolls() async throws {
        func height(_ data: Data?) throws -> Int { try XCTUnwrap(data.flatMap(NSBitmapImageRep.init(data:))).pixelsHigh }
        let many = try await FixtureScene.manyAccounts.make(.zhHans)
        // The account page stops at its own limit whatever the screen allows, and sooner on a short screen.
        XCTAssertEqual(try height(SnapshotRenderer.png(state: many, colorScheme: .light)), Int(2 * Metrics.panelMaxHeight))
        XCTAssertEqual(try height(SnapshotRenderer.png(state: many, colorScheme: .light, heightLimit: 2000)),
                       Int(2 * Metrics.panelMaxHeight))
        let limited = SnapshotRenderer.png(state: many, colorScheme: .light, heightLimit: 700)
        XCTAssertEqual(try height(limited), 2 * 700)
        let directory = repoRoot().appendingPathComponent(".build/snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(limited).write(to: directory.appendingPathComponent("many-accounts-limited-zhHans-light.png"), options: .atomic)
        // A page that fits keeps its own height, the settings page too; a screen too short for the
        // settings page stops that one as well.
        for scene in [FixtureScene.main, .settings] {
            let state = try await scene.make(.zhHans)
            XCTAssertEqual(try height(SnapshotRenderer.png(state: state, colorScheme: .light, heightLimit: 2000)),
                           try height(SnapshotRenderer.png(state: state, colorScheme: .light)), scene.name)
        }
        let settings = try await FixtureScene.settings.make(.zhHans)
        XCTAssertEqual(try height(SnapshotRenderer.png(state: settings, colorScheme: .light, heightLimit: 300)), 2 * 300)
    }

    private func repoRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        let files = FileManager.default
        while url.path != "/" {
            url.deleteLastPathComponent()
            if files.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}
