import Foundation

public struct ProfileConfiguration: Equatable, Sendable {
    public let accountUUID: String?
    public let organizationStamps: [String: String]
    /// Includes stamp-key suffixes even when the stamp value is invalid.
    public let knownOrganizationUUIDs: [String]
    public let activeOrganizationUUID: String?
    public let updaterLastSeenVersion: String?
}

public struct ProfileConfigReader: Sendable {
    public init() {}

    public func read(profile: URL) throws -> ProfileConfiguration {
        try parse(SessionFileIO().read(profile.appending(path: "config.json")))
    }

    public func parse(_ data: Data) throws -> ProfileConfiguration {
        // A keyed container can enumerate names without decoding the oauth values.
        try StableJSON.decode(SelectedConfig.self, from: data).configuration
    }
}

private struct ConfigKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.init(stringValue) }
    init?(intValue: Int) { return nil }
}

private struct SelectedConfig: Decodable {
    let configuration: ProfileConfiguration

    init(from decoder: Decoder) throws {
        let map = try decoder.container(keyedBy: ConfigKey.self)
        let account = try? map.decode(String.self, forKey: ConfigKey("lastKnownAccountUuid"))
        let version = try? map.decode(String.self, forKey: ConfigKey("updaterLastSeenVersion"))
        let prefix = "dxt:allowlistLastUpdated:"
        var stamps: [String: String] = [:]
        var known: [String] = []
        var valid: [(String, OrganizationStamp)] = []
        for key in map.allKeys where key.stringValue.hasPrefix(prefix) {
            let org = String(key.stringValue.dropFirst(prefix.count))
            guard !org.isEmpty else { continue }
            known.append(org)
            guard let stamp = try? map.decode(String.self, forKey: key) else { continue }
            stamps[org] = stamp
            guard let date = OrganizationStamp(stamp) else { continue }
            valid.append((org, date))
        }
        valid.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        configuration = ProfileConfiguration(
            accountUUID: account.flatMap { $0.isEmpty ? nil : $0 },
            organizationStamps: stamps,
            knownOrganizationUUIDs: known.sorted(),
            activeOrganizationUUID: valid.first?.0,
            updaterLastSeenVersion: version
        )
    }
}

/// Preserve sub-millisecond ordering without rounding a stamp through Date.
private struct OrganizationStamp: Comparable {
    let second: Int64
    let fraction: String

    init?(_ text: String) {
        let pattern = #"^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]+))?([Zz]|[+-][0-9]{2}:[0-9]{2})$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String {
            guard let range = Range(match.range(at: index), in: text) else { return "" }
            return String(text[range])
        }
        let numbers = (1...6).compactMap { Int(group($0)) }
        guard numbers.count == 6, (1...9999).contains(numbers[0]), (1...12).contains(numbers[1]),
              (1...31).contains(numbers[2]), (0...23).contains(numbers[3]),
              (0...59).contains(numbers[4]), (0...59).contains(numbers[5]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: numbers[0], month: numbers[1], day: numbers[2],
            hour: numbers[3], minute: numbers[4], second: numbers[5])
        guard let local = calendar.date(from: components),
              calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: local) == components else { return nil }
        let zone = group(8)
        var offset = 0
        if zone != "Z" && zone != "z" {
            guard let hours = Int(zone.dropFirst().prefix(2)), let minutes = Int(zone.suffix(2)),
                  hours <= 23, minutes <= 59 else { return nil }
            offset = (hours * 3600 + minutes * 60) * (zone.first == "-" ? -1 : 1)
        }
        second = Int64(local.timeIntervalSince1970) - Int64(offset)
        var fraction = group(7)
        while fraction.last == "0" { fraction.removeLast() }
        self.fraction = fraction
    }

    static func < (a: Self, b: Self) -> Bool {
        a.second == b.second ? a.fraction < b.fraction : a.second < b.second
    }
}
