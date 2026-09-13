import Foundation

func runPrecomputedConditioningGainChecks() throws {
    var parameters = OutputConditioningParameters()
    parameters.isEnabled = true
    parameters.outputMode = .pcmOversampling
    parameters.headroomDB = -120 // Deliberately differs from the control packet.
    let cached = ResamplingOutputConditioningEngine(maxInputFrames: 256)
    cached.updateSettings(parameters, precomputedHeadroomGain: 0.25)
    let reference = ResamplingOutputConditioningEngine(maxInputFrames: 256)
    parameters.headroomDB = 20 * log10(0.25)
    reference.updateSettings(parameters)
    let input = [Float](repeating: 0.2, count: 512)
    var actual = [Float](repeating: 0, count: 1_024)
    var expected = actual
    let actualFrames = input.withUnsafeBufferPointer { source in
        actual.withUnsafeMutableBufferPointer { output in
            cached.processLive(input: source.baseAddress!, inputFrames: 256, output: output.baseAddress!)
        }
    }
    let expectedFrames = input.withUnsafeBufferPointer { source in
        expected.withUnsafeMutableBufferPointer { output in
            reference.processLive(input: source.baseAddress!, inputFrames: 256, output: output.baseAddress!)
        }
    }
    guard actualFrames == 512, expectedFrames == 512,
          zip(actual, expected).allSatisfy({ abs($0 - $1) < 0.000001 }),
          abs(actual.last! - 0.05) < 0.000001 else {
        throw AppError.message("Live conditioning must use the supplied precomputed gain, independent of the settings dB field.")
    }
    print("Precomputed conditioning gain checks passed (packet gain matches manager conversion; dB sentinel ignored)")
}
