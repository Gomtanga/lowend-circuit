import AudioRingBufferC
import Foundation
import LowEndSupport

enum DSPPrecompute {
    static func makeDSPSettings(sampleRate: Float,
                                intensity: Float,
                                body: Float,
                                outputDb: Float,
                                dspModel: Settings.DSPModel,
                                exciterOversamplingMode: ExciterOversamplingMode = .auto) -> LCDSPSettings {
        let normalIntensity = clamp(intensity / 100, 0, 1)
        let normalBody = clamp(body / 100, 0, 1)
        let shelfDb = normalIntensity * 6.5
        let shelfFreq = 68 + normalIntensity * 24
        let outputGain = pow(10, outputDb / 20)
        let transformerShelfDb = 0.7 + normalIntensity * 2.2 + normalBody * 0.7
        let transformerShelfFreq = 78 + normalIntensity * 10 + normalBody * 24
        let transformerDrive = 1.0 + normalIntensity * 0.24 + normalBody * 0.08
        let transformerAsymmetry = 0.002 + normalIntensity * 0.008 + normalBody * 0.004
        let transformerBiasOffset = makePolynomialSoftClip(transformerAsymmetry)
        let transformerMakeupGain: Float = 1 / max(1 + (transformerDrive - 1) * 0.35, 0.001)
        let exciterFrequency = min(Float(11_000), sampleRate * 0.45)
        let exciterDrive = dspModel == .highExciter ? normalIntensity : 0
        let exciterWetMix = dspModel == .highExciter ? normalBody : 0
        let exciterOversampleFactor = makeExciterOversampleFactor(
            sampleRate: sampleRate,
            mode: exciterOversamplingMode
        )
        let exciterLowPassFrequency = min(Float(20_000), sampleRate * 0.40)
        let exciterStage1Rate = sampleRate * 2
        let exciterStage2Rate = sampleRate * 4
        let butterworthQ1: Float = 0.5411961
        let butterworthQ2: Float = 1.306563

        let bodyInjectionGain = (0.46 + 0.06 * normalIntensity) * normalBody
        let virtualFeedbackGain = 0.16 * normalIntensity
        let shelfLinearGain = pow(10, shelfDb / 20)
        let estimatedCircuitGain = shelfLinearGain + bodyInjectionGain + virtualFeedbackGain
        let circuitHeadroomGain: Float = 1 / max(estimatedCircuitGain, 1)
        let circuitMakeupGain = min(sqrt(max(estimatedCircuitGain, 1)), 1.4125376)

        return LCDSPSettings(
            intensity: normalIntensity,
            body: normalBody,
            outputGain: outputGain,
            headroomGain: pow(10, (-3 * normalIntensity) / 20),
            dspModel: dspModel.controlID,
            shelf: makeLowShelf(sampleRate: sampleRate, frequency: shelfFreq, q: 0.72, gainDb: shelfDb),
            warmthAmount: 0.008 * normalIntensity + 0.004 * normalBody,
            virtualFeedbackGain: virtualFeedbackGain,
            bodyInjectionGain: bodyInjectionGain,
            circuitHeadroomGain: circuitHeadroomGain,
            circuitMakeupGain: circuitMakeupGain,
            wetMix: min(max(0.32 * normalIntensity + 0.18 * normalBody, 0), 0.54),
            bassAlpha: makeRcAlpha(sampleRate: sampleRate, frequency: 72 + normalIntensity * 36),
            subAlpha: makeRcAlpha(sampleRate: sampleRate, frequency: 38 + normalBody * 26),
            transformerPreEmphasis: makeLowShelf(sampleRate: sampleRate, frequency: transformerShelfFreq, q: 0.72, gainDb: transformerShelfDb),
            transformerDeEmphasis: makeLowShelf(sampleRate: sampleRate, frequency: transformerShelfFreq, q: 0.72, gainDb: -transformerShelfDb),
            transformerDrive: transformerDrive,
            transformerAsymmetry: transformerAsymmetry,
            transformerBiasOffset: transformerBiasOffset,
            transformerMakeupGain: transformerMakeupGain,
            exciterHighPass: makeHighPass(sampleRate: sampleRate, frequency: exciterFrequency, q: 0.707),
            exciterDrive: exciterDrive,
            exciterWetMix: exciterWetMix,
            exciterOversampleFactor: exciterOversampleFactor,
            exciterStage1LowPass1: makeLowPass(
                sampleRate: exciterStage1Rate,
                frequency: exciterLowPassFrequency,
                q: butterworthQ1
            ),
            exciterStage1LowPass2: makeLowPass(
                sampleRate: exciterStage1Rate,
                frequency: exciterLowPassFrequency,
                q: butterworthQ2
            ),
            exciterStage2LowPass1: makeLowPass(
                sampleRate: exciterStage2Rate,
                frequency: exciterLowPassFrequency,
                q: butterworthQ1
            ),
            exciterStage2LowPass2: makeLowPass(
                sampleRate: exciterStage2Rate,
                frequency: exciterLowPassFrequency,
                q: butterworthQ2
            ),
            exciterDCBlockPole: exp(-2 * Float.pi * 5 / sampleRate),
            preciseCircuitCoefficientsEnabled: 1,
            preciseShelf: makeLowShelf64(
                sampleRate: Double(sampleRate), frequency: Double(shelfFreq), q: 0.72, gainDb: Double(shelfDb)
            ),
            preciseTransformerPreEmphasis: makeLowShelf64(
                sampleRate: Double(sampleRate), frequency: Double(transformerShelfFreq), q: 0.72, gainDb: Double(transformerShelfDb)
            ),
            preciseTransformerDeEmphasis: makeLowShelf64(
                sampleRate: Double(sampleRate), frequency: Double(transformerShelfFreq), q: 0.72, gainDb: Double(-transformerShelfDb)
            )
        )
    }

