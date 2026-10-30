import Foundation

public enum ClaudeArguments {
    public enum ParseError: Error, Equatable, Sendable {
        case missingValue
        case invalidPath
        case relativePath
    }

    /// nil means no flag; the caller supplies the default profile in that case.
    public static func profileDirectory(in argv: [String]) throws -> URL? {
        var selected: String?
        var foundFlag = false
        var index = 0
        while index < argv.count {
            let argument = argv[index]
            if argument == "--" { break }
            if argument.hasPrefix("--user-data-dir=") {
                selected = String(argument.dropFirst("--user-data-dir=".count))
                foundFlag = true
            } else if argument == "--user-data-dir" {
                foundFlag = true
                selected = nil
                if index + 1 < argv.count, !argv[index + 1].hasPrefix("--") {
                    index += 1
                    selected = argv[index]
                }
            }
            index += 1
        }
        guard foundFlag else { return nil }
        guard let selected else { throw ParseError.missingValue }
        guard !selected.isEmpty, !selected.contains("\0") else { throw ParseError.invalidPath }
        guard selected.hasPrefix("/") else { throw ParseError.relativePath }
        return URL(fileURLWithPath: selected, isDirectory: true).standardizedFileURL
    }
}
