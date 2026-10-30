import CoreFoundation
import Foundation

enum JSONNumbers {
    /// Finite JSON numbers. Booleans are not numbers here.
    static func finite(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = value as? NSNumber else { return nil }
        if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return double
    }
}

enum OrganizationIdentity {
    static func isUUID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 36 else { return false }
        for (index, byte) in bytes.enumerated() {
            if index == 8 || index == 13 || index == 18 || index == 23 {
                if byte != UInt8(ascii: "-") { return false }
                continue
            }
            let digit = byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
            let lower = byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f")
            let upper = byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "F")
            if !digit && !lower && !upper { return false }
        }
        return true
    }
}
