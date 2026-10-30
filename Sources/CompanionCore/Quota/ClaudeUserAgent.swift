import Foundation

/// Desktop-like User-Agent. A missing or blank version omits that token.
public enum ClaudeUserAgent {
    public static func headerValue(claude: String?, electron: String?) -> String {
        var parts = [desktop]
        if let claude = token("Claude", claude) {
            parts.append(claude)
        }
        if let electron = token("Electron", electron) {
            parts.append(electron)
        }
        parts.append(safari)
        return parts.joined(separator: " ")
    }

    private static func token(_ name: String, _ version: String?) -> String? {
        guard let version else { return nil }
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let unsafe = trimmed.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
        guard !unsafe else { return nil }
        return name + "/" + trimmed
    }

    private static let desktop = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)"
    private static let safari = "Safari/537.36"
}
