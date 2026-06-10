import AudioRingBufferC
import LowEndDSPCoreC

final class SharedDSPCore {
    private let handle: OpaquePointer

    init(sampleRate: Double, maxChannels: UInt32 = 2) throws {
        guard let handle = lc_dsp_core_create() else {
            throw AppError.message("Could not allocate shared DSP core.")
        }
        self.handle = handle
        lc_dsp_core_prepare(handle, sampleRate, maxChannels)
    }

    deinit {
        lc_dsp_core_destroy(handle)
    }

    func update(_ settings: LCDSPSettings) {
        var settings = settings
        withUnsafePointer(to: &settings) {
            lc_dsp_core_update(handle, $0)
        }
    }

    func process(left: UnsafeMutablePointer<Float>,
                 right: UnsafeMutablePointer<Float>,
                 frameCount: Int) {
        lc_dsp_core_process_stereo(handle, left, right, UInt32(max(frameCount, 0)))
    }

    func reset() {
        lc_dsp_core_reset(handle)
    }
}
