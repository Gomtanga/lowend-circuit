import Foundation

/// Stateful DoP 1.1 packer for the offline/test path. Each channel contributes
/// 16 chronological DSD bits, MSB first, to a 24-bit word below its marker.
/// The word is right-aligned in a 32-bit little-endian container:
/// `[payloadLow, payloadHigh, marker, 0]`. Stereo interleaves L then R.
///
/// Partial payloads and marker phase survive block boundaries. `reset()` starts
/// a new stream and discards an unfinished payload; no implicit zero padding is
/// emitted. This format contract does not enable a live DSD output transport.
/// All processing state is scalar and packing performs no allocation or locks.
final class DoPacker {
    enum ChannelLayout { case mono, stereo }

    let channelLayout: ChannelLayout
    private var leftPayload: UInt16 = 0
    private var rightPayload: UInt16 = 0
    private var pendingBits = 0
    private var nextMarker = DoPCarrier.markerA

    init(channelLayout: ChannelLayout = .stereo) {
        self.channelLayout = channelLayout
    }

    var channelCount: Int { channelLayout == .stereo ? 2 : 1 }

    /// Exact output capacity for the next call, including pending payload bits.
    /// The result is zero for negative or unrepresentably large frame counts.
    func outputByteCount(forDsdFrames dsdFrames: Int) -> Int {
        guard dsdFrames >= 0 else { return 0 }
        let (total, overflow) = dsdFrames.addingReportingOverflow(pendingBits)
        guard !overflow else { return 0 }
        let frames = total / DoPCarrier.payloadBitsPerSample
        let (bytes, bytesOverflow) = frames.multipliedReportingOverflow(
            by: channelCount * DoPCarrier.carrierSampleBytes)
        return bytesOverflow ? 0 : bytes
    }

    /// Pack bytes containing 0/1 bits. `output` must hold `outputByteCount` for
    /// this call; a nonempty input can produce zero bytes while retaining bits.
    /// A missing stereo right channel is invalid and leaves all state unchanged.
    @discardableResult
    func pack(leftBits: UnsafePointer<UInt8>,
              rightBits: UnsafePointer<UInt8>?,
              dsdFrames: Int,
              output: UnsafeMutablePointer<UInt8>) -> Int {
        guard dsdFrames > 0, channelCount == 1 || rightBits != nil else { return 0 }
        let (total, overflow) = dsdFrames.addingReportingOverflow(pendingBits)
        guard !overflow,
              total / DoPCarrier.payloadBitsPerSample <= Int.max / (channelCount * 4) else {
            return 0
        }
        var outIndex = 0
        for i in 0..<dsdFrames {
            leftPayload = (leftPayload << 1) | UInt16(leftBits[i] & 1)
            if let rightBits, channelCount == 2 {
                rightPayload = (rightPayload << 1) | UInt16(rightBits[i] & 1)
            }
            pendingBits += 1
            if pendingBits == DoPCarrier.payloadBitsPerSample {
                write(leftPayload, into: output.advanced(by: outIndex))
                outIndex += DoPCarrier.carrierSampleBytes
                if channelCount == 2 {
                    write(rightPayload, into: output.advanced(by: outIndex))
                    outIndex += DoPCarrier.carrierSampleBytes
                }
                nextMarker = nextMarker == DoPCarrier.markerA
                    ? DoPCarrier.markerB : DoPCarrier.markerA
                pendingBits = 0
                leftPayload = 0
                rightPayload = 0
            }
        }
        return outIndex
    }

    @inline(__always)
    private func write(_ payload: UInt16, into output: UnsafeMutablePointer<UInt8>) {
        output[0] = UInt8(truncatingIfNeeded: payload)
        output[1] = UInt8(truncatingIfNeeded: payload >> 8)
        output[2] = nextMarker
        output[3] = 0
    }

    func reset() {
        leftPayload = 0
        rightPayload = 0
        pendingBits = 0
        nextMarker = DoPCarrier.markerA
    }

    /// Validate a complete buffer independently of the current packing state.
    /// A slice may start with either valid marker; subsequent frames must toggle.
    /// Optional `startingMarker` also verifies its phase within a larger stream.
    @discardableResult
    func verifyMarkers(output: UnsafePointer<UInt8>, byteCount: Int,
                       startingMarker: UInt8? = nil) -> Int {
        let frameBytes = channelCount * DoPCarrier.carrierSampleBytes
        guard byteCount > 0, byteCount % frameBytes == 0 else { return 0 }
        var expected = startingMarker ?? output[DoPCarrier.markerByteOffset]
        guard expected == DoPCarrier.markerA || expected == DoPCarrier.markerB else { return 0 }
        let frames = byteCount / frameBytes
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let base = frame * frameBytes + channel * DoPCarrier.carrierSampleBytes
                guard output[base + DoPCarrier.markerByteOffset] == expected,
                      output[base + 3] == 0 else { return 0 }
            }
            expected = expected == DoPCarrier.markerA
                ? DoPCarrier.markerB : DoPCarrier.markerA
        }
        return frames
    }
}
