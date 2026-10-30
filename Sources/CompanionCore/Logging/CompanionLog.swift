import Darwin
import Foundation
import os

public enum LogCategory: String, Equatable, Sendable {
    case app
    case `switch`
    case sync
    case backup
    case quota
    case platform
}

public enum LogLevel: String, Equatable, Sendable {
    case debug
    case info
    case warning
    case error

    var label: String {
        rawValue.uppercased()
    }
}

/// Writes a scrubbed line to `Logs/cc-relay.log` and to `os.Logger`.
///
/// The file rotates at 1 MB, keeping `cc-relay.log.1` and `cc-relay.log.2`.
/// Callers pass ordinary text. Messages are scrubbed again here so an email or
/// UUID that slipped through is still masked. The methods take a `String` only:
/// there is no entry point for a cookie or token.
public final class CompanionLog: @unchecked Sendable {
    public static let rotationThreshold = 1_048_576

    private let directory: URL
    private let fileURL: URL
    private let clock: any Clock
    private let threshold: Int
    private let lock = NSLock()

    public init(
        paths: AppPaths,
        clock: any Clock = SystemClock(),
        rotationThreshold: Int = CompanionLog.rotationThreshold
    ) {
        directory = paths.companionDataDirectory.appending(path: "Logs", directoryHint: .isDirectory)
        fileURL = directory.appending(path: "cc-relay.log")
        self.clock = clock
        self.threshold = max(rotationThreshold, 1)
    }

    public func debug(_ category: LogCategory, _ message: String) {
        write(.debug, category, message)
    }

    public func info(_ category: LogCategory, _ message: String) {
        write(.info, category, message)
    }

    public func warning(_ category: LogCategory, _ message: String) {
        write(.warning, category, message)
    }

    public func error(_ category: LogCategory, _ message: String) {
        write(.error, category, message)
    }

    private func write(_ level: LogLevel, _ category: LogCategory, _ message: String) {
        let safe = Redaction.scrub(message)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let line = "\(ISO8601Fractional.string(from: clock.now())) \(level.label) \(category.rawValue) \(safe)\n"
        lock.lock()
        append(line)
        lock.unlock()
        let logger = Logger(subsystem: "local.cc-relay", category: category.rawValue)
        // The text was scrubbed above, so it is safe to mark public.
        switch level {
        case .debug:
            logger.debug("\(safe, privacy: .public)")
        case .info:
            logger.info("\(safe, privacy: .public)")
        case .warning:
            logger.warning("\(safe, privacy: .public)")
        case .error:
            logger.error("\(safe, privacy: .public)")
        }
    }

    private func append(_ line: String) {
        ensureDirectory()
        if fileSize(fileURL) >= threshold {
            rotate()
        }
        let fd = Darwin.open(fileURL.path, Darwin.O_CREAT | Darwin.O_WRONLY | Darwin.O_APPEND, mode_t(0o600))
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }
        _ = fchmod(fd, mode_t(0o600))
        _ = line.withCString { pointer in
            Darwin.write(fd, pointer, strlen(pointer))
        }
    }

    private func rotate() {
        let first = fileURL.appendingPathExtension("1")
        let second = fileURL.appendingPathExtension("2")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: second.path) {
            try? fileManager.removeItem(at: second)
        }
        if fileManager.fileExists(atPath: first.path) {
            try? fileManager.moveItem(at: first, to: second)
        }
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.moveItem(at: fileURL, to: first)
        }
    }

    private func ensureDirectory() {
        var missing: [URL] = []
        var current = directory
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: current.path) {
            missing.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path {
                break
            }
            current = parent
        }
        for directory in missing.reversed() {
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            _ = chmod(directory.path, mode_t(0o700))
        }
    }

    private func fileSize(_ url: URL) -> Int {
        var info = stat()
        if stat(url.path, &info) != 0 {
            return 0
        }
        return Int(info.st_size)
    }
}
