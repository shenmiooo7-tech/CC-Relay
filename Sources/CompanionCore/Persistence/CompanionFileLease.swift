import Darwin
import Foundation

enum CompanionFileLeaseError: Error { case busy, unavailable }

/// An OS-owned lease; a crashed process releases it without deleting/replacing its inode.
final class CompanionFileLease {
    private var descriptor: Int32?

    init(file: URL, waitMilliseconds: Int = 0) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = Darwin.open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw CompanionFileLeaseError.unavailable }
        for attempt in 0...max(0, min(1_000, waitMilliseconds) / 5) {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { descriptor = fd; return }
            let code = errno
            guard code == EWOULDBLOCK || code == EAGAIN else { Darwin.close(fd); throw CompanionFileLeaseError.unavailable }
            if attempt < max(0, min(1_000, waitMilliseconds) / 5) { usleep(5_000) }
        }
        Darwin.close(fd); throw CompanionFileLeaseError.busy
    }

    func release() {
        if let fd = descriptor { descriptor = nil; _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) }
    }
    deinit { release() }
}
