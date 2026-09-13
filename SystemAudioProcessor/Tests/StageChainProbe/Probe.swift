import AudioRingBufferC
import Darwin
import Foundation
import LowEndSupport
import StageProbe

// Only non-processing declarations from main.swift are repeated here. All
// processing classes and coefficient/geometry code are compiled unchanged.
enum AppError: Error { case message(String) }
func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
    min(max(value, lower), upper)
}

private func add(_ a: inout StageProbeCounts, _ b: StageProbeCounts) {
    a.mallocCalls += b.mallocCalls; a.callocCalls += b.callocCalls
    a.reallocCalls += b.reallocCalls; a.freeCalls += b.freeCalls
    a.zoneMallocCalls += b.zoneMallocCalls; a.zoneCallocCalls += b.zoneCallocCalls
    a.zoneReallocCalls += b.zoneReallocCalls
    a.mutexLockCalls += b.mutexLockCalls; a.mutexTryLockCalls += b.mutexTryLockCalls
    a.unfairLockCalls += b.unfairLockCalls; a.unfairTryLockCalls += b.unfairTryLockCalls
    a.otherAllocatorCalls += b.otherAllocatorCalls
}

private func countValues(_ c: StageProbeCounts) -> [UInt64] {
    [c.mallocCalls, c.callocCalls, c.reallocCalls, c.freeCalls, c.zoneMallocCalls,
     c.zoneCallocCalls, c.zoneReallocCalls, c.mutexLockCalls, c.mutexTryLockCalls,
     c.unfairLockCalls, c.unfairTryLockCalls, c.otherAllocatorCalls]
}

private let countNames = ["malloc", "calloc", "realloc", "free", "zone_malloc",
                          "zone_calloc", "zone_realloc", "pthread_mutex_lock",
                          "pthread_mutex_trylock", "os_unfair_lock", "os_unfair_trylock", "other_allocator_entrypoints"]

private final class Chain {
    let tonal: TonalDSPRouter
    let spatial: Spatializer
    let conditioning: ResamplingOutputConditioningEngine
    let input: UnsafeMutablePointer<Float>
    let postSpatial: UnsafeMutablePointer<Float>
    let output: UnsafeMutablePointer<Float>
    let drained: UnsafeMutablePointer<Float>
    let ring: OpaquePointer
    let analysisRing: OpaquePointer
    let frames: Int
    let settingsA: LCDSPSettings
    let settingsB: LCDSPSettings
    let spatialA: LCSpatialSettings
    let spatialB: LCSpatialSettings
    let conditioningA: OutputConditioningParameters
    let conditioningB: OutputConditioningParameters
    let precomputedHeadroomGain: Float
    let transitioning: Bool
    var outputFrames = 0
    var droppedSamples: UInt64 = 0
    var nonFiniteSamples: UInt64 = 0
    var checksum: Double = 0
    var freshThreadCounts = StageProbeCounts()
    var freshThreadCPU: Double = 0
    var freshThreadElapsed: Double = 0
    var diagnosticTrace = false

