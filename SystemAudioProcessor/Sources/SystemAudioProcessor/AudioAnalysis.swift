import AppKit
import Accelerate
import AudioRingBufferC
import Combine
import Darwin
import Foundation
import Metal
import MetalKit
import SwiftUI

@MainActor
final class DynamicsMeterModel: ObservableObject {
    struct Levels: Sendable {
        var peak: Float
        var rms: Float
        var crestFactor: Float
    }

    @Published private(set) var levels = Levels(peak: -100, rms: -100, crestFactor: 0)

    func update(peak: Float, rms: Float, crestFactor: Float) {
        levels = Levels(peak: peak, rms: rms, crestFactor: crestFactor)
    }

    func reset() {
        update(peak: -100, rms: -100, crestFactor: 0)
    }
}

// The C snapshot provides concurrent publish/copy. Lifecycle callers stop the
// analyzer before clearing/destroying the snapshot.
final class SpectrumModel: @unchecked Sendable {
    static let binCount = Int(LC_SPECTRUM_BIN_COUNT)
    private let snapshot: OpaquePointer

    init() {
        guard let snapshot = lc_spectrum_snapshot_create() else {
            fatalError("Could not allocate spectrum snapshot.")
        }
        self.snapshot = snapshot
    }

    deinit {
        lc_spectrum_snapshot_destroy(snapshot)
    }

    func publish(_ values: [Float]) {
        values.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            lc_spectrum_snapshot_publish(snapshot, baseAddress, UInt32(pointer.count))
        }
    }

    func copySnapshot(
        into destination: UnsafeMutablePointer<Float>,
        after previousSequence: UInt64
    ) -> UInt64? {
        var newSequence: UInt64 = previousSequence
        let copied = lc_spectrum_snapshot_copy_if_new(
            snapshot,
            destination,
            UInt32(Self.binCount),
            previousSequence,
            &newSequence
        )
        return copied == UInt32(Self.binCount) ? newSequence : nil
    }

    func setAnalysisActive(_ active: Bool) {
        lc_spectrum_snapshot_set_active(snapshot, active ? 1 : 0)
    }

    var isAnalysisActive: Bool {
        lc_spectrum_snapshot_is_active(snapshot) != 0
    }

    func reset() {
        lc_spectrum_snapshot_clear(snapshot)
    }
}

private struct MetalSpectrumUniforms {
    var viewportAndCount = SIMD4<Float>(0, 0, Float(SpectrumModel.binCount), 0)
    var layout = SIMD4<Float>(42, 5, 1.5, 0)
}

/// CPU slots stay exclusively owned until their command buffer completes.
/// A slow GPU drops a render opportunity instead of blocking the main thread.
final class MetalSpectrumFrameSlots: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight: [Bool]

    init(count: Int) { inFlight = Array(repeating: false, count: max(0, count)) }

    func acquire() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = inFlight.firstIndex(of: false) else { return nil }
        inFlight[index] = true
        return index
    }

    func release(_ index: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard inFlight.indices.contains(index) else { return }
        inFlight[index] = false
    }

    func releaseAfterCompletion(_ index: Int, of commandBuffer: MTLCommandBuffer) {
        commandBuffer.addCompletedHandler { [self] _ in release(index) }
    }
}

