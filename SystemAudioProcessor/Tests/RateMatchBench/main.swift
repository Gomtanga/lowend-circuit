import CoreAudio
import Foundation

// Isolated benchmark for `setNominalSampleRate` + property-listener confirmation.
// Bypasses SystemAudioProcessor entirely so we can measure the hardware cost and
// verify that the property-listener signal fires (and how long it takes) on the
// current output device.

private func defaultOutputDevice() throws -> AudioObjectID {
    var deviceID = AudioObjectID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioObjectID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &address, 0, nil, &size, &deviceID
    )
    guard status == noErr else {
        throw NSError(domain: "RateMatchBench", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "default output device failed"])
    }
    return deviceID
}

private func nominalSampleRate(_ deviceID: AudioObjectID) throws -> Double {
    var value = Float64(0)
    var size = UInt32(MemoryLayout<Float64>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value)
    guard status == noErr else {
        throw NSError(domain: "RateMatchBench", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "read nominal rate failed"])
    }
    return Double(value)
}

private func setNominalSampleRate(_ deviceID: AudioObjectID, _ rate: Double) throws {
    var value = Float64(rate)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectSetPropertyData(
        deviceID, &address, 0, nil,
        UInt32(MemoryLayout<Float64>.size), &value
    )
    guard status == noErr else {
        throw NSError(domain: "RateMatchBench", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "set nominal rate failed"])
    }
}

private func availableRates(_ deviceID: AudioObjectID) -> [Double] {
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyAvailableNominalSampleRates,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr else {
        return []
    }
    let count = Int(size) / MemoryLayout<AudioValueRange>.stride
    var ranges = [AudioValueRange](repeating: AudioValueRange(mMinimum: 0, mMaximum: 0), count: count)
    guard count > 0,
          ranges.withUnsafeMutableBufferPointer({ ptr in
              AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, ptr.baseAddress!)
          }) == noErr else {
        return []
    }
    let standards: [Double] = [8_000, 11_025, 12_000, 16_000, 22_050, 24_000, 32_000,
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000, 705_600, 768_000]
    return standards.filter { rate in ranges.contains { rate >= $0.mMinimum - 0.5 && rate <= $0.mMaximum + 0.5 } }
}

private func rateText(_ rate: Double) -> String {
    String(format: "%.1fk", rate / 1000)
}

private final class ObservedRate: @unchecked Sendable {
    private let lock = NSLock()
    private var rate: Double?
    func store(_ value: Double) { lock.lock(); rate = value; lock.unlock() }
    func load() -> Double? { lock.lock(); defer { lock.unlock() }; return rate }
}

private func monotonicSeconds() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }

private func confirmedRate(_ deviceID: AudioObjectID, target: Double) throws -> Double {
    let deadline = monotonicSeconds() + 3
    repeat {
        let actual = try nominalSampleRate(deviceID)
        if abs(actual - target) <= 1 { return actual }
        Thread.sleep(forTimeInterval: 0.01)
    } while monotonicSeconds() < deadline
    throw NSError(domain: "RateMatchBench", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Rate confirmation timed out for device \(deviceID), target \(target)"])
}

private func runOnce(deviceID: AudioObjectID, to targetRate: Double,
                     listenerQueue: DispatchQueue) throws -> [String: Double] {
    let semaphore = DispatchSemaphore(value: 0)
    let observed = ObservedRate()
    let listener: AudioObjectPropertyListenerBlock = { _, _ in
        if let rate = try? nominalSampleRate(deviceID) { observed.store(rate) }
        semaphore.signal()
    }
    var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let added = AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, listener)
    guard added == noErr else { throw NSError(domain: "RateMatchBench.listener", code: Int(added)) }
    defer {
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &address, listenerQueue, listener)
        listenerQueue.sync {} // Retire callbacks before releasing their captured state.
    }
    var timings: [String: Double] = [:]
    let start = monotonicSeconds()
    try setNominalSampleRate(deviceID, targetRate)
    timings["setCallMs"] = (monotonicSeconds() - start) * 1_000
    let waitStart = monotonicSeconds()
    let result = semaphore.wait(timeout: .now() + .seconds(2))
    timings["listenerWaitMs"] = (monotonicSeconds() - waitStart) * 1_000
    timings["listenerFired"] = result == .success ? 1 : 0
    timings["signaledRate"] = observed.load() ?? -1
    timings["confirmedRate"] = try confirmedRate(deviceID, target: targetRate)
    timings["totalMs"] = (monotonicSeconds() - start) * 1_000
    return timings
}

