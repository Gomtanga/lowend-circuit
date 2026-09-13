import AudioRingBufferC
import Foundation
import LowEndDSPCoreC
import LowEndSupport

func runDSPParityChecks() throws {
    let sampleRates: [Float] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000]
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

    try compareRouterTransitions()
    try runTonalDSPRegressionChecks()
    print("DSP parity and independent tonal regressions passed for 44.1...768 kHz.")
}

private func compareRouterTransitions() throws {
    for sampleRate: Float in [48_000, 192_000, 768_000] {
        let router = TonalDSPRouter(sampleRate: sampleRate, intensity: 55, body: 30,
                                    outputDb: 0, dspModel: .clean)
        let core = try SharedDSPCore(sampleRate: Double(sampleRate))
        core.update(DSPPrecompute.makeDSPSettings(sampleRate: sampleRate, intensity: 55,
            body: 30, outputDb: 0, dspModel: .clean))
        let changes: [(Int, Settings.DSPModel, ExciterOversamplingMode)] = [
            (128, .circuit, .auto), (160, .highExciter, .four), (192, .clean, .auto),
            (800, .circuit, .auto), (1200, .highExciter, .one),
            (1700, .highExciter, .four), (1720, .highExciter, .two), (1740, .highExciter, .one),
            (2400, .circuit, .auto), (2600, .clean, .auto)
        ]
        var nextChange = 0
        var maximumDelta: Float = 0
        for frame in 0..<4096 {
            if nextChange < changes.count && frame == changes[nextChange].0 {
                let change = changes[nextChange]
                let settings = DSPPrecompute.makeDSPSettings(sampleRate: sampleRate,
                    intensity: 100, body: 100, outputDb: 0, dspModel: change.1,
                    exciterOversamplingMode: change.2)
                router.update(settings)
                core.update(settings)
                nextChange += 1
            }
            let phase = 2 * Double.pi * Double(frame) / Double(sampleRate)
            let inputLeft = Float(0.25 * sin(phase * 55) + 0.25 * sin(phase * 8000))
            let inputRight = Float(0.2 * cos(phase * 80) - 0.2 * sin(phase * 8000))
            let expected = router.process(left: inputLeft, right: inputRight)
            var left = inputLeft
            var right = inputRight
            withUnsafeMutablePointer(to: &left) { leftPointer in
                withUnsafeMutablePointer(to: &right) { rightPointer in
                    core.process(left: leftPointer, right: rightPointer, frameCount: 1)
                }
            }
            guard left.isFinite, right.isFinite, expected.0.isFinite, expected.1.isFinite else {
                throw AppError.message("Router transition produced non-finite output at \(sampleRate) Hz.")
            }
            maximumDelta = max(maximumDelta, abs(left - expected.0), abs(right - expected.1))
            if frame >= 3112, left != inputLeft || right != inputRight {
                throw AppError.message("Router latest pending Clean did not converge at \(sampleRate) Hz.")
            }
        }
        guard maximumDelta < 0.00005 else {
            throw AppError.message("Router transition parity delta \(maximumDelta) at \(sampleRate) Hz.")
        }
        router.resetState()
        core.reset()
        let silence = router.process(left: 0, right: 0)
        guard silence.0 == 0, silence.1 == 0 else {
            throw AppError.message("Router reset retained stale history.")
        }
    }
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
        guard left[frame].isFinite, right[frame].isFinite,
              expectedLeft[frame].isFinite, expectedRight[frame].isFinite else {
            throw AppError.message("\(model.displayName) processing produced a non-finite sample.")
        }
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
        guard swiftValues[index].isFinite, coreValues[index].isFinite else {
            throw AppError.message("\(context) contains a non-finite coefficient.")
        }
        maximumDelta = max(maximumDelta, abs(swiftValues[index] - coreValues[index]))
    }
    guard swift.dspModel == core.dspModel,
          swift.exciterOversampleFactor == core.exciterOversampleFactor,
          swift.preciseCircuitCoefficientsEnabled == core.preciseCircuitCoefficientsEnabled,
          maximumDelta <= 0.00005 else {
        throw AppError.message("\(context) delta \(maximumDelta) exceeds tolerance.")
    }
    let swiftPrecise = preciseSettingsValues(swift)
    let corePrecise = preciseSettingsValues(core)
    for index in swiftPrecise.indices {
        guard swiftPrecise[index].isFinite, corePrecise[index].isFinite,
              abs(swiftPrecise[index] - corePrecise[index]) <= 0.000_000_001 else {
            throw AppError.message("\(context) precise coefficient mismatch at \(index).")
        }
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
        settings.circuitMakeupGain,
        settings.wetMix,
        settings.bassAlpha,
        settings.subAlpha,
        settings.transformerDrive,
        settings.transformerAsymmetry,
        settings.transformerBiasOffset,
        settings.transformerMakeupGain,
        settings.exciterDrive,
        settings.exciterWetMix,
        settings.exciterDCBlockPole
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

private func preciseSettingsValues(_ settings: LCDSPSettings) -> [Double] {
    [settings.preciseShelf, settings.preciseTransformerPreEmphasis,
     settings.preciseTransformerDeEmphasis].flatMap {
        [$0.b0, $0.b1, $0.b2, $0.a1, $0.a2]
    }
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