@available(macOS 14.4, *)
struct MetalSpectrumView: NSViewRepresentable {
    let model: SpectrumModel
    var isActive = true

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: context.coordinator.device)
        model.setAnalysisActive(isActive && context.coordinator.isReady)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.clearColor = MTLClearColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
        view.preferredFramesPerSecond = 30
        view.enableSetNeedsDisplay = false
        view.isPaused = !isActive || !context.coordinator.isReady
        view.presentsWithTransaction = false
        if !context.coordinator.isReady {
            let fallback = NSTextField(wrappingLabelWithString: "스펙트럼을 표시할 수 없습니다. 오디오 처리는 계속 사용할 수 있습니다.")
            fallback.textColor = .secondaryLabelColor
            fallback.alignment = .center
            fallback.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(fallback)
            NSLayoutConstraint.activate([
                fallback.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                fallback.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                fallback.centerYAnchor.constraint(equalTo: view.centerYAnchor)
            ])
        }
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        model.setAnalysisActive(isActive && context.coordinator.isReady)
        nsView.isPaused = !isActive || !context.coordinator.isReady
    }

    static func dismantleNSView(_ nsView: MTKView, coordinator: Coordinator) {
        coordinator.setAnalysisActive(false)
        nsView.isPaused = true
        nsView.delegate = nil
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        let device: MTLDevice?
        private let model: SpectrumModel
        private let commandQueue: MTLCommandQueue?
        private let pipelineState: MTLRenderPipelineState?
        private let amplitudeBuffers: [MTLBuffer]
        private let uniformBuffers: [MTLBuffer]
        private let frameSlots = MetalSpectrumFrameSlots(count: 3)
        private var drawableSize = SIMD2<Float>(0, 0)
        private var lastSequence = UInt64.max

        var isReady: Bool {
            device != nil &&
                commandQueue != nil &&
                pipelineState != nil &&
                amplitudeBuffers.count == 3 &&
                uniformBuffers.count == 3
        }

        init(model: SpectrumModel) {
            self.model = model
            let device = MTLCreateSystemDefaultDevice()
            self.device = device
            self.commandQueue = device?.makeCommandQueue()
            self.pipelineState = Self.makePipeline(device: device)

            var amplitudes: [MTLBuffer] = []
            var uniforms: [MTLBuffer] = []
            if let device {
                let amplitudeLength = SpectrumModel.binCount * MemoryLayout<Float>.stride
                let uniformLength = MemoryLayout<MetalSpectrumUniforms>.stride
                for _ in 0..<3 {
                    if let amplitude = device.makeBuffer(length: amplitudeLength, options: .storageModeShared),
                       let uniform = device.makeBuffer(length: uniformLength, options: .storageModeShared) {
                        memset(amplitude.contents(), 0, amplitudeLength)
                        uniform.contents().bindMemory(to: MetalSpectrumUniforms.self, capacity: 1)
                            .initialize(to: MetalSpectrumUniforms())
                        amplitudes.append(amplitude)
                        uniforms.append(uniform)
                    }
                }
            }
            self.amplitudeBuffers = amplitudes
            self.uniformBuffers = uniforms
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            drawableSize = SIMD2(Float(size.width), Float(size.height))
            lastSequence = UInt64.max
        }

        func setAnalysisActive(_ active: Bool) {
            model.setAnalysisActive(active)
        }

        func draw(in view: MTKView) {
            guard isReady,
                  drawableSize.x > 0,
                  drawableSize.y > 0,
                  let commandQueue,
                  let pipelineState,
                  let index = frameSlots.acquire() else { return }
            var submitted = false
            defer { if !submitted { frameSlots.release(index) } }
            let amplitudeBuffer = amplitudeBuffers[index]
            let amplitudePointer = amplitudeBuffer.contents().bindMemory(
                to: Float.self,
                capacity: SpectrumModel.binCount
            )
            guard let sequence = model.copySnapshot(
                into: amplitudePointer,
                after: lastSequence
            ) else { return }
            let uniformBuffer = uniformBuffers[index]
            let uniformPointer = uniformBuffer.contents().bindMemory(
                to: MetalSpectrumUniforms.self,
                capacity: 1
            )
            var uniforms = MetalSpectrumUniforms()
            uniforms.viewportAndCount = SIMD4(
                drawableSize.x,
                drawableSize.y,
                Float(SpectrumModel.binCount),
                0
            )
            uniformPointer.pointee = uniforms

            guard let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipelineState)
            encoder.setVertexBuffer(amplitudeBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(uniformBuffer, offset: 0, index: 1)
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: SpectrumModel.binCount
            )
            encoder.endEncoding()
            commandBuffer.present(drawable)
            frameSlots.releaseAfterCompletion(index, of: commandBuffer)
            submitted = true
            lastSequence = sequence
            commandBuffer.commit()
        }

        fileprivate static func packagedShaderURL() -> URL? {
            let moduleURL = Bundle.main.url(
                forResource: "SystemAudioProcessor_SystemAudioProcessor", withExtension: "bundle"
            ) ?? Bundle.main.bundleURL.appendingPathComponent("SystemAudioProcessor_SystemAudioProcessor.bundle")
            return Bundle(url: moduleURL)?.url(forResource: "SpectrumShaders", withExtension: "metal")
        }

        private static func makePipeline(device: MTLDevice?) -> MTLRenderPipelineState? {
            guard let device else { return nil }
            // The generated Bundle.module accessor traps for a missing bundle.
            // Optional resolution instead permits the unavailable-view fallback.
            let shaderURL = Bundle.main.url(forResource: "SpectrumShaders", withExtension: "metal")
                ?? packagedShaderURL()
            guard let shaderURL,
                  let shaderSource = try? String(contentsOf: shaderURL, encoding: .utf8),
                  let library = try? device.makeLibrary(source: shaderSource, options: nil),
                  let vertexFunction = library.makeFunction(name: "spectrumVertex"),
                  let fragmentFunction = library.makeFunction(name: "spectrumFragment") else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "LowEnd Spectrum Bars"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
    }
}

