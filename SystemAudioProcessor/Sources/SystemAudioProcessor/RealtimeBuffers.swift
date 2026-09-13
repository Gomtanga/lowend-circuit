import AudioRingBufferC
import Foundation

final class LockFreeFloatRingBuffer {
    private let handle: OpaquePointer

    init(capacityFrames: Int, channels: Int) throws {
        let (samples, overflow) = max(capacityFrames, 512).multipliedReportingOverflow(by: channels)
        guard capacityFrames > 0, channels > 0, !overflow,
              let requestedSamples = UInt32(exactly: samples) else {
            throw AppError.message("Audio ring capacity is invalid or overflows UInt32.")
        }
        guard let handle = lc_ring_buffer_create(requestedSamples) else {
            throw AppError.message("Could not allocate audio ring buffer.")
        }
        self.handle = handle
    }

    deinit {
        lc_ring_buffer_destroy(handle)
    }

    func push(_ samples: UnsafePointer<Float>, count: Int) {
        guard let count = UInt32(exactly: count) else { return }
        _ = lc_ring_buffer_push(handle, samples, count)
    }

    func droppedWriteSamples() -> UInt64 {
        lc_ring_buffer_dropped_write_samples(handle)
    }

    func underrunSamples() -> UInt64 {
        lc_ring_buffer_underrun_samples(handle)
    }

    func totalWrittenSamples() -> UInt64 {
        lc_ring_buffer_total_written_samples(handle)
    }

    func totalReadSamples() -> UInt64 {
        lc_ring_buffer_total_read_samples(handle)
    }

    func resetDiagnostics() {
        lc_ring_buffer_reset_diagnostics(handle)
    }

    func availableSamples() -> Int {
        Int(lc_ring_buffer_available(handle))
    }

    func popInterleaved(into pointer: UnsafeMutablePointer<Float>, count: Int) {
        guard let count = UInt32(exactly: count) else { return }
        _ = lc_ring_buffer_pop(handle, pointer, count)
    }

    func popStereo(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frameCount: Int) {
        guard let frameCount = UInt32(exactly: frameCount) else { return }
        _ = lc_ring_buffer_pop_deinterleaved_stereo(handle, left, right, frameCount)
    }

    /// Both producer and consumer must be stopped before clear().
    func clear() { lc_ring_buffer_clear(handle) }
    func requestDiscard() { lc_ring_buffer_request_discard(handle) }
    func consumeDiscardRequest() -> Bool { lc_ring_buffer_consume_discard_request(handle) != 0 }
}