    static func makeExciterOversampleFactor(
        sampleRate: Float,
        mode: ExciterOversamplingMode = .auto
    ) -> UInt32 {
        ExciterOversamplingPolicy.resolve(
            processingSampleRate: Double(sampleRate),
            mode: mode
        ).effectiveFactor
    }

    static func makeSpatialSettings(sampleRate: Float, settings: SpatialSettings) -> LCSpatialSettings {
        SpatialGeometrySnapshot.make(sampleRate: sampleRate, settings: settings)?.raw.settings
            ?? LCSpatialSettings()
    }

    static func makeLowPass(sampleRate: Float, frequency: Float, q: Float) -> LCBiquadCoefficients {
        let w0 = 2 * Float.pi * frequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        return LCBiquadCoefficients(
            b0: ((1 - cosW0) / 2) / a0,
            b1: (1 - cosW0) / a0,
            b2: ((1 - cosW0) / 2) / a0,
            a1: (-2 * cosW0) / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func makeHighPass(sampleRate: Float, frequency: Float, q: Float) -> LCBiquadCoefficients {
        let clampedFrequency = min(max(frequency, 20), sampleRate * 0.45)
        let w0 = 2 * Float.pi * clampedFrequency / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        return LCBiquadCoefficients(
            b0: ((1 + cosW0) / 2) / a0,
            b1: (-(1 + cosW0)) / a0,
            b2: ((1 + cosW0) / 2) / a0,
            a1: (-2 * cosW0) / a0,
            a2: (1 - alpha) / a0
        )
    }

    static func makeLowShelf(sampleRate: Float, frequency: Float, q: Float, gainDb: Float) -> LCBiquadCoefficients {
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Float.pi * frequency / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2 * q)
        let beta = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosW0 + beta

        return LCBiquadCoefficients(
            b0: a * ((a + 1) - (a - 1) * cosW0 + beta) / a0,
            b1: 2 * a * ((a - 1) - (a + 1) * cosW0) / a0,
            b2: a * ((a + 1) - (a - 1) * cosW0 - beta) / a0,
            a1: -2 * ((a - 1) + (a + 1) * cosW0) / a0,
            a2: ((a + 1) + (a - 1) * cosW0 - beta) / a0
        )
    }

    static func makeLowShelf64(sampleRate: Double, frequency: Double, q: Double,
                               gainDb: Double) -> LCBiquadCoefficients64 {
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let beta = 2 * sqrt(a) * alpha
        let a0 = (a + 1) + (a - 1) * cosine + beta
        return LCBiquadCoefficients64(
            b0: a * ((a + 1) - (a - 1) * cosine + beta) / a0,
            b1: 2 * a * ((a - 1) - (a + 1) * cosine) / a0,
            b2: a * ((a + 1) - (a - 1) * cosine - beta) / a0,
            a1: -2 * ((a - 1) + (a + 1) * cosine) / a0,
            a2: ((a + 1) + (a - 1) * cosine - beta) / a0
        )
    }

    static func makeRcAlpha(sampleRate: Float, frequency: Float) -> Float {
        let clampedFrequency = min(max(frequency, 5), sampleRate * 0.45)
        return 1 - exp(-2 * Float.pi * clampedFrequency / sampleRate)
    }

    private static func makePolynomialSoftClip(_ input: Float) -> Float {
        if input > 1 {
            return 2 / 3
        }
        if input < -1 {
            return -2 / 3
        }
        return input - (input * input * input) / 3
    }


}

private struct Biquad {
    var b0: Float = 1
    var b1: Float = 0
    var b2: Float = 0
    var a1: Float = 0
    var a2: Float = 0
    var z1: Float = 0
    var z2: Float = 0

