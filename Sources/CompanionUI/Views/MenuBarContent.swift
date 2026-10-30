import Foundation

/// What the status item says about itself. It shows only the app's logo; VoiceOver still hears
/// the current account and its 5-hour remaining percent, or the switch in progress.
public struct MenuBarContent: Equatable, Sendable {
    public var accessibilityLabel: String

    public init(title: String, quotaPercent: Int?, isSwitching: Bool, language: L10nLanguage) {
        let percent = isSwitching ? nil : quotaPercent
        let status = percent.map { "\(title) · \($0)%" } ?? title
        let product = L10nKey.productName.string(in: language)
        // Without a current account the title is the product name itself; say it once.
        accessibilityLabel = status == product ? product : product + ", " + status
    }
}

public extension MenuBarLabelModel {
    var content: MenuBarContent {
        MenuBarContent(title: title, quotaPercent: quotaPercent, isSwitching: isSwitching, language: language)
    }
}
