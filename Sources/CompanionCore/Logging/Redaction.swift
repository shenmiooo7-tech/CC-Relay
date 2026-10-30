import Foundation

/// Masks identifiers before they reach a log line.
///
/// There is no function here that accepts a cookie, token, or password.
public enum Redaction {
    public static func maskEmail(_ email: String) -> String {
        guard let at = email.firstIndex(of: "@") else { return email }
        let local = email[..<at]
        let domain = email[email.index(after: at)...]
        guard let first = local.first, !domain.isEmpty else { return email }
        return "\(first)\u{2022}\u{2022}\u{2022}@\(domain)"
    }

    public static func maskUUID(_ uuid: String) -> String {
        guard uuid.count > 8 else { return uuid }
        return String(uuid.prefix(8)) + "\u{2026}"
    }

    /// Replaces every email-shaped or UUID-shaped substring.
    public static func scrub(_ text: String) -> String {
        let withoutEmails = replace(text, pattern: emailPattern, maskEmail)
        return replace(withoutEmails, pattern: uuidPattern, maskUUID)
    }

    private static let emailPattern = "[A-Za-z0-9._%+\\-]+@[A-Za-z0-9.\\-]+\\.[A-Za-z]{2,}"
    private static let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"

    private static func replace(
        _ text: String,
        pattern: String,
        _ transform: (String) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: text, range: full)
        if matches.isEmpty {
            return text
        }
        var result = ""
        var cursor = 0
        for match in matches {
            let range = match.range
            if range.location > cursor {
                result += ns.substring(with: NSRange(location: cursor, length: range.location - cursor))
            }
            result += transform(ns.substring(with: range))
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            result += ns.substring(from: cursor)
        }
        return result
    }
}