    mutating func process(_ input: Float) -> Float {
        let output = b0 * input + z1
        z1 = b1 * input - a1 * output + z2
        z2 = b2 * input - a2 * output
        return output
    }

    mutating func update(_ coefficients: LCBiquadCoefficients) {
        b0 = coefficients.b0
        b1 = coefficients.b1
        b2 = coefficients.b2
        a1 = coefficients.a1
        a2 = coefficients.a2
    }

    mutating func resetState() {
        z1 = 0
        z2 = 0
    }

    static func lowPass(sampleRate: Float, frequency: Float, q: Float) -> Biquad {
        var biquad = Biquad()
        biquad.update(DSPPrecompute.makeLowPass(sampleRate: sampleRate, frequency: frequency, q: q))
        return biquad
    }

    static func lowShelf(sampleRate: Float, frequency: Float, q: Float, gainDb: Float) -> Biquad {
        var biquad = Biquad()
        biquad.update(DSPPrecompute.makeLowShelf(sampleRate: sampleRate, frequency: frequency, q: q, gainDb: gainDb))
        return biquad
    }
}

// Keeping both coefficients and state in Double avoids the low-frequency
// cancellation error at 384/768 kHz. Sample I/O remains Float.
private struct Biquad64 {
    private var b0: Double = 1
    private var b1: Double = 0
    private var b2: Double = 0
    private var a1: Double = 0
    private var a2: Double = 0
    private var z1: Double = 0
    private var z2: Double = 0

    mutating func process(_ input: Float) -> Float {
        let sample = Double(input)
        let output = b0 * sample + z1
        z1 = b1 * sample - a1 * output + z2
        z2 = b2 * sample - a2 * output
        return Float(output)
    }

    mutating func update(_ coefficients: LCBiquadCoefficients64) {
        b0 = coefficients.b0
        b1 = coefficients.b1
        b2 = coefficients.b2
        a1 = coefficients.a1
        a2 = coefficients.a2
    }

    mutating func update(_ coefficients: LCBiquadCoefficients) {
        update(LCBiquadCoefficients64(
            b0: Double(coefficients.b0), b1: Double(coefficients.b1),
            b2: Double(coefficients.b2), a1: Double(coefficients.a1), a2: Double(coefficients.a2)
        ))
    }

    mutating func resetState() {
        z1 = 0
        z2 = 0
    }
}

private struct OversamplingLowPass {
    private var section1 = Biquad()
    private var section2 = Biquad()

    mutating func update(_ first: LCBiquadCoefficients, _ second: LCBiquadCoefficients) {
        section1.update(first)
        section2.update(second)
    }

    mutating func resetState() {
        section1.resetState()
        section2.resetState()
    }

    mutating func process(_ input: Float) -> Float {
        section2.process(section1.process(input))
    }
}

private struct Oversampling2xStage {
    private var interpolationFilter = OversamplingLowPass()
    private var decimationFilter = OversamplingLowPass()

    mutating func update(_ first: LCBiquadCoefficients, _ second: LCBiquadCoefficients) {
        interpolationFilter.update(first, second)
        decimationFilter.update(first, second)
    }

    mutating func resetState() {
        interpolationFilter.resetState()
        decimationFilter.resetState()
    }

    mutating func upsample(_ input: Float, first: inout Float, second: inout Float) {
        first = interpolationFilter.process(input * 2)
        second = interpolationFilter.process(0)
    }

