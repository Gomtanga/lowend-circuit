import AudioRingBufferC
import Foundation

/// Owned only by the capture callback. Storage is allocated before capture starts.
final class DelayLine {
    // Unique fixed storage avoids Array's mutable access/CoW runtime path on
    // a callback thread's first use. Allocate and release only while quiescent.
    private let buffer: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    let capacity: Int

    init(capacity: Int) {
        self.capacity = max(capacity, 2)
        buffer = .allocate(capacity: self.capacity)
        buffer.initialize(repeating: 0, count: self.capacity)
    }

    deinit {
        buffer.deinitialize(count: capacity)
        buffer.deallocate()
    }

    func write(_ input: Float) { buffer[writeIndex] = input }

    func read(delaySamples: Int) -> Float {
        let delay = min(max(delaySamples, 0), capacity - 1)
        return buffer[(writeIndex - delay + capacity) % capacity]
    }

    func advance() { writeIndex = (writeIndex + 1) % capacity }

    func process(_ input: Float, delaySamples: Int) -> Float {
        write(input)
        let output = read(delaySamples: delaySamples)
        advance()
        return output
    }

    func reset() {
        for index in 0..<capacity { buffer[index] = 0 }
        writeIndex = 0
    }
}

final class Spatializer {
    /// Geometry is bounded to 3.18 m relative distance: 7,121 samples at 768 kHz.
    static let delayCapacity = 8_192
    static let transitionFrames = 256

    private struct Path {
        var delay: Int = 0
        var gain: Float = 1
        init() {}
        init(_ path: LCSpatialPathSettings) {
            delay = min(Int(path.delaySamples), Spatializer.delayCapacity - 1)
            gain = path.gain.isFinite ? path.gain : 0
        }
    }

    private struct Paths {
        var ll = Path(), lr = Path(), rl = Path(), rr = Path()
        init() {}
        init(_ settings: LCSpatialSettings) {
            ll = Path(settings.ll); lr = Path(settings.lr)
            rl = Path(settings.rl); rr = Path(settings.rr)
        }
    }

    private let leftHistory = DelayLine(capacity: delayCapacity)
    private let rightHistory = DelayLine(capacity: delayCapacity)
    private var current = Paths()
    private var target = Paths()
    private var pending: Paths?
    private var transitionRemaining = 0
    private var amount: Float = 0
    private var targetAmount: Float = 0
    private var activation: Float = 0
    private var targetActivation: Float = 0
    private var mixRemaining = 0
    private var initialized = false

    init(sampleRate: Float, settings: SpatialSettings) {
        update(DSPPrecompute.makeSpatialSettings(sampleRate: sampleRate, settings: settings))
    }

    init(settings: LCSpatialSettings) { update(settings) }

    func update(_ settings: LCSpatialSettings) {
        let paths = Paths(settings)
        let nextAmount = settings.amount.isFinite ? min(max(settings.amount, 0), 1) : 0
        let nextActivation: Float = settings.enabled != 0 && nextAmount > 0.001 ? 1 : 0
        targetAmount = nextAmount
        targetActivation = nextActivation
        if !initialized {
            current = paths; target = paths
            amount = nextAmount; activation = nextActivation
            initialized = true
            return
        }
        // Finish the current two-tap fade before starting the latest target.
        // This keeps rapid retargets continuous with a fixed callback cost.
        if transitionRemaining > 0 { pending = paths }
        else { target = paths; transitionRemaining = Self.transitionFrames }
        mixRemaining = Self.transitionFrames
    }

    func resetState() {
        leftHistory.reset(); rightHistory.reset()
        if let pending { target = pending }
        current = target; pending = nil; transitionRemaining = 0
        amount = targetAmount; activation = targetActivation; mixRemaining = 0
    }

    func process(left: Float, right: Float) -> (Float, Float) {
        // Bypass advances history too; re-enabling cannot replay an old tail.
        leftHistory.write(left); rightHistory.write(right)
        defer { leftHistory.advance(); rightHistory.advance() }

        if mixRemaining > 0 {
            amount += (targetAmount - amount) / Float(mixRemaining)
            activation += (targetActivation - activation) / Float(mixRemaining)
            mixRemaining -= 1
            if mixRemaining == 0 { amount = targetAmount; activation = targetActivation }
        }
        let progress = transitionRemaining > 0
            ? Float(Self.transitionFrames - transitionRemaining + 1) / Float(Self.transitionFrames) : 1
        func tap(_ history: DelayLine, _ old: Path, _ new: Path) -> Float {
            let a = history.read(delaySamples: old.delay) * old.gain
            let b = history.read(delaySamples: new.delay) * new.gain
            return a + (b - a) * progress
        }
        let wetLeft = tap(leftHistory, current.ll, target.ll) + tap(rightHistory, current.rl, target.rl)
        let wetRight = tap(rightHistory, current.rr, target.rr) + tap(leftHistory, current.lr, target.lr)
        if transitionRemaining > 0 {
            transitionRemaining -= 1
            if transitionRemaining == 0 {
                current = target
                if let next = pending { target = next; pending = nil; transitionRemaining = Self.transitionFrames }
            }
        }
        guard activation > 0 else { return (left, right) }
        let outLeft = left * (1 - amount) + wetLeft * 0.82 * amount
        let outRight = right * (1 - amount) + wetRight * 0.82 * amount
        let processedLeft = tanh(outLeft * 1.02) / 1.02
        let processedRight = tanh(outRight * 1.02) / 1.02
        return (left + activation * (processedLeft - left), right + activation * (processedRight - right))
    }
}
