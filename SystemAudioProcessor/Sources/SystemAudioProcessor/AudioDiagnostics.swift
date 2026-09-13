import Foundation

/// Read the tap's own membership, never infer capture from all running apps.
/// A process can disappear between the membership and identity reads; fail the
/// observation instead of presenting a partial list as the complete target.
enum CaptureTargetSummary {
    struct Identity {
        let pid: Int32
        let bundleID: String
    }

    static func read(processes: () throws -> [UInt32],
                     identity: (UInt32) throws -> Identity) throws -> String {
        let ids = try Set(processes()).sorted()
        guard !ids.isEmpty else { return "연결된 캡처 프로세스 없음" }
        return try ids.map { id in
            let process = try identity(id)
            guard id != 0, process.pid > 0, !process.bundleID.isEmpty else {
                throw AppError.message("캡처 프로세스 정보가 변경되었거나 유효하지 않습니다.")
            }
            return "\(process.bundleID) (pid \(process.pid))"
        }.joined(separator: ", ")
    }
}

/// Counts actual PCM since this capture graph was installed. Underrun padding
/// is excluded by the ring's read counter, while legitimate silent PCM counts.
struct AudioFlowProgress: Sendable, Equatable {
    var generation: UInt64 = 0
    var producedSamples: UInt64 = 0
    var consumedSamples: UInt64 = 0

    var isConfirmed: Bool { generation > 0 && producedSamples > 0 && consumedSamples > 0 }
    var displayText: String {
        if isConfirmed { return "입력·출력 데이터 확인" }
        if producedSamples > 0 { return "출력 데이터 대기" }
        return "오디오 데이터 대기"
    }
    static let waitingHelp = "음원을 재생하고 시스템 오디오 접근 요청이 있으면 허용해 주세요. 입력과 출력 데이터가 진행되면 상태가 갱신됩니다."
}

struct AudioDiagnosticsSnapshot: Sendable {
    let outputUnderrunSamples: UInt64
    let outputDroppedSamples: UInt64
    let visualizerDroppedSamples: UInt64
    let engineRestartCount: UInt64
    let captureTarget: String
    let audioFlow: AudioFlowProgress

    var displayText: String {
        "XRuns out \(outputUnderrunSamples) / drop \(outputDroppedSamples) / analysis \(visualizerDroppedSamples) | restart \(engineRestartCount) | \(captureTarget)"
    }
}