    mutating func downsample(_ first: Float, _ second: Float) -> Float {
        let output = decimationFilter.process(first)
        _ = decimationFilter.process(second)
        return output
    }
}

private protocol BassProcessor: AnyObject {
    func process(left: Float, right: Float) -> (Float, Float)
}

private final class LowEndDSP: BassProcessor {
    private var shelfL = Biquad()
    private var shelfR = Biquad()
    private var subL: Biquad
    private var subR: Biquad
    private var intensity: Float = 0
    private var body: Float = 0
    private var outputGain: Float = 1
    private var headroomGain: Float = 1

    init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float) {
        self.subL = .lowPass(sampleRate: sampleRate, frequency: 135, q: 0.68)
        self.subR = .lowPass(sampleRate: sampleRate, frequency: 135, q: 0.68)
        update(DSPPrecompute.makeDSPSettings(
            sampleRate: sampleRate,
            intensity: intensity,
            body: body,
            outputDb: outputDb,
            dspModel: .clean
        ))
    }

    func update(_ settings: LCDSPSettings) {
        self.intensity = settings.intensity
        self.body = settings.body
        self.outputGain = settings.outputGain
        self.headroomGain = settings.headroomGain
        shelfL.update(settings.shelf)
        shelfR.update(settings.shelf)
    }

    func resetState() {
        shelfL.resetState()
        shelfR.resetState()
        subL.resetState()
        subR.resetState()
    }

    func process(left: Float, right: Float) -> (Float, Float) {
        var lShelf = shelfL.process(left)
        var rShelf = shelfR.process(right)
        let lSub = tanh(subL.process(left) * 2.4) * 0.18 * body
        let rSub = tanh(subR.process(right) * 2.4) * 0.18 * body
        lShelf = tanh((lShelf + lSub) * headroomGain * outputGain * 1.05) / 1.05
        rShelf = tanh((rShelf + rSub) * headroomGain * outputGain * 1.05) / 1.05
        return (lShelf, rShelf)
    }
}

private final class RcLowPass {
    private var alpha: Float = 0
    private var z: Float = 0

    init(sampleRate: Float, frequency: Float) {
        update(alpha: DSPPrecompute.makeRcAlpha(sampleRate: sampleRate, frequency: frequency))
    }

    func update(alpha: Float) {
        self.alpha = alpha
    }

    func resetState() {
        z = 0
    }

    func process(_ input: Float) -> Float {
        z += alpha * (input - z)
        return z
    }
}

final class VirtualCircuitBassDSP: BassProcessor {
    private final class Channel {
        private let bassPole: RcLowPass
        private let subPole: RcLowPass
        private var bassShelf = Biquad64()
        private var preEmphasis = Biquad64()
        private var deEmphasis = Biquad64()
        private var intensity: Float = 0
        private var body: Float = 0
        private var outputGain: Float = 1
        private var virtualFeedbackGain: Float = 0
        private var bodyInjectionGain: Float = 0
        private var headroomGain: Float = 1
        private var makeupGain: Float = 1
        private var wetMix: Float = 0
        private var transformerDrive: Float = 1
        private var transformerAsymmetry: Float = 0
        private var transformerBiasOffset: Float = 0
        private var transformerMakeupGain: Float = 1

        init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float) {
            self.bassPole = RcLowPass(sampleRate: sampleRate, frequency: 72)
            self.subPole = RcLowPass(sampleRate: sampleRate, frequency: 38)
            update(DSPPrecompute.makeDSPSettings(
                sampleRate: sampleRate,
                intensity: intensity,
                body: body,
                outputDb: outputDb,
                dspModel: .circuit
            ))
        }

        func update(_ settings: LCDSPSettings) {
            self.intensity = settings.intensity
            self.body = settings.body
            self.outputGain = settings.outputGain
            self.virtualFeedbackGain = settings.virtualFeedbackGain
            self.bodyInjectionGain = settings.bodyInjectionGain
            self.headroomGain = settings.circuitHeadroomGain
            self.makeupGain = settings.circuitMakeupGain
            self.wetMix = settings.wetMix
            self.transformerDrive = settings.transformerDrive
            self.transformerAsymmetry = settings.transformerAsymmetry
            self.transformerBiasOffset = settings.transformerBiasOffset
            self.transformerMakeupGain = settings.transformerMakeupGain
            if settings.preciseCircuitCoefficientsEnabled != 0 {
                bassShelf.update(settings.preciseShelf)
                preEmphasis.update(settings.preciseTransformerPreEmphasis)
                deEmphasis.update(settings.preciseTransformerDeEmphasis)
            } else {
                bassShelf.update(settings.shelf)
                preEmphasis.update(settings.transformerPreEmphasis)
                deEmphasis.update(settings.transformerDeEmphasis)
            }
            bassPole.update(alpha: settings.bassAlpha)
            subPole.update(alpha: settings.subAlpha)
        }

