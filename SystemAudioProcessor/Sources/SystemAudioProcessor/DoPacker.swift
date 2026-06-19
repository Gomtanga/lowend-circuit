import Foundation

/// Packs a 1-bit DSD/PDM stream into DoP (DSD-over-PCM) carrier frames per the
/// DoP open standard v1.0.
///
/// Frame layout (this implementation uses a 32-bit / 4-byte PCM carrier, the
/// most common case for USB/DSD DACs):
///
/// ```
/// per DoP sample frame (stereo), 8 bytes, interleaved L then R:
///
///   [ DSD_L ][ 0x00 ][ 0x00 ][ marker ]   <- left carrier sample (LE u32)
///   [ DSD_R ][ 0x00 ][ 0x00 ][ marker ]   <- right carrier sample (LE u32)
/// ```
///
/// where:
/// * `DSD_x` holds 8 consecutive DSD bits packed **MSB-first** (bit 7 = earliest
///   in time), per the DoP spec;
/// * `marker` alternates per DoP sample *frame* (both channels of one frame share
///   the same marker), toggling `0xFA` -> `0x05` -> `0xFA` ... so the DAC can lock
///   onto 8-sample frame boundaries.
///
/// Real-time contract: `pack(...)` writes into a caller-owned output buffer using
/// only scalar arithmetic and pointer writes — no allocation, no locks. It is
/// reached only from the offline/test pipeline in this iteration.
final class DoPacker {
    /// Channel interleaving supported by the packer.
    enum ChannelLayout { case mono, stereo }

    let channelLayout: ChannelLayout

    init(channelLayout: ChannelLayout = .stereo) {
        self.channelLayout = channelLayout
    }

    var channelCount: Int {
        channelLayout == .stereo ? 2 : 1
    }

    /// Number of output bytes a full pack of `dsdFrames` DSD bits will produce.
    /// `dsdFrames` is rounded down to a multiple of 8 (one DSD byte per 8 bits).
    func outputByteCount(forDsdFrames dsdFrames: Int) -> Int {
        let carrierFrames = dsdFrames / 8
        return carrierFrames * channelCount * DoPCarrier.carrierSampleBytes
    }

    /// Pack the per-channel DSD bit streams into interleaved DoP bytes.
    ///
    /// - Parameters:
    ///   - leftBits: `dsdFrames` bytes, each 0 or 1 (DSD bits for the left channel).
    ///   - rightBits: `dsdFrames` bytes for the right channel (ignored in mono).
    ///   - dsdFrames: number of DSD bits per channel. Must be a multiple of 8 for a
    ///     clean pack; any trailing partial byte is ignored.
    ///   - output: caller-owned buffer of at least `outputByteCount(forDsdFrames:)`.
    /// - Returns: number of bytes written to `output`, or 0 on invalid arguments.
    @discardableResult
    func pack(leftBits: UnsafePointer<UInt8>,
              rightBits: UnsafePointer<UInt8>?,
              dsdFrames: Int,
              output: UnsafeMutablePointer<UInt8>) -> Int {
        guard dsdFrames >= 8 else { return 0 }
        let carrierFrames = dsdFrames / 8
        let bytesPerSample = DoPCarrier.carrierSampleBytes
        let ch = channelCount
        var outIndex = 0

        for t in 0..<carrierFrames {
            let dsdL = packByte(bits: leftBits, baseBitIndex: t * 8)
            let marker: UInt8 = (t & 1) == 0 ? DoPCarrier.markerA : DoPCarrier.markerB

            // Left carrier sample (LE): [dsd, 0, 0, marker].
            output[outIndex] = dsdL;          outIndex &+= 1
            output[outIndex] = 0x00;          outIndex &+= 1
            output[outIndex] = 0x00;          outIndex &+= 1
            output[outIndex] = marker;        outIndex &+= 1

            if ch == 2 {
                let dsdR = packByte(bits: rightBits!, baseBitIndex: t * 8)
                output[outIndex] = dsdR;      outIndex &+= 1
                output[outIndex] = 0x00;      outIndex &+= 1
                output[outIndex] = 0x00;      outIndex &+= 1
                output[outIndex] = marker;    outIndex &+= 1
            }
        }
        return carrierFrames * ch * bytesPerSample
    }

    /// Verify the marker alternation on an already-packed buffer.
    ///
    /// For stereo: every DoP frame's left and right carrier samples must carry
    /// the same marker, and the marker must toggle 0xFA / 0x05 across frames.
    /// Returns the number of frames inspected, or 0 if a violation is found
    /// (callers treat 0 on a non-empty buffer as a failure).
    @discardableResult
    func verifyMarkers(output: UnsafePointer<UInt8>, byteCount: Int) -> Int {
        let bytesPerSample = DoPCarrier.carrierSampleBytes
        let ch = channelCount
        let frameBytes = ch * bytesPerSample
        guard frameBytes > 0, byteCount % frameBytes == 0 else { return 0 }
        let frames = byteCount / frameBytes
        for t in 0..<frames {
            let expected: UInt8 = (t & 1) == 0 ? DoPCarrier.markerA : DoPCarrier.markerB
            let frameBase = t * frameBytes
            // Marker byte is the last byte of each carrier sample.
            let markerL = output[frameBase + bytesPerSample - 1]
            if markerL != expected { return 0 }
            if ch == 2 {
                let markerR = output[frameBase + bytesPerSample + (bytesPerSample - 1)]
                if markerR != expected { return 0 }
            }
        }
        return frames
    }

    /// Pack 8 DSD bits (each 0/1) into one byte, MSB-first per the DoP spec.
    private func packByte(bits: UnsafePointer<UInt8>, baseBitIndex: Int) -> UInt8 {
        var byte: UInt8 = 0
        byte |= (bits[baseBitIndex    ] & 1) << 7
        byte |= (bits[baseBitIndex + 1] & 1) << 6
        byte |= (bits[baseBitIndex + 2] & 1) << 5
        byte |= (bits[baseBitIndex + 3] & 1) << 4
        byte |= (bits[baseBitIndex + 4] & 1) << 3
        byte |= (bits[baseBitIndex + 5] & 1) << 2
        byte |= (bits[baseBitIndex + 6] & 1) << 1
        byte |= (bits[baseBitIndex + 7] & 1)
        return byte
    }
}