private final class AnalysisPublicationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

// All FFT, sample history and meter smoothing state belongs to analysisQueue.
// Only immutable meter levels cross to MainActor, protected against stale
// publication by a token invalidated on stop/rate generation changes.
final class AudioSpectrumAnalyzer: NSObject, @unchecked Sendable {
    private static let fftSize = 16384
    private static let halfSize = 8192
    private static let barCount = 128

    private let ringBuffer: LockFreeFloatRingBuffer
    private let dynamicsModel: DynamicsMeterModel
    private let spectrumModel: SpectrumModel
    private let fftSize = AudioSpectrumAnalyzer.fftSize
    private let halfSize = AudioSpectrumAnalyzer.halfSize
    private let log2n = vDSP_Length(14)
    private let barCount = AudioSpectrumAnalyzer.barCount
    private var sampleRate: Float
    private let analysisQueue = DispatchQueue(label: "lowend.spectrum.analysis", qos: .userInitiated)
    private let analysisQueueKey = DispatchSpecificKey<UInt8>()
    private var timer: DispatchSourceTimer?
    private var publicationToken = AnalysisPublicationToken()
    private var fftSetup: FFTSetup?
    private var drainBuffer = [Float](repeating: 0, count: 32_768)
    private var history = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize)
    private var window = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize)
    private var windowed = [Float](repeating: 0, count: AudioSpectrumAnalyzer.fftSize)
    private var real = [Float](repeating: 0, count: AudioSpectrumAnalyzer.halfSize)
    private var imag = [Float](repeating: 0, count: AudioSpectrumAnalyzer.halfSize)
    private var powerBins = [Float](repeating: 0, count: AudioSpectrumAnalyzer.halfSize)
    private var dbBins = [Float](repeating: -120, count: AudioSpectrumAnalyzer.halfSize)
    private var magnitudes = [Float](repeating: 0, count: AudioSpectrumAnalyzer.barCount)
    private var binCenters = [Float](repeating: 1, count: AudioSpectrumAnalyzer.barCount)
    private var filledSamples = 0
    private var smoothedPeakDb: Float = -100
    private var smoothedRMSDb: Float = -100
    private var smoothedCrestDb: Float = 0
    private var dynamicsPublishCounter = 0
    private let levelReleaseDbPerTick: Float = 1.10
    private let crestReleaseDbPerTick: Float = 0.40

    init(ringBuffer: LockFreeFloatRingBuffer,
         sampleRate: Float,
         dynamicsModel: DynamicsMeterModel,
         spectrumModel: SpectrumModel) {
        self.ringBuffer = ringBuffer
        self.dynamicsModel = dynamicsModel
        self.spectrumModel = spectrumModel
        self.sampleRate = sampleRate
        super.init()
        analysisQueue.setSpecific(key: analysisQueueKey, value: 1)
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        rebuildLogBins()
    }

    deinit {
        stop()
        if let fftSetup {
            vDSP_destroy_fftsetup(fftSetup)
        }
    }

    func start() {
        withAnalysisQueue {
            stopOnAnalysisQueue()
            resetAnalysisState()
            let timer = DispatchSource.makeTimerSource(queue: analysisQueue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(3))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        withAnalysisQueue { stopOnAnalysisQueue() }
    }

    private func withAnalysisQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: analysisQueueKey) != nil { return try work() }
        return try analysisQueue.sync(execute: work)
    }

    private func stopOnAnalysisQueue() {
        publicationToken.invalidate()
        timer?.setEventHandler {}
        timer?.cancel()
        timer = nil
    }

    func updateSampleRate(_ sampleRate: Float) {
        guard sampleRate.isFinite, sampleRate >= 8_000 else { return }
        analysisQueue.async { [weak self] in
            guard let self, self.sampleRate != sampleRate else { return }
            self.sampleRate = sampleRate
            self.rebuildLogBins()
            self.resetAnalysisState()
        }
    }

    private func resetAnalysisState() {
        publicationToken.invalidate()
        publicationToken = AnalysisPublicationToken()
        history.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: 0, count: $0.count) }
        magnitudes.withUnsafeMutableBufferPointer { $0.baseAddress?.update(repeating: 0, count: $0.count) }
        filledSamples = 0
        dynamicsPublishCounter = 0
        smoothedPeakDb = -100
        smoothedRMSDb = -100
        smoothedCrestDb = 0
        spectrumModel.reset()
        let token = publicationToken
        Task { @MainActor [dynamicsModel] in
            guard token.isValid else { return }
            dynamicsModel.reset()
        }
    }

    private func tick() {
        if ringBuffer.consumeDiscardRequest() { resetAnalysisState() }
        guard drainAudio(),
              spectrumModel.isAnalysisActive,
              filledSamples >= fftSize else { return }
        computeSpectrum()
        spectrumModel.publish(magnitudes)
    }

    @discardableResult
    private func drainAudio() -> Bool {
        // Drain the finite snapshot available at tick entry, not an unbounded
        // producer loop. Keeping only the final FFT window prevents backlog at
        // 768 kHz; the old one-chunk/tick path capped at 491,520 frames/s.
        let available = ringBuffer.availableSamples()
        var remaining = available - (available % 2)
        guard remaining >= 2 else { return false }

        while remaining > 0 {
            let sampleCount = min(remaining, drainBuffer.count)
            drainBuffer.withUnsafeMutableBufferPointer { pointer in
                if let baseAddress = pointer.baseAddress {
                    ringBuffer.popInterleaved(into: baseAddress, count: sampleCount)
                }
            }
            remaining -= sampleCount
            // All older chunks are consumed to free capacity; only the newest
            // window contributes to the final display and dynamics update.
            if remaining == 0 { updateDynamics(sampleCount: sampleCount) }
            appendHistory(sampleCount: sampleCount)
        }
        return true
    }

    private func appendHistory(sampleCount: Int) {
        let frameCount = sampleCount / 2
        if frameCount >= fftSize {
            let startFrame = frameCount - fftSize
            downmixStereo(
                sourceStartFrame: startFrame,
                destinationStartFrame: 0,
                frameCount: fftSize
            )
            filledSamples = fftSize
            return
        }

        let keepCount = fftSize - frameCount
        history.withUnsafeMutableBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            memmove(
                baseAddress,
                baseAddress.advanced(by: frameCount),
                keepCount * MemoryLayout<Float>.stride
            )
        }
        downmixStereo(
            sourceStartFrame: 0,
            destinationStartFrame: keepCount,
            frameCount: frameCount
        )
        filledSamples = min(fftSize, filledSamples + frameCount)
    }

    private func downmixStereo(
        sourceStartFrame: Int,
        destinationStartFrame: Int,
        frameCount: Int
    ) {
        guard frameCount > 0 else { return }

        drainBuffer.withUnsafeBufferPointer { sourcePointer in
            history.withUnsafeMutableBufferPointer { destinationPointer in
                guard let sourceBase = sourcePointer.baseAddress,
                      let destinationBase = destinationPointer.baseAddress else { return }
                let left = sourceBase.advanced(by: sourceStartFrame * 2)
                let right = left.advanced(by: 1)
                let destination = destinationBase.advanced(by: destinationStartFrame)
                let count = vDSP_Length(frameCount)
                var half: Float = 0.5
                vDSP_vadd(left, 2, right, 2, destination, 1, count)
                vDSP_vsmul(destination, 1, &half, destination, 1, count)
            }
        }
    }

    private func computeSpectrum() {
        guard let fftSetup else { return }

        vDSP_vmul(history, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        windowed.withUnsafeBufferPointer { windowPointer in
            real.withUnsafeMutableBufferPointer { realPointer in
                imag.withUnsafeMutableBufferPointer { imagPointer in
                    guard let windowBase = windowPointer.baseAddress,
                          let realBase = realPointer.baseAddress,
                          let imagBase = imagPointer.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realBase, imagp: imagBase)

                    windowBase.withMemoryRebound(to: DSPComplex.self, capacity: halfSize) { complexPointer in
                        vDSP_ctoz(complexPointer, 2, &split, 1, vDSP_Length(halfSize))
                    }

                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                    var scale = 1 / Float(fftSize)
                    vDSP_vsmul(split.realp, 1, &scale, split.realp, 1, vDSP_Length(halfSize))
                    vDSP_vsmul(split.imagp, 1, &scale, split.imagp, 1, vDSP_Length(halfSize))

                    powerBins.withUnsafeMutableBufferPointer { powerPointer in
                        guard let powerBase = powerPointer.baseAddress else { return }
                        vDSP_zvmags(&split, 1, powerBase, 1, vDSP_Length(halfSize))
                    }
                }
            }
        }

        var floor: Float = 1.0e-12
        vDSP_vthr(powerBins, 1, &floor, &powerBins, 1, vDSP_Length(halfSize))
        var reference: Float = 1
        vDSP_vdbcon(powerBins, 1, &reference, &dbBins, 1, vDSP_Length(halfSize), 0)

        for bar in 0..<barCount {
            let sampledDb = interpolatedDb(at: binCenters[bar])
            let normalized = clamp((sampledDb + 96) / 78, 0, 1)
            magnitudes[bar] = magnitudes[bar] * 0.68 + normalized * 0.32
        }
    }

    private func interpolatedDb(at fractionalBin: Float) -> Float {
        let clampedBin = clamp(fractionalBin, 1, Float(halfSize - 2))
        let lowerIndex = Int(clampedBin)
        let upperIndex = lowerIndex + 1
        let fraction = clampedBin - Float(lowerIndex)
        let lower = dbBins[lowerIndex]
        let upper = dbBins[upperIndex]
        return lower + (upper - lower) * fraction
    }

    private func updateDynamics(sampleCount: Int) {
        var peak: Float = 0
        var rms: Float = 0

        drainBuffer.withUnsafeBufferPointer { sourcePointer in
            guard let sourceBase = sourcePointer.baseAddress else { return }
            let count = vDSP_Length(sampleCount)
            vDSP_maxmgv(sourceBase, 1, &peak, count)
            vDSP_rmsqv(sourceBase, 1, &rms, count)
        }

        let peakDb = amplitudeToDb(peak)
        let rmsDb = amplitudeToDb(rms)
        let crestDb = max(0, peakDb - rmsDb)

        smoothedPeakDb = releaseSmooth(current: smoothedPeakDb, target: peakDb, step: levelReleaseDbPerTick)
        smoothedRMSDb = releaseSmooth(current: smoothedRMSDb, target: rmsDb, step: levelReleaseDbPerTick)
        smoothedCrestDb = releaseSmooth(current: smoothedCrestDb, target: crestDb, step: crestReleaseDbPerTick)

        dynamicsPublishCounter += 1
        if dynamicsPublishCounter >= 2 {
            dynamicsPublishCounter = 0
            let levels = DynamicsMeterModel.Levels(
                peak: smoothedPeakDb, rms: smoothedRMSDb, crestFactor: smoothedCrestDb
            )
            let token = publicationToken
            Task { @MainActor [dynamicsModel] in
                guard token.isValid else { return }
                dynamicsModel.update(peak: levels.peak, rms: levels.rms, crestFactor: levels.crestFactor)
            }
        }
    }

    private func amplitudeToDb(_ value: Float) -> Float {
        let clamped = max(value, 0.00001)
        return max(20 * log10(clamped), -100)
    }

    private func releaseSmooth(current: Float, target: Float, step: Float) -> Float {
        if target >= current {
            return target
        }
        return max(current - step, target)
    }

    private func rebuildLogBins() {
        let nyquist = max(sampleRate * 0.5, 1_000)
        let minHz: Float = 28
        let bassMaxHz: Float = min(420, nyquist * 0.75)
        let maxHz = min(nyquist, 20_000)
        let bassBarRatio: Float = 0.38
        let bassCurve: Float = 0.82
        let minLog = log(max(bassMaxHz, minHz + 1))
        let maxLog = log(max(maxHz, bassMaxHz + 1))

        for bar in 0..<barCount {
            let ratio = (Float(bar) + 0.5) / Float(barCount)
            let centerHz: Float
            if ratio < bassBarRatio {
                let bassRatio = ratio / bassBarRatio
                centerHz = minHz + pow(bassRatio, bassCurve) * (bassMaxHz - minHz)
            } else {
                let trebleRatio = (ratio - bassBarRatio) / (1 - bassBarRatio)
                centerHz = exp(minLog + (maxLog - minLog) * trebleRatio)
            }
            binCenters[bar] = clamp((centerHz / sampleRate) * Float(fftSize), 1, Float(halfSize - 2))
        }
    }

    /// No Process Tap or audio device is opened. This exercises the actual
    /// worker's high-rate drain, history boundary and discard/rate reset paths.
    @MainActor
    static func runOfflineChecks() throws {
        func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            guard condition() else {
                throw NSError(domain: "LowEndAudioAnalysisChecks", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
#if SWIFT_PACKAGE
        if #available(macOS 14.4, *) {
            try require(MetalSpectrumView.Coordinator.packagedShaderURL() != nil,
                        "the delivered executable must resolve its packaged SwiftPM shader bundle")
        }
#endif
        let slots = MetalSpectrumFrameSlots(count: 3)
        let acquired = [slots.acquire(), slots.acquire(), slots.acquire()]
        try require(Set(acquired.compactMap { $0 }).count == 3, "in-flight GPU slots must be distinct")
        try require(slots.acquire() == nil, "a slow GPU must skip a frame without reusing its resources")
        slots.release(1)
        try require(slots.acquire() == 1, "only a completed GPU slot may become writable")
        let uniforms = MetalSpectrumUniforms()
        try require(uniforms.layout == SIMD4<Float>(42, 5, 1.5, 0), "all shader layout defaults must be initialized")
        try require(MemoryLayout<MetalSpectrumUniforms>.stride == 32, "shader uniforms must preserve the two-float4 layout")

        // Exercise actual Metal completion, not a manually released slot. A
        // shared-event wait keeps submitted work in flight while further CPU
        // frames try to acquire storage. This opens no audio device or tap.
        if let device = MTLCreateSystemDefaultDevice(),
           let commandQueue = device.makeCommandQueue(),
           let event = device.makeSharedEvent() {
            let delayedSlots = MetalSpectrumFrameSlots(count: 3)
            var skipped = 0
            for round in 1...12 {
                var commands: [MTLCommandBuffer] = []
                var sources: [MTLBuffer] = []
                var destinations: [MTLBuffer] = []
                let callbacks = DispatchSemaphore(value: 0)
                // Always unblock submitted GPU work if a check throws.
                defer { event.signaledValue = UInt64(round) }
                for frame in 0..<3 {
                    guard let slot = delayedSlots.acquire(),
                          let source = device.makeBuffer(length: 256, options: .storageModeShared),
                          let destination = device.makeBuffer(length: 256, options: .storageModeShared),
                          let command = commandQueue.makeCommandBuffer() else {
                        throw NSError(domain: "LowEndAudioAnalysisChecks", code: 2,
                                      userInfo: [NSLocalizedDescriptionKey: "Metal delayed-frame setup failed"])
                    }
                    let sentinel = UInt8(round * 3 + frame)
                    source.contents().initializeMemory(as: UInt8.self, repeating: sentinel, count: 256)
                    destination.contents().initializeMemory(as: UInt8.self, repeating: 0, count: 256)
                    command.encodeWaitForEvent(event, value: UInt64(round))
                    guard let blit = command.makeBlitCommandEncoder() else {
                        throw NSError(domain: "LowEndAudioAnalysisChecks", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "Metal blit encoder unavailable"])
                    }
                    blit.copy(from: source, sourceOffset: 0, to: destination, destinationOffset: 0, size: 256)
                    blit.endEncoding()
                    delayedSlots.releaseAfterCompletion(slot, of: command)
                    command.addCompletedHandler { _ in callbacks.signal() }
                    commands.append(command); sources.append(source); destinations.append(destination)
                    command.commit()
                }
                Thread.sleep(forTimeInterval: 0.01)
                for _ in 0..<100 {
                    try require(delayedSlots.acquire() == nil,
                                "a pending Metal command exposed its CPU frame storage")
                    skipped += 1
                }
                event.signaledValue = UInt64(round)
                for _ in 0..<3 {
                    try require(callbacks.wait(timeout: .now() + 5) == .success,
                                "Metal completion handler did not return its slot")
                }
                for command in commands {
                    try require(command.status == .completed, "delayed Metal command failed")
                }
                for frame in 0..<3 {
                    let bytes = destinations[frame].contents().assumingMemoryBound(to: UInt8.self)
                    try require((0..<256).allSatisfy { bytes[$0] == UInt8(round * 3 + frame) },
                                "in-flight GPU resource contents changed before completion")
                }
                withExtendedLifetime(sources) {}
            }
            print("AudioAnalysisChecks: Metal delayed completion 36 commands, \(skipped) skipped acquisitions, 0 resource mismatches (\(device.name))")
        } else {
            print("AudioAnalysisChecks: SKIP real Metal delayed completion (device/queue/shared event unavailable)")
        }

        let ring = try LockFreeFloatRingBuffer(capacityFrames: 65_536, channels: 2)
        let model = DynamicsMeterModel()
        let spectrum = SpectrumModel()
        spectrum.setAnalysisActive(true)
        let analyzer = AudioSpectrumAnalyzer(ringBuffer: ring, sampleRate: 768_000,
                                             dynamicsModel: model, spectrumModel: spectrum)
        let frames = 30_000 // More than the old 16,384-frame per-tick limit.
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(frame) / Float(frames)
            input[frame * 2] = value
            input[frame * 2 + 1] = value
        }
        input.withUnsafeBufferPointer { ring.push($0.baseAddress!, count: $0.count) }
        let completed = DispatchSemaphore(value: 0)
        let offMain = AnalysisPublicationToken()
        analyzer.analysisQueue.async {
            if pthread_main_np() != 0 { offMain.invalidate() }
            analyzer.tick()
            completed.signal()
        }
        try require(completed.wait(timeout: .now() + 5) == .success, "the analysis worker must complete its input snapshot")
        try require(offMain.isValid, "FFT/history work must run off the main thread")
        try analyzer.withAnalysisQueue {
            try require(ring.availableSamples() == 0, "one tick must consume the entire finite input snapshot")
            try require(analyzer.filledSamples == analyzer.fftSize, "the latest FFT window must remain full")
            try require(abs(analyzer.history[0] - Float(frames - analyzer.fftSize) / Float(frames)) < 1e-6,
                        "history must begin at the newest complete FFT window")
            try require(abs(analyzer.history.last! - Float(frames - 1) / Float(frames)) < 1e-6,
                        "history must end at the newest stereo frame")
            analyzer.computeSpectrum()
            try require(analyzer.magnitudes.allSatisfy(\.isFinite), "FFT output must remain finite")
        }
        ring.requestDiscard()
        try analyzer.withAnalysisQueue {
            analyzer.tick()
            try require(analyzer.filledSamples == 0 && analyzer.history.allSatisfy { $0 == 0 },
                        "the consumer must reset FFT history when it acknowledges a route discard")
        }
        analyzer.updateSampleRate(48_000)
        try analyzer.withAnalysisQueue {
            try require(analyzer.sampleRate == 48_000 && analyzer.filledSamples == 0,
                        "an output rate change must reset history on the worker queue")
        }
        analyzer.stop()
        print("AudioAnalysisChecks: frame ownership, uniforms, high-rate drain, worker and reset checks passed")
    }
}