        func resetState() {
            bassShelf.resetState()
            preEmphasis.resetState()
            deEmphasis.resetState()
            bassPole.resetState()
            subPole.resetState()
        }

        func process(_ input: Float) -> Float {
            if intensity < 0.001 && body < 0.001 {
                return input * outputGain
            }

            let bassShaped = bassShelf.process(input)
            let bassNode = bassPole.process(input)
            let subNode = subPole.process(input)
            let shaped = bassShaped + subNode * bodyInjectionGain
            let headroomShaped = shaped * headroomGain
            let circuitInput = headroomShaped + bassNode * virtualFeedbackGain * headroomGain
            let emphasized = preEmphasis.process(circuitInput)
            let saturated = asymmetricSaturate(emphasized)
            let deEmphasized = deEmphasis.process(saturated)
            let blended = headroomShaped + (deEmphasized - headroomShaped) * wetMix
            return fastClamp(softProtect(blended * makeupGain * outputGain))
        }

        private func asymmetricSaturate(_ input: Float) -> Float {
            let driven = input * transformerDrive
            let biased = driven + transformerAsymmetry
            let clipped: Float

            if biased > 1 {
                clipped = 2 / 3
            } else if biased < -1 {
                clipped = -2 / 3
            } else {
                clipped = biased - (biased * biased * biased) * 0.33333334
            }

            return (clipped - transformerBiasOffset) * transformerMakeupGain
        }

        private func softProtect(_ input: Float) -> Float {
            if !input.isFinite {
                return 0
            }

            let magnitude = abs(input)
            if magnitude <= 0.8 {
                return input
            }
            if magnitude >= 1.2 {
                return input < 0 ? -1 : 1
            }

            let t = (magnitude - 0.8) / 0.4
            let curved = 0.8 + 0.2 * (2 * t - t * t)
            return input < 0 ? -curved : curved
        }

        private func fastClamp(_ input: Float) -> Float {
            if !input.isFinite {
                return 0
            }
            if input > 1 {
                return 1
            }
            if input < -1 {
                return -1
            }
            return input
        }
    }

    private let left: Channel
    private let right: Channel

    init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float) {
        left = Channel(sampleRate: sampleRate, intensity: intensity, body: body, outputDb: outputDb)
        right = Channel(sampleRate: sampleRate, intensity: intensity, body: body, outputDb: outputDb)
    }

    func update(_ settings: LCDSPSettings) {
        left.update(settings)
        right.update(settings)
    }

    func resetState() {
        left.resetState()
        right.resetState()
    }

    func process(left inputLeft: Float, right inputRight: Float) -> (Float, Float) {
        (left.process(inputLeft), right.process(inputRight))
    }
}

final class HighExciterDSP {
    private final class Pipeline {
        private var stage1 = Oversampling2xStage()
        private var stage2 = Oversampling2xStage()
        var drive: Float = 0
        var wetMix: Float = 0
        var oversampleFactor: UInt32 = 1
        private var dcBlockPole: Float = 0.9993457
        private var previousHarmonic: Float = 0
        private var previousDCBlocked: Float = 0

        func update(_ settings: LCDSPSettings) {
            stage1.update(settings.exciterStage1LowPass1, settings.exciterStage1LowPass2)
            stage2.update(settings.exciterStage2LowPass1, settings.exciterStage2LowPass2)
            drive = settings.exciterDrive
            wetMix = settings.exciterWetMix
            oversampleFactor = settings.exciterOversampleFactor == 4 ? 4
                : settings.exciterOversampleFactor == 2 ? 2 : 1
            let pole = settings.exciterDCBlockPole
            dcBlockPole = pole.isFinite && pole > 0 && pole < 1 ? pole : 0.9993457
        }

