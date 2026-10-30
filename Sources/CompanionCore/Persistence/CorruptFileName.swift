import Foundation

enum CorruptFileName {
    /// `<prefix>.<label>-yyyyMMdd-HHmmss-SSS.json`, with `-2`, `-3`, … if that name is taken.
    /// `label` is `corrupt` for a file that could not be decoded, or `partial` when
    /// individual records were skipped and the rest was kept.
    static func url(prefix: String, directory: URL, date: Date, label: String = "corrupt") -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: date)
        let fileManager = FileManager.default
        var candidate = directory.appending(path: "\(prefix).\(label)-\(stamp).json")
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "\(prefix).\(label)-\(stamp)-\(counter).json")
            counter += 1
        }
        return candidate
    }
}
