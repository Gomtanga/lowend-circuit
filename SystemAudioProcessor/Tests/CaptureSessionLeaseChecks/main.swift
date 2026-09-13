import Darwin
import Foundation

func report(_ text: String) { print(text); fflush(stdout) }
func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw NSError(domain: "CaptureSessionLeaseChecks", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    guard CommandLine.arguments.count == 3 else { throw CaptureSessionLease.Failure.unsafePath }
    let mode = CommandLine.arguments[1]
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    switch mode {
    case "probe":
        let lease = CaptureSessionLease(testDirectory: directory)
        try require(!lease.isHeld, "unexpected initial ownership")
        try lease.acquire()
        try require(lease.isHeld, "acquire did not hold")
        lease.release()
        try require(!lease.isHeld, "release did not clear")
        report("ACQUIRED pid=\(getpid())")
    case "same-pid":
        let first = CaptureSessionLease(testDirectory: directory)
        let second = CaptureSessionLease(testDirectory: directory)
        try first.acquire(); try first.acquire()
        var rejected = false
        do { try second.acquire() }
        catch CaptureSessionLease.Failure.alreadyOwned { rejected = true }
        try require(rejected && first.isHeld && !second.isHeld, "same-PID owners failed to contend")
        first.release(); first.release()
        try second.acquire(); second.release()
        report("SAME_PID_PASS pid=\(getpid())")
    case "holder":
        var lease: CaptureSessionLease? = CaptureSessionLease(testDirectory: directory)
        try lease!.acquire()
        report("HELD pid=\(getpid())")
        while let command = readLine() {
            switch command {
            case "release": lease!.release(); report("RELEASED")
            case "deinit": lease = nil; report("DEINITIALIZED")
            case "abandon":
                lease!.abandonUntilProcessExit()
                lease!.release()
                try require(lease!.isHeld, "abandon allowed explicit release")
                lease = nil
                report("ABANDONED")
            case "crash":
                report("CRASHING")
                raise(SIGKILL)
                _exit(93)
            case "quit":
                lease?.release()
                report("EXITING")
                exit(0)
            default: throw CaptureSessionLease.Failure.unsafePath
            }
        }
        lease?.release()
    case "exec":
        let lease = CaptureSessionLease(testDirectory: directory)
        try lease.acquire()
        report("EXEC_HELD pid=\(getpid())")
        let arguments = [CommandLine.arguments[0], "probe", directory.path]
        var pointers = arguments.map { strdup($0) } + [nil]
        defer { for pointer in pointers { free(pointer) } }
        let result = withExtendedLifetime(lease) {
            pointers.withUnsafeMutableBufferPointer { execv(arguments[0], $0.baseAddress!) }
        }
        throw CaptureSessionLease.Failure.system("검사 exec", result == -1 ? errno : EINVAL)
    default: throw CaptureSessionLease.Failure.unsafePath
    }
} catch CaptureSessionLease.Failure.alreadyOwned {
    report("BUSY")
    exit(23)
} catch {
    report("REJECTED \(error)")
    exit(24)
}
