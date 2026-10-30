import CoreFoundation
import Darwin
import Foundation

/// Reads only the most recent usable assistant usage, without loading a whole transcript.
public struct TranscriptUsageReader: Sendable {
    static let maximumLineBytes = 16 * 1024 * 1024
    static let maximumScanBytes = 64 * 1024 * 1024
    private let cliHome: URL
    private let chunkBytes: Int
    private let io = SessionFileIO()

    public init(paths: AppPaths) {
        self.init(paths: paths, chunkBytes: 64 * 1024)
    }

    init(paths: AppPaths, chunkBytes: Int) {
        cliHome = paths.claudeCLIHome
        self.chunkBytes = max(1, min(chunkBytes, Self.maximumLineBytes))
    }

    public func contextTokens(cliSessionID: String) -> Int? {
        guard (1...64).contains(cliSessionID.utf8.count), cliSessionID.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45
        }) else { return nil }
        let projects = cliHome.appending(path: "projects").resolvingSymlinksInPath()
        guard let entries = try? io.list(projects) else { return nil }
        var budget = Self.maximumScanBytes
        for entry in entries {
            do {
                let project = entry.resolvingSymlinksInPath()
                guard let metadata = try io.info(project), io.isDirectory(metadata) else { continue }
                let file = project.appending(path: cliSessionID + ".jsonl").resolvingSymlinksInPath()
                guard let metadata = try io.info(file), io.isRegular(metadata) else { continue }
                if let tokens = try scan(file, budget: &budget) { return tokens }
            } catch ReadFailure.boundExceeded { return nil }
            catch { }
            if budget == 0 { return nil }
        }
        return nil
    }

    private enum ReadFailure: Error { case unreadable, boundExceeded }
    private enum Row { case usage(Int), compacted, other }

    private func scan(_ file: URL, budget: inout Int) throws -> Int? {
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw ReadFailure.unreadable }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, io.isRegular(metadata), metadata.st_size >= 0 else {
            throw ReadFailure.unreadable
        }
        var offset = metadata.st_size
        // Fragments are held in reverse order, avoiding repeated copies of a growing line.
        var fragments: [Data] = []
        var lineBytes = 0
        func append(_ bytes: Data.SubSequence) throws {
            guard bytes.count <= Self.maximumLineBytes - lineBytes else { throw ReadFailure.boundExceeded }
            if !bytes.isEmpty { fragments.append(Data(bytes)); lineBytes += bytes.count }
        }
        func row() -> Row {
            guard lineBytes > 0 else { return .other }
            var line = Data(capacity: lineBytes)
            for fragment in fragments.reversed() { line.append(fragment) }
            return Self.classify(line)
        }
        while offset > 0, budget > 0 {
            let count = Int(min(off_t(min(chunkBytes, budget)), offset))
            offset -= off_t(count)
            var chunk = Data(count: count)
            try chunk.withUnsafeMutableBytes { buffer in
                guard let base = buffer.baseAddress else { throw ReadFailure.unreadable }
                var filled = 0
                while filled < count {
                    let read = pread(descriptor, base.advanced(by: filled), count - filled, offset + off_t(filled))
                    if read < 0, errno == EINTR { continue }
                    guard read > 0 else { throw ReadFailure.unreadable }
                    filled += read
                    budget -= read
                }
            }
            var end = chunk.endIndex
            for index in chunk.indices.reversed() where chunk[index] == 10 {
                try append(chunk[(index + 1)..<end])
                switch row() {
                case .usage(let tokens): return tokens
                case .compacted: return nil
                case .other: break
                }
                fragments.removeAll(keepingCapacity: true)
                lineBytes = 0
                end = index
            }
            try append(chunk[..<end])
        }
        // A partial first line at the scan budget is not a JSON row.
        guard offset == 0, case .usage(let tokens) = row() else { return nil }
        return tokens
    }

    private static func classify(_ line: Data) -> Row {
        guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return .other }
        // The next request after a compaction starts from the summary, so older usage overstates the context.
        if row["isCompactSummary"] as? Bool == true
            || (row["type"] as? String == "system" && row["subtype"] as? String == "compact_boundary") {
            return .compacted
        }
        guard row["type"] as? String == "assistant", row["isSidechain"] as? Bool != true,
              let message = row["message"] as? [String: Any], message["model"] as? String != "<synthetic>",
              let usage = message["usage"] as? [String: Any] else { return .other }
        var total = 0
        for field in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "output_tokens"] {
            guard let value = usage[field] else { continue }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !CFNumberIsFloatType(number), let integer = Int(number.stringValue) else { return .other }
            let sum = total.addingReportingOverflow(integer)
            guard !sum.overflow else { return .other }
            total = sum.partialValue
        }
        // Notices Claude Code writes itself, such as a usage-limit error, carry zero usage.
        return total > 0 ? .usage(total) : .other
    }
}
