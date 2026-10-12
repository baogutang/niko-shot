// Keeps one resident process per user with a validated, persistent Darwin advisory lock.
import Darwin
import Foundation

/// An exclusive resident lock retained for the lifetime of its owning application process.
///
/// The descriptor is immutable after acquisition. The lock file remains on disk when
/// the descriptor closes so another process always locks the same inode.
public final class ResidentInstanceLock: @unchecked Sendable {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit {
        _ = flock(descriptor, LOCK_UN)
        _ = Darwin.close(descriptor)
    }

    /// Acquires the current user's resident lock, or returns `nil` when another resident owns it.
    /// - Throws: A POSIX error if the path is unsafe or the lock cannot be opened or written.
    public static func acquire() throws -> ResidentInstanceLock? {
        try acquire(at: defaultURL)
    }

    /// Returns a live PID only while a validated resident lock is exclusively occupied.
    ///
    /// This performs one bounded lookup without creating files or adding a polling task.
    public static func currentPID() -> Int32? { currentPID(at: defaultURL) }

    private static var defaultURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("niko-shot-resident-\(getuid()).lock")
    }

    static func acquire(at url: URL) throws -> ResidentInstanceLock? {
        let path = try validatedPath(url)
        let descriptor = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard descriptor >= 0 else { throw posixError() }
        var retainsDescriptor = false
        defer { if !retainsDescriptor { _ = Darwin.close(descriptor) } }

        try validate(descriptor)
        guard try tryLock(descriptor, operation: LOCK_EX | LOCK_NB) else { return nil }
        // Recheck the same descriptor after locking, before any existing contents are changed.
        try validate(descriptor)
        guard Darwin.ftruncate(descriptor, 0) == 0 else { throw posixError() }
        let bytes = Array("\(getpid())\n".utf8)
        try bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { throw POSIXError(.EIO) }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw count < 0 ? posixError() : POSIXError(.EIO) }
                offset += count
            }
        }
        retainsDescriptor = true
        return ResidentInstanceLock(descriptor: descriptor)
    }

    static func currentPID(at url: URL) -> Int32? {
        do {
            let path = try validatedPath(url)
            let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            guard descriptor >= 0 else { return nil }
            defer { _ = Darwin.close(descriptor) }
            try validate(descriptor)
            // A shared lock succeeds unless another descriptor holds an exclusive lock.
            guard try !tryLock(descriptor, operation: LOCK_SH | LOCK_NB) else { return nil }
            var info = stat()
            guard Darwin.fstat(descriptor, &info) == 0, info.st_size > 1, info.st_size <= 32 else { return nil }
            var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
            let count = try bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { throw POSIXError(.EIO) }
                var count: Int
                repeat { count = Darwin.pread(descriptor, base, buffer.count, 0) } while count < 0 && errno == EINTR
                guard count >= 0 else { throw posixError() }
                return count
            }
            guard count == bytes.count, bytes.last == 10 else { return nil }
            let digits = bytes.dropLast()
            guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }),
                  let pid = Int32(String(decoding: digits, as: UTF8.self)), pid > 0 else { return nil }
            guard Darwin.kill(pid, 0) == 0 || errno == EPERM else { return nil }
            // Do not return a stale PID if the owner released the lock during this lookup.
            guard try !tryLock(descriptor, operation: LOCK_SH | LOCK_NB) else { return nil }
            return pid
        } catch { return nil }
    }

    private static func validatedPath(_ url: URL) throws -> String {
        guard url.isFileURL, !url.path.utf8.contains(0) else { throw POSIXError(.EINVAL) }
        return url.path
    }

    private static func validate(_ descriptor: Int32) throws {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw posixError() }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == getuid(), (info.st_mode & 0o7777) == 0o600,
              info.st_nlink == 1 else { throw POSIXError(.EACCES) }
    }

    private static func tryLock(_ descriptor: Int32, operation: Int32) throws -> Bool {
        var result: Int32
        repeat { result = flock(descriptor, operation) } while result != 0 && errno == EINTR
        if result == 0 { return true }
        if errno == EWOULDBLOCK || errno == EAGAIN { return false }
        throw posixError()
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
