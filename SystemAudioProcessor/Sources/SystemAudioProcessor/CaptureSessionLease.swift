import Darwin
import Foundation

// Darwin's Swift overlay exposes the POSIX `struct flock` under the same name.
// Bind the BSD function explicitly; its ABI is two C ints returning a C int.
@_silgen_name("flock")
private func captureSessionFlock(_ descriptor: CInt, _ operation: CInt) -> CInt

/// One capture owner per macOS user, including independent instances in the
/// same process. All operations are control-plane only; never use on an audio
/// callback. Every acquisition opens a separate file description for flock.
final class CaptureSessionLease: @unchecked Sendable {
    enum Failure: Error, CustomStringConvertible, LocalizedError {
        case alreadyOwned
        case abandoned
        case unsafePath
        case system(String, Int32)

        var description: String {
            switch self {
            case .alreadyOwned:
                return "이미 실행 중인 LowEnd 오디오 처리 세션이 있습니다. 다른 LowEnd 앱에서 처리를 중지한 뒤 다시 적용하세요."
            case .abandoned:
                return "오디오 정리가 끝나지 않아 잠금을 유지하고 있습니다. 앱을 완전히 종료한 뒤 다시 실행하세요."
            case .unsafePath:
                return "오디오 처리 잠금 경로의 소유자·형식·권한을 확인하지 못했습니다. 중복 처리를 막기 위해 시작하지 않았습니다."
            case .system(let operation, let code):
                return "오디오 처리 잠금을 준비하지 못했습니다 (\(operation), 오류 \(code)). 중복 처리를 막기 위해 시작하지 않았습니다."
            }
        }
        var errorDescription: String? { description }
    }

    private let stateLock = NSLock()
    private let testDirectory: URL?
    private var descriptor: Int32 = -1
    private var abandoned = false
    private static let filename = "capture.lock"
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// The override exists only for isolated checks. Production callers use
    /// CaptureSessionLease(), whose path comes from passwd rather than HOME.
    init(testDirectory: URL? = nil) { self.testDirectory = testDirectory }

    var isHeld: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return descriptor >= 0
    }

    /// Idempotent for this owner. A distinct object must contend even in the
    /// same PID. No waiting, PID polling, stale-file deletion or lock unlink.
    func acquire() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !abandoned else { throw Failure.abandoned }
        guard descriptor < 0 else { return }
        let directory = try openLeaseDirectory()
        defer { Darwin.close(directory) }
        let fd = Darwin.openat(directory, Self.filename,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw Failure.system("잠금 파일 열기", errno) }
        var acquired = false
        defer { if !acquired { Darwin.close(fd) } }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw Failure.system("잠금 파일 확인", errno) }
        guard Self.validFile(info) else { throw Failure.unsafePath }
        guard captureSessionFlock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { throw Failure.alreadyOwned }
            throw Failure.system("독점 잠금", code)
        }
        // Detect replacement between open and acquisition without unlinking or
        // replacing the persistent inode used by other cooperating processes.
        var linked = stat()
        guard Darwin.fstatat(directory, Self.filename, &linked, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw Failure.system("잠금 파일 연결 확인", errno)
        }
        guard Self.validFile(linked), linked.st_dev == info.st_dev, linked.st_ino == info.st_ino else {
            throw Failure.unsafePath
        }
        descriptor = fd
        acquired = true
    }

    /// Release only after the associated audio graph has been removed. The
    /// lock file remains in place: unlink would let another inode bypass flock.
    func release() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard descriptor >= 0, !abandoned else { return }
        let fd = descriptor
        descriptor = -1
        _ = captureSessionFlock(fd, LOCK_UN)
        _ = Darwin.close(fd)
    }

    /// One-way fail-closed transfer to process lifetime. This deliberately
    /// leaves the descriptor open even if this object is released. The kernel
    /// releases it on process exit, or on exec because it has FD_CLOEXEC.
    func abandonUntilProcessExit() {
        stateLock.lock(); defer { stateLock.unlock() }
        if descriptor >= 0 { abandoned = true }
    }

    deinit { release() }

    private static func validFile(_ value: stat) -> Bool {
        value.st_uid == geteuid()
            && value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
            && value.st_mode & mode_t(0o7777) == mode_t(0o600)
            && value.st_nlink == 1
    }

    private static func validateDirectory(_ fd: Int32, privateDirectory: Bool) throws {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0 else { throw Failure.system("잠금 디렉터리 확인", errno) }
        guard info.st_uid == geteuid(), info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              (privateDirectory ? info.st_mode & mode_t(0o7777) == mode_t(0o700)
                                : info.st_mode & mode_t(0o022) == 0) else {
            throw Failure.unsafePath
        }
    }

    private func openLeaseDirectory() throws -> Int32 {
        if let testDirectory {
            guard testDirectory.isFileURL, testDirectory.path.hasPrefix("/") else { throw Failure.unsafePath }
            let path = testDirectory.path
            if Darwin.mkdir(path, mode_t(0o700)) != 0, errno != EEXIST {
                throw Failure.system("검사 잠금 디렉터리 생성", errno)
            }
            let fd = Darwin.open(path, Self.directoryFlags)
            guard fd >= 0 else { throw Failure.system("검사 잠금 디렉터리 열기", errno) }
            do { try Self.validateDirectory(fd, privateDirectory: true); return fd }
            catch { Darwin.close(fd); throw error }
        }

        // All app/binary locations and HOME overrides resolve to this same
        // user's persistent Application Support directory. Walk with openat
        // so symbolic-link directories cannot redirect the lease namespace.
        let home = try Self.accountHomeDirectory()
        var fd = Darwin.open(home, Self.directoryFlags)
        guard fd >= 0 else { throw Failure.system("사용자 디렉터리 열기", errno) }
        do {
            try Self.validateDirectory(fd, privateDirectory: false)
            for component in ["Library", "Application Support", "LowEndCircuitCapture"] {
                if Darwin.mkdirat(fd, component, mode_t(0o700)) != 0, errno != EEXIST {
                    throw Failure.system("잠금 디렉터리 생성", errno)
                }
                let next = Darwin.openat(fd, component, Self.directoryFlags)
                guard next >= 0 else { throw Failure.system("잠금 디렉터리 열기", errno) }
                Darwin.close(fd); fd = next
                try Self.validateDirectory(fd, privateDirectory: component == "LowEndCircuitCapture")
            }
            return fd
        } catch { Darwin.close(fd); throw error }
    }

    private static func accountHomeDirectory() throws -> String {
        var size = max(16_384, Int(sysconf(_SC_GETPW_R_SIZE_MAX)))
        while size <= 1_048_576 {
            var storage = [CChar](repeating: 0, count: size)
            var account = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var home: String?
            let code = storage.withUnsafeMutableBufferPointer { buffer in
                let code = getpwuid_r(geteuid(), &account, buffer.baseAddress!, buffer.count, &result)
                if code == 0, result != nil, let directory = account.pw_dir { home = String(cString: directory) }
                return code
            }
            if code == ERANGE { size *= 2; continue }
            guard code == 0, let home, home.hasPrefix("/") else {
                throw Failure.system("사용자 홈 확인", code == 0 ? ENOENT : code)
            }
            return home
        }
        throw Failure.system("사용자 홈 확인", ERANGE)
    }
}
