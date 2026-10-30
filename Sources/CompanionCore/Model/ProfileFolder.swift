import Foundation

public enum ProfileFolderError: Error, Equatable, Sendable {
    case empty
    case reserved
    case notASingleComponent
}

/// Directory name of a Claude profile, which is also the registry identity.
///
/// `"Claude"` is the default profile. Any other non-empty single path
/// component is representable: profiles made by other tools may not follow the
/// `Claude_<suffix>` convention.
public struct ProfileFolder: Hashable, Sendable, Codable, CustomStringConvertible {
    public let name: String

    public init(_ name: String) throws {
        if name.isEmpty {
            throw ProfileFolderError.empty
        }
        if name == "." || name == ".." {
            throw ProfileFolderError.reserved
        }
        if name.contains("/") || name.contains("\0") {
            throw ProfileFolderError.notASingleComponent
        }
        self.name = name
    }

    public var isDefault: Bool {
        name == "Claude"
    }

    /// `"Claude"` or `"Claude_"` plus at least one character. Comparison is
    /// case-sensitive, matching how profile directories are discovered.
    public var isConventionalName: Bool {
        if name == "Claude" {
            return true
        }
        return name.hasPrefix("Claude_") && name.count > "Claude_".count
    }

    public var description: String { name }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let name = try container.decode(String.self)
        do {
            try self.init(name)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid profile folder."
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(name)
    }
}