        func process(_ high: Float) -> Float {
            if wetMix < 0.0001 || drive < 0.0001 { return 0 }
            let harmonic: Float

            switch oversampleFactor {
            case 4:
                var stage1First: Float = 0
                var stage1Second: Float = 0
                stage1.upsample(high, first: &stage1First, second: &stage1Second)

                var sample0: Float = 0
                var sample1: Float = 0
                var sample2: Float = 0
                var sample3: Float = 0
                stage2.upsample(stage1First, first: &sample0, second: &sample1)
                stage2.upsample(stage1Second, first: &sample2, second: &sample3)

                let downsampled0 = stage2.downsample(
                    makeHarmonic(sample0),
                    makeHarmonic(sample1)
                )
                let downsampled1 = stage2.downsample(
                    makeHarmonic(sample2),
                    makeHarmonic(sample3)
                )
                harmonic = stage1.downsample(downsampled0, downsampled1)
            case 2:
                var first: Float = 0
                var second: Float = 0
                stage1.upsample(high, first: &first, second: &second)
                harmonic = stage1.downsample(makeHarmonic(first), makeHarmonic(second))
            default:
                harmonic = makeHarmonic(high)
            }

            let dcBlocked = (1 + dcBlockPole) * 0.5 * (harmonic - previousHarmonic)
                + dcBlockPole * previousDCBlocked
            previousHarmonic = harmonic
            previousDCBlocked = dcBlocked

            return dcBlocked * wetMix
        }

        private func makeHarmonic(_ input: Float) -> Float {
            let driven = input * drive
            let squared = driven * driven
            return squared + squared * driven * 0.5
        }

        func resetState() {
            stage1.resetState()
            stage2.resetState()
            previousHarmonic = 0
            previousDCBlocked = 0
        }
    }

    private final class Channel {
        private static let transitionFrames = 256
        private var highPass = Biquad()
        private let first = Pipeline()
        private let second = Pipeline()
        private var active = 0
        private var target = 1
        private var transitionRemaining = 0
        private var initialized = false
        private var pending: LCDSPSettings?

        private func pipeline(_ index: Int) -> Pipeline { index == 0 ? first : second }

        func update(_ settings: LCDSPSettings) {
            if transitionRemaining > 0 { pending = settings; return }
            let nextFactor: UInt32 = settings.exciterOversampleFactor == 4 ? 4
                : settings.exciterOversampleFactor == 2 ? 2 : 1
            highPass.update(settings.exciterHighPass)
            if !initialized {
                pipeline(active).update(settings)
                pipeline(active).resetState()
                initialized = true
            } else if pipeline(active).oversampleFactor == nextFactor {
                pipeline(active).update(settings)
            } else {
                target = 1 - active
                pipeline(target).update(settings)
                pipeline(target).resetState()
                transitionRemaining = Self.transitionFrames
            }
        }

        func process(_ input: Float) -> Float {
            let dry = input.isFinite ? input : 0
            let high = highPass.process(dry)
            let isDry = (pipeline(active).wetMix < 0.0001 || pipeline(active).drive < 0.0001)
                && (transitionRemaining == 0 || pipeline(target).wetMix < 0.0001 || pipeline(target).drive < 0.0001)
            var wet = pipeline(active).process(high)
            if transitionRemaining > 0 {
                let nextWet = pipeline(target).process(high)
                let mix = Float(Self.transitionFrames - transitionRemaining + 1) / Float(Self.transitionFrames)
                wet += (nextWet - wet) * mix
                transitionRemaining -= 1
                if transitionRemaining == 0 {
                    active = target
                    if let next = pending { pending = nil; update(next) }
                }
            }
            if isDry { return dry }
            let output = dry + wet
            return output.isFinite ? min(max(output, -1), 1) : 0
        }

        func resetState() {
            if transitionRemaining > 0 { active = target }
            transitionRemaining = 0
            if let next = pending {
                highPass.update(next.exciterHighPass)
                pipeline(active).update(next)
                pending = nil
            }
            highPass.resetState()
            first.resetState()
            second.resetState()
        }
    }

    private let left = Channel()
    private let right = Channel()

    init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float,
         dspModel: Settings.DSPModel, exciterOversamplingMode: ExciterOversamplingMode = .auto) {
        update(DSPPrecompute.makeDSPSettings(sampleRate: sampleRate, intensity: intensity,
            body: body, outputDb: outputDb, dspModel: dspModel,
            exciterOversamplingMode: exciterOversamplingMode))
    }

    func update(_ settings: LCDSPSettings) { left.update(settings); right.update(settings) }
    func resetState() { left.resetState(); right.resetState() }
    func process(left: Float, right: Float) -> (Float, Float) { (self.left.process(left), self.right.process(right)) }
}

