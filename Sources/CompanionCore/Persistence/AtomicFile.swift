import Darwin
import Foundation

public enum AtomicFileError: Error, Equatable, Sendable {
    case notFound(URL)
    case notRegularFile(URL)
    case readFailed(URL, errno: Int32)
    case writeFailed(URL, errno: Int32)
    /// `config.json` inside the caller's `protectedRoot` would make profile
    /// scanners treat the app data directory as a Claude profile.
    case refusedConfigJSON(URL)
}

/// Read and write a file by renaming a temporary sibling into place.
///
/// Parent directories created along the way are mode `0700`. The file is mode
/// `0600` unless `permissions` says otherwise. A crash during the write leaves
/// the previous file intact and does not keep the temporary name.
public enum AtomicFile {
    public static let defaultPermissions = 0o600

    public static func read(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, Darwin.O_RDONLY)
        if fd < 0 {
            let error = errno
            if error == ENOENT {
                throw AtomicFileError.notFound(url)
            }
            throw AtomicFileError.readFailed(url, errno: error)
        }
        defer { _ = Darwin.close(fd) }

        var info = stat()
        if fstat(fd, &info) != 0 {
            throw AtomicFileError.readFailed(url, errno: errno)
        }
        if info.st_mode & S_IFMT != S_IFREG {
            throw AtomicFileError.notRegularFile(url)
        }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 {
                break
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                throw AtomicFileError.readFailed(url, errno: errno)
            }
            data.append(buffer, count: count)
        }
        return data
    }

    public static func write(
        _ data: Data,
        to url: URL,
        permissions: Int = defaultPermissions,
        protectedRoot: URL? = nil
    ) throws {
        if refusesConfigJSON(url, protectedRoot: protectedRoot) {
            throw AtomicFileError.refusedConfigJSON(url)
        }
        try ensureParentDirectory(of: url)

        let tempURL = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        let fd = Darwin.open(tempURL.path, Darwin.O_CREAT | Darwin.O_EXCL | Darwin.O_WRONLY, mode_t(0o600))
        if fd < 0 {
            throw AtomicFileError.writeFailed(url, errno: errno)
        }

        do {
            try writeAll(data, to: fd, destination: url)
            let mode = mode_t(permissions & 0o777)
            if fchmod(fd, mode) != 0 {
                throw AtomicFileError.writeFailed(url, errno: errno)
            }
            if fsync(fd) != 0 {
                throw AtomicFileError.writeFailed(url, errno: errno)
            }
        } catch {
            _ = Darwin.close(fd)
            Darwin.unlink(tempURL.path)
            throw error
        }

        if Darwin.close(fd) != 0 {
            Darwin.unlink(tempURL.path)
            throw AtomicFileError.writeFailed(url, errno: errno)
        }
        if Darwin.rename(tempURL.path, url.path) != 0 {
            let error = errno
            Darwin.unlink(tempURL.path)
            throw AtomicFileError.writeFailed(url, errno: error)
        }
        // The rename is the commit. A directory fsync failure must not delete it.
        let directory = Darwin.open(url.deletingLastPathComponent().path, Darwin.O_RDONLY)
        if directory >= 0 {
            _ = fsync(directory)
            _ = Darwin.close(directory)
        }
    }

    private static func writeAll(_ data: Data, to fd: Int32, destination: URL) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let wrote = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if wrote < 0 {
                    if errno == EINTR {
                        continue
                    }
                    throw AtomicFileError.writeFailed(destination, errno: errno)
                }
                offset += wrote
            }
        }
    }

    private static func ensureParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        var missing: [URL] = []
        var current = parent
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: current.path) {
            missing.append(current)
            let next = current.deletingLastPathComponent()
            if next.path == current.path {
                break
            }
            current = next
        }
        for directory in missing.reversed() {
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
            } catch let error as AtomicFileError {
                throw error
            } catch {
                if !fileManager.fileExists(atPath: directory.path) {
                    throw AtomicFileError.writeFailed(directory, errno: Int32(EIO))
                }
                continue
            }
            if chmod(directory.path, mode_t(0o700)) != 0 {
                throw AtomicFileError.writeFailed(directory, errno: errno)
            }
        }
    }

    /// Profile scanners identify a profile by `config.json`. Only the app data
    /// directory passed as `protectedRoot` is off limits. A parent folder that
    /// happens to be named "CC-Relay" (the repository, or `./sandbox`
    /// under it) is not.
    private static func refusesConfigJSON(_ url: URL, protectedRoot: URL?) -> Bool {
        guard let protectedRoot else { return false }
        guard url.lastPathComponent.compare("config.json", options: .caseInsensitive) == .orderedSame else {
            return false
        }
        return isInside(url, root: protectedRoot)
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == rootPath {
            return true
        }
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }
}
