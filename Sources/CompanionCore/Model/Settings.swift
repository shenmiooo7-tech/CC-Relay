import Foundation

/// Persisted UI language. An unknown raw value from a newer version decodes as
/// `.system`. A non-string value still throws.
public enum AppLanguage: String, Equatable, Sendable, Codable {
    case system
    case zhHans
    case en

    public init(from decoder: Decoder) throws {
        self = try LenientStringEnum.decode(from: decoder, fallback: .system)
    }

    public func encode(to encoder: Encoder) throws {
        try LenientStringEnum.encode(self, to: encoder)
    }
}

/// The panel's light or dark look. An unknown raw value from a newer version decodes as `.system`.
public enum AppAppearance: String, Equatable, Sendable, Codable {
    case system
    case light
    case dark

    public init(from decoder: Decoder) throws {
        self = try LenientStringEnum.decode(from: decoder, fallback: .system)
    }

    public func encode(to encoder: Encoder) throws {
        try LenientStringEnum.encode(self, to: encoder)
    }
}

public struct Settings: Equatable, Sendable, Codable {
    public var autoSyncOnSwitch: Bool
    /// Opt in to closing and switching Desktop when the active account is exhausted.
    public var autoSwitchOnQuota: Bool
    /// Always on: its switch was taken out of the settings, and an earlier "off" is read as on.
    public var autoCorrectDefaultLaunch: Bool
    /// Ask the current Code conversation to compact itself when the five-hour quota is nearly spent.
    public var autoCompactOnLowQuota: Bool
    /// Open CC-Relay when the person logs in to the Mac: off until they turn it on.
    public var launchAtLogin: Bool
    public var language: AppLanguage
    public var appearance: AppAppearance
    /// Ask once before a switch that a click on an account starts.
    public var confirmSwitch: Bool

    public init(
        autoSyncOnSwitch: Bool = true,
        autoSwitchOnQuota: Bool = false,
        autoCorrectDefaultLaunch: Bool = true,
        autoCompactOnLowQuota: Bool = false,
        launchAtLogin: Bool = false,
        language: AppLanguage = .system,
        appearance: AppAppearance = .system,
        confirmSwitch: Bool = true
    ) {
        self.autoSyncOnSwitch = autoSyncOnSwitch
        self.autoSwitchOnQuota = autoSwitchOnQuota
        self.autoCorrectDefaultLaunch = autoCorrectDefaultLaunch
        self.autoCompactOnLowQuota = autoCompactOnLowQuota
        self.launchAtLogin = launchAtLogin
        self.language = language
        self.appearance = appearance
        self.confirmSwitch = confirmSwitch
    }

    private enum CodingKeys: String, CodingKey {
        case autoSyncOnSwitch
        case autoSwitchOnQuota
        case autoCorrectDefaultLaunch
        case autoCompactOnLowQuota
        case launchAtLogin
        case language
        case appearance
        case confirmSwitch
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.autoSyncOnSwitch = try JSONFields.value(
            Bool.self,
            from: container,
            forKey: .autoSyncOnSwitch,
            default: true
        )
        self.autoSwitchOnQuota = try JSONFields.value(Bool.self, from: container, forKey: .autoSwitchOnQuota, default: false)
        // Still read, so a malformed value is noticed like any other, but always on.
        _ = try JSONFields.value(
            Bool.self,
            from: container,
            forKey: .autoCorrectDefaultLaunch,
            default: true
        )
        self.autoCorrectDefaultLaunch = true
        self.autoCompactOnLowQuota = try JSONFields.value(
            Bool.self,
            from: container,
            forKey: .autoCompactOnLowQuota,
            default: false
        )
        self.launchAtLogin = try JSONFields.value(
            Bool.self,
            from: container,
            forKey: .launchAtLogin,
            default: false
        )
        self.language = try JSONFields.value(
            AppLanguage.self,
            from: container,
            forKey: .language,
            default: .system
        )
        self.appearance = try JSONFields.value(
            AppAppearance.self,
            from: container,
            forKey: .appearance,
            default: .system
        )
        self.confirmSwitch = try JSONFields.value(
            Bool.self,
            from: container,
            forKey: .confirmSwitch,
            default: true
        )
    }
}