private func benchmark() throws {
    var execute = false
    var explicitDevice: AudioObjectID?
    var rounds = 4
    var arguments = CommandLine.arguments.dropFirst().makeIterator()
    while let argument = arguments.next() {
        switch argument {
        case "--execute": execute = true
        case "--dry-run": execute = false
        case "--device":
            guard let value = arguments.next(), let number = UInt32(value), number != kAudioObjectUnknown else {
                throw NSError(domain: "RateMatchBench.arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "--device needs a nonzero numeric device ID"])
            }
            explicitDevice = number
        case "--rounds":
            guard let value = arguments.next(), let number = Int(value), (1...20).contains(number) else {
                throw NSError(domain: "RateMatchBench.arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "--rounds needs 1...20"])
            }
            rounds = number
        case "--help", "-h":
            print("RateMatchBench [--dry-run] [--device ID] [--rounds 1...20]")
            print("RateMatchBench --execute --device ID [--rounds 1...20]")
            print("Default is read-only. --execute changes this physical device's rate and may interrupt other audio. The original rate is restored and read back even if a round fails.")
            return
        default: throw NSError(domain: "RateMatchBench.arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown argument: \(argument)"])
        }
    }
    guard !execute || explicitDevice != nil else {
        throw NSError(domain: "RateMatchBench.arguments", code: 1, userInfo: [NSLocalizedDescriptionKey: "--execute requires --device ID; run --dry-run first"])
    }
    let deviceID = try explicitDevice ?? defaultOutputDevice()
    let originalRate = try nominalSampleRate(deviceID)
    let supported = availableRates(deviceID)
    print("Device: \(deviceID); original nominal rate: \(rateText(originalRate))")
    print("Supported standard rates: \(supported.map(rateText).joined(separator: ", "))")
    guard let rateA = supported.first(where: { $0 >= 44_100 }),
          let rateB = supported.last, rateA != rateB else {
        print("No two supported test rates are available.")
        return
    }
    print("Proposed: \(rateText(rateA)) ↔ \(rateText(rateB)), \(rounds) rounds; restore \(rateText(originalRate))")
    guard execute else { print("DRY RUN: no hardware values changed."); return }

    let listenerQueue = DispatchQueue(label: "rate-bench.listener")
    var failure: Error?
    do {
        var current = originalRate
        for round in 1...rounds {
            let next = abs(current - rateA) < 1 ? rateB : rateA
            let timings = try runOnce(deviceID: deviceID, to: next, listenerQueue: listenerQueue)
            print("Round \(round): \(rateText(current)) → \(rateText(next))")
            for key in timings.keys.sorted() { print("  \(key)=\(timings[key]!)") }
            current = next
        }
    } catch { failure = error }
    do {
        try setNominalSampleRate(deviceID, originalRate)
        let actual = try confirmedRate(deviceID, target: originalRate)
        print("RESTORE VERIFIED: device \(deviceID) at \(rateText(actual))")
    } catch {
        throw NSError(domain: "RateMatchBench.restore", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "RESTORE FAILED: device \(deviceID), original \(originalRate) Hz; \(error). Round error: \(String(describing: failure))"])
    }
    if let failure { throw failure }
}

do { try benchmark() }
catch { fputs("\(error)\n", stderr); exit(1) }