/// Two preallocated banks run together only during a model transition.
/// Inactive model history is cleared before reuse, without continuous DSP cost.
final class TonalDSPRouter {
    private final class Bank {
        let circuit: VirtualCircuitBassDSP
        let exciter: HighExciterDSP
        var model: UInt32 = DSPModelID.clean

        init(sampleRate: Float) {
            circuit = VirtualCircuitBassDSP(sampleRate: sampleRate, intensity: 0, body: 0, outputDb: 0)
            exciter = HighExciterDSP(sampleRate: sampleRate, intensity: 0, body: 0,
                                    outputDb: 0, dspModel: .highExciter)
        }

        func update(_ settings: LCDSPSettings, clearState: Bool) {
            model = settings.dspModel == DSPModelID.circuit || settings.dspModel == DSPModelID.highExciter
                ? settings.dspModel : DSPModelID.clean
            circuit.update(settings)
            exciter.update(settings)
            if clearState { resetState() }
        }

        func process(left: Float, right: Float) -> (Float, Float) {
            switch model {
            case DSPModelID.circuit: return circuit.process(left: left, right: right)
            case DSPModelID.highExciter: return exciter.process(left: left, right: right)
            default: return (left, right)
            }
        }

        func resetState() { circuit.resetState(); exciter.resetState() }
    }

    private static let transitionFrames = 256
    private let first: Bank
    private let second: Bank
    private var active = 0
    private var target = 1
    private var transitionRemaining = 0
    private var pending: LCDSPSettings?
    private var initialized = false
    private func bank(_ index: Int) -> Bank { index == 0 ? first : second }

    init(sampleRate: Float, intensity: Float, body: Float, outputDb: Float,
         dspModel: Settings.DSPModel, exciterOversamplingMode: ExciterOversamplingMode = .auto) {
        first = Bank(sampleRate: sampleRate)
        second = Bank(sampleRate: sampleRate)
        update(DSPPrecompute.makeDSPSettings(sampleRate: sampleRate, intensity: intensity,
            body: body, outputDb: outputDb, dspModel: dspModel,
            exciterOversamplingMode: exciterOversamplingMode))
    }

    func update(_ settings: LCDSPSettings) {
        if transitionRemaining > 0 { pending = settings; return }
        let nextModel = settings.dspModel == DSPModelID.circuit || settings.dspModel == DSPModelID.highExciter
            ? settings.dspModel : DSPModelID.clean
        if !initialized {
            bank(active).update(settings, clearState: true)
            initialized = true
        } else if bank(active).model == nextModel {
            bank(active).update(settings, clearState: false)
        } else {
            target = 1 - active
            bank(target).update(settings, clearState: true)
            transitionRemaining = Self.transitionFrames
        }
    }

    func process(left: Float, right: Float) -> (Float, Float) {
        let left = left.isFinite ? left : 0
        let right = right.isFinite ? right : left
        var output = bank(active).process(left: left, right: right)
        if transitionRemaining > 0 {
            let next = bank(target).process(left: left, right: right)
            let mix = Float(Self.transitionFrames - transitionRemaining + 1) / Float(Self.transitionFrames)
            output.0 += (next.0 - output.0) * mix
            output.1 += (next.1 - output.1) * mix
            transitionRemaining -= 1
            if transitionRemaining == 0 {
                active = target
                if let nextSettings = pending { pending = nil; update(nextSettings) }
            }
        }
        return output
    }

    func resetState() {
        if transitionRemaining > 0 { active = target }
        transitionRemaining = 0
        if let settings = pending {
            bank(active).update(settings, clearState: true)
            pending = nil
        }
        first.resetState(); second.resetState()
    }
}

