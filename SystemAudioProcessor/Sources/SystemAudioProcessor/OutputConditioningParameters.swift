import Foundation

// MARK: - Output-conditioning domain types
//
// This module is intentionally independent of the existing tonal DSP (Clean /
// Circuit / HighExciter / Spatializer). It owns its own enums and parameter
// struct so it can be developed, tested, and eventually wired (or unwired)
// without touching the tonal pipeline.
//
// Real-time-safety note: these plain value types are the *source* of truth on
// the UI / manager thread. They are never read directly from the audio thread.
// They are flattened into `LCOutputConditioningSettings` (see AudioRingBufferC.h)
// and handed to the audio thread through the existing lock-free SPSC control
// event queue — the same proven bridge used by the DSP / spatial parameters.

/// Selects what the conditioning layer does to the post-tonal-DSP signal before
/// it reaches the output device.
enum OutputConditioningMode: UInt32, CaseIterable {
    /// Identity pass-through. The live output is untouched. This is the only
    /// mode that is actually exercised on the live audio path in this iteration.
    case bypass = 0
    /// Integer polyphase oversampling (2x / 4x / 8x). Rate-changing: producing
    /// a live result requires switching the output device format, which is out
    /// of scope here, so it runs in the offline harness only.
    case pcmOversampling = 1
    /// Same-rate dither / noise shaping (and headroom) without a rate change.
    /// Kept as a structural placeholder; on the Float32 live output it is a no-op.
    case pcmWithDither = 2
    /// Experimental PCM -> delta-sigma -> DoP. Offline / testable only; never
    /// enabled on the live path in this iteration.
    case experimentalDSD = 3

    var displayName: String {
        switch self {
        case .bypass: return "Bypass"
        case .pcmOversampling: return "PCM Oversampling"
        case .pcmWithDither: return "PCM + Dither"
        case .experimentalDSD: return "Experimental DSD / DoP"
        }
    }
}

/// Target DSD rate family. `off` keeps the path purely PCM.
enum DSDMode: UInt32, CaseIterable {
    case off = 0
    case dsd64 = 64
    case dsd128 = 128
    case dsd256 = 256

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .dsd64: return "DSD64"
        case .dsd128: return "DSD128"
        case .dsd256: return "DSD256"
        }
    }

    /// The DSD bit-stream clock rate in Hz for this family.
    /// DSD64 = 2.8224 MHz, DSD128 = 5.6448 MHz, DSD256 = 11.2896 MHz.
    var bitStreamRate: Double {
        switch self {
        case .off: return 0
        case .dsd64: return 2_822_400
        case .dsd128: return 5_644_800
        case .dsd256: return 11_289_600
        }
    }
}

/// Polyphase FIR filter character used by `PCMResampler`.
enum ResamplingFilterMode: UInt32, CaseIterable {
    /// Short linear-phase FIR (lower latency, moderate stop-band attenuation).
    case linearPhaseShort = 0
    /// Long linear-phase FIR (sharper cut-off, more attenuation, higher latency/CPU).
    case linearPhaseLong = 1
    /// Minimum-phase. API/structure only in this iteration — it falls back to
    /// the short linear-phase coefficient set so the surface is stable while the
    /// real minimum-phase design (Hilbert/cepstral method) is left for later.
    case minimumPhaseExperimental = 2

    var displayName: String {
        switch self {
        case .linearPhaseShort: return "Linear Phase Short"
        case .linearPhaseLong: return "Linear Phase Long"
        case .minimumPhaseExperimental: return "Minimum Phase (Experimental)"
        }
    }

    /// Number of taps per polyphase branch. More taps = sharper / heavier.
    var tapsPerPhase: Int {
        switch self {
        case .linearPhaseShort: return 32
        case .linearPhaseLong: return 128
        // Same tap count as short until a real minimum-phase design lands.
        case .minimumPhaseExperimental: return 32
        }
    }

    var isImplemented: Bool {
        switch self {
        case .linearPhaseShort, .linearPhaseLong: return true
        case .minimumPhaseExperimental: return false
        }
    }
}

/// DoP (DSD-over-PCM) carrier helpers. The DoP open standard packs 8 DSD bits
/// into the least-significant byte of a PCM carrier sample, with a marker byte
/// (0x05 / 0xFA alternating) in the most-significant byte. For stereo, one DoP
//  sample *frame* spans one carrier sample per channel.
enum DoPCarrier {
    /// PCM carrier sample rate required to clock a given DSD family out as DoP.
    /// DSD64 -> 176.4 kHz, DSD128 -> 352.8 kHz, DSD256 -> 705.6 kHz carrier.
    /// (8 DSD bits packed per carrier sample, so carrierRate = bitStreamRate / 8.)
    static func requiredCarrierRate(for dsdMode: DSDMode) -> Double {
        switch dsdMode {
        case .off: return 0
        case .dsd64: return 176_400
        case .dsd128: return 352_800
        case .dsd256: return 705_600
        }
    }

    /// Bytes per PCM carrier sample in the packed DoP stream. We use the 32-bit
    /// (4-byte) carrier layout: [dsdByte, 0x00, 0x00, markerByte].
    static let carrierSampleBytes = 4

    /// The marker byte toggled into the MSB of successive DoP sample frames.
    static let markerA: UInt8 = 0xFA
    static let markerB: UInt8 = 0x05
}

/// High-level parameters for the output-conditioning layer. This is the UI-side
/// value type; it is flattened into `LCOutputConditioningSettings` before it
/// crosses onto the audio thread.
struct OutputConditioningParameters: Equatable {
    var isEnabled: Bool = false
    var outputMode: OutputConditioningMode = .bypass
    var oversamplingFactor: Int = 2
    var filterMode: ResamplingFilterMode = .linearPhaseShort
    /// Output attenuation applied before any clipping / delta-sigma modulation.
    /// Default -3.0 dB to protect the modulator and downstream DAC from overload.
    var headroomDB: Float = -3.0
    var ditherEnabled: Bool = false
    var noiseShapingEnabled: Bool = false
    var dsdMode: DSDMode = .off

    /// Linear gain corresponding to `headroomDB` (e.g. -3 dB -> ~0.7079).
    var headroomGain: Float {
        pow(10.0, headroomDB / 20.0)
    }

    /// Allowed integer oversampling factors for the picker / validation.
    static let allowedOversamplingFactors: [Int] = [2, 4, 8]

    init() {}

    init(isEnabled: Bool,
         outputMode: OutputConditioningMode,
         oversamplingFactor: Int,
         filterMode: ResamplingFilterMode,
         headroomDB: Float,
         ditherEnabled: Bool,
         noiseShapingEnabled: Bool,
         dsdMode: DSDMode) {
        self.isEnabled = isEnabled
        self.outputMode = outputMode
        self.oversamplingFactor = OutputConditioningParameters
            .clampFactor(oversamplingFactor)
        self.filterMode = filterMode
        self.headroomDB = headroomDB
        self.ditherEnabled = ditherEnabled
        self.noiseShapingEnabled = noiseShapingEnabled
        self.dsdMode = dsdMode
    }

    /// Clamp an arbitrary integer to the nearest supported oversampling factor.
    static func clampFactor(_ value: Int) -> Int {
        guard let nearest = allowedOversamplingFactors.min(
            by: { abs($0 - value) < abs($1 - value) }
        ) else { return 2 }
        return nearest
    }
}
