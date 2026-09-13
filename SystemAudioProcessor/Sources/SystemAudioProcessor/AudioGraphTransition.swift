import Foundation

struct AudioGraphTransitionFailure: Error, CustomStringConvertible {
    let cause: Error
    let recoveryFailure: Error?
    var recovered: Bool { recoveryFailure == nil }
    var description: String {
        if let recoveryFailure {
            return "전환 실패: \(cause). 복구 실패로 출력 정지: \(recoveryFailure)"
        }
        return "전환 실패 후 PCM 복구 완료: \(cause)"
    }
}

/// Runs on the manager queue. All direct DSP mutation and graph creation occur
/// only inside install closures, after quiesce stopped both audio callbacks.
/// Injectable operations exercise the exact production rollback order in tests.
enum AudioGraphTransition {
    struct Operations {
        var fadeOut: () throws -> Void
        var quiesce: () throws -> Void
        var installTarget: () throws -> Void
        var installRollback: () throws -> Void
        var verifyFlow: () throws -> Void
        var fadeIn: () throws -> Void
    }

    static func run(_ operations: Operations) throws {
        var quiescing = false
        do {
            try operations.fadeOut()
            quiescing = true
            try operations.quiesce()
            quiescing = false
            try operations.installTarget()
            try operations.verifyFlow()
            try operations.fadeIn()
        } catch {
            // An installer can already have tried and failed to quiesce its
            // partial graph. That is the same barrier failure as the explicit
            // quiesce step; retrying here could reset/reinstall preserved state.
            if let failure = error as? AudioGraphTransitionFailure, !failure.recovered {
                throw failure
            }
            let cause = error
            // A teardown failure is a barrier failure, not an install failure.
            // Do not retry it implicitly or attempt any replacement graph.
            if quiescing { throw AudioGraphTransitionFailure(cause: cause, recoveryFailure: error) }
            // Includes late failures with a fully running target graph.
            do { try operations.quiesce() }
            catch { throw AudioGraphTransitionFailure(cause: cause, recoveryFailure: error) }
            do {
                try operations.installRollback()
                try operations.verifyFlow()
                try operations.fadeIn()
            } catch {
                let recoveryFailure = error
                if let failure = error as? AudioGraphTransitionFailure, !failure.recovered {
                    throw AudioGraphTransitionFailure(cause: cause, recoveryFailure: failure)
                }
                do { try operations.quiesce() }
                catch { throw AudioGraphTransitionFailure(cause: cause, recoveryFailure: error) }
                throw AudioGraphTransitionFailure(cause: cause, recoveryFailure: recoveryFailure)
            }
            throw AudioGraphTransitionFailure(cause: cause, recoveryFailure: nil)
        }
    }
}