/// Exercise the actual Swift processing path as well as implementation parity.
/// These invariants deliberately fail for dry-only, DC-biased, or discontinuous
/// implementations even when both language implementations share that defect.
func runTonalDSPRegressionChecks() throws {
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw AppError.message("Tonal regression: \(message)") }
    }

    var isolated = LCDSPSettings()
    isolated.intensity = 1
    isolated.outputGain = 0.5
    isolated.circuitHeadroomGain = 1
    isolated.circuitMakeupGain = 1
    isolated.wetMix = 1
    isolated.transformerDrive = 1
    isolated.transformerMakeupGain = 1
    isolated.shelf.b0 = 1
    isolated.transformerPreEmphasis.b0 = 1
    isolated.transformerDeEmphasis.b0 = 1
    let circuit = VirtualCircuitBassDSP(sampleRate: 48_000, intensity: 0, body: 0, outputDb: 0)
    circuit.update(isolated)
    for sign: Float in [-1, 1] {
        let inside = circuit.process(left: sign * 0.99999, right: 0).0
        let outside = circuit.process(left: sign * 1.00001, right: 0).0
        try require(inside.isFinite && outside.isFinite && abs(outside - inside) < 0.00001,
                    "Circuit saturation must be continuous at both boundaries")
        try require(abs(outside - sign / 3) < 0.00001, "Circuit saturation endpoint")
    }

    for mode: ExciterOversamplingMode in [.one, .two, .four] {
        let exciter = HighExciterDSP(sampleRate: 48_000, intensity: 100, body: 100,
                                    outputDb: 0, dspModel: .highExciter, exciterOversamplingMode: mode)
        var mean: Double = 0
        for frame in 0..<96_000 {
            let input = Float(0.5 * sin(2 * Double.pi * 12_000 * Double(frame) / 48_000))
            let output = exciter.process(left: input, right: input)
            try require(output.0.isFinite && output.1.isFinite, "Exciter finite output")
            if frame >= 48_000 { mean += Double(output.0) }
        }
        try require(abs(mean / 48_000) < 0.00002, "Exciter wet DC rejection \(mode.title)")
        var earlyPeak: Float = 0
        var latePeak: Float = 0
        var lateMean: Double = 0
        for frame in 0..<36_000 {
            let output = exciter.process(left: 0, right: 0)
            try require(output.0.isFinite && output.1.isFinite, "Exciter natural silence finite")
            if frame < 480 { earlyPeak = max(earlyPeak, abs(output.0)) }
            if frame >= 24_000 {
                latePeak = max(latePeak, abs(output.0))
                lateMean += Double(output.0)
            }
        }
        try require(earlyPeak > 0.00001, "Exciter natural silence must retain its initial wet tail")
        try require(latePeak < 0.000002 && abs(lateMean / 12_000) < 0.000002,
                    "Exciter natural silence must decay below -114 dBFS after 0.5 s")
        try require(latePeak < earlyPeak * 0.001, "Exciter natural silence tail must decay by 60 dB")
        exciter.resetState()
        try require(exciter.process(left: 0, right: 0).0 == 0, "DC blocker reset")
    }

    let harmonicExciter = HighExciterDSP(sampleRate: 48_000, intensity: 100, body: 100,
                                        outputDb: 0, dspModel: .highExciter)
    var real: Double = 0
    var imaginary: Double = 0
    for frame in 0..<96_000 {
        let phase = 2 * Double.pi * 8_000 * Double(frame) / 48_000
        let input = Float(0.5 * sin(phase))
        let output = harmonicExciter.process(left: input, right: input).0
        if frame >= 48_000 {
            let difference = Double(output - input)
            real += difference * cos(phase * 2)
            imaginary -= difference * sin(phase * 2)
        }
    }
    try require(2 * hypot(real, imaginary) / 48_000 > 0.001,
                "Exciter must add a measurable 16 kHz AC harmonic to an 8 kHz input")

    // Independent 55 Hz response fixtures for the intended shelf design.
    // These are not derived from the coefficients being tested.
    for (intensity, expectedDb): (Float, Double) in [(22, 1.09647), (55, 2.97563), (100, 5.77288)] {
        let settings = DSPPrecompute.makeDSPSettings(sampleRate: 768_000,
            intensity: intensity, body: 30, outputDb: 0, dspModel: .circuit)
        var filter = Biquad64()
        filter.update(settings.preciseShelf)
        var energy: Double = 0
        for frame in 0..<1_536_000 {
            let input = Float(0.05 * sin(2 * Double.pi * 55 * Double(frame) / 768_000))
            let output = filter.process(input)
            if frame >= 768_000 { energy += Double(output) * Double(output) }
        }
        let measuredDb = 20 * log10(sqrt(energy / 768_000) / (0.05 / sqrt(2)))
        try require(measuredDb.isFinite && abs(measuredDb - expectedDb) < 0.001,
                    "768 kHz shelf amplitude \(measuredDb) dB differs from \(expectedDb) dB")
    }
}
