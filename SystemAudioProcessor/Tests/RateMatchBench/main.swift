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
    return ranges.map { Double($0.mMinimum) }.sorted()
}

private func rateText(_ rate: Double) -> String {
    String(format: "%.1fk", rate / 1000)
}

private func runOnce(deviceID: AudioObjectID,
                     from startRate: Double,
                     to targetRate: Double,
                     listenerQueue: DispatchQueue) -> [String: Double] {
    let semaphore = DispatchSemaphore(value: 0)
    var signaledRate: Double?

    let listener: AudioObjectPropertyListenerBlock = { _, _ in
        if let r = try? nominalSampleRate(deviceID) {
            signaledRate = r
        }
        semaphore.signal()
    }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyNominalSampleRate,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    _ = AudioObjectAddPropertyListenerBlock(deviceID, &address, listenerQueue, listener)

    var timings: [String: Double] = [:]
    let t0 = Date()

    // Issue the hardware rate change.
    do {
        try setNominalSampleRate(deviceID, targetRate)
    } catch {
        timings["set.error"] = -1
        var addr2 = address
        _ = AudioObjectRemovePropertyListenerBlock(deviceID, &addr2, listenerQueue, listener)
        return timings
    }
    timings["afterSetCall"] = Date().timeIntervalSince(t0) * 1000

    // Wait for the property-listener signal.
    let waitStart = Date()
    let waitResult = semaphore.wait(timeout: .now() + .seconds(2))
    timings["listenerWait"] = Date().timeIntervalSince(waitStart) * 1000
    timings["listenerFired"] = (waitResult == .success) ? 1 : 0
    timings["signaledRate"] = signaledRate ?? -1

    // Also measure how long a direct read takes after the signal, in case the
    // property value lags the listener.
    let readStart = Date()
    let confirmedRate = (try? nominalSampleRate(deviceID)) ?? -1
    timings["postRead"] = Date().timeIntervalSince(readStart) * 1000
    timings["confirmedRate"] = confirmedRate
    timings["matchTarget"] = abs(confirmedRate - targetRate) <= 1 ? 1 : 0
    timings["total"] = Date().timeIntervalSince(t0) * 1000

    var addr2 = address
    _ = AudioObjectRemovePropertyListenerBlock(deviceID, &addr2, listenerQueue, listener)
    return timings
}

private func benchmark() throws {
    let deviceID = try defaultOutputDevice()
    let originalRate = try nominalSampleRate(deviceID)
    let supported = availableRates(deviceID)

    print("Default output device: \(deviceID)")
    print("Current nominal rate: \(rateText(originalRate))")
    print("Supported rates: \(supported.map(rateText).joined(separator: ", "))")

    guard supported.count >= 2 else {
        print("Device supports fewer than 2 sample rates. Cannot benchmark transitions.")
        return
    }

    // Pick two distinct rates to alternate between.
    let candidates = [44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0]
        .filter { supported.contains($0) }
    guard let rateA = candidates.first,
          let rateB = candidates.last,
          rateA != rateB else {
        print("Could not pick two distinct rates. Falling back to first/last supported.")
        let rateA = supported.first!
        let rateB = supported.last!
        try runRounds(deviceID: deviceID, rateA: rateA, rateB: rateB, originalRate: originalRate)
        return
    }

    try runRounds(deviceID: deviceID, rateA: rateA, rateB: rateB, originalRate: originalRate)
}

private func runRounds(deviceID: AudioObjectID,
                       rateA: Double,
                       rateB: Double,
                       originalRate: Double) throws {
    let listenerQueue = DispatchQueue(label: "rate-bench.listener")
    print("\nAlternating \(rateText(rateA)) ↔ \(rateText(rateB)) for 4 rounds...\n")

    // Start from rateA so the alternation is deterministic.
    if originalRate != rateA {
        try setNominalSampleRate(deviceID, rateA)
        Thread.sleep(forTimeInterval: 0.5)
    }

    var current = rateA
    for round in 1...4 {
        let next = (current == rateA) ? rateB : rateA
        print("Round \(round): \(rateText(current)) → \(rateText(next))")
        let timings = runOnce(deviceID: deviceID, from: current, to: next, listenerQueue: listenerQueue)
        for key in ["afterSetCall", "listenerWait", "listenerFired", "signaledRate",
                    "postRead", "confirmedRate", "matchTarget", "total"] {
            let value = timings[key] ?? -1
            if ["listenerFired", "matchTarget"].contains(key) {
                print("  \(key)=\(Int(value))")
            } else if ["signaledRate", "confirmedRate"].contains(key) {
                print("  \(key)=\(rateText(value))")
            } else {
                print("  \(key)=\(String(format: "%.1fms", value))")
            }
        }
        current = next
        Thread.sleep(forTimeInterval: 0.8)
    }

    // Restore original rate.
    print("\nRestoring original rate \(rateText(originalRate))...")
    try setNominalSampleRate(deviceID, originalRate)
    Thread.sleep(forTimeInterval: 0.5)
    let final = try nominalSampleRate(deviceID)
    print("Final rate: \(rateText(final)) \(final == originalRate ? "(ok)" : "(MISMATCH)")")
}

try benchmark()
