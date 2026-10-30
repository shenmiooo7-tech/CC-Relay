import Foundation

/// Collects records that were skipped while decoding a persisted file.
///
/// Stores install one of these on the decoder. A decode that does not install
/// one still skips bad elements; it just has nowhere to report them.
/// Decoding is synchronous, and each collector is used by only one decode.
final class DecodeSkips: @unchecked Sendable {
    static let userInfoKey = CodingUserInfoKey(rawValue: "local.cc-relay.decodeSkips")!

    private(set) var paths: [String] = []

    func record(_ path: String) {
        paths.append(path)
    }

    var isEmpty: Bool { paths.isEmpty }
}

/// Missing keys and JSON null both become the fallback. A present value of the
/// wrong type still throws, so a corrupt file is not silently half-read.
enum JSONFields {
    static func optional<T: Decodable, Key: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) throws -> T? {
        guard container.contains(key) else { return nil }
        if try container.decodeNil(forKey: key) { return nil }
        return try container.decode(T.self, forKey: key)
    }

    static func value<T: Decodable, Key: CodingKey>(
        _ type: T.Type,
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        default defaultValue: @autoclosure () -> T
    ) throws -> T {
        try optional(T.self, from: container, forKey: key) ?? defaultValue()
    }

    /// Decodes an array one element at a time. An element that cannot be decoded
    /// is omitted and recorded on `skips`. A value that is not an array still throws.
    static func lenientArray<Element: Decodable, Key: CodingKey>(
        _ type: Element.Type,
        from container: KeyedDecodingContainer<Key>,
        forKey key: Key,
        path: String,
        skips: DecodeSkips?
    ) throws -> [Element] {
        guard container.contains(key) else { return [] }
        if try container.decodeNil(forKey: key) { return [] }
        var nested = try container.nestedUnkeyedContainer(forKey: key)
        var result: [Element] = []
        while !nested.isAtEnd {
            let index = nested.currentIndex
            do {
                result.append(try nested.decode(type))
            } catch {
                // A failed decode leaves the index unmoved on this SDK. Advance
                // past the bad value ourselves. If the index already moved, the
                // value was consumed and a second decode would drop the next one.
                if nested.currentIndex == index {
                    _ = try nested.decode(DiscardedJSON.self)
                }
                skips?.record("\(path)[\(index)]")
            }
        }
        return result
    }
}

/// Any JSON value. Used only to move an unkeyed container past a bad element.
private struct DiscardedJSON: Decodable {
    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            while !unkeyed.isAtEnd {
                _ = try unkeyed.decode(DiscardedJSON.self)
            }
            return
        }
        if let keyed = try? decoder.container(keyedBy: DiscardKey.self) {
            for key in keyed.allKeys {
                _ = try keyed.decode(DiscardedJSON.self, forKey: key)
            }
            return
        }
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { return }
        if (try? single.decode(Bool.self)) != nil { return }
        if (try? single.decode(Double.self)) != nil { return }
        if (try? single.decode(String.self)) != nil { return }
        throw DecodingError.dataCorruptedError(
            in: single,
            debugDescription: "Could not skip a JSON value."
        )
    }
}

private struct DiscardKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// Unknown string raw values become `fallback`. A non-string JSON value throws.
enum LenientStringEnum {
    static func decode<T: RawRepresentable>(
        from decoder: Decoder,
        fallback: T
    ) throws -> T where T.RawValue == String {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        return T(rawValue: raw) ?? fallback
    }

    static func encode<T: RawRepresentable>(_ value: T, to encoder: Encoder) throws where T.RawValue == String {
        var container = encoder.singleValueContainer()
        try container.encode(value.rawValue)
    }
}
