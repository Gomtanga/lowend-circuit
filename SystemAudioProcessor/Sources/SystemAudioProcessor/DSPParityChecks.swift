import AudioRingBufferC
import Foundation
import LowEndDSPCoreC
import LowEndSupport

func runDSPParityChecks() throws {
    let sampleRates: [Float] = [44_100, 48_000, 96_000, 192_000, 768_000]
    let parameterSets: [(Float, Float, Float)] = [
        (0, 0, 0),
        (22, 8, -1),
        (55, 30, -1.5),
        (100, 100, -6)
    ]

    for sampleRate in sampleRates {
        for parameters in parameterSets {
            for model in [Settings.DSPModel.circuit, .highExciter] {
                let modes: [ExciterOversamplingMode] = model == .highExciter
                    ? [.auto, .one, .two, .four]
                    : [.auto]
                for mode in modes {
                    let swiftSettings = DSPPrecompute.makeDSPSettings(
                        sampleRate: sampleRate,
                        intensity: parameters.0,
                        body: parameters.1,
                        outputDb: parameters.2,
                        dspModel: model,
                        exciterOversamplingMode: mode
                    )
                    var coreSettings = LCDSPSettings()
                    lc_dsp_core_precompute_with_oversampling(
                        sampleRate,
                        parameters.0,
                        parameters.1,
                        parameters.2,
                        model.controlID,
                        mode.rawValue,
                        &coreSettings
                    )
                    try compareSettings(
                        swiftSettings,
                        coreSettings,
                        context: "\(model.displayName) \(sampleRate) Hz \(mode.title) precompute"
                    )
                    try compareProcessing(
                        sampleRate: sampleRate,
                        model: model,
                        settings: swiftSettings
                    )
                }
            }
        }
    }

    print("DSP parity checks passed for 44.1/48/96/192/768 kHz.")
}

private func compareProcessing(sampleRate: Float,
                               model: Settings.DSPModel,
                               settings: LCDSPSettings) throws {
    let frameCount = 2048
    var left = Array(repeating: Float(0), count: frameCount)
    var right = Array(repeating: Float(0), count: frameCount)
    for frame in 0..<frameCount {
        let phase = Float(frame % 257) / 257
        let impulse: Float = frame.isMultiple(of: 509) ? 0.2 : 0
        left[frame] = sin(phase * 2 * .pi) * 0.45 + impulse
        right[frame] = cos(phase * 2 * .pi) * 0.35 - impulse
    }

    var expectedLeft = Array(repeating: Float(0), count: frameCount)
    var expectedRight = Array(repeating: Float(0), count: frameCount)

    switch model {
    case .circuit:
        let swiftDSP = VirtualCircuitBassDSP(
            sampleRate: sampleRate,
            intensity: 0,
            body: 0,
            outputDb: 0
        )
        swiftDSP.update(settings)
        for frame in 0..<frameCount {
            let output = swiftDSP.process(left: left[frame], right: right[frame])
            expectedLeft[frame] = output.0
            expectedRight[frame] = output.1
        }
    case .highExciter:
        let swiftDSP = HighExciterDSP(
            sampleRate: sampleRate,
            intensity: 0,
            body: 0,
            outputDb: 0,
            dspModel: .highExciter,
            exciterOversamplingMode: ExciterOversamplingMode(
                rawValue: settings.exciterOversampleFactor
            ) ?? .one
        )
        swiftDSP.update(settings)
        for frame in 0..<frameCount {
            let output = swiftDSP.process(left: left[frame], right: right[frame])
            expectedLeft[frame] = output.0
            expectedRight[frame] = output.1
        }
    case .clean:
        return
    }

    let core = try SharedDSPCore(sampleRate: Double(sampleRate))
    core.update(settings)
    left.withUnsafeMutableBufferPointer { leftBuffer in
        right.withUnsafeMutableBufferPointer { rightBuffer in
            core.process(
                left: leftBuffer.baseAddress!,
                right: rightBuffer.baseAddress!,
                frameCount: frameCount
            )
        }
    }

    var maximumDelta: Float = 0
    for frame in 0..<frameCount {
        maximumDelta = max(
            maximumDelta,
            abs(left[frame] - expectedLeft[frame]),
            abs(right[frame] - expectedRight[frame])
        )
    }
    let tolerance: Float = sampleRate >= 384_000 ? 0.003 : 0.002
    guard maximumDelta <= tolerance else {
        throw AppError.message(
            "\(model.displayName) \(sampleRate) Hz \(settings.exciterOversampleFactor)x processing delta \(maximumDelta) exceeds tolerance."
        )
    }
}

private func compareSettings(_ swift: LCDSPSettings,
                             _ core: LCDSPSettings,
                             context: String) throws {
    let swiftValues = settingsValues(swift)
    let coreValues = settingsValues(core)
    var maximumDelta: Float = 0
    for index in swiftValues.indices {
        maximumDelta = max(maximumDelta, abs(swiftValues[index] - coreValues[index]))
    }
    guard swift.dspModel == core.dspModel,
          swift.exciterOversampleFactor == core.exciterOversampleFactor,
          maximumDelta <= 0.00005 else {
        throw AppError.message("\(context) delta \(maximumDelta) exceeds tolerance.")
    }
}

private func settingsValues(_ settings: LCDSPSettings) -> [Float] {
    var values: [Float] = [
        settings.intensity,
        settings.body,
        settings.outputGain,
        settings.headroomGain,
        settings.warmthAmount,
        settings.virtualFeedbackGain,
        settings.bodyInjectionGain,
        settings.circuitHeadroomGain,
        settings.drive,
        settings.wetMix,
        settings.bassAlpha,
        settings.subAlpha,
        settings.transformerDrive,
        settings.transformerAsymmetry,
        settings.transformerBiasOffset,
        settings.transformerMakeupGain,
        settings.exciterDrive,
        settings.exciterWetMix
    ]
    values.append(contentsOf: coefficientsValues(settings.shelf))
    values.append(contentsOf: coefficientsValues(settings.transformerPreEmphasis))
    values.append(contentsOf: coefficientsValues(settings.transformerDeEmphasis))
    values.append(contentsOf: coefficientsValues(settings.exciterHighPass))
    values.append(contentsOf: coefficientsValues(settings.exciterStage1LowPass1))
    values.append(contentsOf: coefficientsValues(settings.exciterStage1LowPass2))
    values.append(contentsOf: coefficientsValues(settings.exciterStage2LowPass1))
    values.append(contentsOf: coefficientsValues(settings.exciterStage2LowPass2))
    return values
}

private func coefficientsValues(_ coefficients: LCBiquadCoefficients) -> [Float] {
    [
        coefficients.b0,
        coefficients.b1,
        coefficients.b2,
        coefficients.a1,
        coefficients.a2
    ]
}
