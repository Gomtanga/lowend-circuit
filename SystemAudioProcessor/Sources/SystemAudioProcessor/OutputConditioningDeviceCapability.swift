import CoreAudio
import Foundation

/// Reports whether the current output device can actually receive the carrier
/// formats the conditioning layer might produce (DoP carrier sample rates and a
/// wide-enough PCM bit depth). The result drives UI enablement: DSD/DoP is
/// disabled when the DAC cannot accept the required carrier rate.
///
/// All CoreAudio property queries here run **off** the audio thread (UI / manager
/// thread). The audio callback never performs device-format negotiation — it is
/// a hard rule that failures simply fall back to PCM.
struct OutputConditioningCapability: Equatable {
    /// For each DSD family, whether the required DoP carrier rate is supported.
    let supportedCarriers: [DSDMode: Bool]
    /// Best-effort: does at least one output stream advertise a 24- or 32-bit
    /// physical PCM format (required to carry the DoP marker + DSD byte)?
    let supportsWideCarrierBitDepth: Bool
    /// Full supported-rate list from the device (for display / preview).
    let supportedRates: [Double]
    let isRateSettable: Bool
    let deviceID: AudioObjectID

    /// A DSD/DoP family is only attemptable when the carrier rate is supported
    /// AND the device advertises a wide-enough carrier bit depth.
    func canAttemptDoP(_ mode: DSDMode) -> Bool {
        guard mode != .off else { return false }
        let carrierOK = supportedCarriers[mode] ?? false
        return carrierOK && supportsWideCarrierBitDepth
    }

    /// PCM 2× live oversampling doubles the eligible input rate. Returns the
    /// target output rate for a given tap (input) rate, or nil if that rate is
    /// not eligible — this PR supports only 44.1k→88.2k and 48k→96k. Any other
    /// input rate bypasses live oversampling entirely.
    static func livePCM2xTargetRate(forTapRate tapRate: Double) -> Double? {
        if abs(tapRate - 44_100) < 0.5 { return 88_200 }
        if abs(tapRate - 48_000) < 0.5 { return 96_000 }
        return nil
    }

    /// Whether the output device can run the live PCM 2× path for the given tap
    /// rate: the doubled output rate must be advertised AND the device rate must
    /// be settable (the reconfigure path switches the DAC to 2×). If not, the
    /// mode cannot activate and must fall back to PCM bypass.
    func canAttemptLivePCM2x(tapRate: Double) -> Bool {
        guard let target = Self.livePCM2xTargetRate(forTapRate: tapRate) else { return false }
        return isRateSettable
            && supportedRates.contains { abs($0 - target) < 0.5 }
    }

    /// The target output rate for the current tap rate when the device supports
    /// live PCM 2×, otherwise nil. Convenience for the UI / negotiation path.
    func livePCM2xTargetRateIfSupported(tapRate: Double) -> Double? {
        canAttemptLivePCM2x(tapRate: tapRate)
            ? Self.livePCM2xTargetRate(forTapRate: tapRate)
            : nil
    }

    /// Conservative empty result used when the device cannot be queried.
    static func unknown(deviceID: AudioObjectID) -> OutputConditioningCapability {
        OutputConditioningCapability(
            supportedCarriers: [.off: true],
            supportsWideCarrierBitDepth: true,
            supportedRates: [],
            isRateSettable: false,
            deviceID: deviceID
        )
    }
}

enum OutputConditioningCapabilityQuery {
    /// Query a specific device. Runs on the caller's (non-audio) thread.
    static func query(deviceID: AudioObjectID) -> OutputConditioningCapability {
        guard deviceID != kAudioObjectUnknown else {
            return .unknown(deviceID: kAudioObjectUnknown)
        }
        let capabilities: HardwareSampleRateTracker.RateCapabilities
        do {
            capabilities = try HardwareSampleRateTracker.rateCapabilities(for: deviceID)
        } catch {
            return .unknown(deviceID: deviceID)
        }

        var supported: [DSDMode: Bool] = [.off: true]
        for mode in [DSDMode.dsd64, .dsd128, .dsd256] {
            let carrier = DoPCarrier.requiredCarrierRate(for: mode)
            supported[mode] = capabilities.supportedRates.contains { abs($0 - carrier) < 0.5 }
        }

        let wideBits = supportsWidePhysicalBitDepth(deviceID: deviceID)
        return OutputConditioningCapability(
            supportedCarriers: supported,
            supportsWideCarrierBitDepth: wideBits,
            supportedRates: capabilities.supportedRates,
            isRateSettable: capabilities.isSettable,
            deviceID: deviceID
        )
    }

    /// Query the system default output device.
    static func queryDefaultOutput() -> OutputConditioningCapability {
        let deviceID: AudioObjectID
        do {
            deviceID = try HardwareSampleRateTracker.defaultOutputDevice()
        } catch {
            return .unknown(deviceID: kAudioObjectUnknown)
        }
        return query(deviceID: deviceID)
    }

    // MARK: - Physical bit-depth probe

    /// Best-effort: returns true if any output stream advertises a 24- or 32-bit
    /// physical PCM format. On total query failure (no streams / no format data),
    /// returns true so we do not block DoP merely because we could not introspect
    /// the device. If we DID probe at least one stream successfully and none
    /// advertised a wide format, returns false.
    private static func supportsWidePhysicalBitDepth(deviceID: AudioObjectID) -> Bool {
        guard let streamIDs = outputStreamIDs(deviceID: deviceID), !streamIDs.isEmpty else {
            return true
        }
        var probedAnySuccessfully = false
        for streamID in streamIDs {
            guard let depths = availablePhysicalBitDepths(streamID: streamID) else { continue }
            probedAnySuccessfully = true
            if depths.contains(where: { $0 == 24 || $0 == 32 }) {
                return true
            }
        }
        // Probed but found no wide format -> not supported. All probes failed -> fallback true.
        return !probedAnySuccessfully
    }

    private static func outputStreamIDs(deviceID: AudioObjectID) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard ids.withUnsafeMutableBufferPointer({ ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, base) == noErr
        }) else {
            return nil
        }
        return ids
    }

    private static func availablePhysicalBitDepths(streamID: AudioObjectID) -> [UInt32]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyAvailablePhysicalFormats,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(streamID, &address, 0, nil, &size) == noErr,
              size > 0 else {
            return nil
        }
        let count = Int(size) / MemoryLayout<AudioStreamRangedDescription>.stride
        var ranges = [AudioStreamRangedDescription](
            repeating: AudioStreamRangedDescription(),
            count: count
        )
        guard ranges.withUnsafeMutableBufferPointer({ ptr -> Bool in
            guard let base = ptr.baseAddress else { return false }
            return AudioObjectGetPropertyData(streamID, &address, 0, nil, &size, base) == noErr
        }) else {
            return nil
        }
        return ranges.map { $0.mFormat.mBitsPerChannel }
    }
}