    init(rate: Float, frames: Int, model: Settings.DSPModel,
         nextModel: Settings.DSPModel, conditioningMode: String, transitioning: Bool) {
        self.frames = frames; self.transitioning = transitioning
        settingsA = DSPPrecompute.makeDSPSettings(sampleRate: rate, intensity: 55,
            body: 30, outputDb: -1.5, dspModel: model)
        settingsB = DSPPrecompute.makeDSPSettings(sampleRate: rate, intensity: 75,
            body: 60, outputDb: -1.5, dspModel: nextModel)
        spatialA = DSPPrecompute.makeSpatialSettings(sampleRate: rate, settings:
            SpatialSettings(enabled: true, listenerX: 0.4, listenerZ: -0.6,
                            speakerWidth: 1.65, amount: 35))
        spatialB = DSPPrecompute.makeSpatialSettings(sampleRate: rate, settings:
            SpatialSettings(enabled: true, listenerX: 3, listenerZ: 1.8,
                            speakerWidth: 3, amount: 100))
        var firstConditioning = OutputConditioningParameters()
        firstConditioning.isEnabled = conditioningMode != "bypass"
        firstConditioning.outputMode = firstConditioning.isEnabled ? .pcmOversampling : .bypass
        firstConditioning.filterMode = conditioningMode == "2x_long" ? .linearPhaseLong : .linearPhaseShort
        conditioningA = firstConditioning
        precomputedHeadroomGain = firstConditioning.headroomGain
        var nextConditioning = firstConditioning
        if conditioningMode == "2x_filter_transition" { nextConditioning.filterMode = .linearPhaseLong }
        conditioningB = nextConditioning
        tonal = TonalDSPRouter(sampleRate: rate, intensity: 55, body: 30,
                               outputDb: -1.5, dspModel: model)
        spatial = Spatializer(settings: spatialA)
        conditioning = ResamplingOutputConditioningEngine(maxInputFrames: frames)
        conditioning.updateSettings(conditioningA, precomputedHeadroomGain: precomputedHeadroomGain)
        input = .allocate(capacity: frames * 2)
        postSpatial = .allocate(capacity: frames * 2)
        output = .allocate(capacity: frames * 4)
        drained = .allocate(capacity: frames * 4)
        input.initialize(repeating: 0, count: frames * 2)
        postSpatial.initialize(repeating: 0, count: frames * 2)
        output.initialize(repeating: 0, count: frames * 4)
        drained.initialize(repeating: 0, count: frames * 4)
        for i in 0..<frames {
            let t = Double(i) / Double(rate)
            input[2 * i] = Float(0.2 * sin(2 * .pi * 55 * t) + 0.1 * sin(2 * .pi * 8_000 * t))
            input[2 * i + 1] = Float(0.18 * sin(2 * .pi * 71 * t) + 0.09 * cos(2 * .pi * 11_000 * t))
        }
        ring = lc_ring_buffer_create(UInt32(frames * 8))!
        analysisRing = lc_ring_buffer_create(UInt32(frames * 8))!
    }

    deinit {
        input.deallocate(); postSpatial.deallocate(); output.deallocate(); drained.deallocate()
        lc_ring_buffer_destroy(ring); lc_ring_buffer_destroy(analysisRing)
    }

    // Deliberately has no collection growth, logging, clock reads, or draining.
    // The event payloads above are prepared before the measured interval.
    @inline(never) func process(_ block: Int) {
        if transitioning {
            tonal.update(block % 2 == 0 ? settingsB : settingsA)
            spatial.update(block % 2 == 0 ? spatialB : spatialA)
            conditioning.updateSettings(block % 2 == 0 ? conditioningB : conditioningA,
                                        precomputedHeadroomGain: precomputedHeadroomGain)
        }
        for frame in 0..<frames {
            let t = tonal.process(left: input[frame * 2], right: input[frame * 2 + 1])
            let s = spatial.process(left: t.0, right: t.1)
            postSpatial[frame * 2] = s.0; postSpatial[frame * 2 + 1] = s.1
        }
        outputFrames = conditioning.processLive(input: postSpatial, inputFrames: frames, output: output)
        let sampleCount = UInt32(outputFrames * 2)
        droppedSamples += UInt64(sampleCount - lc_ring_buffer_push(ring, output, sampleCount))
        droppedSamples += UInt64(sampleCount - lc_ring_buffer_push(analysisRing, output, sampleCount))
    }

    func drainAndCheck() {
        let n = UInt32(outputFrames * 2)
        let consumed = lc_ring_buffer_pop(ring, drained, n)
        if consumed != n { droppedSamples += UInt64(n - consumed) }
        for index in 0..<Int(consumed) {
            if !drained[index].isFinite { nonFiniteSamples += 1 }
            checksum += Double(drained[index])
        }
        _ = lc_ring_buffer_pop(analysisRing, drained, n)
    }
}

