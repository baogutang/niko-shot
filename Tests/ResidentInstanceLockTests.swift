// Verifies resident exclusion, descriptor teardown, PID lookup and unsafe-path protection in isolated temporary files.
import Darwin
import Foundation
import XCTest
@testable import NikoShot

final class ResidentInstanceLockTests: XCTestCase {
    func testRepeatedAcquisitionAndReleasePreserveTheSameLockInode() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("resident.lock")
            var first: ResidentInstanceLock? = try XCTUnwrap(ResidentInstanceLock.acquire(at: url))
            weak let weakFirst = first
            var original = stat()
            XCTAssertEqual(lstat(url.path, &original), 0)
            XCTAssertEqual(original.st_mode & 0o7777, 0o600)
            XCTAssertNil(try ResidentInstanceLock.acquire(at: url))
            XCTAssertEqual(ResidentInstanceLock.currentPID(at: url), getpid())

            first = nil
            XCTAssertNil(weakFirst)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Releasing a lock must not unlink its inode")
            XCTAssertNil(ResidentInstanceLock.currentPID(at: url), "A stale PID in an unlocked file is not a resident")
            var second: ResidentInstanceLock? = try XCTUnwrap(ResidentInstanceLock.acquire(at: url))
            weak let weakSecond = second
            var restored = stat()
            XCTAssertEqual(lstat(url.path, &restored), 0)
            XCTAssertEqual(original.st_ino, restored.st_ino)
            XCTAssertEqual(ResidentInstanceLock.currentPID(at: url), getpid())
            second = nil
            XCTAssertNil(weakSecond)
            XCTAssertNil(ResidentInstanceLock.currentPID(at: url))
        }
    }

    func testPIDLookupRequiresAnOccupiedLockAndALivePositivePID() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("resident.lock")
            XCTAssertNil(ResidentInstanceLock.currentPID(at: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "Lookup must not create a file")
            let descriptor = open(url.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, mode_t(0o600))
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            guard descriptor >= 0 else { return }
            defer { _ = close(descriptor) }
            try writePID(getpid(), descriptor: descriptor)
            XCTAssertNil(ResidentInstanceLock.currentPID(at: url))
            XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
            XCTAssertEqual(ResidentInstanceLock.currentPID(at: url), getpid())
            for pid in [Int32.max, 0, -1] {
                try writePID(pid, descriptor: descriptor)
                XCTAssertNil(ResidentInstanceLock.currentPID(at: url))
            }
            XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        }
    }

    func testUnsafeFilesAreRejectedWithoutChangingTheirContents() throws {
        try withTemporaryDirectory { directory in
            let sentinel = directory.appendingPathComponent("sentinel")
            let original = Data("private-sentinel\n".utf8)
            try original.write(to: sentinel)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sentinel.path)
            let symbolic = directory.appendingPathComponent("symbolic.lock")
            try FileManager.default.createSymbolicLink(at: symbolic, withDestinationURL: sentinel)
            XCTAssertThrowsError(try ResidentInstanceLock.acquire(at: symbolic))
            XCTAssertNil(ResidentInstanceLock.currentPID(at: symbolic))
            XCTAssertEqual(try Data(contentsOf: sentinel), original)

            let hardLink = directory.appendingPathComponent("hard.lock")
            XCTAssertEqual(link(sentinel.path, hardLink.path), 0)
            XCTAssertThrowsError(try ResidentInstanceLock.acquire(at: hardLink))
            XCTAssertNil(ResidentInstanceLock.currentPID(at: hardLink))
            XCTAssertEqual(try Data(contentsOf: sentinel), original)

            let readable = directory.appendingPathComponent("readable.lock")
            try original.write(to: readable)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: readable.path)
            XCTAssertThrowsError(try ResidentInstanceLock.acquire(at: readable))
            XCTAssertNil(ResidentInstanceLock.currentPID(at: readable))
            XCTAssertEqual(try Data(contentsOf: readable), original)

            let fifo = directory.appendingPathComponent("fifo.lock")
            XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
            XCTAssertThrowsError(try ResidentInstanceLock.acquire(at: fifo))
            XCTAssertNil(ResidentInstanceLock.currentPID(at: fifo))
            XCTAssertThrowsError(try ResidentInstanceLock.acquire(at: directory))
            XCTAssertNil(ResidentInstanceLock.currentPID(at: directory))
        }
    }

    private func writePID(_ pid: Int32, descriptor: Int32) throws {
        guard ftruncate(descriptor, 0) == 0 else { throw POSIXError(.EIO) }
        let bytes = Array("\(pid)\n".utf8)
        let count = bytes.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return pwrite(descriptor, base, buffer.count, 0)
        }
        XCTAssertEqual(count, bytes.count)
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("niko-shot-resident-lock-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