// Ownership is handed to the C-created worker while the caller joins it. The
// two threads never touch the chain concurrently. No device thread is used.
@_cdecl("stage_probe_measure_fresh_thread")
private func measureFreshThread(_ context: UnsafeMutableRawPointer?) {
    let chain = Unmanaged<Chain>.fromOpaque(context!).takeUnretainedValue()
    _ = stage_probe_clock()
    let tickNanos = stage_probe_nanoseconds_per_tick()
    if chain.diagnosticTrace { stage_probe_enable_trace() }
    stage_probe_begin()
    let start = stage_probe_clock()
    chain.process(0)
    let end = stage_probe_clock()
    let counts = stage_probe_end()
    chain.freshThreadCounts = counts
    chain.freshThreadCPU = Double(end.cpuNanos - start.cpuNanos) / 1_000
    chain.freshThreadElapsed = Double(end.wallTicks - start.wallTicks) * tickNanos / 1_000
    chain.drainAndCheck()
    if chain.diagnosticTrace { stage_probe_print_trace() }
}

@main struct StageChainProbe {
    static func main() throws {
        let iterations = min(10_000, max(100, CommandLine.arguments.dropFirst().first.flatMap(Int.init) ?? 1_000))
        let captureTrace = CommandLine.arguments.contains("--trace-first-allocation")
        let tickNanos = stage_probe_nanoseconds_per_tick()
        stage_canary_calls() // warm symbol bindings and counter TLS
        stage_probe_begin()
        stage_canary_calls()
        let canary = stage_probe_end()
        let expectedIndices = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]
        let canaryValues = countValues(canary)
        guard expectedIndices.allSatisfy({ canaryValues[$0] > 0 }) else {
            throw AppError.message("Interposition canary failed: \(canaryValues)")
        }
        stage_probe_begin()
        let swiftAllocation = UnsafeMutablePointer<Float>.allocate(capacity: 4_096)
        let touched = stage_canary_touch(swiftAllocation)
        let swiftCounts = stage_probe_end()
        swiftAllocation.deallocate()
        guard touched == 79 && swiftCounts.mallocCalls + swiftCounts.zoneMallocCalls + swiftCounts.otherAllocatorCalls > 0 else {
            throw AppError.message("Swift allocation canary was not intercepted: \(countValues(swiftCounts))")
        }
        guard stage_probe_clock().cpuNanos > 0 else { throw AppError.message("Thread CPU clock unavailable") }
        print("# canary_names=" + countNames.joined(separator: ";"))
        print("# canary_counts=" + canaryValues.map(String.init).joined(separator: ";"))
        print("# swift_allocation_canary=" + countValues(swiftCounts).map(String.init).joined(separator: ";"))
        print("# diagnostic_trace_enabled=\(captureTrace)")
        print("# Scope: offline production stage chain + two C ring pushes; no CoreAudio callback, scheduling priority, device, queue drain, output render, or GPU workload.")
        print("# Durations include clock-read overhead; elapsed includes preemption; thread_cpu excludes descheduled time. All allocator counts are symbol calls, potentially overlapping, not unique allocations.")
        let header = ["rate_hz", "block_frames", "model", "next_model", "scenario", "conditioning", "blocks", "block_budget_us",
                      "cpu_p50_us", "cpu_p95_us", "cpu_max_us", "elapsed_p50_us", "elapsed_p95_us", "elapsed_max_us",
                      "cold_cpu_us", "cold_elapsed_us", "fresh_thread_cpu_us", "fresh_thread_elapsed_us"]
            + countNames + countNames.map { "cold_" + $0 } + countNames.map { "fresh_thread_" + $0 }
            + ["dropped_samples", "nonfinite_samples", "checksum"]
        print(header.joined(separator: ","))
        let rates: [Float] = [44_100, 48_000, 96_000, 192_000, 384_000, 768_000]
        let models: [Settings.DSPModel] = [.clean, .circuit, .highExciter]
        for rate in rates {
            for frames in [64, 256] {
                for (index, model) in models.enumerated() {
                    let nextModel = models[(index + 1) % models.count]
                    var modes = [("bypass", false), ("bypass", true)]
                    if rate == 44_100 || rate == 48_000 {
                        modes += [("2x_short", false), ("2x_long", false), ("2x_filter_transition", true)]
                    }
                    for (mode, transition) in modes {
                        let chain = Chain(rate: rate, frames: frames, model: model,
                                          nextModel: nextModel, conditioningMode: mode, transitioning: transition)
                        let cpu = UnsafeMutablePointer<Double>.allocate(capacity: iterations)
                        let elapsed = UnsafeMutablePointer<Double>.allocate(capacity: iterations)
                        cpu.initialize(repeating: 0, count: iterations)
                        elapsed.initialize(repeating: 0, count: iterations)
                        if captureTrace { stage_probe_enable_trace() }
                        stage_probe_begin()
                        let coldStart = stage_probe_clock()
                        chain.process(0)
                        let coldEnd = stage_probe_clock()
                        let coldCounts = stage_probe_end()
                        chain.drainAndCheck()
                        if captureTrace { stage_probe_print_trace() }
                        for block in 1...256 { chain.process(block); chain.drainAndCheck() }
                        var totals = StageProbeCounts()
                        for block in 0..<iterations {
                            stage_probe_begin()
                            let start = stage_probe_clock()
                            chain.process(block)
                            let end = stage_probe_clock()
                            let counts = stage_probe_end()
                            cpu[block] = Double(end.cpuNanos - start.cpuNanos) / 1_000
                            elapsed[block] = Double(end.wallTicks - start.wallTicks) * tickNanos / 1_000
                            add(&totals, counts)
                            chain.drainAndCheck()
                        }
                        // Sorting, formatting, and output happen after measurement.
                        let cpuSorted = Array(UnsafeBufferPointer(start: cpu, count: iterations)).sorted()
                        let wallSorted = Array(UnsafeBufferPointer(start: elapsed, count: iterations)).sorted()
                        cpu.deallocate(); elapsed.deallocate()
                        let p50 = iterations / 2, p95 = Int(ceil(Double(iterations) * 0.95)) - 1
                        // Preparing/warming on this thread must not be mistaken
                        // for initializing Swift runtime state on a new worker.
                        chain.tonal.resetState(); chain.spatial.resetState(); chain.conditioning.resetAll()
                        chain.diagnosticTrace = captureTrace
                        let threadResult = stage_probe_on_fresh_thread(Unmanaged.passUnretained(chain).toOpaque(), measureFreshThread)
                        guard threadResult == 0 else { throw AppError.message("Fresh-thread diagnostic failed: \(threadResult)") }
                        let values = [Double(frames) / Double(rate) * 1_000_000,
                                      cpuSorted[p50], cpuSorted[p95], cpuSorted.last!,
                                      wallSorted[p50], wallSorted[p95], wallSorted.last!,
                                      Double(coldEnd.cpuNanos - coldStart.cpuNanos) / 1_000,
                                      Double(coldEnd.wallTicks - coldStart.wallTicks) * tickNanos / 1_000,
                                      chain.freshThreadCPU, chain.freshThreadElapsed]
                        var row = [String(Int(rate)), String(frames), model.rawValue,
                                   transition ? nextModel.rawValue : model.rawValue,
                                   transition ? "model_spatial_transition" : "steady_spatial_on", mode, String(iterations)]
                        row += values.map { String(format: "%.3f", $0) }
                        row += countValues(totals).map(String.init)
                        row += countValues(coldCounts).map(String.init)
                        row += countValues(chain.freshThreadCounts).map(String.init)
                        row += [String(chain.droppedSamples), String(chain.nonFiniteSamples), String(format: "%.8f", chain.checksum)]
                        print(row.joined(separator: ","))
                        guard chain.droppedSamples == 0 && chain.nonFiniteSamples == 0 else {
                            throw AppError.message("Output validation failed at \(rate)/\(frames)/\(model)/\(mode)")
                        }
                    }
                }
            }
        }
    }
}
